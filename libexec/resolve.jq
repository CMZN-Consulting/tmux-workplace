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
  def absolute:
    if startswith("/") then . else error("\($term[0]): \(.) is not an absolute path") end;
  def beneath($p; $q): ($q == "/" and $p != "/") or ($p | startswith($q + "/"));
  def resolve($e; $st):
    if ($e | type) == "string" then [{v: $e, lit: true}]
    elif ($e | type) != "object" then error("the binding of \($term[0]) holds an element that is neither a string nor an object")
    elif $e | has("arg") then [{v: (arg($e.arg) | modify($e)), lit: false}]
    elif $e | has("path") then [{v: (arg($e.path) | absolute | modify($e)), lit: false}]
    elif $e | has("slot") then
      key($e.slot) as $k
      | if ($st.slots | has($k)) then [{v: ($st.slots[$k] | modify($e)), lit: false}]
        else error("\($term[0]): no slot \(shown($e.slot))") end
    elif $e | has("file") then [{v: ($build + "/" + $e.file), lit: false}]
    elif $e | has("concat") then [{v: ([$e.concat[] | resolve(.; $st)[].v] | join("")), lit: false}]
    else error("the binding of \($term[0]) holds an element of no known kind") end;
  def resolve_all($elems; $st): [$elems[] | resolve(.; $st)[]];
  def one($e; $st): resolve($e; $st)[0].v;
  def encode($p):
    if $p | has("escape-last") then
      $p["escape-last"] as $x
      | map(if .lit or (.v | endswith($x) | not) then .v
            else (.v | .[0:(length - ($x | length))]) + "\\" + $x end)
    else map(.v) end;
  def program($n): $binding.programs[$n] // error("the binding names no program \($n)");
  def call($elems; $st):
    program($elems[0]) as $p
    | (resolve_all($p.argv; $st) | map(.lit = true)) + resolve_all($elems[1:]; $st) | encode($p);
  def after_rows($spec; $st):
    [($spec["after-rows"] // [])[]
     | select((if has("if-slot") then ($st.slots[key(.["if-slot"])] // "") != "" else true end)
              and (if has("unless-slot") then ($st.slots[key(.["unless-slot"])] // "") == "" else true end))];
  def view_args($spec; $k; $directory; $st):
    [($tables[$spec.cell] // [])[] | select(.key[0:3] == $k) | {path: .key[3], state: .value[0]}] as $rows
    | if ($rows | length) == 0 then []
      else
        ($rows | map(select(.path == $spec.root))) as $root
        | if ($root | length) != 1 then error("\($term[0]): the view of \($k | join("/")) has no row for \($spec.root)") else . end
        | [$rows[] | . as $r | $rows[]
           | select(.state == $spec.hides and $r.state != $spec.hides and beneath($r.path; .path))
           | "\($r.path) (\($r.state)) lies beneath \(.path) (\(.state))"] as $contradictions
        | if ($contradictions | length) > 0
          then error("\($term[0]): the view of \($k | join("/")) is refused whole: \($contradictions | join("; "))")
          else . end
        | ($rows | map(select(.path != $spec.root)) | sort_by(.path)) as $rest
        | def emit($r):
            ($spec.states[$r.state] // error("\($term[0]): no state \($r.state)"))
            | map(if type == "object" and has("row") then $r[.row] else . end);
          [(resolve_all($spec.head; $st) | map(.v))[],
           emit($root[0])[],
           $spec["after-root"][],
           ($rest[] | emit(.)[]),
           (after_rows($spec; $st)[]
            | (resolve_all(.args; $st)[] | .v),
              (if has("ro-bind-pairs") then (one(.["ro-bind-pairs"]; $st) | fromjson[] | "--ro-bind", .[0], .[1]) else empty end),
              (resolve_all(.["args-after"] // []; $st)[] | .v)),
           ($spec.tail[] | if type == "object" and has("seat") then $directory else . end)]
      end;
  def seat_record($s; $st):
    one($s.name; $st) as $name
    | name($s.key) as $k
    | one($s.directory; $st) as $directory
    | (arg($s.argv) | try fromjson catch error("\($term[0]): argument \($s.argv) is not JSON")) as $argv
    | if ($argv | type) != "array" or ($argv | length) < 1 or ([$argv[] | type] | unique) != ["string"]
      then error("\($term[0]): argument \($s.argv) is not a list of strings with a program first") else . end
    | if ($argv[0] | contains("=")) or (($argv[0] | contains("/")) and ($argv[0] | startswith("/") | not)) or $argv[0] == ""
      then error("\($term[0]): the program \($argv[0]) is neither an absolute path nor a bare name, or it holds =") else . end
    | $binding.tables[$s.view] as $vspec
    | $binding.tables[$s.environment] as $espec
    | {name: $name, key: $k, directory: $directory,
       command: (view_args($vspec; $k; $directory; $st) + $argv),
       environment: ([($tables[$espec.cell] // [])[] | select(.key[0:3] == $k) | [.key[3], .value[0]]]
                     + (if ([($tables[$vspec.cell] // [])[] | select(.key[0:3] == $k)] | length) > 0
                        then [after_rows($vspec; $st)[]
                              | ((.environment // [])[] | [.[0], one(.[1]; $st)]),
                                (.["environment-pairs"] // empty | one(.; $st) | fromjson[])]
                        else [] end)),
       expects: (($st.slots[key(["expects"] + $s.key)] // "[]") | fromjson),
       values: ($st.slots[key(["values-file"])] // ""),
       view: ([($tables[$vspec.cell] // [])[] | select(.key[0:3] == $k)] | length)};
  def phase_call:
    entry as $e
    | if nargs != $e.arity then error("\($term[0]) takes \($e.arity) arguments, and the term has \(nargs)") else . end
    | reduce ($e.set // [])[] as $s ($st; .slots[key($s[0])] = one($s[1]; .))
    | . as $s1
    | [($e.require // [])[] | [.[0], one(.[1]; $s1)]] as $req
    | (if ($e | has("claim")) and ($s1.slots | has(key($e.claim.slot))) then
         {argv: call($e.claim.call; $s1), st: ($s1 | .slots |= del(.[key($e.claim.slot)])), claimed: shown($e.claim.slot)}
       elif $e | has("call") then {argv: call($e.call; $s1), st: $s1, claimed: ""}
       else {argv: [], st: $s1, claimed: ""} end) as $c
    | (if $e | has("seat") then seat_record($e.seat; $s1) | tojson else "" end) as $seat
    | ["ok", ($c.st | tojson), ($req | length | tostring)] + ($req | flatten)
      + [($c.argv | length | tostring)] + $c.argv
      + [(($e.capture // []) | length | tostring), $seat, $c.claimed]
    | .[];
  def phase_after:
    entry as $e
    | ($e.capture // []) as $cn
    | if ($caps | length) != ($cn | length)
      then error("\($term[0]) printed \($caps | length) values, and the binding captures \($cn | length)")
      else . end
    | reduce range(0; $cn | length) as $i ($st; .slots[key($cn[$i])] = $caps[$i])
    | . as $s
    | [($e.verify // [])[]
       | if .[0] == "equals" then
           (one(.[1]; $s)) as $a | (one(.[2]; $s)) as $want
           | if $a == $want then empty else error("\($term[0]): \($a) where the binding requires \($want)") end
         else [.[0], one(.[1]; $s)] end] as $verify
    | def record($r):
        {what: (if $r | has("what") then [$r.what[] | if type == "object" and has("slot") then one(.; $s) else part end] | join("/") else $term[0] end),
         when: (if $r | has("when") then call($r.when; $s) else null end),
         is: (if $r | has("is") then one($r.is; $s) else null end),
         call: call($r.call; $s)};
      (if $e | has("then") then call($e.then; $s) else [] end) as $then
      | ["ok", ($s | tojson),
         (if $e | has("undo") then record($e.undo) | tojson else "" end),
         (if $e | has("check") then record($e.check) | tojson else "" end),
         ($verify | length | tostring)] + ($verify | flatten)
        + [($then | length | tostring)] + $then
      | .[];
  if $phase == "call" then phase_call
  elif $phase == "after" then phase_after
  else error("no phase \($phase)") end
