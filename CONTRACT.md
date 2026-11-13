# The loop's contract

`workplace` is an interpreter of one expected form: six terms that it executes and two tables that it folds into each seat's start. It also assembles a clone for the reader and folds the plan's statements into a seat's view. It holds no code for any one primitive. What a term does is its entry in `host/binding.json`; what the loop does with any entry is below. Each sentence is shown by at least one check of `tests/run.sh` that carries its number.

## Inputs and the build

- **C1.** The loop reads two variables of its own and no other setting: `WORKPLACE_ROOT`, the absolute path of a directory, and `WORKPLACE_CONFIG`, the absolute path of a directory at or below it. Anything else is refused with exit 2. For the workplaces' state directory it reads the platform's `XDG_STATE_HOME`, else `HOME` (C35). Every tmux call of the loop names the run's socket by its path (C68), so `TMUX_TMPDIR` plays no part in which server it reaches.
- **C2.** `build` reads `PLAN/` in `WORKPLACE_CONFIG` and nothing else:
  - `plan.json` is the reader's output as printed;
  - `facts.json` is the facts it was planned on;
  - `manifest.json` is the root, the inputs and the outputs, each with its sha256.
  - It refuses, naming the file or the fact: a missing file; a changed input or output; outputs that do not list `plan.json` (and `facts.json` when there is one); a root other than `WORKPLACE_ROOT`.
  - When the plan's `facts` member is `none`, it compares no fact.
  - When the member is a digest, `facts.json` must have that digest and belong to the same root, with canonical paths and v1's five facts only. Its own collector then reads again each fact the file records, and refuses one that no longer holds; an entry the file does not record is no difference.
  - It prints the manifest's reader and derivations.
  - `build` writes `BUILD`: the plan, its facts and manifest, the binding, the loop's own files, and a `MANIFEST` of their hashes, each equal to its source.
  - It refuses while `BUILD` exists, and a failed or interrupted build leaves no `BUILD`. `unbuild` removes one while the workplace is down (C99).
- **C3.** The plan is refused at build for:
  - a status other than `ok` or `unchecked`, or a control character;
  - a term with no binding, outside the binding's order, or of the wrong arity;
  - a value that a term gives for a closed set, such as a layout, outside its set;
  - a command that is not a JSON list of strings whose program is a bare name or a path (C4);
  - a name that is empty, holds `/` or begins with `-`;
  - a state row that is not four strings and one value, names a seat the plan does not make, or holds an unknown state;
  - two seats of one name, and a key that is not one (C67);
  - and against the binding's structure: not exactly one `server`; two `session` terms for an office, two `window` or `arrange` terms for a room, two `pane` or `start` terms for a seat; a session with no window, a window with no pane or arrangement, a pane with no window or no start, and the reverse. Each such refusal names each term it rests on, by its file and place.
- **C4.** A path that a term, a recorded term or a row gives as a place on the machine is written absolute or relative to the root, and the plan keeps it as written. The frame joins a relative path: the root, a slash and the path, where `.` is the root, with no doubled slash under the root `/` and never `/.`. An absolute path is taken as written.
  - The places are the binding's: each `path` argument of a primitive; the program of a seat's command when it holds a slash; and those under `paths`, which are a statement's and a label's path, a claim's, a recorded directory, and a row of the `view` cell. The root that the plan's `configure root` records is not joined again.
  - A bare program is looked up on the seat's path. The other words of a command and every value of the environment are text, and are not touched.
  - A path with an empty component, a `.` or `..` component other than the single `.`, or a slash at its end is refused by `plan` and by `build`, with exit 1, naming the term or the row's origin.
  - `view.json`, every row, the fold and everything `build` writes carry the joined path, and `why` prints the path as written beside the joined one where they differ.
  - A program's and an origin's `path` are the reader's record of where a line was written, and the loop neither rewrites nor refuses them.
  - A `read-only` or `read-write` row whose path does not exist is refused, and so is a `hidden`, `searchable-only` or `scratch` row whose path is not a directory. The preconditions the binding names (a directory, a file) are checked at build.
- **C5.** `up` checks `BUILD` against its `MANIFEST`, refuses a changed, missing or unlisted file, and never builds.
- **C6.** The loop needs bash 5.2, jq 1.7 and tmux 3.5a or later, and refuses an older one; versions are compared with tmux's letter suffix, so the floor 3.5a refuses 3.5. It needs `setpriv`, `env`, `mkdir`, `cp`, `rm`, `sha256sum` and `stat`, and bubblewrap only when a seat has a view. GnuPG 2.4.4 or later (`gpg`, `gpg-agent`, `gpgconf`, `gpg-connect-agent`), with `setsid` and `base64`, is needed only by a plan in which a seat holds a key (C44), and OpenSSH's `ssh-keygen` and `ssh-add` only by one that grants an ssh key (C86), GNU `env` with `-S`, coreutils 8.30 or later, only by one in which a seat expects a value (C49): `up` and `exec` refuse an older `env` there with exit 2, naming both versions; and git 2.32 or later, with `flock`, `dd`, `mv`, `tail` and `date`, only by a plan that holds mail (C56). It resolves each program to an absolute path before it applies anything, and refuses a path that holds `=`.

## Applying the plan

- **C7.** Every value the plan or a slot gives a tmux command is encoded: a backslash before a trailing `;`, and where tmux expands formats, every run of `#` not followed by `[` doubled. The program's own options (`-L`, `-f`) are not encoded, since tmux's command parser never sees them. No text of the plan is evaluated by a shell.
- **C8.** Terms are applied in the binding's order of primitives (`server`, `session`, `window`, `pane`, `arrange`, `start`), and in plan order within one primitive, whatever the order of the plan's programs. Each office gives a session, each room a window and a layout, each seat a pane and a start in its first directory. A pane is made by splitting its room's window, which is then re-spaced with tmux's `tiled` so that the next split has room. The room's declared layout is applied once, by `arrange`, after all its panes exist, and the room ends in that layout.
- **C9.** tmux's first window of a session and first pane of a window are claimed by the first `window` and `pane` terms that ask for them. No term says which seat is first, and `up` refuses when a window or pane that is not a seat would stand. Every target is a captured id.
- **C10.** Every tmux call runs under `setpriv --no-new-privs` with `TMUX` and `TMUX_PANE` removed, so the server and every seat run without privilege gain. A running server without no-new-privileges is refused. The check names the process it checked: the tmux server, an agent or the carrier. A process that has ended by the time its status is read is a refusal of its own, which says so. The server's socket stands in `RUN` (C68), so no server that `up` did not start stands there when `up` starts.
- **C11.** `server` checks, before any session exists, that `destroy-unattached` and `exit-unattached` are off and `exit-empty` is on. With `exit-empty` off, the empty server its check started stays and nothing else is made: the loop never ends a server, and the refusal names the server's socket and the command that ends it, and keeps `RUN`, which holds the socket, while the server stands. Every session carries the run's mark, `@workplace`.

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
- **C16.** A seat's program receives exactly the binding's inherited names and the rows of the plan's `environment` cell for that seat, then the variables that the frame gives it (C39, C48) and the values it expects (C49). An inherited name takes its value from the environment `exec` runs in, and `PWD` is the seat's directory. A variable of the server or of the loop does not arrive.

## exec, down and the run

- **C17.** A pane's command is `workplace exec -- SEAT` and nothing else. `exec` checks `BUILD` first. It starts the seat's program with the view, the environment's rows and the inherited names that `up` recorded in the seat's own record, from any terminal and any directory. `--print` prints the call that `exec` makes, word for word, and an unknown seat, a changed build or a workplace that is not up is refused with exit 2. A pane holds a silent tmux client until its start replaces it with `respawn-pane -k`, which is followed by clearing its history. No key is sent to a pane but by the carrier, which types a seat's write request where the plan allows it (C60) and its own pointer to delivered mail where the reader's kind has a wake (C94), both through one function.
- **C18.** `down` undoes, newest first, what `up` recorded and nothing else. It acts only on a session that still carries the run's mark, removes `RUN` and keeps `BUILD`, and with nothing up it does nothing. It reaches the run's server by its socket's path, whatever the shell's `TMUX_TMPDIR`. When the server still holds sessions that the run did not make, it leaves them, says so, and keeps `RUN`, which holds the socket, while the server stands. It keeps `RUN` and exits 1 when an undo fails.
- **C19.** A failed term stops `up`. Everything made in that run is torn down by its captured id, whether or not its mark was set yet, `RUN` is removed, and the failure names the term.
- **C20.** `up` refuses while `RUN` exists.
- **C21.** `RUN` holds:
  - every call made;
  - the undo ledger;
  - the checks `status` runs;
  - each seat's recorded start;
  - the tables;
  - the learned slots;
  - the carrier's directory, which is its working directory and its mark, and its log (C57);
  - the server's socket (C68).
  It is the loop's record and no input of the reader.
- **C22.** `status` reports the build, the run and every check as ok or gone, and exits 1 when the build has changed or a check fails. With the run up, it prints the line that attaches to the server.

## Questions and the host

- **C23.** `why SEAT PATH` prints the row that decides a path for a seat, or its nearest ancestor's, with every claim behind it and each claim's origin, losing claims included.
  - For a path with no row it says what the nearest row above means for the path: beneath a read-only or read-write row the path is as the machine has it, with that access; beneath a hidden row the seat cannot reach it; beneath a scratch row it is not there until the seat makes it; beneath a searchable-only row it is not there and the seat cannot make it.
  - Where a row lies beneath the path, beneath a searchable-only row the path is a directory the seat passes through to that row and nothing more, and beneath a scratch row it is a directory of the seat's scratch made to hold that row.
  - Where a mask of the frame covers the path, it says that the mask decides and the row does not. The mailbox is such a mask (C55).
- **C24.** `doctor` reports each program with its version, whether no-new-privileges can be set, whether bubblewrap can make a user namespace, whether the kernel lets a program push input into its terminal (TIOCSTI), git and the programs that a plan that holds mail needs (C56), and the programs a chain to the journal needs and whether a user manager answers (C72). When the host refuses the namespaces, it names the host's one root step and never takes it.
- **C25.** A workplace's tmux server is named by the plan's `server` term. The name names the workplace's state directory, its carrier's unit and its socket in `RUN`, and `default` is a name like any other. For any other name, `build` derives the name again by the rule that the manifest names as `derivations.workplace-name`, and refuses another name, a missing rule or a rule it does not know. The rule it knows, `sha256-path-prefix12-v1`, is the clone's directory name, a dash, and the first twelve hex digits of the SHA-256 of the clone's absolute physical path. Two workplaces never meet, since each run's socket stands in its own clone.
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
  - `manifest.json`: the root, the name, the reader, each derivation's version, every input with its hash in a fixed order, each generated file with its hash, the source map and the outputs. The fold's version is `frame-5.17-5.18-5.24-5.29-5.37-5.50-5.54-5.66-5.78-5.122-5.124-v9`.
  - `plan` writes `manifest.json` after the outputs, and `build` refuses an output that is missing or whose hash differs from the manifest's, naming it. A `PLAN/` left half-written is never built.
  - `build` needs no reader. When the clone holds `workplace.json` or the manifest lists generated files, it assembles again, with the refusals of C27. It refuses a different name, an input that was added or is gone, and a generated file that differs, each by name.
  - It folds `plan.json` again, and refuses a `view.json` that differs, naming the seats and both fold versions, and saying to plan again. Where the manifest names another fold and the views are equal, it says so in one line and goes on.
- **C30.** The fold reads the plan's `statement A B C SCOPE PATH STATE`, `clearance A B C SCOPE NUMBER`, `clearance-scale turned`, `label PATH NUMBER`, `key A B C SCOPE STATE`, the four terms of C45, `mail` and `reach` (C54), and the four terms of C69 from the programs' `recorded` lists, in the plan's order. It takes the seats from the `pane` terms and each seat's kind from the `seat-kinds` cell. For each seat:
  - its statements are the workplace's, its kind's, its office's, its room's and its own;
  - equal statements, clearances and labels count once, and carry the origin of each;
  - a statement is replaced by a narrower one at its path or at a directory above it, by components, and those that remain are the seat's rows;
  - its clearance is its room's, else its office's, else none, and a seat with none is cleared for no label. A seat carries no clearance of its own (5.118).
  - A clearance is a whole number, and 0 is the most cleared (5.122 point 1). A label is a whole number or `closed`. A seat is cleared for a numbered label when its clearance is at most the label, and for a `closed` label never (5.124 point 6).
  - Labels are taken from the shallowest. Where the seat has no row at a labelled path, the label is read against the nearest row above it:
    - when the seat is not cleared for the label, it makes a hidden row, and none when that row is searchable-only or scratch;
    - when it is cleared, it makes a read-only row, and none when that row is scratch, or hidden by a statement.

    The row a label makes replaces nothing.
  - A hidden row that a label made becomes searchable-only when a row that is not hidden stands beneath it. It is then a passage to what lies beneath (5.124 point 7): a label beneath a labelled path governs that path.
  - the rows stand in the byte order of their paths, each with the origins of the statement or label that made it.
- **C31.** The fold refuses the plan, naming the seat, the paths and the origins, for:
  - a term of the wrong shape, an unknown scope or state, a path that is not canonical, a number that is not whole, or a label that is neither a whole number nor `closed`;
  - a clearance at a seat's scope, since a seat has its room's clearance (5.118);
  - clearance or label terms with no `clearance-scale turned` term. A configuration numbered before 5.122's turn is refused, until it is renumbered and says so;
  - a label beneath a `closed` path;
  - a statement or clearance that names an office, a room or a seat that the plan does not make;
  - two statements of one scope about one path with different states, two clearances of one scope, or two labels of one path, with different numbers;
  - a label on `/`;
  - a seat with no row for `/`, checked before any label is taken;
  - a row that is not hidden, lying beneath a hidden row;
  - a row that is not hidden, whose governing label is one the seat is not cleared for. A row's governing label is the deepest label at or above it, and a passage is not refused.
- **C32.** `plan` prints, for each seat:
  - its kind and clearance, or that it is cleared for no label, and its home and the names it expects where it has them;
  - each remaining statement that replaced others, with every statement that it replaced. A statement that was itself replaced is printed only as replaced;
  - each statement that stands at a labelled path;
  - the counts.

  It prints each label whose row is a passage (C30), with the seats that pass through it, and lists the directories held by nobody as a report. None of this is in the plan.
- **C33.** A seat's table is `view.json` when the plan holds statements, and the plan's `view` cell when it holds none.
  - The choice is made in one place, `folded` in `libexec/table.jq`. It reads the binding's `fold` words: `statement`, `clearance`, `clearance-scale`, `label`, `key`, `home`, `home-variable`, `home-seed` and `expect`.
  - `plan`, `build`, `up` and `why` all call it. A plan that holds any of them without a statement is folded too, and refused, since no seat has a row for `/`.
  - `view.json` holds the rows and, for each seat in the order of the `pane` terms, its kind, clearance (with `null` for none), key, count of rows, replacement statements and their counts, and its statements at labelled paths.
  - `why` names the statement or the label behind a folded row, and what that statement replaced.
- **C34.** The fold reads `key A B C SCOPE STATE`, with SCOPE `workplace`, `office`, `room` or `seat` and STATE `held` or `none`. A seat holds a key by the narrowest scope that speaks: its own, else its room's, else its office's, else the workplace's, else none. `view.json` gives each seat `key: {state, scope, origins}`.
  - It refuses, naming the origins, two keys of one scope with different states, a key that names an office, room or seat the plan does not make, and any other state.
  - A plan that holds a key term is folded, so every seat of it has a view.
- **C35.** The workplaces' state directory R is `${XDG_STATE_HOME:-$HOME/.local/state}/workplace`, and a workplace's own is S = `R/NAME`, with mode 0700, made by `build`.
  - For each seat that holds a key, in the order of the panes, `build` makes a home `S/keys/NN`, NN being the seat's place among the panes.
  - In it, under `setsid` with nothing on standard input, it makes an ed25519 key that signs and certifies, with an ed25519 subkey that authenticates. There is no passphrase, no expiry and nothing that encrypts.
  - The user id is `NAME <A.B.C@WORKPLACE>`: the seat's name, and its place at the workplace. A user id that gpg does not make as asked refuses the build by name. The user id is passed after `--`, since gpg reads one that begins with `-` as its options.
  - The agent of the home has `pinentry-program` set to `false`, `enable-ssh-support` and `disable-scdaemon` (C88). The home holds the subkey's keygrip in `sshcontrol`, which is read-only (0444), and `no-autostart` in `gpg.conf`.
- **C36.** No key outlives its build.
  - Every build removes the old homes of `S/keys`, first removing their runtime socket directories, which ends any agent of them. `unbuild` removes them the same way (C99), so that none outlives a build that is gone.
  - It removes the revocation certificate that gpg writes unasked, and ends the agent that made the key.
- **C37.** `BUILD/keys.json`, listed in `BUILD/MANIFEST`, holds the workplace's name and S. For each holding seat it holds:
  - its place and name, its home and its user id;
  - the fingerprints of the key and of the subkey, and the armored public key;
  - the OpenSSH line of the subkey, with the comment `A/B/C@WORKPLACE`, and that line's SHA256 fingerprint;
  - its grants (C87).
- **C38.** Before any term, `up` starts one agent per holding seat under `setpriv --no-new-privs`, outside every view.
  - It refuses where an agent of the home already answers, and leaves that agent alone.
  - It refuses a socket path over 106 bytes, the most GnuPG takes. `build` refuses a state directory too long for the sockets: over 84 bytes, or over 78 where there is no runtime directory.
  - It records in the ledger the agent, marked by its process id, and, where its sockets stand in the runtime directory, that directory. It records in the run's checks the agent's answer.
- **C39.** After the rows, the binding's fixed part closes the runtime directory, and with it the agents' sockets, in every view that would show it as the machine has it (C84), and masks R in every view: closed for a seat that holds no key and has no home, and searchable for one that holds a key or has a home.
  - A holding seat is shown, at G = `S/gnupg`, a read-only directory of the frame's making. It holds the key's public ring, its trust database and `gpg.conf`, the agent's extra socket as `S.gpg-agent`, its ssh socket as `S.gpg-agent.ssh`, and, for a seat that an ssh key reaches, the keys' public files in `ssh/` (C90). It is never shown the standard socket, a private key or another seat's home.
  - The frame gives such a seat `GNUPGHOME` and `SSH_AUTH_SOCK` after the environment's cell, and a plan that sets either for it is refused by `plan` and by `build`, naming the row and the key term (C48).
- **C40.** In its view a holding seat signs with gpg and with `ssh-keygen -Y sign`, and makes a signed git commit with the committer set to its name and address alone, all with nothing set by hand. Each verifies against `keys.json`.
- **C41.** Through its sockets a seat obtains nothing of its key and changes nothing.
  - The secret exports give 0 bytes.
  - The agent forbids every command that reads, exports, imports, deletes or changes a key, or reloads or ends the agent.
  - Removing every ssh key changes nothing, and adding one is refused.
  - An add of a key that already stands in the home, its public half sent with any bytes for its secret, is refused too, and `sshcontrol` stands unchanged. For such a key the agent checks nothing of the secret and would only write the key's grip into `sshcontrol`, and that file is read-only (C35). The seat's own key is still listed alone and signs.
- **C42.** `down` ends every agent that carries the run's mark, and removes its runtime socket directory once no agent of the home answers.
  - GnuPG makes that directory whenever it is asked about a home, also after its agent has ended. The frame asks only while an agent is expected, and removes the directory wherever it ends an agent: `build` after each key, `up` where it stops before its first term, and `down`. `up` records the directory in the ledger before it starts the agent.
  - No build, run, status or refusal leaves a runtime socket directory of a key home. The tests find a directory by the name GnuPG gives it, the base32 of the home's SHA-1, and never ask GnuPG after an agent has ended.
- **C43.** `status` lists each agent with its key and process id. It exits 1 when one is gone, saying that the seat cannot sign until the workplace is brought down and up again.
  - `why` names a seat's key and the term that gives it, and the masks on R and on the runtime directory's `gnupg`.
  - `doctor` reports GnuPG and its floor, the state directory and the length it leaves for a workplace's name, and the runtime directory.
- **C44.** GnuPG's floor is 2.4.4, the CI image's, and only a plan in which a seat holds a key needs it. An older gpg refuses such a build with exit 2, naming both versions.

## A seat's home and the values at run time

- **C45.** The fold reads four terms of the plan's `recorded` lists.
  - `home KIND VARIABLE STATE`: a seat of the kind has a home, named to its program through VARIABLE. STATE is `kept` or `scratch`.
  - `home-variable KIND NAME SUBPATH`: a further variable, given the directory SUBPATH inside the home. SUBPATH is relative to the home, with no empty, `.` or `..` component; `.` alone is the home.
  - `home-seed KIND PATH`: a program that `build` runs for each kept home it makes. PATH is a path position of C4.
  - `expect A B C SCOPE NAME`, with SCOPE `workplace`, `office`, `room` or `seat`: the seats of that scope expect the value NAME, an environment variable, at their start. A seat expects the union of the names that the workplace, its office, its room and its own terms state; none takes a name away, and equal terms count once with all their origins.
  - `view.json` gives a seat of a kind with a home `home: {kind, variable, state, variables, seed, origins}`, and a seat that expects a value `expects: [{name, scopes, origins}]`, by name. A seat with neither has neither member, so the view of a plan without these terms is the one the fold gave before.
  - It refuses, naming the origins: a kind no seat has and the plan does not declare; a name that is not a variable name; a state other than `kept` or `scratch`; two homes, two variables of one name or two seeds of one kind that differ; a variable or a seed for a kind with no home; a variable that is the home's own; a seed for a scratch home; an expect of a place the plan does not make or of another scope. A refusal that rests on two terms names the origin of both: a variable that is the home's own names the variable and the home, and a seed for a scratch home names the seed and the home.
  - A kind's name and a seat's keys are each one directory of its home's name, since none is empty, `.` or `..` or holds `/` (C67).
  - The names the frame keeps are the binding's `kept-names`, the names its fixed part gives a seat itself: `GNUPGHOME` and `SSH_AUTH_SOCK`. A home's variable, a further variable or an expected name that is one of them is refused. So is an expected name that the binding passes on from the caller, such as `HOME`, since that would cover the value; a home may use such a name.
  - It refuses a seat that expects a name its kind's home gives it, naming the seat and both origins.
- **C46.** A home is named by its seat's kind and keys, never by the seat's place among the panes: `S/homes/KIND/A/B/C`. No two seats share it, since a key holds no `/` and none is `.` or `..` (C67). `build` makes a kept home with mode 0700, each directory above it in `S/homes`, and `S/homes` itself, also 0700, and keeps it across builds.
  - A new order of the panes moves no home. A seat whose kind changes is given the home of its new kind, and its old home stays where it was, shown to no seat.
  - `S/homes.json`, the frame's record with mode 0600, names the seat of each kept home by the home's name, `KIND/A/B/C`. `build` refuses, naming both, a home that the record gives another seat, and a directory that the record does not name, which it leaves alone.
  - A scratch home has the same path and nothing on the machine.
  - `BUILD/homes.json`, listed in `BUILD/MANIFEST`, holds for each seat with a home its keys, name, kind, state, home's name, path and variables.
- **C47.** For each kept home that `build` makes new, it runs the kind's seed once, under `setpriv --no-new-privs`, in the home, with nothing on standard input. Its words are the home, then the seat's start directory, then its declared directories, joined, each once: the start's directory is the seat primitive's, and the declared ones are the recorded term that the binding's `directories` names, `record-directory`. A directory that is both the start and a declared one stands once, first, and a seed is given no mark of which word is which. Its environment is the inherited names and the home's variables.
  - It never runs for a home that exists, so a seat whose start directory changes later has its home seeded by hand. The record keeps the words each home was seeded with, and a later build that finds other words for the seat says so in one line, naming the seat and both sets of directories; it does not refuse and does not seed again. A home whose seed did not finish is made and seeded again.
  - A seed that fails refuses the build, with exit 1, naming the seed, the kind, the seat, its exit and what it said last: the last five lines of its output and errors together that are not empty, joined by spaces. Its new home is removed. A seed that is not an executable file refuses the build before the home is made.
  - `build` makes each further variable's directory in a kept home, mode 0700: when it makes the home, before the seed runs, and where one is missing in a home that exists. It goes down from the home one name at a time and makes what is missing. At a link, or at something that is not a directory, it makes nothing for that variable, and says so in one line naming the variable, the seat and the path. It makes none in a scratch home (the limits).
- **C48.** After the rows and inside the mask on R, the binding's fixed part shows a seat its home at the home's own path: a kept home read-write as the machine's directory, and a scratch home as a file system of mode 0700 made when the pane starts, empty, of which nothing is left when the pane ends. No other seat is shown it.
  - The frame gives the seat, after the environment's cell, the kind's variable with the home's path, and each further variable with its path inside the home.
  - A seat's further variables stand in the code-point order of their names, after the kind's variable: in `view.json`, in `BUILD/homes.json`, and in the environments of the seed and the seat.
  - `plan` refuses, with exit 1 and leaving `PLAN/` as it was, a plan whose environment cell sets for a seat a name that the frame gives it (a key's two names, its home's variables) or a value the seat expects, naming the seat, the row's origin and the term's. `build` keeps its own check of the same, for a plan written by hand.
- **C49.** The run-time file is `S/values.json`, mode 0600, written by the desk lead and never by the frame. It is an object with `workplace`, mapping names to values, and `offices`, `rooms` and `seats`, mapping a place written `A`, `A/B` or `A/B/C` to names and values. A value is text of one line that is not empty: an empty one, or one with a line end or a NUL byte, is refused, naming the name and never the value. A name in the file that a seat does not expect is not given to it.
  - `up` and `exec` give a seat each value it expects from the narrowest place that has it: the seat, its room, its office, the workplace. Changing a value needs no new plan and no new build.
  - `up` refuses, with exit 1 and before it starts anything, a run-time file that others than its owner may read, one of another owner or form, and a seat that expects a value the file does not give, naming the value and the seat. `exec` refuses the same, with exit 2.
  - `exec` gives the values through the environment of `env`, which fills each value's place in one `-S` word and clears every other variable. No value is a word of any program's command line.
- **C50.** No value is ever shown. A message, the ledger, the run's checks, calls, state, slots and seats' records, `BUILD`, the server's environment, `status`, `why`, `doctor` and the call that `exec --print` prints carry a value's name and never the value. In the printed call each value's place is `NAME=${WORKPLACE_VALUE_NAME}`.
- **C51.** `status` names each seat's home and its state, each name a seat expects with the place that gives it, and the mail's store with the count of requests that wait in the seats' `out`. It exits 1 for a kept home that is missing, a value that is missing, or a run-time file it refuses.
  - `why` names the seat's home, its variables and seed with their terms, says that a path in the home is the seat's own, and names each value the seat expects with its terms and whether the file supplies it.
  - `doctor` reports `env -S`, the run-time file of the workplace that `WORKPLACE_CONFIG` names, and the count of its homes, without a value.

## The clone

- **C52.** In every view the binding's fixed part masks the clone the workplace is built from, `WORKPLACE_CONFIG`, with its `PLAN` and `BUILD`: closed (0000), after the rows and before the other masks, also where the path was absent.
  - For rule 6 the mask counts as a hidden row at the clone in every seat's table: `plan` and `build` refuse, with exit 1, naming the seat, the path, its state and origin, a row other than hidden at or beneath the clone.
  - `plan` and `build` refuse, with exit 1, naming the term or its origin, a seat whose directory, its start's or one it declares, or whose program lies at or beneath the clone.
  - A kind's seed may lie in the clone, since `build` runs it outside every view.
  - `why` names the mask for a path at or beneath the clone.

## A server belongs to one clone

- **C53.** The `session` term marks its server with the clone, as the global user option `@workplace-clone`. The mark lives in the server's memory and nowhere else, so it ends with the server.
  - The server's socket stands in the clone's `RUN` (C68). So when `up` starts, no other clone's server and no earlier run's stands there, and two clones that name the same server each have one of their own.
  - `status` reads the mark, and exits 1 for another clone's mark or for none. A server that lost its mark is told from one that never had it by the process id that `up` records once its terms are applied: the run's own process with no mark is reported as such, and another process as another.
  - `down` refuses, keeping `RUN`, a server that carries another clone's mark. For a server with no mark it says so and goes on, since each undo checks its own mark.
  - The mark is the clone's resolved path, so a clone is moved only while its workplace is down.

## The Comms layer: mail, grab and write

- **C54.** The fold reads `mail PATH`, once for the workplace, and `reach A B C SCOPE ACTION TA TB TC TSCOPE STATE`. ACTION is `mail`, `grab` or `write`, STATE is `allowed` or `banned`, and each scope is `workplace`, `office`, `room` or `seat`, with `-` for the keys it does not use.
  - For one asking seat, one action and one target, of the terms whose scope holds the seat, whose target holds the target and whose action is that one, those of the narrowest asking scope are taken, and among them the one of the narrowest target. Its state decides. With none, a seat may mail every seat, and may grab and write none. No clearance is read.
  - `view.json` gives the mail path with its origins, and each seat `reach`: for each action, the names of the seats it may reach, in the plan's order. `plan` prints the path and, for each seat and action, those seats, each with the origins of the terms that decide it.
  - `plan` refuses, with exit 1, leaving `PLAN/` as it was and naming the origins:
    - a term of the wrong form, scope or state, or one that names what the plan does not make;
    - the action `record`, which the Logs layer brings;
    - two `reach` terms equal in asking scope, target and action with different states, and two `mail` terms with different paths (equal ones count once);
    - `reach` terms with no `mail` term;
    - a seat with no row for `/` in a plan that holds either term, since a seat with no view could write as any seat.
- **C55.** After the rows, the binding's fixed part shows each seat its own mailbox at the mail path: a file system there, holding `out` read-write; `in`, `sent` and `answers` read-only; and `README.md`, the frame's page for a seat (C97), read-only; and read-only itself. No seat is shown another seat's.
  - `plan` refuses, with exit 1, naming the origins: a statement or a label at the mail path or beneath it; a mail path that is `/`, lies at or beneath the clone, or lies beneath a hidden row of a seat's table, which the seat could not pass; and a seat whose directory or program lies at or beneath it.
  - `build` refuses a mail path that is not a directory on the machine, and one that lies in the workplaces' state directory R or holds it. It refuses one that holds a control character, a character that moves or breaks a line, or bytes that are not UTF-8, as C58 refuses them in a head, since the pointer types the path into every seat's pane (C94). `up` refuses one that is no longer a directory.
  - Each of these refusals names the origins of the `mail` term beside those of what conflicts with it.
  - `why` names the mailbox for a path at or beneath the mail path.
- **C56.** The store stands in S, which no view holds. `build` makes it once and keeps it.
  - `S/mail` is a git repository made with no template, whose branch is `mail`. For each seat it holds a directory named by the seat's three keys joined by a space, with `in` and `sent`. A key may be `.git`, which git refuses as a path's component, and a key holds no white space, so the joined name is one seat's and is never git's.
  - Beside it, `S/comms` holds for each seat `out` and `answers` under the same name, `taken`, where the carrier keeps what it takes, the record, and `wake.json`, where it keeps the mail each reader has to be pointed out (C94). Every directory is the user's, with mode 0700, and the record and `wake.json` have mode 0600.
  - `BUILD/mail.json`, listed in the MANIFEST, holds the mail path with the origins of its term, S, and each seat's mailbox and reach, and, for a seat whose kind has a wake, its pattern (C93).
  - `BUILD/seat-page.md`, listed in the MANIFEST, is `build`'s copy of the frame's page for a seat (C97).
  - A plan that holds mail needs git 2.32 or later, `flock`, `dd`, `mv`, `tail` and `date`. `build` and `up` refuse it with exit 2 when one is missing, naming it. A plan without mail needs none of them.
- **C57.** The carrier is one process for the workplace, `workplace carry`. `up` starts it after the agents and before the first term, under `setpriv --no-new-privs` and in no view, and records it in the ledger and in the checks.
  - Its working directory is `RUN/carrier`, which is its mark. `down` ends it only while the process's working directory is that directory, waits until it has ended, and says it is gone when it is. A carrier whose mark is gone, its run directory removed under it, ends of itself at its next pass.
  - It holds a lock on the store, so a second carrier for the same store ends with exit 2.
  - It takes no request until `up` has recorded the run. Then it makes a pass a second, serving the seats in the plan's order, one request of each per pass, and each seat's requests in the byte order of their names.
  - `status` names it, and exits 1 when it is gone, saying that requests wait. It counts the requests that wait, in all and for each seat that has any. While it is gone, requests wait in `out` and none is lost: the next carrier serves them. A request it was serving when it stopped is answered when it starts again.
  - A request taken while it is still being written would be delivered cut short. Two rules prevent it:
    - An entry whose name begins with a dot is the seat's draft, and the carrier does not take it. A seat that wants certainty writes `.NAME` and renames it to `NAME`.
    - The carrier takes an entry only once its change time is at least one second old, so a request that a seat's file tool writes under its final name rests until it is whole. Until then the carrier takes nothing of that seat, so its requests keep their order.
- **C58.** A request is one regular file in `out`, named with letters, digits, dot, dash and underscore and ending in `.md`, `.grab` or `.write`, of at most 256 kB, which is 256,000 bytes.
  - Its head is lines `WORD: VALUE`: at most 20, each word once, of the words its kind knows, with no control character, no character that moves or breaks a line, and no bytes that are not UTF-8.
  - Every request gets an answer in `answers`, under its own name: `ok` and the request's id, or `refused` and the reason in words. A refused request does nothing.
  - The carrier refuses: a name of another form; an entry that is not a regular file; a file it cannot read at once; a larger file; a head of more than 20 lines, one with a line it does not know or a word twice, and one with no reader, subject or seat; a reader or seat the plan does not make, by its exact name; an action the table does not allow; a count outside 1 to 5,000; a text that is not one line, of more than 4,096 bytes, or with a control character; and a key outside the list.
- **C59.** A mail, `.md`, is a head with `to` and `subject`, and optionally `cc`, `re` and `reply`; a line of three dashes; and the body. `to` and `cc` name its readers, separated by commas, as the panes name them. If one reader is refused, the mail goes to none.
  - The carrier writes one file, `ID.md`, into each reader's `in` and into the writer's `sent`. Each holds `id`, the carrier's own time as `at`, and the writer as `from`; then the writer's other lines as they stood, with the writer's own `from`, `id` and `at` dropped; then the dashes and the body, byte for byte.
  - The delivery is one commit, by the carrier, and no commit is rewritten.
- **C60.** A grab, `.grab`, names `seat` and optionally `lines`, which is 200 unless stated and at most 5,000. Its answer is `ok`, the id, and what the pane showed: that many lines of history above the screen, and the screen.
  - A write, `.write`, names `seat` and optionally `key`, then has the dashes and one line of text. The carrier types the text into the pane as it stands, with `send-keys -l` and a trailing `;` escaped. Then it rests one second, looks at the pane again, and sends the key in a call of its own: `Enter`, unless the head names `Escape`, `C-c`, `Tab` or `none`.
  - The key goes apart because a program that reads one burst of input as a paste takes an `Enter` that comes with the text as a new line in what it holds, and the line is not submitted. The rest is the one that was measured to submit with the real program. During it the carrier does nothing else.
  - When the carrier looks again and the pane is gone, no longer carries the run's mark, is in a mode, or runs another program than before, it sends no key. The text stands typed and not submitted. The write is refused, its answer and its record say that the text was typed and its key was not sent, and why, and the record holds the text's length and SHA-256.
  - Both act only on the pane that the run captured for that seat, and only while its session carries the run's mark.
  - A write is typed only into a pane that tmux shows in no mode (`#{pane_in_mode}`). A pane in a mode, such as copy mode, takes the keys itself and its program reads none, so a write to it is refused and recorded, with a reason that names the mode.
- **C61.** The carrier moves an entry out of `out` into `taken`, which no view holds, by renaming it, before it looks at it. Before the move it reads the entry's name and its change time, and nothing else: not its content, not its kind. It never opens a name inside a seat's reach. It starts only when every `out` lies on the file system of `taken`, so that a move is never a copy.
- **C62.** It takes only a regular file. A link, a directory, a fifo, a socket or any other kind of entry is answered as refused and removed.
- **C63.** It reads the moved file once, into a file of its own, and works on that copy. The read follows no link, does not block, and stops one byte past the limit. What a seat changes afterwards through another name of the same file changes nothing, and a file held under a lease is refused at once rather than waited for.
- **C64.** It runs nothing that a request names. Names are compared with the plan's exactly, as text. A head, a name, a text or a body is never read as an option, a pattern, a format or a command: the text is typed literally, paths reach git as literal paths, and no word of a request reaches a shell.
- **C65.** The store runs no hook, and no seat can write into it. Git runs with a cleared environment, no system or user configuration and `core.hooksPath` set to `/dev/null`, so neither a hook in the repository nor the user's configuration runs. No view shows S.
- **C66.** The record is `S/comms/record`: one line of JSON for each request, served or refused, with the time, the id, the seat that asked, the request's name, the action, the target, the outcome and a refusal's reason. A write's line also holds the length and the SHA-256 of its text. Each pointer of the wake is one line of it too (C96). No line holds a body, a capture or a text. The mail's own record is its repository.

## Keys and names

- **C67.** A key of an office, a room or a seat, and a kind's name, is not empty, is not `-`, `.` or `..`, does not begin with `-`, and holds no `/`, no white space and no control character. `plan` and `build` refuse one that is, with exit 1, naming the term or the row. A name is one seat's alone: `plan` and `build` refuse two seats of one name, naming both terms. A seat's name, in every plan, is not empty, is not `.` or `..`, and holds no `/`, no comma and no control character, and neither begins nor ends with white space: `plan` and `build` refuse one that is, naming the term. The Logs layer uses a name as a directory's name, and a mail's head separates its readers by commas.


## No seat reaches a tmux server

- **C68.** The workplace's tmux server listens at `RUN/NAME`, in the clone, which no view holds (C52), and every tmux call of the frame names that socket by its path. `up` refuses, with exit 2 and before it starts anything, a socket path of more than 107 bytes, naming the path and its length.
  - After the rows, in every view, the binding's fixed part masks the user's own tmux socket directories, `${TMUX_TMPDIR:-/tmp}/tmux-UID` and `/tmp/tmux-UID`, closed (0000), where they exist.
  - So from a seat's view neither the workplace's server, tried by its real path, nor another tmux server of the user answers, though a row shows the places above them read-only.
  - `why` names the mask. `down` removes `RUN`, and the socket with it: tmux leaves its socket file however its server ends.

## The Logs layer: what a pane showed, kept and chained

- **C69.** The fold reads `record A B C SCOPE WHAT STATE`, `record-limit BYTES`, `record-chain SINK` and `record-path PATH`, and `reach`'s fourth action, `record`.
  - WHAT is `pane` or `programs`, STATE `kept` or `none`, and the scopes are a key's: the narrowest that speaks decides, and with no term nothing is kept. The limit is a whole number of bytes a seat's pane may fill in a day, 268,435,456 (256 MiB) by default. The sink is `journal` or `file`.
  - `view.json` gives `records`: the path, the limit and the sink. Each seat gets `record`, with whether its pane is kept, and `reach.record`, with the seats whose record it may read. With no term a seat reads no record, its own included.
  - `plan` refuses, with exit 1, leaving `PLAN/` as it was and naming the origins:
    - a term of the wrong form, scope, WHAT or state, a limit that is not a whole number above 0, or a sink the frame does not know;
    - `record … programs kept`, since the record of programs is built after the cutover;
    - two `record` terms of one scope and one WHAT with different states, and two `record-limit`, `record-chain` or `record-path` terms that differ;
    - `reach … record` with no `record-path`;
    - for the record path, everything it refuses for the mail path (C55), each naming the origins of the `record-path` term where C55's names those of the `mail` term, and a record path at, above or beneath the mail path;
    - a kept record of a seat with no view, since such a seat could reach its own record.
  - `plan` prints the records, whether each seat's pane is kept, and whose records it may read.
- **C70.** `build` makes `S/records`, and in it one directory for each seat, named by its keys joined by a space, each the user's with mode 0700.
  - A seat's directory holds one file for each day by UTC, `DAY.pane`, and `unstored` and `gaps`, which only grow. `S/records` holds the carrier's `chain.state` and the file sink's `chain`.
  - `BUILD/records.json`, listed in the MANIFEST, holds the path with the origins of its term, the limit, the sink, the carrier's unit, and each seat's directory, its pane's state and whose records it reads.
  - `build` refuses a record path that is not a directory on the machine, or that lies in the state directory R or holds it, and `up` one that is no longer a directory. Each names the origins of the `record-path` term.
  - A plan that keeps a record needs `dd`, `date`, `tail` and `head`. One whose chain goes to the journal needs `systemd-run`, `systemctl` and `journalctl`.
- **C71.** `up` sets each kept pane's pipe after the pane terms and before the first start, so nothing the pane's program writes is missed. The pipe is `pipe-pane -O` into a keeper of the frame's, `workplace keep DIR LIMIT`.
  - The keeper runs outside every view, as a child of the server and under its no-new-privileges, and it ends with its pane. The pipe outlives the start's `respawn-pane`.
  - The pipe's command quotes each word for the shell, and doubles its `%` and `#`, since tmux expands both in it.
  - The keeper stores what the pane's program wrote, byte for byte, with `dd`, a chunk at each read. It takes the day from `date -u` whenever the second changes, and changes the file itself at a change of day, so the pipe is set once. Setting it again loses lines: 2 in 20, measured.
  - At the limit it stores nothing more that day and counts what it does not store. When that day's file ends, at a change of day or when its pipe closes, it appends `DAY COUNT` to `unstored`. On tmux 3.8 a pane's pipe closes when its program ends; C98 says what tmux before 3.8 does.
- **C72.** With a sink, the carrier sends one entry for each kept file, every ten seconds and twice as it ends: for what was appended since that file's last entry. The kept files are each seat's day files, `unstored`, `gaps` and `signed` (C91), and the frame's record of requests (C66).
  - An entry is `{chain: "workplace-record", at, workplace, mark, seat, file, offset, length, hash, previous}`.
  - `mark` is the state directory's: 32 hexadecimal digits that `build` draws at random into `S/records/mark` when it is missing, and keeps across builds. `build` refuses a mark that is not a file holding 32 hexadecimal digits.
  - Its hash is the SHA-256 of `previous`, written as 64 lowercase hex digits, followed by the bytes from `offset` for `length`. Before a file's first entry, `previous` is 64 zeros.
  - The carrier keeps each file's offset and last hash in `chain.state`, across runs.
  - **The file sink:** appends each entry, one line of JSON, to `S/records/chain`.
  - **The journal sink:** `up` starts the carrier as a transient unit of the user's manager, `workplace-carrier-NAME.service`, under `NoNewPrivileges` and `setpriv`, and refuses where no manager answers.
    - The ledger marks the unit by its invocation id, and `down` stops it through its manager: the unit is inactive when `down` returns.
    - The unit's `KillMode` is `mixed`: stopping it signals the carrier alone, which sends its last entries and ends. The programs it runs to hash an entry are not cut off, so no entry goes out with its hash missing.
    - The unit sets `SyslogIdentifier=workplace-carrier`, so the carrier's entries carry that identifier. `record verify` reads by unit and does not rest on it.
    - The carrier writes each entry on its standard output, which the manager hands to the journal stamped with the unit.
    - A run of the tests' own leaves about five lines of the carrier's in the journal, beside the manager's own lines about the unit.
- **C73.** In every view of a workplace that keeps a chain, the fixed part masks, after the rows and closed, `/var/log/journal`, `/run/log/journal` and `/run/systemd/journal`, where they exist. `plan` and `build` refuse a row other than hidden at or beneath one of them, naming the seat, the row and its origin, as at the clone. The user manager's socket and the session bus are closed in every view by C84.
- **C74.** On each pass the carrier reads every kept pane's pipe. Where one is gone, it sets it again and writes the time to the seat's `gaps`. It does not end the seat.
- **C75.** `status` names, for each kept seat, its day file, its size against the limit and the byte the chain has reached, and, with the run up, its pane's pipe. It exits 1 for a pane without its pipe and while the sink's last entry was refused.
  - A refused entry moves nothing forward: the next entry the sink takes covers the same bytes, so a refusal leaves no hole.
  - Once the sink takes an entry again, `status` exits 0 for it, and names the time of the last refusal for the rest of the run.
  - `record verify NAME [DAY]` reads the seat's day file, today's by UTC by default, against its chain, taken from the plan's sink. From the journal, it takes only the entries whose `_SYSTEMD_USER_UNIT` is the carrier's unit and whose `mark` is the state directory's.
  - The carrier's unit is named by the workplace's name alone, so a workplace of the same name with another state directory sends its entries under the same unit. Its entries carry its own mark, and `record verify` passes over them. The file sink stands in S, so its entries are the state directory's by their place.
  - A build made before the mark holds no `mark` in `records.json`, and its carrier, which is the build's own loop, sends entries with none. `up` refuses such a build when its chain goes to the journal, with exit 1, and `record verify` with exit 2, each saying to build again.
  - It takes only the entries sent within the file's day and ten minutes on either side of it: from the journal it asks for that span alone, and from the file sink it takes the entries whose `at` lies within it. Its cost follows one day's entries, not the unit's whole history. Ten minutes hold the carrier's ten-second interval and a long pass of it many times over, so the entries of a day's last bytes stand within them. An entry sent later, by a carrier that was stopped without warning and started again after the margin, stands outside, and verify then says that the file's last bytes are not covered yet.
  - `record verify NAME unstored`, `gaps` or `signed` reads that file of the seat, and `record verify --requests` the frame's record of requests (C66), each against its chain. These files are not a day's, so verify reads their chain over its whole span: from the journal, every entry of the unit, which 5.98 measured at about 4.5 seconds for each 100,000 entries.
  - It names the first place where file and chain differ, or says that they agree and up to which byte.
  - It exits 1 where they differ, and 2 for a seat it does not know, a day not written YYYY-MM-DD that is none of those three names, a workplace with no chain, and `--requests` in a workplace that holds no mail.
- **C76.** In a plan that holds a record path, the fixed part puts the frame's read-only file system at the record path in every seat's view, after the rows, whatever the machine holds there and whatever a row says above it. It holds one read-only directory for each seat whose record the seat may read, under that seat's name, and for a seat that may read none it is empty. `why` names it, and says for a seat that may read none that it is empty.
  - Since a seat with no view has no view to hold it, `plan` refuses, with exit 1, a seat with no row for `/` in a plan that holds a record path, naming the origins of the `record-path` term.
- **C77.** No seat writes, cuts short, renames or removes a record, its own or another's, or makes a file beside one. A record stands in S, which no view holds, and the record path shows it read-only.
- **C78.** A seat that may read one seat's record reaches no third seat's through it, by a link, by `..` or by a name built for it. The record path holds only the directories the seat may read, each bound alone, and S is masked.
- **C79.** A pane's bytes are stored as they came: NUL bytes, bytes that are not UTF-8, formats, commands and escapes. None is read as a pattern, a format or a command by the keeper, the carrier or `record verify`: the keeper copies bytes, and the chain and `record verify` hash them.
- **C80.** `record verify` names a byte changed, a file cut short, a file removed and a line added in the middle, each at the first place it shows: the entry whose bytes no longer hash as sent, the byte where the file ends, or the file's absence.
- **C81.** A change of day loses nothing and doubles nothing. Measured: 3,000 lines, one a millisecond, across a forced change of day, each kept once and in order.
- **C82.** At the limit nothing more is stored that day, and the count of what was not stored is exact.
- **C83.** With the journal as the sink, an entry that another process sends under the carrier's words is not taken as the carrier's. `record verify` reads only the entries the journal itself stamps with the carrier's unit.

## The user's runtime directory

- **C84.** In every view, chain or none, where the seat's rows would show `/run/user/UID` as the machine has it, the nearest row at or above it being `read-only` or `read-write`, the fixed part puts there, after the rows, an empty file system, made read-only once the frame has put beneath it what it gives the seat.
  - **Why:** the user's manager answers there, through its own socket and over the session bus, and starts a unit outside every view for any caller of the user's; the user's ssh agent, the first program's sessions and the desktop keep their sockets there too.
  - **What it holds:** only the seat's own `hidden`, `searchable-only` and `scratch` rows beneath it, mounted again after the mask, and whatever the frame gives the seat beneath it. A seat's key agent is shown in its key home (C39), so a seat signs under the mask, and under a `hidden` row at the runtime directory as well.
  - **Rows:** a `hidden`, `searchable-only` or `scratch` row at the runtime directory stands as the text wrote it, and no mask is put there. `plan` and `build` refuse a `read-only` or a `read-write` row at or beneath it, naming the seat, the row and its origin, as at the clone. `why` names the mask, and the seat's rows beneath it that stand.

## An ssh key granted to a seat's agent

- **C85.** The fold reads `ssh-key NAME PATH` and `ssh-grant A B C SCOPE NAME STATE`. NAME is a word under the rule for a key of an office. PATH is as written, and the frame joins a relative one to the root. SCOPE is `workplace`, `office`, `room` or `seat`, with A, B and C as for `key`, and STATE is `granted` or `none`. For each NAME the narrowest scope that speaks decides, and with no term nothing is granted. A plan that holds either term is folded, so every seat of it has a view.
  - It refuses, naming the origins: two `ssh-key` terms of one NAME that differ, two `ssh-grant` terms of one scope and one NAME with different states, a NAME that no `ssh-key` term declares, a grant at a seat's own scope to a seat that holds no key, and a word, a count of words or a scope that the terms do not take.
  - It refuses a key's file that any seat's table shows read-only or read-write, naming the seat, its row and the key's term: no seat is shown the file of a private key.
  - A grant of a wider scope reaches the seats of that scope that hold a key. `plan` prints each key with its file, and, for a key that no grant takes to a seat that holds a key, that it reaches no seat. It prints for each seat the names it is granted, with their terms, and, for a seat of the scope that holds no key, that the grant does not reach it. `view.json` gives each seat `ssh: {granted, unreached}`, and the keys under `ssh.keys`.
- **C86.** `build` checks the file of each key that reaches a seat, once and before it makes any key home, with `ssh-keygen -y` and an empty passphrase, under `setsid` with nothing on standard input. It refuses with exit 1, naming the key and its file: a file that is missing or is not a regular file, one that asks for a passphrase, one that ssh does not read as a private key, an RSA key under 2048 bits, a security key's file, and any kind but ed25519, RSA and ECDSA on nistp256, nistp384 or nistp521.
- **C87.** For each holding seat that a key reaches, `build` loads the key into the seat's home, after the seat's own: through an agent of the home started with `--batch` on its command line, by `ssh-add` reading the file on its standard input, and it ends that agent. The file is read by `build` alone, outside every view: once for the check and once for each seat, and nothing of it is kept between the reads.
  - The home gains one unprotected key file per grant, and its grip in `sshcontrol` after the seat's own, which the agent offers first. `sshcontrol` is made read-only once the keys are loaded (C35).
  - The home gains `ssh/NAME.pub` for each grant, read-only: the public OpenSSH line with NAME as its comment.
  - `keys.json` gives each holding seat `grants`: for each, its NAME, that line, its SHA256 fingerprint, the grip of the key and its kind. No byte of a private key stands in `BUILD`.
  - The copy in a home is a key of that build: every build removes the old homes, and their copies with them (C36).
- **C88.** The agent of each home has `disable-scdaemon`: no smartcard daemon runs for it after a listing.
- **C89.** `up` refuses with exit 1, naming the file, a home whose `gpg-agent.conf` says `batch`, and a machine whose `gpg-agent.conf` in GnuPG's system directory says it, since every agent reads that file and an agent with `batch` takes any key added through its ssh socket. It checks that each agent offers every key the build loaded for it, refuses where one does not, and records the agent's answer among the run's checks.
- **C90.** A seat that a key reaches is shown, in G at `ssh/`, the public files of its keys, read-only. Through its ssh socket it lists each granted key after its own and signs with it.
  - A key loaded on standard input shows the file's own comment, or `(stdin)`, and never a path. A seat tells its keys apart by their public files.
  - Through the two sockets it is shown it obtains nothing of a granted key, adds none and removes none, as for its own (C41). No file of the key stands in its view.
  - Its ssh configuration, which the workplace's text writes, names the key's public file for each host and offers only that one. A host that allows one try logs it in so, and refuses an agent that offers every key, since the agent offers the seat's own first.
- **C91.** Where the plan keeps a record, each holding seat's agent logs at `-v` to `signed`, in the seat's directory of records, with its times in UTC, and the carrier chains `signed` among the kept files (C72). After an ssh signature it holds a line with the second, and nothing of the key or of the data.
- **C92.** `status` lists each agent's granted keys by name, and exits 1 when an agent no longer offers one that the build loaded. `why` names a seat's grants, the terms that give them and their public files, and for a seat that holds no key, the grants that do not reach it.

## The wake: a delivered mail pointed out to its reader

- **C93.** The fold reads `wake KIND PATTERN`, once for a kind. PATTERN is a POSIX extended regular expression, matched as bash's `=~` matches it in the loop's C locale, byte by byte. With no term a kind's seats are not woken. A plan that holds the term is folded.
  - `view.json` gives each seat of the kind `wake`, with the pattern and its origins, and `plan` prints it for each such seat.
  - `plan` refuses, with exit 1, leaving `PLAN/` as it was and naming the origins: a term of the wrong form; a kind the plan does not make; an empty pattern, which finds every screen ready; two terms for one kind with different patterns, while equal ones count once; a pattern that bash refuses; and a wake with no mail term. `build` refuses a pattern that bash refuses in a plan written by hand.
- **C94.** Once the carrier delivers a mail to a reader whose kind has a wake, that reader has mail to be pointed out, unless the reader is the mail's writer. A mail that a seat sends itself is delivered and is not pointed out: the count and the newest id come only from mail whose writer, as the carrier writes it in `from` (C59), is another seat. After each pass, for each such reader that had no pointer in the last minute, the carrier looks at the visible screen of the reader's pane, never at its history.
  - The pane is ready when tmux shows it in no mode and one of the last five lines of that screen that are not empty matches the pattern. Then the carrier types one line, and `Enter` after it in a call of its own a second later, through the function that types a write (C60): `mail: N new, newest ID.md, in PATH/in, and the page PATH/README.md says what this line is`. N is the count of mail delivered to that reader since its last pointer, in decimal, ID is the newest one's id, and PATH is the mail path, where the seat sees its mailbox. Then nothing is left to be pointed out to that reader.
  - The function types every mail path that `build` takes as it stands. `build` refuses one with a character that moves or breaks a line (C55), and `send-keys -l` types the rest literally: a space, a comma and a `;` inside the line, measured byte for byte. The line ends in `README.md` and so never in `;`.
  - That function checks the mode too, beside the mark. A pointer that meets a mode there is recorded as refused, and its mail stays to be pointed out.
  - What is to be pointed out outlives the run. It stands in `wake.json`, and after `down` and `up` the carrier goes on from it, with the same count and the same newest id.
  - It types nothing else of its own accord, and nothing into a pane that is not ready. The line holds no byte that a seat wrote: the count, the id and the mail path are the frame's own, and a mail's subject, body and writer, and a request's name, do not enter it.
  - At most one pointer goes to a reader in a minute.
- **C95.** `status` lists each seat with mail to be pointed out: how many, by the same count, and the time the first was delivered. A seat's own mail puts it in no list. A seat that works, that sits at a question of its own program, or whose pane is in a mode, stands in that list until its pane is ready. `status` does not exit 1 for it.
- **C96.** Each pointer is one line of the record (C66): the time, `the frame` as the one who asked, the action `wake`, the reader as its target, the ids it covers, the outcome, and the length and SHA-256 of the line typed.

## What a seat is told about mail: the frame's page

- **C97.** Every mailbox holds `README.md`: the frame's page for a seat. Its text is `share/seat-page.md` in the frame's repository, the same in every mailbox, and it names no seat, no workplace and no path.
  - `build` copies it into `BUILD/seat-page.md` when the plan holds mail, and a plan without mail gets none. The fixed part shows that copy at `PATH/README.md`, read-only, in the mailbox's file system, which is read-only too, so a seat can neither change the page nor put another in its place. `up` refuses a build with mail that holds no page.
  - The page says what the pointer's line is and that no person typed it; what the four parts of a mailbox are; that the frame writes `id`, `at` and `from`, and that `from` is a sender's only identity; how a mail is sent and where its answer stands; that grab and write exist and are refused where they are not allowed; the form of each, as C60 gives it, and what its answer holds; and that a `C-c` ends a pane whose program is plain, and its seat with it.
  - The forms of a request are defined here, in C57 to C60, and told to a seat by the page alone. Every suffix and every word of a head that the page names is one that the carrier takes.

## Starting a seat again, and removing a build

- **C98.** A seat's pane stays when its program ends, dead and in its place: `start` sets the pane's `remain-on-exit` before it starts the program. Its id, its place in the window, the session's mark and the carrier's slots stay as they were. `status` names the seat as gone and exits 1. The carrier types nothing into a dead pane and does not set its pipe again.
  - **What becomes of the pane's pipe.** tmux 3.8 closes a pane's pipe when its program ends, so the keeper ends with the program and writes its count (C71). tmux 3.5a to 3.7c keep a dead pane's pipe open: their `server_destroy_pane` closes the pane's terminal and not its pipe, and `pipe-pane` refuses a dead pane. In the pipeline on 3.5a, a pipe set on a pane stayed open after its program ended, and its reader had no end of its input until the server ended; and in the frame, a keeper of the dead pane's record still ran after its program had ended. `restart`'s `pipe-pane` closes an old pipe before it sets its own. On both versions the count of what was not stored is exact, and stands once, by the time `down` returns (C82). When it is written on 3.5a while the pane is dead is among the limits.
  - `workplace restart [SEAT ...]` starts again each named seat, or with no name each seat whose program has ended, and leaves every other pane as it is. For each, it makes the pane ready with a waiting program, sets a kept pane's pipe as `up` does, and runs the seat's own start from the run's calls again: the same view, environment and command.
  - It refuses what `up` refuses, and then starts nothing: a build that does not verify; a missing program; a server that is not the run's; a seat whose start `exec --print` refuses; values, homes, mail and records as `up` checks them; and any other line of the run's checks that `status` names as gone, the carrier's and the agents' among them. It refuses with exit 2 a seat it does not know, a pane that is gone or lacks the run's mark, and a workplace that is not up, and with exit 1 a seat whose program runs.
  - It records who asked: one line of JSON in `S/restarts`, mode 0600, with the time, the seat, its pane, and the user, the uid and the terminal of the shell that asked, and, for a kept pane, a line in the seat's `gaps`, which the chain covers. It says the same on its output.
  - The mail that waits to be pointed out to the seat stays (C94). Its count and newest id come with the next pointer, once the new program's pane is ready.
- **C99.** `workplace unbuild` removes `BUILD` while the workplace is down. It refuses with exit 1 while `RUN` stands. It names each file it removes and the MANIFEST's hash. With no `BUILD` it says so, and goes on.
  - Then it removes the homes of `S/keys` as every build does before it makes new ones (C36): their runtime socket directories first, which ends any agent of them, then the homes. It names each home and how many files it held. It does so also when no `BUILD` stands and key homes do.
  - It finds S where the build's records name it while `BUILD` stands, and otherwise by the workplace's name (C25): the one that `BUILD/plan.json` or else `PLAN/plan.json` gives when it is `default` or the clone's derived name, and else the clone's derived name.
  - It names the state directory and keeps everything else in it: the seats' homes, the records, the mail's store, the values file and `restarts`. It exits 0.

## Limits, stated and not checked

- A mail's body is carried byte for byte, since mail carries captures and logs, which hold control characters. The head is the frame's, and it ends at the first line of three dashes; a reader takes `from` from the head alone. A mail shown raw on a terminal can draw over its own head, so a mail is read through a program that does not obey control characters, as a seat's file tool does.
- A C-c typed into a pane whose program is plain ends the view with it, before the program's own handler runs: it reaches the whole foreground process group, the view's bubblewrap included, which ends and takes the program with it. A shell with job control and a full-screen program are not touched. It was measured on a workplace of its own: a C-c typed from outside the workplace into the panes of two seats whose programs were plain, with no job queued, ended each within three seconds with its view, nothing started either again, and `status` named both as gone. Such a pane now stays, dead, until `restart` or `down` (C98). The frame does not refuse such a write: a write's key may be `C-c` (C60), and the frame does not tell a plain program from another. That no C-c is written into a plain pane is a rule for whoever writes a write request.
- A read-only row does not close a socket. The fold knows files: a socket that any row shows, read-only included, gives the seat whatever its listener does for the user, and an abstract socket, which has no file, is reached by every seat that shares the machine's network. The frame closes its own: the server's (C68), each agent's (C39), the user's runtime directory with the manager, the session bus and the user's agents in every view (C84), and the journal's where a chain is kept (C73). For the rest, a workplace's text hides the places where the machine keeps sockets: `/tmp` and `/run`. An abstract socket stays reachable: the kernel's Landlock can scope a process to the abstract sockets of its own domain, but neither `setpriv` nor bubblewrap offers that scope yet.
- **A row holds the object at its path, not the name.** It shows the file or directory that stood at its path at `up`, under the row's state, for as long as the seat's view stands, and it does not keep that name on the machine.
  - Beneath a row that shows the machine's directory, whoever writes that directory from outside the seat's view, another seat's view or a process of the user, can put another object at the name: a new file renamed over a file, or a directory removed and made again. The seat's row is then gone, and the seat sees the new object as the parent row shows it. A `read-only` row beneath a `read-write` one becomes writable so, and a `hidden` directory shows what the new one holds.
  - Where a directory lies between a row and its `read-write` parent row, the seat itself can rename that directory and make the path anew. Its row stays on the old object, and the name on the machine is then the seat's.
  - The seat cannot do this to its own row's path, which is a mount point in its view: a removal or a rename over it is refused. A row beneath a `hidden`, `searchable-only` or `scratch` row is not touched, since its mount point stands in a file system that the view made.
- `restart` records the account and the terminal that asked, not the person: anyone who runs the frame as the user can start a seat again.
- **A dead pane's count on tmux before 3.8.** On tmux 3.5a, in the pipeline, a count of what was not stored stood in `unstored` while the pane was dead and a keeper of its record still ran, before `down`; after `down` it stood once and exact. Who wrote it then is not yet measured, and the test prints the keepers it finds and `unstored`, so that the pipeline shows it.
- A process of the user outside every view can stop the carrier or its unit, edit or remove a record, or move a process of its own into the carrier's unit and send under its name. An edit shows to `record verify`, and a stop as a gap in the chain. What the carrier had not sent when it was stopped without warning is the part that no entry covers.
- The keeper takes the day from `date -u` on the path that `up` was given, and the carrier sends its entries every ten seconds and as it ends.
- A keeper that a signal ends does not write that day's count of what it had not stored. The carrier sets the pipe again and records the gap.
- The journal keeps what it is sent within its own rate limit and retention, which are the administrator's. On this machine they are the defaults: a rate limit of 10,000 entries in 30 seconds for a unit, and removal by size and not by age. The carrier sends an entry only for a file that grew in the last ten seconds, so a house of 28 seats sends a few hundred in 30 seconds at the most. An entry that the journal dropped, or has since removed, shows to `record verify` as a skip.
- A seat's home (C47, C48):
  - **A scratch home's further directories.** The frame makes no further variable's directory in a scratch home. The home is empty when its pane starts, and the seat's program makes them. The frame would need an entry of the fixed part that makes a list of directories, which it does not have.
  - **A further variable names a directory, never a file.** `build` makes each further variable's path a directory in a kept home (C47), so a further variable cannot name a file. A variable that names a file would be a term of its own, which the fold does not have.
  - **A home changed while `build` runs.** `build` checks each name below a kept home before it makes the next. A seat that runs while `build` does, and puts a link there between the check and the making, has `build` make the directory where the link points.
- A seat's program has no session bus, and so no notification, no secret service and no portal, and it has no manager of the user's (C84).
- A granted key (C85 to C92):
  - **Copies.** Each holding seat's key home holds an unprotected copy of every key granted to it, for as long as the build stands. A key granted to every holding seat stands once in each of their homes. The copies go with the build's homes (C36).
  - **The extra socket.** A seat signs any hash with a granted key through its extra socket too, and such a signature leaves no line in `signed`. The agent's own log cannot name the key behind an ssh signature without also writing the private keys, so `signed` names the seat and the second, and the accepting host's record names the key and the account.
  - **The agent's answers.** It answers `ssh-rsa` signatures with SHA-1; which signatures a host takes is the host's. Lock answers success, and the agent still lists its keys.
  - **Use.** A seat uses a granted key for as long as it runs, and it can forward its agent to a host for the length of one connection. A process of the user outside every view reaches the state directory, and the homes in it.
  - **Who runs `build`.** A workplace that names a key is built outside its own views. A seat of another workplace that runs the build was shown the key's file by that workplace's text. The frame does not see across workplaces.
  - **Where no record is kept,** a holding seat's agent logs nothing.
  - **What `status` compares.** `status` compares each agent's whole answer to `KEYINFO --ssh-list --ssh-fpr=sha256` with the one `up` recorded, and not its keys alone. A change in any other field of that answer exits 1 too, as if a key were gone.
- The wake (C93 to C96):
  - **Ready is what the pattern says of a screen.** A program that shows its input box while it works is typed into while it works. A kind's pattern is to match only what its program shows when it waits for a line.
  - **Typed is not read.** The frame knows that a pointer was typed. It does not know that a mail was read.
  - **A kind with no wake.** Its seats are reached as before: by a writer that may write their panes (C60), or by their own look.
  - **The carrier's own stops.** A pointer that tmux does not take is recorded as refused, and its mail stays to be pointed out. A carrier stopped between a delivery and noting it in `wake.json` leaves that mail delivered and not pointed out.
  - **A mode entered after a look.** The carrier looks at the pane, in the call that checks the mark, before it types the text and again before it sends the key (C60). A mode entered between the first look and the text takes the text, and the second look refuses the key, as C60 says. A mode entered after the last look takes what comes after it, the key, or the text when the key is `none`: the write or the pointer is recorded as `ok`, and its program reads none of it.
  - **The C locale.** A pattern matches byte by byte (C93). A literal of any script matches as written, so `❯` works. A bracket expression with a character of more than one byte matches each of its bytes alone, and `.` matches one byte. A kind's pattern for a program whose prompt is not ASCII writes the character outside brackets.
