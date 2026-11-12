# tmux-workplace

The frame that applies a workplace's plan. tmux makes the sessions, windows and panes, and bubblewrap gives each seat the view its table declares.

```text
export WORKPLACE_ROOT=/path/the/workplace/lives/under
export WORKPLACE_CONFIG=$WORKPLACE_ROOT/path/of/the/configuration/clone
bin/workplace build
bin/workplace up
bin/workplace status
bin/workplace exec 'Seat Name'
bin/workplace why 'Seat Name' /some/path
bin/workplace down
bin/workplace doctor
```

- `build` checks `PLAN/` in the configuration's clone against its sources and against the machine, then writes `BUILD/`.
- `up` starts a verified build under no-new-privileges, and never builds.
- A pane's command is `workplace exec SEAT`. The same command run by hand gives a seat its view and its environment in any terminal.
- `down` removes what `up` made and nothing else.

What each term does is one entry of `host/binding.json`. What the loop does with any entry is `CONTRACT.md`.

## Needs

- bash 5.2, jq 1.7 and tmux 3.0 or later;
- `setpriv`, `env`, `mkdir`, `cp`, `rm`, `sha256sum` and `stat`;
- bubblewrap, only when a seat has a view, on a Linux host with unprivileged user namespaces.

`doctor` checks each of these. The loop has run on tmux 3.8. The workflow in `.github/workflows/` runs the tests on tmux 3.5a, built from its release archive.

## Tests

`bash tests/run.sh` runs every test on a tmux server of its own, under a scratch home, with `TMUX` and `TMUX_PANE` unset. `bash tests/run.sh t_views` runs one test.
