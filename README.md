# tmux-workplace declaration layers

These layers describe structure, access, shell-seat directories and environments, and host launches. The reader computes a plan; the workplace loop applies it. This branch contains the first shared-layer fixture, not a deployed workplace.

`layers/Structure.typify`, `Access.typify`, `Agents.typify` and `Host.typify` are assembled as whole bodies, in that order, into `LanguageDeclarations.typify`. The layers contain no workplace identities. `tests/fixtures/reader-workplace/` contains the invented Harbor/Orchard workplace: two offices, three rooms, five seats, and six declared directories. All five seats explicitly use `none`; general agent kinds and their stores belong to the later frame fold.

The accepted reader is Typify commit `4bb7584a88a4e59bd1295f56f771a3f434e5d7ea`. It is not modified here. The fixture uses `/tmp/workplace-reference-a4` as its fixed root. Its generated root program encloses every consumer program. Source paths in the native wire remain reader provenance; filesystem resource paths are absolute.

The executable interface is `server`, `session`, `window`, `pane`, `arrange`, `start`. The binding applies them in that order, preserving order within a primitive. The view has five states and an explicit `/` row per seat. Claims are retained in the reader's `recorded` arrays. The environment is keyed by office, room, seat and variable; the watch seat's inner row overrides its outer baseline.

The Access layer checks root-row and declared-seat presence. The loop checks hidden-ancestor contradictions by path components, and validates command JSON and structural completeness. The single Structure program checks workplace-wide seat display-name uniqueness; it does not independently forbid two display names sharing a structural seat key. These are stated boundaries, not extra reader guarantees.

The fixture's `PLAN/plan.json` is the reader's output without semantic rewriting. `PLAN/facts.json` is the native collector's fixed input, and `PLAN/manifest.json` binds the reader commit, derivation versions, source inputs and output hashes. Byte comparison was measured on a separate frozen miniature; this fixture is planned once per frozen source revision. Integration with the revised loop is a separate measurement.

To prepare the fixed reference root, copy `root/` into `/tmp/workplace-reference-a4`, `tmux.conf` into its `config/`, the four layers and assembled declarations into `config/sources/`, and `source/` into `config/sources/tree/`. Copy `PLAN/` into `config/PLAN/`. Never apply this fixture to an existing workplace. The integration runner uses a private named tmux server and leaves the live server unchanged.
