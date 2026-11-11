# tmux-workplace

The loop that applies a workplace's plan: tmux makes the sessions, windows and panes, and bubblewrap gives each seat the view its table declares.

```text
export WORKPLACE_ROOT=/path/the/workplace/lives/under
export WORKPLACE_CONFIG=$WORKPLACE_ROOT/path/of/the/configuration/clone
bin/workplace build --plan PLAN.json
bin/workplace up
bin/workplace status
bin/workplace down
```

`build` writes `BUILD/` in the configuration's clone: the plan, the binding and a manifest of their hashes. `up` applies a verified build and never builds. `down` removes what `up` made and nothing else.

The plan is the JSON that `typify plan --json` prints over a root. What each term does is one line of `host/binding.json`. What the loop does with any line is `CONTRACT.md`.

## Needs

bash 5.2, tmux 2.9 and jq 1.7 or later, and `mkdir`, `cp`, `rm` and `sha256sum`. bubblewrap is needed only when a seat has a view, and `realpath` only for a `resolve` term.

## Tests

`bash tests/run.sh` runs every test on a tmux server of its own, under a scratch home, with `TMUX` and `TMUX_PANE` unset. `bash tests/run.sh t_seat_views` runs one test.
