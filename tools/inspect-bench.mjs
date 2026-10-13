#!/usr/bin/env node
// Offline inspector for the bench dashboard. Reuses assets/bench-core.js so the
// computation matches what the browser chart does.
//
// Usage:
//   node tools/inspect-bench.mjs                       # default: sparse, minimum, all dates
//   node tools/inspect-bench.mjs sparse minimum
//   node tools/inspect-bench.mjs sparse mean --days 15  # the site's default range
//
// `--days N` keeps the last N days, like the chart's time range (0 or no flag
// is "All"). Reads the extracts that analysis/fetch_data.jl downloads into data/.
//
// Prints:
//   - The group geomean series in the range (raw + % from baseline).
//   - The individual benchmark series for the last several reports, with the
//     same baseline math the dashboard applies in "expanded group" view.
//   - A spread summary showing how far apart the individual % values are at
//     each of the most recent dates (median / min / max / IQR) compared to
//     the group geomean line.
//
// Like the chart, it does not cut series at methodology changes
// (data/methodology_changes.json): the chart only fades the older points.
// Benchmarks with such a change are flagged in the per-benchmark table.

import { gunzipSync } from "node:zlib";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const BenchCore = require("../assets/bench-core.js");

const here = dirname(fileURLToPath(import.meta.url));
const dataDir = join(here, "..", "data");

function loadGz(path) {
  return JSON.parse(gunzipSync(readFileSync(path)).toString());
}

// Load methodology-change registry into BenchCore (sync; mirrors what
// loadBenchmarkData() does in the browser).
BenchCore.setMethodologyChanges(
  JSON.parse(readFileSync(join(dataDir, "methodology_changes.json"), "utf8")),
);

const positional = [];
let days = 0;
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === "--days") {
    days = Number(process.argv[++i]);
    if (!Number.isInteger(days) || days < 0) {
      console.error("--days needs a whole number of days (0 for all)");
      process.exit(2);
    }
  } else if (a.startsWith("--")) {
    console.error(`unknown option ${a}; usage: inspect-bench.mjs [group] [minimum|mean] [--days N]`);
    process.exit(2);
  } else {
    positional.push(a);
  }
}
const group = positional[0] || "sparse";
const stat = positional[1] || "minimum";

const benchDir = join(dataDir, "benchmarks");
const groupPath = join(benchDir, `${group}.json.gz`);
if (!existsSync(groupPath)) {
  const groups = existsSync(benchDir)
    ? readdirSync(benchDir).filter((f) => f.endsWith(".json.gz")).map((f) => f.slice(0, -8)).sort()
    : [];
  if (groups.length === 0) {
    console.error(`No benchmark data in ${benchDir}. Download it with: julia --project analysis/fetch_data.jl --only benchmarks`);
  } else {
    console.error(`No data for group "${group}". Groups: ${groups.join(", ")}`);
  }
  process.exit(1);
}
const detail = loadGz(groupPath);
const statData = detail[stat];
if (!statData) {
  console.error(`No "${stat}" statistic in ${group}; use one of: ${Object.keys(detail).join(", ")}`);
  process.exit(1);
}

// Same cutoff as the chart's time range selector
let cutoff = null;
if (days > 0) {
  cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - days);
}

// ---- Group geomean line (computed in-browser-style from per-bench detail) ----
const geomean = BenchCore.buildGroupGeomeanFromDetail(detail, stat, cutoff);
const geomeanPct = BenchCore.toPercentOfBaseline(geomean);
if (geomean.length === 0) {
  console.error(`No ${group} data in the last ${days} days`);
  process.exit(1);
}

const tail = 10;
const range = days > 0 ? `last ${days} days` : "all dates";
console.log(`\n== ${group} group geomean (${stat}, ${range}, ${geomean.length} points, baseline = first point) ==`);
console.log("  date         raw_ns             % from baseline");
for (let i = Math.max(0, geomean.length - tail); i < geomean.length; i++) {
  const p = geomean[i];
  const pct = geomeanPct[i];
  console.log(
    `  ${p.x.toISOString().slice(0, 10)}  ${String(Math.round(p.yRaw)).padStart(14)}    ${pct.y.toFixed(2).padStart(10)}%`,
  );
}

// ---- Per-benchmark series ----
const recentDates = geomean.slice(-3).map((p) => p.x.toISOString().slice(0, 10));
console.log(`\n== Per-benchmark % from baseline on recent dates (${recentDates.join(", ")}) ==`);

const rows = [];
for (const name of Object.keys(statData.benchmarks).sort()) {
  const series = BenchCore.buildBenchmarkSeries(statData, group, name, cutoff);
  if (series.length < 2) continue;
  const pct = BenchCore.toPercentOfBaseline(series);
  const byDate = new Map(pct.map((p) => [p.x.toISOString().slice(0, 10), p]));
  const slice = recentDates.map((d) => byDate.get(d));
  if (!slice[slice.length - 1]) continue;
  rows.push({
    name,
    baselineRaw: series[0].yRaw,
    baselineDate: series[0].x.toISOString().slice(0, 10),
    slice,
    last: slice[slice.length - 1].y,
    changes: BenchCore.getMethodologyChanges()
      .filter((c) => c.benchmarks.has(`${group}/${name}`))
      .map((c) => c.firstValidDate),
  });
}

// Sort by |last %| descending so the most-affected benchmarks surface first.
rows.sort((a, b) => Math.abs(b.last) - Math.abs(a.last));

const header = ["benchmark"].concat(recentDates.map((d) => d + " %"));
console.log("  " + header.join("   ").padEnd(80));
for (const r of rows.slice(0, 30)) {
  const note = r.changes.length ? `  [methodology change ${r.changes.join(", ")}]` : "";
  const cells = r.slice.map((p) =>
    p ? p.y.toFixed(1).padStart(12) + "%" : "          —",
  );
  console.log(`  ${cells.join("  ")}  base=${String(Math.round(r.baselineRaw)).padStart(10)}@${r.baselineDate}  ${r.name}${note}`);
}
if (rows.length > 30) console.log(`  ... (${rows.length - 30} more rows)`);

// ---- Spread summary ----
function quantile(sorted, q) {
  if (sorted.length === 0) return NaN;
  const idx = (sorted.length - 1) * q;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}

console.log(`\n== Spread of per-benchmark % at recent dates vs group geomean line ==`);
console.log("  date         n   min%        p25%        median%     p75%        max%        geomean-line%");
for (const d of recentDates) {
  const ys = rows.map((r) => r.slice[recentDates.indexOf(d)]?.y).filter((v) => v != null);
  ys.sort((a, b) => a - b);
  const geo = geomeanPct.find((p) => p.x.toISOString().slice(0, 10) === d);
  if (ys.length === 0) {
    console.log(`  ${d}  0`);
    continue;
  }
  const fmt = (v) => (v >= 0 ? "+" : "") + v.toFixed(1) + "%";
  console.log(
    `  ${d}  ${String(ys.length).padStart(3)}  ${fmt(ys[0]).padStart(10)}  ${fmt(quantile(ys, 0.25)).padStart(10)}  ${fmt(quantile(ys, 0.5)).padStart(10)}  ${fmt(quantile(ys, 0.75)).padStart(10)}  ${fmt(ys[ys.length - 1]).padStart(10)}  ${geo ? fmt(geo.y).padStart(10) : "         —"}`,
  );
}
console.log("");
