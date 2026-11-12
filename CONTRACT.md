# The loop's contract

`workplace` is an interpreter of one expected form: six terms that it executes and two tables that it folds into each seat's start. It holds no code for any one primitive. What a term does is its entry in `host/binding.json`; what the loop does with any entry is below. Each sentence is shown by at least one check of `tests/run.sh` that carries its number.

## Inputs and the build

- **C1.** The loop reads two variables and no other setting: `WORKPLACE_ROOT`, the absolute path of a directory, and `WORKPLACE_CONFIG`, the absolute path of a directory at or below it. Anything else is refused with exit 2. tmux itself reads `TMUX_TMPDIR` to find its socket; the loop records the socket it used, and `down` and `status` refuse to act from a shell that would reach another (C18).
- **C2.** `build` reads `PLAN/` in `WORKPLACE_CONFIG` and nothing else:
  - `plan.json` is the reader's output as printed;
  - `facts.json` is the facts it was planned on;
  - `manifest.json` is the root, the inputs and the outputs, each with its sha256.
  - It refuses, naming the file or the fact: a missing file; a changed input or output; outputs that do not list `plan.json` (and `facts.json` when there is one); a root other than `WORKPLACE_ROOT`.
  - When the plan's `facts` member is `none`, it compares no fact.
  - When the member is a digest, `facts.json` must have that digest and belong to the same root, with canonical paths and v1's five facts only. Its own collector then reads again each fact the file records, and refuses one that no longer holds; an entry the file does not record is no difference.
  - It prints the manifest's reader and derivations.
  - `build` writes `BUILD`: the plan, its facts and manifest, the binding, the loop's own files, and a `MANIFEST` of their hashes, each equal to its source.
  - It refuses while `BUILD` exists, and a failed or interrupted build leaves no `BUILD`.
- **C3.** The plan is refused at build for:
  - a status other than `ok` or `unchecked`, or a control character;
  - a term with no binding, outside the binding's order, or of the wrong arity;
  - a value that a term gives for a closed set, such as a layout, outside its set;
  - a command that is not a JSON list of strings whose program is an absolute path or a bare name;
  - a name that is empty, holds `/` or begins with `-`;
  - a state row that is not four strings and one value, names a seat the plan does not make, or holds an unknown state;
  - two seats of one name;
  - and against the binding's structure: not exactly one `server`; two `session` terms for an office, two `window` or `arrange` terms for a room, two `pane` or `start` terms for a seat; a session with no window, a window with no pane or arrangement, a pane with no window or no start, and the reverse.
- **C4.** Every path that a term or a row gives as a place on the machine is absolute and canonical (no empty, `.` or `..` component, no trailing slash), and any other is refused by name. A program's and an origin's `path` are the reader's record of where a line was written, and the loop neither rewrites nor refuses them. A `read-only` or `read-write` row whose path does not exist is refused, and so is a `hidden`, `searchable-only` or `scratch` row whose path is not a directory; the preconditions the binding names (a directory, a file) are checked at build.
- **C5.** `up` checks `BUILD` against its `MANIFEST`, refuses a changed, missing or unlisted file, and never builds.
- **C6.** The loop needs bash 5.2, jq 1.7 and tmux 3.0 or later, and refuses an older one; versions are compared with tmux's letter suffix, so a floor of 3.5a refuses 3.5. It needs `setpriv`, `env`, `mkdir`, `cp`, `rm`, `sha256sum` and `stat`, and bubblewrap only when a seat has a view. It resolves each program to an absolute path before it applies anything, and refuses a path that holds `=`.

## Applying the plan

- **C7.** Every value the plan or a slot gives a tmux command is encoded: a backslash before a trailing `;`, and where tmux expands formats, every run of `#` not followed by `[` doubled. The program's own options (`-L`, `-f`) are not encoded, since tmux's command parser never sees them. No text of the plan is evaluated by a shell.
- **C8.** Terms are applied in the binding's order of primitives (`server`, `session`, `window`, `pane`, `arrange`, `start`), and in plan order within one primitive, whatever the order of the plan's programs. Each office gives a session, each room a window and a layout, each seat a pane and a start in its first directory. A pane is made by splitting its room's window, which is then re-spaced with tmux's `tiled` so that the next split has room. The room's declared layout is applied once, by `arrange`, after all its panes exist, and the room ends in that layout.
- **C9.** tmux's first window of a session and first pane of a window are claimed by the first `window` and `pane` terms that ask for them. No term says which seat is first, and `up` refuses when a window or pane that is not a seat would stand. Every target is a captured id.
- **C10.** Every tmux call runs under `setpriv --no-new-privs` with `TMUX` and `TMUX_PANE` removed, so the server and every seat run without privilege gain. A running server without no-new-privileges is refused.
- **C11.** `server` checks, before any session exists, that `destroy-unattached` and `exit-unattached` are off and `exit-empty` is on. With `exit-empty` off, the empty server its check started stays, and nothing else is made. Every session carries the run's mark, `@workplace`.

## A seat's view

- **C12.** A seat's view is the table of the plan's `view` cell, read in one place. A seat with rows starts in bubblewrap with its own user, PID, IPC and device namespaces. The emission order is: the row for `/`; then a fresh `/proc` and `/dev`; then the other rows in the byte order of their paths. A seat with no rows starts without bubblewrap.
- **C13.** A row that is not `hidden`, lying beneath a `hidden` row by path components, refuses the seat's table whole, naming both paths. `/a` and `/ab` are separate branches.
- **C14.** The states:
  - `hidden` is a tmpfs of mode 0000, and nothing beneath it exists;
  - `searchable-only` is a tmpfs of mode 0111: it can be passed through, not listed, and only its rows exist;
  - `scratch` is an empty writable tmpfs;
  - `read-only` and `read-write` bind the path onto itself.
  A path with no row has its nearest ancestor's state, and every table of a seat holds a row for `/`.
- **C15.** Inside a view, `/dev/tty` opens, the terminal's size can be read, job control works, a full-screen program reaches the alternate screen, and another pane's terminal cannot be written.
- **C16.** A seat's program receives exactly the binding's inherited names and the rows of the plan's `environment` cell for that seat. An inherited name takes its value from the environment `exec` runs in, and `PWD` is the seat's directory. A variable of the server or of the loop does not arrive.

## exec, down and the run

- **C17.** A pane's command is `workplace exec -- SEAT` and nothing else. `exec` checks `BUILD` first. It starts the seat's program with the view, the environment's rows and the inherited names that `up` recorded in the seat's own record, from any terminal and any directory. `--print` prints the call, and an unknown seat, a changed build or a workplace that is not up is refused with exit 2. A pane holds a silent tmux client until its start replaces it with `respawn-pane -k`, which is followed by clearing its history, and no key is ever sent to a pane.
- **C18.** `down` undoes, newest first, what `up` recorded and nothing else. It acts only on a session that still carries the run's mark, removes `RUN` and keeps `BUILD`, and with nothing up it does nothing. It refuses, keeping `RUN`, when this shell would reach another tmux socket than the run's, and it keeps `RUN` and exits 1 when an undo fails.
- **C19.** A failed term stops `up`. Everything made in that run is torn down by its captured id, whether or not its mark was set yet, `RUN` is removed, and the failure names the term.
- **C20.** `up` refuses while `RUN` exists.
- **C21.** `RUN` holds:
  - every call made;
  - the undo ledger;
  - the checks `status` runs;
  - each seat's recorded start;
  - the tables;
  - the learned slots.
  It is the loop's record and no input of the reader.
- **C22.** `status` reports the build, the run and every check as ok or gone, and exits 1 when the build has changed or a check fails.

## Questions and the host

- **C23.** `why SEAT PATH` prints the row that decides a path for a seat, or its nearest ancestor's, with every claim behind it and each claim's origin, losing claims included.
- **C24.** `doctor` reports each program with its version, whether no-new-privileges can be set, whether bubblewrap can make a user namespace, and whether the kernel lets a program push input into its terminal (TIOCSTI). When the host refuses the namespaces, it names the host's one root step and never takes it.
- **C25.** A workplace's tmux server is named by the plan's `server` term, and the loop applies that name as given. The assembler derives it from the configuration's clone, and `default` means tmux's default socket. Two workplaces whose plans name different servers do not meet.
