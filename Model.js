function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return next
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    list.push(parts[0])
    if (parts[1] === "1") active = parts[0]
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  }
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery)) return false

  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))
  var threshold = chargeThresholdActive(d, onBattery, states)

  if (threshold) return defaultIcons[index]
  if (d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return chargingIcons[index]
  return defaultIcons[index]
}

function modeLabel(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var percentage = d.isPresent ? d.percentage : 0
  if (chargeThresholdActive(d, onBattery, states)) return "Threshold"
  if (onBattery) return "On battery"
  if (!onBattery && percentage >= 1) return "Fully charged"
  return "Charging"
}

// ---- Dell charge-limit helpers -------------------------------------------
// Threshold constraints discovered on the Latitude 7390 EC:
//   start 50–95, end 55–100, end >= start + 5

const DELL_START_MIN = 50
const DELL_START_MAX = 95
const DELL_END_MIN = 55
const DELL_END_MAX = 100
const DELL_GAP = 5

const DELL_MODES = ["Standard", "Express", "Adaptive", "PrimAcUse", "Custom"]

const DELL_MODE_INFO = {
  Standard: "Charges to 100% at normal rate",
  Express: "Fast charge to 100%",
  Adaptive: "100% based on usage patterns (learning)",
  PrimAcUse: "Primary AC use — reduced ceiling",
  Custom: "Applies your charge thresholds (start → stop)"
}

function dellClampStart(value) {
  var v = Math.round(Number(value))
  if (!isFinite(v)) return DELL_START_MIN
  return Math.max(DELL_START_MIN, Math.min(DELL_START_MAX, v))
}

function dellClampEnd(value, start) {
  var v = Math.round(Number(value))
  if (!isFinite(v)) return DELL_END_MAX
  var floor = Math.max(DELL_END_MIN, dellClampStart(start) + DELL_GAP)
  return Math.max(floor, Math.min(DELL_END_MAX, v))
}

function dellStepStart(value, delta, step) {
  return dellClampStart(dellClampStart(value) + delta * step)
}

// Steps the end threshold while preserving end >= start + 5. Returns the
// requested stepped value clamped so that the invariant always holds.
function dellStepEnd(value, start, delta, step) {
  var cur = dellClampEnd(value, start)
  return dellClampEnd(cur + delta * step, start)
}

// Estimated time until the battery reaches the stop threshold while charging.
// Returns "" when the estimate is not meaningful (above the threshold,
// no meaningful rate, missing inputs).
function timeToThresholdText(endPercent, fraction, sizeWh, rateW) {
  var end = Number(endPercent)
  var frac = Number(fraction)
  var size = Number(sizeWh)
  var rate = Number(rateW)
  if (!isFinite(end) || !isFinite(frac) || !isFinite(size) || !isFinite(rate)) return ""
  if (frac >= end / 100) return ""
  if (rate <= 0.5) return ""
  if (size <= 0) return ""
  var minutes = Math.round((end / 100 - frac) * size / rate * 60)
  if (minutes < 1) return "<1m"
  if (minutes < 60) return minutes + "m"
  return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m"
}

// end for a given start, adjusted to preserve the invariant.
function dellEndForStart(start, end) {
  return dellClampEnd(end, start)
}

function parsePowerChain(raw) {
  var text = String(raw || "").trim()
  if (!text) return null
  var obj = null
  try {
    obj = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!obj || typeof obj.source !== "string") return null
  function num(v) {
    return typeof v === "number" && isFinite(v) ? v : null
  }
  return {
    source: obj.source,
    usbType: typeof obj.usbType === "string" ? obj.usbType : "",
    batteryW: num(obj.batteryW),
    systemW: num(obj.systemW),
    adapterW: num(obj.adapterW),
    componentsW: num(obj.componentsW),
    cpuW: num(obj.cpuW),
    ramW: num(obj.ramW),
    screenW: num(obj.screenW),
    igpuW: num(obj.igpuW),
    nominalWh: num(obj.nominalWh),
    portW: num(obj.portW),
    packV: num(obj.packV),
    packA: num(obj.packA)
  }
}

function parseDellStatus(raw) {
  var text = String(raw || "").trim()
  if (!text) return null
  var obj = null
  try {
    obj = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!obj || obj.ok !== true) return null
  var wmi = obj.wmi && typeof obj.wmi === "object" ? obj.wmi : {}
  var thresholds = obj.thresholds && typeof obj.thresholds === "object" ? obj.thresholds : {}
  var hasThresholds = typeof thresholds.start === "number" && typeof thresholds.end === "number"
  var hasWmi = typeof wmi.mode === "string"
  return {
    ok: true,
    dell: obj.dell === true,
    source: String(obj.source || "cache"),
    hasThresholds: hasThresholds,
    hasWmi: hasWmi,
    start: hasThresholds ? thresholds.start : -1,
    end: hasThresholds ? thresholds.end : -1,
    mode: typeof wmi.mode === "string" ? wmi.mode : "",
    llc: typeof wmi.llc === "string" ? wmi.llc : "",
    usbPowerShare: typeof wmi.usbPowerShare === "string" ? wmi.usbPowerShare : "",
    typeCPower: typeof wmi.typeCPower === "string" ? wmi.typeCPower : "",
    peakShift: typeof wmi.peakShift === "string" ? wmi.peakShift : "",
    advBatteryCharge: typeof wmi.advBatteryCharge === "string" ? wmi.advBatteryCharge : ""
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    parseKeyValue: parseKeyValue,
    parseProfiles: parseProfiles,
    profileIcon: profileIcon,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel,
    DELL_START_MIN: DELL_START_MIN,
    DELL_START_MAX: DELL_START_MAX,
    DELL_END_MIN: DELL_END_MIN,
    DELL_END_MAX: DELL_END_MAX,
    DELL_GAP: DELL_GAP,
    DELL_MODES: DELL_MODES,
    DELL_MODE_INFO: DELL_MODE_INFO,
    dellClampStart: dellClampStart,
    dellClampEnd: dellClampEnd,
    dellStepStart: dellStepStart,
    dellStepEnd: dellStepEnd,
    timeToThresholdText: timeToThresholdText,
    dellEndForStart: dellEndForStart,
    parseDellStatus: parseDellStatus,
    parsePowerChain: parsePowerChain
  }
}
