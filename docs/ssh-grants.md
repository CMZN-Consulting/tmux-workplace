# SSH key and grant declarations

The optional SSH body records two state-effect terms. It reads no private key, loads no agent and opens no socket. Its contract follows definition5.66, the amendments of5.69 and K1 of5.79.

| Source file                                   | Form                                                      | Recorded term                      |
| --------------------------------------------- | --------------------------------------------------------- | ---------------------------------- |
| programs/SSH.typify                           | `ssh-key : PATH = NAME`                                   | `ssh-key NAME PATH`                |
| SSH.typify at workplace, office, room or seat | `ssh-grant : granted = NAME` or `ssh-grant : none = NAME` | `ssh-grant A B C SCOPE NAME STATE` |

The surface puts NAME last; the recorded argument order stays as shown above. For example:

```text
ssh-key : sealed/keys/alpha.pem = İşlem-α
ssh-key : sealed/keys/beta.pem = 鍵[#]%+@=
ssh-grant : granted = İşlem-α
ssh-grant : none = 鍵[#]%+@=
```

The previous NAME-first candidate was refused at its first declaration check: all five forms had a text capture that could contain the following delimiter. This separate candidate removes that following delimiter from NAME. The path-before-equals shape already occurs in the accepted Access declarations, and the grant prefix is a finite state. The receiving signatures, emitted terms, shadow cells and existence checks are unchanged. No old-surface alias is included. This candidate has not been checked; the grammar change is a static proposal.

The source position supplies A, B, C and SCOPE, with literal `-` for unused structural keys. All files are optional. Office, room and seat grants require that structural selector to exist. Every grant also requires a declared SSH name, including a grant whose state is none. This requirement concerns the source declaration; it does not inspect a key's bytes or the seat's Identity selection.

NAME uses the existing nonempty text capture directly, including in both primitives' receiving signatures. There is no word alias or ASCII identifier class for it. This keeps legal punctuation and Unicode in the admitted domain rather than pretending an ASCII regular expression implements K1. The shared structural-key classes are unchanged.

K1 assigns the excluded-name checks to plan: reject an empty name, minus alone, dot, dot-dot, a leading minus, slash, white space or a control character, naming the term. The text surface already needs a nonempty line capture; the frame remains responsible for every K1 check. Native formation may admit names that plan must refuse. The behavior of legal punctuation and Unicode through this direct capture must be checked before claiming exact preservation; this source adds no reader feature.

PATH uses the existing workplace-path class: canonical absolute path, canonical relative path or dot. It remains as authored. The frame joins relative paths against the workplace root. A path in a declaration is a resource address, not copied key material.

The auxiliary shadow cells are bookkeeping only. No native count guard or conflict policy is imposed. Every recorded event and origin survives, even if a shadow cell retains only its latest value. The frame must decide from the recorded stream:

- Whether repeated definitions for a name disagree.
- For each name, which narrowest structural grant applies and which equal-scope states conflict.
- Default none, a seat's Identity holding and the non-reaching seats under wider grants.
- The refusal of a seat-scoped grant to a seat with no Identity key.
- A private file visible read-only or read-write in any seat's table, and the required views when either SSH term is present.

Identity selection and an SSH grant are different declarations. The SSH body does not add an Identity key to make a grant work. Selection, conflicts, visibility and cryptographic checks are frame obligations, not stronger claims established by a native formation check.

Build reads files outside every seat view. Under5.69 it checks a file once and reads it again for each seat load, retaining nothing between those reads. It validates a regular, usable, non-passphrase file and the supported key kind: ed25519, RSA of at least 2048 bits or ECDSA on the three NIST curves. Smaller RSA, security-key files and other kinds are refused. It loads through a temporary batch agent, then ends that agent. The serving agent is separate and cannot run in batch mode. Public files are exposed under `ssh/NAME.pub`; no private bytes belong in BUILD or a seat's visible files.

Those are implementation obligations, not actions of this source. Independent build/socket tests must establish loading, permitted signatures and listing, refused mutations, public-name/fingerprint metadata, status and why provenance. Tests use their own generated keys; they do not read a user's keys.

The contract's limits remain. Granted keys have unprotected copies in their build's key homes until those homes are removed. A holding seat can use the agent while it runs and forward it for a connection; outside processes of the user can reach state. The workstation's serving-agent log identifies seat and time, while the accepting host identifies key and account. A signature through the extra socket is not logged there. No claim here converts those records into a complete signature audit or prevents every use beyond a chosen host.

Before native or frame measurement, freeze source-derived event, origin, grant and refusal predictions privately. No SSH validation, key loading or runtime enforcement is implied by the declaration file alone.
