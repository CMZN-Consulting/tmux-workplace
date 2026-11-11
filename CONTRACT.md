# The loop's contract

`workplace` is an interpreter of a plan. It holds no code for any one primitive: what a term does is its line in `host/binding.json`, and what the loop does with any line is below. Each sentence is shown by at least one check of `tests/run.sh` that carries its number.

## Inputs

- **C1.** The loop reads two variables and no other setting: `WORKPLACE_ROOT`, the absolute path of a directory, and `WORKPLACE_CONFIG`, the absolute path of a directory at or below it. Anything else is refused with exit 2.
- **C2.** `build --plan FILE` reads a root plan in Typify's wire: `programs` with their ordered terms, a `state`, and a `status`. It refuses a status other than `ok` or `unchecked`, a control character, a term with no binding, a term of the wrong arity, and a state row of the wrong shape or an unknown state.
- **C3.** `build` writes `BUILD` in `WORKPLACE_CONFIG`: the plan, the binding, the loop's jq programs and files, and a `MANIFEST` of their sha256 hashes, each equal to its source's hash. It refuses when `BUILD` exists, and a failed build leaves no `BUILD`.
- **C4.** `up` checks `BUILD` against its `MANIFEST`, refuses a changed, missing or unlisted file, and never builds.

## Programs

- **C5.** The loop needs bash 5.2, tmux 2.9 and jq 1.7 or later, and refuses an older one. It needs bubblewrap only when some seat has a view, and realpath only for a `resolve` term. Before it applies anything, it resolves every program the plan needs to an absolute path.

## Applying a plan

- **C6.** Terms are applied in plan order: the programs in their order, each program's terms in order. A binding names a term's arguments by position. A relative path is joined to `WORKPLACE_ROOT`. No text of the plan is evaluated by a shell.
- **C7.** Every value that the plan or a slot gives tmux is encoded. A trailing `;` gets a backslash before it. Where tmux expands formats, every run of `#` not followed by `[` is doubled. The binding's own literals pass as written.
- **C8.** A slot is a value a call printed, kept under a name made of the term's arguments, for later terms. The loop's own slots are the root, the configuration's clone, the build, the run's mark, bash, and each program the plan needs.
- **C9.** A binding's preconditions (a directory, a file, a name) are checked before its call, and a failed precondition fails the term.
- **C10.** `server` checks that `destroy-unattached` and `exit-unattached` are off in the server the plan names, before any session exists.
- **C11.** Every session the loop makes carries the run's mark, `@workplace`, set by a call that names the session by its captured id.

## A seat's view

- **C12.** A seat's view is the plan's state cell `view`: rows keyed by office, room, seat and path, each holding one state. The start of a seat emits its rows after bubblewrap's fixed head, in the byte order of their absolute paths, skipping a row beneath a `hidden` row. A seat with no rows starts without bubblewrap.
- **C13.** `hidden` is a tmpfs of mode 0000, `searchable` a tmpfs of mode 0111, `read-only` and `read-write` are binds of the path onto itself, and `denied` is an empty file bound read-only over the path.
- **C14.** A `resolve` term adds to its seat's view the resolved target of its path as `denied`. It adds one row per target, however many names point at it, and that row replaces a plan row at the same path. `status` lists every added row as unchecked.

## Panes and starts

- **C15.** A pane is made holding a process that prints nothing: a tmux client waiting on the run's channel. `start` replaces it with `respawn-pane -k`, then clears the pane's history. No key is ever sent to a pane, and every target is a captured id, never an index.

## Failure, teardown and records

- **C16.** A failed term stops `up`. The loop then undoes, newest first, what the run recorded, removes `RUN`, and exits 1 naming the term.
- **C17.** An undo acts only on an object that still carries the run's mark. A session that is gone, or carries another mark, is left alone.
- **C18.** `down` undoes what `up` recorded and nothing else, removes `RUN` and keeps `BUILD`. With nothing up it does nothing.
- **C19.** `up` refuses while `RUN` exists.
- **C20.** `up` writes in `BUILD/RUN` every call it made, the undo ledger, the checks `status` runs, the rows it added, and the learned slots as facts (`{"fact": "slot", "args": [...], "value": ...}`).
- **C21.** `status` reports the build, the run, every check as ok or gone, and every added row as unchecked. It exits 1 when the build has changed or a check fails.
- **C22.** Every tmux call names the plan's server with `-L` and runs with `TMUX` and `TMUX_PANE` removed from its environment.
