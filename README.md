# tmux-workplace

The frame that applies a workplace's plan. tmux makes the sessions, windows and panes, and bubblewrap gives each seat the view its table declares.

```text
export WORKPLACE_ROOT=/path/the/workplace/lives/under
export WORKPLACE_CONFIG=$WORKPLACE_ROOT/path/of/the/configuration/clone
bin/workplace plan
bin/workplace build
bin/workplace up
bin/workplace status
bin/workplace exec 'Seat Name'
bin/workplace why 'Seat Name' /some/path
bin/workplace down
bin/workplace doctor
```

- `plan` assembles the clone's layers and programs, runs the reader `typify` and folds the plan's statements into each seat's view, then writes `PLAN/`. It is the only command that needs the reader.
- `build` checks `PLAN/` in the configuration's clone against its sources and against the machine, then writes `BUILD/`.
- `up` starts a verified build under no-new-privileges, and never builds.
- A pane's command is `workplace exec SEAT`. The same command run by hand gives a seat its view and its environment in any terminal.
- `down` removes what `up` made and nothing else.

What each term does is one entry of `host/binding.json`. What the loop does with any entry is `CONTRACT.md`.

## Needs

- bash 5.2, jq 1.7 and tmux 3.5a or later;
- `setpriv`, `env`, `mkdir`, `cp`, `rm`, `sha256sum` and `stat`;
- bubblewrap, only when a seat has a view, on a Linux host with unprivileged user namespaces;
- the reader, `typify` on the path, for `plan` alone;
- GnuPG 2.4.4 or later (`gpg`, `gpg-agent`, `gpgconf`, `gpg-connect-agent`), with `setsid` and `base64`, only when a seat holds a key. Each such seat gets a key made at every build. In its view it signs and authenticates through its agent's restricted socket, and never sees its private key;
- GNU `env` with `-S`, coreutils 8.30 or later, only when a seat expects a value given at run time. The values stand in the workplace's `values.json` in its state directory, which the desk lead writes with mode 0600, and no value is ever printed or put on a command line.

`doctor` checks each of these. The tests pass on tmux 3.5a, built from its release archive by the workflow in `.github/workflows/`, and on tmux 3.8.

## Tests

`bash tests/run.sh` runs every test on a tmux server of its own, under a scratch home, with `TMUX` and `TMUX_PANE` unset. `bash tests/run.sh t_views` runs one test.
