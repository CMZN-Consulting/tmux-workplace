t_generation_counter_leftovers() {
  mkdir -p -- "$scratch/counter-build/shared/7" "$scratch/counter-build/floors/deck/11"
  cat > "$scratch/counter-driver" <<'BASH'
source <(sed -nE '/^build_(state_lock|generation_next|state_begin)\(\) \{$/,/^}$/p' "$1")
counter_state=$2 build_dir=$3
state_root() { printf '%s\n' "$counter_state"; }
die() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
build_state_begin specimen
printf '%s\n' "$build_generation"
BASH
  local state=$scratch/counter-state
  check "[C116] an unnamed floor generation bounds the first allocated number" bash -c '
    [[ $("$BASH" "$1" "$2" "$3" "$4") == 12 ]]
  ' _ "$scratch/counter-driver" "$tool/bin/workplace" "$state" "$scratch/counter-build"
  check "[C116] the counter durably reserves the following number" test "$(cat "$state/specimen/generation.next")" = 13
  mkdir -- "$scratch/counter-build/shared/12"
  rm -- "$state/specimen/generation.next"
  check "[C116] losing the counter does not reuse a directory left by a stopped build" bash -c '
    [[ $("$BASH" "$1" "$2" "$3" "$4") == 13 ]]
  ' _ "$scratch/counter-driver" "$tool/bin/workplace" "$state" "$scratch/counter-build"
  mkdir -- "$scratch/counter-build/shared/19"
  printf '%s\n' 1 > "$state/specimen/generation.next"
  check "[C116] a stale counter also respects a higher unnamed shared generation" bash -c '
    [[ $("$BASH" "$1" "$2" "$3" "$4") == 20 ]]
  ' _ "$scratch/counter-driver" "$tool/bin/workplace" "$state" "$scratch/counter-build"
  check "[C116] saving the next count preserves its private mode" test "$(stat -c %a -- "$state/specimen/generation.next")" = 600
}

t_generations_entry_lock() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C117] generations lock fixture plans" exit_is 0 wplan
  check "[C117] fixture builds" exit_is 0 wp build
  local real_tmux s action pid kind selected_locale=C
  real_tmux=$(command -v tmux) s=$(state_of)
  if [[ -z $(env LC_ALL=C.UTF-8 "$BASH" -c : 2>&1) ]]; then selected_locale=C.UTF-8
  else skip "[C117] no C.UTF-8 caller locale is installed; lock lifetime is still measured with C"; fi
  mkdir -- "$scratch/generations-tmux"
  printf '%s\n' '#!/usr/bin/env bash' \
    "if [[ -f '$scratch/generations-gate' ]]; then" \
    "  kind=\$(cat '$scratch/generations-gate')" \
    '  for arg in "$@"; do if [[ $arg == "$kind" ]]; then' \
    "    : > '$scratch/generations-entered'; while [[ -e '$scratch/generations-gate' ]]; do sleep 0.05; done" \
    '    break; fi; done' \
    'fi' \
    "exec '$real_tmux' \"\$@\"" > "$scratch/generations-tmux/tmux"
  chmod +x -- "$scratch/generations-tmux/tmux"
  for action in up restart; do
    kind=new-session
    local -a arguments=(up deck)
    if [[ $action == restart ]]; then
      check "[C117] end the selected synthetic program before restart" exit_is 0 on deck T send-keys -t "$(on deck pane_by_title 'Harbor Keeper')" C-c
      check "[C117] the selected program has ended before restart" eventually_long on deck dead_pane "Harbor Keeper"
      kind=respawn-pane arguments=(restart deck "Harbor Keeper")
    fi
    rm -f -- "$scratch/generations-entered"
    printf '%s\n' "$kind" > "$scratch/generations-gate"
    timeout --kill-after=1 20 env LC_ALL="$selected_locale" PATH="$scratch/generations-tmux:$PATH" "$BASH" "$loop" "${arguments[@]}" > "$scratch/generations-$action.log" 2>&1 & pid=$!
    if ! eventually_long test -e "$scratch/generations-entered"; then
      fail "[C117] $action did not reach its native gate"
      rm -f -- "$scratch/generations-gate"
      wait "$pid" 2>/dev/null
      cat "$scratch/generations-$action.log"
      return 1
    fi
    check "[C117] $action holds the shared generations lock through its native work" bash -c '! flock -n -x "$1" true' _ "$s/generations.lock"
    rm -- "$scratch/generations-gate"
    if wait "$pid"; then check "[C117] $action completes after its gate opens" true
    else fail "[C117] $action failed after its gate opened"; cat "$scratch/generations-$action.log"; return 1; fi
    check "[C117] $action leaves no generations lock inherited by its living children" flock -n -x "$s/generations.lock" true
    check "[C117] $action keeps the caller's locale across its command boundary" test "$(on deck T show-environment -g LC_ALL)" = "LC_ALL=$selected_locale"
  done
  check "[C117] stop the synthetic floor" exit_is 0 wp down deck
}

generation_test_project() {
  jq -c -L "$tool/libexec" --slurpfile binding "$tool/host/binding.json" --slurpfile view "$2" \
    --argjson conf '{"deck":"deck-conf","bridge":"bridge-conf","lodge":"lodge-conf"}' \
    'include "generations"; generation_slices($binding[0];$view[0];$conf)' "$1" > "$3"
}

generation_test_changes() {
  jq -ne --slurpfile old "$1" --slurpfile new "$2" --argjson wanted "$3" '
    [$old[0].slices | keys[] | select($old[0].slices[.]!=$new[0].slices[.])] == $wanted'
}

t_generation_slices() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["reach","orchard","barn","grower","seat","mail","-","-","-","workplace","banned"];2)]'
  check "[C118] floor projection fixture plans" exit_is 0 wplan
  local plan=$clone/PLAN/plan.json view=$clone/PLAN/view.json base=$scratch/slices-base next=$scratch/slices-next
  check "[C118] project the accepted plan and folded view" generation_test_project "$plan" "$view" "$base"
  [[ -s $base ]] || return 1
  check "[C118] every declared floor has a slice" jq -e '.slices|keys==["bridge","deck","lodge"]' "$base"
  jq 'walk(if type=="object" and has("origin") then .origin={path:"moved.typify",line:900} else . end)' "$plan" > "$scratch/origin-plan"
  jq 'walk(if type=="object" and has("origins") then .origins=[{path:"moved.typify",line:900}] else . end)' "$view" > "$scratch/origin-view"
  generation_test_project "$scratch/origin-plan" "$scratch/origin-view" "$next"
  check "[C118] origin changes alone change no projection" jq -ne --slurpfile a "$base" --slurpfile b "$next" '$a[0]==$b[0]'
  jq '(.programs[] | select(.path=="harbor/dock/keeper/seat.typify") | .plan[1].term[5])=(["/usr/bin/printf","changed"]|tojson)' "$plan" > "$scratch/command-plan"
  generation_test_project "$scratch/command-plan" "$view" "$next"
  check "[C118] a changed command belongs to its own floor" generation_test_changes "$base" "$next" '["deck"]'
  jq '(.programs[] | select(.path=="harbor/dock/keeper/seat.typify") | .plan[1].term[5]) |= ("  "+.+"  ")' "$plan" > "$scratch/formatted-plan"
  generation_test_project "$scratch/formatted-plan" "$view" "$next"
  check "[C118] JSON formatting of the same argv adds no operational change" generation_test_changes "$base" "$next" '[]'
  jq '.state.environment += [{key:["orchard","barn","grower","WPT_SLICE"],value:["new"],masked:false,origin:{path:"env.typify",line:1}}]' "$plan" > "$scratch/environment-plan"
  generation_test_project "$scratch/environment-plan" "$view" "$next"
  check "[C118] an environment change belongs to the receiving floor" generation_test_changes "$base" "$next" '["bridge"]'
  jq '(.seats[] | select(.seat==["orchard","barn","grower"])).reach.mail=["Harbor Keeper"]' "$view" > "$scratch/relation-view"
  generation_test_project "$plan" "$scratch/relation-view" "$next"
  check "[C118] a cross-floor relation is excluded from every private slice" generation_test_changes "$base" "$next" '[]'
  check "[C118] that relation is still represented in the shared relation index" jq -e 'any(.relations[]; .from=="Orchard Grower" and .from_floor=="bridge" and .to=="Harbor Keeper" and .to_floor=="deck" and .action=="mail")' "$next"
  jq '.records={path:"records",limit:17,chain:"file",origins:[]}' "$view" > "$scratch/global-view"
  generation_test_project "$plan" "$scratch/global-view" "$next"
  check "[C118] repeated global record settings are compared outside private slices" jq -ne --slurpfile a "$base" --slurpfile b "$next" '$a[0].globals!=$b[0].globals'
}

generation_test_faults() {
  jq -n -L "$tool/libexec" --slurpfile old "$1" --slurpfile new "$2" --arg floor "$3" \
    'include "generations"; $old[0] | generation_rebuild_faults($new[0];$floor)' > "$4"
}

t_generation_admission_model() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["reach","orchard","barn","grower","seat","mail","-","-","-","workplace","banned"];2)]'
  check "[C118] admission component fixture plans" exit_is 0 wplan
  local base=$scratch/admission-base next=$scratch/admission-next faults=$scratch/admission-faults
  generation_test_project "$clone/PLAN/plan.json" "$clone/PLAN/view.json" "$base"
  [[ -s $base ]] || { fail "[C118] the admission fixture has no projected model"; return 1; }
  jq '.slices.deck.terms += [["start","harbor","dock","extra",".",["/usr/bin/true"]]]' "$base" > "$next"
  generation_test_faults "$base" "$next" deck "$faults"
  check "[C118] the component permits a change confined to the requested floor" jq -e 'length==0' "$faults"
  jq '.slices.bridge.environment += [{key:["orchard","barn","grower","WPT_SLICE"],value:["different"],masked:false}]' "$base" > "$next"
  generation_test_faults "$base" "$next" deck "$faults"
  check "[C118] a different floor's environment requires a whole build" jq -e 'any(.[]; .kind=="slice" and .floor=="bridge" and .member=="environment")' "$faults"
  jq '.relations += [{from:"Orchard Grower",from_floor:"bridge",to:"Harbor Keeper",to_floor:"deck",action:"mail"}] | .relations |= sort_by([.from,.action,.to])' "$base" > "$next"
  generation_test_faults "$base" "$next" deck "$faults"
  check "[C118] a shared mail pair touching the requested floor is permitted" jq -e 'length==0' "$faults"
  generation_test_faults "$base" "$next" lodge "$faults"
  check "[C118] that same pair is refused for an unrelated requested floor" jq -e 'any(.[]; .kind=="unrelated-mail")' "$faults"
  jq '.slices.deck.conf="new-conf"' "$base" > "$next"
  generation_test_faults "$base" "$next" deck "$faults"
  check "[C118] the requested floor may replace its own configuration bytes" jq -e 'length==0' "$faults"
  generation_test_faults "$base" "$next" lodge "$faults"
  check "[C118] another floor's configuration bytes cannot change" jq -e 'any(.[]; .kind=="slice" and .floor=="deck" and .member=="conf")' "$faults"
  jq '(.floors[] | select(.[1]=="deck"))[7]="new-smallest"' "$base" > "$next"
  generation_test_faults "$base" "$next" deck "$faults"
  check "[C118] the requested smallest value is the admitted floor-line change" jq -e 'length==0' "$faults"
  jq '(.floors[] | select(.[1]=="deck"))[2]="renamed"' "$base" > "$next"
  generation_test_faults "$base" "$next" deck "$faults"
  check "[C118] changing another field of that floor line requires a whole build" jq -e 'any(.[]; .kind=="floor-line")' "$faults"
}

t_generation_unpublished_files() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C119] generation-side-file fixture plans" exit_is 0 wplan
  check "[C119] fixture builds" exit_is 0 wp build
  mkdir -p -- "$clone/BUILD/shared/99/.work" "$clone/BUILD/floors/lodge/99/.work"
  printf '%s\n' staged > "$clone/BUILD/shared/99/.work/output"
  printf '%s\n' staged > "$clone/BUILD/floors/lodge/99/.work/output"
  printf '%s\n' '{"pid":1,"generation":99,"at":"2026-11-18T00:00:00Z"}' > "$clone/BUILD/floors/lodge/BUILDING"
  check "[C119] another floor still starts while unnamed generations and a peer marker stand" exit_is 0 wp up deck
  check "[C119] the unaffected floor stops normally" exit_is 0 wp down deck
  check "[C119] the part-built floor refuses before starting anything" exit_is 1 wp up lodge
  check "[C119] the refusal names the partial floor" said "the floor lodge is part-built"
  check "[C119] no partial run was made" test ! -e "$run/lodge"
  ln -s -- "$root/harbor/charts" "$clone/BUILD/shared/99/untrusted-link"
  check "[C119] an unnamed generation does not exempt a symbolic link" exit_is 1 wp up deck
  check "[C119] the link is named" said "symbolic link: shared/99/untrusted-link"
  rm -- "$clone/BUILD/shared/99/untrusted-link"
  printf '%s\n' unexpected > "$clone/BUILD/unknown-file"
  check "[C119] a file outside generation directories is still refused" exit_is 1 wp up deck
  check "[C119] the unlisted file is named" said "MANIFEST does not list: unknown-file"
  rm -- "$clone/BUILD/unknown-file" "$clone/BUILD/floors/lodge/BUILDING"
  check "[C119] removing the planted marker permits its unchanged published generation" exit_is 0 wp up lodge
  check "[C119] stop that synthetic floor" exit_is 0 wp down lodge
}

t_generation_key_prerequisites() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"' | .programs[-1].recorded += [{term:["key","lodge","east","-","room","held"],origin:at(2)}]'
  check "[C120] the key prerequisite fixture plans" exit_is 0 wplan
  (( test_failed == 0 )) || return 1
  check "[C120] the initial build makes a real synthetic key" exit_is 0 wp build
  (( test_failed == 0 )) || return 1
  local s before after
  s=$(state_of)
  before=$(find "$s/floors/lodge/keys" -type f -printf '%P %i %m %s\n' -exec sha256sum -- '{}' \; | sha256sum)
  check "[C120] generation scratch is absent after publication" bash -c '[[ -z $(find "$1/shared" "$1/floors" -name .work -print) && ! -e $1/key.out ]]' _ "$clone/BUILD"
  rm -rf -- "$clone/BUILD"
  mkdir -- "$scratch/key-prerequisite-bin"
  printf '%s\n' '#!/usr/bin/env bash' 'if [[ ${1-} == --version ]]; then printf "%s\n" "gpg (GnuPG) 2.0.0"; exit 0; fi; exit 2' > "$scratch/key-prerequisite-bin/gpg"
  chmod +x -- "$scratch/key-prerequisite-bin/gpg"
  check "[C120] an unavailable supported GnuPG refuses before replacing keys" exit_is 2 env PATH="$scratch/key-prerequisite-bin:$PATH" "$BASH" "$loop" build
  check "[C120] the refusal names the unsupported prerequisite" said "gpg 2.0.0 found"
  after=$(find "$s/floors/lodge/keys" -type f -printf '%P %i %m %s\n' -exec sha256sum -- '{}' \; | sha256sum)
  check "[C120] the existing floor's key files retain their bytes, inodes and modes" test "$before" = "$after"
}
