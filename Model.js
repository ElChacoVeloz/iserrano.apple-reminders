// Formatting helpers for the Apple Reminders widget. Panel.qml stays layout.

var glyph = {
  list: "󰝖",
  check: "",
  undo: "",
  plus: "",
  alert: "",
  flag: "",
  calendar: "\uf073"
}

function parse(text) {
  try {
    var data = JSON.parse(String(text || "").trim())
    return (data && typeof data === "object") ? data : null
  } catch (e) {
    return null
  }
}

function itemsOf(data) {
  var items = data ? data.items : null
  return Array.isArray(items) ? items : []
}

function listsOf(data) {
  var lists = data ? data.lists : null
  return Array.isArray(lists) ? lists : []
}

function truncate(text, chars) {
  var value = String(text || "")
  var limit = Math.max(4, Number(chars) || 24)
  if (value.length <= limit) return value
  return value.slice(0, limit - 1).replace(/\s+$/, "") + "…"
}

function itemById(items, id) {
  for (var i = 0; i < items.length; i++) {
    if (items[i].id === id) return items[i]
  }
  return null
}

function withoutItem(items, id) {
  var out = []
  for (var i = 0; i < items.length; i++) {
    if (items[i].id !== id) out.push(items[i])
  }
  return out
}

function withItem(items, item) {
  var out = [item]
  for (var i = 0; i < items.length; i++) {
    if (items[i].id !== item.id) out.push(items[i])
  }
  return out
}

function listById(lists, id) {
  for (var i = 0; i < lists.length; i++) {
    if (lists[i].id === id) return lists[i]
  }
  return null
}

function nextList(lists, id) {
  if (lists.length === 0) return null
  for (var i = 0; i < lists.length; i++) {
    if (lists[i].id === id) return lists[(i + 1) % lists.length]
  }
  return lists[0]
}

// Mirrors the helper's default: an explicit choice, then a list called
// Recordatorios/Reminders/Inbox, then the first list.
function addTarget(lists, id) {
  var chosen = listById(lists, id)
  if (chosen) return chosen
  for (var i = 0; i < lists.length; i++) {
    var name = String(lists[i].title || "").trim().toLowerCase()
    if (name === "recordatorios" || name === "reminders" || name === "inbox") return lists[i]
  }
  return lists.length > 0 ? lists[0] : null
}

function rows(items, cap) {
  var out = []
  var limit = Math.max(1, Number(cap) || 16)
  var section = null
  var shown = 0
  for (var j = 0; j < items.length && shown < limit; j++) {
    var item = items[j]
    var name = item.section || ""
    if (name !== "" && name !== section) {
      section = name
      out.push({ kind: "header", title: name, itemIndex: -1 })
    }
    out.push({ kind: "item", item: item, itemIndex: j })
    shown++
  }
  if (items.length > shown) out.push({ kind: "more", hidden: items.length - shown, itemIndex: -1 })
  return out
}

function cursorTargets(rowList) {
  var targets = []
  for (var i = 0; i < rowList.length; i++) {
    if (rowList[i].kind === "item") targets.push(rowList[i].itemIndex)
  }
  return targets
}

function step(targets, current, delta) {
  if (targets.length === 0) return -1
  var at = targets.indexOf(current)
  if (at === -1) return targets[delta >= 0 ? 0 : targets.length - 1]
  var next = at + delta
  if (next < 0) next = targets.length - 1
  else if (next >= targets.length) next = 0
  return targets[next]
}

function overdueCount(items) {
  var n = 0
  for (var i = 0; i < items.length; i++) if (items[i].overdue) n++
  return n
}

// The next reminder as the bar shows it: when it is due, then the title, each
// field joined by a dash ("12/10 - 10:00 - Pagar luz"). The date only shows for
// reminders left over from an earlier day, the time only when they carry one,
// and a field that is missing takes its dash with it. The title is trimmed to
// the configured width.
function nextItemText(item, opts) {
  var when = []
  if (item.overdue && item.due) when.push(shortDate(item.due))
  if (opts.showNextTime && item.time) when.push(String(item.time))
  var title = truncate(item.content, opts.chars)
  return when.length > 0 ? when.join(" - ") + " - " + title : title
}

function barText(view, opts) {
  var icon = glyph.list
  if (!view.ok) return opts.vertical ? glyph.alert : icon + " " + glyph.alert
  if (view.loading && view.total === 0 && !view.settled) return opts.vertical ? icon : icon + " …"
  if (view.total === 0) return opts.hideWhenEmpty ? "" : (opts.vertical ? icon + "\n0" : icon + " 0")
  if (opts.vertical) return icon + "\n" + view.total
  var text = icon + " " + view.total
  if (opts.showNextItem && view.items.length > 0) text += " · " + nextItemText(view.items[0], opts)
  return text
}

function tooltip(view) {
  if (!view.ok) return "Recordatorios · " + errorMessage(view.error)
  if (view.total === 0) return "Recordatorios · nada para hoy"
  var overdue = overdueCount(view.items)
  var text = "Recordatorios · " + view.total + " para hoy"
  if (overdue > 0) text += " (" + overdue + " vencido" + (overdue === 1 ? ")" : "s)")
  return text
}

function meta(item) {
  var parts = []
  if (item.time) parts.push(item.time)
  else if (item.overdue && item.due) parts.push(shortDate(item.due))
  if (item.list) parts.push(item.list)
  return parts.join(" · ")
}

function shortDate(iso) {
  var bits = String(iso || "").split("-")
  if (bits.length !== 3) return iso
  return Number(bits[2]) + "/" + Number(bits[1])
}

function needsLogin(error) {
  return error === "no-account" || error === "needs-login" || error === "login-failed"
    || error === "not-installed"
}

function errorMessage(error) {
  switch (error) {
  case "no-account": return "Sin cuenta de iCloud conectada"
  case "needs-login": return "La sesión de iCloud caducó"
  case "login-failed": return "iCloud rechazó el inicio de sesión"
  case "not-installed": return "Falta instalar pyicloud"
  case "keyring": return "No se pudo leer el llavero"
  case "offline": return "No se puede contactar con iCloud"
  case "syncing": return "Sincronizando tus listas de iCloud por primera vez…"
  case "no-lists": return "No hay listas de recordatorios"
  case "text-too-long": return "El texto es demasiado largo"
  case "bad-response": return "Respuesta ilegible del helper"
  case "helper-crash": return "El helper falló"
  case "helper-exit": return "El helper falló"
  default: return error ? "Error: " + error : "Algo salió mal"
  }
}
