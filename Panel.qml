import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Animated semantic search over the EmbeddingGemma 2 index.
// Summoned with a payload of {"query":"..."}; runs search.py, then plays
// the results in with staggered entrance, growing score bars, and a
// pulsing "thinking" state while the embedding model works.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string homeDir: Quickshell.env("HOME") || ""
  // The bundled search tool, resolved relative to this QML file.
  readonly property string searchScript: String(Qt.resolvedUrl("tools/search.py")).replace(/^file:\/\//, "")
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string defaultIndexDir: Quickshell.env("GEMMA_SEARCH_INDEX") || (homeDir + "/embedding-space")
  // May be overridden per summon via the payload's "index" field.
  property string indexDir: defaultIndexDir
  readonly property string launcher: "omarchy-launch-editor"
  readonly property int resultCount: 12
  readonly property int minThinkingTime: 550   // ms, so the sweep is visible

  // ---- lifecycle -----------------------------------------------------------

  property bool opened: false
  property bool cardVisible: false

  function open(payloadJson) {
    var incoming = ({})
    try { incoming = JSON.parse(payloadJson || "{}") } catch (e) { incoming = ({}) }
    if (!incoming.query) return

    closeTimer.stop()   // cancel a teardown from a previous close
    root.query = String(incoming.query)
    root.indexDir = incoming.index ? String(incoming.index) : root.defaultIndexDir
    root.results = []
    root.selectedIndex = -1
    root.errorText = ""
    root.searching = true
    root.queryStartedAt = Date.now()
    root.pendingResults = null
    root.opened = true
    Qt.callLater(function() {
      root.cardVisible = true
      keyCatcher.forceActiveFocus()
    })
    searchTimer.restart()   // (re)start the search process on the next tick
  }

  function close() {
    root.cardVisible = false
    closeTimer.restart()
  }

  function finishClose() {
    if (root.cardVisible) return   // a fresh open() superseded this close
    root.opened = false
    root.searching = false
    if (searchProcess.running) searchProcess.running = false
    root.results = []
    root.query = ""
  }

  // ---- state ---------------------------------------------------------------

  property string query: ""
  property bool searching: false
  property string errorText: ""
  property var results: []
  property int selectedIndex: -1
  property double queryStartedAt: 0
  property var pendingResults: null

  function revealResults(parsed) {
    root.results = parsed
    root.searching = false
    root.selectedIndex = parsed.length > 0 ? 0 : -1
  }

  function move(delta) {
    if (root.results.length === 0) return
    var n = root.results.length
    root.selectedIndex = (root.selectedIndex + delta % n + n) % n
    ensureVisible()
  }

  function activate(i) {
    var idx = (i === undefined) ? root.selectedIndex : i
    if (idx < 0 || idx >= root.results.length) return
    var hit = root.results[idx]
    var isMedia = hit.kind === "image" || hit.kind === "video"
    openProcess.command = isMedia ? ["xdg-open", hit.path] : [root.launcher, hit.path]
    openProcess.running = true
    root.close()
  }

  function ensureVisible() {
    if (root.selectedIndex < 0) return
    var rowTop = root.selectedIndex * (rowHeight + rowSpacing)
    var rowBottom = rowTop + rowHeight
    if (rowTop < listFlick.contentY)
      listFlick.contentY = Math.max(0, rowTop - rowSpacing)
    else if (rowBottom > listFlick.contentY + listFlick.height)
      listFlick.contentY = rowBottom - listFlick.height + rowSpacing
  }

  readonly property int rowHeight: Style.space(68)
  readonly property int rowSpacing: Style.space(4)

  // ---- theme ---------------------------------------------------------------

  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  readonly property color accent: Commons.Color.accent
  readonly property color muted: Util.alpha(foreground, 0.55)
  readonly property color faint: Util.alpha(foreground, 0.35)
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int cardWidth: Math.min(Style.space(780), panel.width - Style.space(48))

  // Font Awesome-style glyphs as escapes, so the source survives patching.
  function iconFor(path, kind) {
    if (kind === "video") return "\uf03d"
    if (kind === "image") return "\uf03e"
    var dot = path.lastIndexOf(".")
    var ext = dot >= 0 ? path.slice(dot + 1).toLowerCase() : ""
    if (["md", "markdown", "txt", "rst", "org"].indexOf(ext) !== -1) return "\uf15c"
    if (["sh", "bash", "zsh", "fish", "ps1", "bat", "conf", "service", "log"].indexOf(ext) !== -1) return "\uf120"
    if (["py", "js", "ts", "tsx", "jsx", "mjs", "cjs", "c", "h", "cpp", "hpp", "rs", "go", "java", "rb", "lua", "php", "swift", "kt", "sql", "html", "htm", "css", "scss", "xml", "nix", "jl", "hs", "vim", "el", "clj", "scala", "dart"].indexOf(ext) !== -1) return "\uf121"
    if (["json", "yaml", "yml", "toml", "ini", "cfg", "env", "tex", "bib"].indexOf(ext) !== -1) return "\uf013"
    if (["csv", "tsv"].indexOf(ext) !== -1) return "\uf0ce"
    return "\uf15b"
  }

  function baseName(path) {
    var i = path.lastIndexOf("/")
    return i >= 0 ? path.slice(i + 1) : path
  }

  function dirName(path) {
    var i = path.lastIndexOf("/")
    return i > 0 ? path.slice(0, i) : path
  }

  // ---- processes -----------------------------------------------------------

  Process {
    id: searchProcess
    command: ["python3", root.searchScript, root.query, "--index", root.indexDir,
              "-k", String(root.resultCount), "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: searchProcess.collected = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: searchProcess.stderrText = text
    }
    property string collected: ""
    property string stderrText: ""
    onExited: function(exitCode) {
      if (!root.opened) return
      var parsed = []
      if (exitCode === 0 && collected.trim()) {
        try {
          parsed = JSON.parse(collected)
        } catch (e) {
          console.warn("file-search: bad JSON from search.py:", e)
          root.errorText = "Could not parse search results"
        }
      } else {
        // Surface the tool's own message (missing index, Ollama down, ...).
        var firstLine = String(searchProcess.stderrText || "").trim().split("\n")[0]
        if (firstLine.indexOf("no index at") !== -1) {
          root.errorText = "No index yet — build one: " + root.pluginDir + "/tools/choose-folders.sh"
        } else {
          root.errorText = firstLine !== ""
            ? firstLine
            : "Search failed — is the Ollama service running?"
        }
      }
      // Keep the thinking state up for a moment so the animation reads.
      var elapsed = Date.now() - root.queryStartedAt
      if (elapsed < root.minThinkingTime) {
        root.pendingResults = parsed
        revealTimer.interval = root.minThinkingTime - elapsed
        revealTimer.restart()
      } else {
        root.revealResults(parsed)
      }
    }
  }

  Process {
    id: openProcess
    command: []
  }

  Timer {
    id: searchTimer
    interval: 0
    onTriggered: {
      if (root.opened && root.query) searchProcess.running = true
    }
  }

  Timer {
    id: revealTimer
    onTriggered: {
      if (root.opened && root.pendingResults !== null) {
        root.revealResults(root.pendingResults)
        root.pendingResults = null
      }
    }
  }

  Timer {
    id: closeTimer
    interval: 140
    onTriggered: root.finishClose()
  }

  // ---- surface -------------------------------------------------------------

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "tictac-file-search"

    // Scrim fades with the card.
    Rectangle {
      anchors.fill: parent
      color: root.scrim
      opacity: root.cardVisible ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: root.opened

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.move(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.move(1)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activate()
          event.accepted = true
        }
      }

      BorderSurface {
        id: card
        width: root.cardWidth
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.max(Style.space(80), Math.round((parent.height - height) / 2 - Style.space(40)))
        radius: root.cornerRadius
        color: root.background
        borderSpec: root.borderSpec
        padding: Style.space(14)
        implicitHeight: contentColumn.implicitHeight + topPadding + bottomPadding
        height: implicitHeight

        // Entrance: fade + rise + settle, and grow smoothly as results land.
        opacity: root.cardVisible ? 1 : 0
        scale: root.cardVisible ? 1 : 0.965
        Behavior on opacity { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on implicitHeight { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
          id: contentColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: parent.contentLeftInset
          anchors.rightMargin: parent.contentRightInset
          anchors.topMargin: parent.contentTopInset
          spacing: Style.space(10)

          // --- header -------------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: "\uf002"
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
              color: root.accent
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: queryText
              textFormat: Text.PlainText
              text: root.query
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              color: root.foreground
              elide: Text.ElideRight
              width: parent.width - Style.space(24) - thinking.width - statusText.implicitWidth
              anchors.verticalCenter: parent.verticalCenter
            }

            // Pulsing dots while the model is thinking.
            Row {
              id: thinking
              visible: root.searching
              spacing: Style.space(5)
              anchors.verticalCenter: parent.verticalCenter
              Repeater {
                model: 3
                Rectangle {
                  width: Style.space(5)
                  height: Style.space(5)
                  radius: width / 2
                  color: root.accent
                  opacity: 0.25
                  SequentialAnimation on opacity {
                    running: root.searching
                    loops: Animation.Infinite
                    PauseAnimation { duration: index * 140 }
                    NumberAnimation { to: 1.0; duration: 260; easing.type: Easing.OutQuad }
                    NumberAnimation { to: 0.25; duration: 300; easing.type: Easing.InQuad }
                    PauseAnimation { duration: 280 }
                  }
                }
              }
            }

            Text {
              id: statusText
              textFormat: Text.PlainText
              visible: !root.searching && root.results.length > 0
              text: root.results.length + (root.results.length === 1 ? " match" : " matches")
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: root.muted
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // --- sweep line (thinking) ---------------------------------------
          Item {
            width: parent.width
            height: Style.space(3)
            visible: root.searching
            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: root.faint
              opacity: 0.25
            }
            Rectangle {
              id: sweep
              height: parent.height
              radius: height / 2
              width: parent.width * 0.3
              color: root.accent
              opacity: 0.9
              SequentialAnimation on x {
                running: root.searching
                loops: Animation.Infinite
                NumberAnimation { from: 0; to: parent.width - sweep.width; duration: 620; easing.type: Easing.InOutQuad }
                NumberAnimation { from: parent.width - sweep.width; to: 0; duration: 620; easing.type: Easing.InOutQuad }
              }
            }
          }

          // --- results ------------------------------------------------------
          Flickable {
            id: listFlick
            width: parent.width
            height: Math.min(resultColumn.implicitHeight, Style.space(470))
            contentHeight: resultColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            Behavior on contentY { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            Column {
              id: resultColumn
              width: parent.width
              spacing: root.rowSpacing

              Repeater {
                model: root.results

                delegate: Rectangle {
                  id: row
                  required property var modelData
                  required property int index

                  property bool entered: false
                  readonly property bool highlighted: root.selectedIndex === index

                  width: resultColumn.width
                  height: root.rowHeight
                  radius: Math.min(root.cornerRadius, Style.space(6))
                  color: highlighted ? root.selectedBackground : "transparent"
                  Behavior on color { ColorAnimation { duration: 120; easing.type: Easing.OutCubic } }

                  // staggered entrance
                  opacity: entered ? 1 : 0
                  x: entered ? 0 : -Style.space(26)
                  Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                  Behavior on x { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                  Timer {
                    interval: 50 + row.index * 48
                    running: true
                    onTriggered: row.entered = true
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.selectedIndex = row.index
                    onClicked: root.activate(row.index)
                  }

                  Item {
                    id: rowIcon
                    readonly property bool isImage: row.modelData.kind === "image"
                    width: isImage ? Style.space(48) : Style.space(30)
                    height: parent.height
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)

                    // Real thumbnail for image results.
                    Image {
                      visible: rowIcon.isImage
                      anchors.fill: parent
                      anchors.topMargin: Style.space(7)
                      anchors.bottomMargin: Style.space(7)
                      anchors.rightMargin: Style.space(6)
                      source: rowIcon.isImage ? ("file://" + row.modelData.path) : ""
                      sourceSize.width: 192
                      sourceSize.height: 192
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      cache: true
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: !rowIcon.isImage
                      text: root.iconFor(row.modelData.path, row.modelData.kind)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.iconLarge
                      color: row.highlighted ? root.selectedText : root.faint
                      Behavior on color { ColorAnimation { duration: 120 } }
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      y: Style.space(7)
                    }
                  }

                  Text {
                    id: rowPercent
                    textFormat: Text.PlainText
                    text: row.modelData.pct + "%"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: row.highlighted
                    color: root.accent
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(12)
                    y: Style.space(6)
                  }

                  Text {
                    id: rowName
                    textFormat: Text.PlainText
                    text: root.baseName(row.modelData.path)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    color: row.highlighted ? root.selectedText : root.foreground
                    Behavior on color { ColorAnimation { duration: 120 } }
                    elide: Text.ElideMiddle
                    width: parent.width - rowIcon.width - rowPercent.implicitWidth - Style.space(40)
                    anchors.left: rowIcon.right
                    y: Style.space(5)
                  }

                  Text {
                    id: rowDir
                    textFormat: Text.PlainText
                    text: root.dirName(row.modelData.path)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    color: root.muted
                    elide: Text.ElideMiddle
                    width: rowName.width
                    anchors.left: rowName.left
                    y: rowName.y + rowName.height + Style.space(1)
                  }

                  // One-line content preview for text files.
                  Text {
                    id: rowSnippet
                    textFormat: Text.PlainText
                    visible: row.modelData.kind === "text" && (row.modelData.preview || "").length > 0
                    text: row.modelData.preview || ""
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    color: root.faint
                    elide: Text.ElideRight
                    width: rowName.width
                    anchors.left: rowName.left
                    y: rowDir.y + rowDir.height + Style.space(1)
                  }

                  // score bar, growing in behind the text
                  Item {
                    id: barTrack
                    height: Style.space(3)
                    width: parent.width - Style.space(54)
                    anchors.left: rowIcon.right
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(5)
                    Rectangle {
                      anchors.fill: parent
                      radius: height / 2
                      color: root.faint
                      opacity: 0.22
                    }
                    Rectangle {
                      height: parent.height
                      radius: height / 2
                      color: row.highlighted ? root.accent : Util.alpha(root.accent, 0.75)
                      width: row.entered ? Math.max(parent.width * (row.modelData.pct / 100), Style.space(8)) : 0
                      Behavior on width { NumberAnimation { duration: 760; easing.type: Easing.OutQuart } }
                      Behavior on color { ColorAnimation { duration: 120 } }
                    }
                  }
                }
              }
            }
          }

          // --- empty / error states -----------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: !root.searching && root.results.length === 0
            Text {
              textFormat: Text.PlainText
              text: "\uf071"
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
              color: root.faint
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              text: root.errorText !== "" ? root.errorText : ("Nothing in the index matches \u201c" + root.query + "\u201d")
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.muted
              elide: Text.ElideRight
              width: parent.width - Style.space(24)
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // --- footer -------------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(14)
            visible: root.results.length > 0 && !root.searching
            Text {
              textFormat: Text.PlainText
              text: "\u2191\u2193 navigate   \u23ce open   esc close"
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              color: root.faint
            }
          }
        }
      }
    }
  }
}
