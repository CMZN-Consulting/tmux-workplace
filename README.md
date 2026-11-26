# Tmux Workplace

Picture five programs on one computer, each running in a terminal window of its own. They might be AI coding assistants, or scripts, or programs that people type commands into. Three of them have the made-up names Harbor Pilot, Harbor Watch and Harbor Keeper. Here is how their day goes.

- **Who may change what.** The first program, Harbor Pilot, may change the files in a folder called `public`. The second, Harbor Watch, may open and read the same files, but when it tries to change one, the computer refuses with the message "Read-only file system".
- **What stays out of sight.** Neither of them can open a folder called `sealed`. They try, and the computer refuses with the message "Permission denied". Whatever lies in `sealed`, a secret for instance, stays out of their sight.
- **Letters between programs.** Harbor Pilot wants to tell Harbor Keeper that its report is ready. It writes a short letter and puts it in a folder called `out`. A moment later the letter lies in Harbor Keeper's folder called `in`, with the sender's name on it. The sender cannot choose that name: it is written on the letter by the program that delivers it.
- **A record afterwards.** Everything that Harbor Pilot's terminal showed is saved in a file, a new file each day, so that you can read it later.
- **A key that cannot be read.** Harbor Pilot may log in to another computer with a secret key (a file that proves who you are, in place of a password), yet it cannot open that file. It only asks a helper program of its own, a small program that runs in the background and holds the key, to do the proving for it.

Tmux Workplace, shortened to 🏢 on the rest of this page, sets all of this up from one written description of which program runs where and what each may see. A set-up of this kind, with all its programs, where each runs and what each may see, is called a workplace. 🏢 does the work with two ordinary Linux programs: tmux, which shows several terminals inside one window so that you can switch between them, and bubblewrap, which is what keeps a program away from files it may not see: it starts the program with only some of the computer's files in view and the rest hidden.

## Three words for the parts of a workplace

The written description uses three words.

- A **seat** is one terminal with one program in it, and the rules for what that program may see. Harbor Pilot is a seat.
- A **room** is a group of seats that share one window on your screen. The Dock is a room. Harbor Pilot and Harbor Keeper sit in it.
- An **office** is a group of rooms. Harbor is an office. The Dock and the Tower are its rooms, and Harbor Watch sits in the Tower.

The example used below has five seats: Harbor Pilot, Harbor Keeper and Harbor Watch in the office Harbor, and Orchard Grower and Orchard Picker in a room called the Barn, in the office Orchard.

The description is written in a small written language called Typify, made for this kind of description. A program called the reader (it is named `typify`) reads the description, checks it for mistakes and turns it into a plan: a file that lists every seat and what it may see. You do not need to learn the language to try the example: its description comes with the files that you download below.

## When you would want 🏢

- Several AI coding assistants work on one computer. Each should change only its own part of a project, and none should read the passwords of the others.
- A few scripts, or a few people, share one machine. Some folders must stay out of reach of some of them, and you want that rule written down once, in one place, and not kept in your head.

## How it goes

You run one command at a time. Each reads or writes a folder next to the description.

1. `plan`: the reader checks the description, and 🏢 works out what every seat may see. That result, the plan, goes into a folder called `PLAN` (you will see it in the first example).
2. `build`: 🏢 checks the plan against your computer (do the folders exist, are the keys there) and writes a folder called `BUILD` (you will see it in the second).
3. `up`: 🏢 starts the terminals, the seats' programs and the small background programs that go with them: one for each key, and one, called the carrier, that delivers letters.
4. `status`: 🏢 says whether everything it started is still there.
5. `down`: 🏢 stops what `up` started. `unbuild` then removes `BUILD`.

## What to install first

🏢 runs on Linux. Install these first:

- git, to download the files of 🏢 (the letters in the second example need git 2.32 or newer);
- bash 5.2 or newer (the shell the commands are typed into), jq 1.7 or newer (a tool for reading files in the JSON format, a plain-text way of writing down data) and tmux 3.5a or newer;
- bubblewrap (the program is called `bwrap`), on a Linux that lets an ordinary user run it; the check below tells you whether yours does;
- the basic command-line tools `setpriv`, `env`, `mkdir`, `cp`, `rm`, `sha256sum` and `stat`, which a normal Linux has (you will never need to know what they do);
- the Typify reader, a program called `typify` that has to be on your `PATH` (the list of folders in which your terminal looks for programs). The [reader installation guide](https://github.com/CMZN-Consulting/typify/blob/v1.0.0/docs/install.md) describes how to download it and check it;
- for the second example below, which starts the seats: GnuPG 2.4.4 or newer (`gpg`, `gpg-agent`, `gpgconf`, `gpg-connect-agent`, with `setsid` and `base64`), which makes and guards each seat's key; OpenSSH's `ssh-keygen` and `ssh-add`; GNU `env` with the `-S` option (coreutils 8.30 or newer); `flock`, `dd`, `mv`, `tail` and `date`, which the letters need.

Download the files of 🏢 and let it check your computer:

```sh
git clone https://github.com/CMZN-Consulting/tmux-workplace.git
cd tmux-workplace
bin/workplace doctor
```

Every line it prints should start with `ok`. Most of them name a program and its version, as in `ok      tmux 3.8`. A line that starts with `absent` names something that is missing and says what that stops. One such line may name "a user manager": it matters only for plans that send their records to the system's own log, which the examples below do not. Check the reader on its own:

```sh
typify --version
```

It prints one line with a version number.

## First example: let 🏢 read a description

The repository holds a ready-made description of the five seats above. The commands below copy it into a new, empty directory and run `plan` on it. Nothing is started, and planning needs only bash, jq and the reader. The example uses invented paths and key names.

```sh
example_root=$(mktemp -d /tmp/workplace-example.XXXXXX)
bash tests/fixtures/ssh-workplace/prepare.sh "$example_root/config"
WORKPLACE_ROOT="$example_root" WORKPLACE_CONFIG="$example_root/config" bin/workplace plan --no-inventory
```

The first two commands print nothing. The third may take several seconds, then prints a line that says `planned`, the new `PLAN` folder, the reader's version line and `19 terms` (a term is one step of setting up, such as making an office, making a room, placing a seat or starting its program; the example needs 19), then the names of three files it wrote, a few lines about the mail, the records and the ssh keys, and then one block for each seat:

```text
planned /tmp/workplace-example.AbC123/config/PLAN: the reader 1.0; 19 terms
  plan.json 68aecea0…
  view.json 62f95530…
  manifest.json 22f57e97…
mail: /tmp/workplace-example.AbC123/mailbox, where each seat is shown its own mailbox (programs/COMMS.typify:1)
…
seat Harbor Pilot (harbor/dock/pilot): kind navigator; clearance 0, the room's (…); … 17 rows
  mail: Harbor Keeper (…), Harbor Watch (…)
…
```

Your directory name, the three digests and your reader's version line will differ. The command exited with status 0. Check it with `echo $?` straight after it. A description that the reader refuses prints the reader's message with the file and line, and the status is 1.

Each `seat` block ends with a number of rows. A row is one path and what the seat may do with it. Print the rows of Harbor Pilot, one per line:

```sh
jq -r '.rows[] | select(.key[0:3] == ["harbor","dock","pilot"]) | [.key[3], .value[0]] | @tsv' "$example_root/config/PLAN/view.json"
```

You see 17 lines. Each has a path, a tab and one of `read-only`, `read-write`, `hidden`, `searchable-only` or `scratch`. Four of them, with your directory name in place of `ROOT`:

```text
ROOT/public            read-write
ROOT/harbor/charts     read-only
ROOT/harbor/ledger     hidden
ROOT/sealed            hidden
```

`hidden` means that the seat cannot open the path and sees nothing in it. `scratch` is an empty space that the seat may write in and that is gone when its terminal ends. Leave off everything after `select(...)` to see each row whole, with the line of the description that made it.

The same rows give this table. The numbers are the rooms' clearances. A clearance is how much of the workplace a room may see: 0 is the highest, and a path marked with a number is open to the rooms whose number is at most that one. Here `public` is marked 2, so every room may read it. `restricted` is marked 0, so only the Dock may.

| Room  | Seat           | Clearance | `public`   | `restricted` | `sealed` |
| ----- | -------------- | --------: | ---------- | ------------ | -------- |
| Dock  | Harbor Pilot   |         0 | read-write | read-only    | hidden   |
| Dock  | Harbor Keeper  |         0 | read-only  | read-only    | hidden   |
| Tower | Harbor Watch   |         1 | read-only  | hidden       | hidden   |
| Barn  | Orchard Grower |         2 | read-only  | hidden       | hidden   |
| Barn  | Orchard Picker |         2 | read-only  | hidden       | hidden   |

`python3 tests/w4-example.py` prepares a fresh copy, plans it and checks these modes by itself. The [example's own page](tests/fixtures/ssh-workplace/README.md) says more.

## Second example: start the five seats

The example is invented: it names folders, keys and programs that do not exist on your computer. This step makes stand-ins for them, in the same directory, so that the seats can start. It makes empty folders, five throwaway keys (the keys exist for this example only) and one small program that all five seats will run. The program tells each seat's terminal whether it can open `sealed` and whether it can change `public`, and Harbor Pilot's copy also writes the letter to Harbor Keeper.

```sh
export WORKPLACE_ROOT="$example_root" WORKPLACE_CONFIG="$example_root/config" XDG_STATE_HOME="$example_root/state"
cd "$example_root"
mkdir -p state tools records mailbox public restricted/lower sealed/info sealed/keys \
  agents/gardener/shared agents/gardener/stores/grower agents/navigator/shared agents/navigator/stores/pilot \
  harbor/berth harbor/charts harbor/ledger/inner harbor/scratch orchard/crate-picker orchard/scratch
for key in '[plain]#control' '[edge]#one' '[internal]#two' '[compute]#three' '[notes]#four'; do
  ssh-keygen -q -t ed25519 -N '' -C example -f "sealed/keys/$key.pem"
done
printf '#!/bin/sh\nexit 0\n' > tools/seed-home
cat > tools/probe <<EOF
#!/bin/sh
echo "I am the \$1."
if ls "$example_root/sealed" > /dev/null 2>&1; then echo "sealed: I can open it"; else echo "sealed: I cannot open it"; fi
if touch "$example_root/public/note-from-\$1" 2> /dev/null; then echo "public: I changed it"; else echo "public: I could not change it"; fi
if [ "\$1" = pilot ]; then
  printf 'to: Harbor Keeper\nsubject: the report\n---\nThe report is in public.\n' > "$example_root/mailbox/out/.letter"
  mv "$example_root/mailbox/out/.letter" "$example_root/mailbox/out/letter.md"
fi
exec sleep 3600
EOF
chmod +x tools/seed-home tools/probe
cd - > /dev/null
```

None of these prints anything. Now build:

```sh
bin/workplace build
```

You see about ten lines. Among them are `keys: 4 made in …` (a key of its own for each of the four seats that hold one), `ssh keys loaded: …` (which ssh key went to how many seats), a `home: …` line for each seat that has a home folder of its own, `records: 2 panes kept in …`, `mail: 5 mailboxes in …, shown at …/mailbox` (one for each seat), and then the line about the build itself, `built …/config/BUILD: 19 terms; manifest …`, followed by the reader's version line. The exit status is 0. If `build` refuses, the message names what is missing, such as a key file or a folder.

Each seat of the example expects a few facts when it starts, for instance the name of its office. The person who runs the workplace gives them in a file called `values.json`, in the workplace's own state directory, with permissions that only that person can read. 🏢 never writes it. Write it now:

```sh
state=$(echo "$XDG_STATE_HOME"/workplace/*)
(umask 077 && cat > "$state/values.json" <<'EOF'
{
  "workplace": { "RUN_WORKPLACE": "example" },
  "offices": { "harbor": { "RUN_OFFICE": "harbor" } },
  "rooms": { "harbor/dock": { "RUN_ROOM": "dock" } },
  "seats": { "Harbor Pilot": { "RUN_SEAT": "pilot" } }
}
EOF
)
```

Now start the seats:

```sh
bin/workplace up
```

You see six lines. Four are `up: the agent of …, pid …`, the key helpers of the four seats that hold a key. Then comes `up: the carrier, pid …`, the helper that delivers letters, and last `up: 19 terms applied; run workplace-…`. The exit status is 0.

Ask whether everything is there:

```sh
bin/workplace status
```

The first line reads `build: verified, manifest …`. Then come lines about the mail, the seats' home folders and the values, then `run: up, workplace-…` and a line that starts `attach` and gives a `tmux` command. After that you see nineteen lines that start with `ok`: the tmux server, the key helpers, the carrier, `session/harbor`, `session/orchard`, one `seat/…` line for each of the five seats and the pipes that keep two terminals' records. Two `record` lines say how many bytes of today's record are kept. A line that starts with `gone` instead of `ok` is a check that failed, and then the exit status is 1.

Look at the terminals. Copy the command from the `attach` line, which looks like this, and run it:

```text
tmux -S '/tmp/workplace-example.AbC123/config/BUILD/RUN/config-3461cbd94fbf' attach
```

Your terminal turns into one of the two offices. Each window of it is a room. The Dock has two terminals, Harbor Pilot's and Harbor Keeper's. Harbor Pilot's reads:

```text
I am the pilot.
sealed: I cannot open it
public: I changed it
```

and Harbor Keeper's reads `I am the keeper.`, then the same second line, and `public: I could not change it`. The terminal of Harbor Watch in the Tower, and the two terminals of the Barn in the other office, read the same as the Keeper's, each with its own first line. That is the table above at work: one program, and five different views of the files. In tmux's own words, an office is a session, a room is a window and a seat is a pane. Press `Ctrl-b` and then `n` for the next window, `Ctrl-b` and then `(` or `)` to change the office, and `Ctrl-b` and then `d` to leave. Leaving stops nothing.

Ask why Harbor Watch cannot open `sealed`:

```sh
bin/workplace why 'Harbor Watch' "$example_root/sealed"
```

It prints a line for each fact about that seat (its key, its home folder, the values it was given) and ends with three lines. The first, `row: …/sealed hidden`, is the verdict. The second says how the path was written and joined, and the third names the line of the description that made the row, here `programs/WORKPLACE.typify:12`. Ask the same about `"$example_root/public"` for `'Harbor Pilot'`, and the verdict reads `row: …/public read-write`.

Now the letter. Harbor Pilot's program has written it into its `out`. The carrier has taken it, and Harbor Keeper's `in` holds it, under a name made of the time and a number:

```sh
ls "$state/mail/Harbor Keeper/in"
cat "$state/mail/Harbor Keeper/in/"*.md
```

You see one file name, such as `20261126T010106Z-000001.md`, and then its text:

```text
id: 20261126T010106Z-000001
at: 2026-11-26T01:01:06Z
from: Harbor Pilot
to: Harbor Keeper
subject: the report
---
The report is in public.
```

The first three lines were written by 🏢: the letter's number, the time and the real sender. The rest is what Harbor Pilot wrote. If the letter is not there yet, wait a few seconds and run the two commands again.

Now take it down:

```sh
bin/workplace down
```

You see one line for each thing it undoes, newest first: `undo session/orchard: done`, `undo session/harbor: done`, `undo the carrier, pid …: done`, then for each key helper `undo the agent of …: done` and, where the helpers keep their sockets in the system's runtime directory, `undo the runtime sockets of …'s agent: done`, and last `down: done`. Run `bin/workplace status` again and it says `run: down`.

`down` removes only what `up` made: the terminals and the helpers. Everything else stays, `BUILD` too. `unbuild` then removes the build:

```sh
bin/workplace unbuild
```

It names the twenty files of `BUILD` that it removes, then the key homes that it removes (`unbuild: removed the key homes in …, 4 homes, …`), and last says which part of the state directory it keeps:

```text
unbuild: the state directory …/state/workplace/config-3461cbd94fbf is kept, with everything in it but the key homes: carrier.lock, comms, homes, homes.json, mail, records, values.json
```

What stays on the disk, then: the description and its `PLAN` in `config`, the letters in the state directory's `mail`, the kept record of the two terminals in its `records`, the values you wrote, the folders and stand-ins that you made, and `public/note-from-pilot`, the one file that a seat was allowed to make. What is gone: the terminals, the helpers, `BUILD` and the keys that were made for the seats. The example lives in one directory, so this removes all of it:

```sh
rm -rf "$example_root"
```

## All the commands

Every command reads two settings from its environment. `WORKPLACE_ROOT` is the folder in which the workplace lives. `WORKPLACE_CONFIG` is the folder that holds the description, at or below the root. The commands, in the order of a workplace's life:

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
- `record verify` reads a seat's kept record of a day, or its `unstored`, `gaps` or `signed`, or 🏢's record of requests, against its chain, and names the first place where they differ.

What each term does is one entry of `host/binding.json`. What the loop does with any entry is `CONTRACT.md`. What a seat is told about its mailbox is `share/seat-page.md`, which every mailbox holds as `README.md`. The contract and the older notes call 🏢 "the frame".

The [shared declaration layers](docs/declarations.md) cover room access, communication, recording and scoped SSH grants.

### Preview a Typify edit

The optional `bin/workplace-preview` shows what a proposed edit of the Typify source would change in a plan, without touching the plan, the build or any running session. [Preview a Typify edit](docs/preview.md) describes its input and its reply.

### What a running workplace checks

[The checks of build, up, restart and exec](docs/running.md) cover how an alias of a path is checked, how a build is sealed, how a started workplace is checked and what a shutdown leaves.

## Everything 🏢 can need

- bash 5.2, jq 1.7 and tmux 3.5a or later;
- `setpriv`, `env`, `mkdir`, `cp`, `rm`, `sha256sum` and `stat`;
- bubblewrap, only when a seat has a view, on a Linux host with unprivileged user namespaces;
- the reader, `typify` on the path, for `plan` alone. Bun is needed only for the optional MCP server, and no Racket installation is needed;
- GnuPG 2.4.4 or later (`gpg`, `gpg-agent`, `gpgconf`, `gpg-connect-agent`), with `setsid` and `base64`, only when a seat holds a key. Each such seat gets a key made at every build. In its view it signs and authenticates through its agent's restricted socket, and never sees its private key;
- OpenSSH's `ssh-keygen` and `ssh-add`, only when the plan grants an ssh key. `build` checks the key's file and loads it into the agent of each seat it is granted to, and the seat is shown the key's public file alone;
- GNU `env` with `-S`, coreutils 8.30 or later, only when a seat expects a value given at run time. The values stand in the workplace's `values.json` in its state directory, which the person who runs the workplace writes with mode 0600, and no value is ever printed or put on a command line;
- git 2.32 or later, with `flock`, `dd`, `mv`, `tail` and `date`, only when the plan holds mail. Each seat is then shown its own mailbox at the plan's mail path, with 🏢's page for a seat in it, and the carrier, which `up` starts, takes what a seat leaves in its `out`: a mail it delivers into the store, a grab or a write it does on another seat's pane where the plan allows it. Where a kind's `wake` term says how its pane looks when it waits for a line, the carrier types into a reader's waiting pane one line that points out its new mail and names its mailbox's `in` and the page;
- `dd`, `date`, `tail` and `head`, only when the plan keeps a pane's record, and `systemd-run`, `systemctl` and `journalctl` with a user manager that answers, only when its chain goes to the journal. A kept pane is piped from before its program starts into a keeper of 🏢's, one file a day for each seat in the workplace's state directory, and the carrier sends the chain every ten seconds.

`doctor` checks each of these. The workflow in `.github/workflows/tmux.yml` is configured to test the minimum tmux 3.5a and the pinned 3.6b, 3.7c and 3.8 releases, with hash-checked upstream archives. Each version runs independently and the `tests` check requires all four to succeed. This configuration does not itself establish that a candidate has passed those jobs; consult its actual run results.

## Tests

`bash tests/run.sh` runs every test on a tmux server of its own, under a scratch home, with `TMUX` and `TMUX_PANE` unset. `bash tests/run.sh t_views` runs one test.

## License

🏢 is licensed under the [Apache License, Version 2.0](LICENSE).
