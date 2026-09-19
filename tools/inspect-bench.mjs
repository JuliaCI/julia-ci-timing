#!/usr/bin/env node
// Offline inspector for the bench dashboard. Reuses assets/bench-core.js so the
// computation matches what the browser chart does.
//
// Usage:
//   node tools/inspect-bench.mjs                       # default: sparse, minimum
//   node tools/inspect-bench.mjs sparse minimum
//   node tools/inspect-bench.mjs sparse mean
//
// Prints:
//   - The post-cutoff group geomean series (raw + % from baseline).
//   - The individual benchmark series for the last several reports, with the
//     same baseline math the dashboard applies in "expanded group" view.
//   - A spread summary showing how far apart the individual % values are at
//     each of the most recent dates (median / min / max / IQR) compared to
//     the group geomean line.

import { gunzipSync } from "node:zlib";
import { readFileSync } from "node:fs";
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

const group = process.argv[2] || "sparse";
const stat = process.argv[3] || "minimum";

const detail = loadGz(join(dataDir, "benchmarks", `${group}.json.gz`));
const statData = detail[stat];

// ---- Group geomean line (computed in-browser-style from per-bench detail) ----
const geomean = BenchCore.buildGroupGeomeanFromDetail(detail, stat, null);
const geomeanPct = BenchCore.toPercentOfBaseline(geomean);

const tail = 10;
console.log(`\n== ${group} group geomean (${stat}, ${geomean.length} points, baseline = first post-cutoff) ==`);
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
  const series = BenchCore.buildBenchmarkSeries(statData, group, name, null);
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
  });
}

// Sort by |last %| descending so the most-affected benchmarks surface first.
rows.sort((a, b) => Math.abs(b.last) - Math.abs(a.last));

const header = ["benchmark"].concat(recentDates.map((d) => d + " %"));
console.log("  " + header.join("   ").padEnd(80));
for (const r of rows.slice(0, 30)) {
  const cells = r.slice.map((p) =>
    p ? p.y.toFixed(1).padStart(12) + "%" : "          —",
  );
  console.log(`  ${cells.join("  ")}  base=${String(Math.round(r.baselineRaw)).padStart(10)}@${r.baselineDate}  ${r.name}`);
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
