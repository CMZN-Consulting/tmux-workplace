# Relative resource-path fixture

The relative edition overlays the accepted five-seat reader-workplace fixture. Only thirteen program files change, so the overlay avoids duplicating its structure, kinds registry, directory declarations, environment and support data. Every program keeps its source address and line count.

The preparation script also makes the existing absolute edition with the updated shared layers, for comparison:

```sh
bash tests/fixtures/relative-workplace/prepare.sh absolute /absolute/new/config
bash tests/fixtures/relative-workplace/prepare.sh relative /another/new/config
```

Each destination must be a new absolute path whose parent already exists. The script copies no PLAN/, BUILD/ or runtime data. It copies the four current shared layers, so either edition receives the same declarations. It neither plans nor builds nor starts a workplace. Support files remain in reader-workplace/root/.

The relative edition writes `.` for the workplace root and relative suffixes for every resource beneath it. `/` remains the filesystem root. A command's executable is `tools/probe`, while its other words remain unchanged. The frame resolves the executable under the root; a bare command name still uses the seat's PATH. Directories were already written relative in the baseline and are unchanged.

The plan preserves path strings exactly as authored. The frame joins declared resource-path slots before folding and applying them, including directory and server slots. The frame checks the executable path inside command JSON; the language does not parse that element. Environment values, later command words and source-provenance paths are not resource slots. See [the path-slot inventory](../../../docs/path-slots.md).

PLAN/ records the files written for the materialized relative configuration at /tmp/workplace-reference-s3 by joining frame f4ea33f. Its raw plan is f007776c… and its 78-row view is cd4e82c6…, equal to the independent prediction and the absolute edition's view. Its manifest inputs name the complete prepared configuration, not only this sparse overlay. The script still prepares sources without copying PLAN/ so a new independent run can reproduce these files. No file from the earlier eager-join interface is reused. This fixture makes no live workplace or Identity mechanism claim.
