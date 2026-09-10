import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point: a Laravel glyph that opens the Laravel Cloud panel.
// Mirrors the first-party weather widget's split between a thin bar button
// and a Panel.qml that owns state, processes and the popup.
//
//   left   = toggle panel
//   right  = open the Laravel Cloud dashboard in the browser
//   middle = refresh status now
BarWidget {
  id: root
  moduleName: "christophrumpel.laravel-cloud"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  readonly property var panel: panelLoader.item
  readonly property bool deploying: panel ? panel.anyDeploying === true : false
  readonly property bool failed: panel ? panel.anyFailed === true : false

  property real spinAngle: 0
  NumberAnimation on spinAngle {
    running: root.deploying
    from: 0; to: 360
    duration: 1000
    loops: Animation.Infinite
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.deploying ? "󰦖" : ""  // nf-md-loading while deploying, nf-dev-laravel otherwise
    slotSize: Style.bar.iconSlot
    active: root.failed && !root.deploying
    tooltipText: root.panel ? root.panel.tooltipText : "Laravel Cloud"

    textRotation: root.deploying ? root.spinAngle : 0

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) {
        if (root.panel) root.panel.openDashboard()
      } else if (b === Qt.MiddleButton) {
        root.refresh()
      } else {
        root.togglePanel()
      }
    }
  }
}
