# ARIA Warehouse — dbt Analytics Engineering Project

A production-style dbt project that models the raw output of [**ARIA**](https://github.com/rosalinatorres888) — an autonomous job-intelligence pipeline I built that scrapes ~150 job postings daily across 5 sources, semantically scores them against a 55-skill profile, and runs unattended in production.

This repo takes ARIA's raw pipeline output and shapes it into a **dimensionally-modeled analytical warehouse** suitable for BI consumption.

[![CI](https://github.com/rosalinatorres888/aria-dbt/actions/workflows/ci.yml/badge.svg)](https://github.com/rosalinatorres888/aria-dbt/actions/workflows/ci.yml)
[![dbt](https://img.shields.io/badge/dbt-1.11-FF694B?logo=dbt&logoColor=white)](https://docs.getdbt.com/)
[![DuckDB](https://img.shields.io/badge/DuckDB-local-FFF000?logo=duckdb&logoColor=black)](https://duckdb.org/)
[![tests](https://img.shields.io/badge/tests-46_passing-success)](#testing-strategy)

---

## TL;DR

```bash
git clone https://github.com/rosalinatorres888/aria-dbt && cd aria-dbt
pip install dbt-core dbt-duckdb
dbt deps
dbt build                  # seeds → models → tests, 55 nodes, ~1.5s
```

Then poke around:
```bash
duckdb aria.duckdb
> SELECT * FROM mart_skill_demand ORDER BY demand_rank LIMIT 10;
```

---

## What this project demonstrates

| Skill | Where to look |
| --- | --- |
| **dbt fundamentals** — sources, refs, materialization strategy | `dbt_project.yml`, every model |
| **Staging → Marts layering** | `models/staging/` (views), `models/marts/` (tables) |
| **Dimensional modeling** — fact + conformed dimension + analytics mart | `models/marts/` |
| **Schema tests** — `not_null`, `unique`, `accepted_values`, `relationships`, `accepted_range` | `models/*/schema.yml` |
| **Singular (data-invariant) tests** | `tests/assert_qualified_threshold.sql` |
| **Cross-warehouse SQL portability** | Comments in `fct_qualified_postings.sql` explaining `string_agg` vs `LISTAGG` |
| **Reproducibility** — CSV seeds + DuckDB so anyone clones & runs in 30s | `seeds/`, `profiles.yml` |
| **CI** — automated `dbt build` on every push | `.github/workflows/ci.yml` |

---

## Architecture

```
┌──────────────────────────┐
│  ARIA Pipeline (upstream)│  7-stage autonomous scraper, MongoDB + SQLite
│  └─ raw_postings.csv     │  (sampled to seeds/ for this repo)
│  └─ raw_sources.csv      │
│  └─ raw_skill_matches.csv│
└────────────┬─────────────┘
             │  dbt seed
             ▼
┌──────────────────────────┐
│  Sources (raw schema)    │  Declared in models/staging/_sources.yml
│  Tested at the boundary  │  not_null + unique + accepted_values
└────────────┬─────────────┘
             │  dbt run
             ▼
┌──────────────────────────┐
│  Staging (views)         │  Type-cast, renamed, lightly cleaned
│  stg_postings            │  NO business logic here
│  stg_sources             │  Acts as the contract for downstream models
│  stg_skill_matches       │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│  Marts (tables)          │  Business-logic layer, query-optimized
│  fct_qualified_postings  │  ← Fact (one row per qualified posting)
│  dim_source_performance  │  ← Conformed dimension (one row per source)
│  mart_skill_demand       │  ← Analytics mart (skill-level demand metrics)
└──────────────────────────┘
```

---

## Dimensional modeling decisions

This is the part recruiters care about — *why* each choice was made.

### 1. Two-layer model (staging → marts), not three

I deliberately **skipped an intermediate layer**. ARIA's source data is already lightly cleaned upstream (deduplication, normalization happen in the Python pipeline before dbt sees it), so a Snowflake-style `raw → base → staging → intermediate → marts` would have been busywork.

The boundary the project actually defends is:
- **Staging** is a 1:1 contract with the source — same grain, same row count, just trustworthy types and names.
- **Marts** is where business logic lives — filtering (`match_score >= 0.50`), aggregation (skills-per-posting), and ranking (`source_quality_rank`).

This means downstream consumers only ever ref marts. If a column rename happens upstream, only the staging layer changes.

### 2. `fct_qualified_postings` — declarative grain

The fact table's grain is **one row per qualified posting** (`match_score >= 0.50`). This is encoded three places so the contract is unambiguous:

1. In the model SQL itself: `where match_score >= 0.50`
2. In the schema test `accepted_values` (excludes `low` from `match_tier`)
3. In a singular invariant test: `tests/assert_qualified_threshold.sql`

If anyone changes the threshold in one place without the others, the build breaks. That's the point.

The fact table aggregates skill matches up to posting-level (`skill_match_count`, `top_skills_list`) so dashboards don't need to fan out and re-aggregate on every query.

### 3. `dim_source_performance` — conformed dimension with pre-aggregated KPIs

Traditional Kimball would have a thin `dim_source` (just descriptive attributes) with metrics living elsewhere. I made a **conformed dimension that pre-computes KPIs**:

- `qualified_rate` (qualified / total)
- `avg_match_score`
- `source_quality_rank` (window function)

**Why**: source-level aggregations are computed once on rebuild and queried hundreds of times by BI. The cost trade-off (slightly larger dim, dramatically cheaper queries) is worth it for a 5-row dimension that updates daily.

If this were a 1M-row dim, I'd split it into `dim_source` (slowly-changing attributes) + `agg_source_daily` (a snapshot fact). At 5 rows, that's over-engineering.

### 4. `mart_skill_demand` — purpose-built analytics mart

This isn't a strict Kimball fact or dimension — it's a **denormalized analytics mart** built specifically to answer "what skills are most in-demand right now?" The grain is one row per (skill, category) with pre-computed:

- `demand_count`
- `avg_match_strength`
- `demand_rank` (global) and `demand_rank_in_category` (partitioned)

This pattern (a purpose-built mart layered on top of the fact + dim foundation) is exactly what feeds the Streamlit dashboards ARIA's downstream consumers actually use.

### 5. Materialization strategy

| Layer | Materialization | Rationale |
| --- | --- | --- |
| Staging | `view` | Cheap, no storage, always reflects current sources |
| Marts | `table` | Query-optimized, supports indexes (DuckDB / Postgres / Snowflake all benefit) |
| Sources | n/a | External — declared via `sources:` yaml |

For larger production data the marts would shift to `incremental` (only process new postings each run). DuckDB at this scale is overkill for incremental; called out for completeness in the docstrings.

---

## Testing strategy

**46 tests total**, run via `dbt test`. Split across three categories:

### Schema tests on sources (boundary defense — 11 tests)

These fire **before** any model runs, so a malformed seed/source fails the pipeline fast.
- `not_null` on every PK and FK
- `unique` on every PK
- `accepted_values` on `source_code` (`LINKEDIN`/`INDEED`/`GREENHOUSE`/`LEVER`/`ASHBY`) — guards against typos in upstream ARIA config
- `relationships` between `raw_skill_matches.posting_id` and `raw_postings.posting_id`

### Schema tests on transformed models (24 tests)

Same primitives, applied to model outputs. Examples:
- `accepted_range` (0 ≤ `match_score` ≤ 1) — uses `dbt_utils`
- `accepted_values` on `match_tier`, `skill_category`, `source_type`
- `relationships` between marts (`fct_qualified_postings.source_code` → `dim_source_performance.source_code`)

### Singular data-invariant test (1 test)

`tests/assert_qualified_threshold.sql` enforces a cross-row business rule that schema tests can't express: every row in the fact table must clear the 0.50 match threshold. If anyone weakens the filter in the model SQL without updating both, this test fails.

Plus **the 10 standard tests dbt_utils auto-derives from `accepted_range`** for free.

### Required test types (per ARB job description)

| Required | Implementation |
| --- | --- |
| `not_null` | 14 occurrences across sources + models |
| `unique` | 6 occurrences (every PK) |
| `accepted_values` | 5 occurrences on enum-style columns |

Run them:
```bash
dbt test --select test_type:generic   # all schema tests
dbt test --select test_type:singular  # custom invariant tests
```

---

## CI / automation

`.github/workflows/ci.yml` runs `dbt deps && dbt build` on every push. Confirms:
- Seeds load
- Every model compiles
- Every test passes
- Deprecation warnings surfaced

In production this same workflow would run on a schedule (post-ARIA-pipeline-run) and write to Snowflake instead of DuckDB. The only config change is `profiles.yml`.

---

## Local development

Requires Python 3.10+.

```bash
pip install dbt-core dbt-duckdb
cd aria-dbt
dbt deps                    # install dbt_utils
dbt build                   # full pipeline + tests
dbt docs generate           # build the docs site
dbt docs serve              # http://localhost:8080 — explore the DAG visually
```

The DuckDB file (`aria.duckdb`) is gitignored — rebuilt from seeds on every clone.

---

## Why DuckDB for this project

DuckDB is the right tool for *this repo specifically* because it lets a reviewer:

1. Clone the repo
2. `pip install dbt-core dbt-duckdb`
3. `dbt build`
4. See 55 nodes complete in <2 seconds — no cloud account, no credentials, no warehouse provisioning

In production (where this would actually run), the target is Snowflake — same models, same tests, same DAG. The only file that changes is `profiles.yml`. That's the whole point of dbt's adapter abstraction.

---

## What's deliberately left out

Honest about scope:

- **No incremental models** — at 30 seed rows it would be theater. Implementation pattern is documented in the fct comments.
- **No snapshots** — the source data here doesn't have a true type-2 SCD use case. Real candidate: tracking job posting `match_score` changes over time as the 55-skill profile evolves.
- **No semantic layer (MetricFlow)** — would add value for stakeholder self-serve but bloats a portfolio repo. Worth adding if this evolves into a real product.
- **No data quality framework beyond dbt tests** — production would layer on `re_data` or Elementary for anomaly detection on `match_score` distributions.

These are deliberate omissions, not gaps. Each is the right call for a portfolio repo built in a weekend.

---

## Repo structure

```
aria-dbt/
├── README.md                  ← you are here
├── dbt_project.yml            ← project config
├── profiles.yml               ← warehouse connection (DuckDB)
├── packages.yml               ← dbt_utils dependency
├── seeds/
│   ├── raw_postings.csv       ← 30 sampled postings from ARIA output
│   ├── raw_sources.csv        ← 5 scraping sources
│   └── raw_skill_matches.csv  ← 54 (posting, skill) matches
├── models/
│   ├── staging/
│   │   ├── _sources.yml       ← source declarations + boundary tests
│   │   ├── schema.yml         ← staging model tests
│   │   ├── stg_postings.sql
│   │   ├── stg_sources.sql
│   │   └── stg_skill_matches.sql
│   └── marts/
│       ├── schema.yml         ← mart model tests + descriptions
│       ├── fct_qualified_postings.sql   ← fact table
│       ├── dim_source_performance.sql   ← conformed dimension
│       └── mart_skill_demand.sql        ← analytics mart
├── tests/
│   └── assert_qualified_threshold.sql   ← singular invariant test
└── .github/workflows/
    └── ci.yml                 ← runs dbt build on every push
```

---

## About the upstream ARIA pipeline

ARIA is a separate project — a 7-stage autonomous job-intelligence system that:
- Scrapes ~150 job postings daily across LinkedIn, Indeed, Greenhouse, Lever, Ashby
- Applies a local `sentence-transformers` model to semantically score each posting against a 55-skill profile
- Eliminates cloud-API dependencies via Ollama-based local LLM inference
- Persists 147+ qualified opportunities in MongoDB with cross-session SQLite memory sync
- Has run unattended in production for 6+ months

This dbt project consumes ARIA's output and turns it into the analytical warehouse that powers the downstream Streamlit dashboard.

---

**Author**: [Rosalina Torres](https://www.linkedin.com/in/rosalina-torres) — MS Data Analytics Engineering, Northeastern University
