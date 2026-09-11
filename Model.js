.pragma library

// Pure data model for Battery Insights: parses the helper's CSV logs and
// turns them into chart series, usage buckets, and health figures. No QML
// here, so it can be exercised from node (see test/model.test.mjs).

// Samples arrive once a minute. A longer silence means the machine was
// asleep (or off), which is drawn and counted separately from awake use.
var GAP_SEC = 300

var RANGES = {
  "24h": { label: "24 hours", span: 1, unit: "hour", levelStep: 300 },
  "7d": { label: "7 days", span: 7, unit: "day", levelStep: 1800 },
  "30d": { label: "30 days", span: 30, unit: "day", levelStep: 7200 }
}

var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// Service threshold Apple and most vendors use for "replace soon".
var HEALTH_SERVICE_THRESHOLD = 80

// ---------------------------------------------------------------- parsing

function parseSamples(text) {
  var out = []
  var lines = String(text || "").split("\n")
  var lastT = -1
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split(",")
    if (f.length < 6) continue
    var t = Number(f[0])
    var p = Number(f[1])
    if (!isFinite(t) || !isFinite(p)) continue
    // Rows share a timestamp when a sample lands in the same second as a
    // state-change sample; the later row wins.
    if (t === lastT) out.pop()
    else if (t < lastT) continue
    out.push({ t: t, p: p, e: Number(f[2]) || 0, f: Number(f[3]) || 0, w: Number(f[4]) || 0, s: f[5].trim() })
    lastT = t
  }
  return out
}

function parseHealth(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].split(",")
    if (f.length < 3) continue
    var t = dateToEpoch(f[0])
    var full = Number(f[1])
    var design = Number(f[2])
    if (!t || !(full > 0) || !(design > 0)) continue
    out.push({ t: t, full: full, design: design, cycles: Number(f[3]) || 0, capacity: full / design * 100 })
  }
  return out
}

function parseInfo(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var eq = lines[i].indexOf("=")
    if (eq <= 0) continue
    out[lines[i].slice(0, eq).trim()] = lines[i].slice(eq + 1).trim()
  }
  return out
}

// "2021-02-26" -> epoch seconds at local noon (noon keeps DST shifts from
// nudging a date into its neighbour).
function dateToEpoch(value) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || "").trim())
  if (!m) return 0
  return Math.floor(new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 12).getTime() / 1000)
}

// ---------------------------------------------------------------- buckets

// Usage buckets for a range, aligned to local hours or midnights so bars
// line up with the clock. The last bucket holds "now" and is partial.
function buckets(rangeKey, nowSec) {
  var range = RANGES[rangeKey] || RANGES["24h"]
  var out = []
  var now = new Date(nowSec * 1000)
  if (range.unit === "hour") {
    var end = new Date(now.getFullYear(), now.getMonth(), now.getDate(), now.getHours() + 1)
    var endSec = Math.floor(end.getTime() / 1000)
    for (var h = 24; h > 0; h--) out.push({ start: endSec - h * 3600, end: endSec - (h - 1) * 3600 })
  } else {
    // Built from calendar dates rather than 86400s steps so a DST change
    // does not shear the buckets off midnight.
    for (var d = range.span - 1; d >= 0; d--) {
      var start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - d)
      var next = new Date(now.getFullYear(), now.getMonth(), now.getDate() - d + 1)
      out.push({ start: Math.floor(start.getTime() / 1000), end: Math.floor(next.getTime() / 1000) })
    }
  }
  for (var i = 0; i < out.length; i++) {
    var b = out[i]
    b.awake = 0     // % used while awake on battery
    b.sleep = 0     // % lost while asleep on battery
    b.awakeWh = 0
    b.sleepWh = 0
    b.batterySec = 0
    b.sleepSec = 0
    b.charged = 0
    b.chargeSec = 0
  }
  return out
}

// Walk consecutive sample pairs and attribute each interval to awake
// discharge, sleep discharge, or charging. An interval is spread over the
// buckets it overlaps in proportion to the overlap, so a night of sleep
// drain split by midnight lands on both days. Rises while discharging and
// drops while charging are gauge noise and count as zero.
//
// This runs over ~45k intervals for 30 days inside the shell's JS engine,
// hence one forward pass with a bucket cursor and plain field writes.
function accumulate(list, samples) {
  if (list.length === 0) return
  var from = list[0].start
  var to = list[list.length - 1].end
  var cursor = 0
  for (var i = 1; i < samples.length; i++) {
    var a = samples[i - 1]
    var b = samples[i]
    if (b.t <= from || a.t >= to) continue
    var dt = b.t - a.t
    if (dt <= 0) continue

    var kind
    if (dt <= GAP_SEC) kind = a.s === "D" ? 1 : (a.s === "C" ? 2 : 0)
    else kind = a.s === "D" && b.s === "D" ? 3 : 0
    if (kind === 0) continue

    while (cursor < list.length && list[cursor].end <= a.t) cursor++
    var drop = Math.max(0, a.p - b.p)
    var dropWh = Math.max(0, a.e - b.e)
    var rise = Math.max(0, b.p - a.p)
    for (var k = cursor; k < list.length && list[k].start < b.t; k++) {
      var bk = list[k]
      var share = (Math.min(b.t, bk.end) - Math.max(a.t, bk.start)) / dt
      if (share <= 0) continue
      if (kind === 1) {
        bk.awake += drop * share
        bk.awakeWh += dropWh * share
        bk.batterySec += dt * share
      } else if (kind === 2) {
        bk.charged += rise * share
        bk.chargeSec += dt * share
      } else {
        bk.sleep += drop * share
        bk.sleepWh += dropWh * share
        bk.sleepSec += dt * share
      }
    }
  }
}

// ---------------------------------------------------------------- level series

// Battery level points for the line chart, thinned to one bin per
// `levelStep`. Each bin keeps its first, lowest, highest and last reading so
// charge spikes and drops survive the thinning. `gap` marks a point that
// follows a sleep, where the line should be drawn as a jump, not usage.
function levelSeries(samples, from, to, step) {
  var out = []
  var bin = null
  var prev = null

  function flush() {
    if (!bin) return
    var pts = [bin.first, bin.min, bin.max, bin.last]
    pts.sort(function(x, y) { return x.t - y.t })
    for (var k = 0; k < pts.length; k++) {
      if (k > 0 && pts[k] === pts[k - 1]) continue
      out.push({ t: pts[k].t, p: pts[k].p, s: pts[k].s, gap: k === 0 && bin.gap })
    }
    bin = null
  }

  for (var i = 0; i < samples.length; i++) {
    var s = samples[i]
    if (s.t < from || s.t > to) { prev = s; continue }
    var gap = !!prev && s.t - prev.t > GAP_SEC
    var key = Math.floor((s.t - from) / step)
    if (!bin || gap || key !== bin.key) {
      flush()
      bin = { key: key, first: s, min: s, max: s, last: s, gap: gap }
    } else {
      if (s.p < bin.min.p) bin.min = s
      if (s.p > bin.max.p) bin.max = s
      bin.last = s
    }
    prev = s
  }
  flush()
  return out
}

// ---------------------------------------------------------------- report

function buildReport(samples, rangeKey, nowSec) {
  var range = RANGES[rangeKey] || RANGES["24h"]
  var list = buckets(rangeKey, nowSec)
  accumulate(list, samples)

  var from = list[0].start
  var to = list[list.length - 1].end
  var totals = { awake: 0, sleep: 0, awakeWh: 0, sleepWh: 0, batterySec: 0, sleepSec: 0, charged: 0, chargeSec: 0 }
  var maxUse = 0
  for (var i = 0; i < list.length; i++) {
    for (var key in totals) totals[key] += list[i][key]
    maxUse = Math.max(maxUse, list[i].awake + list[i].sleep)
  }

  var latest = samples.length ? samples[samples.length - 1] : null
  var batteryHours = totals.batterySec / 3600
  var sleepHours = totals.sleepSec / 3600
  // Averages over a few minutes of use are mostly noise.
  var drainW = totals.batterySec >= 600 ? totals.awakeWh / batteryHours : null
  var drainPctH = totals.batterySec >= 600 ? totals.awake / batteryHours : null
  var sleepPctH = totals.sleepSec >= 1800 ? totals.sleep / sleepHours : null
  var fullWh = latest ? latest.f : 0
  var runtimeH = drainW && drainW > 0.1 && fullWh > 0 ? fullWh / drainW : null

  return {
    range: rangeKey,
    from: from,
    to: to,
    now: nowSec,
    unit: range.unit,
    buckets: list,
    maxUse: maxUse,
    level: levelSeries(samples, from, to, range.levelStep),
    ticks: axisTicks(rangeKey, list),
    totals: totals,
    drainW: drainW,
    drainPctH: drainPctH,
    sleepPctH: sleepPctH,
    runtimeH: runtimeH,
    lastCharge: lastCharge(samples),
    hasData: samples.some(function(s) { return s.t >= from && s.t <= to })
  }
}

// X-axis labels as { fraction, text } across the report window.
function axisTicks(rangeKey, list) {
  var from = list[0].start
  var span = list[list.length - 1].end - from
  var out = []
  var every = rangeKey === "24h" ? 6 : (rangeKey === "7d" ? 1 : 7)
  // Anchor 30-day labels on the newest day so today always carries one.
  var offset = rangeKey === "30d" ? (list.length - 1) % every : 0
  for (var i = offset; i < list.length; i += every) {
    var d = new Date(list[i].start * 1000)
    var text
    if (rangeKey === "24h") text = pad2(d.getHours()) + ":00"
    else if (rangeKey === "7d") text = DAY_NAMES[d.getDay()]
    else text = d.getDate() + " " + MONTH_NAMES[d.getMonth()]
    // 24h labels sit on the hour line; day labels centre under their bar.
    var at = rangeKey === "24h" ? list[i].start : (list[i].start + list[i].end) / 2
    out.push({ fraction: (at - from) / span, text: text })
  }
  return out
}

// The most recent charge: where it stopped and when, or charging right now.
function lastCharge(samples) {
  var n = samples.length
  if (n === 0) return null
  if (samples[n - 1].s === "C") return { charging: true, p: samples[n - 1].p, t: samples[n - 1].t }
  for (var i = n - 1; i >= 0; i--) {
    if (samples[i].s !== "C") continue
    // The reading after the last charging one is where charging ended.
    var end = i + 1 < n ? samples[i + 1] : samples[i]
    return { charging: false, p: Math.max(samples[i].p, end.p), t: end.t }
  }
  return null
}

// ---------------------------------------------------------------- health

function healthReport(info, history, nowSec) {
  var full = Number(info.full_wh) || 0
  var design = Number(info.design_wh) || 0
  if (!(full > 0 && design > 0) && history.length) {
    full = history[history.length - 1].full
    design = history[history.length - 1].design
  }
  if (!(full > 0 && design > 0)) return null

  var capacity = full / design * 100
  var loss = Math.max(0, 100 - capacity)
  var cycles = Number(info.cycles) || (history.length ? history[history.length - 1].cycles : 0)
  var manufactured = dateToEpoch(info.manufactured)
  var ageYears = manufactured ? (nowSec - manufactured) / (365.25 * 86400) : null
  var perYear = ageYears && ageYears >= 0.25 ? loss / ageYears : null
  var per100Cycles = cycles > 0 ? loss / cycles * 100 : null

  var trend = measuredTrend(history)
  // Projections prefer what was actually measured on this machine over the
  // lifetime average, once there is enough of it to trust.
  var rate = trend && trend.perYear > 0 ? trend.perYear : perYear
  var yearsTo80 = null
  if (capacity > HEALTH_SERVICE_THRESHOLD && rate && rate > 0) yearsTo80 = (capacity - HEALTH_SERVICE_THRESHOLD) / rate

  return {
    capacity: capacity,
    fullWh: full,
    designWh: design,
    loss: loss,
    cycles: cycles,
    manufactured: manufactured,
    ageYears: ageYears,
    perYear: perYear,
    per100Cycles: per100Cycles,
    trend: trend,
    trackedDays: history.length ? Math.round((history[history.length - 1].t - history[0].t) / 86400) + 1 : 0,
    rate: rate,
    yearsTo80: yearsTo80,
    condition: capacity >= HEALTH_SERVICE_THRESHOLD ? "Normal" : "Service recommended",
    history: history
  }
}

// Least-squares slope of capacity over the tracked days. The fuel gauge's
// estimate of full capacity wobbles by a percent or so between charges, so
// this needs two weeks of readings before it says anything.
var TREND_MIN_DAYS = 14

function measuredTrend(history) {
  if (history.length < 7) return null
  var spanDays = (history[history.length - 1].t - history[0].t) / 86400
  if (spanDays < TREND_MIN_DAYS) return null
  var n = history.length
  var sx = 0, sy = 0, sxx = 0, sxy = 0
  for (var i = 0; i < n; i++) {
    var x = (history[i].t - history[0].t) / 86400
    var y = history[i].capacity
    sx += x; sy += y; sxx += x * x; sxy += x * y
  }
  var denom = n * sxx - sx * sx
  if (denom === 0) return null
  var slopePerDay = (n * sxy - sx * sy) / denom
  return { perYear: -slopePerDay * 365.25, spanDays: spanDays }
}

// ---------------------------------------------------------------- formatting

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

function formatDuration(sec) {
  if (!(sec > 0)) return "0m"
  var minutes = Math.round(sec / 60)
  var h = Math.floor(minutes / 60)
  var m = minutes % 60
  if (h >= 48) return Math.round(h / 24) + "d"
  if (h === 0) return m + "m"
  return h + "h " + pad2(m) + "m"
}

function formatHours(hours) {
  if (hours === null || hours === undefined || !isFinite(hours)) return "—"
  return formatDuration(hours * 3600)
}

function formatPercent(value, digits) {
  if (value === null || value === undefined || !isFinite(value)) return "—"
  return value.toFixed(digits === undefined ? 0 : digits) + "%"
}

// "14:32", "Yesterday 09:10", "Tue 18:05", "3 Sep" depending on distance.
function formatWhen(tSec, nowSec) {
  var d = new Date(tSec * 1000)
  var now = new Date(nowSec * 1000)
  var today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
  var day = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  var clock = pad2(d.getHours()) + ":" + pad2(d.getMinutes())
  var daysAgo = Math.round((today - day) / 86400000)
  if (daysAgo <= 0) return "Today " + clock
  if (daysAgo === 1) return "Yesterday " + clock
  if (daysAgo < 7) return DAY_NAMES[d.getDay()] + " " + clock
  return d.getDate() + " " + MONTH_NAMES[d.getMonth()]
}

function formatBucketLabel(bucket, unit) {
  var d = new Date(bucket.start * 1000)
  if (unit === "hour") {
    var e = new Date(bucket.end * 1000)
    return pad2(d.getHours()) + ":00–" + pad2(e.getHours()) + ":00"
  }
  return DAY_NAMES[d.getDay()] + " " + d.getDate() + " " + MONTH_NAMES[d.getMonth()]
}

function formatYears(years) {
  if (years === null || years === undefined || !isFinite(years)) return "—"
  if (years < 1) return Math.max(1, Math.round(years * 12)) + " months"
  return years.toFixed(1) + " years"
}
