// Run with: node --test test/
// Model.js is a QML `.pragma library` script, so it is evaluated in a vm
// context here rather than imported.
process.env.TZ = "UTC"

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*$/m, "")
const Model = vm.createContext({})
vm.runInContext(source, Model)

const HOUR = 3600
// 2026-09-10 00:00 UTC
const MIDNIGHT = Date.UTC(2026, 8, 10) / 1000

function sample(t, p, s, full = 40) {
  return { t, p, e: (p / 100) * full, f: full, w: 4, s }
}

// Minute-by-minute readings from `start`, `count` long, changing by `step`% each.
function run(start, count, p0, step, s) {
  return Array.from({ length: count }, (_, i) => sample(start + i * 60, p0 + i * step, s))
}

function near(actual, expected, tolerance = 0.01) {
  assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} is not within ${tolerance} of ${expected}`)
}

test("parseSamples keeps the later of two same-second rows and skips junk", () => {
  const rows = Model.parseSamples("100,50,20,40,4,D\n100,49,19.6,40,4,D\n90,48,1,1,1,D\nbad\n160,48,19.2,40,4,D\n")
  assert.equal(rows.length, 2)
  assert.equal(rows[0].p, 49)
  assert.equal(rows[1].t, 160)
})

test("daily buckets are contiguous, midnight-aligned, and end with today", () => {
  const now = MIDNIGHT + 15 * HOUR
  const list = Model.buckets("30d", now)
  assert.equal(list.length, 30)
  for (let i = 1; i < list.length; i++) assert.equal(list[i].start, list[i - 1].end)
  assert.equal(list[29].start, MIDNIGHT)
  assert.ok(list[29].end > now)
})

test("hourly buckets cover the last 24 hours up to the next full hour", () => {
  const now = MIDNIGHT + 15 * HOUR + 1200
  const list = Model.buckets("24h", now)
  assert.equal(list.length, 24)
  assert.equal(list[23].end, MIDNIGHT + 16 * HOUR)
  assert.equal(list[0].start, MIDNIGHT - 8 * HOUR)
})

test("awake use, sleep drain and charging are counted separately", () => {
  const start = MIDNIGHT + 8 * HOUR
  // Two hours awake on battery losing 0.2% a minute: 100 -> 76.2.
  const awake = run(start, 120, 100, -0.2, "D")
  // Asleep six hours, lose 3%, wake still on battery.
  const woke = run(start + 120 * 60 + 6 * HOUR, 10, 73.2, -0.1, "D")
  // Plug in and charge half an hour at 1% a minute.
  const charge = run(woke.at(-1).t + 60, 30, 72.5, 1, "C")
  const samples = [...awake, ...woke, ...charge]

  const report = Model.buildReport(samples, "24h", charge.at(-1).t + 60)
  const t = report.totals
  // 119 awake intervals before sleep + 9 after, at 0.2% and 0.1%. The step
  // into charging rises, so it adds nothing.
  near(t.awake, 119 * 0.2 + 9 * 0.1)
  near(t.sleep, 76.2 - 73.2)
  near(t.sleepSec, 6 * HOUR + 60, 1)
  near(t.charged, 29)
  near(report.sleepPctH, 3 / (6 + 1 / 60), 0.001)
  // 0.2% of 40 Wh per minute = 4.8 W awake.
  assert.ok(report.drainW > 4 && report.drainW < 5, `drainW ${report.drainW}`)
  assert.equal(report.lastCharge.charging, true)
})

test("an interval that crosses midnight is split between both days", () => {
  const before = sample(MIDNIGHT - 2 * HOUR, 80, "D")
  const after = sample(MIDNIGHT + 2 * HOUR, 76, "D")
  const report = Model.buildReport([before, after], "7d", MIDNIGHT + 10 * HOUR)
  const last = report.buckets.at(-1)
  const previous = report.buckets.at(-2)
  near(previous.sleep, 2)
  near(last.sleep, 2)
})

test("level series flags the point after a sleep and thins long ranges", () => {
  const start = MIDNIGHT
  const samples = [...run(start, 600, 100, -0.05, "D"), ...run(start + 600 * 60 + 4 * HOUR, 60, 60, -0.05, "D")]
  const series = Model.levelSeries(samples, start, start + 24 * HOUR, 1800)
  assert.ok(series.length < samples.length / 4, `kept ${series.length} of ${samples.length}`)
  const gaps = series.filter((p) => p.gap)
  assert.equal(gaps.length, 1)
  assert.equal(gaps[0].t, start + 600 * 60 + 4 * HOUR)
})

test("last charge reports where the most recent charge stopped", () => {
  const samples = [...run(MIDNIGHT, 10, 70, 1, "C"), sample(MIDNIGHT + 600, 80, "P"), ...run(MIDNIGHT + 660, 5, 80, -0.2, "D")]
  const last = Model.lastCharge(samples)
  assert.equal(last.charging, false)
  assert.equal(last.p, 80)
  assert.equal(last.t, MIDNIGHT + 600)
})

test("health report derives lifetime and per-cycle loss", () => {
  const now = Model.dateToEpoch("2026-09-11")
  const info = { full_wh: "41", design_wh: "50", cycles: "600", manufactured: "2021-03-11" }
  const health = Model.healthReport(info, [], now)
  near(health.capacity, 82)
  near(health.per100Cycles, 3)
  near(health.ageYears, 5.5, 0.01)
  near(health.perYear, 18 / health.ageYears)
  assert.equal(health.trend, null)
  near(health.yearsTo80, 2 / health.perYear)
  assert.equal(health.condition, "Normal")
})

test("measured trend needs two weeks, then fits the slope", () => {
  const day = 86400
  const t0 = Model.dateToEpoch("2026-08-01")
  const history = Array.from({ length: 20 }, (_, i) => ({ t: t0 + i * day, capacity: 90 - i * 0.01 }))
  const trend = Model.measuredTrend(history)
  near(trend.perYear, 3.6525, 0.001)
  assert.equal(Model.measuredTrend(history.slice(0, 10)), null)
})

test("formatting helpers", () => {
  assert.equal(Model.formatDuration(5 * HOUR + 7 * 60), "5h 07m")
  assert.equal(Model.formatDuration(59), "1m")
  assert.equal(Model.formatYears(0.5), "6 months")
  assert.equal(Model.formatWhen(MIDNIGHT + 14 * HOUR + 32 * 60, MIDNIGHT + 20 * HOUR), "Today 14:32")
  assert.equal(Model.formatWhen(MIDNIGHT - HOUR, MIDNIGHT + 20 * HOUR), "Yesterday 23:00")
})
