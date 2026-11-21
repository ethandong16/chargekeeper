const assert = require("node:assert/strict")
const test = require("node:test")
const Model = require("../Model.js")

test("reads the active charge mode from the bracketed token", () => {
  assert.deepEqual(Model.parseChargeTypes("Fast [Standard] Long_Life\n"), {
    mode: "Standard",
    available: ["Fast", "Standard", "Long_Life"]
  })
  assert.deepEqual(Model.parseChargeTypes("Fast Standard [Long_Life]"), {
    mode: "Long_Life",
    available: ["Fast", "Standard", "Long_Life"]
  })
  assert.deepEqual(Model.parseChargeTypes("[Fast] Standard Long_Life"), {
    mode: "Fast",
    available: ["Fast", "Standard", "Long_Life"]
  })
})

test("survives missing, unknown, or unbracketed charge_types output", () => {
  assert.deepEqual(Model.parseChargeTypes(""), { mode: "", available: [] })
  assert.deepEqual(Model.parseChargeTypes("Fast Standard Long_Life"), {
    mode: "",
    available: ["Fast", "Standard", "Long_Life"]
  })
  assert.deepEqual(Model.parseChargeTypes("Trickle [Bypass]"), { mode: "", available: [] })
})

test("right click never selects Fast", () => {
  assert.equal(Model.nextCareMode("Standard"), "Long_Life")
  assert.equal(Model.nextCareMode("Long_Life"), "Standard")
  assert.equal(Model.nextCareMode("Fast"), "Long_Life")
  assert.equal(Model.nextCareMode(""), "Long_Life")
})

test("glyphs distinguish all three modes", () => {
  const glyphs = Model.MODES.map(Model.glyphFor)
  assert.equal(new Set(glyphs).size, Model.MODES.length)
})

test("native paths are limited to the sysfs name alphabet", () => {
  assert.equal(Model.safeNativePath("BAT1"), "BAT1")
  assert.equal(Model.safeNativePath("battery_macsmc"), "battery_macsmc")
  assert.equal(Model.safeNativePath("../BAT1"), "")
  assert.equal(Model.safeNativePath("BAT1/charge_types"), "")
  assert.equal(Model.safeNativePath(""), "")
})

test("percentage and watts are clamped and rounded for display", () => {
  assert.equal(Model.percent({ isPresent: true, percentage: 0.844 }), 84)
  assert.equal(Model.percent({ isPresent: true, percentage: 0.7 }), 70)
  assert.equal(Model.percent({ isPresent: false, percentage: 0.7 }), 0)
  assert.equal(Model.percent({ isPresent: true, percentage: 2 }), 100)
  assert.equal(Model.percent({ isPresent: true, percentage: -1 }), 0)

  assert.equal(Model.formatWatts(58.888), "58.9 W")
  assert.equal(Model.formatWatts(-12), "12.0 W")
  assert.equal(Model.formatWatts(0), "")
  assert.equal(Model.formatWatts("nope"), "")
})

test("durations read naturally around the hour boundaries", () => {
  assert.equal(Model.formatDuration(0), "")
  assert.equal(Model.formatDuration(30), "<1 min")
  assert.equal(Model.formatDuration(90), "2 min")
  assert.equal(Model.formatDuration(3600), "1 h")
  assert.equal(Model.formatDuration(3660), "1 h 1 min")
  assert.equal(Model.formatDuration(773), "13 min")
})

test("state names follow the injected UPower enum", () => {
  const states = { Charging: 1, Discharging: 2, FullyCharged: 4, PendingCharge: 5, Empty: 3 }
  assert.equal(Model.stateKey(1, states), "charging")
  assert.equal(Model.stateKey(2, states), "discharging")
  assert.equal(Model.stateKey(4, states), "full")
  assert.equal(Model.stateKey(5, states), "pending")
  assert.equal(Model.stateKey(3, states), "empty")
  assert.equal(Model.stateKey(99, states), "unknown")
})
