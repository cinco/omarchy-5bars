#!/usr/bin/env python3
"""Apply edits.json to an Omarchy Bar.qml, offline.

The plugin does this at runtime; this is the same table applied from a shell,
for checking a new Omarchy release before anyone's bar falls back to stock:

    python3 dev/apply-edits.py /usr/share/omarchy/shell/plugins/bar/Bar.qml
    python3 dev/apply-edits.py <upstream> <out.qml>      # also write the result

Exits non-zero naming the first edit whose anchor no longer matches, which is
the signal to re-anchor it. edits.json is the single source of truth — the
plugin reads the same file.
"""
import json, os, sys

here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
edits = json.load(open(os.path.join(here, "edits.json")))
src = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/omarchy/shell/plugins/bar/Bar.qml"
text = open(src).read()

for edit in edits:
    seen = text.count(edit["old"])
    if seen != edit["count"]:
        sys.exit(f"ANCHOR MOVED [{edit['label']}]: expected {edit['count']} "
                 f"match(es), found {seen}\n---\n{edit['old'][:400]}")
    text = text.replace(edit["old"], edit["new"])

print(f"{len(edits)} edits apply cleanly to {src}")
if len(sys.argv) > 2:
    open(sys.argv[2], "w").write(text)
    print(f"wrote {sys.argv[2]}")
