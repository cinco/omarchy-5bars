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

## What the anchors do not guard

The anchor assertions cover the *patch*. They say nothing about the **host
contract** — what `configureBar` injects into a bar plugin, and what the shell
later reads back off `shell.bar`. That half has no checksum and fails
silently, which is exactly how 4.0.3 broke:

- `configureBar` stopped passing ShellRoot to a third-party bar and started
  passing `pluginShellFor(manifest)`, a `PluginShellApi` facade. The facade
  declares its own `bar` property, so the wrapper's `handOver()` — which used
  to repoint `shell.bar` at the real bar — began writing into the facade while
  the host kept reading the wrapper. Every host read degraded to a zero or an
  `"unknown"`: bar height for notification placement, `summon` of a bar-widget
  panel, `toggleBarTransparency`, `debugBarGeometry`, the panel-position
  hotkeys. The wrapper now forwards that surface explicitly.
- Third-party bar widgets stopped receiving the bar root and started receiving
  a `PluginBarApi` facade. 5bars' own Studio panel needs the real bar, so
  `injectProps` exempts `cinco.5bars` **and nothing else** — every other
  third-party widget keeps the sandbox upstream gave it.
- `pluginRegistryFor()` scopes a plugin's registry view to its own manifest,
  so the panel enumerates bar widgets from `bar.barWidgetRegistry` instead.

Pills widened that surface, so the same paragraph now covers more:

| Reached for | If it goes away |
|---|---|
| `Color.pick`, `Color.pickAlpha`, `Color.flatColor`, `Util.alpha` | checked at runtime (`pillThemingAvailable`); capsules fall back to the bar background at 0.85, which is what they were before colour was configurable |
| `~/.local/state/omarchy/current/theme/colors.toml` | read directly for the theme's full palette; absent or unreadable leaves the palette empty and tokens resolve through `Color` alone |
| `Color.backgroundChanged` / `accentChanged` | `ignoreUnknownSignals`; costs the theme-switch refresh of the palette, not the bar |
| `shell.mutateShellConfig` | already load-bearing for the panel; `healRegistry()` also uses it as a no-op write to force the host to re-hand its facades |
| a bar widget's `containmentMask` | how a capsule learns what the widget actually paints; a widget without one fills its slot, which is the old behaviour |

Checking a new release therefore means running the checker **and** confirming
`shell.qml`'s `configureBar` still hands over what the wrapper expects. The
`5bars` IPC target reports the injected shell's kind for exactly this reason:

```bash
qs ipc -i <instance> call 5bars status     # shellIsFacade tells you which
```

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
| Verified against | Omarchy 4.0.3-1 |
| That file's sha256 (first 16) | `9874c0f36271840b` |
| Edits | 35 |

## Licence

Omarchy is MIT (David Heinemeier Hansson). The anchors in `edits.json` quote
its source; `LICENSE` carries both notices.
