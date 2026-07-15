-- 03_clean.sql
-- Builds the typed `crimes` table from raw_crimes and records every cleaning
-- decision in a data_quality_log table so the README numbers come straight
-- from SQL, not from memory.
--
-- CLEANING DECISIONS (each one logged with a real row count below):
--
-- 1. Duplicate crime IDs. The same crime ID can appear twice WITHIN a monthly
--    file (checked: no ID spans two months in this dataset). About 70% of the
--    duplicate pairs disagree only on the outcome column. We keep ONE row per
--    crime_id, preferring a row that has an outcome recorded; where both do,
--    the choice is deterministic but arbitrary (ctid order) — with no
--    timestamp there is no way to know which outcome is fresher, and this
--    affects ~5k rows out of 3M. Rows dropped are logged.
--    ASB rows have no crime_id at all, so they cannot be deduplicated —
--    we keep all of them and accept that as a known limitation.
--
-- 2. Missing locations. Some rows have no coordinates / no LSOA ("No
--    location" rows). We KEEP them — they are real recorded crimes and must
--    count in trends and outcomes — but flag them with has_location so the
--    geographic analysis can exclude them explicitly.
--
-- 3. Out-of-area rows. The Met (and occasionally West Midlands) record
--    crimes that happened outside their own force area, so a Met row can
--    carry an LSOA in, say, Derbyshire. We keep them (the crime is real and
--    the LSOA is where it happened) but flag them with in_force_area so the
--    concentration analysis can be read correctly. Detection is by LSOA name
--    prefix: London borough names for the Met, the seven West Midlands
--    council names for West Midlands Police.
--
-- 4. Blank outcomes. 'Last outcome category' is empty for all ASB (police.uk
--    never publishes outcomes for ASB) and for a small number of other rows.
--    We leave it NULL rather than inventing a value; the outcomes analysis
--    excludes ASB and reports the NULL share for everything else.
--
-- 5. The `context` column is empty on every row (checked below) and is not
--    carried into the clean table. `falls_within` always equals `reported_by`
--    in these files, so we keep a single `force` column.

-- CASCADE: on a re-run the analysis views depend on this table; they are
-- recreated by the analysis scripts straight after.
DROP TABLE IF EXISTS crimes CASCADE;
DROP TABLE IF EXISTS data_quality_log;

CREATE TABLE data_quality_log (
    step        int,
    description text,
    row_count   bigint
);

INSERT INTO data_quality_log
SELECT 1, 'raw rows loaded', count(*) FROM raw_crimes;

INSERT INTO data_quality_log
SELECT 2, 'raw rows with non-empty context column (expect 0)', count(*)
FROM raw_crimes WHERE context IS NOT NULL AND context <> '';

INSERT INTO data_quality_log
SELECT 3, 'raw rows where falls_within differs from reported_by (expect 0)', count(*)
FROM raw_crimes WHERE falls_within IS DISTINCT FROM reported_by;

INSERT INTO data_quality_log
SELECT 4, 'rows with no crime_id (all ASB, cannot be deduplicated)', count(*)
FROM raw_crimes WHERE crime_id IS NULL;

-- Duplicate crime IDs: count the surplus rows before deduplicating.
INSERT INTO data_quality_log
SELECT 5, 'surplus duplicate rows (same crime_id appearing more than once)',
       count(*) - count(DISTINCT crime_id)
FROM raw_crimes WHERE crime_id IS NOT NULL;

CREATE TABLE crimes (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    crime_id     text,          -- NULL for ASB; unique otherwise (enforced below)
    month        date NOT NULL, -- first day of the month
    force        text NOT NULL,
    longitude    numeric(9,6),
    latitude     numeric(9,6),
    location     text,
    lsoa_code    text,
    lsoa_name    text,
    crime_type   text NOT NULL,
    last_outcome text,
    has_location boolean NOT NULL,
    in_force_area boolean       -- NULL when there is no location to judge by
);

-- Dedupe: one row per crime_id, preferring a row with an outcome recorded;
-- ctid is the deterministic tie-breaker (see decision 1 above).
WITH ranked AS (
    SELECT *,
           row_number() OVER (
               PARTITION BY crime_id
               ORDER BY (nullif(last_outcome, '') IS NULL), ctid
           ) AS rn
    FROM raw_crimes
    WHERE crime_id IS NOT NULL
),
kept AS (
    SELECT * FROM ranked WHERE rn = 1
    UNION ALL
    SELECT r.*, 1 AS rn FROM raw_crimes r WHERE r.crime_id IS NULL
)
INSERT INTO crimes (crime_id, month, force, longitude, latitude, location,
                    lsoa_code, lsoa_name, crime_type, last_outcome,
                    has_location, in_force_area)
SELECT
    crime_id,
    to_date(month, 'YYYY-MM'),
    reported_by,
    nullif(longitude, '')::numeric(9,6),
    nullif(latitude, '')::numeric(9,6),
    nullif(location, ''),
    nullif(lsoa_code, ''),
    nullif(lsoa_name, ''),
    crime_type,
    nullif(last_outcome, ''),
    (nullif(lsoa_code, '') IS NOT NULL),
    CASE
        WHEN nullif(lsoa_name, '') IS NULL THEN NULL
        WHEN reported_by = 'Metropolitan Police Service' THEN
            regexp_replace(lsoa_name, ' [0-9]{3}[A-Z]$', '') IN
            ('Barking and Dagenham','Barnet','Bexley','Brent','Bromley','Camden',
             'City of London','Croydon','Ealing','Enfield','Greenwich','Hackney',
             'Hammersmith and Fulham','Haringey','Harrow','Havering','Hillingdon',
             'Hounslow','Islington','Kensington and Chelsea','Kingston upon Thames',
             'Lambeth','Lewisham','Merton','Newham','Redbridge',
             'Richmond upon Thames','Southwark','Sutton','Tower Hamlets',
             'Waltham Forest','Wandsworth','Westminster')
        WHEN reported_by = 'West Midlands Police' THEN
            regexp_replace(lsoa_name, ' [0-9]{3}[A-Z]$', '') IN
            ('Birmingham','Coventry','Dudley','Sandwell','Solihull','Walsall',
             'Wolverhampton')
        ELSE NULL
    END
FROM kept;

-- crime_id must now be unique; this index doubles as the check.
CREATE UNIQUE INDEX idx_crimes_crime_id ON crimes (crime_id) WHERE crime_id IS NOT NULL;
CREATE INDEX idx_crimes_month ON crimes (month);
CREATE INDEX idx_crimes_lsoa  ON crimes (lsoa_code);

INSERT INTO data_quality_log
SELECT 6, 'clean rows kept', count(*) FROM crimes;

INSERT INTO data_quality_log
SELECT 7, 'clean rows with no location (kept, excluded from geography only)', count(*)
FROM crimes WHERE NOT has_location;

INSERT INTO data_quality_log
SELECT 8, 'clean rows located outside the recording force''s own area', count(*)
FROM crimes WHERE in_force_area = false;

INSERT INTO data_quality_log
SELECT 9, 'non-ASB rows with blank outcome', count(*)
FROM crimes WHERE crime_type <> 'Anti-social behaviour' AND last_outcome IS NULL;

ANALYZE crimes;

SELECT step, description, row_count FROM data_quality_log ORDER BY step;
