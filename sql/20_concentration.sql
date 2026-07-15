-- 20_concentration.sql
-- Question 2: which areas account for a disproportionate share of crime?
--
-- Unit of area: LSOA (Lower-layer Super Output Area, ~1,500 residents each).
-- It is the finest geography police.uk publishes, and using it avoids joining
-- an external ward lookup table.
--
-- Scope decisions:
--   * Rows with no location are excluded here (they cannot be placed) — the
--     excluded count is in data_quality_log and the README.
--   * Rows the force recorded OUTSIDE its own area (e.g. Met crimes in
--     Derbyshire) are excluded so each force's concentration is measured over
--     its own patch. Also logged.
--   * Whole 25-month period pooled: concentration is a structural question,
--     and pooling smooths single-month noise in small LSOAs.
--
-- Method: rank LSOAs by crime count within each force (RANK), compute each
-- LSOA's cumulative share of force crime (SUM ... OVER ordered window), and
-- bucket LSOAs into deciles (NTILE). Headline metric: share of all located
-- crime that occurs in the top 10% of LSOAs.
--
-- Caveat for the README: police.uk anonymises coordinates by snapping crimes
-- to a fixed list of street-level points, so LSOA assignment is approximate
-- near boundaries. And busy LSOAs (town centres, transport hubs) have large
-- daytime populations — high counts do not mean residents are at high risk.

DROP VIEW IF EXISTS v_lsoa_ranking;

CREATE VIEW v_lsoa_ranking AS
WITH per_lsoa AS (
    SELECT force, lsoa_code, lsoa_name, count(*) AS crimes
    FROM crimes
    WHERE has_location AND in_force_area
    GROUP BY force, lsoa_code, lsoa_name
),
ranked AS (
    SELECT
        force,
        lsoa_code,
        lsoa_name,
        crimes,
        rank()  OVER (PARTITION BY force ORDER BY crimes DESC) AS crime_rank,
        ntile(10) OVER (PARTITION BY force ORDER BY crimes DESC) AS decile,
        round(100.0 * crimes / sum(crimes) OVER (PARTITION BY force), 3) AS pct_of_force_crime,
        round(100.0 * sum(crimes) OVER (PARTITION BY force ORDER BY crimes DESC, lsoa_code)
                    / sum(crimes) OVER (PARTITION BY force), 2) AS cumulative_pct
    FROM per_lsoa
)
SELECT * FROM ranked;

-- Decile summary: what share of crime sits in each tenth of LSOAs?
DROP VIEW IF EXISTS v_concentration_by_decile;

CREATE VIEW v_concentration_by_decile AS
SELECT
    force,
    decile,
    count(*) AS lsoas,
    sum(crimes) AS crimes,
    round(100.0 * sum(crimes) / sum(sum(crimes)) OVER (PARTITION BY force), 2) AS pct_of_force_crime
FROM v_lsoa_ranking
GROUP BY force, decile
ORDER BY force, decile;

-- What drives the hotspots: category mix in top-decile LSOAs vs everywhere else.
DROP VIEW IF EXISTS v_hotspot_category_mix;

CREATE VIEW v_hotspot_category_mix AS
WITH top_lsoas AS (
    SELECT force, lsoa_code FROM v_lsoa_ranking WHERE decile = 1
),
labelled AS (
    SELECT
        c.force,
        c.crime_type,
        CASE WHEN t.lsoa_code IS NOT NULL THEN 'top decile' ELSE 'rest' END AS area_group,
        count(*) AS crimes
    FROM crimes c
    LEFT JOIN top_lsoas t ON t.force = c.force AND t.lsoa_code = c.lsoa_code
    WHERE c.has_location AND c.in_force_area
    GROUP BY 1, 2, 3
)
SELECT
    force,
    area_group,
    crime_type,
    crimes,
    round(100.0 * crimes / sum(crimes) OVER (PARTITION BY force, area_group), 2) AS pct_within_group
FROM labelled
ORDER BY force, area_group, crimes DESC;
