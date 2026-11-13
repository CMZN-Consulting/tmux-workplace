include "table";

def term_of: if type == "object" and .unchecked == true then .term else . end;
def canonical: type == "string" and (. == "/" or (startswith("/") and (endswith("/") | not) and (.[1:] | split("/") | all(. != "" and . != "." and . != ".."))));
def beneath($p; $q): ($q == "/" and $p != "/") or ($p | startswith($q + "/"));
def at_or_beneath($p; $q): $p == $q or beneath($p; $q);
def depth: if . == "/" then 0 else (split("/") | length) - 1 end;
def whole: type == "string" and test("^(0|[1-9][0-9]*)$");
def rank: {"workplace": 0, "floor": 1, "kind": 2, "office": 3, "room": 4, "seat": 5}[.];
def states: ["hidden", "searchable-only", "scratch", "read-only", "read-write"];
def at($o): "\($o.path // "?"):\($o.line // "?")";
def ats($os): [$os[] | at(.)] | join(", ");
def places($scope; $n):
  ($n | map(. != "-")) as $used
  | {"workplace": [false, false, false], "floor": [true, false, false], "kind": [true, false, false], "office": [true, false, false],
     "room": [true, true, false], "seat": [true, true, true]}[$scope] == $used;
def scope_text($t; $scope; $n):
  if $scope == "workplace" then "the workplace"
  elif $scope == "kind" then "the kind \($n[0])"
  else "the \($scope) \([$n[] | select(. != "-")] | join("/"))" end;
def entities($rs):
  reduce $rs[] as $r ([]; (map(.term) | index([$r.term])) as $i
    | if $i == null then . + [{term: $r.term, origins: [$r.origin]}] else .[$i].origins += [$r.origin] end);
def statement_object: {term, origins};
def variable_name: test("^[A-Za-z_][A-Za-z0-9_]*$");
def inner_path: . == "." or ((startswith("/") | not) and (split("/") | all(. != "" and . != "." and . != "..")));

joined($b[0]; $root) as $plan
| ($b[0]["kept-names"] // []) as $kept
| ($b[0].inherit // []) as $inherited
| [$plan.programs[] | (.plan // [])[] | term_of | select(type == "array" and .[0] == "pane")] as $panes
| [$panes[] | .[1:4]] as $seats
| ($seats | map(.[0:1]) | unique) as $offices
| ($seats | map(.[0:2]) | unique) as $rooms
| [$plan.programs[] | .path as $pp | (.plan // []) | to_entries[] | (.value | term_of) as $t | select($t | type == "array" and .[0] == "floor")
   | {key: $t[1], name: $t[2], houses: $t[3], enforced: ($t[4] == "enforced"), socket: $t[5], conf: $t[6], smallest: $t[7], origins: [{path: $pp, term: (.key + 1)}]}] as $floors
| [$floors[].key] as $floor_keys
| [$floors[] | select(.houses == "rooms") | .key] as $room_floor_keys
| ([$plan.programs[] | (.plan // [])[] | term_of | select(type == "array" and .[0] == "house") | {key: .[2], value: .[1]}] | from_entries) as $housed
| [$plan.programs[] | (.plan // [])[] | term_of | select(type == "array" and .[0] == "window") | .[1:3]] as $window_rooms
| ($floors | length > 0) as $floored
| def floor_of($a): if ($room_floor_keys | index($a)) != null then $a else $housed[$a] end;
  def mode_of($k): if $floored | not then "legacy"
    else floor_of($k[0]) as $f | ([$floors[] | select(.key == $f)][0]) as $fl
      | if $fl == null then "legacy" elif $fl.enforced then "enforced" else "unenforced" end end;
  def occupants($k): [$seats[] | select(.[0:2] == $k[0:2])];
  def scoped_fault($t; $scope; $n):
    if $scope == "office" and ($floor_keys | index($n[0])) != null then "the \($t[0]) names the office \($n[0]), and \($n[0]) is a floor (5.125 point 1)"
    elif $scope == "floor" and ($floor_keys | index($n[0])) == null and (($offices | index([$n[0]])) != null or ($housed | has($n[0])))
    then "the \($t[0]) names the floor \($n[0]), and \($n[0]) is an office (5.125 point 1)"
    else null end;
  [($plan.state["seat-kinds"] // [])[] | {key: (.key | tojson), value: .value[0]}] | from_entries as $kinds
| ([$kinds[]] + [($plan.state.kinds // [])[] | .key[0]?] | map(select(type == "string" and . != "none")) | unique) as $made_kinds
| [$plan.programs[] | .recorded[]? | select((.term | type) == "array" and (.term[0] | IN("statement", "clearance", "clearance-scale", "label", "key", "home", "home-variable", "home-seed", "expect", "mail", "reach", "record", "record-limit", "record-chain", "record-path", "ssh-key", "ssh-grant", "wake")))] as $records
| def known($scope; $n):
    if $scope == "floor" then ($floor_keys | index($n[0])) != null
    elif $scope == "office" then ($offices | index([$n[0:1]])) != null
    elif $scope == "room" then ($rooms | index([$n[0:2]])) != null
    elif $scope == "seat" then ($seats | index([$n])) != null
    else true end;
  def shape($r):
    $r.term as $t | at($r.origin) as $where
    | if ([$t[] | type] | unique) != ["string"] then "\($where): \($t[0]) holds a word that is not a string"
      elif $t[0] == "statement" then
        if ($t | length) != 7 then "\($where): a statement has the words statement A B C SCOPE PATH STATE, not \($t | length)"
        elif ($t[4] | IN("workplace", "floor", "kind", "office", "room", "seat") | not) then "\($where): \($t[4]) is not a scope of a statement"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) statement cannot name \($t[1:4] | join(" "))"
        elif scoped_fault($t; $t[4]; $t[1:4]) != null then "\($where): \(scoped_fault($t; $t[4]; $t[1:4]))"
        elif known($t[4]; $t[1:4]) | not then "\($where): the statement names \(scope_text($t; $t[4]; $t[1:4])), which the plan does not make"
        elif $t[4] == "seat" and mode_of($t[1:4]) == "enforced"
        then "\($where): the statement speaks at the seat \($t[1:4] | join("/")), on the enforced floor \(floor_of($t[1])), where the room is one view and a seat's statement would promise a wall that the room does not have (5.124 point 5)"
        elif $t[5] | canonical | not then "\($where): \($t[5]) is not an absolute, canonical path"
        elif $t[6] | IN(states[]) | not then "\($where): \($t[6]) is not one of \(states | join(", "))"
        else empty end
      elif $t[0] == "clearance" then
        if ($t | length) != 6 then "\($where): a clearance has the words clearance A B C SCOPE NUMBER, not \($t | length)"
        elif $t[4] == "seat" then "\($where): a seat has its room's clearance and none of its own (5.118), so seat is not a scope of a clearance"
        elif $t[4] == "floor" then "\($where): floor is not a scope of a clearance: a room's number is its own line's, else its office's (5.122 point 1)"
        elif ($t[4] | IN("office", "room") | not) then "\($where): \($t[4]) is not a scope of a clearance"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) clearance cannot name \($t[1:4] | join(" "))"
        elif scoped_fault($t; $t[4]; $t[1:4]) != null then "\($where): \(scoped_fault($t; $t[4]; $t[1:4]))"
        elif known($t[4]; $t[1:4]) | not then "\($where): the clearance names \(scope_text($t; $t[4]; $t[1:4])), which the plan does not make"
        elif $t[5] | whole | not then "\($where): \($t[5]) is not a whole number"
        else empty end
      elif $t[0] == "key" then
        if ($t | length) != 6 then "\($where): a key has the words key A B C SCOPE STATE, not \($t | length)"
        elif ($t[4] | IN("workplace", "floor", "office", "room", "seat") | not) then "\($where): \($t[4]) is not a scope of a key"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) key cannot name \($t[1:4] | join(" "))"
        elif scoped_fault($t; $t[4]; $t[1:4]) != null then "\($where): \(scoped_fault($t; $t[4]; $t[1:4]))"
        elif known($t[4]; $t[1:4]) | not then "\($where): the key names \(scope_text($t; $t[4]; $t[1:4])), which the plan does not make"
        elif $t[5] | IN("held", "none") | not then "\($where): \($t[5]) is not held or none"
        else empty end
      elif $t[0] == "expect" then
        if ($t | length) != 6 then "\($where): an expect has the words expect A B C SCOPE NAME, not \($t | length)"
        elif ($t[4] | IN("workplace", "floor", "office", "room", "seat") | not) then "\($where): \($t[4]) is not a scope of an expect"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) expect cannot name \($t[1:4] | join(" "))"
        elif scoped_fault($t; $t[4]; $t[1:4]) != null then "\($where): \(scoped_fault($t; $t[4]; $t[1:4]))"
        elif known($t[4]; $t[1:4]) | not then "\($where): the expect names \(scope_text($t; $t[4]; $t[1:4])), which the plan does not make"
        elif $t[5] | variable_name | not then "\($where): \($t[5]) is not a variable name"
        elif $kept | index($t[5]) then "\($where): \($t[5]) is a name the frame keeps for itself, and no value may take it"
        elif $inherited | index($t[5]) then "\($where): \($t[5]) is a name every seat takes from its caller, and a value given at run time may not take it"
        else empty end
      elif $t[0] | IN("home", "home-variable", "home-seed") then
        ({"home": 4, "home-variable": 4, "home-seed": 3}[$t[0]]) as $n
        | if ($t | length) != $n then "\($where): a \($t[0]) has the words \({"home": "home KIND VARIABLE STATE", "home-variable": "home-variable KIND NAME SUBPATH", "home-seed": "home-seed KIND PATH"}[$t[0]]), not \($t | length)"
          elif ($made_kinds | index($t[1])) == null then "\($where): the \($t[0]) names the kind \($t[1]), which the plan does not make"
          elif $t[0] == "home" and ($t[2] | variable_name | not) then "\($where): \($t[2]) is not a variable name"
          elif $t[0] | IN("home", "home-variable") and ($kept | index($t[2])) then "\($where): \($t[2]) is a name the frame keeps for itself, and no home may take it"
          elif $t[0] == "home" and ($t[3] | IN("kept", "scratch") | not) then "\($where): \($t[3]) is not kept or scratch"
          elif $t[0] == "home-variable" and ($t[2] | variable_name | not) then "\($where): \($t[2]) is not a variable name"
          elif $t[0] == "home-variable" and ($t[3] | inner_path | not) then "\($where): \($t[3]) is not a path inside the home: it is written relative to the home, with no empty, . or .. component"
          elif $t[0] == "home-seed" and ($t[2] | canonical | not) then "\($where): \($t[2]) is not an absolute, canonical path"
          else empty end
      elif $t[0] == "mail" then
        if ($t | length) != 2 then "\($where): a mail has the words mail PATH, not \($t | length)"
        elif $t[1] | canonical | not then "\($where): \($t[1]) is not an absolute, canonical path"
        elif $t[1] == "/" then "\($where): a mail path of / would cover each seat's whole view with its mailbox"
        else empty end
      elif $t[0] == "reach" then
        if ($t | length) != 11 then "\($where): a reach has the words reach A B C SCOPE ACTION TA TB TC TSCOPE STATE, not \($t | length)"
        elif ($t[4] | IN("workplace", "floor", "office", "room", "seat") | not) then "\($where): \($t[4]) is not a scope of a reach"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) reach cannot name \($t[1:4] | join(" "))"
        elif scoped_fault($t; $t[4]; $t[1:4]) != null then "\($where): \(scoped_fault($t; $t[4]; $t[1:4]))"
        elif known($t[4]; $t[1:4]) | not then "\($where): the reach names \(scope_text($t; $t[4]; $t[1:4])), which the plan does not make"
        elif $t[4] == "seat" and mode_of($t[1:4]) == "enforced" and (occupants($t[1:4]) | length) > 1
        then "\($where): the reach asks for the seat \($t[1:4] | join("/")), on the enforced floor \(floor_of($t[1])), whose room holds \(occupants($t[1:4]) | length) occupants: what one occupant of a room may ask, each of its room-mates may (5.118)"
        elif ($t[5] | IN("mail", "grab", "write", "record") | not) then "\($where): \($t[5]) is not mail, grab, write or record"
        elif ($t[9] | IN("workplace", "floor", "office", "room", "seat") | not) then "\($where): \($t[9]) is not a scope of a reach's target"
        elif places($t[9]; $t[6:9]) | not then "\($where): a \($t[9]) target cannot name \($t[6:9] | join(" "))"
        elif scoped_fault($t; $t[9]; $t[6:9]) != null then "\($where): \(scoped_fault($t; $t[9]; $t[6:9]))"
        elif known($t[9]; $t[6:9]) | not then "\($where): the reach's target names \(scope_text($t; $t[9]; $t[6:9])), which the plan does not make"
        elif $t[10] | IN("allowed", "banned") | not then "\($where): \($t[10]) is not allowed or banned"
        else empty end
      elif $t[0] == "record" then
        if ($t | length) != 7 then "\($where): a record has the words record A B C SCOPE WHAT STATE, not \($t | length)"
        elif ($t[4] | IN("workplace", "floor", "office", "room", "seat") | not) then "\($where): \($t[4]) is not a scope of a record"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) record cannot name \($t[1:4] | join(" "))"
        elif scoped_fault($t; $t[4]; $t[1:4]) != null then "\($where): \(scoped_fault($t; $t[4]; $t[1:4]))"
        elif known($t[4]; $t[1:4]) | not then "\($where): the record names \(scope_text($t; $t[4]; $t[1:4])), which the plan does not make"
        elif ($t[5] | IN("pane", "programs") | not) then "\($where): \($t[5]) is not pane or programs"
        elif ($t[6] | IN("kept", "none") | not) then "\($where): \($t[6]) is not kept or none"
        elif $t[5] == "programs" and $t[6] == "kept" then "\($where): the record of the programs a seat starts is built after the cutover, and no plan keeps it yet"
        else empty end
      elif $t[0] == "record-limit" then
        if ($t | length) != 2 then "\($where): a record-limit has the words record-limit BYTES, not \($t | length)"
        elif ($t[1] | test("^[1-9][0-9]{0,15}$") | not) then "\($where): \($t[1]) is not a whole number of bytes above 0"
        else empty end
      elif $t[0] == "record-chain" then
        if ($t | length) != 2 then "\($where): a record-chain has the words record-chain SINK, not \($t | length)"
        elif ($t[1] | IN("journal", "file") | not) then "\($where): \($t[1]) is not a sink the frame knows: journal or file"
        else empty end
      elif $t[0] == "record-path" then
        if ($t | length) != 2 then "\($where): a record-path has the words record-path PATH, not \($t | length)"
        elif $t[1] | canonical | not then "\($where): \($t[1]) is not an absolute, canonical path"
        elif $t[1] == "/" then "\($where): a record path of / would cover each seat's whole view"
        else empty end
      elif $t[0] == "ssh-key" then
        if ($t | length) != 3 then "\($where): an ssh-key has the words ssh-key NAME PATH, not \($t | length)"
        elif ($t[1] | key_fault) != null then "\($where): the ssh key's name \($t[1] | tojson) is refused: \($t[1] | key_fault)"
        elif $t[2] | canonical | not then "\($where): \($t[2]) is not an absolute, canonical path"
        else empty end
      elif $t[0] == "ssh-grant" then
        if ($t | length) != 7 then "\($where): an ssh-grant has the words ssh-grant A B C SCOPE NAME STATE, not \($t | length)"
        elif ($t[4] | IN("workplace", "floor", "office", "room", "seat") | not) then "\($where): \($t[4]) is not a scope of an ssh-grant"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) ssh-grant cannot name \($t[1:4] | join(" "))"
        elif scoped_fault($t; $t[4]; $t[1:4]) != null then "\($where): \(scoped_fault($t; $t[4]; $t[1:4]))"
        elif known($t[4]; $t[1:4]) | not then "\($where): the ssh-grant names \(scope_text($t; $t[4]; $t[1:4])), which the plan does not make"
        elif ($t[5] | key_fault) != null then "\($where): the ssh key's name \($t[5] | tojson) is refused: \($t[5] | key_fault)"
        elif $t[6] | IN("granted", "none") | not then "\($where): \($t[6]) is not granted or none"
        else empty end
      elif $t[0] == "clearance-scale" then
        if ($t | length) != 2 then "\($where): a clearance-scale has the words clearance-scale turned, not \($t | length)"
        elif $t[1] != "turned" then "\($where): \($t[1]) is not a scale the fold knows: turned, where 0 is the most cleared (5.122)"
        else empty end
      elif $t[0] == "wake" then
        if ($t | length) != 3 then "\($where): a wake has the words wake KIND PATTERN, not \($t | length)"
        elif ($made_kinds | index($t[1])) == null then "\($where): the wake names the kind \($t[1]), which the plan does not make"
        elif $t[2] == "" then "\($where): the wake's pattern is empty, and an empty pattern finds every screen ready"
        else empty end
      else
        if ($t | length) != 3 then "\($where): a label has the words label PATH NUMBER, not \($t | length)"
        elif $t[1] | canonical | not then "\($where): \($t[1]) is not an absolute, canonical path"
        elif $t[1] == "/" then "\($where): a label on / refuses the plan"
        elif ($t[2] | whole | not) and $t[2] != "closed" then "\($where): \($t[2]) is neither a whole number nor closed"
        else empty end
      end;
  [$records[] | shape(.)] as $shapes
  | if ($shapes | length) > 0 then {errors: $shapes}
    else
      [$records[] | select(.term[0] == "statement")] as $said
      | [$records[] | select(.term[0] == "home")] as $homed
      | [$records[] | select(.term[0] == "home-variable")] as $home_variables
      | [$records[] | select(.term[0] == "home-seed")] as $seeded
      | [$records[] | select(.term[0] == "expect")] as $expected
      | [$records[] | select(.term[0] == "clearance")] as $cleared
      | [$records[] | select(.term[0] == "label")] as $labelled
      | [$records[] | select(.term[0] == "key")] as $keyed
      | [$records[] | select(.term[0] == "mail")] as $mailed
      | [$records[] | select(.term[0] == "reach")] as $reached
      | ($mailed | map(.term[1]) | unique) as $mail_paths
      | [$records[] | select(.term[0] == "record")] as $recs
      | [$records[] | select(.term[0] == "record-limit")] as $limits
      | [$records[] | select(.term[0] == "record-chain")] as $chains
      | [$records[] | select(.term[0] == "record-path")] as $rpaths
      | ($rpaths | map(.term[1]) | unique) as $record_paths
      | ([$recs, $limits, $chains, $rpaths] | add | length > 0) as $logs
      | [$records[] | select(.term[0] == "ssh-key")] as $sshkeys
      | [$records[] | select(.term[0] == "ssh-grant")] as $sshgrants
      | ([$sshkeys, $sshgrants] | add | length > 0) as $ssh
      | ($sshkeys | map(.term[1]) | unique) as $ssh_names
      | [$records[] | select(.term[0] == "wake")] as $waked
      | [$records[] | select(.term[0] == "clearance-scale")] as $scaled
      | [($said | group_by(.term[1:6])[] | select((map(.term[6]) | unique | length) > 1)
          | "two statements of \(scope_text(.[0].term; .[0].term[4]; .[0].term[1:4])) about \(.[0].term[5]) differ: \(map("\(.term[6]) from \(at(.origin))") | join(", "))"),
         ($cleared | group_by(.term[1:5])[] | select((map(.term[5] | tonumber) | unique | length) > 1)
          | "two clearances of \(scope_text(.[0].term; .[0].term[4]; .[0].term[1:4])) differ: \(map("\(.term[5]) from \(at(.origin))") | join(", "))"),
         ($labelled | group_by(.term[1])[] | select((map(.term[2]) | unique | length) > 1)
          | "two labels of \(.[0].term[1]) differ: \(map("\(.term[2]) from \(at(.origin))") | join(", "))"),
         (if ([$cleared, $labelled] | add | length) > 0 and ($scaled | length) == 0
          then "the plan holds clearance or label terms and no clearance-scale term: since 5.122 the number 0 is the most cleared, and a plan numbered before that turn is refused until it is renumbered and says clearance-scale turned (the clearance or label at \(ats([([$cleared, $labelled] | add)[0:3][] | .origin])))" else empty end),
         ($labelled[] | select(.term[2] == "closed") as $c | $labelled[] | select(beneath(.term[1]; $c.term[1]))
          | "\(at(.origin)): the label speaks of \(.term[1]), which lies beneath \($c.term[1]), closed (from \(at($c.origin))): no label governs beneath a closed path (5.124 point 6)"),
         ($keyed | group_by(.term[1:5])[] | select((map(.term[5]) | unique | length) > 1)
          | "two keys of \(scope_text(.[0].term; .[0].term[4]; .[0].term[1:4])) differ: \(map("\(.term[5]) from \(at(.origin))") | join(", "))"),
         ($homed | group_by(.term[1])[] | select((map(.term[2:4]) | unique | length) > 1)
          | "two homes of the kind \(.[0].term[1]) differ: \(map("\(.term[2]) \(.term[3]) from \(at(.origin))") | join(", "))"),
         ($home_variables | group_by(.term[1:3])[] | select((map(.term[3]) | unique | length) > 1)
          | "two home variables \(.[0].term[2]) of the kind \(.[0].term[1]) differ: \(map("\(.term[3]) from \(at(.origin))") | join(", "))"),
         ($seeded | group_by(.term[1])[] | select((map(.term[2]) | unique | length) > 1)
          | "two seeds of the kind \(.[0].term[1]) differ: \(map("\(.term[2]) from \(at(.origin))") | join(", "))"),
         (($homed | map({key: .term[1], value: .term}) | from_entries) as $home_of
          | def home_at($kind; f): ats([$homed[] | select(.term[1] == $kind and (.term | f)) | .origin]);
            ($home_variables[] | select($home_of[.term[1]] == null)
             | "\(at(.origin)): the kind \(.term[1]) has a home variable and no home"),
            ($home_variables[] | . as $v | select($home_of[.term[1]] != null and $home_of[.term[1]][2] == .term[2])
             | "the home variable \(.term[2]) of the kind \(.term[1]) is the variable that names its home (the home variable at \(at(.origin)); the home at \(home_at(.term[1]; .[2] == $v.term[2])))"),
            ($seeded[] | select($home_of[.term[1]] == null)
             | "\(at(.origin)): the kind \(.term[1]) has a seed and no home"),
            ($seeded[] | select($home_of[.term[1]] != null and $home_of[.term[1]][3] == "scratch")
             | "the kind \(.term[1]) has a seed and a scratch home, and build seeds only a kept one (the seed at \(at(.origin)); the home at \(home_at(.term[1]; .[3] == "scratch")))")),
         (if ($mail_paths | length) > 1
          then "two mail terms differ: \([$mail_paths[] as $p | "\($p) from \(ats([$mailed[] | select(.term[1] == $p) | .origin]))"] | join(", "))" else empty end),
         ($reached | group_by(.term[1:10])[] | select((map(.term[10]) | unique | length) > 1)
          | "two reach terms of \(scope_text(.[0].term; .[0].term[4]; .[0].term[1:4])) about \(.[0].term[5]) to \(scope_text(.[0].term; .[0].term[9]; .[0].term[6:9])) differ: \(map("\(.term[10]) from \(at(.origin))") | join(", "))"),
         ($sshkeys | group_by(.term[1])[] | select((map(.term[2]) | unique | length) > 1)
          | "two ssh-key terms of the name \(.[0].term[1]) differ: \(map("\(.term[2]) from \(at(.origin))") | join(", "))"),
         ($sshgrants | group_by(.term[1:6])[] | select((map(.term[6]) | unique | length) > 1)
          | "two ssh-grant terms of \(scope_text(.[0].term; .[0].term[4]; .[0].term[1:4])) for the key \(.[0].term[5]) differ: \(map("\(.term[6]) from \(at(.origin))") | join(", "))"),
         ($waked | group_by(.term[1])[] | select((map(.term[2]) | unique | length) > 1)
          | "two wake terms of the kind \(.[0].term[1]) differ: \(map("\(.term[2] | tojson) from \(at(.origin))") | join(", "))"),
         (if ($waked | length) > 0 and ($mailed | length) == 0
          then "the plan holds wake terms and no mail term, so no mail is delivered to point out (the wake at \(ats([$waked[].origin])))" else empty end),
         ($sshgrants[] | select(.term[5] as $n | $ssh_names | index($n) | not)
          | "\(at(.origin)): the ssh-grant names the key \(.term[5]), which no ssh-key term declares"),
         ([$reached[] | select(.term[5] != "record")] as $asks
          | if ($asks | length) > 0 and ($mailed | length) == 0
            then "the plan holds reach terms and no mail term, so no seat has a mailbox to ask in (the reach at \(ats([$asks[].origin])))" else empty end),
         ([$reached[] | select(.term[5] == "record")] as $reads
          | if ($reads | length) > 0 and ($rpaths | length) == 0
            then "the plan holds reach terms for records and no record-path term, so no seat is shown a record (the reach at \(ats([$reads[].origin])))" else empty end),
         ($recs | group_by(.term[1:6])[] | select((map(.term[6]) | unique | length) > 1)
          | "two records of \(scope_text(.[0].term; .[0].term[4]; .[0].term[1:4])) about its \(.[0].term[5]) differ: \(map("\(.term[6]) from \(at(.origin))") | join(", "))"),
         (["record-limit", $limits], ["record-chain", $chains], ["record-path", $rpaths] | . as [$word, $terms]
          | select(($terms | map(.term[1]) | unique | length) > 1)
          | "two \($word) terms differ: \([$terms | map(.term[1]) | unique | .[] as $v | "\($v) from \(ats([$terms[] | select(.term[1] == $v) | .origin]))"] | join(", "))"),
         ($record_paths[] as $r | $mail_paths[] as $m | select(at_or_beneath($r; $m) or at_or_beneath($m; $r))
          | "the record path \($r) and the mail path \($m) lie one in the other (the record-path at \(ats([$rpaths[] | select(.term[1] == $r) | .origin])); the mail at \(ats([$mailed[] | select(.term[1] == $m) | .origin])))"),
         ($record_paths[] as $m
          | ($said[] | select(at_or_beneath(.term[5]; $m))
             | "\(at(.origin)): the statement speaks of \(.term[5]), which lies at or beneath the record path \($m), where the frame shows a seat the records it may read (the record-path at \(ats([$rpaths[] | select(.term[1] == $m) | .origin])))"),
            ($labelled[] | select(at_or_beneath(.term[1]; $m))
             | "\(at(.origin)): the label speaks of \(.term[1]), which lies at or beneath the record path \($m), where the frame shows a seat the records it may read (the record-path at \(ats([$rpaths[] | select(.term[1] == $m) | .origin])))")),
         ($mail_paths[] as $m
          | ($said[] | select(at_or_beneath(.term[5]; $m))
             | "\(at(.origin)): the statement speaks of \(.term[5]), which lies at or beneath the mail path \($m), where the frame shows each seat its mailbox (the mail at \(ats([$mailed[] | select(.term[1] == $m) | .origin])))"),
            ($labelled[] | select(at_or_beneath(.term[1]; $m))
             | "\(at(.origin)): the label speaks of \(.term[1]), which lies at or beneath the mail path \($m), where the frame shows each seat its mailbox (the mail at \(ats([$mailed[] | select(.term[1] == $m) | .origin])))")),
         ($rooms[] as $rm | select(mode_of($rm) == "enforced")
          | ([$seats[] | select(.[0:2] == $rm) | $kinds[tojson] // "none"] | unique) as $ks
          | [$said[] | select((.term[4] == "room" and .term[1:3] == $rm) or (.term[4] == "kind" and (.term[1] as $kk | $ks | index($kk)) != null))]
          | group_by(.term[5])[] | select((map(.term[6]) | unique | length) > 1)
          | "two statements about \(.[0].term[5]) at the room \($rm | join("/")) differ: \([group_by(.term[6])[] | "\(.[0].term[6]) from \(ats(map(.origin)))"] | join(", ")) (5.124 point 5)")] as $conflicts
      | if ($conflicts | length) > 0 then {errors: $conflicts}
        else
          entities($said) as $statements
          | entities($cleared) as $clearances
          | entities($keyed) as $keys
          | entities($homed) as $homes
          | entities($home_variables) as $home_vars
          | entities($seeded) as $seeds
          | entities($expected) as $expects
          | entities($reached) as $reaches
          | entities($recs) as $record_terms
          | entities($sshkeys) as $ssh_keys_e
          | entities($sshgrants) as $ssh_grants_e
          | entities($waked) as $wakes
          | (if ($rpaths | length) == 0 then null else $record_paths[0] end) as $record_path
          | (if ($mailed | length) == 0 then null else {path: $mail_paths[0], origins: [$mailed[].origin]} end) as $mail
          | def holds($scope; $n; $k):
              $scope == "workplace" or ($scope == "floor" and $n[0] == floor_of($k[0])) or ($scope == "office" and $n[0] == $k[0]) or ($scope == "room" and $n[0:2] == $k[0:2]) or ($scope == "seat" and $n == $k);
            def decide($action; $k; $tk):
              [$reaches[] | select(.term[5] == $action and holds(.term[4]; .term[1:4]; $k) and holds(.term[9]; .term[6:9]; $tk))] as $c
              | if ($c | length) == 0 then {state: (if $action == "mail" then "allowed" else "banned" end), origins: []}
                else ($c | map(.term[4] | rank) | max) as $ask | [$c[] | select((.term[4] | rank) == $ask)] as $narrow
                  | ($narrow | map(.term[9] | rank) | max) as $tgt | [$narrow[] | select((.term[9] | rank) == $tgt)][0]
                  | {state: .term[10], origins} end;
            (entities($labelled) | map({path: .term[1], value: (if .term[2] == "closed" then "closed" else (.term[2] | tonumber) end), origins}) | sort_by((.path | depth), .path)) as $labels
          | def cleared($c; $l): $l.value != "closed" and $c.value != null and $c.value <= $l.value;
            def governing($p): [$labels[] | select(at_or_beneath($p; .path))] | max_by(.path | depth);
            [$panes[] | . as $pane | $pane[1:4] as $k | ($kinds[$k | tojson] // "none") as $kind
             | mode_of($k) as $mode
             | (if $mode == "enforced" then [occupants($k)[] | $kinds[tojson] // "none"] | unique else [$kind] end) as $kindset
             | def eff_rank: if $mode == "enforced" and .term[4] == "kind" then ("room" | rank) else (.term[4] | rank) end;
               (if $mode == "unenforced" then []
                else [$statements[] | select(
                 .term[4] == "workplace"
                 or (.term[4] == "floor" and .term[1] == floor_of($k[0]))
                 or (.term[4] == "kind" and .term[1] != "none" and (.term[1] as $kk | $kindset | index($kk)) != null)
                 or (.term[4] == "office" and .term[1] == $k[0])
                 or (.term[4] == "room" and .term[1:3] == $k[0:2])
                 or (.term[4] == "seat" and .term[1:4] == $k))] end) as $mine
             | [$mine[] | . as $s | ($s | eff_rank) as $sr
                | select(any($mine[]; eff_rank > $sr and at_or_beneath($s.term[5]; .term[5])) | not)] as $remaining
             | ([$clearances[] | select(.term[4] == "room" and .term[1:3] == $k[0:2])]
                + [$clearances[] | select(.term[4] == "office" and .term[1] == $k[0])]) as $held
             | (if ($held | length) == 0 then {value: null, scope: null, origins: []}
                else ($held[0].term[4]) as $scope | [$held[] | select(.term[4] == $scope)] as $same
                  | {value: ($same[0].term[5] | tonumber), scope: $scope, origins: [$same[].origins[]]} end) as $clearance
             | ([$keys[] | select(.term[4] == "seat" and .term[1:4] == $k)]
                + [$keys[] | select(.term[4] == "room" and .term[1:3] == $k[0:2])]
                + [$keys[] | select(.term[4] == "office" and .term[1] == $k[0])]
                + [$keys[] | select(.term[4] == "floor" and .term[1] == floor_of($k[0]))]
                + [$keys[] | select(.term[4] == "workplace")]) as $spoken
             | (if ($spoken | length) == 0 then {state: "none", scope: null, origins: []}
                else {state: $spoken[0].term[5], scope: $spoken[0].term[4], origins: $spoken[0].origins} end) as $key
             | ([$homes[] | select(.term[1] == $kind)][0]) as $h
             | (if $h == null then null
                else {kind: $kind, variable: $h.term[2], state: $h.term[3],
                      variables: [$home_vars[] | select(.term[1] == $kind) | {name: .term[2], path: .term[3], origins}] | sort_by(.name),
                      seed: ([$seeds[] | select(.term[1] == $kind) | {path: .term[2], origins}][0]),
                      origins: $h.origins} end) as $home
             | ([$expects[] | select(
                  .term[4] == "workplace"
                  or (.term[4] == "floor" and .term[1] == floor_of($k[0]))
                  or (.term[4] == "office" and .term[1] == $k[0])
                  or (.term[4] == "room" and .term[1:3] == $k[0:2])
                  or (.term[4] == "seat" and .term[1:4] == $k))]
                | group_by(.term[5])
                | map({name: .[0].term[5], scopes: (map(.term[4]) | unique | sort_by(rank)), origins: [.[].origins[]]})) as $expecting
             | ([$remaining | group_by(.term[5])[]
                 | {key: .[0].term[5], value: {key: ($k + [.[0].term[5]]), value: [.[0].term[6]], origins: [.[].origins[]], source: "statement", term: .[0].term}}]
                | from_entries) as $stated
             | ((if $mail == null then [] else ["mail", "grab", "write"] end) + (if $record_path == null then [] else ["record"] end)) as $actions
             | (if ($actions | length) == 0 then null
                else [$actions[] as $action
                      | {key: $action, value: [$panes[] | . as $tp | decide($action; $k; $tp[1:4]) | select(.state == "allowed") | {name: $tp[4], origins}]}]
                     | from_entries end) as $reach
             | ([$record_terms[] | select(.term[5] == "pane" and .term[4] == "seat" and .term[1:4] == $k)]
                + [$record_terms[] | select(.term[5] == "pane" and .term[4] == "room" and .term[1:3] == $k[0:2])]
                + [$record_terms[] | select(.term[5] == "pane" and .term[4] == "office" and .term[1] == $k[0])]
                + [$record_terms[] | select(.term[5] == "pane" and .term[4] == "floor" and .term[1] == floor_of($k[0]))]
                + [$record_terms[] | select(.term[5] == "pane" and .term[4] == "workplace")]) as $spoke
             | (if $logs | not then null
                elif ($spoke | length) == 0 then {pane: "none", scope: null, origins: []}
                else {pane: $spoke[0].term[6], scope: $spoke[0].term[4], origins: $spoke[0].origins} end) as $record
             | [$ssh_names[] as $nm
                | ([$ssh_grants_e[] | select(.term[5] == $nm and holds(.term[4]; .term[1:4]; $k))] | max_by(.term[4] | rank)) as $g
                | select($g != null and $g.term[6] == "granted")
                | {name: $nm, scope: $g.term[4], origins: $g.origins}] as $ssh_granted
             | (if $ssh | not then null
                elif $key.state == "held" then {granted: $ssh_granted, unreached: []}
                else {granted: [], unreached: $ssh_granted} end) as $ssh_seat
             | ([$wakes[] | select(.term[1] == $kind)][0]) as $w
             | (if $w == null then null else {pattern: $w.term[2], origins: $w.origins} end) as $wake
             | {seat: $k, name: $pane[4], kind: $kind, mode: $mode, clearance: $clearance, key: $key, home: $home, expects: $expecting, mine: $mine, remaining: $remaining, stated: $stated, reach: $reach, record: $record, ssh: $ssh_seat, wake: $wake}]
          as $folds
          | [$folds[] | select(.home != null) | . as $f
             | ([$f.home.variable] + [$f.home.variables[].name]) as $given
             | $f.expects[] | .name as $n | select($given | index($n))
             | "seat \($f.name) (\($f.seat | join("/"))): it expects the value \(.name), which the home of its kind \($f.home.kind) gives it (the expect at \(ats(.origins)); the home at \(ats($f.home.origins + [$f.home.variables[] | select(.name == $n) | .origins[]])))"] as $clashes
          | [$folds[] | select(.mode != "unenforced" and (.stated | has("/") | not))
             | "seat \(.name) (\(.seat | join("/"))): no row for /"
               + ([$reached[] | select(.term[5] != "record")] as $asks
                  | if $mail != null or ($asks | length) > 0
                  then ": it has no view, and a seat with no view could write as any seat, which the plan's \(if $mail != null then "mail" else "reach" end) terms do not allow (at \(ats(if $mail != null then $mail.origins else [$asks[].origin] end)))"
                  elif .record.pane? == "kept"
                  then ": it has no view, and a seat with no view could reach its own record, which the plan keeps (the record at \(ats(.record.origins)))"
                  elif $record_path != null
                  then ": it has no view to hold the frame's file system at the record path \($record_path), which the frame puts in every seat's view (the record-path at \(ats([$rpaths[].origin])))"
                  else "" end)] as $rootless
          | [$folds[] | select(.ssh != null) | . as $f | $f.ssh.unreached[] | select(.scope == "seat")
             | "seat \($f.name) (\($f.seat | join("/"))): the ssh-grant at \(ats(.origins)) grants the key \(.name) at the seat's own scope, and the seat holds no key, so it has no agent to hold it"
               + (if $f.key.scope == null then "" else " (the key at \(ats($f.key.origins)))" end)] as $unheld
          | if ($clashes | length) > 0 then {errors: $clashes}
            elif ($rootless | length) > 0 then {errors: $rootless}
            elif ($unheld | length) > 0 then {errors: $unheld}
            else
              [$folds[] | . as $f
               | (if $f.mode == "unenforced" then {rows: {}, at: []} else reduce $labels[] as $l ({rows: $f.stated, at: []};
                   if .rows | has($l.path) then
                     (if .rows[$l.path].source == "statement" then .at += [{statement: (.rows[$l.path] | statement_object), label: {value: $l.value, origins: $l.origins}}] else . end)
                   else
                     .rows[[.rows | to_entries[] | select(.value.source == "statement" and beneath($l.path; .key)) | .key] | max_by(depth)].value[0] as $stated
                     | .rows[[.rows | keys[] | select(beneath($l.path; .))] | max_by(depth)].value[0] as $above
                     | if $stated | IN("hidden", "scratch") then .
                       elif cleared($f.clearance; $l) | not then
                         if $above == "searchable-only" then .
                         else .rows[$l.path] = {key: ($f.seat + [$l.path]), value: ["hidden"], origins: $l.origins, source: "label"} end
                       else .rows[$l.path] = {key: ($f.seat + [$l.path]), value: ["read-only"], origins: $l.origins, source: "label"} end
                   end) end) as $made
               | ($made.rows | with_entries(
                   .key as $p
                   | if .value.source == "label" and .value.value[0] == "hidden"
                        and any($made.rows[]; .value[0] != "hidden" and beneath(.key[3]; $p))
                     then .value.value = ["searchable-only"] | .value.passage = true else . end)) as $passed
               | [$passed | keys[] as $p | $passed[$p]] as $rows
               | $f + {rows: $rows, at: ($made.at | sort_by(.statement.term[5]))}]
            as $tables
            | [$tables[] | . as $f
               | ($f.rows[] | . as $r | select($r.value[0] != "hidden")
                  | ($f.rows[] | select(.value[0] == "hidden" and beneath($r.key[3]; .key[3]))
                     | "seat \($f.name) (\($f.seat | join("/"))): \($r.key[3]) (\($r.value[0]), from \(ats($r.origins))) lies beneath \(.key[3]) (hidden, from \(ats(.origins)))")),
                 ($f.rows[] | . as $r | select($r.value[0] != "hidden" and ($r.passage | not))
                  | governing($r.key[3]) | select(. != null and (cleared($f.clearance; .) | not))
                  | "seat \($f.name) (\($f.seat | join("/"))): \($r.key[3]) (\($r.value[0]), from \(ats($r.origins))) lies at or beneath \(.path), labelled \(.value) (from \(ats(.origins)))"
                    + (if .value == "closed" then ", which no clearance reaches"
                       elif $f.clearance.value == null then ", and the seat is cleared for no label"
                       else ", which the seat's clearance \($f.clearance.value) does not reach" end)),
                 ($labels[] | . as $l | select(cleared($f.clearance; $l) | not)
                  | ([$f.rows[] | select(at_or_beneath($l.path; .key[3]))] | max_by(.key[3] | depth)) as $r
                  | select($r != null and $r.key[3] != $l.path and ($r.value[0] | IN("read-only", "read-write")))
                  | "seat \($f.name) (\($f.seat | join("/"))): \($l.path), labelled \($l.value) (from \(ats($l.origins))), lies beneath \($r.key[3]) (\($r.value[0]), from \(ats($r.origins))) with no row of its own"
                    + (if $l.value == "closed" then ", and no clearance reaches closed"
                       elif $f.clearance.value == null then ", and the seat is cleared for no label"
                       else ", and the seat's clearance \($f.clearance.value) does not reach \($l.value)" end)),
                 (if $mail == null then empty
                  else $f.rows[] | select(.value[0] == "hidden" and beneath($mail.path; .key[3]))
                    | "seat \($f.name) (\($f.seat | join("/"))): its mailbox at \($mail.path) lies beneath \(.key[3]) (hidden, from \(ats(.origins))), and the seat could not reach it (the mail at \(ats($mail.origins)))" end),
                 (if $record_path == null then empty
                  else $f.rows[] | select(.value[0] == "hidden" and beneath($record_path; .key[3]))
                    | "seat \($f.name) (\($f.seat | join("/"))): its record path \($record_path) lies beneath \(.key[3]) (hidden, from \(ats(.origins))), and the seat could not reach it (the record-path at \(ats([$rpaths[].origin])))" end),
                 ($ssh_keys_e[] | . as $sk | $sk.term[2] as $file
                  | ([$f.rows[] | select(at_or_beneath($file; .key[3]))] | max_by(.key[3] | length)) as $row
                  | select($row != null and ($row.value[0] | IN("read-only", "read-write")))
                  | "seat \($f.name) (\($f.seat | join("/"))): the file \($file) of the ssh key \($sk.term[1]) (the ssh-key at \(ats($sk.origins))) is shown to the seat by its row \($row.key[3]) \($row.value[0]) (from \(ats($row.origins))), and no seat is shown the file of a private key")]
            as $refused
            | if ($refused | length) > 0 then {errors: $refused}
              else
                [$tables[] | . as $f
                 | [$f.remaining[] | . as $r
                    | [$f.mine[] | select((.term[4] | rank) < ($r.term[4] | rank) and at_or_beneath(.term[5]; $r.term[5])) | statement_object] as $under
                    | select(($under | length) > 0)
                    | {statement: ($r | statement_object), replaced: $under}] | sort_by(.statement.term[5]) as $replacing
                 | $f + {replacing: $replacing, distinct: ([$replacing[].replaced[].term] | unique | length)}]
                as $done
                | {view: ({
                    rows: [$done[].rows[] | {key, value, origins, source}],
                    seats: [$done[] | {
                      seat, kind,
                      clearance: {value: .clearance.value, origin: (.clearance.origins[0] // null), origins: .clearance.origins, scope: .clearance.scope},
                      key}
                     + (if $floored then {floor: floor_of(.seat[0]), enforced: (.mode == "enforced")} else {} end)
                     + (if .home == null then {} else {home} end)
                     + (if (.expects | length) == 0 then {} else {expects} end)
                     + (if .reach == null then {} else {reach: (.reach | map_values(map(.name)))} end)
                     + (if .record == null then {} else {record} end)
                     + (if .ssh == null then {} else {ssh} end)
                     + (if .wake == null then {} else {wake} end)
                     + {
                      rows: (.rows | length),
                      replacement_statements: .replacing,
                      exception_count: (.replacing | length),
                      distinct_replaced_statement_count: .distinct,
                      statements_at_labelled_paths: .at}]}
                    + (if $floored | not then {}
                       else {floors: [$floors[] | {key, name, houses, enforced, socket, conf, smallest, origins}],
                             rooms: [$window_rooms[] as $rm | [$done[] | select(.seat[0:2] == $rm)] as $occ
                               | select(($occ | length) > 0 and $occ[0].mode == "enforced")
                               | {room: $rm, of: (if ($room_floor_keys | index($rm[0])) != null then "floor" else "office" end), floor: floor_of($rm[0]),
                                  clearance: {value: $occ[0].clearance.value, origin: ($occ[0].clearance.origins[0] // null),
                                              origins: $occ[0].clearance.origins, scope: $occ[0].clearance.scope},
                                  occupants: [$occ[].name],
                                  rows: [$occ[0].rows[] | {key: ($rm + [.key[3]]), value, origins, source}],
                                  statements_at_labelled_paths: $occ[0].at}]} end)
                    + (if $mail == null then {} else {mail: $mail} end)
                    + (if $ssh | not then {} else {ssh: {keys: [$ssh_keys_e[] | {name: .term[1], path: .term[2], origins}]}} end)
                    + (if $logs | not then {}
                       else {records: {path: $record_path, limit: ((($limits | map(.term[1]) | unique)[0] // "268435456") | tonumber),
                                       chain: (($chains | map(.term[1]) | unique)[0] // null),
                                       origins: [$limits[].origin, $chains[].origin, $rpaths[].origin]}} end)),
                   report: {
                     names: [$done[] | {key: (.seat | tojson), value: .name}] | from_entries,
                     wakes: [$wakes[] | {kind: .term[1], pattern: .term[2], origins}],
                     record_path_origins: [$rpaths[].origin],
                     reach: [$done[] | select(.reach != null) | {key: (.seat | tojson), value: .reach}] | from_entries,
                     unnumbered: [$window_rooms[] as $rm | [$done[] | select(.seat[0:2] == $rm)] as $occ
                       | select(($occ | length) > 0 and $occ[0].mode == "enforced" and $occ[0].clearance.value == null)
                       | {room: $rm, floor: floor_of($rm[0]), of: (if ($room_floor_keys | index($rm[0])) != null then "floor" else "office" end)}],
                     unenforced: [$floors[] | select(.enforced | not) | .key],
                     passages: [$labels[] | . as $l
                       | {label: $l, seats: [$done[] | select(any(.rows[]; .passage == true and .key[3] == $l.path)) | .name]}
                       | select((.seats | length) > 0)]}}
              end
            end
        end
    end
