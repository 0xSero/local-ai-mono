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
  property string page: "home"
  property string selectedId: ""
  property int cursor: 0
  property string busy: ""
  property string afterAction: ""
  property string errorText: ""
  property string lastFailure: ""

  readonly property string sourceDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cli: sourceDir + "/bin/omarchy-local-ai"
  readonly property var models: data.models || []
  readonly property var status: data.status || {}
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Util.alpha(foreground, 0.55)

  function selectedModel() {
    for (var i = 0; i < models.length; i++) if (models[i].recipeId === selectedId) return models[i]
    return models.length > 0 ? models[Math.min(cursor, models.length - 1)] : null
  }
  function refresh() {
    if (sourceDir !== "" && !snapshot.running) snapshot.running = true
  }
  function choose(index) {
    if (models.length === 0) return
    cursor = ((index % models.length) + models.length) % models.length
    selectedId = models[cursor].recipeId
  }
  function showModels() {
    page = "models"
    choose(cursor)
  }
  function showModel(model) {
    if (!model) return
    selectedId = model.recipeId
    page = "model"
  }
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
  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "AI"
    fontSize: Style.font.caption
    dimmed: root.status.ready !== true
    tooltipText: root.status.ready ? "Local AI · " + root.status.model : "Local AI"
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(292))
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
        spacing: Style.space(14)

        Column {
          width: parent.width
          spacing: Style.space(3)

          Text {
            width: parent.width
            text: root.busy !== "" ? root.busy
              : root.page === "models" ? "Choose a model"
              : root.page === "model" && root.selectedModel() ? root.selectedModel().name
              : root.status.model || "Local AI"
            color: root.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: root.busy !== "" ? "This can keep working with the panel closed"
              : root.errorText !== "" ? root.errorText
              : root.page === "models" ? (root.models.length > 0 ? "From ~/omarchy/local-ai" : "No models match this machine")
              : root.page === "model" && root.selectedModel()
                ? (root.selectedModel().active ? "Running"
                  : root.selectedModel().downloaded ? "Downloaded · " + root.selectedModel().precision
                  : root.selectedModel().precision + " · ready to download")
              : root.status.ready
                ? "Ready" + (root.data.benchmark ? " · " + Number(root.data.benchmark.medianTokensPerSecond).toFixed(1) + " tok/s" : "")
              : root.status.running ? "Loading" : "Nothing running"
            color: root.errorText !== "" ? root.foreground : root.dim
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(11)
          visible: root.busy === "" && root.page === "home"

          ActionLink { text: "Open agent"; enabled: root.status.ready === true; onTriggered: root.openAgent() }
          ActionLink { text: "Change model"; onTriggered: root.showModels() }
          ActionLink { text: "Unload"; visible: Boolean(root.status.recipeId); onTriggered: root.runAction("Unloading", ["unload"], "home") }
          ActionLink { text: "Scan"; onTriggered: root.runAction("Scanning", ["scan"], "models") }
        }

        Column {
          width: parent.width
          spacing: Style.space(11)
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
                  text: modelData.active ? String(root.status.state || "stopped") : modelData.downloaded ? "downloaded" : "download"
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

          ActionLink { text: "Scan again"; onTriggered: root.runAction("Scanning", ["scan"], "models") }
          ActionLink { text: "Back"; onTriggered: root.page = "home" }
        }

        Column {
          width: parent.width
          spacing: Style.space(11)
          visible: root.busy === "" && root.page === "model"

          ActionLink {
            visible: Boolean(root.selectedModel()) && (!root.selectedModel().active || !root.status.running)
            enabled: Boolean(root.selectedModel()) && (!root.selectedModel().downloaded || root.selectedModel().ready || root.status.running)
            text: root.selectedModel() && !root.selectedModel().downloaded ? "Download"
              : root.status.running ? "Switch running model" : "Run"
            onTriggered: root.primary()
          }
          ActionLink { text: "Open agent"; visible: Boolean(root.selectedModel()) && root.selectedModel().active && root.status.ready === true; onTriggered: root.openAgent() }
          ActionLink { text: "Back"; onTriggered: root.page = "models" }
        }
      }
    }
  }

  component ActionLink: Text {
    signal triggered()
    color: enabled ? root.foreground : root.dim
    opacity: enabled ? 1 : 0.35
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
}
