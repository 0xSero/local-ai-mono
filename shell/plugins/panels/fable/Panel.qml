import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Fable: quick answers from the local model, straight from the bar. A thin
// chat popup over the Local AI endpoint — the heavy lifting (serving, model
// choice, lifecycle) belongs to the omarchy.local-ai panel; Fable only asks.
Panel {
  id: root
  moduleName: "omarchy.fable"
  ipcTarget: "omarchy.fable"
  manageIpc: false

  property var info: ({})
  property var transcript: []
  property bool asking: false
  property string error: ""

  readonly property bool installed: !!info.state && info.state !== "not-setup"
  readonly property bool serving: info.state === "running"
  readonly property string model: String(info.model || "")
  readonly property string endpoint: "http://127.0.0.1:" + String(info.port || "") + "/v1/chat/completions"
  readonly property color dim: bar ? Qt.darker(bar.foreground, 1.55) : Color.foreground
  readonly property string prompt: "You are Fable, a quick assistant living in the Omarchy top bar. Answer plainly and briefly; this is a small popup, not a document."

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function ask() {
    var text = input.text.trim()
    if (text === "" || asking || !serving) return
    input.text = ""
    error = ""
    transcript = transcript.concat([{ role: "user", content: text }])
    asking = true
    askProc.command = ["curl", "--fail", "--silent", "--max-time", "300", endpoint,
      "--header", "Content-Type: application/json",
      "--data", JSON.stringify({
        model: model,
        messages: [{ role: "system", content: prompt }].concat(transcript.slice(-20))
      })]
    askProc.running = true
  }

  function answered(text) {
    if (!asking) return
    try {
      var reply = String(JSON.parse(text).choices[0].message.content).trim()
      transcript = transcript.concat([{ role: "assistant", content: reply }])
    } catch (e) {
      error = "The model did not answer — check: omarchy ai status"
    }
    asking = false
  }

  function loadModel() {
    if (!startProc.running) startProc.running = true
  }

  visible: installed
  implicitWidth: installed ? button.implicitWidth : 0
  implicitHeight: installed ? button.implicitHeight : 0

  onOpenedChanged: {
    if (opened) {
      refresh()
      error = ""
    }
  }

  IpcHandler {
    target: "omarchy.fable"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  Process {
    id: listProc
    command: ["omarchy-ai-list", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.info = JSON.parse(text) } catch (e) { root.info = {} }
      }
    }
  }

  Process {
    id: askProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.answered(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.asking) {
        root.asking = false
        root.error = "The model is not answering — is it loaded?"
      }
    }
  }

  Process {
    id: startProc
    command: ["omarchy-ai-start"]
    onExited: root.refresh()
  }

  Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰙴"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    opacity: root.serving ? 1 : 0.5
    tooltipText: root.serving ? "Fable — ask the local model" : "Fable — the local model is unloaded"
    onPressed: function(b) {
      if (b === Qt.RightButton) { if (root.bar) root.bar.run("omarchy-agent") }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: input
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      // ---------- Hero ----------
      Column {
        width: parent.width
        spacing: Style.space(2)

        Text {
          text: "Fable"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          text: (root.asking ? "THINKING…"
               : root.serving ? "ASKING " + root.model
               : "MODEL UNLOADED").toUpperCase()
          color: root.serving || root.asking ? root.bar.foreground : root.dim
          opacity: root.serving || root.asking ? 0.75 : 1
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
          elide: Text.ElideRight
          width: parent.width
        }
      }

      // ---------- Transcript ----------
      Flickable {
        id: log
        visible: root.transcript.length > 0
        width: parent.width
        height: Math.min(logColumn.implicitHeight, Style.space(240))
        contentWidth: width
        contentHeight: logColumn.implicitHeight
        clip: true
        onContentHeightChanged: contentY = Math.max(0, contentHeight - height)

        Column {
          id: logColumn
          width: log.width
          spacing: Style.space(8)

          Repeater {
            model: root.transcript

            Text {
              required property var modelData

              width: logColumn.width
              text: modelData.content
              color: modelData.role === "user" ? root.dim : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }
        }
      }

      Text {
        visible: root.error !== ""
        width: parent.width
        text: root.error
        color: root.bar ? root.bar.urgent : Color.urgent
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      // ---------- Ask ----------
      TextField {
        id: input
        width: parent.width
        foreground: root.bar.foreground
        placeholderText: root.serving ? "Ask anything — Enter to send" : "Load the model to ask"
        enabled: root.serving && !root.asking
        onAccepted: root.ask()
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          }
        }
      }

      Button {
        visible: !root.serving
        width: parent.width
        text: "Load the model"
        fontSize: Style.font.bodySmall
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        horizontalPadding: Style.spacing.controlPaddingX
        verticalPadding: Style.spacing.controlPaddingY
        bordered: true
        onClicked: root.loadModel()
      }
    }
  }
}
