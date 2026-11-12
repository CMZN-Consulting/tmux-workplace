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

def seat_names($plan):
  [($plan | if type == "object" then .programs[]? else empty end) | select(type == "object") | (.plan // [])[]
   | (if type == "object" and has("term") then .term else . end)
   | select(type == "array" and length > 4 and .[0] == "pane") | {key: (.[1:4] | tojson), value: .[4]}] | from_entries;

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
    ($seats[] | select(.home != null) | . as $s
     | ([.home.kind] + .seat | unique[]) | select(. == "" or . == "." or . == ".." or contains("/"))
     | "seat \(who($s.seat)): its home is named by its kind and its keys, \($s.home.kind)/\($s.seat | join("/")), and \(tojson) cannot be one directory of that name"),
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
