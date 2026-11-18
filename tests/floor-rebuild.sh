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
  jq -c --slurpfile binding "$tool/host/binding.json" --slurpfile view "$2" \
    --argjson conf '{"deck":"deck-conf","bridge":"bridge-conf","lodge":"lodge-conf"}' \
    '{plan:.,binding:$binding[0],view:$view[0],conf:$conf}' "$1" \
    | jq -c -L "$tool/libexec" --arg operation project -f "$tool/libexec/generations.jq" > "$3"
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
  jq -n --slurpfile old "$1" --slurpfile new "$2" --arg floor "$3" '{old:$old[0],new:$new[0],floor:$floor}' \
    | jq -L "$tool/libexec" --arg operation compare -f "$tool/libexec/generations.jq" > "$4"
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

t_generation_published_metadata() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$root/records"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["record","-","-","-","workplace","pane","kept"];2),
    m(["record-path","records"];3),m(["record-chain","file"];4),
    m(["key","lodge","east","-","room","held"];5)]'
  check "[C121] the metadata fixture plans" exit_is 0 wplan
  (( test_failed == 0 )) || return 1
  check "[C121] its whole build publishes the three floor slices" exit_is 0 wp build
  (( test_failed == 0 )) || return 1
  local generation shared floor name
  generation=$(top_gen) shared=$clone/BUILD/shared/$(top_gen)
  check "[C121] the shared projection pins the root, state and configuration edition" jq -e --arg root "$root" --arg state "$(state_of)" \
    '.root==$root and .state==$state and (.configuration.floors|length)==3 and (.slices|keys)==["bridge","deck","lodge"]' "$shared/projection.json"
  check "[C121] record-path origins stay in the shared settings" jq -e '.path!=null and (.origins|length)>0' "$shared/records.json"
  for floor in bridge deck lodge; do
    check "[C121] $floor has its own origin-free sealed slice" jq -e --arg floor "$floor" \
      '.floor[1]==$floor and ([paths | select(.[-1]=="origin" or .[-1]=="origins")]|length)==0' "$clone/BUILD/floors/$floor/$generation/slice.json"
    for name in keys.json homes.json records.json; do
      [[ -f $clone/BUILD/floors/$floor/$generation/$name ]] || continue
      check "[C121] $floor/$name carries no source origins" jq -e \
        '([paths | select(.[-1]=="origin" or .[-1]=="origins")]|length)==0' "$clone/BUILD/floors/$floor/$generation/$name"
    done
    check "[C121] $floor keeps cross-floor record reads in the shared view" jq -e 'all(.seats[]; has("reads")|not)' "$clone/BUILD/floors/$floor/$generation/records.json"
  done
  check "[C121] the new metadata is covered by generation verification" exit_is 0 wp status
}

generation_tree_digest() {
  { find "$@" -printf '%p %i %m %s\n'; find "$@" -type f -exec sha256sum -- '{}' \;; } | sort | sha256sum
}

generation_top_floor() {
  sed -n "\\|^[0-9a-f]\\{64\\}  floors/$1/[0-9]*/MANIFEST$|p" "$clone/BUILD/MANIFEST"
}

t_generation_floor_rebuild() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C122] the floor-rebuild fixture plans" exit_is 0 wplan
  (( test_failed == 0 )) || return 1
  check "[C122] its initial whole build succeeds" exit_is 0 wp build
  (( test_failed == 0 )) || return 1
  check "[C122] the witness floor starts" exit_is 0 wp up deck
  (( test_failed == 0 )) || return 1
  local s bridge_before deck_before deck_line deck_pid lodge_line lodge_pid generation next_count
  s=$(state_of)
  bridge_before=$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge")
  deck_before=$(generation_tree_digest "$clone/BUILD/floors/deck" "$s/floors/deck")
  deck_line=$(generation_top_floor deck) deck_pid=$(on deck T display-message -p '#{pid}')
  statements_plan "$floors_terms $lodge_west"
  check "[C122] adding a room on lodge makes a new plan" exit_is 0 wplan
  (( test_failed == 0 )) || return 1
  check "[C122] build lodge publishes only its floor and a shared generation" exit_is 0 wp build lodge
  (( test_failed == 0 )) || return 1
  check "[C122] the running floor keeps its exact top entry" test "$(generation_top_floor deck)" = "$deck_line"
  check "[C122] the running floor's generation and state keep their bytes, inodes and modes" test "$(generation_tree_digest "$clone/BUILD/floors/deck" "$s/floors/deck")" = "$deck_before"
  check "[C122] the down floor is also left byte for byte" test "$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge")" = "$bridge_before"
  check "[C122] the witness server is the same process" test "$(on deck T display-message -p '#{pid}')" = "$deck_pid"
  check "[C122] unknown floors are a usage error" exit_is 2 wp build unknown
  check "[C122] rebuilding more than one floor is a usage error" exit_is 2 wp build lodge deck
  check "[C122] a running floor must be stopped before rebuilding" exit_is 1 wp build deck
  check "[C122] the refusal names the existing run" said "RUN/deck stands; down deck first"
  generation=$(generation_top_floor lodge); generation=${generation%/MANIFEST}; generation=${generation##*/}
  next_count=$(cat "$s/generation.next")
  ( umask 077; jq -nc --argjson n "$generation" '{pid:1,generation:$n,at:"2026-11-18T00:00:00Z"}' > "$clone/BUILD/floors/lodge/BUILDING" )
  check "[C122] an already-committed matching edition recovers by removing its marker" exit_is 0 wp build lodge
  check "[C122] that recovery reports its exact operation" said "generation $generation was committed; its marker is removed"
  check "[C122] marker recovery allocates no new generation" test "$(cat "$s/generation.next")" = "$next_count"
  check "[C122] the rebuilt rooms floor starts" exit_is 0 wp up lodge
  (( test_failed == 0 )) || return 1
  check "[C122] its newly added seat exists" bash -c '"$1" -S "$2" list-panes -a -F "#{pane_title}" | grep -qxF "Lodge Ivo"' _ "$(command -v tmux)" "$run/lodge/$label"
  check "[C122] stop the floor of offices for its own change" exit_is 0 wp down deck
  lodge_line=$(generation_top_floor lodge) lodge_pid=$(on lodge T display-message -p '#{pid}')
  statements_plan "$floors_terms $lodge_west $harbor_yard"
  check "[C122] an added room on a floor of offices plans" exit_is 0 wplan
  (( test_failed == 0 )) || return 1
  check "[C122] a floor of offices rebuilds through the same interface" exit_is 0 wp build deck
  (( test_failed == 0 )) || return 1
  check "[C122] the rooms floor keeps its top entry" test "$(generation_top_floor lodge)" = "$lodge_line"
  check "[C122] and its living server" test "$(on lodge T display-message -p '#{pid}')" = "$lodge_pid"
  check "[C122] the third floor remains byte for byte after both builds" test "$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge")" = "$bridge_before"
  check "[C122] the rebuilt office floor starts" exit_is 0 wp up deck
  check "[C122] stop both synthetic servers" exit_is 0 wp down deck
  check "[C122] stop the rooms floor" exit_is 0 wp down lodge
}

t_generation_floor_admission() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox"
  statements_plan "$floors_terms | $comms_terms"
  check "[C123] the admission fixture plans" exit_is 0 wplan
  check "[C123] its initial whole build succeeds" exit_is 0 wp build
  (( test_failed == 0 )) || return 1
  local original count s entry title change expected before
  original=$(cat "$clone/workplace.json") s=$(state_of)
  count=$(cat "$s/generation.next") before=$(generation_tree_digest "$clone/BUILD")
  local -a changes=(
    'another floor command|terms_of("harbor/dock/keeper/seat.typify"; if .[0]=="start" then .[5]=(["/usr/bin/true"]|tojson) else . end)|slice of floor deck (terms)'
    'another floor environment|.state.environment += [{key:["harbor","dock","keeper","WPT_ADMISSION"],value:["changed"],masked:false,origin:at(22)}]|slice of floor deck (environment)'
    'unrelated mail|.programs[-1].recorded += [m(["reach","orchard","barn","grower","seat","mail","harbor","dock","keeper","seat","allowed"];23)]|unrelated-mail'
  )
  for entry in "${changes[@]}"; do
    title=${entry%%|*} entry=${entry#*|} change=${entry%|*} expected=${entry##*|}
    statements_plan "$floors_terms | $comms_terms | $change"
    check "[C123] $title is a valid plan before floor admission" exit_is 0 wplan
    (( test_failed == 0 )) || return 1
    if [[ $title == 'unrelated mail' ]]; then
      check "[C123] the unrelated mail case really adds its previously banned route" jq -e \
        'any(.seats[]; .seat==["orchard","barn","grower"] and (.reach.mail|index("Harbor Keeper"))!=null)' "$clone/PLAN/view.json"
      (( test_failed == 0 )) || return 1
    fi
    check "[C123] $title requires a whole build" exit_is 1 wp build lodge
    check "[C123] the refusal identifies $title" said "$expected"
    check "[C123] refusal of $title writes no published or staged file" test "$(generation_tree_digest "$clone/BUILD")" = "$before"
    check "[C123] refusal of $title allocates no generation" test "$(cat "$s/generation.next")" = "$count"
  done
  printf '%s\n' 'set -g status-left changed' > "$clone/floors/deck.conf"
  statements_plan "$floors_terms | $comms_terms"
  check "[C123] a changed peer configuration plans" exit_is 0 wplan
  check "[C123] the peer configuration requires a whole build" exit_is 1 wp build lodge
  check "[C123] that refusal identifies the configuration slice" said "slice of floor deck (conf)"
  : > "$clone/floors/deck.conf"
  jq '.floors |= reverse' <<< "$original" > "$clone/workplace.json"
  statements_plan "$floors_terms | $comms_terms"' | .programs[0].plan = [.programs[0].plan[0]] + ([.programs[0].plan[] | select(.[0]=="floor")]|reverse)'
  check "[C123] a reordered floor edition plans" exit_is 0 wplan
  check "[C123] changing floor order requires a whole build" exit_is 1 wp build lodge
  check "[C123] that refusal identifies topology" said "topology"
  printf '%s\n' "$original" > "$clone/workplace.json"
  statements_plan "$floors_terms | $comms_terms"
  check "[C123] restore the source edition" exit_is 0 wplan
  check "[C123] every admission refusal left BUILD unchanged" test "$(generation_tree_digest "$clone/BUILD")" = "$before"
  check "[C123] every admission refusal left the counter unchanged" test "$(cat "$s/generation.next")" = "$count"
}

t_generation_key_identity() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"' | .programs[-1].recorded += [
    {term:["key","lodge","east","-","room","held"],origin:at(2)},
    {term:["key","harbor","dock","-","room","held"],origin:at(3)}]'
  check "[C124] the key identity fixture plans" exit_is 0 wplan
  check "[C124] its whole build makes real keys on two floors" exit_is 0 wp build
  (( test_failed == 0 )) || return 1
  local s home generation expected before next actual
  s=$(state_of) generation=$(top_gen) home=$(state_of)/floors/lodge/keys/01
  expected=$(jq -r '.seats[0].fingerprint' "$clone/BUILD/floors/lodge/$generation/keys.json")
  check "[C124] the donor and recipient are distinct identities" test "$expected" != "$(jq -r '.seats[0].fingerprint' "$clone/BUILD/floors/deck/$generation/keys.json")"
  mv -- "$home" "$scratch/kept-key-home"
  cp -a -- "$s/floors/deck/keys/01" "$home"
  check "[C124] no agent answers for the substituted home before up" bash -c 'reply=$(gpg-connect-agent --homedir "$1" --no-autostart "GETINFO pid" /bye 2>/dev/null); [[ $reply != D\ * ]]' _ "$home"
  check "[C124] a swapped key home refuses up" exit_is 1 wp up lodge
  check "[C124] the refusal names the mismatched fingerprints" said "does not hold the signing and authentication fingerprints of this build"
  check "[C124] the rejected key leaves no run" test ! -e "$run/lodge"
  check "[C124] the rejected key starts no GnuPG agent" bash -c 'reply=$(gpg-connect-agent --homedir "$1" --no-autostart "GETINFO pid" /bye 2>/dev/null); [[ $reply != D\ * ]]' _ "$home"
  rm -rf -- "$home"
  mv -- "$scratch/kept-key-home" "$home"
  check "[C124] the restored genuine key starts" exit_is 0 wp up lodge
  (( test_failed == 0 )) || return 1
  check "[C124] stop the genuine key's floor" exit_is 0 wp down lodge
  before=$(generation_tree_digest "$home/private-keys-v1.d") next=$(cat "$s/generation.next")
  ( umask 077; jq -nc --argjson n "$generation" '{pid:1,generation:$n,at:"2026-11-18T00:00:00Z"}' > "$clone/BUILD/floors/lodge/BUILDING" )
  check "[C124] committed-marker recovery does not remake real keys" exit_is 0 wp build lodge
  check "[C124] the private key files keep their bytes, inodes and modes" test "$(generation_tree_digest "$home/private-keys-v1.d")" = "$before"
  check "[C124] marker recovery also preserves the generation count" test "$(cat "$s/generation.next")" = "$next"
  check "[C124] an ordinary floor build then makes a fresh identity" exit_is 0 wp build lodge
  (( test_failed == 0 )) || return 1
  actual=$(generation_top_floor lodge); actual=${actual%/MANIFEST}; actual=${actual##*/}
  check "[C124] the fresh build's fingerprint differs" test "$(jq -r '.seats[0].fingerprint' "$clone/BUILD/floors/lodge/$actual/keys.json")" != "$expected"
}

t_generation_reader_retry() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C125] the reader fixture plans" exit_is 0 wplan
  check "[C125] the reader fixture builds" exit_is 0 wp build
  check "[C125] its unchanged target floor starts" exit_is 0 wp up deck
  (( test_failed == 0 )) || return 1
  local real_jq old command expected pid result number=0
  local -a call
  real_jq=$(command -v jq)
  mkdir -- "$scratch/reader-bin"
  printf '%s\n' '#!/usr/bin/env bash' 'for word in "$@"; do' \
    "  if [[ -f '$scratch/reader-gate' && \$word == \"\$(cat '$scratch/reader-gate')\" ]]; then" \
    "    : > '$scratch/reader-entered'; while [[ -f '$scratch/reader-gate' ]]; do sleep 0.02; done" \
    '    break; fi' 'done' "exec '$real_jq' \"\$@\"" > "$scratch/reader-bin/jq"
  chmod +x -- "$scratch/reader-bin/jq"
  for command in status why doctor record exec; do
    case $command in
      status) call=(status deck); expected=0 ;;
      why) call=(why "Harbor Keeper" /); expected=0 ;;
      doctor) call=(doctor); expected=0 ;;
      record) call=(record verify "Harbor Keeper" 2026-11-18); expected=2 ;;
      exec) call=(exec --print -- "Harbor Keeper"); expected=0 ;;
    esac
    number=$(( number + 1 ))
    old=$(sed -n 's|^[0-9a-f]\{64\}  \(shared/[0-9]*\)/MANIFEST$|\1|p' "$clone/BUILD/MANIFEST")
    printf '%s\n' "$clone/BUILD/$old/plan.json" > "$scratch/reader-gate"
    rm -f -- "$scratch/reader-entered"
    timeout --kill-after=1 30 env PATH="$scratch/reader-bin:$PATH" "$BASH" "$loop" "${call[@]}" > "$scratch/reader-$command.out" 2> "$scratch/reader-$command.error" & pid=$!
    if ! eventually_long test -e "$scratch/reader-entered"; then
      fail "[C125] $command did not reach its old-generation read gate"
      rm -f -- "$scratch/reader-gate"
      wait "$pid" 2>/dev/null
      return 1
    fi
    check "[C125] publish during the $command read" exit_is 0 wp build lodge
    if [[ -d $clone/BUILD/$old ]]; then mv -- "$clone/BUILD/$old" "$scratch/reader-retired-$number"; fi
    check "[C125] the blocked reader's shared directory is retired" test ! -e "$clone/BUILD/$old"
    rm -- "$scratch/reader-gate"
    result=0; wait "$pid" || result=$?
    check "[C125] $command retries and preserves its native result" test "$result" = "$expected"
    check "[C125] $command emits no diagnostic from the retired generation" bash -c '! grep -qF "$1" "$2"' _ "$old" "$scratch/reader-$command.error"
    if [[ $command == status ]]; then
      check "[C125] status reports the final published top" grep -qF "$(sha256sum < "$clone/BUILD/MANIFEST" | cut -d' ' -f1)" "$scratch/reader-status.out"
    elif [[ $command == record ]]; then
      check "[C125] record verification retains its final refusal diagnostic" grep -qF 'this workplace keeps no record' "$scratch/reader-record.error"
    elif [[ $command == exec ]]; then
      check "[C125] exec print still returns its command array" jq -e 'type=="array" and length>0' "$scratch/reader-exec.out"
    fi
  done
  check "[C125] stop the unchanged target" exit_is 0 wp down deck
}

t_generation_exec_values() {
  if [[ $(nnp_of $$) != NoNewPrivs:0 ]]; then skip "[C125] final exec PID on an unenforced floor needs an unbarred caller"; return 0; fi
  scoped_clone
  floors_clone
  jq '(.floors[] | select(.key=="bridge")).socket="run"' "$clone/workplace.json" > "$scratch/config-next"
  mv -- "$scratch/config-next" "$clone/workplace.json"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\0" "$$" "$PWD" "$WPT_TOKEN" > "$1"' > "$root/tools/exec-probe"
  chmod +x -- "$root/tools/exec-probe"
  statements_plan "$floors_terms"' | (.programs[0].plan[] | select(.[0]=="floor" and .[1]=="bridge"))[5]="run"
    | .programs[-1].recorded += [{term:["expect","orchard","-","-","office","WPT_TOKEN"],origin:at(2)}]
    | terms_of("orchard/barn/grower/seat.typify"; if .[0]=="start" then .[4]=$root+"/harbor/berth" | .[5]=([$root+"/tools/exec-probe",$root+"/harbor/berth/exec-values"]|tojson) else . end)'
  check "[C125] the exec value fixture plans" exit_is 0 wplan
  check "[C125] it builds" exit_is 0 wp build
  (( test_failed == 0 )) || return 1
  local payload=$'two words\twith $ and "quotes" = end' s pid result
  local -a observed
  s=$(state_of)
  printf '%s' "$payload" | jq -Rs '{workplace:{WPT_TOKEN:.}}' > "$s/values.json"
  chmod 0600 -- "$s/values.json"
  check "[C125] the value-bearing Administration fixture starts" exit_is 0 wp up bridge
  (( test_failed == 0 )) || return 1
  check "[C125] print prepares the value expansion without revealing its text" exit_is 0 wp exec --print -- "Orchard Grower"
  check "[C125] print retains the value placeholder" grep -qF WORKPLACE_VALUE_WPT_TOKEN "$scratch/out"
  check "[C125] print contains no actual value" bash -c '! grep -qF "$1" "$2"' _ "$payload" "$scratch/out"
  "$BASH" "$loop" exec -- "Orchard Grower" > "$scratch/exec-native.out" 2> "$scratch/exec-native.error" & pid=$!
  result=0; wait "$pid" || result=$?
  check "[C125] the prepared command executes successfully" test "$result" = 0
  mapfile -d '' -t observed < "$root/harbor/berth/exec-values"
  check "[C125] the final program retains the public exec process's PID" test "${observed[0]-}" = "$pid"
  check "[C125] it runs in the declared directory" test "${observed[1]-}" = "$root/harbor/berth"
  check "[C125] its value retains spaces, tabs, quotes and dollar signs" test "${observed[2]-}" = "$payload"
  check "[C125] stop the value-bearing fixture" exit_is 0 wp down bridge
}

t_generation_retention() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"' | .programs[-1].recorded += [{term:["key","harbor","dock","-","room","held"],origin:at(2)}]'
  check "[C126] the retention fixture plans" exit_is 0 wplan
  check "[C126] its whole build succeeds" exit_is 0 wp build
  (( test_failed == 0 )) || return 1
  local s real_connect action pid old middle top bridge_before result
  s=$(state_of) real_connect=$(command -v gpg-connect-agent)
  mkdir -p -- "$clone/BUILD/floors/bridge/99/.work" "$scratch/retention-bin"
  printf '%s\n' bridge-leftover > "$clone/BUILD/floors/bridge/99/.work/data"
  ( umask 077; printf '%s\n' '{"pid":1,"generation":99,"at":"2026-11-18T00:00:00Z"}' > "$clone/BUILD/floors/bridge/BUILDING" )
  bridge_before=$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge")
  printf '%s\n' '#!/usr/bin/env bash' 'for word in "$@"; do' \
    "  if [[ \$word == 'GETINFO pid' && -f '$scratch/retention-gate' ]]; then" \
    "    : > '$scratch/retention-entered'; while [[ -f '$scratch/retention-gate' ]]; do sleep 0.02; done" \
    '    break; fi' 'done' "exec '$real_connect' \"\$@\"" > "$scratch/retention-bin/gpg-connect-agent"
  chmod +x -- "$scratch/retention-bin/gpg-connect-agent"
  for action in up restart; do
    local -a call=(up deck)
    if [[ $action == restart ]]; then
      check "[C126] end the selected program before restart" exit_is 0 on deck T send-keys -t "$(on deck pane_by_title 'Harbor Keeper')" C-c
      check "[C126] its program has ended" eventually_long on deck dead_pane 'Harbor Keeper'
      call=(restart deck 'Harbor Keeper')
    fi
    old=$(top_gen) top=$(sha256sum < "$clone/BUILD/MANIFEST"); top=${top%% *}
    : > "$scratch/retention-gate"
    rm -f -- "$scratch/retention-entered"
    timeout --kill-after=1 30 env PATH="$scratch/retention-bin:$PATH" "$BASH" "$loop" "${call[@]}" > "$scratch/retention-$action.out" 2>&1 & pid=$!
    if ! eventually_long test -e "$scratch/retention-entered"; then
      fail "[C126] $action did not reach its native GnuPG gate"
      rm -f -- "$scratch/retention-gate"
      wait "$pid" 2>/dev/null
      cat "$scratch/retention-$action.out"
      return 1
    fi
    check "[C126] the blocked $action holds the shared generation lock" bash -c '! flock -n -x "$1" true' _ "$s/generations.lock"
    check "[C126] publish once while $action is blocked" exit_is 0 wp build lodge
    middle=$(top_gen)
    check "[C126] publish again while $action is blocked" exit_is 0 wp build lodge
    check "[C126] $action retains the shared generation it began reading" test -d "$clone/BUILD/shared/$old"
    check "[C126] its hold also retains the intervening shared generation" test -d "$clone/BUILD/shared/$middle"
    rm -- "$scratch/retention-gate"
    result=0; wait "$pid" || result=$?
    check "[C126] $action completes from its retained snapshot" test "$result" = 0
    if (( result )); then cat "$scratch/retention-$action.out"; return 1; fi
    check "[C126] $action records exactly its starting top and paths" jq -e --arg sha "$top" --arg shared "shared/$old" \
      '.top==$sha and .generations.shared==$shared and (.generations.floor|startswith("floors/deck/"))' "$run/deck/state.json"
    check "[C126] status names retained shared generations" exit_is 0 wp status deck
    check "[C126] status identifies the old shared directory" said "shared/$old"
    check "[C126] cleanup runs after the reader releases its hold" exit_is 0 wp build lodge
    check "[C126] the old shared generation is now removed" test ! -e "$clone/BUILD/shared/$old"
    check "[C126] the intervening generation is also removed" test ! -e "$clone/BUILD/shared/$middle"
    check "[C126] living server and key-agent children retain no generations lock" flock -n -x "$s/generations.lock" true
    check "[C126] cleanup leaves the other down floor's tree and state unchanged" test "$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge")" = "$bridge_before"
  done
  mkdir -p -- "$clone/BUILD/floors/lodge/900/.work"
  printf '%s\n' abandoned > "$clone/BUILD/floors/lodge/900/.work/data"
  rm -- "$s/generation.next"
  check "[C126] allocation reads an abandoned number before cleanup can remove it" exit_is 0 wp build lodge
  check "[C126] the published generation is above that abandoned number" test "$(top_gen)" -gt 900
  check "[C126] the abandoned generation was cleaned after reservation" test ! -e "$clone/BUILD/floors/lodge/900"
  check "[C126] the other floor's abandoned generation and marker are still untouched" test "$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge")" = "$bridge_before"
  check "[C126] stop the witness and its real key agents" exit_is 0 wp down deck
}


t_generation_phase_reports() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C127] the phase fixture plans" exit_is 0 wplan
  check "[C127] the phase fixture builds" exit_is 0 wp build
  (( test_failed == 0 )) || return 1
  local s current next pid result bridge_before real_mv
  s=$(state_of)
  mkdir -p -- "$clone/BUILD/floors/lodge/777/.work"
  printf '%s\n' abandoned > "$clone/BUILD/floors/lodge/777/.work/data"
  ( umask 077; printf '%s\n' '{"pid":123,"generation":777,"at":"2026-11-18T00:01:00Z"}' > "$clone/BUILD/floors/lodge/BUILDING" )
  check "[C127] bare status refuses an interrupted floor" exit_is 1 wp status
  check "[C127] the interruption is distinguished from a corrupt manifest" said 'stopped before its commit'
  check "[C127] a partial marker is not a manifest mismatch" bash -c '! grep -qF "build: does not match its manifest" "$1"' _ "$scratch/out"
  check "[C127] status of that floor refuses" exit_is 1 wp status lodge
  check "[C127] status names the exact interrupted generation and start" said 'process 123, generation 777'
  check "[C127] status of an unaffected floor succeeds" exit_is 0 wp status deck
  check "[C127] the scoped report hides the other floor interruption" bash -c '! grep -qF "part-built" "$1"' _ "$scratch/out"
  check "[C127] doctor flags the interrupted floor" exit_is 1 wp doctor
  check "[C127] doctor names the recovery operation" said 'partial the floor lodge is part-built'
  check "[C127] up cannot use the interrupted floor" exit_is 1 wp up lodge
  check "[C127] no interrupted run was made" test ! -e "$run/lodge"
  current=$(generation_top_floor lodge); current=${current%/MANIFEST}; current=${current##*/}
  next=$(cat "$s/generation.next")
  ( umask 077; jq -nc --argjson n "$current" '{pid:123,generation:$n,at:"2026-11-18T00:01:00Z"}' > "$clone/BUILD/floors/lodge/BUILDING" )
  check "[C127] status distinguishes a committed marker" exit_is 1 wp status lodge
  check "[C127] its message names the actual committed generation" said "build committed generation $current and stopped before it removed its marker"
  check "[C127] its timestamp is identified as the start" said 'it began at 2026-11-18T00:01:00Z'
  check "[C127] committed-marker recovery succeeds" exit_is 0 wp build lodge
  check "[C127] marker recovery leaves the counter alone" test "$(cat "$s/generation.next")" = "$next"
  check "[C127] a stale successful build holder is not a running build" exit_is 0 wp status lodge
  check "[C127] the old unnamed directory is reported" said "left    $clone/BUILD/floors/lodge/777:"
  check "[C127] a leftover alone does not make doctor bad" exit_is 0 wp doctor
  check "[C127] doctor names that leftover as a note" said "note    $clone/BUILD/floors/lodge/777:"
  mkdir -p -- "$clone/BUILD/floors/bridge/888/.work" "$scratch/phase-bin"
  printf '%s\n' keep > "$clone/BUILD/floors/bridge/888/.work/data"
  ( umask 077; printf '%s\n' '{"pid":321,"generation":888,"at":"2026-11-18T00:02:00Z"}' > "$clone/BUILD/floors/bridge/BUILDING" )
  bridge_before=$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge")
  real_mv=$(command -v mv)
  printf '%s\n' '#!/usr/bin/env bash' "if [[ \${!#} == '$clone/BUILD/floors/lodge/BUILDING' ]]; then" \
    "  : > '$scratch/phase-entered'; while [[ -f '$scratch/phase-gate' ]]; do sleep 0.02; done" \
    'fi' "exec '$real_mv' \"\$@\"" > "$scratch/phase-bin/mv"
  chmod +x -- "$scratch/phase-bin/mv"
  : > "$scratch/phase-gate"
  timeout --kill-after=1 30 env PATH="$scratch/phase-bin:$PATH" "$BASH" "$loop" build lodge > "$scratch/phase-build.out" 2>&1 & pid=$!
  if ! eventually_long test -e "$scratch/phase-entered"; then
    fail "[C127] the builder did not reach its native marker gate"
    rm -f -- "$scratch/phase-gate"; wait "$pid" 2>/dev/null
    cat "$scratch/phase-build.out"; return 1
  fi
  check "[C127] status of the running build succeeds before any marker stands" exit_is 0 wp status lodge
  check "[C127] the lock and holder identify that running build" said 'build: build lodge runs, process '
  check "[C127] its reserved generation is shown" said "toward generation $(jq -r .generation "$s/build.holder")"
  check "[C127] bare status still flags the other interrupted floor" exit_is 1 wp status
  check "[C127] bare status also names the running build" said 'build: build lodge runs, process '
  check "[C127] the other marker remains an interruption" said 'the floor bridge is part-built'
  check "[C127] doctor reports both states and refuses for the interruption" exit_is 1 wp doctor
  check "[C127] doctor identifies the live build as a note" said 'note    build lodge runs'
  check "[C127] the untouched floor remains healthy during both states" exit_is 0 wp status deck
  rm -- "$scratch/phase-gate"
  result=0; wait "$pid" || result=$?
  check "[C127] the real builder resumes and publishes" test "$result" = 0
  check "[C127] the other floor's marker and tree remain untouched" test "$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge")" = "$bridge_before"
  check "[C127] the completed build is no longer reported as running" exit_is 0 wp status lodge
  check "[C127] a free lock overrides a stale build holder" bash -c '! grep -qF "build lodge runs" "$1"' _ "$scratch/out"
}

t_generation_store_report() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox"
  statements_plan "$floors_terms | $comms_terms"
  check "[C127] the store-holder fixture plans" exit_is 0 wplan
  check "[C127] its initial build succeeds" exit_is 0 wp build
  (( test_failed == 0 )) || return 1
  local s real_mv pid result
  s=$(state_of) real_mv=$(command -v mv)
  mkdir -- "$scratch/store-bin"
  printf '%s\n' '#!/usr/bin/env bash' "if [[ \${!#} == '$clone/BUILD/MANIFEST' ]]; then" \
    "  cp -- '$s/store.holder' '$scratch/build-store-holder'; : > '$scratch/store-entered'" \
    "  while [[ -f '$scratch/store-gate' ]]; do sleep 0.02; done" \
    'fi' "exec '$real_mv' \"\$@\"" > "$scratch/store-bin/mv"
  chmod +x -- "$scratch/store-bin/mv"
  : > "$scratch/store-gate"
  timeout --kill-after=1 30 env PATH="$scratch/store-bin:$PATH" "$BASH" "$loop" build lodge > "$scratch/store-build.out" 2>&1 & pid=$!
  if ! eventually_long test -e "$scratch/store-entered"; then
    fail "[C127] the builder did not reach its store-locked top commit"
    rm -f -- "$scratch/store-gate"; wait "$pid" 2>/dev/null
    cat "$scratch/store-build.out"; return 1
  fi
  check "[C127] the actual store lock is held during publication" bash -c '! flock -n "$1" true' _ "$s/mail"
  check "[C127] status succeeds during the store hold" exit_is 0 wp status lodge
  check "[C127] status identifies a build rather than a carrier" said "store   held by build lodge, process $(jq -r .pid "$scratch/build-store-holder"), since "
  rm -- "$scratch/store-gate"
  result=0; wait "$pid" || result=$?
  check "[C127] the store-held publisher completes" test "$result" = 0
  check "[C127] the publisher removes its holder" test ! -e "$s/store.holder"
  ( umask 077; cat "$scratch/build-store-holder" > "$s/store.holder" )
  check "[C127] a stale store holder leaves status successful" exit_is 0 wp status lodge
  check "[C127] status distinguishes a free lock from the stale named process" said 'but nobody holds the lock; the next hold replaces it'
  rm -- "$s/store.holder"
}

generation_interrupt_stubs() {
  local program real
  mkdir -- "$scratch/interrupt-bin"
  for program in mv rm gpg; do
    real=$(command -v "$program")
    printf '%s\n' '#!/usr/bin/env bash' \
      "program='$program'; real='$real'; build='$clone/BUILD'; state='$s'; scratch='$scratch'" \
      'point=${WORKPLACE_TEST_POINT-}; floor=${WORKPLACE_TEST_FLOOR-lodge}; hit=0' \
      'case "$point:$program" in' \
      '  K1:mv) [[ ${!#} == "$build/floors/$floor/BUILDING" ]] && hit=1 ;;' \
      '  K2:gpg|D1:gpg|PAUSE:gpg) for arg in "$@"; do [[ $arg != --quick-gen-key ]] || hit=1; done ;;' \
      '  K3:mv) [[ ${!#} == "$build/MANIFEST" ]] && hit=1 ;;' \
      '  K4:rm) [[ ${!#} == "$build/floors/$floor/BUILDING" ]] && hit=1 ;;' \
      '  K5:rm) [[ ${!#} =~ ^$build/(shared|floors/$floor)/[0-9]+$ ]] && hit=1 ;;' \
      'esac' \
      'if (( hit )); then' \
      '  printf "%s\n" "$point" > "$scratch/interrupt-hit"' \
      '  if [[ $point == D1 ]]; then printf "%s\n" "synthetic key generation failure" >&2; exit 1; fi' \
      '  if [[ $point == PAUSE ]]; then while [[ -f $scratch/interrupt-gate ]]; do sleep 0.02; done' \
      '  else pid=$(jq -r .pid "$state/build.holder")' \
      '    [[ $pid =~ ^[1-9][0-9]*$ ]] || exit 2' \
      '    kill -KILL "$pid"; exit 137' \
      '  fi' \
      'fi' 'exec "$real" "$@"' > "$scratch/interrupt-bin/$program"
    chmod +x -- "$scratch/interrupt-bin/$program"
  done
}

t_generation_interruptions() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["key","lodge","east","-","room","held"];2),
    m(["key","harbor","dock","-","room","held"];3)]'
  check "[C128] the interruption fixture plans" exit_is 0 wplan
  check "[C128] its whole build succeeds with real keys and mail" exit_is 0 wp build
  (( test_failed == 0 )) || return 1
  local s point result bridge_before bridge_line bridge_box deck_before deck_line deck_pid next before hold
  s=$(state_of)
  generation_interrupt_stubs
  rm -f -- "$scratch/interrupt-hit"
  timeout --kill-after=2 45 env PATH="$scratch/interrupt-bin:$PATH" WORKPLACE_TEST_POINT=K3 WORKPLACE_TEST_FLOOR=bridge \
    "$BASH" "$loop" build bridge > "$scratch/bridge-interruption.out" 2>&1
  result=$?
  check "[C128] a real bridge build is killed before its top commit" test "$result" = 137
  check "[C128] that builder reached the named top operation" test "$(cat "$scratch/interrupt-hit")" = K3
  check "[C128] the down bridge really remains part-built" test -f "$clone/BUILD/floors/bridge/BUILDING"
  (( test_failed == 0 )) || { cat "$scratch/bridge-interruption.out"; return 1; }
  bridge_box=$s/comms/Orchard\ Grower
  check "[C128] the down floor's answers directory existed" test -d "$bridge_box/answers"
  rmdir -- "$bridge_box/answers"
  bridge_before=$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge" "$s/mail/Orchard Grower" "$bridge_box")
  bridge_line=$(generation_top_floor bridge)
  check "[C128] the witness deck starts while bridge is interrupted" exit_is 0 wp up deck
  (( test_failed == 0 )) || return 1
  deck_line=$(generation_top_floor deck) deck_pid=$(on deck T display-message -p '#{pid}')
  deck_before=$(generation_tree_digest "$clone/BUILD/floors/deck" "$s/floors/deck/keys/01/private-keys-v1.d")
  for point in K1 K2 K3 K4 K5 D1; do
    rm -f -- "$scratch/interrupt-hit"
    if [[ $point == K1 ]]; then
      exec {hold}< "$s/generations.lock"
      flock -s "$hold" || return 1
    fi
    timeout --kill-after=2 45 env PATH="$scratch/interrupt-bin:$PATH" WORKPLACE_TEST_POINT="$point" WORKPLACE_TEST_FLOOR=lodge \
      "$BASH" "$loop" build lodge > "$scratch/interruption-$point.out" 2>&1
    result=$?
    [[ $point != K1 ]] || exec {hold}<&-
    if [[ $point == D1 ]]; then check "[C128] D1 is a native key-generation refusal" test "$result" = 2
    else check "[C128] $point kills the actual publishing builder" test "$result" = 137; fi
    check "[C128] $point reached its named operation" test "$(cat "$scratch/interrupt-hit" 2>/dev/null)" = "$point"
    check "[C128] $point keeps the witness floor healthy" exit_is 0 wp status deck
    check "[C128] $point preserves the witness top entry" test "$(generation_top_floor deck)" = "$deck_line"
    check "[C128] $point preserves its immutable tree and private-key files" test "$(generation_tree_digest "$clone/BUILD/floors/deck" "$s/floors/deck/keys/01/private-keys-v1.d")" = "$deck_before"
    check "[C128] $point preserves the witness server process" test "$(on deck T display-message -p '#{pid}')" = "$deck_pid"
    check "[C128] $point preserves the other interrupted floor and its mailboxes" test "$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge" "$s/mail/Orchard Grower" "$bridge_box")" = "$bridge_before"
    check "[C128] $point does not change bridge's published entry" test "$(generation_top_floor bridge)" = "$bridge_line"
    check "[C128] $point does not recreate the other floor's removed answers" test ! -e "$bridge_box/answers"
    if [[ $point == K2 || $point == K3 || $point == K4 || $point == D1 ]]; then
      check "[C128] $point refuses up of its interrupted floor" exit_is 1 wp up lodge
      check "[C128] $point explains that the marker stands" said 'BUILDING marker stands'
      check "[C128] $point leaves no partial run" test ! -e "$run/lodge"
    fi
    if [[ $point == K4 ]]; then before=$(generation_tree_digest "$s/floors/lodge/keys/01/private-keys-v1.d"); next=$(cat "$s/generation.next"); fi
    check "[C128] recovery after $point succeeds" exit_is 0 wp build lodge
    if (( test_failed )); then cat "$scratch/interruption-$point.out"; return 1; fi
    if [[ $point == K4 ]]; then
      check "[C128] committed-marker recovery keeps private-key bytes, inodes and modes" test "$(generation_tree_digest "$s/floors/lodge/keys/01/private-keys-v1.d")" = "$before"
      check "[C128] committed-marker recovery allocates no generation" test "$(cat "$s/generation.next")" = "$next"
    fi
    check "[C128] recovery after $point still leaves bridge byte for byte" test "$(generation_tree_digest "$clone/BUILD/floors/bridge" "$s/floors/bridge" "$s/mail/Orchard Grower" "$bridge_box")" = "$bridge_before"
    check "[C128] recovery after $point makes lodge usable" exit_is 0 wp up lodge
    check "[C128] end lodge after $point" exit_is 0 wp down lodge
  done
  check "[C128] end the unchanged witness" exit_is 0 wp down deck
}

t_generation_pause_isolation() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"' | .programs[-1].recorded += [{term:["key","lodge","east","-","room","held"],origin:at(2)}]'
  check "[C128] the pause fixture plans" exit_is 0 wplan
  check "[C128] its whole build succeeds" exit_is 0 wp build
  check "[C128] start the witness before pausing another build" exit_is 0 wp up deck
  (( test_failed == 0 )) || return 1
  local s pid result
  s=$(state_of)
  generation_interrupt_stubs
  : > "$scratch/interrupt-gate"
  timeout --kill-after=2 60 env PATH="$scratch/interrupt-bin:$PATH" WORKPLACE_TEST_POINT=PAUSE \
    "$BASH" "$loop" build lodge > "$scratch/interruption-pause.out" 2>&1 & pid=$!
  if ! eventually_long test -e "$scratch/interrupt-hit"; then
    fail "[C128] the builder did not reach its native key-generation pause"
    rm -f -- "$scratch/interrupt-gate"; wait "$pid" 2>/dev/null
    cat "$scratch/interruption-pause.out"; return 1
  fi
  check "[C128] the other floor's status does not wait for the paused build" exit_is 0 wp status deck
  check "[C128] end a witness program for restart" exit_is 0 on deck T send-keys -t "$(on deck pane_by_title 'Harbor Keeper')" C-c
  check "[C128] the program really ended" eventually_long on deck dead_pane 'Harbor Keeper'
  check "[C128] restarting another floor does not wait for the paused build" exit_is 0 wp restart deck 'Harbor Keeper'
  check "[C128] down of another floor does not wait" exit_is 0 wp down deck
  check "[C128] up of another floor does not wait" exit_is 0 wp up deck
  rm -- "$scratch/interrupt-gate"
  result=0; wait "$pid" || result=$?
  check "[C128] the key generation resumes and publishes" test "$result" = 0
  check "[C128] end the restarted witness" exit_is 0 wp down deck
}
