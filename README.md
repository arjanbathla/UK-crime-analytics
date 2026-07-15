# UK Street-Level Crime: a SQL Analysis

**Dashboard:** [live on Tableau Public](https://public.tableau.com/app/profile/arjan.bathla/viz/crime_analytics/Trends)

A SQL-first analysis of police.uk recorded crime data for the Metropolitan
Police and West Midlands Police, April 2024 – April 2026 (25 months,
3,046,144 raw rows). All analysis lives in commented `.sql` files; each one
writes its results to `exports/*.csv` for visualisation elsewhere. There is
deliberately no dashboard and no pandas in this repo.

**Data source:** [data.police.uk](https://data.police.uk) street-level crime
CSVs, published under the
[Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).
Contains public sector information licensed under the OGL.

## Setup

Requires Docker (with Compose) and ~1GB of disk for the database. No local
Postgres or Python needed — everything runs inside the container.

```bash
# 1. put the CSVs in place (see "Getting the data" below), then check them:
./scripts/check_data.sh

# 2. run everything: start Postgres 16, load, clean, analyse, export
./run.sh
```

`run.sh` prints headline numbers at the end and leaves nine CSVs in
`exports/`. It is idempotent — run it again and it rebuilds from scratch.
To poke around yourself: `docker compose exec db psql -U crime -d crime`
(or connect to `localhost:5434`, user/password/db all `crime`).

### Getting the data

The CSVs come from the [custom download form](https://data.police.uk/data/):
tick **Metropolitan Police Service** and **West Midlands Police**, date range
**April 2024 – April 2026**, include crime data only (not outcomes or
stop-and-search). Unzip into `data/`, keeping the archive's one-folder-per-month
layout (`data/2024-04/2024-04-metropolitan-street.csv`, ...). The loader in
`run.sh` globs `data/*/*-street.csv`, so any force/month combination dropped
in there gets loaded — there is nothing hard-coded about these two forces.

## Scope: why these two forces and 25 months

- **Metropolitan Police** is the obvious anchor: the largest force in the
  country and the one most stakeholders ask about.
- **West Midlands Police** is the best like-for-like comparison: the
  second-largest urban force (Birmingham, Coventry, Wolverhampton), so
  differences are less likely to be explained away by "London is just bigger".
- **25 months** is the shortest window that still allows year-over-year
  comparison for 13 of the months. YoY is essential here because crime is
  seasonal — comparing July to February tells you about the weather, not the
  trend.
- Greater Manchester Police (the other natural comparator) was ruled out: it
  has well-documented gaps in its police.uk submissions.

At ~3M rows the whole thing loads in a couple of minutes and every query runs
in seconds, which keeps the feedback loop fast without sampling.

## The three questions

Each question is one SQL file. Views are created by the file; `run.sh`
exports them.

| # | Question | SQL | Main exports |
|---|----------|-----|--------------|
| 1 | How have crime volumes moved month by month, and what is seasonal vs trend? | `sql/10_trends.sql` | `monthly_trends.csv`, `seasonality.csv` |
| 2 | Which areas account for a disproportionate share of crime? | `sql/20_concentration.sql` | `lsoa_ranking.csv`, `concentration_by_decile.csv`, `hotspot_category_mix.csv` |
| 3 | What share of crimes reach each outcome, by type and over time? | `sql/30_outcomes.sql` | `outcome_detail.csv`, `outcomes_by_type.csv`, `outcomes_over_time.csv` |

## Data quality and cleaning log

Every decision is written as a comment in `sql/03_clean.sql`, and every count
below is computed by that script into a `data_quality_log` table (exported to
`exports/data_quality_log.csv`), so these numbers regenerate on each run.

| Issue | What the data showed | Decision |
|---|---|---|
| Duplicate crime IDs | 6,899 IDs appear twice, always within the same monthly file, never across months. 5,080 of the pairs disagree on the outcome column. | Keep one row per ID, preferring the row that has an outcome recorded. Where both rows have (different) outcomes there is no timestamp to say which is fresher, so the tie-break is deterministic but arbitrary. Affects 0.23% of rows. |
| Missing crime IDs | 535,180 rows (17.6%) have no crime ID — exactly the Anti-social behaviour rows. police.uk never assigns IDs to ASB. | Kept. They count in trends and geography but cannot be deduplicated and carry no outcome. |
| Missing locations | Far less of a problem than police.uk's reputation suggests: **0** rows without coordinates and **1** row without an LSOA in the whole extract. | The single row is kept, flagged `has_location = false`, and excluded from the geographic analysis only. |
| Out-of-area records | 11,198 rows (0.4%) are recorded by a force but located outside its own area — e.g. Met-recorded crimes with Derbyshire LSOAs. | Kept and flagged `in_force_area = false`. Included in trends and outcomes (the force did record them), excluded from the concentration analysis (which measures each force over its own patch). Detection is by LSOA-name prefix against the 33 London boroughs / 7 West Midlands councils. |
| Location anonymisation | All coordinates are snapped to police.uk's fixed list of street-level anonymisation points. | Nothing to fix, but it means LSOA assignment is approximate near boundaries, and point-level maps would be misleading. Analysis stays at LSOA level or above. |
| Blank outcomes | Blank only for ASB (by design — outcomes are never published for ASB). 0 non-ASB rows have a blank outcome. | ASB excluded from the outcomes analysis; stated wherever outcomes are discussed. |
| Met October 2024 outcome glitch | 20,939 Met crimes in Oct 2024 carry the outcome "Status update unavailable" — 26% of that month's non-ASB crimes, vs ~2.5% in every surrounding month. Clearly a publishing artefact, not a real backlog. | Kept as-is (there is nothing to correct it to), but grouped under "Still in progress / no update" so it is visible as a one-month spike in the outcomes-over-time chart rather than silently distorting a "resolved" category. |
| `Context` column | Empty on all 3M rows. | Not carried into the clean table. |
| `Falls within` vs `Reported by` | Identical on all rows. | Collapsed to a single `force` column. |

Clean table: **3,039,245 rows** (raw 3,046,144 − 6,899 duplicate rows).

## Methodology

- `raw_crimes` mirrors the CSVs exactly (all text, no constraints) so loading
  can never silently mangle a value; `crimes` is the typed, deduplicated table
  with a surrogate primary key, a unique index on `crime_id`, and flags for
  the quality issues above. All analysis reads `crimes`.
- Q1 uses `LAG(count, 1)` for month-over-month and `LAG(count, 12)` for
  year-over-year change, partitioned by force and category. YoY compares each
  month to the same calendar month a year earlier, which cancels seasonality.
  A second view averages each calendar month's share of its year to show the
  seasonal shape directly.
- Q2 pools the whole period, ranks LSOAs within each force (`RANK`), computes
  cumulative share of crime (`SUM ... OVER` an ordered window) and buckets
  LSOAs into deciles (`NTILE(10)`).
- Q3 groups the 14 raw outcome strings into six readable buckets with a
  `CASE` (mapping preserved in `exports/outcome_detail.csv`), then cuts them
  by crime type and by month.

## Findings

All numbers are from the exports in this repo and regenerate on `./run.sh`.

### 1. Trends and seasonality

- Comparing the two complete years (May 2024–Apr 2025 vs May 2025–Apr 2026):
  the Met is flat (1,132,818 → 1,131,917 crimes, **−0.1%**); West Midlands
  fell **−5.5%** (337,209 → 318,678).
- Both forces show the same seasonal shape: July is the peak month (~9.1% of
  the year's crime in the Met, 9.3% in West Midlands) and February the trough
  (~7.4% in both). Part of the February dip is just month length — 28 days
  would give 7.7% even at a flat daily rate — but July sits above its
  31-day expectation of 8.5%, so summer really is higher.
- Biggest category moves, year over year (categories above 10k/year):
  - Met **theft from the person −19.5%** (96,536 → 77,737) and vehicle crime
    −9.6% — while **violence and sexual offences rose +8.3%** (254,595 →
    275,649) and drugs +16.3%. A drugs rise usually reflects enforcement
    activity (drugs crimes are mostly recorded when police search someone),
    so it should not be read as a rise in underlying drug use.
  - West Midlands **anti-social behaviour −42.6%** (29,447 → 16,893). A fall
    this large and this isolated is more likely a recording or triage change
    than a real halving of ASB; the data cannot distinguish the two, so it is
    flagged rather than celebrated.

### 2. Geographic concentration

- Crime is heavily concentrated. The top 10% of LSOAs account for **36.7%**
  of located crime in the Met and **33.0%** in West Midlands. Just 228 of the
  Met's 4,981 LSOAs (4.6%) contain a quarter of its crime; West Midlands
  needs only 105 of 1,719.
- The Met's top four LSOAs are all in **Westminster** — the West End retail
  and nightlife core — with the #1 (Westminster 013G) alone holding 28,467
  crimes, 1.2% of everything the Met recorded in two years. #5 is Hillingdon
  031A, which contains Heathrow. West Midlands' #1 is Birmingham 138A (city
  centre), 1.8% of force crime.
- What makes a hotspot is acquisitive street crime, not neighbourhood crime:
  in top-decile LSOAs, shoplifting and theft from the person are 3–4× their
  share elsewhere, while burglary and vehicle crime are *under*-represented.
  These are places people visit, not places people live — high counts do not
  mean residents there face proportionate risk, and LSOA counts are not
  divided by (resident or daytime) population here.

### 3. Outcomes

- Outcomes are bleak and the numbers should be reported plainly: across the
  full period, **5.2%** of non-ASB crimes in the Met and **8.4%** in West
  Midlands ended in a charge or court process. The single most common outcome
  is "Investigation complete; no suspect identified" (1.22M crimes, 49% of
  all non-ASB records), followed by "Unable to prosecute suspect" (0.81M,
  32%) — which typically means a suspect existed but the case could not
  proceed, often for evidential or victim-support reasons.
- Charge rates vary enormously by crime type. Met theft from the person:
  **0.6% charged, 88.5% no suspect identified**. Vehicle crime: 1.0% charged.
  At the other end, drugs: 14.4% charged and only 2.8% "no suspect" —
  unsurprising, since a drugs record usually starts with a suspect in hand.
  Shoplifting splits the forces: 21.3% charged in West Midlands vs 8.3% in
  the Met.
- The over-time view is dominated by **right-censoring**: 47% of April 2026
  crimes are still "in progress / no update", falling to ~2% for early-2024
  months. That curve is time-to-resolution, not a collapse in performance,
  which is why this project does not claim an outcome trend from the recent
  months. Comparing only well-settled months (2024-04 to 2025-04, all ≤3%
  in progress) shows charge rates stable within a percentage point.

## Limitations — read before quoting any number

- **Recorded crime is not actual crime.** These files contain what police
  recorded. The Crime Survey for England and Wales consistently shows large
  amounts of crime never reported to police, with reporting rates that differ
  by crime type and area. A change in recorded volume can reflect a change in
  reporting or recording practice as easily as a change in crime — the West
  Midlands ASB fall above is a likely example.
- **Nothing here is causal.** This analysis describes where, when and what;
  it cannot say why.
- **Outcomes are a snapshot** at publication, taken from the street file's
  "Last outcome category". Recent months are right-censored (see above), and
  outcomes for older crimes can still change after publication.
- **Locations are anonymised** to snap points, so fine-grained geography is
  approximate; LSOA is the safe resolution.
- **No population denominator.** Concentration figures are raw counts, not
  rates. City-centre LSOAs have tiny resident populations and huge footfall.
- **Two forces, two years.** Nothing here generalises to England and Wales.

## Repo layout

```
docker-compose.yml     Postgres 16, data in a named volume, host port 5434
run.sh                 the whole pipeline, one command
scripts/check_data.sh  verifies the expected 50 CSVs before you run
sql/01_schema.sql      raw landing table
sql/03_clean.sql       typed clean table + cleaning log (the decisions live here)
sql/10_trends.sql      Q1: trend & seasonality
sql/20_concentration.sql  Q2: geographic concentration
sql/30_outcomes.sql    Q3: outcomes
exports/               9 CSVs, regenerated by run.sh
data/                  the police.uk CSVs (not committed; ~700MB)
```
