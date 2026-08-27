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
  property var data: ({ models: [], status: { state: "loading" } })
  property string page: "home"; property string selectedId: ""
  property int cursor: 0; property string busy: ""; property string afterAction: ""
  property string errorText: ""; property string lastFailure: ""
  readonly property string sourceDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cli: sourceDir + "/bin/omarchy-local-ai"
  readonly property var models: data.models || []; readonly property var status: data.status || {}; readonly property var hardwareGroups: data.hardware && data.hardware.groups ? data.hardware.groups : []
  readonly property int gpuCount: { var total = 0; for (var i = 0; i < hardwareGroups.length; i++) total += Number(hardwareGroups[i].count || 0); return total }
  readonly property string gpuOptions: { var values = []; for (var i = 0; i < models.length; i++) if (values.indexOf(models[i].acceleratorCount) < 0) values.push(models[i].acceleratorCount); return values.join(" / ") }
  readonly property int recipeCount: data.registry ? Number(data.registry.recipeCount || 0) : 0; readonly property color foreground: bar ? bar.foreground : Color.foreground; readonly property color dim: Util.alpha(foreground, 0.55)
  readonly property var download: {
    var rows = data.downloads || []
    for (var i = 0; i < rows.length; i++) if (rows[i].id === selectedId) return rows[i]; return null
  }
  readonly property real downloadProgress: download && download.expectedBytes > 0
    ? Math.min(1, download.localBytes / download.expectedBytes) : 0

  function selectedModel() {
    for (var i = 0; i < models.length; i++) if (models[i].recipeId === selectedId) return models[i]
    return models.length > 0 ? models[Math.min(cursor, models.length - 1)] : null
  }
  function refresh() { if (sourceDir !== "" && !snapshot.running) snapshot.running = true }
  function choose(index) {
    if (models.length === 0) return
    cursor = ((index % models.length) + models.length) % models.length
    selectedId = models[cursor].recipeId
  }
  function showModels() { page = "models"; choose(cursor) }
  function showModel(model) { if (model) { selectedId = model.recipeId; page = "model" } }
  function runAction(label, args, nextPage) {
    if (busy !== "" || action.running) return
    busy = label
    afterAction = nextPage
    errorText = ""
    lastFailure = ""
    action.command = [cli].concat(args)
    action.running = true
  }
  function primary() {
    var model = selectedModel()
    if (!model || (model.active && status.running)) return
    if (!model.downloaded) runAction("Downloading", ["download", model.recipeId], "model")
    else if (status.running) runAction("Switching", ["switch", model.recipeId], "home")
    else runAction("Loading", ["run", model.recipeId], "home")
  }
  function openAgent() {
    close()
    if (bar) bar.run("omarchy-agent --pick")
  }
  function activate() {
    if (busy !== "") return
    if (page === "models") showModel(selectedModel())
    else if (page === "model") primary()
    else if (status.ready) openAgent()
    else showModels()
  }

  onOpenedChanged: if (opened) { page = "home"; errorText = ""; refresh() }

  Process {
    id: snapshot
    command: [root.cli, "snapshot"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.data = JSON.parse(text)
          if (root.errorText === "Registry unavailable") root.errorText = ""
          if (root.cursor >= root.models.length) root.cursor = Math.max(0, root.models.length - 1)
        } catch (e) {
          root.errorText = "Registry unavailable"
        }
      }
    }
  }

  Process {
    id: action
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastFailure = text.trim().replace(/^local-ai:\s*/, "")
    }
    onExited: function(exitCode) {
      var next = root.afterAction
      root.busy = ""
      if (exitCode === 0) root.page = next
      else root.errorText = root.lastFailure || "That action did not finish"
      root.refresh()
    }
  }

  Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }
  Timer { interval: root.busy === "Downloading" ? 2000 : 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Rectangle {
          anchors.centerIn: parent
          width: Style.space(9); height: width; radius: width / 2
          color: root.status.ready ? root.foreground : "transparent"
          border.width: root.status.ready ? 0 : Math.max(1, Style.space(1)); border.color: root.foreground
        }
      }
    }
    tooltipText: root.status.ready ? "Local AI · " + root.status.model : "Local AI"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton && root.status.ready) root.openAgent()
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
    contentWidth: panel.fittedContentWidth(Style.space(260))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (root.page === "models") root.choose(root.cursor + (dy !== 0 ? dy : dx)) }
      onActivateRequested: root.activate()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(17)

        Column {
          width: parent.width
          spacing: Style.space(6)

          Text {
            width: parent.width
            text: root.busy !== "" && root.selectedModel() ? root.selectedModel().name
              : root.page === "models" ? "Choose a recipe"
              : root.page === "model" && root.selectedModel() ? root.selectedModel().name
              : root.status.model || "Local AI"
            color: root.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.heading
            font.weight: Font.Medium
            font.letterSpacing: Style.spaceReal(0.25)
            elide: Text.ElideRight
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            MetaText {
              width: parent.width
              text: root.errorText !== "" ? root.errorText
                : root.busy !== "" ? root.busy
                : root.page === "models" ? (root.models.length > 0 ? "GPU options · " + root.gpuOptions : "No recipes match this machine")
                : root.page === "model" && root.selectedModel()
                  ? (root.selectedModel().active ? String(root.status.state || "stopped")
                    : root.selectedModel().precision + " · " + root.selectedModel().engine + " · " + root.selectedModel().acceleratorCount + " GPU" + (root.selectedModel().acceleratorCount === 1 ? "" : "s"))
                : root.status.ready ? "ready" : root.status.running ? "loading" : "nothing running"
              color: root.errorText !== "" ? root.foreground : root.dim
              wrapMode: Text.WordWrap
            }

            MetaText { visible: root.busy === "" && root.page === "home" && Boolean(root.status.ready); text: "Running locally" }

            MetaText {
              visible: root.busy === "" && root.page === "home" && Boolean(root.status.ready) && Boolean(root.data.benchmark)
              text: Number(root.data.benchmark ? root.data.benchmark.medianTokensPerSecond : 0).toFixed(1) + " tok/s"
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(3)
          visible: root.busy === "" && root.page === "home"

          MetaText {
            text: root.gpuCount > 0 ? root.gpuCount + " GPUs detected" : snapshot.running ? "Detecting hardware" : "No GPUs detected"
            color: root.foreground
          }
          Repeater {
            model: root.hardwareGroups
            MetaText {
              required property var modelData
              width: content.width; text: modelData.count + " × " + (modelData.registryName || modelData.product); elide: Text.ElideRight
            }
          }
          MetaText { text: root.recipeCount + " recipes · " + root.gpuOptions + " GPUs" }
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.busy !== ""

          Row {
            width: parent.width
            visible: root.busy === "Downloading"
            Text { text: "Download"; color: root.dim; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
            Item { width: parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth; height: 1 }
            Text { text: Math.round(root.downloadProgress * 100) + "%"; color: root.dim; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
          }

          Rectangle {
            width: parent.width
            height: Math.max(2, Style.spaceReal(2))
            visible: root.busy === "Downloading"
            color: Util.alpha(root.foreground, 0.18)
            Rectangle { width: parent.width * root.downloadProgress; height: parent.height; color: root.foreground }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: root.busy === "" && root.page === "home"

          ActionLink { text: root.status.running ? "Change recipe" : "Choose recipe"; onTriggered: root.showModels() }
          Hairline {}
          ActionLink { text: "Scan again"; onTriggered: root.runAction("Scanning", ["scan"], "models") }
        }

        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: root.busy === "" && root.page === "models"

          Repeater {
            model: root.models
            Item {
              required property var modelData
              required property int index
              width: content.width
              height: modelName.implicitHeight

              Row {
                width: parent.width
                spacing: Style.space(10)
                Text {
                  id: modelName
                  width: parent.width - modelState.implicitWidth - parent.spacing
                  text: modelData.name
                  color: root.cursor === index ? root.foreground : root.dim
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                Text {
                  id: modelState
                  text: modelData.acceleratorCount + " GPU" + (modelData.acceleratorCount === 1 ? "" : "s") + " · " + (modelData.hardware.indexOf("Intel") >= 0 ? "Arc" : "RTX")
                  color: root.dim
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.choose(index)
                onClicked: root.showModel(modelData)
              }
            }
          }

          Hairline {}
          ActionLink { text: "Scan again"; onTriggered: root.runAction("Scanning", ["scan"], "models") }
          ActionLink { text: "Back"; onTriggered: root.page = "home" }
        }

        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: root.busy === "" && root.page === "model"

          ActionLink {
            visible: Boolean(root.selectedModel()) && (!root.selectedModel().active || !root.status.running)
            enabled: Boolean(root.selectedModel()) && (!root.selectedModel().downloaded || root.selectedModel().ready || root.status.running)
            text: root.selectedModel() && !root.selectedModel().downloaded ? "Download"
              : root.status.running ? "Switch running model" : "Run"
            onTriggered: root.primary()
          }
          ActionLink { text: "Open agent"; visible: Boolean(root.selectedModel()) && root.selectedModel().active && root.status.ready === true; onTriggered: root.openAgent() }
          ActionLink { text: "Unload"; visible: Boolean(root.selectedModel()) && root.selectedModel().active; onTriggered: root.runAction("Unloading", ["unload"], "home") }
          ActionLink { text: "Back"; onTriggered: root.page = "models" }
        }
      }
    }
  }

  component ActionLink: Text {
    signal triggered()
    property bool dimmed: false
    color: enabled ? root.foreground : root.dim
    opacity: enabled ? (dimmed ? 0.72 : 1) : 0.35
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    MouseArea {
      anchors.fill: parent
      enabled: parent.enabled
      hoverEnabled: true
      cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: parent.triggered()
    }
  }

  component MetaText: Text {
    color: root.dim
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component Hairline: Rectangle {
    width: parent ? parent.width : 0
    height: Math.max(1, Style.spaceReal(1))
    color: Util.alpha(root.foreground, 0.18)
  }
}
