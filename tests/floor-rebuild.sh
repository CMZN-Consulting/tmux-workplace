t_generation_counter_leftovers() {
  mkdir -p -- "$scratch/counter-build/shared/7" "$scratch/counter-build/floors/deck/11"
  cat > "$scratch/counter-driver" <<'BASH'
source <(sed -n '/^build_state_begin() {$/,/^}$/p' "$1")
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
