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

  property var data: ({ models: [], hardware: { groups: [] }, status: { state: "not-setup" } })
  property int cursor: 0
  property bool keyboardCursor: false

  readonly property string sourceDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cli: sourceDir + "/bin/omarchy-local-ai"
  readonly property var models: data.models || []
  readonly property var hardware: data.hardware && data.hardware.groups ? data.hardware.groups : []
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)
  readonly property color hover: Style.hoverFillFor(foreground, Color.accent)

  function refresh() { if (sourceDir !== "" && !snapshot.running) snapshot.running = true }
  function select(delta) {
    if (models.length === 0) return
    cursor = ((cursor + delta) % models.length + models.length) % models.length
  }
  function runModel(model) {
    if (!model || model.compatible !== true || !bar) return
    close()
    bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(cli + " run " + model.recipeId))
  }
  function lifecycle() {
    var state = data.status ? String(data.status.state || "") : ""
    control.command = [cli, state === "ready" || state === "loading" ? "stop" : "start"]
    control.running = true
  }

  onOpenedChanged: if (opened) { keyboardCursor = false; refresh() }

  Process {
    id: snapshot
    command: [root.cli, "snapshot"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.data = JSON.parse(text) }
        catch (e) { root.data = { models: [], hardware: { groups: [] }, status: { state: "error" } } }
      }
    }
  }

  Process { id: control; onExited: root.refresh() }
  Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
  Timer { interval: 3000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    opacity: data.status && data.status.ready ? 1 : 0.55
    tooltipText: data.status && data.status.ready ? "Local AI · " + data.status.model : "Local AI"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton && data.status && data.status.model) root.lifecycle()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(310))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.keyboardCursor = true; root.select(dy !== 0 ? dy : dx) }
      onActivateRequested: root.runModel(root.models[root.cursor])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        Row {
          width: parent.width
          spacing: Style.space(8)

          Column {
            width: parent.width - action.implicitWidth - parent.spacing
            spacing: Style.space(2)
            Text { text: "Local AI"; color: root.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
            Text {
              text: (root.data.status ? String(root.data.status.state || "registry") : "registry").toUpperCase()
              color: root.dim; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: 1
            }
          }

          Button {
            id: action
            text: root.data.status && (root.data.status.state === "ready" || root.data.status.state === "loading") ? "Stop" : "Start"
            foreground: root.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.lifecycle()
          }
        }

        Text {
          width: parent.width
          text: root.hardware.map(function(h) { return h.count + "× " + h.product.replace("NVIDIA GeForce ", "") }).join("  ·  ")
          color: root.dim; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight
        }

        PanelSeparator { foreground: root.foreground }

        Repeater {
          model: root.models
          Rectangle {
            required property var modelData
            required property int index
            width: content.width
            implicitHeight: row.implicitHeight + Style.space(10)
            radius: Style.cornerRadius
            color: root.keyboardCursor && root.cursor === index ? root.hover : "transparent"
            opacity: modelData.compatible ? 1 : 0.35

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: modelData.compatible ? Qt.PointingHandCursor : Qt.ArrowCursor
              onEntered: { root.cursor = index; root.keyboardCursor = true }
              onClicked: root.runModel(modelData)
            }

            Row {
              id: row
              anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6); anchors.rightMargin: Style.space(6); spacing: Style.space(8)
              Text { text: modelData.ready ? "●" : "○"; color: modelData.ready ? root.foreground : root.dim; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
              Column {
                width: parent.width - Style.space(22); spacing: Style.space(1)
                Text { width: parent.width; text: modelData.id; color: root.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true; elide: Text.ElideRight }
                Text { width: parent.width; text: modelData.compatible ? modelData.precision + " · " + modelData.engine : "other hardware"; color: root.dim; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
              }
            }
          }
        }

        Text {
          text: "Registry is truth · downloads stay local · endpoint stays on loopback"
          color: root.dim; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
