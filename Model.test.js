// Tests unitaires du Model — exécuter avec : node Model.test.js
const Model = require("./Model.js")

let failures = 0

function check(name, actual, expected) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) {
    console.log("ok   " + name)
  } else {
    failures++
    console.log("FAIL " + name + "\n     got:  " + a + "\n     want: " + e)
  }
}

// ---- seuils ----
check("clampStart 40 -> 50", Model.dellClampStart(40), 50)
check("clampStart 50 -> 50", Model.dellClampStart(50), 50)
check("clampStart 95 -> 95", Model.dellClampStart(95), 95)
check("clampStart 100 -> 95", Model.dellClampStart(100), 95)
check("clampStart NaN -> 50", Model.dellClampStart("x"), 50)

check("clampEnd 40 (start 50) -> 55", Model.dellClampEnd(40, 50), 55)
check("clampEnd 55 -> 55", Model.dellClampEnd(55, 50), 55)
check("clampEnd 90 -> 90", Model.dellClampEnd(90, 50), 90)
check("clampEnd 100 -> 100", Model.dellClampEnd(100, 50), 100)
check("clampEnd 101 -> 100", Model.dellClampEnd(101, 50), 100)
check("clampEnd invariant start 95 -> 100", Model.dellClampEnd(95, 95), 100)
check("clampEnd invariant start 100 -> 100", Model.dellClampEnd(80, 100), 100)

check("stepStart +5 (90) -> 95", Model.dellStepStart(90, 1, 5), 95)
check("stepStart +5 (95) -> 95", Model.dellStepStart(95, 1, 5), 95)
check("stepStart -5 (50) -> 50", Model.dellStepStart(50, -1, 5), 50)
check("stepStart -5 (80) -> 75", Model.dellStepStart(80, -1, 5), 75)

check("stepEnd +5 (90) -> 95", Model.dellStepEnd(90, 50, 1, 5), 95)
check("stepEnd +5 (100) -> 100", Model.dellStepEnd(100, 50, 1, 5), 100)
check("stepEnd -5 (60, start 55) -> 60 (plancher)", Model.dellStepEnd(60, 55, -1, 5), 60)
check("stepEnd -5 (60, start 50) -> 55", Model.dellStepEnd(60, 50, -1, 5), 55)
check("stepEnd +5 (80, start 95) -> 100", Model.dellStepEnd(80, 95, 1, 5), 100)

// ---- parseDellStatus ----
check("parse vide -> null", Model.parseDellStatus(""), null)
check("parse non-JSON -> null", Model.parseDellStatus("nope"), null)
check("parse ok:false -> null", Model.parseDellStatus('{"ok":false,"error":"x"}'), null)

const full = Model.parseDellStatus(
  '{"ok":true,"dell":true,"source":"live","thresholds":{"start":50,"end":90},' +
  '"wmi":{"mode":"Custom","llc":"Disabled","usbPowerShare":"Disabled",' +
  '"typeCPower":"7.5W","peakShift":"Disabled","advBatteryCharge":"Disabled"}}'
)
check("parse plein ok", full.ok, true)
check("parse plein dell", full.dell, true)
check("parse plein start", full.start, 50)
check("parse plein mode", full.mode, "Custom")
check("parse plein hasWmi", full.hasWmi, true)
check("parse plein hasThresholds", full.hasThresholds, true)

const noBattery = Model.parseDellStatus('{"ok":true,"dell":true,"thresholds":{"start":null,"end":null},"wmi":{}}')
check("parse sans batterie hasThresholds", noBattery.hasThresholds, false)
check("parse sans batterie hasWmi", noBattery.hasWmi, false)

// ---- parsePowerChain ----
check("chain vide -> null", Model.parsePowerChain(""), null)
check("chain non-JSON -> null", Model.parsePowerChain("nope"), null)
const chain = Model.parsePowerChain(
  '{"source":"mains","usbType":"","batteryW":8.8,"systemW":20.7,"componentsW":11.9}'
)
check("chain source", chain.source, "mains")
check("chain batteryW", chain.batteryW, 8.8)
check("chain componentsW", chain.componentsW, 11.9)
const chainNulls = Model.parsePowerChain('{"source":"battery","batteryW":-10.2,"systemW":null,"componentsW":null}')
check("chain nulls", chainNulls.systemW, null)
check("chain battery source", chainNulls.source, "battery")

// ---- timeToThresholdText ----
check("t2t 70% @67% 29Wh 15.9W -> 3m", Model.timeToThresholdText(70, 0.67, 29, 15.9), "3m")
check("t2t 80% @50% 60Wh 60W -> 18m", Model.timeToThresholdText(80, 0.5, 60, 60), "18m")
check("t2t 80% @50% 60Wh 6W -> 3h 0m", Model.timeToThresholdText(80, 0.5, 60, 6), "3h 0m")
check("t2t au-dessus du seuil -> vide", Model.timeToThresholdText(70, 0.75, 60, 10), "")
check("t2t taux nul -> vide", Model.timeToThresholdText(70, 0.6, 60, 0), "")
check("t2t NaN -> vide", Model.timeToThresholdText(70, 0.6, NaN, 10), "")
check("t2t <1m", Model.timeToThresholdText(70, 0.699, 29, 60), "<1m")

// ---- non régression de la base ----
check("parseKeyValue tab", Model.parseKeyValue("size\t57 Wh\ncycles\t0"), { size: "57 Wh", cycles: "0" })
check("parseProfiles", Model.parseProfiles("balanced\t1\nperformance\t0", 0),
  { profiles: ["balanced", "performance"], activeProfile: "balanced", profileIndex: 0 })
check("clampIndex 5/3", Model.clampIndex(5, 3), 2)
check("clampIndex -2/3", Model.clampIndex(-2, 3), 0)

if (failures > 0) {
  console.log("\n" + failures + " échec(s)")
  process.exit(1)
}
console.log("\nTous les tests passent.")
