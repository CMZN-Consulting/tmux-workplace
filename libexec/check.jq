include "table";
$b[0] as $binding
| joined($binding; $root) as $plan
| def source_rows($spec): table_rows($plan; $folded[0]; $spec);
  def term: if type == "object" and .unchecked == true then .term else . end;
  def strings_list: type == "array" and ([.[] | type] | unique) == ["string"];
  def beneath($p; $q): ($q == "/" and $p != "/") or ($p | startswith($q + "/"));
  def canonical: . == "/" or (startswith("/") and (endswith("/") | not) and (.[1:] | split("/") | all(. != "" and . != "." and . != "..")));
  def terms: [$plan.programs[] | .path as $p | .plan | to_entries[] | {path: $p, n: (.key + 1), term: (.value | term)}];
  def path_places($name):
    [$binding.primitives[$name] | .. | objects | select(has("path")) | .path] | unique;
  def term_problems:
    terms[] | . as $r | $r.term as $t
    | if ($t | strings_list | not) or ($t | length) < 1 then "\($r.path), term \($r.n): not a list of strings"
      elif ($binding.primitives | has($t[0])) | not then "\($r.path), term \($r.n): the binding has no primitive \($t[0])"
      elif ($binding.order | index($t[0])) == null then "\($r.path), term \($r.n): the binding's order does not place \($t[0])"
      elif ($t | length) - 1 != $binding.primitives[$t[0]].arity
      then "\($r.path), term \($r.n): \($t[0]) takes \($binding.primitives[$t[0]].arity) arguments, not \(($t | length) - 1)"
      else
        (path_places($t[0])[] | . as $i
         | select($t[$i] | canonical | not)
         | "\($r.path), term \($r.n): \($t[$i]) is not an absolute, canonical path"),
        ([$binding.primitives[$t[0]] | .. | objects | select(has("map") and has("arg"))] | unique[] | . as $m
         | select(($m.map | has($t[$m.arg])) | not)
         | "\($r.path), term \($r.n): \($t[$m.arg]) is not one of \($m.map | keys | join(", "))"),
        ($binding.primitives[$t[0]].seat // empty | .argv as $a
         | ($t[$a] | try fromjson catch null) as $argv
         | if ($argv | type) != "array" or ($argv | length) < 1 or ([$argv[] | type] | unique) != ["string"]
           then "\($r.path), term \($r.n): the command is not a JSON list of strings with a program first"
           elif ($argv[0] | startswith("/")) and ($argv[0] | canonical | not)
           then "\($r.path), term \($r.n): the program \($argv[0]) is not a canonical path"
           elif (($argv[0] | startswith("/") | not) and ($argv[0] | contains("/"))) or ($argv[0] | contains("=")) or ($argv[0] | startswith("-")) or $argv[0] == ""
           then "\($r.path), term \($r.n): the program \($argv[0]) is neither an absolute path nor a bare name"
           else empty end),
        ([$binding.primitives[$t[0]].require // [] | .[] | select(.[0] == "name" and (.[1] | has("arg")))] | .[] | $t[.[1].arg] as $v
         | select($v == "" or ($v | contains("/")) or ($v | startswith("-")))
         | "\($r.path), term \($r.n): '\($v)' is not a name: empty, holding a /, or beginning with -")
      end;
  def structure_problems:
    ($binding.structure // {}) as $s
    | [terms[] | .term] as $all
    | def keyed($p; $pos): [$all[] | select(.[0] == $p) | [.[$pos[]]]];
      (($s["exactly-one"] // [])[] | . as $p | [$all[] | select(.[0] == $p)] | length as $n
       | select($n != 1) | "the plan holds \($n) \($p) terms; it needs exactly one"),
      (($s["unique-keys"] // [])[] | . as [$p, $pos] | keyed($p; $pos) | group_by(.) | map(select(length > 1))[]
       | "the plan holds \(length) \($p) terms for \(.[0] | join("/")); one is allowed"),
      (($s.requires // [])[] | . as [$p, $pos, $q, $qpos] | keyed($q; $qpos) as $have
       | keyed($p; $pos) | unique[] | select(. as $k | $have | index([$k]) | not)
       | "the \($p) term for \(join("/")) has no \($q) term");
  def unique_problems:
    ($binding.unique // [])[] | . as $u
    | [terms[] | .term | select(.[0] == $u[0]) | .[$u[1]]] | group_by(.) | map(select(length > 1))[]
    | "the name \(.[0]) is given to \(length) of the \($u[0]) terms; it must be unique";
  def seat_keys: [terms[] | .term | select(.[0] == "pane") | .[1:4]];
  def table_problems:
    seat_keys as $seats
    | $binding.tables | to_entries[] | .key as $name | .value as $spec | source_rows($spec) as $rows
    | if ($rows | type) != "array" then "the plan's state cell \($spec.cell) is not a list"
      else
        ($rows | to_entries[] | .key as $i | .value as $row
         | if ($row | type) != "object" or ($row.key | strings_list | not) or ($row.key | length) != 4
           then "state \($spec.cell), row \($i + 1): the key is not four strings"
           elif ($row.value | strings_list | not) or ($row.value | length) != 1
           then "state \($spec.cell), row \($i + 1): the value is not one string"
           elif ($seats | index([$row.key[0:3]])) == null
           then "state \($spec.cell), row \($i + 1): \($row.key[0:3] | join("/")) is not a seat the plan makes"
           elif ($spec | has("states")) and (($spec.states | has($row.value[0])) | not)
           then "state \($spec.cell), row \($i + 1): \($row.value[0]) is not one of \($spec.states | keys | join(", "))"
           elif ($spec | has("states")) and (($row.key[3] | canonical) | not)
           then "state \($spec.cell), row \($i + 1): \($row.key[3]) is not an absolute, canonical path"
           elif ($spec | has("name")) and (($row.key[3] | test($spec.name)) | not)
           then "state \($spec.cell), row \($i + 1): \($row.key[3]) is not a variable name"
           else empty end),
        (if $spec | has("root") then
           ($rows | group_by(.key[0:3])[] | . as $seat | ($seat[0].key[0:3] | join("/")) as $who
            | (if any($seat[]; .key[3] == $spec.root) | not then "the view of \($who) has no row for \($spec.root)" else empty end),
              ([$seat[] | . as $r | $seat[]
                | select(.value[0] == $spec.hides and $r.value[0] != $spec.hides and beneath($r.key[3]; .key[3]))
                | "\($r.key[3]) (\($r.value[0])) lies beneath \(.key[3]) (\(.value[0]))"]
               | if length > 0 then "the view of \($who) is refused whole: \(join("; "))" else empty end))
         else empty end)
      end;
  def identity_problems:
    ([$binding.tables[] | (.["after-rows"] // [])[] | (.environment // [])[] | .[0]] | unique) as $names
    | [($folded[0].seats // [])[] | select(.key.state? == "held") | .seat] as $holders
    | $binding.tables[] | select(has("name")) | . as $spec
    | source_rows($spec)[]
    | .key[0:3] as $s | .key[3] as $n
    | select(($holders | index([$s])) != null and ($names | index($n)) != null)
    | "state \($spec.cell): \(.key[0:3] | join("/")) holds a key, and its environment may not set \(.key[3]), which the frame gives (\(.origin.path // "?"):\(.origin.line // "?"))";
  def problems:
    path_problems($binding),
    (if any($binding.tables[]; folded($plan; .)) and $folded[0] == null
     then "the plan holds statements, clearances or labels, and no folded view was given with it" else empty end),
    (if (.status | type) != "string" or (.status | IN("ok", "unchecked") | not)
     then "the plan's status is \(.status // "absent"), not ok or unchecked" else empty end),
    (if [.. | strings | explode[] | select(. < 32 or . == 127)] | length > 0
     then "the plan holds a control character" else empty end),
    (.programs | to_entries[] | .key as $i | .value
     | if type != "object" or (.path | type) != "string" then "program \($i + 1) has no path"
       elif (.plan | type) != "array" then "\(.path): the plan is not a list"
       else empty end);
  if type != "object" or (.programs | type) != "array"
  then {errors: ["the plan is not a root plan: it has no programs list"]}
  else
    [problems] as $first
    | if ($first | length) > 0 then {errors: $first}
      else
        [term_problems, unique_problems, structure_problems, table_problems, identity_problems] as $errors
        | if ($errors | length) > 0 then {errors: $errors}
          else
            {errors: [],
             programs: ([$binding.tables[] | select((source_rows(.) | length) > 0) | .programs // [] | .[]] | unique),
             terms: (terms | length),
             name: ([terms[] | .term | select(.[0] == $binding.name.term) | .[$binding.name.arg]] | first // null),
             tables: ($binding.tables | with_entries(.value = source_rows(.value))),
             must_exist: [$binding.tables[] | select(has("must-exist")) | . as $spec
                          | source_rows($spec)[] | select(.value[0] as $v | $spec["must-exist"] | index($v)) | .key[3]] | unique,
             must_be_directory: [$binding.tables[] | select(has("directory-states")) | . as $spec
                          | source_rows($spec)[] | select(.key[3] != $spec.root)
                          | select(.value[0] as $v | $spec["directory-states"] | index($v)) | .key[3]] | unique,
             requires: [terms[] | .term as $t | ($binding.primitives[$t[0]].require // [])[]
                        | select(.[0] != "name") | select(.[1] | has("path")) | [.[0], $t[.[1].path]]] | unique}
          end
      end
  end
