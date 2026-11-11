$b[0] as $binding
| $t[0] as $tables
| def entry: $binding.primitives[$term[0]] // error("the binding has no primitive \($term[0])");
  def nargs: ($term | length) - 1;
  def arg($n):
    if ($n | type) != "number" or $n < 1 or $n > nargs
    then error("the binding of \($term[0]) names argument \($n), and the term has \(nargs)")
    else $term[$n] end;
  def part:
    if type == "string" then .
    elif type == "object" and has("arg") then arg(.arg)
    else error("a name in the binding of \($term[0]) holds a part that is neither a string nor an argument") end;
  def name($parts): $parts | map(part);
  def key($parts): name($parts) | tojson;
  def shown($parts): name($parts) | join("/");
  def rx: gsub("(?<c>[\\\\^$.|?*+()\\[\\]{}#-])"; "\\\(.c)");
  def modify($e):
    (if $e | has("map") then
       (. as $v | if ($e.map | has($v)) then $e.map[$v]
                  else error("\($term[0]): \($v) is not one of \($e.map | keys | join(", "))") end)
     else . end)
    | (if $e | has("double") then
         ($e.double | rx) as $d
         | (if $e | has("unless-before") then "(?![" + $d + ($e["unless-before"] | rx) + "])" else "" end) as $guard
         | gsub("(?<run>" + $d + "+)" + $guard; .run + .run)
       else . end);
  def place:
    if . == "" then error("\($term[0]): an empty path")
    elif startswith("/") then .
    else $root + "/" + . end;
  def program_path:
    if startswith("/") then . elif contains("/") then $root + "/" + . else . end;
  def lies_beneath($p; $q): $q == "/" and $p != "/" or ($p | startswith($q + "/"));
  def table_rows($tname; $k):
    ($binding.tables[$tname] // error("the binding has no table \($tname)")) as $spec
    | [($tables[$tname] // [])[] | select(.key[0:($k | length)] == $k)
       | {path: (.key[$k | length] | place), state: .value[0], from: "plan"}] as $planned
    | [($st.added[$tname] // {})[($k | tojson)] // [] | .[]] as $added
    | ($added | map(.path)) as $taken
    | ([$planned[] | select(.path as $p | $taken | index($p) | not)] + $added)
    | sort_by(.path)
    | . as $rows
    | [$rows[] | select(.path as $p | any($rows[]; .state == $spec["skip-beneath"] and lies_beneath($p; .path)) | not)];
  def resolve($e; $st):
    if ($e | type) == "string" then {vals: [{v: $e, lit: true}], st: $st}
    elif ($e | type) != "object" then error("the binding of \($term[0]) holds an element that is neither a string nor an object")
    elif $e | has("arg") then {vals: [{v: (arg($e.arg) | modify($e)), lit: false}], st: $st}
    elif $e | has("path") then {vals: [{v: (arg($e.path) | place | modify($e)), lit: false}], st: $st}
    elif $e | has("slot") then
      key($e.slot) as $k
      | if ($st.slots | has($k)) then {vals: [{v: ($st.slots[$k] | modify($e)), lit: false}], st: $st}
        else error("\($term[0]): no slot \(shown($e.slot))") end
    elif $e | has("file") then {vals: [{v: ($build + "/" + $e.file), lit: false}], st: $st}
    elif $e | has("argv") then
      (arg($e.argv) | try fromjson catch error("\($term[0]): argument \($e.argv) is not JSON")) as $a
      | if ($a | type) != "array" or ($a | length) < 1 or ([$a[] | type] | unique) != ["string"]
        then error("\($term[0]): argument \($e.argv) is not a list of strings with a program first")
        else {vals: ([{v: ($a[0] | program_path), lit: false}] + [$a[1:][] | {v: ., lit: false}]), st: $st} end
    elif $e | has("table") then
      $binding.tables[$e.table] as $spec
      | table_rows($e.table; name($e.key)) as $rows
      | if ($rows | length) == 0 then {vals: [], st: $st}
        else
          reduce ($spec.head + ([$rows[] | . as $row
            | ($spec.states[$row.state] // error("\($term[0]): the table \($e.table) has no state \($row.state)"))
            | map(if type == "object" and has("entry") then {entry: $row[.entry]} else . end)[]]) + $spec.tail)[] as $x
            ({vals: [], st: $st};
             if ($x | type) == "object" and ($x | has("entry")) then .vals += [{v: $x.entry, lit: false}]
             else resolve($x; .st) as $r | {vals: (.vals + $r.vals), st: $r.st} end)
        end
    else error("the binding of \($term[0]) holds an element of no known kind") end;
  def resolve_all($elems; $st):
    reduce $elems[] as $e ({vals: [], st: $st}; resolve($e; .st) as $r | {vals: (.vals + $r.vals), st: $r.st});
  def encode($p):
    if $p | has("escape-last") then
      $p["escape-last"] as $x
      | map(if .lit or (.v | endswith($x) | not) then .v
            else (.v | .[0:(length - ($x | length))]) + "\\" + $x end)
    else map(.v) end;
  def program($n): $binding.programs[$n] // error("the binding names no program \($n)");
  def call($elems; $st):
    program($elems[0]) as $p
    | resolve_all($p.argv + $elems[1:]; $st) as $r
    | {argv: ($r.vals | encode($p)), st: $r.st};
  def one($e; $st): resolve_all([$e]; $st).vals[0].v;
  def phase_call:
    entry as $e
    | if nargs != $e.arity then error("\($term[0]) takes \($e.arity) arguments, and the term has \(nargs)") else . end
    | reduce ($e.set // [])[] as $s ($st; .slots[key($s[0])] = one($s[1]; .))
    | . as $s1
    | [($e.require // [])[] | [.[0], one(.[1]; $s1)]] as $req
    | [($e.add // empty) | one(.target; $s1)] as $targets
    | (if $e | has("call") then call($e.call; $s1) else {argv: [], st: $s1} end) as $c
    | ["ok", ($c.st | tojson),
       (if $e | has("expect") then "1" else "0" end), ($e.expect // ""),
       ($req | length | tostring)] + ($req | flatten)
      + [($targets | length | tostring)] + $targets
      + [($c.argv | length | tostring)] + $c.argv
      + [(($e.capture // []) | length | tostring)]
    | .[];
  def phase_after:
    entry as $e
    | ($e.capture // []) as $cn
    | if ($caps | length) != ($cn | length)
      then error("\($term[0]) printed \($caps | length) values, and the binding captures \($cn | length)")
      else . end
    | reduce range(0; $cn | length) as $i ($st; .slots[key($cn[$i])] = $caps[$i])
    | . as $before
    | (if $e | has("add") then
         $e.add as $a | name($a.key) as $k | one($a.state; .) as $state
         | ($binding.tables[$a.table].states | has($state)
            or error("\($term[0]): the table \($a.table) has no state \($state)")) as $ok
         | reduce $resolved[] as $p (.;
             if any((.added[$a.table] // {})[$k | tojson] // [] | .[]; .path == $p) then .
             else .added[$a.table][$k | tojson] += [{path: $p, state: $state, from: one($a.target; .)}] end)
       else . end)
    | . as $s
    | def record($r):
        {what: (if $r | has("what") then shown($r.what) else $term[0] end),
         when: (if $r | has("when") then call($r.when; $s).argv else null end),
         is: (if $r | has("is") then one($r.is; $s) else null end),
         call: call($r.call; $s).argv};
      (if $e | has("then") then call($e.then; $s).argv else [] end) as $then
      | (if $e | has("add") then
           name($e.add.key) as $k
           | [$resolved[] | . as $p
              | select(any(($before.added[$e.add.table] // {})[$k | tojson] // [] | .[]; .path == $p) | not)
              | {what: (([$e.add.table] + $k) | join("/")), path: $p, state: one($e.add.state; $s),
                 from: one($e.add.target; $s)} | tojson]
         else [] end) as $added
      | ["ok", ($s | tojson),
         (if $e | has("undo") then record($e.undo) | tojson else "" end),
         (if $e | has("check") then record($e.check) | tojson else "" end),
         ($then | length | tostring)] + $then
        + [($added | length | tostring)] + $added
      | .[];
  if $phase == "call" then phase_call
  elif $phase == "after" then phase_after
  else error("no phase \($phase)") end
