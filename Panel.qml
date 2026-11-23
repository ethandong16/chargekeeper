import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "Policy.js" as Policy

// ChargeKeeper: the charge mode lives in the EC, so the file is the source of
// truth. Standard and Long_Life go through UPower (passwordless polkit
// action); Fast needs the small root helper, because UPower has no Fast verb.
Panel {
  id: root
  moduleName: "io.github.ethandong16.chargekeeper"
  ipcTarget: "io.github.ethandong16.chargekeeper"
  manageIpc: false

  LayoutMirroring.enabled: Commons.I18n.rightToLeft
  LayoutMirroring.childrenInherit: true

  readonly property var device: UPower.displayDevice
  readonly property bool batteryPresent: !!(device && device.isPresent)
  readonly property real fraction: Model.fraction(device)
  readonly property bool onAc: !UPower.onBattery
  readonly property bool showLabel: setting("showLabel", false) === true

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/chargekeeper/config.json"
  readonly property string overridePath: home + "/.local/state/chargekeeper/manual-until"
  readonly property string helperPath: "/usr/lib/chargekeeper/chargekeeper-helper"
  readonly property string batteryName: {
    var name = device ? Model.safeNativePath(device.nativePath) : ""
    return name === "" ? "BAT1" : name
  }
  readonly property string modePath: "/sys/class/power_supply/" + batteryName + "/charge_types"

  property string mode: ""
  property var available: []
  property bool modeLoaded: false
  property bool fastAvailable: false
  property var config: Policy.normalizeConfig(null)
  property bool applying: false
  property string pendingMode: ""
  property string errorText: ""
  property bool cursorActive: false
  property int selectedIndex: 0
  property bool modeQueued: false

  readonly property var modeOrder: Model.MODES

  function states() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge,
      Empty: UPowerDeviceState.Empty
    }
  }

  function stateKey() {
    return Model.stateKey(device ? device.state : -1, states())
  }

  function statusText() {
    if (!batteryPresent) return strings.t("status.noBattery")
    if (!modeLoaded) return strings.t("status.reading")
    var parts = [Math.round(fraction * 100) + "%", strings.t("status." + stateKey())]
    parts.push(strings.t(onAc ? "status.onAc" : "status.onBattery"))
    return parts.join(" · ")
  }

  function modeTitle(value) {
    return strings.t("mode." + value)
  }

  function modeShort() {
    if (!Model.isMode(mode)) return ""
    return strings.t("short." + mode)
  }

  function cleanError(text) {
    var value = String(text === undefined || text === null ? "" : text).trim()
    if (value.length > 240) value = value.slice(0, 240) + "…"
    return value
  }

  function rateText() {
    return Model.formatWatts(device ? device.changeRate : 0)
  }

  function timeText() {
    if (!batteryPresent) return ""
    var state = stateKey()
    if (state === "charging" && device.timeToFull > 0)
      return strings.t("info.untilFull").arg(Model.formatDuration(device.timeToFull))
    if (state === "discharging" && device.timeToEmpty > 0)
      return strings.t("info.untilEmpty").arg(Model.formatDuration(device.timeToEmpty))
    return ""
  }

  function autoText() {
    var c = config
    if (!c.enabled) return strings.t("auto.off")
    var text = strings.t("auto.ac").arg(modeTitle(c.acMode)).arg(c.acDelayMinutes)
    text += " · " + strings.t("auto.battery").arg(modeTitle(c.batteryMode))
    if (Policy.parseClock(c.nightStart) >= 0 && Policy.parseClock(c.nightEnd) >= 0) {
      text += " · " + strings.t("auto.night").arg(c.nightStart).arg(c.nightEnd).arg(modeTitle("Long_Life"))
    }
    return text
  }

  function readMode() {
    if (modeProc.running) {
      modeQueued = true
      return
    }
    modeQueued = false
    modeProc.running = true
  }

  function applyModeText(text) {
    var parsed = Model.parseChargeTypes(text)
    mode = parsed.mode
    available = parsed.available
    modeLoaded = true
    if (modeQueued) {
      modeQueued = false
      Qt.callLater(root.readMode)
    }
  }

  function readConfig() {
    configProc.running = true
  }

  function markManual() {
    var minutes = Number(config.manualMinutes)
    if (!isFinite(minutes) || minutes <= 0) return
    var until = Math.floor(Date.now() / 1000) + Math.round(minutes * 60)
    // Fixed script; the path and the epoch are arguments, never interpolated.
    var script = 'd=${1%/*}; mkdir -p "$d" && printf "%s\\n" "$2" > "$1"'
    Quickshell.execDetached(["bash", "-c", script, "chargekeeper", root.overridePath, String(until)])
  }

  function applyMode(target) {
    if (!Model.isMode(target)) {
      errorText = strings.t("error.invalid")
      return
    }
    if (!batteryPresent) {
      errorText = strings.t("error.noBattery")
      return
    }
    if (target === "Fast" && !fastAvailable) {
      errorText = strings.t("error.fastUnavailable")
      return
    }
    if (available.length > 0 && available.indexOf(target) === -1) {
      errorText = strings.t("error.unsupported").arg(target)
      return
    }
    if (target === mode && !applying) return

    errorText = ""
    applying = true
    pendingMode = target

    if (target === "Fast") {
      actionProc.command = ["sudo", "-n", root.helperPath, "mode", root.batteryName, "Fast"]
    } else {
      actionProc.command = [
        "busctl", "call", "org.freedesktop.UPower",
        "/org/freedesktop/UPower/devices/battery_" + batteryName,
        "org.freedesktop.UPower.Device", "EnableChargeThreshold", "b",
        target === "Long_Life" ? "true" : "false"
      ]
    }
    actionProc.running = true
  }

  function cycle() {
    if (!batteryPresent) {
      open()
      return
    }
    applyMode(Model.nextCareMode(mode))
  }

  function moveCursor(delta) {
    cursorActive = true
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > modeOrder.length - 1) next = modeOrder.length - 1
    selectedIndex = next
  }

  function applySelected() {
    if (!cursorActive) {
      cursorActive = true
      return
    }
    applyMode(modeOrder[selectedIndex])
  }

  function statusJson() {
    return JSON.stringify({
      mode: mode,
      available: available,
      percentage: batteryPresent ? Math.round(fraction * 100) : 0,
      onAc: onAc,
      state: stateKey(),
      fastAvailable: fastAvailable
    })
  }

  onOpenedChanged: {
    if (!opened) return
    errorText = ""
    cursorActive = false
    readMode()
    readConfig()
    var index = modeOrder.indexOf(mode)
    selectedIndex = index >= 0 ? index : 0
  }

  Component.onCompleted: {
    readMode()
    readConfig()
    fastProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.readMode()
  }

  Timer {
    id: settleTimer
    interval: 450
    onTriggered: root.readMode()
  }

  Process {
    id: modeProc
    command: ["cat", root.modePath]
    stdout: StdioCollector { id: modeOut; waitForEnd: true }
    stderr: StdioCollector { id: modeErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyModeText(modeOut.text)
      else root.modeLoaded = false
    }
  }

  Process {
    id: configProc
    command: ["cat", root.configPath]
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    stderr: StdioCollector { id: configErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.config = Policy.normalizeConfig(null)
        return
      }
      var parsed = null
      try {
        parsed = JSON.parse(configOut.text)
      } catch (error) {
        parsed = null
      }
      root.config = Policy.normalizeConfig(parsed)
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applying = false
      root.pendingMode = ""
      if (exitCode !== 0) {
        root.errorText = strings.t("error.action").arg(
          root.cleanError(actionErr.text) || strings.t("error.unknown"))
        return
      }
      root.errorText = ""
      root.markManual()
      settleTimer.restart()
    }
  }

  Process {
    id: fastProc
    command: ["sudo", "-n", "-l", root.helperPath, "mode", root.batteryName, "Fast"]
    stdout: StdioCollector { id: fastOut; waitForEnd: true }
    stderr: StdioCollector { id: fastErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.fastAvailable = exitCode === 0
    }
  }

  ShellIpc {
    target: "io.github.ethandong16.chargekeeper"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function setFast() { root.applyMode("Fast") }
    function setStandard() { root.applyMode("Standard") }
    function setLongLife() { root.applyMode("Long_Life") }
    function cycle() { root.cycle() }
    function refresh() { root.readMode(); root.readConfig() }
    function status() { return root.statusJson() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barGlyph()
    labelText: root.showLabel && root.batteryPresent ? root.modeShort() : ""
    slotSize: root.barVertical || button.labelText === "" ? Style.bar.iconSlot : Style.bar.iconSlot * 2
    dimmed: !root.batteryPresent
    tooltipText: root.statusText()

    onPressed: function(clickedButton) {
      if (clickedButton === Qt.MiddleButton) root.readMode()
      else if (clickedButton === Qt.RightButton) root.cycle()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(620))

    content: PanelKeyCatcher {
      id: keyCatcher
      implicitHeight: contentColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: root.applySelected()
      onCloseRequested: root.close()
      onTextKey: function(text, modifiers) {
        if (text >= "1" && text <= "3") {
          var value = root.modeOrder[Number(text) - 1]
          if (value) root.applyMode(value)
        } else if (text === "r" || text === "R") {
          root.readMode()
          root.readConfig()
        }
      }

      Column {
        id: contentColumn
        width: keyCatcher.width
        spacing: Style.space(10)

        Item {
          width: parent.width
          implicitHeight: Math.max(headerIcon.implicitHeight, headerLabels.implicitHeight)

          Text {
            id: headerIcon
            textFormat: Text.PlainText
            text: Model.glyphFor(root.mode)
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: headerLabels
            anchors.left: headerIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: strings.t("title")
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusText()
              color: Qt.darker(root.barForeground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        Rectangle {
          width: parent.width
          height: Style.spacing.hairline
          color: root.barForeground
          opacity: 0.12
        }

        Row {
          width: parent.width
          spacing: Style.space(18)
          visible: root.rateText() !== "" || root.timeText() !== ""

          Text {
            textFormat: Text.PlainText
            visible: root.rateText() !== ""
            text: strings.t("info.rate").arg(root.rateText())
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            visible: root.timeText() !== ""
            text: root.timeText()
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        Repeater {
          model: root.modeOrder

          delegate: Rectangle {
            id: modeRow
            required property var modelData
            required property int index

            readonly property bool usable: root.batteryPresent && !root.applying
              && (modelData !== "Fast" || root.fastAvailable)

            width: parent.width
            height: modeTitleText.implicitHeight + Style.space(20)
            radius: Style.cornerRadius
            opacity: usable ? 1 : 0.45
            color: modeMouse.containsMouse && modeMouse.enabled
              ? Style.hoverFillFor(root.barForeground, Commons.Color.accent)
              : "transparent"
            border.width: root.mode === modelData ? Math.max(1, Style.space(1)) : 0
            border.color: Commons.Color.accent

            Item {
              anchors.fill: parent
              anchors.margins: Style.space(10)

              Text {
                id: modeKey
                textFormat: Text.PlainText
                text: index + 1
                color: Qt.darker(root.barForeground, 1.5)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: modeMark
                textFormat: Text.PlainText
                text: root.applying && root.pendingMode === modelData
                  ? "…"
                  : (root.mode === modelData ? "✓" : "")
                color: Commons.Color.accent
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: modeTitleText
                textFormat: Text.PlainText
                text: root.modeTitle(modelData)
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                font.bold: root.mode === modelData
                elide: Text.ElideRight
                anchors.left: modeKey.right
                anchors.right: modeMark.left
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            MouseArea {
              id: modeMouse
              anchors.fill: parent
              enabled: modeRow.usable
              hoverEnabled: true
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.applyMode(modeRow.modelData)
            }
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.autoText()
          color: Qt.darker(root.barForeground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.errorText !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.errorText
          color: Commons.Color.urgent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: strings.t("hint")
          color: Qt.darker(root.barForeground, 1.6)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
