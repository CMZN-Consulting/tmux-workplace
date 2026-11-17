#!/usr/bin/env bash
export LC_ALL=C
set -o nounset -o pipefail
unset TMUX TMUX_PANE XDG_STATE_HOME

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

T() { setpriv --no-new-privs tmux -S "${tsock:-$run/$label}" -u "$@"; }
# On the floor F the helpers built on T reach that floor's own server, RUN/F/NAME, and no other (5.160 point 8).
on() {
  local tsock=$run/$1/$label
  if [[ -f $run/$1/state.json ]]; then
    tsock=$(jq -r --arg fallback "$tsock" '.slots[(["socket-path"] | tojson)] // $fallback' "$run/$1/state.json")
  fi
  shift
  "$@"
}
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
  mkdir -p -- "$HOME"
  mkdir -m 0700 -- "$TMUX_TMPDIR"
  local socket_base
  socket_base=$(cd -P -- "$TMUX_TMPDIR" && pwd -P) || return 1
  [[ $socket_base != /tmp && $socket_base/tmux-$EUID/default != /tmp/tmux-$EUID/* ]] \
    || { fail "the test would reach the machine's tmux socket directory"; return 1; }
  [[ $(stat -c %a -- "$TMUX_TMPDIR") == 700 ]] \
    || { fail "the test's TMUX_TMPDIR is not private"; return 1; }
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
  for home in "$scratch"/home/.local/state/workplace/*/keys/* "$scratch"/home/.local/state/workplace/*/floors/*/keys/* \
    "$scratch"/state-*/workplace/*/keys/* "$scratch"/verify; do
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

# A directory that a test shuts, at mode 000, is named in the scratch's list before it is shut, and cleanup opens each
# again, the last shut first, before it removes the scratch, whatever path the test ends by; the test opens it again
# itself once its checks are done.
shut() { printf '%s\0' "$1" >> "$scratch/shut-directories" && chmod 000 -- "$1"; }
reopen() { chmod 0700 -- "$1"; }
reopen_shut() {
  local i
  local -a shut=()
  [[ -f $scratch/shut-directories ]] || return 0
  mapfile -d '' -t shut < "$scratch/shut-directories"
  for (( i = ${#shut[@]} - 1; i >= 0; i-- )); do chmod 0700 -- "${shut[i]}" 2> /dev/null; done
  return 0
}

cleanup() {
  local home status=0 unit pid cwd
  [[ -n ${scratch-} && -d $scratch ]] || return 0
  if command -v gpgconf > /dev/null; then
    while IFS= read -r home; do
      agent_of "$home" && gpgconf --homedir "$home" --kill gpg-agent > /dev/null 2>&1
      gpgconf --homedir "$home" --remove-socketdir > /dev/null 2>&1
    done < <(key_homes)
  fi
  [[ -n ${label-} && -S ${run-}/$label ]] && tmux -S "$run/$label" kill-server 2> /dev/null
  if [[ -n ${label-} && -d ${run-} ]]; then
    for home in "$run"/*/"$label"; do
      [[ -S $home ]] && tmux -S "$home" kill-server 2> /dev/null
    done
  fi
  if [[ -n ${label-} ]] && command -v systemctl > /dev/null; then
    while IFS= read -r unit; do
      pid=$(systemctl --user show -p MainPID --value "$unit" 2>/dev/null)
      [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
      cwd=$(readlink -- "/proc/$pid/cwd" 2>/dev/null) || continue
      [[ $cwd == "$scratch"/* ]] || continue
      timeout 30 systemctl --user stop -- "$unit" >/dev/null 2>&1
    done < <(systemctl --user list-units --all --no-pager --output=json -- \
      "workplace-carrier-$label.service" "workplace-carrier-$label-*.service" 2>/dev/null | jq -r '.[].unit')
  fi
  [[ -n ${label2-} && -S ${root-}/config2/BUILD/RUN/$label2 ]] && tmux -S "$root/config2/BUILD/RUN/$label2" kill-server 2> /dev/null
  if [[ ${TMUX_TMPDIR-} == "$scratch"/* ]]; then
    for home in "$TMUX_TMPDIR/tmux-$UID"/*; do
      [[ -S $home ]] && tmux -S "$home" kill-server 2> /dev/null
    done
  fi
  end_processes_naming "$scratch" || status=1
  reopen_shut
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
  make_plan '.programs[1].path = "harbor/dock/seat\u0085.typify"'
  check "[C3] 5.159 point 6: nor one with a control character of C1, NEL, in any string" exit_is 1 wp build
  check "[C3] naming it as the fold names it" said "the plan holds a control character"
  make_plan '.state["seat\u009fkinds"] = []'
  check "[C3] nor one with U+009F in a member's name" exit_is 1 wp build
  make_plan '.programs[1].path = "harbor/dock/seat\u00a0.typify"'
  check "[C3] while a plan with U+00A0, which is no control character, builds" exit_is 0 wp build
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
  rm -rf -- "$clone/BUILD"
  check "[C2] the fixture builds again" exit_is 0 wp build
  chmod u+w -- "$clone/BUILD/MANIFEST"
  sed -i '1a\\' "$clone/BUILD/MANIFEST"
  check "[C5] review of 4a: status refuses a MANIFEST with an empty line, as before floors, with exit 1" exit_is 1 wp status
  check "[C5] naming it" said "MANIFEST holds a line that is not a hash and a name"
  rm -rf -- "$clone/BUILD"
  check "[C2] the fixture builds again" exit_is 0 wp build
  chmod u+w -- "$clone/BUILD/MANIFEST"
  printf 'x\0y\n' >> "$clone/BUILD/MANIFEST"
  check "[C5] review of 4a: status refuses a MANIFEST that holds a NUL byte, with exit 1" exit_is 1 wp status
  check "[C5] naming it" said "MANIFEST holds a NUL byte"
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
    test "$(jq -r '.[index("-u") + 1]' "$run/calls.jsonl" | tr '\n' ' ')" = \
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
  check "[C8] the server's term still came first" test "$(jq -r '.[index("-u") + 1]' "$run/calls.jsonl" | head -1)" = start-server
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
  mkdir -m 0700 -- "$TMUX_TMPDIR"
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
  check "[C6] [C31] 5.177: the plan with views does not build without readlink, with which the rule on closed names reads the rows' real paths, with exit 1" \
    exit_is 1 env PATH="$bin" "$BASH" "$loop" build
  check "[C6] [C31] 5.177: naming readlink" said "the rule on closed names reads the rows' real paths with readlink and stat, and readlink is not on PATH"
  rm -rf -- "$clone/BUILD"
  ln -s -- "$(command -v readlink)" "$bin/readlink"
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
gone_pid() { [[ ! -e /proc/$1 || $(awk '/^State:/ { print $2 }' "/proc/$1/status" 2> /dev/null) == Z ]]; }
left_without_server() { [[ $1 =~ ^[1-9][0-9]*$ ]] && gone_pid "$1" && [[ ! -e $2 ]]; }
# The fixture's servers are ended while its BUILD stands, since their sockets lie in BUILD/RUN, and their argvs name
# the fixture and not the scratch, which cleanup's sweep reads. Each server's pid is read from the server itself.
end_reference_servers() {
  local sock pid i
  for sock in "$reference_root/config/BUILD/RUN"/* "$reference_root/config/BUILD/RUN"/*/*; do
    [[ -S $sock ]] || continue
    pid=""
    { read -r pid < <(tmux -S "$sock" list-sessions -F '#{pid}'); } 2> /dev/null
    tmux -S "$sock" kill-server 2> /dev/null
    [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
    for (( i = 0; i < 100; i++ )); do
      gone_pid "$pid" && break
      sleep 0.05
    done
    gone_pid "$pid" || kill -KILL "$pid" 2> /dev/null
  done
}
leave_reference() {
  [[ -n ${reference_root-} && -n ${reference_paths-} ]] || return 0
  end_reference_servers
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
  check "[C29] the fold's version names the rules it follows" test "$(jq -r .derivations.fold "$manifest")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-5.131-5.132-5.141-5.146-5.153-5.162-v18
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
  # The real reader names a file of the tree relative to the tree (5.168, measured by the DA with the reader at 4bb7584).
  printf '%s' '{"diagnostics":[{"code":"E_LINE_SHAPE","severity":"error","file":"ROOT.typify","range":{"start":{"line":3,"column":1},"end":{"line":3,"column":3}},"message":"The line has none of the three shapes"},
    {"code":"E_PROGRAM","severity":"error","file":"programs/policy.typify","range":{"start":{"line":1,"column":1},"end":{"line":1,"column":3}},"message":"program words"}],"status":"failed"}' \
    > "$STUB_DIR/plan-diagnostics.json"
  check "[C28] 5.168: a program's error stops plan with exit 1 where the reader names the file relative to the tree" exit_is 1 wplan
  check "[C28] 5.168: an error in the root program is shown as the generated program's where the reader names it relative to the tree, as the real reader does" \
    said "the generated root program, line 3: error E_LINE_SHAPE: The line has none of the three shapes"
  check "[C28] 5.168: and not by the reader's name for it" bash -c '! grep -qF -- "$1" "$2"' _ "ROOT.typify:3:" "$scratch/out"
  check "[C28] 5.168: a program's so named at its path in the clone" said "programs/policy.typify:1: error E_PROGRAM: program words"
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
  statements_plan '.programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "123456789012344"; 9), lb($root + "/harbor/vault/open"; "123456789012345"; 10), sc(12)]'
  check "[C31] a clearance and a label of 15 digits are taken" exit_is 0 wplan
  check "[C30] and compared exactly: a room at 123456789012344 is cleared for a label at 123456789012345" \
    bash -c '[[ $1 == *"/harbor/vault/open read-only,"* ]]' _ "$(rows_of keeper)"
  statements_plan '.programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "123456789012345"; 9), lb($root + "/harbor/vault/open"; "123456789012344"; 10), sc(12)]'
  check "[C31] the same with the last digits the other way round is taken" exit_is 0 wplan
  check "[C30] and a room at 123456789012345 is not cleared for a label at 123456789012344, so beneath a searchable-only row it gets no row" \
    bash -c '[[ $1 != *"/harbor/vault/open "* ]]' _ "$(rows_of keeper)"

  statements_plan '.programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "3"; 9),
      lb($root + "/harbor/vault/open"; "5"; 10), lb($root + "/harbor/vault/open/inner"; "1"; 11), sc(12)]'
  check "[C30] 5.129 point 2: a label the room is not cleared for, beneath a label's read-only row beneath a searchable-only row, folds" exit_is 0 wplan
  check "[C30] 5.129 point 2: it is read against the label's row, the nearest of any source, and makes a hidden row" \
    bash -c '[[ $1 == *"/harbor/vault/open read-only,"*"/harbor/vault/open/inner hidden,"* ]]' _ "$(rows_of keeper)"
  check "[C31] 5.129 point 2: and no label is refused for lying beneath a row with no row of its own" \
    bash -c '! grep -qF "with no row of its own" "$1"' _ "$scratch/out"
  local fold
  rm -rf -- "$scratch/loose" && mkdir -- "$scratch/loose" && cp -R -- "$tool/." "$scratch/loose/"
  fold=$(< "$scratch/loose/libexec/fold.jq")
  printf '%s\n' "${fold/'                     | .rows[[.rows | keys[] | select(beneath($l.path; .))] | max_by(depth)].value[0] as $above'/'                     | $stated as $above'}" > "$scratch/loose/libexec/fold.jq"
  check "a copy of the loop whose label step reads its second question against the nearest row that a statement made, as 4f18438 did" \
    bash -c '! cmp -s "$1" "$2"' _ "$tool/libexec/fold.jq" "$scratch/loose/libexec/fold.jq"
  check "[C31] 5.131 point 3: F9 refuses what that copy's label step leaves, with exit 1" exit_is 1 loose_wplan
  check "[C31] with F9's line: the label beneath another label's read-only row, with no row of its own, and the clearance that does not reach it" \
    said "workplace: the fold refuses: seat Harbor Keeper (harbor/dock/keeper): $root/harbor/vault/open/inner, labelled 1 (from programs/policy.typify:11), lies beneath $root/harbor/vault/open (read-only, from programs/policy.typify:10) with no row of its own, and the seat's clearance 3 does not reach 1"
  rm -rf -- "$scratch/loose"
  statements_plan '.programs[-1].recorded += [st("harbor"; "-"; "-"; "floor"; $root + "/harbor"; "hidden"; 9)]'
  check "[C103] 5.131: in a plan without floors, a term at a floor's scope that names an office refuses the plan, with exit 1" exit_is 1 wplan
  check "[C103] as naming an office, F2, and not as a floor the plan does not make" \
    said "programs/policy.typify:9: the statement names the floor harbor, and harbor is an office (5.125 point 1)"

  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 10)]'
  check "plan with a closed root" exit_is 0 wplan
  check "[C32] the directories beneath it that no row names are listed as held by nobody" \
    bash -c 'grep -qxF "held by nobody, a report and no part of the plan:" "$2" && grep -qxF "  $1/orchard/cellar" "$2" && grep -qxF "  $1/orchard/crate-picker" "$2"' _ "$root" "$scratch/out"
  check "[C32] and not one that a row names" bash -c '! grep -qxF "  $1/orchard/almanac" "$2"' _ "$root" "$scratch/out"
  mkdir -p -- "$root/orchard/cellar/casks"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 10),
                                              st("orchard"; "-"; "-"; "office"; $root + "/orchard/cellar"; "hidden"; 11),
                                              lb($root + "/orchard/cellar"; "closed"; 12), sc(13)]'
  check "plan with a closed path that an office's statement names, beneath the closed root" exit_is 0 wplan
  check "[C32] 5.149: the listing does not go beneath the closed path, and names nothing at or beneath it" \
    bash -c 'grep -qxF "held by nobody, a report and no part of the plan:" "$2" && ! grep -qF "  $1/orchard/cellar" "$2"' _ "$root" "$scratch/out"
  check "[C32] and names what no row names beside it" bash -c 'grep -qxF "  $1/orchard/crate-picker" "$2"' _ "$root" "$scratch/out"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 10),
                                              st("orchard"; "-"; "-"; "office"; $root + "/orchard/cellar"; "hidden"; 11),
                                              lb("orchard/cellar"; "closed"; 12), sc(13)]'
  check "plan with the same closed path, its label written relative to the root, as the house writes its four (C4)" exit_is 0 wplan
  check "[C32] 5.153: the listing goes beneath no closed path however its label is written, and names nothing at or beneath it" \
    bash -c 'grep -qxF "held by nobody, a report and no part of the plan:" "$2" && ! grep -qF "  $1/orchard/cellar" "$2" && grep -qxF "  $1/orchard/crate-picker" "$2"' _ "$root" "$scratch/out"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 10),
                                              lb("orchard/cellar"; "closed"; 12), sc(13)]'
  check "plan with a closed path that no row names, beneath a searchable-only row, its label written relative to the root" exit_is 0 wplan
  check "[C32] 5.153: the listing does not name the closed path itself, which its label covers, nor anything beneath it, where no seat holds it" \
    bash -c 'grep -qxF "held by nobody, a report and no part of the plan:" "$2" && ! grep -qF "  $1/orchard/cellar" "$2" && grep -qxF "  $1/orchard/crate-picker" "$2"' _ "$root" "$scratch/out"
  ln -s -- orchard "$root/grove"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 10),
                                              lb("grove/cellar"; "closed"; 12), sc(13)]'
  check "plan with a closed label written through a link to the directory the listing walks" exit_is 0 wplan
  check "[C32] 5.153: the listing names no closed directory under another path's name" \
    bash -c 'grep -qxF "held by nobody, a report and no part of the plan:" "$2" && ! grep -qF "  $1/orchard/cellar" "$2" && grep -qxF "  $1/orchard/crate-picker" "$2"' _ "$root" "$scratch/out"
  rm -f -- "$root/grove"
  mkdir -p -- "$root/orchard/cel"$'\n'"lar"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 10),
                                              lb("orchard/cellar"; "closed"; 11), lb("orchard/cel\nlar"; "closed"; 12), sc(13)]'
  check "plan with a closed label whose path holds a newline" exit_is 0 wplan
  check "[C32] 5.153: the listing reads the closed paths whole, and names no part of that one" \
    bash -c 'grep -qxF "  $1/orchard/crate-picker" "$2" && ! grep -qF "  $1/orchard/cel" "$2" && ! grep -qx "lar" "$2"' _ "$root" "$scratch/out"
  rm -rf -- "$root/orchard/cel"$'\n'"lar"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9),
                                              st("-"; "-"; "-"; "workplace"; $root + "/orchard/cellar"; "searchable-only"; 10),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 11)]'
  check "plan with a searchable-only row beneath another" exit_is 0 wplan
  check "[C32] 5.160 point 9: the listing names a directory once, however many searchable-only rows lie above it" \
    test "$(grep -cxF "  $root/orchard/cellar/casks" "$scratch/out")" = 1
  ln -s -- orchard "$root/grove"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/grove"; "searchable-only"; 9),
                                              st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 10),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 11)]'
  check "plan with searchable-only rows on a directory and on a link to it" exit_is 0 wplan
  check "[C32] 5.160 point 9: the listing names a directory once whatever names lead to it, by its physical path" \
    bash -c '[[ $(grep -cxF "  $1/orchard/crate-picker" "$2") == 1 ]] && ! grep -qF "/grove/" "$2"' _ "$root" "$scratch/out"
  check "[C32] and a directory that a row holds under one name is held under every name" bash -c '! grep -qF "almanac" "$1"' _ "$scratch/out"
  rm -f -- "$root/grove"
  ln -s -- orchard/cellar "$root/calias"
  ln -s -- . "$root/zz"
  ln -s -- orchard "$root/aa"
  local closed_base='st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9), lb($root + "/orchard/cellar"; "closed"; 11), sc(12)'
  statements_plan '.programs[-1].recorded += ['"$closed_base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/calias"; "read-only"; 10)]'
  check "plan with a read-only row written through a link to a closed directory, which the fold reads as written" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] 5.159 point 6: build refuses a row whose physical path is at or beneath a closed directory's, with exit 1" exit_is 1 wp build
  check "[C31] naming the row, its physical path and the label" \
    said "its row $root/calias (read-only, from programs/policy.typify:10) is the directory $root/orchard/cellar, at or beneath $root/orchard/cellar, closed by the label at programs/policy.typify:11 as $root/orchard/cellar"
  statements_plan '.programs[-1].recorded += ['"$closed_base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/zz/orchard"; "read-only"; 10)]'
  check "plan with a read-only row that holds the closed directory under another name and sorts after it" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] 5.162 point 6: build refuses a read-only row that holds a closed directory under another name, with exit 1" exit_is 1 wp build
  check "[C31] saying where it would show it, with nothing over it" \
    said "its row $root/zz/orchard (read-only, from programs/policy.typify:10) is the directory $root/orchard, which holds $root/orchard/cellar, closed by the label at programs/policy.typify:11 as $root/orchard/cellar, and would show it at $root/zz/orchard/cellar, where no hidden, scratch or searchable-only row of the view, nor a mask, lies over it"
  statements_plan '.programs[-1].recorded += ['"$closed_base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/aa"; "read-only"; 10)]'
  check "plan with a read-only row that holds the closed directory under another name and sorts before it" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] review of 4a: build refuses it too, since the label lies beneath a searchable-only row and has no tmpfs of its own: that row's tmpfs lies at $root/orchard, and the bind shows the directory at $root/aa/cellar" exit_is 1 wp build
  check "[C31] naming that path" said "and would show it at $root/aa/cellar, where no hidden, scratch or searchable-only row of the view, nor a mask, lies over it"
  statements_plan '.programs[-1].recorded += ['"$closed_base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/aa"; "read-only"; 10),
                                                st("orchard"; "barn"; "grower"; "seat"; $root + "/aa/cellar"; "hidden"; 13), st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard"; "read-only"; 14)]'
  check "plan with that row and a hidden row at the path where it would show the closed directory" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] builds, since the hidden row lies over that path and is mounted after the bind" exit_is 0 wp build
  # A scratch row at the closed directory itself is refused (only a hidden row stands at or beneath one), so the cover
  # is shown one level up: a label on cellar/casks, and a scratch row at aa/cellar, beneath the read-write row.
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9), lb($root + "/orchard/cellar/casks"; "closed"; 11), sc(12),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/aa"; "read-write"; 10),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/aa/cellar"; "scratch"; 13), st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard"; "read-write"; 14)]'
  check "plan with a read-write row through a link to orchard and a scratch row above the closed casks" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] review of 4a: builds, since a scratch row lies over the path where the bind would show the casks, as a hidden one does" exit_is 0 wp build
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9), lb($root + "/orchard/cellar/casks"; "closed"; 11), sc(12),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/aa"; "read-write"; 10)]'
  check "plan with that read-write row alone" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] review of 4a: build refuses it without the scratch row, with exit 1" exit_is 1 wp build
  check "[C31] naming the casks and where they would show" said "which holds $root/orchard/cellar/casks, closed by the label at programs/policy.typify:11 as $root/orchard/cellar/casks, and would show it at $root/aa/cellar/casks"
  statements_plan '.programs[-1].recorded += ['"$closed_base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/aa"; "read-write"; 10)]'
  check "plan with the read-write row alone" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] review of 4a: build refuses a read-write row that would show the closed directory, as it refuses a read-only one, with exit 1" exit_is 1 wp build
  statements_plan '.programs[-1].recorded += ['"$closed_base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard"; "read-only"; 10)]'
  check "plan with a read-only row at the closed directory's parent, written by its physical path" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] builds, since the label's own hidden row lies at the closed directory's path beneath it" exit_is 0 wp build
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9), lb($root + "/zz/orchard/cellar"; "closed"; 11), sc(12)]'
  check "plan with a closed label written through a link before its last part" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] review of 4a: build refuses a closed label written through a link, with exit 1" exit_is 1 wp build
  check "[C31] naming its physical path" said "programs/policy.typify:11: the label of closed names $root/zz/orchard/cellar, which is written through a link to $root/orchard/cellar"
  ln -s -- config "$root/cfglink"
  ln -s -- . "$root/up"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/cfglink"; "read-only"; 10)]'
  check "plan with a read-only row written through a link to the clone" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] the addendum's 2(3): build refuses a row that shows the clone under another name, with exit 1" exit_is 1 wp build
  check "[C31] naming the frame's mask" said "its row $root/cfglink (read-only, from programs/policy.typify:10) is the directory $clone, at or beneath $clone, the clone, which every view masks (C52)"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/up"; "read-only"; 10)]'
  check "plan with a read-only row written through a link to the clone's parent" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] the addendum's 2(3): build refuses a row that would show the clone where its mask does not lie, with exit 1" exit_is 1 wp build
  check "[C31] naming where" said "and would show it at $root/up/config, where no hidden, scratch or searchable-only row of the view, nor a mask, lies over it"
  rm -f -- "$root/cfglink" "$root/up"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9), lb($root + "/calias"; "closed"; 11), sc(12)]'
  check "plan with a closed label whose last part is a link" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] 5.162 point 6: build refuses a closed label whose last part is a link, with exit 1" exit_is 1 wp build
  check "[C31] since bubblewrap mounts nothing on a link" said "programs/policy.typify:11: the label of closed names $root/calias, whose last part is a link, and bubblewrap mounts nothing on a link (5.162 point 6)"
  rm -rf -- "$clone/BUILD"
  rm -f -- "$root/calias" "$root/zz" "$root/aa"
  statements_plan '.programs[-1].recorded += [st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard/almanac"; "read-only"; 10),
                                              st("orchard"; "-"; "-"; "office"; $root + "/orchard/cellar"; "hidden"; 11), sc(13)]'
  check "plan with the same statement and no closed label" exit_is 0 wplan
  check "[C32] the listing goes beneath that path, which is not closed" bash -c 'grep -qxF "  $1/orchard/cellar/casks" "$2"' _ "$root" "$scratch/out"
  rm -rf -- "$root/orchard/cellar/casks"
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

# The rule on closed names at build, guard by guard (5.176 points 7 and 11). The plans are t_the_fold's: a closed
# label on orchard/cellar beneath a searchable-only orchard, and one row of a seat's own written through a link.
t_closed_names() {
  scoped_clone
  local base='st("-"; "-"; "-"; "workplace"; $root + "/orchard"; "searchable-only"; 9), lb($root + "/orchard/cellar"; "closed"; 11), sc(12)'
  local grower="seat Orchard Grower (orchard/barn/grower)" by="closed by the label at programs/policy.typify:11 as $root/orchard/cellar"
  local none="where no hidden, scratch or searchable-only row of the view, nor a mask, lies over it" state
  mkdir -p -- "$root/orchard/cellar/casks" "$root/p"
  ln -s -- orchard/cellar/secret "$root/flink"
  ln -s -- . "$root/zz"
  ln -s -- orchard/cellar "$root/calias"
  ln -s -- calias/secret "$root/flink2"
  ln -s -- orchard/cellar/casks "$root/clink"
  ln -s -- orchard "$root/aa"
  ln -s -- ../orchard "$root/p/aa"

  for state in read-only read-write; do
    statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/flink"; "'"$state"'"; 10)]'
    check "plan with a $state row whose last part is a link to a file beneath a closed label, which the fold reads as written" exit_is 0 wplan
    rm -rf -- "$clone/BUILD"
    check "[C31] follow-up of 4a: build refuses a $state row whose last part is a link to a file beneath a closed label, with exit 1" exit_is 1 wp build
    check "[C31] naming the seat, the $state row and the file it leads to, by its real path, at or beneath the closed directory" \
      said "$grower: its row $root/flink ($state, from programs/policy.typify:10) is the file $root/orchard/cellar/secret, at or beneath $root/orchard/cellar, $by"
  done
  statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/zz/flink"; "read-only"; 10)]'
  check "plan with a read-only row written through a link in the middle of its path, whose last part is a link to a file beneath a closed label" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] follow-up of 4a: build refuses a link to a file through a link in the middle of the row's path, with exit 1" exit_is 1 wp build
  check "[C31] naming the file it leads to" \
    said "$grower: its row $root/zz/flink (read-only, from programs/policy.typify:10) is the file $root/orchard/cellar/secret, at or beneath $root/orchard/cellar, $by"
  statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/flink2"; "read-only"; 10)]'
  check "plan with a read-only row whose last part is a link to a file through a link in the middle of the link's own target" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] follow-up of 4a: build refuses a link to a file through a link in the middle of its target, with exit 1" exit_is 1 wp build
  check "[C31] naming the file at the end of every link" \
    said "$grower: its row $root/flink2 (read-only, from programs/policy.typify:10) is the file $root/orchard/cellar/secret, at or beneath $root/orchard/cellar, $by"

  statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/clink"; "read-only"; 10)]'
  check "plan with a read-only row that is a link to orchard/cellar/casks, beneath the closed orchard/cellar" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] the addendum's own check: build refuses a link into a directory beneath a closed one, with exit 1" exit_is 1 wp build
  check "[C31] naming the directory it leads to" \
    said "$grower: its row $root/clink (read-only, from programs/policy.typify:10) is the directory $root/orchard/cellar/casks, at or beneath $root/orchard/cellar, $by"
  statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/calias/casks"; "read-only"; 10)]'
  check "plan with a read-only row strictly beneath the closed directory by its real path, written through a link in the middle" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] follow-up of 4a: build refuses a row strictly beneath a closed directory as it refuses one at it, with exit 1" exit_is 1 wp build
  check "[C31] with the refusal of a row at or beneath it" \
    said "$grower: its row $root/calias/casks (read-only, from programs/policy.typify:10) is the directory $root/orchard/cellar/casks, at or beneath $root/orchard/cellar, $by"

  statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/aa"; "read-only"; 10),
                                                st("orchard"; "barn"; "picker"; "seat"; $root + "/aa/cellar"; "hidden"; 13)]'
  check "plan with grower's read-only row through a link to orchard, and a hidden row where it would show the closed directory written for picker alone" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] follow-up of 4a: build refuses it, with exit 1: another seat's row lies over nothing in grower's view" exit_is 1 wp build
  check "[C31] naming grower's row and the place where it would show the closed directory" \
    said "$grower: its row $root/aa (read-only, from programs/policy.typify:10) is the directory $root/orchard, which holds $root/orchard/cellar, $by, and would show it at $root/aa/cellar, $none"
  statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/aa"; "read-only"; 10),
                                                st("orchard"; "barn"; "picker"; "seat"; $root + "/aa/cellar"; "hidden"; 13),
                                                st("orchard"; "barn"; "grower"; "seat"; $root + "/aa/cellar"; "hidden"; 14), st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard"; "read-only"; 15), st("orchard"; "barn"; "picker"; "seat"; $root + "/orchard"; "read-only"; 16), st("orchard"; "barn"; "picker"; "seat"; $root + "/aa"; "read-only"; 17)]'
  check "plan with the same hidden row written for grower too" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "builds, since grower's own hidden row lies over that place" exit_is 0 wp build

  # The fold refuses a row beneath a hidden row of the same seat, so the row above is searchable-only, which covers as a
  # hidden row does where it lies beneath the row.
  statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/p"; "searchable-only"; 13),
                                                st("orchard"; "barn"; "grower"; "seat"; $root + "/p/aa"; "read-only"; 10)]'
  check "plan with grower's read-only row through a link to orchard, beneath a searchable-only row of grower's own above it" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] follow-up of 4a: build refuses it, with exit 1: a row above the row is mounted before the row's bind, and lies over nothing that the bind shows" exit_is 1 wp build
  check "[C31] naming the place where it would show the closed directory" \
    said "$grower: its row $root/p/aa (read-only, from programs/policy.typify:10) is the directory $root/orchard, which holds $root/orchard/cellar, $by, and would show it at $root/p/aa/cellar, $none"

  ln -s -- config/programs "$root/cfgin"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/cfgin"; "read-only"; 10)]'
  check "plan with a read-only row that is a link into the clone" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] follow-up of 4a: build refuses a row that is a link into the clone, a mask of the frame's, with exit 1" exit_is 1 wp build
  check "[C31] naming the clone's mask" \
    said "$grower: its row $root/cfgin (read-only, from programs/policy.typify:10) is the directory $clone/programs, at or beneath $clone, the clone, which every view masks (C52)"
  local state_dir=$HOME/.local/state/workplace
  mkdir -p -- "$state_dir"
  ln -s -- "$state_dir" "$root/stlink"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/stlink"; "read-only"; 10)]'
  check "plan with a read-only row that is a link to the workplaces' state R" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] follow-up of 4a: build refuses a row that is a link to the state R, a mask of the frame's, with exit 1" exit_is 1 wp build
  check "[C31] naming R's mask" \
    said "$grower: its row $root/stlink (read-only, from programs/policy.typify:10) is the directory $state_dir, at or beneath $state_dir, the workplaces' state R, which every view masks (C39)"
  local sockets=$TMUX_TMPDIR/tmux-$EUID
  mkdir -p -m 0700 -- "$sockets"
  ln -s -- "$sockets" "$root/tlink"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/tlink"; "read-only"; 10)]'
  check "plan with a read-only row that is a link to the test's own tmux socket directory, under its TMUX_TMPDIR" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] follow-up of 4a: build refuses a row that is a link to the user's tmux socket directory, a mask of the frame's, with exit 1" exit_is 1 wp build
  check "[C31] naming the socket directory's mask" \
    said "$grower: its row $root/tlink (read-only, from programs/policy.typify:10) is the directory $sockets, at or beneath $sockets, the user's tmux socket directory, which every view masks (C68)"
  if [[ -d /var/log/journal && $(readlink -e -- /var/log/journal) == /var/log/journal ]]; then
    mkdir -p -- "$root/records"
    ln -s -- /var/log/journal "$root/jlink"
    statements_plan "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record-chain") | .term[1]) = "journal"
      | .programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/jlink"; "read-only"; 22)]'
    check "plan with a chain to the journal and a read-only row that is a link to /var/log/journal" exit_is 0 wplan
    rm -rf -- "$clone/BUILD"
    check "[C31] follow-up of 4a: build refuses a row that is a link to the journal's directory where a chain is kept, a mask of the frame's, with exit 1" exit_is 1 wp build
    check "[C31] naming the journal's mask" \
      said "$grower: its row $root/jlink (read-only, from programs/policy.typify:22) is the directory /var/log/journal, at or beneath /var/log/journal, the journal's directory, which a view masks where a chain is kept (C73)"
    statements_plan "$records_terms"' | .programs[-1].recorded |= map(select(.term[0] != "record-chain"))
      | .programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/jlink"; "read-only"; 22)]'
    check "plan with the same row and no chain" exit_is 0 wplan
    rm -rf -- "$clone/BUILD"
    check "[C31] follow-up of 4a: where no chain is kept the journal's directory is no mask, and build takes the same row" exit_is 0 wp build
  else
    skip "[C31] this machine has no /var/log/journal at that physical path, so a row that is a link to the journal's directory is not tried; tried where one stands"
  fi

  statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/aa"; "read-only"; 10),
                                                st("orchard"; "barn"; "grower"; "seat"; $root + "/aa/cellar"; "hidden"; 13), st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard"; "read-only"; 14)]'
  check "plan that the rule takes: grower's row through a link to orchard, and grower's hidden row where it would show the closed directory" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "build takes it" exit_is 0 wp build
  local real
  real=$(command -v jq)
  mkdir -p -- "$scratch/jq-plan" "$scratch/jq-view"
  printf '%s\n' '#!/usr/bin/env bash' \
    'for word in "$@"; do [[ $word == *".term[1], (.origin | at)"* ]] && { printf "%s\n" "the test fails this jq" >&2; exit 5; }; done' \
    "exec ${real@Q} \"\$@\"" > "$scratch/jq-plan/jq"
  # The views' jq fails after it has printed what it read, so that only its exit status tells the rule.
  printf '%s\n' '#!/usr/bin/env bash' \
    'for word in "$@"; do [[ $word == *".key[3], .value[0], "* ]] && { '"${real@Q}"' "$@"; printf "%s\n" "the test fails this jq" >&2; exit 5; }; done' \
    "exec ${real@Q} \"\$@\"" > "$scratch/jq-view/jq"
  chmod +x -- "$scratch/jq-plan/jq" "$scratch/jq-view/jq"
  rm -rf -- "$clone/BUILD"
  check "[C31] follow-up of 4a: where the rule cannot read the plan's labels of closed, build refuses the plan that it takes otherwise, with exit 1" \
    exit_is 1 env PATH="$scratch/jq-plan:$PATH" "$BASH" "$loop" build
  check "[C31] saying that it cannot read the plan's labels" said "workplace: cannot read the plan's labels of closed in $clone/PLAN/plan.json"
  rm -rf -- "$clone/BUILD"
  check "[C31] follow-up of 4a: where the rule cannot read the views, build refuses the plan that it takes otherwise, with exit 1" \
    exit_is 1 env PATH="$scratch/jq-view:$PATH" "$BASH" "$loop" build
  check "[C31] saying that it cannot read the views" said "workplace: cannot read the views in $clone/PLAN/view.json"
  rm -rf -- "$clone/BUILD"

  # A read that the rule cannot make is a refusal (5.177 point 6). A directory is resolved without being entered: a
  # row that is a link to a directory of mode 000 beneath the closed label is judged where the link leads.
  mkdir -p -- "$root/orchard/cellar/shut"
  ln -s -- orchard/cellar/shut "$root/shutlink"
  statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/shutlink"; "read-only"; 10)]'
  check "plan with a read-only row that is a link to orchard/cellar/shut, beneath the closed orchard/cellar, which the test then shuts" exit_is 0 wplan
  shut "$root/orchard/cellar/shut"
  rm -rf -- "$clone/BUILD"
  check "[C31] 5.177: build refuses a row that is a link to a directory of mode 000 beneath a closed label, with exit 1" exit_is 1 wp build
  check "[C31] 5.177: naming the row and the directory it leads to by its real path, read without entering it" \
    said "$grower: its row $root/shutlink (read-only, from programs/policy.typify:10) is the directory $root/orchard/cellar/shut, at or beneath $root/orchard/cellar, $by"
  reopen "$root/orchard/cellar/shut"
  # A closed label of mode 000 written through the link zz: its physical path is read without entering it.
  mkdir -p -- "$root/orchard/press"
  statements_plan '.programs[-1].recorded += [lb($root + "/zz/orchard/press"; "closed"; 11), sc(12)]'
  check "plan with a closed label written through the link zz, at orchard/press, which the test then shuts" exit_is 0 wplan
  shut "$root/orchard/press"
  rm -rf -- "$clone/BUILD"
  check "[C31] 5.177: build refuses a closed label of mode 000 written through a link, with exit 1" exit_is 1 wp build
  check "[C31] 5.177: naming the label and its physical path, read without entering it" \
    said "workplace: programs/policy.typify:11: the label of closed names $root/zz/orchard/press, which is written through a link to $root/orchard/press"
  reopen "$root/orchard/press"
  # A label and a mask of which the rule cannot tell whether they stand, since a directory on their way cannot be
  # searched: the label beneath the shut directory gate, and the tmux socket directory under a TMUX_TMPDIR beneath the
  # shut directory shutt, given to this build alone.
  mkdir -p -- "$root/gate/cask" "$scratch/shutt/t/tmux-$EUID"
  statements_plan '.programs[-1].recorded += [lb($root + "/gate/cask"; "closed"; 11), sc(12)]'
  check "plan with a closed label at gate/cask, whose directory gate the test then shuts" exit_is 0 wplan
  shut "$root/gate"
  shut "$scratch/shutt"
  rm -rf -- "$clone/BUILD"
  check "[C31] 5.177: build refuses a label and a mask of which the rule cannot tell whether they stand, with exit 1" \
    exit_is 1 env TMUX_TMPDIR="$scratch/shutt/t" "$BASH" "$loop" build
  check "[C31] 5.177: naming the label, where it once passed it over as one that does not exist" \
    said "workplace: programs/policy.typify:11: the label of closed names $root/gate/cask, of which the rule cannot tell whether it stands (Permission denied), and a read that the rule cannot make is a refusal (5.177 point 6)"
  check "[C31] 5.177: and naming the mask, where it once passed it over as one that does not stand" \
    said "workplace: the frame's mask $scratch/shutt/t/tmux-$EUID, the user's tmux socket directory, which every view masks (C68): the rule cannot tell whether it stands (Permission denied)"
  reopen "$scratch/shutt"
  reopen "$root/gate"
  # Where readlink cannot resolve what stands, the rule refuses: a readlink of the test's own fails on every path whose
  # last part begins with unreadable, for a label and a mask that cannot be entered and for a row.
  local real_readlink
  real_readlink=$(command -v readlink)
  mkdir -p -- "$scratch/readlink" "$root/unreadable-label" "$root/unreadable-row" "$scratch/unreadable-t/tmux-$EUID"
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ ${!#} == */unreadable* ]] && { printf "%s\n" "the test fails this readlink" >&2; exit 1; }' \
    "exec ${real_readlink@Q} \"\$@\"" > "$scratch/readlink/readlink"
  chmod +x -- "$scratch/readlink/readlink"
  statements_plan '.programs[-1].recorded += [lb($root + "/unreadable-label"; "closed"; 11), sc(12),
                                              st("orchard"; "barn"; "grower"; "seat"; $root + "/unreadable-row"; "read-only"; 10)]'
  check "plan with a closed label at unreadable-label and grower's read-only row unreadable-row" exit_is 0 wplan
  shut "$root/unreadable-label"
  shut "$scratch/unreadable-t/tmux-$EUID"
  rm -rf -- "$clone/BUILD"
  check "[C31] 5.177: where readlink cannot resolve a label, a mask and a row that stand, build refuses, with exit 1" \
    exit_is 1 env PATH="$scratch/readlink:$PATH" TMUX_TMPDIR="$scratch/unreadable-t" "$BASH" "$loop" build
  check "[C31] 5.177: naming the label whose physical path it cannot tell" \
    said "workplace: programs/policy.typify:11: the label of closed names $root/unreadable-label, whose physical path the rule cannot tell"
  check "[C31] 5.177: naming the mask whose physical path it cannot tell" \
    said "workplace: the frame's mask $scratch/unreadable-t/tmux-$EUID, the user's tmux socket directory, which every view masks (C68): the rule cannot tell its physical path"
  check "[C31] 5.177: naming the row whose real path it cannot tell" \
    said "workplace: $grower: its row $root/unreadable-row (read-only, from programs/policy.typify:10) stands, and the rule cannot tell its real path"
  reopen "$scratch/unreadable-t/tmux-$EUID"
  reopen "$root/unreadable-label"

  # The runtime directory is held under another name as the other masks are, and a row written at it or beneath it is
  # passed over as before (5.177 point 6). These plans are built alone and never brought up: under a fault of the rule
  # such an up would bind the session's runtime directory into a pane.
  local runtime=/run/user/$EUID rtphys
  if [[ -d $runtime ]]; then
    rtphys=$(cd -P -- "$runtime" && pwd -P)
    ln -s -- "$runtime" "$root/rtlink"
    statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/rtlink"; "read-only"; 10)]'
    check "plan with a read-only row that is a link to the runtime directory" exit_is 0 wplan
    rm -rf -- "$clone/BUILD"
    check "[C31] [C84] 5.177: build refuses a row that is a link to the runtime directory, held under another name as the other masks are, with exit 1" \
      exit_is 1 wp build
    check "[C31] [C84] 5.177: naming the runtime directory's mask" \
      said "$grower: its row $root/rtlink (read-only, from programs/policy.typify:10) is the directory $rtphys, at or beneath $rtphys, the runtime directory, which a view masks where its rows would show it (C84)"
    if [[ -S $runtime/bus ]]; then
      ln -s -- "$runtime/bus" "$root/buslink"
      statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/buslink"; "read-only"; 10)]'
      check "plan with a read-only row that is a link to the session's bus socket in the runtime directory" exit_is 0 wplan
      rm -rf -- "$clone/BUILD"
      check "[C31] [C84] 5.177: build refuses a row that is a link to a socket in the runtime directory, with exit 1" exit_is 1 wp build
      check "[C31] [C84] 5.177: naming the socket by its real path and the runtime directory's mask" \
        said "$grower: its row $root/buslink (read-only, from programs/policy.typify:10) is the file $rtphys/bus, at or beneath $rtphys, the runtime directory, which a view masks where its rows would show it (C84)"
    else
      skip "[C31] [C84] this machine has no session bus socket at $runtime/bus, so a row that is a link to it is not tried; tried where one stands"
    fi
    statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; "'"$runtime"'"; "searchable-only"; 10)]'
    check "plan with a searchable-only row written at the runtime directory itself" exit_is 0 wplan
    rm -rf -- "$clone/BUILD"
    check "[C31] [C84] 5.177: build takes a row written at the runtime directory, where its mask lies, as before" exit_is 0 wp build
    if [[ -d $runtime/systemd ]]; then
      statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; "'"$runtime"'/systemd"; "scratch"; 10)]'
      check "plan with a scratch row written beneath the runtime directory" exit_is 0 wplan
      rm -rf -- "$clone/BUILD"
      check "[C31] [C84] 5.177: build takes a row written beneath the runtime directory, where its mask lies, as before" exit_is 0 wp build
    else
      skip "[C31] [C84] this machine has no $runtime/systemd, so a row written beneath the runtime directory is not tried; tried where it stands"
    fi
  else
    skip "[C31] [C84] this machine has no runtime directory at $runtime, so rows that lead into it are not tried; tried where one stands"
  fi

  # The frame takes R by its physical path, as it takes the clone, so R's mask lies there whatever of a link a view
  # shows; a row is passed over only where it is written at that path or beneath it, and a row that reaches R by
  # another spelling, the link's among them, is refused (5.177 point 6). XDG_STATE_HOME is written through the link
  # xlink, given to these builds alone.
  mkdir -p -- "$scratch/xreal/workplace/sub"
  ln -s -- xreal "$scratch/xlink"
  local rmask="the workplaces' state R, which every view masks (C39)"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; "'"$scratch"'/xlink/workplace/sub"; "read-only"; 10)]'
  check "plan with a read-only row beneath R written through the link xlink, as XDG_STATE_HOME is written" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] [C39] 5.177: build refuses a row beneath R written through the link that XDG_STATE_HOME names, since R is taken by its physical path, with exit 1" \
    exit_is 1 env XDG_STATE_HOME="$scratch/xlink" "$BASH" "$loop" build
  check "[C31] [C39] 5.177: naming R's mask by its physical path" \
    said "$grower: its row $scratch/xlink/workplace/sub (read-only, from programs/policy.typify:10) is the directory $scratch/xreal/workplace/sub, at or beneath $scratch/xreal/workplace, $rmask"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; "'"$scratch"'/xreal/workplace/sub"; "read-only"; 10)]'
  check "plan with the same row written beneath R's physical path" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] [C39] 5.177: build takes a row written beneath R's physical path, where R's mask lies" \
    exit_is 0 env XDG_STATE_HOME="$scratch/xlink" "$BASH" "$loop" build
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; "'"$scratch"'/xlink"; "read-only"; 10)]'
  check "plan with a read-only row at the link xlink, which holds R" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] [C39] 5.177: build refuses a row that holds R under the link's name, where R's mask at its physical path does not lie, with exit 1" \
    exit_is 1 env XDG_STATE_HOME="$scratch/xlink" "$BASH" "$loop" build
  check "[C31] [C39] 5.177: naming the row and where it would show R" \
    said "$grower: its row $scratch/xlink (read-only, from programs/policy.typify:10) is the directory $scratch/xreal, which holds $scratch/xreal/workplace, $rmask, and would show it at $scratch/xlink/workplace"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; "'"$scratch"'/xreal"; "read-only"; 10)]'
  check "plan with the same row at R's physical parent" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] [C39] 5.177: build takes a row that holds R at its physical path, where R's mask lies over it, and each seat's read-only / with it" \
    exit_is 0 env XDG_STATE_HOME="$scratch/xlink" "$BASH" "$loop" build
  # The same for the tmux socket directory, with TMUX_TMPDIR written through the link tlink, given to these builds alone;
  # the directory is the test's own, made at mode 0700, and nothing is brought up.
  mkdir -p -m 0700 -- "$scratch/treal/tmux-$EUID/sub"
  ln -s -- treal "$scratch/tlink"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; "'"$scratch"'/tlink/tmux-'"$EUID"'/sub"; "read-only"; 10)]'
  check "plan with a read-only row beneath the tmux socket directory written through the link tlink, as TMUX_TMPDIR is written" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] [C68] 5.177: build refuses a row beneath the socket directory written through the link that TMUX_TMPDIR names, since that directory is taken by its physical path, with exit 1" \
    exit_is 1 env TMUX_TMPDIR="$scratch/tlink" "$BASH" "$loop" build
  check "[C31] [C68] 5.177: naming the socket directory's mask by its physical path" \
    said "$grower: its row $scratch/tlink/tmux-$EUID/sub (read-only, from programs/policy.typify:10) is the directory $scratch/treal/tmux-$EUID/sub, at or beneath $scratch/treal/tmux-$EUID, the user's tmux socket directory, which every view masks (C68)"

  # A read-only row whose real path is / holds every closed directory, and the rule refuses it (5.177 point 6).
  ln -s -- / "$root/rootlink"
  statements_plan '.programs[-1].recorded += ['"$base"', st("orchard"; "barn"; "grower"; "seat"; $root + "/rootlink"; "read-only"; 10)]'
  check "plan with a read-only row that is a link to /" exit_is 0 wplan
  rm -rf -- "$clone/BUILD"
  check "[C31] 5.177: build refuses a read-only row that is a link to /, with exit 1" exit_is 1 wp build
  check "[C31] 5.177: naming where it would show the closed label" \
    said "$grower: its row $root/rootlink (read-only, from programs/policy.typify:10) is the directory /, which holds $root/orchard/cellar, $by, and would show it at $root/rootlink$root/orchard/cellar, $none"
  check "[C31] 5.177: and where it would show the clone" \
    said "$grower: its row $root/rootlink (read-only, from programs/policy.typify:10) is the directory /, which holds $clone, the clone, which every view masks (C52), and would show it at $root/rootlink$clone, $none"
  rm -rf -- "$clone/BUILD"
}

t_closed_names_unfolded() {
  local grower="seat Orchard Grower (orchard/barn/grower)"
  # A plan with no fold term: its views are the plan's own view cell (C33), and the rule reads them as a pane gets them.
  local unfolded='.state.view += [{key: ["orchard", "barn", "grower", ($root + "/cfglink")], value: ["read-only"], masked: false,
    origin: {kind: "program", path: "orchard/barn/grower/seat.typify", line: 10}}]'
  ln -s -- config "$root/cfglink"
  rm -f -- "$clone/PLAN/view.json"
  make_plan --arg root "$root" "$unfolded"
  check "a plan with no fold term, whose view cell gives grower a read-only row that is a link to the clone" test ! -e "$clone/PLAN/view.json"
  check "[C31] [C33] follow-up of 4a: build refuses a plan with no fold term whose view cell holds a row that is a link to the clone, with exit 1" \
    exit_is 1 wp build
  check "[C31] naming the row and the clone's mask" \
    said "$grower: its row $root/cfglink (read-only, from orchard/barn/grower/seat.typify:10) is the directory $clone, at or beneath $clone, the clone, which every view masks (C52)"
  rm -rf -- "$clone/BUILD"
  mkdir -p -- "$root/orchard/unfolded"
  ln -sfn -- orchard/unfolded "$root/cfglink"
  make_plan --arg root "$root" "$unfolded"
  check "build of the same plan, made again with the link leading to a directory of its own" exit_is 0 wp build
  ln -sfn -- config "$root/cfglink"
  check "[C31] [C33] follow-up of 4a: the link swapped into the clone after the build makes up of the unfolded plan exit 1" exit_is 1 wp up
  check "[C31] naming the row and the clone's mask" \
    said "$grower: its row $root/cfglink (read-only, from orchard/barn/grower/seat.typify:10) is the directory $clone, at or beneath $clone, the clone, which every view masks (C52)"
  check "[C31] and up left no run directory" test ! -e "$clone/BUILD/RUN"
  check "[C31] and started no server" no_server
  rm -rf -- "$clone/BUILD"
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
    'C101|(.programs[0].plan) += [["floor", "orchard", "Orchard", "offices", "enforced", "run", $root + "/config/floors/deck.conf", "80x24"]] | (.programs[] | select(.path == "harbor/office.typify") | .plan) |= map(if .[0] == "session" then .[2] = "orchard" else . end)|the key orchard names a floor and an office (orchard/office.typify, term 1; orchard/office.typify, term 2; workplace.typify, term 5)'
    'C101|(.programs[0].plan) += [["floor", "attic", "Attic", "rooms", "enforced", "run", $root + "/config/floors/deck.conf", "80x24"]]|the floor attic holds no office and no room'
    'C101|(.programs[0].plan) += [["floor", "deck", "Deck", "offices", "enforced", "run", $root + "/config/floors/deck.conf", "80x24"]]|the floor deck is declared 2 times (workplace.typify, term 3; workplace.typify, term 5)'
    'C101|(.programs[0].plan) += [["window", "ghost", "w", "Ghost"]]|the window term for ghost has no session term (workplace.typify, term 5)'
    'C101|(.programs[0].plan) += [["window", "deck", "w", "W"]]|the window term for deck has no session term (workplace.typify, term 5)'
    'C101|.programs[-1].recorded += [cl("lodge"; "-"; "-"; "office"; "1"; 9), sc(20)]|programs/policy.typify:9: the clearance names the office lodge, and lodge is a floor (5.125 point 1)'
    'C103|.programs[-1].recorded += [{term: ["key", "harbor", "-", "-", "floor", "held"], origin: at(9)}]|programs/policy.typify:9: the key names the floor harbor, and harbor is an office (5.125 point 1)'
    'C103|.programs[-1].recorded += [st("nowhere"; "-"; "-"; "floor"; $root + "/tools"; "hidden"; 9)]|programs/policy.typify:9: the statement names the floor nowhere, which the plan does not make'
    'C101|.programs[-1].recorded += [{term: ["expect", "lodge", "-", "-", "office", "WPT_LODGE"], origin: at(9)}]|programs/policy.typify:9: the expect names the office lodge, and lodge is a floor (5.125 point 1)'
    'C103|.programs[-1].recorded += [{term: ["expect", "harbor", "-", "-", "floor", "WPT_HARBOR"], origin: at(9)}]|programs/policy.typify:9: the expect names the floor harbor, and harbor is an office (5.125 point 1)'
    'C101|.programs[-1].recorded += [{term: ["reach", "lodge", "-", "-", "office", "grab", "-", "-", "-", "workplace", "allowed"], origin: at(9)}]|programs/policy.typify:9: the reach names the office lodge, and lodge is a floor (5.125 point 1)'
    'C103|.programs[-1].recorded += [{term: ["reach", "harbor", "-", "-", "floor", "grab", "-", "-", "-", "workplace", "allowed"], origin: at(9)}]|programs/policy.typify:9: the reach names the floor harbor, and harbor is an office (5.125 point 1)'
    'C101|.programs[-1].recorded += [{term: ["reach", "-", "-", "-", "workplace", "grab", "lodge", "-", "-", "office", "allowed"], origin: at(9)}]|programs/policy.typify:9: the reach names the office lodge, and lodge is a floor (5.125 point 1)'
    'C103|.programs[-1].recorded += [{term: ["reach", "-", "-", "-", "workplace", "grab", "harbor", "-", "-", "floor", "allowed"], origin: at(9)}]|programs/policy.typify:9: the reach names the floor harbor, and harbor is an office (5.125 point 1)'
    'C101|.programs[-1].recorded += [{term: ["record", "lodge", "-", "-", "office", "pane", "kept"], origin: at(9)}]|programs/policy.typify:9: the record names the office lodge, and lodge is a floor (5.125 point 1)'
    'C103|.programs[-1].recorded += [{term: ["record", "harbor", "-", "-", "floor", "pane", "kept"], origin: at(9)}]|programs/policy.typify:9: the record names the floor harbor, and harbor is an office (5.125 point 1)'
    'C101|.programs[-1].recorded += [{term: ["ssh-grant", "lodge", "-", "-", "office", "node", "granted"], origin: at(9)}]|programs/policy.typify:9: the ssh-grant names the office lodge, and lodge is a floor (5.125 point 1)'
    'C103|.programs[-1].recorded += [{term: ["ssh-grant", "harbor", "-", "-", "floor", "node", "granted"], origin: at(9)}]|programs/policy.typify:9: the ssh-grant names the floor harbor, and harbor is an office (5.125 point 1)'
    'C104|.programs[-1].recorded += [st("none"; "-"; "-"; "kind"; $root + "/tools"; "hidden"; 9)]|programs/policy.typify:9: the statement names the kind none, which the plan does not make'
    'C104|.programs[-1].recorded += [st("ghost"; "-"; "-"; "kind"; $root + "/tools"; "hidden"; 9)]|programs/policy.typify:9: the statement names the kind ghost, which the plan does not make'
    'C101|(.programs[] | select(.path == "orchard/office.typify") | .plan) |= map(if .[0] == "house" then .[1] = "nowhere" else . end)|the house of orchard names the floor nowhere, which the plan does not make (orchard/office.typify, term 2)'
  )
  local entry
  local number rest
  for entry in "${refusals[@]}"; do
    number=${entry%%|*} rest=${entry#*|}
    statements_plan "$floors_terms | ${rest%|*}"
    check "[$number] plan refuses, with exit 1: ${rest##*|}" exit_is 1 wplan
    check "[$number] naming it" said "${rest##*|}"
  done
  statements_plan "$floors_terms"' | .state["seat-kinds"] = [{key: ["harbor", "dock", "keeper"], value: ["navigator"], masked: false, origin: at(30)},
      {key: ["harbor", "dock", "pilot"], value: ["none"], masked: false, origin: at(31)}]
    | .programs[-1].recorded += [st("none"; "-"; "-"; "kind"; $root + "/tools"; "hidden"; 9), st("harbor"; "dock"; "-"; "room"; $root + "/tools"; "read-only"; 10)]'
  check "[C104] 5.131 point 4: a statement of the kind none, beside the room's own about the same path, refuses the plan, with exit 1" exit_is 1 wplan
  check "[C104] as a statement of a kind the plan does not make" said "programs/policy.typify:9: the statement names the kind none, which the plan does not make"
  check "[C104] and F4 does not meet it" bash -c '! grep -qF "two statements about" "$1"' _ "$scratch/out"
  statements_plan "$floors_terms"' | .state["seat-kinds"] = [{key: ["harbor", "dock", "keeper"], value: ["navigator"], masked: false, origin: at(30)},
      {key: ["harbor", "dock", "pilot"], value: ["gardener"], masked: false, origin: at(31)}]
    | .programs[-1].recorded += [st("gardener"; "-"; "-"; "kind"; $root + "/tools"; "hidden"; 9), st("harbor"; "dock"; "-"; "room"; $root + "/tools"; "hidden"; 10),
      st("navigator"; "-"; "-"; "kind"; $root + "/tools"; "hidden"; 11), st("gardener"; "-"; "-"; "kind"; $root + "/tools"; "hidden"; 12)]'
  check "plan with four equal statements about one path at the room harbor/dock, two of them the same kind's" exit_is 0 wplan
  check "[C104] 5.131 point 4: the seat's merged row names its origins in the plan's order (5.18)" \
    test "$(jq -c --arg p "$root/tools" '[.rows[] | select(.key[2] == "keeper" and .key[3] == $p) | .origins[].line]' "$clone/PLAN/view.json")" = '[9,10,11,12]'
  check "[C104] and so does the room's row" \
    test "$(jq -c --arg p "$root/tools" '[.rooms[] | select(.room == ["harbor", "dock"]) | .rows[] | select(.key[2] == $p) | .origins[].line]' "$clone/PLAN/view.json")" = '[9,10,11,12]'
  statements_plan '(.programs[0].plan) |= map(select(.[0] != "server"))'
  check "[C101] 5.135: a plan with no server and no floor refuses at plan, with exit 1" exit_is 1 wplan
  check "[C101] with the sentence on servers and floors" said "workplace: the plan holds 0 server terms and 0 floor terms: a plan holds one server and no floor, or no server, one workplace and at least one floor"
  check "[C101] then the structure's closing line, and no other line on the server (5.136)" \
    bash -c 'grep -qxF "workplace: the plan refuses a key, a name or its mail path; PLAN/ is as it was" "$1" && ! grep -qF "needs exactly one" "$1"' _ "$scratch/out"
  statements_plan '(.programs[0].plan) += [.programs[0].plan[0]]'
  check "[C3] 5.136: two servers and no floor refuse at plan too, with exit 1" exit_is 1 wplan
  check "[C3] by the accepted line, with its origins, and not by the sentence" \
    bash -c 'grep -qxF "workplace: the plan holds 2 server terms; it needs exactly one (workplace.typify, term 1; workplace.typify, term 2)" "$1" && ! grep -qF "floor terms:" "$1"' _ "$scratch/out"
  statements_plan "$floors_terms"' | (.programs[0].plan) += [["floor", "attic", "Attic", "rooms", "enforced", "run", $root + "/config/floors/deck.conf", "80x24"]]'
  check "[C101] 5.131 point 4: a floor of rooms with no room refuses the plan, with exit 1" exit_is 1 wplan
  check "[C101] saying so" said "the floor attic holds no office and no room"
  check "[C101] and no further line, none calling the floor's term a session term" \
    bash -c '! grep -qF "session term" "$1" && [[ $(grep -c . "$1") == 2 ]]' _ "$scratch/out"
  statements_plan "$floors_terms"' | (.programs[] | select(.path == "orchard/office.typify") | .plan) += [["session", "lodge", "Lodge"]]'
  check "[C101] a session for a floor of rooms refuses the plan, with exit 1" exit_is 1 wplan
  check "[C101] with its line" said "the floor lodge houses rooms, and the plan holds a session or a house for it"
  check "[C101] and no line counts the floor's term among session terms" bash -c '! grep -qF "session terms for lodge" "$1"' _ "$scratch/out"
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
  check "[C102] 5.160: BUILD holds the floor's keys.json in the floor's generation, whose MANIFEST lists it and which the top names" \
    bash -c '[[ $(jq -r ".state + \" \" + .seats[0].name + \" \" + .seats[0].home" "$1/BUILD/floors/deck/$3/keys.json") == "$2/floors/deck Harbor Keeper keys/01" ]] && grep -q "  keys.json$" "$1/BUILD/floors/deck/$3/MANIFEST" && grep -q "  floors/deck/$3/MANIFEST$" "$1/BUILD/MANIFEST"' _ "$clone" "$s" "$(top_gen)"
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
  check "[C102] 5.162 (the addendum's Q8): the build's state stands in S, each a file of this user's with mode 600: its lock, its holder, the generations' lock and the counter" \
    bash -c 'for f in build.lock build.holder generations.lock generation.next; do [[ -f $1/$f && ! -L $1/$f && $(stat -c %a "$1/$f") == 600 ]] || exit 1; done' _ "$s"
  check "[C102] and no process that build started, its agents and its key's gpg among them, holds the build's lock once it has ended" flock -n "$s/build.lock" true
  local counter
  counter=$(< "$s/generation.next")
  chmod 0644 -- "$s/generations.lock"
  check "[C102] a state file of another mode refuses the build, with exit 1" exit_is 1 wp build
  check "[C102] naming it" said "build refuses: $s/generations.lock is not a file of this user's with mode 600"
  chmod 0600 -- "$s/generations.lock"
  rm -rf -- "$clone/BUILD"
  printf '%s\n' '{"command":"build","pid":4242,"at":"2026-01-01T00:00:00Z"}' > "$s/build.holder"
  flock -o "$s/build.lock" sleep 8 &
  local holder=$!
  check "a process of the test holds the build's lock" eventually bash -c '! flock -n "$1" true' _ "$s/build.lock"
  local waited
  waited=$EPOCHREALTIME
  check "[C102] 5.162 (Q8): build refuses while another build holds the build's lock, after a wait of two seconds, with exit 1" exit_is 1 wp build
  waited=$(( ${EPOCHREALTIME/./} - ${waited/./} ))
  check "[C102] review of 4a: having waited the two seconds" test "$waited" -ge 1900000
  check "[C102] naming its holder" said "build refuses: another build of this workplace holds its lock, $s/build.lock: build, process 4242, since 2026-01-01T00:00:00Z"
  kill "$holder" 2> /dev/null
  wait "$holder" 2> /dev/null
  rm -rf -- "$clone/BUILD"
  check "build again" exit_is 0 wp build
  check "[C5] 5.162 (the addendum's P5): a build takes its generation's number from the counter, so that no number is taken twice" \
    test "$(top_gen) $(< "$s/generation.next")" = "$counter $(( counter + 1 ))"
  local kept_counter
  kept_counter=$(< "$s/generation.next")
  printf '%s\n' 07 > "$s/generation.next"
  rm -rf -- "$clone/BUILD"
  check "[C5] review of 4a: a counter that holds anything but a number refuses build, with exit 1" exit_is 1 wp build
  check "[C5] naming it" said "build refuses: $s/generation.next holds 07, which is not the count of this workplace's generations"
  check "[C5] and makes no build" test ! -e "$clone/BUILD"
  printf '%s\n' "$kept_counter" > "$s/generation.next"
  check "build again" exit_is 0 wp build
  local floors_named g
  g=$(top_gen)
  floors_named=$(jq -r --arg g "$g" '[.programs[].plan[] | (if type == "object" then .term else . end) | select(.[0] == "floor") | "floors/\(.[1])/\($g)/MANIFEST"] | join(" ")' "$clone/PLAN/plan.json")
  check "[C5] 5.160 point 2: the top names the frame, one shared generation and one generation for each floor, in the order of the floor terms, and nothing else" \
    test "$(sed 's/^[0-9a-f]\{64\}  //' "$clone/BUILD/MANIFEST" | tr '\n' ' ')" = "binding.json bin/workplace libexec/resolve.jq libexec/check.jq libexec/table.jq libexec/fold.jq libexec/alias-access.jq libexec/floor-runtime.bash share/floor-set-enforced.conf share/floor-set-unenforced.conf shared/$g/MANIFEST $floors_named "
  check "[C2] 5.160 point 2: the plan's copies stand in the shared generation, PLAN's plan byte for byte, and no plan, view, mail, keys, homes or records stands beside the top" \
    bash -c 'cmp -s "$1/PLAN/plan.json" "$1/BUILD/shared/$2/plan.json" && [[ -f $1/BUILD/shared/$2/plan-view.json && -f $1/BUILD/shared/$2/plan-manifest.json ]] \
      && ! ls -- "$1/BUILD" | grep -qxE "(plan|plan-view|plan-manifest|plan-facts|mail|keys|homes|records)[.]json"' _ "$clone" "$g"
  check "[C2] 5.160 point 2: no code of the frame names the build's plan, view or mail beside the top, in any spelling of BUILD, but build's own writes and doctor's read of a build without floors" \
    bash -c '! grep -nE "([$][{]?build_dir[}]?\"?|BUILD)/(plan|plan-view|plan-manifest|plan-facts|mail|view)[.]json" "$1/bin/workplace" | grep -v "build_out" | grep -vxF "$(grep -n "^  dplan=\$config/BUILD/plan.json$" "$1/bin/workplace")"' _ "$tool"
  check "[C5] the build verifies: status reports it so" exit_is 0 wp status
  check "[C5] saying so" said "build: verified, manifest"
  local kept=$scratch/kept-generation entry rest
  local -a breaks=(
    "cp -- \"\$1/BUILD/shared/$g/plan.json\" \"\$1/BUILD/plan.json\"|holds a file its MANIFEST does not list: plan.json|"
    ": > \"\$1/BUILD/floors/deck/$g/stray\"|holds a file its MANIFEST does not list: floors/deck/$g/stray|lodge"
    "chmod u+w -- \"\$1/BUILD/floors/lodge/$g/MANIFEST\" && printf x >> \"\$1/BUILD/floors/lodge/$g/MANIFEST\"|floors/lodge/$g/MANIFEST does not match its MANIFEST|deck"
    "chmod u+w -- \"\$1/BUILD/floors/deck/$g/MANIFEST\" && sed -i '1a\\\\' \"\$1/BUILD/floors/deck/$g/MANIFEST\"|floors/deck/$g/MANIFEST holds a line that is not a hash and a name|lodge"
    "chmod u+w -- \"\$1/BUILD/MANIFEST\" \"\$1/BUILD/floors/lodge\" && sed -i '/  floors\/lodge\//d' \"\$1/BUILD/MANIFEST\" && chmod -R u+w -- \"\$1/BUILD/floors/lodge\" && rm -rf -- \"\$1/BUILD/floors/lodge\"|MANIFEST names the floors bridge deck, and the plan's floors are bridge deck lodge|"
  )
  for entry in "${breaks[@]}"; do
    rm -rf -- "$kept" && cp -a -- "$clone/BUILD" "$kept"
    bash -c "${entry%%|*}" _ "$clone"
    rest=${entry#*|}
    check "[C5] 5.160: status refuses a build whose generations do not verify, with exit 1: ${rest%|*}" exit_is 1 wp status
    check "[C5] naming it" said "${rest%|*}"
    if [[ -n ${rest##*|} ]]; then
      check "[C5] 5.160 point 3: and a floor's own verify reads the top, the frame, the shared generation and its own tree alone, so the floor ${rest##*|} verifies" \
        exit_is 0 wp status "${rest##*|}"
    fi
    rm -rf -- "$clone/BUILD" && mv -- "$kept" "$clone/BUILD"
  done
  check "[C101] 5.160 point 8: with floors, up names its floor, or refuses with exit 2" exit_is 2 wp up
  check "[C101] saying so" said "with floors, up names its floor: workplace up F"
  check "[C101] review of 4a: up of an empty word refuses, with exit 2, as one the build does not make" exit_is 2 wp up ''
  check "[C101] with the frame's line alone, and no line of bash's" test "$(< "$scratch/out")" = "workplace: the build has no floor "
  check "[C101] review of 4a: and so does status of an empty word" exit_is 2 wp status ''
  check "[C101] with the frame's line alone" test "$(< "$scratch/out")" = "workplace: the build has no floor "
  check "[C101] review of 4a: and carry of an empty word" exit_is 2 wp carry ''
  check "[C101] with the frame's line alone" test "$(< "$scratch/out")" = "workplace: the build has no floor "
  check "[C102] unbuild" exit_is 0 wp unbuild
  check "[C102] removes the key homes in every floor's state" \
    bash -c '[[ ! -e $1/floors/deck/keys ]] && grep -qF "unbuild: removed the key homes in $1/floors/deck/keys, 1 homes" "$2"' _ "$s" "$scratch/out"

  # A floor's key may hold a backslash (C67), which sha256sum escapes in the lines it writes.
  jq '.floors |= map(if .key == "lodge" then .key = "lo\\dge" else . end)' "$clone/workplace.json" > "$scratch/w" && cp -- "$scratch/w" "$clone/workplace.json"
  statements_plan "${floors_terms//'"lodge"'/'"lo\\dge"'}"
  check "plan with a floor whose key holds a backslash" exit_is 0 wplan
  check "build of it" exit_is 0 wp build
  check "[C5] review of 4a: the top names that floor's generation by its key as written, where sha256sum would escape it" \
    grep -qE '^[0-9a-f]{64}  floors/lo\\dge/[0-9]+/MANIFEST$' "$clone/BUILD/MANIFEST"
  check "[C5] review of 4a: and the build verifies, whole" exit_is 0 wp status
  check "[C5] and that floor's own verify" exit_is 0 wp status 'lo\dge'
  check "unbuild it" exit_is 0 wp unbuild
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
    '.floors[0].name = "Bridge : upper"|the floor bridge is named "Bridge : upper", which is refused: it holds a colon between spaces, or at its start or end beside a space, which the reader takes for the separator of the root program'"'"'s words'
    '.floors[0].name = "Bridge :"|the floor bridge is named "Bridge :", which is refused: it holds a colon between spaces, or at its start or end beside a space, which the reader takes for the separator of the root program'"'"'s words'
    '.floors[0].smallest = "80x24\n"|the floor bridge says smallest "80x24\n": COLSxROWS'
    '.floors[0].name = ": Bridge"|the floor bridge is named ": Bridge", which is refused: it holds a colon between spaces, or at its start or end beside a space, which the reader takes for the separator of the root program'"'"'s words'
    '.floors[0].conf = ""|the floor bridge names its conf "", which is not a relative path'
    '.layers += [""]|workplace.json names a layer that is not a relative path: ""'
    '.floors[0].conf = "floors/bri : dge.conf"|the floor bridge names its conf "floors/bri : dge.conf", which is refused: it holds a colon between spaces, or at its start or end beside a space, which the reader takes for the separator of the root program'"'"'s words'
  )
  local entry
  : > "$clone/floors/bri : dge.conf"
  for entry in "${cases[@]}"; do
    jq "${entry%|*}" "$clone/workplace.json" > "$scratch/w2" && cp -- "$clone/workplace.json" "$scratch/w-saved" && cp -- "$scratch/w2" "$clone/workplace.json"
    check "[C100] plan refuses, with exit 2: ${entry##*|}" exit_is 2 wplan
    check "[C100] naming it" said "${entry##*|}"
    cp -- "$scratch/w-saved" "$clone/workplace.json"
  done
  jq '. + {socket: "run"}' "$clone/workplace.json" > "$scratch/w2" && cp -- "$clone/workplace.json" "$scratch/w-saved" && cp -- "$scratch/w2" "$clone/workplace.json"
  check "[C100] 5.135: a socket of any value beside floors refuses plan, with exit 2" exit_is 2 wplan
  check "[C100] by its one line, which does not judge the socket's value" \
    bash -c 'grep -qxF "workplace: workplace.json holds socket beside floors: with floors, each floor names its socket" "$1" && ! grep -qF "says socket" "$1"' _ "$scratch/out"
  cp -- "$scratch/w-saved" "$clone/workplace.json"
  jq '.floors[0].conf = "floors/none.conf"' "$clone/workplace.json" > "$scratch/w2" && cp -- "$clone/workplace.json" "$scratch/w-saved" && cp -- "$scratch/w2" "$clone/workplace.json"
  check "[C100] a floor whose conf is no file in the clone refuses plan, with exit 2" exit_is 2 wplan
  check "[C100] naming it" said "the floor bridge names its conf floors/none.conf, which is not a file in the clone"
  cp -- "$scratch/w-saved" "$clone/workplace.json"
  : > "$clone/tmux.conf"
  check "[C100] a tmux.conf beside floors refuses plan, with exit 2" exit_is 2 wplan
  check "[C100] saying so" said "tmux.conf stands in the clone beside floors: each floor names its own file"
  rm -f -- "$clone/tmux.conf"
  check "[C100] and without it plan goes on" exit_is 0 wplan
  jq '.floors[0].name = "Bridge: upper" | .floors[0].key = "bri:dge" | .floors[0].conf = "floors/bri:dge.conf"' "$clone/workplace.json" > "$scratch/w2" \
    && cp -- "$clone/workplace.json" "$scratch/w-saved" && cp -- "$scratch/w2" "$clone/workplace.json" && : > "$clone/floors/bri:dge.conf"
  wplan > "$scratch/out" 2>&1
  check "[C100] 5.142: a bare colon in a floor's name, key or conf is no fault of the frame's: the root program carries them, and their classes are the reader's" \
    grep -qxF "floor : bri:dge : Bridge: upper : offices : unenforced : tmux-default : config/floors/bri:dge.conf : 80x24" "$STUB_DIR/root-program"
  cp -- "$scratch/w-saved" "$clone/workplace.json"; rm -f -- "$clone/floors/bri:dge.conf"
  jq '.floors[0].name = "Bri\\dge"' "$clone/workplace.json" > "$scratch/w2" && cp -- "$clone/workplace.json" "$scratch/w-saved" && cp -- "$scratch/w2" "$clone/workplace.json"
  wplan > "$scratch/out" 2>&1
  check "[C100] 5.141 point 7: the floors' members keep their places, and a backslash reaches the root program once" \
    grep -qxF 'floor : bridge : Bri\dge : offices : unenforced : tmux-default : config/floors/bridge.conf : 80x24' "$STUB_DIR/root-program"
  cp -- "$scratch/w-saved" "$clone/workplace.json"
  local other
  for other in "con:fig" "con.fig" "-config"; do
    rm -rf -- "$root/$other" && cp -R -- "$clone" "$root/$other"
    check "[C27] 5.142: a configuration whose base name does not fit the class of the workplace's name refuses plan, with exit 2: $other" \
      exit_is 2 env WORKPLACE_CONFIG="$root/$other" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
    check "[C27] naming it" said "workplace: the configuration's base name \"$other\" is refused: the workplace's name is derived from it, and it does not fit the class of that name, /[A-Za-z0-9][A-Za-z0-9_-]*/ (5.142)"
    rm -rf -- "$root/$other"
  done
  rm -rf -- "$root/c : d" && cp -R -- "$clone" "$root/c : d"
  check "[C27] a configuration whose path relative to the root holds the separator refuses plan, with exit 2" \
    exit_is 2 env WORKPLACE_CONFIG="$root/c : d" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
  check "[C27] naming it, by one line, though its base name, which holds it too, does not fit the name's class either" \
    bash -c 'grep -qxF "workplace: the configuration'"'"'s path relative to the root, c : d, is refused: it holds a colon between spaces, or at its start or end beside a space, which the reader takes for the separator of the root program'"'"'s words" "$1" && [[ $(grep -c "is refused" "$1") == 1 ]]' _ "$scratch/out"
  rm -rf -- "$root/c : d" "$scratch/r : t" "$scratch/ro:ot"
  mkdir -- "$scratch/r : t" && cp -R -- "$clone" "$scratch/r : t/config"
  local spaced colon
  spaced=$(cd -P -- "$scratch/r : t" && pwd -P)
  check "[C27] a root that holds the separator refuses plan, with exit 2" \
    exit_is 2 env WORKPLACE_ROOT="$spaced" WORKPLACE_CONFIG="$spaced/config" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
  check "[C27] naming it" said "workplace: the root $spaced is refused: it holds a colon between spaces, or at its start or end beside a space, which the reader takes for the separator of the root program's words"
  mkdir -- "$scratch/ro:ot" && cp -R -- "$clone" "$scratch/ro:ot/config"
  colon=$(cd -P -- "$scratch/ro:ot" && pwd -P)
  env WORKPLACE_ROOT="$colon" WORKPLACE_CONFIG="$colon/config" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan > "$scratch/out" 2>&1
  check "[C27] 5.142: a root with a bare colon passes the assembler, the last word of its line, which the reader reads whole" \
    bash -c 'grep -qxF "workdir : $1" "$2" && ! grep -qF "is refused" "$3"' _ "$colon" "$STUB_DIR/root-program" "$scratch/out"
  rm -rf -- "$scratch/r : t" "$scratch/ro:ot"
  local nel
  mkdir -- "$scratch/r"$'\xc2\x85'"t" && cp -R -- "$clone" "$scratch/r"$'\xc2\x85'"t/config"
  nel=$(cd -P -- "$scratch/r"$'\xc2\x85'"t" && pwd -P && printf .) && nel=${nel%$'\n.'}
  check "[C1] 5.159 point 6: a root whose name holds a control character of C1, NEL, refuses plan, with exit 2" \
    exit_is 2 env WORKPLACE_ROOT="$nel" WORKPLACE_CONFIG="$nel/config" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
  check "[C1] naming the control character" said "workplace: the root, the name or the configuration's path holds a control character"
  rm -rf -- "$scratch/r"$'\xc2\x85'"t"
  rm -f -- "$clone/floors/bri : dge.conf"
  rm -rf -- "$root/config"$'\n' && cp -R -- "$clone" "$root/config"$'\n'
  check "[C27] 5.144: a configuration whose base name ends in a newline refuses plan, with exit 2" \
    exit_is 2 env WORKPLACE_CONFIG="$root/config"$'\n' PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
  check "[C27] by A14, since such a base name does not fit the class either" said 'workplace: the configuration'"'"'s base name "config\n" is refused'
  rm -rf -- "$root/config"$'\n'
  mkdir -p -- "$scratch/rt"$'\n' && cp -R -- "$clone" "$scratch/rt"$'\n'"/config"
  env WORKPLACE_ROOT="$scratch/rt"$'\n' WORKPLACE_CONFIG="$scratch/rt"$'\n'"/config" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan > "$scratch/out" 2>&1
  check "[C1] a root whose name ends in a newline is taken with it, and refused for its control character, not read as another directory" \
    said "workplace: the root, the name or the configuration's path holds a control character"
  rm -rf -- "$scratch/rt"$'\n'
  mkdir -p -- "$scratch/wp"$'\n' && cp -R -- "$tool/bin" "$tool/libexec" "$tool/host" "$tool/share" "$scratch/wp"$'\n'/
  env PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan > "$scratch/out-a" 2>&1 && echo 0 >> "$scratch/out-a" || echo "$?" >> "$scratch/out-a"
  env PATH="$STUB_DIR/bin:$PATH" "$BASH" "$scratch/wp"$'\n'/bin/workplace plan > "$scratch/out-b" 2>&1 && echo 0 >> "$scratch/out-b" || echo "$?" >> "$scratch/out-b"
  check "[C1] a frame whose own directory ends in a newline reads its programs from there, and plans as the frame does" cmp -s "$scratch/out-a" "$scratch/out-b"
  rm -rf -- "$scratch/wp"$'\n' "$scratch/out-a" "$scratch/out-b"
  rm -rf -- "$root/x :" && cp -R -- "$clone" "$root/x :"
  check "[C27] 5.142: a path relative to the root that ends in a space and a colon holds no separator as written, and its base name is refused by its class, with exit 2" \
    exit_is 2 env WORKPLACE_CONFIG="$root/x :" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
  check "[C27] by A14 alone, naming the base name" \
    bash -c 'grep -qF "workplace: the configuration'"'"'s base name \"x :\" is refused" "$1" && [[ $(grep -c "is refused" "$1") == 1 ]]' _ "$scratch/out"
  rm -rf -- "$root/x :" "$root/a:b" && mkdir -- "$root/a:b" && cp -R -- "$clone" "$root/a:b/config"
  env WORKPLACE_CONFIG="$root/a:b/config" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan > "$scratch/out" 2>&1
  check "[C27] 5.142: a bare colon in the path relative to the root passes the assembler, into every conf it heads" \
    bash -c 'grep -qF "floor : bridge : Bridge : offices : unenforced : tmux-default : a:b/config/floors/bridge.conf : 80x24" "$1" && ! grep -qF "is refused" "$2"' _ "$STUB_DIR/root-program" "$scratch/out"
  rm -rf -- "$root/a:b" "$scratch/r : t" "$scratch/c : d"
  mkdir -- "$scratch/r : t" && cp -R -- "$clone" "$scratch/r : t/con.fig"
  spaced=$(cd -P -- "$scratch/r : t" && pwd -P)
  check "[C27] a root that holds the separator, and a base name outside the class: two faults" \
    exit_is 2 env WORKPLACE_ROOT="$spaced" WORKPLACE_CONFIG="$spaced/con.fig" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
  check "[C27] two lines, A12's and A14's" \
    bash -c 'grep -qF "workplace: the root $2 is refused" "$1" && grep -qF "workplace: the configuration'"'"'s base name \"con.fig\" is refused" "$1"' _ "$scratch/out" "$spaced"
  cp -R -- "$clone" "$scratch/c : d"
  spaced=$(cd -P -- "$scratch/c : d" && pwd -P)
  check "[C27] a clone that is the root, whose base name holds the separator" \
    exit_is 2 env WORKPLACE_ROOT="$spaced" WORKPLACE_CONFIG="$spaced" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
  check "[C27] refuses by the root's line alone, since the base name's fault is that same separator" \
    bash -c 'grep -qF "workplace: the root $2 is refused" "$1" && [[ $(grep -c "is refused" "$1") == 1 ]]' _ "$scratch/out" "$spaced"
  rm -rf -- "$scratch/r : t" "$scratch/c : d" "$root/con.fig"
  cp -R -- "$clone" "$root/con.fig"
  jq 'del(.floors)' "$clone/workplace.json" > "$root/con.fig/workplace.json" && : > "$root/con.fig/tmux.conf"
  check "[C27] 5.142: without floors and with no socket the name is derived, so a base name outside the class refuses, with exit 2" \
    exit_is 2 env WORKPLACE_CONFIG="$root/con.fig" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
  check "[C27] naming it" said "workplace: the configuration's base name \"con.fig\" is refused"
  jq 'del(.floors) + {socket: "default"}' "$clone/workplace.json" > "$root/con.fig/workplace.json"
  env WORKPLACE_CONFIG="$root/con.fig" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan > "$scratch/out" 2>&1
  check "[C27] with socket default the name is default, and the base name is not judged" \
    bash -c '! grep -qF "base name" "$1" && grep -qxF "server : default : con.fig/tmux.conf" "$2"' _ "$scratch/out" "$STUB_DIR/root-program"
  rm -rf -- "$root/con.fig"
}

lodge_west='| ([.programs[] | select(.path == "lodge/east/room.typify")][0] | .path = "lodge/west/room.typify"
      | .plan |= map(.[2] = "west" | if .[0] == "window" then .[3] = "West" else . end)) as $room
  | ([.programs[] | select(.path == "lodge/east/ida/seat.typify")][0] | .path = "lodge/west/ivo/seat.typify"
      | .plan |= map(if type == "object" then .term[1:4] = ["lodge", "west", "ivo"]
                     else .[1:4] = ["lodge", "west", "ivo"] | if .[0] == "pane" then .[4] = "Lodge Ivo" else . end end)) as $seat
  | .programs = .programs[0:-1] + [$room, $seat] + .programs[-1:]'
orchard_field='| ([.programs[] | select(.path == "orchard/barn/room.typify")][0] | .path = "orchard/field/room.typify"
      | .plan |= map(.[2] = "field" | if .[0] == "window" then .[3] = "Field" else . end)) as $room
  | ([.programs[] | select(.path == "orchard/barn/picker/seat.typify")][0] | .path = "orchard/field/reaper/seat.typify"
      | .plan |= map(if type == "object" then .term[1:4] = ["orchard", "field", "reaper"]
                     else .[1:4] = ["orchard", "field", "reaper"] | if .[0] == "pane" then .[4] = "Orchard Reaper" else . end end)) as $seat
  | .programs = .programs[0:-1] + [$room, $seat] + .programs[-1:]'
harbor_yard='| ([.programs[] | select(.path == "harbor/tower/room.typify")][0] | .path = "harbor/yard/room.typify"
      | .plan |= map(.[2] = "yard" | if .[0] == "window" then .[3] = "Yard" else . end)) as $room
  | ([.programs[] | select(.path == "harbor/tower/watch/seat.typify")][0] | .path = "harbor/yard/sentry/seat.typify"
      | .plan |= map(if type == "object" then .term[1:4] = ["harbor", "yard", "sentry"]
                     else .[1:4] = ["harbor", "yard", "sentry"] | if .[0] == "pane" then .[4] = "Harbor Sentry" else . end end)) as $seat
  | .programs = .programs[0:-1] + [$room, $seat] + .programs[-1:]'

t_reach_floors() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$root/records"
  local base="$floors_terms $lodge_west | $comms_terms" reach
  local numbered='| .programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "2"; 20), cl("harbor"; "tower"; "-"; "room"; "3"; 21), sc(22)]'
  local hk='"Harbor Keeper"' hp='"Harbor Pilot"' hw='"Harbor Watch"' og='"Orchard Grower"' op='"Orchard Picker"' li='"Lodge Ida"' lv='"Lodge Ivo"'
  reach() { seat_of "$1" '[.reach.mail, .reach.grab, .reach.write]'; }
  local dock='harbor/dock at 2, from programs/policy.typify:20' tower='harbor/tower at 3, from programs/policy.typify:21'

  statements_plan "$base $numbered"
  check "plan of floors with mail, the rooms of harbor numbered 2 and 3, and a second room on the floor of rooms" exit_is 0 wplan
  check "[C54] an enforced seat grabs its own room and its sub-room, mails its sub-room alone, and writes none (5.122 point 6)" \
    test "$(reach keeper)" = "[[$hw],[$hk,$hp,$hw],[]]"
  check "[C54] a room above it in its office it neither grabs nor mails" test "$(reach watch)" = "[[],[$hw],[]]"
  check "[C54] on a floor of rooms a seat grabs its own room alone, and no other room has a default" test "$(reach ida)$(reach ivo)" = "[[],[$li],[]][[],[$lv],[]]"
  check "[C54] an unenforced floor's seat has no default: it neither mails, grabs nor writes without a term" test "$(reach grower)" = "[[],[],[]]"
  check "[C54] plan prints the grounds of each default cell: its own room, and a sub-room beneath it, with both rooms' numbers and origins" \
    said "  grab: Harbor Keeper (its own room, $dock), Harbor Pilot (its own room, $dock), Harbor Watch (a sub-room: $tower, beneath $dock)"
  check "[C54] the same for mail" said "  mail: Harbor Watch (a sub-room: $tower, beneath $dock)"
  check "[C54] and no seat writes: an enforced seat by rule, an unenforced one for want of a term" bash -c '[[ $(grep -c "^  write: no seat$" "$1") == 7 ]]' _ "$scratch/out"
  check "[C54] a room with no number is printed so" said "  grab: Lodge Ida (its own room, lodge/east with no number)"
  check "build" exit_is 0 wp build
  check "[C56] mail.json gives each seat its floor and its room's number, null where the room has none (5.132 point 9)" \
    test "$(jq -c '[.seats[] | [.name, .floor, .number]]' "$clone/BUILD/shared/$(top_gen)/mail.json")" = \
    "[[$hk,\"deck\",2],[$hp,\"deck\",2],[$hw,\"deck\",3],[$og,\"bridge\",null],[$op,\"bridge\",null],[$li,\"lodge\",null],[$lv,\"lodge\",null]]"
  rm -rf -- "$clone/BUILD"

  statements_plan "$base"' | .programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "2"; 20), sc(22)]'
  check "plan with only harbor/dock numbered" exit_is 0 wplan
  check "[C54] a room with no number is cleared least, so it is a sub-room of a numbered room (5.125 point 7)" test "$(reach keeper)" = "[[$hw],[$hk,$hp,$hw],[]]"
  check "[C54] and the numbered room is above it" test "$(reach watch)" = "[[],[$hw],[]]"
  check "[C54] printed with no number" said "Harbor Watch (a sub-room: harbor/tower with no number, beneath $dock)"
  statements_plan "$base"
  check "plan with no number at all" exit_is 0 wplan
  check "[C54] two rooms with no number are peers: neither has a default toward the other" test "$(reach keeper)$(reach watch)" = "[[],[$hk,$hp],[]][[],[$hw],[]]"
  statements_plan "$base"' | .programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "2"; 20), cl("harbor"; "tower"; "-"; "room"; "2"; 21), sc(22)]'
  check "plan with both rooms at 2" exit_is 0 wplan
  check "[C54] two rooms of one number are peers (5.122 point 3)" test "$(reach keeper)$(reach watch)" = "[[],[$hk,$hp],[]][[],[$hw],[]]"
  statements_plan "$base"' | .programs[-1].recorded += [cl("lodge"; "east"; "-"; "room"; "1"; 20), cl("lodge"; "west"; "-"; "room"; "2"; 21), sc(22)]'
  check "plan with the floor of rooms' rooms numbered 1 and 2" exit_is 0 wplan
  check "[C54] on a floor of rooms the numbers decide no reach (5.132 point 4)" test "$(reach ida)$(reach ivo)" = "[[],[$li],[]][[],[$lv],[]]"

  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "harbor", "dock", "-", "room", "mail", "orchard", "-", "-", "office", "allowed"]; 2)]'
  check "plan with a room's allow toward another floor" exit_is 0 wplan
  check "[C54] another floor is reached by a term" test "$(reach keeper)" = "[[$hw,$og,$op],[$hk,$hp,$hw],[]]"
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "harbor", "dock", "-", "room", "mail", "orchard", "-", "-", "office", "allowed"]; 2),
      m(["reach", "-", "-", "-", "workplace", "mail", "orchard", "-", "-", "office", "banned"]; 3)]'
  check "plan with the same allow and a workplace's ban" exit_is 0 wplan
  check "[C54] with floors a ban holds against an allow of any rank (5.125 point 3, 5.132 point 1)" test "$(reach keeper)" = "[[$hw],[$hk,$hp,$hw],[]]"
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "harbor", "dock", "-", "room", "grab", "harbor", "tower", "-", "room", "banned"]; 2),
      m(["reach", "harbor", "dock", "-", "room", "mail", "harbor", "dock", "-", "room", "allowed"]; 3)]'
  check "plan with a ban on a sub-room's grab and an allow of the room's own mail" exit_is 0 wplan
  check "[C54] a term bans what a default gives, and opens mail in the room, to the seat itself too (5.125 point 6)" test "$(reach keeper)" = "[[$hk,$hp,$hw],[$hk,$hp],[]]"
  check "[C54] the term's cells print their origins" said "  mail: Harbor Keeper (programs/COMMS.typify:3), Harbor Pilot (programs/COMMS.typify:3), Harbor Watch (a sub-room: $tower, beneath $dock)"
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "lodge", "-", "-", "floor", "grab", "lodge", "-", "-", "floor", "allowed"]; 2),
      m(["reach", "harbor", "-", "-", "office", "grab", "lodge", "-", "-", "floor", "allowed"]; 3)]'
  check "plan with a floor-scope grab on the floor of rooms, and harbor's grab of it" exit_is 0 wplan
  check "[C103] a term at the floor's scope opens its rooms to each other (5.125 point 26)" test "$(reach ida)" = "[[],[$li,$lv],[]]"
  check "[C54] and a term opens another floor to an office" test "$(reach watch)" = "[[],[$hw,$li,$lv],[]]"
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "orchard", "-", "-", "office", "mail", "harbor", "-", "-", "office", "allowed"]; 2),
      m(["reach", "orchard", "-", "-", "office", "write", "harbor", "dock", "-", "room", "allowed"]; 3)]'
  check "plan with an unenforced office's mail and write into an enforced floor" exit_is 0 wplan
  check "[C54] an unenforced floor's terms decide its seats' mail and write, write included (5.132 points 5 and 6)" test "$(reach grower)" = "[[$hk,$hp,$hw],[],[$hk,$hp]]"

  local refusals=(
    '| .programs[-1].recorded += [m(["reach", "harbor", "dock", "-", "room", "write", "orchard", "-", "-", "office", "allowed"]; 2)]|programs/COMMS.typify:2: the reach of the room harbor/dock says write allowed, and it asks for seats of the enforced floor deck: there a seat types into no pane, and write is no word of a term, whichever way it points (5.121, 5.125 point 10)'
    '| .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "write", "orchard", "-", "-", "office", "banned"]; 2)]|programs/COMMS.typify:2: the reach of the workplace says write banned, and it asks for seats of the enforced floors deck, lodge: there a seat types into no pane, and write is no word of a term, whichever way it points (5.121, 5.125 point 10)'
    '| .programs[-1].recorded += [m(["reach", "harbor", "-", "-", "office", "record", "orchard", "-", "-", "office", "allowed"]; 2), {term: ["record-path", "records"], origin: at(12)}]|programs/COMMS.typify:2: the reach of the office harbor allows record, and it asks for seats of the enforced floor deck: reading a seat'"'"'s saved record stays with Management, and no term gives it to a seat of an enforced floor (5.124 point 9)'
    '| .programs[-1].recorded += [m(["reach", "harbor", "tower", "-", "room", "mail", "harbor", "dock", "-", "room", "allowed"]; 2)]|programs/COMMS.typify:2: the reach of the room harbor/tower allows mail to the room harbor/dock, and so would open the room harbor/dock to the room harbor/tower, which is cleared less in the office harbor (harbor/tower at 3, from programs/policy.typify:21; harbor/dock at 2, from programs/policy.typify:20): inside an office no term opens a room cleared more (5.124 point 8, 5.132 point 2)'
    '| .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "grab", "harbor", "-", "-", "office", "allowed"]; 2)]|programs/COMMS.typify:2: the reach of the workplace allows grab to the office harbor, and so would open the room harbor/dock to the room harbor/tower, which is cleared less in the office harbor (harbor/tower at 3, from programs/policy.typify:21; harbor/dock at 2, from programs/policy.typify:20): inside an office no term opens a room cleared more (5.124 point 8, 5.132 point 2)'
  )
  local entry
  for entry in "${refusals[@]}"; do
    statements_plan "$base $numbered ${entry%|*}"
    check "[C54] plan refuses, with exit 1: ${entry##*|}" exit_is 1 wplan
    check "[C54] naming it" said "workplace: the fold refuses: ${entry##*|}"
  done
  statements_plan "$base"' | .programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "2"; 20), cl("harbor"; "tower"; "-"; "room"; "2"; 21), sc(22),
      m(["reach", "harbor", "dock", "-", "room", "grab", "harbor", "tower", "-", "room", "allowed"]; 2)]'
  check "[C54] an allow that opens a peer room inside an office refuses the plan, with exit 1 (5.125 point 9)" exit_is 1 wplan
  check "[C54] naming both rooms' numbers" \
    said "programs/COMMS.typify:2: the reach of the room harbor/dock allows grab to the room harbor/tower, and so would open the room harbor/tower to the room harbor/dock, which is cleared as much in the office harbor (harbor/dock at 2, from programs/policy.typify:20; harbor/tower at 2, from programs/policy.typify:21): inside an office a term opens no peer room (5.125 point 9, 5.132 point 2)"
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "grab", "harbor", "-", "-", "office", "allowed"]; 2)]'
  wplan > "$scratch/out" 2>&1
  check "[C54] a wide allow refuses once for each pair of rooms whose cell it decides, and for no cell a default already opens" \
    test "$(grep -c "and so would open" "$scratch/out")" = 1
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "grab", "harbor", "-", "-", "office", "allowed"]; 2),
      m(["reach", "harbor", "tower", "-", "room", "grab", "harbor", "dock", "-", "room", "banned"]; 3)]'
  check "[C54] with a ban that closes the cell, the wide allow stands (5.132 point 2)" exit_is 0 wplan
  check "[C54] and the room above stays closed" test "$(reach watch)" = "[[],[$hw],[]]"
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "-", "-", "-", "workplace", "grab", "harbor", "-", "-", "office", "allowed"]; 2),
      m(["reach", "harbor", "tower", "-", "room", "grab", "harbor", "dock", "-", "room", "allowed"]; 3)]'
  check "[C54] where a narrower allow decides the cell, the narrower one refuses" exit_is 1 wplan
  check "[C54] and the wide one is not named" bash -c 'grep -qF "programs/COMMS.typify:3: the reach of the room harbor/tower allows grab" "$1" && ! grep -qF "COMMS.typify:2: the reach" "$1"' _ "$scratch/out"
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "harbor", "tower", "-", "room", "mail", "harbor", "dock", "-", "room", "banned"]; 2),
      m(["reach", "harbor", "-", "-", "office", "record", "orchard", "-", "-", "office", "banned"]; 3), {term: ["record-path", "records"], origin: at(12)}]'
  check "[C54] a ban toward a room above stands, and so does a banned record (5.132 points 3 and 7)" exit_is 0 wplan
  statements_plan "$floors_terms $lodge_west $orchard_field | $comms_terms"' | .programs[-1].recorded += [cl("orchard"; "barn"; "-"; "room"; "2"; 20), cl("orchard"; "field"; "-"; "room"; "3"; 21), sc(22),
      m(["reach", "orchard", "field", "-", "room", "mail", "orchard", "barn", "-", "room", "allowed"]; 2)]'
  check "[C54] on an unenforced floor an allow toward a room above in the office stands: the rule binds no unenforced asker (5.132 point 5)" exit_is 0 wplan
  check "[C54] and its term decides" test "$(reach reaper)" = "[[$og,$op],[],[]]"

  statements_plan "$base"' | .programs[-1].recorded += [cl("harbor"; "-"; "-"; "office"; "2"; 20), cl("harbor"; "tower"; "-"; "room"; "3"; 21), sc(22)]'
  check "plan with harbor numbered 2 by its office and tower 3 by its own line" exit_is 0 wplan
  check "[C54] a room with no line of its own takes its office's number (5.122 point 1, 5.141 point 7)" test "$(reach keeper)" = "[[$hw],[$hk,$hp,$hw],[]]"
  check "[C54] printed with the office's clearance" said "Harbor Watch (a sub-room: $tower, beneath harbor/dock at 2, from programs/policy.typify:20)"
  statements_plan "$base"' | .programs[-1].recorded += [cl("lodge"; "west"; "-"; "room"; "1"; 20), sc(22)]'
  check "plan with one room of the floor of rooms numbered" exit_is 0 wplan
  check "[C32] a seat of a floor of rooms with no number is printed so, and no office is spoken of (5.141 point 7)" \
    bash -c 'grep "^seat Lodge Ida (lodge/east/ida): " "$1" | grep -qF "; cleared for no label, since its room has no clearance;"' _ "$scratch/out"
  statements_plan "$floors_terms $lodge_west $harbor_yard | $comms_terms"' | .programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "1"; 20), cl("harbor"; "tower"; "-"; "room"; "2"; 21),
      cl("harbor"; "yard"; "-"; "room"; "2"; 23), sc(22), m(["reach", "harbor", "tower", "-", "room", "grab", "harbor", "-", "-", "office", "allowed"]; 2)]'
  check "[C54] a term that opens a room above and a peer from one room refuses, with exit 1" exit_is 1 wplan
  check "[C54] one line for each pair of rooms, by the asking room and then the target room (5.141 point 7)" \
    test "$(grep -o "and so would open the room harbor/[a-z]* to the room harbor/tower" "$scratch/out" | tr '\n' ,)" = "and so would open the room harbor/dock to the room harbor/tower,and so would open the room harbor/yard to the room harbor/tower,"
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "harbor", "tower", "-", "room", "mail", "harbor", "dock", "-", "room", "allowed"]; 2),
      m(["reach", "harbor", "-", "-", "office", "record", "orchard", "-", "-", "office", "allowed"]; 3), m(["reach", "harbor", "dock", "-", "room", "write", "orchard", "-", "-", "office", "banned"]; 4),
      {term: ["record-path", "records"], origin: at(12)}]'
  check "[C54] R1, R2 and R3 in one plan refuse, with exit 1" exit_is 1 wplan
  check "[C54] in that order, R1 first" test "$(grep -oE "says write|allows record|so would open" "$scratch/out" | tr '\n' ,)" = "says write,allows record,so would open,"
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "orchard", "-", "-", "office", "record", "harbor", "-", "-", "office", "allowed"]; 2),
      {term: ["record-path", "records"], origin: at(12)}]'
  check "[C54] an allowed record asked from an unenforced floor stands (5.132 point 7)" exit_is 0 wplan
  check "[C54] and its term decides the record list" test "$(seat_of grower '.reach.record')" = "[$hk,$hp,$hw]"

  local fold
  rm -rf -- "$scratch/loose" && mkdir -- "$scratch/loose" && cp -R -- "$tool/." "$scratch/loose/"
  fold=$(< "$scratch/loose/libexec/fold.jq")
  printf '%s\n' "${fold/'          | if ($reach_faults | length) > 0 then {errors: $reach_faults}'/'          | if false then {}'}" > "$scratch/loose/libexec/fold.jq"
  check "a copy of the loop whose fold has no R1, R2 or R3" bash -c '! cmp -s "$1" "$2"' _ "$tool/libexec/fold.jq" "$scratch/loose/libexec/fold.jq"
  statements_plan "$base $numbered"' | .programs[-1].recorded += [m(["reach", "harbor", "dock", "-", "room", "write", "orchard", "barn", "grower", "seat", "allowed"]; 2),
      m(["reach", "harbor", "dock", "-", "room", "record", "orchard", "barn", "grower", "seat", "allowed"]; 3), m(["reach", "harbor", "tower", "-", "room", "mail", "harbor", "dock", "keeper", "seat", "allowed"]; 4),
      {term: ["record-path", "records"], origin: at(12)}]'
  check "[C54] 5.141 point 4: the finished table refuses what that copy's terms would give, with exit 1" exit_is 1 loose_wplan
  check "[C54] an enforced seat's write" \
    said "workplace: the fold refuses: seat Harbor Keeper (harbor/dock/keeper), on the enforced floor deck, may write to Orchard Grower (orchard/barn/grower) by its finished reach: a seat of an enforced floor types into no pane (5.121, 5.125 point 10)"
  check "[C54] its record" \
    said "workplace: the fold refuses: seat Harbor Keeper (harbor/dock/keeper), on the enforced floor deck, may read the record of Orchard Grower (orchard/barn/grower) by its finished reach: no seat of an enforced floor reads a saved record (5.124 point 9)"
  check "[C54] and a mail toward a room above it in its office" \
    said "workplace: the fold refuses: seat Harbor Watch (harbor/tower/watch), on the enforced floor deck, may mail Harbor Keeper (harbor/dock/keeper) by its finished reach, a room above its own in the office harbor: inside an office a seat reaches no room cleared more or as much (5.124 point 8, 5.125 point 9)"
  statements_plan "$base"' | .programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "2"; 20), cl("harbor"; "tower"; "-"; "room"; "2"; 21), sc(22),
      m(["reach", "harbor", "dock", "-", "room", "grab", "harbor", "tower", "-", "room", "allowed"]; 2)]'
  check "[C54] the same copy plans a grab between two rooms of one number" exit_is 1 loose_wplan
  check "[C54] and the finished table refuses it, as a room cleared as much" \
    said "workplace: the fold refuses: seat Harbor Keeper (harbor/dock/keeper), on the enforced floor deck, may grab Harbor Watch (harbor/tower/watch) by its finished reach, a room cleared as much as its own in the office harbor: inside an office a seat reaches no room cleared more or as much (5.124 point 8, 5.125 point 9)"
  rm -rf -- "$scratch/loose"
  statements_plan "$floors_terms $lodge_west $harbor_yard | $comms_terms"' | .programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "1"; 20), cl("harbor"; "tower"; "-"; "room"; "2"; 21),
      cl("harbor"; "yard"; "-"; "room"; "2"; 23), sc(22), m(["reach", "-", "-", "-", "workplace", "grab", "harbor", "-", "-", "office", "allowed"]; 2)]'
  check "[C54] a wide term that opens cells from two asking rooms refuses, with exit 1" exit_is 1 wplan
  check "[C54] its lines run by the asking room, then by the target room (5.141 point 7)" \
    test "$(grep -oE "open the room harbor/[a-z]* to the room harbor/[a-z]*" "$scratch/out" | sed 's/open the room //; s/ to the room /</' | tr '\n' ,)" = "harbor/dock<harbor/tower,harbor/yard<harbor/tower,harbor/dock<harbor/yard,harbor/tower<harbor/yard,"
}

t_pointer_floors() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox"
  local extra='| ([.programs[] | select(.path == "lodge/west/ivo/seat.typify")][0] | .path = "lodge/west/ira/seat.typify"
      | .plan |= map(if type == "object" then .term[3] = "ira" else .[3] = "ira" | if .[0] == "pane" then .[4] = "Lodge Ira" else . end end)) as $ira
  | ([.programs[] | select(.path == "orchard/field/reaper/seat.typify")][0] | .path = "orchard/field/gleaner/seat.typify"
      | .plan |= map(if type == "object" then .term[3] = "gleaner" else .[3] = "gleaner" | if .[0] == "pane" then .[4] = "Orchard Gleaner" else . end end)) as $gleaner
  | .programs = .programs[0:-1] + [$ira, $gleaner] + .programs[-1:]'
  local base="$floors_terms $lodge_west $orchard_field $extra | $comms_terms"
  local kinds='| kinds([["harbor", "dock", "keeper", "clerk"], ["harbor", "dock", "pilot", "courier"], ["harbor", "tower", "watch", "clerk"],
      ["orchard", "barn", "grower", "clerk"], ["orchard", "barn", "picker", "scribe"], ["orchard", "field", "reaper", "scribe"],
      ["lodge", "east", "ida", "clerk"], ["lodge", "west", "ivo", "clerk"], ["lodge", "west", "ira", "courier"], ["orchard", "field", "gleaner", "courier"]])'
  # The rooms are numbered 0, 9 and 10, so that a comparison of strings, or one that reads 0 as no number, decides
  # otherwise than the comparison of numbers (5.153).
  local terms='| .programs[-1].recorded += [cl("harbor"; "dock"; "-"; "room"; "0"; 20), cl("harbor"; "tower"; "-"; "room"; "10"; 21),
      cl("orchard"; "barn"; "-"; "room"; "9"; 22), cl("lodge"; "east"; "-"; "room"; "0"; 23), cl("lodge"; "west"; "-"; "room"; "9"; 24), sc(25),
      m(["reach", "orchard", "-", "-", "office", "mail", "-", "-", "-", "workplace", "allowed"]; 2),
      m(["reach", "harbor", "-", "-", "office", "mail", "orchard", "-", "-", "office", "allowed"]; 3),
      m(["reach", "lodge", "-", "-", "floor", "mail", "lodge", "-", "-", "floor", "allowed"]; 4),
      m(["reach", "harbor", "dock", "-", "room", "mail", "harbor", "dock", "-", "room", "allowed"]; 9),
      m(["wake", "clerk", "^waiting>$"]; 5), m(["wake", "scribe", "^waiting>$"]; 6),
      m(["wake-own", "clerk", "enforced", "5.150"]; 7), m(["wake-own", "scribe", "unenforced", "5.151"]; 8)]'

  local refusals=(
    '| .programs[-1].recorded += [m(["wake-own", "clerk", "enforced"]; 30)]|programs/COMMS.typify:30: a wake-own has the words wake-own KIND MODE ITEM, not 3'
    '| .programs[-1].recorded += [m(["wake-own", "ghost", "enforced", "5.150"]; 30)]|programs/COMMS.typify:30: the wake-own names the kind ghost, which the plan does not make'
    '| .programs[-1].recorded += [m(["wake-own", "clerk", "measured", "5.150"]; 30)]|programs/COMMS.typify:30: measured is not enforced or unenforced, the floors where a kind'"'"'s own wake can have been measured'
    '| .programs[-1].recorded += [m(["wake-own", "clerk", "enforced", ""]; 30)]|programs/COMMS.typify:30: the wake-own names no item, and the item that rules the measure is what it carries (5.146)'
    '| .programs[-1].recorded += [m(["wake-own", "clerk", "enforced", "\n"]; 30)]|programs/COMMS.typify:30: the wake-own'"'"'s item holds a control character, which would break the line that plan prints and could be lost where the carrier reads the item back (5.153)'
    '| .programs[-1].recorded += [m(["wake-own", "clerk", "enforced", "5.1\u001b[2J50"]; 30)]|programs/COMMS.typify:30: the wake-own'"'"'s item holds a control character, which would break the line that plan prints and could be lost where the carrier reads the item back (5.153)'
    '| .programs[-1].recorded += [m(["wake-own", "clerk", "enforced", "5.150\u007f"]; 30)]|programs/COMMS.typify:30: the wake-own'"'"'s item holds a control character, which would break the line that plan prints and could be lost where the carrier reads the item back (5.153)'
    '| .programs[-1].recorded += [m(["wake-own", "clerk", "enforced", "5.150\u0085"]; 30)]|programs/COMMS.typify:30: the wake-own'"'"'s item holds a control character, which would break the line that plan prints and could be lost where the carrier reads the item back (5.153)'
    '| .programs[-1].recorded += [m(["wake-own", "courier", "enforced", "5.150"]; 30)]|programs/COMMS.typify:30: the wake-own names the kind courier, which has no wake term: a kind that wakes by itself keeps its pattern for the pointers that stay (5.146)'
    '| .programs[-1].recorded += [m(["wake-own", "clerk", "enforced", "5.160"]; 30)]|two wake-own terms of the kind clerk on an enforced floor differ: 5.150 from programs/COMMS.typify:7, 5.160 from programs/COMMS.typify:30'
  )
  local entry
  for entry in "${refusals[@]}"; do
    statements_plan "$base $kinds $terms ${entry%|*}"
    check "[C93] plan refuses, with exit 1: ${entry##*|}" exit_is 1 wplan
    check "[C93] naming it" said "${entry##*|}"
  done
  # A number the frame compares has at most 15 digits; each input below holds that fault alone.
  local bounds=(
    '| .programs[-1].recorded |= map(if .term == ["clearance", "harbor", "tower", "-", "room", "10"] then .term[5] = "1234567890123456" | .origin.line = 30 else . end)|programs/policy.typify:30: 1234567890123456 has more than 15 digits, and the frame compares no clearance that long'
    '| .programs[-1].recorded += [lb($root + "/tools"; "1234567890123456"; 30)]|programs/policy.typify:30: 1234567890123456 has more than 15 digits, and the frame compares no label that long'
  )
  for entry in "${bounds[@]}"; do
    statements_plan "$base $kinds $terms ${entry%|*}"
    check "[C31] plan refuses, with exit 1: ${entry##*|}" exit_is 1 wplan
    check "[C31] naming it" said "${entry##*|}"
  done
  statements_plan "$comms_terms $wake_kinds $wake_terms"' | .programs[-1].recorded += [m(["wake-own", "clerk", "enforced", "5.150"]; 30)]'
  check "[C93] 5.146: a wake-own in a plan without floors refuses it, with exit 1" exit_is 1 wplan
  check "[C93] naming it" said "wake-own speaks only in a plan with floors, and this plan holds none (the wake-own at programs/COMMS.typify:30)"

  statements_plan "$base $kinds $terms"
  check "plan of floors with numbered rooms, wakes, and a kind's own wake measured on each mode" exit_is 0 wplan
  check "[C93] a seat's wake carries its kind's own wake for its floor's mode, and none for the other" \
    test "$(seat_of keeper '.wake.own | [.mode, .item]')$(seat_of grower '.wake | has("own")')$(seat_of picker '.wake.own | [.mode, .item]')" = '["enforced","5.150"]false["unenforced","5.151"]'
  check "[C93] plan prints it on the seat's wake line" \
    said "  wake: its pane is ready when one of the last five lines of its screen that are not empty matches \"^waiting>\$\", by its kind's term (programs/COMMS.typify:5); on this floor its kind wakes by itself, as 5.150 rules, so mail to it from a room cleared less is delivered without a pointer (programs/COMMS.typify:7)"
  check "[C104] 5.146: plan names a room with no number on an unenforced floor too" \
    said "room orchard/field, on the unenforced floor bridge, has no number: the pointer's direction reads it as cleared least (5.125 point 7, 5.146)"
  wp why "Harbor Keeper" "$root" > "$scratch/out" 2>&1
  check "[C93] why names a seat's own wake, its item and its term" \
    said "own wake: on this floor the seat's kind wakes by itself, as 5.150 rules, by its kind's wake-own term, from programs/COMMS.typify:7; mail to it from a room cleared less is delivered without a pointer"
  check "plan whose work directory cannot be made stops there, with exit 2" exit_is 2 env TMPDIR="$scratch/none" PATH="$STUB_DIR/bin:$PATH" "$BASH" "$loop" plan
  check "naming it in its last line, and writing nothing without it" \
    bash -c 'tail -n 1 "$1" | grep -qF "workplace: cannot make $2/workplace-plan-" && ! grep -qF LanguageDeclarations "$1"' _ "$scratch/out" "$scratch/none"
  check "build whose work directory cannot be made stops there, with exit 2" exit_is 2 env TMPDIR="$scratch/none" "$BASH" "$loop" build
  check "naming it in its last line" bash -c 'tail -n 1 "$1" | grep -qF "workplace: cannot make $2/workplace-build-"' _ "$scratch/out" "$scratch/none"
  check "build" exit_is 0 wp build
  check "[C56] with floors mail.json gives each seat its kind's own wake for its floor's mode, null where none" \
    test "$(jq -c '[.seats[] | [.name, .number, (if has("own") then .own else "absent" end)]]' "$clone/BUILD/shared/$(top_gen)/mail.json")" = '[["Harbor Keeper",0,"5.150"],["Harbor Pilot",0,null],["Harbor Watch",10,"5.150"],["Orchard Grower",9,null],["Orchard Picker",9,"5.151"],["Lodge Ida",0,"5.150"],["Lodge Ivo",9,"5.150"],["Orchard Reaper",null,"5.151"],["Lodge Ira",9,null],["Orchard Gleaner",null,null]]'

  # Runs made by hand, with no panes: the decision is taken at delivery and needs none (5.146 point 5). Each floor has
  # its run and its carrier, which serves its own floor's writers, and the three deliver at one time on one store under
  # its lock (5.160 point 8, 5.162 point 1).
  local f
  for f in bridge deck lodge; do
    mkdir -p -- "$clone/BUILD/RUN/$f/carrier"
    printf '%s\n' '{"slots": {}}' > "$clone/BUILD/RUN/$f/state.json"
  done
  request grower g1.md "to: Harbor Keeper, Harbor Watch, Harbor Pilot, Lodge Ivo, Orchard Grower" "subject: from the barn" --- "one"
  request reaper r1.md "to: Harbor Keeper, Orchard Picker, Orchard Grower" "subject: from the field" --- "two"
  request ivo v1.md "to: Lodge Ida, Lodge Ira" "subject: from the west" --- "three"
  request ida d1.md "to: Lodge Ivo, Lodge Ida" "subject: from the east" --- "four"
  request keeper k1.md "to: Orchard Picker" "subject: from the dock" --- "five"
  request grower g2.md "to: Orchard Reaper, Orchard Gleaner" "subject: to the field" --- "six"
  request gleaner l1.md "to: Orchard Reaper" "subject: within the field" --- "seven"
  request watch w1.md "to: Orchard Picker" "subject: from the tower" --- "eight"
  request pilot p1.md "to: Harbor Keeper" "subject: within the dock" --- "nine"
  local carrier s started
  local -a carriers=()
  s=$(state_of)
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  for f in bridge deck lodge; do
    "$BASH" "$clone/BUILD/bin/workplace" carry "$f" > "$scratch/carry-$f" 2>&1 &
    carriers+=("$!")
  done
  check "[C59] 5.162: the three floors' carriers, on runs made by hand at one time, deliver the nine mails" \
    bash -c 'for a in "$@"; do [[ $a == "ok "* ]] || exit 1; done' _ "$(answer_of grower g1.md)" "$(answer_of reaper r1.md)" "$(answer_of ivo v1.md)" \
      "$(answer_of ida d1.md)" "$(answer_of keeper k1.md)" "$(answer_of grower g2.md)" "$(answer_of gleaner l1.md)" "$(answer_of watch w1.md)" "$(answer_of pilot p1.md)"
  for f in bridge deck lodge; do rm -rf -- "$clone/BUILD/RUN/$f/carrier"; done
  wait "${carriers[@]}"
  # The record is read line by line, and a line that does not parse is passed over, as the carrier passes it over.
  idof() { jq -r -R --arg w "$1" --arg r "$2" 'fromjson? | objects | select(.seat == $w and .request == $r and .action == "mail" and .outcome == "ok") | .id' "$s/comms/record"; }
  decided() { jq -r -R --arg id "$1" 'fromjson? | objects | select(.seat == "the frame" and .covers == [$id]) | "\(.target[0]):\(.outcome)"' "$s/comms/record" | tr '\n' ,; }
  due() { jq -c --arg id "$1" '[.seats[] | select(.ids | index($id)) | .name]' "$s/comms/wake.json"; }
  together() {
    jq -R -s -e --arg id "$2" '[split("\n")[] | fromjson? | objects] | (to_entries | map(select(.value.seat == "the frame" and .value.covers == [$id] and (.value | has("length") | not)) | .key)) as $k
      | (to_entries | map(select(.value.id == $id and .value.action == "mail") | .key)) as $m
      | ($m | length) == 1 and (($k | length) == 0 or $k == [range($m[0] - ($k | length); $m[0])])' "$1" > /dev/null
  }
  all_together() { local f=$1 id; shift; for id in "$@"; do together "$f" "$id" || return 1; done; }
  local g r v d k g2 l w p store
  g=$(idof "Orchard Grower" g1.md) r=$(idof "Orchard Reaper" r1.md) v=$(idof "Lodge Ivo" v1.md) d=$(idof "Lodge Ida" d1.md)
  k=$(idof "Harbor Keeper" k1.md) g2=$(idof "Orchard Grower" g2.md) l=$(idof "Orchard Gleaner" l1.md) w=$(idof "Harbor Watch" w1.md) p=$(idof "Harbor Pilot" p1.md)
  store=$(jq -r '.store' "$clone/BUILD/shared/$(top_gen)/mail.json")
  check "[C94] 5.146: toward a room cleared more whose kind wakes by itself, withheld, 0 as the reader's number below 9; a kind with no pattern and the writer, none; each reader on its own, and a due reader has no line" \
    test "$(decided "$g")" = "Harbor Keeper:withheld,Harbor Pilot:none,Orchard Grower:none,"
  check "[C94] toward rooms of the same number and cleared less, due, in wake.json: a reader at 10 from a writer at 9 is cleared less (5.153)" test "$(due "$g")" = '["Harbor Watch","Lodge Ivo"]'
  check "[C94] 5.153: a reader at 0 from a writer at 0 is cleared as much, and due even where its kind wakes by itself" test "$(decided "$p")$(due "$p")" = '["Harbor Keeper"]'
  check "[C94] 5.153: and a reader at 9 from a writer at 10 is cleared more, and withheld: the numbers are compared as numbers" \
    test "$(decided "$w")$(due "$w")|$(jq -r -R --arg id "$w" 'fromjson? | objects | select(.seat == "the frame" and .covers == [$id]) | .reason' "$s/comms/record")" = "Orchard Picker:withheld,[]|the room of Orchard Picker, at 9, is cleared more than the writer's, at 10, and its kind wakes by itself on its floor, as 5.151 rules (5.124 point 8, 5.125 point 17)"
  check "[C94] a writer with no number counts as cleared least: withheld toward a numbered room above it, and on an unenforced floor by its mode's own wake; due by an own wake of the other mode" \
    test "$(decided "$r")$(due "$r")" = 'Harbor Keeper:withheld,Orchard Picker:withheld,["Orchard Grower"]'
  check "[C96] the withheld line of a writer with no number says so" \
    test "$(jq -r -R --arg id "$r" 'fromjson? | objects | select(.seat == "the frame" and .covers == [$id]) | .reason' "$s/comms/record" | tr '\n' '|')" = "the room of Harbor Keeper, at 0, is cleared more than the writer's, with no number, and its kind wakes by itself on its floor, as 5.150 rules (5.124 point 8, 5.125 point 17)|the room of Orchard Picker, at 9, is cleared more than the writer's, with no number, and its kind wakes by itself on its floor, as 5.151 rules (5.124 point 8, 5.125 point 17)|"
  check "[C94] on a floor of rooms the numbers decide the pointer: from 9 to 0 withheld, and a kind with no pattern there gets none (5.132 point 4)" \
    test "$(decided "$v")" = "Lodge Ida:withheld,Lodge Ira:none,"
  check "[C94] on a floor of rooms from 0 to 9 due, 0 as the writer's number, and the writer's own copy none" test "$(decided "$d")$(due "$d")" = 'Lodge Ida:none,["Lodge Ivo"]'
  check "[C94] toward a room cleared less whose kind wakes by itself on its floor, due by the direction: from 0 to 9, across floors" test "$(decided "$k")$(due "$k")" = '["Orchard Picker"]'
  check "[C94] toward a reader with no number, due even where its kind wakes by itself; and a kind with no pattern on an unenforced floor gets none" \
    test "$(decided "$g2")$(due "$g2")" = 'Orchard Gleaner:none,["Orchard Reaper"]'
  check "[C94] 5.146: between two rooms with no number, both cleared least, due even where the reader's kind wakes by itself" \
    test "$(decided "$l")$(due "$l")" = '["Orchard Reaper"]'
  check "[C96] a withheld line names the mail, both rooms' numbers and the item" \
    test "$(jq -r -R --arg id "$g" 'fromjson? | objects | select(.seat == "the frame" and .covers == [$id] and .outcome == "withheld") | .reason' "$s/comms/record")" = "the room of Harbor Keeper, at 0, is cleared more than the writer's, at 9, and its kind wakes by itself on its floor, as 5.150 rules (5.124 point 8, 5.125 point 17)"
  check "[C96] and a none line its reason" \
    test "$(jq -r -R --arg id "$g" 'fromjson? | objects | select(.seat == "the frame" and .covers == [$id] and .outcome == "none") | .reason' "$s/comms/record" | tr '\n' '|')" = "its kind has no wake pattern, so no pointer is typed for it (C94)|the writer's own mail is pointed out to no one (5.79)|"
  check "[C96] each mail's decision lines stand together, just before the line of its delivery" \
    all_together "$s/comms/record" "$g" "$r" "$v" "$d" "$k" "$g2" "$l" "$w" "$p"
  check "[C96] each decision line carries the time it was made, in the record's form" \
    bash -c 'jq -R -s -e --arg t "$2" "[split(\"\n\")[] | fromjson? | objects | select(.seat == \"the frame\" and .action == \"wake\" and (has(\"length\") | not))] | length > 0 and all(.at | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$\") and . >= \$t)" "$1" > /dev/null' _ "$s/comms/record" "$started"
  check "[C59] the writer is told only that its mail was delivered" test "$(cat "$s/comms/Orchard Grower/answers/g1.md")" = "ok $g"
  check "[C59] 5.146 point 3: every reader sees its mail in in, withheld, due or none alike, the same file as the writer's sent" \
    bash -c 's=$1; shift; while (( $# )); do w=$1 id=$2 n=$3; shift 3; for (( i = 0; i < n; i++ )); do cmp -s "$s/$1/in/$id.md" "$s/$w/sent/$id.md" || exit 1; shift; done; done' _ "$store" \
      "Orchard Grower" "$g" 5 "Harbor Keeper" "Harbor Watch" "Harbor Pilot" "Lodge Ivo" "Orchard Grower" \
      "Orchard Reaper" "$r" 3 "Harbor Keeper" "Orchard Picker" "Orchard Grower" \
      "Lodge Ivo" "$v" 2 "Lodge Ida" "Lodge Ira" \
      "Lodge Ida" "$d" 2 "Lodge Ivo" "Lodge Ida" \
      "Harbor Keeper" "$k" 1 "Orchard Picker" \
      "Orchard Grower" "$g2" 2 "Orchard Reaper" "Orchard Gleaner" \
      "Orchard Gleaner" "$l" 1 "Orchard Reaper" \
      "Harbor Watch" "$w" 1 "Orchard Picker" \
      "Harbor Pilot" "$p" 1 "Harbor Keeper"

  # A carrier stopped between a delivery's commit and the end of its decisions. It had decided for Ira by a line and
  # noted Grower in wake.json; Watch it had found due and not saved, and Ida it had not reached. The commit also gives
  # the mail to a box that the build no longer makes. A torn line stands in the record. The next carrier answers the
  # mail and decides for Gone, Watch and Ida alone, in the store's order, Watch due from the time of the delivery.
  # The torn line was cut before its newline, so the next carrier ends it before it writes (5.153).
  mkdir -p -- "$store/Gone Seat/in"
  printf '%s\n' "a mail of the stopped carrier" > "$store/Lodge Ida/in/recovered-1.md"
  local box
  for box in "Gone Seat" "Harbor Watch" "Lodge Ira" "Orchard Grower"; do cp -- "$store/Lodge Ida/in/recovered-1.md" "$store/$box/in/recovered-1.md"; done
  cp -- "$store/Lodge Ida/in/recovered-1.md" "$store/Lodge Ivo/sent/recovered-1.md"
  git -C "$store" add -A > /dev/null 2>&1 \
    && GIT_COMMITTER_DATE="2026-01-02T03:04:05Z" git -C "$store" -c user.name=test -c user.email=test@test commit -q -m "deliver recovered-1" > /dev/null 2>&1
  printf '%s\n' '{"at":"2026-01-01T00:00:00Z","seat":"the frame","action":"wake","target":["Lodge Ira"],"covers":["recovered-1"],"outcome":"none","reason":"its kind has no wake pattern, so no pointer is typed for it (C94)"}' >> "$s/comms/record"
  printf '%s' '{"at":"2026' >> "$s/comms/record"
  jq '.seats["Orchard Grower"] |= (.count += 1 | .ids += ["recovered-1"]) | del(.seats["Harbor Watch"])' "$s/comms/wake.json" > "$scratch/wake" && cat -- "$scratch/wake" > "$s/comms/wake.json"
  printf '%s\n' '{"id":"recovered-1","box":"Lodge Ivo","request":"v9.md","action":"mail","seat":"Lodge Ivo"}' > "$s/floors/lodge/comms/serving"
  mkdir -p -- "$clone/BUILD/RUN/lodge/carrier"
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  "$BASH" "$clone/BUILD/bin/workplace" carry lodge > "$scratch/carry" 2>&1 &
  carrier=$!
  check "[C57] a carrier that finds a delivery's commit of a stopped carrier of its floor answers it ok" test "$(answer_of ivo v9.md)" = "ok recovered-1"
  rm -rf -- "$clone/BUILD/RUN/lodge/carrier"
  wait "$carrier"
  check "[C96] 5.146: and decides for each reader the stopped carrier had not decided, by a line or in wake.json, and for no other, in the store's order" \
    test "$(decided recovered-1)$(jq -c '.seats["Orchard Grower"].ids | map(select(. == "recovered-1")) | length' "$s/comms/wake.json")" = "Lodge Ira:none,Gone Seat:none,Lodge Ida:withheld,1"
  check "[C96] a reader whose seat the build no longer makes gets a none line, with its reason" \
    test "$(jq -r -R 'fromjson? | objects | select(.covers == ["recovered-1"] and .target == ["Gone Seat"]) | .reason' "$s/comms/record")" = "the build no longer makes this seat, so no pointer is typed for it"
  check "[C94] a reader the stopped carrier had found due and not saved is due again, from the time of the delivery's commit" \
    test "$(jq -c '.seats["Harbor Watch"] | [.count, .ids, .since]' "$s/comms/wake.json")" = '[1,["recovered-1"],"2026-01-02T03:04:05Z"]'
  check "[C57] its line names the readers the delivery's commit gave the mail to, in the store's order" \
    test "$(jq -c -R 'fromjson? | objects | select(.id == "recovered-1" and .action == "mail") | [.target, .outcome]' "$s/comms/record")" = '[["Gone Seat","Harbor Watch","Lodge Ida","Lodge Ira","Orchard Grower"],"ok"]'
  check "[C96] the recovered mail's decision lines, the stopped carrier's and the new one's, stand together just before its ok line" together "$s/comms/record" recovered-1
  check "[C57] 5.153: a torn last line cut before its newline swallows nothing: it stands alone, and every line the next carrier writes after it parses by itself" \
    bash -c 'n=$(grep -c -xF "{\"at\":\"2026" "$1") && [[ $n == 1 ]] && tail -n +$(( $(grep -n -xF "{\"at\":\"2026" "$1" | cut -d: -f1) + 1 )) "$1" \
      | jq -R -s -e "split(\"\n\") as \$l | (\$l | last) == \"\" and (\$l[:-1] | length > 0 and all(.[]; (try fromjson catch null) | type == \"object\"))" > /dev/null' _ "$s/comms/record"
  check "[C57] 5.153: a recovered decision line carries the time it is written, at the restart, and only the due entry the commit's time" \
    bash -c 'jq -R -s -e --arg t "$2" "[split(\"\n\")[] | fromjson? | objects | select(.covers == [\"recovered-1\"] and (.target == [\"Gone Seat\"] or .target == [\"Lodge Ida\"]))] | length == 2 and all(.[]; .at >= \$t)" "$1" > /dev/null' _ "$s/comms/record" "$started"

  rm -rf -- "$clone/BUILD/RUN"
  wp status > "$scratch/out" 2>&1
  check "[C95] status lists the due readers, each with its count" \
    bash -c 'for line in "Harbor Keeper (harbor/dock/keeper): 1" "Harbor Watch (harbor/tower/watch): 1" "Lodge Ivo (lodge/west/ivo): 2" "Orchard Grower (orchard/barn/grower): 2" "Orchard Picker (orchard/barn/picker): 1" "Orchard Reaper (orchard/field/reaper): 2"; do
      grep -qF "wake    $line delivered and not yet pointed out" "$1" || exit 1; done' _ "$scratch/out"
  check "[C95] and no reader that is due nothing: withheld, or of a kind with no pattern" bash -c '! grep -qE "^wake    (Lodge Ida|Harbor Pilot|Lodge Ira|Orchard Gleaner) " "$1"' _ "$scratch/out"
}

# Floors up (5.160 point 8, 5.162, 5.167): each enforced floor on a run socket stands on its own server in RUN/F, with
# its own carrier, and goes down alone; the floor on the default socket is refused in 4a.
t_floors_up() {
  scoped_clone
  floors_clone
  printf '%s\n' 'set -g @floor-own deck' > "$clone/floors/deck.conf"
  mkdir -p -- "$root/mailbox"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
      m(["reach", "harbor", "-", "-", "office", "mail", "lodge", "-", "-", "floor", "allowed"]; 2),
      m(["reach", "lodge", "-", "-", "floor", "mail", "harbor", "-", "-", "office", "allowed"]; 3),
      m(["reach", "harbor", "-", "-", "office", "grab", "lodge", "-", "-", "floor", "allowed"]; 4),
      m(["reach", "harbor", "dock", "-", "room", "grab", "harbor", "dock", "-", "room", "allowed"]; 5),
      m(["reach", "harbor", "dock", "-", "room", "mail", "harbor", "dock", "-", "room", "allowed"]; 6)]'
  check "plan of three floors with mail between the harbor and the lodge" exit_is 0 wplan
  check "build" exit_is 0 wp build
  local s=$HOME/.local/state/workplace/$label
  check "[C101] 5.160 point 8: with floors, up names its floor, or refuses with exit 2" exit_is 2 wp up
  check "[C101] saying so" said "with floors, up names its floor: workplace up F"
  check "[C101] up of a floor the build does not make refuses, with exit 2" exit_is 2 wp up ghost
  check "[C101] naming it" said "the build has no floor ghost"
  if [[ $(nnp_of $$) == NoNewPrivs:0 ]]; then
    check "[C101] 4a2: the default floor starts outside the bar" exit_is 0 wp up bridge
    check "[C101] and makes its own floor run" test -d "$run/bridge"
    check "[C101] default floor down before the two enforced floors" exit_is 0 wp down bridge
  else
    skip "[C101] 4a2: the default floor's positive path requires an unbarred caller"
    check "[C101] a barred caller refuses the default floor" exit_is 1 wp up bridge
  fi
  check "up deck" exit_is 0 wp up deck
  check "[C21] saying its floor" said "up: the floor deck,"
  check "up lodge" exit_is 0 wp up lodge
  check "[C68] each floor stands on its own server, at its own socket in RUN/F" bash -c '[[ -S $1/deck/$2 && -S $1/lodge/$2 && ! -e $1/$2 ]]' _ "$run" "$label"
  check "[C68] two servers, two processes" bash -c '[[ -n $1 && -n $2 && $1 != "$2" ]]' _ "$(on deck T display-message -p '#{pid}')" "$(on lodge T display-message -p '#{pid}')"
  check "[C8] the deck's server holds the harbor's session alone" on deck sessions_are "Harbor "
  check "[C8] the lodge's server holds the lodge's own session alone" on lodge sessions_are "Lodge "
  check "[C21] each floor's run holds its own state and seats" \
    bash -c 'for f in deck lodge; do for x in state.json ledger checks calls.jsonl tables.json seats carrier tmux.conf; do [[ -e $1/$f/$x ]] || exit 1; done; done' _ "$run"
  check "[C21] RUN/deck holds the deck's three seats, RUN/lodge the lodge's one" \
    bash -c '[[ $(ls "$1/deck/seats" | wc -l) == 3 && $(ls "$1/lodge/seats" | wc -l) == 1 ]]' _ "$run"
  check "[C21] state.json names the floor, the top and the generations it read" \
    test "$(jq -c '[.floor, .top, (.generations | keys)]' "$run/deck/state.json")" = "[\"deck\",\"$(sha256sum < "$clone/BUILD/MANIFEST" | cut -c1-64)\",[\"floor\",\"shared\"]]"
  check "[C57] each floor has a carrier of its own" bash -c '[[ -n $1 && -n $2 && $1 != "$2" ]]' _ "$(carrier_pid deck)" "$(carrier_pid lodge)"
  check "[C102] the floor's lock and its holder stand in its state, mode 600" \
    bash -c '[[ $(stat -c %a "$1/floors/deck/up.lock") == 600 && $(stat -c %a "$1/floors/deck/up.holder") == 600 ]]' _ "$s"
  check "[C20] up of a floor that is up refuses, with exit 1" exit_is 1 wp up deck
  check "[C20] saying so" said "the floor deck is up already"
  check "[C53] each floor's server carries the clone's mark" \
    bash -c '[[ -n $1 && $1 == "$2" && $1 == "$3" ]]' _ "$(cd -- "$clone" && pwd -P)" "$(on deck T show-options -gqv @workplace-clone)" "$(on lodge T show-options -gqv @workplace-clone)"
  check "[C17] 5.160 point 8: exec finds a seat's floor and prints its call" exit_is 0 wp exec --print -- "Lodge Ida"
  local stray_gen
  stray_gen=$(sed -n 's|^[0-9a-f]\{64\}  \(floors/deck/[0-9]*\)/MANIFEST$|\1|p' "$clone/BUILD/MANIFEST")
  chmod u+w -- "$clone/BUILD/$stray_gen"
  : > "$clone/BUILD/$stray_gen/stray"
  check "[C5] review of 4a: exec of a lodge seat verifies the lodge's generation alone, so a fault in the deck's stops it not" exit_is 0 wp exec --print -- "Lodge Ida"
  check "[C5] while exec of a deck seat is refused, with exit 2" exit_is 2 wp exec --print -- "Harbor Keeper"
  rm -f -- "$clone/BUILD/$stray_gen/stray"
  check "[C98] 5.160 point 8: with floors, restart names its floor, or refuses with exit 2" exit_is 2 wp restart
  check "[C98] saying so" said "with floors, restart names its floor: workplace restart F"
  check "[C98] restart of a seat of another floor than the one named refuses, with exit 2" exit_is 2 wp restart deck "Lodge Ida"
  check "[C98] restart of a floor with no seat whose program ended starts nothing, with exit 0" exit_is 0 wp restart lodge
  check "[C98] saying so" said "restart: no seat's program has ended, and nothing is started"
  printf '%s\n' '{"command": "restart lodge", "pid": 4242, "at": "2026-11-14T00:00:00Z"}' > "$s/floors/lodge/up.holder"
  flock -o "$s/floors/lodge/up.lock" sleep 6 &
  local lock_holder=$!
  check "the test holds the lodge's floor lock" eventually bash -c '! flock -n "$1" true' _ "$s/floors/lodge/up.lock"
  check "[C20] 5.160 point 8: restart of a floor whose lock another command holds refuses, with exit 1" exit_is 1 wp restart lodge
  check "[C20] naming the command and its process" said "restart lodge holds the floor lodge, process 4242; run it again when that ends"
  check "[C20] and up of that floor refuses so too, before it looks for its run" exit_is 1 wp up lodge
  check "[C20] naming them" said "restart lodge holds the floor lodge, process 4242"
  wait "$lock_holder"
  chmod 644 "$s/floors/lodge/up.lock"
  check "[C102] review of 4a: up refuses a floor whose lock is not a file of this user's with mode 600, with exit 1" exit_is 1 wp up lodge
  check "[C102] naming it" said "$s/floors/lodge/up.lock is not a file of this user's with mode 600"
  chmod 600 "$s/floors/lodge/up.lock"
  check "[C101] review of 4a: up of two floors refuses, with exit 2" exit_is 2 wp up deck lodge
  check "[C101] saying so" said "up takes one floor"
  check "[C18] review of 4a: with floors, a bare down refuses, with exit 2" exit_is 2 wp down
  check "[C18] saying so" said "with floors, down names its floor: workplace down F"
  check "[C18] down of two floors refuses, with exit 2" exit_is 2 wp down deck lodge
  check "[C18] down of a floor the build does not make refuses, with exit 2" exit_is 2 wp down ghost
  check "[C18] naming it" said "the build has no floor ghost"
  mkdir -- "$run/ghost"
  check "[C18] review of 4a: a floor the build does not make whose RUN/F stands is taken for a floor, so that no run is stranded" exit_is 2 wp down ghost
  check "[C18] and found not finished" said "the run under $run/ghost did not finish up"
  rmdir -- "$run/ghost"
  check "[C57] review of 4a: with floors, carry names its floor, or refuses with exit 2" exit_is 2 "$BASH" "$clone/BUILD/bin/workplace" carry
  check "[C57] saying so" said "with floors, carry names its floor: workplace carry F; up starts it"
  check "[C57] carry of a floor the build does not make refuses, with exit 2" exit_is 2 "$BASH" "$clone/BUILD/bin/workplace" carry ghost
  check "[C57] a second carrier of a floor that is up ends, with exit 2" exit_is 2 "$BASH" "$clone/BUILD/bin/workplace" carry deck
  check "[C57] saying that another serves that floor" said "another carrier serves the floor deck of the workplace whose state is $s; this one ends"
  check "[C57] and the floor's own carrier still runs" kill -0 "$(carrier_pid deck)"
  check "[C22] 4a2: the floor's own file is read before the frame's set" \
    test "$(on deck T show-options -gqv @floor-own)" = deck
  local kpane
  kpane=$(on deck pane_by_title "Harbor Keeper")
  on deck T send-keys -t "$kpane" C-c
  check "[C98] keeper's program ends, and its pane stays, dead" on deck eventually_long dead_pane "Harbor Keeper"
  check "[C98] review of 4a: restart deck starts keeper again in its pane" exit_is 0 wp restart deck "Harbor Keeper"
  check "[C98] saying who asked" said "restart: Harbor Keeper is started again in its pane $kpane, asked by $(id -un) (uid $EUID) at "
  check "[C98] its record stands in the floor's own state" bash -c 'jq -e "select(.seat == \"Harbor Keeper\")" "$1" > /dev/null' _ "$s/floors/deck/restarts"
  check "[C98] and keeper's pane is alive again" on deck eventually_long live_pane "Harbor Keeper"
  request keeper k1.md "to: Lodge Ida" "subject: across" --- "body"
  check "[C59] a mail from the deck to the lodge is delivered" answered_ok keeper k1.md
  request ida i1.md "to: Harbor Keeper" "subject: back" --- "body"
  check "[C59] and one from the lodge to the deck" answered_ok ida i1.md
  check "[C61] build makes what each carrier takes into in its own floor's state, and none in S/comms" \
    bash -c '[[ -d $1/floors/deck/comms/taken && -d $1/floors/lodge/comms/taken && ! -e $1/comms/taken ]]' _ "$s"
  request keeper g1.grab "seat: Lodge Ida"
  check "[C60] 5.162 point 1: a grab across floors is refused until 4b" answered keeper g1.grab "refused a grab or a write across floors comes with S2's stop 4b"
  # A stopped carrier's torn last line, and then a grab, whose line is written after the store's lock is let go. The
  # refusal's line is awaited first, so that the torn bytes stand last.
  check "the refusal's line stands in the record" eventually bash -c 'grep -q "\"request\":\"g1.grab\"" "$1"' _ "$s/comms/record"
  printf '%s' '{"at":"2026' >> "$s/comms/record"
  request keeper g2.grab "seat: Harbor Pilot"
  check "a grab of a seat of its own floor is served" answered_ok keeper g2.grab
  check "[C57] 5.153: a grab's line, decided after the store's lock is let go, takes a hold of its own, ends the torn last line first, and parses by itself" \
    eventually bash -c '[[ $(jq -R -c "fromjson? | select(.request == \"g2.grab\") | .outcome" "$1") == "\"ok\"" ]]' _ "$s/comms/record"
  check "[C57] and the torn bytes stay as a line of their own" bash -c 'grep -qx "{\"at\":\"2026" "$1"' _ "$s/comms/record"
  wp status > "$scratch/out" 2>&1
  check "[C22] bare status reports every floor" bash -c 'grep -qx "run: floor deck is up, workplace-[0-9a-f]*" "$1" && grep -qx "run: floor lodge is up, workplace-[0-9a-f]*" "$1" && grep -qx "run: floor bridge is down" "$1"' _ "$scratch/out"
  check "[C22] 4a2: status names the sealed config and following frame set" said "sealed floor configuration, then the frame's set"
  check "[C22] 4a2: every floor has a configuration line" test "$(grep -c '^conf ' "$scratch/out")" = 3
  check "[C22] 4a2: no obsolete 4a capability warning remains" bash -c '! grep -q "^lacks " "$1"' _ "$scratch/out"
  # g2.grab's line took a hold of its own, and the carrier removes the holder as it lets that hold go, after the line;
  # the status that the check of no holder below reads is taken once the store's lock is free.
  eventually_long flock -n "$s/mail" true || note "    the store's lock $s/mail is still held after a minute"
  check "[C22] status of one floor" exit_is 0 wp status deck
  check "[C22] reports that floor alone" bash -c 'grep -qx "run: floor deck is up, workplace-[0-9a-f]*" "$1" && ! grep -q "floor lodge" "$1"' _ "$scratch/out"
  check "[C22] 5.160: with the shared generation and the floor's, as the top names them" \
    bash -c 'grep -qx "shared  generation $2" "$1" && grep -qx "floor   deck: generation $3" "$1"' _ "$scratch/out" \
      "$(sed -n 's|^[0-9a-f]*  shared/\([0-9]*\)/MANIFEST$|\1|p' "$clone/BUILD/MANIFEST")" "$(sed -n 's|^[0-9a-f]*  floors/deck/\([0-9]*\)/MANIFEST$|\1|p' "$clone/BUILD/MANIFEST")"
  check "[C57] 5.162: with no hold of the store's lock, status prints no holder" bash -c '! grep -q "^store " "$1"' _ "$scratch/out"
  printf '%s\n' "{\"floor\": \"deck\", \"pid\": $(carrier_pid deck), \"at\": \"2026-11-14T00:00:00Z\", \"id\": \"20261114T000000Z-000042\"}" > "$s/store.holder"
  check "[C57] 5.162: a holder that is the running carrier of the floor it names is reported as holding the store's lock" exit_is 0 wp status deck
  check "[C57] naming the floor, the process, the time and the request" \
    said "store   held by the carrier of the floor deck, process $(carrier_pid deck), since 2026-11-14T00:00:00Z, for the request 20261114T000000Z-000042"
  printf '%s\n' "{\"floor\": \"deck\", \"pid\": $(carrier_pid lodge), \"at\": \"2026-11-14T00:00:00Z\", \"id\": null}" > "$s/store.holder"
  check "[C57] 5.162: a holder that names a process that is no carrier of that floor is reported as a name the next hold replaces, with exit 0" exit_is 0 wp status deck
  check "[C57] saying so" said "names the carrier of the floor deck, process $(carrier_pid lodge), and no carrier of that floor runs as $(carrier_pid lodge); the next hold replaces it"
  rm -f -- "$s/store.holder"
  local lodge_pid lodge_carrier
  lodge_pid=$(on lodge T display-message -p '#{pid}')
  lodge_carrier=$(carrier_pid lodge)
  local deck_pid
  deck_pid=$(on deck T display-message -p '#{pid}')
  check "[C18] down deck" exit_is 0 wp down deck
  check "[C18] review of 4a: takes the deck's server away, its process ended, and its run" \
    eventually bash -c '[[ -n $1 && ! -e $2/deck ]] && ! kill -0 "$1" 2> /dev/null' _ "$deck_pid" "$run"
  check "[C18] and leaves the lodge up: its run, its server and its carrier" \
    bash -c '[[ -d $1/lodge && $2 == "$3" && -n $4 ]] && kill -0 "$4"' _ "$run" "$lodge_pid" "$(on lodge T display-message -p '#{pid}')" "$lodge_carrier"
  check "[C17] exec of a seat whose floor is not up refuses, with exit 2" exit_is 2 wp exec --print -- "Harbor Keeper"
  check "[C17] saying so" said "nothing is up on the floor deck"
  request keeper k9.md "to: Lodge Ida" "subject: waits" --- "body"
  request pilot p9.md "to: Lodge Ida" "subject: waits" --- "body"
  check "[C22] status of a floor that is down, with requests of its writers waiting, exits 0" exit_is 0 wp status deck
  check "[C22] and counts them: none is served until up" said "waiting the floor deck is down: 2 requests of its writers wait in out, and none is served until up deck"
  sleep 2
  check "[C57] 5.160 point 8: the other floor's carrier serves none of them" \
    bash -c '[[ -e $1/comms/Harbor\ Keeper/out/k9.md && -e $1/comms/Harbor\ Pilot/out/p9.md ]]' _ "$s"
  check "[C18] down of a floor that is down says so, with exit 0" exit_is 0 wp down deck
  check "[C18] saying it" said "down: the floor deck is not up"
  check "[C99] unbuild refuses while a floor is up, with exit 1" exit_is 1 wp unbuild
  check "[C99] naming the floor" said "unbuild refuses: the floor lodge is up"
  check "down lodge" exit_is 0 wp down lodge
  check "[C99] unbuild, with every floor down" exit_is 0 wp unbuild
  check "[C99] removes the empty RUN with the build" test ! -e "$clone/BUILD"
}

t_floor_blocking_config() {
  scoped_clone
  floors_clone
  printf '%s\n' 'run-shell "sleep 12"' > "$clone/floors/deck.conf"
  statements_plan "$floors_terms"
  check "[C105] blocking config: plan" exit_is 0 wplan
  check "[C105] blocking config: build" exit_is 0 wp build
  local before=$SECONDS
  check "[C105] blocking config: up ends with refusal" exit_is 1 wp up deck
  check "[C105] blocking config: up is bounded" test "$(( SECONDS - before ))" -lt 30
  check "[C105] blocking config: diagnostics identify the floor and its file" said "RUN/deck/tmux.conf"
  local socket=$run/deck/$label
  if [[ -S $socket ]]; then timeout 15 tmux -S "$socket" kill-server || fail "cannot stop the blocking-config test's server"; fi
  rm -rf -- "$run/deck"
  check "[C105] blocking config: unbuild" exit_is 0 wp unbuild
}

t_unit_invocation_ownership() {
  local unit=workplace-carrier-default.service
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    skip "invocation ownership: no user manager"
    return 0
  fi
  if [[ $(systemctl --user show -p LoadState --value "$unit" 2>/dev/null) != not-found ]]; then
    skip "invocation ownership: the default-named unit already belongs to another run; untouched"
    return 0
  fi
  local first=$clone first_run=$run second=$root/config2 first_inv second_inv
  label=default
  render default > "$scratch/plan.json"
  scoped_clone
  jq '.socket = "default"' "$clone/workplace.json" > "$scratch/w" && cp "$scratch/w" "$clone/workplace.json"
  mkdir -p -- "$root/records"
  statements_plan "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record-chain") | .term[1]) = "journal"'
  check "[C72] invocation ownership: first plan" exit_is 0 wplan
  check "[C72] invocation ownership: first build" exit_is 0 wp build
  check "[C72] invocation ownership: first up" exit_is 0 wp up
  first_inv=$(systemctl --user show -p InvocationID --value "$unit")
  systemctl --user stop "$unit"
  make_clone "$second"
  clone=$second run=$second/BUILD/RUN
  export WORKPLACE_CONFIG=$clone XDG_STATE_HOME=$scratch/second-state
  scoped_clone
  jq '.socket = "default"' "$clone/workplace.json" > "$scratch/w" && cp "$scratch/w" "$clone/workplace.json"
  render default > "$scratch/plan.json"
  statements_plan "$records_terms"' | (.programs[-1].recorded[] | select(.term[0] == "record-chain") | .term[1]) = "journal"'
  check "[C72] invocation ownership: second plan, same name" exit_is 0 wplan
  check "[C72] invocation ownership: second build" exit_is 0 wp build
  check "[C72] invocation ownership: second up" exit_is 0 wp up
  second_inv=$(systemctl --user show -p InvocationID --value "$unit")
  check "[C72] invocation ownership: new invocation belongs to the second workplace" \
    bash -c '[[ -n $1 && -n $2 && $1 != "$2" ]]' _ "$first_inv" "$second_inv"
  check "[C72] invocation ownership: first down" exit_is 0 env -u XDG_STATE_HOME WORKPLACE_CONFIG="$first" "$BASH" "$loop" down
  check "[C72] invocation ownership: first down leaves the second invocation running" \
    bash -c 'systemctl --user is-active --quiet "$1" && [[ $(systemctl --user show -p InvocationID --value "$1") == "$2" ]]' _ "$unit" "$second_inv"
  check "[C72] invocation ownership: second panes stay up" test "$(T list-panes -a -F x | wc -l)" = 5
  check "[C72] invocation ownership: second down" exit_is 0 wp down
  unset XDG_STATE_HOME
}

t_floor_admin_mail() {
  if [[ $(nnp_of $$) != NoNewPrivs:0 ]]; then
    skip "admin mail: unenforced server needs a caller without the bar"
    return 0
  fi
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$root/records"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["reach","orchard","-","-","office","mail","harbor","-","-","office","allowed"]; 20),
    m(["reach","harbor","-","-","office","mail","orchard","-","-","office","allowed"]; 21),
    m(["reach","orchard","-","-","office","record","harbor","-","-","office","allowed"]; 22),
    m(["record","-","-","-","workplace","pane","kept"]; 23),
    m(["record-path","records"]; 24), m(["record-chain","file"]; 25)]'
  check "[C106] admin mail: plan" exit_is 0 wplan
  check "[C106] admin mail: build" exit_is 0 wp build
  check "[C106] admin mail: build makes each unenforced mailbox" test -L "$root/mailbox/Orchard Grower/out"
  check "[C106] admin mail: it points to the actual out" test "$(readlink "$root/mailbox/Orchard Grower/out")" = "$(state_of)/comms/Orchard Grower/out"
  check "[C106] admin records: build provides the allowed host record link" \
    test "$(readlink "$root/records/Orchard Grower/Harbor Keeper")" = "$(state_of)/floors/deck/records/Harbor Keeper"
  check "[C106] admin mail: up bridge" exit_is 0 wp up bridge
  check "[C106] admin mail: up deck" exit_is 0 wp up deck
  check "[C106] admin mail: the admin pane retains ordinary privileges" \
    test "$(nnp_of "$(on bridge T display-message -p -t "$(on bridge pane_by_title 'Orchard Grower')" '#{pane_pid}')")" = NoNewPrivs:0
  check "[C106] admin mail: its carrier keeps no-new-privileges" test "$(nnp_of "$(carrier_pid bridge)")" = NoNewPrivs:1
  printf '%s\n' 'to: Harbor Keeper' 'subject: admin path' --- body > "$root/mailbox/Orchard Grower/out/admin.md"
  check "[C106] admin mail: a request through the visible host mailbox is delivered" answered_ok grower admin.md
  request keeper reply.md 'to: Orchard Grower' 'subject: reply' --- response
  check "[C106] admin mail: a reply is delivered" answered_ok keeper reply.md
  check "[C106] admin mail: the reply is readable through the host link" \
    eventually bash -c 'grep -qlFx response "$1"/*' _ "$root/mailbox/Orchard Grower/in"
  on deck T set-option -g history-limit 1
  check "[C106] frame set: carrier restores a changed history setting" \
    on deck eventually_long bash -c '[[ $(tmux -S "$1" show-options -gv history-limit) == 5000 ]]' _ "$run/deck/$label"
  check "[C106] frame set: restoration is recorded" \
    eventually_long bash -c 'jq -e "select(.action == \"frame-set\" and .floor == \"deck\" and .outcome == \"restored\")" "$1" >/dev/null' _ "$(state_of)/comms/record"
  on deck T set-hook -g after-list-clients 'display-message harmless'
  check "[C106] frame set: a refused transport change is recorded" \
    eventually_long bash -c 'jq -e "select(.action == \"frame-set\" and .floor == \"deck\" and .outcome == \"refused\")" "$1" >/dev/null' _ "$(state_of)/comms/record"
  request keeper still-mail.md 'to: Orchard Grower' 'subject: mail without terminal transport' --- still-delivered
  check "[C106] frame set: mail continues while terminal transport is refused" answered_ok keeper still-mail.md
  request keeper blocked.grab 'seat: Harbor Pilot'
  check "[C106] frame set: screen access waits for valid transport" \
    answered keeper blocked.grab "refused the floor's terminal transport settings are refused; try again after repair"
  on deck T set-hook -gu after-list-clients
  request keeper restored.grab 'seat: Harbor Pilot'
  check "[C106] frame set: screen access resumes after the hook is removed" answered_ok keeper restored.grab
  check "[C106] admin mail: down deck" exit_is 0 wp down deck
  check "[C106] admin mail: down bridge" exit_is 0 wp down bridge
}

t_floor_config_refusals() {
  scoped_clone
  floors_clone
  local variant expected socket
  for variant in parse hook expansion session; do
    case $variant in
      parse) printf '%s\n' 'this-command-does-not-exist' > "$clone/floors/deck.conf"; expected="configuration does not parse" ;;
      hook) printf '%s\n' 'set-hook -g after-select-window "display-message harmless"' > "$clone/floors/deck.conf"; expected="declares session hooks" ;;
      expansion) printf '%s\n' 'set-option -g status-right "#(printf harmless)"' > "$clone/floors/deck.conf"; expected="shell expansion in an option" ;;
      session) printf '%s\n' 'new-session -d -s unexpected' > "$clone/floors/deck.conf"; expected="file made sessions before the frame" ;;
    esac
    statements_plan "$floors_terms"
    check "[C105] floor config $variant: plan" exit_is 0 wplan
    check "[C105] floor config $variant: build" exit_is 0 wp build
    check "[C105] floor config $variant: up refuses" exit_is 1 wp up deck
    check "[C105] floor config $variant: diagnostic" said "$expected"
    socket=$run/deck/$label
    if [[ -S $socket ]]; then timeout 5 tmux -S "$socket" kill-server || fail "cannot stop the test's refused floor"; fi
    rm -rf -- "$run/deck"
    check "[C105] floor config $variant: unbuild" exit_is 0 wp unbuild
  done
}

floor_server_digest() {
  tmux -S "$1" -N list-sessions -F '#{session_id} #{session_name} #{session_windows}' \; \
    show-options -s \; show-options -g \; show-options -gw \; show-hooks -g \; show-hooks -gw \; show-environment -g | sha256sum
}

t_floor_default_refusals() {
  if [[ $(nnp_of $$) != NoNewPrivs:0 ]]; then
    skip "floor default refusals: the positive unbarred control needs a plain caller"
    return 0
  fi
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C101] floor default: plan" exit_is 0 wplan
  check "[C101] floor default: build" exit_is 0 wp build
  local socket=$TMUX_TMPDIR/tmux-$EUID/default before
  mkdir -m 0700 -- "${socket%/*}"
  env -i HOME="$HOME" PATH="$PATH" TERM=xterm TMUX_TMPDIR="$TMUX_TMPDIR" \
    tmux -S "$socket" -f /dev/null new-session -d -s foreign
  tmux -S "$socket" set-option -g @foreign unchanged \; set-environment -g FOREIGN harmless
  before=$(floor_server_digest "$socket")
  check "[C101] floor default: foreign server is refused" exit_is 1 wp up bridge
  check "[C101] floor default: refusal names its socket" said "the server at $socket does not carry this clone's mark"
  check "[C101] floor default: foreign sessions, options, hooks and environment remain unchanged" test "$(floor_server_digest "$socket")" = "$before"
  check "[C101] floor default: no run was created" test ! -d "$run/bridge"
  tmux -S "$socket" kill-server
  env -i HOME="$HOME" PATH="$PATH" TERM=xterm TMUX_TMPDIR="$TMUX_TMPDIR" \
    setpriv --no-new-privs tmux -S "$socket" -f /dev/null new-session -d -s barred
  tmux -S "$socket" set-option -g @workplace-clone "$clone"
  before=$(floor_server_digest "$socket")
  check "[C101] floor default: correctly marked server with inherited bar is refused" exit_is 1 wp up bridge
  check "[C101] floor default: reason names no-new-privileges" said "carries no-new-privileges"
  check "[C101] floor default: refused marked server also stays unchanged" test "$(floor_server_digest "$socket")" = "$before"
  tmux -S "$socket" kill-server
  check "[C101] floor default: barred caller refuses before server creation" exit_is 1 setpriv --no-new-privs "$BASH" "$loop" up bridge
  check "[C101] floor default: caller is told why it cannot lift the bar" said "this caller carries no-new-privileges"
  check "[C101] floor default: no server answers afterward" bash -c '! tmux -S "$1" -N list-sessions >/dev/null 2>&1' _ "$socket"
  check "[C101] floor default: own floor starts" exit_is 0 wp up bridge
  tmux -S "$socket" new-session -d -s personal
  local pid
  pid=$(tmux -S "$socket" display-message -p '#{pid}')
  check "[C101] floor default: down leaves personal session" exit_is 0 wp down bridge
  check "[C101] floor default: personal server has same pid" test "$(tmux -S "$socket" display-message -p '#{pid}')" = "$pid"
  check "[C101] floor default: only personal session remains" test "$(tmux -S "$socket" list-sessions -F '#{session_name}')" = personal
  check "[C101] floor default: run was removed despite surviving server" test ! -e "$run/bridge"
  check "[C101] floor default: own marked server can be reused" exit_is 0 wp up bridge
  check "[C101] floor default: own floor can go down again" exit_is 0 wp down bridge
  check "[C101] floor default: unbuild before a changed valid configuration" exit_is 0 wp unbuild
  printf '%s\n' 'set-option -g @new-floor-setting changed' > "$clone/floors/bridge.conf"
  statements_plan "$floors_terms"
  check "[C101] floor default: changed configuration plan" exit_is 0 wplan
  check "[C101] floor default: changed configuration build" exit_is 0 wp build
  before=$(floor_server_digest "$socket")
  check "[C101] floor default: an existing server must not silently ignore a changed file" exit_is 1 wp up bridge
  check "[C101] floor default: the refusal explains the loaded configuration mismatch" said "has not loaded this sealed floor configuration"
  check "[C101] floor default: the existing server is unchanged" test "$(floor_server_digest "$socket")" = "$before"
  check "[C101] floor default: unbuild before testing a malformed replacement" exit_is 0 wp unbuild
  printf '%s\n' 'this-command-does-not-exist' > "$clone/floors/bridge.conf"
  statements_plan "$floors_terms"
  check "[C101] floor default: replacement plan" exit_is 0 wplan
  check "[C101] floor default: replacement build" exit_is 0 wp build
  before=$(floor_server_digest "$socket")
  check "[C101] floor default: own marked server refuses a malformed replacement" exit_is 1 wp up bridge
  check "[C101] floor default: the personal server is unchanged after that refusal" test "$(floor_server_digest "$socket")" = "$before"
  tmux -S "$socket" kill-server
  rm -rf -- "$run/bridge"
}

t_floor_runtime() {
  scoped_clone
  floors_clone
  printf '%s\n' 'set-option -g @floor-own deck' 'set-option -g history-limit 0' \
    'set-window-option -g synchronize-panes on' 'set-environment -g COLORTERM poisoned' \
    'set-option -s @workplace-shadow server' 'set-option -g @workplace-shadow session' \
    'set-option -gw @workplace-shadow window' \
    'set-option -s command-alias[999] "floor-poison=list-sessions"' > "$clone/floors/deck.conf"
  printf '%s\n' 'set-option -g history-limit 12000' 'set-option -s set-clipboard on' \
    'set-option -g status-right "#(printf allowed)"' > "$clone/floors/bridge.conf"
  statements_plan "$floors_terms"' | (.programs[] | select(.path == "harbor/dock/keeper/seat.typify") | .plan[1].term[5]) |=
    (fromjson + ["value=COLORTERM"] | tojson)'
  check "[C105] floor runtime: plan" exit_is 0 wplan
  check "[C105] floor runtime: build" exit_is 0 wp build
  check "[C105] floor runtime: config is sealed into its generation" \
    bash -c 'g=$(sed -n "s|^[0-9a-f]*  \\(floors/deck/[0-9]*\\)/MANIFEST$|\\1|p" "$1/BUILD/MANIFEST"); cmp -s "$1/floors/deck.conf" "$1/BUILD/$g/floor.conf" && grep -q "  floor.conf$" "$1/BUILD/$g/MANIFEST"' _ "$clone"
  COLORTERM=original check "[C105] floor runtime: up deck" exit_is 0 wp up deck
  check "[C105] floor runtime: floor config was read" test "$(on deck T show-options -gqv @floor-own)" = deck
  check "[C105] floor runtime: frame restores the history requirement" test "$(on deck T show-options -gv history-limit)" = 5000
  check "[C105] floor runtime: frame disables synchronized typing" test "$(on deck T show-options -gwv synchronize-panes)" = off
  check "[C105] frame removes reserved option shadows in every global scope" \
    test -z "$(on deck T show-options -sqv @workplace-shadow)$(on deck T show-options -gqv @workplace-shadow)$(on deck T show-options -gwqv @workplace-shadow)"
  check "[C105] frame restores the default command aliases" test -z "$(on deck T show-options -sqv 'command-alias[999]')"
  check "[C105] floor runtime: caller environment beats tmux's injected environment" on deck eventually_long screen_has "Harbor Keeper" "value COLORTERM=original"
  check "[C22] status control has no carrier that could repair the setting" test ! -d "$run/deck/carrier"
  on deck T set-option -g history-limit 1
  check "[C22] status refuses transport settings that differ" exit_is 1 wp status deck
  check "[C22] status names the settings disagreement" said "the floor's frame settings differ"
  check "[C22] status leaves the disagreeing setting unchanged" test "$(on deck T show-options -gv history-limit)" = 1
  on deck T set-option -g history-limit 5000
  check "[C22] status agrees once the setting is restored externally" exit_is 0 wp status deck
  check "[C105] floor runtime: down deck" exit_is 0 wp down deck
  if [[ $(nnp_of $$) != NoNewPrivs:0 ]]; then
    skip "floor runtime: unenforced server requires a plain caller without no-new-privileges"
    return 0
  fi
  check "[C105] floor runtime: default floor up" exit_is 0 wp up bridge
  local pid
  pid=$(on bridge T display-message -p '#{pid}')
  check "[C105] floor runtime: unenforced server keeps ordinary privileges" test "$(nnp_of "$pid")" = NoNewPrivs:0
  check "[C105] floor runtime: a higher declared history limit is preserved" test "$(on bridge T show-options -gv history-limit)" = 12000
  check "[C105] an unenforced floor retains its clipboard choice" test "$(on bridge T show-options -sv set-clipboard)" = on
  check "[C105] an unenforced floor retains shell expansion in its status option" test "$(on bridge T show-options -gv status-right)" = '#(printf allowed)'
  check "[C105] floor runtime: default socket is inside the test's private directory" \
    test "$(on bridge T display-message -p '#{socket_path}')" = "$TMUX_TMPDIR/tmux-$EUID/default"
  check "[C105] floor runtime: the named default finds Management's equivalent" test "$(tmux -L default list-sessions -F '#{session_name}')" = Orchard
  check "[C105] floor runtime: down default floor" exit_is 0 wp down bridge
}

t_floor_scoped_readback() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C105] scoped readback: plan" exit_is 0 wplan
  check "[C105] scoped readback: build" exit_is 0 wp build
  check "[C105] scoped readback: up deck" exit_is 0 wp up deck
  [[ -f $run/deck/state.json ]] || return 1
  local session window pane scope target key value commands client control_fd
  session=$(on deck T list-sessions -F '#{session_id}' | head -1)
  window=$(on deck T list-windows -a -F '#{window_id}' | head -1)
  pane=$(on deck T list-panes -a -F '#{pane_id}' | head -1)
  for scope in pane-via-gp session window pane; do
    case $scope in
      pane-via-gp) target=$pane ;;
      session) target=$session ;;
      window) target=$window ;;
      pane) target=$pane ;;
    esac
    case $scope in
      pane-via-gp) on deck T set-hook -gp -t "$target" pane-mode-changed 'display-message harmless' ;;
      session) on deck T set-hook -t "$target" after-list-clients 'display-message harmless' ;;
      window) on deck T set-hook -w -t "$target" pane-mode-changed 'display-message harmless' ;;
      pane) on deck T set-hook -p -t "$target" pane-mode-changed 'display-message harmless' ;;
    esac
    check "[C105] $scope hook: status refuses" exit_is 1 wp status deck
    check "[C105] $scope hook: diagnostic names hooks" said "hooks, which the frame refuses"
    case $scope in
      pane-via-gp) on deck T set-hook -gpu -t "$target" pane-mode-changed ;;
      session) on deck T set-hook -u -t "$target" after-list-clients ;;
      window) on deck T set-hook -wu -t "$target" pane-mode-changed ;;
      pane) on deck T set-hook -pu -t "$target" pane-mode-changed ;;
    esac
  done
  commands=$(on deck T list-commands)
  if [[ $(printf '%s\n' "$commands" | sed -n '/^show-hooks /p') == *B* ]]; then
    on deck T set-hook -gp -B "@scope-probe:$pane:#{pane_dead}"
    check "[C105] a monitor with no command body still refuses" exit_is 1 wp status deck
    check "[C105] the monitor's diagnostic names hooks" said "hooks, which the frame refuses"
    on deck T set-hook -gpu -B @scope-probe
  else
    skip "[C105] this tmux has no hook-monitor subscriptions"
  fi
  for scope in session window pane; do
    case $scope in
      session) on deck T set-option -t "$session" @scope-probe '#(printf harmless)' ;;
      window) on deck T set-option -w -t "$window" @scope-probe '#(printf harmless)' ;;
      pane) on deck T set-option -p -t "$pane" @scope-probe '#(printf harmless)' ;;
    esac
    check "[C105] $scope option expansion: status refuses" exit_is 1 wp status deck
    check "[C105] $scope option expansion: diagnostic" said "shell expansion in an option"
    case $scope in
      session) on deck T set-option -u -t "$session" @scope-probe ;;
      window) on deck T set-option -wu -t "$window" @scope-probe ;;
      pane) on deck T set-option -pu -t "$pane" @scope-probe ;;
    esac
  done
  for key in alternate-screen allow-passthrough synchronize-panes; do
    value=on
    [[ $key != alternate-screen ]] || value=off
    on deck T set-option -gw "$key" "$value"
    check "[C106] global $key: status refuses" exit_is 1 wp status deck
    check "[C22] global $key: status does not repair" test "$(on deck T show-options -gwv "$key")" = "$value"
    value=off
    [[ $key != alternate-screen ]] || value=on
    on deck T set-option -gw "$key" "$value"
  done
  for key in alternate-screen allow-passthrough; do
    value=on
    [[ $key != alternate-screen ]] || value=off
    on deck T set-option -p -t "$pane" "$key" "$value"
    check "[C106] local $key: status refuses" exit_is 1 wp status deck
    check "[C22] local $key: status does not repair" test "$(on deck T show-options -pAv -t "$pane" "$key")" = "$value"
    value=off
    [[ $key != alternate-screen ]] || value=on
    on deck T set-option -p -t "$pane" "$key" "$value"
  done
  mkfifo "$scratch/control-input"
  exec {control_fd}<> "$scratch/control-input"
  tmux -S "$run/deck/$label" -C attach-session -t "$session" <&"$control_fd" > "$scratch/control.log" 2>&1 &
  client=$!
  check "[C106] local session: synthetic client is attached" \
    on deck eventually_long bash -c '[[ $(tmux -S "$1" display-message -p -t "$2" "#{session_attached}") -gt 0 ]]' _ "$run/deck/$label" "$session"
  on deck T set-option -t "$session" destroy-unattached on
  check "[C106] local destroy-unattached: status refuses" exit_is 1 wp status deck
  check "[C22] local destroy-unattached: status does not repair" test "$(on deck T show-options -Av -t "$session" destroy-unattached)" = on
  on deck T set-option -t "$session" destroy-unattached off
  kill "$client" 2>/dev/null || :
  wait "$client" 2>/dev/null || :
  exec {control_fd}>&-
  check "[C106] scoped readback: restored settings agree" exit_is 0 wp status deck
  check "[C105] scoped readback: down deck" exit_is 0 wp down deck
}

t_floor_refresh_scoped() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox"
  statements_plan "$floors_terms | $comms_terms"' | .programs[-1].recorded += [
    m(["reach","harbor","dock","-","room","mail","harbor","dock","-","room","allowed"]; 22)]'
  check "[C106] scoped refresh: plan" exit_is 0 wplan
  check "[C106] scoped refresh: build" exit_is 0 wp build
  check "[C106] scoped refresh: up deck" exit_is 0 wp up deck
  [[ -f $run/deck/state.json ]] || return 1
  local pane session client control_fd
  pane=$(on deck pane_by_title 'Harbor Keeper')
  session=$(on deck T list-sessions -F '#{session_id}' | head -1)
  mkfifo "$scratch/control-input"
  exec {control_fd}<> "$scratch/control-input"
  tmux -S "$run/deck/$label" -C attach-session -t "$session" <&"$control_fd" > "$scratch/control.log" 2>&1 &
  client=$!
  check "[C106] scoped refresh: a synthetic client keeps the test session attached" \
    on deck eventually_long bash -c '[[ $(tmux -S "$1" display-message -p -t "$2" "#{session_attached}") -gt 0 ]]' _ "$run/deck/$label" "$session"
  on deck T set-option -t "$session" destroy-unattached on
  on deck T set-option -gw synchronize-panes on
  on deck T set-option -gw alternate-screen off
  on deck T set-option -gw allow-passthrough on
  on deck T set-option -p -t "$pane" alternate-screen off
  on deck T set-option -p -t "$pane" allow-passthrough on
  check "[C106] scoped refresh: carrier restores the session's attachment policy" \
    on deck eventually_long bash -c '[[ $(tmux -S "$1" show-options -Av -t "$2" destroy-unattached) == off ]]' _ "$run/deck/$label" "$session"
  check "[C106] scoped refresh: carrier restores global synchronized input" \
    on deck eventually_long bash -c '[[ $(tmux -S "$1" show-options -gwv synchronize-panes) == off ]]' _ "$run/deck/$label"
  check "[C106] scoped refresh: carrier restores global alternate screen" \
    on deck eventually_long bash -c '[[ $(tmux -S "$1" show-options -gwv alternate-screen) == on ]]' _ "$run/deck/$label"
  check "[C106] scoped refresh: carrier restores global passthrough" \
    on deck eventually_long bash -c '[[ $(tmux -S "$1" show-options -gwv allow-passthrough) == off ]]' _ "$run/deck/$label"
  check "[C106] scoped refresh: carrier restores pane alternate screen" \
    on deck eventually_long bash -c '[[ $(tmux -S "$1" show-options -pAv -t "$2" alternate-screen) == on ]]' _ "$run/deck/$label" "$pane"
  check "[C106] scoped refresh: carrier restores pane passthrough" \
    on deck eventually_long bash -c '[[ $(tmux -S "$1" show-options -pAv -t "$2" allow-passthrough) == off ]]' _ "$run/deck/$label" "$pane"
  on deck T set-hook -p -t "$pane" pane-mode-changed 'display-message harmless'
  request keeper refused.grab 'seat: Harbor Pilot'
  check "[C106] scoped refresh: a local hook blocks terminal transport" \
    answered keeper refused.grab "refused the floor's terminal transport settings are refused; try again after repair"
  request keeper while-refused.md 'to: Harbor Pilot' 'subject: local hook' --- body
  check "[C106] scoped refresh: mail continues with the local hook present" answered_ok keeper while-refused.md
  on deck T set-hook -pu -t "$pane" pane-mode-changed
  kill "$client" 2>/dev/null || :
  wait "$client" 2>/dev/null || :
  exec {control_fd}>&-
  check "[C106] scoped refresh: down deck" exit_is 0 wp down deck
}

t_floor_alias_reuse() {
  if [[ $(nnp_of $$) != NoNewPrivs:0 ]]; then
    skip "[C105] alias reuse needs an ordinary caller"
    return 0
  fi
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C105] alias reuse: plan" exit_is 0 wplan
  check "[C105] alias reuse: build" exit_is 0 wp build
  check "[C105] alias reuse: up" exit_is 0 wp up bridge
  [[ -f $run/bridge/state.json ]] || return 1
  local socket=$TMUX_TMPDIR/tmux-$EUID/default before
  tmux -S "$socket" new-session -d -s personal
  check "[C105] alias reuse: initial baseline digest exists" \
    bash -c '[[ $(tmux -S "$1" show-options -gqv @workplace-aliases) =~ ^[0-9a-f]{64}$ ]]' _ "$socket"
  check "[C105] alias reuse: down preserves the personal session" exit_is 0 wp down bridge
  tmux -S "$socket" set-option -s 'command-alias[999]' 'scope-probe=list-sessions'
  before=$(floor_server_digest "$socket")
  check "[C105] alias reuse: altered aliases refuse before up" exit_is 1 wp up bridge
  check "[C105] alias reuse: reason names baseline" said "command aliases differ from the recorded frame baseline"
  check "[C105] alias reuse: refusal leaves the personal server unchanged" test "$(floor_server_digest "$socket")" = "$before"
  check "[C105] alias reuse: refusal makes no run" test ! -d "$run/bridge"
  tmux -S "$socket" set-option -su 'command-alias[999]'
  check "[C105] alias reuse: restored aliases allow up" exit_is 0 wp up bridge
  check "[C105] alias reuse: down" exit_is 0 wp down bridge
}

t_floor_restart_mail_links() {
  if [[ $(nnp_of $$) != NoNewPrivs:0 ]]; then
    skip "[C98] admin restart needs an ordinary caller"
    return 0
  fi
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox"
  statements_plan "$floors_terms | $comms_terms"
  check "[C98] restart links: plan" exit_is 0 wplan
  check "[C98] restart links: build" exit_is 0 wp build
  check "[C98] restart links: up bridge" exit_is 0 wp up bridge
  [[ -f $run/bridge/state.json ]] || return 1
  local pane target link="$root/mailbox/Orchard Grower/out"
  pane=$(on bridge pane_by_title 'Orchard Grower')
  on bridge T respawn-pane -k -t "$pane" /usr/bin/true
  check "[C98] restart links: seat ended" on bridge eventually_long dead_pane 'Orchard Grower'
  target=$(readlink "$link")
  rm -- "$link"
  check "[C98] restart links: missing host mailbox link refuses restart" exit_is 1 wp restart bridge 'Orchard Grower'
  check "[C98] restart links: diagnostic names missing link" said "the mailbox entry $link is missing"
  check "[C98] restart links: refused seat stays dead" on bridge dead_pane 'Orchard Grower'
  ln -s -- "$target" "$link"
  check "[C98] restart links: restored mailbox allows restart" exit_is 0 wp restart bridge 'Orchard Grower'
  check "[C98] restart links: down bridge" exit_is 0 wp down bridge
}

t_floor_call_deadlines() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C105] deadlines: plan" exit_is 0 wplan
  check "[C105] deadlines: build" exit_is 0 wp build
  check "[C105] deadlines: up deck" exit_is 0 wp up deck
  [[ -f $run/deck/state.json ]] || return 1
  local socket=$run/deck/$label pid kind
  pid=$(on deck T display-message -p '#{pid}')
  {
    printf '%s\n' 'set -o nounset -o pipefail' 'run_floor=deck' 'run_dir=$1' \
      'carrier_setpriv=$(command -v setpriv)' 'carrier_tmux_program=$(command -v tmux)' 'carrier_socket=$2' \
      'floor_socket=$2' 'floor_unenforced=0'
    sed -n '/^floor_capture() {/,/^}/p;/^floor_client() {/,/^}/p' "$tool/libexec/floor-runtime.bash"
    sed -n '/^caller_locale() {/,/^} 2> \/dev\/null/p;/^run_call() {/,/^}/p;/^read_server() {/,/^}/p;/^carrier_tmux() {/,/^}/p' "$loop"
    printf '%s\n' 'if [[ $3 == carrier ]]; then' \
      '  value=$(carrier_tmux display-message -p "#{pid}") && exit 1' \
      '  result=$?; [[ $result == 124 || $result == 137 ]]' \
      'elif [[ $3 == client ]]; then' \
      '  value=$(floor_client display-message -p "#{pid}") && exit 1' \
      '  result=$?; [[ $result == 124 || $result == 137 ]]' \
      'else' '  read_server "$carrier_setpriv" "$carrier_tmux_program" "$carrier_socket"' \
      '  [[ $server_up == 0 ]]' 'fi'
  } > "$scratch/deadline-driver"
  trap 'kill -CONT "$pid" 2>/dev/null || :; exit 1' HUP INT TERM
  kill -STOP "$pid"
  for kind in carrier read-server client; do
    check "[C105] deadlines: $kind returns before the outer guard with a stopped real server" \
      exit_is 0 timeout --foreground --kill-after=1 14 "$BASH" "$scratch/deadline-driver" "$scratch" "$socket" "$kind"
  done
  kill -CONT "$pid"
  trap - HUP INT TERM
  check "[C105] deadlines: down deck" exit_is 0 wp down deck
}

t_floor_server_privilege_recheck() {
  if [[ $(nnp_of $$) != NoNewPrivs:0 ]]; then
    skip "[C10] wrong-privilege replacement needs an ordinary caller"
    return 0
  fi
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C10] privilege recheck: plan" exit_is 0 wplan
  check "[C10] privilege recheck: build" exit_is 0 wp build
  check "[C10] privilege recheck: up enforced deck" exit_is 0 wp up deck
  [[ -f $run/deck/state.json ]] || return 1
  local socket=$run/deck/$label previous
  previous=$(on deck T display-message -p '#{pid}')
  tmux -S "$socket" kill-server
  check "[C10] privilege recheck: original server has ended before replacement" \
    eventually_long bash -c '! kill -0 "$1" 2>/dev/null' _ "$previous"
  check "[C10] privilege recheck: replacement server starts" \
    tmux -S "$socket" -f /dev/null new-session -d -s replacement 'sleep infinity'
  check "[C10] privilege recheck: replacement receives the old mark" tmux -S "$socket" set-option -g @workplace-clone "$clone"
  check "[C10] privilege recheck: replacement actually has the wrong privileges" \
    test "$(nnp_of "$(tmux -S "$socket" display-message -p '#{pid}')")" = NoNewPrivs:0
  check "[C10] privilege recheck: same mark with wrong privileges refuses restart" exit_is 2 wp restart deck
  check "[C10] privilege recheck: diagnostic names privilege mode" said "does not carry the floor's recorded privilege mode"
  tmux -S "$socket" kill-server
}

t_floor_command_exclusion() {
  scoped_clone
  floors_clone
  statements_plan "$floors_terms"
  check "[C102] floor exclusion: plan" exit_is 0 wplan
  check "[C102] floor exclusion: build" exit_is 0 wp build
  local s=$HOME/.local/state/workplace/$label
  ( umask 077; : > "$s/floors/deck/up.lock"; : > "$s/floors/deck/up.holder" )
  printf '%s\n' '{"command":"up deck","pid":4242,"at":"2026-11-17T00:00:00Z"}' > "$s/floors/deck/up.holder"
  exec {held}>> "$s/floors/deck/up.lock"
  flock "$held"
  local verb before=$SECONDS
  for verb in up restart down; do
    if [[ $verb == restart ]]; then
      mkdir -p -- "$run/deck"
      printf '%s\n' '{}' > "$run/deck/state.json"
    fi
    check "[C102] floor exclusion: $verb refuses the held floor" exit_is 1 wp "$verb" deck
    check "[C102] floor exclusion: $verb names the holder" said "up deck holds the floor deck, process 4242"
  done
  check "[C102] floor exclusion: no command waits for the holder" test "$(( SECONDS - before ))" -lt 10
  exec {held}>&-
  rm -rf -- "$run/deck"
  mkdir -- "$scratch/gate-bin"
  local real_tmux
  real_tmux=$(command -v tmux)
  printf '%s\n' '#!/usr/bin/env bash' \
    'for arg in "$@"; do if [[ $arg == start-server ]]; then' \
    '  : > "$WP_GATE/entered"' \
    '  while [[ ! -e $WP_GATE/release ]]; do read -r -t 0.05 _ <> <(:) || :; done' \
    'fi; done' \
    'exec "$WP_REAL_TMUX" "$@"' > "$scratch/gate-bin/tmux"
  chmod +x -- "$scratch/gate-bin/tmux"
  WP_GATE=$scratch WP_REAL_TMUX=$real_tmux PATH="$scratch/gate-bin:$PATH" wp up deck > "$scratch/blocked-up" 2>&1 &
  local starter=$!
  check "[C102] floor exclusion: actual up reaches its first tmux call" eventually test -f "$scratch/entered"
  check "[C102] floor exclusion: its floor lock is still held through startup" bash -c '! flock -n "$1" true' _ "$s/floors/deck/up.lock"
  before=$SECONDS
  check "[C102] floor exclusion: down refuses during an actual up" exit_is 1 wp down deck
  check "[C102] floor exclusion: down names that up" said "up deck holds the floor deck"
  check "[C102] floor exclusion: down returns before startup is released" test "$(( SECONDS - before ))" -lt 5
  : > "$scratch/release"
  check "[C102] floor exclusion: original up completes" wait "$starter"
  check "[C102] floor exclusion: no daemon inherits the floor lock" flock -n "$s/floors/deck/up.lock" true
  check "[C102] floor exclusion: down after startup" exit_is 0 wp down deck
}

t_actual_default_mask_build() {
  local sockets=/tmp/tmux-$EUID
  if [[ ! -d $sockets ]]; then
    skip "[C68] the machine's default tmux directory does not stand; its build-only alias check is not run"
    return 0
  fi
  scoped_clone
  ln -s -- "$sockets" "$root/actual-sockets"
  statements_plan '.programs[-1].recorded += [st("orchard"; "barn"; "grower"; "seat"; $root + "/actual-sockets"; "read-only"; 10)]'
  check "[C68] a plan naming an alias of the actual default directory forms" exit_is 0 wplan
  check "[C68] build refuses that alias without starting or contacting a server" exit_is 1 wp build
  check "[C68] the refusal names the actual default directory" said "$sockets"
  check "[C68] the refused build leaves no BUILD" test ! -e "$clone/BUILD"
}

# The store's lock (5.162 point 1, the DA's specimen): two floors' carriers deliver at one time on one store, one hold
# for one delivery, and lose nothing of each other's. Runs made by hand, with no panes.
t_store_lock() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox"
  local kinds='| kinds([["harbor", "dock", "keeper", "clerk"], ["harbor", "dock", "pilot", "clerk"], ["harbor", "tower", "watch", "clerk"],
      ["orchard", "barn", "grower", "clerk"], ["orchard", "barn", "picker", "clerk"], ["lodge", "east", "ida", "clerk"]])'
  statements_plan "$floors_terms | $comms_terms $kinds"' | .programs[-1].recorded += [
      m(["reach", "harbor", "-", "-", "office", "mail", "lodge", "-", "-", "floor", "allowed"]; 2),
      m(["reach", "lodge", "-", "-", "floor", "mail", "harbor", "-", "-", "office", "allowed"]; 3),
      m(["reach", "harbor", "dock", "-", "room", "mail", "harbor", "dock", "-", "room", "allowed"]; 4),
      m(["wake", "clerk", "^waiting>$"]; 5)]'
  check "plan of floors with mail between the harbor and the lodge, every kind with a wake" exit_is 0 wplan
  check "build" exit_is 0 wp build
  local s f n holder store
  local -a carriers=() ids=()
  s=$(state_of)
  store=$s/mail
  sgit() { env -i PATH="$PATH" HOME="$scratch" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$store" "$@"; }
  for f in deck lodge; do
    mkdir -p -- "$run/$f/carrier"
    printf '%s\n' '{"slots": {}}' > "$run/$f/state.json"
  done
  flock -o "$store" sleep 5 &
  holder=$!
  check "the test holds the store's lock" eventually bash -c '! flock -n "$1" true' _ "$store"
  for n in 1 2 3; do
    request keeper "k$n.md" "to: Lodge Ida, Harbor Pilot, Harbor Keeper" "subject: k$n" --- "k$n"
    request pilot "p$n.md" "to: Harbor Keeper" "subject: p$n" --- "p$n"
    request ida "i$n.md" "to: Harbor Keeper, Harbor Pilot" "subject: i$n" --- "i$n"
  done
  for f in deck lodge; do
    "$BASH" "$clone/BUILD/bin/workplace" carry "$f" > "$scratch/carry-$f" 2>&1 &
    carriers+=("$!")
  done
  sleep 3
  check "[C57] 5.162 point 1: while the store's lock is held, neither floor's carrier delivers" \
    bash -c '[[ $1 == 0 && -z $(find "$2/comms/Harbor Keeper/answers" "$2/comms/Harbor Pilot/answers" "$2/comms/Lodge Ida/answers" -type f) ]]' _ "$(store_commits)" "$s"
  wait "$holder"
  check "[C59] 5.162: once it is free, the two floors' carriers deliver the nine mails" \
    bash -c 'for a in "$@"; do [[ $a == "ok "* ]] || exit 1; done' _ "$(answer_of keeper k1.md)" "$(answer_of keeper k2.md)" "$(answer_of keeper k3.md)" \
      "$(answer_of pilot p1.md)" "$(answer_of pilot p2.md)" "$(answer_of pilot p3.md)" "$(answer_of ida i1.md)" "$(answer_of ida i2.md)" "$(answer_of ida i3.md)"
  # The carrier answers before it writes the line, so the lines are awaited.
  check "the nine mails' lines stand in the record" eventually bash -c '[[ $(jq -r "select(.action == \"mail\" and .outcome == \"ok\") | .id" "$1" | wc -l) == 9 ]]' _ "$s/comms/record"
  mapfile -t ids < <(jq -r 'select(.action == "mail" and .outcome == "ok") | .id' "$s/comms/record")
  check "[C57] one commit for each delivery, and ids that no two floors share, counted once" \
    bash -c '[[ $1 == 9 && $2 == 9 && $(printf "%s\n" "${@:4}" | sort -u | wc -l) == 9 && $3 == 9 ]]' _ "$(store_commits)" "${#ids[@]}" "$(< "$s/comms/next")" "${ids[@]}"
  check "[C57] each commit holds its own mail alone: its readers' in and its writer's sent" bash -c '
    s=$1; shift
    for id in "$@"; do
      want=$(jq -r --arg id "$id" "select(.id == \$id and .action == \"mail\") | ([.target[] | \"\(.)/in/\(\$id).md\"] + [\"\(.seat)/sent/\(\$id).md\"]) | sort[]" "$s/comms/record")
      commit=$(env -i PATH="$PATH" HOME=/ GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$s/mail" log --format=%H --grep="^deliver $id\$")
      got=$(env -i PATH="$PATH" HOME=/ GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$s/mail" show --name-only --format= "$commit" | sort)
      [[ -n $commit && $want == "$got" ]] || exit 1
    done' _ "$s" "${ids[@]}"
  check "[C96] each mail's decision lines stand together, just before its line, though two floors write the record" \
    bash -c 'for id in "${@:2}"; do jq -R -s -e --arg id "$id" "[split(\"\n\")[] | fromjson? | objects] | (to_entries | map(select(.value.seat == \"the frame\" and .value.covers == [\$id] and (.value | has(\"length\") | not)) | .key)) as \$k
      | (to_entries | map(select(.value.id == \$id and .value.action == \"mail\") | .key)) as \$m
      | (\$m | length) == 1 and ((\$k | length) == 0 or \$k == [range(\$m[0] - (\$k | length); \$m[0])])" "$1" > /dev/null || exit 1; done' _ "$s/comms/record" "${ids[@]}"
  check "[C96] and such lines stand: keeper's none for each of its three mails, which it reads itself" \
    test "$(jq -c 'select(.seat == "the frame" and .outcome == "none" and .target == ["Harbor Keeper"])' "$s/comms/record" | wc -l)" = 3
  check "[C94] 5.162 point 1: wake.json holds every reader's due ids, both floors', none lost to the other's write" \
    test "$(jq -c '[(.seats["Harbor Keeper"].ids | length), (.seats["Harbor Pilot"].ids | length), (.seats["Lodge Ida"].ids | length)]' "$s/comms/wake.json")" = '[6,6,3]'
  check "[C94] in the order of mail.json's seats" test "$(jq -c '.seats | keys_unsorted' "$s/comms/wake.json")" = '["Harbor Keeper","Harbor Pilot","Lodge Ida"]'
  # Which floor took the lock next is the kernel's choice, so the order is shown and not checked.
  note "    the floors' deliveries in the store's order (D the deck, L the lodge): $(for id in "${ids[@]}"; do jq -r --arg id "$id" 'select(.id == $id and .action == "mail") | if .seat == "Lodge Ida" then "L" else "D" end' "$s/comms/record"; done | tr -d '\n')"
  # A carrier removes the holder as it lets the store's lock go, which is after the last delivery's line.
  eventually_long flock -n "$store" true || note "    the store's lock is still held after a minute"
  check "[C57] and no holder of the store's lock stands once they are done" test ! -e "$s/store.holder"
  # A dead carrier's add that no commit took rides into no other delivery.
  printf '%s\n' left > "$store/Harbor Keeper/in/zz.md"
  flock -o "$store" sleep 3 &
  holder=$!
  check "the test holds the store's lock again" eventually bash -c '! flock -n "$1" true' _ "$store"
  sgit add -- "Harbor Keeper/in/zz.md"
  request ida i4.md "to: Harbor Keeper" "subject: i4" --- "i4"
  wait "$holder"
  check "a mail is delivered after the stale add" answered_ok ida i4.md
  check "its line stands in the record" eventually bash -c '[[ -n $(jq -r "select(.request == \"i4.md\" and .action == \"mail\") | .id" "$1") ]]' _ "$s/comms/record"
  check "[C57] 5.162 point 1: its commit holds its own paths alone, and the stale add is unstaged, not committed" \
    bash -c '[[ $(env -i PATH="$PATH" HOME=/ GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$1" show --name-only --format= HEAD | sort | tr "\n" " ") == "Harbor Keeper/in/$2.md Lodge Ida/sent/$2.md " ]] \
      && [[ -z $(env -i PATH="$PATH" HOME=/ GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$1" ls-files -- "Harbor Keeper/in/zz.md") ]]' _ "$store" "$(jq -r 'select(.request == "i4.md" and .action == "mail") | .id' "$s/comms/record")"
  # The holder of the store's lock, seen while a delivery holds it: a poller copies S/store.holder once it stands.
  ( for (( n = 0; n < 2000000; n++ )); do [[ -s $s/store.holder ]] && { cp -- "$s/store.holder" "$scratch/holder-seen" 2> /dev/null && [[ -s $scratch/holder-seen ]] && exit 0; }; done; exit 1 ) &
  holder=$!
  request ida i5.md "to: Harbor Keeper, Harbor Pilot" "subject: i5" --- "i5"
  check "a mail is delivered while the poller watches" answered_ok ida i5.md
  wait "$holder"
  check "[C57] review of 4a: during a delivery S/store.holder names the floor whose carrier holds the lock, and its process" \
    test "$(jq -c '[.floor, .pid]' "$scratch/holder-seen" 2> /dev/null)" = "[\"lodge\",${carriers[1]}]"
  check "[C57] and once the hold is let go it stands no more" eventually test ! -e "$s/store.holder"
  for f in deck lodge; do rm -rf -- "$run/$f/carrier"; done
  wait "${carriers[@]}"
  # A stopped carrier's delivery that another floor's commit follows is found by its subject from the head it noted.
  local base x=recovered-x
  base=$(sgit rev-parse HEAD)
  for f in "Lodge Ida/sent" "Harbor Keeper/in"; do printf '%s\n' x > "$store/$f/$x.md"; done
  sgit add -- "Lodge Ida/sent/$x.md" "Harbor Keeper/in/$x.md"
  sgit -c user.name=t -c user.email=t@t commit -q -m "deliver $x"
  printf '%s\n' y > "$store/Harbor Pilot/in/recovered-y.md"
  sgit add -- "Harbor Pilot/in/recovered-y.md"
  sgit -c user.name=t -c user.email=t@t commit -q -m "deliver recovered-y"
  jq -n -c --arg b "$base" '{id: "recovered-x", box: "Lodge Ida", request: "x.md", action: "mail", seat: "Lodge Ida", base: $b}' > "$s/floors/lodge/comms/serving"
  mkdir -p -- "$run/lodge/carrier"
  "$BASH" "$clone/BUILD/bin/workplace" carry lodge > "$scratch/carry-lodge" 2>&1 &
  carriers=("$!")
  check "[C57] 5.162 point 1: recovery finds the delivery's commit by its subject, after another floor's, and answers it ok" answered ida x.md "ok recovered-x"
  check "[C57] and names its readers, the commit's" \
    eventually bash -c '[[ $(jq -c "select(.id == \"recovered-x\" and .action == \"mail\") | .target" "$1") == "[\"Harbor Keeper\"]" ]]' _ "$s/comms/record"
  rm -rf -- "$run/lodge/carrier"
  wait "${carriers[@]}"
  # A fresh store: the first delivery starts from no head, and another floor's commit follows it.
  rm -rf -- "$run"
  check "unbuild" exit_is 0 wp unbuild
  rm -rf -- "$store"
  check "build again, which makes the store afresh" exit_is 0 wp build
  check "the store has no commit" test "$(store_commits)" = 0
  for f in "Lodge Ida/sent" "Harbor Keeper/in"; do printf '%s\n' x > "$store/$f/first-x.md"; done
  sgit add -- "Lodge Ida/sent/first-x.md" "Harbor Keeper/in/first-x.md"
  sgit -c user.name=t -c user.email=t@t commit -q -m "deliver first-x"
  printf '%s\n' y > "$store/Harbor Pilot/in/other-y.md"
  sgit add -- "Harbor Pilot/in/other-y.md"
  sgit -c user.name=t -c user.email=t@t commit -q -m "deliver other-y"
  jq -n -c '{id: "first-x", box: "Lodge Ida", request: "f.md", action: "mail", seat: "Lodge Ida", base: ""}' > "$s/floors/lodge/comms/serving"
  mkdir -p -- "$run/lodge/carrier"
  printf '%s\n' '{"slots": {}}' > "$run/lodge/state.json"
  "$BASH" "$clone/BUILD/bin/workplace" carry lodge > "$scratch/carry-lodge" 2>&1 &
  carriers=("$!")
  check "[C57] review of 4a: recovery finds the store's first delivery, whose journal noted no head, though another floor committed after it" \
    answered ida f.md "ok first-x"
  rm -rf -- "$run/lodge/carrier"
  wait "${carriers[@]}"
  # A stopped delivery's copies that only the index holds, where the index is locked and the reset cannot run.
  for f in "Lodge Ida/sent" "Harbor Keeper/in"; do printf '%s\n' z > "$store/$f/half-z.md"; done
  sgit add -- "Lodge Ida/sent/half-z.md" "Harbor Keeper/in/half-z.md"
  : > "$store/.git/index.lock"
  jq -n -c --arg b "$(sgit rev-parse HEAD)" '{id: "half-z", box: "Lodge Ida", request: "z.md", action: "mail", seat: "Lodge Ida", base: $b}' > "$s/floors/lodge/comms/serving"
  mkdir -p -- "$run/lodge/carrier"
  "$BASH" "$clone/BUILD/bin/workplace" carry lodge > "$scratch/carry-lodge" 2>&1 &
  carriers=("$!")
  check "[C57] a delivery whose commit does not stand is answered as gone to none" \
    answered ida z.md "refused the carrier stopped while it served this, and it went to none; leave it in out again"
  check "[C57] review of 4a: and its copies are removed, though the index still holds them, since HEAD does not" \
    bash -c '[[ ! -e $1/Lodge\ Ida/sent/half-z.md && ! -e $1/Harbor\ Keeper/in/half-z.md ]]' _ "$store"
  rm -rf -- "$run/lodge/carrier"
  wait "${carriers[@]}"
  rm -f -- "$store/.git/index.lock"
}

# A pointer settles exactly what it counted (5.162 point 1): mail that another floor's carrier delivers to its reader
# while it is typed stays to be pointed out. The test holds the store's lock across the pointer, so that its settle
# waits, and in that time adds a due id as the deck's carrier would under its hold.
t_wake_floors() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$root/screens"
  local d=$root/screens
  printf '%s\n' busy > "$d/screen"
  local kinds='| kinds([["harbor", "dock", "keeper", "clerk"], ["harbor", "dock", "pilot", "clerk"], ["harbor", "tower", "watch", "clerk"],
      ["orchard", "barn", "grower", "clerk"], ["orchard", "barn", "picker", "clerk"], ["lodge", "east", "ida", "clerk"]])'
  statements_plan "$floors_terms | $comms_terms $kinds"' | .programs[-1].recorded += [
      m(["reach", "harbor", "-", "-", "office", "mail", "lodge", "-", "-", "floor", "allowed"]; 2),
      m(["wake", "clerk", "^waiting>$"]; 3)]
    | def add($path; $args): (.programs[] | select(.path == $path) | .plan[1].term[5]) |= (fromjson + $args | tojson);
      add("lodge/east/ida/seat.typify"; ["screen=" + $root + "/screens/screen", "typed=" + $root + "/screens/typed"])
    | .programs[-1].recorded += [st("lodge"; "east"; "-"; "room"; $root + "/screens"; "read-write"; 20)]'
  check "plan of floors whose lodge reader has a wake" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "up lodge" exit_is 0 wp up lodge
  check "ida's pane works" eventually_long on lodge screen_has "Lodge Ida" "working"
  local s k1 x=20261114T235959Z-999999 holder deck path
  s=$(state_of)
  path=$(jq -r '.path' "$clone/BUILD/shared/$(top_gen)/mail.json")
  mkdir -p -- "$run/deck/carrier"
  printf '%s\n' '{"slots": {}}' > "$run/deck/state.json"
  "$BASH" "$clone/BUILD/bin/workplace" carry deck > "$scratch/carry-deck" 2>&1 &
  deck=$!
  request keeper k1.md "to: Lodge Ida" "subject: one" --- "body"
  check "the deck's carrier delivers a mail to the lodge's reader" answered_ok keeper k1.md
  k1=$(answer_of keeper k1.md) k1=${k1#ok }
  check "[C94] the reader is due its pointer, while its pane is not ready" \
    test "$(jq -c '.seats["Lodge Ida"] | [.count, .ids]' "$s/comms/wake.json")" = "[1,[\"$k1\"]]"
  flock -o "$s/mail" sleep 40 &
  holder=$!
  check "the test holds the store's lock" eventually bash -c '! flock -n "$1" true' _ "$s/mail"
  printf '%s\n' ready > "$d/screen"
  check "[C94] the lodge's carrier types the pointer, which needs no lock" \
    file_comes_to "$d/typed" "mail: 1 new, newest $k1.md, in $path/in, and the page $path/README.md says what this line is"
  sleep 2
  check "[C94] 5.162 point 1: while the lock is held the pointer is not settled: its ids stay in wake.json" \
    test "$(jq -c '.seats["Lodge Ida"].ids' "$s/comms/wake.json")" = "[\"$k1\"]"
  check "[C57] review of 4a: and its line is not written without the lock: it waits for the carrier's next hold" \
    bash -c '[[ -z $(jq -c "select(.action == \"wake\" and has(\"length\"))" "$1") ]]' _ "$s/comms/record"
  jq --arg x "$x" '.seats["Lodge Ida"] |= (.ids += [$x] | .times[$x] = "2026-11-14T23:59:59Z" | .count = (.ids | length))' \
    "$s/comms/wake.json" > "$scratch/wake" && cat -- "$scratch/wake" > "$s/comms/wake.json"
  pkill -P "$holder" sleep 2> /dev/null
  wait "$holder" 2> /dev/null
  check "[C94] 5.162 point 1: once it settles, the mail it counted is no longer to be pointed out, and the mail delivered meanwhile stays" \
    eventually bash -c '[[ $(jq -c ".seats[\"Lodge Ida\"] | [.count, .ids, .since, (.last > 0)]" "$1") == "[1,[\"$2\"],\"2026-11-14T23:59:59Z\",true]" ]]' _ "$s/comms/wake.json" "$x"
  check "[C96] the pointer's line covers the mail it counted alone, written once the lock is free" \
    test "$(jq -c --arg k "$k1" 'select(.action == "wake" and has("length")) | [.target, .covers, .outcome]' "$s/comms/record")" = "[[\"Lodge Ida\"],[\"$k1\"],\"ok\"]"
  rm -rf -- "$run/deck/carrier"
  wait "$deck"
  check "down lodge" exit_is 0 wp down lodge
}

# Ruled properties of the floors' carriers that no other check holds (5.176 point 11): the journal in the floor's own
# state, recovery under a hold, a bounded wait for the store's lock and a stop while another holds it, and a floor's
# key that would be a pattern to systemctl. The floors stand up with up, their carriers with them.
t_carrier_floors() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/mailbox" "$root/screens"
  local d=$root/screens
  printf '%s\n' busy > "$d/screen"
  local kinds='| kinds([["harbor", "dock", "keeper", "clerk"], ["harbor", "dock", "pilot", "clerk"], ["harbor", "tower", "watch", "clerk"],
      ["orchard", "barn", "grower", "clerk"], ["orchard", "barn", "picker", "clerk"], ["lodge", "east", "ida", "clerk"]])'
  statements_plan "$floors_terms | $comms_terms $kinds"' | .programs[-1].recorded += [
      m(["reach", "harbor", "-", "-", "office", "mail", "lodge", "-", "-", "floor", "allowed"]; 2),
      m(["reach", "lodge", "-", "-", "floor", "mail", "harbor", "-", "-", "office", "allowed"]; 3),
      m(["reach", "harbor", "dock", "-", "room", "mail", "harbor", "dock", "-", "room", "allowed"]; 4),
      m(["wake", "clerk", "^waiting>$"]; 5)]
    | def add($path; $args): (.programs[] | select(.path == $path) | .plan[1].term[5]) |= (fromjson + $args | tojson);
      add("lodge/east/ida/seat.typify"; ["screen=" + $root + "/screens/screen", "typed=" + $root + "/screens/typed"])
    | .programs[-1].recorded += [st("lodge"; "east"; "-"; "room"; $root + "/screens"; "read-write"; 20)]'
  check "plan of floors with mail between the harbor and the lodge and in the dock, and a wake for the lodge's reader" exit_is 0 wplan
  check "build" exit_is 0 wp build
  local s holder path k1 lodge_carrier real_git
  s=$(state_of)
  # A gate on git's commit for the deck's carrier alone: while the test's file gate.on stands, a delivery waits in its
  # commit, under its hold, so that its journal and its copy stand until the test has looked.
  real_git=$(command -v git)
  mkdir -p -- "$scratch/gate"
  printf '%s\n' '#!/usr/bin/env bash' \
    "for a in \"\$@\"; do [[ \$a == commit ]] || continue; for (( i = 0; i < 600; i++ )); do [[ -e '$scratch/gate.on' ]] || break; sleep 0.1; done; break; done" \
    "exec '$real_git' \"\$@\"" > "$scratch/gate/git"
  chmod +x -- "$scratch/gate/git"
  check "up deck, its carrier's git gated by the test" exit_is 0 env PATH="$scratch/gate:$PATH" "$BASH" "$loop" up deck
  : > "$scratch/gate.on"
  request keeper m1.md "to: Harbor Pilot" "subject: gated" --- "body"
  check "[C56] follow-up of 4a: while a delivery of the deck waits in its commit, its journal stands in the deck's own state, S/floors/deck/comms/serving, naming it, and its copy in S/floors/deck/comms/taken" \
    eventually_long bash -c '[[ $(jq -r .request "$1/serving" 2> /dev/null) == m1.md ]] && c=("$1"/taken/*.copy) && [[ -f ${c[0]} ]]' _ "$s/floors/deck/comms"
  check "[C56] follow-up of 4a: and S/comms holds neither a journal nor a taken" bash -c '[[ ! -e $1/serving && ! -e $1/taken ]]' _ "$s/comms"
  rm -f -- "$scratch/gate.on"
  check "the mail is delivered once the gate is open" answered_ok keeper m1.md
  check "[C56] follow-up of 4a: once it is answered its journal is removed from the deck's state, and none stands in S/comms" \
    eventually bash -c '[[ ! -e $1/floors/deck/comms/serving && ! -e $1/comms/serving ]]' _ "$s"
  check "up lodge" exit_is 0 wp up lodge
  check "ida's pane works" eventually_long on lodge screen_has "Lodge Ida" "working"
  path=$(jq -r '.path' "$clone/BUILD/shared/$(top_gen)/mail.json")
  request keeper k1.md "to: Lodge Ida" "subject: one" --- "body"
  check "the deck's carrier delivers a mail to the lodge's reader" answered_ok keeper k1.md
  k1=$(answer_of keeper k1.md) k1=${k1#ok }
  check "the reader is due its pointer, while its pane is not ready" \
    eventually bash -c '[[ $(jq -c ".seats[\"Lodge Ida\"] | [.count, .ids]" "$1") == "[1,[\"$2\"]]" ]]' _ "$s/comms/wake.json" "$k1"
  # The bounded wait (5.160 point 5): the test holds the store's lock across several passes. A request of the lodge's
  # writer makes each pass try the lock and fail; once the request is taken back, a later pass types the pointer, which
  # needs no lock, so the pass that failed did end. Then down stops the carrier while the lock is still held. The
  # holder outlives every wait below, and the test lets it go itself.
  flock -o "$s/mail" sleep 300 &
  holder=$!
  check "the test holds the store's lock" eventually bash -c '! flock -n "$1" true' _ "$s/mail"
  request ida i1.md "to: Harbor Keeper" "subject: waits" --- "body"
  lodge_carrier=$(carrier_pid lodge)
  check "[C57] 5.177: before the request is taken back, the lodge's carrier tries for the store's lock: a flock that it started is blocked on the store, as /proc/locks reads it" \
    eventually_long blocked_in_flock "$lodge_carrier" "$s/mail"
  sleep 3
  check "[C57] follow-up of 4a: while the test holds the store's lock, the lodge's carrier does not take its writer's request: it waits in out, with no answer" \
    bash -c '[[ -f $1/out/i1.md && ! -e $1/answers/i1.md ]]' _ "$s/comms/Lodge Ida"
  rm -f -- "$s/comms/Lodge Ida/out/i1.md"
  printf '%s\n' ready > "$d/screen"
  check "[C57] follow-up of 4a: its wait for the lock is bounded: the pass whose try failed ends, and a later pass, the lock still held, types the pointer, which needs no lock" \
    file_comes_to "$d/typed" "mail: 1 new, newest $k1.md, in $path/in, and the page $path/README.md says what this line is"
  check "the test still holds the store's lock" bash -c '! flock -n "$1" true' _ "$s/mail"
  lodge_carrier=$(carrier_pid lodge)
  check "[C57] follow-up of 4a: down lodge, while the test still holds the store's lock, ends the floor's carrier within the ten seconds down waits, with exit 0" exit_is 0 wp down lodge
  check "[C57] follow-up of 4a: its carrier's process is gone, and the test held the lock throughout" \
    bash -c '[[ -n $1 ]] && ! kill -0 "$1" 2> /dev/null && ! flock -n "$2" true' _ "$lodge_carrier" "$s/mail"
  pkill -P "$holder" sleep 2> /dev/null
  wait "$holder" 2> /dev/null
  # Recovery under a hold (5.162 point 1): a stopped request's journal in the lodge's own state, and one in the shared
  # S/comms, which is no floor's, planted while the lodge is down; the lodge comes up while the test holds the lock.
  printf '%s\n' busy > "$d/screen"
  jq -n -c '{id: "20261115T000000Z-900001", box: "Lodge Ida", request: "f1.grab", action: "grab", seat: "Lodge Ida"}' > "$s/floors/lodge/comms/serving"
  jq -n -c '{id: "20261115T000000Z-900002", box: "Lodge Ida", request: "s1.grab", action: "grab", seat: "Lodge Ida"}' > "$s/comms/serving"
  # As above, the holder outlives every wait until the test lets it go.
  flock -o "$s/mail" sleep 300 &
  holder=$!
  check "the test holds the store's lock again" eventually bash -c '! flock -n "$1" true' _ "$s/mail"
  check "up lodge, with a stopped request's journal in its state, while the test holds the store's lock" exit_is 0 wp up lodge
  sleep 3
  check "[C57] follow-up of 4a: recovery runs under a hold: while the test holds the store's lock, the lodge's carrier does not recover the journal: it stays, and its request has no answer and no line" \
    bash -c '[[ -f $1 && ! -e $2/answers/f1.grab ]] && ! grep -qF "\"request\":\"f1.grab\"" "$3"' _ "$s/floors/lodge/comms/serving" "$s/comms/Lodge Ida" "$s/comms/record"
  pkill -P "$holder" sleep 2> /dev/null
  wait "$holder" 2> /dev/null
  check "[C57] follow-up of 4a: once the test lets go, the carrier recovers it: its request is answered" \
    answered ida f1.grab "refused the carrier stopped while it served this, and whether it acted is not known"
  check "[C57] follow-up of 4a: its line stands in the record, and the journal is removed" \
    eventually bash -c '[[ ! -e $1 && $(jq -r "select(.request == \"f1.grab\") | .outcome" "$2") == refused ]]' _ "$s/floors/lodge/comms/serving" "$s/comms/record"
  sleep 2
  check "[C56] follow-up of 4a: a journal in the shared S/comms is no floor's: neither floor's carrier recovers it, and its request has no answer and no line" \
    bash -c '[[ -f $1 && ! -e $2/answers/s1.grab ]] && ! grep -qF "\"request\":\"s1.grab\"" "$3"' _ "$s/comms/serving" "$s/comms/Lodge Ida" "$s/comms/record"
  rm -f -- "$s/comms/serving"
  check "down deck" exit_is 0 wp down deck
  check "down lodge" exit_is 0 wp down lodge
  check "unbuild" exit_is 0 wp unbuild
  # A floor's key that holds *, ? or [ is a pattern to systemctl that matches the lodge's unit, unless it is escaped.
  # Units are made only where the records' chain goes to the journal.
  if ! systemctl --user show-environment > /dev/null 2>&1; then
    skip "[C72] follow-up of 4a: no user manager answers here, so no carrier's unit is made, and a floor's key with *, ? or [ is tried where one answers"
    return 0
  fi
  mkdir -p -- "$root/records"
  local pair key esc kj own lodge_unit=workplace-carrier-$label-lodge.service lodge_inv
  for pair in 'l*|l\x2a' 'l?dge|l\x3fdge' '[l]odge|\x5bl\x5dodge'; do
    key=${pair%%|*} esc=${pair#*|}
    own=workplace-carrier-$label-$esc.service
    kj=$(jq -n --arg k "$key" '$k')
    floors_clone
    jq --arg k "$key" '(.floors[] | select(.key == "deck") | .key) = $k' "$clone/workplace.json" > "$scratch/w" && cp -- "$scratch/w" "$clone/workplace.json"
    statements_plan "$floors_terms | $kj as \$k"' | (.programs[0].plan[] | select(.[0] == "floor" and .[1] == "deck") | .[1]) = $k
      | (.programs[] | select(.path == "harbor/office.typify") | .plan[] | select(type == "array" and .[0] == "house") | .[1]) = $k
      | def r($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/LOGS.typify"}};
        .programs[-1].recorded += [r(["record", "-", "-", "-", "workplace", "pane", "kept"]; 1), r(["record-path", "records"]; 2), r(["record-chain", "journal"]; 3)]'
    check "plan of floors whose deck's key is $key, which as a pattern matches lodge, with the records chained to the journal" exit_is 0 wplan
    check "build" exit_is 0 wp build
    # The floor whose key is a pattern comes up first, so that down meets the lodge's unit running beside its own.
    check "up $key" exit_is 0 wp up "$key"
    check "up lodge" exit_is 0 wp up lodge
    check "[C72] follow-up of 4a: the floor $key's carrier runs as a unit of its own, $own, where each byte of the key outside letters, digits and _ . : - is written \\xHH" systemctl --user is-active --quiet "$own"
    check "[C72] follow-up of 4a: and the lodge's carrier as its own, $lodge_unit" systemctl --user is-active --quiet "$lodge_unit"
    lodge_inv=$(systemctl --user show -p InvocationID --value "$lodge_unit" 2> /dev/null)
    check "[C72] follow-up of 4a: down $key, with exit 0" exit_is 0 wp down "$key"
    check "[C72] follow-up of 4a: stops the floor $key's own unit" bash -c '! systemctl --user is-active --quiet "$1"' _ "$own"
    check "[C72] follow-up of 4a: and no other: the lodge's unit still runs, the same invocation" \
      bash -c '[[ -n $2 ]] && systemctl --user is-active --quiet "$1" && [[ $(systemctl --user show -p InvocationID --value "$1") == "$2" ]]' _ "$lodge_unit" "$lodge_inv"
    check "down lodge" exit_is 0 wp down lodge
    check "unbuild" exit_is 0 wp unbuild
  done
}

# The readers with floors (review of 4a): status' homes per floor, doctor through the top, record verify by the
# seat's floor, and unbuild's locks taken before it reads RUN.
t_floors_readers() {
  scoped_clone
  floors_clone
  mkdir -p -- "$root/records" "$root/tools"
  # A seed that leaves a process of its own behind, which would hold the build's lock had build not closed it.
  printf '%s\n' '#!/usr/bin/env bash' 'setsid -f sleep 23.4567 > /dev/null 2>&1 < /dev/null' 'exit 0' > "$root/tools/linger"
  chmod +x -- "$root/tools/linger"
  # The record terms alone: a reach at a seat's scope is refused in a room of two on an enforced floor (5.118).
  statements_plan "$floors_terms"' | def r($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/LOGS.typify"}};
    def h($t; $line): {term: $t, origin: {kind: "program", line: $line, path: "programs/HOMES.typify"}};
    .programs[-1].recorded += [r(["record", "-", "-", "-", "workplace", "pane", "kept"]; 1), r(["record-path", "records"]; 2), r(["record-chain", "file"]; 3)]
    |
    kinds([["harbor", "dock", "keeper", "navigator"], ["harbor", "dock", "pilot", "navigator"], ["harbor", "tower", "watch", "navigator"],
           ["orchard", "barn", "grower", "navigator"], ["orchard", "barn", "picker", "navigator"], ["lodge", "east", "ida", "navigator"]])
    | .programs[-1].recorded += [h(["home", "navigator", "WPT_HOME", "kept"]; 20), h(["home-seed", "navigator", "tools/linger"]; 21)]'
  check "plan of floors with kept homes, a seed and records" exit_is 0 wplan
  check "build" exit_is 0 wp build
  local s rc
  s=$(state_of)
  check "the seed left a process behind" pgrep -f '^sleep 23\.4567$'
  check "[C102] review of 4a: and that process holds not the build's lock, since build closed it in the seeds it starts" flock -n "$s/build.lock" true
  pkill -f '^sleep 23\.4567$' 2> /dev/null
  check "[C51] status of a floor names its seats' kept homes" exit_is 0 wp status deck
  check "[C51] each of that floor's, from its own generation" bash -c 'grep -q "^home    Harbor Keeper (harbor/dock/keeper): kept at " "$1" && ! grep -q "^home    Lodge Ida" "$1"' _ "$scratch/out"
  rm -rf -- "$s/floors/deck/homes/navigator/Harbor Keeper"
  check "[C51] review of 4a: with floors, status of a floor exits 1 for a kept home of it that is missing" exit_is 1 wp status deck
  check "[C51] naming it" said "missing home $s/floors/deck/homes/navigator/Harbor Keeper"
  check "[C51] and status of another floor does not" exit_is 0 wp status lodge
  check "[C51] while a bare status does" exit_is 1 wp status
  check "doctor" exit_is 0 wp doctor
  check "[C102] review of 4a: doctor reads the build through its top and names each floor's homes" \
    bash -c 'grep -qxF "ok      the seats'"'"' homes in $1/floors/deck/homes: 3 kept, 0 scratch" "$2" && grep -qxF "ok      the seats'"'"' homes in $1/floors/lodge/homes: 1 kept, 0 scratch" "$2"' _ "$s" "$scratch/out"
  # The clone named through a link whose name holds & and |, which a sed replacement would read as its own.
  ln -s -- "$clone" "$scratch/c&l|one"
  env WORKPLACE_CONFIG="$scratch/c&l|one" "$BASH" "$loop" doctor > "$scratch/out" 2>&1
  check "[C102] follow-up of 4a: doctor names each floor's homes where the clone's path holds & and |" \
    bash -c 'grep -qxF "ok      the seats'"'"' homes in $1/floors/deck/homes: 3 kept, 0 scratch" "$2" && grep -qxF "ok      the seats'"'"' homes in $1/floors/lodge/homes: 1 kept, 0 scratch" "$2"' _ "$s" "$scratch/out"
  rm -f -- "$scratch/c&l|one"
  wp record verify "Harbor Keeper" unstored > "$scratch/out" 2>&1
  rc=$?
  check "[C75] review of 4a: with floors, record verify reads the seat's floor's records" bash -c '[[ $1 != 2 ]] && ! grep -q "keeps no record" "$2"' _ "$rc" "$scratch/out"
  check "[C75] with floors, record verify --requests is refused, with exit 2" exit_is 2 wp record verify --requests
  check "[C75] saying when it comes" said "with floors, record verify --requests comes with the record of requests of each floor, in S2's stop 4b"
  check "[C57] the carrier's unit with floors names the workplace and the floor" \
    test "$(jq -r '.unit' "$clone/BUILD/$(sed -n 's|^[0-9a-f]\{64\}  \(floors/deck/[0-9]*\)/MANIFEST$|\1|p' "$clone/BUILD/MANIFEST")/records.json")" = "workplace-carrier-$label-deck.service"
  local holder
  flock -o "$s/build.lock" sleep 6 &
  holder=$!
  check "the test holds the build's lock" eventually bash -c '[[ -f $1 ]] && ! flock -n "$1" true' _ "$s/build.lock"
  check "[C99] review of 4a: unbuild refuses while a build holds the build's lock, with exit 1" exit_is 1 wp unbuild
  check "[C99] naming it" said "unbuild refuses: a build holds $s/build.lock"
  check "[C99] and removes nothing" test -f "$clone/BUILD/MANIFEST"
  pkill -P "$holder" sleep 2> /dev/null
  wait "$holder" 2> /dev/null
  rm -f -- "$s/floors/bridge/up.lock" "$s/floors/deck/up.lock" "$s/floors/lodge/up.lock"
  ( umask 077 && : >> "$s/floors/deck/up.lock" )
  flock -o "$s/floors/deck/up.lock" sleep 6 &
  holder=$!
  check "the test holds the deck's floor lock" eventually bash -c '! flock -n "$1" true' _ "$s/floors/deck/up.lock"
  check "[C99] review of 4a: unbuild refuses while an up or a restart holds a floor's lock, with exit 1" exit_is 1 wp unbuild
  check "[C99] naming it" said "unbuild refuses: an up or a restart holds $s/floors/deck/up.lock"
  check "[C99] having made a floor's missing lock first, mode 600, so that the first up after a build is fenced" \
    test "$(stat -c %a "$s/floors/bridge/up.lock" 2> /dev/null)" = 600
  pkill -P "$holder" sleep 2> /dev/null
  wait "$holder" 2> /dev/null
  check "[C99] unbuild, once no lock is held" exit_is 0 wp unbuild
}

# An unenforced floor on a run socket stands up in 4a as an enforced one does (5.167 point 2): its seats have no view,
# its server and its carrier run, and status names what it lacks in 4a.
t_floors_unenforced() {
  scoped_clone
  floors_clone
  jq '(.floors[] | select(.key == "bridge") | .socket) = "run"' "$clone/workplace.json" > "$scratch/w" && cp -- "$scratch/w" "$clone/workplace.json"
  statements_plan "$floors_terms"' | (.programs[0].plan[] | select(.[0] == "floor" and .[1] == "bridge")) |= (.[5] = "run")'
  check "plan of an unenforced floor on a run socket" exit_is 0 wplan
  check "[C104] the view names it unenforced, on a run socket" \
    test "$(jq -c '[.floors[] | select(.key == "bridge") | .enforced, .socket]' "$clone/PLAN/view.json")" = '[false,"run"]'
  check "build" exit_is 0 wp build
  if [[ $(nnp_of $$) != NoNewPrivs:0 ]]; then
    skip "[C104] 4a2: unenforced server and seats need a caller without the bar"
    check "[C104] the barred caller is refused" exit_is 1 wp up bridge
  else
    check "[C101] 4a2: up of an unenforced floor on a run socket" exit_is 0 wp up bridge
    check "[C68] on its own server at RUN/bridge" test -S "$run/bridge/$label"
    check "[C8] which holds the orchard's session" on bridge sessions_are "Orchard "
    check "[C104] its seats' programs run, with no view" on bridge eventually_long live_pane "Orchard Grower"
    check "[C22] 4a2: status reads the frame's set" exit_is 0 wp status bridge
    check "[C22] and reports agreement" said "set     the floor's frame settings agree"
    check "[C104] 4a2: the unenforced server has no inherited bar" \
      test "$(nnp_of "$(on bridge T display-message -p '#{pid}')")" = NoNewPrivs:0
    check "down bridge" exit_is 0 wp down bridge
  fi
  check "unbuild" exit_is 0 wp unbuild
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
  statements_plan '.state.view = [{key: ["harbor", "dock", "keeper", ($root + "/harbor/ledger")], value: ["read-write"]}]
    | .programs[-1].recorded += [lb($root + "/harbor/ledger"; "closed"; 30), sc(31)]'
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
  check "[C17] review of 4a: exec as a pane runs it, from BUILD's own copy of the frame, prints its call and nothing else" \
    bash -c '"$BASH" "$1/BUILD/bin/workplace" exec --print -- "Harbor Keeper" > "$2/exec.out" 2> "$2/exec.err" && [[ -s $2/exec.out && ! -s $2/exec.err ]]' _ "$clone" "$scratch"
  T capture-pane -p -S - -t "$(pane_by_title "Harbor Keeper")" > "$scratch/history" 2> /dev/null
  check "[C17] and the pane's history holds no line of jq's" bash -c '[[ -s $1 ]] && ! grep -q "^jq: " "$1"' _ "$scratch/history"
  mv -- "$root/harbor/berth" "$root/harbor/berth.real"
  ln -s -- ledger "$root/harbor/berth"
  check "[C31] review of 4a: exec as a pane runs it refuses, with exit 2, a view that would now hold the closed ledger under another name" \
    exit_is 2 "$BASH" "$clone/BUILD/bin/workplace" exec --print -- "Harbor Keeper"
  check "[C31] naming the row" said "its row $root/harbor/berth (read-write, from "
  rm -f -- "$root/harbor/berth"
  mv -- "$root/harbor/berth.real" "$root/harbor/berth"
  # A build changed by hand: its folded view taken away, and its MANIFEST's line for it with it. A pane's exec runs no
  # report of the plan first, so the rule's own line is the refusal there.
  cp -- "$clone/BUILD/MANIFEST" "$scratch/MANIFEST.kept"
  mv -- "$clone/BUILD/plan-view.json" "$scratch/plan-view.kept"
  restamp plan-view.json
  check "[C31] 5.177: a pane's exec of a build changed by hand, whose plan folds and which holds no folded view, refuses with exit 2" \
    exit_is 2 "$BASH" "$clone/BUILD/bin/workplace" exec --print -- "Harbor Keeper"
  check "[C31] with the rule's line" said "the plan folds, and no folded view is given"
  mv -- "$scratch/plan-view.kept" "$clone/BUILD/plan-view.json"
  cp -- "$scratch/MANIFEST.kept" "$clone/BUILD/MANIFEST"
  # The plan's root, compared at up, restart and exec, is the same directory however it is written; one that cannot be
  # read as an absolute path is refused (5.177 point 6).
  cp -- "$clone/BUILD/plan-manifest.json" "$scratch/plan-manifest.kept"
  ln -sfn -- "$root" "$scratch/rootlink"
  jq --arg r "$scratch/rootlink" '.root = $r' "$scratch/plan-manifest.kept" > "$clone/BUILD/plan-manifest.json"
  restamp plan-manifest.json
  check "[C31] 5.177: a pane's exec takes a plan whose root is the same directory written through a link" \
    exit_is 0 "$BASH" "$clone/BUILD/bin/workplace" exec --print -- "Harbor Keeper"
  jq '.root = "harbor"' "$scratch/plan-manifest.kept" > "$clone/BUILD/plan-manifest.json"
  restamp plan-manifest.json
  check "[C31] 5.177: a pane's exec refuses a plan whose root it cannot read as an absolute path, with exit 2" \
    exit_is 2 "$BASH" "$clone/BUILD/bin/workplace" exec --print -- "Harbor Keeper"
  check "[C31] naming the plan's manifest" said "exec refuses: cannot read the plan's root in $clone/BUILD/plan-manifest.json"
  cp -- "$scratch/plan-manifest.kept" "$clone/BUILD/plan-manifest.json"
  cp -- "$scratch/MANIFEST.kept" "$clone/BUILD/MANIFEST"
  check "[C33] down" exit_is 0 wp down
  rm -rf -- "$clone/BUILD"
  rm -- "$clone/PLAN/view.json"
  check "[C33] a plan that holds statements and has lost its view.json does not build" exit_is 1 wp build
  check "[C33] naming the file" said "PLAN/view.json is missing"
}

# A build changed by hand: the line of BUILD's MANIFEST for the file NAME written again, or dropped where the file is
# gone, so that the build verifies, as no plan and verified build would give it.
restamp() {
  local name=$1 line sum out=""
  while IFS= read -r line; do
    [[ ${line#*  } == "$name" ]] && continue
    out+=$line$'\n'
  done < "$clone/BUILD/MANIFEST"
  if [[ -f $clone/BUILD/$name ]]; then
    sum=$(sha256sum < "$clone/BUILD/$name") || return 1
    out+="${sum%% *}  $name"$'\n'
  fi
  printf '%s' "$out" > "$clone/BUILD/MANIFEST"
}

# A copy of the frame of the test's own, at $scratch/frame, which a test may change after a build without editing the
# tree that the suite runs from.
frame_wp() { "$BASH" "$scratch/frame/bin/workplace" "$@"; }

t_closed_names_up() {
  local pane refusal
  scoped_clone
  rm -rf -- "$scratch/frame" && mkdir -- "$scratch/frame" && cp -R -- "$tool/." "$scratch/frame/"
  check "a copy of the frame of the test's own, its binding the tree's" cmp -s "$tool/host/binding.json" "$scratch/frame/host/binding.json"
  # A pane sees the cover: grower's read-write row is written through the link zz, which leads to the root, so that it
  # holds the closed cellar under another name; a hidden row of grower's lies where the row would show the cellar.
  ln -s -- . "$root/zz"
  printf '%s\n' planted > "$root/orchard/cellar/planted"
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard/cellar"; "closed"; 30), sc(31),
      st("orchard"; "barn"; "grower"; "seat"; $root + "/zz/orchard"; "read-write"; 32)]'
  check "plan with grower's read-write row through the link zz to orchard, which holds the closed cellar, and no cover" exit_is 0 wplan
  check "[C31] follow-up of 4a: build refuses that view, since nothing lies where the row would show the cellar, with exit 1" exit_is 1 frame_wp build
  check "[C31] naming that place" said "and would show it at $root/zz/orchard/cellar, where no hidden, scratch or searchable-only row of the view, nor a mask, lies over it"
  rm -rf -- "$clone/BUILD"
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard/cellar"; "closed"; 30), sc(31),
      st("orchard"; "barn"; "grower"; "seat"; $root + "/zz/orchard"; "read-write"; 32),
      st("orchard"; "barn"; "grower"; "seat"; $root + "/zz/orchard/cellar"; "hidden"; 33), st("orchard"; "barn"; "grower"; "seat"; $root + "/orchard"; "read-write"; 34)]
    | (.programs[] | select(.path == "orchard/barn/grower/seat.typify") | .plan[1].term[5]) |= (fromjson
        + ["rw=" + $root + "/zz/orchard/almanac", "hidden=" + $root + "/zz/orchard/cellar", "hidden=" + $root + "/orchard/cellar"] | tojson)'
  check "plan with that row and a hidden row of grower's at the place where it would show the cellar" exit_is 0 wplan
  check "[C31] follow-up of 4a: build accepts it, since the cover lies over that place" exit_is 0 frame_wp build
  check "up" exit_is 0 frame_wp up
  check "grower ran" wait_for_probe "Orchard Grower" grower
  check "[C31] follow-up of 4a: grower's row through the link is bound: it writes orchard's almanac, which the root's read-only row alone would refuse" \
    screen_has "Orchard Grower" "rw $root/zz/orchard/almanac: write=ok"
  check "[C31] follow-up of 4a: a pane sees the cover: where that row would show the closed cellar, grower finds it empty, neither its secret nor the file planted in it" \
    screen_has "Orchard Grower" "hidden $root/zz/orchard/cellar: unseen"
  check "[C31] and so at the cellar's own path, which the row's bind lies over" screen_has "Orchard Grower" "hidden $root/orchard/cellar: unseen"
  check "and both files stand in the cellar on the machine" test -s "$root/orchard/cellar/secret" -a -s "$root/orchard/cellar/planted"
  check "down" exit_is 0 frame_wp down
  rm -rf -- "$clone/BUILD"
  rm -f -- "$root/zz"
  # A link swapped after the build: grower's read-only row lnk/inner leads first to a harmless directory, and then
  # beneath the closed cellar. The label is written relative to the root, so that only a binding that joins a label's
  # path finds the cellar.
  mkdir -p -- "$root/harbor/charts/inner" "$root/orchard/cellar/inner"
  ln -s -- harbor/charts "$root/lnk"
  statements_plan '.programs[-1].recorded += [lb("orchard/cellar"; "closed"; 30), sc(31),
      st("orchard"; "barn"; "grower"; "seat"; $root + "/lnk/inner"; "read-only"; 32)]'
  check "plan with a closed label written relative to the root and grower's read-only row through the link lnk to harbor/charts" exit_is 0 wplan
  check "build, which the rule accepts" exit_is 0 frame_wp build
  ln -sfn -- orchard/cellar "$root/lnk"
  refusal="its row $root/lnk/inner (read-only, from programs/policy.typify:32) is the directory $root/orchard/cellar/inner, at or beneath $root/orchard/cellar, closed by the label at programs/policy.typify:30 as $root/orchard/cellar"
  check "[C31] follow-up of 4a: a link swapped after the build into a directory beneath the closed cellar makes up exit 1" exit_is 1 frame_wp up
  check "[C31] saying so" said "up refuses: a seat's view would hold a closed directory under another name"
  check "[C31] naming the row and the directory it now leads to" said "$refusal"
  check "[C31] and up left no run directory" test ! -e "$clone/BUILD/RUN"
  check "[C31] and started no server" no_server
  jq 'del(.paths.recorded.label)' "$scratch/frame/host/binding.json" > "$scratch/binding" && mv -- "$scratch/binding" "$scratch/frame/host/binding.json"
  check "the frame's copy now holds a binding that does not join a label's path" test "$(jq -c '.paths.recorded.label' "$scratch/frame/host/binding.json")" = null
  check "[C31] follow-up of 4a: up decides by the build's binding, which joins the label, and not by the frame's, which would not find the cellar: exit 1" \
    exit_is 1 frame_wp up
  check "[C31] naming the same row" said "$refusal"
  check "[C31] and up left no run directory" test ! -e "$clone/BUILD/RUN"
  printf '%s\n' 'not JSON' > "$scratch/frame/host/binding.json"
  printf '%s\n' 'def broken(: ;' >> "$scratch/frame/libexec/table.jq"
  ln -sfn -- harbor/charts "$root/lnk"
  check "[C31] follow-up of 4a: with the link back, up from a frame whose binding is not JSON and whose table.jq does not compile reads the build's, and starts" \
    exit_is 0 frame_wp up
  check "grower ran" wait_for_probe "Orchard Grower" grower
  pane=$(pane_by_title "Orchard Grower")
  T send-keys -t "$pane" C-c
  check "grower's program ends" eventually_long dead_pane "Orchard Grower"
  ln -sfn -- orchard/cellar "$root/lnk"
  check "[C31] follow-up of 4a: after up, the link swapped into a directory beneath the closed cellar makes restart exit 1" \
    exit_is 1 frame_wp restart "Orchard Grower"
  check "[C31] saying so" said "restart refuses: a seat's view would hold a closed directory under another name"
  check "[C31] naming the row, as the build's binding and library read it" said "$refusal"
  check "[C31] and grower's pane stays dead" dead_pane "Orchard Grower"
  ln -sfn -- harbor/charts "$root/lnk"
  check "[C31] follow-up of 4a: with the link back, restart from that frame reads the build's binding and library, and starts grower again" \
    exit_is 0 frame_wp restart "Orchard Grower"
  check "grower runs again" eventually_long live_pane "Orchard Grower"
  # A fault in grower's view, and another seat, picker.
  check "picker ran" wait_for_probe "Orchard Picker" picker
  ln -sfn -- orchard/cellar "$root/lnk"
  check "[C31] 5.177: with grower's link swapped into the cellar, a pane's exec of grower still refuses, with exit 2" \
    exit_is 2 "$BASH" "$clone/BUILD/bin/workplace" exec --print -- "Orchard Grower"
  check "[C31] 5.177: and a pane's exec of picker reads picker's view alone and is not refused for grower's: exit 0" \
    exit_is 0 "$BASH" "$clone/BUILD/bin/workplace" exec --print -- "Orchard Picker"
  T send-keys -t "$(pane_by_title "Orchard Picker")" C-c
  check "picker's program ends" eventually_long dead_pane "Orchard Picker"
  check "[C31] 5.177: restart of picker, whose own view holds no fault, refuses for the fault in grower's view, with exit 1" \
    exit_is 1 wp restart "Orchard Picker"
  check "[C31] saying so" said "restart refuses: a seat's view would hold a closed directory under another name"
  check "[C31] naming grower's row" said "$refusal"
  check "[C31] and picker's pane stays dead" dead_pane "Orchard Picker"
  ln -sfn -- harbor/charts "$root/lnk"
  # The root: up, restart and exec act at the plan's own root alone. The root's parent holds the clone, and the closed
  # label, written relative to the root, would be read beneath the parent.
  check "[C31] 5.177: a pane's exec at the root's parent, which holds the clone, refuses a root that is not the plan's, with exit 2" \
    exit_is 2 env WORKPLACE_ROOT="$scratch" "$BASH" "$clone/BUILD/bin/workplace" exec --print -- "Orchard Grower"
  check "[C31] saying so" said "exec refuses: the plan belongs to the root $root, not to $scratch"
  check "[C31] 5.177: restart at the root's parent refuses a root that is not the plan's, with exit 1" \
    exit_is 1 env WORKPLACE_ROOT="$scratch" "$BASH" "$loop" restart "Orchard Picker"
  check "[C31] saying so, before it reads a seat" said "restart refuses: the plan belongs to the root $root, not to $scratch"
  check "[C31] and picker's pane stays dead" dead_pane "Orchard Picker"
  check "restart of picker at the plan's root" exit_is 0 wp restart "Orchard Picker"
  check "down" exit_is 0 frame_wp down
  ln -sfn -- orchard/cellar "$root/lnk"
  check "[C31] 5.177: with the link swapped into the cellar, up at the root's parent, where the rule would not find the cellar, refuses a root that is not the plan's, with exit 1" \
    exit_is 1 env WORKPLACE_ROOT="$scratch" "$BASH" "$loop" up
  check "[C31] saying so" said "up refuses: the plan belongs to the root $root, not to $scratch"
  check "[C31] and up left no run directory" test ! -e "$clone/BUILD/RUN"
  check "[C31] and started no server" no_server
  ln -sfn -- harbor/charts "$root/lnk"
  # A read that the rule cannot make is a refusal at up too (5.177 point 6). The same plan, built again from the test's
  # own tree with the link back; then the link is swapped into the closed cellar, first with its inner directory shut,
  # which the rule resolves without entering it, and then with the cellar itself shut, so that the row leads through a
  # directory that cannot be searched, and the rule cannot tell whether the row stands.
  rm -rf -- "$clone/BUILD"
  ln -sfn -- harbor/charts "$root/lnk"
  check "build of the same plan from the test's own tree, with the link back" exit_is 0 wp build
  ln -sfn -- orchard/cellar "$root/lnk"
  shut "$root/orchard/cellar/inner"
  check "[C31] 5.177: a link swapped after the build into a closed directory of mode 000 makes up exit 1" exit_is 1 wp up
  check "[C31] 5.177: naming the row and the directory it now leads to, read without entering it" said "$refusal"
  check "[C31] 5.177: and up left no run directory" test ! -e "$clone/BUILD/RUN"
  check "[C31] 5.177: and started no server" no_server
  reopen "$root/orchard/cellar/inner"
  shut "$root/orchard/cellar"
  local through="seat Orchard Grower (orchard/barn/grower): its row $root/lnk/inner (read-only, from programs/policy.typify:32): the rule cannot tell whether it stands (Permission denied), and a read that the rule cannot make is a refusal (5.177 point 6)"
  check "[C31] 5.177: with the cellar shut, a row that leads through it makes up exit 1, where up once passed it over as one that does not exist" \
    exit_is 1 wp up
  check "[C31] 5.177: naming the row and the reason that the rule cannot tell" said "$through"
  check "[C31] 5.177: and up left no run directory" test ! -e "$clone/BUILD/RUN"
  check "[C31] 5.177: and started no server" no_server
  rm -rf -- "$clone/BUILD"
  check "[C31] 5.177: build refuses the same row, with exit 1" exit_is 1 wp build
  check "[C31] 5.177: by the rule's line, before its test that what a view grants exists" said "$through"
  reopen "$root/orchard/cellar"
  rm -rf -- "$clone/BUILD"
}

# Two lines of the rule that no plan and verified build reach, on a build that the test changes by hand (5.177 point 6).
t_closed_names_on_a_build_changed_by_hand() {
  scoped_clone
  statements_plan '.programs[-1].recorded += [lb($root + "/orchard/cellar"; "closed"; 30), sc(31)]'
  check "plan with the closed label orchard/cellar, beneath each seat's read-only /" exit_is 0 wplan
  check "build" exit_is 0 wp build
  check "the build's view holds the label's own row, hidden, for each seat" \
    test "$(jq -c --arg p "$root/orchard/cellar" '[.rows[] | select(.key[3] == $p) | .value[0]] | unique' "$clone/BUILD/plan-view.json")" = '["hidden"]'
  jq --arg p "$root/orchard/cellar" 'del(.rows[] | select(.key[3] == $p))' "$clone/BUILD/plan-view.json" > "$scratch/view" \
    && mv -- "$scratch/view" "$clone/BUILD/plan-view.json"
  restamp plan-view.json
  check "the view changed by hand holds no row at the label" \
    test "$(jq --arg p "$root/orchard/cellar" '[.rows[] | select(.key[3] == $p)] | length' "$clone/BUILD/plan-view.json")" = 0
  check "[C31] 5.177: up refuses a view without the label's own row, where each seat's read-only / would show the closed cellar, with exit 1" \
    exit_is 1 wp up
  check "[C31] naming the place, since a label's term mounts nothing and only a row of the view lies over a place" \
    said "is the directory /, which holds $root/orchard/cellar, closed by the label at programs/policy.typify:30 as $root/orchard/cellar, and would show it at $root/orchard/cellar, where no hidden, scratch or searchable-only row of the view, nor a mask, lies over it"
  check "[C31] and up left no run directory" test ! -e "$clone/BUILD/RUN"
  [[ ! -d $run ]] || wp down > /dev/null 2>&1
  rm -rf -- "$clone/BUILD"
  statements_plan '.programs[-1].recorded += [lb("orchard/cellar"; "closed"; 30), sc(31)]'
  check "plan with the closed label written relative to the root" exit_is 0 wplan
  check "build" exit_is 0 wp build
  jq 'del(.paths.recorded.label)' "$clone/BUILD/binding.json" > "$scratch/binding" && mv -- "$scratch/binding" "$clone/BUILD/binding.json"
  restamp binding.json
  check "the build's binding, changed by hand, does not join a label's path" test "$(jq -c '.paths.recorded.label' "$clone/BUILD/binding.json")" = null
  check "[C31] 5.177: up refuses a label that is no absolute path once the build's binding joins it, with exit 1" exit_is 1 wp up
  check "[C31] with the rule's line" \
    said "programs/policy.typify:30: the label of closed names orchard/cellar, which is no absolute path once the binding joins it, so the rule cannot find it on the machine"
  check "[C31] and up left no run directory" test ! -e "$clone/BUILD/RUN"
  [[ ! -d $run ]] || wp down > /dev/null 2>&1
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
  # The exit trap leaves the fixture as the next lines do, and a signal can come while the fixture's server stands. So
  # the fixture comes up again, and is left with its server up.
  local server
  local -a argv
  check "[C28] 5.177: up again, so that the fixture is left while its server stands" exit_is 0 wp up
  server=""
  { read -r server < <(T list-sessions -F '#{pid}'); } 2> /dev/null
  leave_reference
  check "[C28] 5.177: leaving the fixture while its server stands ends that server before it removes BUILD, which holds the server's socket: the server's pid, read from the server, is gone, and so is BUILD" \
    left_without_server "$server" "$clone/BUILD"
  # Where the server outlives that, cleanup can no longer reach it by its socket: it is ended here by its pid, while
  # its argv names the fixture.
  if [[ $server =~ ^[1-9][0-9]*$ ]] && ! gone_pid "$server" && { mapfile -d '' -t argv < "/proc/$server/cmdline"; } 2> /dev/null \
    && [[ ${argv[*]-} == *"$reference/"* ]]; then
    kill -TERM "$server" 2> /dev/null
  fi
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
  check "[C34] the fold's version is one that reads keys" test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-5.131-5.132-5.141-5.146-5.153-5.162-v18
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
    said "the plan was folded by frame-older-v0, and this loop folds by frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-5.131-5.132-5.141-5.146-5.153-5.162-v18; the views are equal, so build goes on"
  check "[C36] a build makes the state directory, 0700, and no key home where no seat holds a key" \
    bash -c '[[ $(stat -c %a "$1") == 700 && ! -e $1/keys ]]' _ "$HOME/.local/state/workplace/$label"
  rm -rf -- "$clone/BUILD"
  jq '.rows[0].value = ["read-write"]' "$clone/PLAN/view.json" > "$scratch/v" && cp -- "$scratch/v" "$clone/PLAN/view.json"
  jq --arg s "$(sha256sum < "$clone/PLAN/view.json" | cut -d' ' -f1)" '(.outputs[] | select(.path == "view.json") | .sha256) = $s' "$manifest" > "$scratch/m" \
    && cp -- "$scratch/m" "$manifest"
  check "[C29] where the views differ, build refuses" exit_is 1 wp build
  check "[C29] naming both versions and saying to plan again" \
    said "The plan was folded by frame-older-v0, and this loop folds by frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-5.131-5.132-5.141-5.146-5.153-5.162-v18; run plan again"
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
    test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-5.131-5.132-5.141-5.146-5.153-5.162-v18
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
    test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-5.131-5.132-5.141-5.146-5.153-5.162-v18
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
  check "[C10] the binding's bar precedes tmux except on an unenforced floor, and the socket is explicit" \
    jq -e '.programs.tmux.argv as $a
      | {"unless-slot":["unenforced"],"args":[{"slot":["program","setpriv"]},"--no-new-privs"]} as $bar
      | ($a | index($bar)) as $i | ($a | index({"slot":["program","tmux"]})) as $j
      | $i != null and $j != null and $i < $j
        and $a[$j + 1:$j + 3] == ["-S",{"slot":["socket-path"]}]' "$tool/host/binding.json"
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
    reaper) printf '%s\n' "Orchard Reaper" ;;
    ida) printf '%s\n' "Lodge Ida" ;;
    ivo) printf '%s\n' "Lodge Ivo" ;;
    ira) printf '%s\n' "Lodge Ira" ;;
    gleaner) printf '%s\n' "Orchard Gleaner" ;;
  esac
}
state_of() { printf '%s\n' "$HOME/.local/state/workplace/$label"; }
# The number of the shared generation that the build's top names (5.160 point 2).
top_gen() { sed -n 's|^[0-9a-f]\{64\}  shared/\([0-9]*\)/MANIFEST$|\1|p' "$clone/BUILD/MANIFEST"; }
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
# The carrier answers a request first and writes its line of the record after it, so a check that reads that line
# waits here first for a line of the record for the request $2 of the seat $1, whatever its outcome, a torn line
# passed over. It is no check of its own, but where no line comes within a minute it fails the test that waited, in a
# FAIL line that names the seat and the request: a check that asserts an absence would pass on a record that lacks
# the line, so the missing line itself fails the test.
line_recorded() {
  local file seat i
  file=$(state_of)/comms/record seat=$(box_of "$1")
  for (( i = 0; i < 1200; i++ )); do
    jq -R -e --arg s "$seat" --arg r "$2" 'fromjson? | objects | select(.seat == $s and .request == $r)' "$file" > /dev/null 2>&1 && return 0
    sleep 0.05
  done
  fail "the record holds no line for the request $2 of the seat $seat ($1) within a minute"
  return 1
}
mail_of() { find "$(state_of)/mail/$(box_of "$1")/$2" -type f -name '*.md' | LC_ALL=C sort; }
store_commits() { env -i PATH="$PATH" HOME="$scratch" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$(state_of)/mail" rev-list --count HEAD 2> /dev/null || printf '%s\n' 0; }
# The record's lines but the frame's decisions at delivery that type nothing (5.146): requests and pointers typed.
records() {
  local file
  file=$(state_of)/comms/record
  printf '%s\n' "$(( $(grep -c '' "$file") - $(jq -c 'select(.seat == "the frame" and (.outcome == "none" or .outcome == "withheld"))' "$file" | grep -c '') ))"
}
record_lines_reach() {
  local i
  for (( i = 0; i < 300; i++ )); do
    (( $(records) >= $1 )) && return 0
    sleep 0.05
  done
  return 1
}
carrier_pid() { jq -r 'select(.what | startswith("the carrier, pid ")) | .what | ltrimstr("the carrier, pid ")' "$run${1:+/$1}/ledger"; }
# Whether a child of the process $1 is blocked in a flock of the file $2. /proc/locks writes a blocked request as
# "N: -> FLOCK ADVISORY WRITE PID MAJ:MIN:INODE 0 EOF", PID being the flock process. Its device is the superblock's,
# which differs from stat's on btrfs, so the file is matched by its inode, and the waiter by its parent.
blocked_in_flock() {
  local ino pid parent
  local -a f
  [[ -n $1 ]] || return 1
  ino=$(stat -c %i -- "$2") || return 1
  while read -r -a f; do
    [[ ${f[1]-} == '->' && ${f[2]-} == FLOCK && ${f[6]-} == *":$ino" ]] || continue
    pid=${f[5]} parent=""
    { read -r _ parent < <(grep '^PPid:' "/proc/$pid/status"); } 2> /dev/null
    [[ $parent == "$1" ]] && return 0
  done < /proc/locks
  return 1
}

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
    test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-5.131-5.132-5.141-5.146-5.153-5.162-v18
  statements_plan "$comms_terms"
  check "plan with a mail term alone" exit_is 0 wplan
  check "[C54] without floors, with no reach term, every seat mails every seat, and grabs and writes none" \
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
  make_plan '.programs[0].plan |= map(select(.[0] != "server"))'
  check "[C3] 5.136: build refuses a plan with no server and no floor" exit_is 1 wp build
  check "[C3] by the sentence on servers and floors alone" \
    bash -c 'grep -qF "the plan holds 0 server terms and 0 floor terms: a plan holds one server and no floor, or no server, one workplace and at least one floor" "$1" && ! grep -qF "needs exactly one" "$1"' _ "$scratch/out"
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
    'taken|it is one of the carrier'"'"'s own names beside the seats'"'"' boxes, next, next.new, record, serving, serving.new, taken, wake.json, wake.json.new, and its box would stand on the carrier'"'"'s files (5.162 point 5)'
    'next|it is one of the carrier'"'"'s own names beside the seats'"'"' boxes, next, next.new, record, serving, serving.new, taken, wake.json, wake.json.new, and its box would stand on the carrier'"'"'s files (5.162 point 5)'
    'record|it is one of the carrier'"'"'s own names beside the seats'"'"' boxes, next, next.new, record, serving, serving.new, taken, wake.json, wake.json.new, and its box would stand on the carrier'"'"'s files (5.162 point 5)'
    'serving|it is one of the carrier'"'"'s own names beside the seats'"'"' boxes, next, next.new, record, serving, serving.new, taken, wake.json, wake.json.new, and its box would stand on the carrier'"'"'s files (5.162 point 5)'
    'wake.json|it is one of the carrier'"'"'s own names beside the seats'"'"' boxes, next, next.new, record, serving, serving.new, taken, wake.json, wake.json.new, and its box would stand on the carrier'"'"'s files (5.162 point 5)'
    'wake.json.new|it is one of the carrier'"'"'s own names beside the seats'"'"' boxes, next, next.new, record, serving, serving.new, taken, wake.json, wake.json.new, and its box would stand on the carrier'"'"'s files (5.162 point 5)'
    'chain.state|it is one of the frame'"'"'s own names beside the seats'"'"' directories in the records, chain, chain.state, chain.state.new, mark and mark.N, and its directory would stand on the frame'"'"'s files (5.162 point 5)'
    'mark.42|it is one of the frame'"'"'s own names beside the seats'"'"' directories in the records, chain, chain.state, chain.state.new, mark and mark.N, and its directory would stand on the frame'"'"'s files (5.162 point 5)'
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
  # The rule on closed names reads the rows' real paths with readlink (5.177 point 6).
  ln -s -- "$(command -v readlink)" "$bin/readlink"
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
    test "$(jq -r 'select(.seat != "the frame") | "\(.seat):\(.request)"' "$s/comms/record" | tr '\n' ',')" = "Harbor Keeper:a1.md,Harbor Pilot:b1.md,Harbor Keeper:a2.md,Harbor Pilot:b2.md,Harbor Keeper:a3.md,Harbor Pilot:b3.md,"
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
  printf '%s\n' '{"floor":"deck","pid":1,"at":"2026-11-15T00:00:00Z","id":null}' > "$s/store.holder"
  check "[C22] review of 4a: without floors, status reads no S/store.holder, which no carrier without floors writes" \
    bash -c '"$BASH" "$1" status > "$2" 2>&1; ! grep -q "^store " "$2"' _ "$loop" "$scratch/out"
  rm -f -- "$s/store.holder"
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
  printf '%s\n' half > "$s/mail/Harbor Keeper/in/20261112T000000Z-999999.md"
  printf '%s\n' half > "$s/mail/Harbor Keeper/sent/20261112T000000Z-999999.md"
  jq -n -c '{id: "20261112T000000Z-999999", box: "Harbor Keeper", request: "half.md", action: "mail", seat: "Harbor Keeper"}' > "$s/comms/serving"
  check "[C57] up, after a carrier that stopped while it delivered a mail" exit_is 0 wp up
  check "[C57] the mail is answered as delivered to none" \
    answered keeper half.md "refused the carrier stopped while it served this, and it went to none; leave it in out again"
  check "[C57] 5.162 point 1: and what it had written into the store is removed, by the exact paths of the journal's id" \
    bash -c '[[ ! -e $1/in/20261112T000000Z-999999.md && ! -e $1/sent/20261112T000000Z-999999.md ]]' _ "$s/mail/Harbor Keeper"
  check "[C57] 5.162 point 1: while a file that no journal names stays, as another floor's copies would" test -e "$s/mail/Harbor Keeper/in/stray.md"
  rm -f -- "$s/mail/Harbor Keeper/in/stray.md"
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
live_pane() { [[ $(T display-message -p -t "$(pane_by_title "$1")" '#{pane_dead}' 2> /dev/null) == 0 ]]; }
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
  line_recorded pilot m1.md
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
  line_recorded keeper w17.write
  check "[C66] and recorded so, with no length" \
    test "$(jq -c 'select(.request == "w17.write") | [.outcome, has("length")]' "$s/comms/record")" = '["refused",false]'
  T copy-mode -q -t "$pane"
  check "the pane leaves the mode" test "$(T display-message -p -t "$pane" '#{pane_in_mode}')" = 0
  check "[C60] each line is typed into the pane as it stands, then its key; none: no key; Tab" \
    file_comes_to "$root/orchard/almanac/typed" "$(printf '%s\n' "hello world" "#{pane_id} #(touch $root/pwned) \$(touch $root/pwned2) %s%n" \
      "-l -t %0 kill-server" "ends;" ";" 'a\;' $'x\t')"
  request keeper w15.write "seat: Orchard Grower" --- "$(head -c 4096 /dev/zero | tr '\0' y)"
  check "[C60] a text of 4,096 bytes is taken" answered_ok keeper w15.write
  line_recorded keeper w15.write
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
  line_recorded keeper wz.write
  check "[C66] one line for each request, served or refused, a name with a line break included" \
    test "$(records)" = 45
  T set-option -u -t "$(T display -p -t "$(pane_by_title 'Harbor Pilot')" '#{session_id}')" @workplace
  request picker g10.grab "seat: Harbor Pilot"
  check "[C60] a grab of a pane whose session has lost the run's mark is refused" answered picker g10.grab "refused the pane of Harbor Pilot does not carry this run's mark, or is gone"
  line_recorded picker g10.grab
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
  line_recorded pilot l.md
  line_recorded watch t2.write
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
  # The carrier removes the request that it took before it answers. After the answer come the request's line, the
  # removal of the carrier's own copies that still stand, the removal of its journal and, where the serve still holds
  # the store's lock, the release. Where the request could not be read at once, its copy goes with it before the
  # answer. So once the journal is gone nothing of the last request stands in taken, which is what is read here.
  eventually_long test ! -e "$s/comms/serving" || note "    the carrier's journal $s/comms/serving still stands after a minute"
  check "[C62] [C63] the carrier removes the request it took before it answers, and after the answer come the line, the removal of its own copies that still stand, the removal of its journal and the release where the serve still holds the lock: once a request's journal is gone, nothing of it stands in taken" test -z "$(find "$s/comms/taken" -mindepth 1 -print -quit)"
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
    test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-5.131-5.132-5.141-5.146-5.153-5.162-v18
  local planned entry
  planned=$(cat "$clone/PLAN/view.json" "$clone/PLAN/manifest.json" | sha256sum)
  local refusals=(
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "clerk"]; 10)]|programs/COMMS.typify:10: a wake has the words wake KIND PATTERN, not 2'
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "ghost", "x"]; 10)]|programs/COMMS.typify:10: the wake names the kind ghost, which the plan does not make'
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "none", "x"]; 10)]|programs/COMMS.typify:10: the wake names the kind none, which the plan does not make'
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "clerk", ""]; 10)]|programs/COMMS.typify:10: the wake'"'"'s pattern is empty, and an empty pattern finds every screen ready'
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "clerk", "^wait\u0085ing>$"]; 10)]|programs/COMMS.typify:10: the wake'"'"'s pattern holds a control character, which build refuses in a plan, so plan refuses it too (5.162 point 5)'
    "$comms_terms $wake_kinds"' | .programs[-1].recorded += [m(["wake", "clerk", "^wait\u0007ing>$"]; 10)]|programs/COMMS.typify:10: the wake'"'"'s pattern holds a control character, which build refuses in a plan, so plan refuses it too (5.162 point 5)'
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
  check "[C56] without floors mail.json holds no floor, number or own" \
    bash -c 'jq -e "[.seats[] | has(\"floor\") or has(\"number\") or has(\"own\")] | any | not" "$1" > /dev/null' _ "$clone/BUILD/mail.json"
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
  check "[C96] 5.146: without floors too, the writer's own mail gets its none line in the record, with its reason" \
    test "$(jq -c --arg id "$own" 'select(.seat == "the frame" and .covers == [$id]) | [.target, .outcome, .reason]' "$s/comms/record")" = '[["Harbor Keeper"],"none","the writer'"'"'s own mail is pointed out to no one (5.79)"]'
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
  check "[C94] and it went a minute or more after the first" eventually \
    bash -c 'mapfile -t at < <(jq -r "select(.action == \"wake\" and .target == [\"Harbor Keeper\"] and has(\"length\")) | .at" "$1"); (( ${#at[@]} == 2 && $(date -u -d "${at[1]}" +%s) - $(date -u -d "${at[0]}" +%s) >= 60 ))' _ "$s/comms/record"
  check "[C94] a pane that shows a numbered menu still has none, a minute on" test ! -e "$a/typed"
  first=$(jq -c 'select(.action == "wake" and .target == ["Harbor Keeper"] and has("length"))' "$s/comms/record" | head -n 1)
  line=$(pointer 1 "$id1")
  check "[C66] [C96] each pointer is one line of the record: the time, the frame as the one who asked, the reader, the ids it covers, the outcome, and the length and SHA-256 of the line, the paths included" \
    test "$(jq -c '[.seat, .action, .target, .covers, .outcome, .length, .sha256, (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))]' <<< "$first")" = \
    "[\"the frame\",\"wake\",[\"Harbor Keeper\"],[\"$id1\"],\"ok\",${#line},\"$(printf '%s' "$line" | sha256sum | cut -d' ' -f1)\",true]"
  check "[C96] the next covers the three" \
    test "$(jq -c 'select(.action == "wake" and .target == ["Harbor Keeper"] and has("length")) | .covers | length' "$s/comms/record" | tail -n 1)" = 3
  # After a pointer's line the carrier settles wake.json under a hold of its own, so the list is read once it has.
  eventually_long bash -c 'jq -e "(.seats[\"Harbor Keeper\"].count // 0) == 0 and (.seats[\"Harbor Watch\"].count // 0) == 0" "$1" > /dev/null' \
    _ "$s/comms/wake.json" || note "    wake.json still counts keeper or watch after a minute"
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
  jq -r --arg t "$since" 'select(.action == "wake" and .target == ["Harbor Watch"] and has("length") and .at >= $t and .outcome != "ok") | "\(.at) \(.outcome): \(.reason)"' "$s/comms/record" \
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
  line_recorded keeper w2.write
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
  check "[C29] the fold's version is the one that reads records" test "$(jq -r .derivations.fold "$clone/PLAN/manifest.json")" = frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-5.125-5.126-5.129-5.131-5.132-5.141-5.146-5.153-5.162-v18
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

day_written() {
  # The UTC day of the day's file last written in a seat's record directory: a test takes the day from what was
  # written, since a day read from the clock is another one when midnight falls after the bytes were written.
  local last
  last=$(ls -1t -- "$1"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].pane 2> /dev/null | head -n 1)
  [[ -n $last ]] || return 1
  last=${last##*/}
  printf '%s\n' "${last%.pane}"
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
      "wait=" + $root + "/records/Harbor Pilot/@DAY@.pane", "entries=" + $root + "/records", "entries=" + $root + "/records/Harbor Pilot", "tamper=" + $root + "/records/Harbor Pilot/@DAY@.pane",
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
  check "[C70] the day's file that the keeper wrote last is its owner's alone (mode 600)" test "$(stat -c %a "$(record_of keeper)/$(day_written "$(record_of keeper)").pane")" = 600
  local report=$root/harbor/berth/keeper
  check "[C76] at the record path a seat is shown one directory for each seat whose record it may read, under that seat's name, and no other" \
    grep -qxF "entries $root/records: Harbor Pilot " "$report"
  check "[C76] holding that seat's day" bash -c 'grep -qF "entries $1/records/Harbor Pilot: " "$2" && grep "entries $1/records/Harbor Pilot: " "$2" | grep -qF "$3.pane"' _ "$root" "$report" "$(day_written "$(record_of pilot)")"
  check "[C77] a seat neither appends to, cuts short, renames nor removes a record it reads, nor makes a file beside it" \
    grep -qxF "tamper $root/records/Harbor Pilot/$(day_written "$(record_of pilot)").pane: append=refused truncate=refused rename=refused remove=refused make=refused" "$report"
  check "[C78] through the record it may read a seat reaches no third seat's" grep -qxF "list $root/records/Harbor Pilot/../Harbor Watch: refused" "$report"
  check "[C77] [C78] and the records' store, in the state directory, is unseen" grep -qxF "hidden $s/records: unseen" "$report"
  check "[C79] the pane's bytes are kept as the pane's program wrote them: NUL, bytes that are not UTF-8, formats, commands and escapes" \
    eventually_long bash -c '[[ $(cat -- "$1"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].pane | od -An -v -tx1 | tr -d " \n") == *"$(od -An -v -tx1 < "$2" | tr -d " \n")"* ]]' _ "$(record_of keeper)" "$hostile"
  check "[C79] and nothing they name ran" bash -c 'for n in 1 2 3; do test ! -e "$1/pwned$n" || exit 1; done' _ "$root"
  check "[C71] the keeper runs outside every view: in this shell's mount and user namespaces" \
    bash -c 'for p in $(pgrep -f "workplace keep $1"); do [[ $(stat -L -c %i "/proc/$p/ns/mnt") == $(stat -L -c %i /proc/self/ns/mnt) ]] || exit 1; done; [[ -n $(pgrep -f "workplace keep $1") ]]' _ "$(record_of keeper)"
  wp status > "$scratch/out" 2>&1
  check "[C75] status names each kept seat's file and its size against the limit" \
    bash -c 'grep -qE "^record  Harbor Keeper \(harbor/dock/keeper\): $1\.pane, [0-9]+ of 268435456 bytes, chained to byte [0-9]+$" "$2"' _ "$(day_written "$(record_of keeper)")" "$scratch/out"
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
  check "[C82] at the limit nothing more is stored: the day holds 2,000 bytes" eventually_long bash -c 'd=$(ls -1t -- "$1"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].pane | head -n 1); [[ $(stat -c %s "$d") == 2000 ]]' _ "$(record_of watch)"
  local counted='d=$(ls -1t -- "$1"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].pane | head -n 1); d=${d##*/}; [[ $(awk -v d="${d%.pane}" "\$1 == d { n += \$2 } END { print n + 0 }" "$1/unstored" 2> /dev/null) == $2 ]]'
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
    bash -c 'cat -- "$1"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].pane | grep -qa "probe picker done"' _ "$(state_of)/records/Orchard p%s#{pane_id}"
}

t_records_verify() {
  local d day file entries
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
  check "[C75] 5.146: the record it verifies holds the frame's decision lines at delivery, as written" \
    test "$(jq -c 'select(.seat == "the frame" and .action == "wake") | [.target, .outcome, .reason]' "$(state_of)/comms/record" | head -n 1)" = '[["Harbor Keeper"],"none","its kind has no wake pattern, so no pointer is typed for it (C94)"]'
  # A carrier stopped as it wrote a line leaves that line without its newline (5.153).
  local torn
  printf '%s' '{"at":"2026-' >> "$(state_of)/comms/record"
  torn=$(stat -c %s "$(state_of)/comms/record")
  check "up again, the same day" exit_is 0 wp up
  check "keeper ran again" wait_for_probe "Harbor Keeper" keeper
  request pilot note2.md "to: Harbor Keeper" "subject: a second note" --- "body"
  check "a mail is served after the torn line" answered_ok pilot note2.md
  check "down" exit_is 0 wp down
  check "[C57] 5.153: the carrier that starts ends the torn line with one newline before it writes, and every line after it parses by itself" \
    bash -c 'tail -c +$(( $2 + 1 )) "$1" | jq -R -s -e "split(\"\n\") as \$l | (\$l[0]) == \"\" and (\$l | last) == \"\" and (\$l[1:-1] | length >= 2 and all(.[]; (try fromjson catch null) | type == \"object\"))" > /dev/null' _ "$(state_of)/comms/record" "$torn"
  check "[C75] 5.153: record verify --requests reads bytes and not lines: the torn line, its newline and what follows agree with the chain" exit_is 0 wp record verify --requests
  check "[C75] over the record's whole length" said "comms/record agrees with its chain up to byte $(stat -c %s "$(state_of)/comms/record"), its whole length"
  d=$(record_of keeper)
  day=$(day_written "$d")
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
  check "[C75] make the first sink fault while its writer is stopped" inject_chain_sink_fault "$scratch/first-chain"
  [[ -d $(state_of)/records/chain ]] || return 1
  check "down, with the file sink made unwritable" exit_is 0 wp down
  check "[C75] status exits 1 for a sink that did not take an entry" exit_is 1 wp status
  check "[C75] naming the sink and when" bash -c 'grep -qE "^gone    the chain'"'"'s sink, the file, did not take its last entry, at [0-9-]+T[0-9:]+Z, and has taken none since$" "$1"' _ "$scratch/out"
  rmdir -- "$(state_of)/records/chain"
  check "up, with the file sink as it should be" exit_is 0 wp up
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  local stood
  check "[C75] the restored file sink has taken an entry before the next fault is injected" \
    eventually_long test -f "$(state_of)/records/chain"
  [[ -f $(state_of)/records/chain ]] || return 1
  check "[C75] make the second sink fault while its writer is stopped" inject_chain_sink_fault "$scratch/chain"
  [[ -d $(state_of)/records/chain ]] || return 1
  stood=$chain_fault_offset
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
  check "[C57] 5.153: a carrier that starts on a record whose last line is whole adds nothing to it: after three such starts no line of the record is empty" \
    bash -c '! grep -qx "" "$1"' _ "$(state_of)/comms/record"
}

inject_chain_sink_fault() {
  local backup=$1 carrier status=0
  carrier=$(carrier_pid)
  [[ $carrier =~ ^[1-9][0-9]*$ ]] || return 1
  kill -STOP "$carrier" || return 1
  if eventually grep -Eq '^State:[[:space:]]+T' "/proc/$carrier/status"; then
    chain_fault_offset=$(jq -s -r --slurpfile state "$(state_of)/records/chain.state" \
      '([($state[0].files["comms/record"].offset // 0)] + [.[] | select(.file == "comms/record") | .offset + .length]) | max' "$(state_of)/records/chain") \
      && mv -- "$(state_of)/records/chain" "$backup" && mkdir -- "$(state_of)/records/chain" || status=1
  else
    status=1
  fi
  kill -CONT "$carrier" || status=1
  return "$status"
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
  unit=workplace-carrier-$label.service
  check "up with the chain going to the journal" records_up '| (.programs[-1].recorded[] | select(.term[0] == "record-chain") | .term[1]) = "journal"'
  check "[C72] up starts the carrier as a unit of the user's manager" systemctl --user is-active --quiet "$unit"
  check "[C72] the ledger records the unit by its invocation, which down checks before it stops it" \
    test "$(jq -r 'select(.what | startswith("the carrier")) | .is' "$run/ledger")" = "$(systemctl --user show -p InvocationID --value "$unit")"
  check "[C72] the unit runs under no-new-privileges" test "$(systemctl --user show -p NoNewPrivileges --value "$unit")" = yes
  check "[C72] stopping the unit signals the carrier alone" test "$(systemctl --user show -p KillMode --value "$unit")" = mixed
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  local before sent kept='cat -- "$1"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].pane | wc -c'
  sent=$(journalctl --user _SYSTEMD_USER_UNIT="$unit" -o cat --no-pager | grep -cE '"Harbor Keeper/[0-9]{4}-[0-9]{2}-[0-9]{2}\.pane"')
  T send-keys -t "$(pane_by_title "Harbor Keeper")" x
  check "[C72] a key typed into the kept pane is echoed into its record, and a pass of the carrier sends an entry for it" \
    eventually_long bash -c '(( $(journalctl --user _SYSTEMD_USER_UNIT="$1" -o cat --no-pager | grep -cE "\"Harbor Keeper/[0-9]{4}-[0-9]{2}-[0-9]{2}\\.pane\"") > $2 ))' _ "$unit" "$sent"
  before=$(bash -c "$kept" _ "$(record_of keeper)")
  T send-keys -t "$(pane_by_title "Harbor Keeper")" y
  check "[C72] a second key, typed as soon as that entry is seen, is echoed too: the next pass is some ten seconds away, so only the carrier's last entries at down can cover it" \
    eventually bash -c "(( \$($kept) > \$2 ))" _ "$(record_of keeper)" "$before"
  check "down" exit_is 0 wp down
  day=$(day_written "$(record_of keeper)")
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
  rm -f -- "$scratch/liar/told"
  printf '%s\n' "$pane" > "$scratch/liar/lie"
  sleep 3
  : > "$scratch/liar/lie"
  check "the stand-in told its lie: it listed keeper's piped pane to the carrier as having no pipe, and marked each time" \
    grep -qxF -- "$pane" "$scratch/liar/told"
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
  day=$(day_written "$(record_of keeper)")
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
  local started
  started=$(date -u +%F)
  check "up, the keepers' day being 2030-01-01" exit_is 0 env PATH="$fake:$PATH" "$BASH" "$loop" up
  check "keeper ran" wait_for_probe "Harbor Keeper" keeper
  check "down" exit_is 0 env PATH="$fake:$PATH" "$BASH" "$loop" down
  d=$(record_of keeper)
  check "keeper's record holds the day 2030-01-01, and the file sink holds entries for it, all sent on the days the test ran" \
    bash -c 'test -s "$1/2030-01-01.pane" && days=$(jq -r "select(.file == \"Harbor Keeper/2030-01-01.pane\") | .at[0:10]" "$2" | sort -u) && [[ -n $days ]] && ! grep -qvxF -e "$3" -e "$4" <<< "$days"' _ "$d" "$(state_of)/records/chain" "$started" "$(date -u +%F)"
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


t_alias_access_review() {
  local runner=$scratch/alias-review-guard id data base path target expected
  local -a entries
  printf '%s\n' '#!/usr/bin/env bash' 'set -u -o pipefail' 'export LC_ALL=C' \
    'warn() { printf "workplace: %s\n" "$*" >&2; }' 'root=$1' 'mask_file=$6' > "$runner"
  sed -n '/^physical_of() {/,/^held_by_nobody() {/p' "$loop" | sed '$d' >> "$runner"
  printf '%s\n' 'frame_masks() { cat -- "$mask_file"; }' \
    'refuse_alias_access "$2" "$3" "$4" "$5"' 'rc=$?' \
    'printf "%s\n" "${alias_access_report-}"' 'exit "$rc"' >> "$runner"
  while IFS= read -r id; do
    base=$root/alias-review/$id
    mkdir -p -- "$base/tree/vault/open" "$base/mask/sub" "$base/data/vault" "$base/data/sub/vault"
    data=$(jq -c --arg id "$id" --arg base "$base" --arg uid "$EUID" \
      '.[] | select(.id == $id) | walk(if type == "string" then gsub("@R@"; $base) | gsub("@UID@"; $uid) else . end)' "$fixtures/alias-review-cases.json")
    mapfile -d '' -t entries < <(jq --raw-output0 '(.links // [])[] | .[]' <<< "$data")
    local i
    for ((i=0; i<${#entries[@]}; i+=2)); do
      path=$base/${entries[i]} target=${entries[i+1]}
      mkdir -p -- "${path%/*}"
      ln -s -- "$target" "$path"
    done
    jq -nc --argjson c "$data" '
      def at($n): {path:"review-case.typify",line:$n};
      {programs:[{path:"review-case.typify",plan:[["pane","orchard","barn","grower","Orchard Grower"]],recorded:
        ([($c.labels // [])[] | {term:(["label"] + .),origin:at(1)}]
         + [($c.keys // [])[] | {term:(["ssh-key"] + .),origin:at(2)}])}],
       state:{view:[$c.rows | to_entries[] | {key:(["orchard","barn","grower"] + [.value[0]]),
         value:[.value[1]],source:"statement",origins:[at(.key+3)]}]}}' > "$base/plan.json"
    jq -nc --argjson c "$data" --slurpfile p "$base/plan.json" \
      '{rows:$p[0].state.view,seats:[{seat:["orchard","barn","grower"],clearance:{value:($c.clearance // null)}}]}' > "$base/view.json"
    jq --raw-output0 '(.masks // [])[] | .[]' <<< "$data" > "$base/masks"
    expected=$(jq -r '.expected' <<< "$data")
    local status=1
    [[ $expected == refuse ]] || status=0
    check "[C31] $id: $expected by the actual metadata and admission functions" exit_is "$status" \
      bash "$runner" "$base" "$base/view.json" "$base/plan.json" "$tool/host/binding.json" "$tool/libexec" "$base/masks"
    check "[C31] $id: no parser or extraction failure" \
      bash -c '! grep -Eq "jq: error|syntax error|command not found|cannot decide alias access|cannot read alias-access|cannot inspect alias-access" "$1"' _ "$scratch/out"
  done < <(jq -r '.[].id' "$fixtures/alias-review-cases.json")
}

t_alias_access() {
  scoped_clone
  local id casebase data expected path target
  local -a entries
  while IFS= read -r id; do
    data=$(jq -c --arg id "$id" '.[] | select(.id == $id)' "$fixtures/alias-cases.json")
    expected=$(jq -r '.proposed' <<< "$data")
    casebase=$root/alias-cases/$id
    mkdir -p -- "$casebase/tree/vault/open" "$casebase/tree/vault/secret" "$casebase/tree/vaultish" "$casebase/aliases"
    printf '%s\n' synthetic > "$casebase/tree/vault/value"
    mapfile -d '' -t entries < <(jq --raw-output0 '.links[] | .[]' <<< "$data")
    local i
    for (( i=0; i+1<${#entries[@]}; i+=2 )); do
      ln -s -- "${entries[i+1]}" "$casebase/${entries[i]}"
    done
    statements_plan '('"$data"') as $case | '"$(jq -n --arg b "$casebase" '$b')"' as $base
      | .programs[-1].recorded = ([st("-"; "-"; "-"; "workplace"; "/"; "searchable-only"; 1)]
        + [$case.rows | to_entries[] | st("orchard"; "-"; "-"; "office"; (.value[0] | gsub("@R@"; $base)); .value[1]; (.key+2))]
        + [$case.labels[] | lb((.[0] | gsub("@R@"; $base)); .[1]; 50)]
        + (if $case.clearance == null then [] else [cl("orchard"; "-"; "-"; "office"; $case.clearance; 51)] end)
        + (if ($case.labels | length) == 0 and $case.clearance == null then [] else [sc(52)] end))'
    check "$id: lexical plan" exit_is 0 wplan
    if [[ $expected == accept ]]; then
      check "$id: admitted without widening" exit_is 0 wp build
    else
      check "$id: refused before BUILD" exit_is 1 wp build
      check "$id: a policy refusal, not a broken checker" bash -c '! grep -Eq "jq: error|cannot decide alias access|cannot read alias-access|cannot inspect alias-access" "$1"' _ "$scratch/out"
      check "$id: no BUILD published" test ! -e "$clone/BUILD"
    fi
    [[ ! -d $clone/BUILD ]] || rm -rf -- "$clone/BUILD"
  done < <(jq -r '.[].id' "$fixtures/alias-cases.json")
}


t_alias_access_rechecks() {
  scoped_clone
  mkdir -p -- "$root/aliasbox" "$root/private-alias-data"
  ln -s -- ../orchard/almanac "$root/aliasbox/link"
  statements_plan '.programs[-1].recorded += [sc(30), lb($root + "/private-alias-data"; "0"; 31),
    st("orchard"; "barn"; "grower"; "seat"; $root + "/aliasbox"; "scratch"; 32),
    st("orchard"; "barn"; "grower"; "seat"; $root + "/aliasbox/link"; "read-only"; 33)]'
  check "alias rechecks: plan" exit_is 0 wplan
  check "alias rechecks: build an admitted alias" exit_is 0 wp build
  ln -sfn -- ../private-alias-data "$root/aliasbox/link"
  check "alias rechecks: up refuses a numbered target swapped after build" exit_is 1 wp up
  check "alias rechecks: up made no run directory" test ! -d "$run"
  check "alias rechecks: up started no server" no_server
  ln -sfn -- ../orchard/almanac "$root/aliasbox/link"
  check "alias rechecks: up with the admitted target" exit_is 0 wp up
  check "alias rechecks: grower started" wait_for_probe "Orchard Grower" grower
  local before
  before=$(T list-panes -a -F '#{pane_id}:#{pane_pid}')
  ln -sfn -- ../private-alias-data "$root/aliasbox/link"
  check "alias rechecks: restart refuses before replacing a pane" exit_is 1 wp restart "Orchard Grower"
  check "alias rechecks: existing pane processes unchanged" test "$(T list-panes -a -F '#{pane_id}:#{pane_pid}')" = "$before"
  check "alias rechecks: exec refuses the affected seat" exit_is 2 wp exec --print "Orchard Grower"
  check "alias rechecks: exec of an unaffected seat remains available" exit_is 0 wp exec --print "Harbor Keeper"
  ln -sfn -- ../orchard/almanac "$root/aliasbox/link"
  local runtime=/run/user/$EUID
  jq --arg p "$runtime/house-alias-test-missing" '.rows += [{key: ["orchard", "barn", "grower", $p],
    value: ["read-only"], source: "statement", origins: [{path: "hand-edited-view", line: 1}]}]' \
    "$clone/BUILD/plan-view.json" > "$scratch/changed-view"
  mv -- "$scratch/changed-view" "$clone/BUILD/plan-view.json"
  restamp plan-view.json
  check "runtime rechecks: exec rejects a hand-added runtime row" exit_is 2 wp exec --print "Orchard Grower"
  check "runtime rechecks: the runtime restriction is named" said "the user's runtime directory"
  check "runtime rechecks: exec retains its selected-seat scope" exit_is 0 wp exec --print "Harbor Keeper"
  check "runtime rechecks: restart rejects the runtime row" exit_is 1 wp restart "Orchard Grower"
  check "runtime rechecks: no pane replaced" test "$(T list-panes -a -F '#{pane_id}:#{pane_pid}')" = "$before"
  check "runtime rechecks: down" exit_is 0 wp down
  check "runtime rechecks: up rejects the runtime row" exit_is 1 wp up
  check "runtime rechecks: no run directory remains" test ! -d "$run"
}

t_alias_access_file_cover() {
  scoped_clone
  mkdir -p -- "$root/aliasbox" "$root/file-data"
  printf '%s\n' original > "$root/file-data/locked"
  ln -s -- ../file-data "$root/aliasbox/link"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "probe grower start"' \
    'if IFS= read -r value < "$1/locked"; then echo "locked read=$value"; else echo "locked read=refused"; fi' \
    'if { echo changed > "$1/locked"; } 2>/dev/null; then echo "locked write=ok"; else echo "locked write=refused"; fi' \
    'if echo writable > "$1/open"; then echo "parent write=ok"; fi' \
    'read -r -t 300 _ || :' > "$root/tools/alias-file-probe"
  chmod +x -- "$root/tools/alias-file-probe"
  statements_plan '.programs[-1].recorded += [
    st("orchard"; "barn"; "grower"; "seat"; $root + "/file-data"; "read-write"; 30),
    st("orchard"; "barn"; "grower"; "seat"; $root + "/file-data/locked"; "read-only"; 31),
    st("orchard"; "barn"; "grower"; "seat"; $root + "/aliasbox"; "scratch"; 32),
    st("orchard"; "barn"; "grower"; "seat"; $root + "/aliasbox/link"; "read-write"; 33),
    st("orchard"; "barn"; "grower"; "seat"; $root + "/aliasbox/link/locked"; "read-only"; 34)]
    | (.programs[] | select(.path == "orchard/barn/grower/seat.typify") | .plan[1].term[5]) =
      ([$root + "/tools/alias-file-probe", $root + "/aliasbox/link"] | tojson)'
  check "file cover: plan" exit_is 0 wplan
  check "file cover: build" exit_is 0 wp build
  check "file cover: up" exit_is 0 wp up
  check "file cover: the file remains readable" eventually screen_has "Orchard Grower" "locked read=original"
  check "file cover: the file cannot be written through the parent alias" screen_has "Orchard Grower" "locked write=refused"
  check "file cover: the parent remains writable" screen_has "Orchard Grower" "parent write=ok"
  check "file cover: original host bytes retained" test "$(cat "$root/file-data/locked")" = original
  check "file cover: host received the permitted write" test "$(cat "$root/file-data/open")" = writable
  check "file cover: down" exit_is 0 wp down
}


t_alias_access_mask_failure() {
  scoped_clone
  statements_plan
  check "mask failure: plan" exit_is 0 wplan
  mkdir -- "$scratch/mask-fault-frame"
  cp -R -- "$tool/bin" "$tool/libexec" "$tool/host" "$tool/share" "$scratch/mask-fault-frame/"
  local modified
  modified=$(< "$scratch/mask-fault-frame/bin/workplace")
  printf '%s\n' "${modified/'frame_masks() {'/$'frame_masks() {\n  return 42'}" > "$scratch/mask-fault-frame/bin/workplace"
  local loop=$scratch/mask-fault-frame/bin/workplace
  check "mask failure: a failed mask provider refuses build" exit_is 1 wp build
  check "mask failure: the failed inspection is named" said "cannot read alias-access masks"
  check "mask failure: no BUILD published" test ! -d "$clone/BUILD"
}

t_alias_access_key_sources() {
  scoped_clone
  mkdir -p -- "$root/key-fixture/real"
  printf '%s\n' 'synthetic non-key data' > "$root/key-fixture/real/account"
  ln -s -- real "$root/key-fixture/declared"
  statements_plan '.programs[-1].recorded = [st("-"; "-"; "-"; "workplace"; "/"; "searchable-only"; 1),
    st("orchard"; "-"; "-"; "office"; $root + "/key-fixture/real"; "read-only"; 2),
    {term: ["ssh-key", "synthetic", ($root + "/key-fixture/declared/account")], origin: at(3)}]'
  check "key source: name-only declaration plan" exit_is 0 wplan
  check "key source: a declaration through a parent link refuses" exit_is 1 wp build
  check "key source: the physical source is named" said "$root/key-fixture/real/account"
  check "key source: no BUILD published" test ! -d "$clone/BUILD"
  statements_plan '.programs[-1].recorded = [st("-"; "-"; "-"; "workplace"; "/"; "searchable-only"; 1),
    {term: ["ssh-key", "synthetic", ($root + "/key-fixture/real/account")], origin: at(2)}]'
  check "key source: canonical ungranted declaration plan" exit_is 0 wplan
  check "key source: an ungranted canonical source needs no key parsing" exit_is 0 wp build
}

tests=(
  t_alias_access_review
  t_floor_blocking_config
  t_unit_invocation_ownership
  t_floor_admin_mail
  t_floor_config_refusals
  t_floor_default_refusals
  t_floor_runtime
  t_floor_scoped_readback
  t_floor_refresh_scoped
  t_floor_alias_reuse
  t_floor_restart_mail_links
  t_floor_call_deadlines
  t_floor_server_privilege_recheck
  t_floor_command_exclusion
  t_actual_default_mask_build
  t_alias_access_mask_failure
  t_alias_access_key_sources
  t_alias_access_rechecks
  t_alias_access_file_cover
  t_alias_access
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
  t_closed_names
  t_closed_names_unfolded
  t_plan_relative
  t_floors
  t_reach_floors
  t_pointer_floors
  t_floors_up
  t_store_lock
  t_wake_floors
  t_carrier_floors
  t_floors_readers
  t_floors_unenforced
  t_floors_assembly
  t_the_folded_view_in_the_panes
  t_closed_names_up
  t_closed_names_on_a_build_changed_by_hand
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
    setup "${name#t_}" || exit 1
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
