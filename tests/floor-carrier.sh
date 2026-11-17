t_carrier_git_deadlines() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$scratch/git-wrapper" "$scratch/git-hooks"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["reach", "harbor", "-", "-", "office", "mail", "lodge", "-", "-", "floor", "allowed"]; 2),
    m(["reach", "lodge", "-", "-", "floor", "mail", "harbor", "-", "-", "office", "allowed"]; 3)]'
  check "[C107] two floors with a shared mail store plan" exit_is 0 wplan
  check "[C107] build the throwaway workplace" exit_is 0 wp build
  local real_git s pid blocked_id mode
  real_git=$(command -v git)
  s=$(state_of)
  printf '%s\n' '#!/usr/bin/env bash' \
    "args=(); for a in \"\$@\"; do if [[ \$a == commit && -f '$scratch/git-gate' ]]; then args+=(-c 'core.hooksPath=$scratch/git-hooks'); fi; args+=(\"\$a\"); done" \
    "exec '$real_git' \"\${args[@]}\"" > "$scratch/git-wrapper/git"
  printf '%s\n' '#!/usr/bin/env bash' \
    "[[ -f '$scratch/git-gate' && \$1 == \$(cat '$scratch/git-gate') ]] || exit 0" \
    "printf '%s\\n' \"\$\$\" > '$scratch/git-entered'" \
    "while [[ -f '$scratch/git-gate' ]]; do sleep 0.1; done" > "$scratch/git-hooks/reference-transaction"
  chmod +x -- "$scratch/git-wrapper/git" "$scratch/git-hooks/reference-transaction"
  check "[C107] up the source floor with the real-Git hook wrapper" exit_is 0 env PATH="$scratch/git-wrapper:$PATH" "$BASH" "$loop" up deck
  check "[C107] up the other floor" exit_is 0 wp up lodge
  request keeper seed.md "to: Lodge Ida" "subject: seed" --- body
  check "[C107] seed a real commit before the kill" answered_ok keeper seed.md
  printf '%s\n' preserve > "$s/mail/Lodge Ida/in/stray.md"
  for mode in prepared committed; do
    rm -f -- "$scratch/git-entered"
    printf '%s\n' "$mode" > "$scratch/git-gate"
    request keeper "$mode.md" "to: Lodge Ida" "subject: $mode" --- body
    check "[C107] $mode: the real reference transaction reaches the hook" eventually_long test -s "$scratch/git-entered"
    blocked_id=$(jq -r .id "$s/floors/deck/comms/serving")
    if [[ $mode == prepared ]]; then
      check "[C107] prepared: Git really holds its branch ref lock" test -f "$s/mail/.git/refs/heads/mail.lock"
      check "[C107] prepared: Git really holds its index lock" test -f "$s/mail/.git/index.lock"
      pid=$(carrier_pid deck)
      check "[C107] prepared: kill only the source carrier" kill -KILL "$pid"
      check "[C107] prepared: the orphan Git still holds the store lock" bash -c '! flock -n "$1" true' _ "$s/mail"
    fi
    request ida "$mode.md" "to: Harbor Keeper" "subject: other floor" --- body
    check "[C107] $mode: the other floor delivers after the bounded child ends" answered_ok ida "$mode.md"
    check "[C107] $mode: both stale index and ref locks are gone" bash -c '[[ ! -e $1/.git/index.lock && ! -e $1/.git/refs/heads/mail.lock ]]' _ "$s/mail"
    rm -f -- "$scratch/git-gate"
    if [[ $mode == prepared ]]; then
      check "[C107] prepared: restart the source floor for recovery" exit_is 0 env PATH="$scratch/git-wrapper:$PATH" "$BASH" "$loop" restart deck
      check "[C107] prepared: the uncommitted delivery is refused after recovery" answered keeper "$mode.md" "refused the carrier stopped while it served this, and it went to none; leave it in out again"
      check "[C107] prepared: uncommitted recipient and sent copies are removed" bash -c '[[ ! -e $1/mail/"Lodge Ida"/in/$2.md && ! -e $1/mail/"Harbor Keeper"/sent/$2.md ]]' _ "$s" "$blocked_id"
    else
      check "[C107] committed: a commit followed by timeout is still answered ok" answered_ok keeper "$mode.md"
      check "[C107] committed: committed recipient and sent copies survive" bash -c '[[ -f $1/mail/"Lodge Ida"/in/$2.md && -f $1/mail/"Harbor Keeper"/sent/$2.md ]]' _ "$s" "$blocked_id"
    fi
    check "[C107] $mode: unrelated untracked mail remains" test -f "$s/mail/Lodge Ida/in/stray.md"
  done
  check "[C107] stop the source floor" exit_is 0 wp down deck
  check "[C107] stop the other floor" exit_is 0 wp down lodge
}
