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

  property var data: ({ models: [], hardware: { groups: [] }, registry: {}, status: { state: "loading" } })
  property int cursor: 0
  property bool keyboardCursor: false
  property bool loading: false
  property string errorText: ""

  readonly property string sourceDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cli: sourceDir + "/bin/omarchy-local-ai"
  readonly property var models: data.models || []
  readonly property var hardware: data.hardware && data.hardware.groups ? data.hardware.groups : []
  readonly property var status: data.status || {}
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Util.alpha(foreground, 0.56)
  readonly property color faint: Util.alpha(foreground, 0.13)
  readonly property color hover: bar ? Style.hoverFillFor(foreground, Color.accent) : "transparent"

  function shortHardware(name) {
    return String(name || "GPU").replace("NVIDIA GeForce ", "").replace("Intel ", "")
  }
  function hardwareLine() {
    return hardware.map(function(h) { return h.count + "× " + shortHardware(h.product) }).join("   ·   ")
  }
  function stateLabel(model) {
    if (model.active && status.ready) return "RUNNING"
    if (model.active && status.running) return "LOADING"
    if (model.downloaded) return "LOCAL"
    return model.ready ? "READY" : "BUSY"
  }
  function refresh() {
    if (sourceDir === "" || snapshot.running) return
    loading = true
    snapshot.running = true
  }
  function select(delta) {
    if (models.length === 0) return
    cursor = ((cursor + delta) % models.length + models.length) % models.length
  }
  function runModel(model) {
    if (!model || model.ready !== true || model.active || !bar) return
    close()
    bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(cli + " run " + model.recipeId))
  }
  function lifecycle() {
    var action = status.running ? "stop" : "start"
    if (!status.recipeId) return
    control.command = [cli, action]
    control.running = true
  }
  function syncRegistry() {
    close()
    if (bar) bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(cli + " sync"))
  }

  onOpenedChanged: if (opened) { keyboardCursor = false; refresh() }

  Process {
    id: snapshot
    command: [root.cli, "snapshot"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        try {
          root.data = JSON.parse(text)
          root.errorText = ""
          if (root.cursor >= root.models.length) root.cursor = Math.max(0, root.models.length - 1)
        } catch (e) {
          root.errorText = "Registry unavailable"
        }
      }
    }
  }

  Process { id: control; onExited: root.refresh() }
  Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
  Timer { interval: 4000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    opacity: root.status.ready ? 1 : 0.58
    tooltipText: root.status.ready ? "Local AI · " + root.status.model : "Local AI · registry"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton && root.status.recipeId) root.lifecycle()
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
    contentWidth: panel.fittedContentWidth(Style.space(360))
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
          spacing: Style.space(10)

          Column {
            width: parent.width - headerAction.implicitWidth - parent.spacing
            spacing: Style.space(2)
            Text {
              text: "Local AI"
              color: root.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              width: parent.width
              text: root.hardwareLine()
              color: root.dim
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Button {
            id: headerAction
            text: root.status.running ? "Stop" : "Start"
            foreground: root.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            enabled: Boolean(root.status.recipeId)
            opacity: enabled ? 1 : 0.4
            onClicked: root.lifecycle()
          }
        }

        Rectangle {
          width: parent.width
          implicitHeight: activeContent.implicitHeight + Style.space(20)
          radius: Style.cornerRadius
          color: root.faint
          visible: Boolean(root.status.recipeId)

          Column {
            id: activeContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(10)
            spacing: Style.space(4)

            Row {
              width: parent.width
              Text {
                width: parent.width - activeState.implicitWidth
                text: root.status.model || "Local model"
                color: root.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                id: activeState
                text: String(root.status.state || "stopped").toUpperCase()
                color: root.status.ready ? root.foreground : root.dim
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }

            Text {
              width: parent.width
              text: (root.status.engine || "engine") + "  ·  127.0.0.1:" + (root.status.port || "—") + (root.data.benchmark ? "  ·  " + Number(root.data.benchmark.medianTokensPerSecond).toFixed(1) + " tok/s live" : "")
              color: root.dim
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Row {
          width: parent.width
          Text {
            width: parent.width - modelCount.implicitWidth
            text: "MODELS"
            color: root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }
          Text {
            id: modelCount
            text: root.models.length
            color: root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { foreground: root.foreground; strength: 0.2 }

        Text {
          width: parent.width
          visible: root.errorText !== "" || (!root.loading && root.models.length === 0)
          text: root.errorText !== "" ? root.errorText : "No validated recipes match this hardware."
          color: root.dim
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.models
          Rectangle {
            required property var modelData
            required property int index
            width: content.width
            implicitHeight: modelRow.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: root.keyboardCursor && root.cursor === index ? root.hover : "transparent"
            opacity: modelData.ready || modelData.active ? 1 : 0.42

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: modelData.ready && !modelData.active ? Qt.PointingHandCursor : Qt.ArrowCursor
              onEntered: { root.cursor = index; root.keyboardCursor = true }
              onClicked: root.runModel(modelData)
            }

            Row {
              id: modelRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(10)

              Column {
                width: parent.width - rowState.implicitWidth - parent.spacing
                spacing: Style.space(2)
                Text {
                  width: parent.width
                  text: modelData.name
                  color: root.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: modelData.active
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: modelData.precision + "  ·  " + modelData.engine + "  ·  " + modelData.acceleratorCount + "× " + root.shortHardware(modelData.hardware)
                  color: root.dim
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Text {
                id: rowState
                anchors.verticalCenter: parent.verticalCenter
                text: root.stateLabel(modelData)
                color: modelData.active ? root.foreground : root.dim
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 0.7
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground; strength: 0.2 }

        Row {
          width: parent.width
          spacing: Style.space(8)
          Text {
            width: parent.width - syncLink.implicitWidth - parent.spacing
            text: "0xSero/local-ai-registry  ·  " + (root.data.registry.totalRecipeCount || 0) + " recipes"
            color: root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Text {
            id: syncLink
            text: "SYNC"
            color: syncArea.containsMouse ? root.foreground : root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.8
            MouseArea {
              id: syncArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.syncRegistry()
            }
          }
        }
      }
    }
  }
}
