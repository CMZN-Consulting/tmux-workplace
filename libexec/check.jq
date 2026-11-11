$b[0] as $binding
| . as $plan
| def input_state: ($plan | if type == "object" and (.state | type) == "object" then .state else {} end);
  def term: if type == "object" and .unchecked == true then .term else . end;
  def strings_list: type == "array" and ([.[] | type] | unique) == ["string"];
  def table_problems:
    $binding.tables | to_entries[] | .key as $name | .value as $spec
    | ($spec.cell) as $cell
    | (input_state[$cell] // []) as $rows
    | if ($rows | type) != "array" then "the plan's state cell \($cell) is not a list"
      else
        $rows | to_entries[] | .key as $i | .value as $row
        | if ($row | type) != "object" or ($row.key | strings_list | not) or ($row.key | length) != 4
          then "state \($cell), entry \($i + 1): the key is not four strings"
          elif ($row.value | strings_list | not) or ($row.value | length) != 1
          then "state \($cell), entry \($i + 1): the value is not one string"
          elif ($spec.states | has($row.value[0])) | not
          then "state \($cell), entry \($i + 1): \($row.value[0]) is not one of \($spec.states | keys | join(", "))"
          elif $row.key[3] == "" then "state \($cell), entry \($i + 1): an empty path"
          else empty end
      end;
  def problems:
    (if (.status | type) != "string" or (.status | IN("ok", "unchecked") | not)
     then "the plan's status is \(.status // "absent"), not ok or unchecked" else empty end),
    (if [.. | strings | explode[] | select(. < 32 or . == 127)] | length > 0
     then "the plan holds a control character" else empty end),
    (if has("state") and (.state | type) != "object" then "the plan's state is not an object" else empty end),
    (.programs | to_entries[] | .key as $i | .value as $p
     | if ($p | type) != "object" or ($p.path | type) != "string" then "program \($i + 1) has no path"
       elif ($p.plan | type) != "array" then "\($p.path): the plan is not a list"
       else
         $p.plan | to_entries[] | .key as $j | (.value | term) as $t
         | if ($t | strings_list | not) or ($t | length) < 1
           then "\($p.path), term \($j + 1): not a list of strings"
           elif ($binding.primitives | has($t[0])) | not
           then "\($p.path), term \($j + 1): the binding has no primitive \($t[0])"
           elif ($t | length) - 1 != $binding.primitives[$t[0]].arity
           then "\($p.path), term \($j + 1): \($t[0]) takes \($binding.primitives[$t[0]].arity) arguments, not \(($t | length) - 1)"
           else empty end
       end);
  if type != "object" or (.programs | type) != "array"
  then {errors: ["the plan is not a root plan: it has no programs list"], programs: [], terms: 0}
  else
    [problems, table_problems] as $errors
    | if ($errors | length) > 0 then {errors: $errors, programs: [], terms: 0}
      else
        {errors: [],
         programs: ([(.programs[].plan[] | term | $binding.primitives[.[0]].programs // [] | .[]),
                     ($binding.tables | to_entries[] | select((input_state[.value.cell] // []) | length > 0)
                      | .value.programs // [] | .[])] | unique),
         terms: ([.programs[].plan[]] | length),
         tables: ($binding.tables | with_entries(.value = (input_state[.value.cell] // [])))}
      end
  end
