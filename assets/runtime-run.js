// The run page (runtime-run/): one Runtime benchmarks job of julia-pr, julia-ci or
// julia-buildkite-ci, read from /api/runtime/run/<pipeline>/<build>/<job>, which the
// server fetches from the job's Buildkite artifacts on first use. A comparison shows
// every benchmark's change against the base build with its tolerance, the categories,
// instructions against cycles and the samples of the benchmark picked; a build measured
// alone shows its values. A job that measured its regressions again against a control
// build has a second run, the confirmation.
"use strict";

const API = "../api/runtime/run";
// compare.jl's thresholds where compare.json does not say: a category's geomean, and
// instruction counts (exact, so a change beyond this is the code changing)
const SUITE_TOL_PCT = 1.5;
const INSTR_PCT = 0.5;
// The change chart's notable rows: every flagged benchmark plus the furthest from no change
const NOTABLE_EXTRA = 20;
const RETRY_RUNNING_MS = 60000;

const STATUS_COLORS = {
  light: { ok: "#1a7f37", fail: "#d1242f", warn: "#9a6700", skip: "#8c959f" },
  dark: { ok: "#3fb950", fail: "#f85149", warn: "#d29922", skip: "#8b949e" },
};
const ARM_COLORS = {
  light: { base: "#6e7781", head: "#2a78d6", control: "#8250df" },
  dark: { base: "#8b949e", head: "#3987e5", control: "#a371f7" },
};

const params = new URLSearchParams(location.search);
const job = { pipeline: params.get("pipeline") || "", build: params.get("build") || "", job: params.get("job") || "" };
const state = {
  data: null,
  run: params.get("run") === "confirm" ? "confirm" : "main",
  bench: params.get("b") || null,
  show: params.get("show") === "all" ? "all" : "notable",
  filter: params.get("q") || "",
  sort: { col: "change", asc: false },
};
const samplesCache = new Map();
let charts = [];

// --- theme, as the site's ----------------------------------------------------------

function currentTheme() {
  try {
    return localStorage.getItem("theme") || "system";
  } catch (e) {
    return "system";
  }
}
function isDarkMode() {
  const t = currentTheme();
  return t === "dark" || (t !== "light" && window.matchMedia("(prefers-color-scheme: dark)").matches);
}
function applyTheme() {
  const t = currentTheme();
  if (t === "dark" || t === "light") document.documentElement.setAttribute("data-theme", t);
  else document.documentElement.removeAttribute("data-theme");
  const btn = document.getElementById("theme-toggle");
  btn.textContent = { system: "◑", dark: "☾", light: "☀" }[t] || "◑";
  btn.title = `Theme: ${t}`;
  if (state.data) render();
}
function cycleTheme() {
  const order = ["system", "dark", "light"];
  const next = order[(order.indexOf(currentTheme()) + 1) % order.length];
  try {
    if (next === "system") localStorage.removeItem("theme");
    else localStorage.setItem("theme", next);
  } catch (e) {}
  applyTheme();
}
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (currentTheme() === "system" && state.data) render();
});
const palette = () => {
  const dark = isDarkMode();
  return {
    dark,
    status: STATUS_COLORS[dark ? "dark" : "light"],
    arms: ARM_COLORS[dark ? "dark" : "light"],
    text: dark ? "#8b949e" : "#656d76",
    strong: dark ? "#c9d1d9" : "#24292f",
    grid: dark ? "#30363d" : "#d0d7de",
    band: dark ? "rgba(139,148,158,0.14)" : "rgba(110,119,129,0.12)",
  };
};
const armColor = (a) => palette().arms[a] || palette().text;
const verdictColor = (v, vetoed) =>
  vetoed ? palette().status.warn : v === "regression" ? palette().status.fail : v === "improvement" ? palette().status.ok : palette().status.skip;

// --- formatting ------------------------------------------------------------------

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
function fmtCount(c) {
  if (c == null) return "—";
  if (c < 1e4) return String(Math.round(c));
  if (c < 1e7) return `${(c / 1e3).toFixed(1)}k`;
  if (c < 1e10) return `${(c / 1e6).toFixed(2)}M`;
  return `${(c / 1e9).toFixed(2)}G`;
}
function fmtNs(t) {
  if (t == null) return "—";
  if (t < 1e3) return `${Math.round(t)} ns`;
  if (t < 1e6) return `${(t / 1e3).toFixed(1)} µs`;
  if (t < 1e9) return `${(t / 1e6).toFixed(2)} ms`;
  return `${(t / 1e9).toFixed(2)} s`;
}
const fmtValue = (v, metric) => (v == null ? "—" : metric === "cycles" ? `${fmtCount(v)} cyc` : fmtNs(v));
const pct = (r) => (r == null ? null : (r - 1) * 100);
function fmtPct(p, digits = 1) {
  if (p == null || !isFinite(p)) return "—";
  const t = Math.abs(p).toFixed(digits);
  return Number(t) === 0 ? `${(0).toFixed(digits)}%` : `${p > 0 ? "+" : "−"}${t}%`;
}
const short = (sha) => (sha ? sha.slice(0, 10) : "");
const commitLink = (sha) =>
  sha ? `<a href="https://github.com/JuliaLang/julia/commit/${esc(sha)}" target="_blank" rel="noopener noreferrer"><code>${esc(short(sha))}</code></a>` : "—";
function fmtDuration(s) {
  if (s == null) return "";
  const m = Math.floor(s / 60);
  return m ? `${m} min ${Math.round(s % 60)} s` : `${Math.round(s)} s`;
}

// --- loading -----------------------------------------------------------------------

const runURL = () => `${API}/${encodeURIComponent(job.pipeline)}/${encodeURIComponent(job.build)}/${encodeURIComponent(job.job)}`;

async function load() {
  const main = document.getElementById("rr-main");
  if (!job.pipeline || !job.build || !job.job) {
    main.innerHTML = `<div class="rr-callout rr-error">This page shows one Runtime benchmarks job: open it as
      <code>/runtime-run?pipeline=julia-pr&amp;build=&lt;number&gt;&amp;job=&lt;job id&gt;</code>, the link the job prints at its end.</div>`;
    return;
  }
  let resp;
  try {
    resp = await fetch(runURL());
  } catch (e) {
    main.innerHTML = `<div class="rr-callout rr-error">Could not reach the server: ${esc(e.message)}</div>`;
    return;
  }
  const body = await resp.json().catch(() => ({}));
  if (resp.status === 409) {
    main.innerHTML = `<div class="rr-callout">The job is still ${esc(body.state || "running")}; this page loads its results once it has finished
      and checks again every minute. ${jobLink()}</div>`;
    setTimeout(load, RETRY_RUNNING_MS);
    return;
  }
  if (!resp.ok) {
    main.innerHTML = `<div class="rr-callout rr-error">${esc(body.error || `HTTP ${resp.status}`)}. ${jobLink()}</div>`;
    return;
  }
  state.data = body;
  if (!body[state.run]) state.run = "main";
  if (state.bench && !runData().benchmarks.some((b) => b.name === state.bench)) state.bench = null;
  render();
}

function jobLink() {
  return `<a href="https://buildkite.com/julialang/${encodeURIComponent(job.pipeline)}/builds/${encodeURIComponent(job.build)}#${encodeURIComponent(job.job)}"
    target="_blank" rel="noopener noreferrer">The job on Buildkite</a>`;
}

async function loadSamples(name) {
  const key = `${state.run}/${name}`;
  if (!samplesCache.has(key)) {
    samplesCache.set(
      key,
      fetch(`${runURL()}?bench=${encodeURIComponent(name)}&run=${state.run}`).then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      }),
    );
  }
  return samplesCache.get(key);
}

function updateURL() {
  const u = new URL(location);
  const set = (k, v) => (v ? u.searchParams.set(k, v) : u.searchParams.delete(k));
  set("run", state.run === "confirm" ? "confirm" : "");
  set("b", state.bench);
  set("show", state.show === "all" ? "all" : "");
  set("q", state.filter);
  history.replaceState(null, "", u);
}

// --- the run's rows ------------------------------------------------------------------

const runData = () => state.data[state.run];
const minOver = (cells, key) => {
  const v = (cells || []).filter((c) => c.status === "ok" && c[key] != null).map((c) => c[key]);
  return v.length ? Math.min(...v) : null;
};

// compare.jl's judgement when compare.json has one: counts that differ by more than 0.1%,
// left out for benchmarks judged on time (threads and the GC move their counts)
function allocsChanged(c, metric, a, b) {
  if (c.alloc_change != null) return c.alloc_change !== "";
  if (a == null || b == null || metric === "time") return false;
  return Math.abs(b - a) > Math.max(0, 0.001 * a);
}

// One row per benchmark: its verdict and change when compared, its values per arm
function rows(run = runData()) {
  const base = run.base, head = run.head || run.arm_order[run.arm_order.length - 1], control = run.control;
  return run.benchmarks.map((b) => {
    const c = b.compare || {};
    const failed = run.arm_order.some((a) => (b.arms[a] || []).some((x) => x.status !== "ok" && x.status !== "skipped"));
    const skipped = run.arm_order.every((a) => (b.arms[a] || []).every((x) => x.status === "skipped"));
    const allocs = Object.fromEntries(run.arm_order.map((a) => [a, minOver(b.arms[a], "allocs")]));
    const bytes = Object.fromEntries(run.arm_order.map((a) => [a, minOver(b.arms[a], "bytes")]));
    return {
      name: b.name,
      category: b.category,
      metric: b.metric,
      ops: b.ops,
      verdict: c.verdict || "same",
      vetoed: !!c.vetoed,
      change: pct(c.ratio),
      blocks: (c.ratios || []).map(pct),
      instr: pct(c.instr_ratio),
      instrChanged: !!c.instr_changed,
      tol: c.tolerance != null ? c.tolerance * 100 : null,
      control: pct(c.control_ratio),
      base: minOver(b.arms[base], "value"),
      head: minOver(b.arms[head], "value"),
      controlValue: control ? minOver(b.arms[control], "value") : null,
      time: minOver(b.arms[head], "min_ns"),
      instructions: minOver(b.arms[head], "instructions"),
      allocs,
      bytes,
      allocsChanged: allocsChanged(c, b.metric, allocs[base], allocs[head]),
      failed,
      skipped,
      error: failed ? run.arm_order.flatMap((a) => b.arms[a] || []).find((x) => x.status !== "ok")?.error : null,
    };
  });
}

// --- page ------------------------------------------------------------------------------

function render() {
  charts.forEach((c) => c.destroy());
  charts = [];
  const d = state.data, run = runData();
  const main = document.getElementById("rr-main");
  const all = rows();
  const nreg = all.filter((r) => r.verdict === "regression").length;
  const nimp = all.filter((r) => r.verdict === "improvement").length;
  const creg = run.categories.filter((c) => c.verdict === "regression").length;
  const failures = (run.failures || []).length + all.filter((r) => r.failed).length;
  const icon = !run.compared ? "⚪" : nreg + creg > 0 ? "🔴" : failures ? "⚠️" : nimp > 0 ? "🟢" : "⚪";
  const verdict = run.compared
    ? `${nreg} regression${nreg === 1 ? "" : "s"}, ${nimp} improvement${nimp === 1 ? "" : "s"}${creg ? `, ${creg} categor${creg === 1 ? "y" : "ies"} regressed` : ""}`
    : `${all.length} benchmarks measured`;
  document.title = `Runtime benchmarks: ${job.pipeline} #${job.build}`;
  main.innerHTML = `
    <section class="rr-head">
      <h2>${icon} Runtime benchmarks: ${esc(verdict)}</h2>
      <div class="rr-sub">${headLine(d)}</div>
      ${d.confirm ? confirmCallout(d) : ""}
      ${d.confirm ? runSwitch() : ""}
      ${armsTable(run)}
      <div class="rr-sub">${machineLine(run)}</div>
      ${problems(run, all)}
    </section>
    ${run.compared ? tiles(all, run) : ""}
    ${run.compared ? `
    <section class="rr-section">
      <div class="rr-section-head">
        <h3>Change by benchmark</h3>
        <span class="rr-hint">${run.head} against ${run.base}${run.control ? ` (triangles: against ${run.control})` : ""}, the shaded band the tolerance; bars the overall change, dots each block, diamonds the instruction count</span>
        <span class="rr-spacer"></span>
        <div class="rr-seg" role="group" aria-label="Rows shown">
          <button class="btn ${state.show === "notable" ? "active" : ""}" onclick="setShow('notable')">Notable</button>
          <button class="btn ${state.show === "all" ? "active" : ""}" onclick="setShow('all')">All ${all.length}</button>
        </div>
      </div>
      <div class="rr-chart" id="rr-change-wrap"><canvas id="rr-change"></canvas></div>
    </section>
    <section class="rr-grid2">
      <div class="rr-section">
        <div class="rr-section-head"><h3>Categories</h3><span class="rr-hint">geometric mean of the ratios, dots each block; ±${SUITE_TOL_PCT}% shaded</span></div>
        <div class="rr-chart" id="rr-cat-wrap"><canvas id="rr-cat"></canvas></div>
      </div>
      <div class="rr-section">
        <div class="rr-section-head"><h3>Instructions against cycles</h3><span class="rr-hint">on the diagonal the code changed; on the vertical axis only the time did (code placement, caches)</span></div>
        <div class="rr-chart rr-chart-square"><canvas id="rr-scatter"></canvas></div>
      </div>
    </section>` : ""}
    <section class="rr-section" id="rr-detail"></section>
    <section class="rr-section">
      <div class="rr-section-head">
        <h3>Benchmarks</h3>
        <input class="sidebar-filter rr-filter" type="search" placeholder="Filter benchmarks" value="${esc(state.filter)}" oninput="setFilter(this.value)" aria-label="Filter benchmarks" />
      </div>
      <div class="ttfx-stats rr-table"><table><thead id="rr-thead"></thead><tbody id="rr-tbody"></tbody></table></div>
    </section>`;
  if (run.compared) {
    drawChangeChart(all, run);
    drawCategoryChart(run);
    drawScatter(all);
  }
  renderTable();
  renderDetail();
}

function headLine(d) {
  const parts = [];
  const repo = /^[\w.-]+\/[\w.-]+$/.test(d.pr_repo || "") ? d.pr_repo : "JuliaLang/julia";
  if (d.pr) parts.push(`<a href="https://github.com/${repo}/pull/${d.pr}" target="_blank" rel="noopener noreferrer">${repo === "JuliaLang/julia" ? "" : esc(repo)}#${d.pr}</a>`);
  const msg = (d.message || "").split("\n")[0];
  if (msg) parts.push(esc(msg));
  parts.push(`${esc(d.pipeline)} <a href="${esc(d.build_url || "#")}" target="_blank" rel="noopener noreferrer">build ${d.build}</a>`);
  parts.push(`<a href="${esc(d.job_url || "#")}" target="_blank" rel="noopener noreferrer">job</a> ${esc(d.job_state || "")}`);
  if (d.finished_at) parts.push(`finished ${esc(d.finished_at.replace("T", " ").replace(/\.\d+Z$|Z$/, " UTC"))}`);
  return parts.join(" · ");
}

function confirmCallout(d) {
  const c = rows(d.confirm);
  const stand = c.filter((r) => r.verdict === "regression").length;
  const dropped = c.filter((r) => r.vetoed).length + d.confirm.categories.filter((x) => x.vetoed).length;
  const ctl = d.confirm.arms.find((a) => a.name === d.confirm.control);
  return `<div class="rr-callout">The comparison flagged regressions, so the job measured them again with a third arm, the master build
    ${commitLink(ctl?.commit)} before the merge-base: <b>${stand}</b> stand${stand === 1 ? "s" : ""}, <b>${dropped}</b> dropped
    (head no different from that build). The job's verdict is the confirmation's.</div>`;
}

function runSwitch() {
  return `<div class="rr-seg rr-runs" role="tablist" aria-label="Run">
    <button class="btn ${state.run === "main" ? "active" : ""}" role="tab" onclick="setRun('main')">First comparison</button>
    <button class="btn ${state.run === "confirm" ? "active" : ""}" role="tab" onclick="setRun('confirm')">Confirmation with the control build</button>
  </div>`;
}

function armsTable(run) {
  const role = (a) => (a === run.base ? "base" : a === run.control ? "control" : a === run.head ? "head" : a);
  const tr = run.arms
    .map(
      (a) => `<tr><td><span class="color-dot" style="background:${armColor(role(a.name))}"></span> ${esc(a.name)}</td>
      <td>${esc(a.version || "—")}</td><td>${commitLink(a.commit)}</td><td>${esc(a.llvm || "—")}</td><td>${esc(a.date || "—")}</td></tr>`,
    )
    .join("");
  return `<div class="ttfx-stats rr-arms"><table><thead><tr><th>Arm</th><th>Julia</th><th>Commit</th><th>LLVM</th><th>Built</th></tr></thead><tbody>${tr}</tbody></table></div>`;
}

function machineLine(run) {
  const m = run.machine || {}, s = run.settings || {};
  const parts = [];
  if (m.cpu) parts.push(`${esc(m.cpu)}${m.perf_cores ? ` (${m.perf_cores} P + ${m.efficiency_cores} E cores)` : ""}`);
  if (s.blocks) parts.push(`${s.blocks} blocks`);
  if (s.threads) parts.push(`${s.threads} threads for <code>parallel</code>`);
  if (run.suite_commit)
    parts.push(`suite <a href="https://github.com/JuliaCI/julia-ci-benchmarks/tree/${esc(run.suite_commit)}" target="_blank" rel="noopener noreferrer"><code>${esc(run.suite_commit.slice(0, 7))}</code></a>`);
  if (run.duration_s) parts.push(`${fmtDuration(run.duration_s)} of benchmarking`);
  return parts.join(" · ");
}

function problems(run, all) {
  const items = [];
  for (const f of run.failures || []) items.push(esc(typeof f === "string" ? f : f.message || JSON.stringify(f)));
  for (const r of all.filter((r) => r.failed)) items.push(`<code>${esc(r.name)}</code>: ${esc((r.error || "failed").slice(0, 200))}`);
  return items.length ? `<div class="rr-callout rr-error"><b>Incomplete.</b><ul>${items.map((i) => `<li>${i}</li>`).join("")}</ul></div>` : "";
}

function tiles(all, run) {
  const n = (f) => all.filter(f).length;
  const tile = (value, label, cls = "") => `<div class="rr-tile ${cls}"><div class="rr-tile-value">${value}</div><div class="rr-tile-label">${label}</div></div>`;
  const reg = n((r) => r.verdict === "regression"), imp = n((r) => r.verdict === "improvement");
  const geo = Math.exp(all.filter((r) => r.change != null).reduce((s, r) => s + Math.log(1 + r.change / 100), 0) / Math.max(1, n((r) => r.change != null)));
  return `<section class="rr-tiles">
    ${tile(reg, "regressions", reg ? "rr-bad" : "")}
    ${tile(imp, "improvements", imp ? "rr-good" : "")}
    ${tile(fmtPct(pct(geo), 2), "geomean of all ratios")}
    ${tile(n((r) => r.instrChanged), "with a different instruction count")}
    ${tile(n((r) => r.allocsChanged), "with different allocations", n((r) => r.allocsChanged) ? "rr-warn" : "")}
    ${run.control ? tile(n((r) => r.vetoed) + run.categories.filter((c) => c.vetoed).length, "dropped against the control") : ""}
  </section>`;
}

// --- charts -----------------------------------------------------------------------------

function baseOptions() {
  const p = palette();
  return {
    responsive: true,
    maintainAspectRatio: false,
    animation: false,
    plugins: { legend: { display: false }, tooltip: { mode: "nearest", intersect: true } },
    color: p.text,
  };
}

// A shaded band per row from -tol to +tol, behind the datasets
const bandPlugin = {
  id: "rrBand",
  beforeDatasetsDraw(chart, _, opts) {
    const { ctx, scales } = chart;
    const x = scales.x, y = scales.y;
    if (!opts.tols) return;
    ctx.save();
    ctx.fillStyle = palette().band;
    const step = opts.tols.length > 1 ? Math.abs(y.getPixelForValue(1) - y.getPixelForValue(0)) : y.height;
    opts.tols.forEach((tol, i) => {
      if (tol == null) return;
      const left = x.getPixelForValue(-tol), right = x.getPixelForValue(tol);
      const cy = y.getPixelForValue(i);
      ctx.fillRect(left, cy - step * 0.42, right - left, step * 0.84);
    });
    // The zero line
    ctx.strokeStyle = palette().text;
    ctx.lineWidth = 1;
    const x0 = x.getPixelForValue(0);
    ctx.beginPath();
    ctx.moveTo(x0, y.top);
    ctx.lineTo(x0, y.bottom);
    ctx.stroke();
    ctx.restore();
  },
};

function notableRows(all) {
  const cmp = all.filter((r) => r.change != null);
  if (state.show === "all") return cmp.sort((a, b) => b.change - a.change);
  const keep = new Set(cmp.filter((r) => r.verdict !== "same" || r.vetoed || r.instrChanged || r.allocsChanged).map((r) => r.name));
  [...cmp].sort((a, b) => Math.abs(b.change) - Math.abs(a.change)).slice(0, NOTABLE_EXTRA).forEach((r) => keep.add(r.name));
  if (state.bench) keep.add(state.bench);
  return cmp.filter((r) => keep.has(r.name)).sort((a, b) => b.change - a.change);
}

function drawChangeChart(all) {
  const p = palette();
  const shown = notableRows(all);
  const labels = shown.map((r) => r.name);
  document.getElementById("rr-change-wrap").style.height = `${Math.max(160, shown.length * 20 + 50)}px`;
  // The axis fits the overall changes, markers and bands; a single block far outside them
  // (a wall-time outlier) is drawn at the edge instead of squashing every bar
  const lim = Math.max(5, ...shown.flatMap((r) => [r.change, r.instr, r.control, r.tol].filter((v) => v != null).map(Math.abs))) * 1.15;
  const clip = (v) => Math.max(-lim, Math.min(lim, v));
  const scatter = (label, pts, style, color, radius = 3.5) => ({
    type: "scatter",
    label,
    data: pts,
    pointStyle: style,
    pointRadius: radius,
    pointHoverRadius: radius + 2,
    backgroundColor: color,
    borderColor: color,
  });
  const datasets = [
    {
      type: "bar",
      label: "Change",
      data: shown.map((r) => [0, r.change]),
      backgroundColor: shown.map((r) => verdictColor(r.verdict, r.vetoed) + (r.verdict === "same" && !r.vetoed ? "66" : "cc")),
      borderColor: shown.map((r) => (r.name === state.bench ? p.strong : "transparent")),
      borderWidth: shown.map((r) => (r.name === state.bench ? 2 : 0)),
      barPercentage: 0.7,
      categoryPercentage: 1,
    },
    scatter("Block", shown.flatMap((r) => r.blocks.map((b) => ({ x: clip(b), y: r.name, r, value: b }))), "circle", p.strong, 2.5),
    scatter("Instructions", shown.filter((r) => r.instr != null).map((r) => ({ x: r.instr, y: r.name, r })), "rectRot", p.text, 4),
  ];
  if (shown.some((r) => r.control != null))
    datasets.push(scatter("Against control", shown.filter((r) => r.control != null).map((r) => ({ x: r.control, y: r.name, r })), "triangle", p.arms.control, 4.5));
  const chart = new Chart(document.getElementById("rr-change"), {
    data: { labels, datasets },
    plugins: [bandPlugin],
    options: {
      ...baseOptions(),
      indexAxis: "y",
      scales: {
        x: {
          min: -lim,
          max: lim,
          title: { display: true, text: "% change against base", color: p.text },
          grid: { color: p.grid },
          ticks: { color: p.text, callback: (v) => fmtPct(v, 0) },
        },
        y: { type: "category", grid: { display: false }, ticks: { color: p.text, autoSkip: false, font: { size: 11 } } },
      },
      plugins: {
        ...baseOptions().plugins,
        rrBand: { tols: shown.map((r) => r.tol) },
        tooltip: {
          callbacks: {
            title: (items) => (items[0].dataset.type === "bar" ? labels[items[0].dataIndex] : items[0].raw.y),
            label: (it) => {
              const r = it.dataset.type === "bar" ? shown[it.dataIndex] : it.raw.r;
              if (it.dataset.label === "Change")
                return [`${fmtPct(r.change)} (${r.verdict}${r.vetoed ? ", dropped against the control" : ""})`, `tolerance ±${r.tol?.toFixed(0)}%`,
                        `${fmtValue(r.base, r.metric)} → ${fmtValue(r.head, r.metric)}`];
              return `${it.dataset.label}: ${fmtPct(it.raw.value ?? it.raw.x)}${Math.abs(it.raw.value ?? 0) > lim ? " (off the axis)" : ""}`;
            },
          },
        },
      },
      onClick: (_, els) => {
        if (!els.length) return;
        const e = els[0];
        const r = e.datasetIndex === 0 ? shown[e.index] : chart.data.datasets[e.datasetIndex].data[e.index].r;
        selectBench(r.name);
      },
    },
  });
  charts.push(chart);
}

const catLabel = (c) => `${c.category} (${c.n})`;

function drawCategoryChart(run) {
  const p = palette();
  const cats = [...run.categories].sort((a, b) => b.geomean - a.geomean);
  document.getElementById("rr-cat-wrap").style.height = `${Math.max(160, cats.length * 24 + 50)}px`;
  const datasets = [
    {
      type: "bar",
      label: "Geomean",
      data: cats.map((c) => [0, pct(c.geomean)]),
      backgroundColor: cats.map((c) => verdictColor(c.verdict, c.vetoed) + (c.verdict === "same" && !c.vetoed ? "66" : "cc")),
      barPercentage: 0.7,
      categoryPercentage: 1,
    },
    {
      type: "scatter",
      label: "Block",
      data: cats.flatMap((c) => c.per_block.map((b) => ({ x: pct(b), y: catLabel(c) }))),
      backgroundColor: p.strong,
      pointRadius: 2.5,
    },
  ];
  if (cats.some((c) => c.control_geomean != null))
    datasets.push({
      type: "scatter",
      label: "Against control",
      data: cats.filter((c) => c.control_geomean != null).map((c) => ({ x: pct(c.control_geomean), y: catLabel(c) })),
      pointStyle: "triangle",
      backgroundColor: p.arms.control,
      pointRadius: 4.5,
    });
  charts.push(
    new Chart(document.getElementById("rr-cat"), {
      data: { labels: cats.map(catLabel), datasets },
      plugins: [bandPlugin],
      options: {
        ...baseOptions(),
        indexAxis: "y",
        scales: {
          x: { grid: { color: p.grid }, ticks: { color: p.text, callback: (v) => fmtPct(v, 1) } },
          y: { type: "category", grid: { display: false }, ticks: { color: p.text, autoSkip: false } },
        },
        plugins: {
          ...baseOptions().plugins,
          rrBand: { tols: cats.map(() => SUITE_TOL_PCT) },
          tooltip: { callbacks: { label: (it) => `${it.dataset.label}: ${fmtPct(it.dataset.type === "bar" ? it.raw[1] : it.raw.x, 2)}` } },
        },
      },
    }),
  );
}

function drawScatter(all) {
  const p = palette();
  const pts = all.filter((r) => r.metric === "cycles" && r.instr != null && r.change != null);
  const lim = Math.max(2, ...pts.map((r) => Math.max(Math.abs(r.instr), Math.abs(r.change)))) * 1.1;
  charts.push(
    new Chart(document.getElementById("rr-scatter"), {
      type: "scatter",
      data: {
        datasets: [
          { type: "line", label: "Same change", data: [{ x: -lim, y: -lim }, { x: lim, y: lim }], borderColor: p.grid, borderDash: [4, 4], pointRadius: 0, borderWidth: 1 },
          {
            label: "Benchmarks",
            data: pts.map((r) => ({ x: r.instr, y: r.change, r })),
            backgroundColor: pts.map((r) => verdictColor(r.verdict, r.vetoed) + (r.verdict === "same" && !r.vetoed ? "99" : "ff")),
            pointRadius: pts.map((r) => (r.name === state.bench ? 6 : 3.5)),
            pointHoverRadius: 6,
          },
        ],
      },
      options: {
        ...baseOptions(),
        scales: {
          x: { min: -lim, max: lim, title: { display: true, text: "instructions", color: p.text }, grid: { color: p.grid }, ticks: { color: p.text, callback: (v) => fmtPct(v, 0) } },
          y: { min: -lim, max: lim, title: { display: true, text: "cycles", color: p.text }, grid: { color: p.grid }, ticks: { color: p.text, callback: (v) => fmtPct(v, 0) } },
        },
        plugins: {
          ...baseOptions().plugins,
          tooltip: {
            filter: (it) => it.datasetIndex === 1,
            callbacks: { label: (it) => `${it.raw.r.name}: cycles ${fmtPct(it.raw.y)}, instructions ${fmtPct(it.raw.x)}` },
          },
        },
        onClick: (_, els) => {
          const e = els.find((x) => x.datasetIndex === 1);
          if (e) selectBench(pts[e.index].name);
        },
      },
    }),
  );
}

// --- the picked benchmark ------------------------------------------------------------------

async function renderDetail() {
  const el = document.getElementById("rr-detail");
  const run = runData();
  if (!state.bench) {
    el.innerHTML = `<div class="rr-section-head"><h3>Samples</h3><span class="rr-hint">pick a benchmark in a chart or the table to see every sample of every arm and block</span></div>`;
    return;
  }
  const b = run.benchmarks.find((x) => x.name === state.bench);
  const r = rows().find((x) => x.name === state.bench);
  el.innerHTML = `<div class="rr-section-head"><h3>${esc(b.name)}</h3>
      <span class="rr-hint">${b.metric === "cycles" ? "cycles of the calling thread" : "wall time"} per call (${b.ops} work items), every sample of each
      process; the line marks the 5th percentile, the value compare.jl judges${r.change != null ? ` · ${fmtPct(r.change)}, ${r.verdict}` : ""}</span>
      <span class="rr-spacer"></span><button class="btn" onclick="selectBench(null)">Close</button></div>
    <div class="rr-grid2">
      <div class="rr-chart rr-chart-detail"><canvas id="rr-samples"></canvas></div>
      <div class="rr-chart rr-chart-detail"><canvas id="rr-instr"></canvas></div>
    </div>
    <div class="ttfx-stats rr-table" id="rr-cells"></div>`;
  el.querySelector("#rr-cells").innerHTML = cellsTable(b, run);
  let s;
  try {
    s = await loadSamples(b.name);
  } catch (e) {
    el.querySelector(".rr-grid2").innerHTML = `<div class="rr-callout rr-error">Could not load the samples: ${esc(e.message)}</div>`;
    return;
  }
  if (state.bench !== b.name || !document.getElementById("rr-samples")) return;
  stripChart("rr-samples", s, run, "values", b.metric === "cycles" ? "cycles" : "time", b);
  stripChart("rr-instr", s, run, "instructions", "instructions", b);
}

function cellsTable(b, run) {
  const tr = [];
  for (const a of run.arm_order)
    for (const c of b.arms[a] || []) {
      if (c.status !== "ok") {
        tr.push(`<tr><td>${esc(a)}</td><td class="num">${c.block}</td><td colspan="7">${esc(c.status)}: ${esc(c.error || "")}</td></tr>`);
        continue;
      }
      tr.push(`<tr><td><span class="color-dot" style="background:${armColor(a === run.base ? "base" : a === run.control ? "control" : "head")}"></span> ${esc(a)}</td>
        <td class="num">${c.block}</td><td class="num">${fmtValue(c.value, c.metric)}</td><td class="num">${fmtValue(c.q[2], c.metric)}</td>
        <td class="num">${c.n}</td><td class="num">${fmtCount(c.instructions)}</td><td class="num">${fmtNs(c.min_ns)}</td>
        <td class="num">${c.allocs ?? "—"}</td><td class="num">${c.bytes != null ? fmtCount(c.bytes) + " B" : "—"}</td><td class="num">${fmtNs(c.gc_ns)}</td></tr>`);
    }
  return `<table><thead><tr><th>Arm</th><th class="num">Block</th><th class="num">5th pct.</th><th class="num">Median</th><th class="num">Samples</th>
    <th class="num">Instructions</th><th class="num">Min. time</th><th class="num">Allocs</th><th class="num">Bytes</th><th class="num">GC per call</th></tr></thead>
    <tbody>${tr.join("")}</tbody></table>`;
}

// Every sample of each arm and block side by side, jittered, with the 5th percentile marked
function stripChart(id, s, run, key, unit, b) {
  const p = palette();
  const groups = [];
  const blocks = [...new Set(run.arm_order.flatMap((a) => (s.arms[a] || []).map((x) => x.block)))].sort((x, y) => x - y);
  for (const blk of blocks)
    for (const a of run.arm_order) {
      const cell = (s.arms[a] || []).find((x) => x.block === blk);
      if (cell && cell[key]?.length) groups.push({ arm: a, block: blk, values: cell[key] });
    }
  const canvas = document.getElementById(id);
  if (!groups.length) {
    canvas.parentElement.innerHTML = `<div class="rr-empty">No ${unit === "instructions" ? "instruction counts (no counters)" : "samples"}</div>`;
    return;
  }
  const role = (a) => (a === run.base ? "base" : a === run.control ? "control" : "head");
  // A deterministic jitter, so a redraw does not move the points
  const jitter = (i) => ((Math.sin(i * 12.9898) * 43758.5453) % 1) * 0.3;
  const datasets = groups.map((g, gi) => ({
    label: `${g.arm} · block ${g.block}`,
    data: g.values.map((v, i) => ({ x: gi + jitter(i), y: v })),
    backgroundColor: armColor(role(g.arm)) + "66",
    pointRadius: 1.8,
    pointHoverRadius: 4,
  }));
  groups.forEach((g, gi) => {
    const sorted = [...g.values].sort((x, y) => x - y);
    const p5 = sorted[Math.max(0, Math.ceil(sorted.length / 20) - 1)];
    datasets.push({ type: "line", label: `${g.arm} · block ${g.block}: 5th percentile`, data: [{ x: gi - 0.4, y: p5 }, { x: gi + 0.4, y: p5 }],
                    borderColor: armColor(role(g.arm)), borderWidth: 2, pointRadius: 0 });
  });
  const fmt = (v) => (unit === "time" ? fmtNs(v) : fmtCount(v));
  charts.push(
    new Chart(canvas, {
      type: "scatter",
      data: { datasets },
      options: {
        ...baseOptions(),
        scales: {
          x: {
            min: -0.6,
            max: groups.length - 0.4,
            grid: { display: false },
            ticks: { stepSize: 1, color: p.text, callback: (v) => (Number.isInteger(v) && groups[v] ? `${groups[v].arm} ${groups[v].block}` : "") },
          },
          y: { title: { display: true, text: unit, color: p.text }, grid: { color: p.grid }, ticks: { color: p.text, callback: fmt } },
        },
        plugins: {
          ...baseOptions().plugins,
          title: { display: true, text: unit === "instructions" ? "Instructions retired per call" : `${b.metric === "cycles" ? "Cycles" : "Wall time"} per call`, color: p.text },
          tooltip: { callbacks: { label: (it) => `${it.dataset.label}: ${fmt(it.raw.y)}` } },
        },
      },
    }),
  );
}

// --- table -----------------------------------------------------------------------------------

function renderTable() {
  const run = runData();
  const all = rows();
  const q = state.filter.toLowerCase();
  const shown = all.filter((r) => !q || r.name.toLowerCase().includes(q));
  const cols = run.compared
    ? [
        ["name", "Benchmark", (r) => r.name],
        ["metric", "Metric", (r) => r.metric],
        ["base", run.base, (r) => r.base],
        ["head", run.head, (r) => r.head],
        ...(run.control ? [["controlValue", run.control, (r) => r.controlValue]] : []),
        ["change", "Change", (r) => r.change],
        ["blocks", "Per block", (r) => r.change],
        ["tol", "Tolerance", (r) => r.tol],
        ["instr", "Instr.", (r) => r.instr],
        ["allocs", "Allocs", (r) => r.allocs[run.head]],
        ["verdict", "Verdict", (r) => r.verdict + (r.vetoed ? " dropped" : "")],
      ]
    : [
        ["name", "Benchmark", (r) => r.name],
        ["metric", "Metric", (r) => r.metric],
        ["head", "Value", (r) => r.head],
        ["time", "Time", (r) => r.time],
        ["perop", "Per item", (r) => (r.time != null ? r.time / r.ops : null)],
        ["instructions", "Instructions", (r) => r.instructions],
        ["allocs", "Allocs", (r) => r.allocs[run.head]],
        ["bytes", "Bytes", (r) => r.bytes[run.head]],
      ];
  if (!cols.some((c) => c[0] === state.sort.col)) state.sort = { col: "name", asc: true };
  const sortCol = cols.find((c) => c[0] === state.sort.col);
  shown.sort((a, b) => {
    const x = sortCol[2](a), y = sortCol[2](b);
    if (x == null) return 1;
    if (y == null) return -1;
    const c = typeof x === "string" ? x.localeCompare(y) : x - y;
    return state.sort.asc ? c : -c;
  });
  document.getElementById("rr-thead").innerHTML = `<tr>${cols
    .map(([k, label]) => `<th class="sortable ${k === "name" || k === "metric" || k === "verdict" ? "" : "num"}" onclick="setSort('${k}')">${esc(label)}${k === state.sort.col ? (state.sort.asc ? " ▲" : " ▼") : ""}</th>`)
    .join("")}</tr>`;
  const cls = (r) => (r.verdict === "regression" ? "ttfx-up" : r.verdict === "improvement" ? "ttfx-down" : "");
  document.getElementById("rr-tbody").innerHTML = shown
    .map((r) => {
      const name = `<td>${esc(r.name)}${r.failed ? ` <span class="ttfx-up" title="${esc(r.error || "")}">failed</span>` : ""}</td>`;
      const allocs = r.allocsChanged ? `<span class="rr-warn-text" title="allocations differ between the arms">${r.allocs[run.base]} → ${r.allocs[run.head]}</span>` : String(r.allocs[run.head] ?? "—");
      const cells = run.compared
        ? `${name}<td>${r.metric}</td><td class="num">${fmtValue(r.base, r.metric)}</td><td class="num">${fmtValue(r.head, r.metric)}</td>
           ${run.control ? `<td class="num">${fmtValue(r.controlValue, r.metric)}</td>` : ""}
           <td class="num ${cls(r)}">${fmtPct(r.change)}</td><td class="num"><small>${r.blocks.map((b) => fmtPct(b)).join(" ")}</small></td>
           <td class="num">${r.tol != null ? `±${r.tol.toFixed(0)}%` : "—"}</td>
           <td class="num ${r.instrChanged ? "rr-warn-text" : ""}">${fmtPct(r.instr)}</td><td class="num">${allocs}</td>
           <td class="${cls(r)}">${r.vetoed ? "dropped" : r.verdict === "same" ? "" : r.verdict}</td>`
        : `${name}<td>${r.metric}</td><td class="num">${fmtValue(r.head, r.metric)}</td><td class="num">${fmtNs(r.time)}</td>
           <td class="num">${r.time != null ? fmtNs(r.time / r.ops) : "—"}</td><td class="num">${fmtCount(r.instructions)}</td>
           <td class="num">${allocs}</td><td class="num">${r.bytes[run.head] != null ? fmtCount(r.bytes[run.head]) + " B" : "—"}</td>`;
      return `<tr class="${r.name === state.bench ? "highlight" : ""}" data-name="${esc(r.name)}">${cells}</tr>`;
    })
    .join("");
  document.querySelectorAll("#rr-tbody tr").forEach((tr) => (tr.onclick = () => selectBench(tr.dataset.name)));
}

// --- interactions --------------------------------------------------------------------------------

function selectBench(name) {
  state.bench = state.bench === name ? null : name;
  updateURL();
  render();
  if (state.bench) document.getElementById("rr-detail").scrollIntoView({ behavior: "smooth", block: "start" });
}
function setShow(v) {
  state.show = v;
  updateURL();
  render();
}
function setRun(v) {
  state.run = v;
  if (state.bench && !runData().benchmarks.some((b) => b.name === state.bench)) state.bench = null;
  updateURL();
  render();
}
function setFilter(v) {
  state.filter = v;
  updateURL();
  renderTable();
}
function setSort(col) {
  state.sort = { col, asc: state.sort.col === col ? !state.sort.asc : col === "name" || col === "metric" };
  renderTable();
}

applyTheme();
// Chart.js loads deferred like this script, and before it
load();
