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
  if env LC_ALL=C.UTF-8 "$BASH" -c : >/dev/null 2>&1; then selected_locale=C.UTF-8; fi
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
