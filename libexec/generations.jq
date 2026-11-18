include "table";

def generation_semantic:
  walk(if type=="object" then del(.origin,.origins) else . end);

def generation_floor_of($ix; $key):
  if ($ix.rooms | index($key))!=null then $key else $ix.housed[$key] // null end;

def generation_term($binding):
  ($binding.primitives[.[0]].seat.argv // null) as $argv
  | if $argv==null then . else .[$argv] |= fromjson end;

def generation_slices($binding; $view; $conf):
  . as $plan
  | floor_index($binding) as $ix
  | plan_terms as $terms
  | [$terms[] | select(.term[0]=="pane")
     | {key:(.term[1:4]|tojson),name:.term[4],floor:(.term|term_floor($binding;$ix))}] as $names
  | ([$names[] | {key:.key,value:.name}] | from_entries) as $by_key
  | ([$names[] | {key:.name,value:.floor}] | from_entries) as $by_name
  | [$terms[] | select(.term[0]=="floor") | .term] as $floors
  | {
      floors:$floors,
      globals:({workplace:[$terms[] | select(.term[0]=="workplace" or .term[0]=="server") | .term],
                mail:($view.mail // null),records:($view.records // null),
                environment:[$plan.state[$binding.tables.environment.cell][]?
                             | select(generation_floor_of($ix;.key[0])==null)]} | generation_semantic),
      names:$by_name,
      relations:([$view.seats[]? as $seat | ($seat.reach // {} | to_entries[]) as $reach
                   | $reach.value[] | {from:$by_key[$seat.seat|tojson],from_floor:$seat.floor,
                                      to:.,to_floor:$by_name[.],action:$reach.key}]
                 | sort_by([.from,.action,.to])),
      slices:([$floors[] as $floor | $floor[1] as $f
        | [$names[] | select(.floor==$f) | .name] as $local_names
        | {key:$f,value:({floor:$floor,conf:($conf[$f] // null),
             terms:[$terms[] | select((.term|term_floor($binding;$ix))==$f) | .term | generation_term($binding)],
             seats:[$view.seats[]? | select(.floor==$f) | . + {name:$by_key[.seat|tojson]}
                    | if .reach==null then . else .reach |= map_values(map(select(. as $n | $local_names|index($n)!=null))) end],
             rows:[table_rows($plan;$view;$binding.tables.view)[] | select(generation_floor_of($ix;.key[0])==$f)],
             environment:[$plan.state[$binding.tables.environment.cell][]?
                          | select(generation_floor_of($ix;.key[0])==$f)],
             ssh:[$view.ssh.keys[]? as $key
                  | select(any($view.seats[]?; .floor==$f and any(.ssh.granted[]?; .name==$key.name))) | $key]}
            | generation_semantic)}] | from_entries)
    };
