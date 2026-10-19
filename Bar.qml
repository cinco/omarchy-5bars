import QtQuick
import Quickshell
import Quickshell.Io

// The bar entry point: a wrapper that patches Omarchy's own bar in memory.
//
// 5bars needs changes inside the bar engine — which layout a surface renders,
// which screens get a surface at all — and those live in the middle of
// `Bar.qml`, out of reach of subclassing or composition. The obvious answer is
// to ship a modified copy, and that is what this plugin used to do. The copy
// is the problem: upstream's `Bar.qml` moves often, the manifest has no way to
// declare a compatible Omarchy version, and a frozen copy keeps running
// against a `qs.Ui` that has moved on. It never fails loudly; it just drifts.
//
// So nothing is copied. At startup this reads the `Bar.qml` of the *installed*
// package, applies the edit table in `edits.json`, compiles the result in
// memory, and instantiates that. Two tables ship: `edits.json` for the pooled
// bar (Omarchy r7083 on), `edits-legacy.json` for the one before it, which is
// what the stable 4.0.x releases still carry. The first whose anchors all
// match is the one used. The base is whatever version is on the
// machine, so upstream fixes arrive on their own. When an edit no longer
// matches — upstream moved the ground under an anchor — nothing is guessed:
// the user gets the stock bar of their own version plus a notification saying
// why, which is a bad afternoon instead of a silent lie.
//
// Everything here was learned from experiments in a nested compositor; the
// comments say which rule came from where, because none of them are guessable.
Item {
  id: root

  // Injected by the host in configureBar() (shell.qml), after this component
  // is loaded. Plain properties, not `required`: a bar plugin is loaded from a
  // URL and filled in afterwards, so a required property could never be
  // satisfied in time.
  property string omarchyPath: ""
  property var barWidgetRegistry: null
  property var barConfig: null
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string upstreamDir: (omarchyPath !== "" ? omarchyPath : Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy")
    + "/shell/plugins/bar"

  // The live bar. Everything the host and every widget talks to is this object,
  // never the wrapper — see handOver() for why that matters.
  property var inner: null
  property string mode: "starting"     // starting | patched | stock | failed
  property string failure: ""
  property string edition: ""          // pooled | legacy, once patched
  property bool fellBack: false        // the stock bar is a one-shot; see fallback()

  // ── compiling ──────────────────────────────────────────────────────────

  // The patched text never touches the disk. An earlier version staged it as
  // files under $XDG_CACHE_HOME and loaded them by URL, which meant running
  // whatever sat at a predictable path in a directory nobody verified. Now it
  // is compiled straight from the string this process just built, so there is
  // no file to swap and no stale copy to pick up.
  //
  // The text is compiled against upstream's own URL. That is what resolves its
  // relative import of BarModel.js — upstream's file, unmodified, so there is
  // nothing of ours to stage next to it. Compiling from data leaves the
  // engine's cache for that URL alone: the stock bar loaded from the same URL
  // afterwards is the stock bar, not this.
  readonly property string upstreamUrl: "file://" + upstreamDir + "/Bar.qml"

  // Qt.createQmlObject() hands back an instance, but what has to be kept and
  // reused across wrappers is a component — see CompiledBars — so the patched
  // root object is compiled as the value of a Component-typed property, which
  // QML wraps implicitly. (A literal Component root works too, and is warned
  // about as deprecated.) The wrapper opens on the root object's own line and
  // closes after it, so it shifts no line numbers — but the edits do, by
  // hundreds of lines, and the patched text exists nowhere on disk. A line
  // number alone would send whoever reads the notification to the wrong line
  // of the installed Bar.qml, so each error quotes the offending line of the
  // patched text as well.
  //
  // Compiling goes through CompiledBars, which keeps the result for the rest of
  // the session; see there for why it cannot live in this wrapper.
  function compile(patched) {
    var at = patched.search(/^[A-Z][\w.]*\s*\{/m)
    if (at < 0) throw new Error("no root object in the patched bar")
    var text = patched.slice(0, at) + "QtObject { property Component bar: "
      + patched.slice(at) + "\n}\n"
    try {
      return CompiledBars.component(text, upstreamUrl)
    } catch (e) {
      var errors = e.qmlErrors || []
      if (errors.length === 0) throw e
      var lines = patched.split("\n")
      throw new Error("the patched bar does not compile: " + errors.map(function(err) {
        var quoted = String(lines[err.lineNumber - 1] || "").trim()
        if (quoted.length > 120) quoted = quoted.slice(0, 117) + "..."
        return "patched Bar.qml:" + err.lineNumber + ":" + err.columnNumber + ": "
          + err.message + (quoted !== "" ? " (at `" + quoted + "`)" : "")
      }).join("; "))
    }
  }

  function applyEdits(source, tableText) {
    var text = source
    var table = JSON.parse(tableText)
    for (var i = 0; i < table.length; i++) {
      var edit = table[i]
      var seen = text.split(edit.old).length - 1
      if (seen !== edit.count)
        throw new Error("edit '" + edit.label + "' expected " + edit.count
          + " match(es), found " + seen)
      text = text.split(edit.old).join(edit.new)
    }
    return text
  }

  function build() {
    var source = upstreamBar.text()
    if (!source || source.length === 0) { fallback("could not read " + upstreamDir + "/Bar.qml"); return }

    // The pooled table first: it is the bar Omarchy is moving to. The legacy
    // one covers the releases that still ship the bar before it, so one 5bars
    // serves both channels until stable catches up.
    var patched
    var misses = []
    var tables = [
      { edition: "pooled", file: editsFile },
      { edition: "legacy", file: legacyEditsFile }
    ]
    for (var t = 0; t < tables.length && patched === undefined; t++) {
      try {
        patched = applyEdits(source, tables[t].file.text())
        edition = tables[t].edition
      } catch (e) {
        misses.push(tables[t].edition + ": " + String(e.message || e))
      }
    }
    if (patched === undefined) {
      // An anchor moved in both. This is the expected way to fail after an
      // Omarchy update, and it must not take the user's bar with it.
      fallback(misses.join("; "))
      return
    }

    var component
    try {
      component = compile(patched)
    } catch (e) {
      fallback(String(e.message || e))
      return
    }
    console.log("5bars: built the patched bar in memory (" + edition + " edits)")
    patchedLoader.sourceComponent = component
    var created = patchedLoader.item
    if (!created) {
      // The one thing a Loader cannot build that createObject() can: a root
      // with a `required` property, which only an initial property satisfies.
      // Upstream has none today — the host loads its own clones through a
      // Loader too — but if one comes back, the patched bar is still worth
      // more than the stock one, at the price of the teardown warnings the
      // Loader exists to avoid. instantiate() falls back if this fails too.
      patchedLoader.sourceComponent = null
      console.warn("5bars: the Loader could not build the patched bar; retrying with createObject()")
      instantiate(component, "patched", "the patched bar")
      return
    }
    adopt(created, "patched")
  }

  // The fallback loads upstream's file by its ORIGINAL url — the file as
  // installed, with nothing of ours in between. A fallback that itself fails
  // leaves the session with no bar at all. (E3.1.)
  function fallback(reason) {
    // Several paths can reach this, and one bad startup can trip more than one
    // of them — both FileViews can fail at once. Falling back twice would
    // build a second stock bar on top of the first, so the first reason wins
    // and the rest are only logged.
    if (fellBack) { console.warn("5bars: already falling back; also: " + reason); return }
    fellBack = true
    failure = reason
    console.warn("5bars: falling back to the stock bar because: " + reason)
    // A component errorString spans lines; a notification body reads better as
    // one. The unsquashed text stays in `failure`, which is what ipc reports.
    notify.command = ["omarchy-notification-send", "-g", "󰍹", "5bars",
      "Could not patch the bar, using the built-in one. "
        + String(reason).replace(/\s+/g, " ").trim()]
    notify.running = true
    load(upstreamUrl, "stock")
  }

  // Compiling or instantiating the patched bar can fail for reasons the anchor
  // count cannot see: an upstream change that matches every anchor and still
  // produces invalid QML. Upstream adding a property this patch also adds is
  // the obvious one, and the anchor keeps matching because it is a prefix of a
  // block, not the whole block. That is the same failure as a moved anchor and
  // deserves the same exit: the stock bar of the user's own version, plus a
  // notification.
  //
  // The stock attempt is where that stops. There is nothing left to load, and
  // calling fallback() from there would ask for the same broken file again, so
  // that one branch is allowed to end with no bar — loudly.
  function loadFailed(wanted, reason) {
    if (wanted === "stock") {
      mode = "failed"
      console.warn("5bars: " + reason)
      // fallback() already told the user the built-in bar was on its way. It
      // is not, and a session with no bar and a notification saying otherwise
      // is worse than one that says so. Its own Process: the first one may
      // still be running.
      notifyNoBar.command = ["omarchy-notification-send", "-g", "󰍹", "5bars",
        "The built-in bar failed to load too; there is no bar. "
          + String(reason).replace(/\s+/g, " ").trim()]
      notifyNoBar.running = true
      return
    }
    fallback(reason)
  }

  function load(url, wanted) {
    var component = Qt.createComponent(url, Component.Asynchronous)
    function ready() {
      if (component.status === Component.Loading) return
      if (component.status !== Component.Ready) {
        loadFailed(wanted, url + " failed to load: " + component.errorString())
        return
      }
      instantiate(component, wanted, url)
    }
    if (component.status === Component.Loading) component.statusChanged.connect(ready)
    else ready()
  }

  function instantiate(component, wanted, what) {
    // barConfig and manifest are NOT passed here. Qt turns a JS object with
    // nested arrays into V4ReferenceObject sequences when it arrives as an
    // initial property, and upstream's Array.isArray() checks then see
    // nothing — the bar comes up empty. They are assigned as plain JS right
    // after, which keeps them real arrays. Passing null still satisfies the
    // `required` declarations. (E1b.)
    var created = component.createObject(root, {
      omarchyPath: root.omarchyPath,
      barWidgetRegistry: root.barWidgetRegistry,
      barConfig: null,
      shell: root.shell,
      manifest: null
    })
    if (!created) {
      // A Ready component that fails here — an unset required property, say —
      // leaves errorString() empty and the reason only in the shell log.
      loadFailed(wanted, what + " could not be instantiated: "
        + (component.errorString().trim() || "see the shell log for the reason"))
      return
    }
    created.barConfig = root.barConfig
    created.manifest = root.manifest
    if ("pluginRegistry" in created) created.pluginRegistry = root.pluginRegistry
    adopt(created, wanted)
  }

  // The patched bar is built by this Loader, not by createObject(), and the
  // difference is its QML context. A bar created straight from the cached
  // component gets a context under CompiledBars, which lives for the whole
  // session, so when this wrapper is torn down the old bar's bindings are
  // still live while its items come apart: every `parent.width` in a Repeater
  // re-evaluates against a null parent, twelve TypeErrors per rebuild, blamed
  // on a line of upstream's Bar.qml that does not hold that code. A Loader
  // gives the item a context of its own and deletes that context before the
  // item, so the bindings are dead by then — which is what destroying the
  // wrapper's own context used to do for the file-based bar.
  //
  // The price is that a Loader takes no initial properties, so everything is
  // injected after Component.onCompleted, in the order configureBar()
  // (shell.qml) uses. That is how the host itself injects every third-party
  // bar, upstream's own clone included, so upstream's Bar.qml is built for it.
  Loader {
    id: patchedLoader
    asynchronous: false
    onLoaded: {
      var created = item
      created.omarchyPath = root.omarchyPath
      created.shell = root.shell
      created.manifest = root.manifest
      created.barWidgetRegistry = root.barWidgetRegistry
      if ("pluginRegistry" in created) created.pluginRegistry = root.pluginRegistry
      created.barConfig = root.barConfig
    }
  }

  function adopt(created, wanted) {
    root.inner = created
    root.mode = wanted
    handOver()
    console.log("5bars: bar up, mode=" + wanted)
  }

  // The host sets shell.bar to whatever it loaded — this wrapper — and then
  // everything reads the bar through it: panel hotkeys, transparency, bar
  // geometry, and the notification service asking how tall the bar is. The
  // wrapper has none of that. Repointing shell.bar at the real object used to
  // make the whole thing transparent, so nothing had to be forwarded.
  // Verified both ways in a nested session: pointed at the wrapper, the
  // notification service reads a bar height of 0 and summon returns unknown;
  // pointed at the inner object, both are correct. (E1c.)
  //
  // Omarchy 4.0.3 closed that door. `configureBar` now hands a third-party bar
  // `pluginShellFor(manifest)` (shell.qml:221) instead of ShellRoot, and that
  // facade declares its own `bar` property (PluginShellApi.qml:16). The
  // assignment below therefore lands on the facade and the real `shell.bar`
  // stays pointed at this wrapper for good — silently, with every host read
  // returning a zero or an "unknown". It is kept because it is still correct
  // whenever `shell` really is ShellRoot, and it is free when it is not.
  function handOver() {
    if (shell && inner && shell.bar !== inner) shell.bar = inner
  }

  // True when the host handed over a sandboxed facade rather than ShellRoot,
  // which is what makes the forwarding below load-bearing. ShellRoot owns
  // configureBar(); the facade has no such method.
  readonly property bool shellIsFacade: !!shell && typeof shell.configureBar !== "function"

  // ── the host surface ───────────────────────────────────────────────────
  // Exactly what shell.qml touches on `shell.bar`, forwarded to the real bar:
  // the five values behind the per-plugin bar-state API (shell.qml:461-465),
  // the three bar-widget panel calls behind summon/hide/isOpen, the background
  // cycle behind toggleBarTransparency (:1801; a legacy host calls
  // toggleTransparency there instead), and the two diagnostics/hotkey entry
  // points. `barConfig` is already a wrapper property, forwarded by
  // onBarConfigChanged. Anything added to that list upstream lands here as a
  // dead host read, not a crash — which is why status() reports the facade.
  // `grep -o 'shell\.bar\.[a-zA-Z]*' shell.qml | sort -u` is the list to hold
  // this against after an update.
  readonly property bool barHidden: inner ? inner.barHidden === true : false
  readonly property int barSize: inner ? (inner.barSize || 0) : 0
  readonly property var screenBarSizes: inner && inner.screenBarSizes ? inner.screenBarSizes : ({})
  readonly property string fontFamily: inner ? String(inner.fontFamily || "") : ""
  readonly property string position: inner ? String(inner.position || "top") : "top"

  function summonBarWidget(id) {
    return !!inner && typeof inner.summonBarWidget === "function" && inner.summonBarWidget(id)
  }

  function hideBarWidget(id) {
    return !!inner && typeof inner.hideBarWidget === "function" && inner.hideBarWidget(id)
  }

  function isBarWidgetOpen(id) {
    return !!inner && typeof inner.isBarWidgetOpen === "function" && inner.isBarWidgetOpen(id)
  }

  function cycleBackground() {
    if (inner && typeof inner.cycleBackground === "function") inner.cycleBackground()
  }

  function toggleTransparency() {
    if (inner && typeof inner.toggleTransparency === "function") inner.toggleTransparency()
  }

  function debugBarGeometry() {
    return inner && typeof inner.debugBarGeometry === "function" ? inner.debugBarGeometry() : []
  }

  function panelWidgetIdAt(region, index) {
    return inner && typeof inner.panelWidgetIdAt === "function"
      ? inner.panelWidgetIdAt(region, index) : ""
  }

  // Four things have to arrive before the bar can be built, and they arrive
  // independently: the host injects the registry after loading this component,
  // and the three FileViews load asynchronously. Waiting on all of them is the
  // whole point — the first version built as soon as the registry landed, read
  // an empty file, and fell back to the stock bar for no reason.
  readonly property bool sourcesReady: upstreamRead && editsRead && legacyEditsRead && barWidgetRegistry !== null
  property bool upstreamRead: false
  property bool editsRead: false
  property bool legacyEditsRead: false

  onSourcesReadyChanged: if (sourcesReady && mode === "starting") { healRegistry(); build() }

  // ── a registry of dead components ──────────────────────────────────────
  // The host hands a third-party bar a *snapshot* of the widget registry: the
  // same Component objects the host holds, copied into a facade at
  // configureBar() time and refreshed only when the registry next changes.
  // When this wrapper is torn down and built again in the same session --
  // a shell.json that read as empty for an instant, because an editor
  // truncated it before writing, is enough: the host falls back to the stock
  // bar for that instant and comes back -- the snapshot it is handed was taken
  // while the host was still dropping and re-creating those Components. Most
  // entries then reference a Component that no longer exists, which QML reads
  // as null, so every slot resolves to the empty module and the bar comes up
  // blank. Nothing refreshes the facade afterwards; the next config write does,
  // and that is what the user was doing by hand ("write anything to shell.json
  // and it comes back"). Verified in a live session: 25 keys, 21 dead, 1 of 31
  // slots visible; one no-op write later, 25 of 31.
  //
  // A no-op config mutation is that write, done from here. The host persists
  // the same content (atomically), reassigns shellConfig, and re-syncs every
  // facade before mutateShellConfig() returns, so the registry is live again
  // by the time build() reads it. Once per instance: if the snapshot is still
  // dead after that, this is not the failure it was written for.
  function registryDead() {
    var widgets = barWidgetRegistry ? barWidgetRegistry.widgets : null
    if (!widgets) return false
    for (var id in widgets) {
      var entry = widgets[id]
      if (entry && entry.component === null) return true
    }
    return false
  }

  property bool registryHealed: false

  function healRegistry() {
    if (registryHealed || !registryDead()) return
    registryHealed = true
    if (!shell || typeof shell.mutateShellConfig !== "function") {
      console.warn("5bars: registry snapshot holds dead components and the host offers no way to refresh it")
      return
    }
    console.log("5bars: registry snapshot holds dead components; asking the host for a fresh one")
    shell.mutateShellConfig(function(config) {})
    if (registryDead()) console.warn("5bars: registry snapshot still dead after the refresh; widgets may not render until the next config change")
  }

  onInnerChanged: handOver()
  onBarConfigChanged: if (inner) inner.barConfig = barConfig
  onBarWidgetRegistryChanged: if (inner) inner.barWidgetRegistry = barWidgetRegistry

  // The host re-runs configureBar on reloads, which points shell.bar back at
  // the wrapper. Put it back.
  Connections {
    target: root.shell
    enabled: root.shell !== null
    function onBarChanged() { root.handOver() }
  }

  FileView {
    id: upstreamBar
    path: root.upstreamDir + "/Bar.qml"
    preload: true
    printErrors: true
    onLoaded: root.upstreamRead = true
    onLoadFailed: function(error) { root.fallback("could not read " + path + ": " + FileViewError.toString(error)) }
  }

  // The edit tables, read rather than imported: the same files are the source
  // of truth for both this and the offline checker in dev/, so they cannot
  // drift.
  FileView {
    id: editsFile
    path: Qt.resolvedUrl("edits.json").toString().replace("file://", "")
    preload: true
    printErrors: true
    onLoaded: root.editsRead = true
    onLoadFailed: function(error) { root.fallback("could not read edits.json: " + FileViewError.toString(error)) }
  }

  FileView {
    id: legacyEditsFile
    path: Qt.resolvedUrl("edits-legacy.json").toString().replace("file://", "")
    preload: true
    printErrors: true
    onLoaded: root.legacyEditsRead = true
    onLoadFailed: function(error) { root.fallback("could not read edits-legacy.json: " + FileViewError.toString(error)) }
  }

  Process { id: notify }
  Process { id: notifyNoBar }

  // Diagnostics, and what the tests drive.
  IpcHandler {
    target: "5bars"

    function status(): string {
      return JSON.stringify({
        mode: root.mode,
        edition: root.edition,
        failure: root.failure,
        upstream: root.upstreamDir,
        // On 4.0.3 this is true against the facade's own `bar` slot while the
        // real shell.bar still points at the wrapper, so it says nothing about
        // the host on its own — read it together with shellIsFacade.
        handedOver: !!(root.shell && root.inner && root.shell.bar === root.inner),
        shellIsFacade: root.shellIsFacade,
        slots: root.inner && root.inner.moduleSlots ? root.inner.moduleSlots.length : 0,
        screens: root.inner && root.inner.enabledScreens
          ? root.inner.enabledScreens.map(function(s) { return String(s.name) }) : []
      })
    }
  }
}
