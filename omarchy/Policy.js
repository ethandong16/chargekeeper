// Automatic charge policy. Pure functions; the service supplies the clock and
// the current mode, the tests supply everything else.

var DEFAULTS = {
  enabled: true,
  acMode: "Long_Life",
  batteryMode: "Standard",
  acDelayMinutes: 10,
  nightStart: "",
  nightEnd: "",
  manualMinutes: 120
}

var AUTO_MODES = ["Standard", "Long_Life"]

function isAutoMode(value) {
  return AUTO_MODES.indexOf(String(value === undefined || value === null ? "" : value)) !== -1
}

function parseClock(value) {
  var text = String(value === undefined || value === null ? "" : value).trim()
  var match = /^([01]?[0-9]|2[0-3]):([0-5][0-9])$/.exec(text)
  if (!match) return -1
  return Number(match[1]) * 60 + Number(match[2])
}

function minutesNow(date) {
  var d = date || new Date()
  return d.getHours() * 60 + d.getMinutes()
}

// A window may cross midnight: 22:30-07:00 is active at 23:00 and at 02:00.
function inWindow(now, start, end) {
  if (start < 0 || end < 0 || start === end) return false
  if (start < end) return now >= start && now < end
  return now >= start || now < end
}

function clamp(value, low, high, fallback) {
  var number = Number(value)
  if (!isFinite(number)) return fallback
  return Math.max(low, Math.min(high, Math.round(number)))
}

function normalizeConfig(raw) {
  var input = raw && typeof raw === "object" ? raw : {}
  return {
    enabled: input.enabled === undefined ? DEFAULTS.enabled : input.enabled === true,
    acMode: isAutoMode(input.acMode) ? String(input.acMode) : DEFAULTS.acMode,
    batteryMode: isAutoMode(input.batteryMode) ? String(input.batteryMode) : DEFAULTS.batteryMode,
    acDelayMinutes: clamp(input.acDelayMinutes, 0, 720, DEFAULTS.acDelayMinutes),
    nightStart: parseClock(input.nightStart) >= 0 ? String(input.nightStart).trim() : "",
    nightEnd: parseClock(input.nightEnd) >= 0 ? String(input.nightEnd).trim() : "",
    manualMinutes: clamp(input.manualMinutes, 0, 1440, DEFAULTS.manualMinutes)
  }
}

function decide(state) {
  var s = state || {}
  var config = normalizeConfig(s.config)

  if (!config.enabled) return { mode: "", reason: "disabled" }
  if (Number(s.manualUntil || 0) > Number(s.nowEpoch || 0)) return { mode: "", reason: "manual" }

  var now = Number(s.nowMinutes)
  if (!isFinite(now)) now = minutesNow()
  var nightStart = parseClock(config.nightStart)
  var nightEnd = parseClock(config.nightEnd)
  if (inWindow(now, nightStart, nightEnd)) {
    return desired(config, s.mode, "Long_Life", "night")
  }

  if (s.onAc) {
    if (Number(s.acElapsedMinutes || 0) < Number(config.acDelayMinutes || 0)) {
      return { mode: "", reason: "delay" }
    }
    return desired(config, s.mode, config.acMode, "ac")
  }

  return desired(config, s.mode, config.batteryMode, "battery")
}

function desired(config, mode, target, reason) {
  if (!isAutoMode(target)) return { mode: "", reason: "invalid" }
  if (mode === target) return { mode: "", reason: "" }
  return { mode: target, reason: reason }
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULTS: DEFAULTS,
    AUTO_MODES: AUTO_MODES,
    isAutoMode: isAutoMode,
    parseClock: parseClock,
    minutesNow: minutesNow,
    inWindow: inWindow,
    normalizeConfig: normalizeConfig,
    decide: decide
  }
}
