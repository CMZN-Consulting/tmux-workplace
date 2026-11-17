carrier_test_answer() {
  local file="$(state_of)/comms/$(box_of "$1")/answers/$2" wanted=$3 seconds=${4:-15} end=$(( EPOCHSECONDS + ${4:-15} )) first
  while (( EPOCHSECONDS < end )); do
    if [[ -s $file ]]; then
      IFS= read -r first < "$file"
      if [[ $wanted == ok ]]; then [[ $first =~ ^ok\ [0-9]{8}T[0-9]{6}Z-[0-9]{6}$ ]]; else [[ $first == "$wanted" ]]; fi
      return
    fi
    sleep 0.05
  done
  return 1
}

t_carrier_git_deadlines() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$scratch/git-wrapper" "$scratch/git-hooks"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["reach", "harbor", "-", "-", "office", "mail", "lodge", "-", "-", "floor", "allowed"]; 2),
    m(["reach", "lodge", "-", "-", "floor", "mail", "harbor", "-", "-", "office", "allowed"]; 3)]'
  check "[C107] two floors with a shared mail store plan" exit_is 0 wplan
  check "[C107] build the throwaway workplace" exit_is 0 wp build
  local real_git s pid blocked_id mode start
  real_git=$(command -v git)
  s=$(state_of)
  mkfifo -- "$scratch/git-index-input"
  printf '%s\n' '#!/usr/bin/env bash' \
    "for a in \"\$@\"; do if [[ \$a == add && -f '$scratch/git-gate' && \$(cat '$scratch/git-gate') == index ]]; then printf '%s\\n' \"\$\$\" > '$scratch/git-entered'; exec 5<> '$scratch/git-index-input'; exec '$real_git' update-index --index-info < '$scratch/git-index-input'; fi; done" \
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
  for mode in index prepared committed; do
    rm -f -- "$scratch/git-entered"
    printf '%s\n' "$mode" > "$scratch/git-gate"
    request keeper "$mode.md" "to: Lodge Ida" "subject: $mode" --- body
    check "[C107] $mode: the real reference transaction reaches the hook" eventually_long test -s "$scratch/git-entered"
    blocked_id=$(jq -r .id "$s/floors/deck/comms/serving")
    if [[ $mode != committed ]]; then
      if [[ $mode == prepared ]]; then
        check "[C107] prepared: Git really holds its branch ref lock" test -f "$s/mail/.git/refs/heads/mail.lock"
      else
        check "[C107] index: the real Git index writer holds its lock" eventually_long test -f "$s/mail/.git/index.lock"
      fi
      pid=$(carrier_pid deck)
      check "[C107] prepared: kill only the source carrier" kill -KILL "$pid"
      check "[C107] prepared: the orphan Git still holds the store lock" bash -c '! flock -n "$1" true' _ "$s/mail"
    fi
    start=${EPOCHREALTIME/./}
    request ida "$mode.md" "to: Harbor Keeper" "subject: other floor" --- body
    if carrier_test_answer ida "$mode.md" ok 8; then
      check "[C107] $mode: the other floor delivers within eight seconds of the blocked transaction" test "$(( ${EPOCHREALTIME/./} - start ))" -lt 8000000
    else
      fail "[C107] $mode: the other floor did not deliver within eight seconds"
      return 1
    fi
    check "[C107] $mode: both stale index and ref locks are gone" bash -c '[[ ! -e $1/.git/index.lock && ! -e $1/.git/refs/heads/mail.lock ]]' _ "$s/mail"
    rm -f -- "$scratch/git-gate"
    if [[ $mode != committed ]]; then
      check "[C107] $mode: stop the dead source floor" exit_is 0 wp down deck
      check "[C107] $mode: start a fresh source carrier for recovery" exit_is 0 env PATH="$scratch/git-wrapper:$PATH" "$BASH" "$loop" up deck
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

t_carrier_request_recovery() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$scratch/mv-wrapper"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["reach", "harbor", "-", "-", "office", "mail", "lodge", "-", "-", "floor", "allowed"]; 2),
    m(["reach", "lodge", "-", "-", "floor", "mail", "harbor", "-", "-", "office", "allowed"]; 3)]'
  check "[C108] journal recovery fixture plans" exit_is 0 wplan
  check "[C108] fixture builds" exit_is 0 wp build
  local s c record real_mv pid id original line rec unknown_id=20261118T000000Z-900001
  s=$(state_of) c=$s/floors/deck/comms record=$c/record
  check "[C108] each floor has a private request record; there is no shared writer" bash -c '[[ -f $1/floors/deck/comms/record && -f $1/floors/lodge/comms/record && ! -e $1/comms/record ]] && [[ $(stat -c %a "$1/floors/deck/comms/record") == 600 ]]' _ "$s"
  real_mv=$(command -v mv)
  printf '%s\n' '#!/usr/bin/env bash' \
    'dest=${!#}' \
    "if [[ -f '$scratch/rename-stop' && \$dest == '$c/taken/'* ]]; then" \
    "  '$real_mv' \"\$@\" || exit" \
    "  printf '%s\\n' \"\$PPID\" > '$scratch/rename-entered'" \
    '  kill -STOP "$PPID"; exit 0' \
    'fi' \
    "exec '$real_mv' \"\$@\"" > "$scratch/mv-wrapper/mv"
  chmod +x -- "$scratch/mv-wrapper/mv"
  check "[C108] start the source carrier with only the rename gate" exit_is 0 env PATH="$scratch/mv-wrapper:$PATH" "$BASH" "$loop" up deck
  check "[C108] start the other floor" exit_is 0 wp up lodge
  : > "$scratch/rename-stop"
  request keeper lost.md "to: Lodge Ida" "subject: never lost" --- body
  check "[C108] the actual take rename completes at the gate" eventually_long test -s "$scratch/rename-entered"
  pid=$(cat "$scratch/rename-entered")
  check "[C108] the source carrier is stopped between rename and next instruction" eventually_long grep -q '^State:.*T' "/proc/$pid/status"
  original=$(jq -r .id "$c/serving")
  check "[C108] a named journal already identifies the taken request" bash -c '[[ -f $1/taken/$2 && $(jq -r .stage "$1/serving") == named && $(jq -r .request "$1/serving") == lost.md ]]' _ "$c" "$original"
  check "[C108] kill the stopped source carrier" kill -KILL "$pid"
  rm -f -- "$scratch/rename-stop"
  check "[C108] close only its dead run" exit_is 0 wp down deck
  check "[C108] a fresh source carrier recovers the request" exit_is 0 wp up deck
  if carrier_test_answer keeper lost.md ok; then
    check "[C108] the original request is delivered after recovery" true
  else
    fail "[C108] the original request was lost across the take rename"
    return 1
  fi
  id=$(answer_of keeper lost.md); id=${id#ok }
  check "[C108] recovered request has exactly one delivery commit" test "$(store_commits)" = 1
  check "[C108] the unserved take was returned without a fabricated refusal" bash -c '[[ $(jq -s --arg r lost.md "[.[] | select(.request == \$r)] | length" "$1") == 1 ]] && ! grep -qF "\"id\":\"$2\"" "$1"' _ "$record" "$original"
  request ida other.md "to: Harbor Keeper" "subject: other writer" --- body
  check "[C108] the second floor also delivers" answered_ok ida other.md
  check "[C108] floor records contain only their own request writers" eventually_long bash -c 'jq -s -e "all(.[] | select(.seat != \"the frame\"); .seat != \"Lodge Ida\")" "$1/floors/deck/comms/record" >/dev/null && jq -s -e "any(.[]; .seat == \"Lodge Ida\" and .request == \"other.md\")" "$1/floors/lodge/comms/record" >/dev/null' _ "$s"
  check "[C108] stop the source for planted later windows" exit_is 0 wp down deck
  line=$(jq -c --arg id "$id" 'select(.id == $id and .action == "mail")' "$record")
  jq -nc --arg id "$id" --argjson record "$line" '{id:$id,box:"Harbor Keeper",seat:"Harbor Keeper",request:"lost.md",action:"mail",stage:"recorded",rec:0,record:$record,answer:("ok " + $id + "\n")}' > "$c/serving"
  rm -f -- "$s/comms/Harbor Keeper/answers/lost.md"
  check "[C108] recover after the record but before journal removal" exit_is 0 wp up deck
  check "[C108] the saved answer is restored" answered_ok keeper lost.md
  check "[C108] dedupe appends no second request line" test "$(jq -s --arg id "$id" '[.[] | select(.id == $id and .request == "lost.md")] | length' "$record")" = 1
  check "[C108] stop for an interrupted action" exit_is 0 wp down deck
  rec=$(stat -c %s -- "$record")
  jq -nc --arg id "$unknown_id" --argjson rec "$rec" '{id:$id,box:"Harbor Keeper",seat:"Harbor Keeper",request:"uncertain.write",action:"write",stage:"acting",rec:$rec,target:["Lodge Ida"],written:"3 abc"}' > "$c/serving"
  check "[C108] recover with no further request waiting" exit_is 0 wp up deck
  check "[C108] interrupted write is answered without pretending success" answered keeper uncertain.write "refused the carrier stopped while it served this, and whether it acted is not known"
  check "[C108] its unknown line retains the original target and charged text" eventually_long bash -c 'jq -e "select(.request == \"uncertain.write\" and .outcome == \"unknown\" and .target == [\"Lodge Ida\"] and .length == 3 and .sha256 == \"abc\")" "$1" >/dev/null' _ "$record"
  check "[C108] stop for an invalid recorded base" exit_is 0 wp down deck
  rec=$(stat -c %s -- "$record")
  jq -nc --argjson rec "$rec" '{id:"invalid-base",box:"Harbor Keeper",seat:"Harbor Keeper",request:"uncertain.md",action:"mail",stage:"delivering",rec:$rec,base:"ffffffffffffffffffffffffffffffffffffffff"}' > "$c/serving"
  printf '%s\n' preserve > "$s/mail/Lodge Ida/in/invalid-base.md"
  check "[C108] invalid base is handled by bounded recovery retries" exit_is 0 wp up deck
  check "[C108] no delivery verdict is invented for an unreadable commit range" answered keeper uncertain.md "refused the carrier could not tell whether this was delivered; look in the store for deliver invalid-base before you send it again"
  check "[C108] uncertain recipient data is retained for inspection" test -f "$s/mail/Lodge Ida/in/invalid-base.md"
  request keeper after.md "to: Lodge Ida" "subject: after recovery" --- body
  check "[C108] failed lookup recovery does not block later mail" answered_ok keeper after.md
  check "[C108] stop source" exit_is 0 wp down deck
  check "[C108] stop other floor" exit_is 0 wp down lodge
}
