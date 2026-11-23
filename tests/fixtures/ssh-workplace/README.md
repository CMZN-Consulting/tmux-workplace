# W4 workplace example

This five-seat workplace uses the ten shared declaration layers. With the released Typify reader on your `PATH`, run the following commands from the frame checkout. The destination is a new, disposable directory. Planning writes `PLAN/plan.json` and `PLAN/view.json`.

```sh
example_root=$(mktemp -d)
bash tests/fixtures/ssh-workplace/prepare.sh "$example_root/config"
WORKPLACE_ROOT="$example_root" WORKPLACE_CONFIG="$example_root/config" bin/workplace plan --no-inventory
```

## Expected access in the plan

Each room declares its clearance. Zero is the highest. All rooms qualify for the public label of 2. Dock alone qualifies for the restricted labels of 0. Pilot has an explicit writable view of `public`, and `sealed` is hidden throughout the workplace.

| Room | Seat | Clearance | `public` | `restricted` and `restricted/lower` | `sealed/info` and all five SSH key paths |
|---|---|---:|---|---|---|
| Dock | Pilot | 0 | read-write | read-only | hidden |
| Dock | Keeper | 0 | read-only | read-only | hidden |
| Tower | Watch | 1 | read-only | hidden | hidden |
| Barn | Grower | 2 | read-only | hidden | hidden |
| Barn | Picker | 2 | read-only | hidden | hidden |

`python3 tests/w4-example.py` prepares a fresh copy, plans it, and checks the effective modes at those paths using the nearest matching view row. It also checks the recorded SSH declarations and resolved grants. The example ends at planning. Live key loading and file access require a separately provisioned workplace.

## SSH declarations

The root SSH program uses an ASCII baseline name and four exact text-capture witnesses: İşlem-α, 鍵[#]%+@=, n:=x and café. The final name is decomposed: its final two code points are U+0065 followed by U+0301. Preserve it as written. The paths contain brackets and hash characters under sealed/keys, below the inherited hidden sealed subtree. Those files do not exist in the fixture and must not be replaced with a user's keys.

The source puts PATH or STATE before NAME, leaving NAME in the final text position:

```text
ssh-key : sealed/keys/[edge]#one.pem = İşlem-α
ssh-grant : granted = İşlem-α
```

The reader emits the key name before the path or grant state. The regression test compares the recorded events with their expected names, including duplicates and the decomposed accent.

The source repeats one identical key declaration and one identical grant. It places grants at workplace, office, room and seat scopes, and includes explicit none grants. Identity is held at workplace scope and none at Watch's seat. Direct seat grants are authored only at the other seats. The test checks which grants reach each seat. Watch has no Identity key and receives none of the grants inherited from the workplace and office.

The [earlier W4 fixture](https://github.com/CMZN-Consulting/tmux-workplace/tree/07b37097eac70c98f0c42aded30f72028142901d/tests/fixtures/ssh-workplace) preserves the original seat-scoped clearance examples and release-era source for reproducing the historical reader checks.
