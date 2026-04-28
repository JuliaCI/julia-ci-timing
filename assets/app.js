"use strict";

// === Constants ===
const FAILED_STATES = ["failed", "timed_out", "canceled"];
const VALID_TIME_RANGES = [0, 7, 14, 30, 60, 90, 120, 240, 365];
const VALID_LINE_TYPES = ["raw", "7", "30", "90"];
const DEFAULT_TIME_RANGE = 30;
const DEFAULT_LINE_TYPE = "7";
const STORAGE_KEY = "julia-ci-timing-config";
const DATA_REFRESH_INTERVAL = 5 * 60 * 1000; // 5 minutes
const AGO_UPDATE_INTERVAL = 60 * 1000; // 1 minute

// Data freshness
const STALE_DATA_THRESHOLD_DAYS = 3; // Show warning if data older than 3 days (matches CI update schedule)
const STALE_DATA_THRESHOLD_MS = STALE_DATA_THRESHOLD_DAYS * 24 * 60 * 60 * 1000;

// Pass rate tracking
const PASS_RATE_DAYS = 14; // Track pass rate over last 14 days
const PASS_RATE_THRESHOLD = 0.9; // Below 90% shows warning
const PASS_RATE_MIN_RUNS = 3; // Need at least 3 runs to show warning

// Statistical significance
const TREND_SIGNIFICANCE_P_VALUE = 0.05; // p-value threshold for statistical significance
const TREND_SIGNIFICANCE_R_SQUARED = 0.1; // R² threshold (trend must explain >10% of variance)
const TREND_MIN_POINTS = 3; // Minimum data points required for trend analysis

// === State ===
let chart = null;
let data = null;
let statsTableSortColumn = "median";
let statsTableSortAsc = false; // false = descending (largest first)

// Fetch a gzipped JSON file and return the parsed value.
// Throws on non-2xx responses; AbortError if the signal fires.
async function loadGzipJson(url, options = {}) {
  const resp = await fetch(url, options);
  if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
  const decompressed = resp.body.pipeThrough(new DecompressionStream("gzip"));
  return new Response(decompressed).json();
}
let selectedJobs = new Set();
let timeRangeDays = DEFAULT_TIME_RANGE;
let lineType = DEFAULT_LINE_TYPE;
let excludedStates = new Set(["canceled"]); // States to exclude from display (canceled hidden by default)
let excludedHosts = new Set(); // Hosts to exclude from display
let expandedJobs = new Set(); // Jobs expanded in stats table
let jobColors = {};
let chartMetadata = {};
// Custom zoom state (null = use timeRangeDays preset)
let customXMin = null; // timestamp or null
let customXMax = null; // timestamp or null
let customYMin = null; // seconds or null
let customYMax = null; // seconds or null

// === Comparison Mode State ===
// Format: { build: number, base: number, jobs: { jobName: { duration: seconds, baseline: seconds } } }
let comparisonData = null;

// === Helper Functions ===
const isFailedState = (state) => FAILED_STATES.includes(state);
const getRunState = (run) => run.state || "passed";

// Check if any selected job is a coverage job
function hasSelectedCoverageJob() {
  for (const jobName of selectedJobs) {
    const lower = jobName.toLowerCase();
    if (lower.includes("coverage")) return true;
  }
  return false;
}

// Get coverage data from pre-fetched data in timing_summary.json
function getCoverageForCommit(commit) {
  if (!data?.coverage) return null;
  // Try full commit SHA first, then prefix match
  if (data.coverage[commit]) {
    return data.coverage[commit];
  }
  // Try prefix match (commits in job data are truncated to 8 chars)
  for (const [sha, cov] of Object.entries(data.coverage)) {
    if (sha.startsWith(commit) || commit.startsWith(sha.slice(0, 8))) {
      return cov;
    }
  }
  return null;
}

function refreshAllUI() {
  updateMatrixHighlights();
  updateJobCount();
  updateHostFilterUI();
  updateChart();
  updateStatsTable();
  updateToolbarButtons();
}

function toggleJobsSelection(jobs) {
  if (jobs.length === 0) return;
  const allSelected = jobs.every((j) => selectedJobs.has(j.name));
  for (const { name } of jobs) {
    if (allSelected) {
      selectedJobs.delete(name);
    } else {
      selectedJobs.add(name);
    }
  }
}

// Buildkite emoji mapping - use their actual images
const BUILDKITE_EMOJI_BASE =
  "https://buildkiteassets.com/emojis/img-buildkite-64";
const emojiImageMap = {
  ":macos:": `${BUILDKITE_EMOJI_BASE}/mac.png`,
  ":apple:": `${BUILDKITE_EMOJI_BASE}/mac.png`,
  ":mac:": `${BUILDKITE_EMOJI_BASE}/mac.png`,
  ":linux:": `${BUILDKITE_EMOJI_BASE}/linux.png`,
  ":windows:": `${BUILDKITE_EMOJI_BASE}/windows.png`,
  ":freebsd:": `${BUILDKITE_EMOJI_BASE}/freebsd.png`,
};
const emojiMap = {
  ":rocket:": "🚀",
  ":gear:": "⚙️",
  ":package:": "📦",
  ":test_tube:": "🧪",
  ":memo:": "📝",
  ":lock:": "🔒",
  ":key:": "🔑",
  ":warning:": "⚠️",
  ":x:": "❌",
  ":white_check_mark:": "✅",
  ":hourglass:": "⏳",
  ":zap:": "⚡",
};

// Unicode fallbacks for canvas/tooltip contexts that can't render HTML
const emojiTextMap = {
  ":macos:": "🍎",
  ":apple:": "🍎",
  ":mac:": "🍎",
  ":linux:": "🐧",
  ":windows:": "🪟",
  ":freebsd:": "😈",
};

function convertEmoji(text) {
  let result = text;
  // First, replace with Buildkite images
  for (const [code, url] of Object.entries(emojiImageMap)) {
    result = result.replaceAll(
      code,
      `<img src="${url}" alt="${code}" class="bk-emoji">`,
    );
  }
  // Then replace remaining emoji codes with unicode
  for (const [code, emoji] of Object.entries(emojiMap)) {
    result = result.replaceAll(code, emoji);
  }
  return result;
}

// Plain text version for canvas tooltips
function convertEmojiText(text) {
  let result = text;
  for (const [code, emoji] of Object.entries(emojiTextMap)) {
    result = result.replaceAll(code, emoji);
  }
  for (const [code, emoji] of Object.entries(emojiMap)) {
    result = result.replaceAll(code, emoji);
  }
  return result;
}

// Escape HTML special characters for safe insertion into attributes
function escapeHtml(text) {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Generate visually distinct colors for jobs using golden ratio distribution.
 * Colors are in HSL format for perceptually uniform distribution.
 * @param {number} count - Number of distinct colors to generate
 * @returns {Array<string>} Array of HSL color strings
 */
function generateColors(count) {
  const colors = [];
  const goldenRatio = 0.618033988749895;
  let hue = 0;
  for (let i = 0; i < count; i++) {
    // Use golden ratio to spread hues evenly
    hue = (hue + goldenRatio) % 1;
    // Vary saturation and lightness slightly for more distinction
    const saturation = 65 + (i % 3) * 10; // 65%, 75%, 85%
    const lightness = 45 + (i % 5) * 5; // 45%, 50%, 55%, 60%, 65%
    colors.push(`hsl(${Math.floor(hue * 360)}, ${saturation}%, ${lightness}%)`);
  }
  return colors;
}

// Apply a hue shift to an HSL color
function shiftHue(baseColor, hueShift) {
  const hslMatch = baseColor.match(/hsl\((\d+),\s*(\d+)%,\s*(\d+)%\)/);
  if (hslMatch) {
    const h = (parseInt(hslMatch[1]) + hueShift + 360) % 360;
    const s = parseInt(hslMatch[2]);
    const l = parseInt(hslMatch[3]);
    return `hsl(${h}, ${s}%, ${l}%)`;
  }
  return baseColor;
}

// Get perceptual hue spread multiplier based on base hue
// Human perception of hue variation is non-uniform - greens need
// slightly larger shifts to appear distinct
function getPerceptualHueMultiplier(baseHue) {
  // Normalize hue to 0-360
  const h = ((baseHue % 360) + 360) % 360;
  // Green region needs modestly larger shifts
  if (h >= 80 && h < 140) return 1.9; // Green
  if (h >= 50 && h < 80) return 1.4; // Yellow-green
  if (h >= 140 && h < 180) return 1.3; // Cyan-green
  return 1.0; // Others have good discrimination
}

// Extract hue from an HSL color string
function getHueFromColor(color) {
  const hslMatch = color.match(/hsl\((\d+),\s*(\d+)%,\s*(\d+)%\)/);
  return hslMatch ? parseInt(hslMatch[1]) : 0;
}

function formatDuration(seconds) {
  if (seconds == null) return '<span class="text-muted">—</span>';
  if (seconds < 60) return `${seconds.toFixed(1)}s`;
  const mins = Math.floor(seconds / 60);
  const secs = Math.round(seconds % 60);
  if (mins < 60) {
    return secs > 0 ? `${mins}m ${secs}s` : `${mins}m`;
  }
  const hours = Math.floor(mins / 60);
  const remainMins = mins % 60;
  return remainMins > 0 ? `${hours}h ${remainMins}m` : `${hours}h`;
}

/**
 * Standard normal cumulative distribution function approximation.
 * Uses Abramowitz and Stegun's polynomial approximation.
 * @param {number} z - Z-score value
 * @returns {number} Cumulative probability P(Z ≤ z)
 */
function normalCDF(z) {
  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  const p = 0.3275911;

  const sign = z < 0 ? -1 : 1;
  z = Math.abs(z) / Math.sqrt(2);

  const t = 1.0 / (1.0 + p * z);
  const y =
    1.0 - ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t * Math.exp(-z * z);

  return 0.5 * (1.0 + sign * y);
}

/**
 * Compute trend using linear regression with statistical significance testing.
 * Uses t-distribution for p-value calculation and requires R² > 0.1 for significance.
 * @param {Array<Object>} runs - Array of run objects with duration and date properties
 * @returns {Object|null} Trend analysis object with slope, pValue, rSquared, percentChange, etc., or null if insufficient data
 */
function computeTrend(runs) {
  if (runs.length < TREND_MIN_POINTS) return null;

  // Convert to numeric: x = timestamp (days), y = duration (seconds)
  const points = runs.map((r) => ({
    x: new Date(r.date).getTime() / (1000 * 60 * 60 * 24), // days since epoch
    y: r.duration,
  }));

  const n = points.length;
  const sumX = points.reduce((s, p) => s + p.x, 0);
  const sumY = points.reduce((s, p) => s + p.y, 0);
  const sumXY = points.reduce((s, p) => s + p.x * p.y, 0);
  const sumX2 = points.reduce((s, p) => s + p.x * p.x, 0);

  const meanX = sumX / n;
  const meanY = sumY / n;

  // Slope and intercept
  const denom = sumX2 - n * meanX * meanX;
  if (Math.abs(denom) < 1e-10) return null;

  const slope = (sumXY - n * meanX * meanY) / denom;

  // Standard error of slope for t-test
  const yPred = points.map((p) => meanY + slope * (p.x - meanX));
  const ssRes = points.reduce((s, p, i) => s + (p.y - yPred[i]) ** 2, 0);
  const ssTot = points.reduce((s, p) => s + (p.y - meanY) ** 2, 0);

  const rSquared = ssTot > 0 ? 1 - ssRes / ssTot : 0;

  // Standard error of slope
  const mse = ssRes / (n - 2);
  const seSlope = Math.sqrt(mse / (sumX2 - n * meanX * meanX));

  // t-statistic
  const tStat = seSlope > 0 ? Math.abs(slope) / seSlope : 0;

  // Approximate p-value using t-distribution (two-tailed)
  // Using approximation for degrees of freedom = n - 2
  const df = n - 2;
  const pValue = tDistributionPValue(tStat, df);

  // Calculate percentage change over the time range
  const minX = Math.min(...points.map((p) => p.x));
  const maxX = Math.max(...points.map((p) => p.x));
  const intercept = meanY - slope * meanX;
  const startValue = intercept + slope * minX;
  const endValue = intercept + slope * maxX;
  const percentChange =
    startValue > 0 ? ((endValue - startValue) / startValue) * 100 : 0;
  const absoluteDelta = endValue - startValue; // Total change in seconds

  // Require both statistical significance AND meaningful effect size
  // R² > 0.1 means the trend explains at least 10% of variance
  const isSignificant =
    pValue < TREND_SIGNIFICANCE_P_VALUE &&
    rSquared > TREND_SIGNIFICANCE_R_SQUARED;

  return {
    slope, // seconds per day
    slopePerDay: slope,
    pValue,
    rSquared,
    significant: isSignificant,
    direction: slope > 0 ? "up" : slope < 0 ? "down" : "flat",
    percentChange,
    absoluteDelta,
    intercept, // y-intercept for regression line
    minX, // earliest time (days since epoch)
    maxX, // latest time (days since epoch)
    n,
  };
}

// Approximate two-tailed p-value for t-distribution
function tDistributionPValue(t, df) {
  // For very small t, not significant
  if (Math.abs(t) < 0.001) return 1.0;

  // Use normal approximation for large df
  if (df >= 30) {
    return 2 * (1 - normalCDF(Math.abs(t)));
  }

  // For smaller df, use the beta function relationship:
  // p-value = I(df/(df+t²), df/2, 1/2) where I is the regularized incomplete beta
  // Approximation using Student's t-distribution properties
  const x = df / (df + t * t);

  // Continued fraction approximation for incomplete beta
  // This is more accurate for small df
  const a = df / 2;
  const b = 0.5;

  // Use series expansion approximation
  let betaI;
  if (x < (a + 1) / (a + b + 2)) {
    betaI = betaIncomplete(x, a, b);
  } else {
    betaI = 1 - betaIncomplete(1 - x, b, a);
  }

  return Math.min(1, Math.max(0, betaI));
}

// Regularized incomplete beta function approximation
function betaIncomplete(x, a, b) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;

  // Use series expansion for small x
  const lnBeta = gammaLn(a) + gammaLn(b) - gammaLn(a + b);
  const front = Math.exp(Math.log(x) * a + Math.log(1 - x) * b - lnBeta) / a;

  // Lentz's algorithm for continued fraction
  const maxIter = 100;
  const eps = 1e-10;

  let f = 1,
    c = 1,
    d = 0;
  for (let m = 0; m <= maxIter; m++) {
    const m2 = 2 * m;

    // Even step
    let aa = m === 0 ? 1 : (m * (b - m) * x) / ((a + m2 - 1) * (a + m2));
    d = 1 + aa * d;
    if (Math.abs(d) < 1e-30) d = 1e-30;
    c = 1 + aa / c;
    if (Math.abs(c) < 1e-30) c = 1e-30;
    d = 1 / d;
    f *= d * c;

    // Odd step
    aa = -((a + m) * (a + b + m) * x) / ((a + m2) * (a + m2 + 1));
    d = 1 + aa * d;
    if (Math.abs(d) < 1e-30) d = 1e-30;
    c = 1 + aa / c;
    if (Math.abs(c) < 1e-30) c = 1e-30;
    d = 1 / d;
    const delta = d * c;
    f *= delta;

    if (Math.abs(delta - 1) < eps) break;
  }

  return front * f;
}

// Log gamma function approximation (Lanczos)
function gammaLn(x) {
  const g = 7;
  const c = [
    0.99999999999980993, 676.5203681218851, -1259.1392167224028,
    771.32342877765313, -176.61502916214059, 12.507343278686905,
    -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7,
  ];

  if (x < 0.5) {
    return Math.log(Math.PI / Math.sin(Math.PI * x)) - gammaLn(1 - x);
  }

  x -= 1;
  let sum = c[0];
  for (let i = 1; i < g + 2; i++) {
    sum += c[i] / (x + i);
  }
  const t = x + g + 0.5;
  return (
    0.5 * Math.log(2 * Math.PI) + (x + 0.5) * Math.log(t) - t + Math.log(sum)
  );
}

function formatTrend(
  trend,
  lineColor = null,
  percentageMode = false,
  yAxisID = "y",
) {
  if (!trend || trend.n < TREND_MIN_POINTS) {
    return {
      html: '<span class="text-muted" title="Not enough data points">—</span>',
      trendData: null,
    };
  }

  const { slope, pValue, significant, rSquared, percentChange, absoluteDelta } =
    trend;
  const absSlope = Math.abs(slope);

  // Convert slope to human-readable format (per day)
  let slopeText;
  if (percentageMode) {
    // For percentage mode, slope is in %/day
    slopeText = `${slope >= 0 ? "+" : ""}${slope.toFixed(2)}%/day`;
  } else if (absSlope < 1) {
    slopeText = `${(absSlope * 60).toFixed(1)}s/day`;
  } else if (absSlope < 60) {
    slopeText = `${absSlope.toFixed(1)}s/day`;
  } else {
    slopeText = `${(absSlope / 60).toFixed(1)}m/day`;
  }

  // Format absolute delta
  let deltaText;
  if (percentageMode) {
    // For percentage mode, delta is in percentage points
    deltaText = `${absoluteDelta >= 0 ? "+" : ""}${absoluteDelta.toFixed(1)}pp`;
  } else {
    const absDelta = Math.abs(absoluteDelta);
    if (absDelta < 60) {
      deltaText = `${absoluteDelta >= 0 ? "+" : "-"}${absDelta.toFixed(1)}s`;
    } else {
      deltaText = `${absoluteDelta >= 0 ? "+" : "-"}${(absDelta / 60).toFixed(1)}m`;
    }
  }

  // Format percentage change
  const pctSign = percentChange > 0 ? "+" : "";
  const pctText = `${pctSign}${percentChange.toFixed(1)}%`;

  // Direction arrow and color
  let arrow, color;
  if (!significant) {
    arrow = "→";
    color = "var(--color-fg-muted)";
  } else if (slope > 0) {
    arrow = "↗";
    color = "var(--color-danger-fg)"; // Getting slower is bad
  } else {
    arrow = "↘";
    color = "var(--color-success-fg)"; // Getting faster is good
  }

  // Confidence indicator
  const confidence = significant ? (pValue < 0.01 ? "★★" : "★") : "";
  const pText = pValue < 0.001 ? "<0.001" : pValue.toFixed(3);
  const title = percentageMode
    ? `${slopeText} (${pctText}, ${deltaText} over period)\np-value: ${pText}\nR²: ${(rSquared * 100).toFixed(1)}%\n${significant ? "Statistically significant" : "Not significant"}`
    : `${slope > 0 ? "+" : ""}${slopeText} (${pctText}, ${deltaText} over period)\np-value: ${pText}\nR²: ${(rSquared * 100).toFixed(1)}%\n${significant ? "Statistically significant" : "Not significant"}`;

  const displayText = significant ? `${pctText}` : "flat";

  // Encode trend data for hover handlers (include line color and axis)
  const trendData = JSON.stringify({
    slope: trend.slope,
    intercept: trend.intercept,
    minX: trend.minX,
    maxX: trend.maxX,
    lineColor: lineColor || "rgba(128, 128, 128, 0.8)",
    yAxisID: yAxisID,
  }).replace(/'/g, "&#39;");

  // Return content designed to be placed in a td with class="trend-cell"
  return {
    html: `<span style="color: ${color}" title="${title}">${arrow} ${displayText} ${confidence}</span>`,
    trendData,
  };
}

// Regression line dataset management
let regressionLineDataset = null;

function showRegressionLine(trendData, lineColor = "rgba(128, 128, 128, 0.7)") {
  if (!chart || !trendData) return;

  const { slope, intercept, minX, maxX, yAxisID } = trendData;

  // Convert days since epoch back to milliseconds
  const msPerDay = 1000 * 60 * 60 * 24;
  const startX = minX * msPerDay;
  const endX = maxX * msPerDay;
  const startY = intercept + slope * minX;
  const endY = intercept + slope * maxX;

  // Create regression line dataset
  regressionLineDataset = {
    label: "Trend line",
    data: [
      { x: new Date(startX), y: startY },
      { x: new Date(endX), y: endY },
    ],
    borderColor: lineColor,
    borderWidth: 2,
    borderDash: [6, 4],
    fill: false,
    pointRadius: 0,
    pointHoverRadius: 0,
    tension: 0,
    yAxisID: yAxisID || "y",
    order: -1, // Draw on top
  };

  chart.data.datasets.push(regressionLineDataset);
  chart.update("none");
}

function hideRegressionLine() {
  if (!chart || !regressionLineDataset) return;

  const idx = chart.data.datasets.indexOf(regressionLineDataset);
  if (idx !== -1) {
    chart.data.datasets.splice(idx, 1);
    chart.update("none");
  }
  regressionLineDataset = null;
}

// Track currently hovered trend cell to properly handle mouseover/mouseout
let currentTrendCell = null;

// Event delegation for trend cell hover using mouseover/mouseout (which bubble)
document.addEventListener("mouseover", (e) => {
  const cell = e.target.closest?.(".trend-cell");
  if (cell && cell !== currentTrendCell && cell.dataset.trend) {
    currentTrendCell = cell;
    try {
      const trendData = JSON.parse(cell.dataset.trend.replace(/&#39;/g, "'"));
      showRegressionLine(trendData, trendData.lineColor);
    } catch (err) {
      // Ignore parse errors
    }
  } else if (!cell && currentTrendCell) {
    currentTrendCell = null;
    hideRegressionLine();
  }
});

document.addEventListener("mouseout", (e) => {
  if (!currentTrendCell) return;
  // Check if we're leaving to an element outside the current trend cell
  const relatedCell = e.relatedTarget?.closest?.(".trend-cell");
  if (relatedCell !== currentTrendCell) {
    currentTrendCell = null;
    hideRegressionLine();
  }
});

function filterRunsByState(runs, cutoff, maxCutoff = null, filterHosts = true) {
  return runs.filter((r) => {
    const date = new Date(r.date);
    if (cutoff && date < cutoff) return false;
    if (maxCutoff && date > maxCutoff) return false;
    const runState = getRunState(r);
    if (excludedStates.size > 0 && excludedStates.has(runState)) return false;
    if (filterHosts && excludedHosts.size > 0 && excludedHosts.has(r.agent))
      return false;
    return true;
  });
}

// Calculate pass rate for a job over the last N days
function getJobPassRate(jobData) {
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - PASS_RATE_DAYS);

  let total = 0,
    passed = 0,
    failed = 0,
    timedOut = 0,
    canceled = 0,
    retries = 0;
  for (const run of jobData.recent) {
    const date = new Date(run.date);
    if (date < cutoff) continue;
    total++;
    const state = run.state || "passed";
    if (state === "passed") passed++;
    else if (state === "failed") failed++;
    else if (state === "timed_out") timedOut++;
    else if (state === "canceled") canceled++;
    // Count retries (retry > 0 means this is a retry attempt)
    if (run.retry > 0) retries++;
  }
  return {
    total,
    passed,
    failed,
    timedOut,
    canceled,
    retries,
    rate: total > 0 ? passed / total : 1,
  };
}

// Check if a job has recent failures or timeouts
// Returns object with: { hasFailure, hasTimeout, failedCount, timedOutCount, totalCount, tooltipFailure, tooltipTimeout }
// Shows issues if:
// 1. There was a failure/timeout in the last 24 hours, OR
// 2. There was a failure/timeout in the last 3 runs AND at least one run is within PASS_RATE_DAYS
function hasRecentFailure(jobData) {
  if (!jobData.recent || jobData.recent.length === 0) {
    return {
      hasFailure: false,
      hasTimeout: false,
      failedCount: 0,
      timedOutCount: 0,
      totalCount: 0,
      tooltipFailure: "",
      tooltipTimeout: "",
    };
  }

  const now = new Date();
  const last24h = new Date(now.getTime() - 24 * 60 * 60 * 1000);
  const recentCutoff = new Date();
  recentCutoff.setDate(recentCutoff.getDate() - PASS_RATE_DAYS);

  // Check last 3 runs
  const lastThreeRuns = jobData.recent.slice(
    0,
    Math.min(3, jobData.recent.length),
  );

  // First, check if the job has any runs within the recent cutoff period
  const hasRecentRuns = lastThreeRuns.some(
    (run) => new Date(run.date) >= recentCutoff,
  );
  if (!hasRecentRuns) {
    // Job hasn't run recently, don't flag as having current issues
    return {
      hasFailure: false,
      hasTimeout: false,
      failedCount: 0,
      timedOutCount: 0,
      totalCount: 0,
      tooltipFailure: "",
      tooltipTimeout: "",
    };
  }

  let failedCount = 0;
  let timedOutCount = 0;
  let hasFailure = false;
  let hasTimeout = false;

  for (const run of lastThreeRuns) {
    const state = run.state || "passed";
    const runDate = new Date(run.date);

    // Check if this run failed
    if (state === "failed") {
      failedCount++;
      // Show warning if within 24h OR if this is in the last 3 runs and recent enough
      if (runDate >= last24h || runDate >= recentCutoff) {
        hasFailure = true;
      }
    }
    // Check if this run timed out
    else if (state === "timed_out") {
      timedOutCount++;
      // Show warning if within 24h OR if this is in the last 3 runs and recent enough
      if (runDate >= last24h || runDate >= recentCutoff) {
        hasTimeout = true;
      }
    }
  }

  const tooltipFailure = hasFailure
    ? `Currently failing: ${failedCount}/${lastThreeRuns.length} recent runs failed`
    : "";
  const tooltipTimeout = hasTimeout
    ? `Currently timing out: ${timedOutCount}/${lastThreeRuns.length} recent runs timed-out`
    : "";

  // Check for breakage within recent period
  const breakage = detectBreakage(jobData);
  const hasBreakage = breakage && new Date(breakage.date) >= recentCutoff;
  const tooltipBreakage = hasBreakage
    ? `Breakage detected: ${breakage.failureCount} failures since ${new Date(breakage.date).toLocaleDateString()}\nCommit: ${breakage.commit.substring(0, 8)}\n${breakage.message.substring(0, 60)}${breakage.message.length > 60 ? "..." : ""}`
    : "";

  return {
    hasFailure,
    hasTimeout,
    hasBreakage,
    failedCount,
    timedOutCount,
    totalCount: lastThreeRuns.length,
    tooltipFailure,
    tooltipTimeout,
    tooltipBreakage,
  };
}

/**
 * Detect breakage points where a job transitioned from reliable passing to reliable failing.
 *
 * Strategy: Look for a REGIME CHANGE - a clear transition from stable passing to stable failing.
 * This avoids false positives on flaky jobs that have intermittent failures.
 *
 * Algorithm:
 * 1. Confirm currently broken: ≥80% failure rate in last 5 runs (4 of 5)
 * 2. Scan backwards tracking consecutive passes
 * 3. Once we find 7 consecutive passes, the last failure before that window is the breakage
 *
 * @param {Object} jobData - Job data with recent runs
 * @returns {Object|null} Breakage info with { commit, date, build, message, author, failureCount } or null
 */
function detectBreakage(jobData) {
  const CURRENT_WINDOW = 5;
  const CURRENT_THRESHOLD = 4;
  const STABLE_WINDOW = 7; // Need this many consecutive passes to mark stable

  if (
    !jobData.recent ||
    jobData.recent.length < CURRENT_WINDOW + STABLE_WINDOW
  ) {
    return null;
  }

  const runs = jobData.recent;
  const isFailed = (run) => {
    const state = getRunState(run);
    return state === "failed" || state === "timed_out";
  };

  // Step 1: Check if currently broken
  const recentRuns = runs.slice(0, CURRENT_WINDOW);
  const recentFailures = recentRuns.filter(isFailed).length;
  if (recentFailures < CURRENT_THRESHOLD) {
    return null;
  }

  // Step 2: Scan backwards tracking consecutive passes
  let consecutivePasses = 0;
  let lastFailureIdx = -1;

  for (let i = 0; i < runs.length; i++) {
    const state = getRunState(runs[i]);
    if (state === "passed") {
      consecutivePasses++;
      if (consecutivePasses >= STABLE_WINDOW) {
        break; // Found stable region
      }
    } else {
      consecutivePasses = 0;
      if (isFailed(runs[i])) {
        lastFailureIdx = i;
      }
    }
  }

  if (lastFailureIdx < 0 || consecutivePasses < STABLE_WINDOW) {
    return null;
  }

  // Count failures from breakage to present
  let failureCount = 0;
  for (let i = 0; i <= lastFailureIdx; i++) {
    if (isFailed(runs[i])) failureCount++;
  }

  return {
    commit: runs[lastFailureIdx].commit,
    date: runs[lastFailureIdx].date,
    build: runs[lastFailureIdx].build,
    message: runs[lastFailureIdx].message,
    author: runs[lastFailureIdx].author,
    failureCount: failureCount,
    failureType: getRunState(runs[lastFailureIdx]),
  };
}

// Cache pass rates and breakages for all jobs
let jobPassRates = {};
let jobBreakages = {};

function calculateAllPassRates() {
  jobPassRates = {};
  for (const [name, job] of Object.entries(data.jobs)) {
    jobPassRates[name] = getJobPassRate(job);
  }
}

function calculateAllBreakages() {
  jobBreakages = {};
  for (const [name, job] of Object.entries(data.jobs)) {
    const breakage = detectBreakage(job);
    if (breakage) {
      jobBreakages[name] = breakage;
    }
  }
}

// URL parameter handling for shareable links
const urlCodes = {
  // Platform codes
  linux: "l",
  macos: "m",
  windows: "w",
  freebsd: "f",
  // Type codes
  build: "b",
  test: "t",
  upload: "u",
  coverage: "c",
  // Special group codes
  juliasyntax: "js",
  juliac: "jc",
  docs: "d",
  special: "sp",
  pipeline: "p",
  "upload-results": "ur",
  other: "o",
};
const urlCodesReverse = Object.fromEntries(
  Object.entries(urlCodes).map(([k, v]) => [v, k]),
);

// Job index mapping for URL encoding (built after data loads)
let jobIndexMap = {}; // name -> index
let jobNameList = []; // index -> name

function buildJobIndex() {
  jobNameList = Object.keys(data.jobs).sort();
  jobIndexMap = {};
  jobNameList.forEach((name, i) => (jobIndexMap[name] = i));
}

/**
 * Encode current job selection into compact URL-safe string.
 * Uses short codes for matrix cells, special groups, and job indices.
 * @returns {string} Encoded selection string for URL parameter
 */
function encodeSelection() {
  const parts = [];
  const coveredJobs = new Set();

  // Encode matrix cells that are fully selected
  for (const platform of platformOrder) {
    for (const type of typeOrder) {
      const jobs = jobMatrix[platform]?.[type] || [];
      if (jobs.length > 0 && jobs.every((j) => selectedJobs.has(j.name))) {
        parts.push(urlCodes[platform] + urlCodes[type]);
        jobs.forEach((j) => coveredJobs.add(j.name));
      }
    }
  }
  // Encode special groups that are fully selected
  for (const group of specialGroups) {
    const jobs = specialJobGroups[group] || [];
    if (jobs.length > 0 && jobs.every((j) => selectedJobs.has(j.name))) {
      parts.push(urlCodes[group]);
      jobs.forEach((j) => coveredJobs.add(j.name));
    }
  }

  // Encode remaining individual jobs by index
  const individualIndices = [];
  for (const name of selectedJobs) {
    if (!coveredJobs.has(name) && jobIndexMap[name] !== undefined) {
      individualIndices.push(jobIndexMap[name]);
    }
  }
  if (individualIndices.length > 0) {
    parts.push("i" + individualIndices.sort((a, b) => a - b).join("_"));
  }

  return parts.join(".");
}

/**
 * Decode job selection from URL parameter string.
 * @param {string} param - Encoded selection string from URL
 * @returns {Object|null} Object with {matrix, special, indices} arrays, or null if invalid
 */
function decodeSelection(param) {
  if (!param) return null;
  const selections = { matrix: [], special: [], indices: [] };
  for (const part of param.split(".")) {
    if (part.startsWith("i")) {
      // Individual job indices: i0_5_12
      const indices = part
        .slice(1)
        .split("_")
        .map(Number)
        .filter((n) => !isNaN(n));
      selections.indices.push(...indices);
    } else if (
      part.length === 2 &&
      urlCodesReverse[part[0]] &&
      urlCodesReverse[part[1]]
    ) {
      // Matrix cell: e.g., "lb" = linux-build
      const platform = urlCodesReverse[part[0]];
      const type = urlCodesReverse[part[1]];
      if (platform && type) selections.matrix.push({ platform, type });
    } else {
      // Special group
      const group = urlCodesReverse[part];
      if (group) selections.special.push(group);
    }
  }
  return selections;
}

function updateURL() {
  const encoded = encodeSelection();
  const url = new URL(window.location);
  if (encoded) {
    url.searchParams.set("s", encoded);
  } else {
    url.searchParams.delete("s");
  }
  // Add time range if not default (and not custom zoom)
  if (customXMin === null && timeRangeDays !== DEFAULT_TIME_RANGE) {
    url.searchParams.set("t", timeRangeDays);
  } else if (customXMin === null) {
    url.searchParams.delete("t");
  }
  // Add custom zoom ranges if set
  if (customXMin !== null) {
    url.searchParams.set("x", `${customXMin}.${customXMax}`);
    url.searchParams.delete("t");
  } else {
    url.searchParams.delete("x");
  }
  if (customYMin !== null) {
    url.searchParams.set("y", `${customYMin}.${customYMax}`);
  } else {
    url.searchParams.delete("y");
  }
  // Add line type if not default
  if (lineType !== "raw") {
    url.searchParams.set("l", lineType);
  } else {
    url.searchParams.delete("l");
  }
  // Add expanded jobs if any
  if (expandedJobs.size > 0) {
    const expandedIndices = [...expandedJobs]
      .map((name) => jobIndexMap[name])
      .filter((idx) => idx !== undefined)
      .sort((a, b) => a - b);
    if (expandedIndices.length > 0) {
      url.searchParams.set("e", expandedIndices.join("_"));
    } else {
      url.searchParams.delete("e");
    }
  } else {
    url.searchParams.delete("e");
  }
  // Add excluded states if different from default (canceled only)
  const defaultExcluded = new Set(["canceled"]);
  const isDefaultStates =
    excludedStates.size === defaultExcluded.size &&
    [...excludedStates].every((s) => defaultExcluded.has(s));
  if (!isDefaultStates) {
    // Encode as which states are visible (inverse of excluded)
    const allStates = ["passed", "failed", "timed_out", "canceled"];
    const visible = allStates.filter((s) => !excludedStates.has(s));
    url.searchParams.set("st", visible.join("_"));
  } else {
    url.searchParams.delete("st");
  }
  history.replaceState(null, "", url);
  saveToLocalStorage();
}

function saveToLocalStorage() {
  const statsWrapper = document.getElementById("stats-wrapper");
  const config = {
    selection: encodeSelection(),
    timeRange: timeRangeDays,
    lineType: lineType,
    statsHeight: statsWrapper ? statsWrapper.offsetHeight : 150,
  };
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
  } catch (e) {
    // Ignore storage errors
  }
}

function loadFromLocalStorage() {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (!stored) return null;
    return JSON.parse(stored);
  } catch (e) {
    return null;
  }
}

function applyURLParams() {
  const params = new URLSearchParams(window.location.search);

  // Apply time range
  const t = params.get("t");
  if (t !== null) {
    const days = parseInt(t, 10);
    if (!isNaN(days) && VALID_TIME_RANGES.includes(days)) {
      timeRangeDays = days;
      document.getElementById("time-range").value = days;
    }
  }

  // Apply custom x range (overrides time range)
  const x = params.get("x");
  if (x) {
    const [xMin, xMax] = x.split(".").map(Number);
    if (!isNaN(xMin) && !isNaN(xMax)) {
      customXMin = xMin;
      customXMax = xMax;
      document.getElementById("time-range").value = "custom";
      document.getElementById("btn-reset-zoom").style.display = "";
    }
  }

  // Apply custom y range
  const y = params.get("y");
  if (y) {
    const [yMin, yMax] = y.split(".").map(Number);
    if (!isNaN(yMin) && !isNaN(yMax)) {
      customYMin = yMin;
      customYMax = yMax;
    }
  }

  // Apply line type
  const l = params.get("l");
  if (l !== null && VALID_LINE_TYPES.includes(l)) {
    lineType = l;
    document.getElementById("line-type").value = l;
  }

  // Apply expanded jobs
  const e = params.get("e");
  if (e) {
    expandedJobs.clear();
    const indices = e
      .split("_")
      .map(Number)
      .filter((n) => !isNaN(n));
    for (const idx of indices) {
      if (jobNameList[idx]) expandedJobs.add(jobNameList[idx]);
    }
  }

  // Apply state filter
  const st = params.get("st");
  if (st !== null) {
    const allStates = ["passed", "failed", "timed_out", "canceled"];
    const visibleStates = st
      ? st.split("_").filter((s) => allStates.includes(s))
      : [];
    excludedStates.clear();
    for (const state of allStates) {
      if (!visibleStates.includes(state)) {
        excludedStates.add(state);
      }
    }
    // Sync checkbox UI
    const menu = document.getElementById("state-filter-menu");
    if (menu) {
      const checkboxes = menu.querySelectorAll('input[type="checkbox"]');
      const stateOrder = ["passed", "failed", "timed_out", "canceled"];
      checkboxes.forEach((cb, i) => {
        cb.checked = !excludedStates.has(stateOrder[i]);
      });
    }
    updateStateFilterLabel();
  }

  // Apply selection
  const sel = decodeSelection(params.get("s"));
  if (!sel) return false;

  selectedJobs.clear();
  for (const { platform, type } of sel.matrix) {
    const jobs = jobMatrix[platform]?.[type] || [];
    for (const { name } of jobs) selectedJobs.add(name);
  }
  for (const group of sel.special) {
    const jobs = specialJobGroups[group] || [];
    for (const { name } of jobs) selectedJobs.add(name);
  }
  for (const idx of sel.indices) {
    if (jobNameList[idx]) selectedJobs.add(jobNameList[idx]);
  }
  return (
    sel.matrix.length > 0 || sel.special.length > 0 || sel.indices.length > 0
  );
}

// Parse comparison data from URL parameter
// Format: c=PR:BUILD:BASE:JOB1=DUR1,JOB2=DUR2,...
// PR is 0 if not a PR build, durations are in seconds
function parseComparisonParam(param) {
  if (!param) return null;
  const parts = param.split(":");
  if (parts.length < 4) return null;

  const pr = parseInt(parts[0], 10);
  const build = parseInt(parts[1], 10);
  const base = parseInt(parts[2], 10);
  if (isNaN(build) || isNaN(base)) return null;

  const jobsStr = parts.slice(3).join(":"); // Rejoin in case job names had colons
  const jobs = {};
  for (const pair of jobsStr.split(",")) {
    const eqIdx = pair.lastIndexOf("=");
    if (eqIdx === -1) continue;
    const jobName = decodeURIComponent(pair.substring(0, eqIdx));
    const duration = parseFloat(pair.substring(eqIdx + 1));
    if (!isNaN(duration)) {
      jobs[jobName] = { duration };
    }
  }

  if (Object.keys(jobs).length === 0) return null;
  return { pr: pr || null, build, base, jobs };
}

// Apply comparison data from URL param and update UI
function applyComparisonParam() {
  const params = new URLSearchParams(window.location.search);
  const c = params.get("c");
  comparisonData = parseComparisonParam(c);

  if (comparisonData) {
    // Populate baseline values from our data
    for (const [jobName, jobData] of Object.entries(comparisonData.jobs)) {
      const job = data?.jobs?.[jobName];
      if (job?.stats?.median) {
        jobData.baseline = job.stats.median;
      }
    }
    updateComparisonBanner();
  }
}

// Update the comparison banner UI
function updateComparisonBanner() {
  const banner = document.getElementById("comparison-banner");
  if (!comparisonData) {
    banner.classList.remove("visible");
    return;
  }

  banner.classList.add("visible");

  // Build the title based on PR number availability
  const title = document.getElementById("comparison-title");
  const buildLink = `https://buildkite.com/julialang/julia-master/builds/${comparisonData.build}`;
  const baseLink = `https://buildkite.com/julialang/julia-master/builds/${comparisonData.base}`;

  if (comparisonData.pr) {
    const prLink = `https://github.com/JuliaLang/julia/pull/${comparisonData.pr}`;
    // Check if base is significantly older (more than 50 builds behind)
    const buildDiff = comparisonData.build - comparisonData.base;
    if (buildDiff > 50) {
      title.innerHTML = `Comparing <a href="${prLink}" target="_blank" rel="noopener noreferrer">PR #${comparisonData.pr}</a> (<a href="${buildLink}" target="_blank" rel="noopener noreferrer">build ${comparisonData.build}</a>). Note: the base of the PR branch is old, at <a href="${baseLink}" target="_blank" rel="noopener noreferrer">build ${comparisonData.base}</a>`;
    } else {
      title.innerHTML = `Comparing <a href="${prLink}" target="_blank" rel="noopener noreferrer">PR #${comparisonData.pr}</a> (<a href="${buildLink}" target="_blank" rel="noopener noreferrer">build ${comparisonData.build}</a>)`;
    }
  } else {
    title.innerHTML = `Comparing <a href="${buildLink}" target="_blank" rel="noopener noreferrer">build ${comparisonData.build}</a> vs <a href="${baseLink}" target="_blank" rel="noopener noreferrer">base ${comparisonData.base}</a>`;
  }

  // Calculate summary stats
  let regressions = 0,
    improvements = 0,
    neutral = 0;
  const threshold = 0.05; // 5% threshold for significance

  for (const [jobName, jobData] of Object.entries(comparisonData.jobs)) {
    if (!jobData.baseline) continue;
    const pctDiff = (jobData.duration - jobData.baseline) / jobData.baseline;
    if (pctDiff > threshold) {
      regressions++;
    } else if (pctDiff < -threshold) {
      improvements++;
    } else {
      neutral++;
    }
  }

  const summary = document.getElementById("comparison-summary");
  summary.innerHTML = "";

  if (regressions > 0) {
    const span = document.createElement("span");
    span.className = "comparison-stat regression";
    span.innerHTML = `<span class="comparison-badge regression">↑ ${regressions}</span> slower`;
    summary.appendChild(span);
  }
  if (improvements > 0) {
    const span = document.createElement("span");
    span.className = "comparison-stat improvement";
    span.innerHTML = `<span class="comparison-badge improvement">↓ ${improvements}</span> faster`;
    summary.appendChild(span);
  }
  if (neutral > 0) {
    const span = document.createElement("span");
    span.className = "comparison-stat neutral";
    span.textContent = `${neutral} unchanged`;
    summary.appendChild(span);
  }

  // In comparison mode, only select the compared jobs
  selectedJobs.clear();
  for (const jobName of Object.keys(comparisonData.jobs)) {
    if (data?.jobs?.[jobName]) {
      selectedJobs.add(jobName);
    }
  }
  // Sync the job list UI to reflect the selection
  syncJobListUI();
  updateMatrixHighlights();
}

// Clear comparison mode
function clearComparison() {
  comparisonData = null;
  document.getElementById("comparison-banner").classList.remove("visible");
  // Remove c param from URL
  const url = new URL(window.location);
  url.searchParams.delete("c");
  history.replaceState(null, "", url);
  updateChart();
}

function setTimeRange(days) {
  timeRangeDays = parseInt(days, 10);
  // Clear custom zoom when selecting a preset
  clearCustomZoom();
  updateHostFilterUI();
  updateChart();
  updateStatsTable();
  updateURL();
}

function clearCustomZoom() {
  customXMin = null;
  customXMax = null;
  customYMin = null;
  customYMax = null;
  const select = document.getElementById("time-range");
  select.value = timeRangeDays;
  document.getElementById("btn-reset-zoom").style.display = "none";
}

function setCustomZoom(xMin, xMax, yMin, yMax) {
  customXMin = xMin;
  customXMax = xMax;
  customYMin = yMin;
  customYMax = yMax;
  // Update dropdown to show "Custom"
  const select = document.getElementById("time-range");
  select.value = "custom";
  document.getElementById("btn-reset-zoom").style.display = "";
  updateURL();
}

function handleZoomPanComplete({ chart }) {
  const xAxis = chart.scales.x;
  const yAxis = chart.scales.y;
  // Guard against invalid values when chart has no data
  if (
    !isFinite(xAxis.min) ||
    !isFinite(xAxis.max) ||
    !isFinite(yAxis.min) ||
    !isFinite(yAxis.max)
  ) {
    return;
  }
  setCustomZoom(
    Math.round(xAxis.min),
    Math.round(xAxis.max),
    Math.round(yAxis.min),
    Math.round(yAxis.max),
  );
}

function resetZoom() {
  clearCustomZoom();
  updateChart();
  updateURL();
}

function setLineType(type) {
  lineType = type;
  updateChart();
  updateURL();
}

function toggleStateDropdown(event) {
  event.stopPropagation();
  const dropdown = document.getElementById("state-filter-dropdown");
  dropdown.classList.toggle("open");
  // Close host dropdown if open
  document.getElementById("host-filter-dropdown")?.classList.remove("open");
}

function toggleStateFilter(state, checkbox) {
  if (excludedStates.has(state)) {
    excludedStates.delete(state);
  } else {
    excludedStates.add(state);
  }
  updateStateFilterLabel();
  updateChart();
  updateStatsTable();
  updateURL();
}

function updateStateFilterLabel() {
  const label = document.getElementById("state-filter-label");
  const allStates = ["passed", "failed", "timed_out", "canceled"];
  const visibleCount = allStates.length - excludedStates.size;
  if (excludedStates.size === 0) {
    label.textContent = "All states";
  } else if (visibleCount === 0) {
    label.textContent = "No states";
  } else if (visibleCount === 1) {
    const visible = allStates.find((s) => !excludedStates.has(s));
    const names = {
      passed: "Passed",
      failed: "Failed",
      timed_out: "Timed out",
      canceled: "Canceled",
    };
    label.textContent = names[visible] + " only";
  } else {
    label.textContent = `States (${visibleCount}/${allStates.length})`;
  }
}

// Close dropdown when clicking outside
document.addEventListener("click", (e) => {
  const hostDropdown = document.getElementById("host-filter-dropdown");
  const stateDropdown = document.getElementById("state-filter-dropdown");
  if (hostDropdown && !hostDropdown.contains(e.target)) {
    hostDropdown.classList.remove("open");
  }
  if (stateDropdown && !stateDropdown.contains(e.target)) {
    stateDropdown.classList.remove("open");
  }
});

function toggleHostDropdown(event) {
  event.stopPropagation();
  const dropdown = document.getElementById("host-filter-dropdown");
  dropdown.classList.toggle("open");
  // Close state dropdown if open
  document.getElementById("state-filter-dropdown")?.classList.remove("open");
}

function toggleHostFilter(host, checkbox) {
  if (excludedHosts.has(host)) {
    excludedHosts.delete(host);
  } else {
    excludedHosts.add(host);
  }
  updateHostFilterLabel();
  updateChart();
  updateStatsTable();
}

function setAllHostsVisible(visible) {
  const allHosts = getAllHostsFromSelectedJobs();
  if (visible) {
    excludedHosts.clear();
  } else {
    for (const host of allHosts) {
      excludedHosts.add(host);
    }
  }
  updateHostFilterUI();
  updateChart();
  updateStatsTable();
}

function updateHostFilterLabel() {
  const label = document.getElementById("host-filter-label");
  const allHosts = getAllHostsFromSelectedJobs();
  const excludedCount = excludedHosts.size;
  const visibleCount = allHosts.length - excludedCount;
  if (excludedCount === 0 || allHosts.length === 0) {
    label.textContent = "All hosts";
  } else if (visibleCount === 0) {
    label.textContent = "No hosts";
  } else {
    label.textContent = `Hosts (${visibleCount}/${allHosts.length})`;
  }
}

function updateHostFilterUI() {
  const menu = document.getElementById("host-filter-menu");
  if (!data || !menu) return;
  const allHosts = getAllHostsFromSelectedJobs();

  menu.innerHTML = "";

  // Add "Select all" / "Select none" controls
  const selectAllItem = document.createElement("label");
  selectAllItem.className = "checkbox-dropdown-item";
  selectAllItem.innerHTML = `<input type="checkbox" ${excludedHosts.size === 0 ? "checked" : ""} onchange="setAllHostsVisible(this.checked)"> Select all`;
  menu.appendChild(selectAllItem);

  if (allHosts.length > 0) {
    const divider = document.createElement("div");
    divider.className = "checkbox-dropdown-divider";
    menu.appendChild(divider);
  }

  // Add individual host checkboxes
  for (const host of allHosts) {
    const item = document.createElement("label");
    item.className = "checkbox-dropdown-item";
    const included = !excludedHosts.has(host);
    item.innerHTML = `<input type="checkbox" ${included ? "checked" : ""} onchange="toggleHostFilter('${host.replace(/'/g, "\\'")}', this)"> ${host}`;
    menu.appendChild(item);
  }

  updateHostFilterLabel();
}

function getAllHostsFromSelectedJobs() {
  const hosts = new Set();
  const cutoff = getTimeRangeCutoff();
  for (const jobName of selectedJobs) {
    const job = data?.jobs?.[jobName];
    if (!job) continue;
    for (const run of job.recent) {
      const date = new Date(run.date);
      if (cutoff && date < cutoff) continue;
      if (run.agent) hosts.add(run.agent);
    }
  }
  // Clean up excluded hosts that no longer exist
  for (const host of excludedHosts) {
    if (!hosts.has(host)) excludedHosts.delete(host);
  }
  return [...hosts].sort();
}

function getTimeRangeCutoff() {
  // When custom x-range is set, use it for cutoff (with some padding for smoothing)
  if (customXMin !== null) {
    // Add 90 days padding before customXMin to support smoothing calculations
    return new Date(customXMin - 90 * 24 * 60 * 60 * 1000);
  }
  if (timeRangeDays === 0) return null; // All time
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - timeRangeDays);
  return cutoff;
}

// Get visible time range bounds for stats (respects custom zoom)
function getVisibleTimeRange() {
  if (customXMin !== null) {
    return { min: new Date(customXMin), max: new Date(customXMax) };
  }
  if (timeRangeDays === 0) return { min: null, max: null }; // All time
  const max = new Date();
  const min = new Date();
  min.setDate(min.getDate() - timeRangeDays);
  return { min, max };
}

function classifyJob(name) {
  const lower = name.toLowerCase();
  // Pipeline jobs first (launch/unlock)
  if (lower.includes("launch")) return { group: "pipeline", type: "pipeline" };
  if (lower.includes("unlock")) return { group: "pipeline", type: "pipeline" };
  if (lower.includes("juliasyntax"))
    return { group: "juliasyntax", type: "test" };
  if (lower.includes("juliac")) return { group: "juliac", type: "test" };
  if (lower.includes("upload test results"))
    return { group: "upload-results", type: "upload" };
  if (lower.includes("upload docs")) return { group: "docs", type: "upload" };
  if (lower.includes("doctest") || lower.includes("pdf_docs"))
    return { group: "docs", type: "test" };

  // Upload jobs go to special group (before platform checks)
  if (lower.includes("upload")) return { group: "upload", type: "upload" };

  // Platform-based grouping
  if (lower.includes(":linux:") || lower.includes("linux")) {
    if (lower.includes("coverage")) return { group: "linux", type: "coverage" };
    if (lower.includes("build")) return { group: "linux", type: "build" };
    if (lower.includes("test")) return { group: "linux", type: "test" };
  }
  if (
    lower.includes(":macos:") ||
    lower.includes("macos") ||
    lower.includes("darwin")
  ) {
    if (lower.includes("coverage")) return { group: "macos", type: "coverage" };
    if (lower.includes("build")) return { group: "macos", type: "build" };
    if (lower.includes("test")) return { group: "macos", type: "test" };
  }
  if (
    lower.includes(":windows:") ||
    lower.includes("windows") ||
    lower.includes("mingw")
  ) {
    if (lower.includes("coverage"))
      return { group: "windows", type: "coverage" };
    if (lower.includes("build")) return { group: "windows", type: "build" };
    if (lower.includes("test")) return { group: "windows", type: "test" };
  }
  if (lower.includes(":freebsd:") || lower.includes("freebsd")) {
    if (lower.includes("coverage"))
      return { group: "freebsd", type: "coverage" };
    if (lower.includes("build")) return { group: "freebsd", type: "build" };
    if (lower.includes("test")) return { group: "freebsd", type: "test" };
  }

  // Special test types
  if (
    [
      "asan",
      "tsan",
      "analyzegc",
      "llvmpasses",
      "embedding",
      "gcext",
      "trimming",
    ].includes(lower)
  ) {
    return { group: "special", type: "test" };
  }
  if (lower === "test revise") return { group: "special", type: "test" };

  return { group: "other", type: "other" };
}

/**
 * Compute temporal moving average with Gaussian window.
 * Uses a Gaussian kernel for smooth weighting - points closer to the center
 * have more influence than distant points, producing smoother curves than
 * rectangular windows.
 *
 * @param {Array<Object>} points - Array of {x: Date, y: number} data points
 * @param {number} windowDays - Size of averaging window in days (effective width ~3σ)
 * @returns {Array<Object>} Smoothed data points resampled at even intervals
 */
function computeMovingAverage(points, windowDays) {
  if (points.length === 0) return [];

  // Gaussian window: use windowDays as ~3σ (99.7% of weight within window)
  const sigma = windowDays / 3;
  const sigmaDays = sigma;
  const sigmaMs = sigmaDays * 24 * 60 * 60 * 1000;
  const windowMs = windowDays * 24 * 60 * 60 * 1000;

  // Determine x domain
  const minX = Math.min(...points.map((p) => p.x.getTime()));
  const maxX = Math.max(...points.map((p) => p.x.getTime()));
  const rangeMs = maxX - minX;

  // Resample at ~100 evenly spaced points (or fewer if range is small)
  const numSamples = Math.min(
    100,
    Math.max(2, Math.ceil(rangeMs / (24 * 60 * 60 * 1000))),
  );
  const stepMs = rangeMs / (numSamples - 1);

  const result = [];
  for (let i = 0; i < numSamples; i++) {
    const centerDate = minX + i * stepMs;
    const windowStart = centerDate - windowMs / 2;
    const windowEnd = centerDate + windowMs / 2;

    let weightedSum = 0;
    let totalWeight = 0;

    for (const pt of points) {
      const t = pt.x.getTime();
      if (t >= windowStart && t <= windowEnd) {
        const distanceMs = t - centerDate;
        const distanceDays = distanceMs / (24 * 60 * 60 * 1000);
        const weight = Math.exp(
          -(distanceDays * distanceDays) / (2 * sigmaDays * sigmaDays),
        );
        weightedSum += pt.y * weight;
        totalWeight += weight;
      }
    }

    if (totalWeight > 0) {
      result.push({
        x: new Date(centerDate),
        y: weightedSum / totalWeight,
      });
    }
  }
  return result;
}

function updateChart() {
  const selectedArray = Array.from(selectedJobs);
  if (selectedArray.length === 0) {
    if (chart) chart.destroy();
    chart = null;
    chartMetadata = {};
    return;
  }

  // Build datasets and metadata
  const datasets = [];
  chartMetadata = {};
  const cutoff = getTimeRangeCutoff();
  // Don't show coverage overlay in comparison mode
  const showCoverage = !comparisonData && hasSelectedCoverageJob();

  for (const jobName of selectedArray) {
    const jobData = data.jobs[jobName];
    if (!jobData) continue;

    const color = jobColors[jobName];
    const points = [];

    for (const run of jobData.recent) {
      const date = new Date(run.date);
      if (cutoff && date < cutoff) continue;
      const runState = getRunState(run);
      if (excludedStates.size > 0 && excludedStates.has(runState)) continue;
      if (excludedHosts.size > 0 && excludedHosts.has(run.agent)) continue;
      points.push({
        x: date,
        y: run.duration,
        state: runState,
        retry: run.retry || 0,
        meta: {
          job: jobName,
          commit: run.commit,
          build: run.build,
          date: run.date,
          duration: run.duration,
          message: run.message,
          author: run.author,
          state: runState,
          agent: run.agent || "",
          retry: run.retry || 0,
          pipeline: run.pipeline || "julia-master",
        },
      });
    }

    if (points.length === 0) continue; // Skip jobs with no data in range

    // Sort by date
    points.sort((a, b) => a.x - b.x);

    // Apply moving average if selected
    const smoothedPoints =
      lineType === "raw"
        ? points
        : computeMovingAverage(points, parseInt(lineType, 10));

    // Check if this job has a detected breakage
    const breakage = jobBreakages[jobName];
    const breakageCommit = breakage ? breakage.commit : null;

    // Build metadata from raw points (include breakage flag)
    const datasetIdx = datasets.length;
    points.forEach((pt, idx) => {
      chartMetadata[`${datasetIdx}-${idx}`] = {
        ...pt.meta,
        isBreakage: breakageCommit && pt.meta.commit === breakageCommit,
      };
    });

    // Create custom canvas for timed_out marker (⤒) at high DPI
    const createTimedOutMarker = (fillColor, markerSize = null) => {
      const scale = window.devicePixelRatio || 2;
      // Use smaller markers on narrow screens
      const size = markerSize ?? (window.innerWidth <= 480 ? 7 : 10);
      const canvas = document.createElement("canvas");
      canvas.width = size * scale;
      canvas.height = size * scale;
      canvas.style.width = size + "px";
      canvas.style.height = size + "px";
      const ctx = canvas.getContext("2d");
      ctx.scale(scale, scale);
      ctx.strokeStyle = fillColor;
      ctx.fillStyle = fillColor;
      ctx.lineWidth = size <= 7 ? 0.8 : 1.0;
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      const cx = size / 2;
      const cy = size / 2 + (size <= 7 ? 0.7 : 1);
      const barHalf = size <= 7 ? 1.0 : 1.5;
      const stemLen = size <= 7 ? 2.8 : 4;
      const arrowY = size <= 7 ? 1.8 : 2.5;
      // Horizontal bar at center
      ctx.beginPath();
      ctx.moveTo(cx - barHalf, cy);
      ctx.lineTo(cx + barHalf, cy);
      ctx.stroke();
      // Vertical line (stem) - from center down
      ctx.beginPath();
      ctx.moveTo(cx, cy);
      ctx.lineTo(cx, cy + stemLen);
      ctx.stroke();
      // Arrow head just below the bar
      ctx.beginPath();
      ctx.moveTo(cx - barHalf, cy + arrowY);
      ctx.lineTo(cx, cy);
      ctx.lineTo(cx + barHalf, cy + arrowY);
      ctx.stroke();
      return canvas;
    };

    // Create breakage marker (cross/X with circle around it to indicate breakage)
    const createBreakageMarker = (fillColor, markerSize = null) => {
      const scale = window.devicePixelRatio || 2;
      const size = markerSize ?? (window.innerWidth <= 480 ? 7 : 10);
      const canvas = document.createElement("canvas");
      canvas.width = size * scale;
      canvas.height = size * scale;
      canvas.style.width = size + "px";
      canvas.style.height = size + "px";
      const ctx = canvas.getContext("2d");
      ctx.scale(scale, scale);

      const cx = size / 2;
      const cy = size / 2;
      const radius = size / 2 - 1;

      // Draw circle border to indicate breakage
      ctx.strokeStyle = fillColor;
      ctx.lineWidth = 0.8;
      ctx.beginPath();
      ctx.arc(cx, cy, radius, 0, 2 * Math.PI);
      ctx.stroke();

      // Draw cross/X (failure marker) inside - same size as Chart.js crossRot
      ctx.strokeStyle = fillColor;
      ctx.lineWidth = 1.5;
      const crossSize = size * 0.25;
      // Draw X
      ctx.beginPath();
      ctx.moveTo(cx - crossSize, cy - crossSize);
      ctx.lineTo(cx + crossSize, cy + crossSize);
      ctx.moveTo(cx + crossSize, cy - crossSize);
      ctx.lineTo(cx - crossSize, cy + crossSize);
      ctx.stroke();

      return canvas;
    };

    // Generate per-point colors with perceptually-adjusted hue shifts per agent
    const uniqueAgents = [...new Set(points.map((p) => p.meta.agent || ""))];
    const agentHueShifts = {};
    const baseShift = 20; // Base ±20 degrees range
    const baseHue = getHueFromColor(color);
    const maxShift = baseShift * getPerceptualHueMultiplier(baseHue);
    uniqueAgents.forEach((agent, i) => {
      // Distribute shifts evenly across the perceptually-adjusted range
      agentHueShifts[agent] =
        uniqueAgents.length > 1
          ? -maxShift + (2 * maxShift * i) / (uniqueAgents.length - 1)
          : 0;
    });
    const pointColors = points.map((p) =>
      shiftHue(color, agentHueShifts[p.meta.agent || ""]),
    );

    // Cache timeout markers per color
    const timedOutMarkerCache = {};
    const getTimedOutMarker = (markerColor) => {
      if (!timedOutMarkerCache[markerColor]) {
        timedOutMarkerCache[markerColor] = createTimedOutMarker(markerColor);
      }
      return timedOutMarkerCache[markerColor];
    };

    // Cache breakage markers per color
    const breakageMarkerCache = {};
    const getBreakageMarker = (markerColor) => {
      if (!breakageMarkerCache[markerColor]) {
        breakageMarkerCache[markerColor] = createBreakageMarker(markerColor);
      }
      return breakageMarkerCache[markerColor];
    };

    // Generate point styles based on state (with per-point colors for timeout markers)
    const pointStyles = points.map((p, i) => {
      // Breakage marker takes precedence if this is the breakage commit
      if (breakageCommit && p.meta.commit === breakageCommit)
        return getBreakageMarker(pointColors[i]);
      if (p.state === "timed_out") return getTimedOutMarker(pointColors[i]);
      if (p.state === "failed" || p.state === "canceled") return "crossRot";
      // Use rectRot (diamond) for retry attempts to make them visually distinct
      if (p.retry > 0) return "rectRot";
      return "circle";
    });
    // Smaller points on narrow screens; larger for retries to make them visible
    const isMobile = window.innerWidth <= 480;
    const pointRadii = points.map((p) => {
      // Breakage points same size as regular failed markers
      if (breakageCommit && p.meta.commit === breakageCommit)
        return isMobile ? 3.5 : 5;
      if (isFailedState(p.state)) return isMobile ? 3.5 : 5;
      if (p.retry > 0) return isMobile ? 3 : 4; // Slightly larger for retries
      return isMobile ? 1.5 : 2;
    });
    // Add border to retry points and failed states
    const pointBorderWidths = points.map((p) => {
      if (isFailedState(p.state)) return isMobile ? 0.8 : 1; // Failed markers need visible border
      if (p.retry > 0) return 1;
      return 0;
    });
    const pointHoverBorderWidths = points.map((p) => {
      if (isFailedState(p.state)) return isMobile ? 1.8 : 2.2; // Thicker on hover
      if (p.retry > 0) return 2;
      return 0;
    });

    if (lineType === "raw") {
      // Single dataset with line and points
      datasets.push({
        label: jobName,
        data: points.map((p) => ({ x: p.x, y: p.y })),
        borderColor: color,
        borderWidth: 1.5,
        backgroundColor: color + "20",
        fill: false,
        tension: 0.2,
        pointRadius: pointRadii,
        pointHoverRadius: pointRadii.map((r) => r * 1.2),
        pointHitRadius: 10,
        pointBackgroundColor: pointColors,
        pointBorderColor: pointColors,
        pointBorderWidth: pointBorderWidths,
        pointHoverBorderWidth: pointHoverBorderWidths,
        pointStyle: pointStyles,
        spanGaps: true,
        clip: false,
        yAxisID: "y",
      });
    } else {
      // Two datasets: smoothed line + raw points
      // Line dataset (no points)
      datasets.push({
        label: jobName,
        data: smoothedPoints.map((p) => ({ x: p.x, y: p.y })),
        borderColor: color,
        borderWidth: 1.5,
        backgroundColor: color + "20",
        fill: false,
        tension: 0.4,
        pointRadius: 0,
        pointHoverRadius: 0,
        spanGaps: true,
        yAxisID: "y",
      });
      // Points dataset (raw values, no line)
      datasets.push({
        label: jobName + " (points)",
        data: points.map((p) => ({ x: p.x, y: p.y })),
        borderColor: color,
        backgroundColor: color,
        fill: false,
        showLine: false,
        pointRadius: pointRadii,
        pointHoverRadius: pointRadii.map((r) => r * 1.2),
        pointHitRadius: 10,
        pointStyle: pointStyles,
        pointBorderColor: pointColors,
        pointBackgroundColor: pointColors,
        pointBorderWidth: pointBorderWidths,
        pointHoverBorderWidth: pointHoverBorderWidths,
        clip: false,
        yAxisID: "y",
      });
      // Also track metadata for points dataset (include breakage flag)
      points.forEach((pt, idx) => {
        chartMetadata[`${datasetIdx + 1}-${idx}`] = {
          ...pt.meta,
          isBreakage: breakageCommit && pt.meta.commit === breakageCommit,
        };
      });
    }
  }

  // Add coverage datasets if coverage jobs are selected
  let hasCoverageData = false;
  if (showCoverage && data?.coverage) {
    // Build coverage points from Finalize parallel coverage job
    const finalize = data.jobs["Finalize parallel coverage"];
    if (finalize) {
      const coverallsPoints = [];
      const codecovPoints = [];

      for (const run of finalize.recent) {
        if (run.state !== "passed") continue;
        const date = new Date(run.date);
        if (cutoff && date < cutoff) continue;

        const cov = getCoverageForCommit(run.commit);
        if (cov?.coveralls != null) {
          coverallsPoints.push({
            x: date,
            y: cov.coveralls,
            meta: { commit: run.commit, build: run.build, date: run.date },
          });
        }
        if (cov?.codecov != null) {
          codecovPoints.push({
            x: date,
            y: cov.codecov,
            meta: { commit: run.commit, build: run.build, date: run.date },
          });
        }
      }

      // Sort by date
      coverallsPoints.sort((a, b) => a.x - b.x);
      codecovPoints.sort((a, b) => a.x - b.x);

      // Add Coveralls dataset
      if (coverallsPoints.length > 0) {
        hasCoverageData = true;
        const dsIdx = datasets.length;
        datasets.push({
          label: "Coveralls %",
          data: coverallsPoints.map((p) => ({ x: p.x, y: p.y })),
          borderColor: "#3F5EFB",
          borderWidth: 2,
          backgroundColor: "#3F5EFB20",
          fill: false,
          tension: 0.3,
          pointRadius: 2,
          pointHoverRadius: 4,
          pointBackgroundColor: "#3F5EFB",
          pointBorderColor: "#3F5EFB",
          spanGaps: true,
          yAxisID: "y2",
        });
        coverallsPoints.forEach((pt, idx) => {
          chartMetadata[`${dsIdx}-${idx}`] = {
            ...pt.meta,
            job: "Coveralls Coverage",
            coverage: pt.y,
          };
        });
      }

      // Add Codecov dataset
      if (codecovPoints.length > 0) {
        hasCoverageData = true;
        const dsIdx = datasets.length;
        datasets.push({
          label: "Codecov %",
          data: codecovPoints.map((p) => ({ x: p.x, y: p.y })),
          borderColor: "#F01F7A",
          borderWidth: 2,
          backgroundColor: "#F01F7A20",
          fill: false,
          tension: 0.3,
          pointRadius: 2,
          pointHoverRadius: 4,
          pointBackgroundColor: "#F01F7A",
          pointBorderColor: "#F01F7A",
          spanGaps: true,
          yAxisID: "y2",
        });
        codecovPoints.forEach((pt, idx) => {
          chartMetadata[`${dsIdx}-${idx}`] = {
            ...pt.meta,
            job: "Codecov Coverage",
            coverage: pt.y,
          };
        });
      }
    }
  }

  // Add comparison mode datasets if active
  let comparisonDate = null;
  if (comparisonData) {
    // Find the base build date to position comparison points
    let baseBuildDate = null;
    for (const [jobName, job] of Object.entries(data.jobs)) {
      for (const run of job.recent || []) {
        if (run.build === comparisonData.base) {
          baseBuildDate = new Date(run.date);
          break;
        }
      }
      if (baseBuildDate) break;
    }

    // If no base build found in data, use now
    if (!baseBuildDate) baseBuildDate = new Date();

    // Offset comparison points slightly after base build
    comparisonDate = new Date(baseBuildDate.getTime() + 2 * 60 * 60 * 1000); // +2 hours

    for (const [jobName, jobData] of Object.entries(comparisonData.jobs)) {
      if (!selectedJobs.has(jobName)) continue;
      const color = jobColors[jobName] || "#888";
      const baseline = jobData.baseline || 0;
      const pctDiff =
        baseline > 0 ? (jobData.duration - baseline) / baseline : 0;
      const isRegression = pctDiff > 0.05;
      const isImprovement = pctDiff < -0.05;

      const dsIdx = datasets.length;
      datasets.push({
        label: `${jobName} (PR #${comparisonData.build})`,
        data: [{ x: comparisonDate, y: jobData.duration }],
        borderColor: "transparent",
        backgroundColor: color,
        fill: false,
        showLine: false,
        pointRadius: 10,
        pointHoverRadius: 12,
        pointStyle: isRegression
          ? "triangle"
          : isImprovement
            ? "rectRot"
            : "star",
        pointBorderColor: isRegression
          ? "#cf222e"
          : isImprovement
            ? "#1a7f37"
            : color,
        pointBackgroundColor: color,
        pointBorderWidth: 3,
        yAxisID: "y",
      });
      chartMetadata[`${dsIdx}-0`] = {
        job: jobName,
        build: comparisonData.build,
        baseBuild: comparisonData.base,
        state: "comparison",
        duration: jobData.duration,
        baseline: baseline,
        pctDiff: pctDiff,
        isComparison: true,
      };
    }
  }

  if (chart) chart.destroy();
  highlightActive = false; // Reset highlight state when chart is recreated

  const isDark = isDarkMode();
  const gridColor = isDark ? "#30363d" : "#d0d7de";
  const textColor = isDark ? "#8b949e" : "#656d76";

  // Calculate x-axis bounds based on time range or custom zoom
  let xMin, xMax;
  if (customXMin !== null) {
    xMin = customXMin;
    xMax = customXMax;
  } else if (timeRangeDays > 0) {
    xMax = Date.now();
    xMin = xMax - timeRangeDays * 24 * 60 * 60 * 1000;
    // Extend xMax to include comparison points if needed
    if (comparisonDate && comparisonDate.getTime() > xMax) {
      xMax = comparisonDate.getTime() + 12 * 60 * 60 * 1000; // +12 hours padding
    }
  }
  // For "All time" (timeRangeDays === 0), leave undefined to auto-scale

  const ctx = document.getElementById("timing-chart").getContext("2d");
  chart = new Chart(ctx, {
    type: "line",
    data: { datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      interaction: {
        mode: "nearest",
        intersect: true,
      },
      plugins: {
        legend: {
          display: false,
        },
        zoom: {
          pan: {
            enabled: true,
            mode: "xy",
            modifierKey: null,
            onPanComplete: handleZoomPanComplete,
          },
          zoom: {
            wheel: {
              enabled: true,
              modifierKey: null,
            },
            drag: {
              enabled: true,
              backgroundColor: "rgba(9, 105, 218, 0.2)",
              borderColor: "rgba(9, 105, 218, 0.8)",
              borderWidth: 1,
            },
            mode: "xy",
            onZoomComplete: handleZoomPanComplete,
          },
        },
        tooltip: {
          borderWidth: 3,
          borderColor: (ctx) => {
            if (ctx.tooltip?.dataPoints?.length > 0) {
              const dp = ctx.tooltip.dataPoints[0];
              // Get the actual line color
              const color =
                dp.dataset.borderColor !== "transparent"
                  ? dp.dataset.borderColor
                  : dp.dataset.backgroundColor;
              return color;
            }
            return "transparent";
          },
          callbacks: {
            title: (items) => {
              if (items.length === 0) return "";
              const ctx = items[0];
              // Strip " (points)" suffix from label
              const label = ctx.dataset.label.replace(" (points)", "");
              return convertEmojiText(label);
            },
            label: (ctx) => {
              // Only show details for point datasets (pointRadius > 0)
              if (ctx.dataset.pointRadius === 0) return null;
              const key = `${ctx.datasetIndex}-${ctx.dataIndex}`;
              const meta = chartMetadata[key];
              if (!meta) return null;

              // Coverage dataset tooltip
              if (meta.coverage != null) {
                return [
                  `${meta.coverage.toFixed(2)}%`,
                  `Commit: ${meta.commit?.slice(0, 8) || ""}`,
                ];
              }

              // Comparison dataset tooltip
              if (meta.isComparison) {
                const pctStr = (meta.pctDiff * 100).toFixed(1);
                const arrow =
                  meta.pctDiff > 0 ? "↑" : meta.pctDiff < 0 ? "↓" : "";
                const sign = meta.pctDiff > 0 ? "+" : "";
                return [
                  `PR Build #${meta.build}: ${formatDuration(meta.duration)}`,
                  `Baseline (median): ${formatDuration(meta.baseline)}`,
                  `${arrow} ${sign}${pctStr}% vs baseline`,
                ];
              }

              // Duration dataset tooltip
              const getStateDisplay = (state) => {
                if (state === "timed_out") return "⤒ timed out";
                if (state === "failed") return "❌ failed";
                if (state === "canceled") return "❌ canceled";
                if (state === "passed") return "✓ passed";
                return state || "";
              };
              const lines = [];
              if (meta.isBreakage) lines.push("⚡ Detected breakage");
              lines.push(
                `${getStateDisplay(meta.state)} · ${formatDuration(ctx.parsed.y)}`,
              );
              if (meta.message) lines.push(meta.message);
              if (meta?.agent) lines.push(`🖥️ ${meta.agent}`);
              return lines;
            },
            labelColor: (ctx) => {
              // Use actual color (not transparent for points dataset)
              const color =
                ctx.dataset.backgroundColor !== "transparent"
                  ? ctx.dataset.backgroundColor
                  : ctx.dataset.borderColor;
              return {
                borderColor: color,
                backgroundColor: color,
              };
            },
          },
        },
      },
      scales: {
        x: {
          type: "time",
          min: xMin,
          max: xMax,
          time: {
            displayFormats: {
              second: "HH:mm:ss",
              minute: "HH:mm",
              hour: "MMM d HH:mm",
              day: "MMM d",
              week: "MMM d",
              month: "MMM yyyy",
            },
          },
          ticks: {
            color: textColor,
            maxRotation: 45,
            callback: function (value, index, ticks) {
              // Hide labels for minor ticks
              if (ticks[index] && ticks[index].minor) {
                return "";
              }

              const date = new Date(value);
              const months = [
                "Jan",
                "Feb",
                "Mar",
                "Apr",
                "May",
                "Jun",
                "Jul",
                "Aug",
                "Sep",
                "Oct",
                "Nov",
                "Dec",
              ];

              // Determine time range to decide format (only count major ticks)
              const majorTicks = ticks.filter((t) => !t.minor);
              const rangeMs =
                majorTicks.length >= 2
                  ? majorTicks[majorTicks.length - 1].value -
                    majorTicks[0].value
                  : Infinity;
              const MINUTE = 60 * 1000;
              const HOUR = 60 * MINUTE;
              const DAY = 24 * HOUR;

              const hours = date.getHours().toString().padStart(2, "0");
              const mins = date.getMinutes().toString().padStart(2, "0");
              const secs = date.getSeconds().toString().padStart(2, "0");

              // Find previous major tick for date comparison
              let prevMajorTick = null;
              for (let i = index - 1; i >= 0; i--) {
                if (!ticks[i].minor) {
                  prevMajorTick = ticks[i];
                  break;
                }
              }
              const prevDate = prevMajorTick
                ? new Date(prevMajorTick.value)
                : null;
              const isFirstMajor = !prevMajorTick;

              // For ranges under 10 minutes, show seconds
              if (rangeMs < 10 * MINUTE) {
                const timeStr = `${hours}:${mins}:${secs}`;
                if (isFirstMajor) {
                  return `${months[date.getMonth()]} ${date.getDate()} ${timeStr}`;
                }
                if (prevDate && prevDate.getDate() !== date.getDate()) {
                  return `${months[date.getMonth()]} ${date.getDate()} ${timeStr}`;
                }
                return timeStr;
              }

              // For ranges under 3 days, show time (hours:minutes)
              if (rangeMs < 3 * DAY) {
                const timeStr = `${hours}:${mins}`;
                // Show date on first tick or when date changes
                if (isFirstMajor) {
                  return `${months[date.getMonth()]} ${date.getDate()} ${timeStr}`;
                }
                if (prevDate && prevDate.getDate() !== date.getDate()) {
                  return `${months[date.getMonth()]} ${date.getDate()} ${timeStr}`;
                }
                return timeStr;
              }

              // Default: day-level labels
              const label = `${months[date.getMonth()]} ${date.getDate()}`;
              // Show year on first tick and when year changes
              if (isFirstMajor) {
                return `${label} '${date.getFullYear().toString().slice(-2)}`;
              }
              if (prevDate && prevDate.getFullYear() !== date.getFullYear()) {
                return `${label} '${date.getFullYear().toString().slice(-2)}`;
              }
              return label;
            },
          },
          grid: {
            color: (ctx) => {
              // Minor grid lines are lighter
              if (ctx.tick && ctx.tick.minor) {
                return isDark
                  ? "rgba(48, 54, 61, 0.5)"
                  : "rgba(208, 215, 222, 0.5)";
              }
              return gridColor;
            },
          },
          afterBuildTicks: (axis) => {
            const rangeMs = axis.max - axis.min;
            const SECOND = 1000;
            const MINUTE = 60 * SECOND;
            const HOUR = 60 * MINUTE;
            const DAY = 24 * HOUR;

            // Nice intervals from seconds to years, with minor tick subdivisions
            const niceStepsWithMinor = [
              { step: 5 * SECOND, minor: SECOND },
              { step: 10 * SECOND, minor: 2 * SECOND },
              { step: 15 * SECOND, minor: 5 * SECOND },
              { step: 30 * SECOND, minor: 10 * SECOND },
              { step: MINUTE, minor: 15 * SECOND },
              { step: 2 * MINUTE, minor: 30 * SECOND },
              { step: 5 * MINUTE, minor: MINUTE },
              { step: 10 * MINUTE, minor: 2 * MINUTE },
              { step: 15 * MINUTE, minor: 5 * MINUTE },
              { step: 30 * MINUTE, minor: 10 * MINUTE },
              { step: HOUR, minor: 15 * MINUTE },
              { step: 2 * HOUR, minor: 30 * MINUTE },
              { step: 4 * HOUR, minor: HOUR },
              { step: 6 * HOUR, minor: 2 * HOUR },
              { step: 12 * HOUR, minor: 3 * HOUR },
              { step: DAY, minor: 6 * HOUR },
              { step: 2 * DAY, minor: DAY },
              { step: 7 * DAY, minor: DAY },
              { step: 14 * DAY, minor: 7 * DAY },
              { step: 30 * DAY, minor: 7 * DAY },
              { step: 60 * DAY, minor: 14 * DAY },
              { step: 90 * DAY, minor: 30 * DAY },
              { step: 180 * DAY, minor: 30 * DAY },
              { step: 365 * DAY, minor: 90 * DAY },
            ];

            // Find smallest step that gives <= 12 major ticks
            const config = niceStepsWithMinor.find(
              (c) => rangeMs / c.step <= 12,
            ) || { step: 30 * DAY, minor: 7 * DAY };
            const step = config.step;
            const minorStep = config.minor;

            // Round min to appropriate boundary
            const minDate = new Date(axis.min);
            let minTick;

            if (step < MINUTE) {
              // Align to second boundary
              minDate.setMilliseconds(0);
              minTick = minDate.getTime();
            } else if (step < HOUR) {
              // Align to minute boundary
              minDate.setSeconds(0, 0);
              minTick = minDate.getTime();
            } else if (step < DAY) {
              // Align to hour boundary
              minDate.setMinutes(0, 0, 0);
              minTick = minDate.getTime();
            } else if (step < 7 * DAY) {
              // Align to day boundary
              minDate.setHours(0, 0, 0, 0);
              minTick = minDate.getTime();
            } else if (step < 60 * DAY) {
              // Align to week boundary (Sunday)
              minDate.setHours(0, 0, 0, 0);
              minTick = minDate.getTime();
              const dayOfWeek = minDate.getDay();
              minTick -= dayOfWeek * DAY;
            } else if (step < 365 * DAY) {
              // Align to month boundary (1st of month)
              minDate.setDate(1);
              minDate.setHours(0, 0, 0, 0);
              minTick = minDate.getTime();
            } else {
              // Align to year boundary (Jan 1)
              minDate.setMonth(0, 1);
              minDate.setHours(0, 0, 0, 0);
              minTick = minDate.getTime();
            }

            // Move to first tick after axis.min
            while (minTick < axis.min) minTick += minorStep;

            // Generate ticks with minor flag
            const ticks = [];
            for (let v = minTick; v <= axis.max; v += minorStep) {
              // Check if this is a major tick (aligned to step)
              const isMajor =
                Math.abs(v % step) < minorStep / 2 ||
                Math.abs((v % step) - step) < minorStep / 2;
              ticks.push({ value: v, major: isMajor, minor: !isMajor });
            }
            if (ticks.length > 0) axis.ticks = ticks;
          },
        },
        y: {
          min: customYMin || undefined,
          max: customYMax || undefined,
          title: {
            display: true,
            text: "Duration",
            color: textColor,
          },
          ticks: {
            color: textColor,
            callback: (v) => formatDuration(v),
            // Use nice intervals: 1m, 2m, 5m, 10m, 15m, 30m, 1h, 2h
            autoSkip: true,
            maxTicksLimit: 10,
          },
          grid: { color: gridColor },
          afterBuildTicks: (axis) => {
            const range = axis.max - axis.min;
            // Pick step size for nice round numbers
            const niceSteps = [60, 120, 300, 600, 900, 1800, 3600, 7200];
            let step = niceSteps.find((s) => range / s <= 10) || 7200;
            const minTick = Math.ceil(axis.min / step) * step;
            const ticks = [];
            for (let v = minTick; v <= axis.max; v += step) {
              ticks.push({ value: v });
            }
            axis.ticks = ticks;
          },
        },
        y2: {
          display: hasCoverageData,
          position: "right",
          min: 0,
          max: 100,
          title: {
            display: hasCoverageData,
            text: "Coverage %",
            color: textColor,
          },
          ticks: {
            color: textColor,
            callback: (v) => v + "%",
            stepSize: 10,
          },
          grid: {
            drawOnChartArea: false,
          },
        },
      },
      onClick: (evt, elements) => {
        if (elements.length > 0) {
          const el = elements[0];
          const key = `${el.datasetIndex}-${el.index}`;
          const meta = chartMetadata[key];
          if (meta) showPopup(meta);
        }
      },
      onHover: (evt, elements) => {
        if (elements.length > 0) {
          const el = elements[0];
          const key = `${el.datasetIndex}-${el.index}`;
          const meta = chartMetadata[key];
          if (meta && meta.job) {
            const dataset = chart.data.datasets[el.datasetIndex];
            const yAxisID = dataset.yAxisID || "y";
            highlightYAxis(yAxisID);
            highlightStatsRow(meta.job, meta.agent);
          }
        } else {
          clearYAxisHighlight();
          clearStatsRowHighlight();
        }
      },
    },
  });
}

function showPopup(meta) {
  document.getElementById("popup-job").innerHTML = convertEmoji(meta.job);
  const coverageLinksEl = document.getElementById("popup-coverage-links");

  // Check if this is a coverage data point
  const isCoverage = meta.coverage != null;

  if (isCoverage) {
    // Coverage-specific popup
    const state = "passed";
    const stateEl = document.getElementById("popup-state");
    stateEl.innerHTML = "✅ passed";
    stateEl.style.color = "var(--color-success-fg)";
    document.getElementById("popup-duration").innerHTML =
      '<span class="text-muted">—</span>';
    document.getElementById("popup-agent").textContent = "(n/a)";
    document.getElementById("popup-date").textContent = meta.date;
    document.getElementById("popup-commit").textContent = meta.commit;
    document.getElementById("popup-message").textContent = "(coverage data)";
    document.getElementById("popup-author").textContent = "(n/a)";
    document.getElementById("popup-build").textContent = `#${meta.build}`;

    // Get full commit SHA from coverage data
    const fullCommit = getFullCommitSha(meta.commit);

    document.getElementById("popup-github-link").href =
      `https://github.com/JuliaLang/julia/commit/${fullCommit}`;
    document.getElementById("popup-buildkite-link").href =
      `https://buildkite.com/julialang/julia-master-scheduled/builds/${meta.build}`;

    // Show coverage links
    coverageLinksEl.style.display = "";
    const isCoveralls = meta.job.includes("Coveralls");
    const coverageUrl = isCoveralls
      ? `https://coveralls.io/builds/${fullCommit}`
      : `https://app.codecov.io/gh/JuliaLang/julia/commit/${fullCommit}`;
    const serviceName = isCoveralls ? "Coveralls" : "Codecov";
    document.getElementById("popup-coverage-value").innerHTML =
      `<strong>${meta.coverage.toFixed(2)}%</strong> on <a href="${coverageUrl}" target="_blank" rel="noopener noreferrer">${serviceName}</a>`;
  } else {
    // Regular job popup
    const state = meta.state || "passed";
    const stateEl = document.getElementById("popup-state");
    const failed = isFailedState(state);
    const stateIcon = failed ? "❌" : "✅";
    const stateText = state === "timed_out" ? "timed out" : state;
    stateEl.innerHTML = `${stateIcon} ${stateText}`;
    stateEl.style.color = failed
      ? "var(--color-danger-fg)"
      : state === "passed"
        ? "var(--color-success-fg)"
        : "inherit";

    // Show retry info if this is a retry attempt
    const retryRow = document.getElementById("popup-retry-row");
    const retryEl = document.getElementById("popup-retry");
    const retryNum = meta.retry || 0;
    if (retryNum > 0) {
      retryRow.style.display = "";
      retryEl.innerHTML = `<span style="color: var(--color-attention-fg)">🔄 Retry #${retryNum}</span>`;
    } else {
      retryRow.style.display = "none";
    }

    document.getElementById("popup-duration").textContent = formatDuration(
      meta.duration,
    );
    document.getElementById("popup-agent").textContent =
      meta.agent || "(unknown)";
    document.getElementById("popup-date").textContent = meta.date;
    document.getElementById("popup-commit").textContent = meta.commit;
    document.getElementById("popup-message").textContent =
      meta.message || "(no message)";
    document.getElementById("popup-author").textContent =
      meta.author || "(unknown)";
    document.getElementById("popup-build").textContent = `#${meta.build}`;

    document.getElementById("popup-github-link").href =
      `https://github.com/JuliaLang/julia/commit/${meta.commit}`;

    // Use stored pipeline, with fallback heuristic for old data
    const pipeline =
      meta.pipeline ||
      (meta.job.toLowerCase().includes("coverage") ||
      meta.job.toLowerCase().includes("srcassert")
        ? "julia-master-scheduled"
        : "julia-master");
    document.getElementById("popup-buildkite-link").href =
      `https://buildkite.com/julialang/${pipeline}/builds/${meta.build}`;

    // Hide coverage links for regular jobs
    coverageLinksEl.style.display = "none";
  }

  document.getElementById("popup-overlay").classList.add("visible");
  document.getElementById("popup-overlay").setAttribute("aria-hidden", "false");
}

// Helper to get full commit SHA from coverage data
function getFullCommitSha(shortCommit) {
  if (!data?.coverage) return shortCommit;
  // Look for a full SHA that starts with the short commit
  for (const sha of Object.keys(data.coverage)) {
    if (sha.startsWith(shortCommit)) return sha;
  }
  return shortCommit;
}

function closePopup(event) {
  if (event.target.id === "popup-overlay") {
    closePopupOverlay();
  }
}

function closePopupOverlay() {
  const el = document.getElementById("popup-overlay");
  el.classList.remove("visible");
  el.setAttribute("aria-hidden", "true");
}

// Helper to convert HSL to RGB
function hslToRgb(h, s, l) {
  s /= 100;
  l /= 100;
  const a = s * Math.min(l, 1 - l);
  const f = (n) => {
    const k = (n + h / 30) % 12;
    return l - a * Math.max(Math.min(k - 3, 9 - k, 1), -1);
  };
  return [
    Math.round(f(0) * 255),
    Math.round(f(8) * 255),
    Math.round(f(4) * 255),
  ];
}

// Helper to convert any color to rgba with specified alpha
function colorToRgba(color, alpha) {
  if (!color || typeof color !== "string") return color;

  // Handle hex colors
  const hexResult = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})/i.exec(color);
  if (hexResult) {
    return `rgba(${parseInt(hexResult[1], 16)}, ${parseInt(hexResult[2], 16)}, ${parseInt(hexResult[3], 16)}, ${alpha})`;
  }

  // Handle hsl colors - convert to rgba
  const hslMatch = color.match(/hsl\((\d+),\s*(\d+)%,\s*(\d+)%\)/);
  if (hslMatch) {
    const [r, g, b] = hslToRgb(
      parseInt(hslMatch[1]),
      parseInt(hslMatch[2]),
      parseInt(hslMatch[3]),
    );
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }

  // Handle rgb colors
  const rgbMatch = color.match(/rgb\((\d+),\s*(\d+),\s*(\d+)\)/);
  if (rgbMatch) {
    return `rgba(${rgbMatch[1]}, ${rgbMatch[2]}, ${rgbMatch[3]}, ${alpha})`;
  }

  // Handle rgba - replace the alpha
  const rgbaMatch = color.match(/rgba\((\d+),\s*(\d+),\s*(\d+),\s*[\d.]+\)/);
  if (rgbaMatch) {
    return `rgba(${rgbaMatch[1]}, ${rgbaMatch[2]}, ${rgbaMatch[3]}, ${alpha})`;
  }

  // Handle hsla - convert to rgba
  const hslaMatch = color.match(/hsla\((\d+),\s*(\d+)%,\s*(\d+)%,\s*[\d.]+\)/);
  if (hslaMatch) {
    const [r, g, b] = hslToRgb(
      parseInt(hslaMatch[1]),
      parseInt(hslaMatch[2]),
      parseInt(hslaMatch[3]),
    );
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }

  return color;
}

// Create smaller timeout marker for de-emphasized state
function createSmallTimedOutMarker(fillColor) {
  const scale = window.devicePixelRatio || 2;
  // Smaller on narrow screens: 3.5px vs 5px
  const size = window.innerWidth <= 480 ? 3.5 : 5;
  const canvas = document.createElement("canvas");
  canvas.width = size * scale;
  canvas.height = size * scale;
  canvas.style.width = size + "px";
  canvas.style.height = size + "px";
  const ctx = canvas.getContext("2d");
  ctx.scale(scale, scale);
  ctx.strokeStyle = fillColor;
  ctx.fillStyle = fillColor;
  ctx.lineWidth = size <= 4 ? 0.4 : 0.5;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  const cx = size / 2;
  const cy = size / 2 + (size <= 4 ? 0.35 : 0.5);
  const barHalf = size <= 4 ? 0.5 : 0.75;
  const stemLen = size <= 4 ? 1.4 : 2;
  const arrowY = size <= 4 ? 0.9 : 1.25;
  ctx.beginPath();
  ctx.moveTo(cx - barHalf, cy);
  ctx.lineTo(cx + barHalf, cy);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(cx, cy);
  ctx.lineTo(cx, cy + stemLen);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(cx - barHalf, cy + arrowY);
  ctx.lineTo(cx, cy);
  ctx.lineTo(cx + barHalf, cy + arrowY);
  ctx.stroke();
  return canvas;
}

// Cache for small timeout markers
const smallTimedOutMarkerCache = {};
function getSmallTimedOutMarker(color) {
  if (!smallTimedOutMarkerCache[color]) {
    smallTimedOutMarkerCache[color] = createSmallTimedOutMarker(color);
  }
  return smallTimedOutMarkerCache[color];
}

// Y-axis only highlighting (for chart hover)
let yAxisHighlightActive = false;
function highlightYAxis(yAxisID) {
  if (!chart) return;

  const mutedAxisColor = "rgba(128, 128, 128, 0.4)";

  // Store original values on first highlight
  if (!yAxisHighlightActive) {
    if (chart.options.scales.y?.title) {
      chart.options.scales.y.title._originalColor =
        chart.options.scales.y.title.color;
    }
    if (chart.options.scales.y?.ticks) {
      chart.options.scales.y.ticks._originalColor =
        chart.options.scales.y.ticks.color;
    }
    if (chart.options.scales.y2?.title) {
      chart.options.scales.y2.title._originalColor =
        chart.options.scales.y2.title.color;
    }
    if (chart.options.scales.y2?.ticks) {
      chart.options.scales.y2.ticks._originalColor =
        chart.options.scales.y2.ticks.color;
    }
    yAxisHighlightActive = true;
  }

  // Highlight the relevant y-axis
  if (chart.options.scales.y) {
    const isHighlighted = yAxisID === "y";
    if (chart.options.scales.y.title) {
      chart.options.scales.y.title.color = isHighlighted
        ? chart.options.scales.y.title._originalColor
        : mutedAxisColor;
    }
    if (chart.options.scales.y.ticks) {
      chart.options.scales.y.ticks.color = isHighlighted
        ? chart.options.scales.y.ticks._originalColor
        : mutedAxisColor;
    }
  }
  if (chart.options.scales.y2) {
    const isHighlighted = yAxisID === "y2";
    if (chart.options.scales.y2.title) {
      chart.options.scales.y2.title.color = isHighlighted
        ? chart.options.scales.y2.title._originalColor
        : mutedAxisColor;
    }
    if (chart.options.scales.y2.ticks) {
      chart.options.scales.y2.ticks.color = isHighlighted
        ? chart.options.scales.y2.ticks._originalColor
        : mutedAxisColor;
    }
  }
  chart.update();
}

function clearYAxisHighlight() {
  if (!chart || !yAxisHighlightActive) return;

  if (chart.options.scales.y?.title?._originalColor !== undefined) {
    chart.options.scales.y.title.color =
      chart.options.scales.y.title._originalColor;
  }
  if (chart.options.scales.y?.ticks?._originalColor !== undefined) {
    chart.options.scales.y.ticks.color =
      chart.options.scales.y.ticks._originalColor;
  }
  if (chart.options.scales.y2?.title?._originalColor !== undefined) {
    chart.options.scales.y2.title.color =
      chart.options.scales.y2.title._originalColor;
  }
  if (chart.options.scales.y2?.ticks?._originalColor !== undefined) {
    chart.options.scales.y2.ticks.color =
      chart.options.scales.y2.ticks._originalColor;
  }
  yAxisHighlightActive = false;
  chart.update();
}

// Stats row highlighting (for chart hover)
let highlightedStatsRow = null;
let highlightedHostRow = null;
function highlightStatsRow(jobName, agent = null) {
  clearStatsRowHighlight();
  // Find row by iterating (safer than CSS selector with special chars)
  const rows = document.querySelectorAll("#stats-tbody tr[data-job]");
  for (const row of rows) {
    if (row.dataset.job === jobName && !row.dataset.agent) {
      row.classList.add("chart-hover-highlight");
      highlightedStatsRow = row;
      // Scroll into view if not visible
      const wrapper = document.getElementById("stats-wrapper");
      if (wrapper) {
        const rowRect = row.getBoundingClientRect();
        const wrapperRect = wrapper.getBoundingClientRect();
        if (
          rowRect.top < wrapperRect.top ||
          rowRect.bottom > wrapperRect.bottom
        ) {
          row.scrollIntoView({ block: "center", behavior: "smooth" });
        }
      }
      break;
    }
  }
  // Also highlight the host row if job is expanded and agent is specified
  if (agent && expandedJobs.has(jobName)) {
    const hostRows = document.querySelectorAll(
      "#stats-tbody tr.host-row[data-job][data-agent]",
    );
    for (const hostRow of hostRows) {
      if (hostRow.dataset.job === jobName && hostRow.dataset.agent === agent) {
        hostRow.classList.add("chart-hover-highlight");
        highlightedHostRow = hostRow;
        break;
      }
    }
  }
}

function clearStatsRowHighlight() {
  if (highlightedStatsRow) {
    highlightedStatsRow.classList.remove("chart-hover-highlight");
    highlightedStatsRow = null;
  }
  if (highlightedHostRow) {
    highlightedHostRow.classList.remove("chart-hover-highlight");
    highlightedHostRow = null;
  }
}

// Highlight a specific job/agent in the chart, de-emphasizing others
let highlightActive = false;
function highlightChartDataset(jobColor, agent = null, yAxisID = "y") {
  if (!chart) return;

  // Store original values on first highlight
  if (!highlightActive) {
    chart.data.datasets.forEach((ds) => {
      ds._originalBorderColor = ds.borderColor;
      ds._originalBackgroundColor = ds.backgroundColor;
      ds._originalBorderWidth = ds.borderWidth;
      ds._originalPointRadius = ds.pointRadius;
      ds._originalPointBackgroundColor = ds.pointBackgroundColor;
      ds._originalPointBorderColor = ds.pointBorderColor;
      ds._originalPointStyle = ds.pointStyle;
    });
    // Store original axis colors (title and ticks)
    if (chart.options.scales.y) {
      if (chart.options.scales.y.title) {
        chart.options.scales.y.title._originalColor =
          chart.options.scales.y.title.color;
      }
      if (chart.options.scales.y.ticks) {
        chart.options.scales.y.ticks._originalColor =
          chart.options.scales.y.ticks.color;
      }
    }
    if (chart.options.scales.y2) {
      if (chart.options.scales.y2.title) {
        chart.options.scales.y2.title._originalColor =
          chart.options.scales.y2.title.color;
      }
      if (chart.options.scales.y2.ticks) {
        chart.options.scales.y2.ticks._originalColor =
          chart.options.scales.y2.ticks.color;
      }
    }
    highlightActive = true;
  }

  // Highlight the relevant y-axis (title and ticks)
  const mutedAxisColor = "rgba(128, 128, 128, 0.4)";
  if (chart.options.scales.y) {
    const isHighlighted = yAxisID === "y";
    if (chart.options.scales.y.title) {
      chart.options.scales.y.title.color = isHighlighted
        ? chart.options.scales.y.title._originalColor
        : mutedAxisColor;
    }
    if (chart.options.scales.y.ticks) {
      chart.options.scales.y.ticks.color = isHighlighted
        ? chart.options.scales.y.ticks._originalColor
        : mutedAxisColor;
    }
  }
  if (chart.options.scales.y2) {
    const isHighlighted = yAxisID === "y2";
    if (chart.options.scales.y2.title) {
      chart.options.scales.y2.title.color = isHighlighted
        ? chart.options.scales.y2.title._originalColor
        : mutedAxisColor;
    }
    if (chart.options.scales.y2.ticks) {
      chart.options.scales.y2.ticks.color = isHighlighted
        ? chart.options.scales.y2.ticks._originalColor
        : mutedAxisColor;
    }
  }

  chart.data.datasets.forEach((ds, dsIdx) => {
    // Match by the original border color (unique per job)
    const isJobMatch = ds._originalBorderColor === jobColor;
    // Check if this is a comparison point dataset for the highlighted job
    const comparisonMeta = chartMetadata[`${dsIdx}-0`];
    const isComparisonForJob =
      comparisonMeta?.isComparison &&
      jobColors[comparisonMeta.job] === jobColor;
    const hasPointsArray =
      Array.isArray(ds._originalPointRadius) &&
      ds._originalPointRadius.some((r) => r > 0);
    const hasPointsSingle =
      !Array.isArray(ds._originalPointRadius) && ds._originalPointRadius > 0;
    const hasPoints = hasPointsArray || hasPointsSingle;

    // Helper to mute a color
    const muteColor = (c) => {
      if (typeof c === "string") return colorToRgba(c, 0.25);
      return c;
    };

    if ((isJobMatch || isComparisonForJob) && !agent) {
      // Highlight entire job (or its comparison point): keep original formatting
      ds.borderColor = ds._originalBorderColor;
      ds.backgroundColor = ds._originalBackgroundColor;
      ds.borderWidth = ds._originalBorderWidth;
      ds.pointRadius = ds._originalPointRadius;
      ds.pointBackgroundColor = ds._originalPointBackgroundColor;
      ds.pointBorderColor = ds._originalPointBorderColor;
      ds.pointStyle = ds._originalPointStyle;
    } else if (isJobMatch && agent) {
      // Highlight specific agent within this job
      // Mute the line
      ds.borderColor = muteColor(ds._originalBorderColor);
      ds.backgroundColor = muteColor(ds._originalBackgroundColor);
      ds.borderWidth = ds._originalBorderWidth;

      if (hasPoints) {
        // Reduce non-matching agent points to half size (Chart.js caches point colors)
        if (Array.isArray(ds._originalPointRadius)) {
          ds.pointRadius = ds._originalPointRadius.map((r, ptIdx) => {
            const meta = chartMetadata[`${dsIdx}-${ptIdx}`];
            if (meta && meta.agent === agent) return r;
            return r / 2;
          });
        } else {
          ds.pointRadius = ds._originalPointRadius;
        }
        // Use smaller timeout markers for non-matching agents
        if (Array.isArray(ds._originalPointStyle)) {
          ds.pointStyle = ds._originalPointStyle.map((style, ptIdx) => {
            const meta = chartMetadata[`${dsIdx}-${ptIdx}`];
            if (meta && meta.agent === agent) return style;
            if (style instanceof HTMLCanvasElement) {
              const origColor = Array.isArray(ds._originalPointBackgroundColor)
                ? ds._originalPointBackgroundColor[ptIdx]
                : ds._originalPointBackgroundColor;
              return getSmallTimedOutMarker(origColor);
            }
            return style;
          });
        }
        ds.pointBackgroundColor = ds._originalPointBackgroundColor;
        ds.pointBorderColor = ds._originalPointBorderColor;
      }
    } else {
      // De-emphasize non-matching jobs: mute line and reduce points
      ds.borderColor = muteColor(ds._originalBorderColor);
      ds.backgroundColor = muteColor(ds._originalBackgroundColor);
      ds.borderWidth = 1;
      // Reduce points to half size (Chart.js caches point colors)
      if (ds._originalPointRadius) {
        if (Array.isArray(ds._originalPointRadius)) {
          ds.pointRadius = ds._originalPointRadius.map((r) => r / 2);
        } else if (typeof ds._originalPointRadius === "number") {
          ds.pointRadius = ds._originalPointRadius / 2;
        }
      }
      // Use smaller timeout markers for non-matching jobs
      if (Array.isArray(ds._originalPointStyle)) {
        ds.pointStyle = ds._originalPointStyle.map((style, ptIdx) => {
          if (style instanceof HTMLCanvasElement) {
            const origColor = Array.isArray(ds._originalPointBackgroundColor)
              ? ds._originalPointBackgroundColor[ptIdx]
              : ds._originalPointBackgroundColor;
            return getSmallTimedOutMarker(origColor);
          }
          return style;
        });
      }
    }
  });
  chart.update();
}

function clearChartHighlight() {
  if (!chart || !highlightActive) return;

  chart.data.datasets.forEach((ds) => {
    if (ds._originalBorderColor !== undefined)
      ds.borderColor = ds._originalBorderColor;
    if (ds._originalBackgroundColor !== undefined)
      ds.backgroundColor = ds._originalBackgroundColor;
    if (ds._originalBorderWidth !== undefined)
      ds.borderWidth = ds._originalBorderWidth;
    if (ds._originalPointRadius !== undefined)
      ds.pointRadius = ds._originalPointRadius;
    if (ds._originalPointBackgroundColor !== undefined)
      ds.pointBackgroundColor = ds._originalPointBackgroundColor;
    if (ds._originalPointBorderColor !== undefined)
      ds.pointBorderColor = ds._originalPointBorderColor;
    if (ds._originalPointStyle !== undefined)
      ds.pointStyle = ds._originalPointStyle;
  });
  // Restore axis colors (title and ticks)
  if (chart.options.scales.y) {
    if (chart.options.scales.y.title?._originalColor !== undefined) {
      chart.options.scales.y.title.color =
        chart.options.scales.y.title._originalColor;
    }
    if (chart.options.scales.y.ticks?._originalColor !== undefined) {
      chart.options.scales.y.ticks.color =
        chart.options.scales.y.ticks._originalColor;
    }
  }
  if (chart.options.scales.y2) {
    if (chart.options.scales.y2.title?._originalColor !== undefined) {
      chart.options.scales.y2.title.color =
        chart.options.scales.y2.title._originalColor;
    }
    if (chart.options.scales.y2.ticks?._originalColor !== undefined) {
      chart.options.scales.y2.ticks.color =
        chart.options.scales.y2.ticks._originalColor;
    }
  }
  highlightActive = false;
  chart.update();
}

// Resizable stats panel
(function () {
  const handle = document.getElementById("resize-handle");
  const wrapper = document.getElementById("stats-wrapper");
  let startY, startHeight;

  handle.addEventListener("mousedown", (e) => {
    e.preventDefault();
    startY = e.clientY;
    startHeight = wrapper.offsetHeight;
    document.addEventListener("mousemove", onMouseMove);
    document.addEventListener("mouseup", onMouseUp);
    document.body.style.cursor = "ns-resize";
    document.body.style.userSelect = "none";
  });

  function onMouseMove(e) {
    const delta = startY - e.clientY;
    const newHeight = Math.max(
      50,
      Math.min(window.innerHeight * 0.7, startHeight + delta),
    );
    wrapper.style.height = newHeight + "px";
  }

  function onMouseUp() {
    document.removeEventListener("mousemove", onMouseMove);
    document.removeEventListener("mouseup", onMouseUp);
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
    // Save to localStorage
    saveToLocalStorage();
  }

  // Touch support
  handle.addEventListener("touchstart", (e) => {
    const touch = e.touches[0];
    startY = touch.clientY;
    startHeight = wrapper.offsetHeight;
    document.addEventListener("touchmove", onTouchMove);
    document.addEventListener("touchend", onTouchEnd);
  });

  function onTouchMove(e) {
    const touch = e.touches[0];
    const delta = startY - touch.clientY;
    const newHeight = Math.max(
      50,
      Math.min(window.innerHeight * 0.7, startHeight + delta),
    );
    wrapper.style.height = newHeight + "px";
  }

  function onTouchEnd() {
    document.removeEventListener("touchmove", onTouchMove);
    document.removeEventListener("touchend", onTouchEnd);
    saveToLocalStorage();
  }
})();

// Close popup on Escape
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    for (const id of ["popup-overlay", "shortcuts-overlay"]) {
      const el = document.getElementById(id);
      el.classList.remove("visible");
      el.setAttribute("aria-hidden", "true");
    }
  }
  // Keyboard shortcuts (when not typing in an input)
  if (
    e.target.tagName === "INPUT" ||
    e.target.tagName === "TEXTAREA" ||
    e.target.tagName === "SELECT"
  )
    return;

  if (e.key === "?" || (e.key === "/" && e.shiftKey)) {
    e.preventDefault();
    toggleShortcutsHelp();
  } else if (e.key === "r") {
    e.preventDefault();
    if (customXMin !== null || customYMin !== null) resetZoom();
  } else if (e.key === "a") {
    e.preventDefault();
    selectAllJobs();
  } else if (e.key === "n") {
    e.preventDefault();
    deselectAllJobs();
  }
});

function toggleShortcutsHelp() {
  const el = document.getElementById("shortcuts-overlay");
  const visible = el.classList.toggle("visible");
  el.setAttribute("aria-hidden", visible ? "false" : "true");
}

// Update stats table header for comparison mode
function updateStatsTableHeader() {
  const thead = document.getElementById("stats-thead");
  if (!thead) return;

  const baseHeaders = `
                <th scope="col" class="sortable" data-sort="job" onclick="handleStatsTableSort('job')">Job/Report <span class="sort-indicator">▲</span></th>
                <th scope="col">Hosts</th>
                <th scope="col" class="sortable" data-sort="passRate" title="Pass rate in last 14 days" onclick="handleStatsTableSort('passRate')">Pass Rate <span class="sort-indicator">▲</span></th>
                <th scope="col" class="sortable" data-sort="trend" title="Trend over selected time range" onclick="handleStatsTableSort('trend')">Trend <span class="sort-indicator">▲</span></th>
                <th scope="col" class="sortable" data-sort="median" onclick="handleStatsTableSort('median')">Median <span class="sort-indicator">▲</span></th>
                <th scope="col" class="sortable" data-sort="min" onclick="handleStatsTableSort('min')">Min <span class="sort-indicator">▲</span></th>
                <th scope="col" class="sortable" data-sort="max" onclick="handleStatsTableSort('max')">Max <span class="sort-indicator">▲</span></th>
                <th scope="col" class="sortable" data-sort="std" onclick="handleStatsTableSort('std')">σ <span class="sort-indicator">▲</span></th>
                <th scope="col" class="sortable" data-sort="n" onclick="handleStatsTableSort('n')">n <span class="sort-indicator">▲</span></th>
            `;

  const comparisonHeaders = comparisonData
    ? `
                <th scope="col" class="sortable comparison-col comparison-col-first" data-sort="cmpDuration" onclick="handleStatsTableSort('cmpDuration')" title="PR build duration">PR Duration <span class="sort-indicator">▲</span></th>
                <th scope="col" class="sortable comparison-col" data-sort="cmpChange" onclick="handleStatsTableSort('cmpChange')" title="Change vs median">Change <span class="sort-indicator">▲</span></th>
                <th scope="col" class="sortable comparison-col" data-sort="cmpSig" onclick="handleStatsTableSort('cmpSig')" title="Statistical significance">Sig <span class="sort-indicator">▲</span></th>
            `
    : "";

  thead.innerHTML = `<tr>${baseHeaders}${comparisonHeaders}</tr>`;
  updateSortIndicators();
}

function updateStatsTable() {
  const tbody = document.getElementById("stats-tbody");
  tbody.innerHTML = "";

  // Update table header for comparison mode
  updateStatsTableHeader();

  const colSpan = comparisonData ? 13 : 10;
  if (selectedJobs.size === 0) {
    tbody.innerHTML = `<tr><td colspan="${colSpan}" class="loading">Select jobs to see statistics</td></tr>`;
    updateSortIndicators();
    return;
  }

  const { min: rangeMin, max: rangeMax } = getVisibleTimeRange();

  // First, compute all stats for each job
  const jobStats = [];
  for (const jobName of selectedJobs) {
    const job = data.jobs[jobName];
    if (!job) continue;

    const filtered = filterRunsByState(job.recent, rangeMin, rangeMax);
    if (filtered.length === 0) continue;

    // Collect agent counts from all runs in range (not just filtered by state)
    const allRunsInRange = job.recent.filter((r) => {
      const date = new Date(r.date);
      return (
        (!rangeMin || date >= rangeMin) &&
        (!rangeMax || date <= rangeMax) &&
        (excludedHosts.size === 0 || !excludedHosts.has(r.agent))
      );
    });
    const agentCounts = {};
    for (const r of allRunsInRange) {
      const agent = r.agent || "";
      if (agent) agentCounts[agent] = (agentCounts[agent] || 0) + 1;
    }
    const agents = Object.entries(agentCounts).sort((a, b) => b[1] - a[1]); // Sort by count desc

    // Calculate pass rate from all runs in range (ignoring state filter)
    let prPassed = 0,
      prFailed = 0,
      prTimedOut = 0,
      prCanceled = 0,
      prRetries = 0;
    for (const r of allRunsInRange) {
      const state = r.state || "passed";
      if (state === "passed") prPassed++;
      else if (state === "failed") prFailed++;
      else if (state === "timed_out") prTimedOut++;
      else if (state === "canceled") prCanceled++;
      if (r.retry > 0) prRetries++;
    }
    const prTotal = allRunsInRange.length;
    const pr =
      prTotal > 0
        ? {
            total: prTotal,
            passed: prPassed,
            failed: prFailed,
            timedOut: prTimedOut,
            canceled: prCanceled,
            retries: prRetries,
            rate: prPassed / prTotal,
          }
        : null;

    // Duration stats from all visible runs (respects state filter)
    let median = null,
      mean = null,
      min = null,
      max = null,
      std = null,
      trend = null;
    if (filtered.length > 0) {
      const durations = filtered.map((r) => r.duration);
      const sorted = [...durations].sort((a, b) => a - b);
      median = sorted[Math.floor(sorted.length / 2)];
      mean = durations.reduce((a, b) => a + b, 0) / durations.length;
      min = Math.min(...durations);
      max = Math.max(...durations);
      const variance =
        durations.reduce((sum, d) => sum + (d - mean) ** 2, 0) /
        durations.length;
      std = Math.sqrt(variance);
      trend = computeTrend(filtered);
    }

    jobStats.push({
      jobName,
      color: jobColors[jobName],
      agents,
      median,
      mean,
      min,
      max,
      std,
      trend,
      pr,
      n: filtered.length,
    });
  }

  // Sort based on current sort column
  jobStats.sort((a, b) => {
    let cmp = 0;
    switch (statsTableSortColumn) {
      case "job":
        cmp = a.jobName.localeCompare(b.jobName);
        break;
      case "passRate":
        const prA = a.pr?.rate ?? 1;
        const prB = b.pr?.rate ?? 1;
        cmp = prA - prB;
        break;
      case "median":
        cmp = a.median - b.median;
        break;
      case "mean":
        cmp = a.mean - b.mean;
        break;
      case "min":
        cmp = a.min - b.min;
        break;
      case "max":
        cmp = a.max - b.max;
        break;
      case "std":
        cmp = a.std - b.std;
        break;
      case "trend":
        // Sort by: significant positive (worst) → flat → significant negative (best)
        // Tier: 1 = significant positive, 0 = flat/not significant, -1 = significant negative
        const getTrendTier = (t) => {
          if (!t || !t.significant) return 0; // flat
          return t.percentChange > 0 ? 1 : -1;
        };
        const tierA = getTrendTier(a.trend);
        const tierB = getTrendTier(b.trend);
        if (tierA !== tierB) {
          cmp = tierA - tierB;
        } else {
          // Within same tier, sort by magnitude
          const pctA = a.trend?.percentChange ?? 0;
          const pctB = b.trend?.percentChange ?? 0;
          cmp = pctA - pctB;
        }
        break;
      case "n":
        cmp = a.n - b.n;
        break;
      case "cmpDuration":
        const durA = comparisonData?.jobs[a.jobName]?.duration ?? 0;
        const durB = comparisonData?.jobs[b.jobName]?.duration ?? 0;
        cmp = durA - durB;
        break;
      case "cmpChange":
        const getChange = (stat) => {
          const cmpJob = comparisonData?.jobs[stat.jobName];
          if (!cmpJob || !stat.median) return 0;
          return ((cmpJob.duration - stat.median) / stat.median) * 100;
        };
        cmp = getChange(a) - getChange(b);
        break;
      case "cmpSig":
        const getSig = (stat) => {
          const cmpJob = comparisonData?.jobs[stat.jobName];
          if (!cmpJob || !stat.std || stat.std === 0) return 0;
          return Math.abs((cmpJob.duration - stat.mean) / stat.std);
        };
        cmp = getSig(a) - getSig(b);
        break;
    }
    return statsTableSortAsc ? cmp : -cmp;
  });

  // Render rows

  // Add "All" aggregate row when multiple jobs selected
  if (jobStats.length > 1) {
    // Aggregate pass rate counts
    let allPassed = 0,
      allFailed = 0,
      allTimedOut = 0,
      allCanceled = 0,
      allRetries = 0,
      allTotal = 0;
    let allN = 0;

    for (const stat of jobStats) {
      if (stat.pr) {
        allPassed += stat.pr.passed;
        allFailed += stat.pr.failed;
        allTimedOut += stat.pr.timedOut;
        allCanceled += stat.pr.canceled;
        allRetries += stat.pr.retries || 0;
        allTotal += stat.pr.total;
      }
      allN += stat.n;
    }

    // Normalize each run's duration relative to its job's median
    // This allows meaningful aggregation across jobs with different scales
    const normalizedRuns = [];
    for (const stat of jobStats) {
      if (!stat.median || stat.median <= 0) continue;
      const job = data.jobs[stat.jobName];
      if (!job) continue;
      const filtered = filterRunsByState(job.recent, rangeMin, rangeMax);
      for (const r of filtered) {
        // Normalize: 100% = job's median, so 110% means 10% slower than median
        normalizedRuns.push({
          date: r.date,
          duration: (r.duration / stat.median) * 100, // percentage of median
        });
      }
    }

    // Compute aggregate trend on normalized values
    const aggTrend =
      normalizedRuns.length > 0 ? computeTrend(normalizedRuns) : null;

    let aggPassRateHtml = '<span class="text-muted">—</span>';
    if (allTotal > 0) {
      const aggRate = allPassed / allTotal;
      const aggPct = Math.round(aggRate * 100);
      const aggFailures = allFailed + allTimedOut + allCanceled;
      // Color: green=100%, yellow>=90%, red<90%
      const prColor =
        aggRate >= 1
          ? "var(--color-success-fg)"
          : aggRate >= PASS_RATE_THRESHOLD
            ? "var(--color-attention-fg)"
            : "var(--color-danger-fg)";
      // Check if any job has recent failures or timeouts for warning icons
      let hasAnyRecentFailure = false;
      let hasAnyRecentTimeout = false;
      for (const stat of jobStats) {
        const job = data.jobs[stat.jobName];
        if (job) {
          const issueInfo = hasRecentFailure(job);
          if (issueInfo.hasFailure) hasAnyRecentFailure = true;
          if (issueInfo.hasTimeout) hasAnyRecentTimeout = true;
          if (hasAnyRecentFailure && hasAnyRecentTimeout) break;
        }
      }
      // Icons: ⚠️ if any job has recent failure, ⏳ if any job has recent timeout, 🔄 if retries present
      let icons = "";
      if (hasAnyRecentFailure) icons += "⚠️";
      if (hasAnyRecentTimeout) icons += "⏳";
      if (allRetries > 0) icons += "🔄";
      const parts = [];
      if (allFailed > 0) parts.push(`${allFailed} failed`);
      if (allTimedOut > 0) parts.push(`${allTimedOut} timed out`);
      if (allCanceled > 0) parts.push(`${allCanceled} canceled`);
      if (allRetries > 0) parts.push(`${allRetries} retries`);
      const breakdown = parts.length > 0 ? parts.join(", ") : "all passed";
      aggPassRateHtml = `<span style="color: ${prColor}" title="${breakdown} out of ${allTotal} total runs">${aggPct}%${icons ? " " + icons : ""}</span>`;
    }

    const aggRow = document.createElement("tr");
    aggRow.className = "aggregate-row";
    const aggTrendResult = formatTrend(aggTrend, null, true);
    const aggComparisonCells = comparisonData
      ? '<td class="comparison-col comparison-col-first"></td><td class="comparison-col"></td><td class="comparison-col"></td>'
      : "";
    aggRow.innerHTML = `
                    <td>All (${jobStats.length} jobs)</td>
                    <td></td>
                    <td>${aggPassRateHtml}</td>
                    <td>${aggTrendResult.html}</td>
                    <td></td>
                    <td></td>
                    <td></td>
                    <td></td>
                    <td>${allN}</td>
                    ${aggComparisonCells}
                `;
    tbody.appendChild(aggRow);
  }

  for (const stat of jobStats) {
    const {
      jobName,
      color,
      agents,
      median,
      mean,
      min,
      max,
      std,
      trend,
      pr,
      n,
    } = stat;

    // Build hosts HTML with perceptually-adjusted hue-shifted colors
    let hostsHtml = "";
    if (agents.length > 0) {
      const baseShift = 20;
      const baseHue = getHueFromColor(color);
      const maxShift = baseShift * getPerceptualHueMultiplier(baseHue);
      const maxDotsShown = 10;
      const displayAgents =
        agents.length > maxDotsShown ? agents.slice(0, maxDotsShown) : agents;
      const hostDots = displayAgents
        .map(([agent, count], i) => {
          const hueShift =
            displayAgents.length > 1
              ? -maxShift + (2 * maxShift * i) / (displayAgents.length - 1)
              : 0;
          const hostColor = shiftHue(color, hueShift);
          return `<span class="color-dot" style="background: ${hostColor}" title="${agent}: ${count} runs"></span>`;
        })
        .join("");
      if (agents.length > maxDotsShown) {
        const hiddenCount = agents.length - maxDotsShown;
        const hiddenAgents = agents
          .slice(maxDotsShown)
          .map(([a, c]) => `${a}: ${c} runs`)
          .join("\n");
        hostsHtml =
          hostDots +
          `<span class="text-muted" title="${escapeHtml(hiddenAgents)}">+${hiddenCount}</span>`;
      } else {
        hostsHtml = hostDots;
      }
    }

    let passRateHtml = '<span class="text-muted">—</span>';
    if (pr && pr.total > 0) {
      const pct = Math.round(pr.rate * 100);
      // Color: green=100%, yellow>=90%, red<90%
      const prColor =
        pr.rate >= 1
          ? "var(--color-success-fg)"
          : pr.rate >= PASS_RATE_THRESHOLD
            ? "var(--color-attention-fg)"
            : "var(--color-danger-fg)";
      // Check for recent failures and timeouts
      const job = data.jobs[jobName];
      const issueInfo = job
        ? hasRecentFailure(job)
        : {
            hasFailure: false,
            hasTimeout: false,
            hasBreakage: false,
            tooltipFailure: "",
            tooltipTimeout: "",
            tooltipBreakage: "",
          };
      // Icons: ⚠️ if recent failure, ⏳ if recent timeout, 🔄 if retries present
      let icons = "";
      if (issueInfo.hasFailure) icons += "⚠️";
      if (issueInfo.hasTimeout) icons += "⏳";
      if (pr.retries > 0) icons += "🔄";
      const parts = [];
      if (pr.failed > 0) parts.push(`${pr.failed} failed`);
      if (pr.timedOut > 0) parts.push(`${pr.timedOut} timed out`);
      if (pr.canceled > 0) parts.push(`${pr.canceled} canceled`);
      if (pr.retries > 0) parts.push(`${pr.retries} retries`);
      let breakdown = parts.length > 0 ? parts.join(", ") : "all passed";
      if (issueInfo.hasFailure) {
        const breakageInfo = jobBreakages[jobName];
        if (breakageInfo) {
          breakdown += `\n${issueInfo.tooltipFailure} ⚡ broke at ${breakageInfo.commit.substring(0, 8)}`;
        } else {
          breakdown += `\n${issueInfo.tooltipFailure}`;
        }
      }
      if (issueInfo.hasTimeout) {
        breakdown += `\n${issueInfo.tooltipTimeout}`;
      }
      passRateHtml = `<span style="color: ${prColor}" title="${escapeHtml(breakdown + " out of " + pr.total + " in selected range")}">${pct}%${icons ? " " + icons : ""}</span>`;
    }

    const isExpanded = expandedJobs.has(jobName);
    const hasMultipleHosts = agents.length > 1;

    const row = document.createElement("tr");
    row.dataset.job = jobName;
    if (hasMultipleHosts) {
      row.className = `expandable${isExpanded ? " expanded" : ""}`;
      row.onclick = () => toggleJobExpand(jobName);
    }
    row.onmouseenter = () => highlightChartDataset(color);
    row.onmouseleave = () => clearChartHighlight();
    const trendResult = formatTrend(trend, color);
    const trendCell = trendResult.trendData
      ? `<td class="trend-cell" data-trend='${trendResult.trendData}'>${trendResult.html}</td>`
      : `<td>${trendResult.html}</td>`;

    // Comparison columns
    let comparisonCells = "";
    if (comparisonData) {
      const cmpJob = comparisonData.jobs[jobName];
      if (cmpJob && median) {
        const cmpDuration = cmpJob.duration;
        const pctChange = ((cmpDuration - median) / median) * 100;
        const zScore = std > 0 ? (cmpDuration - mean) / std : 0;
        const pValue = 2 * (1 - normalCDF(Math.abs(zScore)));
        const isSignificant = pValue < 0.05 && Math.abs(pctChange) > 5;

        // Format change with color
        const changeSign = pctChange > 0 ? "+" : "";
        const changeColor = isSignificant
          ? pctChange > 0
            ? "var(--color-danger-fg)"
            : "var(--color-success-fg)"
          : "var(--color-fg-muted)";
        const changeHtml = `<span style="color: ${changeColor}">${changeSign}${pctChange.toFixed(1)}%</span>`;

        // Format significance
        let sigHtml;
        if (isSignificant) {
          const stars = pValue < 0.001 ? "***" : pValue < 0.01 ? "**" : "*";
          const sigColor =
            pctChange > 0
              ? "var(--color-danger-fg)"
              : "var(--color-success-fg)";
          sigHtml = `<span style="color: ${sigColor}" title="p=${pValue.toFixed(4)}, z=${zScore.toFixed(2)}">${stars}</span>`;
        } else {
          sigHtml = `<span class="text-muted" title="p=${pValue.toFixed(4)}, z=${zScore.toFixed(2)}">—</span>`;
        }

        comparisonCells = `
                            <td class="duration comparison-col comparison-col-first">${formatDuration(cmpDuration)}</td>
                            <td class="comparison-col">${changeHtml}</td>
                            <td class="comparison-col">${sigHtml}</td>
                        `;
      } else {
        comparisonCells =
          '<td class="comparison-col comparison-col-first">—</td><td class="comparison-col">—</td><td class="comparison-col">—</td>';
      }
    }

    row.innerHTML = `
                    <td><span class="color-dot" style="background: ${color}"></span> ${convertEmoji(jobName)}</td>
                    <td>${hostsHtml}</td>
                    <td>${passRateHtml}</td>
                    ${trendCell}
                    <td class="duration">${formatDuration(median)}</td>
                    <td class="duration">${formatDuration(min)}</td>
                    <td class="duration">${formatDuration(max)}</td>
                    <td class="duration">${std != null ? "±" + formatDuration(std) : formatDuration(null)}</td>
                    <td>${n}</td>
                    ${comparisonCells}
                `;
    tbody.appendChild(row);

    // Add host detail rows if expanded
    if (isExpanded && hasMultipleHosts) {
      const job = data.jobs[jobName];
      const baseShift = 20;
      const baseHue = getHueFromColor(color);
      const maxShift = baseShift * getPerceptualHueMultiplier(baseHue);

      for (let i = 0; i < agents.length; i++) {
        const [agent, count] = agents[i];
        const hueShift =
          agents.length > 1
            ? -maxShift + (2 * maxShift * i) / (agents.length - 1)
            : 0;
        const hostColor = shiftHue(color, hueShift);

        // Calculate stats for this host only (respects state filter)
        const allHostRuns = job.recent.filter((r) => {
          if (r.agent !== agent) return false;
          const date = new Date(r.date);
          return date >= rangeMin && date <= rangeMax;
        });
        const hostFilteredRuns = allHostRuns.filter((r) => {
          const runState = getRunState(r);
          return excludedStates.size === 0 || !excludedStates.has(runState);
        });
        const hostDurations = hostFilteredRuns.map((r) => r.duration);
        const hostSorted = [...hostDurations].sort((a, b) => a - b);
        const hostMedian =
          hostDurations.length > 0
            ? hostSorted[Math.floor(hostDurations.length / 2)]
            : 0;
        const hostMean =
          hostDurations.length > 0
            ? hostDurations.reduce((a, b) => a + b, 0) / hostDurations.length
            : 0;
        const hostMin =
          hostDurations.length > 0 ? Math.min(...hostDurations) : 0;
        const hostMax =
          hostDurations.length > 0 ? Math.max(...hostDurations) : 0;
        const hostVariance =
          hostDurations.length > 0
            ? hostDurations.reduce((sum, d) => sum + (d - hostMean) ** 2, 0) /
              hostDurations.length
            : 0;
        const hostStd = Math.sqrt(hostVariance);
        const hostTrend = computeTrend(hostFilteredRuns);
        const hostN = hostFilteredRuns.length;

        // Calculate pass rate for this host from all runs in time range
        let hostPrHtml = '<span class="text-muted">—</span>';
        const hostTotal = allHostRuns.length;
        if (hostTotal > 0) {
          let hostPassed = 0,
            hostFailed = 0,
            hostTimedOut = 0,
            hostCanceled = 0,
            hostRetries = 0;
          for (const run of allHostRuns) {
            const state = run.state || "passed";
            if (state === "passed") hostPassed++;
            else if (state === "failed") hostFailed++;
            else if (state === "timed_out") hostTimedOut++;
            else if (state === "canceled") hostCanceled++;
            if (run.retry > 0) hostRetries++;
          }
          const hostRate = hostPassed / hostTotal;
          const hostPct = Math.round(hostRate * 100);
          // Color: green=100%, yellow>=90%, red<90%
          const hostPrColor =
            hostRate >= 1
              ? "var(--color-success-fg)"
              : hostRate >= PASS_RATE_THRESHOLD
                ? "var(--color-attention-fg)"
                : "var(--color-danger-fg)";

          // Check for recent failures/timeouts using same logic as hasRecentFailure
          const now = new Date();
          const last24h = new Date(now.getTime() - 24 * 60 * 60 * 1000);
          const hostLastThree = allHostRuns.slice(
            0,
            Math.min(3, allHostRuns.length),
          );
          let hostHasFailure = false,
            hostHasTimeout = false;
          let hostRecentFailed = 0,
            hostRecentTimedOut = 0;
          for (const run of hostLastThree) {
            const runDate = new Date(run.date);
            const state = run.state || "passed";
            if (state === "failed") {
              hostRecentFailed++;
              if (runDate >= last24h) hostHasFailure = true;
            } else if (state === "timed_out") {
              hostRecentTimedOut++;
              if (runDate >= last24h) hostHasTimeout = true;
            }
          }
          if (hostRecentFailed > 0) hostHasFailure = true;
          if (hostRecentTimedOut > 0) hostHasTimeout = true;

          // Icons: ⚠️ if recent failure, ⏳ if recent timeout, 🔄 if retries present
          let hostIcons = "";
          if (hostHasFailure) hostIcons += "⚠️";
          if (hostHasTimeout) hostIcons += "⏳";
          if (hostRetries > 0) hostIcons += "🔄";
          const parts = [];
          if (hostFailed > 0) parts.push(`${hostFailed} failed`);
          if (hostTimedOut > 0) parts.push(`${hostTimedOut} timed out`);
          if (hostCanceled > 0) parts.push(`${hostCanceled} canceled`);
          if (hostRetries > 0) parts.push(`${hostRetries} retries`);
          let breakdown = parts.length > 0 ? parts.join(", ") : "all passed";
          if (hostHasFailure) {
            const breakageInfo = jobBreakages[jobName];
            if (breakageInfo) {
              breakdown += `\nCurrently failing: ${hostRecentFailed}/${hostLastThree.length} recent runs failed ⚡ broke at ${breakageInfo.commit.substring(0, 8)}`;
            } else {
              breakdown += `\nCurrently failing: ${hostRecentFailed}/${hostLastThree.length} recent runs failed`;
            }
          }
          if (hostHasTimeout)
            breakdown += `\nCurrently timing out: ${hostRecentTimedOut}/${hostLastThree.length} recent runs timed-out`;
          hostPrHtml = `<span style="color: ${hostPrColor}" title="${escapeHtml(breakdown + " out of " + hostTotal + " in selected range")}">${hostPct}%${hostIcons ? " " + hostIcons : ""}</span>`;
        }

        const hostRow = document.createElement("tr");
        hostRow.className = "host-row";
        hostRow.dataset.job = jobName;
        hostRow.dataset.agent = agent;
        hostRow.onmouseenter = () => highlightChartDataset(color, agent);
        hostRow.onmouseleave = () => clearChartHighlight();
        const hostTrendResult = formatTrend(hostTrend, hostColor);
        const hostTrendCell = hostTrendResult.trendData
          ? `<td class="trend-cell" data-trend='${hostTrendResult.trendData}'>${hostTrendResult.html}</td>`
          : `<td>${hostTrendResult.html}</td>`;
        const hostComparisonCells = comparisonData
          ? '<td class="comparison-col comparison-col-first"></td><td class="comparison-col"></td><td class="comparison-col"></td>'
          : "";
        hostRow.innerHTML = `
                            <td><span class="color-dot" style="background: ${hostColor}"></span> ${agent}</td>
                            <td></td>
                            <td>${hostPrHtml}</td>
                            ${hostTrendCell}
                            <td class="duration">${formatDuration(hostMedian)}</td>
                            <td class="duration">${formatDuration(hostMin)}</td>
                            <td class="duration">${formatDuration(hostMax)}</td>
                            <td class="duration">±${formatDuration(hostStd)}</td>
                            <td>${hostN}</td>
                            ${hostComparisonCells}
                        `;
        tbody.appendChild(hostRow);
      }
    }
  }

  // Add coverage report rows if coverage jobs are selected
  if (hasSelectedCoverageJob() && data?.coverage) {
    const { min: covRangeMin, max: covRangeMax } = getVisibleTimeRange();

    // Collect coverage data points within time range
    const coverallsData = [];
    const codecovData = [];

    for (const [sha, cov] of Object.entries(data.coverage)) {
      const date = new Date(cov.date);
      if (date < covRangeMin || date > covRangeMax) continue;

      if (cov.coveralls != null) {
        coverallsData.push({ date, value: cov.coveralls });
      }
      if (cov.codecov != null) {
        codecovData.push({ date, value: cov.codecov });
      }
    }

    // Helper to compute coverage stats
    function computeCoverageStats(dataPoints) {
      if (dataPoints.length === 0) return null;
      const values = dataPoints.map((d) => d.value);
      const sorted = [...values].sort((a, b) => a - b);
      const median = sorted[Math.floor(sorted.length / 2)];
      const mean = values.reduce((a, b) => a + b, 0) / values.length;
      const min = Math.min(...values);
      const max = Math.max(...values);
      const variance =
        values.reduce((sum, v) => sum + (v - mean) ** 2, 0) / values.length;
      const std = Math.sqrt(variance);

      // Compute trend
      const sortedByDate = [...dataPoints].sort(
        (a, b) => new Date(a.date) - new Date(b.date),
      );
      const trend =
        sortedByDate.length >= 2
          ? computeTrend(
              sortedByDate.map((d) => ({ date: d.date, duration: d.value })),
            )
          : null;

      return { median, mean, min, max, std, trend, n: values.length };
    }

    // Add separator row before coverage reports
    if (jobStats.length > 0) {
      const sepRow = document.createElement("tr");
      sepRow.className = "separator-row";
      sepRow.innerHTML = '<td colspan="10"></td>';
      tbody.appendChild(sepRow);
    }

    // Add Coveralls row
    const coverallsStats = computeCoverageStats(coverallsData);
    if (coverallsStats) {
      const row = document.createElement("tr");
      row.dataset.job = "Coveralls Coverage";
      row.onmouseenter = () => highlightChartDataset("#3F5EFB", null, "y2");
      row.onmouseleave = () => clearChartHighlight();
      const trendResult = formatTrend(
        coverallsStats.trend,
        "#3F5EFB",
        true,
        "y2",
      );
      const trendCell = trendResult.trendData
        ? `<td class="trend-cell" data-trend='${trendResult.trendData}'>${trendResult.html}</td>`
        : `<td>${trendResult.html}</td>`;
      row.innerHTML = `
                        <td><svg class="coverage-logo" viewBox="0 0 24 24" fill="#3F5EFB"><path d="M0 12v12h24V0H0v12zm13.195-6.187l1.167 3.515 2.255.005c1.238.005 2.916.019 3.727.037l1.472.028-2.968 2.152c-1.632 1.181-2.976 2.18-2.99 2.212-.01.033.488 1.627 1.106 3.54.619 1.917 1.12 3.496 1.116 3.51-.005.019-1.343-.943-2.972-2.137l-2.963-2.161-2.972 2.161c-1.634 1.19-2.976 2.152-2.981 2.137-.005-.014.497-1.593 1.115-3.51.619-1.913 1.116-3.507 1.107-3.54-.014-.032-1.358-1.031-2.99-2.212L2.184 9.398l1.472-.028c.81-.018 2.488-.032 3.727-.037l2.254-.005 1.168-3.515a512.9 512.9 0 011.195-3.53c.005 0 .544 1.587 1.195 3.53z"/></svg>Coveralls</td>
                        <td><span class="text-muted">—</span></td>
                        <td><span class="text-muted">—</span></td>
                        ${trendCell}
                        <td>${coverallsStats.median.toFixed(2)}%</td>
                        <td>${coverallsStats.min.toFixed(2)}%</td>
                        <td>${coverallsStats.max.toFixed(2)}%</td>
                        <td>±${coverallsStats.std.toFixed(2)}%</td>
                        <td>${coverallsStats.n}</td>
                    `;
      tbody.appendChild(row);
    }

    // Add Codecov row
    const codecovStats = computeCoverageStats(codecovData);
    if (codecovStats) {
      const row = document.createElement("tr");
      row.dataset.job = "Codecov Coverage";
      row.onmouseenter = () => highlightChartDataset("#F01F7A", null, "y2");
      row.onmouseleave = () => clearChartHighlight();
      const trendResult = formatTrend(
        codecovStats.trend,
        "#F01F7A",
        true,
        "y2",
      );
      const trendCell = trendResult.trendData
        ? `<td class="trend-cell" data-trend='${trendResult.trendData}'>${trendResult.html}</td>`
        : `<td>${trendResult.html}</td>`;
      row.innerHTML = `
                        <td><svg class="coverage-logo" viewBox="0 0 24 24" fill="#F01F7A"><path d="M12.006.066c-6.63 0-12 5.37-12 12 0 6.631 5.37 12 12 12 6.631 0 12-5.369 12-12 0-6.63-5.369-12-12-12zm0 2.115a9.885 9.885 0 11-.002 19.77 9.885 9.885 0 01.002-19.77zm-.072 2.418a7.471 7.471 0 00-2.26.39L8.148 9.564a4.318 4.318 0 114.312 4.312l.002-.001a4.268 4.268 0 01-1.915-.467l-1.56 4.568a7.473 7.473 0 109.086-9.82 7.514 7.514 0 00-6.14-3.557z"/></svg>Codecov</td>
                        <td><span class="text-muted">—</span></td>
                        <td><span class="text-muted">—</span></td>
                        ${trendCell}
                        <td>${codecovStats.median.toFixed(2)}%</td>
                        <td>${codecovStats.min.toFixed(2)}%</td>
                        <td>${codecovStats.max.toFixed(2)}%</td>
                        <td>±${codecovStats.std.toFixed(2)}%</td>
                        <td>${codecovStats.n}</td>
                    `;
      tbody.appendChild(row);
    }
  }

  updateSortIndicators();
}

function toggleJobExpand(jobName) {
  if (expandedJobs.has(jobName)) {
    expandedJobs.delete(jobName);
  } else {
    expandedJobs.add(jobName);
  }
  updateStatsTable();
  updateURL();
}

function updateSortIndicators() {
  const headers = document.querySelectorAll(".stats-bar th.sortable");
  headers.forEach((th) => {
    const col = th.dataset.sort;
    const indicator = th.querySelector(".sort-indicator");
    if (col === statsTableSortColumn) {
      th.classList.add("sorted");
      indicator.textContent = statsTableSortAsc ? "▲" : "▼";
    } else {
      th.classList.remove("sorted");
      indicator.textContent = "▲";
    }
  });
}

function handleStatsTableSort(column) {
  if (statsTableSortColumn === column) {
    statsTableSortAsc = !statsTableSortAsc;
  } else {
    statsTableSortColumn = column;
    statsTableSortAsc = column === "job"; // Job defaults to ascending, others to descending
  }
  updateStatsTable();
}

function toggleJobItem(item, jobName) {
  if (selectedJobs.has(jobName)) {
    selectedJobs.delete(jobName);
    item.classList.remove("selected");
  } else {
    selectedJobs.add(jobName);
    item.classList.add("selected");
  }
  refreshAllUI();
  updateURL();
}

function updateToolbarButtons() {
  const total = Object.keys(data.jobs).length;
  const selected = selectedJobs.size;
  document
    .getElementById("btn-all")
    .classList.toggle("primary", selected === total);
  document
    .getElementById("btn-none")
    .classList.toggle("primary", selected === 0);
}

function selectAllJobs() {
  for (const name of Object.keys(data.jobs)) {
    selectedJobs.add(name);
  }
  syncJobListUI();
  refreshAllUI();
  updateURL();
}

function deselectAllJobs() {
  selectedJobs.clear();
  syncJobListUI();
  refreshAllUI();
  updateURL();
}

// Matrix organization
const platformOrder = ["linux", "macos", "windows", "freebsd"];
const typeOrder = ["build", "test", "coverage"];
const platformLabels = {
  linux: `<img src="${BUILDKITE_EMOJI_BASE}/linux.png" class="bk-emoji"> Linux`,
  macos: `<img src="${BUILDKITE_EMOJI_BASE}/mac.png" class="bk-emoji"> macOS`,
  windows: `<img src="${BUILDKITE_EMOJI_BASE}/windows.png" class="bk-emoji"> Windows`,
  freebsd: `<img src="${BUILDKITE_EMOJI_BASE}/freebsd.png" class="bk-emoji"> FreeBSD`,
};
const typeLabels = {
  build: "Build",
  test: "Test",
  coverage: "Coverage",
};
const specialGroups = [
  "upload",
  "juliasyntax",
  "juliac",
  "docs",
  "special",
  "pipeline",
  "upload-results",
  "other",
];
const specialLabels = {
  upload: "📤 Upload",
  juliasyntax: "📝 JuliaSyntax",
  juliac: "🛠️ JuliaC",
  docs: "📚 Docs",
  special: "🔬 Special",
  pipeline: "⚙️ Pipeline",
  "upload-results": "📤 Results",
  other: "📦 Other",
};

// Job matrix data: matrix[platform][type] = [jobs]
let jobMatrix = {};
let specialJobGroups = {};

function buildJobMatrix() {
  jobMatrix = {};
  specialJobGroups = {};

  for (const platform of platformOrder) {
    jobMatrix[platform] = {};
    for (const type of typeOrder) {
      jobMatrix[platform][type] = [];
    }
  }
  for (const group of specialGroups) {
    specialJobGroups[group] = [];
  }

  for (const [name, job] of Object.entries(data.jobs)) {
    const { group, type } = classifyJob(name);
    if (platformOrder.includes(group) && typeOrder.includes(type)) {
      jobMatrix[group][type].push({ name, job });
    } else if (specialGroups.includes(group)) {
      specialJobGroups[group].push({ name, job });
    } else {
      specialJobGroups["other"].push({ name, job });
    }
  }
}

function populateJobSelector() {
  buildJobMatrix();
  buildJobIndex();

  // Assign colors
  const allJobs = Object.keys(data.jobs);
  const colors = generateColors(allJobs.length);
  allJobs.forEach((name, i) => {
    jobColors[name] = colors[i];
  });

  // Calculate pass rates and breakages for all jobs
  calculateAllPassRates();
  calculateAllBreakages();

  // Build matrix table
  renderMatrixTable();
}

function renderMatrixTable() {
  const matrixContainer = document.getElementById("job-matrix");
  let html = '<table class="matrix-table">';

  // Header row
  html +=
    '<tr><th class="matrix-corner clickable" onclick="selectAllMatrix()" title="Select all matrix jobs">All</th>';
  for (const type of typeOrder) {
    html += `<th class="clickable" onclick="selectByType('${type}')">${typeLabels[type]}</th>`;
  }
  html += "</tr>";

  // Platform rows
  for (const platform of platformOrder) {
    html += `<tr><th class="row-header clickable" onclick="selectByPlatform('${platform}')">${platformLabels[platform]}</th>`;
    for (const type of typeOrder) {
      const jobs = jobMatrix[platform][type];
      const count = jobs.length;
      // Check if any job in this cell has recent failures/timeouts/breakages
      let failureTooltips = [];
      let timeoutTooltips = [];
      let breakageTooltips = [];
      let hasFailure = false;
      let hasTimeout = false;
      let hasBreakage = false;

      for (const { name } of jobs) {
        const job = data.jobs[name];
        if (job) {
          const issueInfo = hasRecentFailure(job);
          if (issueInfo.hasFailure) {
            const breakageInfo = jobBreakages[name];
            if (breakageInfo) {
              failureTooltips.push(
                `${name}: ${issueInfo.failedCount}/${issueInfo.totalCount} ⚡ broke at ${breakageInfo.commit.substring(0, 8)}`,
              );
            } else {
              failureTooltips.push(
                `${name}: ${issueInfo.failedCount}/${issueInfo.totalCount}`,
              );
            }
            hasFailure = true;
          }
          if (issueInfo.hasTimeout) {
            timeoutTooltips.push(
              `${name}: ${issueInfo.timedOutCount}/${issueInfo.totalCount}`,
            );
            hasTimeout = true;
          }
          if (issueInfo.hasBreakage) {
            breakageTooltips.push(name);
            hasBreakage = true;
          }
        }
      }

      html += `<td class="matrix-cell" data-platform="${platform}" data-type="${type}" onclick="toggleMatrixCell('${platform}', '${type}')">`;
      if (count > 0) {
        html += `<span class="job-count">${count}</span>`;
        if (hasBreakage) {
          const tooltip = `Breakage detected:\n${breakageTooltips.join("\n")}`;
          html += `<span class="failure-indicator breakage-indicator" title="${escapeHtml(tooltip)}">⚡</span>`;
        }
        if (hasFailure) {
          const tooltip = `Currently failing:\n${failureTooltips.join("\n")}`;
          html += `<span class="failure-indicator" title="${escapeHtml(tooltip)}">⚠️</span>`;
        }
        if (hasTimeout) {
          const tooltip = `Currently timing out:\n${timeoutTooltips.join("\n")}`;
          html += `<span class="failure-indicator" title="${escapeHtml(tooltip)}">⏳</span>`;
        }
      } else {
        html += "-";
      }
      html += "</td>";
    }
    html += "</tr>";
  }

  // Special groups row
  html +=
    '<tr><th class="row-header clickable special-header" colspan="4" onclick="selectAllSpecial()" title="Toggle all special jobs">Special</th></tr>';
  html += '<tr><td colspan="4" class="special-buttons-cell">';
  html += '<div class="special-buttons">';
  for (const group of specialGroups) {
    const jobs = specialJobGroups[group];
    if (jobs.length > 0) {
      let failureTooltips = [];
      let timeoutTooltips = [];
      let breakageTooltips = [];
      let hasFailure = false;
      let hasTimeout = false;
      let hasBreakage = false;

      for (const { name } of jobs) {
        const job = data.jobs[name];
        if (job) {
          const issueInfo = hasRecentFailure(job);
          if (issueInfo.hasFailure) {
            const breakageInfo = jobBreakages[name];
            if (breakageInfo) {
              failureTooltips.push(
                `${name}: ${issueInfo.failedCount}/${issueInfo.totalCount} ⚡ broke at ${breakageInfo.commit.substring(0, 8)}`,
              );
            } else {
              failureTooltips.push(
                `${name}: ${issueInfo.failedCount}/${issueInfo.totalCount}`,
              );
            }
            hasFailure = true;
          }
          if (issueInfo.hasTimeout) {
            timeoutTooltips.push(
              `${name}: ${issueInfo.timedOutCount}/${issueInfo.totalCount}`,
            );
            hasTimeout = true;
          }
          if (issueInfo.hasBreakage) {
            breakageTooltips.push(name);
            hasBreakage = true;
          }
        }
      }

      let warnIcons = "";
      if (hasBreakage) warnIcons += " ⚡";
      if (hasFailure) warnIcons += " ⚠️";
      if (hasTimeout) warnIcons += " ⏳";

      const jobList = jobs.map(({ name }) => convertEmojiText(name)).join("\n");
      let tooltip = jobList;
      if (hasBreakage) {
        tooltip += "\n\nBreakage detected:\n" + breakageTooltips.join("\n");
      }
      if (hasFailure) {
        tooltip += "\n\nCurrently failing:\n" + failureTooltips.join("\n");
      }
      if (hasTimeout) {
        tooltip += "\n\nCurrently timing out:\n" + timeoutTooltips.join("\n");
      }
      html += `<button class="btn btn-special" data-special="${group}" onclick="toggleSpecialGroup('${group}')" title="${escapeHtml(tooltip)}">${specialLabels[group]} (${jobs.length})${warnIcons}</button>`;
    }
  }
  html += "</div></td></tr>";

  html += "</table>";
  matrixContainer.innerHTML = html;

  // Build job list
  const listContainer = document.getElementById("job-list");
  listContainer.innerHTML = "";

  // Apply URL params (selection and time range) or localStorage or default
  const hasURLSelection = applyURLParams();

  // Check if we're in comparison mode (takes priority over localStorage)
  const hasComparisonMode = new URLSearchParams(window.location.search).has(
    "c",
  );

  // Always restore stats panel height from localStorage (independent of URL params)
  const storedConfig = loadFromLocalStorage();
  if (
    storedConfig &&
    storedConfig.statsHeight &&
    storedConfig.statsHeight >= 50
  ) {
    document.getElementById("stats-wrapper").style.height =
      storedConfig.statsHeight + "px";
  }

  if (!hasURLSelection && !hasComparisonMode) {
    // Try localStorage for other settings
    if (storedConfig) {
      // Apply stored time range
      if (
        storedConfig.timeRange !== undefined &&
        [0, 7, 14, 30, 60, 90, 120, 240, 365].includes(storedConfig.timeRange)
      ) {
        timeRangeDays = storedConfig.timeRange;
        document.getElementById("time-range").value = storedConfig.timeRange;
      }
      // Apply stored line type
      if (
        storedConfig.lineType &&
        ["raw", "7", "30", "90"].includes(storedConfig.lineType)
      ) {
        lineType = storedConfig.lineType;
        document.getElementById("line-type").value = storedConfig.lineType;
      }
      // Apply stored selection
      const sel = decodeSelection(storedConfig.selection);
      if (
        sel &&
        (sel.matrix.length > 0 ||
          sel.special.length > 0 ||
          sel.indices.length > 0)
      ) {
        for (const { platform, type } of sel.matrix) {
          const jobs = jobMatrix[platform]?.[type] || [];
          for (const { name } of jobs) selectedJobs.add(name);
        }
        for (const group of sel.special) {
          const jobs = specialJobGroups[group] || [];
          for (const { name } of jobs) selectedJobs.add(name);
        }
        for (const idx of sel.indices) {
          if (jobNameList[idx]) selectedJobs.add(jobNameList[idx]);
        }
      }
    }
    // If still nothing selected, select all platform jobs by default
    if (selectedJobs.size === 0) {
      for (const platform of platformOrder) {
        for (const type of typeOrder) {
          for (const { name } of jobMatrix[platform]?.[type] || []) {
            selectedJobs.add(name);
          }
        }
      }
    }
  }

  const getLatestDuration = (job) => job.recent?.[0]?.duration ?? 0;

  // Separate jobs into groups: with current issues and without
  const allJobs = Object.entries(data.jobs).map(([name, job]) => {
    const issueInfo = hasRecentFailure(job);
    const hasIssues = issueInfo.hasFailure || issueInfo.hasTimeout;
    return { name, job, issueInfo, hasIssues };
  });

  const jobsWithIssues = allJobs
    .filter((j) => j.hasIssues)
    .sort((a, b) => getLatestDuration(b.job) - getLatestDuration(a.job));

  const jobsWithoutIssues = allJobs
    .filter((j) => !j.hasIssues)
    .sort((a, b) => getLatestDuration(b.job) - getLatestDuration(a.job));

  // Render jobs with issues first (if any)
  if (jobsWithIssues.length > 0) {
    const groupHeader = document.createElement("div");
    groupHeader.className = "job-group-header";
    groupHeader.textContent = `Current Issues (${jobsWithIssues.length})`;
    listContainer.appendChild(groupHeader);

    for (const { name, job, issueInfo } of jobsWithIssues) {
      const color = jobColors[name];
      const pr = jobPassRates[name];
      const item = document.createElement("div");
      item.className = "job-item" + (selectedJobs.has(name) ? " selected" : "");
      item.dataset.job = name;
      item.onclick = () => toggleJobItem(item, name);
      let passRateHtml = "";
      if (pr && pr.total >= PASS_RATE_MIN_RUNS) {
        const pct = Math.round(pr.rate * 100);
        // Color: green=100%, yellow>=90%, red<90%
        let rateClass = "green";
        if (pr.rate < 1)
          rateClass = pr.rate >= PASS_RATE_THRESHOLD ? "yellow" : "red";
        // Icons: ⚠️ if recent failure, ⏳ if recent timeout
        let icons = "";
        if (issueInfo.hasFailure) icons += "⚠️";
        if (issueInfo.hasTimeout) icons += "⏳";
        const parts = [];
        if (pr.failed > 0) parts.push(`${pr.failed} failed`);
        if (pr.timedOut > 0) parts.push(`${pr.timedOut} timed out`);
        if (pr.canceled > 0) parts.push(`${pr.canceled} canceled`);
        let tooltip =
          parts.length > 0
            ? `${parts.join(", ")} in last ${PASS_RATE_DAYS} days`
            : `${pr.passed}/${pr.total} passed in last ${PASS_RATE_DAYS} days`;
        if (issueInfo.hasFailure) {
          const breakageInfo = jobBreakages[name];
          if (breakageInfo) {
            tooltip += `\n${issueInfo.tooltipFailure} ⚡ broke at ${breakageInfo.commit.substring(0, 8)}`;
          } else {
            tooltip += `\n${issueInfo.tooltipFailure}`;
          }
        }
        if (issueInfo.hasTimeout) {
          tooltip += `\n${issueInfo.tooltipTimeout}`;
        }
        passRateHtml = `<span class="pass-rate ${rateClass}" title="${escapeHtml(tooltip)}">${pct}%${icons ? " " + icons : ""}</span>`;
      }
      const latestDuration = getLatestDuration(job);
      item.innerHTML = `
                        <span class="color-dot" style="background: ${color}"></span>
                        <span class="job-name">${convertEmoji(name)}</span>
                        ${passRateHtml}
                        <span class="job-median" title="Latest run">${formatDuration(latestDuration)}</span>
                    `;
      listContainer.appendChild(item);
    }
  }

  // Render jobs without issues
  if (jobsWithoutIssues.length > 0) {
    const groupHeader = document.createElement("div");
    groupHeader.className = "job-group-header";
    groupHeader.textContent = `All Jobs (${jobsWithoutIssues.length})`;
    listContainer.appendChild(groupHeader);

    for (const { name, job, issueInfo } of jobsWithoutIssues) {
      const color = jobColors[name];
      const pr = jobPassRates[name];
      const item = document.createElement("div");
      item.className = "job-item" + (selectedJobs.has(name) ? " selected" : "");
      item.dataset.job = name;
      item.onclick = () => toggleJobItem(item, name);
      let passRateHtml = "";
      if (pr && pr.total >= PASS_RATE_MIN_RUNS) {
        const pct = Math.round(pr.rate * 100);
        // Color: green=100%, yellow>=90%, red<90%
        let rateClass = "green";
        if (pr.rate < 1)
          rateClass = pr.rate >= PASS_RATE_THRESHOLD ? "yellow" : "red";
        // Icons: ⚠️ if recent failure, ⏳ if recent timeout
        let icons = "";
        if (issueInfo.hasFailure) icons += "⚠️";
        if (issueInfo.hasTimeout) icons += "⏳";
        const parts = [];
        if (pr.failed > 0) parts.push(`${pr.failed} failed`);
        if (pr.timedOut > 0) parts.push(`${pr.timedOut} timed out`);
        if (pr.canceled > 0) parts.push(`${pr.canceled} canceled`);
        let tooltip =
          parts.length > 0
            ? `${parts.join(", ")} in last ${PASS_RATE_DAYS} days`
            : `${pr.passed}/${pr.total} passed in last ${PASS_RATE_DAYS} days`;
        if (issueInfo.hasFailure) {
          const breakageInfo = jobBreakages[name];
          if (breakageInfo) {
            tooltip += `\n${issueInfo.tooltipFailure} ⚡ broke at ${breakageInfo.commit.substring(0, 8)}`;
          } else {
            tooltip += `\n${issueInfo.tooltipFailure}`;
          }
        }
        if (issueInfo.hasTimeout) {
          tooltip += `\n${issueInfo.tooltipTimeout}`;
        }
        passRateHtml = `<span class="pass-rate ${rateClass}" title="${escapeHtml(tooltip)}">${pct}%${icons ? " " + icons : ""}</span>`;
      }
      const latestDuration = getLatestDuration(job);
      item.innerHTML = `
                        <span class="color-dot" style="background: ${color}"></span>
                        <span class="job-name">${convertEmoji(name)}</span>
                        ${passRateHtml}
                        <span class="job-median" title="Latest run">${formatDuration(latestDuration)}</span>
                    `;
      listContainer.appendChild(item);
    }
  }

  // Apply comparison mode from URL params
  applyComparisonParam();

  refreshAllUI();
}

function updateMatrixHighlights() {
  // Update platform/type cells
  for (const platform of platformOrder) {
    for (const type of typeOrder) {
      const cell = document.querySelector(
        `.matrix-cell[data-platform="${platform}"][data-type="${type}"]`,
      );
      if (!cell) continue;
      const jobs = jobMatrix[platform][type];
      const selectedCount = jobs.filter((j) => selectedJobs.has(j.name)).length;
      cell.classList.remove("has-selection", "partial-selection");
      if (selectedCount === jobs.length && jobs.length > 0) {
        cell.classList.add("has-selection");
      } else if (selectedCount > 0) {
        cell.classList.add("partial-selection");
      }
    }
  }

  // Update special group buttons
  for (const group of specialGroups) {
    const btn = document.querySelector(`button[data-special="${group}"]`);
    if (!btn) continue;
    const jobs = specialJobGroups[group];
    const selectedCount = jobs.filter((j) => selectedJobs.has(j.name)).length;
    btn.classList.remove("primary");
    if (selectedCount === jobs.length && jobs.length > 0) {
      btn.classList.add("primary");
    }
  }
}

function updateJobCount() {
  const total = Object.keys(data.jobs).length;
  const countText = `${selectedJobs.size}/${total}`;
  document.getElementById("job-count").textContent = countText;
  const mobileCount = document.getElementById("job-count-mobile");
  if (mobileCount) mobileCount.textContent = countText;
}

// Toggle collapsible section (mobile) with localStorage persistence
function toggleSection(header) {
  header.classList.toggle("collapsed");
  const content = header.nextElementSibling;
  if (content) content.classList.toggle("collapsed");

  // Save state to localStorage
  if (header.id) {
    const collapsed = header.classList.contains("collapsed");
    try {
      localStorage.setItem(`section-${header.id}`, collapsed ? "1" : "0");
    } catch (e) {
      /* ignore */
    }
  }
}

// Restore collapsed section states from localStorage (mobile only)
function restoreSectionStates() {
  const isMobile = window.innerWidth <= 480;
  document.querySelectorAll(".section-header[id]").forEach((header) => {
    const content = header.nextElementSibling;
    if (isMobile) {
      // On mobile, restore saved state
      try {
        const saved = localStorage.getItem(`section-${header.id}`);
        if (saved === "1") {
          header.classList.add("collapsed");
          if (content) content.classList.add("collapsed");
        } else {
          header.classList.remove("collapsed");
          if (content) content.classList.remove("collapsed");
        }
      } catch (e) {
        /* ignore */
      }
    } else {
      // On larger screens, always show sections expanded
      header.classList.remove("collapsed");
      if (content) content.classList.remove("collapsed");
    }
  });
}
restoreSectionStates();

// Re-check section visibility on resize
window.addEventListener("resize", () => {
  if (window.innerWidth > 480) {
    // Ensure sections are expanded on larger screens
    document.querySelectorAll(".section-header[id]").forEach((header) => {
      header.classList.remove("collapsed");
      const content = header.nextElementSibling;
      if (content) content.classList.remove("collapsed");
    });
  }
});

function toggleMatrixCell(platform, type) {
  toggleJobsSelection(jobMatrix[platform][type]);
  syncJobListUI();
  refreshAllUI();
  updateURL();
}

function selectByPlatform(platform) {
  const jobs = [];
  for (const type of typeOrder) {
    jobs.push(...jobMatrix[platform][type]);
  }
  toggleJobsSelection(jobs);
  syncJobListUI();
  refreshAllUI();
  updateURL();
}

function selectAllMatrix() {
  const jobs = [];
  for (const platform of platformOrder) {
    for (const type of typeOrder) {
      jobs.push(...jobMatrix[platform][type]);
    }
  }
  toggleJobsSelection(jobs);
  syncJobListUI();
  refreshAllUI();
  updateURL();
}

function selectAllSpecial() {
  const jobs = [];
  for (const group of specialGroups) {
    jobs.push(...(specialJobGroups[group] || []));
  }
  toggleJobsSelection(jobs);
  syncJobListUI();
  refreshAllUI();
  updateURL();
}

function selectByType(type) {
  const jobs = [];
  for (const platform of platformOrder) {
    jobs.push(...jobMatrix[platform][type]);
  }
  toggleJobsSelection(jobs);
  syncJobListUI();
  refreshAllUI();
  updateURL();
}

function toggleSpecialGroup(group) {
  toggleJobsSelection(specialJobGroups[group]);
  syncJobListUI();
  refreshAllUI();
  updateURL();
}

function syncJobListUI() {
  document.querySelectorAll(".job-item").forEach((el) => {
    el.classList.toggle("selected", selectedJobs.has(el.dataset.job));
  });
}

function timeAgo(dateString) {
  const date = new Date(dateString);
  const now = new Date();
  const seconds = Math.floor((now - date) / 1000);

  if (seconds < 60) return "just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d ago`;
  const weeks = Math.floor(days / 7);
  return `${weeks}w ago`;
}

async function loadData() {
  try {
    // Render empty matrix skeleton immediately
    renderMatrixSkeleton();

    const resp = await fetch("data/timing_summary.json.gz");
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);

    // Stream and parse JSON progressively (decompress gzip on the fly)
    const decompressed = resp.body.pipeThrough(new DecompressionStream("gzip"));
    const reader = decompressed.getReader();
    const decoder = new TextDecoder();
    let jsonText = "";
    let jobCount = 0;
    let uiRendered = false;
    let lastProgressTime = 0;
    const PROGRESS_INTERVAL = 100; // ms between progress updates

    // Initialize data structure
    data = { jobs: {} };

    // Calculate cutoff date for early UI render based on default time range
    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - DEFAULT_TIME_RANGE);
    const cutoffStr = cutoffDate.toISOString().slice(0, 10); // "yyyy-mm-dd"

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      jsonText += decoder.decode(value, { stream: true });

      const now = performance.now();
      if (now - lastProgressTime > PROGRESS_INTERVAL) {
        // Extract generated_at if we haven't yet
        if (!data.generated_at) {
          const match = jsonText.match(/"generated_at":\s*"([^"]+)"/);
          if (match) {
            data.generated_at = match[1];
            const updatedEl = document.getElementById("last-updated");
            updatedEl.textContent = `Updated ${timeAgo(data.generated_at)}`;
            updatedEl.title = data.generated_at;
          }
        }

        // Count jobs to show progress
        const jobMatches = jsonText.match(/":\s*\{\s*"recent"/g);
        const newCount = jobMatches ? jobMatches.length : 0;
        if (newCount > jobCount) {
          jobCount = newCount;
          const bytesLoaded = jsonText.length;
          const mbLoaded = (bytesLoaded / (1024 * 1024)).toFixed(1);
          document.getElementById("chart-loading").innerHTML =
            `<span class="loading">Loading... ${jobCount} jobs (${mbLoaded} MB)</span>`;
        }

        // Try to render UI early once we have enough data for the default time range
        if (!uiRendered && jobCount >= 5) {
          // Check if we have data beyond the cutoff date (older data)
          // The JSON has jobs sorted newest first, so look for dates older than cutoff
          const hasOldEnoughData =
            jsonText.includes(`"date": "${cutoffStr}`) ||
            (jsonText.includes(`"date": "20`) &&
              jsonText.lastIndexOf('"date":') > jsonText.length - 5000);

          // Try a partial parse to see if we can render
          if (hasOldEnoughData || jsonText.length > 500000) {
            const partialData = tryParsePartialJSON(jsonText);
            if (partialData && Object.keys(partialData.jobs).length >= 5) {
              data = partialData;
              populateJobSelector();
              document.getElementById("chart-loading").style.display = "none";
              uiRendered = true;
            }
          }
        }

        lastProgressTime = now;
      }
    }

    // Final parse
    jsonText += decoder.decode();
    data = JSON.parse(jsonText);

    const updatedEl = document.getElementById("last-updated");
    updatedEl.textContent = `Updated ${timeAgo(data.generated_at)}`;
    updatedEl.title = data.generated_at;

    // Check if data is stale (more than 3 days old)
    checkStaleData(data.generated_at);

    if (!uiRendered) {
      populateJobSelector();
      document.getElementById("chart-loading").style.display = "none";
    } else {
      // Update with complete data - rebuild matrix with all jobs
      buildJobMatrix();
      buildJobIndex();

      // Reassign colors for any new jobs from complete data
      const allJobs = Object.keys(data.jobs);
      const colors = generateColors(allJobs.length);
      allJobs.forEach((name, i) => {
        jobColors[name] = colors[i];
      });

      // Recalculate pass rates with complete data and re-render matrix
      calculateAllPassRates();
      calculateAllBreakages();
      renderMatrixTable();

      // Re-apply URL params with complete data to get full selection
      // (partial data may have missed some jobs in matrix cells)
      selectedJobs.clear();
      const hasURLSelection = applyURLParams();

      // Check if we're in comparison mode (takes priority over localStorage)
      const hasComparisonMode = new URLSearchParams(window.location.search).has(
        "c",
      );

      if (!hasURLSelection && !hasComparisonMode) {
        // Try localStorage
        const storedConfig = loadFromLocalStorage();
        if (storedConfig?.selection) {
          const sel = decodeSelection(storedConfig.selection);
          if (sel) {
            for (const { platform, type } of sel.matrix) {
              const jobs = jobMatrix[platform]?.[type] || [];
              for (const { name } of jobs) selectedJobs.add(name);
            }
            for (const group of sel.special) {
              const jobs = specialJobGroups[group] || [];
              for (const { name } of jobs) selectedJobs.add(name);
            }
            for (const idx of sel.indices) {
              if (jobNameList[idx]) selectedJobs.add(jobNameList[idx]);
            }
          }
        }
      }

      // If still nothing selected and not in comparison mode, select all matrix jobs
      if (selectedJobs.size === 0 && !hasComparisonMode) {
        for (const platform of platformOrder) {
          for (const type of typeOrder) {
            for (const { name } of jobMatrix[platform]?.[type] || []) {
              selectedJobs.add(name);
            }
          }
        }
      }

      // Re-apply comparison mode with complete data
      applyComparisonParam();

      refreshAllUI();
    }
  } catch (err) {
    console.error("Failed to load data:", err);
    const retryBtn =
      '<button class="btn btn-retry" onclick="location.reload()">Retry</button>';
    document.getElementById("chart-loading").innerHTML =
      `<span class="error">Failed to load data</span>${retryBtn}`;
    document.getElementById("job-matrix").innerHTML =
      `<div class="error">Failed to load ${retryBtn}</div>`;
    document.getElementById("job-list").innerHTML =
      `<div class="error">Failed to load jobs ${retryBtn}</div>`;
    document.getElementById("stats-tbody").innerHTML = `
                    <tr><td colspan="10" class="error">
                        Failed to load data. Run <code>julia fetch_timing.jl</code> to generate data. ${retryBtn}
                    </td></tr>
                `;
  }
}

// Try to parse partial JSON by closing open structures
function tryParsePartialJSON(jsonText) {
  try {
    // Find the last complete job entry
    // Jobs look like: "jobname": { "recent": [...], "stats": {...} }
    // Find a point where we can safely truncate

    // Look for the pattern where a job's stats section ends
    const statsEndPattern = /"std_seconds":\s*[\d.]+\s*\}\s*\}/g;
    let lastMatch = null;
    let match;
    while ((match = statsEndPattern.exec(jsonText)) !== null) {
      lastMatch = match;
    }

    if (!lastMatch) return null;

    // Truncate at the end of the last complete job and close the JSON
    const truncateAt = lastMatch.index + lastMatch[0].length;
    let partial = jsonText.slice(0, truncateAt);

    // Close any remaining open braces
    partial += "}}"; // Close jobs object and root object

    return JSON.parse(partial);
  } catch (e) {
    return null;
  }
}

// Render empty matrix immediately so users see structure
function renderMatrixSkeleton() {
  const matrixContainer = document.getElementById("job-matrix");
  let html = '<table class="matrix-table">';

  // Header row
  html += '<tr><th class="matrix-corner" title="Loading...">⋯</th>';
  for (const type of typeOrder) {
    html += `<th>${typeLabels[type]}</th>`;
  }
  html += "</tr>";

  // Platform rows with loading placeholders
  for (const platform of platformOrder) {
    html += `<tr><th class="row-header">${platformLabels[platform]}</th>`;
    for (const type of typeOrder) {
      html += `<td class="matrix-cell" data-platform="${platform}" data-type="${type}">⋯</td>`;
    }
    html += "</tr>";
  }

  // Special groups placeholder
  html +=
    '<tr><th class="row-header special-header" colspan="4">Special</th></tr>';
  html +=
    '<tr><td colspan="4" class="loading loading-small">Loading special jobs...</td></tr>';

  html += "</table>";
  matrixContainer.innerHTML = html;
}

/**
 * Check if data is stale (older than 3 days) and show/hide warning banner.
 * @param {string} generatedAt - ISO timestamp string of when data was generated
 */
function checkStaleData(generatedAt) {
  const dataTime = new Date(generatedAt).getTime();
  const now = Date.now();
  const age = now - dataTime;

  const warningBanner = document.getElementById("stale-data-warning");
  if (age > STALE_DATA_THRESHOLD_MS) {
    warningBanner.classList.add("visible");
  } else {
    warningBanner.classList.remove("visible");
  }
}

let refreshController = null;
async function refreshData() {
  // Abort any in-flight refresh so we don't race with ourselves.
  if (refreshController) refreshController.abort();
  refreshController = new AbortController();
  const signal = refreshController.signal;
  try {
    const newData = await loadGzipJson("data/timing_summary.json.gz", {
      signal,
    });
    if (signal.aborted) return;

    // Only update if data actually changed
    if (newData.generated_at !== data.generated_at) {
      data = newData;
      const updatedEl = document.getElementById("last-updated");
      updatedEl.textContent = `Updated ${timeAgo(data.generated_at)}`;
      updatedEl.title = data.generated_at;
      checkStaleData(data.generated_at);
      updateChart();
      updateStatsTable();
    } else {
      // Update the "ago" time even if data hasn't changed
      const updatedEl = document.getElementById("last-updated");
      updatedEl.textContent = `Updated ${timeAgo(data.generated_at)}`;
    }
  } catch (err) {
    // Silently ignore refresh errors (including AbortError)
  }
}

// === Tab Navigation ===
let activeTab = "perf";

const PERF_ORIGIN = "https://tealquaternion.camdvr.org";

// URL params owned by this dashboard. Anything NOT in this set is treated as
// belonging to the embedded julia-perf site and forwarded to/from the iframe
// so deep links like ?start=abc&end=def&stat=instructions Just Work.
// "perf" is a legacy single-param fallback that holds the full iframe path.
const DASHBOARD_PARAMS = new Set([
  "s", // selected jobs
  "t", // time range (days)
  "x", // custom x zoom
  "y", // custom y zoom
  "l", // line type
  "e", // expanded jobs in stats table
  "st", // state filter
  "c", // comparison build pair
  "tab", // active tab
  "bt", // bench time range
  "bs", // bench stat type
  "bv", // bench table view
  "bg", // bench groups
  "pt", // pkgeval time range
  "pp", // pkgeval proportional toggle
  "perf", // legacy: full iframe path
]);

function applyPerfURLParams() {
  const params = new URLSearchParams(window.location.search);
  const iframe = document.getElementById("perf-iframe");

  // Legacy: ?perf=/path?foo=bar wins if present.
  const perfPath = params.get("perf");
  if (perfPath) {
    iframe.src =
      PERF_ORIGIN + (perfPath.startsWith("/") ? perfPath : "/" + perfPath);
    return;
  }

  // Otherwise, forward any non-dashboard params straight through.
  const forwarded = new URLSearchParams();
  for (const [k, v] of params) {
    if (!DASHBOARD_PARAMS.has(k)) forwarded.append(k, v);
  }
  const qs = forwarded.toString();
  if (qs) iframe.src = `${PERF_ORIGIN}/?${qs}`;
}

// Listen for URL updates posted by the embedded julia-perf site so we
// can reflect them in our own address bar.
window.addEventListener("message", (event) => {
  if (event.origin !== PERF_ORIGIN) return;
  const msg = event.data;
  if (!msg || msg.type !== "julia-perf-url") return;
  if (activeTab !== "perf") return;
  const url = new URL(window.location);

  // Legacy single-param mode: only used if the iframe is not at "/".
  // (julia-perf is a SPA at "/" so in practice we always hit the
  // pass-through branch below.)
  const path = msg.pathname || "/";
  if (path !== "/") {
    const perfPath = path + (msg.search || "") + (msg.hash || "");
    url.searchParams.set("perf", perfPath);
    history.replaceState(null, "", url);
    return;
  }

  // Pass-through mode: mirror the iframe's query params on the parent URL,
  // leaving dashboard-owned params untouched.
  url.searchParams.delete("perf");
  const incoming = new URLSearchParams(msg.search || "");
  // Drop existing forwarded params so removed iframe params disappear here too.
  for (const k of Array.from(url.searchParams.keys())) {
    if (!DASHBOARD_PARAMS.has(k)) url.searchParams.delete(k);
  }
  for (const [k, v] of incoming) {
    if (!DASHBOARD_PARAMS.has(k)) url.searchParams.append(k, v);
  }
  history.replaceState(null, "", url);
});

function switchTab(tab) {
  activeTab = tab;
  const tabIds = {
    "ci-timing": "tab-ci-timing",
    benchmarks: "tab-benchmarks",
    pkgeval: "tab-pkgeval",
    perf: "tab-perf",
  };
  for (const [name, id] of Object.entries(tabIds)) {
    const btn = document.getElementById(id);
    const selected = name === tab;
    btn.classList.toggle("active", selected);
    btn.setAttribute("aria-selected", selected ? "true" : "false");
    btn.setAttribute("tabindex", selected ? "0" : "-1");
  }

  document
    .getElementById("ci-timing-view")
    .classList.toggle("view-hidden", tab !== "ci-timing");
  document
    .getElementById("ci-timing-controls")
    .classList.toggle("view-hidden", tab !== "ci-timing");
  // Hide CI-timing-specific banners
  for (const id of ["stale-data-warning", "comparison-banner"]) {
    const el = document.getElementById(id);
    if (el) el.style.display = tab === "ci-timing" ? "" : "none";
  }

  document
    .getElementById("benchmarks-view")
    .classList.toggle("view-hidden", tab !== "benchmarks");
  document
    .getElementById("pkgeval-view")
    .classList.toggle("view-hidden", tab !== "pkgeval");
  document
    .getElementById("perf-view")
    .classList.toggle("view-hidden", tab !== "perf");
  document.body.classList.toggle("tab-perf-active", tab === "perf");

  if (tab === "benchmarks" && !benchData) {
    loadBenchmarkData();
  }
  if (tab === "pkgeval" && !pkgevalData) {
    loadPkgevalData();
  }

  // Update tab in URL
  const url = new URL(window.location);
  if (tab !== "perf") {
    url.searchParams.set("tab", tab);
  } else {
    url.searchParams.delete("tab");
  }
  history.replaceState(null, "", url);
}

// === Benchmarks State ===
let benchData = null;
let benchChart = null;
let benchSelectedGroups = new Set();
let benchTimeRangeDays = 365;
let benchStatType = "minimum";
let benchSortCol = "date";
let benchSortAsc = false;
let benchGroupColors = {};
let benchExpandedGroups = new Set();
let benchGroupDetail = {}; // group => fetched detail data
let benchHiddenBenchmarks = {}; // group => Set of hidden benchmark names
let benchTableView = "runs"; // 'groups' or 'runs'

function updateBenchURL() {
  const url = new URL(window.location);
  // Tab
  url.searchParams.set("tab", activeTab);
  // Benchmark time range (default 365)
  if (benchTimeRangeDays !== 365) {
    url.searchParams.set("bt", benchTimeRangeDays);
  } else {
    url.searchParams.delete("bt");
  }
  // Benchmark stat type (default minimum)
  if (benchStatType !== "minimum") {
    url.searchParams.set("bs", benchStatType);
  } else {
    url.searchParams.delete("bs");
  }
  // Benchmark table view (default runs)
  if (benchTableView !== "runs") {
    url.searchParams.set("bv", benchTableView);
  } else {
    url.searchParams.delete("bv");
  }
  // Benchmark selected groups — encode as deselected groups (shorter when most are selected)
  const allGroups = Object.keys(benchGroupColors).sort();
  const deselected = allGroups.filter((g) => !benchSelectedGroups.has(g));
  if (deselected.length === 0) {
    url.searchParams.delete("bg");
  } else if (deselected.length < allGroups.length / 2) {
    // Encode deselected with leading '-'
    url.searchParams.set(
      "bg",
      "-" + deselected.map(encodeURIComponent).join(","),
    );
  } else {
    // Encode selected
    const selected = allGroups.filter((g) => benchSelectedGroups.has(g));
    url.searchParams.set("bg", selected.map(encodeURIComponent).join(","));
  }
  history.replaceState(null, "", url);
}

function applyBenchURLParams() {
  const params = new URLSearchParams(window.location.search);

  const bt = params.get("bt");
  if (bt !== null) {
    const days = parseInt(bt, 10);
    if (!isNaN(days) && [90, 180, 365, 730, 0].includes(days)) {
      benchTimeRangeDays = days;
      const sel = document.getElementById("bench-time-range");
      if (sel) sel.value = days;
    }
  }

  const bs = params.get("bs");
  if (bs !== null && ["minimum", "mean"].includes(bs)) {
    benchStatType = bs;
    const sel = document.getElementById("bench-stat-type");
    if (sel) sel.value = bs;
  }

  const bv = params.get("bv");
  if (bv === "groups") {
    benchTableView = "groups";
    benchSortCol = "latest";
    benchSortAsc = false;
    document.getElementById("bench-view-runs")?.classList.remove("btn-primary");
    document.getElementById("bench-view-groups")?.classList.add("btn-primary");
  }
}

function applyBenchGroupParams() {
  const params = new URLSearchParams(window.location.search);
  const bg = params.get("bg");
  if (bg === null) return; // no param → keep default (all selected)

  const allGroups = Object.keys(benchGroupColors).sort();
  if (bg.startsWith("-")) {
    // Deselected list
    const deselected = new Set(bg.slice(1).split(",").map(decodeURIComponent));
    benchSelectedGroups = new Set(allGroups.filter((g) => !deselected.has(g)));
  } else {
    // Selected list
    const selected = new Set(bg.split(",").map(decodeURIComponent));
    benchSelectedGroups = new Set(allGroups.filter((g) => selected.has(g)));
  }
}

function setBenchTimeRange(value) {
  benchTimeRangeDays = parseInt(value);
  updateBenchChart();
  updateBenchTable();
  updateBenchURL();
}

function setBenchStatType(value) {
  benchStatType = value;
  populateBenchGroupList(Object.keys(benchGroupColors).sort());
  updateBenchChart();
  updateBenchTable();
  updateBenchURL();
}

function getBenchCutoff() {
  if (benchTimeRangeDays === 0) return null;
  const d = new Date();
  d.setDate(d.getDate() - benchTimeRangeDays);
  return d;
}

function getFilteredReports() {
  if (!benchData?.reports) return [];
  const cutoff = getBenchCutoff();
  return cutoff
    ? benchData.reports.filter((r) => new Date(r.date) >= cutoff)
    : benchData.reports;
}

function benchKey() {
  return benchStatType + "_geomean_ns";
}

function formatTime(ns) {
  if (ns == null || ns === 0) return "—";
  if (ns < 1e3) return ns.toFixed(1) + " ns";
  if (ns < 1e6) return (ns / 1e3).toFixed(1) + " μs";
  if (ns < 1e9) return (ns / 1e6).toFixed(1) + " ms";
  return (ns / 1e9).toFixed(2) + " s";
}

async function loadBenchmarkData() {
  try {
    benchData = await loadGzipJson("data/benchmark_summary.json.gz");

    const updatedEl = document.getElementById("bench-last-updated");
    updatedEl.textContent = `Updated ${timeAgo(benchData.generated_at)}`;
    updatedEl.title = benchData.generated_at;

    document.getElementById("bench-chart-loading").style.display = "none";

    const allGroups = new Set();
    for (const report of benchData.reports) {
      if (report.by_group) {
        for (const g of Object.keys(report.by_group)) allGroups.add(g);
      }
    }

    const groupList = Array.from(allGroups).sort();
    const colors = generateColors(groupList.length);
    groupList.forEach((g, i) => {
      benchGroupColors[g] = colors[i];
    });

    // Select all groups by default
    benchSelectedGroups = new Set(groupList);

    // Apply URL params for group selection (overrides default)
    applyBenchGroupParams();

    populateBenchGroupList(groupList);
    updateBenchChart();
    updateBenchTable();
  } catch (err) {
    console.error("Failed to load benchmark data:", err);
    document.getElementById("bench-chart-loading").innerHTML =
      '<span class="error">Failed to load benchmark data. Run <code>julia fetch_benchmarks.jl</code> to generate data.</span>';
    document.getElementById("bench-group-list").innerHTML =
      '<div class="group-header">Benchmark Groups</div><div class="error" style="padding: 12px;">Failed to load</div>';
    document.getElementById("bench-stats-tbody").innerHTML =
      '<tr><td colspan="6" class="error">Failed to load data</td></tr>';
  }
}

function populateBenchGroupList(groups) {
  const container = document.getElementById("bench-group-list");
  const reports = getFilteredReports();
  const latest = reports.length > 0 ? reports[reports.length - 1] : null;
  const key = benchKey();

  let html =
    '<div class="group-header">Benchmark Groups (' + groups.length + ")</div>";
  for (const group of groups) {
    const isSelected = benchSelectedGroups.has(group);
    const countKey = benchStatType + "_count";
    const testCount = latest?.by_group?.[group]?.[countKey];
    const countLabel = testCount != null ? testCount : "";
    html += `<div class="group-item ${isSelected ? "selected" : ""}" onclick="toggleBenchGroup('${escapeHtml(group)}')" title="${escapeHtml(group)}">`;
    html += `<span class="color-dot" style="background: ${benchGroupColors[group] || "#888"}"></span>`;
    html += `<span>${escapeHtml(group)}</span>`;
    html += `<span class="group-counts"><span class="bench-count">${countLabel}</span></span>`;
    html += `</div>`;
  }
  container.innerHTML = html;
}

function toggleBenchGroup(group) {
  if (benchSelectedGroups.has(group)) {
    benchSelectedGroups.delete(group);
  } else {
    benchSelectedGroups.add(group);
  }
  populateBenchGroupList(Object.keys(benchGroupColors).sort());
  updateBenchChart();
  updateBenchTable();
  updateBenchURL();
}

function selectAllGroups() {
  benchSelectedGroups = new Set(Object.keys(benchGroupColors));
  populateBenchGroupList(Object.keys(benchGroupColors).sort());
  updateBenchChart();
  updateBenchTable();
  updateBenchURL();
}

function deselectAllGroups() {
  benchSelectedGroups.clear();
  populateBenchGroupList(Object.keys(benchGroupColors).sort());
  updateBenchChart();
  updateBenchTable();
  updateBenchURL();
}

async function toggleExpandGroup(group) {
  if (benchExpandedGroups.has(group)) {
    benchExpandedGroups.delete(group);
    updateBenchTable();
    updateBenchChart();
    return;
  }

  benchExpandedGroups.add(group);

  if (!benchGroupDetail[group]) {
    try {
      benchGroupDetail[group] = await loadGzipJson(
        `data/benchmarks/${encodeURIComponent(group)}.json.gz`,
      );
    } catch (err) {
      console.error(`Failed to load detail for ${group}:`, err);
      benchExpandedGroups.delete(group);
      updateBenchTable();
      return;
    }
  }

  updateBenchTable();
  updateBenchChart();
}

function toggleBenchItem(group, name, event) {
  if (!benchHiddenBenchmarks[group]) benchHiddenBenchmarks[group] = new Set();
  const hidden = benchHiddenBenchmarks[group];

  if (event && (event.shiftKey || event.ctrlKey || event.metaKey)) {
    // Solo: hide all others, or restore all if already solo
    const detail = benchGroupDetail[group];
    const statData = detail?.[benchStatType];
    if (statData) {
      const allNames = Object.keys(statData.benchmarks);
      const othersHidden = allNames.every((n) => n === name || hidden.has(n));
      if (othersHidden && !hidden.has(name)) {
        // Already solo — restore all
        hidden.clear();
      } else {
        // Solo this one
        hidden.clear();
        for (const n of allNames) {
          if (n !== name) hidden.add(n);
        }
      }
    }
  } else {
    if (hidden.has(name)) {
      hidden.delete(name);
    } else {
      hidden.add(name);
    }
  }
  updateBenchTable();
  updateBenchChart();
}

let benchHighlightActive = false;

function highlightBenchDataset(label) {
  if (!benchChart) return;
  if (!benchHighlightActive) {
    benchChart.data.datasets.forEach((ds) => {
      ds._origBorderColor = ds.borderColor;
      ds._origBackgroundColor = ds.backgroundColor;
      ds._origBorderWidth = ds.borderWidth;
      ds._origPointRadius = ds.pointRadius;
    });
    benchHighlightActive = true;
  }
  benchChart.data.datasets.forEach((ds) => {
    if (ds.label === label) {
      ds.borderColor = ds._origBorderColor;
      ds.backgroundColor = ds._origBackgroundColor;
      ds.borderWidth = 2.5;
      ds.pointRadius = 3;
    } else {
      ds.borderColor = colorToRgba(ds._origBorderColor, 0.15);
      ds.backgroundColor = colorToRgba(ds._origBackgroundColor, 0.05);
      ds.borderWidth = 1;
      ds.pointRadius = 0;
    }
  });
  benchChart.update();
}

function highlightBenchGroup(group) {
  if (!benchChart) return;
  if (!benchHighlightActive) {
    benchChart.data.datasets.forEach((ds) => {
      ds._origBorderColor = ds.borderColor;
      ds._origBackgroundColor = ds.backgroundColor;
      ds._origBorderWidth = ds.borderWidth;
      ds._origPointRadius = ds.pointRadius;
    });
    benchHighlightActive = true;
  }
  benchChart.data.datasets.forEach((ds) => {
    if (ds.label === group || ds.label.startsWith(group + "/")) {
      ds.borderColor = ds._origBorderColor;
      ds.backgroundColor = ds._origBackgroundColor;
      ds.borderWidth = 2.5;
      ds.pointRadius = 3;
    } else {
      ds.borderColor = colorToRgba(ds._origBorderColor, 0.15);
      ds.backgroundColor = colorToRgba(ds._origBackgroundColor, 0.05);
      ds.borderWidth = 1;
      ds.pointRadius = 0;
    }
  });
  benchChart.update();
}

function clearBenchHighlight() {
  if (!benchChart || !benchHighlightActive) return;
  benchChart.data.datasets.forEach((ds) => {
    if (ds._origBorderColor !== undefined) ds.borderColor = ds._origBorderColor;
    if (ds._origBackgroundColor !== undefined)
      ds.backgroundColor = ds._origBackgroundColor;
    if (ds._origBorderWidth !== undefined) ds.borderWidth = ds._origBorderWidth;
    if (ds._origPointRadius !== undefined) ds.pointRadius = ds._origPointRadius;
  });
  benchHighlightActive = false;
  benchChart.update();
}

function nanosoldierReportUrl(type, dateOrPath) {
  if (typeof dateOrPath === "string" && dateOrPath.includes("/")) {
    // Direct date_path like "2026-04/12"
    return `https://github.com/JuliaCI/NanosoldierReports/blob/master/${type}/by_date/${dateOrPath}/report.md`;
  }
  // Convert date string "2026-04-08" or Date object to path "2026-04/8"
  let yyyy, mm, dd;
  if (typeof dateOrPath === "string") {
    [yyyy, mm, dd] = dateOrPath.split("-");
    dd = String(parseInt(dd, 10)); // strip leading zero
  } else {
    const d = dateOrPath instanceof Date ? dateOrPath : new Date(dateOrPath);
    yyyy = d.getUTCFullYear();
    mm = String(d.getUTCMonth() + 1).padStart(2, "0");
    dd = String(d.getUTCDate());
  }
  return `https://github.com/JuliaCI/NanosoldierReports/blob/master/${type}/by_date/${yyyy}-${mm}/${dd}/report.md`;
}

function updateBenchChart() {
  const reports = getFilteredReports();
  if (reports.length === 0) {
    if (benchChart) benchChart.destroy();
    benchChart = null;
    return;
  }

  const isDark = isDarkMode();
  const gridColor = isDark ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.1)";
  const textColor = isDark ? "#8b949e" : "#656d76";
  const key = benchKey();
  const statLabel = benchStatType === "minimum" ? "Min" : "Mean";
  const multiGroup = benchSelectedGroups.size > 1;

  const datasets = [];
  const cutoff = getBenchCutoff();

  // Expanded groups that have detail data loaded
  const expandedWithDetail = [...benchSelectedGroups].filter(
    (g) => benchExpandedGroups.has(g) && benchGroupDetail[g],
  );

  // Count total series for % deviation mode
  // All selected groups get a geomean line; expanded ones also get individual lines
  let totalSeries = benchSelectedGroups.size;
  for (const group of expandedWithDetail) {
    const statData = benchGroupDetail[group]?.[benchStatType];
    if (statData) totalSeries += Object.keys(statData.benchmarks).length;
  }
  const multiSeries = totalSeries > 1;

  // Always show geomean for all selected groups
  for (const group of benchSelectedGroups) {
    const color = benchGroupColors[group];
    const rawPoints = reports
      .filter((r) => r.by_group?.[group]?.[key] != null)
      .map((r) => ({
        x: new Date(r.date),
        y: r.by_group[group][key],
        commit: r.commit,
        date_path: r.date_path,
      }));

    if (rawPoints.length === 0) continue;

    let data;
    if (multiSeries) {
      const baseline = rawPoints[0].y;
      data = rawPoints.map((p) => ({
        ...p,
        yRaw: p.y,
        y: baseline > 0 ? ((p.y - baseline) / baseline) * 100 : 0,
      }));
    } else {
      data = rawPoints.map((p) => ({ ...p, yRaw: p.y }));
    }

    datasets.push({
      label: group,
      data,
      borderColor: color,
      backgroundColor: color + "22",
      borderWidth: 1.5,
      pointRadius: 2,
      pointHoverRadius: 5,
      fill: false,
      tension: 0.1,
    });
  }

  // Additionally plot individual benchmarks for expanded groups
  if (expandedWithDetail.length > 0) {
    let colorIdx = 0;
    const detailColors = generateColors(Math.max(totalSeries, 10));
    // Offset past geomean colors
    colorIdx = benchSelectedGroups.size;
    for (const group of expandedWithDetail) {
      const detail = benchGroupDetail[group];
      const statData = detail?.[benchStatType];
      if (!statData) continue;

      const benchNames = Object.keys(statData.benchmarks).sort();
      const hiddenSet = benchHiddenBenchmarks[group] || new Set();
      for (const name of benchNames) {
        if (hiddenSet.has(name)) {
          colorIdx++;
          continue;
        }
        const series = statData.benchmarks[name];
        if (!series) continue;
        const color = detailColors[colorIdx++ % detailColors.length];

        const rawPoints = [];
        for (let i = 0; i < statData.dates.length; i++) {
          if (series[i] == null) continue;
          const d = new Date(statData.dates[i]);
          if (cutoff && d < cutoff) continue;
          rawPoints.push({
            x: d,
            y: series[i],
            commit: statData.commits[i] || "",
            date_path: statData.date_paths?.[i] || "",
            yRaw: series[i],
          });
        }
        if (rawPoints.length === 0) continue;

        let data;
        if (multiSeries) {
          const baseline = rawPoints[0].y;
          data = rawPoints.map((p) => ({
            ...p,
            yRaw: p.y,
            y: baseline > 0 ? ((p.y - baseline) / baseline) * 100 : 0,
          }));
        } else {
          data = rawPoints;
        }

        datasets.push({
          label: `${group}/${name}`,
          data,
          borderColor: color,
          backgroundColor: color + "22",
          borderWidth: 1.5,
          pointRadius: 2,
          pointHoverRadius: 5,
          fill: false,
          tension: 0.1,
        });
      }
    }
  }

  const yAxis = {
    type: "linear",
    grid: { color: gridColor },
    ticks: { color: textColor },
  };

  if (multiSeries) {
    yAxis.title = {
      display: true,
      text: `% Change from Start`,
      color: textColor,
    };
    yAxis.ticks.callback = function (value) {
      return (value >= 0 ? "+" : "") + value.toFixed(0) + "%";
    };
  } else {
    const yLabel =
      expandedWithDetail.length > 0
        ? `${statLabel} Time`
        : `${statLabel} Geomean Time`;
    yAxis.title = { display: true, text: yLabel, color: textColor };
    yAxis.ticks.callback = function (value) {
      return formatTime(value);
    };
  }

  const chartConfig = {
    type: "line",
    data: { datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      transitions: {
        active: { animation: { duration: 0 } },
      },
      animation: {
        y: { duration: 0 },
      },
      interaction: {
        mode: "nearest",
        intersect: false,
      },
      scales: {
        x: {
          type: "time",
          time: {
            unit: "week",
            displayFormats: { week: "MMM d", month: "MMM yyyy" },
          },
          grid: { color: gridColor },
          ticks: { color: textColor, maxRotation: 0 },
        },
        y: yAxis,
      },
      plugins: {
        legend: {
          display: false,
        },
        tooltip: {
          callbacks: {
            title: (items) => {
              if (!items.length) return "";
              const d = items[0].raw.x;
              return d instanceof Date ? d.toLocaleDateString() : d;
            },
            afterTitle: (items) => {
              if (!items.length) return "";
              return items[0].raw.commit
                ? `Commit: ${items[0].raw.commit}`
                : "";
            },
            label: (item) => {
              const raw = item.raw;
              const abs = formatTime(raw.yRaw);
              if (multiSeries) {
                const sign = raw.y >= 0 ? "+" : "";
                return `${item.dataset.label}: ${sign}${raw.y.toFixed(1)}% (${abs})`;
              }
              return `${item.dataset.label}: ${abs}`;
            },
          },
        },
        zoom: {
          pan: { enabled: true, mode: "x" },
          zoom: {
            wheel: { enabled: true },
            pinch: { enabled: true },
            mode: "x",
            onZoomComplete: () => {
              document.getElementById("bench-btn-reset-zoom").style.display =
                "";
            },
          },
        },
      },
      onClick: (evt, elements) => {
        if (elements.length > 0) {
          const raw = elements[0].element.$context.raw;
          if (raw) {
            window.open(
              nanosoldierReportUrl("benchmark", raw.date_path || raw.x),
              "_blank",
            );
          }
        }
      },
      onHover: (evt, elements) => {
        evt.native.target.style.cursor = elements.length > 0 ? "pointer" : "";
      },
    },
  };

  if (benchChart) {
    benchChart.data = chartConfig.data;
    benchChart.options = chartConfig.options;
    benchChart.update();
  } else {
    const ctx = document.getElementById("benchmarks-chart").getContext("2d");
    benchChart = new Chart(ctx, chartConfig);
  }
}

function sortBenchTable(col) {
  if (benchSortCol === col) {
    benchSortAsc = !benchSortAsc;
  } else {
    benchSortCol = col;
    if (benchTableView === "runs") {
      // Date and commit ascend by default for text; date we want newest first → desc
      benchSortAsc = col === "commit";
    } else {
      benchSortAsc = col === "group";
    }
  }
  updateBenchTable();
}

function setBenchTableView(view) {
  if (view !== "groups" && view !== "runs") return;
  if (view === benchTableView) return;
  benchTableView = view;
  document
    .getElementById("bench-view-groups")
    .classList.toggle("btn-primary", view === "groups");
  document
    .getElementById("bench-view-runs")
    .classList.toggle("btn-primary", view === "runs");
  // Reset sort to sensible default for the new view
  if (view === "runs") {
    benchSortCol = "date";
    benchSortAsc = false;
  } else {
    benchSortCol = "latest";
    benchSortAsc = false;
  }
  updateBenchTable();
  updateBenchURL();
}

function updateBenchTable() {
  if (benchTableView === "runs") {
    renderBenchRunsTable();
  } else {
    renderBenchGroupsTable();
  }
}

function formatBenchDelta(d) {
  if (d == null) return "—";
  const pct = d * 100;
  const sign = d > 0 ? "+" : "";
  const text = `${sign}${pct.toFixed(2)}%`;
  const cls =
    Math.abs(d) < 0.005 ? "" : d > 0 ? "bench-delta-pos" : "bench-delta-neg";
  return cls ? `<span class="${cls}">${text}</span>` : text;
}

function renderBenchRunsTable() {
  const reports = getFilteredReports();
  const thead = document.getElementById("bench-stats-thead");
  const tbody = document.getElementById("bench-stats-tbody");

  const arrow = (col) =>
    benchSortCol === col ? (benchSortAsc ? " ▲" : " ▼") : "";
  thead.innerHTML = `<tr>
                <th onclick="sortBenchTable('date')">Report date${arrow("date")}</th>
                <th onclick="sortBenchTable('commit')">Commit${arrow("commit")}</th>
                <th onclick="sortBenchTable('baseline')" title="Baseline date the Nanosoldier report compared against">Baseline${arrow("baseline")}</th>
                <th class="bench-time-header" onclick="sortBenchTable('geomeanMin')">Geomean (min)${arrow("geomeanMin")}</th>
                <th class="bench-delta-header" onclick="sortBenchTable('deltaMin')" title="Min geomean change vs previous run in selected range">Δ${arrow("deltaMin")}</th>
                <th class="bench-time-header" onclick="sortBenchTable('geomeanMean')">Geomean (mean)${arrow("geomeanMean")}</th>
                <th class="bench-delta-header" onclick="sortBenchTable('deltaMean')" title="Mean geomean change vs previous run in selected range">Δ${arrow("deltaMean")}</th>
                <th onclick="sortBenchTable('improved')" title="Improvements reported by Nanosoldier">Improved${arrow("improved")}</th>
                <th onclick="sortBenchTable('regressed')" title="Regressions reported by Nanosoldier">Regressed${arrow("regressed")}</th>
            </tr>`;

  if (reports.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9">No data in selected range</td></tr>';
    return;
  }

  const selected = benchSelectedGroups;
  const minKey = "minimum_geomean_ns";
  const meanKey = "mean_geomean_ns";

  const geomeanOf = (vals) => {
    if (vals.length === 0) return null;
    const sumLog = vals.reduce((a, v) => a + Math.log(v), 0);
    return Math.exp(sumLog / vals.length);
  };

  const computeGeomeans = (key) =>
    reports.map((r) => {
      const vals = [];
      if (r.by_group) {
        for (const g of selected) {
          const v = r.by_group[g]?.[key];
          if (v != null && v > 0) vals.push(v);
        }
      }
      return geomeanOf(vals);
    });
  const minGms = computeGeomeans(minKey);
  const meanGms = computeGeomeans(meanKey);

  const rows = reports.map((r, i) => {
    const gmMin = minGms[i];
    const prevMin = i > 0 ? minGms[i - 1] : null;
    const deltaMin =
      gmMin != null && prevMin != null && prevMin > 0
        ? gmMin / prevMin - 1
        : null;
    const gmMean = meanGms[i];
    const prevMean = i > 0 ? meanGms[i - 1] : null;
    const deltaMean =
      gmMean != null && prevMean != null && prevMean > 0
        ? gmMean / prevMean - 1
        : null;
    return {
      date: r.date || "",
      date_path: r.date_path || "",
      commit: r.commit || "",
      baseline: r.report_baseline_date || "",
      geomeanMin: gmMin,
      deltaMin,
      geomeanMean: gmMean,
      deltaMean,
      improved: r.report_improvements ?? null,
      regressed: r.report_regressions ?? null,
    };
  });

  rows.sort((a, b) => {
    const va = a[benchSortCol];
    const vb = b[benchSortCol];
    if (va == null && vb == null) return 0;
    if (va == null) return 1;
    if (vb == null) return -1;
    const cmp = typeof va === "string" ? va.localeCompare(vb) : va - vb;
    return benchSortAsc ? cmp : -cmp;
  });

  const fmtCount = (n, cls) =>
    n == null ? "—" : n > 0 ? `<span class="${cls}">${n}</span>` : "0";

  let html = "";
  for (const row of rows) {
    const reportUrl = row.date_path
      ? `https://github.com/JuliaCI/NanosoldierReports/blob/master/benchmark/by_date/${row.date_path.split("/").map(encodeURIComponent).join("/")}/report.md`
      : null;
    const dateDisplay = reportUrl
      ? `<a class="bench-runs-link" href="${reportUrl}" target="_blank" rel="noopener">${escapeHtml(row.date)}</a>`
      : escapeHtml(row.date);
    const commitDisplay = row.commit
      ? `<a class="bench-runs-link" href="https://github.com/JuliaLang/julia/commit/${encodeURIComponent(row.commit)}" target="_blank" rel="noopener">${escapeHtml(row.commit.slice(0, 8))}</a>`
      : "—";
    const baselineDisplay = row.baseline ? escapeHtml(row.baseline) : "—";
    html += `<tr>`;
    html += `<td>${dateDisplay}</td>`;
    html += `<td>${commitDisplay}</td>`;
    html += `<td>${baselineDisplay}</td>`;
    html += `<td class="bench-time">${formatTime(row.geomeanMin)}</td>`;
    html += `<td class="bench-delta">${formatBenchDelta(row.deltaMin)}</td>`;
    html += `<td class="bench-time">${formatTime(row.geomeanMean)}</td>`;
    html += `<td class="bench-delta">${formatBenchDelta(row.deltaMean)}</td>`;
    html += `<td>${fmtCount(row.improved, "bench-runs-improved")}</td>`;
    html += `<td>${fmtCount(row.regressed, "bench-runs-regressed")}</td>`;
    html += `</tr>`;
  }
  tbody.innerHTML = html || '<tr><td colspan="9">No runs</td></tr>';
}

function renderBenchGroupsTable() {
  const reports = getFilteredReports();
  const thead = document.getElementById("bench-stats-thead");
  const tbody = document.getElementById("bench-stats-tbody");

  const arrow = (col) =>
    benchSortCol === col ? (benchSortAsc ? " ▲" : " ▼") : "";
  thead.innerHTML = `<tr>
                <th onclick="sortBenchTable('group')">Group${arrow("group")}</th>
                <th class="bench-time-header" onclick="sortBenchTable('latest')">Latest${arrow("latest")}</th>
                <th class="bench-time-header" onclick="sortBenchTable('avg')">Average${arrow("avg")}</th>
                <th class="bench-time-header" onclick="sortBenchTable('min')">Min${arrow("min")}</th>
                <th class="bench-time-header" onclick="sortBenchTable('max')">Max${arrow("max")}</th>
                <th onclick="sortBenchTable('count')">Benchmarks${arrow("count")}</th>
            </tr>`;

  if (reports.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6">No data in selected range</td></tr>';
    return;
  }

  const key = benchKey();
  const countKey = benchStatType + "_count";
  const groupStats = {};
  const allGroups = new Set();

  for (const report of reports) {
    if (!report.by_group) continue;
    for (const [group, gdata] of Object.entries(report.by_group)) {
      allGroups.add(group);
      const val = gdata[key];
      if (val == null || val === 0) continue;
      if (!groupStats[group]) {
        groupStats[group] = { values: [], count: gdata[countKey] || 0 };
      }
      groupStats[group].values.push(val);
      groupStats[group].count = Math.max(
        groupStats[group].count,
        gdata[countKey] || 0,
      );
    }
  }

  const latest = reports[reports.length - 1];

  let rows = Array.from(allGroups).map((group) => {
    const s = groupStats[group] || { values: [], count: 0 };
    const latestVal = latest?.by_group?.[group]?.[key] || 0;
    const avg =
      s.values.length > 0
        ? s.values.reduce((a, b) => a + b, 0) / s.values.length
        : 0;
    const min = s.values.length > 0 ? Math.min(...s.values) : 0;
    const max = s.values.length > 0 ? Math.max(...s.values) : 0;
    return { group, latest: latestVal, avg, min, max, count: s.count };
  });

  rows.sort((a, b) => {
    const va = a[benchSortCol] ?? a.group;
    const vb = b[benchSortCol] ?? b.group;
    const cmp = typeof va === "string" ? va.localeCompare(vb) : va - vb;
    return benchSortAsc ? cmp : -cmp;
  });

  let html = "";
  for (const row of rows) {
    if (!benchSelectedGroups.has(row.group)) continue;
    const isExpanded = benchExpandedGroups.has(row.group);
    const expandClass = isExpanded ? "expandable expanded" : "expandable";
    html += `<tr class="${expandClass}" data-bench-group="${escapeHtml(row.group)}" onclick="toggleExpandGroup('${escapeHtml(row.group)}')">`;
    html += `<td><span class="color-dot" style="background: ${benchGroupColors[row.group] || "#888"}"></span> ${escapeHtml(row.group)}</td>`;
    html += `<td class="bench-time">${formatTime(row.latest)}</td>`;
    html += `<td class="bench-time">${formatTime(row.avg)}</td>`;
    html += `<td class="bench-time">${formatTime(row.min)}</td>`;
    html += `<td class="bench-time">${formatTime(row.max)}</td>`;
    html += `<td>${row.count}</td>`;
    html += `</tr>`;

    // Show individual benchmarks when expanded
    if (isExpanded && benchGroupDetail[row.group]) {
      const detail = benchGroupDetail[row.group];
      const statData = detail[benchStatType];
      if (statData) {
        const cutoff = getBenchCutoff();
        const benchNames = Object.keys(statData.benchmarks).sort();
        for (const name of benchNames) {
          const vals = statData.benchmarks[name];
          // Compute stats for filtered date range
          const filtered = [];
          let latestBenchVal = null;
          for (let i = 0; i < statData.dates.length; i++) {
            if (vals[i] == null) continue;
            const d = new Date(statData.dates[i]);
            if (cutoff && d < cutoff) continue;
            filtered.push(vals[i]);
          }
          latestBenchVal =
            filtered.length > 0 ? filtered[filtered.length - 1] : null;
          const benchAvg =
            filtered.length > 0
              ? filtered.reduce((a, b) => a + b, 0) / filtered.length
              : 0;
          const benchMin = filtered.length > 0 ? Math.min(...filtered) : 0;
          const benchMax = filtered.length > 0 ? Math.max(...filtered) : 0;

          const isHidden = (benchHiddenBenchmarks[row.group] || new Set()).has(
            name,
          );
          const detailClass = isHidden
            ? "bench-detail-row bench-hidden"
            : "bench-detail-row";
          html += `<tr class="${detailClass}" data-bench-label="${escapeHtml(row.group + "/" + name)}" data-bench-group-name="${escapeHtml(row.group)}" data-bench-item-name="${escapeHtml(name)}" style="cursor: pointer;" title="${escapeHtml(name)}">`;
          html += `<td>${escapeHtml(name)}</td>`;
          html += `<td class="bench-time">${formatTime(latestBenchVal)}</td>`;
          html += `<td class="bench-time">${formatTime(benchAvg)}</td>`;
          html += `<td class="bench-time">${formatTime(benchMin)}</td>`;
          html += `<td class="bench-time">${formatTime(benchMax)}</td>`;
          html += `<td></td>`;
          html += `</tr>`;
        }
      }
    }
  }

  tbody.innerHTML = html;

  // Attach hover highlight listeners
  tbody.querySelectorAll("tr[data-bench-group]").forEach((tr) => {
    const group = tr.dataset.benchGroup;
    tr.onmouseenter = () => highlightBenchGroup(group);
    tr.onmouseleave = () => clearBenchHighlight();
  });
  tbody.querySelectorAll("tr[data-bench-label]").forEach((tr) => {
    const label = tr.dataset.benchLabel;
    const group = tr.dataset.benchGroupName;
    const item = tr.dataset.benchItemName;
    tr.onclick = (e) => toggleBenchItem(group, item, e);
    tr.onmouseenter = () => highlightBenchDataset(label);
    tr.onmouseleave = () => clearBenchHighlight();
  });
}

// === PkgEval State ===
let pkgevalData = null;
let pkgevalChart = null;
let pkgevalTimeRangeDays = 0;
let pkgevalProportional = false;

function togglePkgevalProportional() {
  pkgevalProportional = !pkgevalProportional;
  document.getElementById("pkgeval-btn-proportional").textContent =
    pkgevalProportional ? "Show counts" : "Show %";
  updatePkgevalChart();
  updatePkgevalURL();
}

function setPkgevalTimeRange(val) {
  pkgevalTimeRangeDays = parseInt(val);
  updatePkgevalChart();
  updatePkgevalTable();
  updatePkgevalURL();
}

function updatePkgevalURL() {
  const url = new URL(window.location);
  url.searchParams.set("tab", activeTab);
  if (pkgevalTimeRangeDays !== 0) {
    url.searchParams.set("pt", pkgevalTimeRangeDays);
  } else {
    url.searchParams.delete("pt");
  }
  if (pkgevalProportional) {
    url.searchParams.set("pp", "1");
  } else {
    url.searchParams.delete("pp");
  }
  history.replaceState(null, "", url);
}

function applyPkgevalURLParams() {
  const params = new URLSearchParams(window.location.search);
  const pt = params.get("pt");
  if (pt !== null) {
    const days = parseInt(pt, 10);
    if (!isNaN(days) && [90, 180, 365, 730, 0].includes(days)) {
      pkgevalTimeRangeDays = days;
      const sel = document.getElementById("pkgeval-time-range");
      if (sel) sel.value = days;
    }
  }
  if (params.get("pp") === "1") {
    pkgevalProportional = true;
    document.getElementById("pkgeval-btn-proportional").textContent =
      "Show counts";
  }
}

function getPkgevalFilteredReports() {
  if (!pkgevalData) return [];
  const reports = (pkgevalData.reports || []).filter((r) => r.date);
  if (pkgevalTimeRangeDays === 0) return reports;
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - pkgevalTimeRangeDays);
  return reports.filter((r) => new Date(r.date) >= cutoff);
}

async function loadPkgevalData() {
  try {
    pkgevalData = await loadGzipJson("data/pkgeval_summary.json.gz");

    const updatedEl = document.getElementById("pkgeval-last-updated");
    updatedEl.textContent = `Updated ${timeAgo(pkgevalData.generated_at)}`;
    updatedEl.title = pkgevalData.generated_at;

    document.getElementById("pkgeval-chart-loading").style.display = "none";
    updatePkgevalChart();
    updatePkgevalTable();
  } catch (err) {
    console.error("Failed to load pkgeval data:", err);
    document.getElementById("pkgeval-chart-loading").innerHTML =
      '<span class="error">Failed to load pkgeval data. Run <code>julia fetch_pkgeval.jl</code> to generate data.</span>';
    document.getElementById("pkgeval-stats-tbody").innerHTML =
      '<tr><td colspan="8" class="error">Failed to load data</td></tr>';
  }
}

function updatePkgevalChart() {
  const reports = getPkgevalFilteredReports();
  if (!reports.length) return;

  const isDark = isDarkMode();
  const gridColor = isDark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.06)";
  const textColor = isDark ? "#8b949e" : "#656d76";

  const dates = reports.map((r) => r.date);
  const toData = (key) =>
    reports.map((r) => {
      const v = r[key] || 0;
      if (!pkgevalProportional || !r.total) return v;
      return (v / r.total) * 100;
    });
  const okData = toData("ok");
  const failData = toData("fail");
  const crashData = toData("crash");
  const skipData = toData("skip");
  const killData = toData("kill");

  const datasets = [
    {
      label: "OK",
      data: okData,
      borderColor: "#3fb950",
      backgroundColor: "rgba(63,185,80,0.15)",
      fill: true,
      order: 5,
    },
    {
      label: "Fail",
      data: failData,
      borderColor: "#f85149",
      backgroundColor: "rgba(248,81,73,0.15)",
      fill: true,
      order: 4,
    },
    {
      label: "Crash",
      data: crashData,
      borderColor: "#db6d28",
      backgroundColor: "rgba(219,109,40,0.15)",
      fill: true,
      order: 3,
    },
    {
      label: "Skip",
      data: skipData,
      borderColor: "#8b949e",
      backgroundColor: "rgba(139,148,158,0.15)",
      fill: true,
      order: 2,
    },
    {
      label: "Kill",
      data: killData,
      borderColor: "#d29922",
      backgroundColor: "rgba(210,153,34,0.15)",
      fill: true,
      order: 1,
    },
  ];

  // Hide series with all zeros
  const visibleDatasets = datasets.filter((ds) => ds.data.some((v) => v > 0));

  const config = {
    type: "line",
    data: {
      labels: dates,
      datasets: visibleDatasets.map((ds) => ({
        ...ds,
        borderWidth: pkgevalProportional ? 0 : 1.5,
        pointRadius: 0,
        pointHitRadius: 8,
        tension: 0.1,
        backgroundColor: pkgevalProportional
          ? ds.borderColor + "cc"
          : ds.backgroundColor,
      })),
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: "index", intersect: false },
      plugins: {
        legend: {
          display: true,
          labels: {
            color: textColor,
            usePointStyle: true,
            pointStyle: "circle",
            boxWidth: 10,
            boxHeight: 10,
            padding: 16,
          },
        },
        tooltip: {
          usePointStyle: true,
          boxPadding: 4,
          callbacks: {
            title: (items) => {
              if (!items.length) return "";
              const idx = items[0].dataIndex;
              const r = reports[idx];
              return `${r.date}${r.version ? " (" + r.version + ")" : ""}`;
            },
            label: (item) => {
              const idx = item.dataIndex;
              const r = reports[idx];
              const key = item.dataset.label.toLowerCase();
              const raw = r[key] || r[key === "ok" ? "ok" : key] || 0;
              const pct =
                r.total > 0 ? ((raw / r.total) * 100).toFixed(1) : "0.0";
              return ` ${item.dataset.label}: ${raw.toLocaleString()} (${pct}%)`;
            },
            afterBody: (items) => {
              if (!items.length) return "";
              const idx = items[0].dataIndex;
              const r = reports[idx];
              return `Total: ${(r.total || 0).toLocaleString()}`;
            },
          },
        },
        zoom: {
          pan: { enabled: true, mode: "x" },
          zoom: {
            wheel: { enabled: true },
            pinch: { enabled: true },
            drag: {
              enabled: true,
              backgroundColor: isDark
                ? "rgba(56,139,253,0.15)"
                : "rgba(31,111,235,0.1)",
            },
            mode: "x",
            onZoom: () => {
              document.getElementById("pkgeval-btn-reset-zoom").style.display =
                "";
            },
          },
        },
      },
      onClick: (evt, elements) => {
        if (elements.length > 0) {
          const idx = elements[0].index;
          const r = reports[idx];
          if (r) {
            window.open(
              nanosoldierReportUrl("pkgeval", r.date_path || r.date),
              "_blank",
            );
          }
        }
      },
      onHover: (evt, elements) => {
        evt.native.target.style.cursor = elements.length > 0 ? "pointer" : "";
        highlightPkgevalRow(
          elements.length > 0 ? reports[elements[0].index]?.date : null,
        );
      },
      scales: {
        x: {
          type: "time",
          time: { unit: "month", tooltipFormat: "yyyy-MM-dd" },
          grid: { color: gridColor },
          ticks: { color: textColor, maxRotation: 0, autoSkip: true },
        },
        y: {
          stacked: true,
          grid: { color: gridColor },
          ticks: {
            color: textColor,
            callback: pkgevalProportional
              ? (v) => v.toFixed(0) + "%"
              : undefined,
          },
          title: {
            display: true,
            text: pkgevalProportional ? "Percentage" : "Packages",
            color: textColor,
          },
          max: pkgevalProportional ? 100 : undefined,
        },
      },
    },
  };

  const canvas = document.getElementById("pkgeval-chart");
  if (pkgevalChart) {
    pkgevalChart.destroy();
  }
  pkgevalChart = new Chart(canvas, config);
}

function highlightPkgevalRow(date) {
  const tbody = document.getElementById("pkgeval-stats-tbody");
  const prev = tbody.querySelector("tr.highlight");
  if (prev) prev.classList.remove("highlight");
  if (!date) return;
  const row = tbody.querySelector(`tr[data-date="${CSS.escape(date)}"]`);
  if (row) {
    row.classList.add("highlight");
    const container = tbody.closest(".pkgeval-stats");
    if (container) {
      const headerHeight = container.querySelector("thead")?.offsetHeight || 0;
      const rowRect = row.getBoundingClientRect();
      const containerRect = container.getBoundingClientRect();
      const visibleTop = containerRect.top + headerHeight;
      if (rowRect.top < visibleTop || rowRect.bottom > containerRect.bottom) {
        const rowTop = row.offsetTop - headerHeight;
        container.scrollTo({ top: rowTop - 4, behavior: "smooth" });
      }
    }
  }
}

function updatePkgevalTable() {
  const reports = getPkgevalFilteredReports();
  const tbody = document.getElementById("pkgeval-stats-tbody");
  if (!reports.length) {
    tbody.innerHTML = '<tr><td colspan="8">No data</td></tr>';
    return;
  }
  // Show most recent first
  const recent = reports.slice().reverse();
  let html = "";
  for (const r of recent) {
    const url = nanosoldierReportUrl("pkgeval", r.date_path || r.date);
    const t = r.total || 0;
    const pct = (v) => (t > 0 ? ((v / t) * 100).toFixed(1) : "0.0");
    html += `<tr data-date="${escapeHtml(r.date)}" onclick="window.open('${url}', '_blank', 'noopener')">`;
    html += `<td>${escapeHtml(r.date)}</td>`;
    html += `<td>${escapeHtml(r.version || "")}</td>`;
    html += `<td class="num">${t.toLocaleString()}</td>`;
    html += `<td class="num pe-ok">${(r.ok || 0).toLocaleString()} <small>(${pct(r.ok || 0)}%)</small></td>`;
    html += `<td class="num pe-fail">${(r.fail || 0).toLocaleString()} <small>(${pct(r.fail || 0)}%)</small></td>`;
    html += `<td class="num pe-crash">${(r.crash || 0).toLocaleString()} <small>(${pct(r.crash || 0)}%)</small></td>`;
    html += `<td class="num pe-skip">${(r.skip || 0).toLocaleString()} <small>(${pct(r.skip || 0)}%)</small></td>`;
    html += `<td class="num pe-kill">${(r.kill || 0).toLocaleString()} <small>(${pct(r.kill || 0)}%)</small></td>`;
    html += "</tr>";
  }
  tbody.innerHTML = html;
}

loadData();

// Apply benchmark URL params before potential tab switch
applyBenchURLParams();
applyPkgevalURLParams();
applyPerfURLParams();

// Switch to correct tab if URL says so
const urlTab = new URLSearchParams(window.location.search).get("tab");
if (urlTab === "ci-timing" || urlTab === "benchmarks" || urlTab === "pkgeval") {
  switchTab(urlTab);
} else {
  // Default tab is 'perf' — ensure it initializes (loads iframe, etc.)
  switchTab("perf");
}

// Auto-refresh data periodically — but only when the page is visible.
setInterval(() => {
  if (document.visibilityState === "visible") refreshData();
}, DATA_REFRESH_INTERVAL);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") refreshData();
});

// WAI-ARIA tablist keyboard navigation: Left/Right/Home/End move focus and
// activate the tab (manual activation would be safer but our tabs are
// expensive-to-render "pages" rather than panels, and existing UX is click-
// to-switch).
document.querySelector(".tab-nav").addEventListener("keydown", (e) => {
  const tabs = Array.from(document.querySelectorAll(".tab-nav [role='tab']"));
  const i = tabs.indexOf(document.activeElement);
  if (i < 0) return;
  let next = -1;
  if (e.key === "ArrowRight") next = (i + 1) % tabs.length;
  else if (e.key === "ArrowLeft") next = (i - 1 + tabs.length) % tabs.length;
  else if (e.key === "Home") next = 0;
  else if (e.key === "End") next = tabs.length - 1;
  else return;
  e.preventDefault();
  tabs[next].focus();
  tabs[next].click();
});

// Update "ago" time periodically
setInterval(() => {
  if (data?.generated_at) {
    const updatedEl = document.getElementById("last-updated");
    updatedEl.textContent = `Updated ${timeAgo(data.generated_at)}`;
  }
}, AGO_UPDATE_INTERVAL);

// Re-render chart when color scheme changes
window
  .matchMedia("(prefers-color-scheme: dark)")
  .addEventListener("change", () => {
    if (currentTheme() === "system") applyTheme();
    if (selectedJobs.size > 0) updateChart();
    if (benchChart) updateBenchChart();
    if (pkgevalChart) updatePkgevalChart();
  });

function currentTheme() {
  try {
    return localStorage.getItem("theme") || "system";
  } catch (e) {
    return "system";
  }
}
function isDarkMode() {
  const t = currentTheme();
  if (t === "dark") return true;
  if (t === "light") return false;
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}
function applyTheme() {
  const t = currentTheme();
  const root = document.documentElement;
  if (t === "dark" || t === "light") {
    root.setAttribute("data-theme", t);
  } else {
    root.removeAttribute("data-theme");
  }
  const btn = document.getElementById("theme-toggle");
  if (btn) {
    const icons = { system: "◑", dark: "☾", light: "☀" };
    btn.textContent = icons[t] || icons.system;
    btn.title = `Theme: ${t}`;
  }
  // Forward theme to the embedded julia-perf iframe so it stays in sync.
  // Resolve "system" to the actual dark/light value: the iframe's own
  // prefers-color-scheme can differ from the parent's (different sandbox
  // context, etc.), and we want the iframe to match what the parent shows.
  const iframe = document.getElementById("perf-iframe");
  if (iframe && iframe.contentWindow) {
    try {
      iframe.contentWindow.postMessage(
        { type: "set-theme", theme: isDarkMode() ? "dark" : "light" },
        PERF_ORIGIN,
      );
    } catch (e) {}
  }
  if (selectedJobs.size > 0) updateChart();
  if (benchChart) updateBenchChart();
  if (pkgevalChart) updatePkgevalChart();
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
applyTheme();
