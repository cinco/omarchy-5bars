# Upstream

5bars needs changes **inside** Omarchy's bar engine — which layout a surface
renders, which screens get a surface at all. Those live in the middle of
`Bar.qml`, out of reach of subclassing or composition, so the engine has to be
modified. What it does **not** do is ship a modified copy.

## How it works

`Bar.qml` in this repo is a ~450-line wrapper. At startup it reads the
`Bar.qml` of the **installed** Omarchy package, applies an edit table,
compiles the result in memory, and instantiates that. There are two tables,
one per generation of the bar (see below), and the first whose anchors all
match wins. The
patched text is never written to disk, so there is no staged copy for anything
else to replace. `CompiledBars.qml` (a singleton, registered by `qmldir`)
keeps each compiled text for the rest of the session, so rebuilding the bar
does not compile it again. Nothing upstream is copied into this repository — the
only upstream text here is the anchors quoted in the edit tables.

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

The tables are the single source of truth: the plugin reads them at runtime
and the offline checker reads the same files, in the same order.

```bash
python3 dev/apply-edits.py /usr/share/omarchy/shell/plugins/bar/Bar.qml
```

Reports each table and which one the plugin will use; exits non-zero when
neither applies, naming the first edit whose anchor moved in each. Re-anchor
that edit in the table for that generation; do not hand-edit anything else.

| | `edits.json` (pooled) | `edits-legacy.json` (legacy) |
|---|---|---|
| Base | `shell/plugins/bar/Bar.qml`, read from the installed package | same |
| Verified against | omarchy-dev 4.0.0.r7083.g81fd2d2-1 | omarchy 4.0.5 (tag `v4.0.5`) |
| That file's sha256 (first 16) | `33f359bfba0cd17d` | `a8f27b3d8f29f8b8` |
| Edits | 30 | 35 |

The legacy table is 5bars 1.1.1's, unchanged. It stays for as long as a stable
release ships the bar before the pool; when none does, it can go. The panel
follows whichever was applied — it tells them apart by `dropBarModule()`, which
only the legacy bar has — so on 4.0.x it still shows three sections, the centre
anchor and the transparency switch, and never migrates `shell.json`.

## The pooled bar (5bars 1.2.0)

r7083 rewrote the bar around a widget pool, and 29 of 35 anchors went at once.
This was a re-port rather than a re-anchor, because what the edits hook into
changed shape — and the stable channel had not moved yet, so the old table was
kept beside the new one instead of replaced:

- **Widgets come from a pool per surface.** `BarModel.layoutWidgets` gives every
  layout entry a key it keeps wherever it moves; each surface's `WidgetPool`
  builds one `WidgetHost` per key and lends it to the `ModuleSlot` showing it.
  So per-screen layouts are now per-screen *widget sets*: `screenWidgets`
  holds one `layoutWidgets` result per profile, each with its own memo,
  `BarPanel.widgets` picks the surface's, and the pool, the hosts and every
  section list read through it. Keys only need to be unique within a profile.
- **Drags write through `BarModel.moveEntry`,** which only knows
  `config.bar.layout`. `profileConfig()` hands it a config-shaped view of the
  screen's profile, and the move carries its screen, because the drag is
  cleared before the move lands.
- **The settings delta is gone.** A settings-only write keeps its widget and
  hands it the new entry, so neither the delta guard nor `pillSignature` is
  needed any more.
- **`centerAnchor` is gone,** replaced by `centerBegin`/`center`/`centerEnd`.
  Upstream's migration (1791969355) skips any config whose bar is not the
  built-in one, so 5bars splits on read and rewrites the file once
  (`migrateCenterAnchors`), profile by profile.
- **`transparent` became `background`** (`opaque`/`glassy`/`none`). Pills
  read it the way upstream does, and the pooled host calls `cycleBackground`
  where the legacy one calls `toggleTransparency`. The wrapper forwards both,
  together with `screenBarSizes`, which the pooled host now reads too.

## Licence

Omarchy is MIT (David Heinemeier Hansson). The anchors in the edit tables quote
its source; `LICENSE` carries both notices.
