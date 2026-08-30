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
// package, applies the edit table in `edits.json`, stages the result under the
// user's cache, and instantiates that. The base is whatever version is on the
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
  readonly property string cacheRoot: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
    + "/omarchy-5bars"

  // The live bar. Everything the host and every widget talks to is this object,
  // never the wrapper — see handOver() for why that matters.
  property var inner: null
  property string mode: "starting"     // starting | patched | stock | failed
  property string failure: ""

  // ── staging ────────────────────────────────────────────────────────────

  function hashOf(text) {
    // djb2 over the text, plus the length. Only has to distinguish versions,
    // not resist anything.
    var h = 5381
    for (var i = 0; i < text.length; i++) h = ((h * 33) ^ text.charCodeAt(i)) >>> 0
    return h.toString(16) + "-" + text.length
  }

  // The cache path is a DIRECTORY per hash, not a file per hash. A second
  // differently-named .qml in a directory the engine has already seen is
  // rejected with "File name case mismatch", and Qt.clearComponentCache() does
  // not invalidate the type loader's directory listing. One directory per
  // version sidesteps it entirely. (Learned the hard way: E3.2.)
  function stage(patched, barModel, hash) {
    var dir = cacheRoot + "/" + hash
    stagedBar.path = dir + "/Bar.qml"
    stagedBar.setText(patched)
    stagedModel.path = dir + "/BarModel.js"
    stagedModel.setText(barModel)
    return "file://" + dir + "/Bar.qml"
  }

  function applyEdits(source) {
    var text = source
    var table = JSON.parse(editsFile.text())
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

    var patched
    try {
      patched = applyEdits(source)
    } catch (e) {
      // An anchor moved. This is the expected way to fail after an Omarchy
      // update, and it must not take the user's bar with it.
      fallback(String(e.message || e))
      return
    }

    var url = stage(patched, upstreamModel.text(), hashOf(patched))
    console.log("5bars: staged " + url)
    load(url, "patched")
  }

  // The fallback loads upstream's file by its ORIGINAL url. Staging a copy of
  // the stock bar into the cache directory fails — the engine refuses the
  // second file name in a directory it has already loaded from — and a
  // fallback that itself fails leaves the session with no bar at all. (E3.1.)
  function fallback(reason) {
    failure = reason
    console.warn("5bars: falling back to the stock bar because: " + reason)
    notify.command = ["omarchy-notification-send", "-g", "󰍹", "5bars",
      "Could not patch the bar, using the built-in one. " + reason]
    notify.running = true
    load("file://" + upstreamDir + "/Bar.qml", "stock")
  }

  function load(url, wanted) {
    var component = Qt.createComponent(url, Component.Asynchronous)
    function ready() {
      if (component.status === Component.Loading) return
      if (component.status !== Component.Ready) {
        mode = "failed"
        console.warn("5bars: " + url + " failed to load: " + component.errorString())
        return
      }
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
        mode = "failed"
        console.warn("5bars: " + url + " could not be instantiated: " + component.errorString())
        return
      }
      created.barConfig = root.barConfig
      created.manifest = root.manifest
      if ("pluginRegistry" in created) created.pluginRegistry = root.pluginRegistry
      root.inner = created
      root.mode = wanted
      handOver()
      console.log("5bars: bar up, mode=" + wanted)
    }
    if (component.status === Component.Loading) component.statusChanged.connect(ready)
    else ready()
  }

  // The host sets shell.bar to whatever it loaded — this wrapper — and then
  // everything reads the bar through it: panel hotkeys, transparency, bar
  // geometry, and the notification service asking how tall the bar is. The
  // wrapper has none of that. Repointing shell.bar at the real object makes
  // the whole thing transparent, and means no facade has to forward anything.
  // Verified both ways in a nested session: pointed at the wrapper, the
  // notification service reads a bar height of 0 and summon returns unknown;
  // pointed at the inner object, both are correct. (E1c.)
  function handOver() {
    if (shell && inner && shell.bar !== inner) shell.bar = inner
  }

  // Three things have to arrive before the bar can be built, and they arrive
  // independently: the host injects the registry after loading this component,
  // and the two FileViews load asynchronously. Waiting on all three is the
  // whole point — the first version built as soon as the registry landed, read
  // an empty file, and fell back to the stock bar for no reason.
  readonly property bool sourcesReady: upstreamRead && modelRead && editsRead && barWidgetRegistry !== null
  property bool upstreamRead: false
  property bool modelRead: false
  property bool editsRead: false

  onSourcesReadyChanged: if (sourcesReady && mode === "starting") build()

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
    onLoadFailed: function(error) { root.fallback("could not read " + path + ": " + error) }
  }

  FileView {
    id: upstreamModel
    path: root.upstreamDir + "/BarModel.js"
    preload: true
    printErrors: true
    onLoaded: root.modelRead = true
    onLoadFailed: function(error) { root.fallback("could not read " + path + ": " + error) }
  }

  // blockWrites keeps setText synchronous, so the file is on disk before
  // createComponent is asked for its url; without it the component can be
  // created against a path that does not exist yet.
  // The edit table, read rather than imported: one file is the source of truth
  // for both this and the offline checker in dev/, so they cannot drift.
  FileView {
    id: editsFile
    path: Qt.resolvedUrl("edits.json").toString().replace("file://", "")
    preload: true
    printErrors: true
    onLoaded: root.editsRead = true
    onLoadFailed: function(error) { root.fallback("could not read edits.json: " + error) }
  }

  FileView {
    id: stagedBar
    preload: false
    blockWrites: true
    atomicWrites: true
    printErrors: true
  }

  FileView {
    id: stagedModel
    preload: false
    blockWrites: true
    atomicWrites: true
    printErrors: true
  }

  Process { id: notify }

  // Diagnostics, and what the tests drive.
  IpcHandler {
    target: "5bars"

    function status(): string {
      return JSON.stringify({
        mode: root.mode,
        failure: root.failure,
        upstream: root.upstreamDir,
        handedOver: !!(root.shell && root.inner && root.shell.bar === root.inner),
        slots: root.inner && root.inner.moduleSlots ? root.inner.moduleSlots.length : 0,
        screens: root.inner && root.inner.enabledScreens
          ? root.inner.enabledScreens.map(function(s) { return String(s.name) }) : []
      })
    }
  }
}
