#!/usr/bin/env bash
set -o nounset -o pipefail
unset TMUX TMUX_PANE

here=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
tool=${here%/tests}
loop=$tool/bin/workplace
fixtures=$here/fixtures
failures=0
total=0
declare -a failed_tests=()

note() { printf '%s\n' "$*"; }
fail() {
  note "  FAIL: $*"
  test_failed=1
}
check() {
  local message=$1
  shift
  if "$@"; then note "  ok: $message"; else fail "$message"; fi
}

T() { tmux -L "$label" "$@"; }
wp() { "$BASH" "$loop" "$@"; }

setup() {
  scratch=$(mktemp -d /tmp/wpt.XXXXXX)
  export HOME=$scratch/home
  export TMUX_TMPDIR=$scratch/t
  mkdir -p -- "$HOME" "$TMUX_TMPDIR"
  label=wpt-$$-$1
  root=$scratch/root
  mkdir -p -- "$root/config" "$root/tools" \
    "$root/harbor/ledger/inner" "$root/harbor/charts" "$root/harbor/berth" "$root/harbor/vault/shelf" \
    "$root/orchard/cellar/inner" "$root/orchard/almanac" "$root/orchard/crate-picker" "$root/orchard/silo/bin"
  printf '%s\n' secret > "$root/harbor/ledger/secret"
  printf '%s\n' secret > "$root/orchard/cellar/secret"
  printf '%s\n' page > "$root/harbor/charts/page"
  printf '%s\n' page > "$root/orchard/almanac/page"
  cp -- "$fixtures/probe" "$root/tools/probe"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/tools/forbidden.real"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$root/tools/allowed"
  chmod +x -- "$root/tools/forbidden.real" "$root/tools/allowed"
  ln -s forbidden.real "$root/tools/forbidden"
  ln -s forbidden.real "$root/tools/forbidden-alias"
  cp -- "$fixtures/tmux.conf" "$root/config/tmux.conf"
  export WORKPLACE_ROOT=$root
  export WORKPLACE_CONFIG=$root/config
  plan=$scratch/plan.json
  jq --arg l "$label" 'walk(if . == "@LABEL@" then $l else . end)' "$fixtures/workplace.json" > "$plan"
  run=$root/config/BUILD/RUN
  local count
  count=$(env | grep -c '^TMUX=')
  [[ $count == 0 ]] || fail "TMUX is set in the test's environment ($count)"
}

cleanup() {
  T kill-server 2> /dev/null
  rm -rf -- "$scratch"
}

variant() {
  local filter=$1 out=$2
  shift 2
  jq "$@" "$filter" "$plan" > "$out"
}

pane_by_title() {
  T list-panes -a -F '#{pane_title}	#{pane_id}' | while IFS=$'\t' read -r title id; do
    [[ $title == "$1" ]] && printf '%s\n' "$id"
  done
}

screen_of() {
  local id
  id=$(pane_by_title "$1")
  [[ -n $id ]] || return 1
  T capture-pane -p -t "$id"
}

wait_for_probe() {
  local title=$1 seat=$2 i
  for (( i = 0; i < 100; i++ )); do
    if screen_of "$title" | grep -qx "probe $seat done"; then return 0; fi
    sleep 0.05
  done
  return 1
}

screen_has() { screen_of "$1" | grep -qxF -- "$2"; }
no_server() { ! T list-sessions > /dev/null 2>&1; }
sessions_are() { [[ "$(T list-sessions -F '#{session_name}' 2> /dev/null | sort | tr '\n' ' ')" == "$1" ]]; }
exit_is() {
  local want=$1
  shift
  "$@" > "$scratch/out" 2>&1
  local got=$?
  [[ $got == "$want" ]] || { note "    exit $got, wanted $want; output:"; sed 's/^/    | /' "$scratch/out"; return 1; }
}
said() { grep -qF -- "$1" "$scratch/out"; }

seat_call() {
  jq -c --arg s "$1" 'select(.[5] == "respawn-pane" and any(.[]; . == $s))' "$run/calls.jsonl"
}

view_targets() {
  local -a args
  mapfile -d '' -t args < <(jq --raw-output0 '.[]' <<< "$1")
  local i=0 n=${#args[@]}
  while (( i < n )) && [[ ${args[i]} != --dev-bind ]]; do i=$(( i + 1 )); done
  (( i < n )) || return 0
  i=$(( i + 3 ))
  while (( i < n )) && [[ ${args[i]} != -- ]]; do
    case ${args[i]} in
      --perms) i=$(( i + 2 )) ;;
      --tmpfs) printf '%s\n' "tmpfs ${args[i + 1]}"; i=$(( i + 2 )) ;;
      --bind | --ro-bind) printf '%s\n' "${args[i]#--} ${args[i + 1]} ${args[i + 2]}"; i=$(( i + 3 )) ;;
      *) printf '%s\n' "unknown ${args[i]}"; i=$(( i + 1 )) ;;
    esac
  done
}

t_inputs_and_refusals() {
  check "[C1] status without WORKPLACE_ROOT exits 2" exit_is 2 env -u WORKPLACE_ROOT "$BASH" "$loop" status
  check "[C1] a relative WORKPLACE_ROOT exits 2" exit_is 2 env WORKPLACE_ROOT=root "$BASH" "$loop" status
  check "[C1] WORKPLACE_CONFIG outside the root exits 2" exit_is 2 env WORKPLACE_CONFIG="$scratch" "$BASH" "$loop" status
  check "[C2] build without --plan exits 2" exit_is 2 wp build
  check "[C2] the refusal says Typify's plan is not wired" said "Typify's plan is not wired in yet"
  variant '.programs[1].plan[0][0] = "summon"' "$scratch/unknown.json"
  check "[C2] a plan with an unknown primitive does not build" exit_is 1 wp build --plan "$scratch/unknown.json"
  check "[C2] the refusal names the primitive" said "the binding has no primitive summon"
  check "[C3] the refused build left no BUILD" test ! -e "$root/config/BUILD"
  variant '.programs[1].plan[0] |= .[0:3]' "$scratch/arity.json"
  check "[C2] a term with the wrong number of arguments does not build" exit_is 1 wp build --plan "$scratch/arity.json"
  variant '.status = "failed"' "$scratch/failed.json"
  check "[C2] a plan whose status is failed does not build" exit_is 1 wp build --plan "$scratch/failed.json"
  variant '.programs[1].plan[0][4] = "Har\u0007bor"' "$scratch/control.json"
  check "[C2] a plan with a control character does not build" exit_is 1 wp build --plan "$scratch/control.json"
  variant '.state.view[0].value = ["open"]' "$scratch/state.json"
  check "[C2] a view row with an unknown state does not build" exit_is 1 wp build --plan "$scratch/state.json"
  check "[C2] the refusal names the state" said "open is not one of"
  variant '.state.view[0].key |= .[0:3]' "$scratch/key.json"
  check "[C2] a view row whose key is not four strings does not build" exit_is 1 wp build --plan "$scratch/key.json"
  check "[C4] up without a build exits 1" exit_is 1 wp up
  check "[C4] up says it never builds" said "never builds"
  check "[C4] up without a build made no server" no_server
  check "[C3] the fixture builds" exit_is 0 wp build --plan "$plan"
  local name
  for name in plan.json binding.json libexec/resolve.jq libexec/check.jq libexec/exec share/denied MANIFEST; do
    check "[C3] BUILD holds $name" test -f "$root/config/BUILD/$name"
  done
  check "[C3] the manifest's plan hash is the input's hash" \
    test "$(sha256sum < "$plan" | cut -d' ' -f1)" = "$(grep '  plan.json$' "$root/config/BUILD/MANIFEST" | cut -d' ' -f1)"
  check "[C3] the manifest's binding hash is the tool's binding's hash" \
    test "$(sha256sum < "$tool/host/binding.json" | cut -d' ' -f1)" = "$(grep '  binding.json$' "$root/config/BUILD/MANIFEST" | cut -d' ' -f1)"
  check "[C3] a second build refuses while BUILD exists" exit_is 1 wp build --plan "$plan"
  check "[C21] status reports the build verified and exits 0" exit_is 0 wp status
  check "[C21] status says verified" said "build: verified"
  printf '%s\n' ' ' >> "$root/config/BUILD/plan.json"
  check "[C4] up refuses a build whose plan differs from its manifest" exit_is 1 wp up
  check "[C4] the refusal names the file" said "plan.json does not match its MANIFEST"
  check "[C4] the refused up made no server" no_server
  check "[C21] status reports the changed build and exits 1" exit_is 1 wp status
  rm -rf -- "$root/config/BUILD"
  check "[C3] the fixture builds again" exit_is 0 wp build --plan "$plan"
  printf '%s\n' extra > "$root/config/BUILD/extra"
  check "[C4] up refuses a file its manifest does not list" exit_is 1 wp up
  rm -f -- "$root/config/BUILD/extra" "$root/config/BUILD/share/denied"
  check "[C4] up refuses a build missing a listed file" exit_is 1 wp up
  check "[C4] the refused up made no server" no_server
}

t_program_floors() {
  local bin=$scratch/old
  mkdir -p -- "$bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "tmux 2.8"' > "$bin/tmux"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "jq-1.6"' > "$bin/jq"
  chmod +x -- "$bin/tmux" "$bin/jq"
  check "build" exit_is 0 wp build --plan "$plan"
  mv -- "$bin/jq" "$bin/jq.off"
  check "[C5] an older tmux is refused with exit 2" exit_is 2 env PATH="$bin:$PATH" "$BASH" "$loop" up
  check "[C5] the refusal names both versions" said "tmux 2.8 found; 2.9 or later is needed"
  mv -- "$bin/jq.off" "$bin/jq"
  check "[C5] an older jq is refused with exit 2" exit_is 2 env PATH="$bin:$PATH" "$BASH" "$loop" status
  check "[C5] the refusal names both versions" said "jq 1.6 found; 1.7 or later is needed"
  check "[C5] the bash floor is in the source (no older bash is installed to run it)" \
    grep -qF '(( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 2) ))' "$loop"
  check "[C5] nothing was started" no_server
}

t_structure_and_starts() {
  check "build" exit_is 0 wp build --plan "$plan"
  check "up" exit_is 0 wp up
  check "[C6] the sessions are harbor and orchard" sessions_are "harbor orchard "
  local windows panes
  windows=$(T list-windows -a -F '#{session_name}:#{window_name}' | sort | tr '\n' ' ')
  check "[C6] the windows are harbor:dock, harbor:tower, orchard:barn" test "$windows" = "harbor:dock harbor:tower orchard:barn "
  panes=$(T list-panes -a -F '#{session_name}/#{window_name}/#{pane_title}' | sort | tr '\n' ',')
  check "[C6] the panes and titles are the five seats" \
    test "$panes" = "harbor/dock/Harbor Keeper,harbor/dock/Harbor Pilot,harbor/tower/Harbor Watch,orchard/barn/Orchard Grower,orchard/barn/Orchard Picker,"
  local row name seat office
  for row in "Harbor Pilot:pilot:harbor" "Harbor Keeper:keeper:harbor" "Harbor Watch:watch:harbor" \
    "Orchard Grower:grower:orchard" "Orchard Picker:picker:orchard"; do
    IFS=: read -r name seat office <<< "$row"
    check "[C6] $name runs its command" wait_for_probe "$name" "$seat"
    check "[C6] $name started in $office, a relative path joined to the root" \
      screen_has "$name" "probe $seat start cwd=$root/$office seat="
  done
  local kinds
  kinds=$(jq -r '.[5]' "$run/calls.jsonl" | tr '\n' ' ')
  check "[C6] the calls were made in plan order" test "$kinds" = \
    "start-server new-session set-option new-window new-session set-option split-window select-layout split-window select-layout respawn-pane respawn-pane respawn-pane respawn-pane respawn-pane "
  local pilot keeper grower picker
  pilot=$(T display -p -t "$(pane_by_title 'Harbor Pilot')" '#{pane_left} #{pane_top} #{pane_width}')
  keeper=$(T display -p -t "$(pane_by_title 'Harbor Keeper')" '#{pane_left} #{pane_top} #{pane_width}')
  check "[C6] dock: keeper is right of pilot, on the same line, the same width within one" \
    awk -v a="$pilot" -v b="$keeper" 'BEGIN { split(a, p, " "); split(b, k, " "); d = p[3] - k[3]; exit !(k[1] > p[1] && k[2] == p[2] && d <= 1 && d >= -1) }'
  grower=$(T display -p -t "$(pane_by_title 'Orchard Grower')" '#{pane_left} #{pane_top}')
  picker=$(T display -p -t "$(pane_by_title 'Orchard Picker')" '#{pane_left} #{pane_top}')
  check "[C6] barn: picker is below grower" \
    awk -v a="$grower" -v b="$picker" 'BEGIN { split(a, g, " "); split(b, p, " "); exit !(p[2] > g[2] && p[1] == g[1]) }'
  check "[C6] no pane reaches past its window" \
    test -z "$(T list-panes -a -F '#{pane_top} #{pane_height} #{window_height} #{pane_left} #{pane_width} #{window_width}' \
      | awk '$1 + $2 > $3 || $4 + $5 > $6')"
  local mark
  mark=$(jq -r '.slots[(["run"] | tojson)]' "$run/state.json")
  check "[C11] each session carries the run's mark" \
    test "$(T show-options -qv -t =harbor: @workplace) $(T show-options -qv -t =orchard: @workplace)" = "$mark $mark"
  check "[C15] every start was followed by clearing its pane's history" \
    test "$(jq -c 'select(.[5] == "respawn-pane") | [.[] | select(. == "clear-history")] | length' "$run/calls.jsonl" | sort -u)" = 1
  check "[C21] status exits 0 with the workplace up" exit_is 0 wp status
  check "[C21] status lists every seat ok" test "$(grep -c '^ok          seat/' "$scratch/out")" = 5
  for name in calls.jsonl ledger checks added.jsonl facts.json state.json; do
    check "[C20] RUN holds $name" test -f "$run/$name"
  done
  check "[C8] the learned pane ids are written back as facts" \
    test "$(jq '[.facts[] | select(.fact == "slot" and .args[0] == "pane")] | length' "$run/facts.json")" = 5
  check "[C8] the facts hold every program the plan needs, as an absolute path" \
    test "$(jq -r '[.facts[] | select(.args[0] == "program") | .value | startswith("/")] | all and length == 3' "$run/facts.json")" = true
  check "[C19] a second up refuses while the workplace is up" exit_is 1 wp up
  check "[C19] the refusal says it is up already" said "is up already"
  check "[C19] the second up left the first standing" sessions_are "harbor orchard "
}

t_holding_panes() {
  variant '.programs |= map(.plan |= map(select((if type == "object" then .term else . end)[0] != "start")))' "$scratch/held.json"
  check "build of a plan with no start" exit_is 0 wp build --plan "$scratch/held.json"
  check "up" exit_is 0 wp up
  check "[C15] every pane holds a tmux client" test "$(T list-panes -a -F '#{pane_current_command}' | sort -u)" = tmux
  check "[C15] no held pane has printed anything" \
    test -z "$(for id in $(T list-panes -a -F '#{pane_id}'); do T capture-pane -p -t "$id"; done | tr -d '[:space:]')"
}

t_a_foreign_tmux_in_the_environment() {
  T -f /dev/null new-session -d -s bystander
  T select-pane -t =bystander: -T "Bystander"
  local socket pane
  socket=$(T display -p -t =bystander: '#{socket_path},#{pid},#{session_id}')
  pane=$(T display -p -t =bystander: '#{pane_id}')
  check "build" exit_is 0 wp build --plan "$plan"
  check "[C22] up with TMUX and TMUX_PANE naming the bystander's pane" \
    exit_is 0 env TMUX="$socket" TMUX_PANE="$pane" "$BASH" "$loop" up
  check "[C22] every title landed on its own seat" \
    test "$(T list-panes -a -F '#{pane_title}' | sort | tr '\n' ',')" = "Bystander,Harbor Keeper,Harbor Pilot,Harbor Watch,Orchard Grower,Orchard Picker,"
  check "[C11] no run mark reached the bystander" test -z "$(T show-options -qv -t =bystander: @workplace)"
  check "[C22] down with the same environment" exit_is 0 env TMUX="$socket" TMUX_PANE="$pane" "$BASH" "$loop" down
  check "[C18] the bystander survives" sessions_are "bystander "
}

t_seat_views() {
  check "build" exit_is 0 wp build --plan "$plan"
  check "up" exit_is 0 wp up
  local row title seat office hidden ro rw shelf vault
  for row in "Harbor Keeper:keeper:harbor:ledger:charts:berth:vault:shelf" \
    "Orchard Picker:picker:orchard:cellar:almanac:crate-picker:silo:bin"; do
    IFS=: read -r title seat office hidden ro rw vault shelf <<< "$row"
    check "$seat ran" wait_for_probe "$title" "$seat"
    check "[C13] $seat does not see $hidden (tmpfs 0000)" screen_has "$title" "hidden $hidden: unseen"
    check "[C12] under the hidden $hidden, the read-write $hidden/inner is unreachable" \
      screen_has "$title" "reach $hidden/inner: write=refused"
    check "[C13] $seat reads $ro and cannot write it" screen_has "$title" "ro $ro: read=ok write=refused"
    check "[C13] $seat writes $rw" screen_has "$title" "rw $rw: write=ok"
    check "[C13] $seat's write to $rw is there outside the sandbox" test -f "$root/$office/$rw/probe-$seat"
    check "[C13] $seat cannot list the searchable $vault (tmpfs 0111)" screen_has "$title" "list $vault: refused"
    check "[C12] under the searchable $vault, the read-write $vault/$shelf is reachable" \
      screen_has "$title" "reach $vault/$shelf: write=ok"
    check "[C12] that write is there outside the sandbox" test -f "$root/$office/$vault/$shelf/probe-$seat"
  done
  check "[C14] keeper cannot run the denied executable" screen_has "Harbor Keeper" "exec ../tools/forbidden: refused"
  check "[C14] nor its other name" screen_has "Harbor Keeper" "exec ../tools/forbidden-alias: refused"
  check "[C14] keeper runs an executable that is not denied" screen_has "Harbor Keeper" "exec ../tools/allowed: ok"
  for row in "Harbor Pilot:pilot:ledger:charts:vault" "Orchard Grower:grower:cellar:almanac:silo"; do
    IFS=: read -r title seat hidden ro vault <<< "$row"
    check "$seat ran" wait_for_probe "$title" "$seat"
    check "[C12] $seat, with no view, sees $hidden" screen_has "$title" "hidden $hidden: seen"
    check "[C12] $seat, with no view, writes $ro" screen_has "$title" "ro $ro: read=ok write=ok"
    check "[C12] $seat, with no view, lists $vault" screen_has "$title" "list $vault: ok"
  done
  check "[C14] pilot, with no view, runs the executable keeper may not" screen_has "Harbor Pilot" "exec ../tools/forbidden: ok"
  local keeper_call pilot_call expected
  keeper_call=$(seat_call keeper)
  pilot_call=$(seat_call pilot)
  expected="bind $root/harbor/berth $root/harbor/berth
ro-bind $root/harbor/charts $root/harbor/charts
tmpfs $root/harbor/ledger
tmpfs $root/harbor/vault
bind $root/harbor/vault/shelf $root/harbor/vault/shelf
ro-bind $root/config/BUILD/share/denied $root/tools/forbidden.real"
  check "[C12] keeper's view is emitted in byte order, with nothing beneath the hidden ledger" \
    test "$(view_targets "$keeper_call")" = "$expected"
  check "[C12] keeper's start begins with bubblewrap's fixed head" \
    test "$(jq -r '[.[] | select(. == "--unshare-user" or . == "--die-with-parent")] | length' <<< "$keeper_call")" = 2
  check "[C5] bubblewrap is named by its absolute path" \
    test "$(jq -r '.[] | select(endswith("/bwrap"))' <<< "$keeper_call")" = "$(command -v bwrap)"
  check "[C12] pilot, with no rows, starts without bubblewrap" \
    test "$(jq '[.[] | select(endswith("bwrap"))] | length' <<< "$pilot_call")" = 0
  check "[C14] two names of one target make one row" \
    test "$(jq -c '.what' "$run/added.jsonl" | wc -l)" = 1
  check "[C14] the added row replaced the plan's read-only row at the same path" \
    test "$(view_targets "$keeper_call" | grep -c "forbidden.real")" = 1
  check "[C21] status lists the added row" exit_is 0 wp status
  check "[C14] status lists it as unchecked" \
    said "unchecked   view/harbor/dock/keeper $root/tools/forbidden.real: denied, added by the loop for $root/tools/forbidden"
}

t_a_row_of_three_and_a_grid() {
  variant '.programs[3].plan |= (.[0:1] + [["pane", "harbor", "dock", "mate", "keeper", "right", "Harbor Mate", "harbor"]] + .[1:])
    | .programs[4].plan |= (.[0:1] + [["pane", "orchard", "barn", "hand", "grower", "right", "Orchard Hand", "orchard"],
                                      ["pane", "orchard", "barn", "keep", "picker", "right", "Orchard Keep", "orchard"]] + [["arrange", "orchard", "barn", "tiled"]])' "$scratch/grid.json"
  check "build" exit_is 0 wp build --plan "$scratch/grid.json"
  check "up" exit_is 0 wp up
  local widths tops
  widths=$(for t in "Harbor Pilot" "Harbor Keeper" "Harbor Mate"; do T display -p -t "$(pane_by_title "$t")" '#{pane_width}'; done | tr '\n' ' ')
  tops=$(for t in "Harbor Pilot" "Harbor Keeper" "Harbor Mate"; do T display -p -t "$(pane_by_title "$t")" '#{pane_top}'; done | sort -u | wc -l)
  check "[C6] dock: pilot, keeper and mate stand on one line" test "$tops" = 1
  check "[C6] dock: their widths differ by at most one ($widths)" \
    awk -v w="$widths" 'BEGIN { n = split(w, a, " "); lo = a[1]; hi = a[1]; for (i = 2; i <= n; i++) { if (a[i] < lo) lo = a[i]; if (a[i] > hi) hi = a[i] } exit !(n == 3 && hi - lo <= 1) }'
  check "[C6] barn: tiled makes two rows of two" \
    test "$(for t in "Orchard Grower" "Orchard Hand" "Orchard Picker" "Orchard Keep"; do T display -p -t "$(pane_by_title "$t")" '#{pane_top}'; done | sort -u | wc -l)" = 2
  check "[C6] no pane reaches past its window" \
    test -z "$(T list-panes -a -F '#{pane_top} #{pane_height} #{window_height} #{pane_left} #{pane_width} #{window_width}' \
      | awk '$1 + $2 > $3 || $4 + $5 > $6')"
}

t_failure_leaves_nothing() {
  variant '.programs[-1].plan += [["session", "harbor", "again", "stray", "Stray", "harbor"]]' "$scratch/late.json"
  check "build of a plan whose last term fails" exit_is 0 wp build --plan "$scratch/late.json"
  T -f /dev/null new-session -d -s bystander
  check "[C16] up exits 1 when a primitive fails" exit_is 1 wp up
  check "[C16] the failure names the term" said "orchard/barn/picker/seat.typify, term 2"
  check "[C16] no session of the workplace is left; the test's own survives" sessions_are "bystander "
  check "[C16] no RUN is left" test ! -e "$run"
  T kill-session -t =bystander
  rm -rf -- "$root/config/BUILD"
  variant '.programs[3].plan[0][4] = "nobody"' "$scratch/middle.json"
  check "build of a plan that fails in the middle" exit_is 0 wp build --plan "$scratch/middle.json"
  check "[C16] up exits 1" exit_is 1 wp up
  check "[C8] the failure names the missing slot" said "no slot pane/harbor/dock/nobody"
  check "[C16] no session is left, and no server" no_server
  rm -rf -- "$root/config/BUILD"
  variant '(.programs[1].plan[0][5]) = "harbor/nowhere"' "$scratch/nodir.json"
  check "build of a plan whose session directory is missing" exit_is 0 wp build --plan "$scratch/nodir.json"
  check "[C9] up exits 1 before tmux falls back to the home directory" exit_is 1 wp up
  check "[C9] the refusal names the directory" said "harbor/nowhere is not a directory"
  check "[C9] no server was left" no_server
  rm -rf -- "$root/config/BUILD"
  variant '(.programs[1].plan[0][1]) = "har/bor"' "$scratch/slash.json"
  check "build of a plan whose office name holds a slash" exit_is 0 wp build --plan "$scratch/slash.json"
  check "[C9] up refuses the name" exit_is 1 wp up
  check "[C9] the refusal says it is not a name" said "is not a name"
  rm -rf -- "$root/config/BUILD"
  variant '(.programs[5].plan[0].term[5]) = "tools/nothing-here"' "$scratch/unresolved.json"
  check "build of a plan that denies a missing executable" exit_is 0 wp build --plan "$scratch/unresolved.json"
  check "[C14] up refuses a target that does not resolve" exit_is 1 wp up
  check "[C16] and tears down what it made" no_server
}

t_unattached_options() {
  local conf
  for conf in tmux-destroy-unattached.conf tmux-exit-unattached.conf; do
    rm -rf -- "$root/config/BUILD"
    cp -- "$fixtures/$conf" "$root/config/tmux.conf"
    check "build with $conf" exit_is 0 wp build --plan "$plan"
    check "[C10] up refuses with $conf" exit_is 1 wp up
    check "[C10] the refusal comes from the server's check" said "the binding expects 'off off'"
    check "[C10] no session was built" no_server
  done
}

t_down_removes_only_its_own() {
  check "build" exit_is 0 wp build --plan "$plan"
  check "up" exit_is 0 wp up
  T new-session -d -s bystander
  T new-session -d -s harbor-annex
  check "[C18] down" exit_is 0 wp down
  check "[C18] down removed the workplace and left the test's sessions" sessions_are "bystander harbor-annex "
  check "[C18] down removed RUN" test ! -e "$run"
  check "[C18] down kept BUILD" test -f "$root/config/BUILD/MANIFEST"
  check "[C21] status says down" exit_is 0 wp status
  check "[C21] status reports run: down" said "run: down"
  check "[C18] a second down has nothing to do" exit_is 0 wp down
  check "[C18] it says so" said "nothing is up"
  check "[C4] the workplace comes up again from the same build" exit_is 0 wp up
  check "[C18] and goes down again" exit_is 0 wp down
  check "[C18] the test's sessions are still alive" sessions_are "bystander harbor-annex "
}

t_down_when_a_session_was_replaced() {
  check "build" exit_is 0 wp build --plan "$plan"
  check "up" exit_is 0 wp up
  T kill-session -t =orchard
  T new-session -d -s orchard
  check "[C21] status exits 1 when a session is gone" exit_is 1 wp status
  check "[C21] status names it" said "gone        session/orchard"
  check "[C18] down" exit_is 0 wp down
  check "[C17] down left the stranger's orchard alone" sessions_are "orchard "
  check "[C17] down said why" said "undo session/orchard: it does not carry this run's mark, left alone"
}

t_down_after_the_server_restarted() {
  check "build" exit_is 0 wp build --plan "$plan"
  check "up" exit_is 0 wp up
  local first i
  first=$(T display -p -t =harbor: '#{session_id}')
  T kill-server
  for (( i = 0; i < 100; i++ )); do [[ -S $TMUX_TMPDIR/tmux-$UID/$label ]] || break; sleep 0.05; done
  T -f /dev/null new-session -d -s stranger
  check "the stranger now holds the id the workplace's first session had" \
    test "$(T display -p -t =stranger: '#{session_id}')" = "$first"
  check "[C18] down" exit_is 0 wp down
  check "[C17] down did not kill the stranger that reuses the id" sessions_are "stranger "
  check "[C17] down said it left it alone" said "undo session/harbor: it does not carry this run's mark, left alone"
}

t_without_bubblewrap() {
  local bin=$scratch/bin program
  mkdir -p -- "$bin"
  for program in bash env tmux jq mkdir cp rm sha256sum; do
    ln -s -- "$(command -v "$program")" "$bin/$program"
  done
  check "bwrap and realpath are not on the reduced PATH" test -z "$(PATH=$bin command -v bwrap realpath)"
  variant '.state.view = [] | .programs |= map(.plan |= map(select((if type == "object" then .term else . end)[0] != "resolve")))' "$scratch/open.json"
  check "[C5] a plan with no view and no resolve builds with only bash, env, tmux, jq, mkdir, cp, rm and sha256sum" \
    exit_is 0 env PATH="$bin" "$BASH" "$loop" build --plan "$scratch/open.json"
  check "[C5] and comes up" exit_is 0 env PATH="$bin" "$BASH" "$loop" up
  check "[C5] every seat runs" wait_for_probe "Orchard Picker" picker
  check "[C12] picker, now with no view, sees cellar" screen_has "Orchard Picker" "hidden cellar: seen"
  check "[C5] status with the same programs" exit_is 0 env PATH="$bin" "$BASH" "$loop" status
  check "[C5] down with the same programs" exit_is 0 env PATH="$bin" "$BASH" "$loop" down
  rm -rf -- "$root/config/BUILD"
  check "the plan with views builds" exit_is 0 env PATH="$bin" "$BASH" "$loop" build --plan "$plan"
  check "[C5] but does not come up without bubblewrap" exit_is 2 env PATH="$bin" "$BASH" "$loop" up
  check "[C5] the refusal names bwrap" said "this plan needs bwrap"
  check "[C5] no server was started" no_server
}

t_hostile_text() {
  local dir='ha#{pid}#(touch pwned-dir)rbor#[c;'
  mkdir -p -- "$root/$dir"
  variant 'def office: if type == "object" then .term |= office elif .[1] == "harbor" then .[1] = "har#{pid}bor" else . end;
    .programs |= map(.plan |= map(office))
    | .state.view |= map(if .key[0] == "harbor" then .key[0] = "har#{pid}bor" else . end)
    | .programs[1].plan[1][2:6] = ["to#(touch pwned-room)wer#[x];", "watch", "W#{pid}#(touch pwned-title)a##[b;", $dir]
    | .programs[7].plan = [{"term": ["start", "har#{pid}bor", "to#(touch pwned-room)wer#[x];", "watch", $dir,
        (["tools/probe", "watch", ";", "a;", "b\\;", "#{pid}", "", "-x", "x;y", "$(touch pwned-arg)", "#[fg=red]", "a##[b"] | tojson)],
        "unchecked": true}]' "$scratch/hostile.json" --arg dir "$dir"
  check "build" exit_is 0 wp build --plan "$scratch/hostile.json"
  check "up" exit_is 0 wp up
  check "[C7] the office's name is kept as written" sessions_are "har#{pid}bor orchard "
  check "[C7] the room's name is kept as written" \
    test "$(T list-windows -a -F '#{window_name}' | grep -c -xF 'to#(touch pwned-room)wer#[x];')" = 1
  local title='W#{pid}#(touch pwned-title)a##[b;'
  check "[C7] the title is kept as written" test -n "$(pane_by_title "$title")"
  check "watch ran" wait_for_probe "$title" watch
  check "[C7] watch started in the directory as written" screen_has "$title" "probe watch start cwd=$root/$dir seat="
  local arg
  for arg in ';' 'a;' 'b\;' '#{pid}' '' '-x' 'x;y' '$(touch pwned-arg)' '#[fg=red]' 'a##[b'; do
    check "[C7] the argument [$arg] arrives as written" screen_has "$title" "arg [$arg]"
  done
  check "[C6] no text of the plan ran as a command" test -z "$(find "$scratch" -name 'pwned-*' -print -quit)"
}

t_source_and_contract() {
  check "[C6] the loop holds no eval" bash -c '! grep -nw eval "$1"/bin/workplace "$1"/libexec/*' _ "$tool"
  check "[C6] the loop holds no sh -c or bash -c" \
    bash -c '! grep -nE "(^|[^[:alnum:]])(ba)?sh -c" "$1"/bin/workplace "$1"/libexec/* "$1"/host/binding.json' _ "$tool"
  check "[C15] nothing sends keys to a pane" bash -c '! grep -rn "send-keys" "$1"/bin "$1"/libexec "$1"/host' _ "$tool"
  check "[C15] every -t of the binding names a captured slot, never an index" \
    test "$(jq '[.primitives[] | (.call, .then, .undo.when, .undo.call, .check.call) | select(. != null) | . as $c
      | range(0; length) | select($c[.] == "-t") | $c[. + 1] | (type == "object" and has("slot"))] | all' "$tool/host/binding.json")" = true
  check "[C15] respawn-pane -k is followed by clear-history in start" \
    test "$(jq -r '.primitives.start.call | map(strings) | (index("respawn-pane") < index("clear-history"))' "$tool/host/binding.json")" = true
  check "[C22] every tmux call of the binding names its server" \
    test "$(jq -c '.programs.tmux.argv[1:3]' "$tool/host/binding.json")" = '["-L",{"slot":["server"]}]'
  check "[C22] the loop removes TMUX and TMUX_PANE before anything else" \
    test "$(sed -n 4p "$tool/bin/workplace")" = "unset TMUX TMUX_PANE"
  check "every tmux call of these tests names its server" \
    bash -c '! grep -nE "(^|[;&|({!]|\\\$\\()[[:space:]]*tmux " "$1" | grep -v "tmux -L"' _ "$here/run.sh"
  check "the tests run as a user, not root" test "$EUID" -ne 0
  check "nothing of the loop runs through sudo, doas or pkexec" \
    bash -c '! grep -rnwE "sudo|doas|pkexec" "$1"/bin "$1"/libexec "$1"/host' _ "$tool"
  check "bubblewrap is not setuid" test ! -u "$(command -v bwrap)"
  local n missing=""
  for n in $(grep -oE '\*\*C[0-9]+\.\*\*' "$tool/CONTRACT.md" | tr -d '*.'); do
    grep -qF "[$n]" "$here/run.sh" || missing+=" $n"
  done
  check "every sentence of the contract is shown by a check that carries its number${missing:+ (missing:$missing)}" test -z "$missing"
}

tests=(
  t_inputs_and_refusals
  t_program_floors
  t_structure_and_starts
  t_holding_panes
  t_a_foreign_tmux_in_the_environment
  t_seat_views
  t_a_row_of_three_and_a_grid
  t_failure_leaves_nothing
  t_unattached_options
  t_down_removes_only_its_own
  t_down_when_a_session_was_replaced
  t_down_after_the_server_restarted
  t_without_bubblewrap
  t_hostile_text
  t_source_and_contract
)
(( $# )) && tests=("$@")

for name in "${tests[@]}"; do
  note "== $name"
  (
    test_failed=0
    setup "${name#t_}"
    trap cleanup EXIT
    "$name"
    exit "$test_failed"
  )
  status=$?
  total=$(( total + 1 ))
  if (( status )); then
    failures=$(( failures + 1 ))
    failed_tests+=("$name")
  fi
done
note "== $(( total - failures )) of $total tests passed"
(( failures == 0 )) || { note "failed: ${failed_tests[*]}"; exit 1; }
