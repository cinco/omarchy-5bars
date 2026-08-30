import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

// Visual editor for per-screen bar layouts.
//
// One tab per output, plus the default profile every output falls back to.
// Reordering goes through the bar's own bar.dropBarModule() -- the same call
// a drag gesture makes -- so an edit here and a drag on the bar are the same
// shell.json write, landing in the same profile. Adds, removes and profile
// creation are written here, because the plugin registry's placement helpers
// only know about bar.layout and would silently retarget the default.
Panel {
  id: root
  moduleName: "cinco.5bars"
  ipcTarget: "cinco.5bars"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var shellHost: bar ? bar.shell : null
  readonly property var registry: shellHost ? shellHost.pluginRegistry : null

  // Bound to the live config so the panel redraws the moment anything writes
  // shell.json -- including a drag on either bar while this panel is open.
  readonly property var barConfig: {
    var config = shellHost ? shellHost.shellConfig : null
    return config && config.bar ? config.bar : ({})
  }

  readonly property var sections: ["left", "center", "right"]
  readonly property var sectionLabels: ({ "left": "LEFT", "center": "CENTER", "right": "RIGHT" })

  // "" is the default profile. Any other value is an output name.
  property string activeScreen: ""
  property string addSection: "right"

  // Sections start collapsed. The panel is tall enough with three open lists
  // that the add-widget dropdown opens past the bottom of the screen, and the
  // header carries the count anyway -- which is most of what a glance wants.
  property var openSections: ({})
  property string addQuery: ""

  function isOpen(name) { return openSections[String(name)] === true }

  function toggleSection(name) {
    var next = ({})
    for (var key in openSections) next[key] = openSections[key]
    next[String(name)] = !next[String(name)]
    openSections = next
  }

  onOpenedChanged: if (opened) { addSection = "right"; openSections = ({}); addQuery = "" }

  // Values reaching Button labels, tooltips and PanelHero details are rendered
  // by qs.Ui components that declare no textFormat, so Qt treats them as
  // AutoText and interprets markup. Anything that did not come from this
  // plugin's own source is stripped of angle brackets and bounded first.
  function safeText(value, limit) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/[<>]/g, "")
      .substring(0, limit === undefined ? 160 : limit)
  }

  // ------------------------------------------------------------------ screens

  readonly property var screensConfig: {
    var screens = barConfig.screens
    return screens && typeof screens === "object" ? screens : ({})
  }

  function hasProfile(name) {
    var key = String(name || "")
    return key !== "" && screensConfig[key] !== undefined && screensConfig[key] !== null
  }

  // Connected outputs first, then any profile whose monitor is unplugged --
  // an unplugged screen keeps its profile, and has to stay reachable so it can
  // be edited or dropped without waiting for the hardware to come back.
  readonly property var outputs: {
    var config = screensConfig
    var out = []
    var seen = ({})
    var live = Quickshell.screens
    for (var i = 0; i < live.length; i++) {
      var name = String(live[i].name || "")
      if (name === "" || seen[name]) continue
      seen[name] = true
      out.push({
        name: name,
        connected: true,
        detail: root.safeText(live[i].model || "", 40) + " · " + live[i].width + "×" + live[i].height
      })
    }
    for (var key in config) {
      if (seen[String(key)]) continue
      out.push({ name: String(key), connected: false, detail: "not connected" })
    }
    return out
  }

  readonly property int profileCount: {
    var config = screensConfig
    var n = 0
    for (var key in config) n++
    return n
  }

  function outputDetail(name) {
    var list = outputs
    for (var i = 0; i < list.length; i++) if (list[i].name === String(name)) return list[i].detail
    return ""
  }

  // ------------------------------------------------------------- layout reads

  // The layout a screen actually renders: its own when it has a profile, the
  // default when it does not. Mirrors Bar.qml's layoutFor().
  function layoutOf(screen) {
    var key = String(screen || "")
    if (key !== "" && hasProfile(key)) {
      var profile = screensConfig[key]
      var own = profile ? profile.layout : null
      return own && typeof own === "object" ? own : ({})
    }
    return barConfig.layout && typeof barConfig.layout === "object" ? barConfig.layout : ({})
  }

  function entriesIn(section, screen) {
    var layout = layoutOf(screen)
    var arr = layout ? layout[section] : null
    if (!(arr instanceof Array)) return []
    var out = []
    for (var i = 0; i < arr.length; i++) {
      if (!arr[i] || !arr[i].id) continue
      out.push({ id: String(arr[i].id), index: out.length, section: section })
    }
    return out
  }

  function countIn(screen) {
    return entriesIn("left", screen).length
      + entriesIn("center", screen).length
      + entriesIn("right", screen).length
  }

  function centerAnchorOf(screen) {
    var key = String(screen || "")
    if (key !== "" && hasProfile(key)) {
      var profile = screensConfig[key]
      if (profile && profile.centerAnchor !== undefined && profile.centerAnchor !== null)
        return String(profile.centerAnchor)
    }
    return String(barConfig.centerAnchor || "")
  }

  function manifestFor(id) {
    var plugins = registry ? registry.installedPlugins : null
    return plugins ? plugins[String(id)] || null : null
  }

  function displayName(id) {
    var manifest = manifestFor(id)
    if (manifest) {
      var meta = manifest.barWidget || {}
      return String(meta.displayName || manifest.name || id)
    }
    // Custom command/qml modules have no manifest; show the raw id, which came
    // from shell.json and is therefore untrusted.
    return safeText(id, 80)
  }

  function isPlaced(id, screen) {
    for (var s = 0; s < sections.length; s++) {
      var entries = entriesIn(sections[s], screen)
      for (var i = 0; i < entries.length; i++) if (entries[i].id === String(id)) return true
    }
    return false
  }

  // Installed bar widgets not already on the profile being edited. Scoped to
  // the profile, not the bar: a widget on the wide screen is still available
  // to add to the narrow one.
  readonly property var availableWidgets: {
    var revision = registry ? registry.registryRevision : 0
    var config = barConfig
    var screen = activeScreen
    var plugins = registry ? registry.installedPlugins : null
    if (!plugins) return []
    var out = []
    for (var id in plugins) {
      var manifest = plugins[id]
      if (!manifest || !(manifest.kinds instanceof Array)) continue
      if (manifest.kinds.indexOf("bar-widget") === -1) continue
      if (isPlaced(id, screen)) continue
      var meta = manifest.barWidget || {}
      out.push({
        value: String(id),
        label: String(meta.displayName || manifest.name || id),
        description: String(meta.description || "")
      })
    }
    out.sort(function(a, b) { return a.label.toLowerCase() < b.label.toLowerCase() ? -1 : 1 })
    return out
  }

  // How many rows the add list shows before it scrolls. It bounds the
  // viewport, not the results: everything installed stays reachable by
  // scrolling, and the search box is a shortcut rather than the only way past.
  readonly property int addViewportRows: 7
  readonly property int addRowHeight: Style.spacing.controlHeight

  readonly property var matchingWidgets: {
    var all = availableWidgets
    var needle = String(addQuery).toLowerCase().trim()
    if (needle === "") return all
    var out = []
    for (var i = 0; i < all.length; i++) {
      if (String(all[i].label).toLowerCase().indexOf(needle) === -1
          && String(all[i].value).toLowerCase().indexOf(needle) === -1) continue
      out.push(all[i])
    }
    return out
  }

  // ------------------------------------------------------------ layout writes

  function mutate(fn) {
    if (!shellHost || typeof shellHost.mutateShellConfig !== "function") return false
    shellHost.mutateShellConfig(fn)
    return true
  }

  function emptyLayout() {
    return { left: [], center: [], right: [] }
  }

  function ensureBarShape(config) {
    if (!config.bar || typeof config.bar !== "object") config.bar = {}
    if (!config.bar.layout || typeof config.bar.layout !== "object") config.bar.layout = emptyLayout()
    for (var s = 0; s < sections.length; s++)
      if (!(config.bar.layout[sections[s]] instanceof Array)) config.bar.layout[sections[s]] = []
    return config
  }

  // The section array a write should land in: a screen's own when it has a
  // profile, the default otherwise. Same rule as Bar.qml's rawLayoutSection(),
  // so the panel and a drag can never disagree about where an edit goes.
  function sectionArray(config, section, screen) {
    ensureBarShape(config)
    var key = String(screen || "")
    if (key !== "" && config.bar.screens && typeof config.bar.screens === "object"
        && config.bar.screens[key] && typeof config.bar.screens[key] === "object") {
      var profile = config.bar.screens[key]
      if (!profile.layout || typeof profile.layout !== "object") profile.layout = emptyLayout()
      if (!(profile.layout[section] instanceof Array)) profile.layout[section] = []
      return profile.layout[section]
    }
    return config.bar.layout[section]
  }

  // Seeded from the default rather than started empty: on the screen that
  // needs its own profile the work is nearly always taking things away, so
  // starting from what is already on that bar is fewer steps and keeps the
  // widget settings (clock format, tray pins) that came with them.
  function createProfile(screen) {
    var key = String(screen || "")
    if (key === "") return
    mutate(function(config) {
      ensureBarShape(config)
      if (!config.bar.screens || typeof config.bar.screens !== "object") config.bar.screens = {}
      if (config.bar.screens[key]) return
      var seeded = JSON.parse(JSON.stringify(config.bar.layout))
      for (var s = 0; s < root.sections.length; s++)
        if (!(seeded[root.sections[s]] instanceof Array)) seeded[root.sections[s]] = []
      var profile = { layout: seeded }
      if (config.bar.centerAnchor !== undefined && config.bar.centerAnchor !== null)
        profile.centerAnchor = String(config.bar.centerAnchor)
      config.bar.screens[key] = profile
    })
  }

  // Dropping a profile returns the screen to the default. The entry is deleted
  // rather than emptied, because an empty profile is a deliberately blank bar
  // and inheriting is a different thing to mean.
  function dropProfile(screen) {
    var key = String(screen || "")
    if (key === "") return
    mutate(function(config) {
      if (!config.bar || !config.bar.screens) return
      delete config.bar.screens[key]
      var remaining = 0
      for (var name in config.bar.screens) remaining++
      if (remaining === 0) delete config.bar.screens
    })
  }

  function isFirstParty(id) {
    var plugins = registry ? registry.installedPlugins : null
    var manifest = plugins ? plugins[String(id)] : null
    return !!(manifest && manifest.__isFirstParty)
  }

  function inDefaultLayout(config, key) {
    if (!config.bar || !config.bar.layout) return false
    for (var s = 0; s < root.sections.length; s++) {
      var entries = config.bar.layout[root.sections[s]]
      if (!(entries instanceof Array)) continue
      for (var i = 0; i < entries.length; i++)
        if (entries[i] && String(entries[i].id) === key) return true
    }
    return false
  }

  function placedAnywhere(config, key) {
    if (inDefaultLayout(config, key)) return true
    var screens = config.bar ? config.bar.screens : null
    if (!screens || typeof screens !== "object") return false
    for (var name in screens) {
      var layout = screens[name] ? screens[name].layout : null
      if (!layout || typeof layout !== "object") continue
      for (var s = 0; s < root.sections.length; s++) {
        var entries = layout[root.sections[s]]
        if (!(entries instanceof Array)) continue
        for (var i = 0; i < entries.length; i++)
          if (entries[i] && String(entries[i].id) === key) return true
      }
    }
    return false
  }

  // Whether a widget's component gets loaded at all is upstream's call, and it
  // answers with PluginRegistry.isEnabled(). For a third-party widget that
  // falls through to findEntryLocation(), which looks in exactly two places:
  // the default `bar.layout`, and `plugins`. It has never heard of
  // `bar.screens` -- findBarLocation() only ever walks `config.bar.layout`.
  //
  // So a widget placed on a screen profile and nowhere else is never enabled.
  // 5bars builds its slot on the right bar, the slot asks the registry for a
  // component, the registry has none, and the slot renders 0x0: placed and
  // invisible. That is the same failure the disabledPlugins line below guards
  // against, reached through the other door.
  //
  // `plugins` is the door that fits. It means "load this", not "put it on
  // every bar", so the placement stays exactly as per-screen as the user asked
  // for. Writing into `bar.layout` would enable it too -- by putting it on
  // every screen, which is the bug.
  function ensureLoadable(config, key) {
    if (isFirstParty(key)) return
    if (!(config.plugins instanceof Array)) config.plugins = []
    for (var i = 0; i < config.plugins.length; i++)
      if (config.plugins[i] && String(config.plugins[i].id) === key) return
    config.plugins.push({ id: key })
  }

  // The marker is only ours to take back once the widget is off every bar, and
  // only when it is bare: an entry that grew settings is the user's, and
  // dropping it would take their settings with it.
  function dropLoadableMarker(config, key) {
    if (!(config.plugins instanceof Array)) return
    for (var i = 0; i < config.plugins.length; i++) {
      var entry = config.plugins[i]
      if (!entry || String(entry.id) !== key) continue
      if (Object.keys(entry).length > 1) return
      config.plugins.splice(i, 1)
      return
    }
  }

  // ── repair of configs written before the marker existed ────────────────

  property bool loadableRepairDone: false

  // addWidget keeps the marker right from here on, but a shell.json written by
  // an older 5bars is already wrong on disk: the widget sits in a profile with
  // nothing telling upstream to load it, so it stays invisible until the user
  // removes and re-adds it. Nobody should have to guess that, so the upgrade
  // repairs it once.
  //
  // Where this runs from was the real decision. Three candidates:
  //
  //   onOpenedChanged -- safe, but only repairs people who open the panel.
  //   Bar.qml startup -- covers everyone, but the wrapper's startup carries
  //     four rules that each cost an experiment, and a repair has no business
  //     being the fifth.
  //   this widget's own construction -- what it does.
  //
  // The third dominates the first at the first's risk. A config can only reach
  // the broken state through this plugin, and every route to it -- the panel,
  // or a hand edit copying what the panel writes -- leaves the 5bars widget on
  // a bar, so anyone repairable by opening the panel is already repairable at
  // construction, plus everyone who never thinks to open it. Same file, same
  // object, nothing added to Bar.qml. The coverage the wrapper would buy on
  // top of that is a user who has taken the 5bars button off every bar, who
  // also has no way to open the panel and no way to have got here; that is not
  // worth touching the wrapper for.
  function repairLoadableMarkers() {
    if (loadableRepairDone) return
    var host = shellHost
    var plugins = registry ? registry.installedPlugins : null
    // Properties arrive by injection after construction, so a miss here is
    // "not yet", not "never" -- leave the flag down and let the change signal
    // bring us back.
    if (!host || typeof host.mutateShellConfig !== "function" || !plugins) return
    loadableRepairDone = true
    // Read first and write only if there is something to write. On a healthy
    // config this has to cost nothing: a shell.json round trip at startup
    // rebuilds every bar on every screen, which is a lot to pay for a no-op.
    if (missingLoadableMarkers(host.shellConfig, plugins).length === 0) return
    mutate(function(config) {
      var pending = missingLoadableMarkers(config, plugins)
      for (var i = 0; i < pending.length; i++) ensureLoadable(config, pending[i])
    })
  }

  function missingLoadableMarkers(config, plugins) {
    var out = []
    if (!config || !config.bar) return out
    var screens = config.bar.screens
    if (!screens || typeof screens !== "object") return out
    var seen = ({})
    for (var name in screens) {
      var layout = screens[name] ? screens[name].layout : null
      if (!layout || typeof layout !== "object") continue
      for (var s = 0; s < sections.length; s++) {
        var entries = layout[sections[s]]
        if (!(entries instanceof Array)) continue
        for (var i = 0; i < entries.length; i++) {
          var key = entries[i] ? String(entries[i].id) : ""
          if (key === "" || seen[key] === true) continue
          seen[key] = true
          var manifest = plugins[key]
          if (!manifest || !(manifest.kinds instanceof Array)) continue
          if (manifest.kinds.indexOf("bar-widget") === -1) continue
          if (manifest.__isFirstParty) continue
          if (inDefaultLayout(config, key)) continue
          // Switched off on purpose: upstream's isDisabled() outranks the
          // marker anyway, so writing one would not turn it back on -- it
          // would only blur what the user said.
          if (config.disabledPlugins instanceof Array
              && config.disabledPlugins.indexOf(key) !== -1) continue
          var marked = false
          if (config.plugins instanceof Array)
            for (var p = 0; p < config.plugins.length; p++)
              if (config.plugins[p] && String(config.plugins[p].id) === key) { marked = true; break }
          if (marked) continue
          out.push(key)
        }
      }
    }
    return out
  }

  Component.onCompleted: Qt.callLater(root.repairLoadableMarkers)
  onShellHostChanged: Qt.callLater(root.repairLoadableMarkers)

  function addWidget(id, section, screen) {
    var key = String(id)
    if (key === "") return
    mutate(function(config) {
      var arr = root.sectionArray(config, String(section), screen)
      for (var i = 0; i < arr.length; i++)
        if (arr[i] && String(arr[i].id) === key) return
      arr.push({ id: key })
      // A widget's component is only loaded while the plugin is enabled, so a
      // previously disabled one has to be let back in or it would be placed
      // and invisible.
      if (config.disabledPlugins instanceof Array) {
        var at = config.disabledPlugins.indexOf(key)
        if (at !== -1) config.disabledPlugins.splice(at, 1)
      }
      // Landing only on a screen profile is invisible to upstream's enablement
      // check, so say it the way upstream can read.
      if (!root.inDefaultLayout(config, key)) root.ensureLoadable(config, key)
    })
  }

  // Removing never disables the plugin: the same widget is very likely still
  // on another screen, and disabling would take it off that one too.
  function removeWidget(id, section, screen) {
    var key = String(id)
    mutate(function(config) {
      var arr = root.sectionArray(config, String(section), screen)
      for (var i = 0; i < arr.length; i++) {
        if (arr[i] && String(arr[i].id) === key) { arr.splice(i, 1); break }
      }
      // Off every bar: the marker has nothing left to keep alive. Still on one,
      // but no longer on the default: a profile is now the only thing placing
      // it, so it needs the marker it never had -- this is how a profile seeded
      // from the default (createProfile) turns into the invisible case, one
      // removal at a time.
      if (!root.placedAnywhere(config, key)) root.dropLoadableMarker(config, key)
      else if (!root.inDefaultLayout(config, key)) root.ensureLoadable(config, key)
    })
  }

  function setCenterAnchor(value, screen) {
    var next = String(value) === "none" ? "" : String(value)
    var key = String(screen || "")
    mutate(function(config) {
      ensureBarShape(config)
      if (key !== "" && config.bar.screens && config.bar.screens[key]) {
        config.bar.screens[key].centerAnchor = next
        return
      }
      config.bar.centerAnchor = next
    })
  }

  // Stored as `enabled: false` so that a profile saying nothing about it is on,
  // matching how the layout inherits by omission.
  function screenEnabled(screen) {
    var profile = screensConfig[String(screen || "")]
    return !(profile && profile.enabled === false)
  }

  readonly property var enabledScreenNames: {
    var config = screensConfig
    var live = Quickshell.screens
    var out = []
    for (var i = 0; i < live.length; i++) {
      var name = String(live[i].name || "")
      if (name === "" || !screenEnabled(name)) continue
      out.push(name)
    }
    return out
  }

  // Switching off the only screen still drawing a bar would leave no bar at
  // all, and no way back that is not hand-editing shell.json. Asked about the
  // screen being acted on rather than the tab on show: the two are the same
  // when a click drives this, and are not when anything else does.
  function isLastEnabledScreen(screen) {
    var names = enabledScreenNames
    return names.length <= 1 && names.indexOf(String(screen || "")) !== -1
  }

  // A screen going dark must not take this panel with it. If this plugin is
  // not on any bar that will still be drawn, put it back on the default --
  // otherwise turning a screen off can remove the only control that could turn
  // it back on.
  function ensureStudioReachable(config) {
    var id = String(root.moduleName)
    var live = Quickshell.screens
    for (var i = 0; i < live.length; i++) {
      var name = String(live[i].name || "")
      if (name === "") continue
      var profile = config.bar.screens ? config.bar.screens[name] : null
      if (profile && profile.enabled === false) continue
      var layout = profile && profile.layout ? profile.layout : config.bar.layout
      if (!layout) continue
      for (var s = 0; s < root.sections.length; s++) {
        var arr = layout[root.sections[s]]
        if (!(arr instanceof Array)) continue
        for (var j = 0; j < arr.length; j++)
          if (arr[j] && String(arr[j].id) === id) return
      }
    }
    if (!(config.bar.layout.right instanceof Array)) config.bar.layout.right = []
    config.bar.layout.right.unshift({ id: id })
  }

  function setScreenEnabled(screen, on) {
    var key = String(screen || "")
    if (key === "") return
    if (on !== true && isLastEnabledScreen(key)) return
    mutate(function(config) {
      if (!config.bar || !config.bar.screens || !config.bar.screens[key]) return
      if (on === true) { delete config.bar.screens[key].enabled; return }
      config.bar.screens[key].enabled = false
      root.ensureStudioReachable(config)
    })
  }

  function setPosition(value) {
    mutate(function(config) {
      ensureBarShape(config)
      config.bar.position = String(value)
    })
  }

  function setTransparent(value) {
    mutate(function(config) {
      ensureBarShape(config)
      config.bar.transparent = value === true
    })
  }

  // Reorders go through the bar so the panel and a drag gesture stay one code
  // path. screenName is what routes the write to the right profile.
  function moveTo(id, fromSection, toSection, beforeId, screen) {
    if (!bar || typeof bar.dropBarModule !== "function") return
    bar.dropBarModule(
      { region: String(fromSection), moduleName: String(id), screenName: String(screen || "") },
      String(toSection),
      String(beforeId || ""))
  }

  function moveUp(section, index, screen) {
    var entries = entriesIn(section, screen)
    if (index <= 0 || index >= entries.length) return
    moveTo(entries[index].id, section, section, entries[index - 1].id, screen)
  }

  function moveDown(section, index, screen) {
    var entries = entriesIn(section, screen)
    if (index < 0 || index >= entries.length - 1) return
    // Insert before the entry two slots down; past the end means append.
    var beforeId = index + 2 < entries.length ? entries[index + 2].id : ""
    moveTo(entries[index].id, section, section, beforeId, screen)
  }

  function shiftSection(id, fromSection, delta, screen) {
    var order = sections
    var at = order.indexOf(String(fromSection))
    var next = at + delta
    if (at === -1 || next < 0 || next >= order.length) return
    moveTo(id, fromSection, order[next], "", screen)
  }

  // -------------------------------------------------------------------- view

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍹"
    fontSize: Style.bar.iconFont
    tooltipText: "5bars"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(660))

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "5bars"
          // The selected tab already says which profile is being edited, so the
          // chip only carries what the tabs do not: how many widgets are on it.
          meta: root.outputs.length + (root.outputs.length === 1 ? " screen" : " screens")
            + " · " + root.profileCount + " with a profile"
          detail: root.countIn(root.activeScreen) + " widgets"
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: "󰍹"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // ------------------------------------------------------------- tabs

        PanelSectionHeader {
          width: parent.width
          text: "SCREEN"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // A Flow rather than a ButtonGroup: the tab count follows the number of
        // monitors, and four or five output names do not fit on one row.
        Flow {
          width: parent.width
          spacing: Style.space(4)

          Button {
            text: "DEFAULT"
            selected: root.activeScreen === ""
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            tooltipText: "The layout every screen falls back to"
            onClicked: root.activeScreen = ""
          }

          Repeater {
            model: root.outputs

            Button {
              required property var modelData
              text: root.safeText(modelData.name, 24)
                + (modelData.connected ? "" : " ⚠")
                + (root.hasProfile(modelData.name) ? " ●" : " ○")
              selected: root.activeScreen === modelData.name
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              tooltipText: root.safeText(modelData.detail, 60)
                + (root.hasProfile(modelData.name) ? " · own profile" : " · inherits the default")
              onClicked: root.activeScreen = modelData.name
            }
          }
        }

        // ----------------------------------------------------- profile opt-in

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.activeScreen !== ""

          Text {
            width: parent.width
            text: root.safeText(root.outputDetail(root.activeScreen), 70)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          ButtonGroup {
            width: parent.width
            options: [
              { value: "inherit", label: "Use the default" },
              { value: "own", label: "Own profile" }
            ]
            value: root.hasProfile(root.activeScreen) ? "own" : "inherit"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onChanged: function(v) {
              if (v === "own") root.createProfile(root.activeScreen)
              else root.dropProfile(root.activeScreen)
            }
          }

          Text {
            width: parent.width
            visible: !root.hasProfile(root.activeScreen)
            text: "This screen renders the default layout. Giving it a profile starts from a copy of the default, so you edit down from what is already there."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // --------------------------------------------------------- bar-global

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.activeScreen === ""

          PanelSectionHeader {
            width: parent.width
            text: "BAR · ALL SCREENS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ButtonGroup {
            width: parent.width
            options: [
              { value: "top", label: "Top" },
              { value: "bottom", label: "Bottom" },
              { value: "left", label: "Left" },
              { value: "right", label: "Right" }
            ]
            value: String(root.barConfig.position || "top")
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onChanged: function(v) { root.setPosition(v) }
          }

          Toggle {
            width: parent.width
            label: "Transparent bar"
            description: "Applies to every screen"
            checked: root.barConfig.transparent === true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setTransparent(!(root.barConfig.transparent === true))
          }
        }

        // ------------------------------------------------------- this screen

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.activeScreen !== "" && root.hasProfile(root.activeScreen)

          PanelSectionHeader {
            width: parent.width
            text: "THIS SCREEN"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Toggle {
            width: parent.width
            label: "Show the bar here"
            description: root.isLastEnabledScreen(root.activeScreen) ? "The only bar left" : "Off gives its space back"
            checked: root.screenEnabled(root.activeScreen)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setScreenEnabled(root.activeScreen, !root.screenEnabled(root.activeScreen))
          }

        }

        // ----------------------------------------------------------- editor

        Column {
          width: parent.width
          spacing: Style.space(10)
          // The default is always editable; a screen only once it owns a profile.
          visible: root.activeScreen === "" || root.hasProfile(root.activeScreen)

          Dropdown {
            width: parent.width
            label: "Center anchor"
            options: {
              var out = [{ value: "none", label: "No anchor (center as a group)" }]
              var entries = root.entriesIn("center", root.activeScreen)
              for (var i = 0; i < entries.length; i++)
                out.push({ value: entries[i].id, label: root.displayName(entries[i].id) })
              return out
            }
            value: root.centerAnchorOf(root.activeScreen) === "" ? "none" : root.centerAnchorOf(root.activeScreen)
            foreground: root.foreground
            fontFamily: root.fontFamily
            onChanged: function(v) { root.setCenterAnchor(v, root.activeScreen) }
          }

          Repeater {
            model: root.sections

            Column {
              required property var modelData
              width: parent.width
              spacing: Style.space(4)

              readonly property bool sectionOpen: root.isOpen(modelData)

              Button {
                width: parent.width
                leftAlign: true
                bordered: true
                text: (parent.sectionOpen ? "▾  " : "▸  ") + root.sectionLabels[modelData]
                  + " · " + root.entriesIn(modelData, root.activeScreen).length
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.toggleSection(modelData)
              }

              Text {
                width: parent.width
                visible: parent.sectionOpen && root.entriesIn(modelData, root.activeScreen).length === 0
                text: "empty"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: parent.sectionOpen ? root.entriesIn(modelData, root.activeScreen) : []

                // Each row carries its own controls so a move is one click,
                // with no select-then-act step.
                Row {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(2)

                  readonly property var entry: modelData
                  readonly property int siblings: root.entriesIn(entry.section, root.activeScreen).length
                  readonly property int sectionAt: root.sections.indexOf(entry.section)

                  Text {
                    width: parent.width - controls.width - Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.displayName(entry.id)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Row {
                    id: controls
                    spacing: Style.space(2)

                    Button {
                      text: "←"
                      enabled: sectionAt > 0
                      opacity: enabled ? 1 : 0.3
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      tooltipText: "Move one section left"
                      onClicked: root.shiftSection(entry.id, entry.section, -1, root.activeScreen)
                    }
                    Button {
                      text: "→"
                      enabled: sectionAt < root.sections.length - 1
                      opacity: enabled ? 1 : 0.3
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      tooltipText: "Move one section right"
                      onClicked: root.shiftSection(entry.id, entry.section, 1, root.activeScreen)
                    }
                    Button {
                      text: "↑"
                      enabled: entry.index > 0
                      opacity: enabled ? 1 : 0.3
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      tooltipText: "Move up one slot"
                      onClicked: root.moveUp(entry.section, entry.index, root.activeScreen)
                    }
                    Button {
                      text: "↓"
                      enabled: entry.index < siblings - 1
                      opacity: enabled ? 1 : 0.3
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      tooltipText: "Move down one slot"
                      onClicked: root.moveDown(entry.section, entry.index, root.activeScreen)
                    }
                    Button {
                      text: "✕"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      tooltipText: root.activeScreen === ""
                        ? "Take off the default layout"
                        : "Take off this screen only"
                      onClicked: root.removeWidget(entry.id, entry.section, root.activeScreen)
                    }
                  }
                }
              }
            }
          }


          // ------------------------------------------------------------- add

          // Not a dropdown. The kit's popup opens downward with a fixed offset
          // and no flip, so at the bottom of a tall panel a long list lands off
          // the screen with nothing to scroll. An accordion that expands into
          // the panel's own Flickable has no such edge: it scrolls with
          // everything else, and it reads like the three lists above it.
          Column {
            width: parent.width
            spacing: Style.space(4)

            Button {
              width: parent.width
              leftAlign: true
              bordered: true
              text: (root.isOpen("add") ? "▾  " : "▸  ") + "ADD WIDGET · " + root.availableWidgets.length
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.toggleSection("add")
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.isOpen("add")

              ButtonGroup {
                width: parent.width
                options: [
                  { value: "left", label: "Left" },
                  { value: "center", label: "Center" },
                  { value: "right", label: "Right" }
                ]
                value: root.addSection
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onChanged: function(v) { root.addSection = v }
              }

              TextField {
                id: addSearch
                width: parent.width
                placeholderText: "Search widgets…"
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                onTextChanged: root.addQuery = text
              }

              Text {
                width: parent.width
                visible: root.matchingWidgets.length === 0
                text: root.availableWidgets.length === 0
                  ? "Everything installed is already on this profile"
                  : "No matches"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // A list of its own rather than more rows in the panel's column:
              // a long widget catalogue would otherwise push the three section
              // accordions off the top every time this opens. It scrolls, and
              // the panel behind it stops scrolling while the pointer is over
              // it, which is what makes a nested list usable at all.
              ListView {
                id: addList
                width: parent.width
                height: Math.min(root.matchingWidgets.length, root.addViewportRows) * root.addRowHeight
                visible: root.matchingWidgets.length > 0
                model: root.matchingWidgets
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Button {
                  required property var modelData
                  width: addList.width
                  height: root.addRowHeight
                  leftAlign: true
                  text: root.safeText(modelData.label, 48)
                  tooltipText: root.safeText(modelData.description, 90)
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: {
                    // Adding takes this widget out of availableWidgets, which
                    // destroys this very delegate in the middle of the handler;
                    // past that point the enclosing ids stop resolving and the
                    // rest of the handler dies with a ReferenceError. Read what
                    // is needed and clear the field while both still exist,
                    // then touch nothing but locals and root.
                    var chosen = modelData.value
                    addSearch.text = ""
                    root.addWidget(chosen, root.addSection, root.activeScreen)
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.matchingWidgets.length > root.addViewportRows
                text: root.matchingWidgets.length + " widgets — scroll, or type to narrow"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
