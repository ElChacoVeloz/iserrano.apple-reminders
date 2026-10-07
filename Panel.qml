import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "DateParse.js" as DateParse

// Bar widget: today's (and overdue) Apple Reminders from iCloud. Click a row
// to complete it, type to add a new one due today.
//
// All iCloud traffic goes through scripts/apple-reminders, which prints one
// line of JSON per call. Sign-in (password + 2FA) happens in a terminal.
Panel {
  id: root

  moduleName: "iserrano.apple-reminders"
  ipcTarget: "iserrano.apple-reminders"

  property string addListId: ""
  property int refreshSeconds: 300
  property int maxRows: 16
  property bool showNextItem: true
  property int nextItemChars: 22
  property bool hideWhenEmpty: false

  function flagSetting(name, fallback) {
    var value = setting(name, fallback)
    if (value === true || value === 1 || value === "true" || value === "on" || value === "1") return true
    if (value === false || value === 0 || value === "false" || value === "off" || value === "0") return false
    return fallback === true
  }

  function applySettings() {
    addListId = String(setting("addListId", "") || "")
    refreshSeconds = Math.max(60, Number(setting("interval", 300)) || 300)
    maxRows = Math.max(3, Number(setting("maxRows", 16)) || 16)
    showNextItem = flagSetting("showNextItem", true)
    nextItemChars = Math.max(6, Number(setting("nextItemChars", 22)) || 22)
    hideWhenEmpty = flagSetting("hideWhenEmpty", false)
  }

  readonly property string helper: String(Qt.resolvedUrl("scripts/apple-reminders")).replace(/^file:\/\//, "")

  property var items: []
  property var rows: []
  property var lists: []
  property bool ok: true
  property string errorKind: ""
  property string errorHint: ""
  property bool loading: false
  property bool settled: false
  property bool choosingList: false
  property var draft: null
  property string status: ""
  property bool statusIsError: false
  property int cursor: -1
  property string pendingId: ""
  property var undoItem: null
  property var jobs: []
  property var activeJob: null

  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property var addTarget: Model.addTarget(lists, addListId)

  function needsLogin() { return !ok && Model.needsLogin(errorKind) }

  function viewState() {
    return {
      ok: ok, error: errorKind, hint: errorHint,
      loading: loading, settled: settled, items: items, total: items.length
    }
  }

  function rebuildRows() { rows = Model.rows(items, maxRows) }

  onItemsChanged: rebuildRows()
  onMaxRowsChanged: rebuildRows()
  onSettingsChanged: { applySettings(); rebuildRows() }
  Component.onCompleted: applySettings()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    var src = root.settings
    if (src) {
      for (var key in src) {
        if (key !== "id") entry[key] = src[key]
      }
    }
    for (var next in values) entry[next] = values[next]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function cycleAddList() {
    var next = Model.nextList(lists, addTarget ? addTarget.id : "")
    if (next) persistSettings({ addListId: next.id })
  }

  function chooseAddList(id) {
    persistSettings({ addListId: id })
    choosingList = false
    addField.forceActiveFocus()
  }

  function refresh() {
    if (fetchProc.running) return
    loading = true
    fetchProc.command = [root.helper, "fetch"]
    fetchProc.running = true
  }

  function applyFetch(text) {
    var payload = Model.parse(text)
    settled = true
    loading = false
    if (!payload) {
      markError("bad-response", "")
      return
    }
    if (payload.ok === false) {
      markError(payload.error, payload.hint)
      return
    }
    ok = true
    errorKind = ""
    errorHint = ""
    items = Model.itemsOf(payload)
    lists = Model.listsOf(payload)
    if (cursor >= items.length) cursor = items.length - 1
    if (pendingId !== "" && !Model.itemById(items, pendingId)) pendingId = ""
  }

  function markError(kind, hint) {
    ok = false
    errorKind = String(kind || "")
    errorHint = String(hint || "")
    if (needsLogin()) items = []
    if (errorKind === "syncing") syncRetryTimer.restart()
  }

  function enqueue(job) {
    jobs = jobs.concat([job])
    pump()
  }

  function pump() {
    if (actionProc.running || jobs.length === 0) return
    activeJob = jobs[0]
    jobs = jobs.slice(1)
    actionProc.command = [root.helper].concat(activeJob.args)
    actionProc.running = true
  }

  function completeItem(index) {
    var item = items[index]
    if (!item || pendingId === item.id) return
    pendingId = item.id
    enqueue({ kind: "complete", item: item, args: ["complete", item.id] })
  }

  function undoComplete() {
    if (!undoItem) return
    var item = undoItem
    undoItem = null
    undoTimer.stop()
    enqueue({ kind: "reopen", item: item, args: ["reopen", item.id] })
  }

  function addItem(text) {
    var value = String(text || "").trim()
    if (value === "") return
    var parsed = DateParse.parse(value)
    var args = ["add"]
    if (addTarget) args = args.concat(["--list-id", addTarget.id])
    if (parsed.date === "") args.push("--no-date")
    else args = args.concat(["--date", parsed.date])
    if (parsed.time !== "") args = args.concat(["--time", parsed.time])
    enqueue({ kind: "add", content: parsed.title, when: parsed.label, args: args.concat(["--", parsed.title]) })
  }

  function applyAction(text) {
    var payload = Model.parse(text) || { ok: false, error: "bad-response" }
    var job = activeJob || {}
    var item = job.item || null
    pendingId = ""

    if (payload.ok === false) {
      if (Model.needsLogin(payload.error)) markError(payload.error, payload.hint)
      else note(Model.errorMessage(payload.error), true)
    } else if (job.kind === "complete" && item) {
      items = Model.withoutItem(items, item.id)
      if (cursor >= items.length) cursor = items.length - 1
      undoItem = item
      undoTimer.restart()
      note("Hecho: " + Model.truncate(item.content, 28), false)
    } else if (job.kind === "reopen" && item) {
      items = Model.withItem(items, item)
      note("Restaurado: " + Model.truncate(item.content, 28), false)
    } else if (job.kind === "add") {
      note("Añadido a " + (payload.list || "Recordatorios") + " (" + job.when + "): " + Model.truncate(payload.content || job.content || "", 20), false)
    }

    activeJob = null
    resyncTimer.restart()
  }

  function login() {
    if (!bar) return
    bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(Util.shellQuote(root.helper) + " login"))
    root.close()
  }

  function note(text, isError) {
    status = String(text || "")
    statusIsError = !!isError
    statusTimer.restart()
  }

  function openWeb() {
    if (bar) bar.run("omarchy-launch-webapp " + Util.shellQuote("https://www.icloud.com/reminders/"))
  }

  function moveCursor(delta) {
    cursor = Model.step(Model.cursorTargets(rows), cursor, delta)
  }

  onOpenedChanged: {
    if (opened) {
      cursor = -1
      status = ""
      refresh()
      if (addField.visible) Qt.callLater(function() { addField.forceActiveFocus() })
    } else {
      addField.text = ""
      addField.focus = false
      choosingList = false
      draft = null
    }
  }

  Process {
    id: fetchProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFetch(text)
    }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0 && !root.settled) root.markError("helper-exit", "exit " + exitCode)
    }
  }

  Process {
    id: actionProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAction(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.pendingId = ""
        root.activeJob = null
        root.note("El helper falló (exit " + exitCode + ")", true)
      }
      root.pump()
    }
  }

  Timer {
    id: pollTimer

    interval: root.refreshSeconds * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: resyncTimer

    interval: 1500
    onTriggered: if (root.jobs.length === 0 && !actionProc.running) root.refresh()
  }

  Timer {
    id: syncRetryTimer

    interval: 2000
    onTriggered: root.refresh()
  }

  Timer {
    id: statusTimer

    interval: 4000
    onTriggered: { root.status = ""; root.statusIsError = false }
  }

  Timer {
    id: undoTimer

    interval: 12000
    onTriggered: root.undoItem = null
  }

  WidgetButton {
    id: button

    bar: root.bar
    fontFamily: root.fontFamily
    text: Model.barText(root.viewState(), {
      vertical: root.vertical,
      showNextItem: root.showNextItem,
      chars: root.nextItemChars,
      hideWhenEmpty: root.hideWhenEmpty
    })
    tooltipText: Model.tooltip(root.viewState())

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.openWeb()
      else if (mouseButton === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel

    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher

      anchors.fill: parent
      blocked: addField.activeFocus

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: {
        if (root.needsLogin()) root.login()
        else if (root.cursor >= 0) root.completeItem(root.cursor)
      }
      onDeleteRequested: if (root.cursor >= 0) root.completeItem(root.cursor)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "u") root.undoComplete()
        else if (text === "r") root.refresh()
        else if (text === "a") addField.forceActiveFocus()
        else if (text === "l") root.cycleAddList()
        else if (text === "g") root.openWeb()
      }

      Column {
        id: column

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Item {
          width: parent.width
          implicitHeight: Math.max(heroGlyph.implicitHeight, heroLabels.implicitHeight, heroCount.implicitHeight)

          Text {
            id: heroGlyph

            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.ok ? Model.glyph.list : Model.glyph.alert
            color: root.ok ? root.barForeground : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          Column {
            id: heroLabels

            anchors.left: heroGlyph.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroCount.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Recordatorios"
              color: root.barForeground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.loading && !root.settled ? "CARGANDO…"
                : "HOY · " + Qt.formatDate(new Date(), "ddd d MMM").toUpperCase()
              color: Qt.darker(root.barForeground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }

          Text {
            id: heroCount

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(54)
            horizontalAlignment: Text.AlignRight
            opacity: root.ok ? 1 : 0
            text: String(root.items.length)
            color: root.barForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.ok

          Text {
            width: parent.width
            text: Model.errorMessage(root.errorKind)
            color: root.errorKind === "no-account" || root.errorKind === "syncing" ? root.barForeground : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.needsLogin()
            text: "Inicia sesión con tu Apple ID en una terminal (contraseña + código 2FA). La sesión dura unos dos meses."
            color: Qt.darker(root.barForeground, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: !root.needsLogin() && root.errorHint !== ""
            text: root.errorHint
            color: Qt.darker(root.barForeground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
          }

          Row {
            anchors.right: parent.right
            spacing: Style.space(6)

            Button {
              text: "Reintentar"
              bordered: true
              visible: !root.needsLogin()
              foreground: root.barForeground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.refresh()
            }

            Button {
              text: "Conectar iCloud"
              bordered: true
              visible: root.needsLogin()
              foreground: root.barForeground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: root.login()
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.ok && root.items.length > 0

          Repeater {
            model: root.rows

            Item {
              id: slot

              required property int index
              required property var modelData

              width: parent.width
              implicitHeight: loader.item ? loader.item.implicitHeight : 0

              Loader {
                id: loader

                width: parent.width
                sourceComponent: slot.modelData.kind === "item" ? itemComponent
                  : slot.modelData.kind === "header" ? headerComponent : moreComponent
              }

              Component {
                id: headerComponent

                PanelSectionHeader {
                  width: slot.width
                  text: slot.modelData.title
                  foreground: root.barForeground
                  fontFamily: root.fontFamily
                  topPadding: slot.index === 0 ? Style.space(2) : Style.space(8)
                }
              }

              Component {
                id: itemComponent

                ItemRow {
                  width: slot.width
                  item: slot.modelData.item
                  hasCursor: root.cursor === slot.modelData.itemIndex
                  busy: root.pendingId === slot.modelData.item.id
                  foreground: root.barForeground
                  urgent: root.urgent
                  fontFamily: root.fontFamily
                  onEntered: root.cursor = slot.modelData.itemIndex
                  onCompleteRequested: root.completeItem(slot.modelData.itemIndex)
                }
              }

              Component {
                id: moreComponent

                Text {
                  width: slot.width
                  text: "+" + slot.modelData.hidden + " más"
                  color: Qt.darker(root.barForeground, 1.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignHCenter
                  topPadding: Style.space(4)
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.ok && root.settled && root.items.length === 0
          text: Model.glyph.check + "  Nada pendiente para hoy"
          color: Qt.darker(root.barForeground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
        }

        Item {
          width: parent.width
          visible: !!root.undoItem
          implicitHeight: visible ? Style.space(22) : 0

          Rectangle {
            anchors.fill: parent
            radius: Style.space(2)
            color: Util.alpha(root.barForeground, 0.08)
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.right: undoButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.undoItem ? Model.glyph.check + "  " + Model.truncate(root.undoItem.content, 30) : ""
            color: Qt.darker(root.barForeground, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: undoButton

            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: Model.glyph.undo + " deshacer"
            color: undoMouse.containsMouse ? root.barForeground : Qt.darker(root.barForeground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true

            MouseArea {
              id: undoMouse

              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.undoComplete()
            }
          }
        }

        Text {
          width: parent.width
          visible: root.status !== ""
          text: root.status
          color: root.statusIsError ? root.urgent : Qt.darker(root.barForeground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }

        TextField {
          id: addField

          width: parent.width
          visible: root.ok && root.settled
          placeholderText: Model.glyph.plus + "  Nuevo… ej. «Pagar luz mañana 10:30»"
          foreground: root.barForeground
          accent: root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall

          onTextChanged: root.draft = text.trim() === "" ? null : DateParse.parse(text)

          onAccepted: {
            root.addItem(text)
            text = ""
          }

          Keys.onEscapePressed: function(event) {
            if (root.choosingList) root.choosingList = false
            else if (text !== "") text = ""
            else keyCatcher.forceActiveFocus()
            event.accepted = true
          }

          Keys.onPressed: function(event) {
            if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_L) {
              root.cycleAddList()
              event.accepted = true
            }
          }
        }

        Text {
          width: parent.width
          visible: addField.visible && !!root.draft
          text: root.draft ? Model.glyph.calendar + "  " + root.draft.label + "   ·   «" + root.draft.title + "»" : ""
          color: Qt.darker(root.barForeground, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Item {
          width: parent.width
          visible: addField.visible && root.lists.length > 0
          implicitHeight: listChip.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Guardar en"
            color: Qt.darker(root.barForeground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            id: listChip

            anchors.right: parent.right
            text: (root.addTarget ? root.addTarget.title : "—") + (root.choosingList ? "  ▴" : "  ▾")
            bordered: true
            selected: root.choosingList
            foreground: root.barForeground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.choosingList = !root.choosingList
          }
        }

        Flow {
          width: parent.width
          visible: addField.visible && root.choosingList
          spacing: Style.space(4)

          Repeater {
            model: root.lists

            Button {
              required property var modelData

              text: modelData.title
              bordered: true
              selected: root.addTarget && modelData.id === root.addTarget.id
              foreground: root.barForeground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(4)
              onClicked: root.chooseAddList(modelData.id)
            }
          }
        }

        Text {
          width: parent.width
          text: root.needsLogin()
            ? "↵ conectar · esc cerrar"
            : root.items.length > 0
              ? "↵ hecho · a añadir · ctrl+l lista · u deshacer · r refrescar"
              : "a añadir · ctrl+l lista · r refrescar · g abrir iCloud"
          color: Qt.darker(root.barForeground, 1.7)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }
    }
  }
}
