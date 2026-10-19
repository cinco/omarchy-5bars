#!/usr/bin/env python3
"""Apply the edit tables to an Omarchy Bar.qml, offline.

The plugin does this at runtime; this is the same tables applied from a shell,
for checking a new Omarchy release before anyone's bar falls back to stock:

    python3 dev/apply-edits.py /usr/share/omarchy/shell/plugins/bar/Bar.qml
    python3 dev/apply-edits.py <upstream> <out.qml>      # also write the result

Two tables ship, tried in the plugin's order: edits.json for the pooled bar,
edits-legacy.json for the bar before it. Each is reported; the first that
applies is the one the plugin will use, and the one written out. Exits non-zero
when neither applies, naming the first edit whose anchor no longer matches in
each, which is the signal to re-anchor it. The tables are the single source of
truth — the plugin reads the same files.
"""
import json, os, sys

here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/omarchy/shell/plugins/bar/Bar.qml"
source = open(src).read()


def apply(table):
    edits = json.load(open(os.path.join(here, table)))
    text = source
    for edit in edits:
        seen = text.count(edit["old"])
        if seen != edit["count"]:
            return None, (f"ANCHOR MOVED [{edit['label']}]: expected {edit['count']} "
                          f"match(es), found {seen}\n---\n{edit['old'][:400]}")
        text = text.replace(edit["old"], edit["new"])
    return text, f"{len(edits)} edits apply cleanly"


used = None
for edition, table in (("pooled", "edits.json"), ("legacy", "edits-legacy.json")):
    text, report = apply(table)
    print(f"{table} ({edition}): {report}")
    if text is not None and used is None:
        used = (edition, text)

if used is None:
    sys.exit(f"neither table applies to {src}")

print(f"5bars will patch {src} with the {used[0]} table")
if len(sys.argv) > 2:
    open(sys.argv[2], "w").write(used[1])
    print(f"wrote {sys.argv[2]}")
