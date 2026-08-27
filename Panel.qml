import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "sero.local-ai"
  ipcTarget: "sero.local-ai"
  manageIpc: false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  property var data: ({ status: { state: "loading" }, models: [] })
  property string errorText: ""
  readonly property string sourceDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cli: sourceDir + "/bin/omarchy-local-ai"
  readonly property var status: data.status || {}
  readonly property var groups: data.hardware && data.hardware.groups ? data.hardware.groups : []
  readonly property int gpuCount: { var n = 0; for (var i = 0; i < groups.length; i++) n += Number(groups[i].count || 0); return n }
  readonly property int recipeCount: data.registry ? Number(data.registry.recipeCount || 0) : 0
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Util.alpha(foreground, 0.55)

  function refresh() { if (sourceDir !== "" && !snapshot.running) snapshot.running = true }
  function openDashboard() { close(); Quickshell.execDetached(["omarchy-shell", "shell", "summon", "sero.local-ai", "{}"]) }
  function openAgent() { close(); Quickshell.execDetached(["omarchy-agent", "--pick"]) }
  onOpenedChanged: if (opened) { errorText = ""; refresh() }

  Process {
    id: snapshot
    command: [root.cli, "snapshot"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.data = JSON.parse(text); root.errorText = "" } catch (e) { root.errorText = "Registry unavailable" } } }
  }
  Timer { interval: root.opened ? 5000 : 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item { Rectangle { anchors.centerIn: parent; width: Style.space(9); height: width; radius: width / 2; color: root.status.ready ? root.foreground : "transparent"; border.width: root.status.ready ? 0 : Math.max(1, Style.space(1)); border.color: root.foreground } }
    }
    tooltipText: root.status.ready ? "Local AI · " + root.status.model : "Local AI"
    onPressed: function(buttonCode) { if (buttonCode === Qt.RightButton && root.status.ready) root.openAgent(); else root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(260))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onActivateRequested: root.openDashboard()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(14)

        Column {
          width: parent.width; spacing: Style.space(3)
          Text { text: root.status.model || "Local AI"; color: root.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.heading; font.weight: Font.Medium }
          Meta { text: root.errorText || (root.status.ready ? "ready" : root.status.running ? "loading" : "nothing running") }
        }
        Column {
          width: parent.width; spacing: Style.space(3)
          Meta { text: root.gpuCount + " GPUs detected"; color: root.foreground }
          Repeater { model: root.groups; Meta { required property var modelData; width: content.width; text: modelData.count + " × " + (modelData.registryName || modelData.product); elide: Text.ElideRight } }
          Meta { text: root.recipeCount + " matching recipes" }
        }
        Column {
          width: parent.width; spacing: Style.space(11)
          Link { text: "Open Local AI panel"; onTriggered: root.openDashboard() }
          Rule {}
          Link { text: "Open agent"; visible: Boolean(root.status.ready); onTriggered: root.openAgent() }
        }
      }
    }
  }

  component Meta: Text { color: root.dim; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
  component Link: Text {
    signal triggered()
    color: root.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall
    MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.triggered() }
  }
  component Rule: Rectangle { width: parent ? parent.width : 0; height: Math.max(1, Style.spaceReal(1)); color: Util.alpha(root.foreground, 0.18) }
}
