# Resource paths at the layer/frame boundary

The shared class is `is : workplace-path = canonical-path | relative-path | "."`. It accepts absolute canonical paths, canonical relative paths, and `.` for the workplace root. The union is an ordinary string class, so the reader performs no nominal relative-path resolution. Each receiving path signature uses this class too.

The frame preserves absolute paths. It replaces `.` with its root and joins any other declared relative path beneath that root, lexically: one separator, no doubled slash, no `/.`, and no symlink resolution. It joins before comparing scopes, equal paths, replacements, labels and conflicts. Thus a relative and an absolute spelling of one resource denote the same resource to the frame, although native counts still see distinct authored strings.

Argument numbers below exclude the constructor name. The plan preserves every path as written.

| Input | Path in the plan | Frame handling |
| --- | --- | --- |
| `view : PATH = MODE`, at workplace, office, room, seat or kind | `statement A B C SCOPE PATH MODE`, argument 5 | Join before folding; kind shared places use these view lines, while private program homes are frame-supplied |
| `label : PATH = NUMBER` | `label PATH NUMBER`, argument 1 | Join before grouping and label checks |
| Seat `directory : PATH` | `record-directory A B C PATH`, argument 4 | Join before using the declared directories |
| Seat `command : ARGV` | `start A B C DIR ARGV`, argument 4 | DIR is the first directory line's raw value through the existing context; join before application |
| Generated `server : NAME : CONF` | `server NAME CONF`, argument 2 | CONF is the raw configuration path; join before application |
| Kind `home-seed : PATH` | `home-seed KIND PATH`, argument 2 | Join against the workplace root before executable validation and build-time use |
| Kind `home-variable : NAME = SUBPATH` | `home-variable KIND NAME SUBPATH`, argument 3 | Preserve raw relative-or-dot spelling; resolve against that seat's private home, never the workplace root |
| Generated `workdir : ROOT` | `configure root ROOT`, argument 2 | ROOT is already absolute canonical and is the root parameter, not a relative resource to rejoin |

The first element of the JSON command array is also a path position. A bare program name uses the seat's PATH. An absolute program path is taken as written. A relative program path containing a slash stands beneath the workplace root. The frame validates this element at plan time, since the language's argv capture is opaque JSON text. Later elements remain literal text; they are not recursively joined.

Environment values are text, even when they contain slashes. Office, room, seat and kind keys, key states, clearance values, file templates and program-origin paths are not resource-path positions. No line or arbitrary string is rewritten by the assembler. Key homes, private program homes, sockets and fixed runtime views remain frame mechanisms. Home-variable names and runtime expected names are identifiers, not path positions; supplied runtime values are text. A seed's path is build-time code and may be inside the configuration clone; a seat's executable and directories may not (definition5.40).

The absolute edition may anchor a resource outside the root. The relative edition needs no such anchor beneath its root. The absolute filesystem root `/` and the workplace-root spelling `.` retain different meanings.
