def within($p; $q): $p == $q or ($q == "/" and ($p | startswith("/"))) or ($p | startswith($q + "/"));
def below($p; $q): $p != $q and within($p; $q);
def depth: split("/") | length;
def level: {"hidden": 0, "scratch": 0, "searchable-only": 0, "read-only": 1, "read-write": 2}[.] // error("\(.) is not one of hidden, scratch, searchable-only, read-only, read-write");
def origin: [(.origins // [.origin // {}])[] | "\(.path // "?"):\(.line // "?")"] | join(", ");
def joined($parent; $tail): ($parent | rtrimstr("/")) + "/" + $tail;
def relative($p; $q): $p[(if $q == "/" then 1 else ($q | length) + 1 end):];

. as $doc
| def fact($p): $doc.facts[$p] // error("missing path metadata for \($p | tojson)");
  def terminal($r): any($doc.masks[]; .kind == "closed" and within($r.path; .path));
  def cleared($seat; $label): $label.value != "closed" and $seat.clearance != null and $seat.clearance <= ($label.value | tonumber);
  def permission($seat; $rows; $x):
    if any($doc.labels[]; .value == "closed" and fact(.path).status == "present" and within($x; .path))
       or any($doc.keys[]; fact(.path).status == "present" and within($x; .path))
       or any($doc.masks[]; within($x; .path)) then 0
    else ([$doc.labels[] | select(fact(.path).status == "present" and within($x; .path))] | max_by(.path | depth)) as $label
      | if $label != null and (cleared($seat; $label) | not) then 0
        else ([$rows[] | select(within($x; .path))] | max_by(.path | depth)) as $row
          | ([$rows[] | select((.source // "statement") == "statement" and within($x; .path))] | max_by(.path | depth)) as $statement
          | ($row.state // "hidden" | level) as $access
          | if $label != null and ($statement == null or below($label.path; $statement.path)) then [$access, 1] | min else $access end
        end
    end;
  def boundaries($rows):
    ([$doc.labels[], $doc.keys[], $doc.masks[] | .path]
     + [$rows[] | select(.path == .real) | .path]) | unique;
  def certified($bind; $cover; $target; $rows):
    below($cover.path; $bind.path) and within($target; $cover.path)
    and ($cover.real == joined($bind.real; relative($cover.path; $bind.path)))
    and (fact($cover.path).symlink | not)
    and ($bind.path == $bind.real or (any($rows[];
      below(.path; $bind.path) and below($cover.path; .path)
      and (.state | level) == 0) | not));
  def covering($bind; $p; $seat; $rows):
    joined($bind.path; relative($p; $bind.real)) as $target
    | ([$rows[] | select(below(.path; $bind.path) and within($target; .path))] | max_by(.path | depth)) as $cover
    | any($doc.masks[]; within($target; .path))
      or ($cover != null and ($cover.state | level) <= permission($seat; $rows; $p)
          and certified($bind; $cover; $target; $rows));
  def anchor_cover($row; $seat; $rows):
    any($rows[]; . as $bind | select((.state | level) > 0 and .exists and below($row.path; .path))
      | certified($bind; $row; $row.path; $rows)
        and any(boundaries($rows)[]; . as $p
          | within($p; $row.real) and below($p; $bind.real)
          and permission($seat; $rows; $p) < ($bind.state | level)));
  def who($s): "seat \($s.name) (\($s.key | join("/")))";
  def policy_name($seat; $rows; $x):
    ([$doc.keys[] | select(within($x; .path)) | "private key source \(.path | tojson) (from \(origin))"]
     + [$doc.masks[] | select(within($x; .path)) | .name]
     + [$doc.labels[] | select(fact(.path).status == "present" and within($x; .path)) | "label \(.path | tojson) = \(.value) (from \(origin))"]
     + [$rows[] | select(within($x; .path)) | "row \(.path | tojson) \(.state) (from \(origin))"]) | join("; ");
  def row_faults($seat; $rows):
    $rows[] as $r
    | if terminal($r) then empty
      elif ($r.state | level) == 0 then
        if fact($r.path).symlink then "\(who($seat)): protective row \($r.path | tojson) (\($r.state), from \($r | origin)) ends in a symbolic link"
        elif $r.exists and fact($r.path).kind != "directory" then "a view makes \($r.path) a tmpfs, and it is not a directory"
        elif $r.path != $r.real and (anchor_cover($r; $seat; $rows) | not) then
          "\(who($seat)): protective row \($r.path | tojson) leads to \($r.real | tojson) without an independently anchored projected cover"
        elif ($r.state == "scratch" or ($r.state == "searchable-only" and $r.source != "label"))
             and (any($doc.labels[]; fact(.path).status == "present" and within($r.real; .path)
                       and .value == "closed")
                  or (([$doc.labels[] | select(fact(.path).status == "present" and within($r.real; .path))] | max_by(.path | depth)) as $l
                      | $l != null and (cleared($seat; $l) | not))) then
          "\(who($seat)): protective row \($r.path | tojson) (\($r.state)) leads into a label that the seat may not open at \($r.real | tojson)"
        else empty end
      elif $r.exists then
        if ($r.state | level) > permission($seat; $rows; $r.real) then
          "\(who($seat)): row \($r.path | tojson) (\($r.state), from \($r | origin)) leads to \($r.real | tojson), whose own-name host access is \(permission($seat; $rows; $r.real)); \(policy_name($seat; $rows; $r.real)): an alias may not increase access"
        else empty end,
        (if fact($r.path).kind == "directory" then
          boundaries($rows)[] as $p
          | select(below($p; $r.real) and fact($p).status == "present")
          | select(permission($seat; $rows; $p) < ($r.state | level))
          | select(covering($r; $p; $seat; $rows) | not)
          | "\(who($seat)): row \($r.path | tojson) (\($r.state), from \($r | origin)) holds \($p | tojson) through \($r.real | tojson), exposing it at \(joined($r.path; relative($p; $r.real)) | tojson) without a final cover at host access \(permission($seat; $rows; $p)); \(policy_name($seat; $rows; $p))"
        else empty end)
      else empty end;
  ($doc.rows | map(. + {path: .key[3], state: .value[0], real: fact(.key[3]).real,
                           exists: (fact(.key[3]).status == "present")})) as $all
  | [$all | group_by(.key[0:3])[]
     | . as $rows | .[0].key[0:3] as $key
     | {key: $key, name: ($doc.names[$key | tojson] // "?"),
        clearance: ([$doc.seats[] | select(.seat == $key)][0].clearance.value // null), rows: $rows}] as $seats
  | {faults: ($doc.runtime_faults
       + [$doc.facts | to_entries[] | select(.value.status == "error")
          | "cannot inspect \(.key | tojson): \(.value.reason); an indeterminate path is refused"]
       + [((($doc.labels | map(. + {role: "label"})) + ($doc.keys | map(. + {role: "private key source"})))[])
          | if fact(.path).symlink or (fact(.path).status != "error" and .path != fact(.path).real)
            then "\(.role) \(.path | tojson) (from \(origin)) is written through a symbolic link to \(fact(.path).real | tojson)" else empty end]
       + [$seats[] | row_faults(.; .rows)]),
     labelled: [$seats[] as $s | $s.rows[] as $r
       | select(($r.source // "statement") == "statement" and ($r.state | level) > 0 and $r.exists and (terminal($r) | not))
       | $doc.labels[] | select(fact(.path).status == "present" and .value != "closed")
       | select($r.path != $r.real and (within($r.real; .path) or within(.path; $r.real)))
       | "machine alias at labelled path: \(who($s)), row \($r.path | tojson) -> \($r.real | tojson) (\($r.state), from \($r | origin)), label \(.path | tojson) = \(.value) (from \(origin))"]}
