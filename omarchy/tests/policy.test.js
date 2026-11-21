const assert = require("node:assert/strict")
const test = require("node:test")
const Policy = require("../Policy.js")

function config(extra) {
  return Policy.normalizeConfig(Object.assign({}, extra || {}))
}

function state(extra) {
  return Object.assign({
    config: config(),
    mode: "Standard",
    onAc: true,
    acElapsedMinutes: 60,
    nowMinutes: 12 * 60,
    nowEpoch: 1000,
    manualUntil: 0
  }, extra || {})
}

test("clock parsing accepts only HH:MM", () => {
  assert.equal(Policy.parseClock("00:00"), 0)
  assert.equal(Policy.parseClock("7:05"), 7 * 60 + 5)
  assert.equal(Policy.parseClock("23:59"), 23 * 60 + 59)
  assert.equal(Policy.parseClock("24:00"), -1)
  assert.equal(Policy.parseClock("12:60"), -1)
  assert.equal(Policy.parseClock(""), -1)
})

test("night windows cross midnight", () => {
  assert.equal(Policy.inWindow(23 * 60, 22 * 60 + 30, 7 * 60), true)
  assert.equal(Policy.inWindow(2 * 60, 22 * 60 + 30, 7 * 60), true)
  assert.equal(Policy.inWindow(12 * 60, 22 * 60 + 30, 7 * 60), false)
  assert.equal(Policy.inWindow(12 * 60, 9 * 60, 17 * 60), true)
  assert.equal(Policy.inWindow(12 * 60, -1, 17 * 60), false)
  assert.equal(Policy.inWindow(12 * 60, 12 * 60, 12 * 60), false)
})

test("config defaults and rejects Fast as an automatic mode", () => {
  const defaults = Policy.normalizeConfig(null)
  assert.equal(defaults.enabled, true)
  assert.equal(defaults.acMode, "Long_Life")
  assert.equal(defaults.batteryMode, "Standard")
  assert.equal(defaults.acDelayMinutes, 10)

  const odd = Policy.normalizeConfig({ acMode: "Fast", batteryMode: "Trickle", acDelayMinutes: -5, manualMinutes: 9999 })
  assert.equal(odd.acMode, "Long_Life")
  assert.equal(odd.batteryMode, "Standard")
  assert.equal(odd.acDelayMinutes, 0)
  assert.equal(odd.manualMinutes, 1440)
})

test("disabled and manual override win over everything", () => {
  assert.deepEqual(Policy.decide(state({ config: config({ enabled: false }) })), { mode: "", reason: "disabled" })
  assert.deepEqual(Policy.decide(state({ manualUntil: 2000, nowEpoch: 1000 })), { mode: "", reason: "manual" })
})

test("AC waits for the configured delay, then applies acMode", () => {
  assert.deepEqual(Policy.decide(state({ acElapsedMinutes: 5 })), { mode: "", reason: "delay" })
  assert.deepEqual(Policy.decide(state({ acElapsedMinutes: 10 })), { mode: "Long_Life", reason: "ac" })
  assert.deepEqual(Policy.decide(state({ acElapsedMinutes: 60, mode: "Long_Life" })), { mode: "", reason: "" })
})

test("battery applies batteryMode and clears Long-life", () => {
  assert.deepEqual(Policy.decide(state({ onAc: false, mode: "Long_Life" })), {
    mode: "Standard",
    reason: "battery"
  })
  assert.deepEqual(Policy.decide(state({ onAc: false, mode: "Standard" })), { mode: "", reason: "" })
})

test("the night window enforces Long-life even before the AC delay", () => {
  const night = config({ nightStart: "22:30", nightEnd: "07:00" })
  assert.deepEqual(Policy.decide(state({
    config: night,
    acElapsedMinutes: 0,
    nowMinutes: 23 * 60
  })), { mode: "Long_Life", reason: "night" })

  assert.deepEqual(Policy.decide(state({
    config: night,
    onAc: false,
    mode: "Standard",
    nowMinutes: 2 * 60
  })), { mode: "Long_Life", reason: "night" })

  assert.deepEqual(Policy.decide(state({
    config: night,
    onAc: false,
    mode: "Long_Life",
    nowMinutes: 12 * 60
  })), { mode: "Standard", reason: "battery" })
})

test("a zero delay applies immediately on AC", () => {
  const immediate = config({ acDelayMinutes: 0 })
  assert.deepEqual(Policy.decide(state({ config: immediate, acElapsedMinutes: 0 })), {
    mode: "Long_Life",
    reason: "ac"
  })
})
