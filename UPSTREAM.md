# Upstream

5bars needs changes **inside** Omarchy's bar engine — which layout a surface
renders, which screens get a surface at all. Those live in the middle of
`Bar.qml`, out of reach of subclassing or composition, so the engine has to be
modified. What it does **not** do is ship a modified copy.

## How it works

`Bar.qml` in this repo is a ~230-line wrapper. At startup it reads the
`Bar.qml` of the **installed** Omarchy package, applies the table in
`edits.json`, stages the result under `$XDG_CACHE_HOME/omarchy-5bars/<hash>/`,
and instantiates that. Nothing upstream is copied into this repository — the
only upstream text here is the anchors quoted in `edits.json`.

Two things follow from that, and they are the whole reason for the design:

- **Upstream fixes arrive on their own.** The base is whatever version is on the
  machine, so an `omarchy update` is picked up at the next shell start.
- **An anchor that moves fails loudly and safely.** Every edit asserts its own
  match count. If one no longer matches, the plugin loads the **stock bar of
  that same version** and says why in a notification. A user never runs a
  frozen copy against a shell that has moved on.

## Checking a new Omarchy release

`edits.json` is the single source of truth: the plugin reads it at runtime and
the offline checker reads the same file.

```bash
python3 dev/apply-edits.py /usr/share/omarchy/shell/plugins/bar/Bar.qml
```

Exits non-zero naming the first edit whose anchor moved. Re-anchor that edit in
`edits.json`; do not hand-edit anything else.

| | |
|---|---|
| Base | `shell/plugins/bar/Bar.qml`, read from the installed package |
| Verified against | Omarchy 4.0.1-1 |
| That file's sha256 (first 16) | `a9db2da058c2822d` |
| Edits | 32 |

## Licence

Omarchy is MIT (David Heinemeier Hansson). The anchors in `edits.json` quote
its source; `LICENSE` carries both notices.
