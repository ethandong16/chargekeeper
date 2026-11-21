import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "Model.js" as Model
import "Policy.js" as Policy

// Applies the configured policy on AC/battery transitions, a night window, and
// a once-a-minute tick. It never uses Fast: that needs the root helper and is
// a deliberate user action from the panel.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/chargekeeper/config.json"
  readonly property string overridePath: home + "/.local/state/chargekeeper/manual-until"
  readonly property string batteryName: {
    var name = UPower.displayDevice ? Model.safeNativePath(UPower.displayDevice.nativePath) : ""
    return name === "" ? "BAT1" : name
  }

  property var config: Policy.normalizeConfig(null)
  property string mode: ""
  property bool modeLoaded: false
  property real manualUntil: 0
  property double acSince: 0
  property bool applying: false
  property bool refreshing: false
  property bool refreshQueued: false

  readonly property bool present: !!(UPower.displayDevice && UPower.displayDevice.isPresent)

  function nowEpoch() {
    return Math.floor(Date.now() / 1000)
  }

  function acElapsedMinutes() {
    if (UPower.onBattery || !acSince) return 0
    return (nowEpoch() - acSince) / 60
  }

  function refresh() {
    if (refreshing) {
      refreshQueued = true
      return
    }
    refreshQueued = false
    refreshing = true
    configProc.running = true
  }

  function evaluate() {
    if (applying || !modeLoaded || !present) return
    var decision = Policy.decide({
      config: config,
      mode: mode,
      onAc: !UPower.onBattery,
      acElapsedMinutes: acElapsedMinutes(),
      nowMinutes: Policy.minutesNow(new Date()),
      nowEpoch: nowEpoch(),
      manualUntil: manualUntil
    })
    if (decision.mode !== "" && decision.mode !== mode) apply(decision.mode)
  }

  function apply(target) {
    if (target !== "Standard" && target !== "Long_Life") return
    applying = true
    actionProc.command = [
      "busctl", "call", "org.freedesktop.UPower",
      "/org/freedesktop/UPower/devices/battery_" + batteryName,
      "org.freedesktop.UPower.Device", "EnableChargeThreshold", "b",
      target === "Long_Life" ? "true" : "false"
    ]
    actionProc.running = true
  }

  Component.onCompleted: {
    if (!UPower.onBattery) acSince = nowEpoch()
    refresh()
  }

  Connections {
    target: UPower

    function onOnBatteryChanged() {
      root.acSince = UPower.onBattery ? 0 : root.nowEpoch()
      root.refresh()
    }
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: settleTimer
    interval: 600
    onTriggered: root.refresh()
  }

  Process {
    id: configProc
    command: ["cat", root.configPath]
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    stderr: StdioCollector { id: configErr; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = null
      if (exitCode === 0) {
        try {
          parsed = JSON.parse(configOut.text)
        } catch (error) {
          parsed = null
        }
      }
      root.config = Policy.normalizeConfig(parsed)
      modeProc.running = true
    }
  }

  Process {
    id: modeProc
    command: ["cat", "/sys/class/power_supply/" + root.batteryName + "/charge_types"]
    stdout: StdioCollector { id: modeOut; waitForEnd: true }
    stderr: StdioCollector { id: modeErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.mode = Model.parseChargeTypes(modeOut.text).mode
        root.modeLoaded = true
      } else {
        root.modeLoaded = false
      }
      overrideProc.running = true
    }
  }

  Process {
    id: overrideProc
    command: ["cat", root.overridePath]
    stdout: StdioCollector { id: overrideOut; waitForEnd: true }
    stderr: StdioCollector { id: overrideErr; waitForEnd: true }
    onExited: function(exitCode) {
      var value = 0
      if (exitCode === 0) {
        var parsed = Number(String(overrideOut.text).trim())
        if (isFinite(parsed)) value = parsed
      }
      root.manualUntil = value
      root.refreshing = false
      root.evaluate()
      if (root.refreshQueued) {
        root.refreshQueued = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applying = false
      if (exitCode !== 0) {
        console.warn("chargekeeper: could not set charge mode: " + String(actionErr.text).trim())
        return
      }
      settleTimer.restart()
    }
  }
}
