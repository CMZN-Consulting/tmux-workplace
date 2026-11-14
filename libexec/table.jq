def holds($plan; $word):
  any($plan | if type == "object" then .programs[]? else empty end | .recorded[]?; (.term | type) == "array" and .term[0] == $word);

def folded($plan; $spec):
  any(($spec.fold // [])[]; holds($plan; .));

def table_rows($plan; $view; $spec):
  if folded($plan; $spec) then ($view.rows // [])
  else ($plan | if type == "object" and (.state | type) == "object" then (.state[$spec.cell] // []) else [] end) end;

def path_fault:
  if type != "string" then "it is not text"
  elif . == "" then "it is empty"
  elif . == "." or . == "/" then null
  elif endswith("/") then "it ends in a slash"
  elif ((if startswith("/") then .[1:] else . end) | split("/") | any(. == "")) then "it has an empty component"
  elif ((if startswith("/") then .[1:] else . end) | split("/") | any(. == "." or . == "..")) then "it has a . or .. component"
  else null end;

def joined_path($root):
  if startswith("/") then . elif . == "." then $root elif $root == "/" then "/" + . else $root + "/" + . end;

def term_places($binding; $word):
  [($binding.primitives[$word] // {}) | .. | objects | select(has("path")) | .path] | unique;

def command_place($binding; $word):
  ($binding.primitives[$word] // {}).seat.argv // null;

def relative_program: type == "string" and contains("/") and (startswith("/") | not);

def path_problems($binding):
  ($binding.paths.recorded // {}) as $recorded
  | ($binding.paths.cells // {}) as $cells
  | def at($o; $file): "\($o.path // $file):\($o.line // "?")";
    def bare($t): if type == "object" and has("term") then .term else . end;
    def word: type == "array" and length > 0 and (.[0] | type) == "string";
    (.programs // [] | .[] | select(type == "object") | (.path // "a program") as $file
     | ((.plan // []) | to_entries[] | (.key + 1) as $n | (.value | bare(.)) as $t | select($t | word)
        | ((term_places($binding; $t[0])[] | select(. < ($t | length))) as $i
           | $t[$i] | path_fault as $fault | select($fault != null)
           | "\($file), term \($n) (\($t[0])): the path \($t[$i] | tojson) is refused: \($fault)"),
          (command_place($binding; $t[0]) // empty | . as $a | select($a < ($t | length))
           | ($t[$a] | try fromjson catch null) as $argv
           | select(($argv | type) == "array" and ($argv[0] | type) == "string" and ($argv[0] | contains("/")))
           | $argv[0] | path_fault as $fault | select($fault != null)
           | "\($file), term \($n) (\($t[0])): the program \($argv[0] | tojson) is refused: \($fault)")),
       ((.recorded // [])[] | select(type == "object" and (.term | word)) | .term as $t | (.origin // {}) as $o
        | ($recorded[$t[0]] // [])[] | select(. < ($t | length)) | $t[.] as $v
        | $v | path_fault as $fault | select($fault != null)
        | "\(at($o; $file)) (\($t[0])): the path \($v | tojson) is refused: \($fault)")),
    (. as $plan
     | if ($plan.state | type) == "object" then
       $cells | to_entries[] | .key as $cell | .value as $places
       | ($plan.state[$cell] // [] | if type == "array" then .[] else empty end) as $row
       | select(($row | type) == "object" and ($row.key | type) == "array")
       | $places[] | select(. < ($row.key | length)) | $row.key[.] as $v
       | $v | path_fault as $fault | select($fault != null)
       | "\(at($row.origin // {}; "the plan")) (state \($cell)): the path \($v | tojson) is refused: \($fault)"
       else empty end);

def clone_problems($binding; $clone):
  def inside: type == "string" and (. == $clone or startswith(if $clone == "/" then "/" else $clone + "/" end));
  def at($o; $file): "\($o.path // $file):\($o.line // "?")";
  def bare: if type == "object" and has("term") then .term else . end;
  ($binding.directories // {}) as $d
  | (.programs // [])[] | select(type == "object") | (.path // "a program") as $file
  | ((.plan // []) | to_entries[] | (.key + 1) as $n | (.value | bare) as $t
     | select(($t | type) == "array" and ($t[0] | type) == "string")
     | ($binding.primitives[$t[0]].seat // null) as $seat | select($seat != null)
     | (($seat.directory.path? // empty) | select(. < ($t | length)) | $t[.] | select(inside)
        | "\($file), term \($n) (\($t[0])): the seat's directory \(.) lies in the clone \($clone), which the frame masks in every view"),
       (($seat.argv // empty) | select(. < ($t | length)) | ($t[.] | try fromjson catch null)
        | select(type == "array") | .[0] | select(inside)
        | "\($file), term \($n) (\($t[0])): the seat's program \(.) lies in the clone \($clone), which the frame masks in every view")),
    ((.recorded // [])[] | select(type == "object" and (.term | type) == "array" and .term[0] == $d.recorded)
     | .term[$d.path] as $p | select($p | inside)
     | "\(at(.origin // {}; $file)) (\($d.recorded)): the seat's directory \($p) lies in the clone \($clone), which the frame masks in every view");

def key_fault:
  if type != "string" then "it is not text"
  elif . == "" then "it is empty"
  elif . == "-" then "it is -, which the terms write for a key that a scope does not use"
  elif . == "." or . == ".." then "it is \(.)"
  elif startswith("-") then "it begins with -"
  elif contains("/") then "it holds a /"
  elif (explode | any(. < 32 or (. >= 127 and . < 160))) then "it holds a control character"
  elif (explode | any(. == 32 or . == 160 or . == 5760 or (. >= 8192 and . <= 8202) or . == 8232 or . == 8233 or . == 8239 or . == 8287 or . == 12288 or . == 65279))
  then "it holds white space"
  else null end;

def plan_terms:
  [(.programs // [])[] | select(type == "object") | (.path // "a program") as $file
   | (.plan // []) | to_entries[] | {file: $file, n: (.key + 1), term: (.value | if type == "object" and has("term") then .term else . end)}
   | select((.term | type) == "array" and (.term[0] | type) == "string")];

def term_at: "\(.file), term \(.n)";

def key_problems($binding):
  ($binding.keys // {}) as $places
  | def at($o): "\($o.path // "the plan"):\($o.line // "?")";
    (plan_terms[] | . as $r | ($places[$r.term[0]] // [])[] | select(. < ($r.term | length)) | $r.term[.] as $v
     | ($v | key_fault) as $fault | select($fault != null)
     | "\($r | term_at) (\($r.term[0])): the key \($v | tojson) is refused: \($fault)"),
    (if (.state | type) == "object" then
       ((.state["seat-kinds"] // [])[] | select(type == "object") | . as $row | ($row.value[0]? // null) as $v
        | select($v != null and $v != "none") | ($v | key_fault) as $fault | select($fault != null)
        | "\(at($row.origin // {})) (state seat-kinds): the kind \($v | tojson) is refused: \($fault)"),
       ((.state.kinds // [])[] | select(type == "object") | . as $row | ($row.key[0]? // null) as $v
        | select($v != null and $v != "none") | ($v | key_fault) as $fault | select($fault != null)
        | "\(at($row.origin // {})) (state kinds): the kind \($v | tojson) is refused: \($fault)")
     else empty end);

def name_fault:
  if type != "string" then "it is not text"
  elif . == "" then "it is empty"
  elif . == "." or . == ".." then "it is \(.)"
  elif startswith(".") then "it begins with ., and the seat's directories in the store and the records are named by it"
  elif contains("/") then "it holds a /"
  elif contains(",") then "it holds a comma, and a mail's head separates its readers by commas"
  elif (explode | any(. < 32 or (. >= 127 and . < 160))) then "it holds a control character"
  elif test("^\\s|\\s$") then "it begins or ends with white space"
  else null end;

def name_problems($binding):
  plan_terms[] | . as $r | ($binding.unique // [])[] | select(.[0] == $r.term[0] and .[1] < ($r.term | length))
  | $r.term[.[1]] as $v | ($v | name_fault) as $fault | select($fault != null)
  | "\($r | term_at) (\($r.term[0])): the seat's name \($v | tojson) is refused: \($fault)";

def unique_problems($binding):
  plan_terms as $terms
  | ($binding.unique // [])[] | . as [$word, $pos]
  | [$terms[] | select(.term[0] == $word and (.term | length) > $pos)] | group_by(.term[$pos])[] | select(length > 1)
  | "the name \(.[0].term[$pos]) is given to \(length) of the \($word) terms; it must be unique (\(map(term_at) | join("; ")))";

def floors_problems($binding):
  ($binding.structure.floors // null) as $fs
  | select($fs != null)
  | plan_terms as $all
  | def of($w): [$all[] | select(.term[0] == $fs[$w])];
    of("floor") as $floors | of("server") as $servers | of("workplace") as $workplaces
  | of("house") as $houses | of("session") as $sessions | of("window") as $windows
  | [$floors[] | select(.term[$fs.houses] == "offices") | .term[$fs.key]] as $office_floors
  | [$floors[] | select(.term[$fs.houses] == "rooms") | .term[$fs.key]] as $room_floors
  | ([$sessions[] | .term[1]] + [$houses[] | .term[2]] | unique) as $offices
  | if ($floors | length) == 0 then
      (($workplaces + $houses)[] | "\(.term[0]) speaks only in a plan with floors, and this plan holds none (\(term_at))")
    else
      (if ($servers | length) > 0
       then "the plan holds \($servers | length) server terms and \($floors | length) floor terms: a plan holds one server and no floor, or no server, one workplace and at least one floor" else empty end),
      (if ($workplaces | length) != 1 then "the plan holds \($workplaces | length) workplace terms, and with floors it holds exactly one" else empty end),
      ($floors | group_by(.term[$fs.key])[] | select(length > 1)
       | "the floor \(.[0].term[$fs.key]) is declared \(length) times (\(map(term_at) | join("; ")))"),
      ($floors[] | select(.term[$fs.smallest] | test("^[1-9][0-9]*x[1-9][0-9]*$") | not)
       | "the floor \(.term[$fs.key]) says smallest \(.term[$fs.smallest] | tojson): COLSxROWS (\(term_at))"),
      ($houses[] | select(.term[1] as $f | $office_floors | index($f) | not)
       | "the house of \(.term[2]) names the floor \(.term[1]), \(if (.term[1] as $f | $room_floors | index($f)) != null then "which houses no offices" else "which the plan does not make" end) (\(term_at))"),
      ($houses | group_by(.term[2])[] | select(length > 1)
       | "the office \(.[0].term[2]) stands in \(length) houses, and it stands in one (\(map(term_at) | join("; ")))"),
      ($sessions[] | select(.term[1] as $a | ($room_floors | index($a) | not) and ([$houses[].term[2]] | index($a) | not))
       | "the office \(.term[1]) stands on no floor: with floors every session stands in a house (\(term_at))"),
      ($sessions[] | select(.term[1] as $a | $room_floors | index($a))
       | "the floor \(.term[1]) houses rooms, and the plan holds a session or a house for it (\(term_at))"),
      ($offices[] as $k | select([$floors[].term[$fs.key]] | index($k))
       | "the key \($k) names a floor and an office (\(([$floors[] | select(.term[$fs.key] == $k)] + [($sessions + $houses)[] | select(.term[1] == $k or .term[2] == $k)]) | map(term_at) | unique | join("; ")))"),
      ($office_floors[] as $f | select([$houses[] | select(.term[1] == $f)] | length == 0)
       | "the floor \($f) holds no office and no room"),
      ($room_floors[] as $f | select([$windows[] | select(.term[1] == $f)] | length == 0)
       | "the floor \($f) holds no office and no room")
    end;

def structure_problems($binding):
  ($binding.structure // {}) as $s
  | plan_terms as $all
  | ($s.floors // null) as $fs
  | ([$all[] | select($fs != null and .term[0] == $fs.floor)] | length > 0) as $floored
  | def keyed($p; $pos): [$all[] | select(.term[0] == $p) | . + {k: [.term[$pos[]]]}];
    def standing($p; $pos): keyed($p; $pos)
      + (if $fs != null and $p == $fs.session
         then [$all[] | select(.term[0] == $fs.floor and .term[$fs.houses] == "rooms") | . + {k: [.term[$fs.key]]}] else [] end);
    floors_problems($binding),
    (($s["exactly-one"] // [])[] | select($floored | not) | . as $p | [$all[] | select(.term[0] == $p)] as $have
     | select(($have | length) != 1)
     | "the plan holds \($have | length) \($p) terms; it needs exactly one\(if ($have | length) > 1 then " (\($have | map(term_at) | join("; ")))" else "" end)"),
    (($s["unique-keys"] // [])[] | . as [$p, $pos] | keyed($p; $pos) | group_by(.k) | map(select(length > 1))[]
     | "the plan holds \(length) \($p) terms for \(.[0].k | join("/")); one is allowed (\(map(term_at) | join("; ")))"),
    (($s.requires // [])[] | . as [$p, $pos, $q, $qpos] | [standing($q; $qpos)[].k] as $have
     | keyed($p; $pos) | group_by(.k)[] | select(.[0].k as $k | $have | index([$k]) | not)
     | "the \($p) term for \(.[0].k | join("/")) has no \($q) term (\(map(term_at) | join("; ")))");

def term_paths($word): [(.programs // [])[] | select(type == "object") | (.recorded // [])[] | select(type == "object" and (.term | type) == "array" and .term[0] == $word and (.term | length) == 2) | .term[1] | strings] | unique;

def mail_paths: term_paths("mail");

def shown_path_problems($binding; $clone; $word; $what; $where):
  . as $plan
  | term_paths($word) as $paths
  | if ($paths | length) == 0 then empty
    else
      def under($p; $q): $q == "/" or $p == $q or ($p | startswith($q + "/"));
      def at($o; $file): "\($o.path // $file):\($o.line // "?")";
      def term_of($p):
        "(the \($word) at \([($plan.programs // [])[] | select(type == "object") | (.path // "a program") as $file | (.recorded // [])[]
                               | select(type == "object" and (.term | type) == "array" and .term[0] == $word and (.term | length) == 2 and .term[1] == $p)
                               | at(.origin // {}; $file)] | join(", ")))";
      ($binding.directories // {}) as $d
      | ($paths[] | select(under(.; $clone))
         | "the \($what) \(.) lies at or beneath the clone \($clone), which the frame masks in every view \(term_of(.))"),
        ($paths[] | select(. == "/") | "the \($what) / would cover each seat's whole view \(term_of(.))"),
        ($paths[] | select(. != "/") as $m
         | ($plan | plan_terms[] | . as $r | ($binding.primitives[$r.term[0]].seat // null) as $seat | select($seat != null)
            | (($seat.directory.path? // empty) | select(. < ($r.term | length)) | $r.term[.] | select(type == "string" and under(.; $m))
               | "\($r | term_at) (\($r.term[0])): the seat's directory \(.) lies at or beneath the \($what) \($m), \($where) \(term_of($m))"),
              (($seat.argv // empty) | select(. < ($r.term | length)) | ($r.term[.] | try fromjson catch null)
               | select(type == "array") | .[0] | select(type == "string" and startswith("/") and under(.; $m))
               | "\($r | term_at) (\($r.term[0])): the seat's program \(.) lies at or beneath the \($what) \($m), \($where) \(term_of($m))")),
           (($plan.programs // [])[] | select(type == "object") | (.path // "a program") as $file | (.recorded // [])[]
            | select(type == "object" and (.term | type) == "array" and .term[0] == $d.recorded and (.term | length) > $d.path)
            | .term[$d.path] as $p | select(($p | type) == "string" and under($p; $m))
            | "\(at(.origin // {}; $file)) (\($d.recorded)): the seat's directory \($p) lies at or beneath the \($what) \($m), \($where) \(term_of($m))"))
    end;

def mail_problems($binding; $clone):
  shown_path_problems($binding; $clone; "mail"; "mail path"; "where the frame shows each seat its mailbox"),
  shown_path_problems($binding; $clone; "record-path"; "record path"; "where the frame shows a seat the records it may read");

def seat_names($plan):
  [($plan | if type == "object" then .programs[]? else empty end) | select(type == "object") | (.plan // [])[]
   | (if type == "object" and has("term") then .term else . end)
   | select(type == "array" and length > 4 and .[0] == "pane") | {key: (.[1:4] | tojson), value: .[4]}] | from_entries;

def chain_mask_problems($binding; $plan; $view; $masks):
  def inside($m): type == "string" and (. == $m or startswith(if $m == "/" then "/" else $m + "/" end));
  def at($o): "\($o.path // "?"):\($o.line // "?")";
  if ($masks | length) == 0 then empty
  else
    seat_names($plan) as $names
    | $binding.tables.view as $spec
    | table_rows($plan; $view; $spec)[]
    | select(type == "object" and (.key | type) == "array" and (.value[0]? != "hidden")) | . as $row
    | $masks[] as $m | select($row.key[3] | inside($m)) | $m
    | "seat \($names[$row.key[0:3] | tojson] // "?") (\($row.key[0:3] | join("/"))): \($row.key[3]) (\($row.value[0]?), from \([($row.origins // [$row.origin // {}])[] | at(.)] | join(", "))) lies at or beneath \(.), which the frame hides in every view of a workplace that keeps a chain, as a hidden row would"
  end;

def runtime_row_problems($binding; $plan; $view; $runtime):
  def inside: type == "string" and (. == $runtime or startswith($runtime + "/"));
  def at($o): "\($o.path // "?"):\($o.line // "?")";
  seat_names($plan) as $names
  | $binding.tables.view as $spec
  | table_rows($plan; $view; $spec)[]
  | select(type == "object" and (.key | type) == "array" and (.key[3] | inside) and (.value[0]? == "read-only" or .value[0]? == "read-write"))
  | "seat \($names[.key[0:3] | tojson] // "?") (\(.key[0:3] | join("/"))): \(.key[3]) (\(.value[0]), from \([(.origins // [.origin // {}])[] | at(.)] | join(", "))) lies at or beneath \($runtime), the user's runtime directory, which the frame shows to no seat as the machine has it; a row there may be hidden, searchable-only or scratch";

def clone_row_problems($binding; $plan; $view; $clone):
  def inside: type == "string" and (. == $clone or startswith(if $clone == "/" then "/" else $clone + "/" end));
  def at($o): "\($o.path // "?"):\($o.line // "?")";
  seat_names($plan) as $names
  | $binding.tables.view as $spec
  | table_rows($plan; $view; $spec)[]
  | select(type == "object" and (.key | type) == "array" and (.key[3] | inside) and (.value[0]? != "hidden"))
  | "seat \($names[.key[0:3] | tojson] // "?") (\(.key[0:3] | join("/"))): \(.key[3]) (\(.value[0]?), from \([(.origins // [.origin // {}])[] | at(.)] | join(", "))) lies at or beneath the clone \($clone), which the frame hides in every view as a hidden row would";

def given_problems($binding; $plan; $view):
  ($binding["kept-names"] // []) as $kept
  | (($view // {}).seats // []) as $seats
  | seat_names($plan) as $names
  | def at($o): "\($o.path // "?"):\($o.line // "?")";
    def ats($os): [$os[] | at(.)] | join(", ");
    def who($k): "\($names[$k | tojson] // "?") (\($k | join("/")))";
    def given($seat):
      (if $seat.key.state? == "held" then [$kept[] | {name: ., by: "holds a key", what: "the key", origins: $seat.key.origins}] else [] end)
      + (if $seat.home != null
         then [{name: $seat.home.variable, by: "has a home", what: "the home", origins: $seat.home.origins}]
              + [$seat.home.variables[] | {name, by: "has a home", what: "the home variable", origins}]
         else [] end);
    ($binding.tables[] | select(has("name")) | . as $spec
     | table_rows($plan; $view; $spec)[] | . as $row
     | ($seats[] | select(.seat == $row.key[0:3])) as $seat
     | (given($seat) | map(select(.name == $row.key[3])) | first) as $g
     | if $g != null then
         "state \($spec.cell): \(who($row.key[0:3])) \($g.by), and its environment may not set \($row.key[3]), which the frame gives (the row at \(at($row.origin // {})); \($g.what) at \(ats($g.origins)))"
       else
         (($seat.expects // [])[] | select(.name == $row.key[3])
          | "state \($spec.cell): \(who($row.key[0:3])) expects the value \($row.key[3]) at its start, and its environment may not set it (the row at \(at($row.origin // {})); the expect at \(ats(.origins)))")
       end);

def joined($binding; $root):
  ($binding.paths.recorded // {}) as $recorded
  | ($binding.paths.cells // {}) as $cells
  | def join_one: if type == "string" and path_fault == null then joined_path($root) else . end;
    def word: type == "array" and length > 0 and (.[0] | type) == "string";
    def join_term:
      if word then
        .[0] as $w
        | reduce (term_places($binding; $w)[]) as $i (.; if $i < length then .[$i] |= join_one else . end)
        | command_place($binding; $w) as $a
        | if $a != null and $a < length then
            (.[$a] | try fromjson catch null) as $argv
            | if ($argv | type) == "array" and ($argv[0] | relative_program) and ($argv[0] | path_fault) == null
              then .[$a] = ($argv | .[0] |= joined_path($root) | tojson) else . end
          else . end
      else . end;
    def join_record:
      if word then .[0] as $w | reduce (($recorded[$w] // [])[]) as $i (.; if $i < length then .[$i] |= join_one else . end)
      else . end;
    if type == "object" and (.programs | type) == "array" then
      .programs |= map(
        if type != "object" then .
        else
          (if (.plan | type) == "array" then .plan |= map(if type == "object" and has("term") then .term |= join_term else join_term end) else . end)
          | (if (.recorded | type) == "array" then .recorded |= map(if type == "object" and has("term") then .term |= join_record else . end) else . end)
        end)
      | if (.state | type) == "object" then
          reduce ($cells | to_entries[]) as $c (.;
            if (.state[$c.key] | type) == "array" then
              .state[$c.key] |= map(
                if type == "object" and (.key | type) == "array" then
                  reduce $c.value[] as $i (.; if $i < (.key | length) then .key[$i] |= join_one else . end)
                else . end)
            else . end)
        else . end
    else . end;
