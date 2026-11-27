#!/usr/bin/env bash
set -u -o pipefail
fixture_frame=$(cd -P -- "${1:-${BASH_SOURCE[0]%/*}/..}" && pwd)
tool=$fixture_frame
scratch=$(mktemp -d) || exit 1
trap 'rm -rf -- "$scratch"' EXIT
export HOME=$scratch/home TMPDIR=$scratch
mkdir -p "$HOME"
source <(sed -e '/^source_dir=/,/^source .*floor-runtime.bash/c\source "$fixture_frame/libexec/floor-runtime.bash"' -e '/^(( \$# )) || { usage/,$d' "$fixture_frame/bin/workplace")
check() { if "$@"; then printf 'ok %s\n' "$label"; else
  printf 'failed %s\n' "$label" >&2; exit 1
fi; }
comms=$scratch/private fcomms=$scratch/floor taken=$scratch/floor/taken comms_record=$scratch/floor/record
build_dir=$scratch/build mail_path=$scratch/workspace/mail store=$scratch/store run_dir=$scratch/run
mkdir -p "$taken" "$build_dir" "$run_dir" "$mail_path"
touch "$build_dir/MANIFEST"
carrier_top=$(sha_of "$build_dir/MANIFEST")
carrier_socket="" carrier_run="" carrier_tmux_program=false carrier_setpriv=false
carrier_held=0 carrier_stop=0 client_next=()
for who in Finch Wren; do
  mkdir -p -- "$comms/$who"/{out,answers} "$store/$who"/{in,sent} "$mail_path/$who"
done
git -c init.defaultBranch=fixture init -q --template= -- "$store" || exit 1
index=$(jq -cn --arg base "$mail_path" --arg comms "$comms" '{clientMail:true,path:$base,seats: [
  {seat:["a","a","a"],name:"Finch",box:"Finch",reach:{mail:["Wren"]},clientEndpoint:true,pendingNotice:true},
  {seat:["b","b","b"],name:"Wren",box:"Wren",reach:{mail:["Finch"]},wake:"waiting>"}]
  | map(. + {out:($comms+"/"+.box+"/out"),answers:($comms+"/"+.box+"/answers")})}')
carrier_index_load "$index"
notice_without_pattern() (
  comms=$scratch/notice comms_record=$scratch/notice/record
  mkdir -p "$comms"
  carrier_id=notice-1
  carrier_wake_note "2026-01-01T00:00:00Z" Wren Finch \
    && jq -e '.seats.Finch.ids == ["notice-1"]' "$comms/wake.json"
)
label="a selected reader without a prompt pattern has a pending notice"
check notice_without_pattern
label="the client publish and answer directories exist on the carrier filesystem"
check floor_client_mail_dirs make "$mail_path/Finch" "$comms/Finch/out" "$taken"
label="the build makes client-sent beside client-in, a real directory of the user's with mode 700"
check bash -c '[[ -d $1 && ! -L $1 && $(stat -c %u:%a "$1") == "$2:700" ]]' _ "$mail_path/Finch/client-sent" "$EUID"
old_build() (
  mv -T -- "$mail_path/Finch/client-sent" "$scratch/client-sent.away" || exit 1
  floor_client_mail_dirs check "$mail_path/Finch" "$comms/Finch/out" "$taken" 2> /dev/null
  status=$?
  mv -T -- "$scratch/client-sent.away" "$mail_path/Finch/client-sent" || exit 1
  exit "$status"
)
label="a build made before client-sent existed passes the check that up and recovery make"
check old_build
linked_sent() (
  mv -T -- "$mail_path/Finch/client-sent" "$scratch/client-sent.away" || exit 1
  ln -s -- "$scratch/client-sent.away" "$mail_path/Finch/client-sent" || exit 1
  floor_client_mail_dirs check "$mail_path/Finch" "$comms/Finch/out" "$taken" 2> /dev/null
  status=$?
  rm -- "$mail_path/Finch/client-sent" && mv -T -- "$scratch/client-sent.away" "$mail_path/Finch/client-sent" || exit 1
  ((status != 0))
)
label="a client-sent that is a link is refused by that check"
check linked_sent
ln -s -- "$comms/Finch/out" "$mail_path/Finch/out" && ln -s -- "$store/Finch/in" "$mail_path/Finch/in" \
  && ln -s -- "$store/Finch/sent" "$mail_path/Finch/sent" && ln -s -- "$comms/Finch/answers" "$mail_path/Finch/answers" || exit 1
outbox=$mail_path/Finch/client-out
answers=$mail_path/Finch/client-answers
turn() {
  carrier_pass_begin
  carrier_serve_turn "$1"
}
letter() { printf 'to: %s\nsubject: synthetic mail\n---\n%s\n' "$1" "$2"; }
letter Wren first > "$outbox/.draft"
key=first.$(sha_of "$outbox/.draft").md
sleep 1.05
turn 0 || exit 1
label="dot drafts consume no request ID"
check test ! -f "$comms/next"
mv -T -- "$outbox/.draft" "$outbox/$key"
sleep 1.05
turn 0 || exit 1
label="the carrier publishes a readable success receipt"
check grep -Eq '^ok [0-9]{8}T[0-9]{6}Z-000001$' "$answers/$key"
read -r _ id < "$answers/$key"
label="the verified bytes reach the intended reader"
check grep -qx first "$store/Wren/in/$id.md"
label="the carrier assigns the sender"
check grep -qx 'from: Finch' "$store/Wren/in/$id.md"
label="the visible receipt is read-only"
check test "$(stat -c %a "$answers/$key")" = 400
label="pending notice holds the delivery ID"
check jq -e --arg id "$id" '.seats.Wren.ids == [$id] and .seats.Wren.count == 1' "$comms/wake.json"
seat_pane[1]=%17
carrier_tmux() {
  printf 'terminal access\n' >> "$scratch/terminal"; return 1
}
carrier_wake
carrier_wake
label="a retained clientMail index suppresses screen input without an explicit screen route"
check test ! -e "$scratch/terminal"
rm -- "$answers/$key"
letter Wren first > "$outbox/$key"
letter Wren changed > "$outbox/.other"
conflict=first.$(sha_of "$outbox/.other").md
mv -T -- "$outbox/.other" "$outbox/$conflict"
sleep 1.05
turn 0
turn 0
label="the original receipt is recoverable after replay"
check grep -qxF "ok $id" "$answers/$key"
label="another payload under that logical name has a conflict receipt"
check grep -q '^refused .*different contents' "$answers/$conflict"
label="replays consume no counter"
check test "$(< "$comms/next")" = 1
label="the sender's client-sent holds its copy of the mail: the reader's in and the store's sent byte for byte, read-only, on an inode of its own"
check bash -c 'cmp -s "$1" "$2" && cmp -s "$1" "$3" && [[ $(stat -c %a "$1") == 400 && ! $1 -ef $3 ]]' _ \
  "$mail_path/Finch/client-sent/$id.md" "$store/Wren/in/$id.md" "$store/Finch/sent/$id.md"
label="client-sent holds that mail and nothing else"
check test "$(ls -A -- "$mail_path/Finch/client-sent")" = "$id.md"
swapped_during_copy() (
  local sent=$mail_path/Finch/client-sent decoy=$scratch/decoy
  mkdir -p -- "$decoy"
  rm -f -- "$sent/$id.md"
  eval "$(declare -f carrier_git | sed '1s/^carrier_git/carrier_git_real/')"
  carrier_git() {
    if [[ $1 == cat-file && ! -L $sent ]]; then
      mv -T -- "$sent" "$scratch/client-sent.real" && ln -s -- "$decoy" "$sent" || return 1
    fi
    carrier_git_real "$@"
  }
  carrier_copy_inbox Finch "$sent" sent
  local status=$?
  rm -- "$sent" && mv -T -- "$scratch/client-sent.real" "$sent" || exit 1
  [[ $status == 0 && -z $(ls -A -- "$decoy") && -f $sent/$id.md ]] && cmp -s -- "$sent/$id.md" "$store/Finch/sent/$id.md"
)
label="a client-sent swapped for a link after its checks gets the copy in the directory that was checked, and the link's target gets nothing"
check swapped_during_copy
fifo_during_copy() (
  local sent=$mail_path/Finch/client-sent
  stat() {
    if [[ $1 == -c && $2 == %u:%a:%h && $4 == */$id.md ]]; then
      command stat "$@"
      local status=$?
      rm -f -- "$4" && mkfifo -m 0600 -- "$4"
      return "$status"
    fi
    command stat "$@"
  }
  carrier_copy_inbox Finch "$sent" sent
)
fifo_during_copy &
copier=$!
for n in {1..50}; do
  kill -0 "$copier" 2> /dev/null || break
  sleep 0.2
done
if kill -0 "$copier" 2> /dev/null; then
  kill "$copier"
  timeout 2 bash -c ': > "$1"' _ "$mail_path/Finch/client-sent/$id.md"
  copied=hung
else
  wait "$copier"
  copied=$?
fi
label="a fifo put in place of a published copy between its check and its read blocks nothing: the copy is published again"
check bash -c '[[ $1 == 0 && -f $2 && ! -p $2 && $(stat -c %a "$2") == 400 ]] && cmp -s "$2" "$3"' _ "$copied" "$mail_path/Finch/client-sent/$id.md" "$store/Finch/sent/$id.md"
letter Wren remainder > "$outbox/.full"
incomplete=incomplete.$(sha_of "$outbox/.full").md
printf 'to: Wren\nsubject: synthetic mail\n---\n' > "$outbox/$incomplete"
printf 'ignored\n' > "$outbox/invalid.write"
letter Ghost missing > "$outbox/.new"
denied=missing.$(sha_of "$outbox/.new").md
mv -T -- "$outbox/.new" "$outbox/$denied"
letter Finch reply > "$comms/Wren/out/reply.md"
sleep 1.05
turn 0
turn 0
turn 0
turn 1
label="an incomplete final file cannot deliver"
check grep -q '^refused .*SHA-256' "$answers/$incomplete"
label="client outbox refuses pane operations"
check grep -q '^refused .*client mail' "$answers/invalid.write"
label="recipient policy applies to verified client mail"
check grep -q '^refused ' "$answers/$denied"
label="existing outbox can reply"
check grep -q '^ok ' "$comms/Wren/answers/reply.md"
label="a client without a pattern can have pending mail"
check jq -e '.seats.Finch.count == 1' "$comms/wake.json"
label="only two mails entered the store"
check test "$(git -C "$store" rev-list --count HEAD)" = 2
label="a client with a masked private state can publish using native workspace tools"
client() {
  bwrap --unshare-all --die-with-parent --ro-bind /usr /usr --symlink usr/lib64 /lib64 --symlink usr/lib /lib \
    --dir /workspace --bind "$mail_path/Finch" /workspace/Finch --chdir /workspace/Finch \
    --clearenv --setenv PATH /usr/bin /usr/bin/bash -c "$@"
}
check client 'set -e; test -L out; test ! -e out; printf "to: Wren\nsubject: commit\n---\nclient\n" > client-out/.draft; hash=$(sha256sum < client-out/.draft); hash=${hash%% *}; mv -nT client-out/.draft "client-out/visible.$hash.md"'
sleep 1.05
turn 0
read -r _ incoming < "$comms/Wren/answers/reply.md"
label="the client can enumerate and read its committed reply with private state absent"
check client 'set -e; test -L in; test ! -e in; test "$(ls client-in)" = "$1.md"; grep -Fxq "from: Wren" "client-in/$1.md"; grep -Fxq reply "client-in/$1.md"' _ "$incoming"
label="the workspace inbox is a read-only file on a separate inode"
check bash -c '[[ $(stat -c %a "$1") == 400 && ! $1 -ef $2 ]] && cmp -s "$1" "$2"' _ "$mail_path/Finch/client-in/$incoming.md" "$store/Finch/in/$incoming.md"
uncommitted=20260101T000000Z-999999.md
printf 'unfinished\n' > "$store/Finch/in/$uncommitted"
rm -- "$mail_path/Finch/client-in/$incoming.md"
printf 'unfinished\n' > "$store/Finch/sent/$uncommitted"
rm -- "$mail_path/Finch/client-sent/$id.md"
printf 'stale\n' > "$mail_path/Finch/client-sent/20260101T000000Z-999998.md"
carrier_index_load "$index"
turn 0
label="a fresh carrier backfills existing committed mail and ignores an unfinished delivery"
check client 'test -s "client-in/$1.md" && test ! -e "client-in/$2"' _ "$incoming" "$uncommitted"
read -r _ visible < "$mail_path/Finch/client-answers/visible".*.md
label="the client reads both of its sent mails in client-sent, with its private sent absent, and no unfinished or stale one"
check client 'set -e; test -L sent; test ! -e sent; test "$(ls client-sent | tr "\n" " ")" = "$1.md $2.md "; grep -Fxq first "client-sent/$1.md"; grep -Fxq client "client-sent/$2.md"; grep -Fxq "from: Finch" "client-sent/$2.md"' \
  _ "$id" "$visible"
label="the client reads its receipt in the same restricted view"
check client 'grep -q "^ok " client-answers/visible.*.md'
recover() {
  carrier_pass_begin
  carrier_hold || return 1
  carrier_recover
  local result=$?
  carrier_release; return "$result"
}
letter Wren restore > "$outbox/.before"
before=restore.$(sha_of "$outbox/.before").md
(
  client_request=true
  carrier_next_id && carrier_journal Finch "$before" mail Finch "$(git -C "$store" rev-parse HEAD)" \
    && mv -T -- "$outbox/.before" "$taken/$carrier_id" && carrier_progress '.stage="taken"'
) || exit 1
label="recovery returns a claimed unpublished request to the same queue"
check recover
label="restored public request exists"
check test -f "$outbox/$before"
sleep 1.05
turn 0
label="returned request is delivered once"
check grep -q '^ok ' "$answers/$before"
letter Wren after > "$outbox/.after"
after=after.$(sha_of "$outbox/.after").md
mv -T -- "$outbox/.after" "$outbox/$after"
sleep 1.05
(
  carrier_answer() { return 1; }
  ! turn 0
) || exit 1
label="interrupted delivery leaves its journal"
check test -s "$fcomms/serving"
committed=$(git -C "$store" rev-list --count HEAD)
letter Finch second > "$comms/Wren/out/new.md"
sleep 1.05
turn 1 || exit 1
label="another request waits while the floor has an interrupted delivery"
check test -e "$comms/Wren/out/new.md"
label="restart completes the public receipt from the committed delivery"
check recover
label="a second recovery is harmless"
check recover
label="public receipt survives post-commit recovery"
check grep -q '^ok ' "$answers/$after"
label="recovery holds the original store head count"
check test "$(git -C "$store" rev-list --count HEAD)" = "$committed"
b_mail=$scratch/mail.json b_view=$scratch/missing b_layout=flat f_gen=$scratch/generation
jq --arg comms "$comms" --arg store "$store" '. + {comms:$comms,store:$store}' <<< "$index" > "$b_mail"
label="status explains the reason and gives the oldest ID"
seats_report > "$scratch/status"
check grep -F "oldest $id; pending:" "$scratch/status"

native_notice() (
  local id=$1 marker=$comms/Wren/answers/.workplace-claude-notice.json ack=$comms/Wren/out/.workplace-read-$1
  mkdir -p -- "$fcomms/.pointing"
  local old_index=$index
  index=$(jq -c '.seats[1] |= (del(.wake) + {clientNotice:"claude-hook",pendingNotice:true})' <<< "$index")
  carrier_index_load "$index" || return 1
  carrier_pass_begin
  carrier_wake || return 1
  jq -e --arg id "$id" '.version == 1 and .ids[0] == $id and (.text | startswith("mail: "))' "$marker" || return 1
  local old_stamp
  old_stamp=$(stat -c '%i:%y' "$marker")
  carrier_index_load "$index"
  carrier_pass_begin
  carrier_wake || return 1
  [[ $(stat -c '%i:%y' "$marker") == "$old_stamp" ]] || return 1
  printf 'unconfirmed\n' > "$ack"
  carrier_pass_begin
  carrier_wake || return 1
  jq -e --arg id "$id" '.seats.Wren.ids | index($id) != null' "$comms/wake.json" || return 1
  sha256sum < "$store/Wren/in/$id.md" > "$ack"
  (
    carrier_settle() { :; }
    carrier_pass_begin
    carrier_wake
  ) || return 1
  jq -e --arg id "$id" '.outcome == "read" and .ids == [$id]' "$fcomms/.pointing/Wren" || return 1
  jq -e --arg id "$id" '.seats.Wren.ids | index($id) != null' "$comms/wake.json" || return 1
  carrier_index_load "$index"
  carrier_pass_begin
  carrier_wake || return 1
  carrier_pass_begin
  carrier_wake || return 1
  jq -e --arg id "$id" '.seats.Wren.ids | length > 0 and index($id) == null' "$comms/wake.json" || return 1
  jq -e --arg id "$id" '.notify == false and (.ids | index($id) == null)' "$marker" || return 1
  letter Wren another > "$comms/Finch/out/after-read.md"
  sleep 1.05
  turn 0 || return 1
  local new_id
  read -r _ new_id < "$comms/Finch/answers/after-read.md" || return 1
  carrier_pass_begin
  carrier_wake || return 1
  jq -e --arg id "$new_id" '.notify == false and (.ids | index($id) == null)' "$marker" || return 1
  WAKE_PERIOD=0
  carrier_pass_begin
  carrier_wake || return 1
  jq -e --arg id "$new_id" '.notify != false and (.ids | index($id) != null)' "$marker" || return 1
  [[ ! -e $ack && ! -e $scratch/terminal ]] || return 1
  [[ $(jq -rs --arg id "$id" '[.[] | select(.outcome=="read" and .covers==[$id])] | length' "$comms_record") == 1 ]] || return 1
  # A fresh read of an already confirmed letter leaves a duplicate digest even after its ID
  # has disappeared from the marker. The carrier reaps it without waking again.
  sha256sum < "$store/Wren/in/$id.md" > "$ack"
  carrier_pass_begin
  carrier_wake || return 1
  [[ ! -e $ack ]] || return 1

  state_dir=$scratch/native-state
  local remote=$state_dir/floors/sender/comms early hidden delayed receipt
  mkdir -p "$remote/taken"
  touch "$remote/record"
  letter Wren early > "$comms/Finch/out/early.md"
  sleep 1.05
  (
    fcomms=$remote taken=$remote/taken comms_record=$remote/record
    carrier_wake_note() { return 1; }
    ! turn 0
  ) || return 1
  early=$(jq -er .id "$remote/serving") || return 1
  receipt=$comms/Wren/out/.workplace-read-$early
  sha256sum < "$store/Wren/in/$early.md" > "$receipt"
  carrier_pass_begin
  carrier_wake || return 1
  [[ -f $receipt ]] || return 1
  (
    carrier_hold() {
      touch "$scratch/unneeded-hold"; return 1
    }
    carrier_clear_read_receipts 1
  ) || return 1
  [[ ! -e $scratch/unneeded-hold ]] || return 1
  (
    fcomms=$remote taken=$remote/taken comms_record=$remote/record
    recover
  ) || return 1
  carrier_pass_begin
  carrier_wake || return 1
  jq -e --arg id "$early" '.ids | index($id) != null' "$marker" || return 1
  carrier_pass_begin
  carrier_wake || return 1
  carrier_pass_begin
  carrier_wake || return 1
  [[ ! -e $receipt ]] || return 1
  jq -e --arg id "$early" '.seats.Wren.ids | index($id) == null' "$comms/wake.json" || return 1
  jq -se --arg id "$early" '[.[] | select(.outcome == "read" and (.covers | index($id) != null))] | length == 1' "$comms_record" || return 1

  # Preserve early receipts beyond the bounded marker. Use a real committed ID in the tail.
  delayed=$new_id
  sha256sum < "$store/Wren/in/$delayed.md" > "$comms/Wren/out/.workplace-read-$delayed"
  jq --arg id "$delayed" '.seats.Wren.ids = ([range(128) | "older-" + tostring] + [$id])' "$comms/wake.json" > "$scratch/large-wake"
  cp "$comms/wake.json" "$scratch/small-wake"
  mv "$scratch/large-wake" "$comms/wake.json"
  carrier_pass_begin
  carrier_clear_read_receipts 1 || return 1
  [[ -f $comms/Wren/out/.workplace-read-$delayed ]] || return 1
  mv "$scratch/small-wake" "$comms/wake.json"
  rm "$comms/Wren/out/.workplace-read-$delayed"

  # Self-wake suppression never made this committed letter due. Its reader may still open it.
  letter Wren withheld > "$comms/Finch/out/withheld.md"
  sleep 1.05
  (
    fcomms=$remote taken=$remote/taken comms_record=$remote/record
    seat_own[1]=fixture seat_number[1]=1 seat_number[0]=2
    turn 0
  ) || return 1
  read -r _ hidden < "$comms/Finch/answers/withheld.md" || return 1
  jq -se --arg id "$hidden" 'any(.[]; .outcome == "withheld" and .covers == [$id])' "$remote/record" || return 1
  sha256sum < "$store/Wren/in/$hidden.md" > "$comms/Wren/out/.workplace-read-$hidden"
  carrier_pass_begin
  carrier_wake || return 1
  [[ ! -e $comms/Wren/out/.workplace-read-$hidden ]] || return 1
  carrier_index_load "$old_index"
  carrier_pass_begin
  carrier_wake || return 1
  [[ ! -e $marker && ! -e $scratch/terminal ]]
)
label="a selected Claude hook receives pending mail on restart, confirms one committed letter and never types a key"
check native_notice "$id"

client_pane_recovery() (
  local name digest request original_index=$index
  printf '%s\n' 'seat: Wren' --- 'fixture line' > "$scratch/body"
  digest=$(sha_of "$scratch/body")
  name="one-turn.$digest.write"
  request=$outbox/$name
  cp -- "$scratch/body" "$request"
  sleep 1.05
  turn 0 && grep -Fq 'refused client mail' "$answers/$name" || return 1
  rm -- "$answers/$name"
  index=$(jq -c '.seats[0] += {clientPanes:true} | .seats[0].reach.write = ["Wren"]' <<< "$index")
  carrier_index_load "$index" || return 1
  seat_pane[1]='%1'
  cp -- "$scratch/body" "$request"
  sleep 1.05
  (
    carrier_type() { printf '%s\n' "$2" >> "$scratch/typed"; }
    carrier_answer() { return 1; }
    ! turn 0
  ) || return 1
  jq -e --arg r "$name" '.request==$r and .action=="write" and .clientKey=="one-turn" and .stage=="acting"' "$fcomms/serving" || return 1
  grep -xq 'fixture line' "$scratch/typed" || return 1
  recover || return 1
  grep -Fq 'whether it acted is not known' "$answers/$name" || return 1
  cp -- "$answers/$name" "$scratch/uncertain-receipt"
  rm -- "$answers/$name"
  cp -- "$scratch/body" "$request"
  sleep 1.05
  carrier_index_load "$index" || return 1
  (
    carrier_type() { printf '%s\n' 'duplicate' >> "$scratch/typed"; }
    turn 0
  ) || return 1
  cmp -s -- "$answers/$name" "$scratch/uncertain-receipt" || return 1
  [[ $(wc -l < "$scratch/typed") == 1 ]] || return 1
  jq -se --arg r "$name" '[.[] | select(.request==$r and .action=="write" and .outcome=="unknown" and .seat=="Finch")] | length == 1' "$comms_record" || return 1
  carrier_index_load "$original_index"
)
label="a pane write requires opt-in and replays an interrupted action without typing twice"
check client_pane_recovery

read_before_pointer() (
  local route=$1 delivery receipt updated
  mkdir -p -- "$fcomms/.pointing"
  updated=$(jq -c --arg route "$route" 'if $route == "screen-pattern" then
      .seats[0] += {clientNotice:$route,wake:"^waiting>$"} | del(.seats[0].pendingNotice)
    else .seats |= map(del(.wake)) end' <<< "$index") || return 1
  carrier_index_load "$updated"
  letter Finch "early read" > "$comms/Wren/out/00-read-$route.md"
  sleep 1.05
  turn 1 || return 1
  read -r _ delivery < "$comms/Wren/answers/00-read-$route.md" || return 1
  receipt=$comms/Finch/out/.workplace-read-$delivery
  printf 'wrong digest\n' > "$receipt"
  carrier_pass_begin
  carrier_wake || return 1
  jq -e --arg id "$delivery" '.seats.Finch.ids | index($id) != null' "$comms/wake.json" || return 1
  sha256sum < "$store/Finch/in/$delivery.md" > "$receipt"
  (
    carrier_settle() { :; }
    carrier_pass_begin
    carrier_wake
  ) || return 1
  jq -e --arg id "$delivery" '.outcome == "read" and .ids == [$id]' "$fcomms/.pointing/Finch" || return 1
  carrier_index_load "$updated"
  carrier_pass_begin
  carrier_wake || return 1
  carrier_pass_begin
  carrier_wake || return 1
  [[ ! -e $receipt ]] || return 1
  jq -e --arg id "$delivery" '.seats.Finch.ids | index($id) == null' "$comms/wake.json" || return 1
  sha256sum < "$store/Finch/in/$delivery.md" > "$receipt"
  carrier_pass_begin
  carrier_wake || return 1
  [[ ! -e $receipt && ! -e $comms/Finch/answers/.workplace-claude-notice.json ]] || return 1
  jq -se --arg id "$delivery" '[.[] | select(.action == "wake" and .covers == [$id]) | .outcome] == ["read"]' "$comms_record"
)
label="an explicit screen route verifies early reads, recovers once and removes repeated confirmations"
check read_before_pointer screen-pattern
label="a pending-only seat can settle a delivery on a floor without any screen pattern"
check read_before_pointer pending

