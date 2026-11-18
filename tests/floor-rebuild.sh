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
  statements_plan "$floors_terms"' | (.programs[] | select(.path=="harbor/dock/keeper/seat.typify") | .plan[1].term[5])=(["/usr/bin/true"]|tojson)'
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
