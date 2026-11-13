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
left=()
for path in /tmp/wpt.* /tmp/wpt-skips.*; do
  [[ -e $path || -L $path ]] && left+=("$path")
done
if (( ${#left[@]} )); then
  printf '%s\n' "== left by another run, and not touched: ${left[*]}"
fi
skips=$(mktemp /tmp/wpt-skips.XXXXXX)
trap 'rm -f -- "$skips"' EXIT
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

T() { setpriv --no-new-privs tmux -S "$run/$label" -u "$@"; }
B() { setpriv --no-new-privs tmux -L bystander -u "$@"; }
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
  cp -- "$fixtures/probe" "$fixtures/racer" "$fixtures/paster" "$fixtures/forge" "$root/tools/"
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
    { cmdline=$(tr '\0' ' ' < "$entry"); } 2> /dev/null || continue
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

processes_naming() {
  local entry
  local -a argv
  for entry in /proc/[0-9]*; do
    [[ ${entry#/proc/} == "$BASHPID" ]] && continue
    { mapfile -d '' -t argv < "$entry/cmdline"; } 2> /dev/null || continue
    [[ ${argv[*]-} == *"$1/"* ]] && printf '%s\n' "${entry#/proc/}"
  done
}

end_processes_naming() {
  local round i
  local -a left
  for round in TERM KILL; do
    mapfile -t left < <(processes_naming "$1")
    (( ${#left[@]} )) || return 0
    kill "-$round" "${left[@]}" 2> /dev/null
    for (( i = 0; i < 40; i++ )); do
      mapfile -t left < <(processes_naming "$1")
      (( ${#left[@]} )) || return 0
      sleep 0.05
    done
  done
  note "  FAIL: the test left processes that name its scratch $1 and outlive SIGKILL: ${left[*]}"
  return 1
}

cleanup() {
  local home status=0
  [[ -n ${scratch-} && -d $scratch ]] || return 0
  if command -v gpgconf > /dev/null; then
    while IFS= read -r home; do
      agent_of "$home" && gpgconf --homedir "$home" --kill gpg-agent > /dev/null 2>&1
      gpgconf --homedir "$home" --remove-socketdir > /dev/null 2>&1
    done < <(key_homes)
  fi
  [[ -n ${label-} && -S ${run-}/$label ]] && tmux -S "$run/$label" kill-server 2> /dev/null
  if [[ -n ${label-} ]] && command -v systemctl > /dev/null; then
    timeout 30 systemctl --user stop -- "workplace-carrier-$label.service" > /dev/null 2>&1
  fi
  [[ -n ${label2-} && -S ${root-}/config2/BUILD/RUN/$label2 ]] && tmux -S "$root/config2/BUILD/RUN/$label2" kill-server 2> /dev/null
  if [[ ${TMUX_TMPDIR-} == "$scratch"/* ]]; then
    for home in "$TMUX_TMPDIR/tmux-$UID"/*; do
      [[ -S $home ]] && tmux -S "$home" kill-server 2> /dev/null
    done
  fi
  end_processes_naming "$scratch" || status=1
  rm -rf -- "$scratch"
  return "$status"
}

pane_by_title() {
  T list-panes -a -F '#{pane_title}	#{pane_id}' 2> /dev/null | while IFS=$'\t' read -r title id; do
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
        elif $c[$i] == "--remount-ro" then "remount-ro \($c[$i + 1])", walk_ops($i + 2)
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
    "start-server new-session set-option new-session set-option rename-window new-window rename-window display-message select-pane split-window select-pane display-message select-pane display-message select-pane split-window select-pane select-layout select-layout select-layout set-option set-option set-option set-option set-option "
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
  B -f /dev/null new-session -d -s bystander
  B select-pane -t =bystander: -T Bystander
  local socket pane
  socket=$(B display -p -t =bystander: '#{socket_path},#{pid},#{session_id}')
  pane=$(B display -p -t =bystander: '#{pane_id}')
  make_plan
  check "build" exit_is 0 wp build
  check "[C10] up with TMUX and TMUX_PANE naming the bystander's pane" \
    exit_is 0 env TMUX="$socket" TMUX_PANE="$pane" "$BASH" "$loop" up
  check "[C10] every title landed on its own seat, in the workplace's own server" \
    test "$(T list-panes -a -F '#{pane_title}' | sort | tr '\n' ',')" = "Harbor Keeper,Harbor Pilot,Harbor Watch,Orchard Grower,Orchard Picker,"
  check "[C11] no run mark reached the bystander's server, nor any pane" \
    test "$(B show-options -qv -t =bystander: @workplace)$(B list-panes -a -F '#{pane_title}')" = Bystander
  check "[C10] down with the same environment" exit_is 0 env TMUX="$socket" TMUX_PANE="$pane" "$BASH" "$loop" down
  check "[C18] the bystander survives" test "$(B list-sessions -F '#{session_name}')" = bystander
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
  [[ -d $TMUX_TMPDIR/tmux-$UID ]] && expected+=$'\n'"tmpfs $TMUX_TMPDIR/tmux-$UID"
  [[ -d /tmp/tmux-$UID && /tmp/tmux-$UID != "$TMUX_TMPDIR/tmux-$UID" ]] && expected+=$'\n'"tmpfs /tmp/tmux-$UID"
  [[ -d /run/user/$EUID ]] && expected+=$'\n'"tmpfs /run/user/$EUID"
  expected+=$'\n'"tmpfs $HOME/.local/state/workplace"
  [[ -d /run/user/$EUID ]] && expected+=$'\n'"remount-ro /run/user/$EUID"
  check "[C12] keeper's view: / first, then /proc and /dev, then the rows in byte order, then the frame's masks (C39, C52, C68, C84), the runtime directory's made read-only last" \
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
  local long=$root/a-directory-whose-name-is-long-enough-to-carry-the-clone-past-the-length-of-a-socket
  make_clone "$long/config"
  local second=$long/config label_long
  label_long=$(name_of_clone "$second")
  cp -- "$scratch/plan.json" "$scratch/plan-first.json"
  render "$label_long" "$second/tmux.conf" > "$scratch/plan.json"
  PLAN_CLONE=$second make_plan
  cp -- "$scratch/plan-first.json" "$scratch/plan.json"
  check "build a clone whose path is long" exit_is 0 env WORKPLACE_CONFIG="$second" "$BASH" "$loop" build
  check "[C68] up refuses, with exit 2, a server whose socket's path would be too long for a socket" exit_is 2 env WORKPLACE_CONFIG="$second" "$BASH" "$loop" up
  check "[C68] naming the path and its length" said "the server's socket would be $second/BUILD/RUN/$label_long, $(( ${#second} + 11 + ${#label_long} )) bytes, and a socket's path holds at most 107"
  check "[C68] and starts nothing" test ! -e "$second/BUILD/RUN"
}

t_a_server_that_ends_before_its_check() {
  local real dead wrap=$scratch/ending
  real=$(command -v tmux)
  true &
  dead=$!
  wait "$dead"
  mkdir -p -- "$wrap"
  printf '%s\n' '#!/usr/bin/env bash' "for word in \"\$@\"; do" \
    "  [[ \$word == new-session ]] || continue" "  out=\$('$real' \"\$@\") || exit" "  read -r a b _ <<< \"\$out\"" "  printf '%s\\n' \"\$a \$b $dead\"" "  exit 0" "done" \
    "exec '$real' \"\$@\"" > "$wrap/tmux"
  chmod +x -- "$wrap/tmux"
  make_plan
  check "build" exit_is 0 wp build
  check "[C10] up refuses, with exit 1, when the server that a session term names has ended before its status is read" exit_is 1 env PATH="$wrap:$PATH" "$BASH" "$loop" up
  check "[C10] saying so, as a refusal of its own, and naming the server" \
    said "harbor/office.typify, term 1 (session harbor Harbor): the tmux server (process $dead) has ended, and its status could not be read; it is refused"
  check "[C10] and leaves nothing up" test ! -e "$run"
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
  check "[C19] up exits 1 at the last start" exit_is 1 wp up
  check "[C19] the failure names the directory" said "$root/orchard/gone is not a directory"
  check "[C19] every session it made is torn down, by its captured id" said "undo session/harbor: done"
  check "[C19] and no server is left" no_server
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
      local socket=$run/$label
      check "[C11] the refusal names the empty server it leaves and the command that ends it, and keeps RUN, which holds its socket" \
        said "the tmux server at $socket is left running with no session, and the loop never ends a server; $run, which holds its socket, is kept while it stands. To end it: tmux -S ${socket@Q} kill-server, and then remove $run"
      check "[C11] RUN is kept" test -d "$run"
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
  check "[C18] it keeps RUN, which holds the server's socket, while the server holds them" test -d "$run"
  check "[C18] saying so" said "still holds sessions that this run did not make (2)"
  T kill-server
  check "[C18] down again, once the server has ended" exit_is 0 wp down
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
  check "[C18] down from a shell whose TMUX_TMPDIR differs reaches the run's server by its socket's path" exit_is 0 env TMUX_TMPDIR="$elsewhere" "$BASH" "$loop" down
  check "[C18] and removes RUN" test ! -e "$run"
}

t_down_after_the_server_restarted() {
  check "build and up" up_fixture
  local first i
  first=$(T display -p -t =Harbor: '#{session_id}')
  T kill-server
  for (( i = 0; i < 100; i++ )); do [[ -S $run/$label ]] || break; sleep 0.05; done
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
  check "[C25] build and up the second" exit_is 0 bash -c 'WORKPLACE_CONFIG=$1 "$BASH" "$2" build && WORKPLACE_CONFIG=$1 "$BASH" "$2" up' _ "$second" "$loop"
  check "[C25] each has its own server" \
    test "$(tmux -S "$second/BUILD/RUN/$label2" list-sessions -F '#{session_name}' | sort | tr '\n' ' ')" = "Harbor Orchard "
  check "[C25] down the first" exit_is 0 wp down
  check "[C25] the first is gone" no_server
  check "[C25] the second stands" test "$(tmux -S "$second/BUILD/RUN/$label2" list-panes -a -F x | wc -l)" = 5
  check "[C25] down the second" exit_is 0 bash -c 'WORKPLACE_CONFIG=$1 "$BASH" "$2" down' _ "$second" "$loop"
}

t_the_default_name() {
  render default > "$scratch/plan.json"
  label=default
  make_plan
  jq 'del(.derivations)' "$clone/PLAN/manifest.json" > "$scratch/manifest" && cp -- "$scratch/manifest" "$clone/PLAN/manifest.json"
  check "[C25] a plan whose server term says default builds, with no rule for the name" exit_is 0 wp build
  check "[C25] and comes up" exit_is 0 wp up
  check "[C25] its server is named default, and its socket stands in the clone's run directory" test -S "$run/default"
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
  check "[C26] up under C, with a TMUX_TMPDIR whose name is not ASCII, and the run's socket where it always stands" exit_is 0 wp up
  check "[C26] the run records the socket as it is" \
    test "$(jq -r '.slots[(["socket"] | tojson)]' "$run/state.json")" = "$run/$label"
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

t_why_says_what_the_nearest_row_means() {
  scoped_clone
  statements_plan '.programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; $root + "/harbor/vault/box/lid"; "read-only"; 9),
                                              st("harbor"; "dock"; "keeper"; "seat"; $root + "/harbor/scratch/in/deep"; "read-only"; 10)]
    | (.programs[] | select(.path == "harbor/dock/keeper/seat.typify") | .plan[1].term[5]) |= (fromjson
        + ["report=" + $root + "/harbor/berth/keeper", "entries=" + $root + "/harbor/scratch/in", "scratch=" + $root + "/harbor/scratch/in"] | tojson)'
  check "plan" exit_is 0 wplan
  local cases=(
    "$root/harbor/charts/page|/ read-only|so the path is as the machine has it, read-only"
    "$root/harbor/berth/page|$root/harbor/berth read-write|so the path is as the machine has it, read-write"
    "$root/harbor/ledger/page|$root/harbor/ledger hidden|so the seat cannot reach the path"
    "$root/harbor/scratch/page|$root/harbor/scratch scratch|so the path is not there until the seat makes it"
    "$root/harbor/scratch/in|$root/harbor/scratch scratch|so the path is a directory of the seat's scratch, made to hold the row beneath it at $root/harbor/scratch/in/deep; the rest is the seat's to make"
    "$root/harbor/vault/page|$root/harbor/vault searchable-only|so the path is not there, and the seat cannot make it"
    "$root/harbor/vault/box|$root/harbor/vault searchable-only|so the path is a directory that the seat passes through to the row beneath it at $root/harbor/vault/box/lid, and nothing more"
  )
  local entry path rest
  for entry in "${cases[@]}"; do
    path=${entry%%|*} rest=${entry#*|}
    wp why "Harbor Keeper" "$path" > "$scratch/out" 2>&1
    check "[C23] for $path, with no row, why names the nearest row above it, ${rest%%|*}, and says what it means: ${rest#*|}" \
      bash -c 'grep -qxF "no row at the path; its nearest ancestor'"'"'s row is $2" "$1" && grep -qxF "  $3" "$1"' _ "$scratch/out" "${rest%%|*}" "${rest#*|}"
  done
  wp why "Harbor Keeper" "$root/harbor/vault/box/lid" > "$scratch/out" 2>&1
  check "[C23] a path with a row of its own is told by that row alone" bash -c 'grep -qxF "row: $2 read-only" "$1" && ! grep -q "^  so " "$1"' _ "$scratch/out" "$root/harbor/vault/box/lid"
  mkdir -p -- "$root/harbor/vault/box/lid" "$root/harbor/scratch/in/deep" "$root/harbor/scratch/in/other"
  check "build" exit_is 0 wp build
  check "up" exit_is 0 wp up
  check "keeper ran" eventually_long grep -qx "probe keeper done" "$root/harbor/berth/keeper"
  check "[C23] in the pane, beneath a scratch row, a path above a row is a directory made to hold it alone, and the seat may make the rest" \
    bash -c 'grep -qxF "entries $2: deep " "$1" && grep -qxF "scratch $2: entries=1 write=ok" "$1"' _ "$root/harbor/berth/keeper" "$root/harbor/scratch/in"
  check "down" exit_is 0 wp down
}

t_doctor() {
  check "[C24] doctor exits 0 on this machine" exit_is 0 wp doctor
  check "[C24] it checks setpriv" said "ok      no-new-privileges can be set"
  check "[C24] it checks bubblewrap's namespaces" said "with unprivileged user namespaces"
  check "[C24] it reports git, which a plan that holds mail needs" bash -c 'grep -qE "^(ok      git |old     git |absent  git: needed only by a plan that holds mail)" "$1"' _ "$scratch/out"
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
  trap 'leave_reference; cleanup || exit 1' EXIT
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
loose_wplan() { local loop=$scratch/loose/bin/workplace; wplan; }
statements_plan() {
  local filter=${1:-.}
  jq --arg root "$root" '
    def at($line): {kind: "program", line: $line, path: "programs/policy.typify"};
    def st($a; $b; $c; $scope; $path; $state; $line): {term: ["statement", $a, $b, $c, $scope, $path, $state], origin: at($line)};
    def cl($a; $b; $c; $scope; $n; $line): {term: ["clearance", $a, $b, $c, $scope, $n], origin: at($line)};
    def lb($path; $n; $line): {term: ["label", $path, $n], origin: at($line)};
    def sc($line): {term: ["clearance-scale", "turned"], origin: at($line)};
    def kinds($rows): .state["seat-kinds"] = [$rows[] | {key: .[0:3], masked: false, origin: at(30), value: [.[3]]}];
    def terms_of($path; f): (.programs[] | select(.path == $path) | .plan) |= map(if type == "object" then .term |= f else f end);
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
  check "[C29] the fold's version names the rules it follows" test "$(jq -r .derivations.fold "$manifest")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-v12
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
  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "1"; 9), cl("harbor"; "-"; "-"; "office"; "2"; 10), sc(20)]'
  check "[C31] rule 2: two clearances of one office with different numbers refuse the plan" exit_is 1 wplan
  check "[C31] naming both" said "two clearances of the office harbor differ: 1 from programs/policy.typify:9, 2 from programs/policy.typify:10"
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard"; "1"; 9), lb($root + "/orchard"; "2"; 10), sc(20)]'
  check "[C31] rule 2: two labels of one path with different numbers refuse the plan" exit_is 1 wplan
  check "[C31] naming both" said "two labels of $root/orchard differ: 1 from programs/policy.typify:9, 2 from programs/policy.typify:10"
  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "1"; 9), cl("harbor"; "-"; "-"; "office"; "1"; 10), sc(20)]'
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

  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "1"; 9), cl("harbor"; "dock"; "-"; "room"; "2"; 10), sc(20)]'
  check "plan with clearances" exit_is 0 wplan
  check "[C30] rule 4: a seat has its room's clearance" test "$(seat_of keeper '[.clearance.value, .clearance.origin.line, .clearance.scope]')" = '[2,10,"room"]'
  check "[C30] rule 4: so do its room-mates" test "$(seat_of pilot '[.clearance.value, .clearance.origin.line]')" = '[2,10]'
  check "[C30] rule 4: else its office's" test "$(seat_of watch '[.clearance.value, .clearance.origin.line, .clearance.scope]')" = '[1,9,"office"]'
  check "[C30] rule 4: else none, which is null and no 0" test "$(seat_of grower '[.clearance.value, .clearance.origin, .clearance.scope]')" = '[null,null,null]'
  check "[C32] plan prints a seat with none as cleared for no label" \
    said "seat Orchard Grower (orchard/barn/grower): kind none; cleared for no label, since neither its room nor its office has a clearance; 1 rows"
  check "[C32] and a seat with a number with its scope" said "seat Harbor Watch (harbor/tower/watch): kind none; clearance 1, the office's (programs/policy.typify:9); 2 rows"
  statements_plan '.programs[-1].recorded += [cl("harbor"; "dock"; "keeper"; "seat"; "3"; 11), sc(20)]'
  check "[C31] 5.118: a clearance at a seat's scope refuses the plan" exit_is 1 wplan
  check "[C31] naming it, and why" said "programs/policy.typify:11: a seat has its room's clearance and none of its own (5.118), so seat is not a scope of a clearance"
  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "1"; 9), lb($root + "/orchard"; "2"; 10)]'
  check "[C31] clearance or label terms with no clearance-scale refuse the plan" exit_is 1 wplan
  check "[C31] saying that 0 is the most cleared now, and naming the terms" \
    said "the plan holds clearance or label terms and no clearance-scale term: since 5.122 the number 0 is the most cleared, and a plan numbered before that turn is refused until it is renumbered and says clearance-scale turned (the clearance or label at programs/policy.typify:9, programs/policy.typify:10)"
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard"; "2"; 9), lb($root + "/harbor/charts"; "2"; 10), cl("harbor"; "-"; "-"; "office"; "1"; 11), lb($root + "/orchard/almanac"; "3"; 12)]'
  check "[C31] four clearance or label terms with no clearance-scale refuse the plan" exit_is 1 wplan
  check "[C31] naming the first three origins, the clearance before the labels though it stands third, and no more" \
    bash -c 'grep -qF "(the clearance or label at programs/policy.typify:11, programs/policy.typify:9, programs/policy.typify:10)" "$1" && ! grep -qF "policy.typify:12" "$1"' _ "$scratch/out"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/harbor/ledger"; "hidden"; 9), sc(20)]'
  check "[C30] a clearance-scale with no number to read refuses nothing" exit_is 0 wplan
  statements_plan '.programs[-1].recorded += [{term: ["clearance-scale", "turned", "twice"], origin: at(20)}]'
  check "[C31] a clearance-scale of three words refuses the plan" exit_is 1 wplan
  check "[C31] naming its words" said "programs/policy.typify:20: a clearance-scale has the words clearance-scale turned, not 3"
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard"; "closed"; 10), lb($root + "/orchard"; "2"; 11), sc(12)]'
  check "[C31] rule 2: closed and a number as two labels of one path refuse the plan" exit_is 1 wplan
  check "[C31] naming both" said "two labels of $root/orchard differ: closed from programs/policy.typify:10, 2 from programs/policy.typify:11"
  statements_plan '.programs[-1].recorded = [sc(20)]'
  check "[C33] 5.126 point 3: a plan whose only fold term would be clearance-scale turned is not folded, and stands" exit_is 0 wplan
  check "[C33] it has no view.json, as a plan with no fold term" test ! -e "$clone/PLAN/view.json"
  check "[C33] and is not refused for a row for /" bash -c '! grep -qF "no row for /" "$1"' _ "$scratch/out"
  statements_plan '.programs[-1].recorded += [{term: ["clearance-scale", "upright"], origin: at(20)}]'
  check "[C31] a scale the fold does not know refuses the plan" exit_is 1 wplan
  check "[C31] naming it" said "programs/policy.typify:20: upright is not a scale the fold knows: turned, where 0 is the most cleared (5.122)"

  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "3"; 9), cl("harbor"; "dock"; "-"; "room"; "1"; 11),
      lb($root + "/harbor/charts"; "2"; 12), lb($root + "/harbor/ledger/inner"; "1"; 13),
      lb($root + "/orchard"; "2"; 14), lb($root + "/orchard/almanac"; "3"; 15),
      st("harbor"; "-"; "-"; "office"; $root + "/harbor/vault/shelf"; "read-write"; 16), lb($root + "/harbor/vault"; "3"; 17), sc(18)]'
  check "plan with labels" exit_is 0 wplan
  check "[C30] rule 5: a label the seat is not cleared for (its 3 above the label 2) makes a hidden row" bash -c '[[ $1 == *"/harbor/charts hidden"* ]]' _ "$(rows_of watch)"
  check "[C30] rule 5: one it is cleared for (its 1 at most 2), under an open row, makes a read-only row" bash -c '[[ $1 == *"/harbor/charts read-only"* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5: cleared, under a row a statement hides, none" bash -c '[[ $1 != *"/harbor/ledger/inner "* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5 as 5.126 point 2 rules it: not cleared, under a row a statement hides, none either" bash -c '[[ $1 != *"/harbor/ledger/inner "* ]]' _ "$(rows_of watch)"
  check "[C30] rule 5: the row a label makes carries the label's origin" \
    test "$(jq -c --arg p "$root/harbor/charts" '[.rows[] | select(.key[2] == "watch" and .key[3] == $p) | [.source, .origins[0].line]][0]' "$clone/PLAN/view.json")" = '["label",12]'
  check "[C30] rule 5: and replaces nothing: the office's row beneath it stands" \
    bash -c '[[ $1 == *"/harbor/vault read-only,"* && $1 == *"/harbor/vault/shelf read-write,"* ]]' _ "$(rows_of watch)"
  check "[C30] 5.124 point 7: a label beneath a labelled path governs it, and the ancestor is a passage for a seat that sees the child alone" \
    bash -c '[[ $1 == *"/orchard searchable-only,"* && $1 == *"/orchard/almanac read-only,"* ]]' _ "$(rows_of watch)"
  check "[C30] the passage is the label's row" \
    test "$(jq -c --arg p "$root/orchard" '[.rows[] | select(.key[2] == "watch" and .key[3] == $p) | [.source, .origins[0].line]][0]' "$clone/PLAN/view.json")" = '["label",14]'
  check "[C30] a seat cleared for both gets both read-only" bash -c '[[ $1 == *"/orchard read-only,"* && $1 == *"/orchard/almanac read-only,"* ]]' _ "$(rows_of keeper)"
  check "[C30] a seat cleared for no label gets both hidden, and no passage" \
    bash -c '[[ $1 == *"/orchard hidden,"* && $1 == *"/orchard/almanac hidden,"* ]]' _ "$(rows_of grower)"
  check "[C32] the plan stands, and plan prints the passage with the seats that pass" \
    said "label $root/orchard (2) is searchable only, a passage to the labels beneath it that a seat is cleared for (5.124 point 7), for: Harbor Watch (programs/policy.typify:14)"
  check "[C32] a statement standing at a labelled path is printed" said "stands at a labelled path: seat harbor/dock/keeper $root/harbor/vault searchable-only"

  statements_plan '.programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "4"; 9),
      lb($root + "/harbor/ledger/vault"; "3"; 10), lb($root + "/harbor/ledger/vault/notes"; "4"; 11), sc(12)]'
  check "[C30] 5.126 point 2: the research vault's shape beneath a path a statement hides folds, and refuses nothing" exit_is 0 wplan
  check "[C30] a label beneath it makes no row for a room cleared for the child alone: none for the ancestor, none for the child" \
    bash -c '[[ $1 != *"/harbor/ledger/vault"* && $2 != *"/harbor/ledger/vault"* ]]' _ "$(rows_of keeper)" "$(rows_of pilot)"
  check "[C30] nor for a seat cleared for no label" bash -c '[[ $1 != *"/harbor/ledger/vault"* ]]' _ "$(rows_of watch)"
  check "[C32] and no passage is printed" bash -c '! grep -qF "a passage to the labels beneath it" "$1"' _ "$scratch/out"

  statements_plan '.programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "3"; 9),
      lb($root + "/harbor/scratch/deep"; "1"; 10), lb($root + "/harbor/scratch/page"; "5"; 11),
      lb($root + "/harbor/vault/deep"; "1"; 12), lb($root + "/harbor/vault/open"; "5"; 13), sc(14)]'
  check "plan with labels beneath a scratch row and a searchable-only row" exit_is 0 wplan
  check "[C30] rule 5 (5.24): beneath a scratch row, a label the seat is not cleared for makes no row" \
    bash -c '[[ $1 != *"/harbor/scratch/deep "* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5 (5.24): beneath a scratch row, a label it is cleared for makes no row" \
    bash -c '[[ $1 != *"/harbor/scratch/page "* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5 (5.24): beneath a searchable-only row, a label it is not cleared for makes no row" \
    bash -c '[[ $1 != *"/harbor/vault/deep "* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5: beneath a searchable-only row, a label it is cleared for makes a read-only row" \
    bash -c '[[ $1 == *"/harbor/vault/open read-only,"* ]]' _ "$(rows_of keeper)"
  check "[C30] rule 5: and the seat's rows are those and no more" \
    test "$(rows_of keeper)" = "/ read-only,$root/harbor/berth read-write,$root/harbor/hold hidden,$root/harbor/holdall read-write,$root/harbor/ledger hidden,$root/harbor/scratch scratch,$root/harbor/vault searchable-only,$root/harbor/vault/open read-only,$root/harbor/vault/shelf read-write,"

  statements_plan '.programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "3"; 9),
      lb($root + "/harbor/vault/open"; "5"; 10), lb($root + "/harbor/vault/open/inner"; "1"; 11), sc(12)]'
  check "[C30] 5.129 point 2: a label the room is not cleared for, beneath a label's read-only row beneath a searchable-only row, folds" exit_is 0 wplan
  check "[C30] 5.129 point 2: it is read against the label's row, the nearest of any source, and makes a hidden row" \
    bash -c '[[ $1 == *"/harbor/vault/open read-only,"*"/harbor/vault/open/inner hidden,"* ]]' _ "$(rows_of keeper)"
  check "[C31] 5.129 point 2: and no label is refused for lying beneath a row with no row of its own" \
    bash -c '! grep -qF "with no row of its own" "$1"' _ "$scratch/out"

  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 10)]'
  check "plan with a closed root" exit_is 0 wplan
  check "[C32] the directories beneath it that no row names are listed as held by nobody" \
    bash -c 'grep -qxF "held by nobody, a report and no part of the plan:" "$2" && grep -qxF "  $1/orchard/cellar" "$2" && grep -qxF "  $1/orchard/crate-picker" "$2"' _ "$root" "$scratch/out"
  check "[C32] and not one that a row names" bash -c '! grep -qxF "  $1/orchard/almanac" "$2"' _ "$root" "$scratch/out"
  statements_plan '.programs[-1].recorded = [lb($root + "/orchard"; "1"; 9), sc(10)]'
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
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-write"; 9), lb($root + "/orchard"; "1"; 10), sc(20)]'
  check "[C31] rule 6: a row open beneath a label the seat is not cleared for refuses the plan" exit_is 1 wplan
  check "[C31] naming the seat, the path, the label and the origins, for a seat cleared for no label" \
    said "seat Orchard Grower (orchard/barn/grower): $root/orchard/almanac (read-write, from programs/policy.typify:9) lies at or beneath $root/orchard, labelled 1 (from programs/policy.typify:10), and the seat is cleared for no label"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-write"; 9), lb($root + "/orchard"; "1"; 10),
      cl("orchard"; "-"; "-"; "office"; "2"; 11), sc(20)]'
  check "[C31] rule 6: and for a seat whose number is above the label" exit_is 1 wplan
  check "[C31] naming its number" \
    said "seat Orchard Grower (orchard/barn/grower): $root/orchard/almanac (read-write, from programs/policy.typify:9) lies at or beneath $root/orchard, labelled 1 (from programs/policy.typify:10), which the seat's clearance 2 does not reach"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard/almanac"; "read-only"; 9), lb($root + "/orchard/almanac"; "0"; 10),
      cl("harbor"; "-"; "-"; "office"; "0"; 11), sc(20)]'
  check "[C31] 5.122 point 1: a seat with no number is cleared for no label, not even 0, so an open row at a label 0 refuses the plan" exit_is 1 wplan
  check "[C31] naming a seat with none" said "seat Orchard Grower (orchard/barn/grower): $root/orchard/almanac (read-only, from programs/policy.typify:9) lies at or beneath $root/orchard/almanac, labelled 0 (from programs/policy.typify:10), and the seat is cleared for no label"
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard/almanac"; "0"; 10), cl("harbor"; "-"; "-"; "office"; "0"; 11), sc(20)]'
  check "plan with a label 0 and an office at 0" exit_is 0 wplan
  check "[C30] a seat at 0 is cleared for a label 0: a read-only row" bash -c '[[ $1 == *"/orchard/almanac read-only,"* ]]' _ "$(rows_of watch)"
  check "[C30] a seat with no number gets a hidden row there" bash -c '[[ $1 == *"/orchard/almanac hidden,"* ]]' _ "$(rows_of grower)"
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard"; "closed"; 10), cl("harbor"; "-"; "-"; "office"; "0"; 11), sc(20)]'
  check "plan with a closed label" exit_is 0 wplan
  check "[C30] 5.124 point 6: a closed path is hidden even from a seat at 0" bash -c '[[ $1 == *"/orchard hidden,"* ]]' _ "$(rows_of watch)"
  check "[C30] and from a seat cleared for no label" bash -c '[[ $1 == *"/orchard hidden,"* ]]' _ "$(rows_of grower)"
  statements_plan '.programs[-1].recorded += [st("harbor"; "-"; "-"; "office"; $root + "/orchard/almanac"; "read-only"; 9), lb($root + "/orchard"; "closed"; 10),
      cl("harbor"; "-"; "-"; "office"; "0"; 11), sc(20)]'
  check "[C31] a row opened beneath a closed path refuses the plan, whatever the seat's number" exit_is 1 wplan
  check "[C31] naming the closed label" \
    said "seat Harbor Watch (harbor/tower/watch): $root/orchard/almanac (read-only, from programs/policy.typify:9) lies at or beneath $root/orchard, labelled closed (from programs/policy.typify:10), which no clearance reaches"
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard"; "closed"; 10), lb($root + "/orchard/almanac"; "4"; 11), sc(20)]'
  check "[C31] 5.124 point 6: a label beneath a closed path refuses the plan" exit_is 1 wplan
  check "[C31] naming both" \
    said "programs/policy.typify:11: the label speaks of $root/orchard/almanac, which lies beneath $root/orchard, closed (from programs/policy.typify:10): no label governs beneath a closed path (5.124 point 6)"
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard"; "open"; 10), sc(20)]'
  check "[C31] a label that is neither a number nor closed refuses the plan" exit_is 1 wplan
  check "[C31] naming it" said "programs/policy.typify:10: open is neither a whole number nor closed"
  statements_plan '.programs[-1].recorded += [cl("orchard"; "barn"; "-"; "room"; "4"; 9), lb($root + "/orchard"; "3"; 10), lb($root + "/orchard/almanac"; "4"; 11),
      st("orchard"; "barn"; "-"; "room"; $root + "/orchard/almanac"; "read-write"; 12), sc(20)]'
  check "[C30] 5.124 point 7: a room at 4 writes its own child labelled 4 beneath an ancestor labelled 3" exit_is 0 wplan
  check "[C30] through the ancestor as a passage" \
    bash -c '[[ $1 == *"/orchard searchable-only,"* && $1 == *"/orchard/almanac read-write,"* ]]' _ "$(rows_of grower)"
  statements_plan '.programs[-1].recorded += [cl("orchard"; "barn"; "-"; "room"; "4"; 9), lb($root + "/orchard"; "3"; 10), lb($root + "/orchard/almanac"; "4"; 11),
      st("orchard"; "barn"; "-"; "room"; $root + "/orchard/almanac"; "read-write"; 12), st("orchard"; "barn"; "-"; "room"; $root + "/orchard"; "read-only"; 13), sc(20)]'
  check "[C31] the same room reading the ancestor itself refuses the plan" exit_is 1 wplan
  check "[C31] naming the ancestor's label" \
    said "seat Orchard Grower (orchard/barn/grower): $root/orchard (read-only, from programs/policy.typify:13) lies at or beneath $root/orchard, labelled 3 (from programs/policy.typify:10), which the seat's clearance 4 does not reach"
  statements_plan '.programs[-1].recorded += [lb("/"; "0"; 9)]'
  check "[C31] 5.18: a label on / refuses the plan" exit_is 1 wplan
  check "[C31] saying so" said "programs/policy.typify:9: a label on / refuses the plan"
  statements_plan '.programs[-1].recorded += [{term: ["statement", "workplace", "-", "-", "-", "/", "read-only"], origin: at(9)}]'
  check "[C31] 5.18: a statement with the scope word first is refused" exit_is 1 wplan
  check "[C31] naming the line" said "programs/policy.typify:9: - is not a scope of a statement"
  statements_plan '.programs[-1].recorded += [st("nowhere"; "-"; "-"; "office"; "/"; "hidden"; 9)]'
  check "[C31] a statement naming an office the plan does not make refuses the plan" exit_is 1 wplan
  check "[C31] naming it" said "programs/policy.typify:9: the statement names the office nowhere, which the plan does not make"
  statements_plan '.programs[-1].recorded += [cl("harbor"; "ghost"; "-"; "room"; "1"; 9), sc(20)]'
  check "[C31] a clearance naming a room the plan does not make refuses the plan" exit_is 1 wplan
  check "[C31] naming it" said "the clearance names the room harbor/ghost, which the plan does not make"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/harbor/"; "read-only"; 9)]'
  check "[C4] a statement's path that is not canonical refuses the plan" exit_is 1 wplan
  check "[C4] naming its origin" said "programs/policy.typify:9 (statement): the path \"$root/harbor/\" is refused: it ends in a slash"
  statements_plan '.programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "01"; 10)]'
  check "[C31] a number that is not whole refuses the plan" exit_is 1 wplan
  check "[C31] naming it" said "01 is not a whole number"
}

floors_clone() {
  jq '. + {floors: [
    {key: "bridge", name: "Bridge", houses: "offices", enforced: false, socket: "tmux-default", conf: "floors/bridge.conf", smallest: "80x24"},
    {key: "deck", name: "Deck", houses: "offices", enforced: true, socket: "run", conf: "floors/deck.conf", smallest: "80x24"},
    {key: "lodge", name: "Lodge", houses: "rooms", enforced: true, socket: "run", conf: "floors/lodge.conf", smallest: "80x24"}]}' \
    "$clone/workplace.json" > "$scratch/w" && cp -- "$scratch/w" "$clone/workplace.json"
  mkdir -p -- "$clone/floors"
  : > "$clone/floors/bridge.conf"
  : > "$clone/floors/deck.conf"
  : > "$clone/floors/lodge.conf"
  rm -f -- "$clone/tmux.conf"
}
floors_terms='.programs[-1].recorded |= map(select(.term[4] != "seat"))
  | .programs[0].plan[0][1] as $name
  | .programs[0].plan = [["workplace", $name],
      ["floor", "bridge", "Bridge", "offices", "unenforced", "tmux-default", $root + "/config/floors/bridge.conf", "80x24"],
      ["floor", "deck", "Deck", "offices", "enforced", "run", $root + "/config/floors/deck.conf", "80x24"],
      ["floor", "lodge", "Lodge", "rooms", "enforced", "run", $root + "/config/floors/lodge.conf", "80x24"]]
  | (.programs[] | select(.path == "harbor/office.typify") | .plan) += [["house", "deck", "harbor"]]
  | (.programs[] | select(.path == "orchard/office.typify") | .plan) += [["house", "bridge", "orchard"]]
  | ([.programs[] | select(.path == "harbor/tower/room.typify")][0] | .path = "lodge/east/room.typify"
      | .plan |= map(.[1] = "lodge" | .[2] = "east" | if .[0] == "window" then .[3] = "East" else . end)) as $room
  | ([.programs[] | select(.path == "harbor/tower/watch/seat.typify")][0] | .path = "lodge/east/ida/seat.typify"
      | .plan |= map(if type == "object" then .term[1:4] = ["lodge", "east", "ida"]
                     else .[1:4] = ["lodge", "east", "ida"] | if .[0] == "pane" then .[4] = "Lodge Ida" else . end end)) as $seat
  | .programs = .programs[0:-1] + [$room, $seat] + .programs[-1:]'

t_floors() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "plan of a configuration with three floors of both kinds" exit_is 0 wplan
  check "[C100] the root program is the root, the workplace and a line for each floor" \
    cmp -s "$STUB_DIR/root-program" <(printf '%s\n' "workdir : $root" "workplace : $label" \
      "floor : bridge : Bridge : offices : unenforced : tmux-default : config/floors/bridge.conf : 80x24" \
      "floor : deck : Deck : offices : enforced : run : config/floors/deck.conf : 80x24" \
      "floor : lodge : Lodge : rooms : enforced : run : config/floors/lodge.conf : 80x24")
  check "[C29] with floors the root program's derivation is root-floors-v1" \
    test "$(jq -r '.derivations["root-program"]' "$clone/PLAN/manifest.json")" = root-floors-v1
  check "[C100] and each floor's file is an input, in the floors' order, where tmux.conf was" \
    test "$(jq -r '[.inputs[].path][-3:] | join(" ")' "$clone/PLAN/manifest.json")" = "floors/bridge.conf floors/deck.conf floors/lodge.conf"
  check "[C104] view.json names the floors" test "$(jq -c '[.floors[] | [.key, .houses, .enforced, .socket]]' "$clone/PLAN/view.json")" = \
    '[["bridge","offices",false,"tmux-default"],["deck","offices",true,"run"],["lodge","rooms",true,"run"]]'
  check "[C104] and each seat's floor" test "$(jq -c '[.seats[] | [.seat[2], .floor, .enforced]]' "$clone/PLAN/view.json")" = \
    '[["keeper","deck",true],["pilot","deck",true],["watch","deck",true],["grower","bridge",false],["picker","bridge",false],["ida","lodge",true]]'
  check "[C104] and each room of an enforced floor, in the order of the window terms, with its type and occupants" \
    test "$(jq -c '[.rooms[] | [(.room | join("/")), .of, .floor, .occupants]]' "$clone/PLAN/view.json")" = \
    '[["harbor/dock","office","deck",["Harbor Keeper","Harbor Pilot"]],["harbor/tower","office","deck",["Harbor Watch"]],["lodge/east","floor","lodge",["Lodge Ida"]]]'
  check "[C104] an unenforced floor's seats carry no rows, and refuse nothing for it" test "$(seat_of grower .rows)" = 0
  check "[C104] room-mates carry equal rows" test "$(rows_of keeper)" = "$(rows_of pilot)"
  check "[C104] and the room's rows are theirs, keyed by the room" \
    test "$(jq -r '.rooms[0].rows | map("\(.key | join("/")) \(.value[0])") | join(",")' "$clone/PLAN/view.json")" = "harbor/dock// read-only,harbor/dock/$root/harbor/berth read-write,harbor/dock/$root/harbor/ledger hidden"
  check "[C104] plan says that the unenforced floor has no view" \
    said "the unenforced floor bridge has no view: its occupants read the machine as the user does, and labels, closed paths and bans bind them as conduct (5.124 point 3)"
  check "[C104] and names each room of an enforced floor that has no number (5.125 point 7)" \
    said "room lodge/east, on the enforced floor lodge, has no number: it is cleared for no label, and least among its floor's rooms (5.125 point 7)"
  check "[C104] a room of a floor of offices is least among its office's rooms" \
    said "room harbor/dock, on the enforced floor deck, has no number: it is cleared for no label, and least among its office's rooms (5.125 point 7)"

  local planned loose
  planned=$(cat "$clone/PLAN/manifest.json" "$clone/PLAN/view.json" | sha256sum)
  statements_plan "$floors_terms"' | .programs[-1].recorded = []'
  check "[C104] 5.129 point 4: a plan with enforced floors and no fold term refuses at plan, with exit 1" exit_is 1 wplan
  check "[C104] naming each enforced floor" bash -c 'grep -qxF "workplace: the floor deck is enforced, and the plan holds no fold term: an enforced floor'"'"'s rooms are folded from statements, and the plan'"'"'s view cell, which gives each seat rows of its own, is refused there (5.129 point 4)" "$1" && grep -qF "workplace: the floor lodge is enforced, and the plan holds no fold term" "$1"' _ "$scratch/out"
  check "[C104] in the plan's order, the unenforced floor not among them, and closing that PLAN/ is as it was" \
    test "$(grep -o 'the floor [a-z]* is enforced' "$scratch/out" | tr '\n' ,)$(grep -c 'PLAN/ is as it was$' "$scratch/out")" = "the floor deck is enforced,the floor lodge is enforced,1"
  check "[C104] and PLAN/ is as it was" test "$(cat "$clone/PLAN/manifest.json" "$clone/PLAN/view.json" | sha256sum)" = "$planned"
  statements_plan "$floors_terms"' | .programs[-1].recorded = [] | .programs[0].plan |= map(if .[0] == "floor" then .[4] = "unenforced" else . end)'
  check "[C104] a plan whose floors are all unenforced takes its view cell, as a plan with no fold term does" exit_is 0 wplan
  rm -rf -- "$scratch/loose" && mkdir -- "$scratch/loose" && cp -R -- "$tool/." "$scratch/loose/"
  loose=$(< "$scratch/loose/bin/workplace")
  printf '%s\n' "${loose/'folds "$work/plan.json" "$tool/host/binding.json" || refuse_unfolded "$work/plan.json"'/true}" > "$scratch/loose/bin/workplace"
  statements_plan "$floors_terms"' | .programs[-1].recorded = []'
  check "a loop that does not refuse it plans an enforced floor with no fold term" exit_is 0 loose_wplan
  check "[C104] build refuses it, with exit 1" exit_is 1 wp build
  check "[C104] naming each enforced floor as plan does, and saying so" bash -c 'grep -qF "workplace: the floor deck is enforced, and the plan holds no fold term" "$1" && grep -qF "workplace: the floor lodge is enforced" "$1" && grep -qxF "workplace: build refuses: PLAN/plan.json holds an enforced floor and no fold term" "$1"' _ "$scratch/out"
  check "[C104] and makes nothing" test ! -e "$clone/BUILD"
  rm -rf -- "$scratch/loose" "$clone/PLAN"

  statements_plan "$floors_terms"' | .programs[-1].recorded += [st("orchard"; "-"; "-"; "office"; "/"; "searchable-only"; 9)]'
  check "plan with a statement of an office on the unenforced floor" exit_is 0 wplan
  check "[C104] an unenforced floor's seats fold no statement: none replaces another, none is counted, and no row is made" \
    test "$(seat_of grower '[.rows, .exception_count, .distinct_replaced_statement_count, (.replacement_statements | length)]')" = '[0,0,0,0]'

  statements_plan "$floors_terms"' | .state["seat-kinds"] = [{key: ["harbor", "dock", "keeper"], value: ["navigator"], masked: false, origin: at(30)},
      {key: ["harbor", "dock", "pilot"], value: ["gardener"], masked: false, origin: at(31)}]
    | .programs[-1].recorded += [st("navigator"; "-"; "-"; "kind"; $root + "/tools"; "hidden"; 9), st("gardener"; "-"; "-"; "kind"; $root + "/tools"; "hidden"; 10)]'
  check "plan with two kinds in one room that say the same" exit_is 0 wplan
  check "[C104] 5.125 point 4: each kind's statement reaches the whole room, as one row with both origins" \
    test "$(jq -c --arg p "$root/tools" '[.rows[] | select(.key[3] == $p) | [.key[2], .value[0], [.origins[].line]]]' "$clone/PLAN/view.json")" = \
    '[["keeper","hidden",[9,10]],["pilot","hidden",[9,10]]]'
  statements_plan "$floors_terms"' | .state["seat-kinds"] = [{key: ["harbor", "dock", "keeper"], value: ["navigator"], masked: false, origin: at(30)},
      {key: ["harbor", "dock", "pilot"], value: ["gardener"], masked: false, origin: at(31)}]
    | .programs[-1].recorded += [st("navigator"; "-"; "-"; "kind"; $root + "/tools"; "hidden"; 9), st("gardener"; "-"; "-"; "kind"; $root + "/tools"; "read-only"; 10)]'
  check "[C104] 5.124 point 5: two statements of different states about one path at one room refuse the plan" exit_is 1 wplan
  check "[C104] naming the room, the path and every origin" \
    said "two statements about $root/tools at the room harbor/dock differ: hidden from programs/policy.typify:9, read-only from programs/policy.typify:10 (5.124 point 5)"

  local refusals=(
    'C104|.programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; $root + "/tools"; "hidden"; 9)]|programs/policy.typify:9: the statement speaks at the seat harbor/dock/keeper, on the enforced floor deck, where the room is one view and a seat'"'"'s statement would promise a wall that the room does not have (5.124 point 5)'
    'C101|.programs[-1].recorded += [st("lodge"; "-"; "-"; "office"; $root + "/tools"; "hidden"; 9)]|programs/policy.typify:9: the statement names the office lodge, and lodge is a floor (5.125 point 1)'
    'C103|.programs[-1].recorded += [st("harbor"; "-"; "-"; "floor"; $root + "/tools"; "hidden"; 9)]|programs/policy.typify:9: the statement names the floor harbor, and harbor is an office (5.125 point 1)'
    'C103|.programs[-1].recorded += [cl("deck"; "-"; "-"; "floor"; "1"; 9), sc(20)]|programs/policy.typify:9: floor is not a scope of a clearance: a room'"'"'s number is its own line'"'"'s, else its office'"'"'s (5.122 point 1)'
    'C104|.programs[-1].recorded += [{term: ["reach", "harbor", "dock", "keeper", "seat", "grab", "-", "-", "-", "workplace", "allowed"], origin: at(9)}]|programs/policy.typify:9: the reach asks for the seat harbor/dock/keeper, on the enforced floor deck, whose room holds 2 occupants: what one occupant of a room may ask, each of its room-mates may (5.118)'
    'C101|(.programs[0].plan) += [["server", "x", $root + "/config/floors/deck.conf"]]|the plan holds 1 server terms and 3 floor terms: a plan holds one server and no floor, or no server, one workplace and at least one floor'
    'C101|(.programs[0].plan) += [["workplace", "again"]]|the plan holds 2 workplace terms, and with floors it holds exactly one'
    'C101|(.programs[] | select(.path == "orchard/office.typify") | .plan) += [["house", "lodge", "orchard"]]|the house of orchard names the floor lodge, which houses no offices (orchard/office.typify, term 3)'
    'C101|(.programs[] | select(.path == "orchard/office.typify") | .plan) += [["house", "lodge", "orchard"]]|the office orchard stands in 2 houses, and it stands in one (orchard/office.typify, term 2; orchard/office.typify, term 3)'
    'C101|(.programs[] | select(.path == "harbor/office.typify") | .plan) |= map(select(.[0] != "house"))|the office harbor stands on no floor: with floors every session stands in a house (harbor/office.typify, term 1)'
    'C101|(.programs[] | select(.path == "orchard/office.typify") | .plan) += [["session", "lodge", "Lodge"]]|the floor lodge houses rooms, and the plan holds a session or a house for it (orchard/office.typify, term 3)'
    'C101|(.programs[0].plan) += [["floor", "orchard", "Orchard", "offices", "enforced", "run", $root + "/config/floors/deck.conf", "80x24"]]|the key orchard names a floor and an office'
    'C101|(.programs[0].plan) += [["floor", "attic", "Attic", "offices", "enforced", "run", $root + "/config/floors/deck.conf", "80x24"]]|the floor attic holds no office and no room'
    'C101|(.programs[0].plan) += [["floor", "attic", "Attic", "rooms", "enforced", "run", $root + "/config/floors/deck.conf", "80"]]|the floor attic says smallest "80": COLSxROWS'
    'C101|(.programs[0].plan) += [["floor", "orchard", "Orchard", "offices", "enforced", "run", $root + "/config/floors/deck.conf", "80x24"]]|the key orchard names a floor and an office (orchard/office.typify, term 1; orchard/office.typify, term 2; workplace.typify, term 5)'
    'C101|(.programs[0].plan) += [["floor", "attic", "Attic", "rooms", "enforced", "run", $root + "/config/floors/deck.conf", "80x24"]]|the floor attic holds no office and no room'
    'C101|(.programs[0].plan) += [["floor", "deck", "Deck", "offices", "enforced", "run", $root + "/config/floors/deck.conf", "80x24"]]|the floor deck is declared 2 times (workplace.typify, term 3; workplace.typify, term 5)'
    'C101|(.programs[0].plan) += [["window", "ghost", "w", "Ghost"]]|the window term for ghost has no session term (workplace.typify, term 5)'
    'C101|(.programs[0].plan) += [["window", "deck", "w", "W"]]|the window term for deck has no session term (workplace.typify, term 5)'
    'C101|.programs[-1].recorded += [cl("lodge"; "-"; "-"; "office"; "1"; 9), sc(20)]|programs/policy.typify:9: the clearance names the office lodge, and lodge is a floor (5.125 point 1)'
    'C103|.programs[-1].recorded += [{term: ["key", "harbor", "-", "-", "floor", "held"], origin: at(9)}]|programs/policy.typify:9: the key names the floor harbor, and harbor is an office (5.125 point 1)'
    'C103|.programs[-1].recorded += [st("nowhere"; "-"; "-"; "floor"; $root + "/tools"; "hidden"; 9)]|programs/policy.typify:9: the statement names the floor nowhere, which the plan does not make'
  )
  local entry
  local number rest
  for entry in "${refusals[@]}"; do
    number=${entry%%|*} rest=${entry#*|}
    statements_plan "$floors_terms | ${rest%|*}"
    check "[$number] plan refuses, with exit 1: ${rest##*|}" exit_is 1 wplan
    check "[$number] naming it" said "${rest##*|}"
  done
  statements_plan "$floors_terms"' | .programs[-1].recorded += [st("deck"; "-"; "-"; "floor"; $root + "/tools"; "hidden"; 9)]'
  check "plan with a statement of a floor" exit_is 0 wplan
  check "[C103] a floor's statement reaches the seats of the offices it houses" bash -c '[[ $1 == *"/tools hidden"* ]]' _ "$(rows_of watch)"
  check "[C103] and no seat of another floor" bash -c '[[ $1 != *"/tools "* ]]' _ "$(rows_of ida)"
  mkdir -p -- "$root/records"
  statements_plan "$floors_terms"' | .programs[-1].recorded += [{term: ["key", "deck", "-", "-", "floor", "held"], origin: at(9)},
      {term: ["expect", "deck", "-", "-", "floor", "WPT_DECK"], origin: at(10)},
      {term: ["record", "deck", "-", "-", "floor", "pane", "kept"], origin: at(11)}, {term: ["record-path", "records"], origin: at(12)},
      {term: ["ssh-key", "node", "keys/node"], origin: at(13)}, {term: ["ssh-grant", "deck", "-", "-", "floor", "node", "granted"], origin: at(14)},
      st("-"; "-"; "-"; "workplace"; $root + "/keys"; "hidden"; 15)]'
  check "plan with a key, an expect, a record and an ssh-grant at the floor deck's scope" exit_is 0 wplan
  check "[C103] a floor's key reaches the seats of its offices" test "$(seat_of keeper '[.key.state, .key.scope]')" = '["held","floor"]'
  check "[C103] and no seat of another floor" test "$(seat_of ida .key.state)" = '"none"'
  check "[C103] a floor's expect reaches the seats of its offices" test "$(seat_of watch '[.expects[] | [.name, .scopes]]')" = '[["WPT_DECK",["floor"]]]'
  check "[C103] and no seat of another floor" test "$(seat_of ida '.expects // [] | length')" = 0
  check "[C103] a floor's record reaches the seats of its offices" test "$(seat_of pilot '[.record.pane, .record.scope]')" = '["kept","floor"]'
  check "[C103] and no seat of another floor" test "$(seat_of ida .record.pane)" = '"none"'
  check "[C103] a floor's ssh-grant reaches the seats of its offices, which hold its key" test "$(seat_of keeper '[.ssh.granted[] | [.name, .scope]]')" = '[["node","floor"]]'
  check "[C103] and no seat of another floor" test "$(seat_of ida '[.ssh.granted[]?] | length')" = 0
  statements_plan '(.programs[0].plan) += [["workplace", "lonely"]]'
  check "[C101] a workplace term in a plan without floors refuses it" exit_is 1 wplan
  check "[C101] naming it" said "workplace speaks only in a plan with floors, and this plan holds none (workplace.typify, term 2)"

  statements_plan "$floors_terms"' | .programs[-1].recorded += [{term: ["key", "harbor", "dock", "keeper", "seat", "held"], origin: at(9)}]'
  check "plan again, with a key held by a seat of the floor deck" exit_is 0 wplan
  check "[C2] build of a configuration with floors" exit_is 0 wp build
  local s=$HOME/.local/state/workplace/$label
  check "[C102] each floor has a state directory of its own, mode 700, beneath the configuration's" \
    bash -c 'for f in bridge deck lodge; do [[ -d $1/floors/$f && $(stat -c %a "$1/floors/$f") == 700 ]] || exit 1; done' _ "$s"
  check "[C102] the seat's key home stands in its floor's state, by its place among that floor's panes" \
    bash -c '[[ -d $1/floors/deck/keys/01 && ! -e $1/keys ]]' _ "$s"
  check "[C102] and BUILD holds the floor's keys.json, which the MANIFEST lists" \
    bash -c '[[ $(jq -r ".state + \" \" + .seats[0].name + \" \" + .seats[0].home" "$1/BUILD/floors/deck/keys.json") == "$2/floors/deck Harbor Keeper keys/01" ]] && grep -q "  floors/deck/keys.json$" "$1/BUILD/MANIFEST"' _ "$clone" "$s"
  chmod 0750 -- "$s/floors/deck"
  rm -rf -- "$clone/BUILD"
  check "[C102] a floor's state directory that stands with a mode other than 700 refuses the build, with exit 2" exit_is 2 wp build
  check "[C102] naming it and its mode" said "the state directory $s/floors/deck has the mode 750, not 700"
  chmod 0700 -- "$s/floors/deck"
  chmod 0750 -- "$s/floors"
  rm -rf -- "$clone/BUILD"
  check "[C102] and so does the directory of the floors" exit_is 2 wp build
  check "[C102] naming it" said "the state directory $s/floors has the mode 750, not 700"
  chmod 0700 -- "$s/floors"
  rm -rf -- "$clone/BUILD"
  check "build again" exit_is 0 wp build
  check "[C101] up refuses a build that stands on floors, which S2's stop 4 brings" exit_is 2 wp up
  check "[C101] saying so" said "the build stands on floors; this frame plans and builds floors and does not yet stand them up, which comes with S2's stop 4"
  check "[C102] unbuild" exit_is 0 wp unbuild
  check "[C102] removes the key homes in every floor's state" \
    bash -c '[[ ! -e $1/floors/deck/keys ]] && grep -qF "unbuild: removed the key homes in $1/floors/deck/keys, 1 homes" "$2"' _ "$s" "$scratch/out"
}

t_floors_assembly() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  local cases=(
    '. + {socket: "default"}|workplace.json holds socket beside floors: with floors, each floor names its socket'
    '.floors = []|workplace.json'"'"'s floors is not a list of one or more floors'
    '.floors[0] += {colour: "red"}|the floor at index 0 holds colour, which the loop does not read'
    '.floors[0] |= del(.smallest)|the floor at index 0 lacks smallest'
    '.floors[0].key = "-x"|the floor key "-x" is refused: it begins with -'
    '.floors[1].key = "bridge"|the floor key bridge is listed 2 times'
    '.floors[0].houses = "halls"|the floor bridge houses "halls": offices or rooms'
    '.floors[0].enforced = "no"|the floor bridge says enforced "no": true or false'
    '.floors[0].socket = "tcp"|the floor bridge takes the socket "tcp": run or tmux-default'
    '.floors[1].socket = "tmux-default"|the floor deck is enforced and takes tmux-default: an enforced floor stands on a socket of its run, so that no plain tmux command reaches it (5.124 point 2)'
    '.floors[1].enforced = false | .floors[1].socket = "tmux-default"|2 floors take the socket tmux-default, and at most one may'
    '.floors[0].conf = "../bridge.conf"|the floor bridge names its conf "../bridge.conf", which is not a relative path'
    '.floors[0].smallest = "wide"|the floor bridge says smallest "wide": COLSxROWS'
    '.floors[0].name = "Bridge: upper"|the floor bridge is named "Bridge: upper", which is refused: it holds a :, which separates the words of the root program'
  )
  local entry
  for entry in "${cases[@]}"; do
    jq "${entry%|*}" "$clone/workplace.json" > "$scratch/w2" && cp -- "$clone/workplace.json" "$scratch/w-saved" && cp -- "$scratch/w2" "$clone/workplace.json"
    check "[C100] plan refuses, with exit 2: ${entry##*|}" exit_is 2 wplan
    check "[C100] naming it" said "${entry##*|}"
    cp -- "$scratch/w-saved" "$clone/workplace.json"
  done
  jq '.floors[0].conf = "floors/none.conf"' "$clone/workplace.json" > "$scratch/w2" && cp -- "$clone/workplace.json" "$scratch/w-saved" && cp -- "$scratch/w2" "$clone/workplace.json"
  check "[C100] a floor whose conf is no file in the clone refuses plan, with exit 2" exit_is 2 wplan
  check "[C100] naming it" said "the floor bridge names its conf floors/none.conf, which is not a file in the clone"
  cp -- "$scratch/w-saved" "$clone/workplace.json"
  : > "$clone/tmux.conf"
  check "[C100] a tmux.conf beside floors refuses plan, with exit 2" exit_is 2 wplan
  check "[C100] saying so" said "tmux.conf stands in the clone beside floors: each floor names its own file"
  rm -f -- "$clone/tmux.conf"
  check "[C100] and without it plan goes on" exit_is 0 wplan
}

t_plan_relative() {
  scoped_clone
  local extra='.programs[-1].recorded += [lb($root + "/orchard"; "2"; 9), cl("harbor"; "dock"; "-"; "room"; "3"; 10), sc(11)]'
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
  local pinned=e500ac3ff69c79f114593ae86ad0c2ece3644c39da4226425ef8fa7060c8f4a9 reference=/tmp/workplace-reference-s3
  if ! command -v typify > /dev/null; then
    skip "[C28] the reader typify is not on PATH here, so plan cannot run end to end"
    return 0
  fi
  if [[ ! -f $reference/config/workplace.json ]]; then
    skip "[C28] the relative edition of the fixture (w1-paths 5384b45, renumbered for 5.122 and 5.124) is not laid out as a clone at $reference"
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
  trap 'leave_reference; cleanup || exit 1' EXIT
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
  check "[C34] the fold's version is one that reads keys" test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-v12
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
    said "the plan was folded by frame-older-v0, and this loop folds by frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-v12; the views are equal, so build goes on"
  check "[C36] a build makes the state directory, 0700, and no key home where no seat holds a key" \
    bash -c '[[ $(stat -c %a "$1") == 700 && ! -e $1/keys ]]' _ "$HOME/.local/state/workplace/$label"
  rm -rf -- "$clone/BUILD"
  jq '.rows[0].value = ["read-write"]' "$clone/PLAN/view.json" > "$scratch/v" && cp -- "$scratch/v" "$clone/PLAN/view.json"
  jq --arg s "$(sha256sum < "$clone/PLAN/view.json" | cut -d' ' -f1)" '(.outputs[] | select(.path == "view.json") | .sha256) = $s' "$manifest" > "$scratch/m" \
    && cp -- "$scratch/m" "$manifest"
  check "[C29] where the views differ, build refuses" exit_is 1 wp build
  check "[C29] naming both versions and saying to plan again" \
    said "The plan was folded by frame-older-v0, and this loop folds by frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-v12; run plan again"
  statements_plan "$key_terms"' | .state.environment += [{key: ["harbor", "dock", "keeper", "GNUPGHOME"], value: ["/elsewhere"], masked: false, origin: at(40)}]'
  check "[C39] plan refuses a holding seat's row for GNUPGHOME, with exit 1" exit_is 1 wplan
  check "[C39] naming the seat, the name and both origins" \
    said "state environment: Harbor Keeper (harbor/dock/keeper) holds a key, and its environment may not set GNUPGHOME, which the frame gives (the row at programs/policy.typify:40; the key at programs/IDENTITY.typify:3)"
  statements_plan "$key_terms"
  check "plan with keys" exit_is 0 wplan
  edit_plan '.state.environment += [{key: ["harbor", "dock", "keeper", "GNUPGHOME"], value: ["/elsewhere"], masked: false, origin: {kind: "program", line: 40, path: "programs/policy.typify"}}]'
  check "[C39] build refuses the same row in a plan written by hand" exit_is 1 wp build
  check "[C39] naming it" said "state environment: Harbor Keeper (harbor/dock/keeper) holds a key, and its environment may not set GNUPGHOME, which the frame gives (the row at programs/policy.typify:40; the key at programs/IDENTITY.typify:3)"
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
  local runtime=/run/user/$EUID agents=(gcr/ssh keyring/ssh openssh_agent ssh-agent.socket) agent
  if [[ -d $runtime/systemd ]]; then
    panes+='
    | add("harbor/dock/keeper/seat.typify"; ["entries=RUNTIME", "bus=RUNTIME/bus", "connect=RUNTIME/systemd/private"] + ($agents | split(" ") | map("connect=RUNTIME/" + .)))
    | add("orchard/barn/picker/seat.typify"; ["report=" + $root + "/orchard/crate-picker/report", "identity=" + $root + "/orchard/crate-picker", "list=RUNTIME"])
    | add("harbor/tower/watch/seat.typify"; ["scratch=RUNTIME/systemd"])
    | .programs[-1].recorded += [st("orchard"; "barn"; "picker"; "seat"; "RUNTIME"; "hidden"; 21),
                                 st("orchard"; "barn"; "picker"; "seat"; $root + "/orchard/crate-picker"; "read-write"; 22),
                                 st("harbor"; "tower"; "watch"; "seat"; "RUNTIME/systemd"; "scratch"; 23)]'
    panes=${panes//\$agents/\"${agents[*]}\"}
    panes=${panes//RUNTIME/$runtime}
  fi
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
  check "[C37] and gives each holding seat its grants, none where no ssh key reaches it" test "$(jq -c '[.seats[].grants]' "$keys")" = '[[],[],[]]'
  check "[C35] sshcontrol holds the subkey's keygrip alone, and is read-only, 0444" \
    test "$(stat -c %a "$home/sshcontrol") $(grep -cvE '^[[:space:]]*(#|$)' "$home/sshcontrol") $(cut -d' ' -f1 "$home/sshcontrol")" \
      = "444 1 $(gpg --homedir "$home" --with-colons --with-keygrip --list-keys | awk -F: '$1 == "grp" { g = $10 } END { print g }')"
  local control
  control=$(sha256sum < "$home/sshcontrol")
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
  check "[C41] an add of keeper's signing key, its public half with forged bytes for its secret, is refused" r "key ssh forged add of the signing key: refused"
  check "[C41] and of its own ssh key so, with a confirmation asked" r "key ssh forged add of its own key, confirmed: refused"
  check "[C41] sshcontrol stands unchanged" test "$(sha256sum < "$home/sshcontrol")" = "$control"
  check "[C41] keeper's agent still lists its own ssh key alone" r "key ssh list after forged adds: $(jq -r '.seats[0].ssh' "$keys" | cut -d' ' -f1,2)"
  check "[C41] and signs with it" r "key ssh sign after forged adds: ok"
  check "[C40] keeper commits with a signature, the committer set to its name and address alone" r "key commit: ok"
  local verify=$scratch/verify
  mkdir -m 0700 -- "$verify"
  jq -r '.seats[0].public_key' "$keys" | gpg --homedir "$verify" --batch --import 2> /dev/null
  check "[C40] the gpg signature verifies against keys.json's public key" \
    exit_is 0 env GNUPGHOME="$verify" gpg --batch --verify "$root/harbor/berth/msg.asc" "$root/harbor/berth/msg"
  printf 'keeper %s\n' "$(jq -r '.seats[0].ssh' "$keys" | cut -d' ' -f1,2)" > "$scratch/allowed"
  check "[C40] the ssh signature verifies against keys.json's line" \
    exit_is 0 bash -c 'ssh-keygen -Y verify -f "$1" -I keeper -n file -s "$2.sig" < "$2"' _ "$scratch/allowed" "$root/harbor/berth/msg"
  check "[C40] the commit verifies against keys.json's public key" exit_is 0 env GNUPGHOME="$verify" git -C "$root/harbor/berth/repo" verify-commit HEAD
  check "[C40] its committer is the seat's name and address" \
    test "$(git -C "$root/harbor/berth/repo" log -1 --format='%cn <%ce>')" = "Harbor Keeper <harbor.dock.keeper@$w>"
  agent_of "$verify" && gpgconf --homedir "$verify" --kill gpg-agent > /dev/null 2>&1
  gpgconf --homedir "$verify" --remove-socketdir > /dev/null 2>&1
  check "watch ran" wait_for_probe "Harbor Watch" watch
  if [[ -d $runtime/systemd ]]; then
    check "[C84] in keeper's view, / read-only and no chain, the user's runtime directory is an empty file system" r "entries $runtime: "
    if command -v busctl > /dev/null && timeout 10 busctl --address="unix:path=$runtime/bus" call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.DBus.Properties Get ss org.freedesktop.systemd1.Manager Version > /dev/null 2>&1; then
      check "[C84] outside every view the user's manager answers over the bus, and from keeper's pane it is refused there" r "bus $runtime/bus: refused"
    else
      skip "[C84] no user manager answers over the session bus here, so its refusal from a pane is tried where one does"
    fi
    check "[C84] and its own socket, which stands outside, is not there" \
      bash -c '[[ -S $1/systemd/private ]] && grep -qxF "connect $1/systemd/private: absent" "$2"' _ "$runtime" "$report"
    local found=0
    for agent in "${agents[@]}"; do
      [[ -S $runtime/$agent ]] || continue
      found=1
      check "[C84] the user's ssh agent's socket $runtime/$agent, which stands outside, is not there" r "connect $runtime/$agent: absent"
    done
    (( found )) || skip "[C84] no ssh agent of the user's keeps its socket in $runtime here, so its absence from a pane is shown by the empty runtime directory alone"
    check "[C84] keeper, under the mask, signs through its own agent" bash -c 'grep -qxF "key gpg sign: ok" "$1" && grep -qxF "key ssh sign: ok" "$1"' _ "$report"
    check "picker ran" wait_for_probe "Orchard Picker" picker
    check "[C84] picker's hidden row at the runtime directory stands as written, closed, with no mask over it" grep -qxF "list $runtime: refused" "$root/orchard/crate-picker/report"
    check "[C84] picker, whose row hides the runtime directory, signs through its own agent too" \
      bash -c 'grep -qxF "key gpg sign: ok" "$1" && grep -qxF "key ssh sign: ok" "$1"' _ "$root/orchard/crate-picker/report"
    check "[C84] watch's scratch row beneath the runtime directory stands, after the mask: empty and writable" \
      grep -qxF "scratch $runtime/systemd: entries=0 write=ok" "$root/harbor/charts/report"
  else
    skip "[C84] no runtime directory with a manager's socket stands here, so the runtime directory's mask is tried from a pane where one does"
  fi
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
  local altering=$scratch/altering
  mkdir -p -- "$altering"
  printf '%s\n' '#!/usr/bin/env bash' 'words=() quick=0 next=0' 'for w in "$@"; do [[ $w == --quick-gen-key ]] && quick=1; done' \
    'for w in "$@"; do if (( quick && next )); then words+=("$w (altered)"); next=0; continue; fi; [[ $w == -- ]] && next=1; words+=("$w"); done' \
    "exec '$(command -v gpg)' \"\${words[@]}\"" > "$altering/gpg"
  chmod +x -- "$altering/gpg"
  statements_plan "$key_terms"
  check "plan" exit_is 0 wplan
  check "[C35] a user id that gpg does not make as asked refuses the build" exit_is 1 env PATH="$altering:$PATH" "$BASH" "$loop" build
  check "[C35] naming both" said "gpg did not make the user id 'Harbor Keeper <harbor.dock.keeper@$w>'"
  if [[ -d /run/user/$EUID/gnupg && -r /run/user/$EUID/gnupg ]]; then
    check "[C42] after every build, up, status, why, down and refusal of this test, no key home, nor the test's own home for verifying, has a runtime socket directory" no_socket_dir_left
    check "[C42] nor has any home of the first build, whose directories were noted while its agents ran" \
      bash -c 'for d in "${@:2}"; do [[ $d == "$1"/keys/* || ! -e $d ]] || exit 1; done' _ "$state" "${socket_dirs[@]}"
  else
    skip "[C42] /run/user/$EUID/gnupg cannot be read here, so the directories left after the whole test are measured where it can"
  fi
}

ssh_terms='def s($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/SSH.typify"}};
  .programs[-1].recorded += [
    s(["ssh-key", "account", "keys/account"]; 1), s(["ssh-key", "node-rsa", $root + "/keys/node-rsa"]; 2), s(["ssh-key", "node-ec", "keys/node-ec"]; 3),
    s(["ssh-grant", "-", "-", "-", "workplace", "account", "granted"]; 4), s(["ssh-grant", "harbor", "-", "-", "office", "node-rsa", "granted"]; 5),
    s(["ssh-grant", "harbor", "dock", "keeper", "seat", "node-ec", "granted"]; 6), s(["ssh-grant", "orchard", "barn", "picker", "seat", "account", "none"]; 7),
    st("-"; "-"; "-"; "workplace"; $root + "/keys"; "hidden"; 9)]'
ssh_refused() {
  statements_plan "$key_terms | $ssh_terms | .programs[-1].recorded += [$1]"
  exit_is 1 wplan || return 1
  said "$2" || { note "    wanted: $2"; sed 's/^/    | /' "$scratch/out"; return 1; }
}

t_ssh_grants_fold() {
  scoped_clone
  statements_plan "$key_terms | $ssh_terms"
  check "plan with ssh keys and grants" exit_is 0 wplan
  check "[C85] each seat that holds a key is granted each name by the narrowest scope that speaks, and a grant reaches no seat that holds none" \
    test "$(jq -c '[.seats[] | [.seat[2], [.ssh.granted[] | "\(.name) \(.scope) \(.origins[0].line)"], [.ssh.unreached[].name]]]' "$clone/PLAN/view.json")" = \
    '[["keeper",["account workplace 4","node-ec seat 6","node-rsa office 5"],[]],["pilot",[],["account","node-rsa"]],["watch",[],["account","node-rsa"]],["grower",["account workplace 4"],[]],["picker",[],[]]]'
  check "[C85] a key's path is joined to the root where it is relative, and stands as written where it is absolute" \
    test "$(jq -c '[.ssh.keys[] | [.name, .path]]' "$clone/PLAN/view.json")" \
      = "$(jq -c -n --arg r "$root" '[["account", "\($r)/keys/account"], ["node-rsa", "\($r)/keys/node-rsa"], ["node-ec", "\($r)/keys/node-ec"]]')"
  check "[C85] plan prints each key and its file" said "ssh key account: $root/keys/account (programs/SSH.typify:1)"
  check "[C85] and, for each seat, the names it is granted with their terms" \
    bash -c 'grep -qxF "  ssh key node-ec: granted, by the seat'"'"'s term (programs/SSH.typify:6)" "$1" && grep -qxF "  ssh key account: granted, by the workplace'"'"'s term (programs/SSH.typify:4)" "$1"' _ "$scratch/out"
  check "[C85] and, for a seat of the scope that holds no key, that the grant does not reach it" \
    said "  ssh key node-rsa: the office's grant does not reach it, since the seat holds no key (programs/SSH.typify:5)"
  check "[C85] the fold's version is one that reads ssh grants" \
    test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-v12
  statements_plan "$key_terms | $ssh_terms"' | .programs[-1].recorded += [s(["ssh-key", "node", "keys/node"]; 10), s(["ssh-key", "tower", "keys/tower"]; 11), s(["ssh-grant", "harbor", "tower", "-", "room", "tower", "granted"]; 12)]'
  check "plan with a key that no grant takes, and one granted to a room whose seat holds no key" exit_is 0 wplan
  check "[C85] plan names a key that no grant takes to a seat that holds a key as reaching no seat" \
    bash -c 'for k in node:10 tower:11; do grep -qxF "ssh key ${k%:*}: $2/keys/${k%:*} (programs/SSH.typify:${k#*:}), and it reaches no seat: no grant takes it to a seat that holds a key" "$1" || exit 1; done' _ "$scratch/out" "$root"
  check "[C85] and a key that reaches one by its file alone" \
    bash -c 'for k in account:1 node-rsa:2 node-ec:3; do grep -qxF "ssh key ${k%:*}: $2/keys/${k%:*} (programs/SSH.typify:${k#*:})" "$1" || exit 1; done' _ "$scratch/out" "$root"
  check "[C85] two ssh-key terms of one name that differ refuse the plan with exit 1, naming both" \
    ssh_refused 's(["ssh-key", "account", "keys/other"]; 10)' "two ssh-key terms of the name account differ: $root/keys/account from programs/SSH.typify:1, $root/keys/other from programs/SSH.typify:10"
  check "[C85] two ssh-grant terms of one scope and name with different states refuse it, naming both" \
    ssh_refused 's(["ssh-grant", "harbor", "-", "-", "office", "node-rsa", "none"]; 10)' "two ssh-grant terms of the office harbor for the key node-rsa differ: granted from programs/SSH.typify:5, none from programs/SSH.typify:10"
  check "[C85] a grant of a name that no ssh-key term declares refuses it" \
    ssh_refused 's(["ssh-grant", "-", "-", "-", "workplace", "ghost", "granted"]; 10)' "programs/SSH.typify:10: the ssh-grant names the key ghost, which no ssh-key term declares"
  check "[C85] a grant at a seat's own scope to a seat that holds no key refuses it, naming the seat and both terms" \
    ssh_refused 's(["ssh-grant", "harbor", "dock", "pilot", "seat", "account", "granted"]; 10)' "seat Harbor Pilot (harbor/dock/pilot): the ssh-grant at programs/SSH.typify:10 grants the key account at the seat's own scope, and the seat holds no key, so it has no agent to hold it (the key at programs/IDENTITY.typify:4)"
  check "[C85] a key's file that a seat's table shows read-only refuses it, naming the seat, its row and the key's term" \
    ssh_refused 'st("harbor"; "dock"; "keeper"; "seat"; $root + "/keys"; "read-only"; 10)' "seat Harbor Keeper (harbor/dock/keeper): the file $root/keys/account of the ssh key account (the ssh-key at programs/SSH.typify:1) is shown to the seat by its row $root/keys read-only (from programs/policy.typify:10), and no seat is shown the file of a private key"
  check "[C85] and so does one that a seat's table shows read-write, by a room's row that replaces the workplace's hidden one" \
    ssh_refused 'st("orchard"; "barn"; "-"; "room"; $root + "/keys"; "read-write"; 10)' "seat Orchard Picker (orchard/barn/picker): the file $root/keys/node-ec of the ssh key node-ec (the ssh-key at programs/SSH.typify:3) is shown to the seat by its row $root/keys read-write (from programs/policy.typify:10)"
  check "[C85] a grant naming a seat the plan does not make refuses it" \
    ssh_refused 's(["ssh-grant", "harbor", "dock", "ghost", "seat", "account", "granted"]; 10)' "programs/SSH.typify:10: the ssh-grant names the seat harbor/dock/ghost, which the plan does not make"
  statements_plan "$key_terms | $ssh_terms"' | .programs[-1].recorded += [s(["ssh-key", "-x", "keys/x"]; 10), s(["ssh-grant", "-", "-", "-", "workplace", "account", "maybe"]; 11), s(["ssh-key", "short"]; 12), s(["ssh-grant", "-", "-", "-", "kind", "account", "granted"]; 13)]'
  check "[C85] a name the rule for a key refuses, a state other than granted and none, a wrong count of words and a scope it does not take refuse the plan" exit_is 1 wplan
  check "[C85] naming each" bash -c 'grep -qF "SSH.typify:10: the ssh key'"'"'s name \"-x\" is refused: it begins with -" "$1" && grep -qF "SSH.typify:11: maybe is not granted or none" "$1" \
    && grep -qF "SSH.typify:12: an ssh-key has the words ssh-key NAME PATH, not 2" "$1" && grep -qF "SSH.typify:13: kind is not a scope of an ssh-grant" "$1"' _ "$scratch/out"
  check "[C85] a path with a .. component refuses the plan" \
    ssh_refused 's(["ssh-key", "dots", "keys/../dots"]; 10)' "programs/SSH.typify:10 (ssh-key): the path \"keys/../dots\" is refused: it has a . or .. component"
  statements_plan "$ssh_terms"' | .programs[-1].recorded |= map(select(.term[0] | startswith("ssh")))'
  check "[C85] a plan with ssh terms alone is folded, and refused for want of a row for /" exit_is 1 wplan
  check "[C85] naming a seat" said "no row for /"
}

ssh_shims() {
  local program
  mkdir -p -- "$scratch/shims"
  for program in ssh-keygen ssh-add; do
    printf '%s\n' '#!/usr/bin/env bash' \
      "printf '%s %s stdin=%s\n' $program \"\$*\" \"\$(readlink /proc/\$\$/fd/0)\" >> '$scratch/reads'" \
      "exec '$(command -v "$program")' \"\$@\"" > "$scratch/shims/$program"
    chmod +x -- "$scratch/shims/$program"
  done
}
reads_of() { grep -cF -- "$1" "$scratch/reads"; }

t_ssh_key_refusals() {
  local program
  for program in ssh-keygen python3 gpg; do
    command -v "$program" > /dev/null || { skip "[C86] $program is not on PATH here, so the refusals of a key's file are shown where it is"; return; }
  done
  scoped_clone
  local keys=$root/keys state=$HOME/.local/state/workplace/$label case
  mkdir -m 0700 -- "$keys"
  ssh-keygen -q -t ed25519 -N '' -f "$keys/account" < /dev/null
  ssh-keygen -q -t ecdsa -b 256 -N '' -f "$keys/node-ec" < /dev/null
  statements_plan "$key_terms | $ssh_terms"
  check "plan" exit_is 0 wplan
  local -A said_for=(
    [missing]="build refuses: the ssh key node-rsa, $keys/node-rsa, is missing"
    [directory]="build refuses: the ssh key node-rsa, $keys/node-rsa, is not a regular file"
    [passphrase]="build refuses: the ssh key node-rsa, $keys/node-rsa, asks for a passphrase, and build loads only a key that asks for none"
    [text]="build refuses: the ssh key node-rsa, $keys/node-rsa, is not a private key that ssh reads: "
    [public]="build refuses: the ssh key node-rsa, $keys/node-rsa, is not a private key that ssh reads: "
    [rsa1024]="build refuses: the ssh key node-rsa, $keys/node-rsa, is an RSA key of 1024 bits; the frame takes RSA of 2048 bits or more"
    [security]="build refuses: the ssh key node-rsa, $keys/node-rsa, is a security key's file, of the kind sk-ssh-ed25519@openssh.com, which the agent does not take"
    [dsa]="build refuses: the ssh key node-rsa, $keys/node-rsa, is of the kind ssh-dss; the frame takes ed25519, RSA of 2048 bits or more, and ECDSA on nistp256, nistp384 or nistp521")
  for case in missing directory passphrase text public rsa1024 security dsa; do
    rm -rf -- "$keys/node-rsa" "$keys/node-rsa.pub" "$clone/BUILD"
    case $case in
      directory) mkdir -- "$keys/node-rsa" ;;
      passphrase) ssh-keygen -q -t rsa -b 3072 -m PEM -N 'a passphrase of the tests' -f "$keys/node-rsa" < /dev/null ;;
      text) printf '%s\n' 'a line that is not a key' > "$keys/node-rsa" ;;
      public) ssh-keygen -q -t ed25519 -N '' -f "$keys/node-rsa-made" < /dev/null && cp -- "$keys/node-rsa-made.pub" "$keys/node-rsa" && rm -f -- "$keys/node-rsa-made" "$keys/node-rsa-made.pub" ;;
      rsa1024) ssh-keygen -q -t rsa -b 1024 -N '' -f "$keys/node-rsa" < /dev/null ;;
      security) python3 -I "$fixtures/sk-key" "$keys/node-rsa" ;;
      dsa)
        if ! ssh-keygen -q -t dsa -N '' -f "$keys/node-rsa" < /dev/null > /dev/null 2>&1; then
          skip "[C86] this OpenSSH makes no DSA key, so the refusal of a kind that ssh reads and the frame does not take is shown where it does"
          continue
        fi
        ;;
    esac
    rm -f -- "$keys/node-rsa.pub"
    check "[C86] build refuses the key's file ($case), with exit 1" exit_is 1 wp build
    check "[C86] naming the key and its file" said "${said_for[$case]}"
    check "[C86] before it makes any key home, and leaving no BUILD" bash -c '[[ ! -e $1/BUILD && ! -e $2/keys ]]' _ "$clone" "$state"
  done
  local missing=
  for program in gpg-agent gpgconf gpg-connect-agent ssh-add setsid base64; do
    command -v "$program" > /dev/null || missing+=" $program"
  done
  if [[ -n $missing ]]; then
    skip "[C86] not on PATH here:$missing, so that build takes an RSA key of 2048 bits is shown where they are"
  else
    rm -rf -- "$keys/node-rsa" "$clone/BUILD"
    ssh-keygen -q -t rsa -b 2048 -N '' -f "$keys/node-rsa" < /dev/null
    rm -f -- "$keys/node-rsa.pub"
    check "[C86] build takes an RSA key of exactly 2048 bits, the floor" exit_is 0 wp build
    check "[C86] and keys.json gives it the kind rsa 2048" \
      test "$(jq -r '[.seats[].grants[] | select(.name == "node-rsa") | .kind] | unique | join(", ")' "$clone/BUILD/keys.json")" = "rsa 2048"
  fi
  rm -rf -- "$keys/node-rsa" "$clone/BUILD"
  ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -f "$keys/node-rsa" < /dev/null
  local without=$scratch/path-without-ssh-add dir entry
  local -a dirs found
  local -A have=()
  mkdir -p -- "$without"
  IFS=: read -r -a dirs <<< "$PATH"
  for dir in "${dirs[@]}"; do
    found=()
    for entry in "$dir"/*; do
      [[ -x $entry && ! -d $entry && ${entry##*/} != ssh-add && -z ${have[${entry##*/}]-} ]] || continue
      have[${entry##*/}]=1
      found+=("$entry")
    done
    (( ${#found[@]} )) && ln -s -t "$without" -- "${found[@]}"
  done
  check "[C6] build refuses a plan that grants an ssh key where ssh-add is not on PATH, with exit 2" \
    exit_is 2 env PATH="$without" "$BASH" "$loop" build
  check "[C6] naming it" said "a plan that grants an ssh key needs ssh-add, and ssh-add is not on PATH"
}

t_ssh_grants() {
  local program
  for program in gpg gpg-agent gpgconf gpg-connect-agent ssh-keygen ssh-add ssh git setsid base64 python3; do
    command -v "$program" > /dev/null || { skip "[C87] $program is not on PATH here, so no ssh key is granted and used in a pane"; return; }
  done
  scoped_clone
  local w=$label state=$HOME/.local/state/workplace/$label keys=$root/keys berth=$root/harbor/berth sshd="" path name
  for path in /usr/sbin/sshd /usr/bin/sshd /sbin/sshd; do [[ -x $path ]] && { sshd=$path; break; }; done
  mkdir -m 0700 -- "$keys"
  mkdir -p -- "$root/records"
  ssh-keygen -q -t ed25519 -N '' -C account-comment -f "$keys/account" < /dev/null
  ssh-keygen -q -t rsa -b 3072 -m PEM -N '' -C node-rsa-comment -f "$keys/node-rsa" < /dev/null
  ssh-keygen -q -t ecdsa -b 384 -m PKCS8 -N '' -C node-ec-comment -f "$keys/node-ec" < /dev/null
  rm -f -- "$keys"/*.pub
  mkdir -m 0700 -- "$berth/sshd"
  ssh-keygen -q -t ed25519 -N '' -C host -f "$berth/sshd/host" < /dev/null
  ssh-keygen -y -f "$keys/account" > "$berth/sshd/authorized_keys"
  printf '%s\n' "HostKey $berth/sshd/host" "AuthorizedKeysFile $berth/sshd/authorized_keys" "StrictModes no" "UsePAM no" "PasswordAuthentication no" \
    "KbdInteractiveAuthentication no" "PubkeyAuthentication yes" "MaxAuthTries 1" "LogLevel VERBOSE" > "$berth/sshd/config"
  statements_plan "$key_terms | $ssh_terms | $records_terms"' | def add($path; $args): (.programs[] | select(.path == $path) | .plan[1].term[5]) |= (fromjson + $args | tojson);
    add("harbor/dock/keeper/seat.typify"; ["report=" + $root + "/harbor/berth/report", "grants=" + $root + "/harbor/berth|" + $root + "/keys|'"$sshd"'"])'
  check "plan" exit_is 0 wplan
  ssh_shims
  check "[C86] build checks and loads the granted keys" exit_is 0 env PATH="$scratch/shims:$PATH" "$BASH" "$loop" build
  check "[C87] naming each key and how many seats it is loaded for" said "ssh keys loaded: account for 2 seats, node-ec for 1 seat, node-rsa for 1 seat"
  check "[C86] [C87] each key's file is read by ssh-keygen once for the check, and on ssh-add's standard input once for each seat it is loaded for" \
    test "$(reads_of "$keys/account") $(reads_of "$keys/node-ec") $(reads_of "$keys/node-rsa") $(grep -c "^ssh-add -q - stdin=$keys/" "$scratch/reads")" = "3 2 2 4"
  local keys_json=$clone/BUILD/keys.json home=$state/keys/01 grower=$state/keys/04 picker=$state/keys/05
  check "[C87] keys.json gives each holding seat its grants by name" \
    test "$(jq -c '[.seats[] | [.seat[2], [.grants[].name]]]' "$keys_json")" = '[["keeper",["account","node-ec","node-rsa"]],["grower",["account"]],["picker",[]]]'
  local want
  want=$(for name in account node-ec node-rsa; do printf '%s %s\n' "$(ssh-keygen -y -f "$keys/$name" | cut -d' ' -f1,2)" "$name"; done)
  check "[C87] with the public OpenSSH line of each, NAME its comment" test "$(jq -r '.seats[0].grants[].ssh' "$keys_json")" = "$want"
  check "[C87] its SHA256 fingerprint" \
    test "$(jq -r '.seats[0].grants[].fingerprint' "$keys_json")" = "$(for name in account node-ec node-rsa; do ssh-keygen -l -f "$keys/$name" | cut -d' ' -f2; done)"
  check "[C87] and its kind" test "$(jq -r '[.seats[0].grants[].kind] | join(", ")' "$keys_json")" = "ed25519 256, ecdsa 384, rsa 3072"
  check "[C87] and the key's grip, the name of its file in the home" \
    bash -c 'for g in $(jq -r ".seats[0].grants[].grip" "$1"); do [[ -f $2/private-keys-v1.d/$g.key ]] || exit 1; done' _ "$keys_json" "$home"
  check "[C87] each holding seat's home holds one unprotected key file per grant beside its own two" \
    bash -c '[[ $(ls "$1/private-keys-v1.d" | wc -l) == 5 && $(ls "$2/private-keys-v1.d" | wc -l) == 3 && $(ls "$3/private-keys-v1.d" | wc -l) == 2 ]] && ! grep -q protected-private-key "$1"/private-keys-v1.d/*.key "$2"/private-keys-v1.d/*.key' _ "$home" "$grower" "$picker"
  check "[C87] sshcontrol holds the seat's own grip first, then each grant's, and is read-only, 0444" \
    test "$(grep -vE '^[[:space:]]*(#|$)' "$home/sshcontrol" | cut -d' ' -f1 | paste -sd' ') $(stat -c %a "$home/sshcontrol")" \
      = "$(gpg --homedir "$home" --with-colons --with-keygrip --list-keys | awk -F: '$1 == "grp" { g = $10 } END { print g }') $(jq -r '[.seats[0].grants[].grip] | join(" ")' "$keys_json") 444"
  check "[C87] the home holds ssh/NAME.pub for each grant, the line of keys.json, read-only" \
    bash -c 'for n in account node-ec node-rsa; do [[ $(< "$1/ssh/$n.pub") == "$(jq -r --arg n "$n" ".seats[0].grants[] | select(.name == \$n) | .ssh" "$2")" && $(stat -c %a "$1/ssh/$n.pub") == 444 ]] || exit 1; done' _ "$home" "$keys_json"
  check "[C87] a home with no grant has no ssh directory" test ! -e "$picker/ssh"
  check "[C35] [C88] the home's gpg-agent.conf says pinentry false, ssh support and no smartcard daemon, and never batch" \
    test "$(paste -sd' ' "$home/gpg-agent.conf")" = "pinentry-program $(command -v false) enable-ssh-support disable-scdaemon"
  check "[C87] no byte of a private key stands in BUILD" \
    bash -c '! grep -rqE "PRIVATE KEY|private-key" "$1" && for f in "$2"/*; do ! grep -rqF -- "$(sed -n 2p "$f")" "$1" || exit 1; done' _ "$clone/BUILD" "$keys"
  check "[C87] build leaves no agent running" no_agent_of "$state/keys"
  local t0 t1
  t0=$(date -u +%s)
  check "[C89] up, from a shell whose zone is nine hours east of UTC" exit_is 0 env TZ=XYZ-9 "$BASH" "$loop" up
  wp status > "$scratch/out" 2>&1
  check "[C92] status lists each agent's ssh keys by name" \
    bash -c 'grep -qxF "ok      the agent of Harbor Keeper offers its ssh keys: account, node-ec, node-rsa" "$1" && grep -qxF "ok      the agent of Orchard Grower offers its ssh keys: account" "$1"' _ "$scratch/out"
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  t1=$(date -u +%s)
  local report=$berth/report
  r() { grep -qxF -- "$1" "$report"; }
  check "[C90] keeper is shown the public files of its ssh keys at G/ssh" r "grants files: account.pub node-ec.pub node-rsa.pub "
  check "[C90] read-only" r "grants files write: refused"
  check "[C90] its agent offers its own key first" r "grants list first: $(jq -r '.seats[0].ssh' "$keys_json" | cut -d' ' -f1,2)"
  check "[C90] then each granted key, the comment being the file's own or (stdin), and never a path" \
    r "grants list after it: ssh-ed25519 account-comment|ecdsa-sha2-nistp384 (stdin)|ssh-rsa (stdin)"
  for name in account node-ec node-rsa; do
    check "[C90] keeper signs with $name through its ssh socket" r "grants sign $name: ok"
    printf 'keeper %s\n' "$(jq -r --arg n "$name" '.seats[0].grants[] | select(.name == $n) | .ssh' "$keys_json")" > "$scratch/allowed-$name"
    check "[C90] and the signature verifies against keys.json's line" \
      exit_is 0 bash -c 'ssh-keygen -Y verify -f "$1" -I keeper -n file -s "$2.sig" < "$2"' _ "$scratch/allowed-$name" "$berth/grants-msg-$name"
  done
  check "[C90] a forged add of a granted key is refused" r "grants forged add of account: refused"
  check "[C90] removing a granted key, and every key, changes nothing" r "grants after removing account and every key: listed"
  check "[C90] no file of a key stands in its view" r "grants key files: unseen"
  local extra grip forbidden=0
  extra=$(gpgconf --homedir "$home" --list-dirs agent-extra-socket)
  for grip in $(jq -r '.seats[0].grants[].grip' "$keys_json"); do
    for program in "READKEY $grip" "EXPORT_KEY $grip" "EXPORT_KEY --openpgp $grip" "DELETE_KEY --force $grip"; do
      [[ $(gpg-connect-agent --homedir "$home" --no-autostart -S "$extra" "$program" /bye 2>&1) == *Forbidden* ]] && forbidden=$(( forbidden + 1 ))
    done
  done
  check "[C90] through the extra socket the seat is shown, reading, exporting and deleting each granted key are forbidden" test "$forbidden" = 12
  if [[ -n $sshd ]]; then
    check "[C90] a login that offers every key the agent holds is refused by a host that allows one try" r "grants login all: refused"
    check "[C90] one that names the key's public file and offers only it logs in" r "grants login named: ok"
  else
    skip "[C90] no sshd is installed here, so the login both ways is shown where one is"
  fi
  local scd
  scd=$(gpgconf --list-components | awk -F: '$1 == "scdaemon" { print $3 }')
  if [[ -n $scd && -x $scd ]]; then
    check "[C88] after the seat's listings no smartcard daemon runs for its agent" \
      bash -c '[[ $(gpg-connect-agent --homedir "$1" --no-autostart "GETINFO scd_running" /bye 2>&1) == ERR* ]]' _ "$home"
  else
    skip "[C88] no smartcard daemon is installed here (gpgconf names ${scd:-none}), so that none runs after a listing is measured where one is"
  fi
  local signed="$state/records/Harbor Keeper/signed"
  check "[C91] keeper's agent logs to signed in its record a line for each ssh signature, with the second in UTC" \
    bash -c 'n=0; while IFS= read -r line; do at=$(date -u -d "${line:0:19}" +%s 2> /dev/null) || continue; (( at >= $2 && at <= $3 + 1 )) && n=$(( n + 1 )); done < <(grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} gpg-agent\[[0-9]+\] ssh request handler for sign_request \(13\) started$" "$1"); (( n >= 3 ))' \
      _ "$signed" "$t0" "$t1"
  local -a secrets=("a line the grants sign" "PRIVATE" "private-key")
  for name in $(jq -r '.seats[0] | .ssh, .ssh_fingerprint, (.grants[] | .ssh, .fingerprint, .grip)' "$keys_json"); do
    [[ $name == ssh-* || $name == ecdsa-* ]] && continue
    secrets+=("${name#SHA256:}")
  done
  for name in account node-ec node-rsa; do secrets+=("$(sed -n 2p "$keys/$name")"); done
  check "[C91] and nothing of the keys or of the data" bash -c 'for s in "${@:2}"; do ! grep -qF -- "$s" "$1" || exit 1; done' _ "$signed" "${secrets[@]}"
  check "[C72] [C91] the carrier chains signed among the kept files" \
    eventually_long bash -c 'jq -e "select(.file == \"Harbor Keeper/signed\")" "$1" > /dev/null 2>&1' _ "$state/records/chain"
  wp why "Harbor Keeper" "$state/gnupg/ssh" > "$scratch/out" 2>&1
  check "[C92] why names a seat's grants and the terms that give them" \
    said "ssh key account: granted, by the workplace's term, from programs/SSH.typify:4; the seat is shown its public file at $state/gnupg/ssh/account.pub"
  check "[C92] and the public files in its key view" said ", and in ssh/ the public files of its ssh keys, read-only"
  wp why "Harbor Pilot" / > "$scratch/out" 2>&1
  check "[C92] and, for a seat that holds no key, the grants that do not reach it" \
    said "ssh key account: granted by the workplace's term, from programs/SSH.typify:4, and it does not reach the seat, which holds no key"
  wp status > "$scratch/out" 2>&1
  check "[C92] and lists them so after the seat's signatures, its refused adds and its removals" \
    grep -qxF "ok      the agent of Harbor Keeper offers its ssh keys: account, node-ec, node-rsa" "$scratch/out"
  rm -f -- "$home/private-keys-v1.d/$(jq -r '.seats[0].grants[] | select(.name == "node-rsa") | .grip' "$keys_json").key"
  check "[C92] status exits 1 when an agent no longer offers a key the build loaded" exit_is 1 wp status
  check "[C92] naming the agent and its keys" \
    bash -c 'grep -qxF "gone    the agent of Harbor Keeper offers its ssh keys: account, node-ec, node-rsa" "$1" && grep -qF "no longer offers every ssh key the build loaded for it" "$1"' _ "$scratch/out"
  check "down" exit_is 0 wp down
  check "[C89] up refuses a key home whose agent no longer has every key the build loaded" exit_is 1 wp up
  check "[C89] naming the agent and the key" said "the agent of Harbor Keeper does not offer the ssh key node-rsa, which the build loaded for it; build again"
  check "[C89] and starts no server" no_server
  check "[C89] and leaves no agent running" no_agent_of "$state/keys"
  rm -rf -- "$clone/BUILD"
  check "build again" exit_is 0 wp build
  printf '%s\n' batch >> "$home/gpg-agent.conf"
  check "[C89] up refuses a home whose gpg-agent.conf says batch, with exit 1" exit_is 1 wp up
  check "[C89] naming the file" said "$home/gpg-agent.conf says batch, and an agent that serves a seat never runs with it"
  check "[C89] and starts no server" no_server
  check "[C89] and no agent" no_agent_of "$state/keys"
  sed -i '/^batch$/d' "$home/gpg-agent.conf"
  local machine
  machine=$(gpgconf --list-dirs sysconfdir)
  if [[ -d $machine ]]; then
    check "[C89] up refuses where the machine's gpg-agent.conf says batch, which every agent reads" \
      exit_is 1 bwrap --dev-bind / / --tmpfs "$machine" -- bash -c 'printf "%s\n" batch > "$1/gpg-agent.conf" && exec "$2" "$3" up' _ "$machine" "$BASH" "$loop"
    check "[C89] naming the file" said "the machine's $machine/gpg-agent.conf says batch, which every agent of GnuPG reads"
    check "[C89] and starts no server" no_server
    check "[C89] and no agent" no_agent_of "$state/keys"
  else
    skip "[C89] GnuPG's system directory $machine does not stand here, so a machine's gpg-agent.conf that says batch is tried where it does"
  fi
  check "[C89] up, the home's file mended" exit_is 0 wp up
  check "down" exit_is 0 wp down
  check "[C87] no agent of a key home runs after down" no_agent_of "$state/keys"
  check "[C75] [C91] record verify reads keeper's signed against its chain, over its whole span" exit_is 0 wp record verify "Harbor Keeper" signed
  check "[C75] and it agrees" said "Harbor Keeper/signed agrees with its chain up to byte "
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
edit_plan() {
  local name sum
  jq --arg root "$root" --arg c "$clone" "$1" "$clone/PLAN/plan.json" > "$scratch/p" && cp -- "$scratch/p" "$clone/PLAN/plan.json" || return 1
  if [[ -f $clone/PLAN/view.json ]]; then
    jq -L "$tool/libexec" --arg root "$root" --slurpfile b "$tool/host/binding.json" -f "$tool/libexec/fold.jq" "$clone/PLAN/plan.json" \
      | jq '.view' > "$scratch/v" && cp -- "$scratch/v" "$clone/PLAN/view.json" || return 1
  fi
  for name in plan.json view.json; do
    [[ -f $clone/PLAN/$name ]] || continue
    sum=$(sha256sum < "$clone/PLAN/$name") || return 1
    jq --arg n "$name" --arg s "${sum%% *}" '(.outputs[] | select(.path == $n) | .sha256) = $s' "$clone/PLAN/manifest.json" > "$scratch/m" \
      && cp -- "$scratch/m" "$clone/PLAN/manifest.json" || return 1
  done
}
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
    '{ printf "%s\n" "order $(tr "\0" "\n" < /proc/$$/environ | cut -d= -f1 | grep "^WPT_" | tr "\n" " ")" "pwd $PWD" "$(grep "^NoNewPrivs" /proc/self/status | tr -d " \t")" "names $(tr "\0" "\n" < /proc/$$/environ | cut -d= -f1 | LC_ALL=C sort | tr "\n" " ")" "WPT_HOME=${WPT_HOME-} WPT_CACHE=${WPT_CACHE-}" "cache $(if [[ -d $WPT_CACHE && ! -L $WPT_CACHE ]]; then stat -c %a "$WPT_CACHE"; else echo missing; fi)" "stdin $(readlink /proc/$$/fd/0)"; } > "$home/seeded.how"' \
    'printf "%s\n" "$home" >> "$HOME/seed-log"' > "$root/tools/seed"
  chmod +x -- "$root/tools/seed"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" one two "" three four "" five' 'printf "%s\n" "the seed fails on purpose" "" >&2' 'exit 3' > "$root/tools/failing-seed"
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
    test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-v12
  check "[C32] plan prints each seat's home and the names it expects" \
    bash -c 'grep -qF "seat Harbor Keeper (harbor/dock/keeper): kind navigator; cleared for no label, since neither its room nor its office has a clearance; home kept, by WPT_HOME; expects WPT_DOCK, WPT_TOKEN;" "$1" && grep -qF "seat Orchard Grower (orchard/barn/grower): kind gardener; cleared for no label, since neither its room nor its office has a clearance; home scratch, by WPT_HOME; expects WPT_ORCHARD, WPT_TOKEN;" "$1"' _ "$scratch/out"
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
    '.programs[-1].recorded += [h(["home-variable", "navigator", "WPT_HOME", "x"]; 9)]|the home variable WPT_HOME of the kind navigator is the variable that names its home (the home variable at programs/HOMES.typify:9; the home at programs/HOMES.typify:1)'
    '.state.kinds = [{key: ["lookout"], value: ["declared"]}] | .programs[-1].recorded += [h(["home-variable", "lookout", "WPT_X", "x"]; 9)]|programs/HOMES.typify:9: the kind lookout has a home variable and no home'
    '.state.kinds = [{key: ["lookout"], value: ["declared"]}] | .programs[-1].recorded += [h(["home-seed", "lookout", "tools/seed"]; 9)]|programs/HOMES.typify:9: the kind lookout has a seed and no home'
    '.programs[-1].recorded += [h(["home-seed", "gardener", "tools/seed"]; 9)]|the kind gardener has a seed and a scratch home, and build seeds only a kept one (the seed at programs/HOMES.typify:9; the home at programs/HOMES.typify:4)'
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
    '.state["seat-kinds"] |= map(if .key == ["harbor", "dock", "keeper"] then .value = [".."] else . end) | .programs[-1].recorded += [h(["home", "..", "WPT_HOME", "kept"]; 9)]|programs/policy.typify:30 (state seat-kinds): the kind ".." is refused: it is ..'
    '.state.environment += [{key: ["harbor", "dock", "keeper", "WPT_HOME"], value: ["/elsewhere"], masked: false, origin: at(40)}]|state environment: Harbor Keeper (harbor/dock/keeper) has a home, and its environment may not set WPT_HOME, which the frame gives (the row at programs/policy.typify:40; the home at programs/HOMES.typify:1)'
    '.state.environment += [{key: ["orchard", "barn", "picker", "WPT_CACHE"], value: ["/elsewhere"], masked: false, origin: at(40)}]|state environment: Orchard Picker (orchard/barn/picker) has a home, and its environment may not set WPT_CACHE, which the frame gives (the row at programs/policy.typify:40; the home variable at programs/HOMES.typify:5)'
    '.state.environment += [{key: ["harbor", "dock", "keeper", "WPT_DOCK"], value: ["plain"], masked: false, origin: at(40)}]|state environment: Harbor Keeper (harbor/dock/keeper) expects the value WPT_DOCK at its start, and its environment may not set it (the row at programs/policy.typify:40; the expect at programs/VALUES.typify:2)'
    "$key_terms"' | .state.environment += [{key: ["harbor", "dock", "keeper", "SSH_AUTH_SOCK"], value: ["/elsewhere"], masked: false, origin: at(40)}]|state environment: Harbor Keeper (harbor/dock/keeper) holds a key, and its environment may not set SSH_AUTH_SOCK, which the frame gives (the row at programs/policy.typify:40; the key at programs/IDENTITY.typify:3)'
  )
  local entry
  for entry in "${plan_refusals[@]}"; do
    check "[C45] plan refuses, with exit 1: ${entry##*|}" refused_by 1 plan "${entry%|*}" "${entry##*|}"
  done
  check "[C45] and after every refusal PLAN/ is as it was" test "$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)" = "$planned"
  statements_plan "$home_terms | $value_terms"
  check "plan with homes and expected values again" exit_is 0 wplan
  edit_plan '.state.environment += [{key: ["harbor", "dock", "keeper", "WPT_HOME"], value: ["/elsewhere"], masked: false, origin: {kind: "program", line: 40, path: "programs/policy.typify"}}]'
  check "[C48] build keeps its own check: a plan written with such a row by hand is refused, with exit 1" exit_is 1 wp build
  check "[C48] naming the seat and both origins" said "state environment: Harbor Keeper (harbor/dock/keeper) has a home, and its environment may not set WPT_HOME, which the frame gives (the row at programs/policy.typify:40; the home at programs/HOMES.typify:1)"
  check "[C48] and leaves no BUILD" test ! -e "$clone/BUILD"
  check "[C45] the names the frame keeps are the binding's kept-names, the very names its fixed part gives" \
    test "$(jq -c '.["kept-names"] as $k | [.tables[]["after-rows"]?[]? | (.environment // [])[] | .[0]] | unique == ($k | sort) and $k == ["GNUPGHOME", "SSH_AUTH_SOCK"]' "$tool/host/binding.json")" = true
  write_seed
  local hk="$HOME/.local/state/workplace/$label/homes/navigator/Harbor Keeper"
  statements_plan "$home_terms"' | .programs[-1].recorded += [h(["home-variable", "navigator", "WPT_b", "b/deep"]; 9), h(["home-variable", "navigator", "WPT_A", "a"]; 10), h(["home-variable", "navigator", "WPT__", "u"]; 11)]'
  check "plan with further variables written out of the code-point order of their names" exit_is 0 wplan
  check "[C47] build" exit_is 0 wp build
  check "[C48] a seat's further variables stand in the code-point order of their names, after the kind's variable: in view.json, in BUILD/homes.json and in the seed's environment" \
    bash -c '[[ $(jq -c "[.seats[] | select(.seat == [\"harbor\", \"dock\", \"keeper\"]) | .home.variables[].name]" "$1/PLAN/view.json") == "[\"WPT_A\",\"WPT_CACHE\",\"WPT__\",\"WPT_b\"]" \
      && $(jq -c "[.seats[] | select(.name == \"Harbor Keeper\") | .environment[][0]]" "$1/BUILD/homes.json") == "[\"WPT_HOME\",\"WPT_A\",\"WPT_CACHE\",\"WPT__\",\"WPT_b\"]" ]] \
      && grep -qxF "order WPT_HOME WPT_A WPT_CACHE WPT__ WPT_b " "$2/seeded.how"' _ "$clone" "$hk"
  check "[C47] each directory of a further variable is made, mode 0700, each name on the way down too" \
    test "$(cd "$hk" && find a b u cache -printf '%p %m %y,')" = "a 700 d,b 700 d,b/deep 700 d,u 700 d,cache 700 d,"
  mkdir -- "$scratch/outside"
  rm -rf -- "$hk/b" "$clone/BUILD"
  ln -s -- "$scratch/outside" "$hk/b"
  check "[C47] build, with a link in the home where a further variable's way goes down" exit_is 0 wp build
  check "[C47] makes nothing through the link, and says so, naming the variable, the seat and the path" \
    bash -c 'grep -qxF "home: WPT_b of Harbor Keeper (harbor/dock/keeper) names $1/b/deep, and $1/b is a link or not a directory; build makes nothing there" "$2" && [[ -L $1/b && -z $(ls -A "$3") ]]' _ "$hk" "$scratch/out" "$scratch/outside"
}

t_homes() {
  scoped_clone
  write_seed
  local w=$label s=$HOME/.local/state/workplace/$label
  local hk="$HOME/.local/state/workplace/$label/homes/navigator/Harbor Keeper" hp="$HOME/.local/state/workplace/$label/homes/navigator/Harbor Pilot"
  local hg="$HOME/.local/state/workplace/$label/homes/gardener/Orchard Grower"
  local args='| add("harbor/dock/keeper/seat.typify"; ["report=" + $root + "/harbor/berth/keeper", "home=WPT_HOME", "value=WPT_CACHE", "hidden=" + $s + "/homes/navigator/Harbor Pilot"])
    | add("harbor/tower/watch/seat.typify"; ["report=" + $root + "/harbor/charts/watch", "home=WPT_HOME", "hidden=" + $s])
    | add("orchard/barn/grower/seat.typify"; ["report=" + $root + "/orchard/almanac/grower", "home=WPT_HOME", "value=WPT_CACHE"])'
  statements_plan "$home_terms | $probe_args ${args//\$s/\"$s\"}"' | .programs[-1].recorded += [h(["record-directory", "harbor", "dock", "keeper", "harbor"]; 10)]'
  check "plan" exit_is 0 wplan
  check "[C46] build" exit_is 0 wp build
  check "[C46] it makes a kept home for keeper and for pilot, each seeded" \
    bash -c 'grep -qxF "home: $1 made for Harbor Keeper (harbor/dock/keeper), and seeded by $3" "$4" && grep -qxF "home: $2 made for Harbor Pilot (harbor/dock/pilot), and seeded by $3" "$4"' _ "$hk" "$hp" "$root/tools/seed" "$scratch/out"
  check "[C46] a kept home is S/homes/KIND/NAME, named by its kind and its seat's name; it, S/homes and the kind's directory are 0700, and nothing else stands there" \
    test "$(cd "$s/homes" && find . -maxdepth 2 -type d -printf '%p %m\n' | LC_ALL=C sort | tr '\n' ',')" = ". 700,./navigator 700,./navigator/Harbor Keeper 700,./navigator/Harbor Pilot 700,"
  check "[C46] no directory stands for a scratch home, or for a seat of no kind" test ! -e "$s/homes/gardener"
  check "[C46] the frame's record names the seat of each kept home, by the home's name" \
    test "$(jq -c 'map_values(del(.words))' "$s/homes.json")" = '{"navigator/Harbor Keeper":{"seat":"harbor/dock/keeper","state":"made"},"navigator/Harbor Pilot":{"seat":"harbor/dock/pilot","state":"made"}}'
  check "[C46] and only its owner may read it" test "$(stat -c %a "$s/homes.json")" = 600
  check "[C46] BUILD/homes.json, listed in the MANIFEST, holds each home with its variables" \
    bash -c 'grep -qE "^[0-9a-f]{64}  homes\.json$" "$1/MANIFEST" && [[ $(jq -c "[.seats[] | [.name, .state, .home, .environment]]" "$1/homes.json") == "$2" ]]' _ "$clone/BUILD" \
    "$(jq -c -n --arg s "$s/homes" '[["Harbor Keeper", "kept", "homes/navigator/Harbor Keeper", [["WPT_HOME", "\($s)/navigator/Harbor Keeper"], ["WPT_CACHE", "\($s)/navigator/Harbor Keeper/cache"]]],
      ["Harbor Pilot", "kept", "homes/navigator/Harbor Pilot", [["WPT_HOME", "\($s)/navigator/Harbor Pilot"], ["WPT_CACHE", "\($s)/navigator/Harbor Pilot/cache"]]],
      ["Orchard Grower", "scratch", "homes/gardener/Orchard Grower", [["WPT_HOME", "\($s)/gardener/Orchard Grower"], ["WPT_CACHE", "\($s)/gardener/Orchard Grower"]]],
      ["Orchard Picker", "scratch", "homes/gardener/Orchard Picker", [["WPT_HOME", "\($s)/gardener/Orchard Picker"], ["WPT_CACHE", "\($s)/gardener/Orchard Picker"]]]]')"
  check "[C47] the seed ran once for each new kept home" test "$(grep -c '' "$HOME/seed-log")" = 2
  check "[C47] with the home, then the seat's start directory, then its declared directories, joined and each once, as its words" \
    test "$(cat "$hk/seeded" | tr '\n' ' ')" = "$root/harbor $root/harbor/berth $root/harbor/vault "
  check "[C47] a seat that declares none is given its start directory alone" test "$(cat "$hp/seeded" | tr '\n' ' ')" = "$root/harbor "
  check "[C47] in the home" grep -qxF "pwd $hk" "$hk/seeded.how"
  check "[C47] with nothing on standard input" grep -qxF "stdin /dev/null" "$hk/seeded.how"
  check "[C47] given the home's variables" grep -qxF "WPT_HOME=$hk WPT_CACHE=$hk/cache" "$hk/seeded.how"
  check "[C47] the further variable's directory is made, mode 0700, before the seed runs" grep -qxF "cache 700" "$hk/seeded.how"
  check "[C47] and nothing of the caller's but the inherited names" \
    bash -c 'line=$(grep "^names " "$1"); for n in ${line#names }; do [[ " $2 PWD WPT_HOME WPT_CACHE " == *" $n "* ]] || exit 1; done' _ "$hk/seeded.how" "$(jq -r '.inherit | join(" ")' "$tool/host/binding.json")"
  if [[ $(nnp_of $$) == NoNewPrivs:1 ]]; then
    skip "[C47] the seed reports NoNewPrivs:1, but so would any process this shell starts; measured where the shell does not run under it"
  else
    check "[C47] under no-new-privileges" grep -qxF "NoNewPrivs:1" "$hk/seeded.how"
  fi
  check "[C48] up" exit_is 0 wp up
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  local report=$root/harbor/berth/keeper
  r() { grep -qxF -- "$2" "$1"; }
  check "[C48] keeper is given its home through the kind's variable" r "$report" "home WPT_HOME: $hk"
  check "[C48] and the further variable, the path inside it" r "$report" "value WPT_CACHE=$hk/cache"
  check "[C48] it writes there" r "$report" "home write: ok"
  check "[C48] it sees what the seed wrote" r "$report" "home seeded: $root/harbor $root/harbor/berth $root/harbor/vault "
  check "[C48] a kept home is the machine's directory itself" r "$report" "home where: $(stat -c %d:%i "$hk")"
  check "[C48] of the homes beside it, keeper sees its own alone" r "$report" "home siblings: Harbor Keeper "
  check "[C48] of S, the homes alone" r "$report" "home state: homes "
  check "[C48] and of the kinds, its own alone" r "$report" "home kinds: navigator "
  check "[C48] pilot's home is not shown to keeper" r "$report" "hidden $hp: unseen"
  check "grower ran" wait_for_probe "Orchard Grower" grower
  report=$root/orchard/almanac/grower
  check "[C48] grower's scratch home is a file system of the pane" r "$report" "home fs: tmpfs"
  check "[C48] made for it alone, not a directory of the mask around it" r "$report" "home own file system: yes"
  check "[C48] at its path, 0700, empty at the start and writable" \
    bash -c 'grep -qxF "home WPT_HOME: $2" "$1" && grep -qxF "home mode: 700" "$1" && grep -qxF "home starts: 1" "$1" && grep -qxF "home entries: starts " "$1"' _ "$report" "$hg"
  check "[C48] a further variable written . is the home itself" r "$report" "value WPT_CACHE=$hg"
  check "watch ran" wait_for_probe "Harbor Watch" watch
  check "[C48] a seat of no kind has no home variable" r "$root/harbor/charts/watch" "home WPT_HOME: unset"
  check "[C48] and is shown nothing of S" r "$root/harbor/charts/watch" "hidden $s: unseen"
  wp status > "$scratch/out" 2>&1
  check "[C51] status names each home and its state" \
    bash -c 'grep -qxF "home    Harbor Keeper (harbor/dock/keeper): kept at $2, named to its program by WPT_HOME" "$1" && grep -qxF "home    Orchard Grower (orchard/barn/grower): scratch, a file system made when its pane starts at $3, named to its program by WPT_HOME" "$1"' _ "$scratch/out" "$hk" "$hg"
  wp why "Harbor Keeper" "$hk/x" > "$scratch/out" 2>&1
  check "[C51] why names the seat's home, its variables, its seed and their terms" \
    bash -c 'grep -qxF "home: kept at $2, named to its program by WPT_HOME, by the kind navigator'"'"'s term, from programs/HOMES.typify:1" "$1" && grep -qxF "  home variable WPT_CACHE: the home'"'"'s cache, from programs/HOMES.typify:2" "$1" && grep -qxF "  seeded by $3 when build makes the home, from programs/HOMES.typify:3" "$1"' _ "$scratch/out" "$hk" "$root/tools/seed"
  check "[C51] and that a path in it is the seat's own, shown read-write" said "the seat's home: shown read-write at its own path by the frame after the rows (Home), to this seat alone"
  wp why "Harbor Watch" "$hk" > "$scratch/out" 2>&1
  check "[C51] for another seat the same path is masked" said "masked by the frame after the rows (Identity, Home): $HOME/.local/state/workplace, where workplaces keep their state, is shown to no seat"
  wp doctor > "$scratch/out" 2>&1
  check "[C51] doctor counts the homes" said "ok      the seats' homes in $s/homes: 2 kept, 2 scratch"
  mv -- "$hp" "$hp.away"
  check "[C51] status exits 1 for a kept home that is missing" exit_is 1 wp status
  check "[C51] naming it" said "missing home $hp of Harbor Pilot (harbor/dock/pilot); build again"
  mv -- "$hp.away" "$hp"
  check "[C48] down" exit_is 0 wp down
  check "[C48] nothing of a scratch home is left on the machine" test ! -e "$s/homes/gardener"
  check "[C48] up again, with no build" exit_is 0 wp up
  check "keeper ran again" eventually bash -c 'grep -qxF "home starts: 2" "$1"' _ "$root/harbor/berth/keeper"
  check "[C46] a kept home keeps what its seat wrote" r "$root/harbor/berth/keeper" "home starts: 2"
  check "grower ran again" wait_for_probe "Orchard Grower" grower
  check "[C48] a scratch home starts empty every time" r "$root/orchard/almanac/grower" "home starts: 1"
  check "down" exit_is 0 wp down
  rm -rf -- "$clone/BUILD" "$hk/cache"
  check "[C47] build again" exit_is 0 wp build
  check "[C47] no seed runs for a home that exists" test "$(grep -c '' "$HOME/seed-log")" = 2
  check "[C47] and build says nothing of it" bash -c '! grep -q "^home: " "$1"' _ "$scratch/out"
  check "[C47] a further variable's directory missing from a home that exists is made again, mode 0700" \
    bash -c '[[ -d $1 && ! -L $1 && $(stat -c %a "$1") == 700 ]]' _ "$hk/cache"
  rm -rf -- "$clone/BUILD" "$hp"
  statements_plan "$home_terms | $probe_args"' | (.programs[-1].recorded[] | select(.term[0] == "home-seed") | .term[2]) = "tools/failing-seed"'
  check "plan with a failing seed" exit_is 0 wplan
  check "[C47] a seed that fails refuses the build, with exit 1" exit_is 1 wp build
  check "[C47] naming the seed, the kind, the seat and the exit, with the last five lines it said that are not empty, empty lines between and after them" \
    said "build refuses: the seed $root/tools/failing-seed of the kind navigator failed for Harbor Pilot (harbor/dock/pilot) with exit 3, and its new home is removed: two three four five the seed fails on purpose "
  check "[C47] its new home is removed, the old one kept, and the record names the old one alone" \
    bash -c '[[ ! -e $2 && -d $3 && $(jq -c "keys" "$1/homes.json") == "[\"navigator/Harbor Keeper\"]" ]]' _ "$s" "$hp" "$hk"
  check "[C47] and no BUILD is left" test ! -e "$clone/BUILD"
  statements_plan "$home_terms | $probe_args"' | (.programs[-1].recorded[] | select(.term[0] == "home-seed") | .term[2]) = "tools/nothing"'
  check "plan with a seed that is not there" exit_is 0 wplan
  check "[C47] a seed that is not an executable file refuses the build" exit_is 1 wp build
  check "[C47] naming it" said "build refuses: the seed $root/tools/nothing of the kind navigator is not an executable file"
  statements_plan "$home_terms | $probe_args"
  check "plan" exit_is 0 wplan
  local kh="navigator/Harbor Keeper"
  jq --arg h "$kh" '.[$h].seat = "orchard/barn/picker"' "$s/homes.json" > "$scratch/h" && cp -- "$scratch/h" "$s/homes.json"
  check "[C46] a kept home that the record gives another seat refuses the build" exit_is 1 wp build
  check "[C46] naming both seats" said "build refuses: $s/homes.json gives the home $hk to the seat orchard/barn/picker, not to Harbor Keeper (harbor/dock/keeper); it is left alone"
  jq --arg h "$kh" 'del(.[$h])' "$s/homes.json" > "$scratch/h" && cp -- "$scratch/h" "$s/homes.json"
  check "[C46] a directory the record does not name refuses the build" exit_is 1 wp build
  check "[C46] and is left alone" bash -c 'grep -qF "build refuses: $1 exists, and $2/homes.json names no seat for it; the frame did not make it, so it is left alone" "$3" && [[ -f $1/starts ]]' _ "$hk" "$s" "$scratch/out"
  jq --arg h "$kh" '.[$h] = {seat: "harbor/dock/keeper", state: "seeding"}' "$s/homes.json" > "$scratch/h" && cp -- "$scratch/h" "$s/homes.json"
  check "[C47] a home whose seed did not finish is made and seeded again" exit_is 0 wp build
  check "[C47] saying so" said "home: $hk of Harbor Keeper (harbor/dock/keeper) was left unseeded by an earlier build, and is made again"
  check "[C47] the seed ran for it and for pilot's new home" test "$(grep -c '' "$HOME/seed-log")" = 4
  rm -rf -- "$clone/BUILD"
  statements_plan "$home_terms | $probe_args"' | .programs |= reverse'
  check "plan with the panes in the reverse order" exit_is 0 wplan
  check "[C46] keeper is now the last pane" test "$(jq -c '.seats[-1].seat' "$clone/PLAN/view.json")" = '["harbor","dock","keeper"]'
  check "[C46] build" exit_is 0 wp build
  check "[C46] a new order of the panes moves no home: none is made, none refused, no seed runs" \
    bash -c '! grep -q "^home: " "$1" && [[ $(grep -c "" "$2") == 4 ]]' _ "$scratch/out" "$HOME/seed-log"
  rm -rf -- "$clone/BUILD"
  statements_plan "$home_terms | $probe_args"' | .state["seat-kinds"] |= map(if .key == ["harbor", "dock", "pilot"] then .value = ["lookout"] else . end) | .programs[-1].recorded += [h(["home", "lookout", "WPT_HOME", "kept"]; 10)]'
  check "plan with pilot of another kind" exit_is 0 wplan
  check "[C46] build" exit_is 0 wp build
  check "[C46] a seat whose kind changes is given another home, named by its new kind" said "home: $s/homes/lookout/Harbor Pilot made for Harbor Pilot (harbor/dock/pilot)"
  check "[C46] and its old home stays as it was" test -f "$hp/seeded"
  check "[C47] the record keeps the words each home was seeded with" \
    test "$(jq -c --arg h "$kh" '.[$h].words' "$s/homes.json")" = "[\"$hk\",\"$root/harbor\",\"$root/harbor/berth\",\"$root/harbor/vault\"]"
  rm -rf -- "$clone/BUILD"
  statements_plan "$home_terms | $probe_args"' | .programs[-1].recorded |= map(select(.term[0] != "record-directory" or .term[4] != ($root + "/harbor/vault")))'
  check "plan with a directory of keeper's withdrawn" exit_is 0 wplan
  check "[C47] build" exit_is 0 wp build
  check "[C47] says in one line that the seat's words now differ from those its home was seeded with, naming the directories" \
    said "home: Harbor Keeper (harbor/dock/keeper) would now be seeded with $root/harbor $root/harbor/berth, and its home $hk was seeded with $root/harbor $root/harbor/berth $root/harbor/vault; build does not seed it again"
  check "[C47] and seeds nothing again" test "$(grep -c '' "$HOME/seed-log")" = 4
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
    seats: {"Harbor Keeper": {WPT_TOKEN: $k}}}' > "$values"
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
  jq -n '{workplace: {WPT_TOKEN: ""}, rooms: {"harbor/dock": {WPT_DOCK: "two\nlines"}}, seats: {"Orchard Picker": {WPT_NUL: "a\u0000b"}}}' > "$values"
  check "[C49] an empty value, one of two lines and one with a NUL byte refuse up" exit_is 1 wp up
  check "[C49] naming each name and no value" \
    bash -c 'grep -qF "$2: its workplace gives WPT_TOKEN an empty value" "$1" && grep -qF "$2: its rooms entry \"harbor/dock\" gives WPT_DOCK a value of more than one line, or with a NUL byte" "$1" && grep -qF "$2: its seats entry \"Orchard Picker\" gives WPT_NUL a value of more than one line, or with a NUL byte" "$1" && ! grep -q lines "$1"' _ "$scratch/out" "$values"
  jq -n --arg k "$keeper_token" '{workplace: {WPT_TOKEN: "the workplace token"}, rooms: {"harbor/dock": {WPT_DOCK: "the dock value"}},
    offices: {orchard: {WPT_ORCHARD: "the orchard value"}}, seats: {"Harbor Keeper": {WPT_TOKEN: $k}}}' > "$values"
  local old=$scratch/old-env
  mkdir -p -- "$old"
  printf '%s\n' '#!/usr/bin/env bash' 'if [[ ${1-} == --version ]]; then printf "%s\n" "env (GNU coreutils) 8.29"; exit 0; fi' "exec $(command -v env) \"\$@\"" > "$old/env"
  chmod +x -- "$old/env"
  check "[C6] an env older than 8.30 is refused by up when a seat expects a value, with exit 2" exit_is 2 env PATH="$old:$PATH" "$BASH" "$loop" up
  check "[C6] naming both versions" said "env 8.29 found; 8.30 or later is needed"
  check "[C6] and starts nothing" bash -c '[[ ! -e $1 ]]' _ "$run"
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
  check "[C51] and that env fills a value's place, with its version" grep -qE "^ok      env [0-9]+\.[0-9]+ takes -S and fills a variable's place in it" "$scratch/out"
  chmod 0640 -- "$values"
  check "[C51] status exits 1 for a run-time file it refuses" exit_is 1 wp status
  check "[C51] naming why" said "refused $values has the mode 640, and others than its owner may read it"
  cp -- "$scratch/out" "$scratch/said-status-loose"
  wp doctor > "$scratch/said-doctor-loose" 2>&1
  check "[C51] and so does doctor" grep -qF "refused $values has the mode 640" "$scratch/said-doctor-loose"
  check "[C49] exec refuses it too, with exit 2" exit_is 2 wp exec --print "Harbor Keeper"
  check "[C6] and exec refuses an env older than 8.30, with exit 2" exit_is 2 env PATH="$old:$PATH" "$BASH" "$loop" exec --print "Harbor Keeper"
  check "[C6] naming both versions" said "env 8.29 found; 8.30 or later is needed"
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
  jq --arg k "$new_token" '.seats["Harbor Keeper"].WPT_TOKEN = $k | .rooms = {"harbor/dock": {WPT_DOCK: "the dock value"}}' "$values" > "$scratch/v" && cp -- "$scratch/v" "$values"
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
    | .programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; $root + "/config/PLAN"; "hidden"; 22)]
    | (.programs[-1].recorded[] | select(.term[0] == "home-seed") | .term[2]) = "config/seed"'
  statements_plan "$home_terms | $probe_args $args"
  check "[C52] plan takes a hidden row beneath the clone, and a seed in the clone" exit_is 0 wplan
  check "[C52] build runs a seed that lies in the clone, outside every view" exit_is 0 wp build
  check "[C52] it ran" said "home: $HOME/.local/state/workplace/$label/homes/navigator/Harbor Keeper made for Harbor Keeper (harbor/dock/keeper), and seeded by $clone/seed"
  check "up" exit_is 0 wp up
  check "[C52] keeper's view masks the clone after its rows: the hidden row's closed file system, then the clone's" \
    test "$(view_ops "$(seat_command 'Harbor Keeper')" | grep -nE "^[a-z-]+ $clone(/|\$)" | cut -d: -f2 | tr '\n' ',')" = "tmpfs $clone/PLAN,tmpfs $clone,"
  check "[C52] and closes it: 0000" test "$(jq -r --arg c "$clone" '. as $a | [range(0; length) | select($a[.] == "--tmpfs" and $a[. + 1] == $c) | $a[. - 1]] | join(",")' <<< "$(seat_command 'Harbor Keeper')")" = 0000
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  local report=$root/harbor/berth/keeper
  check "[C52] inside keeper's pane the clone cannot be listed, though the row above it, / read-only, would show it" \
    bash -c 'grep -qxF "hidden $2: unseen" "$1" && grep -qxF "list $2: refused" "$1" && grep -qxF "hidden $2/BUILD: unseen" "$1"' _ "$report" "$clone"
  check "watch ran" wait_for_probe "Harbor Watch" watch
  check "[C52] nor in watch's" grep -qxF "hidden $clone: unseen" "$root/harbor/charts/watch"
  wp why "Harbor Keeper" "$clone/BUILD" > "$scratch/out" 2>&1
  check "[C52] why names the mask" said "masked by the frame after the rows: $clone, the clone the workplace is built from, with its PLAN and BUILD, is shown to no seat, whatever its rows say"
  check "[C23] and says that the mask, not the nearest row, decides" \
    bash -c 'grep -qxF "no row at the path; its nearest ancestor'"'"'s row is / read-only" "$1" && grep -qxF "  the frame'"'"'s mask above decides for the path, and the row does not" "$1"' _ "$scratch/out"
  check "down" exit_is 0 wp down
  local planned
  planned=$(cat "$clone/PLAN/plan.json" "$clone/PLAN/manifest.json" | sha256sum)
  local refusals=(
    '(.programs[] | select(.path == "harbor/dock/keeper/seat.typify") | .plan[1].term[4]) = "config"|harbor/dock/keeper/seat.typify, term 2 (start): the seat'"'"'s directory '"$clone"' lies in the clone '"$clone"', which the frame masks in every view'
    '(.programs[] | select(.path == "harbor/dock/keeper/seat.typify") | .plan[1].term[5]) = (["config/tools/probe"] | tojson)|harbor/dock/keeper/seat.typify, term 2 (start): the seat'"'"'s program '"$clone"'/tools/probe lies in the clone '"$clone"', which the frame masks in every view'
    '.programs[-1].recorded += [h(["record-directory", "harbor", "dock", "pilot", "config/work"]; 9)]|programs/HOMES.typify:9 (record-directory): the seat'"'"'s directory '"$clone"'/work lies in the clone '"$clone"', which the frame masks in every view'
    '.programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; $root + "/config"; "read-only"; 22)]|seat Harbor Keeper (harbor/dock/keeper): '"$clone"' (read-only, from programs/policy.typify:22) lies at or beneath the clone '"$clone"', which the frame hides in every view as a hidden row would'
    '.programs[-1].recorded += [st("orchard"; "barn"; "-"; "room"; $root + "/config/BUILD"; "scratch"; 23)]|seat Orchard Picker (orchard/barn/picker): '"$clone"'/BUILD (scratch, from programs/policy.typify:23) lies at or beneath the clone '"$clone"', which the frame hides in every view as a hidden row would'
  )
  local entry
  for entry in "${refusals[@]}"; do
    statements_plan "$home_terms | ${entry%|*}"
    check "[C52] plan refuses, with exit 1, a seat in the clone or a row that would open it: ${entry##*|}" exit_is 1 wplan
    check "[C52] naming it" said "${entry##*|}"
  done
  check "[C52] each seat that the row speaks for is named" said "seat Orchard Grower (orchard/barn/grower): $clone/BUILD (scratch, from programs/policy.typify:23) lies at or beneath the clone"
  check "[C52] and PLAN/ is as it was" test "$(cat "$clone/PLAN/plan.json" "$clone/PLAN/manifest.json" | sha256sum)" = "$planned"
  rm -rf -- "$clone/BUILD"
  edit_plan '.programs[-1].recorded += [{term: ["statement", "harbor", "dock", "keeper", "seat", $c, "read-write"], origin: {kind: "program", line: 22, path: "programs/policy.typify"}}]'
  check "[C52] build refuses a plan written by hand with a row that would open the clone, with exit 1" exit_is 1 wp build
  check "[C52] naming the seat and the path" said "seat Harbor Keeper (harbor/dock/keeper): $clone (read-write, from programs/policy.typify:22) lies at or beneath the clone $clone"
  statements_plan "$home_terms | $probe_args $args"
  check "plan" exit_is 0 wplan
  edit_plan '(.programs[] | select(.path == "harbor/dock/keeper/seat.typify") | .plan[1].term[4]) = $c'
  check "[C52] build refuses a plan written by hand with a seat in the clone too" exit_is 1 wp build
  check "[C52] naming it" said "harbor/dock/keeper/seat.typify, term 2 (start): the seat's directory $clone lies in the clone $clone"
}

t_a_server_belongs_to_one_clone() {
  label=default
  render default > "$scratch/plan.json"
  check "build and up a workplace whose server is named default, as any clone's may be" up_fixture
  check "[C53] its server's socket stands in the clone's run directory" test -S "$run/default"
  check "[C53] up marks its server with its clone" test "$(T show-options -gqv @workplace-clone)" = "$clone"
  wp status > "$scratch/out" 2>&1
  check "[C53] status reads the mark" said "ok      the server, process $(T display -p '#{pid}'), carries this clone's mark"
  check "[C53] and prints the line that attaches to the server" said "attach  tmux -S '$run/default' attach"
  local second=$root/config2
  make_clone "$second"
  cp -- "$scratch/plan.json" "$scratch/plan-first.json"
  render default "$second/tmux.conf" > "$scratch/plan.json"
  PLAN_CLONE=$second make_plan
  cp -- "$scratch/plan-first.json" "$scratch/plan.json"
  check "build another clone that names the same server" exit_is 0 env WORKPLACE_CONFIG="$second" "$BASH" "$loop" build
  check "[C53] it comes up beside the first, on a server of its own, since each run's socket stands in its own clone" \
    exit_is 0 env WORKPLACE_CONFIG="$second" "$BASH" "$loop" up
  check "[C53] each server carries its own clone's mark" \
    test "$(T show-options -gqv @workplace-clone) $(tmux -S "$second/BUILD/RUN/default" show-options -gqv @workplace-clone)" = "$clone $second"
  check "down the second" exit_is 0 env WORKPLACE_CONFIG="$second" "$BASH" "$loop" down
  check "[C53] and the first stands as it was" sessions_are "Harbor Orchard "
  T set-option -g @workplace-clone /elsewhere
  check "[C53] status exits 1 when the server carries another clone's mark" exit_is 1 wp status
  check "[C53] naming it" said "refused the server at $run/default carries the mark of the clone /elsewhere, not this one's"
  check "[C53] down refuses it, with exit 2" exit_is 2 wp down
  check "[C53] and keeps RUN" test -d "$run"
  T set-option -gu @workplace-clone
  check "[C53] status exits 1 when the run's own server has lost its mark" exit_is 1 wp status
  check "[C53] telling it from another server by the process the run recorded" said "missing the server, process $(T display -p '#{pid}'), is the run's own and has lost its mark"
  T new-session -d -s extra
  check "[C53] down goes on, each undo checking its own mark" exit_is 0 wp down
  check "[C53] and leaves the session it did not make" sessions_are "extra "
  check "[C53] keeping RUN, which holds the server's socket, while that server stands" said "down: the server at $run/default still holds sessions that this run did not make (1); $run, which holds its socket, is kept while it stands"
  T kill-server
}

t_no_seat_reaches_a_tmux_server() {
  local default_dir=$TMUX_TMPDIR/tmux-$UID
  B -f /dev/null new-session -d -s outside
  local outside=$default_dir/bystander
  check "a second tmux server stands in the user's default directory" test -S "$outside"
  make_plan --arg root "$root" --arg label "$label" --arg outside "$outside" --arg dd "$default_dir" \
    '(.programs[] | select(.path == "harbor/dock/keeper/seat.typify") | .plan[1].term[5]) |= (fromjson
      + ["report=" + $root + "/harbor/berth/keeper", "socket=" + $root + "/config/BUILD/RUN/" + $label, "socket=" + $outside, "list=" + $dd] | tojson)'
  check "[C68] keeper's only row above the run directory and the user's tmux directory is / read-only" \
    test "$(jq -r --arg a "$run" --arg b "$default_dir" '[.state.view[] | select(.key[2] == "keeper") | .key[3] as $p
      | select($p == "/" or ($a | startswith($p + "/")) or ($b | startswith($p + "/"))) | "\($p) \(.value[0])"] | join(",")' "$clone/PLAN/plan.json")" = "/ read-only"
  check "build" exit_is 0 wp build
  check "up" exit_is 0 wp up
  check "[C68] the workplace's server listens in the run directory, in the clone" test -S "$run/$label"
  check "keeper ran" eventually_long grep -qx "probe keeper done" "$root/harbor/berth/keeper"
  check "[C68] from inside a seat's view the workplace's server, tried by its real path, is refused" \
    grep -qxF "socket $run/$label: refused" "$root/harbor/berth/keeper"
  check "[C68] and so is a second server of the user's, in the user's default tmux directory" \
    grep -qxF "socket $outside: refused" "$root/harbor/berth/keeper"
  check "[C68] the user's tmux directory cannot be listed there" grep -qxF "list $default_dir: refused" "$root/harbor/berth/keeper"
  check "[C68] while outside every view the workplace's server answers" exit_is 0 T list-sessions
  check "[C68] and so does the second" exit_is 0 B list-sessions
  check "[C68] keeper's view masks the user's tmux directory after its rows, closed" \
    test "$(jq -r --arg d "$default_dir" '. as $a | [range(0; length) | select($a[.] == "--tmpfs" and $a[. + 1] == $d) | $a[. - 1]] | join(",")' <<< "$(seat_command 'Harbor Keeper')")" = 0000
  wp why "Harbor Keeper" "$default_dir/bystander" > "$scratch/out" 2>&1
  check "[C68] why names the mask" said "masked by the frame after the rows: $default_dir, where the user's tmux servers keep their sockets, is shown to no seat"
  check "down" exit_is 0 wp down
}

t_source_and_contract() {
  check "[C8] the loop holds no eval" bash -c '! grep -nw eval "$1"/bin/workplace "$1"/libexec/*' _ "$tool"
  check "[C8] the loop holds no sh -c or bash -c" \
    bash -c '! grep -nE "(^|[^[:alnum:]])(ba)?sh -c" "$1"/bin/workplace "$1"/libexec/* "$1"/host/binding.json' _ "$tool"
  check "[C17] nothing sends keys or pastes into a pane but the carrier's typing, which its write and its pointer use: no send, send-prefix or paste-buffer anywhere, and send-keys only in the two words the carrier types with, called from those two places alone" \
    bash -c '! grep -rnE "(^|[^[:alnum:]-])(send|send-prefix|paste-buffer|pasteb)([^[:alnum:]-]|$)" "$1"/bin "$1"/libexec "$1"/host && [[ $(grep -rnw "send-keys" "$1"/bin "$1"/libexec "$1"/host | grep -c .) == 2 ]] && [[ $(sed -n "/^carrier_type() {/,/^}/p" "$1"/bin/workplace | grep -cw send-keys) == 2 ]] && [[ $(grep -w carrier_type "$1"/bin/workplace | grep -vc "^carrier_type() {$") == 2 ]] && [[ $(sed -n "/^carrier_serve() {/,/^}/p;/^carrier_wake() {/,/^}/p" "$1"/bin/workplace | grep -cw carrier_type) == 2 ]]' _ "$tool"
  check "[C9] every -t of the binding names a captured slot, never a name or an index" \
    test "$(jq '[.primitives[] | (.call, .then, .claim.call, .undo.when, .undo.call, .check.call) | select(. != null) | . as $c
      | range(0; length) | select($c[.] == "-t") | $c[. + 1] | (type == "object" and has("slot"))] | all' "$tool/host/binding.json")" = true
  check "[C17] respawn-pane -k is followed by clear-history in start" \
    test "$(jq -r '.primitives.start.call | map(strings) | (index("respawn-pane") < index("clear-history"))' "$tool/host/binding.json")" = true
  check "[C10] every tmux call runs under setpriv --no-new-privs and names its server" \
    test "$(jq -c '.programs.tmux.argv[0:5]' "$tool/host/binding.json")" = '[{"slot":["program","setpriv"]},"--no-new-privs",{"slot":["program","tmux"]},"-S",{"slot":["socket-path"]}]'
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
  check "[C29] the fold's version that the contract names is the one the loop writes" \
    bash -c '[[ $(grep -oE "The fold'"'"'s version is \`[^\`]+\`" "$1/CONTRACT.md" | grep -c .) == 1 && $(grep -oE "The fold'"'"'s version is \`[^\`]+\`" "$1/CONTRACT.md" | cut -d"\`" -f2) == "$(sed -n "s/^FOLD_DERIVATION=//p" "$1/bin/workplace")" ]]' _ "$tool"
  local n missing=""
  for n in $(grep -oE '\*\*C[0-9]+\.\*\*' "$tool/CONTRACT.md" | tr -d '*.'); do
    grep -qE "^[[:space:]]*check \"\\[$n\\]" "$here/run.sh" || missing+=" $n"
  done
  check "every sentence of the contract is shown by a check that carries its number${missing:+ (missing:$missing)}" test -z "$missing"
}

comms_terms='def m($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/COMMS.typify"}};
  .programs[-1].recorded += [m(["mail", "mailbox"]; 1)]'
comms_reach='| .programs[-1].recorded += [
    m(["reach", "-", "-", "-", "workplace", "grab", "harbor", "-", "-", "office", "allowed"]; 2),
    m(["reach", "harbor", "dock", "-", "room", "grab", "harbor", "tower", "-", "room", "banned"]; 3),
    m(["reach", "harbor", "dock", "keeper", "seat", "grab", "orchard", "-", "-", "office", "allowed"]; 4),
    m(["reach", "-", "-", "-", "workplace", "write", "orchard", "-", "-", "office", "allowed"]; 5),
    m(["reach", "-", "-", "-", "workplace", "write", "orchard", "barn", "picker", "seat", "banned"]; 6),
    m(["reach", "orchard", "-", "-", "office", "mail", "harbor", "-", "-", "office", "banned"]; 7),
    m(["reach", "-", "-", "-", "workplace", "grab", "harbor", "-", "-", "office", "allowed"]; 8)]'
box_of() {
  case $1 in
    keeper) printf '%s\n' "Harbor Keeper" ;;
    pilot) printf '%s\n' "Harbor Pilot" ;;
    watch) printf '%s\n' "Harbor Watch" ;;
    grower) printf '%s\n' "Orchard Grower" ;;
    picker) printf '%s\n' "Orchard Picker" ;;
  esac
}
state_of() { printf '%s\n' "$HOME/.local/state/workplace/$label"; }
request() {
  local seat=$1 name=$2
  shift 2
  printf '%s\n' "$@" > "$(state_of)/comms/$(box_of "$seat")/out/$name"
}
answer_of() {
  local file i
  file=$(state_of)/comms/$(box_of "$1")/answers/$2
  for (( i = 0; i < 1200; i++ )); do
    [[ -s $file ]] && { cat -- "$file"; return 0; }
    sleep 0.05
  done
  printf '%s\n' "no answer"
}
answered() {
  local got
  got=$(answer_of "$1" "$2" | head -n 1)
  [[ $got == "$3" ]] || { note "    the answer to $2 is: $got"; note "    wanted: $3"; return 1; }
}
answered_ok() {
  local got
  got=$(answer_of "$1" "$2" | head -n 1)
  [[ $got =~ ^ok\ [0-9]{8}T[0-9]{6}Z-[0-9]{6}$ ]] || { note "    the answer to $2 is: $got"; return 1; }
}
mail_of() { find "$(state_of)/mail/$(box_of "$1")/$2" -type f -name '*.md' | LC_ALL=C sort; }
store_commits() { env -i PATH="$PATH" HOME="$scratch" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$(state_of)/mail" rev-list --count HEAD 2> /dev/null || printf '%s\n' 0; }
records() { grep -c '' "$(state_of)/comms/record"; }
record_lines_reach() {
  local i
  for (( i = 0; i < 300; i++ )); do
    (( $(records) >= $1 )) && return 0
    sleep 0.05
  done
  return 1
}
carrier_pid() { jq -r 'select(.what | startswith("the carrier, pid ")) | .what | ltrimstr("the carrier, pid ")' "$run/ledger"; }

t_comms_fold() {
  scoped_clone
  mkdir -p -- "$root/mailbox"
  statements_plan "$comms_terms $comms_reach"
  check "plan with mail and reach terms" exit_is 0 wplan
  check "[C54] view.json names the mail path, joined to the root, with its origin" \
    test "$(jq -c '.mail' "$clone/PLAN/view.json")" = '{"path":"'"$root"'/mailbox","origins":[{"kind":"program","line":1,"path":"programs/COMMS.typify"}]}'
  local hk='"Harbor Keeper"' hp='"Harbor Pilot"' hw='"Harbor Watch"' og='"Orchard Grower"' op='"Orchard Picker"'
  check "[C54] each seat's reach: the narrowest asking scope, then the narrowest target, decides; with no term a seat mails every seat and grabs and writes none" \
    test "$(jq -c '[.seats[] | [.seat[2], .reach.mail, .reach.grab, .reach.write]]' "$clone/PLAN/view.json")" = \
    "[[\"keeper\",[$hk,$hp,$hw,$og,$op],[$hk,$hp,$og,$op],[$og]],[\"pilot\",[$hk,$hp,$hw,$og,$op],[$hk,$hp],[$og]],[\"watch\",[$hk,$hp,$hw,$og,$op],[$hk,$hp,$hw],[$og]],[\"grower\",[$og,$op],[$hk,$hp,$hw],[$og]],[\"picker\",[$og,$op],[$hk,$hp,$hw],[$og]]]"
  check "[C54] plan prints the mail path" said "mail: $root/mailbox, where each seat is shown its own mailbox (programs/COMMS.typify:1)"
  check "[C54] and each seat's reach, with the origins of the terms that decide it; equal terms count once and name each origin" \
    said "  grab: Harbor Keeper (programs/COMMS.typify:2, programs/COMMS.typify:8), Harbor Pilot (programs/COMMS.typify:2, programs/COMMS.typify:8), Orchard Grower (programs/COMMS.typify:4), Orchard Picker (programs/COMMS.typify:4)"
  check "[C54] the workplace's term lets every seat write to Orchard Grower, and the seat's term bans Orchard Picker" \
    bash -c 'grep -c "^  write: Orchard Grower (programs/COMMS.typify:5)$" "$1" | grep -qx 5' _ "$scratch/out"
  wp why "Harbor Keeper" "$root/mailbox/in" > "$scratch/out" 2>&1
  check "[C55] why names the mailbox, which decides the path whatever the rows say" \
    bash -c 'grep -qxF "the seat'"'"'s mailbox: shown by the frame after the rows (Comms) at $2, whatever is there on the machine: out read-write, where the seat leaves its requests; in, sent and answers read-only; the seat'"'"'s own, and no other seat'"'"'s" "$1" && grep -qxF "  the frame'"'"'s mask above decides for the path, and the row does not" "$1"' _ "$scratch/out" "$root/mailbox"
  check "[C29] the fold's version is the one that reads mail and reach" \
    test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-v12
  statements_plan "$comms_terms"
  check "plan with a mail term alone" exit_is 0 wplan
  check "[C54] with no reach term every seat mails every seat, and grabs and writes none; no clearance is read" \
    test "$(jq -c '[.seats[] | [(.reach.mail | length), .reach.grab, .reach.write]] | unique' "$clone/PLAN/view.json")" = '[[5,[],[]]]'
  check "[C54] a seat that may grab no seat is told so" bash -c 'grep -c "^  grab: no seat$" "$1" | grep -qx 5' _ "$scratch/out"
  statements_plan
  check "plan with neither" exit_is 0 wplan
  check "[C54] a plan with neither term gives no seat a reach, and view.json no mail" \
    test "$(jq '(has("mail")) or any(.seats[]; has("reach"))' "$clone/PLAN/view.json")" = false
  local planned
  planned=$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)
  local refusals=(
    "$comms_terms $comms_reach"' | .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "grab", "harbor", "-", "-", "office", "banned"]; 9)]|two reach terms of the workplace about grab to the office harbor differ: allowed from programs/COMMS.typify:2, allowed from programs/COMMS.typify:8, banned from programs/COMMS.typify:9'
    "$comms_terms"' | .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "record", "-", "-", "-", "workplace", "allowed"]; 9)]|the plan holds reach terms for records and no record-path term, so no seat is shown a record (the reach at programs/COMMS.typify:9)'
    "$comms_terms"' | .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "grab"]; 9)]|programs/COMMS.typify:9: a reach has the words reach A B C SCOPE ACTION TA TB TC TSCOPE STATE, not 6'
    "$comms_terms"' | .programs[-1].recorded += [m(["reach", "navigator", "-", "-", "kind", "grab", "-", "-", "-", "workplace", "allowed"]; 9)]|programs/COMMS.typify:9: kind is not a scope of a reach'
    "$comms_terms"' | .programs[-1].recorded += [m(["reach", "harbor", "-", "-", "room", "grab", "-", "-", "-", "workplace", "allowed"]; 9)]|programs/COMMS.typify:9: a room reach cannot name harbor - -'
    "$comms_terms"' | .programs[-1].recorded += [m(["reach", "harbor", "dock", "ghost", "seat", "grab", "-", "-", "-", "workplace", "allowed"]; 9)]|programs/COMMS.typify:9: the reach names the seat harbor/dock/ghost, which the plan does not make'
    "$comms_terms"' | .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "grab", "harbor", "attic", "-", "room", "allowed"]; 9)]|programs/COMMS.typify:9: the reach'"'"'s target names the room harbor/attic, which the plan does not make'
    "$comms_terms"' | .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "type", "-", "-", "-", "workplace", "allowed"]; 9)]|programs/COMMS.typify:9: type is not mail, grab, write or record'
    "$comms_terms"' | .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "grab", "-", "-", "-", "workplace", "maybe"]; 9)]|programs/COMMS.typify:9: maybe is not allowed or banned'
    "$comms_terms"' | .programs[-1].recorded += [m(["mail", "elsewhere"]; 9)]|two mail terms differ: '"$root"'/elsewhere from programs/COMMS.typify:9, '"$root"'/mailbox from programs/COMMS.typify:1'
    "$comms_terms"' | .programs[-1].recorded += [m(["mail", "a", "b"]; 9)]|programs/COMMS.typify:9: a mail has the words mail PATH, not 3'
    "$comms_terms"' | (.programs[-1].recorded[] | select(.term[0] == "mail") | .term[1]) = "/"|the mail path / would cover each seat'"'"'s whole view (the mail at programs/COMMS.typify:1)'
    'def m($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/COMMS.typify"}}; .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "grab", "-", "-", "-", "workplace", "allowed"]; 2)]|the plan holds reach terms and no mail term, so no seat has a mailbox to ask in (the reach at programs/COMMS.typify:2)'
    "$comms_terms"' | .programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; $root + "/mailbox/inner"; "read-only"; 22)]|programs/policy.typify:22: the statement speaks of '"$root"'/mailbox/inner, which lies at or beneath the mail path '"$root"'/mailbox, where the frame shows each seat its mailbox (the mail at programs/COMMS.typify:1)'
    "$comms_terms"' | .programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/mailbox"; "hidden"; 22)]|programs/policy.typify:22: the statement speaks of '"$root"'/mailbox, which lies at or beneath the mail path'
    "$comms_terms"' | .programs[-1].recorded += [lb($root + "/mailbox"; "1"; 23), sc(24)]|programs/policy.typify:23: the label speaks of '"$root"'/mailbox, which lies at or beneath the mail path '"$root"'/mailbox, where the frame shows each seat its mailbox (the mail at programs/COMMS.typify:1)'
    "$comms_terms"' | (.programs[-1].recorded[] | select(.term[0] == "mail") | .term[1]) = "harbor/ledger/box"|seat Harbor Keeper (harbor/dock/keeper): its mailbox at '"$root"'/harbor/ledger/box lies beneath '"$root"'/harbor/ledger (hidden, from programs/policy.typify:2), and the seat could not reach it (the mail at programs/COMMS.typify:1)'
    "$comms_terms"' | (.programs[-1].recorded[] | select(.term[0] == "mail") | .term[1]) = "config/mail"|the mail path '"$clone"'/mail lies at or beneath the clone '"$clone"', which the frame masks in every view (the mail at programs/COMMS.typify:1)'
    "$comms_terms"' | (.programs[-1].recorded[] | select(.term[0] == "mail") | .term[1]) = "orchard"|orchard/barn/grower/seat.typify, term 2 (start): the seat'"'"'s directory '"$root"'/orchard lies at or beneath the mail path '"$root"'/orchard, where the frame shows each seat its mailbox (the mail at programs/COMMS.typify:1)'
    "$comms_terms"' | (.programs[-1].recorded[] | select(.term[0] == "mail") | .term[1]) = "tools"|harbor/dock/keeper/seat.typify, term 2 (start): the seat'"'"'s program '"$root"'/tools/probe lies at or beneath the mail path '"$root"'/tools, where the frame shows each seat its mailbox (the mail at programs/COMMS.typify:1)'
    "$comms_terms"' | .programs[-1].recorded += [{term: ["record-directory", "harbor", "dock", "pilot", "mailbox/work"], origin: at(24)}]|programs/policy.typify:24 (record-directory): the seat'"'"'s directory '"$root"'/mailbox/work lies at or beneath the mail path '"$root"'/mailbox, where the frame shows each seat its mailbox (the mail at programs/COMMS.typify:1)'
    "$comms_terms"' | .programs[-1].recorded |= map(select(.term[0] != "statement" or .term[4] != "workplace")) | .programs[-1].recorded += [st("harbor"; "dock"; "-"; "room"; "/"; "read-only"; 25), st("orchard"; "-"; "-"; "office"; "/"; "read-only"; 26)]|seat Harbor Watch (harbor/tower/watch): no row for /: it has no view, and a seat with no view could write as any seat, which the plan'"'"'s mail terms do not allow (at programs/COMMS.typify:1)'
  )
  local entry
  for entry in "${refusals[@]}"; do
    statements_plan "${entry%|*}"
    check "[C54] plan refuses, with exit 1: ${entry##*|}" exit_is 1 wplan
    check "[C54] naming it" said "${entry##*|}"
  done
  check "[C54] and after every refusal PLAN/ is as it was" test "$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)" = "$planned"
  statements_plan "$comms_terms"' | .programs[-1].recorded += [m(["mail", "mailbox"]; 9)]'
  check "[C54] two equal mail terms count once" exit_is 0 wplan
  check "[C54] and name both origins" test "$(jq -c '[.mail.origins[].line]' "$clone/PLAN/view.json")" = '[1,9]'
}

t_keys_and_names() {
  make_plan '.programs[7].plan += [.programs[7].plan[0]]'
  check "[C3] build refuses a seat with two pane terms" exit_is 1 wp build
  check "[C3] naming the origin of each" said "the plan holds 2 pane terms for harbor/dock/pilot; one is allowed (harbor/dock/pilot/seat.typify, term 1; harbor/dock/pilot/seat.typify, term 3)"
  make_plan '.programs[7].plan |= .[0:1]'
  check "[C3] build refuses a pane with no start term" exit_is 1 wp build
  check "[C3] naming the pane's origin" said "the pane term for harbor/dock/pilot has no start term (harbor/dock/pilot/seat.typify, term 1)"
  make_plan '.programs[0].plan += [.programs[0].plan[0]]'
  check "[C3] build refuses two server terms" exit_is 1 wp build
  check "[C3] naming the origin of each" said "the plan holds 2 server terms; it needs exactly one (workplace.typify, term 1; workplace.typify, term 2)"
  make_plan '.programs[6].plan[0][3] = "kee per" | .programs[6].plan[1].term[3] = "kee per"'
  check "[C67] build refuses a key that is not one, in a plan written by hand" exit_is 1 wp build
  check "[C67] naming the term" said 'harbor/dock/keeper/seat.typify, term 1 (pane): the key "kee per" is refused: it holds white space'
  rm -rf -- "$clone/PLAN"
  scoped_clone
  statements_plan
  check "plan" exit_is 0 wplan
  local planned entry json
  planned=$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)
  local cases=(
    'kee per|it holds white space'
    $'kee per|it holds white space'
    '-|it is -, which the terms write for a key that a scope does not use'
    '-keeper|it begins with -'
    '.|it is .'
    '..|it is ..'
    'kee/per|it holds a /'
    '|it is empty'
  )
  for entry in "${cases[@]}"; do
    json=$(jq -n --arg k "${entry%%|*}" '$k')
    statements_plan 'terms_of("harbor/dock/keeper/seat.typify"; .[3] = '"$json"')'
    check "[C67] plan refuses a seat's key, with exit 1: $json, $(printf '%s' "${entry#*|}")" exit_is 1 wplan
    check "[C67] naming the term and the key" said "harbor/dock/keeper/seat.typify, term 1 (pane): the key $json is refused: ${entry#*|}"
  done
  statements_plan 'terms_of("harbor/office.typify"; .[1] = "har bor")'
  check "[C67] an office's key is checked in every term that holds it, its session's too" exit_is 1 wplan
  check "[C67] naming the session's term" said 'harbor/office.typify, term 1 (session): the key "har bor" is refused: it holds white space'
  statements_plan '.state["seat-kinds"] = [{key: ["harbor", "dock", "keeper"], value: ["navi gator"], masked: false, origin: at(30)}]'
  check "[C67] plan refuses a kind's name that is not a key" exit_is 1 wplan
  check "[C67] naming its row" said 'programs/policy.typify:30 (state seat-kinds): the kind "navi gator" is refused: it holds white space'
  local names=(
    'Pilot, Harbor|it holds a comma, and a mail'"'"'s head separates its readers by commas'
    'Harbor Pilot |it begins or ends with white space'
    ' Harbor Pilot|it begins or ends with white space'
    '.|it is .'
    '..|it is ..'
    '.git|it begins with ., and the seat'"'"'s directories in the store and the records are named by it'
    'Harbor/Pilot|it holds a /'
    $'Harbor\tPilot|it holds a control character'
    '|it is empty'
  )
  for entry in "${names[@]}"; do
    json=$(jq -n --arg k "${entry%%|*}" '$k')
    statements_plan 'terms_of("harbor/dock/pilot/seat.typify"; if .[0] == "pane" then .[4] = '"$json"' else . end)'
    check "[C67] plan refuses, in a plan without mail too, the seat's name $json: ${entry#*|}" exit_is 1 wplan
    check "[C67] naming the term" said "harbor/dock/pilot/seat.typify, term 1 (pane): the seat's name $json is refused: ${entry#*|}"
  done
  statements_plan 'terms_of("harbor/dock/pilot/seat.typify"; if .[0] == "pane" then .[4] = "Harbor Keeper" else . end)'
  check "[C67] plan refuses two seats of one name, with exit 1" exit_is 1 wplan
  check "[C67] naming both terms" said "the name Harbor Keeper is given to 2 of the pane terms; it must be unique (harbor/dock/keeper/seat.typify, term 1; harbor/dock/pilot/seat.typify, term 1)"
  check "[C67] and PLAN/ is as it was after every refusal" test "$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)" = "$planned"
  statements_plan 'terms_of("harbor/dock/keeper/seat.typify"; .[3] = ":(exclude).git")
    | (.programs[-1].recorded[] | select(.term[3] == "keeper") | .term[3]) = ":(exclude).git"'
  check "[C67] a key such as :(exclude).git is a key: plan takes it" exit_is 0 wplan
  mkdir -p -- "$root/mailbox"
  statements_plan "$comms_terms"' | terms_of("harbor/dock/keeper/seat.typify"; if .[0] == "pane" then .[4] = ":(exclude).git keeper" else . end)
    | walk(if . == "harbor" then ":(exclude).git" else . end)'
  check "plan with mail, harbor's key :(exclude).git and keeper named :(exclude).git keeper" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "up" exit_is 0 wp up
  printf '%s\n' "to: :(exclude).git keeper" "subject: s" --- "b" > "$scratch/req"
  mv -- "$scratch/req" "$(state_of)/comms/Orchard Grower/out/k.md"
  check "[C64] a mail to a seat whose name a pathspec would read as magic is served" answered_ok grower k.md
  check "[C64] and its file is in the commit: paths reach git as literal paths" \
    bash -c '[[ $(env -i PATH="$PATH" HOME="$1" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$2" ls-files) == *":(exclude).git keeper/in/"* ]]' _ "$scratch" "$(state_of)/mail"
  check "down" exit_is 0 wp down
  rm -rf -- "$clone/BUILD"
}

t_comms_store() {
  scoped_clone
  mkdir -p -- "$root/mailbox"
  local s
  s=$(state_of)
  statements_plan "$comms_terms $comms_reach"
  check "plan" exit_is 0 wplan
  check "[C56] build" exit_is 0 wp build
  check "[C56] makes the store" said "mail: the store $s/mail is made"
  check "[C56] and says where each seat is shown its mailbox" said "mail: 5 mailboxes in $s/mail, shown at $root/mailbox"
  check "[C56] the store: the mail's repository, one directory for each seat named by its name, with in and sent; out and answers beside it; every directory 0700, the record 0600" \
    test "$(cd "$s" && find mail comms -path mail/.git -prune -o -printf '%p %m\n' | LC_ALL=C sort | tr '\n' ',')" = \
    "comms 700,comms/Harbor Keeper 700,comms/Harbor Keeper/answers 700,comms/Harbor Keeper/out 700,comms/Harbor Pilot 700,comms/Harbor Pilot/answers 700,comms/Harbor Pilot/out 700,comms/Harbor Watch 700,comms/Harbor Watch/answers 700,comms/Harbor Watch/out 700,comms/Orchard Grower 700,comms/Orchard Grower/answers 700,comms/Orchard Grower/out 700,comms/Orchard Picker 700,comms/Orchard Picker/answers 700,comms/Orchard Picker/out 700,comms/record 600,comms/taken 700,mail 700,mail/Harbor Keeper 700,mail/Harbor Keeper/in 700,mail/Harbor Keeper/sent 700,mail/Harbor Pilot 700,mail/Harbor Pilot/in 700,mail/Harbor Pilot/sent 700,mail/Harbor Watch 700,mail/Harbor Watch/in 700,mail/Harbor Watch/sent 700,mail/Orchard Grower 700,mail/Orchard Grower/in 700,mail/Orchard Grower/sent 700,mail/Orchard Picker 700,mail/Orchard Picker/in 700,mail/Orchard Picker/sent 700,"
  check "[C65] the repository is made with no template, so it holds no hook and no hooks directory" test ! -e "$s/mail/.git/hooks"
  check "[C56] its branch is mail, with no commit yet" \
    test "$(env -i PATH="$PATH" HOME="$scratch" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$s/mail" symbolic-ref HEAD)" = refs/heads/mail
  check "[C56] BUILD/mail.json holds each seat's mailbox and reach, and the MANIFEST lists it" \
    bash -c 'jq -e --arg s "$1" "[.seats[] | [.name, .box, .in, .out, (.reach.write | length)]][0] == [\"Harbor Keeper\", \"Harbor Keeper\", \"\(\$s)/mail/Harbor Keeper/in\", \"\(\$s)/comms/Harbor Keeper/out\", 1]" "$2/BUILD/mail.json" > /dev/null && grep -q "  mail.json$" "$2/BUILD/MANIFEST"' _ "$s" "$clone"
  check "[C97] build copies the frame's page for a seat into BUILD/seat-page.md, the repository's share/seat-page.md byte for byte, and the MANIFEST lists it" \
    bash -c 'cmp -s "$1/share/seat-page.md" "$2/BUILD/seat-page.md" && grep -q "  seat-page.md$" "$2/BUILD/MANIFEST"' _ "$tool" "$clone"
  check "[C97] and says so" said "mail: 5 mailboxes in $s/mail, shown at $root/mailbox, each with the frame's page for a seat"
  check "[C56] status verifies the build with its mail.json" exit_is 0 wp status
  printf '%s\n' kept > "$s/mail/Harbor Keeper/in/kept.md"
  rm -rf -- "$clone/BUILD"
  check "[C56] a later build" exit_is 0 wp build
  check "[C56] keeps the store and its mail, and makes no new one" \
    bash -c 'test -f "$1" && ! grep -q "the store .* is made" "$2"' _ "$s/mail/Harbor Keeper/in/kept.md" "$scratch/out"
  rm -rf -- "$clone/BUILD"
  local bin=$scratch/bin program
  mkdir -p -- "$bin"
  for program in bash env tmux jq mkdir cp rm sha256sum stat setpriv chmod flock dd mv tail date; do
    ln -s -- "$(command -v "$program")" "$bin/$program"
  done
  check "[C56] build without git refuses a plan that holds mail, with exit 2" exit_is 2 env PATH="$bin" "$BASH" "$loop" build
  check "[C56] naming it" said "a plan that holds mail needs git, and git is not on PATH"
  check "[C56] and leaves no BUILD" test ! -e "$clone/BUILD"
  statements_plan
  check "plan without mail" exit_is 0 wplan
  check "[C56] a plan without mail builds without git" exit_is 0 env PATH="$bin" "$BASH" "$loop" build
  check "[C97] and with no page" test ! -e "$clone/BUILD/seat-page.md"
  rm -rf -- "$clone/BUILD"
  statements_plan "$comms_terms $comms_reach"
  check "plan" exit_is 0 wplan
  rmdir -- "$root/mailbox"
  check "[C55] build refuses a mail path that is not a directory on the machine, with exit 1" exit_is 1 wp build
  check "[C55] naming it and the mail term's origin" said "build refuses: the mail path $root/mailbox is not a directory on the machine, and the frame shows each seat its mailbox there (the mail at programs/COMMS.typify:1)"
  mkdir -p -- "$root/mailbox/state"
  check "[C55] build refuses a mail path that holds the workplaces' state directory" exit_is 1 env XDG_STATE_HOME="$root/mailbox/state" "$BASH" "$loop" build
  check "[C55] naming both and the mail term's origin" said "build refuses: the mail path $root/mailbox and the workplaces' state directory $root/mailbox/state/workplace lie one in the other; a mailbox there would cover the seats' homes and keys, or stand where the frame keeps its state (the mail at programs/COMMS.typify:1)"
  rm -rf -- "$root/mailbox/state"
  check "build" exit_is 0 wp build
  check "[C56] BUILD/mail.json holds the origins of the mail term" test "$(jq -c '.origins' "$clone/BUILD/mail.json")" = '[{"kind":"program","line":1,"path":"programs/COMMS.typify"}]'
  rmdir -- "$root/mailbox"
  check "[C55] up refuses a mail path that is no longer a directory on the machine, with exit 1" exit_is 1 wp up
  check "[C55] naming it and the mail term's origin" said "the mail path $root/mailbox is not a directory on the machine; the frame shows each seat its mailbox there (the mail at programs/COMMS.typify:1)"
  check "[C55] and starts nothing" test ! -e "$clone/BUILD/RUN"
  mkdir -p -- "$root/mailbox"
  rm -f -- "$clone/BUILD/seat-page.md"
  sed -i '/  seat-page[.]md$/d' "$clone/BUILD/MANIFEST"
  check "[C97] up refuses a build with mail that holds no page, as one made before the page does, with exit 1" exit_is 1 wp up
  check "[C97] naming it" said "$clone/BUILD holds no page for a seat's mailbox; build again"
  check "[C97] and starts nothing" test ! -e "$clone/BUILD/RUN"
  rm -rf -- "$clone/BUILD"
  mkdir -p -- "$root/mail"$'\xe2\x80\xae'"box"
  statements_plan "$comms_terms $comms_reach | (.programs[-1].recorded[] | select(.term[0] == \"mail\") | .term[1]) = \"mail\\u202ebox\""
  check "plan, with a mail path that holds a character that turns the line's direction" exit_is 0 wplan
  check "[C55] build refuses a mail path with a character that moves or breaks a line, with exit 1" exit_is 1 wp build
  check "[C55] naming the mail term's origin" said "build refuses: the mail path holds a control character, a character that moves or breaks a line, or bytes that are not UTF-8, as no head of a mail may, and the pointer types it into every seat's pane (the mail at programs/COMMS.typify:1)"
  check "[C55] and leaves no BUILD" test ! -e "$clone/BUILD"
}

t_comms_carrier() {
  scoped_clone
  mkdir -p -- "$root/mailbox"
  local s pid pid2 n ats
  s=$(state_of)
  statements_plan "$comms_terms $comms_reach"
  check "plan" exit_is 0 wplan
  check "build" exit_is 0 wp build
  for n in 1 2 3; do
    request keeper "a$n.md" "to: Harbor Pilot" "subject: round $n" --- "from keeper, $n"
    request pilot "b$n.md" "to: Harbor Keeper" "subject: round $n" --- "from pilot, $n"
  done
  check "[C57] up" exit_is 0 wp up
  pid=$(carrier_pid)
  check "[C57] starts the carrier and says so" said "up: the carrier, pid $pid"
  check "[C57] and records it in the ledger before the first term" test "$(jq -r .what "$run/ledger" | head -n 1)" = "the carrier, pid $pid"
  check "[C57] the carrier serves the requests that waited before up" record_lines_reach 6
  check "[C57] the seats in turn, one request of each in a pass, each seat's in the order of their names" \
    test "$(jq -r '"\(.seat):\(.request)"' "$s/comms/record" | tr '\n' ',')" = "Harbor Keeper:a1.md,Harbor Pilot:b1.md,Harbor Keeper:a2.md,Harbor Pilot:b2.md,Harbor Keeper:a3.md,Harbor Pilot:b3.md,"
  mapfile -t ats < <(jq -r 'select(.seat == "Harbor Keeper") | .at' "$s/comms/record")
  check "[C57] a pass a second: three passes span two seconds or more" \
    test $(( $(date -u -d "${ats[2]}" +%s) - $(date -u -d "${ats[0]}" +%s) )) -ge 2
  check "[C57] the carrier runs outside every view: in this shell's mount and user namespaces" \
    test "$(stat -L -c %i "/proc/$pid/ns/mnt") $(stat -L -c %i "/proc/$pid/ns/user")" = "$(stat -L -c %i /proc/self/ns/mnt) $(stat -L -c %i /proc/self/ns/user)"
  if [[ $(nnp_of $$) == NoNewPrivs:1 ]]; then
    skip "[C57] the carrier reports NoNewPrivs:1, but so would any process this shell starts; measured where the shell does not run under it"
  else
    check "[C57] the carrier runs under no-new-privileges" test "$(nnp_of "$pid")" = "NoNewPrivs:1"
  fi
  check "[C22] status exits 0" exit_is 0 wp status
  check "[C57] status names the carrier" said "ok      the carrier, pid $pid"
  check "[C57] one carrier for a store: another that starts beside it ends, with exit 2" exit_is 2 timeout 10 "$BASH" "$clone/BUILD/bin/workplace" carry
  check "[C57] naming the workplace's state" said "another carrier serves the workplace whose state is $s; this one ends"
  kill -KILL "$pid"
  eventually bash -c '! stat -L "/proc/$1/cwd" > /dev/null 2>&1' _ "$pid"
  check "[C57] status exits 1 when the carrier is gone" exit_is 1 wp status
  check "[C57] naming it, and saying that requests wait" \
    bash -c 'grep -qxF "gone    the carrier, pid $1" "$2" && grep -qxF "        requests wait in the seats'"'"' out, and none is lost, and the chain waits, until the workplace is brought down and up again" "$2"' _ "$pid" "$scratch/out"
  request watch "late.md" "to: Harbor Keeper" "subject: late" --- "while the carrier was gone"
  sleep 2
  check "[C57] while it is gone a request waits in out" test -f "$s/comms/Harbor Watch/out/late.md"
  wp status > "$scratch/out" 2>&1
  check "[C51] status counts the requests that wait" said "requests waiting in the seats' out: 1"
  check "[C51] and names the seat that left them" said "mail    Harbor Watch (harbor/tower/watch): 1 waiting in out"
  check "down" exit_is 0 wp down
  check "[C57] down finds the carrier gone" said "undo the carrier, pid $pid: already gone"
  check "[C57] up again" exit_is 0 wp up
  pid2=$(carrier_pid)
  check "[C57] and the request that waited is served: none is lost" answered_ok watch late.md
  check "down" exit_is 0 wp down
  check "[C57] down ends the carrier" said "undo the carrier, pid $pid2: done"
  check "[C57] which is gone" bash -c '! stat -L "/proc/$1/cwd" > /dev/null 2>&1' _ "$pid2"
  local delivered
  delivered=$(jq -r 'select(.request == "late.md") | .id' "$s/comms/record")
  jq -n -c --arg id "$delivered" '{id: $id, box: "Harbor Watch", request: "again.md", action: "mail", seat: "Harbor Watch"}' > "$s/comms/serving"
  check "[C57] up, after a carrier that stopped once it had delivered a mail" exit_is 0 wp up
  check "[C57] the mail it delivered is answered as delivered when the carrier starts again" answered watch again.md "ok $delivered"
  check "down" exit_is 0 wp down
  printf '%s\n' stray > "$s/mail/Harbor Keeper/in/stray.md"
  jq -n -c '{id: "20261112T000000Z-999999", box: "Harbor Keeper", request: "half.md", action: "mail", seat: "Harbor Keeper"}' > "$s/comms/serving"
  check "[C57] up, after a carrier that stopped while it delivered a mail" exit_is 0 wp up
  check "[C57] the mail is answered as delivered to none" \
    answered keeper half.md "refused the carrier stopped while it served this, and it went to none; leave it in out again"
  check "[C57] and what it had written into the store is removed" test ! -e "$s/mail/Harbor Keeper/in/stray.md"
  check "[C66] both are recorded" test "$(jq -r 'select(.request == "again.md" or .request == "half.md") | .outcome' "$s/comms/record" | tr '\n' ',')" = "ok,refused,"
  check "down" exit_is 0 wp down
  check "up again" exit_is 0 wp up
  local pid3
  pid3=$(carrier_pid)
  rm -rf -- "$run/carrier"
  check "[C57] a carrier whose mark, RUN/carrier, is removed ends of itself at its next pass" \
    eventually_long bash -c '! kill -0 "$1" 2> /dev/null' _ "$pid3"
  check "down" exit_is 0 wp down
  local box_out="$s/comms/Harbor Keeper/out"
  if bwrap --dev-bind / / --tmpfs "$box_out" -- true 2> /dev/null; then
    check "[C61] up with a file system of its own over one seat's out, made in a private mount, refuses: the carrier does not start" \
      exit_is 1 bwrap --dev-bind / / --tmpfs "$box_out" -- "$BASH" "$loop" up
    check "[C61] naming the seat, since a move there would be a copy" \
      said "the carrier did not start: workplace: the out of Harbor Keeper is not a directory on the file system of $s/comms/taken, and the carrier moves by renaming alone"
    check "[C61] and nothing is left up" test ! -e "$run"
  else
    skip "[C61] no private mount can be made here, so the carrier's refusal of an out on another file system is tried where one can"
  fi
}

file_is() { [[ $(cat -- "$1" 2> /dev/null) == "$2" ]]; }
dead_pane() { [[ $(T display-message -p -t "$(pane_by_title "$1")" '#{pane_dead}' 2> /dev/null) == 1 ]]; }
pane_state() { T display-message -p -t "$1" '#{pane_id} #{pane_dead} #{pane_pipe}' 2> /dev/null; }
pane_state_is() { [[ $(pane_state "$1") == "$2" ]]; }
file_comes_to() {
  eventually_long file_is "$1" "$2" && return 0
  note "    $1 holds:"
  cat -A -- "$1" 2> /dev/null | cut -c1-120 | sed 's/^/    | /'
  return 1
}

eventually_long() {
  local i
  for (( i = 0; i < 600; i++ )); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

request_raw() {
  local seat=$1 name=$2 file=$3
  mv -- "$file" "$(state_of)/comms/$(box_of "$seat")/out/$name"
}

t_comms_mail() {
  scoped_clone
  mkdir -p -- "$root/mailbox"
  local s id at file sum line
  s=$(state_of)
  local args='| add("orchard/barn/grower/seat.typify"; ["typed=" + $root + "/orchard/almanac/typed"])'
  statements_plan "$comms_terms $comms_reach | $probe_args $args"
  check "plan" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "up" exit_is 0 wp up
  check "pilot ran" wait_for_probe "Harbor Pilot" pilot
  check "grower ran" wait_for_probe "Orchard Grower" grower
  file=$scratch/m1
  { printf '%s\n' "from: Harbor Keeper" "to: Harbor Keeper, Harbor Watch" "subject: the first" "cc: Orchard Grower" "id: forged" \
      "re: 20261112T000000Z-000001" "reply: needed" "at: forged" ---
    printf 'line one\n\0 a NUL, bytes that are not UTF-8: \xff\xfe, and no newline at the end'; } > "$file"
  request_raw pilot m1.md "$file"
  check "[C59] a mail is served" answered_ok pilot m1.md
  id=$(answer_of pilot m1.md)
  id=${id#ok }
  check "[C59] one file is delivered to each reader's in, cc included, and to the writer's sent" \
    test "$(cd "$s/mail" && find . -path ./.git -prune -o -type f -printf '%p\n' | LC_ALL=C sort | tr '\n' ',')" = \
    "./Harbor Keeper/in/$id.md,./Harbor Pilot/sent/$id.md,./Harbor Watch/in/$id.md,./Orchard Grower/in/$id.md,"
  file="$s/mail/Harbor Keeper/in/$id.md"
  at=$(sed -n 2p "$file")
  check "[C59] the frame writes the id and its own time as at" bash -c '[[ $1 =~ ^at\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]' _ "${at/:/}"
  { printf '%s\n' "id: $id" "$at" "from: Harbor Pilot" "to: Harbor Keeper, Harbor Watch" "subject: the first" "cc: Orchard Grower" \
      "re: 20261112T000000Z-000001" "reply: needed" ---
    printf 'line one\n\0 a NUL, bytes that are not UTF-8: \xff\xfe, and no newline at the end'; } > "$scratch/m1-wanted"
  check "[C59] then the writer as from and its other lines as they stood, its own from, id and at dropped, and the body byte for byte" \
    cmp -s "$file" "$scratch/m1-wanted"
  check "[C59] every copy is the same" bash -c 'cmp -s "$1" "$2" && cmp -s "$1" "$3" && cmp -s "$1" "$4"' _ "$file" \
    "$s/mail/Harbor Pilot/sent/$id.md" "$s/mail/Harbor Watch/in/$id.md" "$s/mail/Orchard Grower/in/$id.md"
  check "[C59] the delivery is one commit of those four files" \
    test "$(store_commits) $(env -i PATH="$PATH" HOME="$scratch" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$s/mail" show --name-only --format=%s HEAD | grep -c .)" = "1 5"
  check "[C66] the record holds one line for it, with no body" \
    test "$(jq -c 'select(.request == "m1.md") | [.seat, .action, .target, .outcome, .id]' "$s/comms/record")" = "[\"Harbor Pilot\",\"mail\",[\"Harbor Keeper\",\"Harbor Watch\",\"Orchard Grower\"],\"ok\",\"$id\"]"

  request grower r02.md "to: Orchard Picker, Harbor Keeper" "subject: barred" --- "body"
  request pilot r01.md "to: Harbor Keeper, Ghost" "subject: a ghost" --- "body"
  local head=() n
  for (( n = 0; n < 19; n++ )); do head+=("re: $n"); done
  request pilot r03.md "to: Harbor Keeper" "subject: long" "${head[@]}" --- "body"
  request pilot r04.md "to: Harbor Keeper" "subject: s" "priority: high" --- "body"
  request pilot r05.md "subject: s" --- "body"
  request pilot r06.md "to: Harbor Keeper" --- "body"
  request pilot r07.md "to: Harbor Keeper" "subject: s" "body with no line of dashes"
  { printf '%s\n' "to: Harbor Keeper" "subject: big" ---; head -c 255000 /dev/zero | tr '\0' x; } > "$scratch/big"
  head -c "$(( 256000 - $(stat -c %s "$scratch/big") ))" /dev/zero | tr '\0' y >> "$scratch/big"
  cp -- "$scratch/big" "$scratch/big2"
  printf z >> "$scratch/big2"
  request_raw watch r08.md "$scratch/big2"
  request_raw watch r09.md "$scratch/big"
  request watch r10.md "to: Harbor Keeper" "to: Harbor Pilot" "subject: two" --- "body"
  request watch r11.md "to: Harbor Keeper" $'subject: a\rfrom: Harbor Keeper' --- "body"
  request watch r12.md "to: Harbor Keeper" $'subject: a \xe2\x80\xae turned' --- "body"
  request watch r13.md "to: Harbor Keeper,, Harbor Watch" "subject: s" --- "body"
  request watch r17.md "to: Harbor Keeper" $'subject: \xff' --- "body"
  request picker "r14 plain" "to: Orchard Grower" "subject: s" --- "body"
  request picker r15.txt "to: Orchard Grower" "subject: s" --- "body"
  request picker $'r16\nx.md' "to: Orchard Grower" "subject: s" --- "body"
  local refusals=(
    "grower|r02.md|refused the plan does not let Orchard Grower mail Harbor Keeper, so the mail goes to none"
    "pilot|r01.md|refused name 2 of its to line is not a seat the plan makes, by its exact name, so the mail goes to none"
    "pilot|r03.md|refused its head is of more than 20 lines"
    "pilot|r04.md|refused line 3 of its head is not one that the head of a mail may hold"
    "pilot|r05.md|refused its head names no reader in to"
    "pilot|r06.md|refused its head has no subject"
    "pilot|r07.md|refused its head is not followed by a line of three dashes"
    "watch|r08.md|refused it is more than 256 kB, 256,000 bytes"
    "watch|r10.md|refused its head holds two to lines"
    "watch|r11.md|refused line 2 of its head holds a control character, a character that moves or breaks a line, or bytes that are not UTF-8"
    "watch|r12.md|refused line 2 of its head holds a control character, a character that moves or breaks a line, or bytes that are not UTF-8"
    "watch|r13.md|refused its to line holds an empty name"
    "watch|r17.md|refused line 2 of its head holds a control character, a character that moves or breaks a line, or bytes that are not UTF-8"
    "picker|r14 plain|refused its name is not letters, digits, dot, dash and underscore ending in .md, .grab or .write; it is removed"
    "picker|r15.txt|refused its name is not letters, digits, dot, dash and underscore ending in .md, .grab or .write; it is removed"
    $'picker|r16\nx.md|refused its name is not letters, digits, dot, dash and underscore ending in .md, .grab or .write; it is removed'
  )
  local entry seat rest
  for entry in "${refusals[@]}"; do
    seat=${entry%%|*} rest=${entry#*|}
    check "[C58] refused, with an answer under the request's name: ${rest#*|}" answered "$seat" "${rest%%|*}" "${rest#*|}"
  done
  check "[C58] a file of 256,000 bytes is taken" answered_ok watch r09.md
  check "[C58] the refused mails went to none: two deliveries and two commits in all" \
    test "$(store_commits) $(find "$s/mail" -path "$s/mail/.git" -prune -o -type f -print | grep -c .)" = "2 6"
  check "[C58] the refused entries are removed from out" test -z "$(find "$s/comms" -path '*/out/*' -print -quit)"

  request picker g1.grab "seat: Harbor Pilot"
  request picker g2.grab "seat: Harbor Pilot" "lines: 5000"
  request picker g3.grab "seat: Harbor Pilot" "lines: 0"
  request picker g4.grab "seat: Harbor Pilot" "lines: 5001"
  request picker g5.grab "seat: Harbor Pilot" "lines: 12x"
  request picker g6.grab "seat: Orchard Grower"
  request picker g7.grab "seat: Ghost"
  request picker g8.grab "lines: 3"
  request picker g9.grab "seat: Harbor Pilot" ---
  check "[C60] a grab is answered with what the pane showed" bash -c '[[ $(cat) == *"probe pilot done"* ]]' < <(answer_of picker g1.grab)
  check "[C60] its answer begins with ok and the id" answered_ok picker g1.grab
  check "[C60] 5,000 lines is the most a grab may ask" answered_ok picker g2.grab
  local grabs=(
    "g3.grab|refused its count of lines is not a whole number from 1 to 5,000"
    "g4.grab|refused its count of lines is not a whole number from 1 to 5,000"
    "g5.grab|refused its count of lines is not a whole number from 1 to 5,000"
    "g6.grab|refused the plan does not let Orchard Picker grab Orchard Grower"
    "g7.grab|refused its seat is not a seat the plan makes, by its exact name"
    "g8.grab|refused its head names no seat"
    "g9.grab|refused line 2 of its head is not one that the head of a grab may hold"
  )
  for entry in "${grabs[@]}"; do
    check "[C58] refused: ${entry#*|}" answered picker "${entry%%|*}" "${entry#*|}"
  done

  request keeper w01.write "seat: Orchard Grower" "key: none" --- "hello"
  request keeper w02.write "seat: Orchard Grower" --- " world"
  request keeper w03.write "seat: Orchard Grower" --- "#{pane_id} #(touch $root/pwned) \$(touch $root/pwned2) %s%n"
  request keeper w04.write "seat: Orchard Grower" --- "-l -t %0 kill-server"
  request keeper w05.write "seat: Orchard Grower" --- "ends;"
  request keeper w06.write "seat: Orchard Grower" --- ";"
  request keeper w07.write "seat: Orchard Grower" --- 'a\;'
  request keeper w08.write "seat: Orchard Grower" "key: Tab" --- "x"
  request keeper w09.write "seat: Orchard Grower" --- ""
  request keeper w10.write "seat: Orchard Grower" --- "one" "two"
  request keeper w11.write "seat: Orchard Grower" "key: none" --- "$(head -c 4097 /dev/zero | tr '\0' y)"
  request keeper w12.write "seat: Orchard Grower" --- $'a\tb'
  request keeper w13.write "seat: Orchard Grower" "key: Home" --- "x"
  request keeper w14.write "seat: Orchard Picker" --- "x"
  local writes=(
    "w10.write|refused its text is not one line"
    "w11.write|refused its text is more than 4,096 bytes"
    "w12.write|refused its text holds a control character or bytes that are not UTF-8"
    "w13.write|refused its key is not one of Enter, Escape, C-c, Tab and none"
    "w14.write|refused the plan does not let Harbor Keeper write to Orchard Picker"
  )
  for entry in "${writes[@]}"; do
    check "[C58] refused: ${entry#*|}" answered keeper "${entry%%|*}" "${entry#*|}"
  done
  local session mark pane
  session=$(T display -p -t "$(pane_by_title 'Orchard Grower')" '#{session_id}')
  mark=$(T show-options -qv -t "$session" @workplace)
  T set-option -u -t "$session" @workplace
  request keeper w16.write "seat: Orchard Grower" --- "unmarked"
  check "[C60] a write to a pane whose session has lost the run's mark is refused, and nothing is typed" \
    answered keeper w16.write "refused the pane of Orchard Grower does not carry this run's mark, or is gone"
  T set-option -t "$session" @workplace "$mark"
  pane=$(pane_by_title 'Orchard Grower')
  T copy-mode -t "$pane"
  request keeper w17.write "seat: Orchard Grower" --- "in a mode"
  check "[C60] a write to a pane that is in a mode is refused, naming the mode, and nothing is typed" \
    answered keeper w17.write "refused the pane of Orchard Grower is in copy-mode, so its program would not read what is typed"
  check "[C66] and recorded so, with no length" \
    test "$(jq -c 'select(.request == "w17.write") | [.outcome, has("length")]' "$s/comms/record")" = '["refused",false]'
  T copy-mode -q -t "$pane"
  check "the pane leaves the mode" test "$(T display-message -p -t "$pane" '#{pane_in_mode}')" = 0
  check "[C60] each line is typed into the pane as it stands, then its key; none: no key; Tab" \
    file_comes_to "$root/orchard/almanac/typed" "$(printf '%s\n' "hello world" "#{pane_id} #(touch $root/pwned) \$(touch $root/pwned2) %s%n" \
      "-l -t %0 kill-server" "ends;" ";" 'a\;' $'x\t')"
  request keeper w15.write "seat: Orchard Grower" --- "$(head -c 4096 /dev/zero | tr '\0' y)"
  check "[C60] a text of 4,096 bytes is taken" answered_ok keeper w15.write
  check "[C66] and recorded with its length" test "$(jq -c 'select(.request == "w15.write") | [.outcome, .length]' "$s/comms/record")" = '["ok",4096]'
  request keeper wz.write "seat: Orchard Grower" "key: C-c" --- "c"
  check "[C60] the key C-c is sent" answered_ok keeper wz.write
  check "[C60] [C98] and interrupts the pane's program, which ends, its pane staying dead" eventually_long dead_pane "Orchard Grower"
  check "[C64] nothing a text named ran: no file was made, and the server stands" \
    bash -c 'test ! -e "$1/pwned" && test ! -e "$1/pwned2" && "${@:2}" list-sessions > /dev/null' _ "$root" setpriv --no-new-privs tmux -S "$run/$label" -u
  sum=$(printf '%s' hello | sha256sum)
  check "[C66] a write's line holds the length and the hash of its text" \
    test "$(jq -c 'select(.request == "w01.write") | [.action, .target, .outcome, .length, .sha256]' "$s/comms/record")" = "[\"write\",[\"Orchard Grower\"],\"ok\",5,\"${sum%% *}\"]"
  check "[C66] and the refused one of 4,097 bytes is recorded with no length" \
    test "$(jq -c 'select(.request == "w11.write") | [.outcome, has("length")]' "$s/comms/record")" = '["refused",false]'
  check "[C66] one line for each request, served or refused, a name with a line break included" \
    test "$(records)" = 45
  T set-option -u -t "$(T display -p -t "$(pane_by_title 'Harbor Pilot')" '#{session_id}')" @workplace
  request picker g10.grab "seat: Harbor Pilot"
  check "[C60] a grab of a pane whose session has lost the run's mark is refused" answered picker g10.grab "refused the pane of Harbor Pilot does not carry this run's mark, or is gone"
  check "[C66] no line holds a body, a capture or a text" \
    bash -c '! grep -qE "line one|probe pilot|hello|world|kill-server|yyyy|body" "$1"' _ "$s/comms/record"
  local page=$tool/share/seat-page.md parts firsts words suffixes word sfx x f n=0 head=() answers=()
  local by_name="refused its name is not letters, digits, dot, dash and underscore ending in .md, .grab or .write; it is removed"
  parts=$( { ls -A -- "$s/mail/Orchard Picker"; ls -A -- "$s/comms/Orchard Picker"; } | LC_ALL=C sort -u)
  firsts=$(for f in "$s"/comms/*/answers/*; do IFS=' ' read -r x _ < "$f" && printf '%s\n' "$x"; done | LC_ALL=C sort -u)
  words=$( { sed '/^## Other requests$/,$d' "$page" | grep -oE '`[a-z]+`' | tr -d '`'; sed '/^## Other requests$/,$d' "$page" | sed -n '/^```text$/,/^---$/p' | sed -n 's/^\([a-z][a-z]*\):.*/\1/p'; } \
    | LC_ALL=C sort -u | grep -vxF -f <(printf '%s\n' $parts $firsts))
  for word in $words; do
    case $word in
      to) head+=("to: Harbor Keeper") ;;
      cc) head+=("cc: Orchard Grower") ;;
      *) head+=("$word: x") ;;
    esac
  done
  request pilot home.md "${head[@]}" --- "body"
  check "[C97] every word of a mail's head that the page names, beside the mailbox's parts ($(echo $parts)) and an answer's first words ($(echo $firsts)), is one that the carrier takes: one mail that holds them all, $(echo $words), is served" \
    answered_ok pilot home.md
  suffixes=$(grep -oE '`[.][a-z]+`' "$page" | tr -d '`' | LC_ALL=C sort -u)
  for sfx in $suffixes .txt; do
    n=$(( n + 1 ))
    request picker "home$n$sfx" "seat: Ghost"
    answers+=("$sfx|$(answer_of picker "home$n$sfx" | head -n 1)")
  done
  check "[C97] every suffix that the page names, $(echo $suffixes), is one that the carrier takes, and .txt, which it does not name, is refused for its name" \
    bash -c 'r=$1; shift; (( $# >= 2 )) || exit 1; for a in "$@"; do s=${a%%|*} g=${a#*|}; if [[ $s == .txt ]]; then [[ $g == "$r" ]] || exit 1; else [[ $g == refused* && $g != "$r" ]] || exit 1; fi; done' _ "$by_name" "${answers[@]}"
  local -a form
  mapfile -t form < <(sed -n '/^## Other requests$/,$p' "$page" | awk '/^```text$/ { n++; on = (n == 1); next } /^```$/ { on = 0; next } on')
  request keeper form.grab "${form[@]//NAME/Orchard Picker}"
  answer_of keeper form.grab > /dev/null
  check "[C97] the page's form of a grab, $(printf '%s|' "${form[@]}"), with a seat that keeper may grab, is served: ok, an id, and the pane's lines" \
    bash -c 'a=$(cat -- "$1/answers/form.grab" 2> /dev/null); [[ ${a%%$'"'"'\n'"'"'*} =~ ^ok\ [0-9]{8}T[0-9]{6}Z-[0-9]{6}$ && $(grep -c "" <<< "$a") -gt 1 ]]' _ "$s/comms/$(box_of keeper)"
  mapfile -t form < <(sed -n '/^## Other requests$/,$p' "$page" | awk '/^```text$/ { n++; on = (n == 2); next } /^```$/ { on = 0; next } on')
  request keeper form.write "${form[@]//NAME/Orchard Picker}"
  check "[C97] the page's form of a write, $(printf '%s|' "${form[@]}"), passes every check of a write's form, and only the plan's table refuses it for a seat that keeper may not write" \
    answered keeper form.write "refused the plan does not let Harbor Keeper write to Orchard Picker"
  check "down" exit_is 0 wp down
}

t_comms_from_a_pane() {
  scoped_clone
  mkdir -p -- "$root/mailbox" "$root/tools/requests"
  command -v python3 > /dev/null || { skip "[C61] python3 is not on PATH here, and the probe's race, its watch on out and its socket need it"; return 0; }
  local s q=$root/tools/requests
  s=$(state_of)
  printf '%s\n' "to: Harbor Keeper" "subject: leak" --- "the ledger's secret" > "$root/harbor/ledger/letter-keeper"
  printf '%s\n' "to: Harbor Pilot" "subject: leak" --- "the ledger's secret" > "$root/harbor/ledger/letter-pilot"
  printf '%s\n' "to: Harbor Keeper" "subject: second" --- "as first written" > "$q/c.md"
  printf '%s\n' "to: Harbor Pilot" "subject: race" --- "harmless" > "$q/r.md"
  printf '%s\n' "to: Harbor Pilot" "subject: leased" --- "held" > "$q/l.md"
  printf '%s\n' "to: Harbor Watch" "subject: -rf" --- "an option" > "$q/rf.md"
  printf '%s\n' "seat: Harbor Pilot" > "$q/help.grab"
  printf '%s\n' "to: Harbor Watch" "subject: s" --- "b" > "$q/plain.md"
  printf '%s\n' "seat: *" > "$q/s1.grab"
  printf '%s\n' "seat: Harbor*" > "$q/s2.grab"
  printf '%s\n' "seat: [H]arbor Pilot" > "$q/s3.grab"
  printf '%s\n' "seat: Harbor Pilot; kill-server" > "$q/s4.grab"
  printf '%s\n' "to: *" "subject: s" --- "b" > "$q/h1.md"
  printf '%s\n' "to: Harbor Watch" "subject: \$(touch $root/pwned4) \`touch $root/pwned5\` %n%s #{pane_id} #(touch $root/pwned6)" --- "b" > "$q/h2.md"
  printf '%s\n' "to: Harbor Watch" "--exec: x" "subject: s" --- "b" > "$q/h3.md"
  printf '%s\n' "seat: Orchard Grower" --- "#(touch $root/pwned7) \$(touch $root/pwned8) %n%s #{session_name} -t ; kill-server" > "$q/t1.write"
  printf '%s\n' "seat: Orchard Grower" --- "--" > "$q/t2.write"
  local args='| add("harbor/dock/keeper/seat.typify"; ["report=" + $root + "/harbor/berth/keeper", "box=" + $root + "/mailbox", "hidden=" + $s,
        "reach=" + $s + "/comms/Harbor Keeper/out", "link=a.md:" + $root + "/harbor/ledger/letter-keeper",
        "node=d.md:dir", "node=f.md:fifo", "node=s.md:socket", "second=c.md:" + $q + "/c.md",
        "answer=a.md", "answer=d.md", "answer=f.md", "answer=s.md"])
    | add("harbor/dock/pilot/seat.typify"; ["report=" + $root + "/harbor/berth/pilot", "box=" + $root + "/mailbox",
        "race=r.md:" + $root + "/harbor/ledger/letter-pilot:" + $q + "/r.md:12", "lease=l.md:" + $q + "/l.md", "answer=l.md"])
    | add("harbor/tower/watch/seat.typify"; ["report=" + $root + "/harbor/charts/watch", "box=" + $root + "/mailbox",
        "post=-rf.md:" + $q + "/rf.md", "post=--help.grab:" + $q + "/help.grab", "post=*.md:" + $q + "/plain.md",
        "post=$(touch pwned3).md:" + $q + "/plain.md", "post=%s%n.md:" + $q + "/plain.md",
        "post=s1.grab:" + $q + "/s1.grab", "post=s2.grab:" + $q + "/s2.grab", "post=s3.grab:" + $q + "/s3.grab", "post=s4.grab:" + $q + "/s4.grab",
        "post=h1.md:" + $q + "/h1.md", "post=h2.md:" + $q + "/h2.md", "post=h3.md:" + $q + "/h3.md",
        "post=t1.write:" + $q + "/t1.write", "post=t2.write:" + $q + "/t2.write",
        "answer=-rf.md", "answer=--help.grab", "answer=*.md", "answer=$(touch pwned3).md", "answer=%s%n.md",
        "answer=s1.grab", "answer=s2.grab", "answer=s3.grab", "answer=s4.grab", "answer=h1.md", "answer=h2.md", "answer=h3.md",
        "answer=t1.write", "answer=t2.write"])
    | add("orchard/barn/grower/seat.typify"; ["report=" + $root + "/orchard/almanac/grower", "box=" + $root + "/mailbox", "typed=" + $root + "/orchard/almanac/typed"])
    | add("orchard/barn/picker/seat.typify"; ["report=" + $root + "/orchard/almanac/picker", "box=" + $root + "/mailbox", "slow=w.md:Orchard Picker"])'
  args=${args//\$q/\"$q\"}
  statements_plan "$comms_terms $comms_reach | $probe_args ${args//\$s/\"$s\"}"
  check "plan" exit_is 0 wplan
  check "build" exit_is 0 wp build
  mkdir -p -- "$s/mail/.git/hooks" "$scratch/hooks"
  local hook
  for hook in "$s/mail/.git/hooks/pre-commit" "$s/mail/.git/hooks/post-commit" "$scratch/hooks/pre-commit" "$scratch/hooks/post-commit" "$scratch/fsmonitor"; do
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' \"\$0\" >> '$scratch/hook-ran'" > "$hook"
    chmod +x -- "$hook"
  done
  printf '%s\n' '[core]' "  hooksPath = $scratch/hooks" "  fsmonitor = $scratch/fsmonitor" "  attributesFile = $scratch/attributes" \
    '[commit]' '  gpgSign = true' '[filter "planted"]' "  clean = $scratch/fsmonitor" > "$HOME/.gitconfig"
  printf '%s\n' '* filter=planted' > "$scratch/attributes"
  check "up" exit_is 0 wp up
  local report
  for report in keeper pilot; do
    check "$report ran" eventually_long grep -qx "probe $report done" "$root/harbor/berth/$report"
  done
  check "watch ran" eventually_long grep -qx "probe watch done" "$root/harbor/charts/watch"
  check "grower looked at its mailbox" eventually_long grep -q "^box page after: " "$root/orchard/almanac/grower"
  report=$root/harbor/berth/keeper
  check "[C55] in its pane a seat is shown its mailbox: out read-write; in, sent and answers read-only, the page, and nothing else there" \
    bash -c 'grep -qxF "box out: write=ok" "$1" && grep -qxF "box in: write=refused" "$1" && grep -qxF "box sent: write=refused" "$1" && grep -qxF "box answers: write=refused" "$1" && grep -qxF "box .: write=refused" "$1" && grep -qxF "box entries: README.md answers in out sent " "$1"' _ "$report"
  local page reports=("$root/harbor/berth/keeper" "$root/harbor/berth/pilot" "$root/harbor/charts/watch" "$root/orchard/almanac/picker" "$root/orchard/almanac/grower")
  page=$(sha256sum < "$tool/share/seat-page.md") page=${page%% *}
  check "[C97] every seat's mailbox holds README.md, the frame's page for a seat: the repository's share/seat-page.md, byte for byte" \
    bash -c 'for r in "${@:2}"; do grep -qxF "box page: $1" "$r" || exit 1; done' _ "$page" "${reports[@]}"
  check "[C97] no seat can change the page or put another in its place: appending, removing, moving a file over it and making a link there are each refused, and the page stays the repository's" \
    bash -c 'for r in "${@:2}"; do for a in append remove replace link; do grep -qxF "box page $a: refused" "$r" || exit 1; done; grep -qxF "box page after: $1" "$r" || exit 1; done' _ "$page" "${reports[@]}"
  check "[C65] no seat can write into the store, which no view holds" \
    bash -c 'grep -qxF "hidden $2: unseen" "$1" && grep -qxF "reach $2/comms/Harbor Keeper/out: write=refused" "$1"' _ "$report" "$s"
  check "[C62] a link to a letter outside the seat's view, addressed to the seat itself, is refused and removed" \
    grep -qxF "answer a.md: refused it is a symbolic link, and the carrier takes a regular file alone; it is removed" "$report"
  check "[C62] a directory, a fifo and a socket are refused and removed, and the carrier goes on" \
    bash -c 'grep -qxF "answer d.md: refused it is a directory, and the carrier takes a regular file alone; it is removed" "$1" && grep -qxF "answer f.md: refused it is a fifo, and the carrier takes a regular file alone; it is removed" "$1" && grep -qxF "answer s.md: refused it is a socket, and the carrier takes a regular file alone; it is removed" "$1"' _ "$report"
  check "[C62] none of them is left in out, and the seat's draft is not taken" \
    test "$(cd "$s/comms/Harbor Keeper/out" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort | tr '\n' ',')" = ".c.md.second,"
  check "[C63] the carrier opened the file a seat wrote once, through no name of the seat's, and the seat's change through its second name afterwards changed nothing" \
    bash -c 'grep -qxF "second c.md: answered=yes opened=1 written=ok" "$1" && ! grep -rqF "changed through a second name" "$2/Harbor Keeper/in" "$2/Harbor Keeper/sent" && grep -rqF "as first written" "$2/Harbor Keeper/in"' _ "$report" "$s/mail"
  check "[C57] a request written under its own name, a line every 300 ms for three seconds, rests until it is whole and is delivered whole" \
    bash -c 'grep -qxF "slow w.md: answered=yes" "$1" && f=$(grep -rlx "subject: slow" "$2/Orchard Picker/in") && [[ $(sed "1,/^---\$/d" "$f" | tr "\n" ,) == "line 1,line 2,line 3,line 4,line 5,line 6,line 7,line 8,line 9,line 10," ]]' _ "$root/orchard/almanac/picker" "$s/mail"
  report=$root/harbor/berth/pilot
  check "[C61] racing the carrier, the seat held its entry still for 2.5 s and then swapped it between a file and a link for 0.3 s, over and over for 12 s, and nothing opened it while it stood in out" \
    bash -c '[[ $(grep "^race r.md: " "$1") =~ ^race\ r\.md:\ swaps=([0-9]+)\ opened=0$ ]] && (( BASH_REMATCH[1] >= 100 ))' _ "$report"
  check "[C61] every one it took was served as the file or refused as a link: $(jq -r 'select(.request == "r.md") | .outcome' "$s/comms/record" | sort | uniq -c | tr -s ' ' | sed 's/^ //' | paste -sd, -)" \
    bash -c '[[ -n $1 ]] && ! grep -vxF -e "ok " -e "refused it is a symbolic link, and the carrier takes a regular file alone; it is removed" <<< "$1"' _ \
    "$(jq -r 'select(.request == "r.md") | .outcome + " " + (.reason // "")' "$s/comms/record")"
  check "[C61] [C62] no letter from the ledger reached any seat, and the record holds none of it" \
    bash -c '! grep -rqF "the ledger" "$1" --exclude-dir=.git && ! grep -qF "ledger" "$2"' _ "$s/mail" "$s/comms/record"
  if grep -qx "lease l.md: lease=held answered=yes" "$report"; then
    check "[C63] a file held under a lease is refused at once, and nothing waits for it" \
      grep -qxF "refused it could not be read at once; it is removed" "$s/comms/Harbor Pilot/answers/l.md"
  elif grep -q "^lease l.md: lease=refused" "$report"; then
    skip "[C63] this file system gives a seat no lease on its request, so a request held under one is not tried"
  else
    fail "[C63] a request held under a lease was not answered at once: $(grep '^lease' "$report")"
  fi
  report=$root/harbor/charts/watch
  local hostile=(
    "-rf.md|ok"
    "--help.grab|ok"
    "*.md|refused its name is not letters, digits, dot, dash and underscore ending in .md, .grab or .write; it is removed"
    "\$(touch pwned3).md|refused its name is not letters, digits, dot, dash and underscore ending in .md, .grab or .write; it is removed"
    "%s%n.md|refused its name is not letters, digits, dot, dash and underscore ending in .md, .grab or .write; it is removed"
    "s1.grab|refused its seat is not a seat the plan makes, by its exact name"
    "s2.grab|refused its seat is not a seat the plan makes, by its exact name"
    "s3.grab|refused its seat is not a seat the plan makes, by its exact name"
    "s4.grab|refused its seat is not a seat the plan makes, by its exact name"
    "h1.md|refused name 1 of its to line is not a seat the plan makes, by its exact name, so the mail goes to none"
    "h2.md|ok"
    "h3.md|refused line 2 of its head is not one that the head of a mail may hold"
    "t1.write|ok"
    "t2.write|ok"
  )
  local entry
  for entry in "${hostile[@]}"; do
    check "[C64] a name, a seat, a head or a text built as an option, a pattern, a format or a command: ${entry%%|*} is answered ${entry#*|}" \
      bash -c '[[ $(grep -F "answer $2: " "$1") == "answer $2: $3"* ]]' _ "$report" "${entry%%|*}" "${entry#*|}"
  done
  check "[C64] the subject is delivered as it stood" grep -rqxF "subject: \$(touch $root/pwned4) \`touch $root/pwned5\` %n%s #{pane_id} #(touch $root/pwned6)" "$s/mail/Harbor Watch/in"
  check "[C64] and the texts typed as they stood" \
    file_comes_to "$root/orchard/almanac/typed" "$(printf '%s\n' "#(touch $root/pwned7) \$(touch $root/pwned8) %n%s #{session_name} -t ; kill-server" --)"
  check "[C64] nothing a request named ran: no file was made, and the server stands" \
    bash -c 'for n in 3 4 5 6 7 8; do test ! -e "$1/pwned$n" || exit 1; done; test ! -e "$2/carrier/pwned3" && test ! -e "$3/pwned3" && "${@:4}" list-sessions > /dev/null' _ \
    "$root" "$run" "$s" setpriv --no-new-privs tmux -S "$run/$label" -u
  check "[C62] [C63] what the carrier took, and its own copies, are removed once each request is answered" test -z "$(find "$s/comms/taken" -mindepth 1 -print -quit)"
  check "[C65] the store runs no hook: not its own, not the user's hooksPath, fsmonitor or filter; the user's signing is not asked" \
    bash -c 'test ! -e "$1/hook-ran" && test "$(jq -r "select(.request == \"h2.md\") | .outcome" "$2")" = ok' _ "$scratch" "$s/comms/record"
  check "down" exit_is 0 wp down
}


wake_kinds='| kinds([["harbor", "dock", "keeper", "clerk"], ["harbor", "dock", "pilot", "courier"], ["harbor", "tower", "watch", "clerk"],
    ["orchard", "barn", "grower", "clerk"], ["orchard", "barn", "picker", "courier"]])'
wake_terms='| .programs[-1].recorded += [m(["wake", "clerk", "^waiting>$"]; 9)]'

t_wake_fold() {
  scoped_clone
  mkdir -p -- "$root/mailbox"
  statements_plan "$comms_terms $wake_kinds $wake_terms"
  check "plan with a wake term" exit_is 0 wplan
  check "[C93] view.json gives each seat of the kind its pattern with its origin, and no other seat a wake" \
    test "$(jq -c '[.seats[] | [.seat[2], .wake.pattern, [.wake.origins[]?.line]]]' "$clone/PLAN/view.json")" = \
    '[["keeper","^waiting>$",[9]],["pilot",null,[]],["watch","^waiting>$",[9]],["grower","^waiting>$",[9]],["picker",null,[]]]'
  check "[C93] plan prints it for each seat of the kind" \
    bash -c '(( $(grep -cxF -- "$2" "$1") == 3 ))' _ "$scratch/out" \
    "  wake: its pane is ready when one of the last five lines of its screen that are not empty matches \"^waiting>\$\", by its kind's term (programs/COMMS.typify:9)"
  check "[C29] the fold's version is the one that reads the wake" \
    test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-v12
  local planned entry
  planned=$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)
  local refusals=(
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "clerk"]; 10)]|programs/COMMS.typify:10: a wake has the words wake KIND PATTERN, not 2'
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "ghost", "x"]; 10)]|programs/COMMS.typify:10: the wake names the kind ghost, which the plan does not make'
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "none", "x"]; 10)]|programs/COMMS.typify:10: the wake names the kind none, which the plan does not make'
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "clerk", ""]; 10)]|programs/COMMS.typify:10: the wake'"'"'s pattern is empty, and an empty pattern finds every screen ready'
    "$comms_terms $wake_kinds $wake_terms"' | .programs[-1].recorded += [m(["wake", "clerk", "^ready$"]; 10)]|two wake terms of the kind clerk differ: "^waiting>$" from programs/COMMS.typify:9, "^ready$" from programs/COMMS.typify:10'
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "clerk", "(waiting"]; 10)]|programs/COMMS.typify:10: the wake'"'"'s pattern "(waiting" is not an extended regular expression that the frame'"'"'s bash reads'
    'def m($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/COMMS.typify"}}; .'" $wake_kinds $wake_terms"'|the plan holds wake terms and no mail term, so no mail is delivered to point out (the wake at programs/COMMS.typify:9)'
  )
  for entry in "${refusals[@]}"; do
    statements_plan "${entry%|*}"
    check "[C93] plan refuses, with exit 1: ${entry##*|}" exit_is 1 wplan
    check "[C93] naming it" said "${entry##*|}"
  done
  check "[C93] and after every refusal PLAN/ is as it was" test "$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)" = "$planned"
  statements_plan "$comms_terms $wake_kinds $wake_terms"' | .programs[-1].recorded += [m(["wake", "clerk", "^waiting>$"]; 10)]'
  check "[C93] two equal wake terms count once" exit_is 0 wplan
  check "[C93] and name both origins" test "$(jq -c '[.seats[0].wake.origins[].line]' "$clone/PLAN/view.json")" = '[9,10]'
  statements_plan "$comms_terms $wake_kinds $wake_terms"' | .programs[-1].recorded |= map(select(.term[0] == "wake"))'
  check "[C93] a plan whose only term that folds is a wake is folded, and refused for want of a mail term" exit_is 1 wplan
  check "[C93] naming the wake" said "the plan holds wake terms and no mail term, so no mail is delivered to point out (the wake at programs/COMMS.typify:9)"
  statements_plan "$comms_terms $wake_kinds $wake_terms"' | .programs[-1].recorded += [m(["wake", "clerk", "^waiting>$"]; 10)]'
  check "plan again" exit_is 0 wplan
  edit_plan '(.programs[-1].recorded[] | select(.term[0] == "wake") | .term[2]) = "a{1"'
  check "[C93] build refuses, with exit 1, a pattern that bash refuses in a plan written by hand" exit_is 1 wp build
  check "[C93] naming the term" said 'programs/COMMS.typify:9, programs/COMMS.typify:10: the wake'"'"'s pattern "a{1" is not an extended regular expression'
}

t_wake() {
  scoped_clone
  mkdir -p -- "$root/mailbox"
  local s b=$root/harbor/berth c=$root/harbor/charts a=$root/orchard/almanac own id1 p1 p2 p4 at1 newest first line pane
  s=$(state_of)
  pointer() { printf '%s\n' "mail: $1 new, newest $2.md, in $root/mailbox/in, and the page $root/mailbox/README.md says what this line is"; }
  printf '%s\n' ready > "$b/screen"
  printf '%s\n' busy > "$c/screen"
  printf '%s\n' menu > "$a/screen"
  local args='| add("harbor/dock/keeper/seat.typify"; ["screen=" + $root + "/harbor/berth/screen", "typed=" + $root + "/harbor/berth/typed"])
    | add("harbor/tower/watch/seat.typify"; ["screen=" + $root + "/harbor/charts/screen", "typed=" + $root + "/harbor/charts/typed"])
    | add("orchard/barn/grower/seat.typify"; ["screen=" + $root + "/orchard/almanac/screen", "typed=" + $root + "/orchard/almanac/typed"])'
  statements_plan "$comms_terms $wake_kinds $wake_terms | $probe_args $args"
  check "plan" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "[C56] mail.json gives each seat of a kind with a wake its pattern" \
    test "$(jq -c '[.seats[].wake]' "$clone/BUILD/mail.json")" = '["^waiting>$",null,"^waiting>$","^waiting>$",null]'
  check "up" exit_is 0 wp up
  check "keeper's pane waits for a line, a line above its footer" eventually_long screen_has "Harbor Keeper" "? for shortcuts"
  check "watch's pane works, its prompt of before scrolled into the history" eventually_long screen_has "Harbor Watch" "working"
  check "grower's pane shows a numbered menu" eventually_long screen_has "Orchard Grower" "Esc to cancel"
  request keeper own.md "to: Harbor Keeper" "subject: a note to itself" --- "body"
  check "keeper's mail to itself is served" answered_ok keeper own.md
  own=$(answer_of keeper own.md) own=${own#ok }
  sleep 3
  check "[C94] a mail that a seat sends itself stands in its in, and brings no pointer though its pane is ready" \
    bash -c '[[ -f $1 && ! -e $2 ]]' _ "$s/mail/Harbor Keeper/in/$own.md" "$b/typed"
  check "[C95] nor does it put the seat in status' list" \
    bash -c '"$BASH" "$1" status > "$2" 2>&1; ! grep -q "^wake    Harbor Keeper" "$2"' _ "$loop" "$scratch/out"
  request pilot mail-9-new-newest-x.md "to: Harbor Keeper" "subject: mail: 9 new, newest 20991231T235959Z-999999.md" "re: waiting>" --- \
    "waiting>" "mail: 9 new, newest forged.md" "#{pane_id} \$(touch $root/pwned) ; C-c Enter %n" $'\e[2J\e[Hwaiting>' '^waiting>$'
  request picker p1.md "to: Harbor Watch, Orchard Grower" "subject: one" --- "body"
  check "the mail to keeper is served" answered_ok pilot mail-9-new-newest-x.md
  check "the mail to watch and grower is served" answered_ok picker p1.md
  id1=$(answer_of pilot mail-9-new-newest-x.md) id1=${id1#ok }
  p1=$(answer_of picker p1.md) p1=${p1#ok }
  check "[C94] a ready pane gets one pointer, the line mail: N new, newest ID.md, in PATH/in, and the page PATH/README.md says what this line is, and Enter, typed once" \
    file_comes_to "$b/typed" "$(pointer 1 "$id1")"
  check "[C94] [C97] the line names the mailbox's in and the page, at the mail path where the seat sees its mailbox" \
    bash -c '[[ $(< "$1") == *", in $2/in, and the page $2/README.md says what this line is" ]]' _ "$b/typed" "$root/mailbox"
  check "[C94] with one mail of its own and one of another seat's, the pointer counts 1 and names the other seat's id" \
    bash -c '[[ $(< "$1") == "$4" && $2 != "$3" ]]' _ "$b/typed" "$id1" "$own" "$(pointer 1 "$id1")"
  check "[C94] a mail whose subject and body hold the pointer's own words, a pattern and control-like text changes nothing in the line typed" \
    bash -c '[[ $(< "$1") == "$2" && ! -e $3/pwned ]]' _ "$b/typed" "$(pointer 1 "$id1")" "$root"
  request pilot k3.md "to: Harbor Keeper" "subject: three" --- "body"
  request picker k4.md "to: Harbor Keeper" "subject: four" --- "body"
  request grower k5.md "to: Harbor Keeper" "subject: five" --- "body"
  request picker p2.md "to: Harbor Watch" "subject: two" --- "body"
  check "three more mails to keeper are served" answered_ok pilot k3.md
  check "from three seats" answered_ok picker k4.md
  check "at about one pass" answered_ok grower k5.md
  check "a second mail to watch is served" answered_ok picker p2.md
  newest=$( { answer_of pilot k3.md; answer_of picker k4.md; answer_of grower k5.md; } | sed 's/^ok //' | LC_ALL=C sort | tail -n 1)
  p2=$(answer_of picker p2.md) p2=${p2#ok }
  sleep 4
  check "[C94] no second pointer goes to a reader within a minute, though its mail waits and its pane is ready" \
    file_is "$b/typed" "$(pointer 1 "$id1")"
  check "[C94] a pane that is not ready gets none" test ! -e "$c/typed"
  check "[C94] a pane that shows a numbered menu gets none" test ! -e "$a/typed"
  at1=$(sed -n 's/^at: //p' "$s/mail/Harbor Watch/in/$p1.md")
  check "[C95] status does not exit 1 for mail to be pointed out" exit_is 0 wp status
  check "[C95] it lists each seat with mail to be pointed out, how many and since when: a seat at work stands in the list" \
    said "wake    Harbor Watch (harbor/tower/watch): 2 delivered and not yet pointed out, the first at $at1"
  check "[C95] and so do a seat whose pane waits out the minute and one at a question of its program" \
    bash -c 'grep -q "^wake    Harbor Keeper (harbor/dock/keeper): 3 delivered and not yet pointed out, the first at " "$1" && grep -qxF "wake    Orchard Grower (orchard/barn/grower): 1 delivered and not yet pointed out, the first at $2" "$1"' _ "$scratch/out" "$at1"
  check "[C56] the carrier keeps what is to be pointed out in S/comms/wake.json, mode 0600" \
    bash -c '[[ $(stat -c %a "$1") == 600 ]] && jq -e ".seats[\"Harbor Watch\"].count == 2" "$1" > /dev/null' _ "$s/comms/wake.json"
  pane=$(pane_by_title "Harbor Watch")
  T copy-mode -t "$pane"
  check "watch's pane is put in copy mode" test "$(T display-message -p -t "$pane" '#{pane_in_mode} #{pane_mode}')" = "1 copy-mode"
  printf '%s\n' ready > "$c/screen"
  check "watch's program shows its prompt beneath the mode" eventually_long screen_has "Harbor Watch" "? for shortcuts"
  sleep 3
  check "[C94] a reader whose pane is in a mode gets no pointer, though its program shows the prompt: nothing is typed, and nothing is recorded for it" \
    bash -c '[[ ! -e $1 && -z $(jq -c "select(.action == \"wake\" and .target == [\"Harbor Watch\"])" "$2") ]]' _ "$c/typed" "$s/comms/record"
  check "[C95] status lists it as a pane that is not ready" \
    bash -c '"$BASH" "$1" status > "$2" 2>&1; grep -qxF "wake    Harbor Watch (harbor/tower/watch): 2 delivered and not yet pointed out, the first at $3" "$2"' _ "$loop" "$scratch/out" "$at1"
  T copy-mode -q -t "$pane"
  check "[C94] once the mode is left, the pane gets one pointer, for all that came since" \
    file_comes_to "$c/typed" "$(pointer 2 "$p2")"
  check "[C94] three mails delivered between two pointers give one pointer, with the count 3 and the newest id" \
    file_comes_to "$b/typed" "$(printf '%s\n' "$(pointer 1 "$id1")" "$(pointer 3 "$newest")")"
  check "[C94] and it went a minute or more after the first" \
    bash -c 'mapfile -t at < <(jq -r "select(.action == \"wake\" and .target == [\"Harbor Keeper\"]) | .at" "$1"); (( ${#at[@]} == 2 && $(date -u -d "${at[1]}" +%s) - $(date -u -d "${at[0]}" +%s) >= 60 ))' _ "$s/comms/record"
  check "[C94] a pane that shows a numbered menu still has none, a minute on" test ! -e "$a/typed"
  first=$(jq -c 'select(.action == "wake" and .target == ["Harbor Keeper"])' "$s/comms/record" | head -n 1)
  line=$(pointer 1 "$id1")
  check "[C66] [C96] each pointer is one line of the record: the time, the frame as the one who asked, the reader, the ids it covers, the outcome, and the length and SHA-256 of the line, the paths included" \
    test "$(jq -c '[.seat, .action, .target, .covers, .outcome, .length, .sha256, (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))]' <<< "$first")" = \
    "[\"the frame\",\"wake\",[\"Harbor Keeper\"],[\"$id1\"],\"ok\",${#line},\"$(printf '%s' "$line" | sha256sum | cut -d' ' -f1)\",true]"
  check "[C96] the next covers the three" \
    test "$(jq -c 'select(.action == "wake" and .target == ["Harbor Keeper"]) | .covers | length' "$s/comms/record" | tail -n 1)" = 3
  check "status" exit_is 0 wp status
  check "[C95] a seat reached leaves the list, and one not yet reached stands in it" \
    bash -c '! grep -q "^wake    Harbor Keeper" "$1" && ! grep -q "^wake    Harbor Watch" "$1" && grep -qxF "wake    Orchard Grower (orchard/barn/grower): 1 delivered and not yet pointed out, the first at $2" "$1"' _ "$scratch/out" "$at1"
  printf '%s\n' far > "$a/screen"
  check "[C94] a pane whose prompt stands fifth from the bottom among the lines that are not empty, with empty lines between, is ready" \
    file_comes_to "$a/typed" "$(pointer 1 "$p1")"
  printf '%s\n' busy > "$c/screen"
  check "watch's pane works again" eventually_long screen_has "Harbor Watch" "working"
  request picker p3.md "to: Harbor Watch" "subject: three" --- "body"
  check "a third mail to watch is served" answered_ok picker p3.md
  request picker p4.md "to: Harbor Watch" "subject: four" --- "body"
  check "and a fourth" answered_ok picker p4.md
  p4=$(answer_of picker p4.md) p4=${p4#ok }
  check "down, with two mails to watch not yet pointed out" exit_is 0 wp down
  check "up again" exit_is 0 wp up
  check "watch's pane works, as it did" eventually_long screen_has "Harbor Watch" "working"
  check "[C95] what was to be pointed out outlives the run: status lists it after down and up" \
    bash -c '"$BASH" "$1" status > "$2" 2>&1; grep -q "^wake    Harbor Watch (harbor/tower/watch): 2 delivered and not yet pointed out, the first at " "$2"' _ "$loop" "$scratch/out"
  local since
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' ready > "$c/screen"
  check "[C94] and once the pane is ready, the pointer comes with that count and the newest id, within two minutes: a refused pointer holds the next one a minute" \
    bash -c 'for (( i = 0; i < 1200; i++ )); do [[ $(cat -- "$1" 2> /dev/null) == "$2" ]] && exit 0; sleep 0.1; done; printf "    %s holds:\n" "$1"; cat -A -- "$1" | cut -c1-120 | sed "s/^/    | /"; exit 1' \
    _ "$c/typed" "$(printf '%s\n' "$(pointer 2 "$p2")" "$(pointer 2 "$p4")")"
  jq -r --arg t "$since" 'select(.action == "wake" and .target == ["Harbor Watch"] and .at >= $t and .outcome != "ok") | "\(.at) \(.outcome): \(.reason)"' "$s/comms/record" \
    | while IFS= read -r line; do note "  a pointer to watch after up was not ok, at $line"; done
  check "down" exit_is 0 wp down
}

t_typing_apart() {
  scoped_clone
  mkdir -p -- "$root/mailbox"
  local s a=$root/orchard/almanac id why
  s=$(state_of)
  local args='| add("orchard/barn/grower/seat.typify"; ["paste=" + $root + "/orchard/almanac/pasted"])
    | add("orchard/barn/picker/seat.typify"; ["paste-quit=" + $root + "/orchard/almanac/quit"])'
  statements_plan "$comms_terms $comms_reach | .programs[-1].recorded += [m([\"reach\", \"harbor\", \"dock\", \"keeper\", \"seat\", \"write\", \"orchard\", \"barn\", \"picker\", \"seat\", \"allowed\"]; 10)] $wake_kinds $wake_terms | $probe_args $args"
  check "plan" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "up" exit_is 0 wp up
  check "grower's program, which takes a burst as a paste and Enter alone as a line's end, waits" eventually_long screen_has "Orchard Grower" "waiting>"
  check "picker's, which ends at its first byte, waits" eventually_long screen_has "Orchard Picker" "waiting>"
  local f
  for f in "$a/pasted.err" "$a/quit.err"; do
    [[ -s $f ]] && note "    $f holds: $(head -c 400 "$f" | tr '\n' '|')"
  done
  request keeper w1.write "seat: Orchard Grower" --- "hello apart"
  check "[C60] a write to it is served" answered_ok keeper w1.write
  check "[C60] the text and its key go in two calls, a rest apart, so a program that takes a burst as a paste takes one submitted line" \
    file_comes_to "$a/pasted" "line: hello apart"
  request pilot m1.md "to: Orchard Grower" "subject: s" --- "b"
  check "a mail to it is served" answered_ok pilot m1.md
  id=$(answer_of pilot m1.md) id=${id#ok }
  check "[C94] the pointer goes the same way, and the program takes it as one submitted line" \
    file_comes_to "$a/pasted" "$(printf '%s\n' "line: hello apart" "line: mail: 1 new, newest $id.md, in $root/mailbox/in, and the page $root/mailbox/README.md says what this line is")"
  why="the text was typed into the pane of Orchard Picker, and its key was not sent: the pane is gone, or no longer carries this run's mark"
  request keeper w2.write "seat: Orchard Picker" --- "the last"
  check "[C60] a pane whose program ends between the text and its key gets no key, and the answer says that the text was typed" \
    answered keeper w2.write "refused $why"
  check "[C60] its program had read the text" file_is "$a/quit" "ended at its first byte"
  check "[C66] the record holds the refusal, with the length and the SHA-256 of the text typed" \
    test "$(jq -c 'select(.request == "w2.write") | [.outcome, .reason, .length, .sha256]' "$s/comms/record")" = \
    "[\"refused\",\"$why\",8,\"$(printf '%s' "the last" | sha256sum | cut -d' ' -f1)\"]"
  local pane reads
  pane=$(pane_by_title "Orchard Grower")
  reads=$(cat -- "$a/pasted.read" 2> /dev/null | grep -c .)
  request keeper w3.write "seat: Orchard Grower" --- "into a mode"
  check "the text reaches grower's program" read_more "$a/pasted.read" "$reads"
  T copy-mode -t "$pane"
  check "[C60] a pane put in a mode between the text and its key gets no key, and the answer says so" \
    answered keeper w3.write "refused the text was typed into the pane of Orchard Grower, and its key was not sent: the pane is now in copy-mode"
  T copy-mode -q -t "$pane"
  reads=$(cat -- "$a/pasted.read" 2> /dev/null | grep -c .)
  request keeper w4.write "seat: Orchard Grower" --- "into another"
  check "the text reaches grower's program again" read_more "$a/pasted.read" "$reads"
  T respawn-pane -k -t "$pane" "exec sleep 600"
  check "[C60] a pane whose program is started anew between the text and its key gets no key, and the answer says so" \
    answered keeper w4.write "refused the text was typed into the pane of Orchard Grower, and its key was not sent: another program now runs in it"
  check "[C60] neither text was submitted" file_is "$a/pasted" "$(printf '%s\n' "line: hello apart" "line: mail: 1 new, newest $id.md, in $root/mailbox/in, and the page $root/mailbox/README.md says what this line is")"
  check "down" exit_is 0 wp down
}

read_more() {
  local i
  for (( i = 0; i < 250; i++ )); do
    (( $(cat -- "$1" 2> /dev/null | grep -c .) > $2 )) && return 0
    sleep 0.02
  done
  return 1
}

records_terms='def r($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/LOGS.typify"}};
  .programs[-1].recorded += [r(["record", "-", "-", "-", "workplace", "pane", "kept"]; 1), r(["record-path", "records"]; 2), r(["record-chain", "file"]; 3),
    r(["reach", "harbor", "dock", "keeper", "seat", "record", "harbor", "dock", "pilot", "seat", "allowed"]; 4)]'
record_of() { printf '%s\n' "$(state_of)/records/$(box_of "$1")"; }
hex_of() { od -An -v -tx1 | tr -d ' \n'; }

t_records_fold() {
  scoped_clone
  mkdir -p -- "$root/records"
  statements_plan "$records_terms"' | .programs[-1].recorded += [r(["record", "orchard", "barn", "-", "room", "pane", "none"]; 5)]'
  check "plan with records" exit_is 0 wplan
  check "[C69] view.json gives the record path, joined, the day's limit, 256 MiB by default, and the sink" \
    test "$(jq -c '.records | [.path, .limit, .chain]' "$clone/PLAN/view.json")" = "[\"$root/records\",268435456,\"file\"]"
  check "[C69] each seat's pane is kept or not by the narrowest scope that speaks" \
    test "$(jq -c '[.seats[] | [.seat[2], .record.pane, .record.scope]]' "$clone/PLAN/view.json")" = '[["keeper","kept","workplace"],["pilot","kept","workplace"],["watch","kept","workplace"],["grower","none","room"],["picker","none","room"]]'
  check "[C69] reach.record gives the seats whose record a seat may read; a seat reads its own only by a term" \
    test "$(jq -c '[.seats[] | [.seat[2], .reach.record]]' "$clone/PLAN/view.json")" = '[["keeper",["Harbor Pilot"]],["pilot",[]],["watch",[]],["grower",[]],["picker",[]]]'
  check "[C69] plan prints the records" said "records: shown at $root/records; 268435456 bytes a day for a pane; chained to the file"
  check "[C69] and whose records a seat may read" said "  record: Harbor Pilot (programs/LOGS.typify:4)"
  check "[C69] and whether its pane is kept" said "seat Orchard Grower (orchard/barn/grower): kind none; cleared for no label, since neither its room nor its office has a clearance; its pane not kept; 1 rows"
  check "[C29] the fold's version is the one that reads records" test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-v12
  statements_plan 'def r($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/LOGS.typify"}}; .programs[-1].recorded += [r(["record", "-", "-", "-", "workplace", "pane", "kept"]; 1)]'
  check "plan with a record and no chain" exit_is 0 wplan
  check "[C69] with no record-chain the files are kept and no chain is made, and plan says so" said "records: shown to no seat; 268435456 bytes a day for a pane; no chain is made, and the files are kept"
  local planned entry
  statements_plan "$records_terms"
  check "plan" exit_is 0 wplan
  planned=$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)
  local refusals=(
    "$records_terms"' | .programs[-1].recorded += [r(["record", "-", "-", "-", "workplace", "programs", "kept"]; 9)]|programs/LOGS.typify:9: the record of the programs a seat starts is built after the cutover, and no plan keeps it yet'
    "$records_terms"' | .programs[-1].recorded += [r(["record", "-", "-", "-", "workplace", "pane", "none"]; 9)]|two records of the workplace about its pane differ: kept from programs/LOGS.typify:1, none from programs/LOGS.typify:9'
    "$records_terms"' | .programs[-1].recorded += [r(["record-limit", "1000"]; 8), r(["record-limit", "2000"]; 9)]|two record-limit terms differ: 1000 from programs/LOGS.typify:8, 2000 from programs/LOGS.typify:9'
    "$records_terms"' | .programs[-1].recorded += [r(["record-limit", "12k"]; 9)]|programs/LOGS.typify:9: 12k is not a whole number of bytes above 0'
    "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record-chain") | .term[1]) = "syslog"|programs/LOGS.typify:3: syslog is not a sink the frame knows: journal or file'
    "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record") | .term[5]) = "screen"|programs/LOGS.typify:1: screen is not pane or programs'
    "$records_terms"' | .programs[-1].recorded |= map(select(.term[0] != "record-path"))|the plan holds reach terms for records and no record-path term, so no seat is shown a record (the reach at programs/LOGS.typify:4)'
    "$records_terms"' | .programs[-1].recorded += [r(["mail", "records/mail"]; 9)]|the record path '"$root"'/records and the mail path '"$root"'/records/mail lie one in the other (the record-path at programs/LOGS.typify:2; the mail at programs/LOGS.typify:9)'
    "$records_terms"' | .programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; $root + "/records/inner"; "read-only"; 22)]|programs/policy.typify:22: the statement speaks of '"$root"'/records/inner, which lies at or beneath the record path '"$root"'/records, where the frame shows a seat the records it may read (the record-path at programs/LOGS.typify:2)'
    "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record-path") | .term[1]) = "harbor/ledger/rec"|seat Harbor Keeper (harbor/dock/keeper): its record path '"$root"'/harbor/ledger/rec lies beneath '"$root"'/harbor/ledger (hidden, from programs/policy.typify:2), and the seat could not reach it (the record-path at programs/LOGS.typify:2)'
    "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record-path") | .term[1]) = "config/rec"|the record path '"$clone"'/rec lies at or beneath the clone '"$clone"', which the frame masks in every view (the record-path at programs/LOGS.typify:2)'
    "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record-path") | .term[1]) = "harbor"|harbor/dock/keeper/seat.typify, term 2 (start): the seat'"'"'s directory '"$root"'/harbor lies at or beneath the record path '"$root"'/harbor, where the frame shows a seat the records it may read (the record-path at programs/LOGS.typify:2)'
    "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record-path") | .term[1]) = "/"|the record path / would cover each seat'"'"'s whole view (the record-path at programs/LOGS.typify:2)'
    "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record-path") | .term[1]) = "tools"|harbor/dock/keeper/seat.typify, term 2 (start): the seat'"'"'s program '"$root"'/tools/probe lies at or beneath the record path '"$root"'/tools, where the frame shows a seat the records it may read (the record-path at programs/LOGS.typify:2)'
    "$records_terms"' | .programs[-1].recorded += [{term: ["record-directory", "harbor", "dock", "pilot", "records/work"], origin: at(24)}]|programs/policy.typify:24 (record-directory): the seat'"'"'s directory '"$root"'/records/work lies at or beneath the record path '"$root"'/records, where the frame shows a seat the records it may read (the record-path at programs/LOGS.typify:2)'
    "$records_terms"' | .programs[-1].recorded += [lb($root + "/records"; "1"; 23), sc(24)]|programs/policy.typify:23: the label speaks of '"$root"'/records, which lies at or beneath the record path '"$root"'/records, where the frame shows a seat the records it may read (the record-path at programs/LOGS.typify:2)'
    "$records_terms"' | .programs[-1].recorded |= map(select(.term[0] != "statement" or .term[4] != "workplace")) | .programs[-1].recorded += [st("harbor"; "dock"; "-"; "room"; "/"; "read-only"; 25), st("orchard"; "-"; "-"; "office"; "/"; "read-only"; 26)]|seat Harbor Watch (harbor/tower/watch): no row for /: it has no view, and a seat with no view could reach its own record, which the plan keeps (the record at programs/LOGS.typify:1)'
    "$records_terms"' | .programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; "/run/systemd/journal"; "read-only"; 22)]|seat Harbor Keeper (harbor/dock/keeper): /run/systemd/journal (read-only, from programs/policy.typify:22) lies at or beneath /run/systemd/journal, which the frame hides in every view of a workplace that keeps a chain, as a hidden row would'
  )
  for entry in "${refusals[@]}"; do
    statements_plan "${entry%|*}"
    check "[C69] plan refuses, with exit 1: ${entry##*|}" exit_is 1 wplan
    check "[C69] naming it" said "${entry##*|}"
  done
  statements_plan "$records_terms"' | .programs[-1].recorded |= map(select(.term[0] != "record" and .term[0] != "reach" and (.term[0] != "statement" or .term[4] != "workplace")))
    | .programs[-1].recorded += [st("harbor"; "dock"; "-"; "room"; "/"; "read-only"; 25), st("orchard"; "-"; "-"; "office"; "/"; "read-only"; 26)]'
  check "[C76] a plan that holds a record path, and no record kept, no reach and no mail, refuses a seat with no row for /, with exit 1" exit_is 1 wplan
  check "[C76] naming the seat and the record-path term's origin" \
    said "seat Harbor Watch (harbor/tower/watch): no row for /: it has no view to hold the frame's file system at the record path $root/records, which the frame puts in every seat's view (the record-path at programs/LOGS.typify:2)"
  check "[C69] and after every refusal PLAN/ is as it was" test "$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)" = "$planned"
  statements_plan "$records_terms"' | .programs[-1].recorded |= map(select(.term[0] != "record-chain")) | .programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; "/run/systemd/journal"; "read-only"; 22)]'
  check "[C73] a workplace that keeps no chain masks no journal, so a row there is taken" exit_is 0 wplan
  statements_plan "$records_terms"
  check "plan" exit_is 0 wplan
  rmdir -- "$root/records"
  check "[C70] build refuses a record path that is not a directory on the machine, with exit 1" exit_is 1 wp build
  check "[C70] naming it and the record-path term's origin" said "build refuses: the record path $root/records is not a directory on the machine, and the frame shows a seat the records it may read there (the record-path at programs/LOGS.typify:2)"
  mkdir -p -- "$root/records/state"
  check "[C70] build refuses a record path that holds the workplaces' state directory" exit_is 1 env XDG_STATE_HOME="$root/records/state" "$BASH" "$loop" build
  check "[C70] naming both and the record-path term's origin" said "build refuses: the record path $root/records and the workplaces' state directory $root/records/state/workplace lie one in the other; it would cover the seats' homes and keys, or stand where the frame keeps its state (the record-path at programs/LOGS.typify:2)"
  rm -rf -- "$root/records/state"
  check "build" exit_is 0 wp build
  check "[C70] BUILD/records.json holds the origins of the record-path term" test "$(jq -c '.origins' "$clone/BUILD/records.json")" = '[{"kind":"program","line":2,"path":"programs/LOGS.typify"}]'
  rmdir -- "$root/records"
  check "[C70] up refuses a record path that is no longer a directory on the machine, with exit 1" exit_is 1 wp up
  check "[C70] naming it and the record-path term's origin" said "the record path $root/records is not a directory on the machine; the frame shows a seat the records it may read there (the record-path at programs/LOGS.typify:2)"
  check "[C70] and starts nothing" test ! -e "$clone/BUILD/RUN"
}

liar_records_up() {
  local -x PATH="$scratch/liar:$PATH"
  records_up "$1"
}

records_up() {
  scoped_clone
  mkdir -p -- "$root/records"
  statements_plan "$records_terms $1"
  exit_is 0 wplan && exit_is 0 wp build && exit_is 0 wp up
}

t_records_in_panes() {
  local s day hostile
  s=$(state_of)
  day=$(date -u +%F)
  hostile=$root/tools/hostile
  { printf 'BEGIN-HOSTILE'; printf '\0\xff\xfe'; printf '%s' "#{pane_id}#(touch $root/pwned1)\$(touch $root/pwned2)%n%s%x" "\`touch $root/pwned3\`"; printf '\033[31m'; printf 'END-HOSTILE'; } > "$hostile"
  mkdir -p -- "$root/records/Harbor Pilot"
  printf '%s\n' forged > "$root/records/Harbor Pilot/$day.pane"
  printf '%s\n' planted > "$root/records/planted"
  check "up with records" records_up '| def add($path; $args): (.programs[] | select(.path == $path) | .plan[1].term[5]) |= (fromjson + $args | tojson);
    add("harbor/dock/keeper/seat.typify"; ["report=" + $root + "/harbor/berth/keeper", "print=" + $root + "/tools/hostile",
      "wait=" + $root + "/records/Harbor Pilot/'"$day"'.pane", "entries=" + $root + "/records", "entries=" + $root + "/records/Harbor Pilot", "tamper=" + $root + "/records/Harbor Pilot/'"$day"'.pane",
      "list=" + $root + "/records/Harbor Pilot/../Harbor Watch", "hidden='"$s"'/records", "bus=/run/user/'"$EUID"'/bus"])
    | add("harbor/dock/pilot/seat.typify"; ["report=" + $root + "/harbor/berth/pilot", "entries=" + $root + "/records", "make=" + $root + "/records"])
    | add("harbor/tower/watch/seat.typify"; ["entries=" + $root + "/records"])
    | .programs[-1].recorded += [st("harbor"; "dock"; "-"; "room"; $root + "/harbor/berth"; "read-write"; 3), st("harbor"; "dock"; "pilot"; "seat"; $root; "read-write"; 9)]'
  check "keeper ran" eventually_long grep -qx "probe keeper done" "$root/harbor/berth/keeper"
  check "pilot ran" wait_for_probe "Harbor Pilot" pilot
  check "watch ran" wait_for_probe "Harbor Watch" watch
  local pilot_report=$root/harbor/berth/pilot
  check "[C76] a seat that may read no record, with a read-write row above the record path, makes no file, directory or link there" \
    grep -qxF "make $root/records: file=refused directory=refused link=refused" "$pilot_report"
  check "[C76] and the machine's directory at the record path holds nothing it made" \
    test "$(cd "$root/records" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort | tr '\n' ',')" = "Harbor Pilot,Harbor Pilot/$day.pane,planted,"
  check "[C76] a file, and a directory under a seat's name, that stand in the machine's directory at the record path are shown to no seat: not to one that may read no record under a read-write row" \
    grep -qxF "entries $root/records: " "$pilot_report"
  check "[C76] nor to one that may read no record under a read-only row" screen_has "Harbor Watch" "entries $root/records: "
  check "[C70] build made S/records, and in it a directory for each seat, named by its name, all 0700" \
    test "$(cd "$s/records" && find . -maxdepth 1 -type d -printf '%P %m\n' | LC_ALL=C sort | tr '\n' ',')" = " 700,Harbor Keeper 700,Harbor Pilot 700,Harbor Watch 700,Orchard Grower 700,Orchard Picker 700,"
  check "[C70] and BUILD/records.json, listed in the MANIFEST, with each seat's directory, pane and reading" \
    bash -c 'grep -q "  records.json$" "$1/MANIFEST" && [[ $(jq -c "[.seats[0] | .name, .pane, .reads]" "$1/records.json") == "[\"Harbor Keeper\",\"kept\",[\"Harbor Pilot\"]]" ]]' _ "$clone/BUILD"
  check "[C70] a day's file is named by its UTC day, and only its owner reads it" test "$(stat -c %a "$(record_of keeper)/$day.pane")" = 600
  local report=$root/harbor/berth/keeper
  check "[C76] at the record path a seat is shown one directory for each seat whose record it may read, under that seat's name, and no other" \
    grep -qxF "entries $root/records: Harbor Pilot " "$report"
  check "[C76] holding that seat's day" bash -c 'grep -qF "entries $1/records/Harbor Pilot: " "$2" && grep "entries $1/records/Harbor Pilot: " "$2" | grep -qF "$3.pane"' _ "$root" "$report" "$day"
  check "[C77] a seat neither appends to, cuts short, renames nor removes a record it reads, nor makes a file beside it" \
    grep -qxF "tamper $root/records/Harbor Pilot/$day.pane: append=refused truncate=refused rename=refused remove=refused make=refused" "$report"
  check "[C78] through the record it may read a seat reaches no third seat's" grep -qxF "list $root/records/Harbor Pilot/../Harbor Watch: refused" "$report"
  check "[C77] [C78] and the records' store, in the state directory, is unseen" grep -qxF "hidden $s/records: unseen" "$report"
  check "[C79] the pane's bytes are kept as the pane's program wrote them: NUL, bytes that are not UTF-8, formats, commands and escapes" \
    eventually_long bash -c '[[ $(od -An -v -tx1 < "$1" | tr -d " \n") == *"$(od -An -v -tx1 < "$2" | tr -d " \n")"* ]]' _ "$(record_of keeper)/$day.pane" "$hostile"
  check "[C79] and nothing they name ran" bash -c 'for n in 1 2 3; do test ! -e "$1/pwned$n" || exit 1; done' _ "$root"
  check "[C71] the keeper runs outside every view: in this shell's mount and user namespaces" \
    bash -c 'for p in $(pgrep -f "workplace keep $1"); do [[ $(stat -L -c %i "/proc/$p/ns/mnt") == $(stat -L -c %i /proc/self/ns/mnt) ]] || exit 1; done; [[ -n $(pgrep -f "workplace keep $1") ]]' _ "$(record_of keeper)"
  wp status > "$scratch/out" 2>&1
  check "[C75] status names each kept seat's file and its size against the limit" \
    bash -c 'grep -qE "^record  Harbor Keeper \(harbor/dock/keeper\): $1\.pane, [0-9]+ of 268435456 bytes, chained to byte [0-9]+$" "$2"' _ "$day" "$scratch/out"
  check "[C75] and its pipe" said "ok      the pipe of Harbor Keeper (harbor/dock/keeper)'s pane"
  T pipe-pane -t "$(pane_by_title 'Harbor Keeper')"
  check "[C74] when a pane's pipe is gone the carrier sets it again" \
    eventually_long bash -c '[[ $("$@" display -p -t "$("$@" list-panes -a -F "#{pane_title} #{pane_id}" | sed -n "s/^Harbor Keeper //p")" "#{pane_pipe}") == 1 ]]' _ setpriv --no-new-privs tmux -S "$run/$label" -u
  check "[C74] and records the gap with its time" eventually_long bash -c 'grep -qE "^[0-9-]+T[0-9:]+Z the pipe of the pane was gone, and the carrier set it again$" "$1/gaps"' _ "$(record_of keeper)"
  wp why "Harbor Keeper" "$root/records/Harbor Pilot" > "$scratch/out" 2>&1
  check "[C76] why names the records a seat is shown" \
    said "the seat's records: shown by the frame after the rows (Logs) at $root/records, whatever is there on the machine: a read-only file system, holding one read-only directory for each seat whose record it may read, under that seat's name: Harbor Pilot"
  wp why "Harbor Pilot" "$root/records" > "$scratch/out" 2>&1
  check "[C76] and says, for a seat that may read no record, that an empty read-only file system stands at the record path, whatever the machine holds there" \
    said "the seat's records: shown by the frame after the rows (Logs) at $root/records, whatever is there on the machine: a read-only file system, empty, since the seat may read no record"
  check "[C73] keeper's view masks the journal's places, the closed masks after its rows" \
    bash -c 'for m in "${@:2}"; do [[ -d $m ]] || continue; [[ $(jq -r --arg d "$m" ". as \$a | [range(0; length) | select(\$a[.] == \"--tmpfs\" and \$a[. + 1] == \$d) | \$a[. - 1]] | join(\",\")" <<< "$1") == 0000 ]] || exit 1; done' _ \
    "$(seat_command 'Harbor Keeper')" /var/log/journal /run/log/journal /run/systemd/journal
  local bus=/run/user/$EUID/bus
  if [[ -S $bus ]] && command -v busctl > /dev/null \
    && timeout 10 busctl --address="unix:path=$bus" call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.DBus.Properties Get ss org.freedesktop.systemd1.Manager Version > /dev/null 2>&1; then
    check "[C84] outside every view the user manager answers over the session bus, and in keeper's view, which keeps a chain, the same call is refused" \
      grep -qxF "bus $bus: refused" "$report"
  else
    skip "[C84] no user manager answers over the session bus here, so the runtime directory's mask is tried where one does"
  fi
  local carrier
  carrier=$(carrier_pid)
  kill -STOP "$carrier"
  T pipe-pane -t "$(pane_by_title 'Harbor Keeper')"
  check "[C75] with the carrier standing but held still, a pane whose pipe is gone stays so, and status exits 1 for it alone" exit_is 1 wp status
  check "[C75] the carrier itself is ok" said "ok      the carrier, pid $carrier"
  check "[C75] naming the pane" said "gone    the pipe of Harbor Keeper (harbor/dock/keeper)'s pane: what it shows is not kept until the carrier sets it again"
  kill -CONT "$carrier"
  check "down" exit_is 0 wp down
  check "[C71] the keepers end with their panes" eventually_long bash -c '[[ -z $(pgrep -f "workplace keep $1") ]]' _ "$(state_of)/records"
}

t_records_day_and_limit() {
  local fake=$scratch/fake-date printer=$root/tools/printer
  mkdir -p -- "$fake"
  printf '%s\n' 2030-01-01 > "$scratch/day"
  printf '%s\n' '#!/usr/bin/env bash' "if [[ \$# == 2 && \$1 == -u && \$2 == +%F ]]; then cat '$scratch/day'; else exec '$(command -v date)' \"\$@\"; fi" > "$fake/date"
  chmod +x -- "$fake/date"
  printf '%s\n' '#!/usr/bin/env bash' 'exec {fd}<> <(:)' 'for (( i = 0; i < 3000; i++ )); do printf "%d\n" "$i"; read -r -t 0.001 -u "$fd" _; done' 'printf "%s\n" printed' 'read -r _' > "$printer"
  chmod +x -- "$printer"
  scoped_clone
  mkdir -p -- "$root/records"
  statements_plan "$records_terms"' | (.programs[] | select(.path == "harbor/tower/watch/seat.typify") | .plan[1].term[5]) = ([$root + "/tools/printer"] | tojson)'
  check "plan" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "up, with a clock whose day the test changes" exit_is 0 env PATH="$fake:$PATH" "$BASH" "$loop" up
  sleep 1.5
  printf '%s\n' 2030-01-02 > "$scratch/day"
  check "watch printed 3,000 numbered lines, one a millisecond" eventually_long bash -c 'grep -q "^printed" "$1"/2030-01-0*.pane' _ "$(record_of watch)"
  check "down" exit_is 0 env PATH="$fake:$PATH" "$BASH" "$loop" down
  local d=$(record_of watch)
  check "[C81] the keeper changed the file itself at the change of day: both days hold lines" test -s "$d/2030-01-01.pane" -a -s "$d/2030-01-02.pane"
  local lines
  lines=$(cat "$d/2030-01-01.pane" "$d/2030-01-02.pane" | tr -d '\r' | grep -E '^[0-9]+$' | tr '\n' ' ')
  check "[C81] a change of day loses nothing and doubles nothing: 0 to 2999, each once and in order (first day $(tr -d '\r' < "$d/2030-01-01.pane" | grep -cE '^[0-9]+$') lines, second $(tr -d '\r' < "$d/2030-01-02.pane" | grep -cE '^[0-9]+$'))" \
    test "$lines" = "$(seq -s ' ' 0 2999) "
  rm -rf -- "$clone/BUILD"
  statements_plan "$records_terms"' | .programs[-1].recorded += [r(["record-limit", "2000"]; 9)] | (.programs[] | select(.path == "harbor/tower/watch/seat.typify") | .plan[1].term[5]) = (["/usr/bin/head", "-c", "5000", "/dev/zero"] | tojson)'
  local proc
  for proc in /proc/[0-9]*; do
    [[ $(tr '\0' ' ' 2> /dev/null < "$proc/cmdline") == *" keep $(record_of watch) "* ]] || continue
    note "  a keeper of watch's record runs before the second up: pid ${proc#/proc/}, started $(ps -o lstart= -p "${proc#/proc/}" 2> /dev/null), limit $(tr '\0' '\n' 2> /dev/null < "$proc/cmdline" | tail -n 1)"
  done
  check "plan with a limit of 2,000 bytes a day" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "up" exit_is 0 wp up
  check "watch's program wrote 5,000 bytes and ended, its pane staying dead" eventually_long dead_pane "Harbor Watch"
  check "[C82] at the limit nothing more is stored: the day holds 2,000 bytes" eventually_long bash -c '[[ $(stat -c %s "$1/$(date -u +%F).pane") == 2000 ]]' _ "$(record_of watch)"
  local counted='[[ $(awk -v d="$(date -u +%F)" "\$1 == d { n += \$2 } END { print n + 0 }" "$1/unstored" 2> /dev/null) == $2 ]]'
  local keepers='f=1; for p in /proc/[0-9]*; do [[ $(tr "\0" " " 2> /dev/null < "$p/cmdline") == *" keep $1 "* ]] && f=0; done;'
  if [[ $(T display-message -p -t "$(pane_by_title "Harbor Watch")" '#{pane_pipe}') == 0 ]]; then
    note "  this tmux, $(T -V), closed the dead pane's pipe (C98)"
    check "[C98] the pipe closed with the program, so watch's keeper has ended" eventually_long bash -c "$keepers (( f == 1 ))" _ "$(record_of watch)"
    check "[C82] and what was not stored is counted exactly, when the day's file ends with the pipe: 3,000" \
      eventually_long bash -c "$counted" _ "$(record_of watch)" 3000
  else
    note "  this tmux, $(T -V), keeps the dead pane's pipe open (C98)"
    check "[C98] the pipe stays open, and a keeper of watch's record still runs" bash -c "$keepers (( f == 0 ))" _ "$(record_of watch)"
    note "  the server: pid $(T display-message -p '#{pid}'); watch's pane: $(T display-message -p -t "$(pane_by_title "Harbor Watch")" 'pid #{pane_pid}, dead #{pane_dead} since #{t:pane_dead_time}, pipe #{pane_pipe}')"
    note "  watch's unstored before down: $(tr '\n' '|' 2> /dev/null < "$(record_of watch)/unstored"), changed $(stat -c %y "$(record_of watch)/unstored" 2> /dev/null)"
    for proc in /proc/[0-9]*; do
      [[ $(tr '\0' ' ' 2> /dev/null < "$proc/cmdline") == *" keep $(record_of watch) "* ]] || continue
      note "  a keeper of watch's record: pid ${proc#/proc/}, parent $(awk '{ print $4 }' "$proc/stat" 2> /dev/null), started $(ps -o lstart= -p "${proc#/proc/}" 2> /dev/null), limit $(tr '\0' '\n' 2> /dev/null < "$proc/cmdline" | tail -n 1)"
    done
  fi
  check "down" exit_is 0 wp down
  check "[C82] after down, what was not stored is counted exactly, once: 3,000" eventually_long bash -c "$counted" _ "$(record_of watch)" 3000
  check "[C75] record verify reads watch's unstored against its chain, over its whole span" exit_is 0 wp record verify "Harbor Watch" unstored
  check "[C75] its whole length" said "Harbor Watch/unstored agrees with its chain up to byte $(stat -c %s "$(record_of watch)/unstored"), its whole length"
}

t_records_keys_that_tmux_expands() {
  local day
  day=$(date -u +%F)
  scoped_clone
  mkdir -p -- "$root/records"
  statements_plan "$records_terms"' | terms_of("orchard/barn/picker/seat.typify"; .[3] = "p%s#{pane_id}" | if .[0] == "pane" then .[4] = "Orchard p%s#{pane_id}" else . end)
    | .state.environment |= map(if .key[0:3] == ["orchard", "barn", "picker"] then .key[2] = "p%s#{pane_id}" else . end)'
  check "plan with a seat whose key holds % and #" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "up" exit_is 0 wp up
  check "picker ran" wait_for_probe "Orchard p%s#{pane_id}" picker
  check "down" exit_is 0 wp down
  check "[C71] the seat's pane is kept in its own directory, since the pipe's command doubles the % and # that tmux would expand" \
    grep -qa "probe picker done" "$(state_of)/records/Orchard p%s#{pane_id}/$day.pane"
}

t_records_verify() {
  local d day file entries
  day=$(date -u +%F)
  mkdir -p -- "$root/mailbox"
  check "up, with mail" records_up '| def add($path; $args): (.programs[] | select(.path == $path) | .plan[1].term[5]) |= (fromjson + $args | tojson);
    add("harbor/dock/keeper/seat.typify"; ["print=" + $root + "/tools/probe"]) | '"$comms_terms"
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  request pilot note.md "to: Harbor Keeper" "subject: a note" --- "body"
  check "a mail is served" answered_ok pilot note.md
  check "down: the carrier chains what is left as it ends" exit_is 0 wp down
  check "[C72] the frame's own record of requests is chained among the kept files" \
    test "$(jq -c 'select(.file == "comms/record") | [.seat, .offset]' "$(state_of)/records/chain" | head -n 1)" = '["the frame",0]'
  check "[C75] record verify --requests reads the frame's record of requests against its chain, over its whole span" exit_is 0 wp record verify --requests
  check "[C75] its whole length" said "comms/record agrees with its chain up to byte $(stat -c %s "$(state_of)/comms/record"), its whole length"
  check "up again, the same day" exit_is 0 wp up
  check "keeper ran again" wait_for_probe "Harbor Keeper" keeper
  check "down" exit_is 0 wp down
  d=$(record_of keeper)
  file=$d/$day.pane
  mapfile -t entries < <(jq -c --arg f "Harbor Keeper/$day.pane" 'select(.file == $f) | [.offset, .length, .at]' "$(state_of)/records/chain")
  check "[C72] the chain holds an entry for each run's bytes, the file sink a line of JSON each" test "${#entries[@]}" -ge 2
  check "[C72] each entry names the workplace, the seat, the file, the offset, the length, and the hash of the bytes with the hash sent before" \
    test "$(jq -c --arg f "Harbor Keeper/$day.pane" 'select(.file == $f) | [.workplace, .seat, (.previous | length), (.hash | length)]' "$(state_of)/records/chain" | head -n 1)" = "[\"$label\",\"Harbor Keeper\",64,64]"
  local first second o l
  first=$(jq -r --arg f "Harbor Keeper/$day.pane" 'select(.file == $f) | .hash' "$(state_of)/records/chain" | head -n 1)
  check "[C72] the first hash is SHA-256 over 64 zeros and the bytes it covers" \
    test "$({ printf '%064d' 0; head -c "$(jq -r '.[1]' <<< "${entries[0]}")" "$file"; } | sha256sum | cut -d' ' -f1)" = "$first"
  check "[C75] record verify says that the file agrees with its chain" exit_is 0 wp record verify "Harbor Keeper" "$day"
  check "[C75] up to its whole length" said "Harbor Keeper/$day.pane agrees with its chain up to byte $(stat -c %s "$file"), its whole length"
  cp -- "$file" "$scratch/kept"
  o=$(jq -r '.[0]' <<< "${entries[1]}") l=$(jq -r '.[1]' <<< "${entries[1]}")
  printf 'Z' | dd of="$file" bs=1 seek=$(( o + l / 2 )) conv=notrunc status=none
  check "[C80] a byte changed is named, with exit 1" exit_is 1 wp record verify "Harbor Keeper" "$day"
  check "[C80] at the first place it shows: the entry that covers it" said "differs from its chain in the $l bytes from byte $o, which its entry of $(jq -r '.[2]' <<< "${entries[1]}") covers"
  cp -- "$scratch/kept" "$file"
  truncate -s $(( o + 5 )) "$file"
  check "[C80] a file cut short is named" exit_is 1 wp record verify "Harbor Keeper" "$day"
  check "[C80] at the byte where it ends, with the entry that covers that byte" said "is cut short at byte $(( o + 5 )): its chain's entry of $(jq -r '.[2]' <<< "${entries[1]}") covers the $l bytes from byte $o"
  cp -- "$scratch/kept" "$file"
  { head -c 1 "$scratch/kept"; printf 'a line added\n'; tail -c +2 "$scratch/kept"; } > "$file"
  check "[C80] a line added in the middle is named" exit_is 1 wp record verify "Harbor Keeper" "$day"
  check "[C80] at the first entry it shows in" said "differs from its chain in the $(jq -r '.[1]' <<< "${entries[0]}") bytes from byte 0"
  rm -f -- "$file"
  check "[C80] a file removed is named" exit_is 1 wp record verify "Harbor Keeper" "$day"
  check "[C80] saying how much its chain covers" said "Harbor Keeper/$day.pane is gone; its chain covers"
  cp -- "$scratch/kept" "$file"
  check "[C80] and with the file as it was, it agrees again" exit_is 0 wp record verify "Harbor Keeper" "$day"
  local chain=$(state_of)/records/chain
  cp -- "$chain" "$scratch/chain-kept"
  jq -c --arg f "Harbor Keeper/$day.pane" 'select(.file != $f or .offset != 0)' "$scratch/chain-kept" > "$chain"
  check "[C80] an entry missing from the sink, as one the journal dropped or removed, is named as a skip" exit_is 1 wp record verify "Harbor Keeper" "$day"
  check "[C80] at the entry after it" said "the chain skips from byte 0 to byte $(jq -r '.[1]' <<< "${entries[0]}") at its entry of $(jq -r '.[2]' <<< "${entries[1]}")"
  cp -- "$scratch/chain-kept" "$chain"
  check "[C75] record verify refuses a seat the workplace does not make, with exit 2" exit_is 2 wp record verify "Ghost" "$day"
  check "up" exit_is 0 wp up
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  rm -f -- "$(state_of)/records/chain"
  mkdir -- "$(state_of)/records/chain"
  check "down, with the file sink made unwritable" exit_is 0 wp down
  check "[C75] status exits 1 for a sink that did not take an entry" exit_is 1 wp status
  check "[C75] naming the sink and when" bash -c 'grep -qE "^gone    the chain'"'"'s sink, the file, did not take its last entry, at [0-9-]+T[0-9:]+Z, and has taken none since$" "$1"' _ "$scratch/out"
  rmdir -- "$(state_of)/records/chain"
  check "up, with the file sink as it should be" exit_is 0 wp up
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  local stood
  stood=$(jq -r '.files["comms/record"].offset' "$(state_of)/records/chain.state")
  mv -- "$(state_of)/records/chain" "$scratch/chain"
  mkdir -- "$(state_of)/records/chain"
  request pilot refused.md "to: Harbor Keeper" "subject: while the sink refuses" --- "body"
  check "a mail is served while the sink refuses" answered_ok pilot refused.md
  check "[C75] while the run is up and the sink's last entry was refused, status exits 1" status_comes_to 1
  check "[C75] naming the sink and when" bash -c 'grep -qE "^gone    the chain'"'"'s sink, the file, did not take its last entry, at [0-9-]+T[0-9:]+Z, and has taken none since$" "$1"' _ "$scratch/out"
  rmdir -- "$(state_of)/records/chain"
  mv -- "$scratch/chain" "$(state_of)/records/chain"
  request pilot taken.md "to: Harbor Keeper" "subject: once it takes again" --- "body"
  check "a mail is served once the sink takes again" answered_ok pilot taken.md
  check "[C75] once the sink takes an entry again, status exits 0 for it" status_comes_to 0
  check "[C75] and names the time of the last refusal for the rest of the run" \
    bash -c 'grep -qE "^ok      the chain'"'"'s sink, the file, takes entries again; it last refused one at [0-9-]+T[0-9:]+Z$" "$1"' _ "$scratch/out"
  check "[C75] a refused entry moved nothing forward: the entry the sink took next begins at byte $stood of the frame's record, where the chain stood before the refusal" \
    bash -c 'jq -s -e --argjson o "$2" "[.[] | select(.file == \"comms/record\" and .offset == \$o)] | length == 1" "$1" > /dev/null' _ "$(state_of)/records/chain" "$stood"
  check "down" exit_is 0 wp down
}

status_exits() {
  "$BASH" "$loop" status > "$scratch/out" 2>&1
  [[ $? == "$1" ]]
}
status_comes_to() {
  eventually_long status_exits "$1" && return 0
  note "    status said:"
  sed 's/^/    | /' "$scratch/out"
  return 1
}

t_the_runtime_directory() {
  scoped_clone
  local runtime=/run/user/$EUID planned entry state
  statements_plan
  check "plan" exit_is 0 wplan
  planned=$(cat "$clone/PLAN/plan.json" "$clone/PLAN/manifest.json" | sha256sum)
  local refusals=(
    '.programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; "RUNTIME"; "read-only"; 22)]|seat Harbor Keeper (harbor/dock/keeper): RUNTIME (read-only, from programs/policy.typify:22) lies at or beneath RUNTIME, the user'"'"'s runtime directory, which the frame shows to no seat as the machine has it; a row there may be hidden, searchable-only or scratch'
    '.programs[-1].recorded += [st("orchard"; "barn"; "-"; "room"; "RUNTIME/systemd/private"; "read-write"; 23)]|seat Orchard Picker (orchard/barn/picker): RUNTIME/systemd/private (read-write, from programs/policy.typify:23) lies at or beneath RUNTIME, the user'"'"'s runtime directory'
  )
  for entry in "${refusals[@]}"; do
    entry=${entry//RUNTIME/$runtime}
    statements_plan "${entry%|*}"
    check "[C84] plan refuses, with exit 1, a read-only or read-write row at or beneath the runtime directory, chain or none: ${entry##*|}" exit_is 1 wplan
    check "[C84] naming the seat, the row and its origin" said "${entry##*|}"
  done
  check "[C84] each seat that the row speaks for is named" said "seat Orchard Grower (orchard/barn/grower): $runtime/systemd/private (read-write, from programs/policy.typify:23) lies at or beneath $runtime"
  check "[C84] and PLAN/ is as it was" test "$(cat "$clone/PLAN/plan.json" "$clone/PLAN/manifest.json" | sha256sum)" = "$planned"
  for state in hidden searchable-only scratch; do
    statements_plan '.programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; "'"$runtime"'"; "'"$state"'"; 22), st("harbor"; "dock"; "keeper"; "seat"; "'"$runtime"'/gnupg"; "hidden"; 23)]'
    check "[C84] a $state row at the runtime directory stands, and a hidden one beneath it: plan takes them" exit_is 0 wplan
  done
  statements_plan
  check "plan" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  edit_plan '.programs[-1].recorded += [{term: ["statement", "harbor", "dock", "keeper", "seat", "'"$runtime"'/bus", "read-only"], origin: {kind: "program", line: 22, path: "programs/policy.typify"}}]'
  check "[C84] build refuses a plan written by hand with such a row, with exit 1" exit_is 1 wp build
  check "[C84] naming the seat and the row" said "seat Harbor Keeper (harbor/dock/keeper): $runtime/bus (read-only, from programs/policy.typify:22) lies at or beneath $runtime"
  if [[ -d $runtime ]]; then
    statements_plan '.programs[-1].recorded += [st("harbor"; "dock"; "keeper"; "seat"; "'"$runtime"'/gnupg"; "hidden"; 23)]'
    check "plan" exit_is 0 wplan
    wp why "Harbor Keeper" "$runtime/bus" > "$scratch/out" 2>&1
    check "[C84] why names the mask" said "masked by the frame after the rows: $runtime, the user's runtime directory, where the user's manager, its bus and the user's agents keep their sockets, is shown to this seat as an empty read-only file system, since its row / read-only would show it as the machine has it; the seat's own rows beneath it stand: $runtime/gnupg hidden"
    check "[C84] and says that the mask, not the nearest row, decides" said "  the frame's mask above decides for the path, and the row does not"
    wp why "Harbor Keeper" "$runtime/gnupg/x" > "$scratch/out" 2>&1
    check "[C84] beneath the mask, the seat's own row decides" bash -c '! grep -qF "the frame'"'"'s mask above decides" "$1" && grep -qxF "no row at the path; its nearest ancestor'"'"'s row is $2/gnupg hidden" "$1"' _ "$scratch/out" "$runtime"
    wp why "Harbor Pilot" "$runtime/bus" > "$scratch/out" 2>&1
    check "[C84] the mask stands for every seat whose rows would show the machine's runtime directory" said "masked by the frame after the rows: $runtime, the user's runtime directory"
  else
    skip "[C84] no runtime directory $runtime here, so why's word on its mask is tried where one stands"
  fi
}

t_records_journal() {
  if ! systemctl --user show-environment > /dev/null 2>&1; then
    skip "[C83] no user manager answers here, so the chain is not sent to the journal; tried where one answers"
    return 0
  fi
  local day unit forged
  day=$(date -u +%F)
  unit=workplace-carrier-$label.service
  check "up with the chain going to the journal" records_up '| (.programs[-1].recorded[] | select(.term[0] == "record-chain") | .term[1]) = "journal"'
  check "[C72] up starts the carrier as a unit of the user's manager" systemctl --user is-active --quiet "$unit"
  check "[C72] the ledger records the unit by its invocation, which down checks before it stops it" \
    test "$(jq -r 'select(.what | startswith("the carrier")) | .is' "$run/ledger")" = "$(systemctl --user show -p InvocationID --value "$unit")"
  check "[C72] the unit runs under no-new-privileges" test "$(systemctl --user show -p NoNewPrivileges --value "$unit")" = yes
  check "[C72] stopping the unit signals the carrier alone" test "$(systemctl --user show -p KillMode --value "$unit")" = mixed
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  local before sent
  sent=$(journalctl --user _SYSTEMD_USER_UNIT="$unit" -o cat --no-pager | grep -cF "\"Harbor Keeper/$day.pane\"")
  T send-keys -t "$(pane_by_title "Harbor Keeper")" x
  check "[C72] a key typed into the kept pane is echoed into its record, and a pass of the carrier sends an entry for it" \
    eventually_long bash -c '(( $(journalctl --user _SYSTEMD_USER_UNIT="$1" -o cat --no-pager | grep -cF "\"Harbor Keeper/$2.pane\"") > $3 ))' _ "$unit" "$day" "$sent"
  before=$(stat -c %s "$(record_of keeper)/$day.pane")
  T send-keys -t "$(pane_by_title "Harbor Keeper")" y
  check "[C72] a second key, typed as soon as that entry is seen, is echoed too: the next pass is some ten seconds away, so only the carrier's last entries at down can cover it" \
    eventually bash -c '(( $(stat -c %s "$1") > $2 ))' _ "$(record_of keeper)/$day.pane" "$before"
  check "down" exit_is 0 wp down
  check "[C72] down ends the unit through its manager: it is inactive when down returns" bash -c '! systemctl --user is-active --quiet "$1"' _ "$unit"
  check "[C83] record verify reads the chain from the journal, and the file agrees" exit_is 0 wp record verify "Harbor Keeper" "$day"
  check "[C83] its whole length" said "Harbor Keeper/$day.pane agrees with its chain up to byte $(stat -c %s "$(record_of keeper)/$day.pane"), its whole length"
  check "[C72] every entry the carrier sent, the last ones at down among them, carries a hash and a previous of 64 hexadecimal digits" \
    test "$(journalctl --user _SYSTEMD_USER_UNIT="$unit" -o cat --no-pager | jq -R -s '[split("\n")[] | try fromjson catch empty | select(type == "object" and .chain == "workplace-record")] | length > 0 and all(.hash + .previous | test("^[0-9a-f]{128}$"))')" = true
  local ident size
  ident=$(journalctl --user _SYSTEMD_USER_UNIT="$unit" -o json --no-pager | jq -r 'select(.MESSAGE | strings | test("workplace-record")) | .SYSLOG_IDENTIFIER' | head -n 1)
  check "[C72] the carrier's entries carry the identifier workplace-carrier" test "$ident" = workplace-carrier
  size=$(stat -c %s "$(record_of keeper)/$day.pane")
  forged=$(jq -n -c --arg w "$label" --arg f "Harbor Keeper/$day.pane" --argjson o "$size" \
    '{chain: "workplace-record", at: "2030-01-01T00:00:00Z", workplace: $w, seat: "Harbor Keeper", file: $f, offset: $o, length: 1, hash: ("f" * 64), previous: ("0" * 64)}')
  printf '%s\n' "$forged" | systemd-cat -t "$ident"
  check "[C83] an entry that another process sends under the carrier's words reaches the journal" \
    eventually_long bash -c 'journalctl --user -t "$1" -o cat --no-pager | grep -qF "2030-01-01T00:00:00Z"' _ "$ident"
  check "[C83] and is not taken as the carrier's: the file still agrees" exit_is 0 wp record verify "Harbor Keeper" "$day"
  check "[C83] its whole length" said "Harbor Keeper/$day.pane agrees with its chain up to byte $(stat -c %s "$(record_of keeper)/$day.pane"), its whole length"
  check "[C83] the run wrote $(journalctl --user _SYSTEMD_USER_UNIT="$unit" -o cat --no-pager | grep -c .) lines of the carrier's to the journal, $(journalctl --user _SYSTEMD_USER_UNIT="$unit" -o cat --no-pager | grep -c workplace-record) of them entries of the chain, beside the manager's own lines of the unit and the one forged" \
    test "$(journalctl --user _SYSTEMD_USER_UNIT="$unit" -o cat --no-pager | grep -c workplace-record)" -ge 1
  local s2=$scratch/state2 mark1 mark2 file1 file2
  file1=$(record_of keeper)/$day.pane
  file2="$s2/workplace/$label/records/Harbor Keeper/$day.pane"
  mark1=$(jq -r '.mark // ""' "$clone/BUILD/records.json")
  mkdir -p -- "$s2"
  export XDG_STATE_HOME=$s2
  rm -rf -- "$clone/BUILD"
  check "[C75] build again, for the workplace of the same name in a second state directory" exit_is 0 wp build
  mark2=$(jq -r '.mark // ""' "$clone/BUILD/records.json")
  check "[C75] build gives each state directory a mark of its own, kept in S/records/mark" \
    bash -c '[[ $1 =~ ^[0-9a-f]{32}$ && $2 =~ ^[0-9a-f]{32}$ && $1 != "$2" && $(cat "$3") == "$2" ]]' _ "$mark1" "$mark2" "$s2/workplace/$label/records/mark"
  check "[C75] up there, its carrier a unit of the same name" exit_is 0 wp up
  check "[C75] the unit is the one of the first run's name" systemctl --user is-active --quiet "$unit"
  check "keeper ran there" wait_for_probe "Harbor Keeper" keeper
  check "down" exit_is 0 wp down
  check "[C75] under the one unit, the journal holds entries of the keeper's file from both state directories, each with its mark" \
    test "$(journalctl --user _SYSTEMD_USER_UNIT="$unit" -o cat --no-pager | jq -R -r --arg f "Harbor Keeper/$day.pane" 'try fromjson catch empty | select(type == "object" and .chain == "workplace-record" and .file == $f) | .mark // "none"' | LC_ALL=C sort -u | tr '\n' ' ')" = "$(printf '%s\n' "$mark1" "$mark2" | LC_ALL=C sort | tr '\n' ' ')"
  check "[C75] record verify in the second state directory passes over the first's entries" exit_is 0 wp record verify "Harbor Keeper" "$day"
  check "[C75] and its file agrees with its own chain, its whole length" said "Harbor Keeper/$day.pane agrees with its chain up to byte $(stat -c %s "$file2"), its whole length"
  unset XDG_STATE_HOME
  rm -rf -- "$clone/BUILD"
  check "[C75] build again in the first state directory" exit_is 0 wp build
  check "[C75] which keeps its mark across builds" test "$(jq -r '.mark // ""' "$clone/BUILD/records.json")" = "$mark1"
  check "[C75] record verify there passes over the second's entries" exit_is 0 wp record verify "Harbor Keeper" "$day"
  check "[C75] and its file agrees with its own chain, its whole length" said "Harbor Keeper/$day.pane agrees with its chain up to byte $(stat -c %s "$file1"), its whole length"
  printf 'not a mark' > "$(state_of)/records/mark"
  rm -rf -- "$clone/BUILD"
  check "[C72] build refuses a mark that is not 32 hexadecimal digits" exit_is 1 wp build
  check "[C72] and says why" said "build refuses: $(state_of)/records/mark is not a file that holds 32 hexadecimal digits, the mark of this state directory"
  local unmarked premark
  printf '%s\n' "$mark1" > "$(state_of)/records/mark"
  check "build again, the first state directory's mark put back" exit_is 0 wp build
  jq -c 'del(.mark)' "$clone/BUILD/records.json" > "$scratch/records.json" && cp -- "$scratch/records.json" "$clone/BUILD/records.json"
  unmarked=$(sha256sum < "$clone/BUILD/records.json")
  sed -i "s/^[0-9a-f]\{64\}  records[.]json\$/${unmarked%% *}  records.json/" "$clone/BUILD/MANIFEST"
  premark="$clone/BUILD was built before the state directory's mark, so its entries in the journal could not be told from those of another state directory of the same name; build again"
  check "[C75] up refuses a build whose chain goes to the journal and that holds no mark, as one made before the mark does, with exit 1" exit_is 1 wp up
  check "[C75] naming it" said "$premark"
  check "[C75] and starts nothing" test ! -e "$clone/BUILD/RUN"
  check "[C75] record verify refuses it too, with exit 2" exit_is 2 wp record verify "Harbor Keeper" "$day"
  check "[C75] naming it" said "$premark"
}

t_restart() {
  local s day pane seen others sum carrier args='| add("harbor/dock/keeper/seat.typify"; ["report=" + $root + "/harbor/berth/keeper", "entries=" + $root + "/records"])'
  s=$(state_of)
  day=$(date -u +%F)
  mkdir -p -- "$scratch/liar"
  command -v tmux > "$scratch/liar/real"
  cp -- "$fixtures/tmux-liar" "$scratch/liar/tmux"
  check "up, every pane kept, keeper's probe listing the record path, the frame's tmux a stand-in that can list a piped pane as having no pipe" \
    liar_records_up "| $probe_args $args"
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  seen=$(grep "^entries $root/records: " "$root/harbor/berth/keeper")
  check "keeper's view shows it the record path" test -n "$seen"
  pane=$(pane_by_title "Harbor Keeper")
  others=$(T list-panes -a -F '#{pane_id} #{pane_pid}' | grep -v "^$pane " | LC_ALL=C sort)
  T send-keys -t "$pane" C-c
  check "[C98] a seat whose program ends keeps its pane, dead" eventually_long dead_pane "Harbor Keeper"
  check "[C98] with the same id" test "$(pane_by_title "Harbor Keeper")" = "$pane"
  check "[C98] status names the seat as gone, and exits 1" exit_is 1 wp status
  check "[C98] naming it" said "gone    seat/Harbor Keeper"
  sleep 3
  check "[C98] the carrier does not set the pipe of a dead pane again" bash -c '! grep -q "the carrier set it again" "$1/gaps" 2> /dev/null' _ "$(record_of keeper)"
  check "[C98] restart refuses a seat whose program runs, with exit 1" exit_is 1 wp restart "Harbor Pilot"
  check "[C98] saying so" said "restart refuses: the program in the pane of Harbor Pilot runs, and restart starts only a seat whose program has ended"
  check "[C98] restart refuses a seat the workplace does not make, with exit 2" exit_is 2 wp restart Ghost
  check "[C98] and neither refusal started anything" dead_pane "Harbor Keeper"
  check "[C98] restart, with no name, starts again each seat whose program ended" exit_is 0 wp restart
  check "[C98] saying who asked" said "restart: Harbor Keeper is started again in its pane $pane, asked by $(id -un) (uid $EUID) at "
  check "[C98] in the same pane, alive, with its record's pipe set" eventually pane_state_is "$pane" "$pane 0 1"
  check "[C98] restart made the pane and set its pipe in one call of tmux, so the carrier never lists it alive with no pipe" \
    jq -se --arg p "$pane" 'any(.[]; index(["respawn-pane", "-k", "-t", $p]) != null and index("pipe-pane") != null and index(";") != null)' "$clone/BUILD/RUN/calls.jsonl"
  check "keeper ran again" wait_for_probe "Harbor Keeper" keeper
  sleep 3
  check "[C98] after the restart and three of the carrier's passes, keeper's gaps hold no line of the carrier" \
    bash -c '! grep -q "the carrier set it again" "$1/gaps"' _ "$(record_of keeper)"
  printf '%s\n' "$pane" > "$scratch/liar/lie"
  sleep 3
  : > "$scratch/liar/lie"
  check "[C98] a carrier that lists keeper's piped pane as having no pipe leaves the pipe as it is" pane_state_is "$pane" "$pane 0 1"
  check "[C98] and writes no gap, since its call set no pipe" bash -c '! grep -q "the carrier set it again" "$1/gaps"' _ "$(record_of keeper)"
  check "[C98] in its view as up made it: it is shown the same record path" test "$(grep "^entries $root/records: " "$root/harbor/berth/keeper")" = "$seen"
  check "[C98] every other pane is as it was, the same process in each" test "$(T list-panes -a -F '#{pane_id} #{pane_pid}' | grep -v "^$pane " | LC_ALL=C sort)" = "$others"
  check "[C98] status is whole again" exit_is 0 wp status
  check "[C98] S/restarts records who asked, mode 0600" \
    bash -c '[[ $(stat -c %a "$1") == 600 ]] && jq -e --arg p "$2" --arg u "$3" --argjson id "$4" "select(.seat == \"Harbor Keeper\" and .pane == \$p and .asked.user == \$u and .asked.uid == \$id and (.asked.terminal | type) == \"string\")" "$1" > /dev/null' \
    _ "$s/restarts" "$pane" "$(id -un)" "$EUID"
  check "[C98] and so does the seat's gaps, which the chain covers" grep -q "the pane's program had ended, and restart started it again, asked by $(id -un) (uid $EUID) at " "$(record_of keeper)/gaps"
  check "down" exit_is 0 wp down
  check "[C75] the day file, which holds both runs of keeper, agrees with its chain" exit_is 0 wp record verify "Harbor Keeper" "$day"
  check "[C75] its whole length" said "Harbor Keeper/$day.pane agrees with its chain up to byte $(stat -c %s "$(record_of keeper)/$day.pane"), its whole length"
  check "[C75] record verify reads keeper's gaps against its chain, over its whole span" exit_is 0 wp record verify "Harbor Keeper" gaps
  check "[C75] its whole length" said "Harbor Keeper/gaps agrees with its chain up to byte $(stat -c %s "$(record_of keeper)/gaps"), its whole length"
  check "[C98] restart refuses when nothing is up, with exit 2" exit_is 2 wp restart
  sum=$(sha256sum < "$clone/BUILD/MANIFEST")
  check "[C99] unbuild removes the build while the workplace is down" exit_is 0 wp unbuild
  check "[C99] naming it and its MANIFEST's hash" said "unbuild: removed $clone/BUILD, "
  check "[C99] the hash" said " files, whose MANIFEST had the hash ${sum%% *}:"
  check "[C99] and each file it removed" bash -c 'grep -qxF "  MANIFEST" "$1" && grep -qxF "  bin/workplace" "$1" && grep -qxF "  records.json" "$1" && grep -qxF "  plan.json" "$1"' _ "$scratch/out"
  check "[C99] and the state directory it keeps" said "unbuild: the state directory $s is kept"
  check "[C99] BUILD is gone, and the state directory stands with the records" test ! -e "$clone/BUILD" -a -s "$(record_of keeper)/$day.pane"
  check "[C99] a second unbuild finds no build, says so, and exits 0" exit_is 0 wp unbuild
  check "[C99] saying so" said "unbuild: there is no build under $clone"
  check "[C99] build again" exit_is 0 wp build
  check "up" exit_is 0 wp up
  check "[C99] unbuild refuses while the workplace is up, with exit 1" exit_is 1 wp unbuild
  check "[C99] saying so" said "unbuild refuses: the workplace is up, since $clone/BUILD/RUN stands; run workplace down first"
  check "[C99] and the build stands" test -f "$clone/BUILD/MANIFEST"
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  pane=$(pane_by_title "Harbor Keeper")
  T send-keys -t "$pane" C-c
  check "keeper's program ends again" eventually_long dead_pane "Harbor Keeper"
  cp -p -- "$clone/BUILD/plan.json" "$scratch/plan.json"
  chmod u+w -- "$clone/BUILD/plan.json"
  printf ' ' >> "$clone/BUILD/plan.json"
  check "[C98] restart refuses what up refuses, and starts nothing: a build that does not verify, with exit 1" exit_is 1 wp restart "Harbor Keeper"
  check "[C98] saying so" said "restart starts a seat only from a verified build, as up does"
  cp -p -- "$scratch/plan.json" "$clone/BUILD/plan.json"
  carrier=$(carrier_pid)
  kill -KILL "$carrier"
  eventually bash -c '! stat -L "/proc/$1/cwd" > /dev/null 2>&1' _ "$carrier"
  check "[C98] and a line of the run's checks that status names as gone, here the carrier's, with exit 1" exit_is 1 wp restart "Harbor Keeper"
  check "[C98] saying so" said "restart refuses: status names this as gone, and only down and up make it again: the carrier, pid $carrier"
  check "[C98] and the seat's pane is still dead" dead_pane "Harbor Keeper"
  check "down" exit_is 0 wp down
}

state_but_keys() {
  (cd -- "$1" && find . -path ./keys -prune -o -printf '%y %m %p\n' | LC_ALL=C sort \
    && find . -path ./keys -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}
files_under() { find "$1" ! -type d 2> /dev/null | grep -c ''; }

t_unbuild_keys() {
  local program
  for program in gpg gpg-agent gpgconf ssh-keygen ssh-add setsid base64; do
    command -v "$program" > /dev/null || { skip "[C99] $program is not on PATH here, so no key home is made for unbuild to remove"; return; }
  done
  scoped_clone
  local s homes before pane home n
  s=$(state_of)
  mkdir -m 0700 -- "$root/keys"
  mkdir -p -- "$root/records" "$root/mailbox"
  ssh-keygen -q -t ed25519 -N '' -C account-comment -f "$root/keys/account" < /dev/null
  rm -f -- "$root/keys/account.pub"
  statements_plan "$key_terms | $home_terms | $value_terms | $comms_terms | $records_terms"' | .programs[-1].recorded |= map(select(.term[0] != "home-seed"))
    | .programs[-1].recorded += [{term: ["ssh-key", "account", "keys/account"], origin: {kind: "program", line: 40, path: "programs/SSH.typify"}},
                                 {term: ["ssh-grant", "-", "-", "-", "workplace", "account", "granted"], origin: {kind: "program", line: 41, path: "programs/SSH.typify"}},
                                 st("-"; "-"; "-"; "workplace"; $root + "/keys"; "hidden"; 42)]'
  check "plan" exit_is 0 wplan
  check "build" exit_is 0 wp build
  jq -n '{workplace: {WPT_TOKEN: "the token"}, rooms: {"harbor/dock": {WPT_DOCK: "the dock"}}, offices: {orchard: {WPT_ORCHARD: "the orchard"}}}' > "$s/values.json"
  chmod 0600 -- "$s/values.json"
  check "up" exit_is 0 wp up
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  pane=$(pane_by_title "Harbor Keeper")
  T send-keys -t "$pane" C-c
  check "keeper's program ends" eventually_long dead_pane "Harbor Keeper"
  check "restart" exit_is 0 wp restart "Harbor Keeper"
  check "down" exit_is 0 wp down
  n=$(files_under "$s/keys")
  check "[C99] the state directory holds the build's key homes, $n files with the grants' copies, beside the seats' homes, the records, the mail's store, the values file and restarts" \
    bash -c '(( $2 > 0 )) && [[ -n $(find "$1/keys" -path "*/ssh/*" ! -type d -print -quit) ]] && for p in homes records mail values.json restarts; do [[ -e $1/$p ]] || exit 1; done' _ "$s" "$n"
  home=$(find "$s/keys" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort | head -n 1)
  gpgconf --homedir "$home" --launch gpg-agent > /dev/null 2>&1
  local agent=1
  if ! eventually agent_of "$home"; then
    agent=0
    skip "[C99] no agent of a key home could be started here, so that unbuild ends one is shown where one can"
  fi
  local socket
  socket=$(gpgconf --homedir "$home" --list-dirs socketdir 2> /dev/null)
  n=$(files_under "$s/keys")
  before=$(state_but_keys "$s")
  check "[C99] unbuild" exit_is 0 wp unbuild
  check "[C99] it names the key homes it removed" said "unbuild: removed the key homes in $s/keys, 3 homes, $n files, first removing their runtime socket directories, which ends any agent of them:"
  check "[C99] and no file stands beneath S/keys" test ! -e "$s/keys"
  (( agent )) && check "[C99] the agent of a key home has ended" eventually_long no_agent_of "$home"
  if (( agent )) && [[ $socket == /run/user/* && -d /run/user/$EUID/gnupg && -r /run/user/$EUID/gnupg ]]; then
    check "[C99] and its runtime socket directory, which stood while it ran, is gone: removing the home alone ends the agent and leaves the directory" test ! -e "$socket"
  else
    skip "[C99] no agent's socket directory stood in a readable /run/user/$EUID/gnupg here, so that unbuild leaves none is measured where one does"
  fi
  check "[C99] everything else in the state directory stands as before, byte for byte" test "$(state_but_keys "$s")" = "$before"
  check "[C99] which unbuild names as kept, the seats' homes, the records, the mail's store, the values file and restarts among it" \
    bash -c 'l=$(grep -F "unbuild: the state directory $2 is kept, with everything in it but the key homes: " "$1") || exit 1; l=", ${l#*key homes: }, "; for p in homes mail records restarts values.json; do [[ $l == *", $p, "* ]] || exit 1; done' _ "$scratch/out" "$s"
  check "build again" exit_is 0 wp build
  rm -rf -- "$clone/BUILD"
  check "[C99] with no BUILD, unbuild still removes the key homes that stand" exit_is 0 wp unbuild
  check "[C99] saying that there is no build" said "unbuild: there is no build under $clone"
  check "[C99] and naming the homes, found by the plan's name" said "unbuild: removed the key homes in $s/keys, 3 homes, "
  check "[C99] and no file stands beneath S/keys" test ! -e "$s/keys"
  check "build again" exit_is 0 wp build
  rm -rf -- "$clone/BUILD"
  local other=${s%/*}/another-workplace
  mkdir -p -m 0700 -- "$other/keys/01"
  printf '%s\n' "another workplace's key" > "$other/keys/01/key"
  cp -- "$clone/PLAN/plan.json" "$scratch/plan-kept.json"
  jq '.programs |= map(.plan |= map(if type == "array" and .[0] == "server" then .[1] = "another-workplace"
                                     elif type == "object" and .term[0]? == "server" then .term[1] = "another-workplace" else . end))' \
    "$scratch/plan-kept.json" > "$clone/PLAN/plan.json"
  check "the plan's server term now names another-workplace" \
    test "$(jq -r '[.programs[].plan[] | (if type == "object" then .term else . end) | select(.[0] == "server") | .[1]] | unique | join(",")' "$clone/PLAN/plan.json")" = another-workplace
  check "[C99] with no BUILD and a PLAN that names a workplace that is neither default nor the clone's, unbuild takes the clone's name" exit_is 0 wp unbuild
  check "[C99] and removes this workplace's key homes" \
    bash -c 'grep -qF "unbuild: removed the key homes in $2/keys, 3 homes, " "$1" && test ! -e "$2/keys"' _ "$scratch/out" "$s"
  check "[C99] and leaves those of the workplace that the plan names" test -s "$other/keys/01/key"
  cp -- "$scratch/plan-kept.json" "$clone/PLAN/plan.json"
  check "build again" exit_is 0 wp build
  rm -rf -- "$clone/BUILD"
  mv -- "$clone/PLAN" "$scratch/PLAN"
  check "[C99] with neither BUILD nor PLAN, unbuild finds them by the name the clone gives" exit_is 0 wp unbuild
  check "[C99] naming them" said "unbuild: removed the key homes in $s/keys, 3 homes, "
  check "[C99] and no file stands beneath S/keys" test ! -e "$s/keys"
  check "[C99] a further unbuild finds no key home, and says so" exit_is 0 wp unbuild
  check "[C99] saying so" said "unbuild: no key home stands in $s/keys"
  mv -- "$scratch/PLAN" "$clone/PLAN"
}

t_records_by_day() {
  local fake=$scratch/fake-date d
  mkdir -p -- "$fake"
  printf '%s\n' '#!/usr/bin/env bash' "if [[ \$# == 2 && \$1 == -u && \$2 == +%F ]]; then echo 2030-01-01; else exec '$(command -v date)' \"\$@\"; fi" > "$fake/date"
  chmod +x -- "$fake/date"
  scoped_clone
  mkdir -p -- "$root/records"
  statements_plan "$records_terms"
  check "plan" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "up, the keepers' day being 2030-01-01" exit_is 0 env PATH="$fake:$PATH" "$BASH" "$loop" up
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  check "down" exit_is 0 env PATH="$fake:$PATH" "$BASH" "$loop" down
  d=$(record_of keeper)
  check "keeper's record holds the day 2030-01-01, and the file sink holds entries for it, all sent today" \
    bash -c 'test -s "$1/2030-01-01.pane" && [[ $(jq -r "select(.file == \"Harbor Keeper/2030-01-01.pane\") | .at[0:10]" "$2" | sort -u) == "$3" ]]' _ "$d" "$(state_of)/records/chain" "$(date -u +%F)"
  check "[C75] record verify takes from the file sink only the entries sent within the file's day and ten minutes on either side: a file of 2030-01-01 whose entries were all sent today finds none of them" \
    exit_is 0 wp record verify "Harbor Keeper" 2030-01-01
  check "[C75] and says that no entry covers it" said "Harbor Keeper/2030-01-01.pane: no entry of the chain covers it yet; it holds $(stat -c %s "$d/2030-01-01.pane") bytes"
  check "[C75] a day that is not a date is refused, with exit 2" exit_is 2 wp record verify "Harbor Keeper" 2030-02-30
  check "[C75] naming it" said "the day 2030-02-30 is not written YYYY-MM-DD, and is not unstored, gaps or signed"
  check "[C75] --requests is refused where the workplace holds no mail, with exit 2" exit_is 2 wp record verify --requests
  check "[C75] naming it" said "this workplace holds no mail, so it keeps no record of requests"
  local clock=$scratch/fake-clock sent when n=0 states round
  mkdir -p -- "$clock"
  printf '%s\n' '#!/usr/bin/env bash' \
    "if [[ \$# == 2 && \$1 == -u && \$2 == +%F ]]; then echo 2030-01-01; elif [[ \$# == 2 && \$1 == -u && \$2 == +%Y-%m-%dT%H:%M:%SZ ]]; then cat '$scratch/sent-at'; else exec '$(command -v date)' \"\$@\"; fi" > "$clock/date"
  chmod +x -- "$clock/date"
  for round in "2030-01-02T00:10:00Z|ten minutes after the day's end|taken" "2030-01-02T00:10:01Z|ten minutes and a second after the day's end|not taken" \
               "2029-12-31T23:50:00Z|ten minutes before the day's start|taken" "2029-12-31T23:49:59Z|ten minutes and a second before the day's start|not taken"; do
    n=$(( n + 1 ))
    IFS='|' read -r sent when round <<< "$round"
    states=$scratch/state-margin-$n
    printf '%s\n' "$sent" > "$scratch/sent-at"
    rm -rf -- "$clone/BUILD"
    check "build, with a state directory of its own" exit_is 0 env XDG_STATE_HOME="$states" "$BASH" "$loop" build
    check "up, the keepers' day being 2030-01-01 and the carrier's clock $sent" exit_is 0 env XDG_STATE_HOME="$states" PATH="$clock:$PATH" "$BASH" "$loop" up
    check "keeper ran" wait_for_probe "Harbor Keeper" keeper
    check "down" exit_is 0 env XDG_STATE_HOME="$states" PATH="$clock:$PATH" "$BASH" "$loop" down
    check "the file sink holds entries for keeper's file of 2030-01-01, each sent at $sent" \
      bash -c '[[ $(jq -r "select(.file == \"Harbor Keeper/2030-01-01.pane\") | .at" "$1" | sort -u) == "$2" ]]' _ "$states/workplace/$label/records/chain" "$sent"
    check "record verify" exit_is 0 env XDG_STATE_HOME="$states" "$BASH" "$loop" record verify "Harbor Keeper" 2030-01-01
    if [[ $round == taken ]]; then
      check "[C75] an entry sent $when is taken: the file agrees with its chain" said "Harbor Keeper/2030-01-01.pane agrees with its chain up to byte"
    else
      check "[C75] an entry sent $when is not taken: no entry covers the file" said "Harbor Keeper/2030-01-01.pane: no entry of the chain covers it yet"
    fi
  done
  rm -rf -- "$clone/BUILD"
  if ! systemctl --user show-environment > /dev/null 2>&1; then
    skip "[C75] no user manager answers here, so the journal's span of a day is tried where one answers"
    return 0
  fi
  local unit=workplace-carrier-$label.service
  rm -rf -- "$clone/BUILD"
  statements_plan "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record-chain") | .term[1]) = "journal"'
  check "plan, the chain going to the journal" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "up, the keepers' day being 2030-01-01" exit_is 0 env PATH="$fake:$PATH" "$BASH" "$loop" up
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  check "down" exit_is 0 env PATH="$fake:$PATH" "$BASH" "$loop" down
  check "the journal holds entries of the carrier's unit for keeper's file of 2030-01-01, sent today" \
    bash -c '(( $(journalctl --user _SYSTEMD_USER_UNIT="$1" -o cat --no-pager | grep -cF "\"Harbor Keeper/2030-01-01.pane\"") > 0 ))' _ "$unit"
  check "[C75] record verify asks the journal for the file's day and ten minutes on either side alone, and finds none of them" \
    exit_is 0 wp record verify "Harbor Keeper" 2030-01-01
  check "[C75] and says that no entry covers it" said "Harbor Keeper/2030-01-01.pane: no entry of the chain covers it yet; it holds $(stat -c %s "$d/2030-01-01.pane") bytes"
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
  t_a_server_that_ends_before_its_check
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
  t_why_says_what_the_nearest_row_means
  t_doctor
  t_the_reference_plan_as_printed
  t_plan_assembles
  t_plan_refusals
  t_the_fold
  t_plan_relative
  t_floors
  t_floors_assembly
  t_the_folded_view_in_the_panes
  t_plan_end_to_end
  t_identity_selection
  t_identity
  t_ssh_grants_fold
  t_ssh_key_refusals
  t_ssh_grants
  t_home_and_values_selection
  t_homes
  t_values
  t_the_clone_is_masked
  t_a_server_belongs_to_one_clone
  t_no_seat_reaches_a_tmux_server
  t_keys_and_names
  t_comms_fold
  t_comms_store
  t_comms_carrier
  t_comms_mail
  t_comms_from_a_pane
  t_wake_fold
  t_wake
  t_typing_apart
  t_records_fold
  t_records_in_panes
  t_records_day_and_limit
  t_records_keys_that_tmux_expands
  t_records_verify
  t_records_journal
  t_records_by_day
  t_restart
  t_unbuild_keys
  t_the_runtime_directory
  t_source_and_contract
)
(( $# )) && tests=("$@")

for name in "${tests[@]}"; do
  note "== $name"
  (
    test_failed=0
    label2=""
    trap 'cleanup || exit 1' EXIT
    setup "${name#t_}"
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
