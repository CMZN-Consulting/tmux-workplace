include "table";

def generation_semantic:
  walk(if type=="object" then del(.origin,.origins) else . end);

def generation_floor_of($ix; $key):
  if ($ix.rooms | index($key))!=null then $key else $ix.housed[$key] // null end;

def generation_term($binding):
  ($binding.primitives[.[0]].seat.argv // null) as $argv
  | if $argv==null then . else .[$argv] |= fromjson end;

def generation_slices:
  .binding as $binding
  | .view as $view
  | .conf as $conf
  | .plan as $plan
  | .root as $root
  | $plan
  | floor_index($binding) as $ix
  | plan_terms as $terms
  | [$terms[] | select(.term[0]=="pane")
     | {key:(.term[1:4]|tojson),name:.term[4],floor:(.term|term_floor($binding;$ix))}] as $names
  | ([$names[] | {key:.key,value:.name}] | from_entries) as $by_key
  | ([$names[] | {key:.name,value:.floor}] | from_entries) as $by_name
  | [$terms[] | select(.term[0]=="floor") | .term] as $floors
  | {
      floors:$floors,
      globals:{workplace:[$terms[] | select(.term[0]=="workplace" or .term[0]=="server") | .term],
                mail:($view.mail // null),records:($view.records // null),
                labels:([$plan.programs[]?.recorded[]? | select(.term[0]?=="label")
                         | {path:(.term[1]|joined_path($root)),
                            value:(if .term[2]=="closed" then "closed" else (.term[2]|tonumber) end)}]
                        | unique_by([.path,.value])),
                ssh_keys:([$plan.programs[]?.recorded[]? | select(.term[0]?=="ssh-key")
                           | {name:.term[1],path:(.term[2]|joined_path($root))}]
                          | unique_by([.name,.path])),
                environment:[$plan.state[$binding.tables.environment.cell][]?
                             | select(generation_floor_of($ix;.key[0])==null)]},
      names:$by_name,
      relations:([$view.seats[]? as $seat | ($seat.reach // {} | to_entries[]) as $reach
                   | $reach.value[] | {from:$by_key[$seat.seat|tojson],from_floor:$seat.floor,
                                      to:.,to_floor:$by_name[.],action:$reach.key}]
                 | sort_by([.from,.action,.to])),
      slices:([$floors[] as $floor | $floor[1] as $f
        | [$names[] | select(.floor==$f) | .name] as $local_names
        | [$view.seats[]? | select(.floor==$f)] as $own_seats
        | [$own_seats[].ssh.granted[]?.name] as $grants
        | {key:$f,value:{floor:$floor,conf:($conf[$f] // null),
             terms:[$terms[] | select((.term|term_floor($binding;$ix))==$f) | .term | generation_term($binding)],
             seats:[$own_seats[] | . + {name:$by_key[.seat|tojson]}
                    | if .reach==null then . else .reach |= map_values(map(select(. as $n | $local_names|index($n)!=null))) end],
             rows:[table_rows($plan;$view;$binding.tables.view)[] | select(generation_floor_of($ix;.key[0])==$f)],
             environment:[$plan.state[$binding.tables.environment.cell][]?
                          | select(generation_floor_of($ix;.key[0])==$f)],
             ssh:[$view.ssh.keys[]? | select(.name as $name | $grants | index($name)!=null)]}}] | from_entries)
    }
  | generation_semantic;

def generation_rebuild_faults($new; $floor):
  . as $old
  | ([$old.floors[][1]]) as $old_order
  | ([$new.floors[][1]]) as $new_order
  | [
      ((["root","state"][]) as $member | select($old[$member]!=$new[$member])
       | {kind:"global",member:$member,reason:"the root or state directory changed"}),
      (if ($old.configuration | if type=="object" then .floors |= map(if .key==$floor then del(.smallest) else . end) else . end)
          !=($new.configuration | if type=="object" then .floors |= map(if .key==$floor then del(.smallest) else . end) else . end)
       then {kind:"configuration",reason:"workplace.json changed beyond the requested floor's smallest value"} else empty end),
      (if ($old_order|index($floor))==null or ($new_order|index($floor))==null
       then {kind:"floor",reason:"the requested floor must exist in both editions"} else empty end),
      (if $old_order!=$new_order then {kind:"topology",reason:"the set or order of floors changed"} else empty end),
      (if ($old.floors|map(if .[1]==$floor then .[7]=null else . end))
          !=($new.floors|map(if .[1]==$floor then .[7]=null else . end))
       then {kind:"floor-line",reason:"a floor line changed beyond the requested floor's smallest value"} else empty end),
      (($old.names|keys[]) as $name | select($new.names|has($name))
       | select($old.names[$name]!=$new.names[$name])
       | {kind:"name-moved",name:$name,reason:"a name moved between floors"}),
      (($old.globals|keys[]) as $member | select($old.globals[$member]!=$new.globals[$member])
       | {kind:"global",member:$member,reason:"a value repeated by every floor changed"}),
      (($old.slices|keys[]) as $other | select($other!=$floor)
       | select($old.slices[$other]!=$new.slices[$other])
       | first(($old.slices[$other]|keys[]) as $member
               | select($old.slices[$other][$member]!=$new.slices[$other][$member])
               | {kind:"slice",floor:$other,member:$member,reason:"another floor's slice changed"})),
      ((["mail","grab","write","record"][]) as $action
       | if ([$old.relations[] | select(.action==$action and .from_floor!=$floor and .to_floor!=$floor)])
           !=([$new.relations[] | select(.action==$action and .from_floor!=$floor and .to_floor!=$floor)])
         then {kind:("unrelated-"+$action),reason:("a "+$action+" pair with neither end on the requested floor changed")} else empty end)
    ];

if $operation=="project" then
  . as $input
  | generation_slices
  | if $input | has("root")
    then . + {root:$input.root,state:$input.state,configuration:$input.configuration}
    else . end
elif $operation=="compare" then
  . as $input | .old | generation_rebuild_faults($input.new;$input.floor)
elif $operation=="private" then
  generation_semantic
  | if $ARGS.named.role=="records.json" then .seats |= map(del(.reads)) else . end
elif $operation=="semantic" then generation_semantic
else error("unknown generation operation") end
