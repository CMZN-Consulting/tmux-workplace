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

carrier_test_floor_text() {
  local pane
  while IFS= read -r pane; do T capture-pane -p -t "$pane"; done < <(T list-panes -a -F '#{pane_id}')
}

t_floor_capture_interruption() {
  mkdir -m 0700 -- "$scratch/capture-files"
  check "[C105] capture preserves stdout, trailing lines and a nonzero command status" bash -c '
    source "$1"
    export TMPDIR=$2
    floor_capture bash -c '\''printf "first\nlast\n\n"; exit 7'\'' > "$3"
    result=$?
    printf "first\nlast\n\n" > "$4"
    [[ $result == 7 ]] && cmp -s -- "$3" "$4"
  ' _ "$tool/libexec/floor-runtime.bash" "$scratch/capture-files" "$scratch/capture-normal" "$scratch/capture-expected"
  check "[C105] ordinary capture leaves no named file" bash -c 'a=("$1"/*); [[ ! -e ${a[0]} ]]' _ "$scratch/capture-files"
  printf '%s\n' '#!/usr/bin/env bash' \
    'source "$1"; export TMPDIR=$2; floor_capture "$BASH" "$3" "$4"' > "$scratch/capture-parent"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf captured; printf "%s\n" "$PPID" > "$1"; kill -STOP "$PPID"' > "$scratch/capture-child"
  "$BASH" "$scratch/capture-parent" "$tool/libexec/floor-runtime.bash" "$scratch/capture-files" "$scratch/capture-child" "$scratch/capture-ready" > "$scratch/capture-output" &
  local pid=$! ready
  check "[C105] capture interruption: the command entered its capture" eventually_long test -s "$scratch/capture-ready"
  ready=$(cat "$scratch/capture-ready")
  check "[C105] capture interruption: the correct capture process is stopped" test "$ready" = "$pid"
  check "[C105] capture interruption: it is actually stopped" eventually_long grep -q '^State:.*T' "/proc/$pid/status"
  check "[C105] capture interruption: captured bytes have no filesystem name while the command runs" bash -c 'a=("$1"/*); [[ ! -e ${a[0]} ]]' _ "$scratch/capture-files"
  check "[C105] capture interruption: kill the stopped capture process" kill -KILL "$pid"
  wait "$pid" 2>/dev/null
  check "[C105] capture interruption: no readable capture file survives the kill" bash -c 'a=("$1"/*); [[ ! -e ${a[0]} ]]' _ "$scratch/capture-files"
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
  local real_git s pid blocked_id mode start worker hook_pid
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
      worker=$(cat "$scratch/git-entered")
      if [[ $mode == prepared ]]; then
        hook_pid=$worker
        worker=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$hook_pid/status")
        check "[C107] prepared: kill the actual Git writer and its test hook" kill -KILL "$worker" "$hook_pid"
        check "[C107] prepared: SIGKILL really leaves a stale ref lock" test -f "$s/mail/.git/refs/heads/mail.lock"
      else
        check "[C107] index: kill the actual index writer" kill -KILL "$worker"
        check "[C107] index: SIGKILL really leaves a stale index lock" test -f "$s/mail/.git/index.lock"
      fi
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
  ( umask 022; request keeper lost.md "to: Lodge Ida" "subject: never lost" --- body )
  check "[C108] the actual take rename completes at the gate" eventually_long test -s "$scratch/rename-entered"
  pid=$(cat "$scratch/rename-entered")
  check "[C108] the source carrier is stopped between rename and next instruction" eventually_long grep -q '^State:.*T' "/proc/$pid/status"
  original=$(jq -r .id "$c/serving")
  check "[C108] a named journal already identifies the taken request" bash -c '[[ -f $1/taken/$2 && $(jq -r .stage "$1/serving") == named && $(jq -r .request "$1/serving") == lost.md ]]' _ "$c" "$original"
  check "[C130] the taken request retains its incoming mode for recovery" test "$(stat -c %a -- "$c/taken/$original")" = 644
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
  ( umask 077; jq -nc --arg id "$id" --argjson record "$line" '{id:$id,box:"Harbor Keeper",seat:"Harbor Keeper",request:"lost.md",action:"mail",stage:"recorded",rec:0,record:$record,answer:("ok " + $id + "\n")}' > "$c/serving" )
  rm -f -- "$s/comms/Harbor Keeper/answers/lost.md"
  check "[C108] recover after the record but before journal removal" exit_is 0 wp up deck
  check "[C108] the saved answer is restored" answered_ok keeper lost.md
  check "[C108] dedupe appends no second request line" test "$(jq -s --arg id "$id" '[.[] | select(.id == $id and .request == "lost.md")] | length' "$record")" = 1
  check "[C108] stop for an interrupted action" exit_is 0 wp down deck
  rec=$(stat -c %s -- "$record")
  ( umask 077; jq -nc --arg id "$unknown_id" --argjson rec "$rec" '{id:$id,box:"Harbor Keeper",seat:"Harbor Keeper",request:"uncertain.write",action:"write",stage:"acting",rec:$rec,target:["Lodge Ida"],written:"3 abc"}' > "$c/serving" )
  check "[C108] recover with no further request waiting" exit_is 0 wp up deck
  check "[C108] interrupted write is answered without pretending success" answered keeper uncertain.write "refused the carrier stopped while it served this, and whether it acted is not known"
  check "[C108] its unknown line retains the original target and charged text" eventually_long bash -c 'jq -e "select(.request == \"uncertain.write\" and .outcome == \"unknown\" and .target == [\"Lodge Ida\"] and .length == 3 and .sha256 == \"abc\")" "$1" >/dev/null' _ "$record"
  check "[C108] stop for an invalid recorded base" exit_is 0 wp down deck
  rec=$(stat -c %s -- "$record")
  ( umask 077; jq -nc --argjson rec "$rec" '{id:"invalid-base",box:"Harbor Keeper",seat:"Harbor Keeper",request:"uncertain.md",action:"mail",stage:"delivering",rec:$rec,base:"ffffffffffffffffffffffffffffffffffffffff"}' > "$c/serving" )
  printf '%s\n' preserve > "$s/mail/Lodge Ida/in/invalid-base.md"
  check "[C108] invalid base is handled by bounded recovery retries" exit_is 0 wp up deck
  check "[C108] no delivery verdict is invented for an unreadable commit range" answered keeper uncertain.md "refused the carrier could not tell whether this was delivered; look in the store for deliver invalid-base before resubmitting this request"
  check "[C108] uncertain recipient data is retained for inspection" test -f "$s/mail/Lodge Ida/in/invalid-base.md"
  request keeper after.md "to: Lodge Ida" "subject: after recovery" --- body
  check "[C108] failed lookup recovery does not block later mail" answered_ok keeper after.md
  check "[C108] stop source" exit_is 0 wp down deck
  check "[C108] stop other floor" exit_is 0 wp down lodge
}

t_carrier_pointer_recovery() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$root/screens" "$scratch/tmux-wrapper"
  printf '%s\n' busy > "$root/screens/screen"
  statements_plan "$floors_terms | $comms_terms"' | kinds([
    ["harbor","dock","keeper","clerk"],["harbor","dock","pilot","clerk"],["harbor","tower","watch","clerk"],
    ["orchard","barn","grower","clerk"],["orchard","barn","picker","clerk"],["lodge","east","ida","clerk"]])
    | .programs[-1].recorded += [m(["reach","harbor","-","-","office","mail","lodge","-","-","floor","allowed"];2),
      m(["wake","clerk","^waiting>$"];3), st("lodge";"east";"-";"room";$root+"/screens";"read-write";20)]
    | (.programs[] | select(.path == "lodge/east/ida/seat.typify") | .plan[1].term[5]) |=
      (fromjson + ["screen="+$root+"/screens/screen","typed="+$root+"/screens/typed"] | tojson)'
  check "[C109] pointer recovery fixture plans" exit_is 0 wplan
  check "[C109] fixture builds" exit_is 0 wp build
  local s c record real_tmux pid id other start holder rec
  s=$(state_of) c=$s/floors/lodge/comms record=$c/record
  real_tmux=$(command -v tmux)
  printf '%s\n' '#!/usr/bin/env bash' \
    'typing=0; for a in "$@"; do [[ $a == send-keys ]] && typing=1; done' \
    "if (( typing )) && [[ -f '$scratch/pointer-stop' ]]; then" \
    "  '$real_tmux' \"\$@\" || exit" \
    "  printf '%s\\n' stopped > '$scratch/pointer-entered'" \
    "  kill -STOP \"\$(cat '$scratch/pointer-pid')\"; exit 0" \
    'fi' \
    "exec '$real_tmux' \"\$@\"" > "$scratch/tmux-wrapper/tmux"
  chmod +x -- "$scratch/tmux-wrapper/tmux"
  check "[C109] start source floor" exit_is 0 wp up deck
  check "[C109] start destination with the typing-only gate" exit_is 0 env PATH="$scratch/tmux-wrapper:$PATH" "$BASH" "$loop" up lodge
  pid=$(carrier_pid lodge); printf '%s\n' "$pid" > "$scratch/pointer-pid"
  request keeper one.md "to: Lodge Ida" "subject: one" --- body
  check "[C109] first mail delivers while the reader is busy" answered_ok keeper one.md
  id=$(answer_of keeper one.md); id=${id#ok }
  : > "$scratch/pointer-stop"
  printf '%s\n' ready > "$root/screens/screen"
  check "[C109] actual tmux typing reaches the gate" eventually_long test -s "$scratch/pointer-entered"
  check "[C109] carrier stopped after typing, before recording the outcome" eventually_long grep -q '^State:.*T' "/proc/$pid/status"
  if jq -e --arg id "$id" '.ids==[$id] and (.length>0) and (.sha256|length)==64 and (has("outcome")|not)' "$c/.pointing/Lodge Ida" > /dev/null 2>&1; then
    check "[C109] pointer evidence was journalled before the effect" true
  else
    fail "[C109] pointer evidence was missing before the effect"
    kill -KILL "$pid" 2>/dev/null
    return 1
  fi
  check "[C109] kill only the stopped carrier" kill -KILL "$pid"
  rm -f -- "$scratch/pointer-stop"
  printf '%s\n' busy > "$root/screens/screen"
  check "[C109] close the dead reader run" exit_is 0 wp down lodge
  check "[C109] restart a fresh reader carrier" exit_is 0 wp up lodge
  check "[C109] recovery records uncertainty without any new request" eventually_long bash -c 'jq -e --arg id "$2" "select(.action==\"wake\" and .covers==[\$id] and .outcome==\"unknown\" and .length>0)" "$1" >/dev/null' _ "$record" "$id"
  check "[C109] uncertain pointer IDs remain due with a retry timestamp" eventually_long bash -c 'jq -e --arg id "$2" ".seats[\"Lodge Ida\"] | .ids==[\$id] and .last>0" "$1" >/dev/null' _ "$s/comms/wake.json" "$id"
  request keeper two.md "to: Lodge Ida" "subject: two" --- body
  check "[C109] later mail delivers independently" answered_ok keeper two.md
  other=$(answer_of keeper two.md); other=${other#ok }
  check "[C109] stop the reader for the successful-record window" exit_is 0 wp down lodge
  rec=$(stat -c %s -- "$record") start=$EPOCHSECONDS
  ( umask 077; jq -nc --arg id "$id" --argjson rec "$rec" --argjson start "$start" '{box:"Lodge Ida",target:"Lodge Ida",ids:[$id],start:$start,rec:$rec,length:3,sha256:"abc",outcome:"ok",reason:""}' > "$c/.pointing/Lodge Ida" )
  flock -o "$s/mail" sleep 60 & holder=$!
  check "[C109] hold the shared store while the local pointer record is recovered" eventually bash -c '! flock -n "$1" true' _ "$s/mail"
  check "[C109] reader starts despite the store holder" exit_is 0 wp up lodge
  check "[C109] successful outcome is recorded even before settlement can take the lock" eventually_long bash -c 'jq -e --arg id "$2" "select(.action==\"wake\" and .covers==[\$id] and .outcome==\"ok\")" "$1" >/dev/null' _ "$record" "$id"
  wp status lodge > "$scratch/pointer-status" 2>&1
  check "[C109] status excludes already-pointed IDs while settlement waits" grep -qF 'Lodge Ida (lodge/east/ida): 1 delivered and not yet pointed out' "$scratch/pointer-status"
  pkill -P "$holder" sleep 2> /dev/null; wait "$holder" 2> /dev/null
  check "[C109] settle removes only the pointed ID and preserves later delivery" eventually_long bash -c '[[ $(jq -c ".seats[\"Lodge Ida\"] | [.ids,.count]" "$1") == "[[\"$2\"],1]" ]] && [[ ! -e $3 ]]' _ "$s/comms/wake.json" "$other" "$c/.pointing/Lodge Ida"
  check "[C109] stop reader" exit_is 0 wp down lodge
  check "[C109] stop source" exit_is 0 wp down deck
}

t_carrier_cross_floor() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$root/records"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["reach","orchard","-","-","office","grab","harbor","-","-","office","allowed"];2),
    m(["reach","orchard","-","-","office","write","harbor","-","-","office","allowed"];3),
    m(["reach","orchard","barn","picker","seat","write","harbor","-","-","office","banned"];4),
    m(["reach","orchard","-","-","office","mail","harbor","-","-","office","allowed"];5),
    m(["reach","harbor","-","-","office","mail","orchard","-","-","office","allowed"];6),
    m(["record","-","-","-","workplace","pane","kept"];7),
    m(["record-path","records"];8),m(["record-chain","file"];9),
    st("harbor";"tower";"-";"room";$root+"/harbor/charts";"read-write";10)]
    | (.programs[] | select(.path=="harbor/tower/watch/seat.typify") | .plan[1].term[5]) |=
      (fromjson + ["typed="+$root+"/harbor/charts/cross-typed"] | tojson)'
  check "[C110] Administration-to-enforced-floor fixture plans" exit_is 0 wplan
  check "[C110] fixture builds" exit_is 0 wp build
  check "[C110] Administration starts on its private test default socket" exit_is 0 wp up bridge
  check "[C110] destination starts on its own socket" exit_is 0 wp up deck
  local s pane holder pid before
  s=$(state_of)
  pane=$(on deck pane_by_title "Harbor Watch")
  check "[C110] destination program is running" eventually_long on deck screen_has "Harbor Watch" "probe watch done"
  request grower cross.grab "seat: Harbor Watch"
  if carrier_test_answer grower cross.grab ok; then
    check "[C110] authorized grab is answered by the destination floor" true
  else
    fail "[C110] authorized grab did not reach the destination floor"
    return 1
  fi
  check "[C110] capture comes from the actual target, despite reused pane IDs" grep -qF 'probe watch done' "$s/comms/Orchard Grower/answers/cross.grab"
  request grower cross.write "seat: Harbor Watch" --- "cross-floor-sentinel"
  check "[C110] authorized write crosses floors" answered_ok grower cross.write
  check "[C110] only the intended destination receives the literal line" eventually_long grep -qxF 'cross-floor-sentinel' "$root/harbor/charts/cross-typed"
  check "[C110] the source floor receives no mistaken typing" bash -c '! grep -qF cross-floor-sentinel "$1"' _ <(on bridge carrier_test_floor_text)
  request picker banned.write "seat: Harbor Watch" --- "forbidden-cross-floor"
  check "[C110] a denied cross-floor write remains denied" answered picker banned.write "refused the plan does not let Orchard Picker write to Harbor Watch"
  check "[C110] denied text was never typed" bash -c '! grep -qF forbidden-cross-floor "$1"' _ "$root/harbor/charts/cross-typed"
  flock -o "$s/floors/deck/type.lock" sleep 60 & holder=$!
  check "[C110] another carrier holds the destination typing slot" eventually bash -c '! flock -n "$1" true' _ "$s/floors/deck/type.lock"
  request grower locked.write "seat: Harbor Watch" --- "after-type-reservation"
  pid=$(carrier_pid bridge)
  check "[C110] the source actually tries the destination lock before taking the request" eventually_long blocked_in_flock "$pid" "$s/floors/deck/type.lock"
  check "[C110] busy typing leaves the original request in out with no answer" bash -c '[[ -f $1/out/locked.write && ! -e $1/answers/locked.write ]]' _ "$s/comms/Orchard Grower"
  request picker meanwhile.md "to: Harbor Watch" "subject: not blocked by typing" --- body
  check "[C110] another seat can deliver mail while typing is reserved" answered_ok picker meanwhile.md
  pkill -P "$holder" sleep 2> /dev/null; wait "$holder" 2> /dev/null
  check "[C110] the waiting write proceeds when its typing slot is free" answered_ok grower locked.write
  check "[C110] the reserved line reached the destination" eventually_long grep -qxF after-type-reservation "$root/harbor/charts/cross-typed"
  check "[C110] change the destination pane's run mark for a refusal probe" exit_is 0 on deck T set-option -p -t "$pane" @workplace stale
  request grower stale.grab "seat: Harbor Watch"
  check "[C110] stale destination pane is refused" answered grower stale.grab "refused the pane of Harbor Watch does not carry this run's mark, or is gone"
  check "[C110] restore the actual destination mark" exit_is 0 on deck T set-option -p -t "$pane" @workplace "$(jq -r '.slots[(["run"]|tojson)]' "$run/deck/state.json")"
  pid=$(on deck T display-message -p '#{pid}')
  check "[C110] stop only the synthetic destination server" kill -STOP "$pid"
  trap 'kill -CONT "$pid" 2>/dev/null; cleanup || exit 1' EXIT
  request grower stopped.grab "seat: Harbor Watch"
  check "[C110] a stopped destination is refused within a bounded call" carrier_test_answer grower stopped.grab "refused the pane of Harbor Watch is not one that this run made" 8
  check "[C110] resume the synthetic destination" kill -CONT "$pid"
  trap 'cleanup || exit 1' EXIT
  request keeper back.md "to: Orchard Grower" "subject: return path" --- body
  check "[C110] the destination's own carrier still serves mail" answered_ok keeper back.md
  check "[C110] stop the destination floor" exit_is 0 wp down deck
  request grower down.write "seat: Harbor Watch" --- "never-to-a-down-floor"
  check "[C110] a down destination is refused" answered grower down.write "refused the pane of Harbor Watch is not one that this run made"
  check "[C110] stop Administration" exit_is 0 wp down bridge
  check "[C110] verify Administration's own request chain" exit_is 0 wp record verify --requests bridge
  check "[C110] verify destination's own request chain" exit_is 0 wp record verify --requests deck
  check "[C110] request verification requires a floor" exit_is 2 wp record verify --requests
  check "[C110] request verification refuses an unknown floor" exit_is 2 wp record verify --requests missing
}

t_carrier_closed_wakes() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox"
  statements_plan "$floors_terms | $comms_terms"
  check "[C111] fixture without any wake pattern plans" exit_is 0 wplan
  check "[C111] fixture builds" exit_is 0 wp build
  local s c record rec
  s=$(state_of) c=$s/floors/deck/comms record=$c/record
  jq -nc '{seats:{"Gone Seat":{name:"Gone Seat",ids:["gone-1"],count:1,since:"2026-11-18T00:00:00Z",last:0},"Harbor Pilot":{name:"Harbor Pilot",ids:["kind-1"],count:1,since:"2026-11-18T00:00:00Z",last:0},"Lodge Ida":{name:"Lodge Ida",ids:["other-floor"],count:1,since:"2026-11-18T00:00:00Z",last:0}}}' > "$s/comms/wake.json"
  chmod 0600 -- "$s/comms/wake.json"
  check "[C111] start the only carrier" exit_is 0 wp up deck
  check "[C111] impossible entries close without a typing attempt" eventually_long bash -c '[[ $(jq -s "[.[] | select(.action==\"wake\" and .outcome==\"closed\")] | length" "$1") == 2 ]]' _ "$record"
  check "[C111] closing lines retain covered IDs and omit text lengths" jq -se 'all(.[] | select(.outcome=="closed"); (.covers|length)==1 and (has("length")|not) and (has("sha256")|not))' "$record"
  check "[C111] removed seat has an explicit reason" jq -se 'any(.[]; .target==["Gone Seat"] and .reason=="no build makes the seat Gone Seat")' "$record"
  check "[C111] removed pattern has an explicit kind reason" jq -se 'any(.[]; .target==["Harbor Pilot"] and .reason=="the kind none of Harbor Pilot has no wake now")' "$record"
  check "[C111] this floor closes only its own entries; a down peer keeps its due ID" eventually_long bash -c '[[ $(jq -c ".seats | keys" "$1") == "[\"Lodge Ida\"]" && $(jq -c ".seats[\"Lodge Ida\"].ids" "$1") == "[\"other-floor\"]" ]]' _ "$s/comms/wake.json"
  check "[C111] stop to plant the claim-before-delete window" exit_is 0 wp down deck
  jq -c '.seats["Gone Again"]={name:"Gone Again",ids:["gone-2"],count:1,since:"2026-11-18T00:00:00Z",last:0} | .seats["Bridge Canary"]={name:"Bridge Canary",ids:["canary"],count:1,since:"2026-11-18T00:00:00Z",last:0}' "$s/comms/wake.json" > "$scratch/wake-new"
  cp -- "$scratch/wake-new" "$s/comms/wake.json"
  rec=$(stat -c %s -- "$record")
  ( umask 077; jq -nc --argjson rec "$rec" '{box:"Gone Again",target:"Gone Again",ids:["gone-2"],start:0,rec:$rec,outcome:"closed",reason:"no build makes the seat Gone Again"}' > "$c/.pointing/Gone Again" )
  check "[C111] another floor starts before the interrupted claimant recovers" exit_is 0 wp up bridge
  check "[C111] the second carrier completes a later closure in the same pass" eventually_long bash -c 'jq -e "select(.covers==[\"canary\"] and .outcome==\"closed\")" "$1" >/dev/null' _ "$s/floors/bridge/comms/record"
  check "[C111] recover a closure already claimed in the local journal" exit_is 0 wp up deck
  check "[C111] recovery both records and removes the claimed entry" eventually_long bash -c '[[ $(jq -c ".seats | keys" "$1") == "[\"Lodge Ida\"]" && ! -e $2 ]] && jq -e "select(.covers==[\"gone-2\"] and .outcome==\"closed\")" "$3" >/dev/null' _ "$s/comms/wake.json" "$c/.pointing/Gone Again" "$record"
  check "[C111] stop after recovered closure" exit_is 0 wp down deck
  check "[C111] restart without any waiting request" exit_is 0 wp up deck
  sleep 2
  check "[C111] no closing line is duplicated across another restart" test "$(jq -s '[.[] | select(.outcome=="closed")] | length' "$record")" = 3
  check "[C111] stop fixture" exit_is 0 wp down deck
  check "[C111] stop the second carrier" exit_is 0 wp down bridge
  check "[C111] an interrupted claim closes in exactly one floor record" bash -c '''[[ $(jq -s "[.[] | select(.covers==[\"gone-2\"] and .outcome==\"closed\")] | length" "$1" "$2") == 1 ]]''' _ "$record" "$s/floors/bridge/comms/record"
}

t_carrier_recovery_decisions() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$scratch/recovery-mv"
  statements_plan "$floors_terms | $comms_terms"' | kinds([
    ["harbor","dock","keeper","clerk"],["harbor","dock","pilot","clerk"],["harbor","tower","watch","clerk"],
    ["orchard","barn","grower","clerk"],["orchard","barn","picker","clerk"],["lodge","east","ida","clerk"]])
    | .programs[-1].recorded += [m(["wake","clerk","^waiting>$"];2)]'
  check "[C108] reader-by-reader recovery fixture plans" exit_is 0 wplan
  check "[C108] fixture builds" exit_is 0 wp build
  local s store c id=resumed-mail real_git real_mv pid
  s=$(state_of) store=$s/mail c=$s/floors/deck/comms
  real_git=$(command -v git); real_mv=$(command -v mv)
  for path in 'Harbor Pilot/in' 'Lodge Ida/in' 'Harbor Keeper/sent'; do printf '%s\n' recovery > "$store/$path/$id.md"; done
  check "[C108] stage the synthetic delivery under the store lock" exit_is 0 flock -o "$store" env -i PATH="$PATH" HOME="$store" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$real_git" -C "$store" add -- .
  check "[C108] commit that delivery under the store lock" exit_is 0 flock -o "$store" env -i PATH="$PATH" HOME="$store" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null "$real_git" -C "$store" -c user.name=fixture -c user.email=fixture@example.test commit -qm "deliver $id"
  ( umask 077; jq -nc --arg id "$id" '{id:$id,box:"Harbor Keeper",seat:"Harbor Keeper",request:"resumed.md",action:"mail",stage:"delivering",base:"",rec:0}' > "$c/serving" )
  printf '%s\n' '#!/usr/bin/env bash' 'dest=${!#}' \
    "'$real_mv' \"\$@\" || exit" \
    "if [[ \$dest == '$s/comms/wake.json' && -f '$scratch/recovery-stop' ]] && jq -e --arg id '$id' '(.seats[\"Harbor Pilot\"].ids // [] | index(\$id)) != null and (.seats[\"Lodge Ida\"].ids // [] | index(\$id)) == null' \"\$dest\" >/dev/null; then" \
    "  printf '%s\\n' \"\$PPID\" > '$scratch/recovery-entered'; kill -STOP \"\$PPID\"" \
    'fi' > "$scratch/recovery-mv/mv"
  chmod +x -- "$scratch/recovery-mv/mv"
  mkdir -p -- "$run/deck/carrier"
  printf '%s\n' '{"slots":{}}' > "$run/deck/state.json"
  : > "$scratch/recovery-stop"
  PATH="$scratch/recovery-mv:$PATH" "$BASH" "$clone/BUILD/bin/workplace" carry deck > "$scratch/recovery-first.log" 2>&1 & pid=$!
  check "[C108] recovery stops after the first reader's due decision" eventually_long test -s "$scratch/recovery-entered"
  check "[C108] the actual recovery carrier is stopped" eventually_long grep -q '^State:.*T' "/proc/$pid/status"
  check "[C108] kill the carrier between its two readers" kill -KILL "$pid"
  wait "$pid" 2>/dev/null
  rm -f -- "$scratch/recovery-stop"
  flock -o "$store" python3 - "$s/comms/wake.json" <<'PY'
import json,os,sys
p=sys.argv[1]
with open(p) as f:v=json.load(f)
v['seats']['Harbor Pilot'].update(ids=[],count=0,since=None)
with open(p+'.fixture','w') as f:json.dump(v,f)
os.replace(p+'.fixture',p)
PY
  "$BASH" "$clone/BUILD/bin/workplace" carry deck > "$scratch/recovery-second.log" 2>&1 & pid=$!
  check "[C108] a second recovery completes and answers the delivery" answered keeper resumed.md "ok $id"
  check "[C108] the already-pointed first reader is not made due again" test "$(jq -c '.seats["Harbor Pilot"].ids' "$s/comms/wake.json")" = '[]'
  check "[C108] the unfinished second reader still receives its due decision" test "$(jq -c '.seats["Lodge Ida"].ids' "$s/comms/wake.json")" = '["resumed-mail"]'
  rm -rf -- "$run/deck/carrier"
  wait "$pid"
  check "[C108] completed delivery releases its temporary reader decisions" jq -e --arg id "$id" '(.decided | has($id) | not) and (.delivered | has($id) | not)' "$s/comms/wake.json"
}

t_carrier_record_links() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$root/records"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["reach","orchard","-","-","office","record","harbor","tower","-","room","allowed"];2),
    m(["record","-","-","-","workplace","pane","kept"];3),
    m(["record-path","records"];4),m(["record-chain","file"];5)]'
  check "[C112] Administration record-view fixture plans" exit_is 0 wplan
  check "[C112] fixture builds" exit_is 0 wp build
  check "[C112] Administration starts with a recorded link view" exit_is 0 wp up bridge
  local s stamp link obsolete sentinel top old_top mark pid
  s=$(state_of) stamp=$s/floors/bridge/links.state
  link=$root/records/Orchard\ Grower/Harbor\ Watch
  obsolete=$root/records/Orchard\ Grower/Former
  sentinel=$root/records/Orchard\ Grower/local-note
  check "[C112] up records the live top and run identity" test -f "$stamp"
  check "[C112] its state is private even under the caller's ordinary umask" test "$(stat -c %a -- "$stamp")" = 600
  old_top=$(jq -r .top "$stamp") mark=$(jq -r .run "$stamp")
  check "[C112] the record link points to its owner's persistent record directory" test "$(readlink -- "$link")" = "$s/floors/deck/records/Harbor Watch"
  check "[C112] a cleanup for another run is refused" exit_is 1 wp record-links-end "$stamp" wrong-run
  check "[C112] wrong-run cleanup changed no link" test -L "$link"
  printf '%s\n' local > "$sentinel"
  printf '%s\n' retained > "$s/floors/deck/records/Harbor Watch/retained"
  ln -s -- "$s/floors/deck/records/Former" "$obsolete"
  jq --arg path "$obsolete" --arg target "$s/floors/deck/records/Former" '.links += [{path:$path,target:$target}]' "$stamp" > "$scratch/link-stamp"
  cat -- "$scratch/link-stamp" > "$stamp"
  rm -f -- "$link"
  python3 - "$clone/BUILD/MANIFEST" <<'PY'
import os,re,sys
p=sys.argv[1]
with open(p) as f:lines=f.readlines()
indices=[i for i,v in enumerate(lines) if re.match(r'^[0-9a-f]{64}  ',v) and '  floors/' not in v]
values=[lines[i] for i in indices][::-1]
for i,v in zip(indices,values):lines[i]=v
with open(p+'.fixture','w') as f:f.writelines(lines)
os.replace(p+'.fixture',p)
PY
  top=$(sha256sum "$clone/BUILD/MANIFEST"); top=${top%% *}
  check "[C112] the semantically unchanged top now has a distinct digest" test "$top" != "$old_top"
  check "[C112] carrier refreshes after that top change" eventually_long bash -c '[[ $(jq -r .top "$1") == "$2" && -L $3 && ! -e $4 && ! -L $4 ]]' _ "$stamp" "$top" "$link" "$obsolete"
  check "[C112] refresh preserves an unowned file in the view" grep -qxF local "$sentinel"
  pid=$(carrier_pid bridge)
  check "[C112] kill only the synthetic Administration carrier" kill -KILL "$pid"
  check "[C112] status detects that its carrier is gone" exit_is 1 wp status bridge
  check "[C112] status names the last refresh and its stale-view limit" said "seats added or removed since are not reflected"
  check "[C112] down ends the owned record links" exit_is 0 wp down bridge
  check "[C112] down removes the managed link and its stamp" bash -c '[[ ! -e $1 && ! -L $1 && ! -e $2 ]]' _ "$link" "$stamp"
  check "[C112] down preserves the recorded data" grep -qxF retained "$s/floors/deck/records/Harbor Watch/retained"
  check "[C112] down preserves the unowned view file" grep -qxF local "$sentinel"
  printf '%s\n' collision > "$link"
  check "[C112] up refuses an unrelated file in a declared link's place" exit_is 1 wp up bridge
  check "[C112] that unrelated file remains unchanged" grep -qxF collision "$link"
  rm -f -- "$link"
  check "[C112] the same built floor starts again without rebuilding" exit_is 0 wp up bridge
  check "[C112] its declared record link is recreated at up" test -L "$link"
  check "[C112] stop the restarted Administration floor" exit_is 0 wp down bridge
}

t_carrier_chain_replay() {
  scoped_clone
  mkdir -p -- "$root/records"
  statements_plan "$records_terms"
  check "[C113] chain replay fixture plans" exit_is 0 wplan
  check "[C113] fixture builds" exit_is 0 wp build
  local s d fifo pid day rel length bad_previous forged_hash
  s=$(state_of) d=$s/records fifo=$s/records/chain.state.new
  mkfifo -- "$fifo"
  check "[C113] start a background carrier with its state-save redirect held" exit_is 0 wp up
  check "[C113] an actual entry reached the file sink before state was saved" eventually_long test -s "$d/chain"
  check "[C113] the saved state is still absent at the FIFO gate" test ! -e "$d/chain.state"
  pid=$(carrier_pid)
  check "[C113] the actual state-save child is blocked opening the FIFO" eventually_long bash -c '
    for child in $(cat "/proc/$1/task/$1/children"); do
      [[ $(cat "/proc/$child/wchan" 2>/dev/null) == wait_for_partner ]] && exit 0
    done
    exit 1
  ' _ "$pid"
  check "[C113] kill the carrier between sending entries and saving state" kill -KILL "$pid"
  check "[C113] release the orphaned state writer and its life-lock descriptor" exit_is 0 timeout --kill-after=1 5 cat "$fifo"
  rm -- "$fifo"
  check "[C113] the orphan did not publish a saved state" test ! -e "$d/chain.state"
  check "[C113] close the dead run" exit_is 0 wp down
  check "[C113] a fresh carrier starts with the older saved state" exit_is 0 wp up
  check "[C113] keeper prints again after the recovery" wait_for_probe "Harbor Keeper" keeper
  check "[C113] stop and flush the restarted carrier" exit_is 0 wp down
  day=$(day_written "$(record_of keeper)") rel="Harbor Keeper/$day.pane"
  check "[C113] the actual sink contains two entries with the same offset and previous hash" bash -c '
    jq -s -e --arg rel "$2" "[.[] | select(.file==\$rel)] | group_by([.offset,.previous]) | any(.[]; length>1)" "$1" >/dev/null
  ' _ "$d/chain" "$rel"
  check "[C113] matching re-sent bytes are accepted" exit_is 0 wp record verify "Harbor Keeper" "$day"
  check "[C113] verification explicitly names the recovered re-send" said "covers again the bytes from byte 0"
  cp -- "$d/chain" "$scratch/replay-chain"
  jq --arg rel "$rel" -sc '
    [.[] | select(.file==$rel)] | group_by([.offset,.previous]) | first(.[] | select(length>1)) | .[0:2][]
  ' "$scratch/replay-chain" > "$scratch/replay-pair"
  length=$(jq -sr '.[1].length' "$scratch/replay-pair")
  printf -v bad_previous '%064d' 1
  forged_hash=$({ printf '%s' "$bad_previous"; head -c "$length" "$(record_of keeper)/$day.pane"; } | sha256sum)
  forged_hash=${forged_hash%% *}
  jq -sc --arg previous "$bad_previous" --arg hash "$forged_hash" '.[1].previous=$previous | .[1].hash=$hash | .[]' "$scratch/replay-pair" > "$d/chain"
  check "[C113] an offset alone does not authorize a replay with a forged previous hash" exit_is 1 wp record verify "Harbor Keeper" "$day"
  check "[C113] the refusal names a backward jump to no earlier starting pair" said "to no place where an earlier entry began"
  jq -sc '.[1].hash=("f"*64) | .[]' "$scratch/replay-pair" > "$d/chain"
  check "[C113] replayed bytes are rehashed instead of trusting a repeated offset" exit_is 1 wp record verify "Harbor Keeper" "$day"
  check "[C113] the replay-hash refusal reports a disagreement with the file" said "differs from its chain"
  cp -- "$scratch/replay-chain" "$d/chain"
  check "[C113] restore and verify the complete actual chain" exit_is 0 wp record verify "Harbor Keeper" "$day"
}

carrier_test_publish_shared() {
  local next=$1 number=$2 old line hash name
  old=$(sed -n 's|^[0-9a-f]\{64\}  \(shared/[0-9]*\)/MANIFEST$|\1|p' "$clone/BUILD/MANIFEST")
  [[ -n $old && ! -e $clone/BUILD/shared/$number ]] || return 1
  hash=$(sha256sum < "$next/MANIFEST");hash=${hash%% *}
  while IFS= read -r line; do
    if [[ ${line#*  } == "$old/MANIFEST" ]]; then printf '%s  shared/%s/MANIFEST\n' "$hash" "$number"
    else printf '%s\n' "$line"; fi
  done < "$clone/BUILD/MANIFEST" > "$scratch/publish-top-$number"
  flock -o "$(state_of)/mail" "$BASH" -c '
    mv -- "$1" "$2/shared/$3" &&
    mv -- "$2/$4" "$5/retired-shared-$3" &&
    mv -fT -- "$5/publish-top-$3" "$2/MANIFEST"
  ' _ "$next" "$clone/BUILD" "$number" "$old" "$scratch"
}

carrier_test_shared_manifest() {
  local dir=$1 file
  (
    cd -- "$dir" || exit
    for file in *; do [[ $file == MANIFEST || ! -f $file ]] || sha256sum -- "$file"; done
  ) > "$dir/MANIFEST"
}

t_carrier_index_reload() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$root/records"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["reach","harbor","-","-","office","mail","lodge","-","-","floor","allowed"];2),
    m(["record","-","-","-","workplace","pane","kept"];3),
    m(["record-path","records"];4),m(["record-chain","file"];5)]'
  check "[C114] index reload fixture plans" exit_is 0 wplan
  check "[C114] fixture builds" exit_is 0 wp build
  local real_flock
  real_flock=$(command -v flock)
  mkdir -- "$scratch/reload-flock"
  printf '%s\n' '#!/usr/bin/env bash' \
    "if [[ \${!#} == 8 && -f '$scratch/reload-pause' ]]; then" \
    "  rm -- '$scratch/reload-pause'; printf '%s\\n' \"\$PPID\" > '$scratch/reload-paused'" \
    '  kill -STOP "$PPID"' \
    "  while [[ ! -e '$scratch/reload-release' ]]; do sleep 0.05; done" \
    'fi' \
    "exec '$real_flock' \"\$@\"" > "$scratch/reload-flock/flock"
  chmod +x -- "$scratch/reload-flock/flock"
  check "[C114] start only the source floor" exit_is 0 env PATH="$scratch/reload-flock:$PATH" "$BASH" "$loop" up deck
  local s old next pid id day file expected
  s=$(state_of) pid=$(carrier_pid deck)
  request keeper unknown.md "to: Lodge Ivo" "subject: unknown before publication" --- body
  check "[C114] the original index does not invent a new name" answered keeper unknown.md "refused name 1 of its to line is not a seat the plan makes, by its exact name, so the mail goes to none"
  old=$(sed -n 's|^[0-9a-f]\{64\}  \(shared/[0-9]*\)/MANIFEST$|\1|p' "$clone/BUILD/MANIFEST")
  next=$scratch/shared-next-50;cp -a -- "$clone/BUILD/$old" "$next"
  mkdir -m 0700 -p -- "$s/mail/Lodge Ivo/in" "$s/mail/Lodge Ivo/sent" "$s/comms/Lodge Ivo/out" "$s/comms/Lodge Ivo/answers"
  jq --arg s "$s" '
    (.seats[] | select(.name=="Lodge Ida")) as $base
    | .seats = [($base | .name="Lodge Ivo" | .box="Lodge Ivo" | .seat[2]="ivo"
      | .in=($s+"/mail/Lodge Ivo/in") | .sent=($s+"/mail/Lodge Ivo/sent")
      | .out=($s+"/comms/Lodge Ivo/out") | .answers=($s+"/comms/Lodge Ivo/answers"))]
      + (.seats | map(if .name=="Harbor Keeper" then .reach.mail=["Lodge Ivo"] else . end))
  ' "$next/mail.json" > "$scratch/new-mail.json"
  mv -f -- "$scratch/new-mail.json" "$next/mail.json"
  carrier_test_shared_manifest "$next"
  check "[C114] synthetic publisher commits a sealed replacement shared index under the store lock" carrier_test_publish_shared "$next" 50
  request keeper added.md "to: Lodge Ivo" "subject: added peer" --- body
  if carrier_test_answer keeper added.md ok; then
    check "[C114] the live carrier admits the new name and route" true
  else
    fail "[C114] the live carrier did not reload the new name and route"
    return 1
  fi
  id=$(answer_of keeper added.md);id=${id#ok }
  check "[C114] array positions still identify the original writer and the new reader" bash -c '[[ -f $1/mail/"Lodge Ivo"/in/$2.md && -f $1/mail/"Harbor Keeper"/sent/$2.md ]]' _ "$s" "$id"
  request keeper removed.md "to: Lodge Ida" "subject: removed route" --- body
  check "[C114] the previous route is no longer authorized" answered keeper removed.md "refused the plan does not let Harbor Keeper mail Lodge Ida, so the mail goes to none"
  check "[C114] reloading keeps the same live carrier process" test "$(carrier_pid deck)" = "$pid"
  next=$scratch/shared-next-51;cp -a -- "$clone/BUILD/shared/50" "$next"
  jq '(.seats[] | select(.name=="Harbor Keeper")).reach.mail=["Lodge Ida"]' "$next/mail.json" > "$scratch/race-mail.json"
  mv -f -- "$scratch/race-mail.json" "$next/mail.json"
  carrier_test_shared_manifest "$next"
  : > "$scratch/reload-pause"
  trap ': > "$scratch/reload-release"; kill -CONT "$pid" 2>/dev/null; cleanup || exit 1' EXIT
  request keeper race.md "to: Lodge Ivo" "subject: revoke before store hold" --- body
  check "[C114] the real carrier reaches its store take after reading the previous index" eventually_long test -s "$scratch/reload-paused"
  check "[C114] the source is stopped before its lock acquisition" eventually_long grep -q '^State:.*T' "/proc/$pid/status"
  check "[C114] publish the route revocation before the carrier takes the store lock" carrier_test_publish_shared "$next" 51
  : > "$scratch/reload-release"
  check "[C114] resume the carrier at its actual store take" kill -CONT "$pid"
  trap 'cleanup || exit 1' EXIT
  check "[C114] the request is decided under the new index, not the stale authorized one" answered keeper race.md "refused the plan does not let Harbor Keeper mail Lodge Ivo, so the mail goes to none"
  check "[C114] that stale pass created no delivery commit" test "$(store_commits)" = 1
  next=$scratch/shared-next-52;cp -a -- "$clone/BUILD/shared/51" "$next"
  cp -- "$next/mail.json" "$scratch/repair-mail.json"
  carrier_test_shared_manifest "$next"
  jq '. + {unverified:true}' "$next/mail.json" > "$scratch/unverified-mail.json"
  mv -f -- "$scratch/unverified-mail.json" "$next/mail.json"
  check "[C114] publish a shared generation whose mail bytes fail its sealed hash" carrier_test_publish_shared "$next" 52
  request keeper held.md "to: Lodge Ida" "subject: retained during invalid snapshot" --- body
  check "[C114] the carrier reports the invalid snapshot" eventually_long grep -qF 'the carrier could not verify the changed build' "$run/deck/carrier.log"
  sleep 2
  check "[C114] a failed snapshot leaves the request untaken and unanswered" bash -c '[[ -f $1/out/held.md && ! -e $1/answers/held.md ]]' _ "$s/comms/Harbor Keeper"
  check "[C114] the carrier remains alive while the index is refused" kill -0 "$pid"
  check "[C114] an owned pane still accepts a literal line during the refusal" exit_is 0 on deck T send-keys -l -t "$(on deck pane_by_title 'Harbor Keeper')" -- index-refusal-output
  check "[C114] the pane receives Enter" exit_is 0 on deck T send-keys -t "$(on deck pane_by_title 'Harbor Keeper')" Enter
  day=$(day_written "$s/floors/deck/records/Harbor Keeper")
  file="$s/floors/deck/records/Harbor Keeper/$day.pane"
  check "[C114] pane recording continues while the index is refused" eventually_long grep -qF index-refusal-output "$file"
  expected=$(stat -c %s -- "$file")
  check "[C114] the record chain continues while the index is refused" eventually_long bash -c '
    jq -e --arg rel "$2" --argjson offset "$3" ".files[\$rel].offset>=\$offset" "$1" >/dev/null
  ' _ "$s/floors/deck/records/chain.state" "Harbor Keeper/$day.pane" "$expected"
  cp -- "$scratch/repair-mail.json" "$clone/BUILD/shared/52/mail.json"
  check "[C114] repairing the snapshot resumes the retained request" answered_ok keeper held.md
  check "[C114] recovery kept the same carrier process" test "$(carrier_pid deck)" = "$pid"
  check "[C114] stop the synthetic floor" exit_is 0 wp down deck
}

t_carrier_pipe_timeout() {
  scoped_clone
  mkdir -p -- "$root/records" "$scratch/pipe-tmux"
  statements_plan "$records_terms"
  check "[C115] pipe timeout fixture plans" exit_is 0 wplan
  check "[C115] fixture builds" exit_is 0 wp build
  local real_tmux pid pane
  real_tmux=$(command -v tmux)
  printf '%s\n' '#!/usr/bin/env bash' \
    'setting=0; for arg in "$@"; do [[ $arg == if-shell ]] && setting=1; done' \
    "if (( setting )) && [[ -f '$scratch/pipe-gate' ]]; then" \
    "  '$real_tmux' \"\$@\" > /dev/null || exit" \
    "  : > '$scratch/pipe-acted'; exec sleep 30" \
    'fi' \
    "exec '$real_tmux' \"\$@\"" > "$scratch/pipe-tmux/tmux"
  chmod +x -- "$scratch/pipe-tmux/tmux"
  check "[C115] start the recording fixture with the gated client" exit_is 0 env PATH="$scratch/pipe-tmux:$PATH" "$BASH" "$loop" up
  pid=$(carrier_pid) pane=$(pane_by_title 'Harbor Keeper')
  : > "$scratch/pipe-gate"
  check "[C115] remove the actual keeper pipe to require restoration" exit_is 0 T pipe-pane -t "$pane"
  check "[C115] the native client restored the pipe before its reply was blocked" eventually_long test -e "$scratch/pipe-acted"
  check "[C115] the bounded uncertain result leaves an explicit gap record" eventually_long grep -qF 'the carrier set the pipe again or tried to, and tmux did not answer within 3 seconds; a gap may stand here' "$(record_of keeper)/gaps"
  check "[C115] the carrier survives the timed-out restoration" kill -0 "$pid"
  rm -- "$scratch/pipe-gate"
  check "[C115] the native server has a pipe rather than an invented success" test "$(T display-message -p -t "$pane" '#{pane_pipe}')" = 1
  check "[C115] stop the fixture" exit_is 0 wp down
}

t_carrier_record_view_reload() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/records" "$root/mailbox"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["record","-","-","-","workplace","pane","kept"];2),
    m(["record-path","records"];3),m(["record-chain","file"];4),
    m(["reach","orchard","barn","grower","seat","record","harbor","dock","keeper","seat","allowed"];5)]'
  check "[C112] shared record-view fixture plans" exit_is 0 wplan
  check "[C112] fixture builds" exit_is 0 wp build
  check "[C112] start Administration on its synthetic default socket" exit_is 0 wp up bridge
  local old next before records record_view=$root/records/Orchard\ Grower
  old=$(sed -n 's|^[0-9a-f]\{64\}  \(shared/[0-9]*\)/MANIFEST$|\1|p' "$clone/BUILD/MANIFEST")
  records=$(sed -n 's|^[0-9a-f]\{64\}  \(floors/bridge/[0-9]*\)/MANIFEST$|\1|p' "$clone/BUILD/MANIFEST")/records.json
  before=$(sha256sum < "$clone/BUILD/$records")
  check "[C112] Administration initially sees the old authorized record" test -L "$record_view/Harbor Keeper"
  check "[C112] the replacement record is initially absent" test ! -e "$record_view/Harbor Pilot"
  next=$scratch/record-shared-next;cp -a -- "$clone/BUILD/$old" "$next"
  jq '(.seats[] | select(.seat==["orchard","barn","grower"])).reach.record=["Harbor Pilot"]' "$next/plan-view.json" > "$scratch/record-shared-view"
  mv -f -- "$scratch/record-shared-view" "$next/plan-view.json"
  carrier_test_shared_manifest "$next"
  check "[C112] publish only the changed shared reach table" carrier_test_publish_shared "$next" 60
  local published_top
  published_top=$(sha256sum < "$clone/BUILD/MANIFEST"); published_top=${published_top%% *}
  check "[C112] the carrier finishes its refresh for the published top" eventually_long jq -e --arg top "$published_top" '.top==$top' "$(state_of)/floors/bridge/links.state"
  check "[C112] the carrier creates the newly authorized link without rebuilding Administration" eventually_long test -L "$record_view/Harbor Pilot"
  check "[C112] the revoked link is removed by the same refresh" test ! -L "$record_view/Harbor Keeper"
  check "[C112] the floor's own sealed metadata stayed byte for byte" test "$(sha256sum < "$clone/BUILD/$records")" = "$before"
  check "[C112] stop Administration after the shared update" exit_is 0 wp down bridge
  check "[C112] start it again from the same own generation" exit_is 0 wp up bridge
  check "[C112] up also resolves record reads from the current shared view" test -L "$record_view/Harbor Pilot"
  check "[C112] up does not recreate the revoked cached read" test ! -L "$record_view/Harbor Keeper"
  check "[C112] stop the fixture" exit_is 0 wp down bridge
}

t_client_mail() {
  check "client mail: isolated carrier, replay and recovery" bash "$here/client-mail.sh" "$tool"
}

client_mail_floor_fixture() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$root/screens"
  printf '%s\n' busy > "$root/screens/grower"
  statements_plan "$floors_terms | $comms_terms"' | kinds([["orchard","barn","grower","courier"],["harbor","dock","keeper","courier"],["harbor","dock","pilot","quiet"]])
    | .programs[-1].recorded += [m(["client-mail","courier"];2),m(["client-panes","courier"];9),m(["client-notice","harbor","courier","claude-hook"];5),
      m(["wake","courier","^waiting>$"];13),m(["kind-notice","courier","screen-pattern"];14),
      m(["client-mail","quiet"];15),m(["kind-notice","quiet","screen-pattern"];16),
      m(["mail-contact","harbor","dock","keeper"];6),m(["mail-contact","orchard","barn","grower"];7),m(["observe-juniors","harbor"];8),
      m(["reach","orchard","-","-","office","mail","harbor","-","-","office","allowed"];3),
      m(["reach","harbor","dock","-","room","mail","orchard","barn","grower","seat","allowed"];4),
      m(["reach","orchard","barn","grower","seat","grab","harbor","tower","watch","seat","allowed"];10),
      m(["reach","orchard","barn","grower","seat","write","harbor","tower","watch","seat","allowed"];11),
      st("harbor";"tower";"-";"room";$root+"/harbor/charts";"read-write";12)]
    | (.programs[] | select(.path=="orchard/barn/grower/seat.typify") | .plan[1].term[5]) |=
      (fromjson + ["screen="+$root+"/screens/grower","typed="+$root+"/screens/grower-typed"] | tojson)
    | (.programs[] | select(.path=="harbor/tower/watch/seat.typify") | .plan[1].term[5]) |=
      (fromjson + ["typed="+$root+"/harbor/charts/client-typed","list="+$root+"/mailbox/in","list="+$root+"/mailbox/Orchard Grower/client-out","list="+$root+"/mailbox/Orchard Grower/client-in"] | tojson)'
}

t_client_mail_floors() {
  if [[ $(nnp_of $$) != NoNewPrivs:0 ]]; then skip "client mail floors: Administration needs an unbarred caller"; return 0; fi
  client_mail_floor_fixture
  check "client mail: plan selects the declared kind" exit_is 0 wplan
  check "client mail: fold persists the opt-in" jq -e '.mail.clientKinds == ["courier","quiet"]' "$clone/PLAN/view.json"
  check "client notice: only the declared office and kind get the hook" jq -e '[.seats[] | select(.clientNotice == "claude-hook") | .seat] == [["harbor","dock","keeper"]]' "$clone/PLAN/view.json"
  check "client mail: synthetic floor build" exit_is 0 wp build
  local mailbox="$root/mailbox/Orchard Grower" key digest file id delivered
  file=$clone/BUILD/shared/$(top_gen)/mail.json
  [[ -s $file ]] || return 1
  check "client mail: exactly one trusted seat has the endpoint" jq -e '[.seats[] | select(.clientEndpoint) | .name] == ["Orchard Grower"]' "$file"
  check "client notice: the office hook takes precedence over its kind's pointer" jq -e 'any(.seats[]; .name == "Harbor Keeper" and .pendingNotice and .clientNotice == "claude-hook")' "$file"
  check "client notice: a selected kind without a wake pattern is pending-only" jq -e 'any(.seats[]; .name == "Harbor Pilot" and .pendingNotice and .wake == null and .clientNotice == null)' "$file"
  check "client notice: the workspace endpoint keeps its kind's pointer in the same client-mail index" jq -e '.clientMail and any(.seats[]; .name == "Orchard Grower" and .clientEndpoint and .clientNotice == "screen-pattern" and .wake == "^waiting>$" and (.pendingNotice | not))' "$file"
  check "client mail: Administration starts" exit_is 0 wp up bridge
  check "client mail: enforced floor starts" exit_is 0 wp up deck
  check "client mail: the enforced seat can read its own inbox" eventually_long on deck screen_has "Harbor Watch" "list $root/mailbox/in: ok"
  check "client mail: the enforced seat cannot read the administrator submission directory" on deck screen_has "Harbor Watch" "list $mailbox/client-out: refused"
  check "client mail: the enforced seat cannot read the administrator inbox directory" on deck screen_has "Harbor Watch" "list $mailbox/client-in: refused"
  printf '%s\n' 'to: Harbor Keeper' 'subject: witnessed submission' --- 'complete letter' > "$mailbox/client-out/.draft"
  digest=$(sha256sum < "$mailbox/client-out/.draft")
  key="first.${digest%% *}.md"
  mv -T -- "$mailbox/client-out/.draft" "$mailbox/client-out/$key"
  check "client mail: sender sees the receipt" eventually_long grep -sEq '^ok [0-9]{8}T[0-9]{6}Z-' "$mailbox/client-answers/$key"
  id=$(sed -n 's/^ok //p' "$mailbox/client-answers/$key")
  delivered="$(state_of)/mail/Harbor Keeper/in/$id.md"
  check "client mail: recipient has the receipt ID" grep -Fxq -- "id: $id" "$delivered"
  check "client mail: recipient sees the submitting seat as sender" grep -Fxq -- "from: Orchard Grower" "$delivered"
  check "client mail: recipient got the complete body" grep -Fxq -- "complete letter" "$delivered"
  local keeper_out keeper_answer reply_id
  keeper_out=$(jq -er '.seats[]|select(.name=="Harbor Keeper")|.out' "$file") || return 1
  [[ -d $keeper_out && $keeper_out == "$scratch"/* ]] || return 1
  keeper_answer=$(jq -r '.seats[]|select(.name=="Harbor Keeper")|.answers' "$file")/reply.md
  printf '%s\n' 'to: Orchard Grower' 'subject: returning mail' --- 'cross-floor reply' > "$keeper_out/.reply" && mv -T -- "$keeper_out/.reply" "$keeper_out/reply.md"
  check "client mail: the other floor sends a reply" eventually_long grep -sEq '^ok [0-9]{8}T[0-9]{6}Z-' "$keeper_answer"
  reply_id=$(sed -n 's/^ok //p' "$keeper_answer")
  check "client mail: the administrator reads the reply at its workspace path" eventually_long grep -sFxq -- 'cross-floor reply' "$mailbox/client-in/$reply_id.md"
  local pointer="mail: 1 new, newest $reply_id.md, in $mailbox/client-in, and the page $mailbox/README.md says what this line is"
  local typed=$root/screens/grower-typed marker=${keeper_answer%/*}/.workplace-claude-notice.json
  check "client notice: the recipient sees its letter while its pane is busy" on bridge screen_has "Orchard Grower" working
  check "client notice: the busy recipient still has its ID queued" jq -e --arg id "$reply_id" '.seats["Orchard Grower"].ids == [$id]' "$(state_of)/comms/wake.json"
  check "client notice: the hook publishes the original delivery" eventually_long jq -e --arg id "$id" '.ids == [$id]' "$marker"
  check "client notice: no pointer was typed while busy" test ! -e "$typed"
  printf '%s\n' menu > "$root/screens/grower"
  check "client notice: the recipient opens a dialog" eventually_long on bridge screen_has "Orchard Grower" 'Esc to cancel'
  local pilot_out pilot_answer
  pilot_out=$(jq -er '.seats[] | select(.name=="Harbor Pilot") | .out' "$file") || return 1
  pilot_answer=$(jq -er '.seats[] | select(.name=="Harbor Pilot") | .answers' "$file")/outside.md
  printf '%s\n' 'to: Orchard Grower' 'subject: non-contact' --- 'outside' > "$pilot_out/.outside" && mv -T -- "$pilot_out/.outside" "$pilot_out/outside.md"
  check "the enforced non-contact cannot mail out through the ordinary queue" eventually_long grep -sFq 'refused the plan does not let Harbor Pilot mail Orchard Grower' "$pilot_answer"
  printf '%s\n' 'to: Harbor Keeper, Harbor Pilot' 'subject: atomic boundary' --- 'blocked' > "$mailbox/client-out/.multi"
  digest=$(sha256sum < "$mailbox/client-out/.multi")
  key="multi.${digest%% *}.md"
  mv -T -- "$mailbox/client-out/.multi" "$mailbox/client-out/$key"
  check "the client queue refuses an entire letter containing a non-contact outside" eventually_long grep -sFq 'refused the plan does not let Orchard Grower mail Harbor Pilot, so the mail goes to none' "$mailbox/client-answers/$key"
  check "client panes: fold is scoped to the selected kind" jq -e '.mail.clientPaneKinds == ["courier"]' "$clone/PLAN/view.json"
  check "client panes: only the trusted endpoint supports pane requests" jq -e '[.seats[] | select(.clientPanes) | .name] == ["Orchard Grower"]' "$file"
  local copy_name write_name refused_name
  printf '%s\n' 'seat: Harbor Watch' > "$mailbox/client-out/.grab"
  digest=$(sha256sum < "$mailbox/client-out/.grab")
  copy_name="look.${digest%% *}.grab"
  mv -T -- "$mailbox/client-out/.grab" "$mailbox/client-out/$copy_name"
  check "client panes: grab reads the declared cross-floor target" eventually_long grep -sFq 'probe watch done' "$mailbox/client-answers/$copy_name"
  printf '%s\n' 'seat: Harbor Watch' --- 'workspace-only marker' > "$mailbox/client-out/.type"
  digest=$(sha256sum < "$mailbox/client-out/.type")
  write_name="speak.${digest%% *}.write"
  mv -T -- "$mailbox/client-out/.type" "$mailbox/client-out/$write_name"
  check "client panes: destination received the verified typed line" eventually_long grep -sxFq 'workspace-only marker' "$root/harbor/charts/client-typed"
  check "client panes: receipt completes" eventually_long grep -sEq '^ok ' "$mailbox/client-answers/$write_name"
  local first_answer
  first_answer=$(< "$mailbox/client-answers/$write_name")
  rm -- "$mailbox/client-answers/$write_name"
  printf '%s\n' 'seat: Harbor Watch' --- 'workspace-only marker' > "$mailbox/client-out/.type"
  mv -T -- "$mailbox/client-out/.type" "$mailbox/client-out/$write_name"
  check "client panes: retry restores original receipt" eventually_long grep -sxFq "$first_answer" "$mailbox/client-answers/$write_name"
  check "client panes: retry does not type twice" test "$(grep -cxF 'workspace-only marker' "$root/harbor/charts/client-typed")" = 1
  printf '%s\n' 'seat: Harbor Pilot' --- 'denied marker' > "$mailbox/client-out/.deny"
  digest=$(sha256sum < "$mailbox/client-out/.deny")
  refused_name="denied.${digest%% *}.write"
  mv -T -- "$mailbox/client-out/.deny" "$mailbox/client-out/$refused_name"
  check "client panes: non-granted target refused with sender attribution" eventually_long grep -sFq 'the plan does not let Orchard Grower write to Harbor Pilot' "$mailbox/client-answers/$refused_name"
  request keeper downward.grab "seat: Harbor Watch"
  check "the senior room observes the actual junior pane" carrier_test_answer keeper downward.grab ok
  request keeper sideways.grab "seat: Harbor Pilot"
  check "the senior cannot observe another seat in the same room" carrier_test_answer keeper sideways.grab "refused the plan does not let Harbor Keeper grab Harbor Pilot"
  request watch upward.grab "seat: Harbor Keeper"
  check "the junior cannot observe the senior" carrier_test_answer watch upward.grab "refused the plan does not let Harbor Watch grab Harbor Keeper"
  check "client mail: pending is visible on status" exit_is 0 wp status
  check "status names the declared office contact" said "Harbor Keeper (harbor/dock/keeper) is office harbor’s external mail contact"
  check "client mail: status ties the recipient, oldest ID and reason together" bash -c 'grep -F "Harbor Keeper (" "$1" | grep -Fq "oldest $2; pending: waiting for the seat"' _ "$scratch/out" "$id"
  check "client notice: the dialog received no pointer" test ! -e "$typed"
  check "client notice: the status gives the screen route and oldest delivery" said "oldest $reply_id; pending: waiting to point out mail at the declared ready prompt"
  printf '%s\n' ready > "$root/screens/grower"
  check "client notice: the ready seat gets the pointer naming its workspace inbox" file_comes_to "$typed" "$pointer"
  local state due log
  state=$(state_of)
  due=$state/comms/wake.json log=$state/floors/bridge/comms/record
  check "client notice: the screen pointer settles only its delivery" eventually_long jq -e '.seats["Orchard Grower"].ids == []' "$due"
  check "client notice: the workspace seat has no hook marker" test ! -e "$mailbox/answers/.workplace-claude-notice.json"
  check "client notice: restart the recipient after pointing" exit_is 0 wp down bridge
  check "client notice: start the recipient with the retained mixed index" exit_is 0 wp up bridge
  request grower restart.grab "seat: Harbor Watch"
  check "client notice: a full carrier pass completes after restart" eventually_long grep -sEq '^ok ' "$mailbox/answers/restart.grab"
  check "client notice: exactly one screen pointer was recorded across restart" jq -se --arg id "$reply_id" '[.[] | select(.action=="wake" and .outcome=="ok" and .covers==[$id])] | length==1' "$log"
  check "client notice: the same ID is typed only once across restart" file_is "$typed" "$pointer"
  printf '%s\n' busy > "$root/screens/grower"
  check "client notice: the recipient is busy again" eventually_long on bridge screen_has "Orchard Grower" working
  request keeper read-first.md "to: Orchard Grower" "subject: early confirmation" --- "read while busy"
  check "client notice: a second letter reaches the busy reader" carrier_test_answer keeper read-first.md ok
  local read_id ack
  read_id=$(answer_of keeper read-first.md); read_id=${read_id#ok }
  check "client notice: the second letter is readable from the workspace" eventually_long grep -sFxq 'read while busy' "$mailbox/client-in/$read_id.md"
  ack="$mailbox/out/.workplace-read-$read_id"
  sha256sum < "$mailbox/client-in/$read_id.md" > "$mailbox/out/.read" && mv -fT -- "$mailbox/out/.read" "$ack"
  check "client notice: the carrier settles the read without typing" eventually_long jq -e --arg id "$read_id" '.seats["Orchard Grower"].ids | index($id) == null' "$due"
  printf '%s\n' ready > "$root/screens/grower"
  check "client notice: a confirmed letter gets a read record and no pointer" jq -se --arg id "$read_id" '[.[] | select(.action=="wake" and .covers==[$id]) | .outcome] == ["read"]' "$log"
  check "client notice: the recipient has only the first pointer" file_is "$typed" "$pointer"
  check "client mail: stop enforced floor" exit_is 0 wp down deck
  check "client mail: stop Administration" exit_is 0 wp down bridge
}
