# Record declarations

Logs.typify adds four state-effect recorded terms to the unchanged accepted Typify reader. It adds no executable primitive, recording implementation or reader feature.

| Program | Source form | Recorded term |
| --- | --- | --- |
| LOGS.typify at workplace, office, room or seat scope | `record : WHAT = STATE` | `record A B C SCOPE WHAT STATE` |
| Workplace LOGS.typify | `record-limit : BYTES` | `record-limit BYTES` |
| Workplace LOGS.typify | `record-chain : SINK` | `record-chain SINK` |
| Workplace LOGS.typify | `record-path : PATH` | `record-path PATH` |

WHAT is pane or programs. STATE is kept or none. Missing structural keys are represented by `-`, as in the other scoped layers. The three global-setting forms are available only in programs/LOGS.typify. Every file is optional. Office, room and seat records require their structural target to have been declared.

The native shadow cells are bookkeeping, not recording policy. The scoped cell is keyed by structural address, scope and WHAT. Each global setting has its own one-component shadow cell. No count guard discards duplicates or decides their consistency. Every original event, equal or conflicting, remains recorded with its origin for the frame.

## Formation and policy boundary

BYTES is a decimal whole number above zero, without a sign or leading zero, of at most sixteen digits. The class is `[1-9][0-9]{0,15}`. The accepted reader's class parser supports bounded repetition; no reader extension is needed. The frame independently refuses a value outside this domain and imposes no additional host maximum. SINK is exactly journal or file. PATH uses the existing workplace-path class.

The frame selects the narrowest record declaration for each seat and WHAT; absent a declaration it keeps none. Different states at the same structural selector and scope for one WHAT refuse the plan globally, naming both origins, even if a narrower term would replace them. Pane and programs are separate selections. Any authored programs-kept term refuses the plan until program recording is built, even where a narrower term says none. Accepting its syntax does not enable it.

The global settings each select one value for the workplace. Equal terms coalesce with every origin retained. Different values refuse the plan, naming each value and its origins. This is a frame fold over the recorded stream, not a native multiplicity restriction.

The pane limit defaults to 256 MiB, or 268435456 bytes. It limits the pane's bytes for one UTC day, not the number of programs or requests. Without record-chain, files may be kept without a chain and the plan reports that fact. Journal uses the machine's journal and requires a user manager at up. File keeps the chain in the workplace's state directory and can be used without a user manager. Carrier startup, journal units, retention, masks and availability checks belong to the frame and carrier.

A kept record requires the seat to have a view. Reading is a Comms reach action named record. Neither self-access nor another seat's access is implicit. Any authored reach term with that action requires record-path, including a banned term. Keeping records without a record-action reach term requires no record path. Allowing a target whose record state is none is legal; the frame must list that target and show an empty read-only directory under its name. That directory behavior still requires measurement.

The frame applies permitted record directories read-only at record-path after ordinary rows. The path is subject to the mail path's placement restrictions and must be neither equal to, above nor beneath it, comparing path components. A neighbour with only a shared character prefix is legal. A statement or label at or beneath record-path refuses the plan, as does a record path beneath a seat's hidden row. Source path strings remain authored strings; joining, containment and mount policy are frame duties. These boundaries follow the Comms/Logs ruling of 2026-11-12T19:25Z.

## What needs independent measurement

The native reader can establish form membership, declared structural targets and the emitted events. It does not prove that a pane is piped before start, that views hide records and sockets, that a keeper enforces the limit or rotates days without loss, or that a seat cannot reach the carrier.

The frame and carrier own pipe-gap recovery, UTC files, overflow counts, chain offsets and hashes, sink rejection and recovery, journal skips, record verification and retention. The keeper changes the day internally. A chain entry hashes the previous hash's 64 lowercase hexadecimal characters followed by the appended bytes, beginning with 64 zeros. The carrier sends at ten-second intervals and twice as it ends. These are implementation obligations from the recording contract, not properties of this declaration layer.

No record, output stream, key, credential, journal entry or real agent home is read by this source fixture. Program-tracing cost, keeper load, week-long verification cost and the workplace's socket rehearsal remain separate measurements. The frame removes no retained record automatically.
