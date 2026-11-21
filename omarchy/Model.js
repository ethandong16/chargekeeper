// Pure helpers for the Battery Care plugin. Keep this file free of QML so the
// panel and the tests can share it.

var MODES = ["Fast", "Standard", "Long_Life"]

// `charge_types` looks like "Fast [Standard] Long_Life": every supported mode
// is listed, the active one is bracketed. Some drivers omit the brackets when
// no mode is selected; then mode is "" and the panel shows the raw state.
function parseChargeTypes(text) {
  var raw = String(text === undefined || text === null ? "" : text).trim()
  var available = []
  var active = ""
  if (raw === "") return { mode: "", available: available }

  var tokens = raw.split(/\s+/)
  for (var i = 0; i < tokens.length; i++) {
    var token = tokens[i]
    if (token === "") continue
    var bracketed = token.charAt(0) === "[" && token.charAt(token.length - 1) === "]"
    var name = bracketed ? token.slice(1, token.length - 1) : token
    if (MODES.indexOf(name) === -1) continue
    if (available.indexOf(name) === -1) available.push(name)
    if (bracketed) active = name
  }
  return { mode: active, available: available }
}

function isMode(value) {
  return MODES.indexOf(String(value === undefined || value === null ? "" : value)) !== -1
}

function glyphFor(mode) {
  if (mode === "Fast") return "󰂅"
  if (mode === "Long_Life") return "󰁹"
  return "󰂄"
}

// The built-in power widget already uses a battery glyph and the percentage.
// The bar entry uses a heart so the two do not read as the same control.
function barGlyph() {
  return ""
}

// Right-click only walks the two modes that never need root.
function nextCareMode(mode) {
  return mode === "Long_Life" ? "Standard" : "Long_Life"
}

function safeNativePath(value) {
  var path = String(value === undefined || value === null ? "" : value)
  return /^[A-Za-z0-9._-]+$/.test(path) ? path : ""
}

function fraction(device) {
  if (!device || !device.isPresent) return 0
  var value = Number(device.percentage)
  if (!isFinite(value)) return 0
  return Math.max(0, Math.min(1, value))
}

function percent(device) {
  return Math.round(fraction(device) * 100)
}

// UPower's device state is an enum; compare through the values QML injects so
// the names survive a Quickshell update.
function stateKey(state, states) {
  var s = states || {}
  if (state === s.Charging) return "charging"
  if (state === s.Discharging) return "discharging"
  if (state === s.FullyCharged) return "full"
  if (state === s.PendingCharge) return "pending"
  if (state === s.Empty) return "empty"
  return "unknown"
}

function formatWatts(value) {
  var watts = Number(value)
  if (!isFinite(watts) || watts === 0) return ""
  return (Math.round(Math.abs(watts) * 10) / 10).toFixed(1) + " W"
}

function formatDuration(seconds) {
  var value = Number(seconds)
  if (!isFinite(value) || value <= 0) return ""
  if (value < 60) return "<1 min"
  var minutes = Math.round(value / 60)
  if (minutes < 60) return minutes + " min"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  return rest === 0 ? hours + " h" : hours + " h " + rest + " min"
}

if (typeof module !== "undefined") {
  module.exports = {
    MODES: MODES,
    parseChargeTypes: parseChargeTypes,
    isMode: isMode,
    glyphFor: glyphFor,
    barGlyph: barGlyph,
    nextCareMode: nextCareMode,
    safeNativePath: safeNativePath,
    fraction: fraction,
    percent: percent,
    stateKey: stateKey,
    formatWatts: formatWatts,
    formatDuration: formatDuration
  }
}
