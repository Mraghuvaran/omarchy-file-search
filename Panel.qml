import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// File Search — semantic search over the user's embedding index.
// Type a description, results stream in as you type (debounced, cancellable),
// with staggered entrance, score bars, thumbnails, snippets, and a live
// preview pane for the selected hit.
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
  readonly property int minThinkingTime: 420   // ms, so the sweep is visible
  readonly property int debounceMs: 280

  // ---- lifecycle -----------------------------------------------------------

  property bool opened: false
  property bool cardVisible: false

  function open(payloadJson) {
    var incoming = ({})
    try { incoming = JSON.parse(payloadJson || "{}") } catch (e) { incoming = ({}) }

    closeTimer.stop()   // cancel a teardown from a previous close
    root.indexDir = incoming.index ? String(incoming.index) : root.defaultIndexDir
    root.results = []
    root.selectedIndex = -1
    root.errorText = ""
    root.searching = false
    root.previewText = ""
    root.previewFile = ""
    var q = incoming.query ? String(incoming.query) : ""
    searchInput.text = q
    root.query = q
    root.opened = true
    Qt.callLater(function() {
      root.cardVisible = true
      searchInput.forceActiveFocus()
    })
    if (q !== "")
      root.startSearch()
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
    if (previewProcess.running) previewProcess.running = false
    root.results = []
    root.query = ""
    root.previewText = ""
    root.previewFile = ""
  }

  // ---- state ---------------------------------------------------------------

  property string query: ""            // the query currently being searched
  property bool searching: false
  property string errorText: ""
  property var results: []
  property int selectedIndex: -1
  property double searchStartedAt: 0
  property var pendingResults: null
  property int searchSerial: 0
  property string previewText: ""
  property string previewFile: ""
  property real previewOpacity: 1

  readonly property int rowHeight: Style.space(68)
  readonly property int rowSpacing: Style.space(4)
  readonly property bool hasSelection: selectedIndex >= 0 && selectedIndex < results.length
  readonly property var selectedHit: hasSelection ? results[selectedIndex] : null

  function startSearch() {
    var q = (searchInput.text || "")
    root.query = q
    if (q.trim().length < 2) {
      if (searchProcess.running) searchProcess.running = false
      root.results = []
      root.selectedIndex = -1
      root.searching = false
      root.errorText = ""
      return
    }
    root.searchSerial++
    searchProcess.issuedSerial = root.searchSerial
    root.searchStartedAt = Date.now()
    root.pendingResults = null
    root.searching = true
    root.errorText = ""
    if (searchProcess.running) searchProcess.running = false
    startTimer.restart()   // (re)start on the next tick so a stop can settle
  }

  function revealResults(parsed) {
    root.results = parsed
    root.searching = false
    root.selectedIndex = parsed.length > 0 ? 0 : -1
    root.loadPreview()
  }

  function move(delta) {
    if (root.results.length === 0) return
    var n = root.results.length
    root.selectedIndex = ((root.selectedIndex + delta) % n + n) % n
    ensureVisible()
    loadPreview()
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

  function loadPreview() {
    var hit = root.selectedHit
    if (!hit) {
      root.previewFile = ""
      root.previewText = ""
      return
    }
    root.previewFile = hit.path
    root.previewText = ""
    if (hit.kind === "text") {
      if (previewProcess.running) previewProcess.running = false
      previewProcess.issuedPath = hit.path
      previewProcess.collected = ""
      previewProcess.command = ["head", "-c", "1800", hit.path]
      previewStartTimer.restart()
    }
    root.previewOpacity = 0
    previewFade.restart()
  }

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
  readonly property int cardWidth: Math.min(Style.space(1080), panel.width - Style.space(48))
  readonly property int listWidth: Math.round(Math.min(Style.space(640), cardWidth * 0.62))

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
    property int issuedSerial: -1
    property string collected: ""
    property string stderrText: ""
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
    onExited: function(exitCode) {
      if (!root.opened || issuedSerial !== root.searchSerial) return   // stale run
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
        var firstLine = String(stderrText || "").trim().split("\n")[0]
        if (firstLine.indexOf("no index at") !== -1) {
          root.errorText = "No index yet — build one: " + root.pluginDir + "/tools/choose-folders.sh"
        } else {
          root.errorText = firstLine !== ""
            ? firstLine
            : "Search failed — is the Ollama service running?"
        }
      }
      // Keep the thinking state up for a moment so the animation reads.
      var elapsed = Date.now() - root.searchStartedAt
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
    id: previewProcess
    property string issuedPath: ""
    property string collected: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (previewProcess.issuedPath === root.previewFile) root.previewText = text
    }
  }

  Process {
    id: openProcess
    command: []
  }

  Timer {
    id: typingTimer
    interval: root.debounceMs
    onTriggered: root.startSearch()
  }

  Timer {
    id: startTimer
    interval: 0
    onTriggered: if (root.opened && root.query.trim().length >= 2) searchProcess.running = true
  }

  Timer {
    id: previewStartTimer
    interval: 0
    onTriggered: if (root.opened && root.previewFile !== "") previewProcess.running = true
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

  NumberAnimation {
    id: previewFade
    target: root
    property: "previewOpacity"
    to: 1
    duration: 240
    easing.type: Easing.OutCubic
  }

  // ---- surface -------------------------------------------------------------

  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "mraghuvaran-file-search"

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
          if (searchInput.text) {
            searchInput.text = ""
            root.startSearch()
          } else {
            root.close()
          }
          event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.move(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.move(1)
          event.accepted = true
        } else if (event.key === Qt.Key_PageUp) {
          root.move(-5)
          event.accepted = true
        } else if (event.key === Qt.Key_PageDown) {
          root.move(5)
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
        y: Math.max(Style.space(70), Math.round((parent.height - height) / 2 - Style.space(50)))
        radius: root.cornerRadius
        color: root.background
        borderSpec: root.borderSpec
        padding: Style.space(14)

        opacity: root.cardVisible ? 1 : 0
        scale: root.cardVisible ? 1 : 0.965
        implicitHeight: contentRow.implicitHeight + topPadding + bottomPadding
        height: implicitHeight
        Behavior on opacity { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on implicitHeight { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

        MouseArea { anchors.fill: parent; onClicked: {} }

        Row {
          id: contentRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.leftMargin: parent.contentLeftInset
          anchors.rightMargin: parent.contentRightInset
          anchors.topMargin: parent.contentTopInset
          spacing: Style.space(14)

          // ======================= results column =========================
          Column {
            id: listColumn
            width: root.listWidth
            spacing: Style.space(10)

            // --- search header -------------------------------------------
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

              TextInput {
                id: searchInput
                width: parent.width - Style.space(24) - thinking.width - statusText.implicitWidth
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                color: root.foreground
                selectionColor: Util.alpha(root.accent, 0.35)
                selectedTextColor: root.foreground
                selectByMouse: true
                clip: true
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  textFormat: Text.PlainText
                  text: "Describe what you're looking for…"
                  visible: searchInput.text.length === 0
                  font.family: searchInput.font.family
                  font.pixelSize: searchInput.font.pixelSize
                  color: root.faint
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                onTextChanged: {
                  if (!root.opened) return
                  root.query = text
                  if (text.trim().length < 2)
                    root.startSearch()   // clears immediately
                  else
                    typingTimer.restart()
                }
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

            // --- sweep line (thinking) -----------------------------------
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

            // --- results --------------------------------------------------
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

                    opacity: entered ? 1 : 0
                    x: entered ? 0 : -Style.space(26)
                    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    Behavior on x { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    Timer {
                      interval: 40 + row.index * 42
                      running: true
                      onTriggered: row.entered = true
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      // Only take over selection when the mouse actually moves;
                      // a stationary cursor overlapping the panel must not
                      // steal the highlight when it opens.
                      onPositionChanged: {
                        root.selectedIndex = row.index
                        root.loadPreview()
                      }
                      onClicked: root.activate(row.index)
                    }

                    Item {
                      id: rowIcon
                      readonly property bool isImage: row.modelData.kind === "image"
                      width: isImage ? Style.space(48) : Style.space(30)
                      height: parent.height
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(10)

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

            // --- empty / error states -------------------------------------
            Row {
              width: parent.width
              spacing: Style.space(8)
              visible: !root.searching && root.results.length === 0
                && (searchInput.text.trim().length >= 2 || root.errorText !== "")
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
                text: root.errorText !== "" ? root.errorText
                  : ("Nothing in the index matches \u201c" + searchInput.text + "\u201d")
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                color: root.muted
                elide: Text.ElideRight
                width: parent.width - Style.space(24)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // --- footer ---------------------------------------------------
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

          // ======================= preview column =========================
          Column {
            id: previewColumn
            width: contentRow.width - root.listWidth - contentRow.spacing
            spacing: Style.space(10)
            opacity: previewOpacity

            Item {
              id: previewBox
              width: parent.width
              height: Style.space(300)
              visible: root.hasSelection

              // Images: the full picture, fit inside the box.
              Image {
                anchors.fill: parent
                visible: !!root.selectedHit && root.selectedHit.kind === "image"
                source: visible ? ("file://" + root.selectedHit.path) : ""
                sourceSize.width: 640
                sourceSize.height: 640
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
              }

              // Videos: a play glyph (we embed a keyframe, not a poster).
              Text {
                textFormat: Text.PlainText
                visible: !!root.selectedHit && root.selectedHit.kind === "video"
                text: "\uf03d"
                font.family: root.fontFamily
                font.pixelSize: Style.space(64)
                color: root.faint
                anchors.centerIn: parent
              }

              // Text: a live excerpt of the file itself.
              Flickable {
                anchors.fill: parent
                visible: !!root.selectedHit && root.selectedHit.kind === "text"
                contentHeight: previewBody.implicitHeight
                clip: true
                interactive: contentHeight > height

                Text {
                  id: previewBody
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.previewText || "…"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  color: root.muted
                  wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                }
              }
            }

            // --- preview metadata -----------------------------------------
            Column {
              width: parent.width
              spacing: Style.space(3)
              visible: root.hasSelection

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.selectedHit ? root.selectedHit.path : ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                color: root.foreground
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 3
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: {
                  if (!root.selectedHit) return ""
                  var hit = root.selectedHit
                  if (hit.kind === "text")
                    return hit.chars + " characters read"
                  return hit.preview || hit.kind
                }
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                color: root.faint
                elide: Text.ElideRight
              }
            }
          }
        }
      }
    }
  }
}
