include "table";

def term_of: if type == "object" and .unchecked == true then .term else . end;
def canonical: type == "string" and (. == "/" or (startswith("/") and (endswith("/") | not) and (.[1:] | split("/") | all(. != "" and . != "." and . != ".."))));
def beneath($p; $q): ($q == "/" and $p != "/") or ($p | startswith($q + "/"));
def at_or_beneath($p; $q): $p == $q or beneath($p; $q);
def depth: if . == "/" then 0 else (split("/") | length) - 1 end;
def whole: type == "string" and test("^(0|[1-9][0-9]*)$");
def rank: {"workplace": 0, "kind": 1, "office": 2, "room": 3, "seat": 4}[.];
def states: ["hidden", "searchable-only", "scratch", "read-only", "read-write"];
def at($o): "\($o.path // "?"):\($o.line // "?")";
def ats($os): [$os[] | at(.)] | join(", ");
def places($scope; $n):
  ($n | map(. != "-")) as $used
  | {"workplace": [false, false, false], "kind": [true, false, false], "office": [true, false, false],
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
| [($plan.state["seat-kinds"] // [])[] | {key: (.key | tojson), value: .value[0]}] | from_entries as $kinds
| ([$kinds[]] + [($plan.state.kinds // [])[] | .key[0]?] | map(select(type == "string" and . != "none")) | unique) as $made_kinds
| [$plan.programs[] | .recorded[]? | select((.term | type) == "array" and (.term[0] | IN("statement", "clearance", "label", "key", "home", "home-variable", "home-seed", "expect")))] as $records
| def known($scope; $n):
    if $scope == "office" then ($offices | index([$n[0:1]])) != null
    elif $scope == "room" then ($rooms | index([$n[0:2]])) != null
    elif $scope == "seat" then ($seats | index([$n])) != null
    else true end;
  def shape($r):
    $r.term as $t | at($r.origin) as $where
    | if ([$t[] | type] | unique) != ["string"] then "\($where): \($t[0]) holds a word that is not a string"
      elif $t[0] == "statement" then
        if ($t | length) != 7 then "\($where): a statement has the words statement A B C SCOPE PATH STATE, not \($t | length)"
        elif ($t[4] | IN("workplace", "kind", "office", "room", "seat") | not) then "\($where): \($t[4]) is not a scope of a statement"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) statement cannot name \($t[1:4] | join(" "))"
        elif known($t[4]; $t[1:4]) | not then "\($where): the statement names \(scope_text($t; $t[4]; $t[1:4])), which the plan does not make"
        elif $t[5] | canonical | not then "\($where): \($t[5]) is not an absolute, canonical path"
        elif $t[6] | IN(states[]) | not then "\($where): \($t[6]) is not one of \(states | join(", "))"
        else empty end
      elif $t[0] == "clearance" then
        if ($t | length) != 6 then "\($where): a clearance has the words clearance A B C SCOPE NUMBER, not \($t | length)"
        elif ($t[4] | IN("office", "room", "seat") | not) then "\($where): \($t[4]) is not a scope of a clearance"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) clearance cannot name \($t[1:4] | join(" "))"
        elif known($t[4]; $t[1:4]) | not then "\($where): the clearance names \(scope_text($t; $t[4]; $t[1:4])), which the plan does not make"
        elif $t[5] | whole | not then "\($where): \($t[5]) is not a whole number"
        else empty end
      elif $t[0] == "key" then
        if ($t | length) != 6 then "\($where): a key has the words key A B C SCOPE STATE, not \($t | length)"
        elif ($t[4] | IN("workplace", "office", "room", "seat") | not) then "\($where): \($t[4]) is not a scope of a key"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) key cannot name \($t[1:4] | join(" "))"
        elif known($t[4]; $t[1:4]) | not then "\($where): the key names \(scope_text($t; $t[4]; $t[1:4])), which the plan does not make"
        elif $t[5] | IN("held", "none") | not then "\($where): \($t[5]) is not held or none"
        else empty end
      elif $t[0] == "expect" then
        if ($t | length) != 6 then "\($where): an expect has the words expect A B C SCOPE NAME, not \($t | length)"
        elif ($t[4] | IN("workplace", "office", "room", "seat") | not) then "\($where): \($t[4]) is not a scope of an expect"
        elif places($t[4]; $t[1:4]) | not then "\($where): a \($t[4]) expect cannot name \($t[1:4] | join(" "))"
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
      else
        if ($t | length) != 3 then "\($where): a label has the words label PATH NUMBER, not \($t | length)"
        elif $t[1] | canonical | not then "\($where): \($t[1]) is not an absolute, canonical path"
        elif $t[1] == "/" then "\($where): a label on / refuses the plan"
        elif $t[2] | whole | not then "\($where): \($t[2]) is not a whole number"
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
      | [($said | group_by(.term[1:6])[] | select((map(.term[6]) | unique | length) > 1)
          | "two statements of \(scope_text(.[0].term; .[0].term[4]; .[0].term[1:4])) about \(.[0].term[5]) differ: \(map("\(.term[6]) from \(at(.origin))") | join(", "))"),
         ($cleared | group_by(.term[1:5])[] | select((map(.term[5] | tonumber) | unique | length) > 1)
          | "two clearances of \(scope_text(.[0].term; .[0].term[4]; .[0].term[1:4])) differ: \(map("\(.term[5]) from \(at(.origin))") | join(", "))"),
         ($labelled | group_by(.term[1])[] | select((map(.term[2] | tonumber) | unique | length) > 1)
          | "two labels of \(.[0].term[1]) differ: \(map("\(.term[2]) from \(at(.origin))") | join(", "))"),
         ($keyed | group_by(.term[1:5])[] | select((map(.term[5]) | unique | length) > 1)
          | "two keys of \(scope_text(.[0].term; .[0].term[4]; .[0].term[1:4])) differ: \(map("\(.term[5]) from \(at(.origin))") | join(", "))"),
         ($homed | group_by(.term[1])[] | select((map(.term[2:4]) | unique | length) > 1)
          | "two homes of the kind \(.[0].term[1]) differ: \(map("\(.term[2]) \(.term[3]) from \(at(.origin))") | join(", "))"),
         ($home_variables | group_by(.term[1:3])[] | select((map(.term[3]) | unique | length) > 1)
          | "two home variables \(.[0].term[2]) of the kind \(.[0].term[1]) differ: \(map("\(.term[3]) from \(at(.origin))") | join(", "))"),
         ($seeded | group_by(.term[1])[] | select((map(.term[2]) | unique | length) > 1)
          | "two seeds of the kind \(.[0].term[1]) differ: \(map("\(.term[2]) from \(at(.origin))") | join(", "))"),
         (($homed | map({key: .term[1], value: .term}) | from_entries) as $home_of
          | ($home_variables[] | select($home_of[.term[1]] == null)
             | "\(at(.origin)): the kind \(.term[1]) has a home variable and no home"),
            ($home_variables[] | select($home_of[.term[1]] != null and $home_of[.term[1]][2] == .term[2])
             | "\(at(.origin)): the home variable \(.term[2]) of the kind \(.term[1]) is the variable that names its home"),
            ($seeded[] | select($home_of[.term[1]] == null)
             | "\(at(.origin)): the kind \(.term[1]) has a seed and no home"),
            ($seeded[] | select($home_of[.term[1]] != null and $home_of[.term[1]][3] == "scratch")
             | "\(at(.origin)): the kind \(.term[1]) has a scratch home, and build seeds only a kept one"))] as $conflicts
      | if ($conflicts | length) > 0 then {errors: $conflicts}
        else
          entities($said) as $statements
          | entities($cleared) as $clearances
          | entities($keyed) as $keys
          | entities($homed) as $homes
          | entities($home_variables) as $home_vars
          | entities($seeded) as $seeds
          | entities($expected) as $expects
          | (entities($labelled) | map({path: .term[1], value: (.term[2] | tonumber), origins}) | sort_by((.path | depth), .path)) as $labels
          | [$panes[] | . as $pane | $pane[1:4] as $k | ($kinds[$k | tojson] // "none") as $kind
             | [$statements[] | select(
                 .term[4] == "workplace"
                 or (.term[4] == "kind" and $kind != "none" and .term[1] == $kind)
                 or (.term[4] == "office" and .term[1] == $k[0])
                 or (.term[4] == "room" and .term[1:3] == $k[0:2])
                 or (.term[4] == "seat" and .term[1:4] == $k))] as $mine
             | [$mine[] | . as $s
                | select(any($mine[]; (.term[4] | rank) > ($s.term[4] | rank) and at_or_beneath($s.term[5]; .term[5])) | not)] as $remaining
             | ([$clearances[] | select(.term[4] == "seat" and .term[1:4] == $k)]
                + [$clearances[] | select(.term[4] == "room" and .term[1:3] == $k[0:2])]
                + [$clearances[] | select(.term[4] == "office" and .term[1] == $k[0])]) as $held
             | (if ($held | length) == 0 then {value: 0, scope: null, origins: []}
                else ($held[0].term[4]) as $scope | [$held[] | select(.term[4] == $scope)] as $same
                  | {value: ($same[0].term[5] | tonumber), scope: $scope, origins: [$same[].origins[]]} end) as $clearance
             | ([$keys[] | select(.term[4] == "seat" and .term[1:4] == $k)]
                + [$keys[] | select(.term[4] == "room" and .term[1:3] == $k[0:2])]
                + [$keys[] | select(.term[4] == "office" and .term[1] == $k[0])]
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
                  or (.term[4] == "office" and .term[1] == $k[0])
                  or (.term[4] == "room" and .term[1:3] == $k[0:2])
                  or (.term[4] == "seat" and .term[1:4] == $k))]
                | group_by(.term[5])
                | map({name: .[0].term[5], scopes: (map(.term[4]) | unique | sort_by(rank)), origins: [.[].origins[]]})) as $expecting
             | ([$remaining[] | {key: .term[5], value: {key: ($k + [.term[5]]), value: [.term[6]], origins, source: "statement", term}}]
                | from_entries) as $stated
             | {seat: $k, name: $pane[4], kind: $kind, clearance: $clearance, key: $key, home: $home, expects: $expecting, mine: $mine, remaining: $remaining, stated: $stated}]
          as $folds
          | [$folds[] | select(.home != null) | . as $f
             | ([$f.home.variable] + [$f.home.variables[].name]) as $given
             | $f.expects[] | .name as $n | select($given | index($n))
             | "seat \($f.name) (\($f.seat | join("/"))): it expects the value \(.name), which the home of its kind \($f.home.kind) gives it (the expect at \(ats(.origins)); the home at \(ats($f.home.origins + [$f.home.variables[] | select(.name == $n) | .origins[]])))"] as $clashes
          | [$folds[] | select(.stated | has("/") | not) | "seat \(.name) (\(.seat | join("/"))): no row for /"] as $rootless
          | if ($clashes | length) > 0 then {errors: $clashes}
            elif ($rootless | length) > 0 then {errors: $rootless}
            else
              [$folds[] | . as $f
               | (reduce $labels[] as $l ({rows: $f.stated, at: []};
                   if .rows | has($l.path) then
                     (if .rows[$l.path].source == "statement" then .at += [{statement: (.rows[$l.path] | statement_object), label: {value: $l.value, origins: $l.origins}}] else . end)
                   else
                     (.rows[[.rows | keys[] | select(beneath($l.path; .))] | max_by(depth)].value[0]) as $above
                     | if $f.clearance.value < $l.value then
                         if $above | IN("searchable-only", "scratch") then .
                         else .rows[$l.path] = {key: ($f.seat + [$l.path]), value: ["hidden"], origins: $l.origins, source: "label"} end
                       elif $above | IN("hidden", "scratch") then .
                       else .rows[$l.path] = {key: ($f.seat + [$l.path]), value: ["read-only"], origins: $l.origins, source: "label"} end
                   end)) as $made
               | [$made.rows | keys[] as $p | $made.rows[$p]] as $rows
               | $f + {rows: $rows, at: ($made.at | sort_by(.statement.term[5]))}]
            as $tables
            | [$tables[] | . as $f
               | ($f.rows[] | . as $r | select($r.value[0] != "hidden")
                  | ($f.rows[] | select(.value[0] == "hidden" and beneath($r.key[3]; .key[3]))
                     | "seat \($f.name) (\($f.seat | join("/"))): \($r.key[3]) (\($r.value[0]), from \(ats($r.origins))) lies beneath \(.key[3]) (hidden, from \(ats(.origins)))")),
                 ($f.rows[] | . as $r | select($r.value[0] != "hidden")
                  | ($labels[] | select(.value > $f.clearance.value and at_or_beneath($r.key[3]; .path))
                     | "seat \($f.name) (\($f.seat | join("/"))): \($r.key[3]) (\($r.value[0]), from \(ats($r.origins))) lies at or beneath \(.path), labelled \(.value) (from \(ats(.origins))), above the seat's clearance \($f.clearance.value)"))]
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
                | {view: {
                    rows: [$done[].rows[] | {key, value, origins, source}],
                    seats: [$done[] | {
                      seat, kind,
                      clearance: {value: .clearance.value, origin: (.clearance.origins[0] // null), origins: .clearance.origins, scope: .clearance.scope},
                      key}
                     + (if .home == null then {} else {home} end)
                     + (if (.expects | length) == 0 then {} else {expects} end)
                     + {
                      rows: (.rows | length),
                      replacement_statements: .replacing,
                      exception_count: (.replacing | length),
                      distinct_replaced_statement_count: .distinct,
                      statements_at_labelled_paths: .at}]},
                   report: {
                     names: [$done[] | {key: (.seat | tojson), value: .name}] | from_entries,
                     pairs: [$labels[] as $upper | $labels[] | . as $lower
                       | select(beneath($lower.path; $upper.path) and $lower.value < $upper.value)
                       | {upper: $upper, lower: $lower,
                          between: [$done[] | select(.clearance.value >= $lower.value and .clearance.value < $upper.value) | .name]}]}}
              end
            end
        end
    end
