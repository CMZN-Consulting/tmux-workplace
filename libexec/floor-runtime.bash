floor_spec() {
  jq -ce --arg f "$run_floor" '[.programs[].plan[]? | (if type == "object" then .term else . end)
    | select(type == "array" and .[0] == "floor" and .[1] == $f)][0] // empty' "$b_plan"
}

floor_capture() {
  local capture capture_fd result=0
  capture=$(mktemp "${TMPDIR:-/tmp}/workplace-tmux.XXXXXXXX") || return 1
  exec {capture_fd}<> "$capture" || { rm -f -- "$capture"; return 1; }
  if ! rm -f -- "$capture"; then exec {capture_fd}>&-; return 1; fi
  "$@" >&"$capture_fd" || result=$?
  cat -- "/proc/self/fd/$capture_fd" || result=1
  exec {capture_fd}>&- || result=1
  return "$result"
}

floor_client() {
  local -a prefix=()
  [[ ${floor_unenforced-0} == 1 ]] || prefix=("$(command -v setpriv)" --no-new-privs)
  floor_capture timeout --foreground --kill-after=1 "${floor_call_timeout:-10}" "${prefix[@]}" "$(command -v tmux)" -N -S "$floor_socket" -u "$@" 5>&- 6>&-
}

floor_prepare() {
  [[ -n $run_floor ]] || return 0
  command -v timeout > /dev/null && command -v mktemp > /dev/null && command -v cat > /dev/null \
    || { warn "a floor needs timeout, mktemp and cat for bounded tmux calls"; return 1; }
  floor_term=$(floor_spec) || { warn "cannot read the floor $run_floor"; return 1; }
  floor_unenforced=0 floor_existing=0
  [[ $(jq -r '.[4]' <<< "$floor_term") == unenforced ]] && floor_unenforced=1
  floor_socket_kind=$(jq -r '.[5]' <<< "$floor_term")
  floor_socket=$run_dir/$(jq -r '.name // "default"' <<< "$report")
  floor_set=$build_dir/share/floor-set-enforced.conf
  (( floor_unenforced )) && floor_set=$build_dir/share/floor-set-unenforced.conf
  if (( floor_unenforced )); then
    local privileges
    privileges=$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/$$/status)
    [[ $privileges == 0 ]] || { warn "the floor $run_floor is unenforced, but this caller carries no-new-privileges and cannot remove it; start it from a plain terminal"; return 1; }
  fi
  if [[ $floor_socket_kind == tmux-default ]]; then
    floor_socket=$(physical_spelling "${TMUX_TMPDIR:-/tmp}/tmux-$EUID")/default
    local found rc=0 pid mark nnp config_hash
    found=$(floor_capture timeout --foreground --kill-after=1 2 "$(command -v tmux)" -N -S "$floor_socket" -u \
      display-message -p '#{pid} #{@workplace-clone}' 2>/dev/null 6>&-) || rc=$?
    if (( rc == 0 )); then
      pid=${found%% *} mark=${found#* }
      [[ $pid =~ ^[1-9][0-9]*$ && $mark == "$clone" ]] || {
        warn "up refuses the floor $run_floor: the server at $floor_socket does not carry this clone's mark; leave it unchanged, or end it yourself with: tmux -S $(sh_quote "$floor_socket") kill-server"
        return 1
      }
      nnp=$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)
      [[ $nnp == 0 ]] || { warn "up refuses the floor $run_floor: the server at $floor_socket carries no-new-privileges or its status cannot be read"; return 1; }
      config_hash=$(floor_client show-options -gqv @workplace-conf 2>/dev/null) || return 1
      [[ $config_hash == "$(sha_of "$f_gen/floor.conf")" ]] || {
        warn "up refuses the floor $run_floor: the server at $floor_socket has not loaded this sealed floor configuration; leave it unchanged, or end it yourself before up"
        return 1
      }
      floor_existing=1
      floor_readback 1 || return 1
    elif (( rc == 124 || rc == 137 )); then
      warn "up refuses the floor $run_floor: the default socket $floor_socket did not answer within two seconds"
      return 1
    elif [[ -e $floor_socket && ! -S $floor_socket ]]; then
      warn "up refuses the floor $run_floor: $floor_socket is not a socket"
      return 1
    fi
  fi
  (( ${#floor_socket} <= 107 )) || { warn "the floor $run_floor's socket path exceeds 107 bytes"; return 1; }
}

floor_state_slots() {
  [[ -n $run_floor ]] || return 0
  local inherited='[]' name value timeout_program
  local -a names
  mapfile -t names < <(jq -r '.inherit[]' "$build_dir/binding.json")
  for name in "${names[@]}"; do
    [[ -n ${!name+x} ]] || continue
    value=${!name}
    inherited=$(jq -c --arg n "$name" --arg v "$value" '. + [[$n,$v]]' <<< "$inherited") || return 1
  done
  timeout_program=$(command -v timeout) || return 1
  state=$(jq -c --arg f "$run_floor" --arg set "$floor_set" --arg tmp "${TMUX_TMPDIR:-/tmp}" \
    --arg timeout "$timeout_program" --argjson env "$inherited" --argjson plain "$floor_unenforced" --argjson existing "$floor_existing" '
    .callerEnvironment = $env
    | .slots[(["frame-set"] | tojson)] = $set
    | .slots[(["tmux-tmpdir"] | tojson)] = $tmp
    | .slots[(["floor-timeout"] | tojson)] = "10"
    | .slots[(["program","timeout"] | tojson)] = $timeout
    | .slots[(["unenforced"] | tojson)] = (if $plain == 1 then "1" else "" end)
    | .slots[(["enforced-floor"] | tojson)] = (if $plain == 0 then "1" else "" end)
    | .slots[(["floor-bootstrap"] | tojson)] = (if $existing == 0 then "1" else "" end)
    | .slots[(["floor-key"] | tojson)] = $f' <<< "$state")
  state=$(jq -c --arg v "$([[ $floor_socket_kind == tmux-default ]] && printf 1)" \
    '.slots[(["floor-default"] | tojson)] = $v' <<< "$state")
}

floor_scope_readback() {
  local kind=$1 hooks options
  shift
  hooks=$(floor_client show-hooks "$@" 2>/dev/null) || { warn "cannot read the floor $run_floor's $kind hooks"; return 1; }
  [[ -z $(printf '%s\n' "$hooks" | sed -n '/^[^[:space:]]*[[:space:]]/p') ]] \
    || { warn "the floor $run_floor declares $kind hooks, which the frame refuses"; return 1; }
  if (( floor_hook_monitors )); then
    hooks=$(floor_client show-hooks -B "$@" 2>/dev/null) || { warn "cannot read the floor $run_floor's $kind monitor hooks"; return 1; }
    [[ -z $hooks ]] || { warn "the floor $run_floor declares $kind monitor hooks, which the frame refuses"; return 1; }
  fi
  if (( ! floor_unenforced )); then
    options=$(floor_client show-options -H "$@" 2>/dev/null) || return 1
    [[ $options != *'#('* ]] || { warn "the enforced floor $run_floor has a shell expansion in an option"; return 1; }
  fi
}

floor_readback() {
  local existing=${1:-0} key value options sessions pane target targets commands
  local failed=0
  local floor_hook_monitors=0
  commands=$(floor_client list-commands 2>/dev/null) || return 1
  [[ $(printf '%s\n' "$commands" | sed -n '/^show-hooks /p') != *B* ]] || floor_hook_monitors=1
  for key in exit-unattached destroy-unattached; do
    if [[ $key == exit-unattached ]]; then value=$(floor_client show-options -sv "$key" 2>/dev/null)
    else value=$(floor_client show-options -gv "$key" 2>/dev/null); fi
    [[ $value == off ]] || { warn "the floor $run_floor's $key is not off"; failed=1; }
  done
  value=$(floor_client show-options -gv history-limit 2>/dev/null)
  [[ $value =~ ^[0-9]+$ && $value -ge 5000 ]] || { warn "the floor $run_floor's history-limit is below 5000 or unreadable"; failed=1; }
  value=$(floor_client show-options -gwv synchronize-panes 2>/dev/null)
  [[ $value == off ]] || { warn "the floor $run_floor's global synchronized input is not off"; failed=1; }
  floor_scope_readback session -g || return 1
  floor_scope_readback window -gw || return 1
  if (( ! floor_unenforced )); then
    value=$(floor_client show-options -sv set-clipboard 2>/dev/null)
    [[ $value == external ]] || { warn "the floor $run_floor's set-clipboard is not external"; failed=1; }
    options=$(floor_client show-options -sH 2>/dev/null) || return 1
    [[ $options != *'#('* ]] || { warn "the enforced floor $run_floor has a shell expansion in an option"; failed=1; }
    for key in alternate-screen allow-passthrough; do
      value=$(floor_client show-options -gwv "$key" 2>/dev/null)
      [[ $key == alternate-screen && $value == on || $key == allow-passthrough && $value == off ]] \
        || { warn "the enforced floor $run_floor's global $key differs from the frame"; failed=1; }
    done
  fi
  if (( ! existing )); then
    sessions=$(floor_client display-message -p '#{server_sessions}' 2>/dev/null)
    [[ $sessions == 0 ]] || { warn "the floor $run_floor's file made sessions before the frame"; failed=1; }
  fi
  if (( existing )); then
    value=$(floor_client show-options -sv exit-empty 2>/dev/null)
    [[ $value == on ]] || { warn "the floor $run_floor's exit-empty is not on"; failed=1; }
    value=$(floor_client show-options -s command-alias 2>/dev/null) || return 1
    key=$(floor_client show-options -gqv @workplace-aliases 2>/dev/null) || return 1
    [[ -n $key && $key == "$(sha_of <(printf '%s\n' "$value"))" ]] \
      || { warn "the floor $run_floor's command aliases differ from the recorded frame baseline"; failed=1; }
    if [[ -n ${floor_aliases-} ]]; then
      value=$(floor_client show-options -s command-alias 2>/dev/null)
      [[ $value == "$floor_aliases" ]] || { warn "the floor $run_floor's command aliases differ from the frame"; failed=1; }
    fi
    targets=$(floor_client list-sessions -F '#{session_id}' 2>/dev/null) || return 1
    while IFS= read -r target; do
      [[ -n $target ]] || continue
      floor_scope_readback 'local session' -t "$target" || return 1
    done <<< "$targets"
    targets=$(floor_client list-windows -a -F '#{window_id}' 2>/dev/null) || return 1
    while IFS= read -r target; do
      [[ -n $target ]] || continue
      floor_scope_readback 'local window' -w -t "$target" || return 1
    done <<< "$targets"
    if [[ -f $run_dir/state.json ]]; then
      targets=$(jq -r '.slots | to_entries[] | select((.key | fromjson)[0] == "session") | .value' "$run_dir/state.json") || return 1
      while IFS= read -r target; do
        [[ -n $target ]] || continue
        value=$(floor_client show-options -Av -t "$target" destroy-unattached 2>/dev/null)
        [[ $value == off ]] || { warn "the floor $run_floor's session $target has destroy-unattached enabled or unreadable"; failed=1; }
      done <<< "$targets"
    fi
    local rows line
    rows=$(floor_client list-panes -a -F '#{pane_id} #{history_limit} #{synchronize-panes}' 2>/dev/null) || return 1
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      read -r pane value key <<< "$line"
      floor_scope_readback 'local pane' -p -t "$pane" || return 1
      [[ $value =~ ^[0-9]+$ && $value -ge 5000 && $key == 0 ]] || {
        warn "the floor $run_floor's pane $pane has insufficient history or synchronized input"; failed=1;
      }
      if (( ! floor_unenforced )); then
        for key in alternate-screen allow-passthrough; do
          value=$(floor_client show-options -pAv -t "$pane" "$key" 2>/dev/null)
          [[ $key == alternate-screen && $value == on || $key == allow-passthrough && $value == off ]] \
            || { warn "the enforced floor $run_floor's pane $pane has $key differing from the frame"; failed=1; }
        done
      fi
    done <<< "$rows"
  fi
  (( failed == 0 ))
}

floor_after_term() {
  [[ -n $run_floor ]] || return 0
  local primitive=$1
  if [[ $primitive == server ]]; then
    floor_client source-file -n "$f_gen/floor.conf" > "$run_dir/config-check" 2>&1 \
      || { warn "the floor $run_floor's configuration does not parse: $(jq_message "$run_dir/config-check")"; return 1; }
    floor_readback "$floor_existing" || return 1
    local scope options option
    for scope in -s -g -gw; do
      options=$(floor_client show-options "$scope" 2>/dev/null) || return 1
      while IFS=' ' read -r option _; do
        [[ $option == @workplace* ]] || continue
        floor_client set-option "$scope" -u "$option" > /dev/null 2>&1 || return 1
      done <<< "$options"
    done
    floor_client set-option -g @workplace-clone "$clone" \; set-option -g @workplace-floor "$run_floor" \
      \; set-option -g @workplace-conf "$(sha_of "$f_gen/floor.conf")" > /dev/null || return 1
    floor_aliases=$(floor_client show-options -s command-alias 2>/dev/null) || return 1
    floor_client set-option -g @workplace-aliases "$(sha_of <(printf '%s\n' "$floor_aliases"))" > /dev/null || return 1
    state=$(jq -c --arg aliases "$floor_aliases" '.floorAliases = $aliases' <<< "$state") || return 1
  fi
}

floor_client_mail_dirs() {
  local mode=$1 destination=$2 private_out=$3 claim_dir=$4 dir
  if [[ $(realpath -e -- "$destination") != "$destination" ]]; then
    warn "the client mailbox $destination must be its physical path"
    return 1
  fi
  for dir in "$destination/client-in" "$destination/client-out" "$destination/client-answers" "${private_out%/*}/client-receipts"; do
    if [[ $mode == make && ! -e $dir && ! -L $dir ]]; then
      mkdir -m 0700 -- "$dir" || return 1
    fi
    if [[ ! -d $dir || -L $dir || $(stat -c '%u:%a:%d' -- "$dir") != "$EUID:700:$(stat -c %d -- "$private_out")" ]]; then
      warn "$dir must be this user's real directory, mode 700, on the carrier's file system"
      return 1
    fi
  done
  if [[ $mode == make ]]; then
    local probe sample
    probe=$(mktemp -d -- "$claim_dir/.mail-probe.XXXXXXXX") || return 1
    sample=$(mktemp -- "$destination/client-out/.mail-probe.XXXXXXXX") || { rmdir -- "$probe"; return 1; }
    if ! mv --no-copy -T -- "$sample" "$probe/letter" || ! mv --no-copy -T -- "$probe/letter" "$destination/client-answers/${sample##*/}"; then
      rm -f -- "$sample" "$probe/letter"
      rmdir -- "$probe"
      warn "client mail requires an atomic rename between its queues and the carrier"
      return 1
    fi
    rm -f -- "$destination/client-answers/${sample##*/}" && rmdir -- "$probe" || return 1
  fi
}

floor_links() {
  [[ -n $run_floor && $(jq -r '.slots[(["unenforced"] | tojson)] // ""' <<< "$state") == 1 ]] || return 0
  local mode=${1:-check} file=$b_mail entry destination link target base
  if [[ -f $file ]]; then
    base=$(jq -r '.path' "$file")
    while IFS= read -r entry; do
      destination=$base/$(jq -r '.name' <<< "$entry")
      if [[ $mode == make && ! -e $destination && ! -L $destination ]]; then mkdir -m 0700 -- "$destination" || return 1; fi
      [[ -d $destination && ! -L $destination && $(stat -c %u -- "$destination") == "$EUID" ]] \
        || { warn "the unenforced floor's mailbox $destination is not this user's directory"; return 1; }
      if jq -e '.clientEndpoint == true' <<< "$entry" > /dev/null; then
        floor_client_mail_dirs "$mode" "$destination" "$(jq -r .out <<< "$entry")" "$(jq -r .state "$file")/floors/$run_floor/comms/taken" || return 1
      fi
      for link in in sent out answers; do
        target=$(jq -r --arg k "$link" '.[$k]' <<< "$entry")
        if [[ -e $destination/$link || -L $destination/$link ]]; then
          [[ -L $destination/$link && $(readlink -- "$destination/$link") == "$target" ]] \
            || { warn "the mailbox entry $destination/$link already names another object"; return 1; }
        elif [[ $mode == make ]]; then ln -s -- "$target" "$destination/$link" || return 1
        else warn "the mailbox entry $destination/$link is missing; build again"; return 1; fi
      done
      target=$build_dir/seat-page.md
      if [[ -e $destination/README.md || -L $destination/README.md ]]; then
        [[ -L $destination/README.md && $(readlink -- "$destination/README.md") == "$target" ]] || return 1
      elif [[ $mode == make ]]; then ln -s -- "$target" "$destination/README.md" || return 1
      else warn "the mailbox page $destination/README.md is missing; build again"; return 1; fi
    done < <(jq -c --arg f "$run_floor" '.seats[] | select(.floor == $f)' "$file")
  fi
  return 0
}

floor_resume_context() {
  [[ -n $run_floor ]] || return 0
  [[ -f $run_dir/state.json ]] || return 1
  local slots=$run_dir/state.json
  floor_transport=0
  if ! jq -e '.slots | has(["frame-set"] | tojson)' "$slots" >/dev/null; then
    jq -e '.slots | keys | all((fromjson)[0] != "pane")' "$slots" >/dev/null \
      || { warn "a floor with panes must record its frame settings"; return 1; }
    return 0
  fi
  floor_transport=1
  floor_unenforced=0
  [[ $(jq -r '.slots[(["unenforced"] | tojson)] // ""' "$slots") == 1 ]] && floor_unenforced=1
  floor_socket=$(jq -er '.slots[(["socket-path"] | tojson)] | strings' "$slots") || return 1
  floor_set=$(jq -er '.slots[(["frame-set"] | tojson)] | strings' "$slots") || return 1
  floor_aliases=$(jq -r '.floorAliases // ""' "$slots") || return 1
}

floor_record_links() {
  local path=$1 entry=$2 binds=$3 mode=${4:-check} destination target link pair
  destination=$path/$(jq -r '.name' <<< "$entry")
  if [[ $mode == make && ! -e $destination && ! -L $destination ]]; then mkdir -m 0700 -- "$destination" || return 1; fi
  [[ -d $destination && ! -L $destination && $(stat -c %u -- "$destination") == "$EUID" ]] \
    || { warn "the record view $destination is not this user's directory"; return 1; }
  while IFS= read -r pair; do
    target=$(jq -r '.[0]' <<< "$pair")
    link=$destination/$(jq -r '.[1] | split("/") | last' <<< "$pair")
    if [[ -e $link || -L $link ]]; then
      [[ -L $link && $(readlink -- "$link") == "$target" ]] \
        || { warn "the record entry $link already names another object"; return 1; }
    elif [[ $mode == make ]]; then ln -s -- "$target" "$link" || return 1
    else warn "the record entry $link is missing; build again"; return 1; fi
  done < <(jq -c '.[]' <<< "$binds")
}

floor_refresh() {
  [[ -n $run_floor && ${floor_transport-0} == 1 ]] || return 0
  local prior problems refreshed scope target value mark
  mark=$(floor_client display-message -p '#{@workplace-clone}' 2>/dev/null) || return 1
  [[ $mark == "$clone" ]] || { warn "the floor $run_floor's server no longer carries this clone's mark"; return 1; }
  prior=$(floor_readback 1 2>&1) && return 0
  if [[ $prior == *'hooks, which the frame refuses'* || $prior == *'shell expansion in an option'* ]]; then
    warn "$prior"
    return 1
  fi
  floor_client source-file "$floor_set" \; set-option -s exit-empty on > /dev/null 2>&1 || return 1
  while IFS= read -r target; do
    [[ -n $target ]] || continue
    floor_client set-option -t "$target" destroy-unattached off > /dev/null 2>&1 || return 1
  done < <(jq -r '.slots | to_entries[] | select((.key | fromjson)[0] == "session") | .value' "$run_dir/state.json")
  while IFS= read -r target; do
    [[ -n $target ]] || continue
    floor_client set-option -w -t "$target" synchronize-panes off > /dev/null 2>&1 || return 1
  done < <(jq -r '.slots | to_entries[] | select((.key | fromjson)[0] == "window") | .value' "$run_dir/state.json")
  if (( ! floor_unenforced )); then
    while IFS= read -r target; do
      [[ -n $target ]] || continue
      floor_client set-option -p -t "$target" alternate-screen on \; set-option -p -t "$target" allow-passthrough off > /dev/null 2>&1 || return 1
    done < <(jq -r '.slots | to_entries[] | select((.key | fromjson)[0] == "pane") | .value' "$run_dir/state.json")
  fi
  floor_readback 1 || return 1
  if [[ -n ${comms_record-} ]]; then
    refreshed=$(jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg f "$run_floor" \
      '{at:$at,seat:"the frame",action:"frame-set",floor:$f,outcome:"restored",reason:"transport settings differed from the frame"}')
    carrier_append "$refreshed"
  fi
}

floor_record_fault() {
  [[ -n ${comms_record-} ]] || return 0
  [[ ${floor_fault_recorded-0} == 0 ]] || return 0
  local event
  event=$(jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg f "$run_floor" \
    '{at:$at,seat:"the frame",action:"frame-set",floor:$f,outcome:"refused",reason:"terminal transport settings could not be admitted; mail delivery continues"}') || return 1
  carrier_append "$event"
  floor_fault_recorded=1
}
