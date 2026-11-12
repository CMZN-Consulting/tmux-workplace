# Mail and reach declarations

The optional Comms body records two policy terms. It supplies no carrier, mailbox binding, tmux operation or network restriction. The accepted Typify reader remains pinned. Native validation checks formation and recorded event emission; independent frame and runtime measurements establish the operational properties.

| Form position | Recorded term |
| --- | --- |
| programs/COMMS.typify: `mail : PATH` | `mail PATH` |
| COMMS.typify at workplace, office, room or seat | `reach A B C SCOPE ACTION TA TB TC TSCOPE STATE` |

Each source scope comes from its file position. Unused structural keys are the literal `-`. Targets have four explicit forms:

```text
reach : mail workplace = allowed
reach : grab office harbor = allowed
reach : write room harbor/dock = banned
reach : record seat harbor/dock/pilot = allowed
```

ACTION is mail, grab, write or record. STATE is allowed or banned. Record is the Logs action; its meaning and default belong to the Logs contract. No record policy is inferred here.

Intermediate terms reach-workplace, reach-office, reach-room and reach-seat translate to the single canonical reach primitive. Native ensures require the named source office, room or seat and the named target office, room or seat to exist. A workplace selector has no structural key to look up. Keys in target captures use distinct class names from file-context captures. The auxiliary shadow cells are bookkeeping; the frame reads every recorded event with its origin, including equal duplicates and conflicting values.

Mail is formed only in the workplace file, with the ordinary workplace-path class: canonical absolute path, canonical relative path or dot. The layer does not inspect the filesystem or enforce a multiplicity. The frame allows one value for the workplace: equal mail terms count once and retain every origin; different values refuse with each value and its origins. It also owns path protection and all mailbox construction.

For mail, grab and write, the fold first filters terms matching the asking seat, target and action. It then takes the narrowest asking scope and, within it, the narrowest target scope. With no matching term, mail is allowed and grab/write are banned. Clearance and structural-key values give no communication authority. An explicit ban or allowance overrides only through that scoped selection; neither a later line nor a lower clearance wins by itself.

Conflicts are global. Reach terms with the same whole asking selector, action and whole target selector but different states refuse the plan even when a narrower term would mask them. Equal terms count once and retain all origins. This remains a frame decision; the declaration records both events.

The frame refuses reach without mail, a Comms term with a seat having no view, and the mailbox/path conflicts of the Comms contract. A mail path cannot be slash, inside the configuration clone or beneath a hidden row; a seat's directory/program cannot lie at or beneath it. A statement or label at the mailbox path or below it is also refused. Build checks that the resolved path is an existing directory and does not contain or lie in the state directory. Relative mail paths join the workplace root, separately from the configuration clone.

The request contract admits grab counts from 1 to 5,000 in decimal with no leading zero, defaulting to 200. A repeated head word is refused. A write has empty text or one line, optionally followed by one framing LF; other line structure is refused. CR is a forbidden control character in both head and text, and the text is at most 4,096 bytes. These are carrier decisions, not Typify form checks.

Before any measurement, the declaration author freezes independent terms, source origins, per-seat reach and request decisions privately. The carrier and view implementation are not read to derive those predictions. Equal-value coalescing, global conflict refusal and the request boundaries above follow the Comms clarification of 2026-11-12T19:25Z.

See tests/fixtures/comms-workplace/ for the invented five-seat source overlay. Its preparation copies selected source only; it starts no carrier or workplace and supplies no runtime credential.
