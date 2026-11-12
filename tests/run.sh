#!/usr/bin/env bash
export LC_ALL=C
set -o nounset -o pipefail
unset TMUX TMUX_PANE

here=$(cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
tool=${here%/tests}
loop=$tool/bin/workplace
fixtures=$here/fixtures
failures=0
total=0
skips=$(mktemp /tmp/wpt-skips.XXXXXX)
declare -a failed_tests=()

note() { printf '%s\n' "$*"; }
skip() {
  note "  SKIP: $*"
  printf '%s\n' "$*" >> "$skips"
}
fail() {
  note "  FAIL: $*"
  test_failed=1
}
check() {
  local message=$1
  shift
  if "$@"; then note "  ok: $message"; else fail "$message"; fi
}

T() { setpriv --no-new-privs tmux -L "$label" -u "$@"; }
start_a_server_without_no_new_privileges() { tmux -L "$label" -u -f /dev/null new-session -d -s "$1"; }
wp() { "$BASH" "$loop" "$@"; }

name_of_clone() {
  local sum
  sum=$(printf '%s' "$1" | sha256sum)
  printf '%s\n' "${1##*/}-${sum:0:12}"
}

make_clone() {
  local dir=$1
  mkdir -p -- "$dir/layers"
  cp -- "$fixtures/tmux.conf" "$dir/tmux.conf"
  cp -- "$fixtures/layers/structure.typify" "$fixtures/layers/access.typify" "$dir/layers/"
}

setup() {
  scratch=$(mktemp -d /tmp/wpt.XXXXXX)
  scratch=$(cd -P -- "$scratch" && pwd -P)
  export HOME=$scratch/home
  export TMUX_TMPDIR=$scratch/t
  mkdir -p -- "$HOME" "$TMUX_TMPDIR"
  root=$scratch/root
  mkdir -p -- "$root/tools" \
    "$root/harbor/ledger" "$root/harbor/charts" "$root/harbor/berth" "$root/harbor/vault/shelf" \
    "$root/harbor/scratch" "$root/harbor/hold" "$root/harbor/holdall" \
    "$root/orchard/cellar" "$root/orchard/almanac" "$root/orchard/crate-picker"
  printf '%s\n' secret > "$root/harbor/ledger/secret"
  printf '%s\n' secret > "$root/harbor/hold/secret"
  printf '%s\n' secret > "$root/orchard/cellar/secret"
  printf '%s\n' page > "$root/harbor/charts/page"
  printf '%s\n' page > "$root/harbor/scratch/page"
  printf '%s\n' page > "$root/orchard/almanac/page"
  cp -- "$fixtures/probe" "$root/tools/probe"
  clone=$root/config
  make_clone "$clone"
  export WORKPLACE_ROOT=$root
  export WORKPLACE_CONFIG=$clone
  cd -- "$scratch" || return 1
  label=$(name_of_clone "$clone")
  render "$label" > "$scratch/plan.json"
  run=$clone/BUILD/RUN
  local count
  count=$(env | grep -c '^TMUX=')
  [[ $count == 0 ]] || fail "TMUX is set in the test's environment ($count)"
}

render() {
  local name=$1 conf=${2:-$clone/tmux.conf} system=() path
  for path in /bin /sbin /lib /lib64; do [[ -e $path ]] && system+=("$path"); done
  jq --arg root "$root" --arg name "$name" --arg conf "$conf" --args '
    def put: if type == "string" then gsub("@ROOT@"; $root) | gsub("@LABEL@"; $name) else . end;
    walk(put)
    | (.programs[0].plan[0][2]) = $conf
    | .state.view += [$ARGS.positional[] | {key: ["orchard", "barn", "grower", .], value: ["read-only"], masked: false,
                                            origin: {kind: "program", path: "orchard/barn/grower/seat.typify", line: 10}}]
  ' "${system[@]}" < "$fixtures/plan.json"
}

collect_by_find() {
  local path type mode uid target
  for path in "$@"; do
    [[ -e $path || -L $path ]] || continue
    IFS=$'\t' read -r type mode uid target < <(find "$path" -maxdepth 0 -printf '%y\t%m\t%U\t%l\n')
    while (( ${#mode} < 4 )); do mode=0$mode; done
    printf '%s\t%s\t%s\n' exists "$path" ""
    [[ $type == d ]] && printf '%s\t%s\t%s\n' directory "$path" ""
    [[ $type == l ]] && printf '%s\t%s\t%s\n' symlink "$path" "$target"
    printf '%s\t%s\t%s\n' mode "$path" "$mode"
    printf '%s\t%s\t%s\n' owner "$path" "$uid"
  done
}

make_plan() {
  local into=${PLAN_CLONE:-$clone} filter=.
  local -a options=()
  if (( $# )); then filter=${!#}; options=("${@:1:$#-1}"); fi
  rm -rf -- "$into/BUILD"
  mkdir -p -- "$into/PLAN"
  local rendered
  rendered=$(jq "${options[@]}" "$filter" "$scratch/plan.json") || return 1
  printf '%s\n' "$rendered" > "$into/PLAN/plan.json"
  local -a paths
  mapfile -t paths < <(jq -r '
    def term: if type == "object" then .term else . end;
    ([.state.view[]?.key[3]]
     + [.programs[].plan[] | term | select(.[0] == "start") | .[4]]
     + [.programs[].plan[] | term | select(.[0] == "server") | .[2]]) | unique | .[]' "$into/PLAN/plan.json")
  paths+=("$root" "$root/tools/probe")
  collect_by_find "${paths[@]}" | jq -R -s --arg root "$root" '
    {collector: "find", root: $root,
     facts: (split("\n")[:-1] | map(split("\t") | {fact: .[0], args: [.[1]]} + (if .[0] | IN("exists", "directory") then {} else {value: .[2]} end)))}
  ' > "$into/PLAN/facts.json"
  local plan_sum facts_sum structure_sum access_sum
  facts_sum=$(sha256sum < "$into/PLAN/facts.json")
  if [[ ${FACTS_MEMBER-digest} == digest ]]; then
    jq --arg d "sha256:${facts_sum%% *}" '.facts = $d' <<< "$rendered" > "$into/PLAN/plan.json"
  fi
  plan_sum=$(sha256sum < "$into/PLAN/plan.json")
  structure_sum=$(sha256sum < "$into/layers/structure.typify")
  access_sum=$(sha256sum < "$into/layers/access.typify")
  jq -n --arg root "$root" --arg p "${plan_sum%% *}" --arg f "${facts_sum%% *}" \
    --arg s "${structure_sum%% *}" --arg a "${access_sum%% *}" '
    {root: $root, reader: "fixture", derivations: {"workplace-name": "sha256-path-prefix12-v1"},
     inputs: [{path: "layers/structure.typify", sha256: $s}, {path: "layers/access.typify", sha256: $a}],
     outputs: [{path: "plan.json", sha256: $p}, {path: "facts.json", sha256: $f}]}' > "$into/PLAN/manifest.json"
}

socket_dir_of() {
  local sum alphabet=ybndrfg8ejkmcpqxot1uwisza345h769 out="" i j chunk
  sum=$(printf '%s' "$1" | sha1sum)
  for (( i = 0; i < 30; i += 5 )); do
    chunk=$(( 16#${sum:i:5} ))
    for (( j = 15; j >= 0; j -= 5 )); do out+=${alphabet:$(( (chunk >> j) & 31 )):1}; done
  done
  printf '%s\n' "/run/user/$EUID/gnupg/d.$out"
}
agent_of() {
  local cmdline entry
  for entry in /proc/[0-9]*/cmdline; do
    cmdline=$(tr '\0' ' ' < "$entry" 2> /dev/null) || continue
    [[ $cmdline == *gpg-agent*"--homedir $1"[\ /]* ]] && return 0
  done
  return 1
}
no_agent_of() { ! agent_of "$1"; }
key_homes() {
  local home
  for home in "$scratch"/home/.local/state/workplace/*/keys/* "$scratch"/state-*/workplace/*/keys/* "$scratch"/verify; do
    [[ -d $home ]] && printf '%s\n' "$home"
  done
}
no_socket_dir_left() {
  local home left=""
  while IFS= read -r home; do
    [[ -e $(socket_dir_of "$home") ]] && left+=" ${home#"$scratch"/}"
  done < <(key_homes)
  [[ -z $left ]] || { note "    a runtime socket directory is left for:$left"; return 1; }
}

cleanup() {
  local home
  if command -v gpgconf > /dev/null; then
    while IFS= read -r home; do
      agent_of "$home" && gpgconf --homedir "$home" --kill gpg-agent > /dev/null 2>&1
      gpgconf --homedir "$home" --remove-socketdir > /dev/null 2>&1
    done < <(key_homes)
  fi
  if [[ $TMUX_TMPDIR == "$scratch"/* ]]; then
    tmux -S "$TMUX_TMPDIR/tmux-$UID/$label" kill-server 2> /dev/null
    [[ -n ${label2-} ]] && tmux -S "$TMUX_TMPDIR/tmux-$UID/$label2" kill-server 2> /dev/null
  fi
  rm -rf -- "$scratch"
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
  T capture-pane -p -J -S - -t "$id"
}

wait_for_line() {
  local title=$1 line=$2 i
  for (( i = 0; i < 120; i++ )); do
    if screen_of "$title" | grep -qxF -- "$line"; then return 0; fi
    sleep 0.05
  done
  return 1
}
wait_for_probe() { wait_for_line "$1" "probe $2 done"; }

screen_has() { screen_of "$1" | grep -qxF -- "$2"; }
eventually() {
  local i
  for (( i = 0; i < 60; i++ )); do
    "$@" && return 0
    sleep 0.05
  done
  return 1
}
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
nnp_of() {
  local line
  while IFS= read -r line; do
    [[ $line == NoNewPrivs:* ]] && { printf '%s\n' "${line//[[:space:]]/}"; return 0; }
  done < "/proc/$1/status"
}
up_fixture() {
  make_plan "$@" && wp build > "$scratch/out" 2>&1 && wp up >> "$scratch/out" 2>&1 \
    || { note "    build or up failed:"; sed 's/^/    | /' "$scratch/out"; return 1; }
}
seat_command() { jq -c --arg n "$1" 'select(.name == $n) | .command' "$run"/seats/*.json; }
view_ops() {
  jq -r '
    . as $c | ($c | index("--die-with-parent")) as $start | ($c | index("--chdir")) as $end
    | def walk_ops($i):
        if $i >= $end then empty
        elif $c[$i] == "--perms" then walk_ops($i + 2)
        elif $c[$i] == "--tmpfs" or $c[$i] == "--proc" or $c[$i] == "--dev" then "\($c[$i][2:]) \($c[$i + 1])", walk_ops($i + 2)
        elif $c[$i] == "--bind" or $c[$i] == "--ro-bind" then "\($c[$i][2:]) \($c[$i + 2])", walk_ops($i + 3)
        else "unknown \($c[$i])", walk_ops($i + 1) end;
      walk_ops($start + 1)' <<< "$1"
}

t_inputs_and_refusals() {
  check "[C1] status without WORKPLACE_ROOT exits 2" exit_is 2 env -u WORKPLACE_ROOT "$BASH" "$loop" status
  check "[C1] a relative WORKPLACE_ROOT exits 2" exit_is 2 env WORKPLACE_ROOT=root "$BASH" "$loop" status
  check "[C1] WORKPLACE_CONFIG outside the root exits 2" exit_is 2 env WORKPLACE_CONFIG="$scratch" "$BASH" "$loop" status
  check "[C2] build without PLAN/ exits 2 and names the file" exit_is 2 wp build
  check "[C2] the refusal names PLAN/plan.json" said "PLAN/plan.json is missing"
  check "[C2] build takes no arguments" exit_is 2 wp build --plan x
  make_plan '.programs[1].plan[0][0] = "summon"'
  check "[C3] a plan with an unknown primitive does not build" exit_is 1 wp build
  check "[C3] the refusal names the primitive" said "the binding has no primitive summon"
  check "[C2] the refused build left no BUILD" test ! -e "$clone/BUILD"
  make_plan '.programs[1].plan[0] += ["extra"]'
  check "[C3] a term with the wrong number of arguments does not build" exit_is 1 wp build
  make_plan '.status = "failed"'
  check "[C3] a plan whose status is failed does not build" exit_is 1 wp build
  make_plan '.programs[1].plan[0][2] = "Har\u0007bor"'
  check "[C3] a plan with a control character does not build" exit_is 1 wp build
  make_plan '.programs[6].plan[1].term[4] = "harbor"'
  check "[C4] a relative path in a term builds: the frame joins it to the root" exit_is 0 wp build
  make_plan '.state.view[1].key[3] = "harbor/holdall"'
  check "[C4] a relative path in a row builds" exit_is 0 wp build
  make_plan '.programs[6].plan[1].term[4] = "harbor//dock"'
  check "[C4] a relative path with an empty component is refused" exit_is 1 wp build
  check "[C4] naming the term and the path" said 'harbor/dock/keeper/seat.typify, term 2 (start): the path "harbor//dock" is refused: it has an empty component'
  make_plan '.state.view[1].key[3] = "./harbor/holdall"'
  check "[C4] a relative path with a . component is refused" exit_is 1 wp build
  check "[C4] naming the row's origin" said 'harbor/dock/keeper/seat.typify:11 (state view): the path "./harbor/holdall" is refused: it has a . or .. component'
  make_plan '.programs[0].plan[0][2] = "config/../config/tmux.conf"'
  check "[C4] a relative path with a .. component is refused" exit_is 1 wp build
  check "[C4] naming the server's term" said 'workplace.typify, term 1 (server): the path "config/../config/tmux.conf" is refused: it has a . or .. component'
  make_plan '.state.view[1].key[3] = "harbor/holdall/"'
  check "[C4] a relative path with a slash at its end is refused" exit_is 1 wp build
  check "[C4] saying so" said '(state view): the path "harbor/holdall/" is refused: it ends in a slash'
  make_plan '.state.view[0].value = ["open"]'
  check "[C3] a view row with an unknown state does not build" exit_is 1 wp build
  check "[C3] the refusal names the state" said "open is not one of"
  make_plan '.state.view[0].key |= .[0:3]'
  check "[C3] a view row whose key is not four strings does not build" exit_is 1 wp build
  make_plan '.state.view[0].key[2] = "nobody"'
  check "[C3] a row for a seat the plan does not make is refused" exit_is 1 wp build
  make_plan '.programs[7].plan[0][4] = "Harbor Keeper"'
  check "[C3] two seats of one name are refused" exit_is 1 wp build
  check "[C3] the refusal names the name" said "the name Harbor Keeper is given to 2"
  make_plan '.state.view |= map(select(.key[2] != "picker" or .key[3] != "/"))'
  check "[C12] a seat with rows and no row for / is refused" exit_is 1 wp build
  check "[C12] the refusal names the seat" said "the view of orchard/barn/picker has no row for /"
  make_plan --arg root "$root" '.state.view += [{key: ["orchard", "barn", "picker", ($root + "/orchard/cellar/inner")], value: ["read-write"]}]'
  mkdir -p -- "$root/orchard/cellar/inner"
  check "[C13] a row opened beneath a hidden row refuses the table whole" exit_is 1 wp build
  check "[C13] the refusal names both paths" said "$root/orchard/cellar/inner (read-write) lies beneath $root/orchard/cellar (hidden)"
  make_plan --arg root "$root" '.state.view += [{key: ["harbor", "dock", "keeper", ($root + "/harbor/nowhere")], value: ["read-write"]}]'
  check "[C4] a grant on a missing path is refused" exit_is 1 wp build
  check "[C4] the refusal names the path" said "a view grants $root/harbor/nowhere, which does not exist"
  make_plan
  check "[C2] the fixture builds" exit_is 0 wp build
  local name
  for name in plan.json plan-facts.json plan-manifest.json binding.json bin/workplace libexec/resolve.jq libexec/check.jq MANIFEST; do
    check "[C2] BUILD holds $name" test -f "$clone/BUILD/$name"
  done
  check "[C2] BUILD's plan is PLAN's plan, byte for byte" cmp -s "$clone/PLAN/plan.json" "$clone/BUILD/plan.json"
  check "[C2] a second build refuses while BUILD exists" exit_is 1 wp build
  rm -rf -- "$clone/BUILD"
  printf '%s\n' changed >> "$clone/layers/access.typify"
  check "[C2] a changed source is refused" exit_is 1 wp build
  check "[C2] the refusal names the source" said "the input $clone/layers/access.typify has changed"
  make_plan
  printf '%s\n' ' ' >> "$clone/PLAN/plan.json"
  check "[C2] a changed plan is refused" exit_is 1 wp build
  check "[C2] the refusal names the plan" said "the plan's file $clone/PLAN/plan.json has changed"
  make_plan
  jq --arg r "$scratch" '.root = $r' "$clone/PLAN/manifest.json" > "$scratch/m" && cp -- "$scratch/m" "$clone/PLAN/manifest.json"
  check "[C2] a plan of another root is refused" exit_is 1 wp build
  check "[C2] the refusal names the root" said "the plan belongs to the root $scratch"
  make_plan
  chmod 0700 -- "$root/harbor/berth"
  check "[C2] a differing fact is refused" exit_is 1 wp build
  check "[C2] the refusal names the fact" said "fact mode of $root/harbor/berth: the plan says 0755, the machine says 0700"
  FACTS_MEMBER=none make_plan
  chmod 0700 -- "$root/harbor/berth"
  check "[C2] a plan whose facts member is none compares no fact" exit_is 0 wp build
  chmod 0755 -- "$root/harbor/berth"
  make_plan
  printf '%s\n' ' ' >> "$clone/PLAN/facts.json"
  jq --arg s "$(sha256sum < "$clone/PLAN/facts.json" | cut -d' ' -f1)" '.outputs |= map(if .path == "facts.json" then .sha256 = $s else . end)' \
    "$clone/PLAN/manifest.json" > "$scratch/m" && cp -- "$scratch/m" "$clone/PLAN/manifest.json"
  check "[C2] a facts file that is not the one the plan was made on is refused" exit_is 1 wp build
  check "[C2] the refusal names the digest" said "PLAN/facts.json is not the facts file the plan was made on"
  make_plan
  check "[C2] the fixture builds" exit_is 0 wp build
  printf '%s\n' ' ' >> "$clone/BUILD/plan.json"
  check "[C5] up refuses a build whose plan differs from its manifest" exit_is 1 wp up
  check "[C5] the refusal names the file" said "plan.json does not match its MANIFEST"
  check "[C5] up says it never builds" said "never builds"
  check "[C5] the refused up made no server" no_server
  check "[C22] status reports the changed build and exits 1" exit_is 1 wp status
}

t_program_floors() {
  local bin=$scratch/old
  mkdir -p -- "$bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "tmux 3.5"' > "$bin/tmux"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "jq-1.6"' > "$bin/jq"
  chmod +x -- "$bin/tmux" "$bin/jq"
  make_plan
  check "build" exit_is 0 wp build
  mv -- "$bin/jq" "$bin/jq.off"
  check "[C6] tmux 3.5, older than the floor 3.5a by its letter, is refused with exit 2" exit_is 2 env PATH="$bin:$PATH" "$BASH" "$loop" up
  check "[C6] the refusal names both versions" said "tmux 3.5 found; 3.5a or later is needed"
  mv -- "$bin/jq.off" "$bin/jq"
  check "[C6] an older jq is refused with exit 2" exit_is 2 env PATH="$bin:$PATH" "$BASH" "$loop" status
  check "[C6] the refusal names both versions" said "jq 1.6 found; 1.7 or later is needed"
  check "[C6] the bash floor is in the source (no older bash is installed to run it)" \
    grep -qF '(( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 2) ))' "$loop"
  check "[C6] nothing was started" no_server
}

t_structure_and_order() {
  check "build and up" up_fixture
  check "[C8] the sessions are Harbor and Orchard" sessions_are "Harbor Orchard "
  check "[C8] the windows are Harbor:Dock, Harbor:Tower, Orchard:Barn" \
    test "$(T list-windows -a -F '#{session_name}:#{window_name}' | sort | tr '\n' ' ')" = "Harbor:Dock Harbor:Tower Orchard:Barn "
  check "[C9] every pane is a seat, and no other pane stands" \
    test "$(T list-panes -a -F '#{session_name}/#{window_name}/#{pane_title}' | sort | tr '\n' ',')" = \
    "Harbor/Dock/Harbor Keeper,Harbor/Dock/Harbor Pilot,Harbor/Tower/Harbor Watch,Orchard/Barn/Orchard Grower,Orchard/Barn/Orchard Picker,"
  local row title seat place
  for row in "Harbor Pilot:pilot:harbor" "Harbor Keeper:keeper:harbor" "Harbor Watch:watch:harbor" \
    "Orchard Grower:grower:orchard" "Orchard Picker:picker:orchard"; do
    IFS=: read -r title seat place <<< "$row"
    check "[C8] $title runs its program" wait_for_probe "$title" "$seat"
    check "[C8] $title started in its first directory" screen_has "$title" "probe $seat start cwd=$root/$place"
    check "[C17] $title's pane command is exec and the seat's name, and nothing else" \
      test "$(T display -p -t "$(pane_by_title "$title")" '#{pane_start_command}')" = "$BASH $clone/BUILD/bin/workplace exec -- \"$title\""
  done
  check "[C8] the calls followed the binding's order: server, sessions, windows, panes, arrangements, starts" \
    test "$(jq -r --argjson n "$(jq '.programs.tmux.argv | length' "$tool/host/binding.json")" '.[$n]' "$run/calls.jsonl" | tr '\n' ' ')" = \
    "start-server new-session set-option new-session set-option rename-window new-window rename-window display-message select-pane split-window select-pane display-message select-pane display-message select-pane split-window select-pane select-layout select-layout select-layout respawn-pane respawn-pane respawn-pane respawn-pane respawn-pane "
  check "[C8] the dock's seats stand side by side" \
    test "$(for t in "Harbor Pilot" "Harbor Keeper"; do T display -p -t "$(pane_by_title "$t")" '#{pane_top}'; done | sort -u | wc -l)" = 1
  check "[C8] no pane reaches past its window" \
    test -z "$(T list-panes -a -F '#{pane_top} #{pane_height} #{window_height} #{pane_left} #{pane_width} #{window_width}' | awk '$1 + $2 > $3 || $4 + $5 > $6')"
  local server
  server=$(T display -p '#{pid}')
  if [[ $(nnp_of $$) == NoNewPrivs:1 ]]; then
    skip "[C10] the server and a seat with no view report NoNewPrivs:1, but so would any process this shell starts; measured where the shell does not run under it"
  else
    check "[C10] the server runs under no-new-privileges" test "$(nnp_of "$server")" = "NoNewPrivs:1"
    check "[C10] a seat with no view runs under no-new-privileges" \
      test "$(nnp_of "$(T display -p -t "$(pane_by_title 'Harbor Watch')" '#{pane_pid}')")" = "NoNewPrivs:1"
  fi
  local mark
  mark=$(jq -r '.slots[(["run"] | tojson)]' "$run/state.json")
  check "[C11] each session carries the run's mark" \
    test "$(T show-options -qv -t =Harbor: @workplace) $(T show-options -qv -t =Orchard: @workplace)" = "$mark $mark"
  check "[C17] every start was followed by clearing its pane's history" \
    test "$(jq -c 'select(any(.[]; . == "respawn-pane")) | [.[] | select(. == "clear-history")] | length' "$run/calls.jsonl" | sort -u)" = 1
  check "[C22] status exits 0 with the workplace up" exit_is 0 wp status
  check "[C22] status lists every seat ok" test "$(grep -c '^ok      seat/' "$scratch/out")" = 5
  local name
  for name in calls.jsonl ledger checks slots.json state.json tables.json; do
    check "[C21] RUN holds $name" test -f "$run/$name"
  done
  check "[C21] RUN holds one recorded start per seat" test "$(ls "$run/seats" | wc -l)" = 5
  check "[C21] the learned pane ids are kept in RUN" \
    test "$(jq '[.[] | select(.slot[0] == "pane")] | length' "$run/slots.json")" = 5
  check "[C20] a second up refuses while the workplace is up" exit_is 1 wp up
  check "[C20] the refusal says it is up already" said "is up already"
}

t_a_foreign_tmux_in_the_environment() {
  T -f /dev/null new-session -d -s bystander
  T select-pane -t =bystander: -T Bystander
  T set-option -g @workplace-clone "$clone"
  local socket pane
  socket=$(T display -p -t =bystander: '#{socket_path},#{pid},#{session_id}')
  pane=$(T display -p -t =bystander: '#{pane_id}')
  make_plan
  check "build" exit_is 0 wp build
  check "[C10] up with TMUX and TMUX_PANE naming the bystander's pane" \
    exit_is 0 env TMUX="$socket" TMUX_PANE="$pane" "$BASH" "$loop" up
  check "[C10] every title landed on its own seat" \
    test "$(T list-panes -a -F '#{pane_title}' | sort | tr '\n' ',')" = "Bystander,Harbor Keeper,Harbor Pilot,Harbor Watch,Orchard Grower,Orchard Picker,"
  check "[C11] no run mark reached the bystander" test -z "$(T show-options -qv -t =bystander: @workplace)"
  check "[C10] down with the same environment" exit_is 0 env TMUX="$socket" TMUX_PANE="$pane" "$BASH" "$loop" down
  check "[C18] the bystander survives" sessions_are "bystander "
}

t_programs_out_of_order() {
  check "build and up, the programs reversed" up_fixture '.programs |= reverse'
  check "[C8] the same sessions" sessions_are "Harbor Orchard "
  check "[C8] the same seats" \
    test "$(T list-panes -a -F '#{session_name}/#{window_name}/#{pane_title}' | sort | tr '\n' ',')" = \
    "Harbor/Dock/Harbor Keeper,Harbor/Dock/Harbor Pilot,Harbor/Tower/Harbor Watch,Orchard/Barn/Orchard Grower,Orchard/Barn/Orchard Picker,"
  check "[C8] the server's term still came first" test "$(jq -r --argjson n "$(jq '.programs.tmux.argv | length' "$tool/host/binding.json")" '.[$n]' "$run/calls.jsonl" | head -1)" = start-server
  check "[C8] every seat runs" wait_for_probe "Orchard Picker" picker
}

t_room_of_eight() {
  check "build and up, the dock with eight seats" up_fixture --arg root "$root" '
    .programs += [range(1; 7) as $i | {path: "harbor/dock/deck\($i)/seat.typify", language: "Seat", status: "present",
      plan: [["pane", "harbor", "dock", "deck\($i)", "Deck \($i)"],
             {term: ["start", "harbor", "dock", "deck\($i)", ($root + "/harbor"), ([$root + "/tools/probe", "deck\($i)"] | tojson)], unchecked: true}],
      ensure: [], skips: [], recorded: []}]'
  check "[C9] the dock holds eight panes" test "$(T list-panes -t "$(jq -r '.slots[(["window", "harbor", "dock"] | tojson)]' "$run/state.json")" -F x | wc -l)" = 8
  check "[C9] the window is tmux's default size" \
    test "$(T display -p -t "$(jq -r '.slots[(["window", "harbor", "dock"] | tojson)]' "$run/state.json")" '#{window_width}x#{window_height}')" = 80x24
  check "[C9] no pane stands that is not a seat" test "$(T list-panes -a -F x | wc -l)" = 11
  check "[C8] no pane reaches past its window" \
    test -z "$(T list-panes -a -F '#{pane_top} #{pane_height} #{window_height} #{pane_left} #{pane_width} #{window_width}' | awk '$1 + $2 > $3 || $4 + $5 > $6')"
  check "[C8] the eighth seat runs" wait_for_probe "Deck 6" deck6
  check "[C8] the dock ends in its declared layout: eight panes on one line" \
    test "$(T list-panes -t "$(jq -r '.slots[(["window", "harbor", "dock"] | tojson)]' "$run/state.json")" -F '#{pane_top}' | sort -u | wc -l)" = 1
}

t_views() {
  check "build and up" up_fixture
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  check "[C14] hidden: keeper does not see ledger" screen_has "Harbor Keeper" "hidden ledger: unseen"
  check "[C14] no row: charts has its nearest ancestor's state, / read-only" screen_has "Harbor Keeper" "ro charts: read=ok write=refused"
  check "[C14] read-write: keeper writes berth" screen_has "Harbor Keeper" "rw berth: write=ok"
  check "[C14] that write went to the machine's berth: the same device and inode inside and out" \
    screen_has "Harbor Keeper" "where berth: $(stat -L -c %d:%i -- "$root/harbor/berth")"
  check "[C14] searchable-only: vault cannot be listed" screen_has "Harbor Keeper" "list vault: refused"
  check "[C14] searchable-only: the row beneath it, vault/shelf, is reachable" screen_has "Harbor Keeper" "reach vault/shelf: write=ok"
  check "[C14] scratch: an empty writable directory" screen_has "Harbor Keeper" "scratch scratch: entries=0 write=ok"
  check "[C14] scratch: it is not the machine's directory" \
    bash -c '[[ $1 == *"where scratch: "* && $1 != *"where scratch: $2"* ]]' _ "$(screen_of 'Harbor Keeper')" "$(stat -L -c %d:%i -- "$root/harbor/scratch")"
  check "[C13] /a against /ab: hold is hidden" screen_has "Harbor Keeper" "hidden hold: unseen"
  check "[C13] /a against /ab: holdall is open" screen_has "Harbor Keeper" "rw holdall: write=ok"
  check "[C15] keeper has its own PID namespace" bash -c '[[ $(grep -E "^pid " <<< "$1") =~ ^pid\ [0-9]\ procs\ [0-9]$ ]]' _ "$(screen_of 'Harbor Keeper')"
  local host_ns keeper_ns watch_ns
  host_ns="ns ipc $(stat -L -c %i /proc/self/ns/ipc) pid $(stat -L -c %i /proc/self/ns/pid)"
  keeper_ns=$(screen_of 'Harbor Keeper' | grep '^ns ')
  check "[C15] keeper has its own IPC namespace ($keeper_ns against $host_ns)" \
    bash -c '[[ -n $1 && ${1#ns ipc } != "${2#ns ipc }" && ${1% pid *} != "${2% pid *}" ]]' _ "$keeper_ns" "$host_ns"
  check "grower ran" wait_for_probe "Orchard Grower" grower
  check "[C14] searchable-only /: grower cannot list /" screen_has "Orchard Grower" "list /: refused"
  check "[C14] searchable-only /: what has no row does not exist" screen_has "Orchard Grower" "hidden ../harbor/ledger: unseen"
  check "[C14] searchable-only /: grower writes its read-write row" screen_has "Orchard Grower" "rw crate-picker: write=ok"
  check "pilot ran" wait_for_probe "Harbor Pilot" pilot
  check "[C14] a seat with no grant, / read-only: pilot sees ledger" screen_has "Harbor Pilot" "hidden ledger: seen"
  check "[C14] a seat with no grant: pilot cannot write berth" screen_has "Harbor Pilot" "rw berth: write=refused"
  check "watch ran" wait_for_probe "Harbor Watch" watch
  check "[C12] a seat with no rows starts without bubblewrap and writes charts" screen_has "Harbor Watch" "rw charts: write=ok"
  check "[C12] it has no PID namespace of its own" bash -c '! [[ $(grep -E "^pid " <<< "$1") =~ ^pid\ [0-9]\ procs ]]' _ "$(screen_of 'Harbor Watch')"
  check "[C12] it shares the host's IPC and PID namespaces" test "$(screen_of 'Harbor Watch' | grep '^ns ')" = "$host_ns"
  local expected
  expected="bind /
proc /proc
dev /dev
bind $root/harbor/berth
tmpfs $root/harbor/hold
bind $root/harbor/holdall
tmpfs $root/harbor/ledger
tmpfs $root/harbor/scratch
tmpfs $root/harbor/vault
bind $root/harbor/vault/shelf
tmpfs $clone"
  [[ -d /run/user/$EUID/gnupg ]] && expected+=$'\n'"tmpfs /run/user/$EUID/gnupg"
  expected+=$'\n'"tmpfs $HOME/.local/state/workplace"
  check "[C12] keeper's view: / first, then /proc and /dev, then the rows in byte order, then the frame's masks (C39, C52)" \
    test "$(view_ops "$(seat_command 'Harbor Keeper')" | sed 's/^ro-bind /bind /')" = "$expected"
  check "[C12] bwrap is named by its absolute path" \
    test "$(jq -r '.[0]' <<< "$(seat_command 'Harbor Keeper')")" = "$(command -v bwrap)"
  check "[C12] watch's command has no bubblewrap" test "$(jq -r '.[0]' <<< "$(seat_command 'Harbor Watch')")" = "$root/tools/probe"
  check "picker ran" wait_for_probe "Orchard Picker" picker
  check "the probes removed every file they wrote" test -z "$(find "$root" -name 'probe-*' -print -quit)"
}

relative_filter='
  def rel: if . == $root then "." elif startswith($root + "/") then .[($root | length) + 1:] else . end;
  def relterm:
    if .[0] == "server" then .[2] |= rel
    elif .[0] == "start" then (.[4] |= rel) | (.[5] |= (fromjson | .[0] |= rel | tojson))
    else . end;
  .programs[].plan[] |= (if type == "object" and has("term") then .term |= relterm else relterm end)
  | .state.view |= map(.key[3] |= rel)'
dot_row='.state.view += [{key: ["harbor", "dock", "pilot", $root], value: ["read-only"], masked: false,
                          origin: {kind: "program", path: "harbor/dock/pilot/seat.typify", line: 20}}]'
seats_as_built() { jq -c '{name, key, directory, command, environment}' "$run"/seats/*.json | sort; }

t_relative_paths() {
  FACTS_MEMBER=none up_fixture --arg root "$root" "$dot_row" || { fail "the plan written absolute does not stand"; return; }
  seats_as_built > "$scratch/seats-absolute"
  check "keeper ran, from the plan written absolute" wait_for_probe "Harbor Keeper" keeper
  wp down > /dev/null 2>&1
  FACTS_MEMBER=none up_fixture --arg root "$root" "$dot_row | $relative_filter" || { fail "[C4] the plan written relative to the root does not stand"; return; }
  check "[C4] the plan holds its paths as written" \
    test "$(jq -r '[.programs[].plan[] | if type == "object" then .term else . end | select(.[0] == "start") | .[4]] | unique | join(" ")' "$clone/BUILD/plan.json")" = "harbor orchard"
  seats_as_built > "$scratch/seats-relative"
  check "[C4] every seat's directory, view, program and environment equal those of the plan written absolute" \
    cmp -s "$scratch/seats-absolute" "$scratch/seats-relative"
  check "[C4] the seat's directory is joined" test "$(jq -r 'select(.name == "Harbor Keeper") | .directory' "$run"/seats/*.json)" = "$root/harbor"
  check "[C4] a relative program is joined" test "$(seat_command "Harbor Keeper" | jq -r '.[index("--") + 1]')" = "$root/tools/probe"
  check "[C4] . is the root: a row written . binds the root, and no /. is made" \
    bash -c '[[ $1 == *"\"--ro-bind\",\"$2\",\"$2\""* && $1 != *"/.\""* ]]' _ "$(seat_command "Harbor Pilot")" "$root"
  check "[C4] the server's configuration is joined in every tmux call" \
    test "$(grep -c -F -- "\"-f\",\"$clone/tmux.conf\"" "$run/calls.jsonl")" = "$(grep -c '' "$run/calls.jsonl")"
  check "[C4] keeper ran, from the plan written relative" wait_for_probe "Harbor Keeper" keeper
  check "[C4] in its view: ledger hidden, holdall writable" \
    bash -c 'grep -qxF "hidden ledger: unseen" <<< "$1" && grep -qxF "rw holdall: write=ok" <<< "$1"' _ "$(screen_of "Harbor Keeper")"
  wp why "Harbor Keeper" "$root/harbor/holdall" > "$scratch/out" 2>&1
  check "[C4] why prints the path as written beside the joined one" said "the row's path is written harbor/holdall and joined to $root/harbor/holdall"
  wp why "Harbor Keeper" "/" > "$scratch/out" 2>&1
  check "[C4] and nothing more where they are the same" bash -c '! grep -q "is written" "$1"' _ "$scratch/out"
  wp down > /dev/null 2>&1
}

t_environment() {
  export WORKPLACE_LEAK=yes
  check "build and up with WORKPLACE_LEAK in the loop's environment" up_fixture
  unset WORKPLACE_LEAK
  check "[C16] the variable reached the server" test "$(T show-environment -g WORKPLACE_LEAK)" = "WORKPLACE_LEAK=yes"
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  local env_line allowed name extra=""
  env_line=$(screen_of "Harbor Keeper" | grep '^env ')
  check "[C16] keeper printed its environment" test -n "$env_line"
  allowed=" $(jq -r '.inherit | join(" ")' "$tool/host/binding.json") GREETING PROBE_SEAT "
  check "[C16] it does not reach keeper" bash -c '[[ $1 != *WORKPLACE_LEAK* ]]' _ "$env_line"
  check "[C16] keeper receives its rows" bash -c '[[ " $1 " == *" GREETING "* && " $1 " == *" PROBE_SEAT "* ]]' _ "$env_line"
  check "[C16] a row's value arrives as written" screen_has "Harbor Keeper" "value GREETING=hello, harbor"
  check "[C16] keeper receives no TMUX, TMUX_PANE or WORKPLACE variable" bash -c '[[ $1 != *TMUX* && $1 != *WORKPLACE* ]]' _ "$env_line"
  for name in ${env_line#env }; do [[ $allowed == *" $name "* ]] || extra+=" $name"; done
  check "[C16] keeper receives nothing but the inherited names and its rows ($env_line)" test -z "$extra"
  check "watch ran" wait_for_probe "Harbor Watch" watch
  local watch_line
  watch_line=$(screen_of 'Harbor Watch' | grep '^env ')
  check "[C16] watch printed its environment" test -n "$watch_line"
  check "[C16] watch, with no rows, receives only inherited names" \
    bash -c '[[ $1 != *PROBE_SEAT* && $1 != *GREETING* && $1 != *WORKPLACE* ]]' _ "$watch_line"
}

t_exec_by_hand() {
  check "build and up" up_fixture
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  check "[C17] exec --print prints the call" exit_is 0 wp exec --print "Harbor Keeper"
  check "[C17] the call starts with env -i" test "$(jq -r '.[0:2] | map(split("/") | last) | join(" ")' "$scratch/out")" = "env -i"
  check "[C17] and runs bubblewrap" test "$(jq -r '[.[] | select(endswith("/bwrap"))] | length' "$scratch/out")" = 1
  local pane_lines hand_lines hand_env
  pane_lines=$(screen_of "Harbor Keeper" | grep -vE '^(pid |env |ns |where scratch: |$)')
  local -a same=()
  local name value
  for name in TERM COLORTERM LANG HOME USER LOGNAME PATH; do
    value=$(T show-environment -g "$name" 2> /dev/null) && [[ $value == "$name="* ]] && same+=("$value")
  done
  [[ " ${same[*]} " == *" TERM="* ]] || same+=("TERM=$(T show-options -gv default-terminal)")
  hand_lines=$(cd / && env -i "${same[@]}" WORKPLACE_ROOT="$root" WORKPLACE_CONFIG="$clone" WORKPLACE_LEAK=yes \
    "$BASH" "$loop" exec "Harbor Keeper" < /dev/null 2>&1)
  hand_env=$(grep '^env ' <<< "$hand_lines")
  hand_lines=$(grep -vE '^(pid |env |ns |where scratch: |$)' <<< "$hand_lines")
  check "[C17] exec by hand, from another directory, gives the pane's view" test "$pane_lines" = "$hand_lines"
  [[ $pane_lines == "$hand_lines" ]] || diff <(printf '%s\n' "$pane_lines") <(printf '%s\n' "$hand_lines") | sed 's/^/    | /'
  check "[C17] and, given the pane's inherited names, the pane's environment ($hand_env)" \
    test "$hand_env" = "$(screen_of 'Harbor Keeper' | grep '^env ')"
  printf '%s\n' ' ' >> "$clone/BUILD/binding.json"
  check "[C17] exec refuses a changed build" exit_is 2 wp exec "Harbor Keeper" < /dev/null
  check "[C17] the refusal says so" said "exec starts a seat only from a verified build"
  check "[C17] exec of an unknown seat exits 2" exit_is 2 wp exec -- "Nobody"
  check "[C18] down" exit_is 0 wp down
  check "[C17] exec with nothing up exits 2" exit_is 2 wp exec "Harbor Keeper"
}

t_fixed_part() {
  check "build and up, keeper measuring its terminal" up_fixture --arg root "$root" '
    (.programs[6].plan[1].term[5]) = ([$root + "/tools/probe", "keeper", ("report=" + $root + "/harbor/berth/report"), ("term=" + $root + "/harbor/berth/other")] | tojson)'
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  T display -p -t "$(pane_by_title 'Harbor Pilot')" '#{pane_tty}' > "$root/harbor/berth/other"
  local i
  for (( i = 0; i < 100; i++ )); do grep -q "term done" "$root/harbor/berth/report" 2> /dev/null && break; sleep 0.1; done
  check "[C15] /dev/tty opens with a private /dev" grep -qx "term /dev/tty: open" "$root/harbor/berth/report"
  check "[C15] the terminal's size can be read" grep -qx "term stty: ok" "$root/harbor/berth/report"
  check "[C15] job control: a job stops" grep -qx "term job stopped: yes" "$root/harbor/berth/report"
  check "[C15] job control: fg brings it back" grep -qx "term fg: ok" "$root/harbor/berth/report"
  check "[C15] another pane's terminal cannot be written" grep -qx "term other pane: refused" "$root/harbor/berth/report"
  check "[C15] nothing reached the other pane" bash -c '[[ $1 != *other-pane-write-mark* ]]' _ "$(screen_of 'Harbor Pilot')"
  sleep 0.3
  check "[C15] a full-screen program switches to the alternate screen" \
    test "$(T display -p -t "$(pane_by_title 'Harbor Keeper')" '#{alternate_on}')" = 1
}

t_server_privilege() {
  if [[ $(nnp_of $$) == NoNewPrivs:1 ]]; then
    skip "[C10] this shell already runs under no-new-privileges, so no server it starts can lack it; measured where the shell does not"
    return 0
  fi
  make_plan
  check "build" exit_is 0 wp build
  start_a_server_without_no_new_privileges bystander
  T set-option -g @workplace-clone "$clone"
  check "[C10] up refuses a running server without no-new-privileges" exit_is 1 wp up
  check "[C10] the refusal says why" said "runs without no-new-privileges; it is refused"
  check "[C10] no session was built, and the bystander survives" sessions_are "bystander "
}

t_failure_leaves_nothing() {
  make_plan '.programs[2].plan[0][2] = "Harbor"'
  check "build of a plan whose second session's name is taken" exit_is 0 wp build
  check "[C19] up exits 1 when a primitive fails" exit_is 1 wp up
  check "[C19] the failure names the term" said "orchard/office.typify, term 1"
  check "[C19] nothing of the workplace is left, and no server" no_server
  check "[C19] no RUN is left" test ! -e "$run"
  mkdir -p -- "$root/orchard/gone"
  make_plan --arg root "$root" '.programs[10].plan[1].term[4] = ($root + "/orchard/gone")'
  check "build of a plan whose last seat starts in a directory that will be removed" exit_is 0 wp build
  rmdir -- "$root/orchard/gone"
  T -f /dev/null new-session -d -s bystander
  T set-option -g @workplace-clone "$clone"
  check "[C19] up exits 1 at the last start" exit_is 1 wp up
  check "[C19] the failure names the directory" said "$root/orchard/gone is not a directory"
  check "[C19] every session it made is torn down, by its captured id" said "undo session/harbor: done"
  check "[C19] the test's own session survives" sessions_are "bystander "
  check "[C19] no RUN is left" test ! -e "$run"
}

t_failure_between_a_session_and_its_mark() {
  local wrap=$scratch/wrap real
  real=$(command -v tmux)
  mkdir -p -- "$wrap"
  printf '%s\n' '#!/usr/bin/env bash' \
    'setting=0 marking=0' \
    'for word in "$@"; do [[ $word == set-option ]] && setting=1; [[ $word == @workplace ]] && marking=1; done' \
    'if (( setting && marking )); then printf "%s\n" "the test refuses to set the mark" >&2; exit 1; fi' \
    "exec ${real@Q} \"\$@\"" > "$wrap/tmux"
  chmod +x -- "$wrap/tmux"
  make_plan
  check "build" exit_is 0 wp build
  check "[C19] up exits 1 when a session is made and its mark cannot be set" exit_is 1 env PATH="$wrap:$PATH" "$BASH" "$loop" up
  check "[C19] the failure names the term" said "harbor/office.typify, term 1"
  check "[C19] and the mark's refusal" said "the test refuses to set the mark"
  check "[C19] the session made before its mark is torn down by its captured id" said "undo session/harbor: done"
  check "[C19] nothing of the workplace is left, and no server" eventually no_server
  check "[C19] no RUN is left" test ! -e "$run"
}

t_unattached_options() {
  local conf
  for conf in tmux-destroy-unattached.conf tmux-exit-unattached.conf tmux-exit-empty-off.conf; do
    rm -rf -- "$clone/BUILD" "$clone/PLAN"
    cp -- "$fixtures/$conf" "$clone/tmux.conf"
    make_plan
    check "build with $conf" exit_is 0 wp build
    check "[C11] up refuses with $conf" exit_is 1 wp up
    check "[C11] the refusal comes from the server's check" said "where the binding requires"
    check "[C11] no session was built" test -z "$(T list-sessions -F x 2> /dev/null)"
    if [[ $conf == tmux-exit-empty-off.conf ]]; then
      local socket=$TMUX_TMPDIR/tmux-$UID/$label
      check "[C11] the refusal names the empty server it leaves and the command that ends it" \
        said "the tmux server at $socket is left running with no session, and the loop never ends a server; to end it: tmux -S ${socket@Q} kill-server"
      check "[C11] that command ends it" tmux -S "$socket" kill-server
      check "[C11] and no server is left" no_server
    else
      check "[C11] a server that ends itself is not named" bash -c '! grep -q "is left running" "$1"' _ "$scratch/out"
    fi
  done
}

t_down_removes_only_its_own() {
  check "build and up" up_fixture
  T new-session -d -s bystander
  T new-session -d -s Harbor-annex
  check "[C18] down" exit_is 0 wp down
  check "[C18] down undid the sessions newest first" \
    test "$(grep -o 'undo session/[a-z]*' "$scratch/out" | tr '\n' ' ')" = "undo session/orchard undo session/harbor "
  check "[C18] down removed the workplace and left the test's sessions" sessions_are "Harbor-annex bystander "
  check "[C18] down removed RUN" test ! -e "$run"
  check "[C18] down kept BUILD" test -f "$clone/BUILD/MANIFEST"
  check "[C22] status says down" exit_is 0 wp status
  check "[C22] status reports run: down" said "run: down"
  check "[C18] a second down has nothing to do" exit_is 0 wp down
  check "[C18] it says so" said "nothing is up"
}

t_status_and_down_on_a_damaged_run() {
  check "build and up" up_fixture
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  T kill-pane -t "$(pane_by_title 'Harbor Keeper')"
  check "[C22] status exits 1 when a seat is gone" exit_is 1 wp status
  check "[C22] status names the seat" said "gone    seat/Harbor Keeper"
  check "[C22] and the others ok" said "ok      seat/Harbor Pilot"
  local elsewhere=$scratch/other-tmp
  mkdir -p -- "$elsewhere"
  check "[C18] down from a shell that reaches another socket refuses" exit_is 2 env TMUX_TMPDIR="$elsewhere" "$BASH" "$loop" down
  check "[C18] the refusal names both sockets" said "tmux from this shell would reach $elsewhere"
  check "[C18] and RUN is kept" test -d "$run"
  check "[C18] down from the right shell" exit_is 0 wp down
}

t_down_after_the_server_restarted() {
  check "build and up" up_fixture
  local first i
  first=$(T display -p -t =Harbor: '#{session_id}')
  T kill-server
  for (( i = 0; i < 100; i++ )); do [[ -S $TMUX_TMPDIR/tmux-$UID/$label ]] || break; sleep 0.05; done
  T -f /dev/null new-session -d -s stranger
  check "the stranger now holds the id the workplace's first session had" \
    test "$(T display -p -t =stranger: '#{session_id}')" = "$first"
  check "[C53] status exits 1 for a server that is not the run's" exit_is 1 wp status
  check "[C53] telling a new process with no mark from the run's own" said "is process $(T display -p '#{pid}'), not the run's $(jq -r '.slots[(["server-pid"] | tojson)]' "$run/state.json") one, and carries no mark"
  check "[C18] down" exit_is 0 wp down
  check "[C18] down did not kill the stranger that reuses the id" sessions_are "stranger "
  check "[C18] down said it left it alone" said "undo session/harbor: it does not carry this run's mark, left alone"
}

t_two_workplaces() {
  check "build and up the first" up_fixture
  local second=$root/config2
  make_clone "$second"
  label2=$(name_of_clone "$second")
  check "[C25] the two workplaces carry different names ($label, $label2)" test "$label" != "$label2"
  render "$label2" "$second/tmux.conf" > "$scratch/plan2.json"
  cp -- "$scratch/plan2.json" "$scratch/plan.json"
  PLAN_CLONE=$second make_plan
  check "[C25] build and up the second" bash -c 'WORKPLACE_CONFIG=$1 "$BASH" "$2" build && WORKPLACE_CONFIG=$1 "$BASH" "$2" up' _ "$second" "$loop"
  check "[C25] each has its own server" \
    test "$(tmux -L "$label2" list-sessions -F '#{session_name}' | sort | tr '\n' ' ')" = "Harbor Orchard "
  check "[C25] down the first" exit_is 0 wp down
  check "[C25] the first is gone" no_server
  check "[C25] the second stands" test "$(tmux -L "$label2" list-panes -a -F x | wc -l)" = 5
  check "[C25] down the second" bash -c 'WORKPLACE_CONFIG=$1 "$BASH" "$2" down' _ "$second" "$loop"
}

t_the_default_name() {
  render default > "$scratch/plan.json"
  label=default
  make_plan
  jq 'del(.derivations)' "$clone/PLAN/manifest.json" > "$scratch/manifest" && cp -- "$scratch/manifest" "$clone/PLAN/manifest.json"
  check "[C25] a plan whose server term says default builds, with no rule for the name" exit_is 0 wp build
  check "[C25] and comes up" exit_is 0 wp up
  check "[C25] its server is tmux's default socket under this test's own TMUX_TMPDIR" test -S "$TMUX_TMPDIR/tmux-$UID/default"
  check "[C25] the seats run there" wait_for_probe "Harbor Watch" watch
  check "[C25] down" exit_is 0 wp down
}

t_structure_and_form_refusals() {
  make_plan '.programs[2].plan += [["session", "orchard", "Orchard Again"]]'
  check "[C3] a second session for one office is refused" exit_is 1 wp build
  check "[C3] the refusal names it" said "the plan holds 2 session terms for orchard"
  make_plan '.programs[5].plan |= map(select(.[0] != "window"))'
  check "[C3] a room with panes and no window is refused" exit_is 1 wp build
  check "[C3] the refusal names the pane's missing window" said "the pane term for orchard/barn has no window term"
  make_plan '.programs |= map(select(.path | IN("orchard/barn/grower/seat.typify", "orchard/barn/picker/seat.typify") | not))
    | .state.view |= map(select(.key[1] != "barn")) | .state.environment |= map(select(.key[1] != "barn"))'
  check "[C3] a room with no seat is refused" exit_is 1 wp build
  check "[C3] the refusal names it" said "the window term for orchard/barn has no pane term"
  make_plan '.programs |= map(select(.path | startswith("orchard/barn") | not))
    | .state.view |= map(select(.key[0] != "orchard")) | .state.environment |= map(select(.key[0] != "orchard"))'
  check "[C3] an office with no room is refused" exit_is 1 wp build
  check "[C3] the refusal names it" said "the session term for orchard has no window term"
  make_plan '.programs[7].plan |= map(select(type == "array"))'
  check "[C3] a pane with no start is refused" exit_is 1 wp build
  check "[C3] the refusal names it" said "the pane term for harbor/dock/pilot has no start term"
  make_plan '.programs[0].plan += [.programs[0].plan[0]]'
  check "[C3] two server terms are refused" exit_is 1 wp build
  make_plan '.programs[3].plan[1][3] = "spiral"'
  check "[C3] an unknown layout is refused at build" exit_is 1 wp build
  check "[C3] the refusal names it" said "spiral is not one of"
  make_plan '.programs[7].plan[1].term[5] = (["tools/probe", "pilot"] | tojson)'
  check "[C4] a relative program with a slash builds: the frame joins it to the root" exit_is 0 wp build
  make_plan '.programs[7].plan[1].term[5] = (["./tools/probe", "pilot"] | tojson)'
  check "[C4] a relative program with a . component is refused at build" exit_is 1 wp build
  check "[C4] naming it" said 'harbor/dock/pilot/seat.typify, term 2 (start): the program "./tools/probe" is refused: it has a . or .. component'
  make_plan '.programs[7].plan[0][4] = "-x"'
  check "[C3] a seat whose name begins with - is refused" exit_is 1 wp build
  make_plan --arg root "$root" '.state.view[1].key[3] = ($root + "/harbor/holdall/")'
  check "[C4] a path with a trailing slash is refused" exit_is 1 wp build
  check "[C4] as ending in a slash" said "holdall/\" is refused: it ends in a slash"
  make_plan --arg root "$root" '.programs[7].plan[1].term[4] = ($root + "/harbor/../harbor")'
  check "[C4] a path with .. is refused" exit_is 1 wp build
  make_plan --arg root "$root" '.state.view += [{key: ["harbor", "dock", "keeper", ($root + "/harbor/charts/page")], value: ["hidden"]}]'
  check "[C4] a tmpfs state on a file is refused" exit_is 1 wp build
  check "[C4] the refusal names the path" said "a view makes $root/harbor/charts/page a tmpfs, and it is not a directory"
  make_plan
  jq '.outputs = []' "$clone/PLAN/manifest.json" > "$scratch/m" && cp -- "$scratch/m" "$clone/PLAN/manifest.json"
  check "[C2] a manifest whose outputs leave out the plan is refused" exit_is 1 wp build
  check "[C2] the refusal names what is missing" said "does not list plan.json facts.json among its outputs"
  make_plan
  jq --arg r "$scratch" '.root = $r' "$clone/PLAN/facts.json" > "$scratch/f" && cp -- "$scratch/f" "$clone/PLAN/facts.json"
  local digest
  digest=$(sha256sum < "$clone/PLAN/facts.json" | cut -d' ' -f1)
  jq --arg d "sha256:$digest" '.facts = $d' "$clone/PLAN/plan.json" > "$scratch/p" && cp -- "$scratch/p" "$clone/PLAN/plan.json"
  jq --arg p "$(sha256sum < "$clone/PLAN/plan.json" | cut -d' ' -f1)" --arg f "$digest" \
    '.outputs = [{path: "plan.json", sha256: $p}, {path: "facts.json", sha256: $f}]' "$clone/PLAN/manifest.json" > "$scratch/m" \
    && cp -- "$scratch/m" "$clone/PLAN/manifest.json"
  check "[C2] a facts file of another root is refused" exit_is 1 wp build
  check "[C2] the refusal names the root" said "the facts file belongs to the root $scratch"
  make_plan
  mv -- "$root/harbor/hold" "$root/harbor/hold.away"
  check "[C2] a path the facts record that is gone is refused" exit_is 1 wp build
  check "[C2] the refusal names the fact" said "fact exists of $root/harbor/hold: the plan says true, the machine has no such fact"
  mv -- "$root/harbor/hold.away" "$root/harbor/hold"
}

t_the_name_by_its_rule() {
  make_plan '.programs[0].plan[0][1] = "elsewhere-000000000000"'
  check "[C25] a plan whose server is not the name its clone gives is refused" exit_is 1 wp build
  check "[C25] the refusal names both names and the rule" \
    said "the plan names the workplace elsewhere-000000000000; by the rule sha256-path-prefix12-v1 its clone $clone gives $label"
  check "[C25] and no BUILD is left" test ! -e "$clone/BUILD"
  make_plan
  jq 'del(.derivations["workplace-name"])' "$clone/PLAN/manifest.json" > "$scratch/manifest" && cp -- "$scratch/manifest" "$clone/PLAN/manifest.json"
  check "[C25] a manifest that names no rule for the name is refused" exit_is 1 wp build
  check "[C25] the refusal says so" said "the manifest names no rule for the workplace's name"
  make_plan
  jq '.derivations["workplace-name"] = "md5-path-v0"' "$clone/PLAN/manifest.json" > "$scratch/manifest" && cp -- "$scratch/manifest" "$clone/PLAN/manifest.json"
  check "[C25] a rule the loop does not know is refused" exit_is 1 wp build
  check "[C25] the refusal names the rule" said "the manifest names the rule md5-path-v0 for the workplace's name, and this loop does not know it"
  make_plan
  check "[C25] the name by the rule builds" exit_is 0 wp build
  check "[C25] build reads the rule from the manifest" said "workplace-name sha256-path-prefix12-v1"
}

t_the_callers_locale() {
  local candidate other="" kind
  for candidate in de_DE.UTF-8 tr_TR.UTF-8 fr_FR.UTF-8 en_US.UTF-8 C.UTF-8; do
    [[ -z $(env LC_ALL="$candidate" "$BASH" -c : 2>&1) ]] || continue
    other=$candidate
    break
  done
  if [[ -z $other ]]; then
    skip "[C26] no locale but C is installed on this machine, so no other caller's locale can be tried"
    return 0
  fi
  kind=$(env LC_ALL="$other" stat --printf '%F' -- "$root")
  local in_locale=(env LC_ALL="$other" LANG="$other" "$BASH" "$loop")
  make_plan
  check "build under C" exit_is 0 wp build
  cp -- "$scratch/out" "$scratch/build-c"
  rm -rf -- "$clone/BUILD"
  check "[C26] build under the caller's locale $other, in which stat calls a directory a '$kind', with the facts compared" \
    exit_is 0 "${in_locale[@]}" build
  check "[C26] it prints what it prints under C, byte for byte" cmp -s "$scratch/build-c" "$scratch/out"
  check "why under C" exit_is 0 wp why "Harbor Keeper" "$root/harbor/charts/page"
  cp -- "$scratch/out" "$scratch/why-c"
  check "[C26] why under $other" exit_is 0 "${in_locale[@]}" why "Harbor Keeper" "$root/harbor/charts/page"
  check "[C26] prints what it prints under C" cmp -s "$scratch/why-c" "$scratch/out"
  check "[C26] up under $other" exit_is 0 "${in_locale[@]}" up
  check "[C26] the server's environment keeps the caller's locale" test "$(T show-environment -g LC_ALL)" = "LC_ALL=$other"
  check "[C26] status under $other" exit_is 0 "${in_locale[@]}" status
  check "[C26] down under $other" exit_is 0 "${in_locale[@]}" down
  export TMUX_TMPDIR=$scratch/sockets-ü
  mkdir -p -- "$TMUX_TMPDIR"
  check "[C26] up under C, where tmux's socket lies in a directory whose name is not ASCII" exit_is 0 wp up
  check "[C26] the run records the socket as it is" \
    test "$(jq -r '.slots[(["socket"] | tojson)]' "$run/state.json")" = "$TMUX_TMPDIR/tmux-$UID/$label"
  check "[C26] status finds it" exit_is 0 wp status
  check "[C26] down finds it" exit_is 0 wp down
}

t_without_bubblewrap() {
  local bin=$scratch/bin program
  mkdir -p -- "$bin"
  for program in bash env tmux jq mkdir cp rm sha256sum stat setpriv sort; do
    ln -s -- "$(command -v "$program")" "$bin/$program"
  done
  check "bwrap is not on the reduced PATH" test -z "$(PATH=$bin command -v bwrap)"
  make_plan '.state.view = []'
  check "[C6] a plan with no view builds with only bash, env, tmux, jq, mkdir, cp, rm, sha256sum, stat and setpriv, and sort for the probe" \
    exit_is 0 env PATH="$bin" "$BASH" "$loop" build
  check "[C6] and comes up" exit_is 0 env PATH="$bin" "$BASH" "$loop" up
  check "[C6] every seat runs" wait_for_probe "Orchard Picker" picker
  check "[C6] down with the same programs" exit_is 0 env PATH="$bin" "$BASH" "$loop" down
  rm -rf -- "$clone/BUILD"
  make_plan
  check "the plan with views builds" exit_is 0 env PATH="$bin" "$BASH" "$loop" build
  check "[C6] but does not come up without bubblewrap" exit_is 2 env PATH="$bin" "$BASH" "$loop" up
  check "[C6] the refusal names bwrap" said "this plan needs bwrap"
  check "[C6] no server was started" no_server
}

t_hostile_text() {
  local dir="$root/ha#{pid}#(touch pwned-dir)rbor#[c;"
  mkdir -p -- "$dir"
  local title='W#{pid}#(touch pwned-title)a##[b;'
  check "build and up with names, a title and a directory that tmux would expand or split" up_fixture --arg dir "$dir" --arg title "$title" --arg root "$root" '
    .programs[1].plan[0][2] = "Har#{pid}bor;"
    | .programs[4].plan[0][3] = "To#(touch pwned-room)wer#[x];"
    | .programs[8].plan = [["pane", "harbor", "tower", "watch", $title],
        {term: ["start", "harbor", "tower", "watch", $dir,
          ([$root + "/tools/probe", "watch", ";", "a;", "b\\;", "#{pid}", "", "-x", "x;y", "$(touch pwned-arg)", "#[fg=red]", "a##[b"] | tojson)],
         unchecked: true}]'
  check "[C7] the office's name is kept as written" sessions_are "Har#{pid}bor; Orchard "
  check "[C7] the room's name is kept as written" \
    test "$(T list-windows -a -F '#{window_name}' | grep -c -xF 'To#(touch pwned-room)wer#[x];')" = 1
  check "[C7] the title is kept as written" test -n "$(pane_by_title "$title")"
  check "watch ran" wait_for_probe "$title" watch
  check "[C7] watch started in the directory as written" screen_has "$title" "probe watch start cwd=$dir"
  local arg
  for arg in ';' 'a;' 'b\;' '#{pid}' '' '-x' 'x;y' '$(touch pwned-arg)' '#[fg=red]' 'a##[b'; do
    check "[C7] the argument [$arg] arrives as written" screen_has "$title" "arg [$arg]"
  done
  check "[C7] no text of the plan ran as a command" test -z "$(find "$scratch" -name 'pwned-*' -print -quit)"
}

t_why() {
  make_plan
  check "[C23] why answers for a row" exit_is 0 wp why "Harbor Keeper" "$root/harbor/berth"
  check "[C23] it names the row and its state" said "row: $root/harbor/berth read-write"
  check "[C23] it lists both claims behind the row" said "claims behind $root/harbor/berth: 2"
  check "[C23] with the losing claim's origin" said "read-only  from harbor/office.typify:2"
  check "[C23] and the winner's" said "read-write  from harbor/dock/keeper/seat.typify:4"
  check "[C23] a path with no row names its nearest ancestor's row" exit_is 0 wp why "Harbor Keeper" "$root/harbor/charts/page"
  check "[C23] the ancestor is /" said "its nearest ancestor's row is / read-only"
  check "[C23] a seat with no rows has no view" exit_is 0 wp why "Harbor Watch" /etc
  check "[C23] it says so" said "no view"
  check "[C23] why refuses a relative path" exit_is 2 wp why "Harbor Keeper" harbor
}

t_doctor() {
  check "[C24] doctor exits 0 on this machine" exit_is 0 wp doctor
  check "[C24] it checks setpriv" said "ok      no-new-privileges can be set"
  check "[C24] it checks bubblewrap's namespaces" said "with unprivileged user namespaces"
  local bin=$scratch/bin program
  mkdir -p -- "$bin"
  for program in bash env tmux jq mkdir cp rm sha256sum stat; do
    ln -s -- "$(command -v "$program")" "$bin/$program"
  done
  check "[C24] doctor exits 1 without setpriv" exit_is 1 env PATH="$bin" "$BASH" "$loop" doctor
  check "[C24] it names what is missing" said "missing setpriv"
  check "[C24] it says bubblewrap is needed only for a view" said "absent  bwrap: needed only by a plan in which a seat has a view"
}

shape_of() { find "$1" -path "$1/config/BUILD" -prune -o -printf '%y %m %s %P\n' | sort; }
tidy_reference() {
  local path
  while IFS= read -r path; do
    [[ ${path##*/} == probe-* && -f $path && ! -L $path ]] && rm -f -- "$path"
  done < <(comm -13 <(printf '%s\n' "$reference_paths") <(find "$reference_root" -path "$reference_root/config/BUILD" -prune -o -print | sort))
}
leave_reference() {
  [[ -n ${reference_root-} && -n ${reference_paths-} ]] || return 0
  tidy_reference
  rm -rf -- "$reference_root/config/BUILD"
  if [[ -n ${reference_plan-} && -d $reference_plan ]]; then
    rm -rf -- "$reference_root/config/PLAN" && cp -a -- "$reference_plan" "$reference_root/config/PLAN"
  fi
}

t_the_reference_plan_as_printed() {
  local pinned=fa8d54f683c2e4a80c24e3f7120f76fb42b51d720d7c5cb53c05f4a66d463cee sum reference=/tmp/workplace-reference-a4
  reference_root=$reference
  if [[ ! -f $reference/config/PLAN/plan.json ]]; then
    skip "[C8] the reference root of the layers' commit 1127c90 is not on this machine"
    return 0
  fi
  sum=$(sha256sum < "$reference/config/PLAN/plan.json")
  if [[ ${sum%% *} != "$pinned" ]]; then
    skip "[C8] the plan at $reference is not the reader's plan $pinned"
    return 0
  fi
  if [[ -e $reference/config/BUILD ]]; then
    skip "[C8] a BUILD already stands in $reference; this test makes and removes only its own"
    return 0
  fi
  export WORKPLACE_ROOT=$reference WORKPLACE_CONFIG=$reference/config
  clone=$reference/config
  run=$clone/BUILD/RUN
  label=$(jq -r '[.programs[].plan[] | (if type == "object" then .term else . end) | select(.[0] == "server")][0][1]' "$clone/PLAN/plan.json")
  reference_paths=$(find "$reference" -path "$reference/config/BUILD" -prune -o -print | sort)
  local shape
  shape=$(shape_of "$reference")
  trap 'leave_reference; cleanup' EXIT
  check "[C2] the reader's plan, as printed, builds" exit_is 0 wp build
  check "[C8] and comes up" exit_is 0 wp up
  check "[C9] its five seats stand, and no other pane" \
    test "$(T list-panes -a -F '#{session_name}/#{window_name}/#{pane_title}' | sort | tr '\n' ',')" = \
    "harbor/dock/Harbor Keeper,harbor/dock/Harbor Pilot,harbor/tower/Harbor Watch,orchard/barn/Orchard Grower,orchard/barn/Orchard Picker,"
  local row title seat
  for row in "Harbor Pilot:pilot" "Harbor Keeper:keeper" "Harbor Watch:watch" "Orchard Grower:grower" "Orchard Picker:picker"; do
    IFS=: read -r title seat <<< "$row"
    check "[C8] $title runs its program" wait_for_probe "$title" "$seat"
  done
  check "[C14] keeper: ledger, opened searchable-only, does not list" screen_has "Harbor Keeper" "hidden ledger: unseen"
  check "[C14] keeper: the grant beneath it is reachable" screen_has "Harbor Keeper" "reach ledger/inner: write=ok"
  check "[C14] keeper: charts is read-only" screen_has "Harbor Keeper" "ro charts: read=ok write=refused"
  check "[C14] picker: silo cannot be listed, its bin is reachable" \
    bash -c '[[ $1 == *"list silo: refused"* && $1 == *"reach silo/bin: write=ok"* ]]' _ "$(screen_of 'Orchard Picker')"
  check "[C22] status exits 0" exit_is 0 wp status
  check "[C23] why names the two claims behind keeper's ledger" exit_is 0 wp why "Harbor Keeper" "$reference/harbor/ledger"
  check "[C23] the losing claim, hidden, with its origin as written" said "hidden  from programs/ACCESS.typify:7"
  check "[C18] down" exit_is 0 wp down
  check "[C18] nothing of the workplace is left" no_server
  leave_reference
  check "[C8] the reference root is left as the test found it: every entry's type, mode and size" test "$(shape_of "$reference")" = "$shape"
}

scoped_clone() {
  export STUB_DIR=$scratch/stub
  mkdir -p -- "$STUB_DIR/bin" "$clone/programs"
  cp -- "$fixtures/typify-stub" "$STUB_DIR/bin/typify"
  printf '%s\n' 0.0-stub > "$STUB_DIR/version"
  printf '%s\n' '{"layers": ["layers/structure.typify", "layers/access.typify"]}' > "$clone/workplace.json"
  printf '%s\n' 'statement : / = read-only' > "$clone/programs/policy.typify"
}
path_without_reader() {
  local dir out=""
  local -a dirs
  IFS=: read -r -a dirs <<< "$PATH"
  for dir in "${dirs[@]}"; do [[ -x $dir/typify ]] || out+=${out:+:}$dir; done
  printf '%s\n' "$out"
}
wplan() { env PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan; }
statements_plan() {
  local filter=${1:-.}
  jq --arg root "$root" '
    def at($line): {kind: "program", line: $line, path: "programs/policy.typify"};
    def st($a; $b; $c; $scope; $path; $state; $line): {term: ["statement", $a, $b, $c, $scope, $path, $state], origin: at($line)};
    def cl($a; $b; $c; $scope; $n; $line): {term: ["clearance", $a, $b, $c, $scope, $n], origin: at($line)};
    def lb($path; $n; $line): {term: ["label", $path, $n], origin: at($line)};
    def kinds($rows): .state["seat-kinds"] = [$rows[] | {key: .[0:3], masked: false, origin: at(30), value: [.[3]]}];
    del(.state.view)
    | .facts = "none"
    | .programs |= map(.recorded |= ((. // []) | map(select(.term[0] != "claim"))))
    | .programs += [{path: "programs/policy.typify", language: "Access", status: "ok", plan: [], recorded: [
        st("-"; "-"; "-"; "workplace"; "/"; "read-only"; 1),
        st("harbor"; "-"; "-"; "office"; $root + "/harbor/ledger"; "hidden"; 2),
        st("harbor"; "dock"; "-"; "room"; $root + "/harbor/berth"; "read-write"; 3),
        st("harbor"; "dock"; "keeper"; "seat"; $root + "/harbor/vault"; "searchable-only"; 4),
        st("harbor"; "dock"; "keeper"; "seat"; $root + "/harbor/vault/shelf"; "read-write"; 5),
        st("harbor"; "dock"; "keeper"; "seat"; $root + "/harbor/scratch"; "scratch"; 6),
        st("harbor"; "dock"; "keeper"; "seat"; $root + "/harbor/hold"; "hidden"; 7),
        st("harbor"; "dock"; "keeper"; "seat"; $root + "/harbor/holdall"; "read-write"; 8)]}]
    | '"$filter" "$scratch/plan.json" > "$STUB_DIR/plan.json"
}
rows_of() { jq -r --arg s "$1" '.rows[] | select(.key[2] == $s) | "\(.key[3]) \(.value[0])"' "$clone/PLAN/view.json" | tr '\n' ','; }
seat_of() { jq -c --arg s "$1" ".seats[] | select(.seat[2] == \$s) | $2" "$clone/PLAN/view.json"; }

t_plan_assembles() {
  scoped_clone
  printf '%s\n' '#lang typify' 'stray : outside the tree' > "$clone/STRAY.typify"
  printf '%s\n' 'statement : /tmp = read-only' > "$clone/programs/back\\slash.typify"
  statements_plan
  check "[C27] plan, with the reader on the path" exit_is 0 wplan
  check "[C29] every input's hash is 64 hex digits, a name with a backslash too" \
    test "$(jq '[.inputs[].sha256 | test("^[0-9a-f]{64}$")] | all' "$clone/PLAN/manifest.json")" = true
  rm -- "$clone/programs/back\\slash.typify"
  check "plan again without it" exit_is 0 wplan
  check "[C27] the declarations are one header and each layer's body in workplace.json's order" \
    cmp -s "$STUB_DIR/declarations" <(printf '%s\n' '#lang typify'; tail -n +2 "$clone/layers/structure.typify"; tail -n +2 "$clone/layers/access.typify")
  check "[C27] the root program is exactly two lines: the root and the server" \
    cmp -s "$STUB_DIR/root-program" <(printf '%s\n' "workdir : $root" "server : $label : config/tmux.conf")
  check "[C27] the tree holds the generated root program and a copy of programs/, and no sibling of the root" \
    test "$(tr '\n' ' ' < "$STUB_DIR/tree")" = ". ./ROOT.typify ./programs ./programs/policy.typify "
  check "[C28] plan.json is the reader's output as printed" cmp -s "$STUB_DIR/plan.json" "$clone/PLAN/plan.json"
  check "[C29] PLAN/ holds plan.json, view.json and manifest.json" test "$(ls "$clone/PLAN" | tr '\n' ' ')" = "manifest.json plan.json view.json "
  local manifest=$clone/PLAN/manifest.json
  check "[C29] the manifest names the root, the name and the reader as it states its version" \
    test "$(jq -r '"\(.root) \(.name) \(.reader)"' "$manifest")" = "$root $label 0.0-stub"
  check "[C29] and each derivation's version" \
    test "$(jq -r '.derivations | keys | join(" ")' "$manifest")" = "assembly fold root-program workplace-name"
  check "[C29] the fold's version names the rules it follows" test "$(jq -r .derivations.fold "$manifest")" = frame-5.17-5.18-5.24-5.29-5.37-v4
  check "[C29] every input with its hash, in order: workplace.json, the layers, the programs, tmux.conf" \
    test "$(jq -r '[.inputs[] | "\(.path)=\(.sha256)"] | join(" ")' "$manifest")" = \
    "$(for f in workplace.json layers/structure.typify layers/access.typify programs/policy.typify tmux.conf; do s=$(sha256sum < "$clone/$f"); printf '%s ' "$f=${s%% *}"; done | sed 's/ $//')"
  local d r
  d=$(sha256sum < "$STUB_DIR/declarations")
  r=$(sha256sum < "$STUB_DIR/root-program")
  check "[C29] each generated file with the hash of what the reader was given" \
    test "$(jq -r '[.generated[] | "\(.path)=\(.sha256)"] | join(" ")' "$manifest")" = "LanguageDeclarations.typify=${d%% *} tree/ROOT.typify=${r%% *}"
  check "[C29] the source map gives each layer's interval" \
    test "$(jq -c '[.source_map[] | [.source, .source_start_line, .assembled_start_line, .line_count]]' "$manifest")" = \
    '[["layers/structure.typify",2,2,2],["layers/access.typify",2,4,2]]'
  check "[C29] the outputs, and not the manifest itself" test "$(jq -r '[.outputs[].path] | join(" ")' "$manifest")" = "plan.json view.json"
  check "[C29] build needs no reader" exit_is 0 wp build
  check "[C29] and builds the folded view" test -f "$clone/BUILD/plan-view.json"
  local built
  built=$(sha256sum < "$clone/BUILD/MANIFEST")
  check "[C28] plan never touches BUILD" exit_is 0 wplan
  check "[C28] BUILD is as it was" test "$(sha256sum < "$clone/BUILD/MANIFEST")" = "$built"
  rm -rf -- "$clone/BUILD"
  printf '%s\n' 'statement : /tmp = read-only' > "$clone/programs/late.typify"
  check "[C29] build refuses a program added after the plan" exit_is 1 wp build
  check "[C29] naming it" said "the clone holds the input programs/late.typify, which the manifest does not list"
  rm -- "$clone/programs/late.typify"
  jq '.generated[1].sha256 = ("0" * 64)' "$manifest" > "$scratch/m" && cp -- "$scratch/m" "$manifest"
  check "[C29] build refuses a generated file that differs from the manifest's" exit_is 1 wp build
  check "[C29] naming it" said "the generated tree/ROOT.typify is not the one the plan was made from"
  check "plan again" exit_is 0 wplan
  jq '.rows[0].value = ["read-write"]' "$clone/PLAN/view.json" > "$scratch/v" && cp -- "$scratch/v" "$clone/PLAN/view.json"
  jq --arg s "$(sha256sum < "$clone/PLAN/view.json" | cut -d' ' -f1)" '(.outputs[] | select(.path == "view.json") | .sha256) = $s' "$manifest" > "$scratch/m" \
    && cp -- "$scratch/m" "$manifest"
  check "[C29] build refuses a view.json that is not the fold of plan.json" exit_is 1 wp build
  check "[C29] naming the seat" said "PLAN/view.json is not the fold of PLAN/plan.json; it differs for harbor/dock/keeper"
  check "plan again" exit_is 0 wplan
  local moved=$root/moved
  cp -a -- "$clone" "$moved"
  check "[C29] build of the plan copied into another clone is refused" exit_is 1 env WORKPLACE_CONFIG="$moved" "$BASH" "$loop" build
  check "[C29] naming both names" said "the manifest names the workplace $label, and the clone assembles it as $(name_of_clone "$moved")"
  rm -rf -- "$moved"
  cp -- "$manifest" "$scratch/manifest-before"
  statements_plan '.programs[-1].recorded += [st("harbor"; "-"; "-"; "office"; $root + "/harbor/charts"; "read-only"; 9)]'
  check "plan a changed plan" exit_is 0 wplan
  cp -- "$scratch/manifest-before" "$manifest"
  check "[C29] build refuses a PLAN/ whose plan.json and view.json are new and whose manifest is not" exit_is 1 wp build
  check "[C29] naming plan.json" said "the plan's file $clone/PLAN/plan.json has changed since the plan was made"
  check "[C29] and view.json" said "the plan's file $clone/PLAN/view.json has changed since the plan was made"
  local failing=$scratch/failing-cp
  mkdir -- "$failing"
  printf '%s\n' '#!/usr/bin/env bash' '[[ ${!#} != */PLAN/manifest.json ]] || exit 1' "exec $(command -v cp) \"\$@\"" > "$failing/cp"
  chmod +x -- "$failing/cp"
  check "[C29] plan that cannot write manifest.json exits 2" exit_is 2 env PATH="$failing:$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
  check "[C29] saying PLAN/ is incomplete" said "PLAN/ is incomplete, run plan again"
  check "[C29] it wrote manifest.json last: the outputs are there and the manifest is not" \
    test "$(ls "$clone/PLAN" | tr '\n' ' ')" = "plan.json view.json "
  check "[C29] build refuses that PLAN/" exit_is 2 wp build
  check "[C29] naming the manifest" said "PLAN/manifest.json is missing"
  check "plan again" exit_is 0 wplan
  jq '.facts = "none"' "$scratch/plan.json" > "$STUB_DIR/plan.json"
  check "[C29] plan of a plan with no statement, clearance or label" exit_is 0 wplan
  check "[C29] removes the view.json that the plan before it wrote" test "$(ls "$clone/PLAN" | tr '\n' ' ')" = "manifest.json plan.json "
  check "[C29] and lists plan.json alone among the outputs" test "$(jq -r '[.outputs[].path] | join(" ")' "$manifest")" = "plan.json"
  printf '%s\n' '{"layers": ["layers/structure.typify", "layers/access.typify"], "socket": "default"}' > "$clone/workplace.json"
  statements_plan '.programs[0].plan[0][1] = "default"'
  check "[C25] plan with socket default" exit_is 0 wplan
  check "[C25] the root program names the server default" test "$(sed -n 2p "$STUB_DIR/root-program")" = "server : default : config/tmux.conf"
  check "[C25] and the manifest's name is default" test "$(jq -r .name "$manifest")" = default
}

t_plan_refusals() {
  scoped_clone
  statements_plan
  check "plan" exit_is 0 wplan
  local before
  before=$(cat "$clone/PLAN/manifest.json")
  cp -- "$clone/layers/access.typify" "$scratch/access"
  printf '\xef\xbb\xbf' | cat - "$scratch/access" > "$clone/layers/access.typify"
  check "[C27] a layer with a byte-order mark is refused with exit 2" exit_is 2 wplan
  check "[C27] naming it" said "the layer layers/access.typify begins with a byte-order mark"
  sed 's/$/\r/' "$scratch/access" > "$clone/layers/access.typify"
  check "[C27] a layer with CR line ends is refused with exit 2" exit_is 2 wplan
  check "[C27] naming it" said "the layer layers/access.typify has CR line ends"
  cp -- "$scratch/access" "$clone/layers/access.typify"
  printf 'statement : / = read-only\r\n' > "$clone/programs/crlf.typify"
  check "[C27] a program with CR line ends is refused with exit 2" exit_is 2 wplan
  check "[C27] naming it" said "the program programs/crlf.typify has CR line ends"
  rm -- "$clone/programs/crlf.typify"
  mkdir -- "$clone/programs/empty"
  check "[C27] an empty directory under programs/ is refused with exit 2" exit_is 2 wplan
  check "[C27] naming it" said "programs/empty is an empty directory; git carries none"
  check "[C29] build's assembly refuses it with exit 2" exit_is 2 wp build
  check "[C29] naming it" said "programs/empty is an empty directory; git carries none"
  rmdir -- "$clone/programs/empty"
  mkdir -p -- "$clone/programs/nest/inner"
  check "[C27] an empty directory deeper under programs/ is refused with exit 2" exit_is 2 wplan
  check "[C27] naming it" said "programs/nest/inner is an empty directory"
  rm -r -- "$clone/programs/nest"
  printf '%s\n' '{"layers": ["layers/structure.typify", "layers/access.typify", "layers/access.typify"]}' > "$clone/workplace.json"
  check "[C27] a layer listed twice is refused with exit 2" exit_is 2 wplan
  check "[C27] naming it" said "the layer name access is listed 2 times"
  printf '%s\n' '#lang typify' 'declare : Access' 'end!' > "$clone/layers/again.typify"
  printf '%s\n' '{"layers": ["layers/structure.typify", "layers/access.typify", "layers/again.typify"]}' > "$clone/workplace.json"
  check "[C27] a language declared twice is refused with exit 2" exit_is 2 wplan
  check "[C27] naming both places" said "the language Access is declared twice: at layers/access.typify:2 and at layers/again.typify:2"
  printf '%s\n' '{"layers": ["layers/structure.typify", "layers/access.typify"], "owner": "x"}' > "$clone/workplace.json"
  check "[C27] a member of workplace.json the loop does not read is refused" exit_is 2 wplan
  printf '%s\n' '{"layers": ["layers/structure.typify", "layers/access.typify"]}' > "$clone/workplace.json"
  check "[C27] the refused plans left PLAN/ as it was" test "$(cat "$clone/PLAN/manifest.json")" = "$before"
  printf '%s' '{"diagnostics":[
    {"code":"E_DECLARATION","severity":"error","file":"@DECLARATIONS@","range":{"start":{"line":2,"column":1},"end":{"line":2,"column":9}},"message":"first words"},
    {"code":"E_DECLARATION","severity":"error","file":"@DECLARATIONS@","range":{"start":{"line":5,"column":1},"end":{"line":5,"column":4}},"message":"second words"}],"ok":false}' \
    > "$STUB_DIR/check.json"
  check "[C28] a declaration error stops plan with exit 1" exit_is 1 wplan
  check "[C28] shown at the first layer's file and line, beside the reader's words" \
    said "layers/structure.typify:2: error E_DECLARATION: first words (the reader: LanguageDeclarations.typify:2)"
  check "[C28] and at the second layer's" said "layers/access.typify:3: error E_DECLARATION: second words (the reader: LanguageDeclarations.typify:5)"
  rm -- "$STUB_DIR/check.json"
  printf '%s' '{"diagnostics":[{"code":"E_PROGRAM","severity":"error","file":"@TREE@/ROOT.typify","range":{"start":{"line":2,"column":1},"end":{"line":2,"column":3}},"message":"root words"},
    {"code":"E_PROGRAM","severity":"error","file":"@TREE@/programs/policy.typify","range":{"start":{"line":1,"column":1},"end":{"line":1,"column":3}},"message":"program words"}],"status":"failed"}' \
    > "$STUB_DIR/plan-diagnostics.json"
  check "[C28] a program's error stops plan with exit 1" exit_is 1 wplan
  check "[C28] an error in the root program is shown as the generated program's" said "the generated root program, line 2: error E_PROGRAM: root words"
  check "[C28] a program's at its path in the clone" said "programs/policy.typify:1: error E_PROGRAM: program words"
  rm -- "$STUB_DIR/plan-diagnostics.json"
  statements_plan '.facts = "sha256:" + ("0" * 64)'
  check "[C28] a plan made on facts is refused with exit 1" exit_is 1 wplan
  check "[C28] with the open item of 5.15 as the reason" said "a plan whose facts member is not none is refused for now, since 5.15 leaves open which facts build compares"
  : > "$STUB_DIR/version"
  check "[C28] a reader that states no version stops plan with exit 2" exit_is 2 wplan
  check "[C28] saying so" said "states no version, and plan stops here"
  check "[C28] plan without a reader on the path exits 2" exit_is 2 env PATH="$(path_without_reader)" "$BASH" "$loop" plan
  check "[C28] naming the reader" said "plan needs the reader, the program typify on PATH"
  check "[C28] and PLAN/ is still as it was" test "$(cat "$clone/PLAN/manifest.json")" = "$before"
}

t_the_fold() {
  scoped_clone
  statements_plan
  check "plan folds the base plan" exit_is 0 wplan
  check "[C33] the seats stand in the order of the pane terms" \
    test "$(jq -r '[.seats[].seat[2]] | join(" ")' "$clone/PLAN/view.json")" = "keeper pilot watch grower picker"
  check "[C30] rule 1: the workplace's statement reaches every seat" test "$(jq '[.rows[] | select(.key[3] == "/")] | length' "$clone/PLAN/view.json")" = 5
  check "[C30] rule 1: the office's reaches its own seats only" \
    test "$(jq -r --arg p "$root/harbor/ledger" '[.rows[] | select(.key[3] == $p) | .key[2]] | join(" ")' "$clone/PLAN/view.json")" = "keeper pilot watch"
  check "[C30] rule 1: the room's reaches its room only" \
    test "$(jq -r --arg p "$root/harbor/berth" '[.rows[] | select(.key[3] == $p) | .key[2]] | join(" ")' "$clone/PLAN/view.json")" = "keeper pilot"
  check "[C30] rule 7: a seat's rows in the byte order of their paths" \
    test "$(rows_of keeper)" = "/ read-only,$root/harbor/berth read-write,$root/harbor/hold hidden,$root/harbor/holdall read-write,$root/harbor/ledger hidden,$root/harbor/scratch scratch,$root/harbor/vault searchable-only,$root/harbor/vault/shelf read-write,"
  check "[C30] each row carries its statement's origin" \
    test "$(jq -c '[.rows[] | select(.key[2] == "keeper" and .key[3] == "/") | .origins][0]' "$clone/PLAN/view.json")" = '[{"kind":"program","line":1,"path":"programs/policy.typify"}]'

  statements_plan '.state["seat-kinds"] = [{key: ["harbor", "dock", "keeper"], value: ["navigator"], masked: false, origin: at(30)},
                                          {key: ["harbor", "dock", "pilot"], value: ["none"], masked: false, origin: at(31)}]
    | .programs[-1].recorded += [st("navigator"; "-"; "-"; "kind"; $root + "/tools"; "hidden"; 9)]'
  check "plan with a kind" exit_is 0 wplan
  check "[C30] rule 1: a kind's statement reaches the seats of that kind" bash -c '[[ $1 == *"/tools hidden"* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 1: and no seat of none" bash -c '[[ $1 != *"/tools "* ]]' _ "$(rows_of pilot)"
  check "[C33] the seat's kind is in its table" test "$(seat_of keeper .kind)" = '"navigator"'

  local before
  before=$(cat "$clone/PLAN/manifest.json")
  statements_plan '.programs[-1].recorded += [st("harbor"; "-"; "-"; "office"; $root + "/harbor/ledger"; "read-only"; 9)]'
  check "[C31] rule 2: two statements of one scope about one path with different states refuse the plan" exit_is 1 wplan
  check "[C28] the refused fold left PLAN/ as it was" test "$(cat "$clone/PLAN/manifest.json")" = "$before"
  check "[C31] naming both origins" said "two statements of the office harbor about $root/harbor/ledger differ: hidden from programs/policy.typify:2, read-only from programs/policy.typify:9"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; "/"; "read-only"; 9)]
    | .programs[0].recorded = [st("-"; "-"; "-"; "workplace"; "/"; "read-only"; 4) | .origin.path = "workplace.typify"]'
  check "[C30] 5.18: equal statements make one row" exit_is 0 wplan
  check "[C30] 5.18: which carries the origin of each, in the plan's order" \
    test "$(jq -c '[.rows[] | select(.key[2] == "picker" and .key[3] == "/") | [.origins[] | "\(.path):\(.line)"]][0]' "$clone/PLAN/view.json")" = \
    '["workplace.typify:4","programs/policy.typify:1","programs/policy.typify:9"]'
  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "1"; 9), cl("harbor"; "-"; "-"; "office"; "2"; 10)]'
  check "[C31] rule 2: two clearances of one office with different numbers refuse the plan" exit_is 1 wplan
  check "[C31] naming both" said "two clearances of the office harbor differ: 1 from programs/policy.typify:9, 2 from programs/policy.typify:10"
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard"; "1"; 9), lb($root + "/orchard"; "2"; 10)]'
  check "[C31] rule 2: two labels of one path with different numbers refuse the plan" exit_is 1 wplan
  check "[C31] naming both" said "two labels of $root/orchard differ: 1 from programs/policy.typify:9, 2 from programs/policy.typify:10"
  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "1"; 9), cl("harbor"; "-"; "-"; "office"; "1"; 10)]'
  check "[C30] equal clearances count once" exit_is 0 wplan
  check "[C30] with both origins" test "$(seat_of watch '[.clearance.value, [.clearance.origins[].line]]')" = '[1,[9,10]]'

  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/harbor/ledger/inner"; "read-write"; 9),
                                              st("harbor"; "-"; "-"; "office"; $root + "/harbor/hold"; "hidden"; 10),
                                              st("-"; "-"; "-"; "workplace"; $root + "/harbor/holdall"; "read-write"; 11)]'
  check "plan with statements beneath a narrower one" exit_is 0 wplan
  check "[C30] rule 3: a narrower statement replaces a wider one beneath its path" bash -c '[[ $1 != *"/harbor/ledger/inner "* ]]' _ "$(rows_of watch)"
  check "[C30] rule 3: but not on another seat's office" bash -c '[[ $1 == *"/harbor/ledger/inner read-write"* ]]' _ "$(rows_of grower)"
  check "[C30] rule 3: /a against /ab: hold is hidden and holdall stays open" \
    bash -c '[[ $1 == *"/harbor/hold hidden,"* && $1 == *"/harbor/holdall read-write,"* ]]' _ "$(rows_of watch)"
  check "[C32] the statement that replaced is printed with what it replaced" \
    said "  workplace $root/harbor/ledger/inner read-write (programs/policy.typify:9)"
  check "[C32] and counted" test "$(seat_of watch '[.exception_count, .distinct_replaced_statement_count]')" = '[1,1]'

  statements_plan '.state["seat-kinds"] = [{key: ["harbor", "dock", "keeper"], value: ["navigator"], masked: false, origin: at(30)}]
    | .programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/r/a/b"; "read-only"; 9),
                                 st("navigator"; "-"; "-"; "kind"; $root + "/r/a"; "read-only"; 10),
                                 st("harbor"; "-"; "-"; "office"; $root + "/r"; "read-only"; 11)]'
  check "plan with 5.18's example" exit_is 0 wplan
  check "[C32] 5.18: the office's statement remains, and both others stand under it" \
    test "$(seat_of keeper '[.replacement_statements[] | select(.statement.term[5] | endswith("/r")) | [.replaced[].term[4]]][0]')" = '["workplace","kind"]'
  check "[C32] 5.18: the kind's statement, itself replaced, is printed only as replaced" \
    test "$(seat_of keeper '[.replacement_statements[] | .statement.term[4]] | index("kind")')" = null
  check "[C32] 5.18: the counts are 1 and 2" test "$(seat_of keeper '[.exception_count, .distinct_replaced_statement_count]')" = '[1,2]'

  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "1"; 9), cl("harbor"; "dock"; "-"; "room"; "2"; 10),
                                              cl("harbor"; "dock"; "keeper"; "seat"; "3"; 11)]'
  check "plan with clearances" exit_is 0 wplan
  check "[C30] rule 4: the seat's own clearance" test "$(seat_of keeper '[.clearance.value, .clearance.origin.line]')" = '[3,11]'
  check "[C30] rule 4: else its room's" test "$(seat_of pilot '[.clearance.value, .clearance.origin.line]')" = '[2,10]'
  check "[C30] rule 4: else its office's" test "$(seat_of watch '[.clearance.value, .clearance.origin.line]')" = '[1,9]'
  check "[C30] rule 4: else 0" test "$(seat_of grower '[.clearance.value, .clearance.origin]')" = '[0,null]'

  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "1"; 9), cl("harbor"; "dock"; "keeper"; "seat"; "3"; 11),
      lb($root + "/harbor/charts"; "2"; 12), lb($root + "/harbor/ledger/inner"; "1"; 13),
      lb($root + "/orchard"; "2"; 14), lb($root + "/orchard/almanac"; "1"; 15),
      st("harbor"; "-"; "-"; "office"; $root + "/harbor/vault/shelf"; "read-write"; 16), lb($root + "/harbor/vault"; "1"; 17)]'
  check "plan with labels" exit_is 0 wplan
  check "[C30] rule 5: a label above the seat's clearance makes a hidden row" bash -c '[[ $1 == *"/harbor/charts hidden"* ]]' _ "$(rows_of watch)"
  check "[C30] rule 5: at or below it, under an open row, a read-only row" bash -c '[[ $1 == *"/harbor/charts read-only"* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5: under a hidden row, none" bash -c '[[ $1 != *"/harbor/ledger/inner "* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5: the row a label makes carries the label's origin" \
    test "$(jq -c --arg p "$root/harbor/charts" '[.rows[] | select(.key[2] == "watch" and .key[3] == $p) | [.source, .origins[0].line]][0]' "$clone/PLAN/view.json")" = '["label",12]'
  check "[C30] rule 5: and replaces nothing: the office's row beneath it stands" \
    bash -c '[[ $1 == *"/harbor/vault read-only,"* && $1 == *"/harbor/vault/shelf read-write,"* ]]' _ "$(rows_of watch)"
  check "[C30] rule 5: labels from the shallowest: a lower label beneath a higher one opens nothing to the seats between" \
    bash -c '[[ $1 == *"/orchard hidden,"* && $1 != *"/orchard/almanac "* ]]' _ "$(rows_of watch)"
  check "[C32] the plan stands, and plan prints the pair" \
    said "label $root/orchard/almanac (1) lies beneath $root/orchard (2), and opens nothing to the seats between: Harbor Pilot, Harbor Watch"
  check "[C32] a statement standing at a labelled path is printed" said "stands at a labelled path: seat harbor/dock/keeper $root/harbor/vault searchable-only"

  statements_plan '.programs[-1].recorded += [cl("harbor"; "dock"; "keeper"; "seat"; "3"; 9),
      lb($root + "/harbor/scratch/deep"; "5"; 10), lb($root + "/harbor/scratch/page"; "1"; 11),
      lb($root + "/harbor/vault/deep"; "5"; 12), lb($root + "/harbor/vault/open"; "1"; 13)]'
  check "plan with labels beneath a scratch row and a searchable-only row" exit_is 0 wplan
  check "[C30] rule 5 (5.24): beneath a scratch row, a label above the seat's clearance makes no row" \
    bash -c '[[ $1 != *"/harbor/scratch/deep "* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5 (5.24): beneath a scratch row, a label at or below the seat's clearance makes no row" \
    bash -c '[[ $1 != *"/harbor/scratch/page "* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5 (5.24): beneath a searchable-only row, a label above the seat's clearance makes no row" \
    bash -c '[[ $1 != *"/harbor/vault/deep "* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5: beneath a searchable-only row, a label at or below the seat's clearance makes a read-only row" \
    bash -c '[[ $1 == *"/harbor/vault/open read-only,"* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5: and the seat's rows are those and no more" \
    test "$(rows_of keeper)" = "/ read-only,$root/harbor/berth read-write,$root/harbor/hold hidden,$root/harbor/holdall read-write,$root/harbor/ledger hidden,$root/harbor/scratch scratch,$root/harbor/vault searchable-only,$root/harbor/vault/open read-only,$root/harbor/vault/shelf read-write,"

  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 10)]'
  check "plan with a closed root" exit_is 0 wplan
  check "[C32] the directories beneath it that no row names are listed as held by nobody" \
    bash -c 'grep -qxF "held by nobody, a report and no part of the plan:" "$2" && grep -qxF "  $1/orchard/cellar" "$2" && grep -qxF "  $1/orchard/crate-picker" "$2"' _ "$root" "$scratch/out"
  check "[C32] and not one that a row names" bash -c '! grep -qxF "  $1/orchard/almanac" "$2"' _ "$root" "$scratch/out"
  statements_plan '.programs[-1].recorded = [lb($root + "/orchard"; "1"; 9)]'
  check "[C31] a plan with a label and no statement is folded, and refused for want of a row for /" exit_is 1 wplan
  check "[C31] naming a seat" said "seat Harbor Keeper (harbor/dock/keeper): no row for /"
  statements_plan '(.programs[-1].recorded[0].term[6]) = "searchable-only" | .programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root; "read-only"; 9)]'
  check "plan with / searchable-only" exit_is 0 wplan
  check "[C32] a directory beneath / that no row names is listed by its own path" \
    bash -c 'grep -qxF "  /usr" "$1" && ! grep -qF "  //" "$1"' _ "$scratch/out"
  statements_plan '.programs[-1].recorded |= map(select(.term[4] != "workplace")) | .programs[-1].recorded += [st("harbor"; "-"; "-"; "office"; "/"; "read-only"; 9)]'
  check "[C31] rule 6: a seat with no row for / refuses the plan" exit_is 1 wplan
  check "[C31] naming the seat" said "seat Orchard Grower (orchard/barn/grower): no row for /"
  statements_plan '.programs[-1].recorded += [st("harbor"; "-"; "-"; "office"; $root + "/harbor/ledger/inner"; "read-write"; 9)]'
  check "[C31] rule 6: a row opened beneath a hidden one refuses the plan" exit_is 1 wplan
  check "[C31] naming the seat, both paths and their origins" \
    said "seat Harbor Watch (harbor/tower/watch): $root/harbor/ledger/inner (read-write, from programs/policy.typify:9) lies beneath $root/harbor/ledger (hidden, from programs/policy.typify:2)"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-write"; 9), lb($root + "/orchard"; "1"; 10)]'
  check "[C31] rule 6: a row open at or beneath a label above the seat's clearance refuses the plan" exit_is 1 wplan
  check "[C31] naming the seat, the path, the label and the origins" \
    said "seat Orchard Grower (orchard/barn/grower): $root/orchard/almanac (read-write, from programs/policy.typify:9) lies at or beneath $root/orchard, labelled 1 (from programs/policy.typify:10), above the seat's clearance 0"
  statements_plan '.programs[-1].recorded += [lb("/"; "0"; 9)]'
  check "[C31] 5.18: a label on / refuses the plan" exit_is 1 wplan
  check "[C31] saying so" said "programs/policy.typify:9: a label on / refuses the plan"
  statements_plan '.programs[-1].recorded += [{term: ["statement", "workplace", "-", "-", "-", "/", "read-only"], origin: at(9)}]'
  check "[C31] 5.18: a statement with the scope word first is refused" exit_is 1 wplan
  check "[C31] naming the line" said "programs/policy.typify:9: - is not a scope of a statement"
  statements_plan '.programs[-1].recorded += [st("nowhere"; "-"; "-"; "office"; "/"; "hidden"; 9)]'
  check "[C31] a statement naming an office the plan does not make refuses the plan" exit_is 1 wplan
  check "[C31] naming it" said "programs/policy.typify:9: the statement names the office nowhere, which the plan does not make"
  statements_plan '.programs[-1].recorded += [cl("harbor"; "dock"; "ghost"; "seat"; "1"; 9)]'
  check "[C31] a clearance naming a seat the plan does not make refuses the plan" exit_is 1 wplan
  check "[C31] naming it" said "the clearance names the seat harbor/dock/ghost, which the plan does not make"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/harbor/"; "read-only"; 9)]'
  check "[C4] a statement's path that is not canonical refuses the plan" exit_is 1 wplan
  check "[C4] naming its origin" said "programs/policy.typify:9 (statement): the path \"$root/harbor/\" is refused: it ends in a slash"
  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "01"; 10)]'
  check "[C31] a number that is not whole refuses the plan" exit_is 1 wplan
  check "[C31] naming it" said "01 is not a whole number"
}

t_plan_relative() {
  scoped_clone
  local extra='.programs[-1].recorded += [lb($root + "/orchard"; "2"; 9), cl("harbor"; "dock"; "keeper"; "seat"; "3"; 10)]'
  local rel='def rel: if . == $root then "." elif startswith($root + "/") then .[($root | length) + 1:] else . end;
    .programs[-1].recorded |= map(if .term[0] == "statement" then .term[5] |= rel elif .term[0] == "label" then .term[1] |= rel else . end)'
  statements_plan "$extra"
  check "plan of statements written absolute" exit_is 0 wplan
  cp -- "$clone/PLAN/view.json" "$scratch/view-absolute"
  statements_plan "$extra | $rel"
  check "[C4] plan of the same statements written relative to the root" exit_is 0 wplan
  check "[C4] plan.json keeps the paths as written" \
    test "$(jq '[.programs[-1].recorded[] | select(.term[0] == "statement") | .term[5] | select(startswith("/") | not)] | length' "$clone/PLAN/plan.json")" = 7
  check "[C4] view.json is the same, byte for byte: the fold reads joined paths" cmp -s "$scratch/view-absolute" "$clone/PLAN/view.json"
  wp why "Harbor Keeper" "$root/harbor/ledger" > "$scratch/out" 2>&1
  check "[C4] why prints a statement's path as written beside the joined one" said "the row's path is written harbor/ledger and joined to $root/harbor/ledger"
  statements_plan '.programs[-1].recorded = [st("-"; "-"; "-"; "workplace"; "."; "read-only"; 1), st("-"; "-"; "-"; "workplace"; "usr"; "read-only"; 2)]'
  check "[C4] plan under the root /" exit_is 0 env PATH="$STUB_DIR/bin:$PATH" WORKPLACE_ROOT=/ "$BASH" "$loop" plan
  check "[C4] under /, . is / and usr is /usr: no /. and no //" \
    test "$(jq -r '[.rows[].key[3]] | unique | join(" ")' "$clone/PLAN/view.json")" = "/ /usr"
  statements_plan '.programs[-1].recorded += [st("harbor"; "-"; "-"; "office"; "harbor/ledger"; "hidden"; 9)]'
  check "[C4] one path spelt relative and absolute, with one state, is one statement" exit_is 0 wplan
  check "[C4] whose row carries both origins" \
    test "$(jq -c --arg p "$root/harbor/ledger" '[.rows[] | select(.key[2] == "watch" and .key[3] == $p) | [.origins[].line]][0]' "$clone/PLAN/view.json")" = '[2,9]'
  statements_plan '.programs[-1].recorded += [st("harbor"; "-"; "-"; "office"; "harbor/ledger"; "read-only"; 9)]'
  check "[C4] with two states, it is a conflict that refuses the plan" exit_is 1 wplan
  check "[C4] naming the joined path" said "two statements of the office harbor about $root/harbor/ledger differ: hidden from programs/policy.typify:2, read-only from programs/policy.typify:9"
  statements_plan "$extra"
  check "plan again" exit_is 0 wplan
  local before
  before=$(cat "$clone/PLAN/manifest.json")
  statements_plan '.programs[-1].recorded += [st("harbor"; "-"; "-"; "office"; "harbor//vault"; "hidden"; 9)]'
  check "[C4] a statement whose relative path has an empty component refuses the plan" exit_is 1 wplan
  check "[C4] naming its origin" said 'programs/policy.typify:9 (statement): the path "harbor//vault" is refused: it has an empty component'
  statements_plan '.programs[-1].recorded += [lb("orchard/"; "1"; 9)]'
  check "[C4] a label whose path ends in a slash refuses the plan" exit_is 1 wplan
  check "[C4] naming its origin" said 'programs/policy.typify:9 (label): the path "orchard/" is refused: it ends in a slash'
  statements_plan '.programs[0].plan[0][2] = "config/"'
  check "[C4] a server's configuration that ends in a slash refuses the plan" exit_is 1 wplan
  check "[C4] naming the term" said 'workplace.typify, term 1 (server): the path "config/" is refused: it ends in a slash'
  statements_plan '(.programs[] | select(.path == "harbor/dock/pilot/seat.typify") | .plan[1].term[4]) = "harbor/."'
  check "[C4] a seat's directory with a . component refuses the plan" exit_is 1 wplan
  check "[C4] naming the term" said 'harbor/dock/pilot/seat.typify, term 2 (start): the path "harbor/." is refused: it has a . or .. component'
  statements_plan '(.programs[] | select(.path == "harbor/dock/pilot/seat.typify") | .plan[1].term[5]) = (["../tools/probe", "pilot"] | tojson)'
  check "[C4] a relative program with a .. component refuses the plan" exit_is 1 wplan
  check "[C4] naming the term" said 'harbor/dock/pilot/seat.typify, term 2 (start): the program "../tools/probe" is refused: it has a . or .. component'
  statements_plan '(.programs[] | select(.path == "harbor/dock/pilot/seat.typify") | .plan[1].term[5]) = (["probe", "../text", "a//b"] | tojson)'
  check "[C4] a bare program and text with slashes in the other words plan" exit_is 0 wplan
  before=$(cat "$clone/PLAN/manifest.json")
  statements_plan '.programs[-1].recorded += [{term: ["record-directory", "harbor", "dock", "keeper", "harbor/"], origin: at(9)}]'
  check "[C4] a recorded directory that ends in a slash refuses the plan" exit_is 1 wplan
  check "[C4] naming its origin" said 'programs/policy.typify:9 (record-directory): the path "harbor/" is refused: it ends in a slash'
  check "[C28] the refused plans left PLAN/ as it was" test "$(cat "$clone/PLAN/manifest.json")" = "$before"
}

t_the_folded_view_in_the_panes() {
  scoped_clone
  statements_plan '.state.view = [{key: ["harbor", "dock", "keeper", ($root + "/harbor/ledger")], value: ["read-write"]}]'
  check "plan" exit_is 0 wplan
  check "[C33] build" exit_is 0 wp build
  check "[C33] up" exit_is 0 wp up
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  check "[C33] the seat's view is the fold's: ledger, hidden by the office, is unseen, and the plan's view cell is not read" \
    screen_has "Harbor Keeper" "hidden ledger: unseen"
  check "[C33] berth, opened by the room, is written" screen_has "Harbor Keeper" "rw berth: write=ok"
  check "[C33] vault, searchable-only by the seat, cannot be listed" screen_has "Harbor Keeper" "list vault: refused"
  check "[C33] and its shelf is reachable" screen_has "Harbor Keeper" "reach vault/shelf: write=ok"
  check "[C33] why names the statement behind a folded row" exit_is 0 wp why "Harbor Keeper" "$root/harbor/ledger/secret"
  check "[C33] the row and its origin" \
    bash -c 'grep -qxF "no row at the path; its nearest ancestor'"'"'s row is $1/harbor/ledger hidden" "$2" && grep -qxF "made by a statement, from programs/policy.typify:2" "$2"' _ "$root" "$scratch/out"
  check "[C33] down" exit_is 0 wp down
  rm -rf -- "$clone/BUILD"
  rm -- "$clone/PLAN/view.json"
  check "[C33] a plan that holds statements and has lost its view.json does not build" exit_is 1 wp build
  check "[C33] naming the file" said "PLAN/view.json is missing"
}

t_plan_end_to_end() {
  local pinned=f007776cde073439b0cac818c1b193afdcddee7d7d23ac5d6fb66a4f1aab7107 reference=/tmp/workplace-reference-s3
  if ! command -v typify > /dev/null; then
    skip "[C28] the reader typify is not on PATH here, so plan cannot run end to end"
    return 0
  fi
  if [[ ! -f $reference/config/workplace.json ]]; then
    skip "[C28] the relative edition of the fixture (w1-paths 5384b45) is not laid out as a clone at $reference"
    return 0
  fi
  if [[ -e $reference/config/BUILD ]]; then
    skip "[C28] a BUILD already stands in $reference; this test makes and removes only its own"
    return 0
  fi
  export WORKPLACE_ROOT=$reference WORKPLACE_CONFIG=$reference/config
  clone=$reference/config
  run=$clone/BUILD/RUN
  reference_plan=$scratch/reference-plan
  cp -a -- "$clone/PLAN" "$reference_plan" || { fail "cannot keep a copy of $clone/PLAN"; return 0; }
  reference_root=$reference
  reference_paths=$(find "$reference" -path "$reference/config/BUILD" -prune -o -print | sort)
  local shape
  shape=$(shape_of "$reference")
  trap 'leave_reference; cleanup' EXIT
  check "[C28] plan with the reader $(typify --version)" exit_is 0 wp plan
  (( test_failed == 0 )) || return 0
  check "[C29] PLAN/ now holds the folded view" test -f "$clone/PLAN/view.json"
  check "[C28] writes plan.json byte for byte as the fixture's committed plan" test "$(sha256sum < "$clone/PLAN/plan.json" | cut -d' ' -f1)" = "$pinned"
  check "[C29] and the generated files the fixture's manifest records" \
    test "$(jq -c .generated "$clone/PLAN/manifest.json")" = "$(jq -c .generated "$reference_plan/manifest.json")"
  check "[C29] and the same inputs" test "$(jq -c .inputs "$clone/PLAN/manifest.json")" = "$(jq -c .inputs "$reference_plan/manifest.json")"
  label=$(jq -r .name "$clone/PLAN/manifest.json")
  check "[C29] build, with no reader on the path" exit_is 0 env PATH="$(path_without_reader)" "$BASH" "$loop" build
  check "[C8] up" exit_is 0 wp up
  check "[C9] five seats and no other pane" test "$(T list-panes -a -F x | wc -l)" = 5
  local row title seat
  for row in "Harbor Pilot:pilot" "Harbor Keeper:keeper" "Harbor Watch:watch" "Orchard Grower:grower" "Orchard Picker:picker"; do
    IFS=: read -r title seat <<< "$row"
    check "[C33] $title runs its program" wait_for_probe "$title" "$seat"
  done
  check "[C33] keeper: ledger, hidden by its office, is unseen" screen_has "Harbor Keeper" "hidden ledger: unseen"
  check "[C33] keeper: charts, read-only by its office over the workplace's read-write, refuses a write" \
    screen_has "Harbor Keeper" "ro charts: read=ok write=refused"
  check "[C33] keeper: berth, hidden by its room, cannot be written" bash -c '[[ $1 == *"rw berth: write=refused"* ]]' _ "$(screen_of 'Harbor Keeper')"
  check "[C33] status exits 0" exit_is 0 wp status
  check "[C33] why reads the folded view" exit_is 0 wp why "Orchard Picker" "$reference/restricted/lower/x"
  check "[C33] a row a label made" said "made by a label"
  check "[C18] down" exit_is 0 wp down
  check "[C18] nothing of the workplace is left" no_server
  leave_reference
  check "[C28] the clone's PLAN/ is restored as the test found it" diff -r "$reference_plan" "$clone/PLAN"
  check "[C28] and the root is left as the test found it: every entry's type, mode and size" test "$(shape_of "$reference")" = "$shape"
}

key_terms='def k($a; $b; $c; $scope; $state; $line): {term: ["key", $a, $b, $c, $scope, $state], origin: {kind: "program", line: $line, path: "programs/IDENTITY.typify"}};
  .programs[-1].recorded += [k("-"; "-"; "-"; "workplace"; "held"; 1), k("harbor"; "-"; "-"; "office"; "none"; 2),
                             k("harbor"; "dock"; "-"; "room"; "held"; 3), k("harbor"; "dock"; "pilot"; "seat"; "none"; 4)]'

t_identity_selection() {
  scoped_clone
  statements_plan "$key_terms"
  check "plan with keys at four scopes" exit_is 0 wplan
  check "[C34] each seat holds a key by the narrowest scope that speaks: its room's, its own, its office's, the workplace's" \
    test "$(jq -c '[.seats[] | [.seat[2], .key.state, .key.scope, [.key.origins[].line]]]' "$clone/PLAN/view.json")" = \
    '[["keeper","held","room",[3]],["pilot","none","seat",[4]],["watch","none","office",[2]],["grower","held","workplace",[1]],["picker","held","workplace",[1]]]'
  check "[C34] the fold's version is one that reads keys" test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-v4
  statements_plan '.programs[-1].recorded += [{term: ["key", "-", "-", "-", "workplace", "held"], origin: at(1)}]'
  check "plan with the workplace's key alone" exit_is 0 wplan
  check "[C34] the workplace's key alone reaches every seat" \
    test "$(jq -c '[.seats[] | .key.state] | unique' "$clone/PLAN/view.json")" = '["held"]'
  statements_plan "$key_terms"' | .programs[-1].recorded += [k("harbor"; "dock"; "-"; "room"; "none"; 5)]'
  check "[C34] two keys of one scope with different states refuse the plan" exit_is 1 wplan
  check "[C34] naming both origins" said "two keys of the room harbor/dock differ: held from programs/IDENTITY.typify:3, none from programs/IDENTITY.typify:5"
  statements_plan "$key_terms"' | .programs[-1].recorded += [k("harbor"; "dock"; "ghost"; "seat"; "held"; 5), k("-"; "-"; "-"; "workplace"; "maybe"; 6)]'
  check "[C34] a key naming a seat the plan does not make, or a state other than held and none, refuses the plan" exit_is 1 wplan
  check "[C34] naming each" bash -c 'grep -qF "IDENTITY.typify:5: the key names the seat harbor/dock/ghost, which the plan does not make" "$1" && grep -qF "IDENTITY.typify:6: maybe is not held or none" "$1"' _ "$scratch/out"
  statements_plan "$key_terms"' | .programs[-1].recorded |= map(select(.term[0] == "key"))'
  check "[C34] a plan with keys and no statement is folded, and refused for want of a row for /" exit_is 1 wplan
  check "[C34] naming a seat" said "no row for /"
  statements_plan
  check "plan with no key" exit_is 0 wplan
  local manifest=$clone/PLAN/manifest.json
  jq '.derivations.fold = "frame-older-v0"' "$manifest" > "$scratch/m" && cp -- "$scratch/m" "$manifest"
  check "[C29] build of a plan folded by another version, whose view this loop's fold gives again" exit_is 0 wp build
  check "[C29] says so in one line and goes on" \
    said "the plan was folded by frame-older-v0, and this loop folds by frame-5.17-5.18-5.24-5.29-5.37-v4; the views are equal, so build goes on"
  check "[C36] a build makes the state directory, 0700, and no key home where no seat holds a key" \
    bash -c '[[ $(stat -c %a "$1") == 700 && ! -e $1/keys ]]' _ "$HOME/.local/state/workplace/$label"
  rm -rf -- "$clone/BUILD"
  jq '.rows[0].value = ["read-write"]' "$clone/PLAN/view.json" > "$scratch/v" && cp -- "$scratch/v" "$clone/PLAN/view.json"
  jq --arg s "$(sha256sum < "$clone/PLAN/view.json" | cut -d' ' -f1)" '(.outputs[] | select(.path == "view.json") | .sha256) = $s' "$manifest" > "$scratch/m" \
    && cp -- "$scratch/m" "$manifest"
  check "[C29] where the views differ, build refuses" exit_is 1 wp build
  check "[C29] naming both versions and saying to plan again" \
    said "The plan was folded by frame-older-v0, and this loop folds by frame-5.17-5.18-5.24-5.29-5.37-v4; run plan again"
  statements_plan "$key_terms"' | .state.environment += [{key: ["harbor", "dock", "keeper", "GNUPGHOME"], value: ["/elsewhere"], masked: false, origin: at(40)}]'
  check "plan with an environment row the frame owns" exit_is 0 wplan
  check "[C39] build refuses a holding seat's row for GNUPGHOME" exit_is 1 wp build
  check "[C39] naming the seat, the name and the origin" \
    said "state environment: harbor/dock/keeper holds a key, and its environment may not set GNUPGHOME, which the frame gives (programs/policy.typify:40)"
  statements_plan "$key_terms"
  check "plan with keys" exit_is 0 wplan
  local old=$scratch/oldgpg
  mkdir -p -- "$old"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "gpg (GnuPG) 2.4.3"' > "$old/gpg"
  chmod +x -- "$old/gpg"
  check "[C44] GnuPG 2.4.3, below the floor 2.4.4, is refused for a plan in which a seat holds a key, with exit 2" exit_is 2 env PATH="$old:$PATH" "$BASH" "$loop" build
  check "[C44] naming both versions" said "gpg 2.4.3 found; 2.4.4 or later is needed"
  check "[C44] and leaving no BUILD" test ! -e "$clone/BUILD"
  wp doctor > "$scratch/out" 2>&1
  check "[C43] doctor names the state directory and the room it leaves for a workplace's name" \
    said "the workplaces' state directory $HOME/.local/state/workplace: a workplace whose seats hold keys may have a name of at most"
}

t_identity() {
  local program
  for program in gpg gpg-agent gpgconf gpg-connect-agent ssh-keygen ssh-add git setsid base64; do
    command -v "$program" > /dev/null || { skip "[C35] $program is not on PATH here, so no key is made and used in a pane"; return; }
  done
  scoped_clone
  local w=$label state=$HOME/.local/state/workplace/$label
  local panes='
    def add($path; $args): (.programs[] | select(.path == $path) | .plan[1].term[5]) |= (fromjson + $args | tojson);
    .programs[-1].recorded += [st("harbor"; "tower"; "watch"; "seat"; $root + "/harbor/charts"; "read-write"; 20)]
    | (.programs[] | select(.path == "orchard/barn/grower/seat.typify") | .plan[0][4]) = "Orchard Grower (L0)"
    | add("harbor/dock/keeper/seat.typify"; ["report=" + $root + "/harbor/berth/report", "identity=" + $root + "/harbor/berth",
                                            "commit=" + $root + "/harbor/berth|Harbor Keeper|harbor.dock.keeper@WORKPLACE"])
    | add("harbor/tower/watch/seat.typify"; ["report=" + $root + "/harbor/charts/report", "identity=/nowhere"])'
  statements_plan "$key_terms | ${panes//WORKPLACE/$w}"
  check "plan" exit_is 0 wplan
  check "[C35] build makes the keys" exit_is 0 wp build
  check "[C35] three: keeper's, the grower's and the picker's" said "keys: 3 made in $state/keys"
  local keys=$clone/BUILD/keys.json home=$state/keys/01
  check "[C37] keys.json names the workplace and its state directory" test "$(jq -r '"\(.workplace) \(.state)"' "$keys")" = "$w $state"
  check "[C35] one key home per holding seat, named by its place among the panes" \
    test "$(jq -r '[.seats[] | "\(.seat | join("/")) \(.home)"] | join(", ")' "$keys")" = "harbor/dock/keeper keys/01, orchard/barn/grower keys/04, orchard/barn/picker keys/05"
  check "[C35] the user id is the seat's name and an address of its place at the workplace" \
    test "$(jq -r '.seats[0].uid' "$keys")" = "Harbor Keeper <harbor.dock.keeper@$w>"
  check "[C35] a name with parentheses passes" test "$(jq -r '.seats[1].uid' "$keys")" = "Orchard Grower (L0) <orchard.barn.grower@$w>"
  check "[C35] an ed25519 key that signs and certifies, with an ed25519 subkey that authenticates, and nothing that encrypts" \
    test "$(gpg --homedir "$home" --with-colons --list-keys | grep -E '^(pub|sub):' | cut -d: -f1,4,12 | tr '\n' ' ')" = "pub:22:scSCA sub:22:a "
  check "[C35] no passphrase protects it: both key files are stored in the clear" \
    bash -c 'files=("$1"/private-keys-v1.d/*.key); (( ${#files[@]} == 2 )) && ! grep -q protected-private-key "${files[@]}"' _ "$home"
  check "[C36] gpg's revocation certificate is removed" test ! -e "$home/openpgp-revocs.d"
  check "[C36] the state directory is 0700" test "$(stat -c %a "$state")" = 700
  check "[C37] the two fingerprints are the key's own" \
    test "$(jq -r '.seats[0] | "\(.fingerprint) \(.authentication)"' "$keys")" = "$(gpg --homedir "$home" --with-colons --list-keys | grep '^fpr' | cut -d: -f10 | paste -sd' ')"
  check "[C37] the ssh line is gpg's own, with the seat's place at the workplace for its comment" \
    test "$(jq -r '.seats[0].ssh' "$keys")" = "$(gpg --homedir "$home" --export-ssh-key "$(jq -r '.seats[0].fingerprint' "$keys")" | cut -d' ' -f1,2) harbor/dock/keeper@$w"
  check "[C37] its fingerprint is the one ssh-keygen gives" \
    test "$(jq -r '.seats[0].ssh_fingerprint' "$keys")" = "$(jq -r '.seats[0].ssh' "$keys" | ssh-keygen -lf - | cut -d' ' -f2)"
  check "[C37] the build's manifest lists keys.json" grep -qE '^[0-9a-f]{64}  keys\.json$' "$clone/BUILD/MANIFEST"
  check "[C35] build leaves no agent running" no_agent_of "$state/keys"
  if [[ -d /run/user/$EUID/gnupg && -r /run/user/$EUID/gnupg ]]; then
    check "[C42] and no runtime socket directory: each key home's, by the name GnuPG gives it, is absent" no_socket_dir_left
  else
    skip "[C42] /run/user/$EUID/gnupg cannot be read here, so whether build leaves a socket directory there is measured where it can"
  fi
  gpg-agent --homedir "$home" --daemon > /dev/null 2>&1
  check "[C38] up refuses while an agent of a key home answers" exit_is 1 wp up
  check "[C38] naming it" said "an agent of $home already answers"
  check "[C38] and leaves that agent alone" bash -c '[[ $(gpg-connect-agent --homedir "$1" --no-autostart "GETINFO pid" /bye 2> /dev/null) == D* ]]' _ "$home"
  check "[C38] and starts no server" no_server
  gpgconf --homedir "$home" --kill gpg-agent > /dev/null 2>&1
  check "[C38] up" exit_is 0 wp up
  check "[C38] it started one agent for each holding seat" test "$(grep -c '^up: the agent of ' "$scratch/out")" = 3
  local pid
  pid=$(gpg-connect-agent --homedir "$home" --no-autostart 'GETINFO pid' /bye | sed -n 's/^D //p')
  if [[ $(nnp_of $$) == NoNewPrivs:1 ]]; then
    skip "[C38] keeper's agent reports NoNewPrivs:1, but so would any process this shell starts; measured where the shell does not run under it"
  else
    check "[C38] the agent runs under no-new-privileges" test "$(nnp_of "$pid")" = "NoNewPrivs:1"
  fi
  wp status > "$scratch/out" 2>&1
  check "[C43] status lists each agent, its key and its pid" said "ok      the agent of Harbor Keeper, key $(jq -r '.seats[0].fingerprint[-16:]' "$keys"), pid $pid"
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  local report=$root/harbor/berth/report
  r() { grep -qxF -- "$1" "$report"; }
  check "[C39] keeper is shown its key home: the public ring, the trust database, gpg.conf and two sockets" \
    r "key home: S.gpg-agent S.gpg-agent.ssh gpg.conf pubring.kbx trustdb.gpg "
  check "[C39] read-only" r "key home write: refused"
  check "[C39] in a state directory that holds nothing else" r "key state: gnupg "
  check "[C39] the agents' runtime sockets are not seen" r "key runtime sockets: unseen"
  check "[C40] keeper signs with gpg, with nothing set by hand" r "key gpg sign: ok"
  check "[C41] exporting the private key gives nothing" bash -c 'grep -qxF "key export: 0 bytes" "$1" && grep -qxF "key export loopback: 0 bytes" "$1" && grep -qxF "key export subkeys: 0 bytes" "$1"' _ "$report"
  check "[C41] every agent command that reads, exports, imports, deletes or changes a key, or reloads or ends the agent, is forbidden" r "key agent: 18 of 18 forbidden"
  check "[C41] and keeper still signs after them" r "key gpg sign after: ok"
  check "[C40] keeper's agent offers the manifest's ssh key" r "key ssh list: $(jq -r '.seats[0].ssh' "$keys" | cut -d' ' -f1,2)"
  check "[C40] keeper signs with ssh" r "key ssh sign: ok"
  check "[C41] removing every ssh key changes nothing" r "key ssh after removing all: listed"
  check "[C41] adding a key is refused" r "key ssh add: refused"
  check "[C40] keeper commits with a signature, the committer set to its name and address alone" r "key commit: ok"
  local verify=$scratch/verify
  mkdir -m 0700 -- "$verify"
  jq -r '.seats[0].public_key' "$keys" | gpg --homedir "$verify" --batch --import 2> /dev/null
  check "[C40] the gpg signature verifies against keys.json's public key" \
    env GNUPGHOME="$verify" gpg --batch --verify "$root/harbor/berth/msg.asc" "$root/harbor/berth/msg"
  printf 'keeper %s\n' "$(jq -r '.seats[0].ssh' "$keys" | cut -d' ' -f1,2)" > "$scratch/allowed"
  check "[C40] the ssh signature verifies against keys.json's line" \
    bash -c 'ssh-keygen -Y verify -f "$1" -I keeper -n file -s "$2.sig" < "$2"' _ "$scratch/allowed" "$root/harbor/berth/msg"
  check "[C40] the commit verifies against keys.json's public key" env GNUPGHOME="$verify" git -C "$root/harbor/berth/repo" verify-commit HEAD
  check "[C40] its committer is the seat's name and address" \
    test "$(git -C "$root/harbor/berth/repo" log -1 --format='%cn <%ce>')" = "Harbor Keeper <harbor.dock.keeper@$w>"
  agent_of "$verify" && gpgconf --homedir "$verify" --kill gpg-agent > /dev/null 2>&1
  gpgconf --homedir "$verify" --remove-socketdir > /dev/null 2>&1
  check "watch ran" wait_for_probe "Harbor Watch" watch
  check "[C39] a seat that holds no key has no key home" grep -qxF "key home: none" "$root/harbor/charts/report"
  check "[C39] nor reaches the agents' runtime sockets" grep -qxF "key runtime sockets: unseen" "$root/harbor/charts/report"
  check "[C39] nor holds GNUPGHOME or SSH_AUTH_SOCK, which keeper holds" \
    bash -c '[[ $1 != *GNUPGHOME* && $1 != *SSH_AUTH_SOCK* && $2 == *GNUPGHOME*SSH_AUTH_SOCK* ]]' _ "$(screen_of 'Harbor Watch' | grep '^env ')" "$(screen_of 'Harbor Keeper' | grep '^env ')"
  wp why "Harbor Keeper" "$home" > "$scratch/out" 2>&1
  check "[C43] why names the mask on the state directory" said "masked by the frame after the rows (Identity, Home): $HOME/.local/state/workplace, where workplaces keep their state, is shown to no seat"
  check "[C43] and what a holding seat is shown" said "passes through it to $state/gnupg"
  check "[C43] and the seat's key with its term" said "key: held, by the room's term, from programs/IDENTITY.typify:3"
  gpgconf --homedir "$home" --kill gpg-agent > /dev/null 2>&1
  check "[C43] status exits 1 when an agent is gone" exit_is 1 wp status
  check "[C43] saying the seat cannot sign until down and up" said "Harbor Keeper cannot sign until the workplace is brought down and up again"
  local -a socket_dirs=()
  for program in "$state"/keys/*; do socket_dirs+=("$(gpgconf --homedir "$program" --list-dirs socketdir)"); done
  if [[ ${socket_dirs[0]} == /run/user/* ]]; then
    check "[C42] the socket directory's name is GnuPG's, computed here without asking it" test "${socket_dirs[0]}" = "$(socket_dir_of "$state/keys/01")"
  fi
  check "[C42] down" exit_is 0 wp down
  check "[C42] no runtime socket directory is left (${#socket_dirs[@]} looked at, noted while the agents ran)" \
    bash -c 'for d in "${@:2}"; do [[ $d == "$1"/keys/* || ! -e $d ]] || exit 1; done' _ "$state" "${socket_dirs[@]}"
  check "[C42] and no agent of a key home runs after down" no_agent_of "$state/keys"
  local before
  before=$(jq -r '.seats[0].fingerprint' "$keys")
  rm -rf -- "$clone/BUILD"
  check "build again" exit_is 0 wp build
  check "[C36] a new build makes new keys, and no home keeps an old one" \
    bash -c '[[ $(jq -r ".seats[0].fingerprint" "$1") != "$2" ]] || exit 1; for h in "$3"/keys/*; do ! gpg --homedir "$h" --list-keys "$2" > /dev/null 2>&1 || exit 1; done' _ "$keys" "$before" "$state"
  rm -rf -- "$clone/BUILD"
  local long=$scratch/state-$(printf 'x%.0s' {1..40})
  mkdir -p -- "$long"
  check "[C38] a state directory too long for the sockets refuses the build, with exit 2" exit_is 2 env XDG_STATE_HOME="$long" "$BASH" "$loop" build
  check "[C38] naming the socket's length and the limit" said "and GnuPG takes 106"
  check "[C38] and leaving no BUILD" test ! -e "$clone/BUILD"
  statements_plan "$key_terms"' | (.programs[] | select(.path == "orchard/barn/picker/seat.typify") | .plan[0][4]) = " Orchard Picker"'
  check "plan with a name that gpg trims" exit_is 0 wplan
  check "[C35] a user id that gpg does not make as asked refuses the build" exit_is 1 wp build
  check "[C35] naming both" said "gpg did not make the user id ' Orchard Picker <orchard.barn.picker@$w>'"
  if [[ -d /run/user/$EUID/gnupg && -r /run/user/$EUID/gnupg ]]; then
    check "[C42] after every build, up, status, why, down and refusal of this test, no key home, nor the test's own home for verifying, has a runtime socket directory" no_socket_dir_left
    check "[C42] nor has any home of the first build, whose directories were noted while its agents ran" \
      bash -c 'for d in "${@:2}"; do [[ $d == "$1"/keys/* || ! -e $d ]] || exit 1; done' _ "$state" "${socket_dirs[@]}"
  else
    skip "[C42] /run/user/$EUID/gnupg cannot be read here, so the directories left after the whole test are measured where it can"
  fi
}

home_terms='def h($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/HOMES.typify"}};
  kinds([["harbor", "dock", "keeper", "navigator"], ["harbor", "dock", "pilot", "navigator"], ["harbor", "tower", "watch", "none"],
         ["orchard", "barn", "grower", "gardener"], ["orchard", "barn", "picker", "gardener"]])
  | .programs[-1].recorded += [
      h(["home", "navigator", "WPT_HOME", "kept"]; 1), h(["home-variable", "navigator", "WPT_CACHE", "cache"]; 2),
      h(["home-seed", "navigator", "tools/seed"]; 3), h(["home", "gardener", "WPT_HOME", "scratch"]; 4),
      h(["home-variable", "gardener", "WPT_CACHE", "."]; 5),
      h(["record-directory", "harbor", "dock", "keeper", "harbor/berth"]; 6),
      h(["record-directory", "harbor", "dock", "keeper", $root + "/harbor/vault"]; 7),
      h(["record-directory", "harbor", "dock", "keeper", "harbor/berth"]; 8)]'
value_terms='def v($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/VALUES.typify"}};
  .programs[-1].recorded += [
    v(["expect", "-", "-", "-", "workplace", "WPT_TOKEN"]; 1), v(["expect", "harbor", "dock", "-", "room", "WPT_DOCK"]; 2),
    v(["expect", "harbor", "dock", "keeper", "seat", "WPT_TOKEN"]; 3), v(["expect", "orchard", "-", "-", "office", "WPT_ORCHARD"]; 4)]'
probe_args='def add($path; $args): (.programs[] | select(.path == $path) | .plan[1].term[5]) |= (fromjson + $args | tojson);
  .programs[-1].recorded += [st("harbor"; "tower"; "watch"; "seat"; $root + "/harbor/charts"; "read-write"; 20),
                             st("orchard"; "barn"; "-"; "room"; $root + "/orchard/almanac"; "read-write"; 21)]'
refused_by() {
  local exit=$1 command=$2 filter=$3 message=$4
  statements_plan "$home_terms | $value_terms | $filter"
  if [[ $command == build ]]; then
    exit_is 0 wplan || return 1
    exit_is "$exit" wp build || return 1
  else
    exit_is "$exit" wplan || return 1
  fi
  said "$message" || { note "    wanted: $message"; sed 's/^/    | /' "$scratch/out"; return 1; }
}
write_seed() {
  printf '%s\n' '#!/usr/bin/env bash' 'home=$1' 'shift' 'printf "%s\n" "$@" > "$home/seeded"' \
    '{ printf "%s\n" "pwd $PWD" "$(grep "^NoNewPrivs" /proc/self/status | tr -d " \t")" "names $(tr "\0" "\n" < /proc/$$/environ | cut -d= -f1 | LC_ALL=C sort | tr "\n" " ")" "WPT_HOME=${WPT_HOME-} WPT_CACHE=${WPT_CACHE-}" "stdin $(readlink /proc/$$/fd/0)"; } > "$home/seeded.how"' \
    'printf "%s\n" "$home" >> "$HOME/seed-log"' > "$root/tools/seed"
  chmod +x -- "$root/tools/seed"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "the seed fails on purpose" >&2' 'exit 3' > "$root/tools/failing-seed"
  chmod +x -- "$root/tools/failing-seed"
}

t_home_and_values_selection() {
  scoped_clone
  statements_plan "$home_terms | $value_terms"
  check "plan with homes and expected values" exit_is 0 wplan
  check "[C45] a seat of a kind with a home has it, with the kind's variable, its further variables and its seed, the seed's path joined; a seat of no kind has none" \
    test "$(jq -c '[.seats[] | [.seat[2], .home.kind, .home.state, .home.variable, [.home.variables[]? | [.name, .path]], .home.seed.path]]' "$clone/PLAN/view.json")" = \
    "$(jq -c -n --arg s "$root/tools/seed" '[["keeper", "navigator", "kept", "WPT_HOME", [["WPT_CACHE", "cache"]], $s], ["pilot", "navigator", "kept", "WPT_HOME", [["WPT_CACHE", "cache"]], $s],
      ["watch", null, null, null, [], null], ["grower", "gardener", "scratch", "WPT_HOME", [["WPT_CACHE", "."]], null], ["picker", "gardener", "scratch", "WPT_HOME", [["WPT_CACHE", "."]], null]]')"
  check "[C45] each seat expects the names of every scope that speaks for it, with the scopes and their origins" \
    test "$(jq -c '[.seats[] | [.seat[2], [.expects[]? | [.name, .scopes, [.origins[].line]]]]]' "$clone/PLAN/view.json")" = \
    '[["keeper",[["WPT_DOCK",["room"],[2]],["WPT_TOKEN",["workplace","seat"],[1,3]]]],["pilot",[["WPT_DOCK",["room"],[2]],["WPT_TOKEN",["workplace"],[1]]]],["watch",[["WPT_TOKEN",["workplace"],[1]]]],["grower",[["WPT_ORCHARD",["office"],[4]],["WPT_TOKEN",["workplace"],[1]]]],["picker",[["WPT_ORCHARD",["office"],[4]],["WPT_TOKEN",["workplace"],[1]]]]]'
  check "[C29] the fold's version is the one that reads homes and expected values" \
    test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-v4
  check "[C32] plan prints each seat's home and the names it expects" \
    bash -c 'grep -qF "seat Harbor Keeper (harbor/dock/keeper): kind navigator; clearance 0, by default; home kept, by WPT_HOME; expects WPT_DOCK, WPT_TOKEN;" "$1" && grep -qF "seat Orchard Grower (orchard/barn/grower): kind gardener; clearance 0, by default; home scratch, by WPT_HOME; expects WPT_ORCHARD, WPT_TOKEN;" "$1"' _ "$scratch/out"
  statements_plan
  check "plan with neither" exit_is 0 wplan
  check "[C45] a plan with no home and no expect gives no seat a home or an expects member" \
    test "$(jq '[.seats[] | has("home") or has("expects")] | any' "$clone/PLAN/view.json")" = false
  local planned
  planned=$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)
  statements_plan '.programs[-1].recorded += [{term: ["expect", "-", "-", "-", "workplace", "WPT_TOKEN"], origin: at(1)}] | .programs[-1].recorded |= map(select(.term[0] != "statement"))'
  check "[C45] a plan with an expect and no statement is folded, and refused for want of a row for /" exit_is 1 wplan
  check "[C45] naming a seat" said "no row for /"
  local plan_refusals=(
    '.programs[-1].recorded += [h(["home", "ghost", "WPT_X", "kept"]; 9)]|programs/HOMES.typify:9: the home names the kind ghost, which the plan does not make'
    '.programs[-1].recorded += [h(["home", "navigator", "WPT_HOME"]; 9)]|programs/HOMES.typify:9: a home has the words home KIND VARIABLE STATE, not 3'
    '.programs[-1].recorded += [h(["home", "navigator", "1BAD", "kept"]; 9)]|programs/HOMES.typify:9: 1BAD is not a variable name'
    '.programs[-1].recorded += [h(["home", "navigator", "WPT_HOME", "shared"]; 9)]|programs/HOMES.typify:9: shared is not kept or scratch'
    '.programs[-1].recorded += [h(["home", "navigator", "WPT_OTHER", "kept"]; 9)]|two homes of the kind navigator differ: WPT_HOME kept from programs/HOMES.typify:1, WPT_OTHER kept from programs/HOMES.typify:9'
    '.programs[-1].recorded += [h(["home-variable", "navigator", "WPT_CACHE", "other"]; 9)]|two home variables WPT_CACHE of the kind navigator differ: cache from programs/HOMES.typify:2, other from programs/HOMES.typify:9'
    '.programs[-1].recorded += [h(["home-variable", "navigator", "WPT_UP", "../up"]; 9)]|programs/HOMES.typify:9: ../up is not a path inside the home'
    '.programs[-1].recorded += [h(["home-variable", "navigator", "WPT_ABS", "/abs"]; 9)]|programs/HOMES.typify:9: /abs is not a path inside the home'
    '.programs[-1].recorded += [h(["home-variable", "navigator", "WPT_HOME", "x"]; 9)]|programs/HOMES.typify:9: the home variable WPT_HOME of the kind navigator is the variable that names its home'
    '.state.kinds = [{key: ["lookout"], value: ["declared"]}] | .programs[-1].recorded += [h(["home-variable", "lookout", "WPT_X", "x"]; 9)]|programs/HOMES.typify:9: the kind lookout has a home variable and no home'
    '.state.kinds = [{key: ["lookout"], value: ["declared"]}] | .programs[-1].recorded += [h(["home-seed", "lookout", "tools/seed"]; 9)]|programs/HOMES.typify:9: the kind lookout has a seed and no home'
    '.programs[-1].recorded += [h(["home-seed", "gardener", "tools/seed"]; 9)]|programs/HOMES.typify:9: the kind gardener has a scratch home, and build seeds only a kept one'
    '.programs[-1].recorded += [h(["home-seed", "navigator", "tools/other"]; 9)]|two seeds of the kind navigator differ: '"$root"'/tools/seed from programs/HOMES.typify:3, '"$root"'/tools/other from programs/HOMES.typify:9'
    '.programs[-1].recorded += [h(["home-seed", "navigator", "tools//seed"]; 9)]|programs/HOMES.typify:9 (home-seed): the path "tools//seed" is refused: it has an empty component'
    '.programs[-1].recorded += [v(["expect", "harbor", "dock", "ghost", "seat", "WPT_X"]; 9)]|programs/VALUES.typify:9: the expect names the seat harbor/dock/ghost, which the plan does not make'
    '.programs[-1].recorded += [v(["expect", "-", "-", "-", "workplace", "9X"]; 9)]|programs/VALUES.typify:9: 9X is not a variable name'
    '.programs[-1].recorded += [v(["expect", "navigator", "-", "-", "kind", "WPT_X"]; 9)]|programs/VALUES.typify:9: kind is not a scope of an expect'
    '.programs[-1].recorded += [h(["home", "gardener", "GNUPGHOME", "scratch"]; 9)]|programs/HOMES.typify:9: GNUPGHOME is a name the frame keeps for itself, and no home may take it'
    '.programs[-1].recorded += [h(["home-variable", "navigator", "SSH_AUTH_SOCK", "agent"]; 9)]|programs/HOMES.typify:9: SSH_AUTH_SOCK is a name the frame keeps for itself, and no home may take it'
    '.programs[-1].recorded += [v(["expect", "-", "-", "-", "workplace", "GNUPGHOME"]; 9)]|programs/VALUES.typify:9: GNUPGHOME is a name the frame keeps for itself, and no value may take it'
    '.programs[-1].recorded += [v(["expect", "-", "-", "-", "workplace", "PATH"]; 9)]|programs/VALUES.typify:9: PATH is a name every seat takes from its caller, and a value given at run time may not take it'
    '.programs[-1].recorded += [v(["expect", "harbor", "dock", "-", "room", "WPT_HOME"]; 9)]|seat Harbor Keeper (harbor/dock/keeper): it expects the value WPT_HOME, which the home of its kind navigator gives it (the expect at programs/VALUES.typify:9; the home at programs/HOMES.typify:1)'
    '.programs[-1].recorded += [v(["expect", "orchard", "barn", "picker", "seat", "WPT_CACHE"]; 9)]|seat Orchard Picker (orchard/barn/picker): it expects the value WPT_CACHE, which the home of its kind gardener gives it (the expect at programs/VALUES.typify:9; the home at programs/HOMES.typify:4, programs/HOMES.typify:5)'
  )
  local entry
  for entry in "${plan_refusals[@]}"; do
    check "[C45] plan refuses, with exit 1: ${entry##*|}" refused_by 1 plan "${entry%|*}" "${entry##*|}"
  done
  check "[C45] and after every refusal PLAN/ is as it was" test "$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)" = "$planned"
  local build_refusals=(
    '.state.environment += [{key: ["harbor", "dock", "keeper", "WPT_HOME"], value: ["/elsewhere"], masked: false, origin: at(40)}]|state environment: harbor/dock/keeper has a home, and its environment may not set WPT_HOME, which the frame gives (programs/policy.typify:40)'
    '.state.environment += [{key: ["orchard", "barn", "picker", "WPT_CACHE"], value: ["/elsewhere"], masked: false, origin: at(40)}]|state environment: orchard/barn/picker has a home, and its environment may not set WPT_CACHE, which the frame gives (programs/policy.typify:40)'
    '.state.environment += [{key: ["harbor", "dock", "keeper", "WPT_DOCK"], value: ["plain"], masked: false, origin: at(40)}]|state environment: harbor/dock/keeper expects the value WPT_DOCK at its start, and its environment may not set it (programs/policy.typify:40)'
    "$key_terms"' | .state.environment += [{key: ["harbor", "dock", "keeper", "SSH_AUTH_SOCK"], value: ["/elsewhere"], masked: false, origin: at(40)}]|state environment: harbor/dock/keeper holds a key, and its environment may not set SSH_AUTH_SOCK, which the frame gives (programs/policy.typify:40)'
  )
  for entry in "${build_refusals[@]}"; do
    check "[C48] build refuses, with exit 1: ${entry##*|}" refused_by 1 build "${entry%|*}" "${entry##*|}"
  done
  check "[C48] and leaves no BUILD" test ! -e "$clone/BUILD"
  check "[C45] the names the frame keeps are the binding's kept-names, the very names its fixed part gives" \
    test "$(jq -c '.["kept-names"] as $k | [.tables[]["after-rows"]?[]? | (.environment // [])[] | .[0]] | unique == ($k | sort) and $k == ["GNUPGHOME", "SSH_AUTH_SOCK"]' "$tool/host/binding.json")" = true
}

t_homes() {
  scoped_clone
  write_seed
  local w=$label s=$HOME/.local/state/workplace/$label
  local args='| add("harbor/dock/keeper/seat.typify"; ["report=" + $root + "/harbor/berth/keeper", "home=WPT_HOME", "value=WPT_CACHE", "hidden=" + $s + "/homes/02"])
    | add("harbor/tower/watch/seat.typify"; ["report=" + $root + "/harbor/charts/watch", "home=WPT_HOME", "hidden=" + $s])
    | add("orchard/barn/grower/seat.typify"; ["report=" + $root + "/orchard/almanac/grower", "home=WPT_HOME", "value=WPT_CACHE"])'
  statements_plan "$home_terms | $probe_args ${args//\$s/\"$s\"}"
  check "plan" exit_is 0 wplan
  check "[C46] build" exit_is 0 wp build
  check "[C46] it makes a kept home for keeper and for pilot, each seeded" \
    bash -c 'grep -qxF "home: $1/homes/01 made for Harbor Keeper (harbor/dock/keeper), and seeded by $2" "$3" && grep -qxF "home: $1/homes/02 made for Harbor Pilot (harbor/dock/pilot), and seeded by $2" "$3"' _ "$s" "$root/tools/seed" "$scratch/out"
  check "[C46] S/homes and each kept home are 0700" test "$(stat -c %a "$s/homes" "$s/homes/01" "$s/homes/02" | tr '\n' ' ')" = "700 700 700 "
  check "[C46] no directory stands for a scratch home, or for a seat of no kind" test "$(ls "$s/homes" | tr '\n' ' ')" = "01 02 "
  check "[C46] the frame's record names the seat of each kept home" \
    test "$(jq -c . "$s/homes.json")" = '{"01":{"seat":"harbor/dock/keeper","state":"made"},"02":{"seat":"harbor/dock/pilot","state":"made"}}'
  check "[C46] and only its owner may read it" test "$(stat -c %a "$s/homes.json")" = 600
  check "[C46] BUILD/homes.json, listed in the MANIFEST, holds each home with its variables" \
    bash -c 'grep -qE "^[0-9a-f]{64}  homes\.json$" "$1/MANIFEST" && [[ $(jq -c "[.seats[] | [.name, .state, .home, .environment]]" "$1/homes.json") == "$2" ]]' _ "$clone/BUILD" \
    "$(jq -c -n --arg s "$s" '[["Harbor Keeper", "kept", "homes/01", [["WPT_HOME", "\($s)/homes/01"], ["WPT_CACHE", "\($s)/homes/01/cache"]]],
      ["Harbor Pilot", "kept", "homes/02", [["WPT_HOME", "\($s)/homes/02"], ["WPT_CACHE", "\($s)/homes/02/cache"]]],
      ["Orchard Grower", "scratch", "homes/04", [["WPT_HOME", "\($s)/homes/04"], ["WPT_CACHE", "\($s)/homes/04"]]],
      ["Orchard Picker", "scratch", "homes/05", [["WPT_HOME", "\($s)/homes/05"], ["WPT_CACHE", "\($s)/homes/05"]]]]')"
  check "[C47] the seed ran once for each new kept home" test "$(grep -c '' "$HOME/seed-log")" = 2
  check "[C47] with the home and then the seat's declared directories, joined and each once, as its words" \
    test "$(cat "$s/homes/01/seeded" | tr '\n' ' ')" = "$root/harbor/berth $root/harbor/vault "
  check "[C47] in the home" grep -qxF "pwd $s/homes/01" "$s/homes/01/seeded.how"
  check "[C47] with nothing on standard input" grep -qxF "stdin /dev/null" "$s/homes/01/seeded.how"
  check "[C47] given the home's variables" grep -qxF "WPT_HOME=$s/homes/01 WPT_CACHE=$s/homes/01/cache" "$s/homes/01/seeded.how"
  check "[C47] and nothing of the caller's but the inherited names" \
    bash -c 'line=$(grep "^names " "$1"); for n in ${line#names }; do [[ " $2 PWD WPT_HOME WPT_CACHE " == *" $n "* ]] || exit 1; done' _ "$s/homes/01/seeded.how" "$(jq -r '.inherit | join(" ")' "$tool/host/binding.json")"
  if [[ $(nnp_of $$) == NoNewPrivs:1 ]]; then
    skip "[C47] the seed reports NoNewPrivs:1, but so would any process this shell starts; measured where the shell does not run under it"
  else
    check "[C47] under no-new-privileges" grep -qxF "NoNewPrivs:1" "$s/homes/01/seeded.how"
  fi
  check "[C48] up" exit_is 0 wp up
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  local report=$root/harbor/berth/keeper
  r() { grep -qxF -- "$2" "$1"; }
  check "[C48] keeper is given its home through the kind's variable" r "$report" "home WPT_HOME: $s/homes/01"
  check "[C48] and the further variable, the path inside it" r "$report" "value WPT_CACHE=$s/homes/01/cache"
  check "[C48] it writes there" r "$report" "home write: ok"
  check "[C48] it sees what the seed wrote" r "$report" "home seeded: $root/harbor/berth $root/harbor/vault "
  check "[C48] a kept home is the machine's directory itself" r "$report" "home where: $(stat -c %d:%i "$s/homes/01")"
  check "[C48] of the homes, keeper sees its own alone" r "$report" "home siblings: 01 "
  check "[C48] and of S, the homes alone" r "$report" "home state: homes "
  check "[C48] pilot's home is not shown to keeper" r "$report" "hidden $s/homes/02: unseen"
  check "grower ran" wait_for_probe "Orchard Grower" grower
  report=$root/orchard/almanac/grower
  check "[C48] grower's scratch home is a file system of the pane" r "$report" "home fs: tmpfs"
  check "[C48] made for it alone, not a directory of the mask around it" r "$report" "home own file system: yes"
  check "[C48] at its path, 0700, empty at the start and writable" \
    bash -c 'grep -qxF "home WPT_HOME: $2/homes/04" "$1" && grep -qxF "home mode: 700" "$1" && grep -qxF "home starts: 1" "$1" && grep -qxF "home entries: starts " "$1"' _ "$report" "$s"
  check "[C48] a further variable written . is the home itself" r "$report" "value WPT_CACHE=$s/homes/04"
  check "watch ran" wait_for_probe "Harbor Watch" watch
  check "[C48] a seat of no kind has no home variable" r "$root/harbor/charts/watch" "home WPT_HOME: unset"
  check "[C48] and is shown nothing of S" r "$root/harbor/charts/watch" "hidden $s: unseen"
  wp status > "$scratch/out" 2>&1
  check "[C51] status names each home and its state" \
    bash -c 'grep -qxF "home    Harbor Keeper (harbor/dock/keeper): kept at $2/homes/01, named to its program by WPT_HOME" "$1" && grep -qxF "home    Orchard Grower (orchard/barn/grower): scratch, a file system made when its pane starts at $2/homes/04, named to its program by WPT_HOME" "$1"' _ "$scratch/out" "$s"
  wp why "Harbor Keeper" "$s/homes/01/x" > "$scratch/out" 2>&1
  check "[C51] why names the seat's home, its variables, its seed and their terms" \
    bash -c 'grep -qxF "home: kept at $2/homes/01, named to its program by WPT_HOME, by the kind navigator'"'"'s term, from programs/HOMES.typify:1" "$1" && grep -qxF "  home variable WPT_CACHE: the home'"'"'s cache, from programs/HOMES.typify:2" "$1" && grep -qxF "  seeded by $3 when build makes the home, from programs/HOMES.typify:3" "$1"' _ "$scratch/out" "$s" "$root/tools/seed"
  check "[C51] and that a path in it is the seat's own, shown read-write" said "the seat's home: shown read-write at its own path by the frame after the rows (Home), to this seat alone"
  wp why "Harbor Watch" "$s/homes/01" > "$scratch/out" 2>&1
  check "[C51] for another seat the same path is masked" said "masked by the frame after the rows (Identity, Home): $HOME/.local/state/workplace, where workplaces keep their state, is shown to no seat"
  wp doctor > "$scratch/out" 2>&1
  check "[C51] doctor counts the homes" said "ok      the seats' homes in $s/homes: 2 kept, 2 scratch"
  mv -- "$s/homes/02" "$s/homes/02.away"
  check "[C51] status exits 1 for a kept home that is missing" exit_is 1 wp status
  check "[C51] naming it" said "missing home $s/homes/02 of Harbor Pilot (harbor/dock/pilot); build again"
  mv -- "$s/homes/02.away" "$s/homes/02"
  check "[C48] down" exit_is 0 wp down
  check "[C48] nothing of a scratch home is left on the machine" test "$(ls "$s/homes" | tr '\n' ' ')" = "01 02 "
  check "[C48] up again, with no build" exit_is 0 wp up
  check "keeper ran again" eventually bash -c 'grep -qxF "home starts: 2" "$1"' _ "$root/harbor/berth/keeper"
  check "[C46] a kept home keeps what its seat wrote" r "$root/harbor/berth/keeper" "home starts: 2"
  check "grower ran again" wait_for_probe "Orchard Grower" grower
  check "[C48] a scratch home starts empty every time" r "$root/orchard/almanac/grower" "home starts: 1"
  check "down" exit_is 0 wp down
  rm -rf -- "$clone/BUILD"
  check "[C47] build again" exit_is 0 wp build
  check "[C47] no seed runs for a home that exists" test "$(grep -c '' "$HOME/seed-log")" = 2
  check "[C47] and build says nothing of it" bash -c '! grep -q "^home: " "$1"' _ "$scratch/out"
  rm -rf -- "$clone/BUILD" "$s/homes/02"
  statements_plan "$home_terms | $probe_args"' | (.programs[-1].recorded[] | select(.term[0] == "home-seed") | .term[2]) = "tools/failing-seed"'
  check "plan with a failing seed" exit_is 0 wplan
  check "[C47] a seed that fails refuses the build, with exit 1" exit_is 1 wp build
  check "[C47] naming the seed, the kind, the seat and the exit, with what it said" \
    said "build refuses: the seed $root/tools/failing-seed of the kind navigator failed for Harbor Pilot (harbor/dock/pilot) with exit 3, and its new home is removed: the seed fails on purpose"
  check "[C47] its new home is removed, the old one kept, and the record names the old one alone" \
    bash -c '[[ ! -e $1/homes/02 && -d $1/homes/01 && $(jq -c "keys" "$1/homes.json") == "[\"01\"]" ]]' _ "$s"
  check "[C47] and no BUILD is left" test ! -e "$clone/BUILD"
  statements_plan "$home_terms | $probe_args"' | (.programs[-1].recorded[] | select(.term[0] == "home-seed") | .term[2]) = "tools/nothing"'
  check "plan with a seed that is not there" exit_is 0 wplan
  check "[C47] a seed that is not an executable file refuses the build" exit_is 1 wp build
  check "[C47] naming it" said "build refuses: the seed $root/tools/nothing of the kind navigator is not an executable file"
  statements_plan "$home_terms | $probe_args"
  check "plan" exit_is 0 wplan
  jq '.["01"].seat = "orchard/barn/picker"' "$s/homes.json" > "$scratch/h" && cp -- "$scratch/h" "$s/homes.json"
  check "[C46] a kept home that the record gives another seat refuses the build" exit_is 1 wp build
  check "[C46] naming both seats" said "build refuses: the home $s/homes/01 was made for the seat orchard/barn/picker, and the plan now places Harbor Keeper (harbor/dock/keeper) at 01 among the panes; move the home by hand"
  jq 'del(.["01"])' "$s/homes.json" > "$scratch/h" && cp -- "$scratch/h" "$s/homes.json"
  check "[C46] a directory the record does not name refuses the build" exit_is 1 wp build
  check "[C46] and is left alone" bash -c 'grep -qF "build refuses: $1/homes/01 exists, and $1/homes.json names no seat for it; the frame did not make it, so it is left alone" "$2" && [[ -f $1/homes/01/starts ]]' _ "$s" "$scratch/out"
  jq '.["01"] = {seat: "harbor/dock/keeper", state: "seeding"}' "$s/homes.json" > "$scratch/h" && cp -- "$scratch/h" "$s/homes.json"
  check "[C47] a home whose seed did not finish is made and seeded again" exit_is 0 wp build
  check "[C47] saying so" said "home: $s/homes/01 of Harbor Keeper (harbor/dock/keeper) was left unseeded by an earlier build, and is made again"
  check "[C47] the seed ran for it and for pilot's new home" test "$(grep -c '' "$HOME/seed-log")" = 4
}

t_values() {
  scoped_clone
  local s=$HOME/.local/state/workplace/$label values
  values=$HOME/.local/state/workplace/$label/values.json
  local keeper_token='keeper token: "quoted", $HOME, ${PATH}, a back\slash, # a mark, and  two spaces'
  local args='| add("harbor/dock/keeper/seat.typify"; ["report=" + $root + "/harbor/berth/keeper", "secret=WPT_TOKEN", "secret=WPT_DOCK", "env"])
    | add("harbor/tower/watch/seat.typify"; ["report=" + $root + "/harbor/charts/watch", "secret=WPT_TOKEN", "secret=WPT_DOCK"])
    | add("orchard/barn/grower/seat.typify"; ["report=" + $root + "/orchard/almanac/grower", "secret=WPT_TOKEN", "secret=WPT_ORCHARD"])'
  statements_plan "$value_terms | $probe_args $args"
  check "plan" exit_is 0 wplan
  check "[C49] build" exit_is 0 wp build
  mkdir -p -- "$s"
  jq -n --arg k "$keeper_token" '{workplace: {WPT_TOKEN: "the workplace token"}, rooms: {"harbor/dock": {WPT_DOCK: "the dock value"}},
    seats: {"harbor/dock/keeper": {WPT_TOKEN: $k}}}' > "$values"
  chmod 0600 -- "$values"
  check "[C49] a value missing at every place of a seat refuses up, with exit 1" exit_is 1 wp up
  check "[C49] naming the value and each seat" \
    bash -c 'grep -qF "the seat Orchard Grower (orchard/barn/grower) expects the value WPT_ORCHARD, and $2 gives it at none of its places: the seat, its room, its office, the workplace" "$1" && grep -qF "the seat Orchard Picker (orchard/barn/picker) expects the value WPT_ORCHARD" "$1"' _ "$scratch/out" "$values"
  check "[C49] and starts nothing" bash -c '[[ ! -e $1 ]]' _ "$run"
  check "[C49] no server" no_server
  jq '.offices = {orchard: {WPT_ORCHARD: "the orchard value"}}' "$values" > "$scratch/v" && cp -- "$scratch/v" "$values"
  chmod 0644 -- "$values"
  check "[C49] a run-time file that others can read refuses up" exit_is 1 wp up
  check "[C49] naming its mode" said "$values has the mode 644, and others than its owner may read it"
  check "[C49] and starts nothing" test ! -e "$run"
  chmod 0600 -- "$values"
  printf '%s\n' '{"workplace": {"WPT_TOKEN": 1}}' > "$scratch/bad" && cp -- "$scratch/bad" "$values"
  check "[C49] a run-time file of another form refuses up" exit_is 1 wp up
  check "[C49] naming what is wrong" said "$values: its workplace gives WPT_TOKEN a value that is not text"
  jq -n '{workplace: {WPT_TOKEN: ""}, rooms: {"harbor/dock": {WPT_DOCK: "two\nlines"}}, seats: {"orchard/barn/picker": {WPT_NUL: "a\u0000b"}}}' > "$values"
  check "[C49] an empty value, one of two lines and one with a NUL byte refuse up" exit_is 1 wp up
  check "[C49] naming each name and no value" \
    bash -c 'grep -qF "$2: its workplace gives WPT_TOKEN an empty value" "$1" && grep -qF "$2: its rooms entry \"harbor/dock\" gives WPT_DOCK a value of more than one line, or with a NUL byte" "$1" && grep -qF "$2: its seats entry \"orchard/barn/picker\" gives WPT_NUL a value of more than one line, or with a NUL byte" "$1" && ! grep -q lines "$1"' _ "$scratch/out" "$values"
  jq -n --arg k "$keeper_token" '{workplace: {WPT_TOKEN: "the workplace token"}, rooms: {"harbor/dock": {WPT_DOCK: "the dock value"}},
    offices: {orchard: {WPT_ORCHARD: "the orchard value"}}, seats: {"harbor/dock/keeper": {WPT_TOKEN: $k}}}' > "$values"
  check "[C49] up" exit_is 0 wp up
  cp -- "$scratch/out" "$scratch/said-up"
  sha() { local sum; sum=$(printf '%s' "$1" | sha256sum); printf '%s\n' "${sum%% *}"; }
  r() { grep -qxF -- "$2" "$1"; }
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  check "[C49] keeper is given its own value, the narrowest, exactly as written" r "$root/harbor/berth/keeper" "secret WPT_TOKEN: sha256 $(sha "$keeper_token")"
  check "[C49] and its room's" r "$root/harbor/berth/keeper" "secret WPT_DOCK: sha256 $(sha "the dock value")"
  check "[C49] as variables of its environment, with no other new name" \
    bash -c 'grep -q "^env .* WPT_DOCK WPT_TOKEN" "$1" && ! grep -q WORKPLACE_VALUE "$1"' _ "$root/harbor/berth/keeper"
  check "watch ran" wait_for_probe "Harbor Watch" watch
  check "[C49] watch is given the workplace's" r "$root/harbor/charts/watch" "secret WPT_TOKEN: sha256 $(sha "the workplace token")"
  check "[C49] and nothing it does not expect" r "$root/harbor/charts/watch" "secret WPT_DOCK: unset"
  check "grower ran" wait_for_probe "Orchard Grower" grower
  check "[C49] grower is given its office's" r "$root/orchard/almanac/grower" "secret WPT_ORCHARD: sha256 $(sha "the orchard value")"
  check "[C50] exec --print" exit_is 0 wp exec --print "Harbor Keeper"
  cp -- "$scratch/out" "$scratch/said-print"
  check "[C50] shows each value's place by its name" \
    test "$(jq -c '.[2:4]' "$scratch/said-print")" = '["-S","WPT_DOCK=${WORKPLACE_VALUE_WPT_DOCK} WPT_TOKEN=${WORKPLACE_VALUE_WPT_TOKEN}"]'
  local wrap=$scratch/wrap real_env
  real_env=$(command -v env)
  mkdir -p -- "$wrap"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\0" "$0" "$@" > "$WPT_ARGV_LOG"' "exec ${real_env@Q} \"\$@\"" > "$wrap/env"
  chmod +x -- "$wrap/env"
  env PATH="$wrap:$PATH" WPT_ARGV_LOG="$scratch/argv" "$BASH" "$loop" exec --print "Harbor Keeper" > "$scratch/wrapped-print" 2>&1
  (cd / && env PATH="$wrap:$PATH" WPT_ARGV_LOG="$scratch/argv" "$BASH" "$loop" exec "Harbor Keeper" < /dev/null > "$scratch/hand" 2>&1)
  check "[C50] the call exec makes is the one it prints, word for word, with no value in it" \
    test "$(jq -R -s -c 'split("\u0000")[:-1]' "$scratch/argv")" = "$(jq -c . "$scratch/wrapped-print")"
  check "[C49] and by hand the seat is given the same values" grep -qxF "secret WPT_TOKEN: sha256 $(sha "$keeper_token")" "$scratch/hand"
  wp status > "$scratch/out" 2>&1
  cp -- "$scratch/out" "$scratch/said-status"
  check "[C51] status names each value a seat expects and the place that gives it" \
    grep -qxF "values  Harbor Keeper (harbor/dock/keeper): WPT_DOCK by the room, WPT_TOKEN by the seat" "$scratch/said-status"
  wp why "Harbor Keeper" "$root/harbor/berth" > "$scratch/out" 2>&1
  cp -- "$scratch/out" "$scratch/said-why"
  check "[C51] why names each value, its terms and the place that supplies it" \
    grep -qxF "value WPT_TOKEN: expected by the workplace's and the seat's terms, from programs/VALUES.typify:1, programs/VALUES.typify:3; supplied by the seat in $values" "$scratch/said-why"
  wp doctor > "$scratch/out" 2>&1
  cp -- "$scratch/out" "$scratch/said-doctor"
  check "[C51] doctor names the run-time file without its values" said "ok      the run-time file $values, which only its owner may read; its values are not shown"
  check "[C51] and that env fills a value's place" said "ok      env takes -S and fills a variable's place in it"
  chmod 0640 -- "$values"
  check "[C51] status exits 1 for a run-time file it refuses" exit_is 1 wp status
  check "[C51] naming why" said "refused $values has the mode 640, and others than its owner may read it"
  cp -- "$scratch/out" "$scratch/said-status-loose"
  wp doctor > "$scratch/said-doctor-loose" 2>&1
  check "[C51] and so does doctor" grep -qF "refused $values has the mode 640" "$scratch/said-doctor-loose"
  check "[C49] exec refuses it too, with exit 2" exit_is 2 wp exec --print "Harbor Keeper"
  cp -- "$scratch/out" "$scratch/said-exec-loose"
  chmod 0600 -- "$values"
  jq 'del(.rooms)' "$values" > "$scratch/v" && cp -- "$scratch/v" "$values"
  check "[C49] a value removed after up refuses the seat's start by hand, with exit 2" exit_is 2 wp exec "Harbor Keeper" < /dev/null
  cp -- "$scratch/out" "$scratch/said-exec"
  check "[C49] naming the value and the seat" said "the seat Harbor Keeper (harbor/dock/keeper) expects the value WPT_DOCK, and $values gives it at none of its places"
  check "[C51] status exits 1 for a missing value" exit_is 1 wp status
  check "[C51] naming it" said "values  Harbor Keeper (harbor/dock/keeper): WPT_DOCK missing, WPT_TOKEN by the seat"
  cp -- "$scratch/out" "$scratch/said-status-missing"
  wp why "Harbor Keeper" "$root/harbor/berth" > "$scratch/said-why-missing" 2>&1
  check "[C51] and why says it is missing" grep -qF "value WPT_DOCK: expected by the room's term, from programs/VALUES.typify:2; missing from $values" "$scratch/said-why-missing"
  local -a kept=("$run"/ledger "$run"/checks "$run"/calls.jsonl "$run"/state.json "$run"/slots.json "$run"/tables.json "$run"/seats/*.json)
  mkdir -p -- "$scratch/run-copy"
  cp -- "${kept[@]}" "$scratch/run-copy/"
  T show-environment -g > "$scratch/said-server" 2>&1
  check "[C49] down" exit_is 0 wp down
  cp -- "$scratch/out" "$scratch/said-down"
  local new_token="a new keeper token"
  jq --arg k "$new_token" '.seats["harbor/dock/keeper"].WPT_TOKEN = $k | .rooms = {"harbor/dock": {WPT_DOCK: "the dock value"}}' "$values" > "$scratch/v" && cp -- "$scratch/v" "$values"
  check "[C49] a value changed with no new plan and no new build" exit_is 0 wp up
  check "keeper ran with it" eventually bash -c 'grep -qxF "secret WPT_TOKEN: sha256 $2" "$1"' _ "$root/harbor/berth/keeper" "$(sha "$new_token")"
  check "[C49] reaches its seat at the next up" r "$root/harbor/berth/keeper" "secret WPT_TOKEN: sha256 $(sha "$new_token")"
  cat "$scratch/out" >> "$scratch/said-up"
  check "down" exit_is 0 wp down
  printf '%s\n' "the workplace token" "the dock value" "the orchard value" "$new_token" > "$scratch/patterns"
  printf '%s\n' "$keeper_token" >> "$scratch/patterns"
  check "[C50] no value stands in any message of build, up, exec --print, exec, status, why, doctor or down, in the ledger, the run's checks, calls, state, slots or seats, in BUILD, or in the server's environment" \
    bash -c '! grep -rlF -f "$1" "$2"/said-* "$2"/run-copy "$2"/hand "$3"' _ "$scratch/patterns" "$scratch" "$clone/BUILD"
}

t_the_clone_is_masked() {
  scoped_clone
  write_seed
  cp -- "$root/tools/seed" "$clone/seed"
  local args='| add("harbor/dock/keeper/seat.typify"; ["report=" + $root + "/harbor/berth/keeper", "hidden=" + $root + "/config", "list=" + $root + "/config", "hidden=" + $root + "/config/BUILD"])
    | add("harbor/tower/watch/seat.typify"; ["report=" + $root + "/harbor/charts/watch", "hidden=" + $root + "/config"])
    | .programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; $root + "/config"; "read-only"; 22)]
    | (.programs[-1].recorded[] | select(.term[0] == "home-seed") | .term[2]) = "config/seed"'
  statements_plan "$home_terms | $probe_args $args"
  check "plan with a row that opens the clone to keeper, and a seed in the clone" exit_is 0 wplan
  check "[C52] build runs a seed that lies in the clone, outside every view" exit_is 0 wp build
  check "[C52] it ran" said "home: $HOME/.local/state/workplace/$label/homes/01 made for Harbor Keeper (harbor/dock/keeper), and seeded by $clone/seed"
  check "up" exit_is 0 wp up
  check "[C52] keeper's view masks the clone after its rows: the row's bind, then the closed file system" \
    test "$(view_ops "$(seat_command 'Harbor Keeper')" | sed 's/^ro-bind /bind /' | grep -nxE "(bind|tmpfs) $clone" | cut -d: -f2 | tr '\n' ',')" = "bind $clone,tmpfs $clone,"
  check "[C52] and closes it: 0000" test "$(jq -r --arg c "$clone" '. as $a | [range(0; length) | select($a[.] == "--tmpfs" and $a[. + 1] == $c) | $a[. - 1]] | join(",")' <<< "$(seat_command 'Harbor Keeper')")" = 0000
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  local report=$root/harbor/berth/keeper
  check "[C52] inside keeper's pane the clone cannot be listed, though a row would open it" \
    bash -c 'grep -qxF "hidden $2: unseen" "$1" && grep -qxF "list $2: refused" "$1" && grep -qxF "hidden $2/BUILD: unseen" "$1"' _ "$report" "$clone"
  check "watch ran" wait_for_probe "Harbor Watch" watch
  check "[C52] nor in watch's" grep -qxF "hidden $clone: unseen" "$root/harbor/charts/watch"
  wp why "Harbor Keeper" "$clone/BUILD" > "$scratch/out" 2>&1
  check "[C52] why names the mask" said "masked by the frame after the rows: $clone, the clone the workplace is built from, with its PLAN and BUILD, is shown to no seat, whatever its rows say"
  check "down" exit_is 0 wp down
  local planned
  planned=$(cat "$clone/PLAN/plan.json" "$clone/PLAN/manifest.json" | sha256sum)
  local refusals=(
    '(.programs[] | select(.path == "harbor/dock/keeper/seat.typify") | .plan[1].term[4]) = "config"|harbor/dock/keeper/seat.typify, term 2 (start): the seat'"'"'s directory '"$clone"' lies in the clone '"$clone"', which the frame masks in every view'
    '(.programs[] | select(.path == "harbor/dock/keeper/seat.typify") | .plan[1].term[5]) = (["config/tools/probe"] | tojson)|harbor/dock/keeper/seat.typify, term 2 (start): the seat'"'"'s program '"$clone"'/tools/probe lies in the clone '"$clone"', which the frame masks in every view'
    '.programs[-1].recorded += [h(["record-directory", "harbor", "dock", "pilot", "config/work"]; 9)]|programs/HOMES.typify:9 (record-directory): the seat'"'"'s directory '"$clone"'/work lies in the clone '"$clone"', which the frame masks in every view'
  )
  local entry
  for entry in "${refusals[@]}"; do
    statements_plan "$home_terms | ${entry%|*}"
    check "[C52] plan refuses, with exit 1, a seat in the clone: ${entry##*|}" exit_is 1 wplan
    check "[C52] naming it" said "${entry##*|}"
  done
  check "[C52] and PLAN/ is as it was" test "$(cat "$clone/PLAN/plan.json" "$clone/PLAN/manifest.json" | sha256sum)" = "$planned"
  jq --arg c "$clone" '(.programs[] | select(.path == "harbor/dock/keeper/seat.typify") | .plan[1].term[4]) = $c' "$clone/PLAN/plan.json" > "$scratch/p" \
    && cp -- "$scratch/p" "$clone/PLAN/plan.json"
  jq --arg s "$(sha256sum < "$clone/PLAN/plan.json" | cut -d' ' -f1)" '(.outputs[] | select(.path == "plan.json") | .sha256) = $s' "$clone/PLAN/manifest.json" > "$scratch/m" \
    && cp -- "$scratch/m" "$clone/PLAN/manifest.json"
  rm -rf -- "$clone/BUILD"
  check "[C52] build refuses such a plan too" exit_is 1 wp build
  check "[C52] naming it" said "harbor/dock/keeper/seat.typify, term 2 (start): the seat's directory $clone lies in the clone $clone"
}

t_a_server_belongs_to_one_clone() {
  label=default
  render default > "$scratch/plan.json"
  check "build and up a workplace whose server is named default, as any clone's may be" up_fixture
  check "[C53] up marks its server with its clone" test "$(T show-options -gqv @workplace-clone)" = "$clone"
  wp status > "$scratch/out" 2>&1
  check "[C53] status reads the mark" said "ok      the server, process $(T display -p '#{pid}'), carries this clone's mark"
  local second=$root/config2 socket=$TMUX_TMPDIR/tmux-$UID/default
  make_clone "$second"
  cp -- "$scratch/plan.json" "$scratch/plan-first.json"
  render default "$second/tmux.conf" > "$scratch/plan.json"
  PLAN_CLONE=$second make_plan
  cp -- "$scratch/plan-first.json" "$scratch/plan.json"
  check "build another clone that names the same server" env WORKPLACE_CONFIG="$second" "$BASH" "$loop" build
  check "[C53] its up refuses the server that carries the first clone's mark, with exit 1" exit_is 1 env WORKPLACE_CONFIG="$second" "$BASH" "$loop" up
  check "[C53] naming both clones" said "the tmux server default at $socket carries the mark of the clone $clone, not this one's ($second); up leaves it alone"
  check "[C53] before any term: the other clone has no run" test ! -e "$second/BUILD/RUN"
  check "[C53] and the first's sessions stand as they were" sessions_are "Harbor Orchard "
  check "down" exit_is 0 wp down
  T -f /dev/null new-session -d -s foreign
  check "[C53] up refuses a server that holds sessions and carries no mark, with exit 1" exit_is 1 wp up
  check "[C53] naming it" said "the tmux server default at $socket holds sessions (1) and carries no clone's mark; up leaves it alone"
  check "[C53] and leaves its session alone" sessions_are "foreign "
  T kill-server
  check "up" exit_is 0 wp up
  T new-session -d -s extra
  check "down, while another session keeps the server" exit_is 0 wp down
  check "the server stands, with its mark" test "$(T show-options -gqv @workplace-clone)" = "$clone"
  check "[C53] up again takes the workplace's own server, which carries its mark" exit_is 0 wp up
  check "[C53] and stands in it" sessions_are "Harbor Orchard extra "
  T set-option -g @workplace-clone /elsewhere
  check "[C53] status exits 1 when the server carries another clone's mark" exit_is 1 wp status
  check "[C53] naming it" said "refused the server at $socket carries the mark of the clone /elsewhere, not this one's"
  check "[C53] down refuses it, with exit 2" exit_is 2 wp down
  check "[C53] and keeps RUN" test -d "$run"
  T set-option -gu @workplace-clone
  check "[C53] status exits 1 when the run's own server has lost its mark" exit_is 1 wp status
  check "[C53] telling it from another server by the process the run recorded" said "missing the server, process $(T display -p '#{pid}'), is the run's own and has lost its mark"
  check "[C53] down goes on, each undo checking its own mark" exit_is 0 wp down
  check "[C53] and leaves the other session" sessions_are "extra "
  T kill-server
}

t_source_and_contract() {
  check "[C8] the loop holds no eval" bash -c '! grep -nw eval "$1"/bin/workplace "$1"/libexec/*' _ "$tool"
  check "[C8] the loop holds no sh -c or bash -c" \
    bash -c '! grep -nE "(^|[^[:alnum:]])(ba)?sh -c" "$1"/bin/workplace "$1"/libexec/* "$1"/host/binding.json' _ "$tool"
  check "[C17] nothing sends keys or pastes into a pane: no send-keys, send, send-prefix or paste-buffer in the loop or the binding" \
    bash -c '! grep -rnwE "send-keys|send|send-prefix|paste-buffer|pasteb" "$1"/bin "$1"/libexec "$1"/host' _ "$tool"
  check "[C9] every -t of the binding names a captured slot, never a name or an index" \
    test "$(jq '[.primitives[] | (.call, .then, .claim.call, .undo.when, .undo.call, .check.call) | select(. != null) | . as $c
      | range(0; length) | select($c[.] == "-t") | $c[. + 1] | (type == "object" and has("slot"))] | all' "$tool/host/binding.json")" = true
  check "[C17] respawn-pane -k is followed by clear-history in start" \
    test "$(jq -r '.primitives.start.call | map(strings) | (index("respawn-pane") < index("clear-history"))' "$tool/host/binding.json")" = true
  check "[C10] every tmux call runs under setpriv --no-new-privs and names its server" \
    test "$(jq -c '.programs.tmux.argv[0:5]' "$tool/host/binding.json")" = '[{"slot":["program","setpriv"]},"--no-new-privs",{"slot":["program","tmux"]},"-L",{"slot":["server"]}]'
  check "[C10] the loop removes TMUX and TMUX_PANE before any program runs" \
    test "$(sed -n 6p "$tool/bin/workplace")" = "unset TMUX TMUX_PANE"
  check "[C26] the loop sets LC_ALL=C before anything else, once it has kept the caller's" \
    test "$(sed -n 2,3p "$tool/bin/workplace")" = 'if [[ -n ${LC_ALL+set} ]]; then caller_lc_all=$LC_ALL; fi
export LC_ALL=C'
  check "[C26] and so does this test file" test "$(sed -n 2p "$here/run.sh")" = "export LC_ALL=C"
  check "every tmux call of these tests names its server" \
    bash -c '! grep -nE "(^|[;&|({!]|\\\$\\()[[:space:]]*tmux " "$1" | grep -vE "tmux -L|tmux -S"' _ "$here/run.sh"
  check "the tests run as a user, not root" test "$EUID" -ne 0
  check "nothing of the loop runs through sudo, doas or pkexec" \
    bash -c '! grep -rnwE "sudo|doas|pkexec" "$1"/bin "$1"/libexec "$1"/host' _ "$tool"
  check "bubblewrap is not setuid" test ! -u "$(command -v bwrap)"
  local n missing=""
  for n in $(grep -oE '\*\*C[0-9]+\.\*\*' "$tool/CONTRACT.md" | tr -d '*.'); do
    grep -qE "^[[:space:]]*check \"\\[$n\\]" "$here/run.sh" || missing+=" $n"
  done
  check "every sentence of the contract is shown by a check that carries its number${missing:+ (missing:$missing)}" test -z "$missing"
}

tests=(
  t_inputs_and_refusals
  t_program_floors
  t_structure_and_order
  t_a_foreign_tmux_in_the_environment
  t_programs_out_of_order
  t_room_of_eight
  t_views
  t_relative_paths
  t_environment
  t_exec_by_hand
  t_fixed_part
  t_server_privilege
  t_failure_leaves_nothing
  t_failure_between_a_session_and_its_mark
  t_unattached_options
  t_down_removes_only_its_own
  t_status_and_down_on_a_damaged_run
  t_down_after_the_server_restarted
  t_two_workplaces
  t_the_default_name
  t_structure_and_form_refusals
  t_the_name_by_its_rule
  t_the_callers_locale
  t_without_bubblewrap
  t_hostile_text
  t_why
  t_doctor
  t_the_reference_plan_as_printed
  t_plan_assembles
  t_plan_refusals
  t_the_fold
  t_plan_relative
  t_the_folded_view_in_the_panes
  t_plan_end_to_end
  t_identity_selection
  t_identity
  t_home_and_values_selection
  t_homes
  t_values
  t_the_clone_is_masked
  t_a_server_belongs_to_one_clone
  t_source_and_contract
)
(( $# )) && tests=("$@")

for name in "${tests[@]}"; do
  note "== $name"
  (
    test_failed=0
    label2=""
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
if [[ -s $skips ]]; then
  note "== $(grep -c '' "$skips") checks skipped, each with its reason:"
  sed 's/^/   /' "$skips"
fi
rm -f -- "$skips"
(( failures == 0 )) || { note "failed: ${failed_tests[*]}"; exit 1; }
