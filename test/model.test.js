#!/usr/bin/env node
// Model.js tests: the texts and the dots the bar paints.
// Run with: node test/model.test.js   (no dependencies, exit 1 on failure)

const Model = require("../Model.js")

let passed = 0
const failures = []

function check(name, condition, detail) {
  if (condition) {
    passed++
    return
  }
  failures.push(name + (detail === undefined ? "" : "  ->  " + JSON.stringify(detail)))
}

function eq(name, actual, expected) {
  check(name, JSON.stringify(actual) === JSON.stringify(expected), { actual: actual, expected: expected })
}

// ---- dots per list --------------------------------------------------------

const ITEMS = [
  { id: "a", listId: "L1", list: "Reminders", color: "#ffcc00", content: "Buy milk", due: "2026-10-12", time: "19:30", overdue: false },
  { id: "b", listId: "L2", list: "Home", color: "#3366ff", content: "Take the trash out", due: "2026-10-12", time: "", overdue: false },
  { id: "c", listId: "L1", list: "Reminders", color: "#ffcc00", content: "Pay the rent", due: "2026-10-11", time: "", overdue: true },
  { id: "d", listId: "L3", list: "No color", color: "", content: "Call the shop", due: "2026-10-12", time: "", overdue: false }
]

eq("one dot per list, in its color and with its count",
  Model.listDots(ITEMS, 4).map(d => [d.list, d.color, d.count]),
  [["Reminders", "#ffcc00", 2], ["Home", "#3366ff", 1], ["No color", "", 1]])
eq("the cap cuts the extra lists", Model.listDots(ITEMS, 2).map(d => d.list), ["Reminders", "Home"])
eq("no reminders, no dots", Model.listDots([], 4), [])

// ---- the bar label --------------------------------------------------------

const VIEW = { ok: true, loading: false, settled: true, items: ITEMS, total: ITEMS.length }
const VIEW_EMPTY = { ok: true, loading: false, settled: true, items: [], total: 0 }
const VIEW_LOADING = { ok: true, loading: true, settled: false, items: [], total: 0 }
const VIEW_BROKEN = { ok: false, loading: false, settled: true, items: [], total: 0, error: "needs-login" }
const NEXT_OPTS = { showNextItem: true, showNextTime: true, chars: 22 }

eq("the list glyph", Model.barGlyph(VIEW), Model.glyph.list)
eq("the alert glyph", Model.barGlyph(VIEW_BROKEN), Model.glyph.alert)
eq("the count", Model.barCount(VIEW), "4")
eq("the count at zero", Model.barCount(VIEW_EMPTY), "0")
eq("an ellipsis while loading", Model.barCount(VIEW_LOADING), "…")
eq("no session, no count", Model.barCount(VIEW_BROKEN), "")
eq("the next reminder", Model.barNext(VIEW, NEXT_OPTS), "19:30 - Buy milk")
eq("the next reminder can be turned off", Model.barNext(VIEW, { showNextItem: false }), "")
eq("nothing next when there is nothing", Model.barNext(VIEW_EMPTY, NEXT_OPTS), "")
eq("no session, no next reminder", Model.barNext(VIEW_BROKEN, NEXT_OPTS), "")
eq("something is overdue", Model.barUrgent(VIEW), true)
eq("nothing overdue, no urgency", Model.barUrgent({ ok: true, items: [ITEMS[0]], total: 1 }), false)

// ---- report ---------------------------------------------------------------

if (failures.length) {
  console.error("FAILED " + failures.length + " of " + (passed + failures.length) + " tests:\n")
  failures.forEach(f => console.error("  ✗ " + f))
  process.exit(1)
}
console.log("OK: " + passed + " model tests passed")
