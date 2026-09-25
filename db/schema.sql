-- Schema for the julia-ci-timing database. Source of truth for the tables
-- described in docs/database-migration.md; Store.jl applies it on open.
--
-- Conventions
--   * Instants are ISO 8601 UTC TEXT with a trailing Z, at the source's
--     precision (seconds, or minutes for legacy timing/TTFX rows, stored as
--     :00Z). Columns named *_at. Days (YYYY-MM-DD) are named date.
--   * Durations are REAL seconds (*_s); benchmark times are REAL nanoseconds
--     (*_ns): BenchmarkTools estimates are Float64 and the legacy data has
--     fractional values.
--   * Every fact table carries change_seq, a monotonic integer taken from
--     meta.change_seq. Store.transaction advances it only when a commit
--     changed a row (and records it per source under change_seq:<source>),
--     so "change_seq > N" is a reliable incremental cursor and the API's
--     ETags hold still across runs that fetched nothing new.
--   * Legacy rows imported from the committed data/ files leave upstream
--     identifiers (job UUIDs, full SHAs, timestamps) NULL rather than
--     fabricating them.

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT OR IGNORE INTO meta VALUES ('schema_version', '1');
INSERT OR IGNORE INTO meta VALUES ('change_seq', '0');

-- One row per fetcher invocation; the freshness signal for /healthz and alerts.
CREATE TABLE IF NOT EXISTS source_runs (
    id           INTEGER PRIMARY KEY,
    source       TEXT NOT NULL,
    started_at   TEXT NOT NULL,
    finished_at  TEXT,
    ok           INTEGER,
    rows_written INTEGER,
    error        TEXT
);
CREATE INDEX IF NOT EXISTS source_runs_source ON source_runs (source, started_at);

-- Optional enrichment from a clone of JuliaLang/julia. pr_number is parsed from
-- the subject's trailing "(#NNNN)" and may be NULL.
CREATE TABLE IF NOT EXISTS commits (
    sha          TEXT PRIMARY KEY CHECK (length(sha) = 40),
    author       TEXT,
    authored_at  TEXT,
    committed_at TEXT,
    subject      TEXT,
    pr_number    INTEGER
);

-- ---------------------------------------------------------------- timing --

CREATE TABLE IF NOT EXISTS builds (
    id            INTEGER PRIMARY KEY,
    pipeline      TEXT NOT NULL,
    number        INTEGER NOT NULL,
    commit_prefix TEXT NOT NULL,            -- 8 chars, what the legacy data has
    commit_sha    TEXT,                     -- 40 chars once fetched from the API
    branch        TEXT,
    state         TEXT,
    source        TEXT,                     -- webhook | schedule | api | ui
    blocked       INTEGER,
    pull_request  INTEGER,
    author        TEXT NOT NULL DEFAULT '',
    message       TEXT NOT NULL DEFAULT '', -- first line, <= 80 chars, as today
    created_at    TEXT NOT NULL,
    scheduled_at  TEXT,
    started_at    TEXT,
    finished_at   TEXT,
    web_url       TEXT,
    change_seq    INTEGER NOT NULL,
    UNIQUE (pipeline, number)
);
CREATE INDEX IF NOT EXISTS builds_created ON builds (created_at);
CREATE INDEX IF NOT EXISTS builds_commit ON builds (commit_prefix);
CREATE INDEX IF NOT EXISTS builds_seq ON builds (change_seq);

-- Buildkite step names carry emoji and drift; classify once at ingest.
CREATE TABLE IF NOT EXISTS job_kinds (
    id      INTEGER PRIMARY KEY,
    name    TEXT NOT NULL UNIQUE,
    kind    TEXT,                            -- build | test | coverage | docs | upload | pipeline | special
    os      TEXT,
    triplet TEXT,
    flags   TEXT                             -- comma separated: assert, rr, gcoff, profiling, ...
);

CREATE TABLE IF NOT EXISTS jobs (
    id                   INTEGER PRIMARY KEY,
    build_id             INTEGER NOT NULL REFERENCES builds (id),
    name                 TEXT NOT NULL,
    retry                INTEGER NOT NULL DEFAULT 0, -- legacy per-name ordinal within the build
    job_uuid             TEXT UNIQUE,                -- NULL on imported rows
    step_key             TEXT,
    kind_id              INTEGER REFERENCES job_kinds (id),
    agent_hostname       TEXT NOT NULL DEFAULT '',
    agent_name           TEXT,
    queue                TEXT,
    state                TEXT NOT NULL,
    exit_status          INTEGER,
    soft_failed          INTEGER,
    retried              INTEGER,
    retries_count        INTEGER,
    retry_type           TEXT,
    parallel_group_index INTEGER,
    duration_s           REAL NOT NULL,              -- finished - started; the only timing legacy rows have
    created_at           TEXT,
    scheduled_at         TEXT,
    runnable_at          TEXT,
    started_at           TEXT,
    finished_at          TEXT,
    web_url              TEXT,
    change_seq           INTEGER NOT NULL,
    UNIQUE (build_id, name, retry)
);
CREATE INDEX IF NOT EXISTS jobs_name ON jobs (name, build_id);
CREATE INDEX IF NOT EXISTS jobs_seq ON jobs (change_seq);

-- Buildkite only retains a window of builds, so keep what it said.
CREATE TABLE IF NOT EXISTS raw_builds (
    pipeline   TEXT NOT NULL,
    number     INTEGER NOT NULL,
    fetched_at TEXT NOT NULL,
    json_zst   BLOB NOT NULL,
    PRIMARY KEY (pipeline, number)
);

-- Provider timestamps are kept verbatim: the two providers format them
-- differently and the legacy export copies them through.
CREATE TABLE IF NOT EXISTS coverage (
    commit_sha  TEXT PRIMARY KEY,
    measured_at TEXT,
    codecov     REAL,
    coveralls   REAL,
    change_seq  INTEGER NOT NULL
);

-- ------------------------------------------------------------ benchmarks --

-- path is the directory under NanosoldierReports/benchmark, e.g. by_date/2026-09/13.
-- Daily reports are one per day; by_hash PR reports can share a day, hence
-- path rather than date is the identity.
CREATE TABLE IF NOT EXISTS bench_reports (
    id                     INTEGER PRIMARY KEY,
    path                   TEXT NOT NULL UNIQUE,
    kind                   TEXT NOT NULL DEFAULT 'daily',
    date                   TEXT NOT NULL,
    commit_sha             TEXT NOT NULL DEFAULT '',
    baseline_commit_sha    TEXT,
    baseline_date          TEXT,
    julia_version          TEXT,
    llvm                   TEXT,
    cpu                    TEXT,
    os                     TEXT,
    benchmarktools_version TEXT,
    nanosoldier_commit     TEXT,
    report_total           INTEGER,
    report_regressions     INTEGER,
    report_improvements    INTEGER,
    change_seq             INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS bench_reports_date ON bench_reports (kind, date);

CREATE TABLE IF NOT EXISTS bench_names (
    id   INTEGER PRIMARY KEY,
    grp  TEXT NOT NULL,
    name TEXT NOT NULL,
    UNIQUE (grp, name)
);

-- One row per (report, benchmark, statistic); only benchmarks that ran.
CREATE TABLE IF NOT EXISTS bench_results (
    report_id    INTEGER NOT NULL REFERENCES bench_reports (id),
    bench_id     INTEGER NOT NULL REFERENCES bench_names (id),
    stat         TEXT NOT NULL,              -- minimum | median | mean | std
    time_ns      REAL,
    gctime_ns    REAL,
    memory_bytes INTEGER,
    allocs       INTEGER,
    PRIMARY KEY (report_id, bench_id, stat)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS bench_results_bench ON bench_results (bench_id, stat, report_id);

-- Nanosoldier's own comparison against the baseline, from report.md.
CREATE TABLE IF NOT EXISTS bench_verdicts (
    report_id        INTEGER NOT NULL REFERENCES bench_reports (id),
    bench_id         INTEGER NOT NULL REFERENCES bench_names (id),
    time_ratio       REAL,
    time_tolerance   REAL,
    memory_ratio     REAL,
    memory_tolerance REAL,
    verdict          TEXT,                   -- regression | improvement | invariant
    PRIMARY KEY (report_id, bench_id)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS bench_errors (
    report_id INTEGER NOT NULL REFERENCES bench_reports (id),
    bench_id  INTEGER NOT NULL REFERENCES bench_names (id),
    error     TEXT,
    PRIMARY KEY (report_id, bench_id)
) WITHOUT ROWID;

-- Presence and summary per (report, group, statistic). A row means the
-- statistic's detail data was read for that group on that report; the
-- geomean/count are what benchmark_summary.json carries per group. The
-- other estimates get their own geomean over the benchmarks with a
-- positive value (added by Store's column migrations; NULL until a report
-- is parsed from its tarball).
CREATE TABLE IF NOT EXISTS bench_report_groups (
    report_id            INTEGER NOT NULL REFERENCES bench_reports (id),
    grp                  TEXT NOT NULL,
    stat                 TEXT NOT NULL,
    geomean_ns           REAL NOT NULL,
    count                INTEGER NOT NULL,
    gctime_geomean_ns    REAL,
    gctime_count         INTEGER,
    memory_geomean_bytes REAL,
    memory_count         INTEGER,
    allocs_geomean       REAL,
    allocs_count         INTEGER,
    PRIMARY KEY (report_id, grp, stat)
) WITHOUT ROWID;

-- --------------------------------------------------------------- pkgeval --

CREATE TABLE IF NOT EXISTS pkgeval_reports (
    id            INTEGER PRIMARY KEY,
    path          TEXT NOT NULL UNIQUE,     -- by_date/2026-09/09
    kind          TEXT NOT NULL DEFAULT 'daily',
    date          TEXT NOT NULL,            -- db.json's own date field
    commit_sha    TEXT NOT NULL DEFAULT '', -- 8 chars in legacy rows
    julia_version TEXT NOT NULL DEFAULT '',
    total         INTEGER NOT NULL,
    ok            INTEGER NOT NULL,
    fail          INTEGER NOT NULL,
    crash         INTEGER NOT NULL,
    skip          INTEGER NOT NULL,
    kill          INTEGER NOT NULL,
    change_seq    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS pkgeval_reports_date ON pkgeval_reports (kind, date);

CREATE TABLE IF NOT EXISTS pkgeval_reasons (
    report_id INTEGER NOT NULL REFERENCES pkgeval_reports (id),
    status    TEXT NOT NULL,
    reason    TEXT NOT NULL DEFAULT '',
    count     INTEGER NOT NULL,
    PRIMARY KEY (report_id, status, reason)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS packages (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS pkgeval_results (
    report_id  INTEGER NOT NULL REFERENCES pkgeval_reports (id),
    package_id INTEGER NOT NULL REFERENCES packages (id),
    version    TEXT,
    status     TEXT NOT NULL,
    reason     TEXT,
    duration_s REAL,
    PRIMARY KEY (report_id, package_id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS pkgeval_results_pkg ON pkgeval_results (package_id, report_id);

-- ------------------------------------------------------------------ ttfx --

CREATE TABLE IF NOT EXISTS ttfx_jobs (
    job_uuid         TEXT PRIMARY KEY,
    pipeline         TEXT NOT NULL DEFAULT 'julia-ci',
    build            INTEGER NOT NULL,
    triplet          TEXT NOT NULL,
    state            TEXT NOT NULL,
    build_created_at TEXT NOT NULL,          -- legacy "date", minute precision
    commit_sha       TEXT NOT NULL DEFAULT '',
    version          TEXT NOT NULL DEFAULT '',
    message          TEXT NOT NULL DEFAULT '',
    agent            TEXT NOT NULL DEFAULT '',
    cpu              TEXT NOT NULL DEFAULT '',
    snippets         TEXT NOT NULL DEFAULT '',
    blocks           INTEGER,
    n_tasks          INTEGER,
    n_metrics        INTEGER NOT NULL,       -- length of the legacy metric arrays; < 7 means "re-fetch me"
    selected_arm     TEXT,
    started_at       TEXT,
    finished_at      TEXT,
    web_url          TEXT,
    has_samples      INTEGER NOT NULL DEFAULT 0,
    change_seq       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ttfx_jobs_build ON ttfx_jobs (build_created_at, build);

-- Materialized (not derived at export): legacy rows have only these minima
-- and their artifacts are gone.
CREATE TABLE IF NOT EXISTS ttfx_results (
    job_uuid   TEXT NOT NULL REFERENCES ttfx_jobs (job_uuid),
    task       TEXT NOT NULL,
    precompile REAL,
    load       REAL,
    run        REAL,
    warm       REAL,
    load_gcoff REAL,
    run_gcoff  REAL,
    warm_gcoff REAL,
    PRIMARY KEY (job_uuid, task)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS ttfx_failures (
    job_uuid TEXT NOT NULL REFERENCES ttfx_jobs (job_uuid),
    task     TEXT NOT NULL,
    error    TEXT NOT NULL,
    PRIMARY KEY (job_uuid, task)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS ttfx_arms (
    job_uuid   TEXT NOT NULL REFERENCES ttfx_jobs (job_uuid),
    arm        TEXT NOT NULL,
    commit_sha TEXT,
    version    TEXT,
    PRIMARY KEY (job_uuid, arm)
) WITHOUT ROWID;

-- One row per record in results.json, in file order (seq), so minima,
-- medians and the first reported error can all be recomputed.
CREATE TABLE IF NOT EXISTS ttfx_samples (
    job_uuid      TEXT NOT NULL REFERENCES ttfx_jobs (job_uuid),
    seq           INTEGER NOT NULL,
    task          TEXT NOT NULL,
    arm           TEXT NOT NULL,
    block         INTEGER,
    status        TEXT,
    error         TEXT,
    error_gcoff   TEXT,
    precompile_s  REAL,
    load_s        TEXT,                      -- JSON arrays of seconds
    run_s         TEXT,
    total_s       TEXT,
    load_gcoff_s  TEXT,
    run_gcoff_s   TEXT,
    total_gcoff_s TEXT,
    PRIMARY KEY (job_uuid, seq)
) WITHOUT ROWID;

-- The latest finished TTFX comparison (head against the master build of the
-- merge-base) of every open julia pull request that has one. Current state
-- only: a run replaces a pull request's row when a newer job finishes and
-- deletes it once the pull request is closed.
CREATE TABLE IF NOT EXISTS ttfx_prs (
    pr_number        INTEGER PRIMARY KEY,
    title            TEXT NOT NULL DEFAULT '',
    author           TEXT NOT NULL DEFAULT '',
    draft            INTEGER NOT NULL DEFAULT 0,
    pr_head_sha      TEXT NOT NULL DEFAULT '',   -- the pull request's head now; the job may be older
    build            INTEGER NOT NULL,           -- julia-pr build number
    job_uuid         TEXT NOT NULL,
    job_state        TEXT NOT NULL,
    build_created_at TEXT NOT NULL,
    finished_at      TEXT,
    web_url          TEXT,
    head_commit      TEXT NOT NULL DEFAULT '',
    head_version     TEXT NOT NULL DEFAULT '',
    base_commit      TEXT NOT NULL DEFAULT '',
    base_version     TEXT NOT NULL DEFAULT '',
    blocks           INTEGER,
    n_tasks          INTEGER,
    verdict          TEXT NOT NULL,              -- improvement, regression or same, as the job judged it
    n_improvements   INTEGER NOT NULL,
    n_regressions    INTEGER NOT NULL,
    suite            TEXT NOT NULL,              -- JSON: metric => {geomeans (head/base per block), verdict, n_tasks}
    tasks            TEXT NOT NULL,              -- JSON: the tasks with an improvement or regression, and their notes
    change_seq       INTEGER NOT NULL
);

-- Buildkite artifacts expire; keep the pair we parsed.
CREATE TABLE IF NOT EXISTS raw_ttfx (
    job_uuid    TEXT PRIMARY KEY REFERENCES ttfx_jobs (job_uuid),
    fetched_at  TEXT NOT NULL,
    results_zst BLOB,
    meta_zst    BLOB
);

-- ------------------------------------------------------------- downloads --
-- Rollup rows from julialang-logs public_outputs, stored as published.
-- request_addrs counts distinct addresses within its own row only and must
-- not be summed across rows.

CREATE TABLE IF NOT EXISTS dl_resource_types (
    date            TEXT NOT NULL,
    resource_type   TEXT NOT NULL,
    status          INTEGER NOT NULL,
    client_type     TEXT NOT NULL DEFAULT '',
    request_addrs   INTEGER,
    request_count   INTEGER,
    cache_misses    INTEGER,
    body_bytes_sent INTEGER,
    request_time_s  REAL,
    PRIMARY KEY (date, resource_type, status, client_type)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS dl_julia_versions (
    date            TEXT NOT NULL,
    julia_version   TEXT NOT NULL,
    client_type     TEXT NOT NULL DEFAULT '',
    request_addrs   INTEGER,
    request_count   INTEGER,
    successes       INTEGER,
    cache_misses    INTEGER,
    body_bytes_sent INTEGER,
    request_time_s  REAL,
    PRIMARY KEY (date, julia_version, client_type)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS dl_julia_systems (
    date            TEXT NOT NULL,
    julia_system    TEXT NOT NULL,
    client_type     TEXT NOT NULL DEFAULT '',
    request_addrs   INTEGER,
    request_count   INTEGER,
    successes       INTEGER,
    cache_misses    INTEGER,
    body_bytes_sent INTEGER,
    request_time_s  REAL,
    PRIMARY KEY (date, julia_system, client_type)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS dl_client_types (
    date            TEXT NOT NULL,
    client_type     TEXT NOT NULL DEFAULT '',
    request_addrs   INTEGER,
    request_count   INTEGER,
    successes       INTEGER,
    cache_misses    INTEGER,
    body_bytes_sent INTEGER,
    request_time_s  REAL,
    PRIMARY KEY (date, client_type)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS dl_package_uuids (
    id   INTEGER PRIMARY KEY,
    uuid TEXT NOT NULL UNIQUE
);

-- Names for the uuids, from the General registry's Registry.toml on every
-- downloads run. A uuid missing here is not in General.
CREATE TABLE IF NOT EXISTS registry_packages (
    uuid TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT
);
CREATE INDEX IF NOT EXISTS registry_packages_name ON registry_packages (name);

-- ~20k rows/day after filtering to successful package requests; upstream
-- keeps 3 days, so this table is the only history there is.
CREATE TABLE IF NOT EXISTS dl_packages (
    date            TEXT NOT NULL,
    package_id      INTEGER NOT NULL REFERENCES dl_package_uuids (id),
    status          INTEGER NOT NULL,
    client_type     TEXT NOT NULL DEFAULT '',
    request_addrs   INTEGER,
    request_count   INTEGER,
    cache_misses    INTEGER,
    body_bytes_sent INTEGER,
    PRIMARY KEY (date, package_id, status, client_type)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS dl_packages_pkg ON dl_packages (package_id, date);

-- The series the site draws, materialized: for dates before the rollup
-- window these come from the legacy export and cannot be recomputed.
CREATE TABLE IF NOT EXISTS dl_series (
    date           TEXT PRIMARY KEY,
    total_requests INTEGER NOT NULL,
    user_requests  INTEGER NOT NULL,
    ci_requests    INTEGER NOT NULL,
    change_seq     INTEGER NOT NULL
);

-- kind = version (key = minor like "1.12") or stage (key = stable | rc |
-- beta | alpha | other); key '*' is the date's total.
CREATE TABLE IF NOT EXISTS dl_mix (
    date           TEXT NOT NULL,
    kind           TEXT NOT NULL,
    key            TEXT NOT NULL,
    total_requests INTEGER NOT NULL,
    user_requests  INTEGER NOT NULL,
    ci_requests    INTEGER NOT NULL,
    PRIMARY KEY (date, kind, key)
) WITHOUT ROWID;

-- published_at is kept as the fetcher formats it (no zone suffix).
CREATE TABLE IF NOT EXISTS julia_tags (
    tag          TEXT PRIMARY KEY,
    date         TEXT NOT NULL,
    published_at TEXT NOT NULL,
    url          TEXT NOT NULL,
    prerelease   INTEGER NOT NULL
);

-- ---------------------------------------------------------------- agents --

CREATE TABLE IF NOT EXISTS agent_snapshots (
    time TEXT PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS agent_snapshot_members (
    time       TEXT NOT NULL REFERENCES agent_snapshots (time),
    agent_name TEXT NOT NULL,
    PRIMARY KEY (time, agent_name)
) WITHOUT ROWID;

-- fold_key is the name without its ".N" slot suffix, the key the Workers
-- tab folds ephemeral per-job agents on.
CREATE TABLE IF NOT EXISTS agents (
    name         TEXT PRIMARY KEY,
    fold_key     TEXT NOT NULL,
    agent_id     TEXT,
    hostname     TEXT NOT NULL DEFAULT '',
    queue        TEXT NOT NULL DEFAULT '',
    os           TEXT NOT NULL DEFAULT '',
    arch         TEXT NOT NULL DEFAULT '',
    version      TEXT NOT NULL DEFAULT '',
    meta_data    TEXT,                       -- JSON array of "key=value" tags
    state        TEXT NOT NULL DEFAULT '',
    connected_at TEXT,
    first_seen   TEXT,
    last_seen    TEXT,
    job_json     TEXT,                       -- {"name","pipeline","build","started_at"} or NULL
    change_seq   INTEGER NOT NULL
);
