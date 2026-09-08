// Shared benchmark data-processing helpers.
// Loadable in the browser (attaches `BenchCore` to the global) and in Node
// (`require('./bench-core.js')`), so the same logic powers the dashboard chart
// and the offline `tools/inspect-bench.mjs` analysis script.
(function (root, factory) {
  const exports = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = exports;
  } else {
    root.BenchCore = exports;
  }
})(typeof self !== "undefined" ? self : globalThis, function () {
  "use strict";

  // Benchmark methodology changes: data before first_valid_date used a different
  // measurement and is not comparable to newer data. The canonical registry is
  // data/methodology_changes.json — loaded asynchronously in the browser via
  // BenchCore.loadMethodologyChanges() and synchronously in Node via
  // BenchCore.setMethodologyChanges(parsedJson).
  let BENCH_METHODOLOGY_CHANGES = [];

  function normalizeChanges(raw) {
    const list = (raw && raw.changes) || [];
    return list.map((c) => ({
      firstValidDate: c.first_valid_date,
      mergedDate: c.merged_date,
      benchmarks: new Set(c.benchmarks || []),
      description: c.description || "",
      url: c.url || "",
      id: c.id || "",
    }));
  }

  function setMethodologyChanges(raw) {
    BENCH_METHODOLOGY_CHANGES = normalizeChanges(raw);
  }

  // Browser-only: fetch the JSON registry. Returns the parsed list.
  async function loadMethodologyChanges(url) {
    url = url || "data/methodology_changes.json";
    try {
      const resp = await fetch(url, { cache: "no-cache" });
      if (!resp.ok) throw new Error("HTTP " + resp.status);
      const raw = await resp.json();
      setMethodologyChanges(raw);
    } catch (e) {
      // eslint-disable-next-line no-console
      console.warn("Failed to load methodology changes:", e);
      BENCH_METHODOLOGY_CHANGES = [];
    }
    return BENCH_METHODOLOGY_CHANGES;
  }

  function getMethodologyChanges() {
    return BENCH_METHODOLOGY_CHANGES;
  }

  // Sorted unique list of methodology-change dates (as Date objects). Used
  // for annotations on the chart.
  function getMethodologyDates() {
    const seen = new Set();
    const out = [];
    for (const c of BENCH_METHODOLOGY_CHANGES) {
      if (!c.firstValidDate || seen.has(c.firstValidDate)) continue;
      seen.add(c.firstValidDate);
      out.push(new Date(c.firstValidDate));
    }
    out.sort((a, b) => a - b);
    return out;
  }

  // Build the per-benchmark raw series from a {benchmarks, dates, commits,
  // date_paths} block. Returns an array of points sorted by date.
  function buildBenchmarkSeries(statData, group, name, baseCutoff) {
    const series = statData && statData.benchmarks && statData.benchmarks[name];
    if (!series) return [];
    const points = [];
    for (let i = 0; i < statData.dates.length; i++) {
      const v = series[i];
      if (v == null || v === 0) continue;
      const d = new Date(statData.dates[i]);
      if (baseCutoff && d < baseCutoff) continue;
      points.push({
        x: d,
        y: v,
        yRaw: v,
        commit: (statData.commits && statData.commits[i]) || "",
        date_path: (statData.date_paths && statData.date_paths[i]) || "",
      });
    }
    return points;
  }

  // Build the per-group geomean series by averaging (log-mean) all benchmarks
  // in `groupDetail` (the parsed data/benchmarks/<group>.json.gz) at each
  // date. `stat` is "minimum" or "mean".
  function buildGroupGeomeanFromDetail(groupDetail, stat, baseCutoff) {
    const statData = groupDetail && groupDetail[stat];
    if (!statData || !statData.dates) return [];
    const dates = statData.dates;
    const commits = statData.commits || [];
    const datePaths = statData.date_paths || [];
    const benchNames = Object.keys(statData.benchmarks || {});
    const points = [];
    for (let i = 0; i < dates.length; i++) {
      const d = new Date(dates[i]);
      if (baseCutoff && d < baseCutoff) continue;
      let logSum = 0;
      let n = 0;
      for (const name of benchNames) {
        const v = statData.benchmarks[name][i];
        if (v == null || v === 0) continue;
        logSum += Math.log(v);
        n++;
      }
      if (n === 0) continue;
      const y = Math.exp(logSum / n);
      points.push({
        x: d,
        y,
        yRaw: y,
        commit: commits[i] || "",
        date_path: datePaths[i] || "",
      });
    }
    return points;
  }

  // Convert a raw series to "% deviation from baseline" form. Baseline is
  // points[0].y. The returned points preserve `yRaw` (original ns value) and
  // overwrite `y` with the percentage.
  function toPercentOfBaseline(points) {
    if (points.length === 0) return [];
    const baseline = points[0].y;
    if (!(baseline > 0)) {
      return points.map((p) => ({ ...p, yRaw: p.yRaw != null ? p.yRaw : p.y, y: 0 }));
    }
    return points.map((p) => ({
      ...p,
      yRaw: p.yRaw != null ? p.yRaw : p.y,
      y: ((p.y - baseline) / baseline) * 100,
    }));
  }

  // Geomean across an arbitrary set of per-group raw series. `groupSeries` is
  // a Map<groupName, points[]>. Returns points (one per date) whose y is the
  // geomean of contributing group values at that date.
  function buildOverallFromGroupSeries(groupSeries) {
    const byDate = new Map();
    for (const points of groupSeries.values()) {
      for (const p of points) {
        const k = p.x.getTime();
        let entry = byDate.get(k);
        if (!entry) {
          entry = { x: p.x, logSum: 0, n: 0, commit: p.commit, date_path: p.date_path };
          byDate.set(k, entry);
        }
        if (p.y > 0) {
          entry.logSum += Math.log(p.y);
          entry.n++;
        }
      }
    }
    const out = [];
    for (const e of byDate.values()) {
      if (e.n === 0) continue;
      const y = Math.exp(e.logSum / e.n);
      out.push({ x: e.x, y, yRaw: y, commit: e.commit, date_path: e.date_path });
    }
    out.sort((a, b) => a.x - b.x);
    return out;
  }

  return {
    get BENCH_METHODOLOGY_CHANGES() {
      return BENCH_METHODOLOGY_CHANGES;
    },
    getMethodologyChanges,
    getMethodologyDates,
    setMethodologyChanges,
    loadMethodologyChanges,
    buildBenchmarkSeries,
    buildGroupGeomeanFromDetail,
    buildOverallFromGroupSeries,
    toPercentOfBaseline,
  };
});
