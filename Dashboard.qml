import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root
  property var shell: null
  property var manifest: null
  property var data: ({ status: { state: "loading" }, models: [] })
  property int selectedIndex: 0
  property string busy: ""
  property string errorText: ""
  property bool closingFromHost: false
  readonly property string sourceDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cli: sourceDir + "/bin/omarchy-local-ai"
  readonly property var models: data.models || []
  readonly property var groups: data.hardware && data.hardware.groups ? data.hardware.groups : []
  readonly property var status: data.status || {}
  readonly property int gpuCount: { var n = 0; for (var i = 0; i < groups.length; i++) n += Number(groups[i].count || 0); return n }
  readonly property string gpuOptions: { var a = []; for (var i = 0; i < models.length; i++) if (a.indexOf(models[i].acceleratorCount) < 0) a.push(models[i].acceleratorCount); return a.join(" / ") }
  readonly property int downloadedCount: data.downloads ? data.downloads.filter(function(d) { return d.modelDownloaded && d.imageDownloaded }).length : 0
  readonly property var selectedDownload: { var a = data.downloads || [], id = selected() ? selected().recipeId : ""; for (var i = 0; i < a.length; i++) if (a[i].id === id) return a[i]; return null }
  readonly property real downloadProgress: selectedDownload && selectedDownload.expectedBytes > 0 ? Math.min(1, selectedDownload.localBytes / selectedDownload.expectedBytes) : 0
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color dim: Util.alpha(foreground, 0.55)
  readonly property string fontFamily: Style.font.family

  function open(payloadJson) { window.visible = true; refresh(); Qt.callLater(function() { keys.forceActiveFocus() }) }
  function close() { closingFromHost = true; window.visible = false; closingFromHost = false }
  function dismiss() { if (shell && typeof shell.hide === "function") shell.hide("sero.local-ai"); else window.visible = false }
  function refresh() { if (!snapshot.running) snapshot.running = true }
  function choose(index) { if (models.length) selectedIndex = Math.max(0, Math.min(models.length - 1, index)) }
  function selected() { return models.length ? models[selectedIndex] : null }
  function runAction(label, args) { if (busy || action.running) return; busy = label; errorText = ""; action.command = [cli].concat(args); action.running = true }
  function primary() { var m = selected(); if (!m) return; if (!m.downloaded) runAction("Downloading", ["download", m.recipeId]); else if (status.running) runAction("Switching", ["switch", m.recipeId]); else runAction("Loading", ["run", m.recipeId]) }
  function openAgent() { Quickshell.execDetached(["omarchy-agent", "--pick"]) }

  Process { id: snapshot; command: [root.cli, "snapshot"]; stdout: StdioCollector { waitForEnd: true; onStreamFinished: { try { root.data = JSON.parse(text); root.errorText = ""; root.choose(root.selectedIndex) } catch (e) { root.errorText = "Registry unavailable" } } } }
  Process {
    id: action
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim()) root.errorText = text.trim().replace(/^local-ai:\s*/, "") }
    onExited: function(exitCode) { if (exitCode !== 0 && !root.errorText) root.errorText = "Action failed"; root.busy = ""; root.refresh() }
  }
  Timer { interval: root.busy ? 2000 : 5000; running: window.visible; repeat: true; onTriggered: root.refresh() }

  FloatingWindow {
    id: window
    title: "Local AI"
    color: root.background
    implicitWidth: 960
    implicitHeight: 680
    minimumSize: Qt.size(760, 520)
    onVisibleChanged: if (!visible && !root.closingFromHost) root.dismiss()

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy) root.choose(root.selectedIndex + dy) }
      onActivateRequested: root.primary()
      onCloseRequested: root.dismiss()

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(24)
        spacing: Style.space(16)

        Row {
          width: parent.width
          Column {
            width: parent.width - headerActions.implicitWidth
            Text { text: "Local AI"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.iconLarge; font.weight: Font.Medium }
            Meta { text: root.errorText || root.busy || (root.status.ready ? root.status.model + " · ready" : root.status.running ? "Model loading" : "Nothing running") }
          }
          Row {
            id: headerActions; spacing: Style.space(16)
            Link { text: "Refresh"; onTriggered: root.refresh() }
            Link { text: "Open agent"; enabled: Boolean(root.status.ready); onTriggered: root.openAgent() }
            Link { text: "Unload"; enabled: Boolean(root.status.running); onTriggered: root.runAction("Unloading", ["unload"]) }
          }
        }
        Rule {}

        Row {
          width: parent.width; spacing: Style.space(36)
          Repeater {
            model: [{value:root.gpuCount,label:"GPUs detected"},{value:root.models.length,label:"recipes found"},{value:root.gpuOptions,label:"GPU options"},{value:root.downloadedCount,label:"downloaded"}]
            Column {
              required property var modelData; width: (parent.width - parent.spacing * 3) / 4; spacing: Style.space(2)
              Text { text: modelData.value; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading }
              Meta { text: modelData.label }
            }
          }
        }
        Rule {}

        Row {
          width: parent.width
          height: parent.height - y - selectedBar.height
          spacing: Style.space(18)
          Column {
            width: Style.space(210); spacing: Style.space(12)
            Label { text: "HARDWARE" }
            Repeater {
              model: root.groups
              Column {
                required property var modelData; width: parent.width; spacing: Style.space(2)
                Text { width: parent.width; text: modelData.count + " × " + (modelData.registryName || modelData.product); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
                Meta { text: Math.round(modelData.memoryBytesEach / 1073741824) + " GB each · " + modelData.backend }
              }
            }
            Label { text: "REGISTRY"; topPadding: Style.space(8) }
            Meta { width: parent.width; text: (root.data.registry ? root.data.registry.recipeCount : 0) + " matching of " + (root.data.registry ? root.data.registry.totalRecipeCount : 0); wrapMode: Text.WordWrap }
            Link { text: "Scan registry"; onTriggered: root.runAction("Scanning", ["scan"]) }
          }
          Rule { width: Math.max(1, Style.spaceReal(1)); height: parent.height }
          Column {
            width: parent.width - Style.space(230); height: parent.height; spacing: Style.space(8)
            Label { text: "RECIPES · SORTED BY GPU COUNT" }
            ListView {
              id: recipeList
              width: parent.width; height: parent.height - Style.space(28); clip: true; model: root.models; currentIndex: root.selectedIndex
              delegate: CursorSurface {
                required property var modelData; required property int index
                width: recipeList.width; height: Style.space(42); hasCursor: index === root.selectedIndex; current: Boolean(modelData.active)
                Row {
                  anchors.fill: parent; anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8); spacing: Style.space(8)
                  Cell { width: parent.width * 0.31; text: modelData.name; color: index === root.selectedIndex ? root.foreground : root.dim }
                  Cell { width: parent.width * 0.21; text: modelData.engine + " · " + modelData.precision }
                  Cell { width: parent.width * 0.20; text: modelData.hardware.indexOf("Intel") >= 0 ? "Arc Pro B70" : "RTX 3090" }
                  Cell { width: parent.width * 0.11; text: modelData.acceleratorCount + " GPU" + (modelData.acceleratorCount === 1 ? "" : "s") }
                  Cell { width: parent.width * 0.13; text: modelData.downloaded ? "downloaded" : modelData.ready ? "available" : "busy" }
                }
                MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onEntered: root.choose(index); onClicked: root.choose(index); onDoubleClicked: root.primary() }
              }
              ScrollBar.vertical: ScrollBar {}
            }
          }
        }

        Item {
          id: selectedBar
          width: parent.width; height: Style.space(44)
          Rule { width: parent.width; anchors.top: parent.top }
          Meta { anchors.left: parent.left; anchors.right: primaryAction.left; anchors.rightMargin: Style.space(18); anchors.verticalCenter: parent.verticalCenter; text: root.selected() ? root.selected().name + " · " + root.selected().acceleratorCount + " GPU" + (root.selected().acceleratorCount === 1 ? "" : "s") + " · " + root.selected().hardware : "No matching recipe"; elide: Text.ElideRight }
          Link { id: primaryAction; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; enabled: Boolean(root.selected()) && !root.busy; text: root.busy === "Downloading" ? Math.round(root.downloadProgress * 100) + "%" : !root.selected() ? "" : !root.selected().downloaded ? "Download" : root.status.running ? "Switch" : "Run"; onTriggered: root.primary() }
        }
      }
    }
  }

  component Meta: Text { color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall }
  component Label: Text { color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.letterSpacing: Style.spaceReal(0.4) }
  component Cell: Text { anchors.verticalCenter: parent.verticalCenter; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight }
  component Link: Text {
    signal triggered()
    color: root.foreground; opacity: enabled ? 1 : 0.32; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
    MouseArea { anchors.fill: parent; enabled: parent.enabled; hoverEnabled: true; cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: parent.triggered() }
  }
  component Rule: Rectangle { width: parent ? parent.width : 0; height: Math.max(1, Style.spaceReal(1)); color: Util.alpha(root.foreground, 0.18) }
}
