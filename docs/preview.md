# Preview a Typify edit

The optional `bin/workplace-preview` accepts a configuration checkout and one JSON request on standard input. It requires Python 3, the frame's planning dependencies and the Typify reader. Set `TYPIFY_PREVIEW_READER` to an absolute executable to select a reader explicitly. If `WORKPLACE_ROOT` is empty or unset, the preview treats the checkout's parent as the root. With an explicit root, the checkout must be at or below it and retains that relative position in the preview.

```sh
bin/workplace-preview "$WORKPLACE_CONFIG" <<'JSON'
{"edits":[{"path":"programs/OFFICE[5]/COMMS.typify","content":null}]}
JSON
```

A string replaces or creates the entire UTF-8 file. A JSON null removes an existing file. Valid edit paths are unique, relative `.typify` paths in `programs/` or declared layers. An empty edit list compares two identical inputs. Only regular source files are admitted, and every file under `programs/` must use the `.typify` extension. Hidden entries, links in the source tree, and reserved `BUILD` and `PLAN` components are refused. The preview checks that the declared tmux configuration files exist and uses empty placeholders for them.

The command stages a private copy, calls `workplace plan --no-inventory`, applies the proposed edits there and calls the same planner again. The flag skips the optional host-directory inventory. Both passes use the same synthetic root, reader and configuration path. The caller's plan, build, tmux sessions and source are left alone.

The JSON reply reports `planChanged`, `viewChanged`, changed program paths and affected seats by address and name. Seat changes cover pane, room, start, directories, environment key names, filesystem rows and folded seat settings including reach. Filesystem rows describe declared access. Changes outside this projection can appear in the plan without a seat delta. An error reply names the failing stage and carries its diagnostic, and the command exits with status 1.
