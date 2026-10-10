// Z13 clone of Omarchy's omarchy.battery service (plugins/services/battery).
//
// Upstream calls `omarchy-powerprofiles-set ac|battery` on every
// UPower.onBatteryChanged. On the ROG Flow Z13 the EC toggles AC0.online
// spuriously while charging — a few times per few minutes near full charge,
// and at ~1 Hz under heavy load on an under-rated (140 W) supply. Each toggle
// flipped the platform profile Performance <-> Balanced, and asusd rewrote the
// fan curve on every flip.
//
// The only change from upstream: the profile switch is applied once
// UPower.onBattery has held one value for `powerSourceSettleMs`, and only if
// that settled source differs from the one last applied. A flap that returns to
// where it started is a no-op; a real plug/unplug lands after the settle time.
// The low-battery warning is unchanged and still reacts immediately.
//
// upstream.sha256 next to this file records the upstream revision this clone
// was taken from; phase 3 warns when Omarchy ships a different one.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "BatteryModel.js" as BatteryModel

Item {
  id: root

  property var shell: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property int batteryThreshold: 10
  readonly property int powerSourceSettleMs: 5000
  property string pendingPowerSource: ""
  // Boot already applied the right profile (omarchy-powerprofiles-init), so the
  // source current at load is treated as applied. Assigned imperatively in
  // Component.onCompleted: a declarative binding would track UPower.onBattery
  // and make every change look already-applied.
  property string appliedPowerSource: ""

  Component.onCompleted: {
    appliedPowerSource = currentPowerSource()
    log("loaded; power source " + appliedPowerSource + ", settle " + powerSourceSettleMs + " ms")
  }

  PersistentProperties {
    id: persisted
    reloadableId: "omarchy-battery"
    property bool notifiedLowBattery: false
  }

  // Plugin console output is not forwarded to the journal, so decisions are
  // logged via logger(1) under the z13-battery tag (argv, no shell). The
  // validation script counts these.
  function log(message) {
    Quickshell.execDetached(["logger", "-t", "z13-battery", message])
  }

  function currentPowerSource() {
    return UPower.onBattery ? "battery" : "ac"
  }

  function batteryPercentage() {
    return BatteryModel.batteryPercentage(UPower.displayDevice)
  }

  function isDischarging() {
    return BatteryModel.isDischarging(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging)
  }

  function checkBattery() {
    var state = BatteryModel.shouldWarnLowBattery(UPower.displayDevice, UPower.onBattery, UPowerDeviceState.Discharging, batteryThreshold, persisted.notifiedLowBattery)
    persisted.notifiedLowBattery = state.notifiedLowBattery
    if (state.notify) sendLowBatteryWarning(state.level)
  }

  function sendLowBatteryWarning(level) {
    if (warningProcess.running) return
    warningProcess.command = [
      "omarchy-battery-low",
      String(level)
    ]
    warningProcess.running = true
  }

  function applyPowerProfile() {
    var source = currentPowerSource()
    if (source === appliedPowerSource) {
      log("power source settled back on " + source + "; profile left unchanged")
      return
    }
    log("power source settled on " + source + "; applying profile")
    appliedPowerSource = source
    pendingPowerSource = source
    if (!powerProfileProcess.running) runPendingPowerProfile()
  }

  function runPendingPowerProfile() {
    powerProfileProcess.command = ["omarchy-powerprofiles-set", pendingPowerSource]
    pendingPowerSource = ""
    powerProfileProcess.running = true
  }

  Process { id: warningProcess }

  Process {
    id: powerProfileProcess
    onExited: if (root.pendingPowerSource !== "") root.runPendingPowerProfile()
  }

  Timer {
    id: powerSourceSettle
    interval: root.powerSourceSettleMs
    repeat: false
    onTriggered: root.applyPowerProfile()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkBattery()
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      root.checkBattery()
      powerSourceSettle.restart()
    }
  }
}
