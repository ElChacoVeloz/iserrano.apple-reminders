// Pulls a due date/time out of free text, Spanish first with a little English:
//   "Pagar luz mañana 10:30"           -> mañana, 10:30
//   "Dentista viernes a las 5 de la tarde" -> próximo viernes, 17:00
//   "Llamar a mamá 15/10 9am"          -> 15 oct, 09:00
//   "Revisar correo sin fecha"          -> no due date
// No date words means today. Dates are d/m (d/m/aaaa). Returns
// { title, date: "YYYY-MM-DD" | "", time: "HH:MM" | "", label }.

var WEEKDAYS = {
  domingo: 0, lunes: 1, martes: 2, miercoles: 3, jueves: 4, viernes: 5, sabado: 6,
  sunday: 0, monday: 1, tuesday: 2, wednesday: 3, thursday: 4, friday: 5, saturday: 6
}
var DAY_NAMES = ["dom", "lun", "mar", "mié", "jue", "vie", "sáb"]
var MONTH_NAMES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]

// Lowercase and strip accents so the regexes stay ASCII. Same length as the
// input, so match offsets apply to the original text too.
function fold(text) {
  return String(text).toLowerCase()
    .replace(/[áà]/g, "a").replace(/[éè]/g, "e").replace(/[íì]/g, "i")
    .replace(/[óò]/g, "o").replace(/[úùü]/g, "u").replace(/ñ/g, "n")
}

function pad(n) { return (n < 10 ? "0" : "") + n }
function iso(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) }
function addDays(d, n) { var r = new Date(d.getFullYear(), d.getMonth(), d.getDate()); r.setDate(r.getDate() + n); return r }

function parse(text, now) {
  var original = String(text || "")
  var src = fold(original)
  var today = now ? new Date(now) : new Date()
  today = new Date(today.getFullYear(), today.getMonth(), today.getDate())
  var cut = []           // [start, end) ranges removed from the title
  var date = null
  var noDate = false
  var hour = -1, minute = 0, meridiem = ""

  function take(re, fn) {
    var m = re.exec(src)
    if (!m) return false
    if (fn(m) === false) return false
    cut.push([m.index, m.index + m[0].length])
    src = src.slice(0, m.index) + Array(m[0].length + 1).join("\u0000") + src.slice(m.index + m[0].length)
    return true
  }

  take(/(^|[\s\u0000])sin fecha\b/, function() { noDate = true })

  // Period of day first so "mañana" inside "de la mañana" is not a date.
  take(/\s*\b(de|en|por) la (manana|tarde|noche)\b/, function(m) { meridiem = m[2] === "manana" ? "am" : "pm" })
  take(/(^|[\s\u0000])(al )?mediodia\b/, function() { hour = 12; minute = 0 })

  if (!noDate) {
    take(/(^|[\s\u0000])pasado manana\b/, function() { date = addDays(today, 2) })
      || take(/(^|[\s\u0000])(manana|tomorrow)\b/, function(m) {
        if (/\bla\s*$/.test(src.slice(0, m.index + m[1].length))) return false  // "la mañana"
        date = addDays(today, 1)
      })
      || take(/(^|[\s\u0000])(hoy|today)\b/, function() { date = today })
      || take(/(^|[\s\u0000])((el|este|esta|proximo|next|on) )?(lunes|martes|miercoles|jueves|viernes|sabado|domingo|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/, function(m) {
        var delta = (WEEKDAYS[m[4]] - today.getDay() + 7) % 7
        date = addDays(today, delta === 0 ? 7 : delta)
      })
      || take(/(^|[\s\u0000])((el|para el) )?(\d{1,2})\/(\d{1,2})(\/(\d{2,4}))?(?=[\s\u0000]|$)/, function(m) {
        var day = Number(m[4]), month = Number(m[5]) - 1
        var year = m[7] ? Number(m[7]) : today.getFullYear()
        if (year < 100) year += 2000
        if (month < 0 || month > 11 || day < 1 || day > 31) return false
        var d = new Date(year, month, day)
        if (d.getMonth() !== month) return false
        if (!m[7] && d < today) d = new Date(year + 1, month, day)
        date = d
      })
  }

  if (hour < 0) {
    take(/(^|[\s\u0000])((a las|a la|at) )?(\d{1,2}):(\d{2})( ?(am|pm|hrs|hr|h)\b)?/, function(m) {
      hour = Number(m[4]); minute = Number(m[5])
      if (m[7] === "am" || m[7] === "pm") meridiem = meridiem || m[7]
    })
      || take(/(^|[\s\u0000])((a las|a la|at) )?(\d{1,2}) ?(am|pm)\b/, function(m) {
        hour = Number(m[4]); minute = 0; meridiem = meridiem || m[5]
      })
      || take(/(^|[\s\u0000])(a las|a la|at) (\d{1,2})\b( ?(hrs|hr|h)\b)?/, function(m) {
        hour = Number(m[3]); minute = 0
        // "a las 5" with no am/pm: before 8 reads as afternoon.
        if (!meridiem && !m[4] && hour >= 1 && hour < 8) meridiem = "pm"
      })
  }

  if (hour >= 0) {
    if (meridiem === "pm" && hour < 12) hour += 12
    if (meridiem === "am" && hour === 12) hour = 0
    if (hour > 23 || minute > 59) hour = -1
  }

  var title = ""
  var last = 0
  cut.sort(function(a, b) { return a[0] - b[0] })
  for (var i = 0; i < cut.length; i++) {
    title += original.slice(last, cut[i][0]) + " "
    last = cut[i][1]
  }
  title += original.slice(last)
  title = title.replace(/\s+/g, " ").replace(/\s+([,.;])/g, "$1").replace(/[\s,;-]+$/, "").trim()
  if (title === "") title = original.trim()

  if (noDate) return { title: title, date: "", time: "", label: "sin fecha" }
  if (!date) date = today
  var time = hour >= 0 ? pad(hour) + ":" + pad(minute) : ""
  return { title: title, date: iso(date), time: time, label: label(date, today, time) }
}

function label(date, today, time) {
  var diff = Math.round((date - today) / 86400000)
  var text = diff === 0 ? "hoy" : diff === 1 ? "mañana" : diff === 2 ? "pasado mañana"
    : DAY_NAMES[date.getDay()] + " " + date.getDate() + " " + MONTH_NAMES[date.getMonth()]
  if (diff > 0 && diff <= 2) text += " (" + DAY_NAMES[date.getDay()] + " " + date.getDate() + ")"
  if (date.getFullYear() !== today.getFullYear()) text += " " + date.getFullYear()
  return time ? text + " · " + time : text
}
