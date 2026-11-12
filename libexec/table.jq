def holds($plan; $word):
  any($plan | if type == "object" then .programs[]? else empty end | .recorded[]?; (.term | type) == "array" and .term[0] == $word);

def folded($plan; $spec):
  any(($spec.fold // [])[]; holds($plan; .));

def table_rows($plan; $view; $spec):
  if folded($plan; $spec) then ($view.rows // [])
  else ($plan | if type == "object" and (.state | type) == "object" then (.state[$spec.cell] // []) else [] end) end;
