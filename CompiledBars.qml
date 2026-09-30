pragma Singleton

import QtQuick

// Compiled patched bars, kept for the life of the shell.
//
// Bar.qml compiles its patched text with Qt.createQmlObject(), and the engine
// never frees what that compiles: each call retains ~0.4 MB, destroy() and
// gc() or not. The wrapper is torn down and built again on every plugin
// reload, bar switch or truncated shell.json, so compiling per wrapper leaks
// per rebuild. Compiling once per distinct text does not.
//
// The cache has to live here, not in the wrapper. A component keeps the
// context of the code that called createQmlObject(), whatever parent the
// holder is given, and the wrapper's context dies with the wrapper: a
// component compiled there and reused after it is gone refuses with "Cannot
// create a component in an invalid context". A singleton's context lasts as
// long as the engine does.
//
// The bars built from these components must not live in this context, only
// the components: Bar.qml builds each one through a Loader it owns, so the
// bar's bindings die with the wrapper that built it. See the Loader there.
//
// One entry per distinct text, so it only grows when Omarchy or edits.json
// changes within a session. Old entries are not dropped: the bar built from
// one may still be alive, and destroying its component's holder would pull
// the context out from under it.
//
// This object is created once per engine and outlives plugin reloads: an
// update that changes this file keeps running the old one until the shell
// restarts. Treat component(text, url) as frozen. A change in what it does
// ships under a new type name in qmldir, so the new Bar.qml never talks to an
// old instance that means something else.
QtObject {
  id: cache

  property var entries: ({})

  // Returns the Component for `text`, compiled against `url`, or throws what
  // compiling it threw. Failures are cached too: the same broken text fails the
  // same way, and compiling it again would leak the same way.
  function component(text, url) {
    var key = Qt.md5(url + "\n" + text)
    var entry = entries[key]
    if (!entry) {
      try {
        entry = { holder: Qt.createQmlObject(text, cache, url) }
      } catch (e) {
        entry = { error: e }
      }
      entries[key] = entry
    }
    if (entry.error) throw entry.error
    return entry.holder.bar
  }
}
