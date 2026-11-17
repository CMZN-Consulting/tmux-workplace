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
  check "[C109] pointer evidence was journalled before the effect" jq -e --arg id "$id" '.ids==[$id] and (.length>0) and (.sha256|length)==64 and (has("outcome")|not)' "$c/.pointing/Lodge Ida"
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
  jq -nc --arg id "$id" --argjson rec "$rec" --argjson start "$start" '{box:"Lodge Ida",target:"Lodge Ida",ids:[$id],start:$start,rec:$rec,length:3,sha256:"abc",outcome:"ok",reason:""}' > "$c/.pointing/Lodge Ida"
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
  check "[C110] authorized grab is answered by the destination floor" answered_ok grower cross.grab
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
  jq -c '.seats["Gone Again"]={name:"Gone Again",ids:["gone-2"],count:1,since:"2026-11-18T00:00:00Z",last:0}' "$s/comms/wake.json" > "$scratch/wake-new"
  cp -- "$scratch/wake-new" "$s/comms/wake.json"
  rec=$(stat -c %s -- "$record")
  jq -nc --argjson rec "$rec" '{box:"Gone Again",target:"Gone Again",ids:["gone-2"],start:0,rec:$rec,outcome:"closed",reason:"no build makes the seat Gone Again"}' > "$c/.pointing/Gone Again"
  check "[C111] recover a closure already claimed in the local journal" exit_is 0 wp up deck
  check "[C111] recovery both records and removes the claimed entry" eventually_long bash -c '[[ $(jq -c ".seats | keys" "$1") == "[\"Lodge Ida\"]" && ! -e $2 ]] && jq -e "select(.covers==[\"gone-2\"] and .outcome==\"closed\")" "$3" >/dev/null' _ "$s/comms/wake.json" "$c/.pointing/Gone Again" "$record"
  check "[C111] stop after recovered closure" exit_is 0 wp down deck
  check "[C111] restart without any waiting request" exit_is 0 wp up deck
  sleep 2
  check "[C111] no closing line is duplicated across another restart" test "$(jq -s '[.[] | select(.outcome=="closed")] | length' "$record")" = 3
  check "[C111] stop fixture" exit_is 0 wp down deck
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
  jq -nc --arg id "$id" '{id:$id,box:"Harbor Keeper",seat:"Harbor Keeper",request:"resumed.md",action:"mail",stage:"delivering",base:"",rec:0}' > "$c/serving"
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
  check "[C112] the same built floor starts again without rebuilding" exit_is 0 wp up bridge
  check "[C112] its declared record link is recreated at up" test -L "$link"
  check "[C112] stop the restarted Administration floor" exit_is 0 wp down bridge
}
