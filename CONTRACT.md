# The loop's contract

`workplace` is an interpreter of one expected form: six terms that it executes and two tables that it folds into each seat's start. It also assembles a clone for the reader and folds the plan's statements into a seat's view. It holds no code for any one primitive. What a term does is its entry in `host/binding.json`; what the loop does with any entry is below. Each sentence is shown by at least one check of `tests/run.sh` that carries its number.

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
  - a command that is not a JSON list of strings whose program is a bare name or a path (C4);
  - a name that is empty, holds `/` or begins with `-`;
  - a state row that is not four strings and one value, names a seat the plan does not make, or holds an unknown state;
  - two seats of one name;
  - and against the binding's structure: not exactly one `server`; two `session` terms for an office, two `window` or `arrange` terms for a room, two `pane` or `start` terms for a seat; a session with no window, a window with no pane or arrangement, a pane with no window or no start, and the reverse.
- **C4.** A path that a term, a recorded term or a row gives as a place on the machine is written absolute or relative to the root, and the plan keeps it as written. The frame joins a relative path: the root, a slash and the path, where `.` is the root, with no doubled slash under the root `/` and never `/.`. An absolute path is taken as written.
  - The places are the binding's: each `path` argument of a primitive; the program of a seat's command when it holds a slash; and those under `paths`, which are a statement's and a label's path, a claim's, a recorded directory, and a row of the `view` cell. The root that the plan's `configure root` records is not joined again.
  - A bare program is looked up on the seat's path. The other words of a command and every value of the environment are text, and are not touched.
  - A path with an empty component, a `.` or `..` component other than the single `.`, or a slash at its end is refused by `plan` and by `build`, with exit 1, naming the term or the row's origin.
  - `view.json`, every row, the fold and everything `build` writes carry the joined path, and `why` prints the path as written beside the joined one where they differ.
  - A program's and an origin's `path` are the reader's record of where a line was written, and the loop neither rewrites nor refuses them.
  - A `read-only` or `read-write` row whose path does not exist is refused, and so is a `hidden`, `searchable-only` or `scratch` row whose path is not a directory. The preconditions the binding names (a directory, a file) are checked at build.
- **C5.** `up` checks `BUILD` against its `MANIFEST`, refuses a changed, missing or unlisted file, and never builds.
- **C6.** The loop needs bash 5.2, jq 1.7 and tmux 3.5a or later, and refuses an older one; versions are compared with tmux's letter suffix, so the floor 3.5a refuses 3.5. It needs `setpriv`, `env`, `mkdir`, `cp`, `rm`, `sha256sum` and `stat`, and bubblewrap only when a seat has a view. It resolves each program to an absolute path before it applies anything, and refuses a path that holds `=`.

## Applying the plan

- **C7.** Every value the plan or a slot gives a tmux command is encoded: a backslash before a trailing `;`, and where tmux expands formats, every run of `#` not followed by `[` doubled. The program's own options (`-L`, `-f`) are not encoded, since tmux's command parser never sees them. No text of the plan is evaluated by a shell.
- **C8.** Terms are applied in the binding's order of primitives (`server`, `session`, `window`, `pane`, `arrange`, `start`), and in plan order within one primitive, whatever the order of the plan's programs. Each office gives a session, each room a window and a layout, each seat a pane and a start in its first directory. A pane is made by splitting its room's window, which is then re-spaced with tmux's `tiled` so that the next split has room. The room's declared layout is applied once, by `arrange`, after all its panes exist, and the room ends in that layout.
- **C9.** tmux's first window of a session and first pane of a window are claimed by the first `window` and `pane` terms that ask for them. No term says which seat is first, and `up` refuses when a window or pane that is not a seat would stand. Every target is a captured id.
- **C10.** Every tmux call runs under `setpriv --no-new-privs` with `TMUX` and `TMUX_PANE` removed, so the server and every seat run without privilege gain. A running server without no-new-privileges is refused.
- **C11.** `server` checks, before any session exists, that `destroy-unattached` and `exit-unattached` are off and `exit-empty` is on. With `exit-empty` off, the empty server its check started stays and nothing else is made: the loop never ends a server, and the refusal names the server's socket and the command that ends it. Every session carries the run's mark, `@workplace`.

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
- **C25.** A workplace's tmux server is named by the plan's `server` term, and `default` means tmux's default socket. For any other name, `build` derives the name again by the rule that the manifest names as `derivations.workplace-name`, and refuses another name, a missing rule or a rule it does not know. The rule it knows, `sha256-path-prefix12-v1`, is the clone's directory name, a dash, and the first twelve hex digits of the SHA-256 of the clone's absolute physical path. Two workplaces whose plans name different servers do not meet.
- **C26.** The loop sets the C locale before anything else, so that no result follows its caller's locale: the names `stat` gives a file's type and the messages of the programs it calls are C's. tmux runs with the caller's `LC_ALL` as it was, so that the server's environment is the caller's, and with `-u`, so that what tmux prints is never rewritten for a terminal without UTF-8. The test file sets the C locale too.

## The plan and the fold

- **C27.** `plan` reads the clone at `WORKPLACE_CONFIG`: `workplace.json`, the layers it lists, `programs/` and `tmux.conf`. It assembles in a directory of its own, which it removes.
  - The declarations are one `#lang typify` header and each layer's whole body after its header line, in `workplace.json`'s order. No line is edited.
  - The tree is a generated root program with a copy of `programs/` beneath it, and nothing else. The root program is exactly two lines: `workdir : ROOT` and `server : NAME : CONF`.
  - CONF is the path of `tmux.conf` relative to the root, and NAME is derived (C25), or `default` when `workplace.json` says `"socket": "default"`.
  - It refuses, with exit 2:
    - a layer with a byte-order mark, CR line ends, a NUL byte, no `#lang typify` header or no final newline;
    - a program with a byte-order mark or CR line ends;
    - an empty directory under `programs/`, which git does not carry, so the plan could not be made again from a clone;
    - a layer name listed twice, or a language declared twice;
    - a member of `workplace.json` that it does not read.
- **C28.** The reader is the program `typify` on the path.
  - `plan` runs the reader's `check` on the declarations, and stops on an error. It shows the error at the layer's file and line, beside the reader's own words and line.
  - It then runs the reader's `plan --json` on the tree, and keeps the output as printed. A program's error is shown at its path in the clone, and the root program's as the generated program's.
  - It records the first line that the reader's `--version` prints, and stops when the reader states none.
  - A plan whose `facts` member is not `none` is refused, since 5.15 leaves open which facts `build` compares.
  - `plan` exits 0 when `PLAN/` is written, 1 when the reader or the fold refuses, and 2 on a fault of its inputs. On a refusal, `PLAN/` stays as it was, and `plan` never touches `BUILD`.
- **C29.** `PLAN/` holds the following, and `build` checks them:
  - `plan.json`;
  - `view.json`, exactly when the plan holds statements, clearances or labels, all of which the fold reads. A `plan` that writes none removes the one before it;
  - `manifest.json`: the root, the name, the reader, each derivation's version, every input with its hash in a fixed order, each generated file with its hash, the source map and the outputs. The fold's version is `frame-5.17-5.18-5.24-v2`.
  - `plan` writes `manifest.json` after the outputs, and `build` refuses an output that is missing or whose hash differs from the manifest's, naming it. A `PLAN/` left half-written is never built.
  - `build` needs no reader. When the clone holds `workplace.json` or the manifest lists generated files, it assembles again, with the refusals of C27. It refuses a different name, an input that was added or is gone, and a generated file that differs, each by name.
  - It folds `plan.json` again, and refuses a `view.json` that differs, naming the seats.
- **C30.** The fold reads the plan's `statement A B C SCOPE PATH STATE`, `clearance A B C SCOPE NUMBER` and `label PATH NUMBER` terms from the programs' `recorded` lists, in the plan's order. It takes the seats from the `pane` terms and each seat's kind from the `seat-kinds` cell. For each seat:
  - its statements are the workplace's, its kind's, its office's, its room's and its own;
  - equal statements, clearances and labels count once, and carry the origin of each;
  - a statement is replaced by a narrower one at its path or at a directory above it, by components, and those that remain are the seat's rows;
  - its clearance is its own, else its room's, else its office's, else 0;
  - labels are taken from the shallowest. Where the seat has no row at a labelled path, the label is read against the nearest row above it:
    - when the seat's clearance is below the label, it makes a hidden row, and none when that row is searchable-only or scratch;
    - otherwise it makes a read-only row, and none when that row is hidden or scratch.

    The row a label makes replaces nothing;
  - the rows stand in the byte order of their paths, each with the origins of the statement or label that made it.
- **C31.** The fold refuses the plan, naming the seat, the paths and the origins, for:
  - a term of the wrong shape, an unknown scope or state, a path that is not canonical, or a number that is not whole;
  - a statement or clearance that names an office, a room or a seat that the plan does not make;
  - two statements of one scope about one path with different states, two clearances of one scope, or two labels of one path, with different numbers;
  - a label on `/`;
  - a seat with no row for `/`, checked before any label is taken;
  - a row that is not hidden, lying beneath a hidden row;
  - a row that is not hidden, lying at or beneath a label above the seat's clearance.
- **C32.** `plan` prints, for each seat:
  - its kind and clearance;
  - each remaining statement that replaced others, with every statement that it replaced. A statement that was itself replaced is printed only as replaced;
  - each statement that stands at a labelled path;
  - the counts.

  It prints each label that lies beneath a larger one, with the seats between the two, and lists the directories held by nobody as a report. None of this is in the plan.
- **C33.** A seat's table is `view.json` when the plan holds statements, and the plan's `view` cell when it holds none.
  - The choice is made in one place, `folded` in `libexec/table.jq`. It reads the binding's `fold` words: `statement`, `clearance` and `label`.
  - `plan`, `build`, `up` and `why` all call it. A plan that holds clearances or labels without a statement is folded too, and refused, since no seat has a row for `/`.
  - `view.json` holds the rows and, for each seat in the order of the `pane` terms, its kind, clearance, count of rows, replacement statements and their counts, and its statements at labelled paths.
  - `why` names the statement or the label behind a folded row, and what that statement replaced.
