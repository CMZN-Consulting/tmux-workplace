# tmux-workplace

The frame that applies a workplace's plan. tmux makes the sessions, windows and panes, and bubblewrap gives each seat the view its table declares.

```text
export WORKPLACE_ROOT=/path/the/workplace/lives/under
export WORKPLACE_CONFIG=$WORKPLACE_ROOT/path/of/the/configuration/clone
bin/workplace plan
bin/workplace build
bin/workplace up
bin/workplace status
bin/workplace restart ['Seat Name' ...]
bin/workplace exec 'Seat Name'
bin/workplace why 'Seat Name' /some/path
bin/workplace record verify 'Seat Name' [YYYY-MM-DD | unstored | gaps | signed]
bin/workplace record verify --requests
bin/workplace down
bin/workplace unbuild
bin/workplace doctor
```

- `plan` assembles the clone's layers and programs, runs the reader `typify` and folds the plan's statements into each seat's view, then writes `PLAN/`. It is the only command that needs the reader.
- `build` checks `PLAN/` in the configuration's clone against its sources and against the machine, then writes `BUILD/`.
- `up` starts a verified build and never builds. Enforced floors and configurations without floors retain no-new-privileges. An unenforced floor needs a plain caller and starts its server and seats with ordinary user privileges; its agents, carrier and record keepers retain no-new-privileges.
- A pane's command is `workplace exec SEAT`. The same command run by hand gives a seat its view and its environment in any terminal.
- `down` removes what `up` made and nothing else. `unbuild` then removes `BUILD` and the build's key homes, and keeps the rest of the workplace's state directory.
- A seat whose program has ended keeps its pane, dead, until `restart` starts it again in that pane, as `up` started it, or the workplace goes down.
- Each floor has its own server and configuration. Run sockets live in the clone's `BUILD/RUN`; an unenforced `tmux-default` floor uses the caller's default socket. A foreign server there is refused without changes. Every later call uses the recorded socket path. `status` prints the attach command.
- `record verify` reads a seat's kept record of a day, or its `unstored`, `gaps` or `signed`, or the frame's record of requests, against its chain, and names the first place where they differ.

What each term does is one entry of `host/binding.json`. What the loop does with any entry is `CONTRACT.md`. What a seat is told about its mailbox is `share/seat-page.md`, which every mailbox holds as `README.md`.

An enforced seat's aliases cannot increase its host-file access. A bind through a
symbolic link needs the same or greater permission at the resolved path's own
name. A writable alias of a read-only path is refused. A parent alias must also
cover each stricter descendant at the alias's destination; explicitly permitted
children and read-only aliases of writable data remain usable. The check runs
again at build, up, restart and each seat's exec. Private-key source files remain
unshown even where an alias uses a different name. This is a check of declared
paths and host metadata, not a scan of file contents.

The check assumes stable paths and mounts between inspection and namespace
creation. It does not identify hard links, separate host mounts of the same data
or descriptors that another process already holds. The contract states the
external host work on which a running view depends.

Build seals each floor's configuration into its generation and publishes the
enforced and unenforced frame settings in `BUILD/share/`. Startup reads the
floor's configuration first and the frame's settings second. It rejects active
hooks, malformed or blocking files, unexpected sessions, and shell expansions
in enforced-floor options. Startup calls have a ten-second deadline. The carrier
repairs changed transport settings and records a repair; `status` checks them
without repairing them. Existing pane history below 5000 cannot be repaired and
is refused. Higher history limits are preserved.

Unenforced mailboxes are `MAILPATH/NAME/` links into the store; record views are
`RECORDPATH/NAME/`. Their source files are reachable to ordinary processes of the
same Unix user, so neither seat identity nor privacy is enforced on that floor.
Shutdown leaves personal sessions and their default server running, removes its
own run directory, and retains the frame's global settings and reserved marks.
It stops a carrier unit only while the unit has the recorded invocation ID.
Reusing that default server requires the same sealed floor configuration. If
the file changed, `up` refuses without changing the server, since tmux would
ignore the later client's `-f`. End that server yourself before loading the
new configuration.

## Needs

- bash 5.2, jq 1.7 and tmux 3.5a or later;
- `setpriv`, `env`, `mkdir`, `cp`, `rm`, `sha256sum` and `stat`;
- bubblewrap, only when a seat has a view, on a Linux host with unprivileged user namespaces;
- the reader, `typify` on the path, for `plan` alone;
- GnuPG 2.4.4 or later (`gpg`, `gpg-agent`, `gpgconf`, `gpg-connect-agent`), with `setsid` and `base64`, only when a seat holds a key. Each such seat gets a key made at every build. In its view it signs and authenticates through its agent's restricted socket, and never sees its private key;
- OpenSSH's `ssh-keygen` and `ssh-add`, only when the plan grants an ssh key. `build` checks the key's file and loads it into the agent of each seat it is granted to, and the seat is shown the key's public file alone;
- GNU `env` with `-S`, coreutils 8.30 or later, only when a seat expects a value given at run time. The values stand in the workplace's `values.json` in its state directory, which the desk lead writes with mode 0600, and no value is ever printed or put on a command line;
- git 2.32 or later, with `flock`, `dd`, `mv`, `tail` and `date`, only when the plan holds mail. Each seat is then shown its own mailbox at the plan's mail path, with the frame's page for a seat in it, and the carrier, which `up` starts, takes what a seat leaves in its `out`: a mail it delivers into the store, a grab or a write it does on another seat's pane where the plan allows it. Where a kind's `wake` term says how its pane looks when it waits for a line, the carrier types into a reader's waiting pane one line that points out its new mail and names its mailbox's `in` and the page;
- `dd`, `date`, `tail` and `head`, only when the plan keeps a pane's record, and `systemd-run`, `systemctl` and `journalctl` with a user manager that answers, only when its chain goes to the journal. A kept pane is piped from before its program starts into a keeper of the frame's, one file a day for each seat in the workplace's state directory, and the carrier sends the chain every ten seconds.

`doctor` checks each of these. The workflow in `.github/workflows/tmux.yml` is configured to test the minimum tmux 3.5a and the pinned 3.6b, 3.7c and 3.8 releases, with hash-checked upstream archives. Each version runs independently and the `tests` check requires all four to succeed. This configuration does not itself establish that a candidate has passed those jobs; consult its actual run results.

## Tests

`bash tests/run.sh` runs every test on a tmux server of its own, under a scratch home, with `TMUX` and `TMUX_PANE` unset. `bash tests/run.sh t_views` runs one test.
