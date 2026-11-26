# What a running workplace checks

These paragraphs describe what `bin/workplace` checks when it builds, starts, restarts and stops a workplace. The [contract](../CONTRACT.md) states each rule with the checks that show it.

An enforced seat's aliases cannot increase its host-file access. A bind through a
symbolic link needs the same or greater permission at the resolved path's own
name. A writable alias of a read-only path is refused. A parent alias must also
cover each stricter descendant at the alias's destination; explicitly permitted
children and read-only aliases of writable data remain usable. The check runs
again at build, up, restart and each seat's exec. Private-key source files remain
unshown even where an alias uses a different name. This is a check of declared
paths and host metadata, not a scan of file contents.

The check assumes stable paths and mounts between inspection and namespace
creation. It does not identify hard links, separate host mounts of the same data
or descriptors that another process already holds. The contract states the
external host work on which a running view depends.

Build seals each floor's configuration into its generation and publishes the
enforced and unenforced frame settings in `BUILD/share/`. Startup reads the
floor's configuration first and the frame's settings second. It rejects active
hooks, malformed or blocking files, unexpected sessions, and shell expansions
in enforced-floor options. Startup calls have a ten-second deadline. The carrier
repairs changed transport settings and records a repair; `status` checks them
without repairing them. Existing pane history below 5000 cannot be repaired and
is refused. Higher history limits are preserved.

Unenforced mailboxes are `MAILPATH/NAME/` links into the store; record views are
`RECORDPATH/NAME/`. Their source files are reachable to ordinary processes of the
same Unix user, so neither seat identity nor privacy is enforced on that floor.
Shutdown leaves personal sessions and their default server running, removes its
own run directory, and retains the frame's global settings and reserved marks.
It stops a carrier unit only while the unit has the recorded invocation ID.
Reusing that default server requires the same sealed floor configuration. If
the file changed, `up` refuses without changing the server, since tmux would
ignore the later client's `-f`. End that server yourself before loading the
new configuration.
