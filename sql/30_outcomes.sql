-- 30_outcomes.sql
-- Question 3: what share of crimes reach each outcome, how does it vary by
-- crime type, and how has it shifted over time?
--
-- Source column: 'Last outcome category' in the street file — the latest
-- outcome police.uk had at publication. Two honest limitations:
--   * Anti-social behaviour never gets an outcome published, so ASB is
--     excluded from this whole analysis.
--   * Outcomes are a SNAPSHOT. Recent months are right-censored: many crimes
--     are still 'Under investigation' simply because not enough time has
--     passed. The over-time view keeps 'still in progress' as its own group
--     so the censoring is visible instead of hidden, and time comparisons in
--     the README are only made between months old enough to have settled.
--
-- The 14 raw outcome strings observed in this dataset are grouped with CASE
-- into six buckets a stakeholder can read at a glance. Note the data never
-- contains a plain 'Suspect charged' value: charges surface as 'Awaiting
-- court outcome' / 'Court result unavailable', so those are grouped as
-- 'Charged or court process'. The raw strings and their mapping are preserved
-- in the outcome_detail export as an audit trail.

DROP VIEW IF EXISTS v_outcomes_over_time;
DROP VIEW IF EXISTS v_outcomes_by_type;
DROP VIEW IF EXISTS v_outcome_detail;
DROP VIEW IF EXISTS v_outcomes_base;

CREATE VIEW v_outcomes_base AS
SELECT
    force,
    month,
    crime_type,
    last_outcome,
    CASE
        WHEN last_outcome IN ('Suspect charged',
                              'Suspect charged as part of another case',
                              'Awaiting court outcome',
                              'Court result unavailable')
            THEN 'Charged or court process'
        WHEN last_outcome IN ('Offender given a caution',
                              'Offender given penalty notice',
                              'Local resolution',
                              'Action to be taken by another organisation')
            THEN 'Out-of-court resolution'
        WHEN last_outcome = 'Investigation complete; no suspect identified'
            THEN 'No suspect identified'
        WHEN last_outcome = 'Unable to prosecute suspect'
            THEN 'Suspect known, unable to prosecute'
        WHEN last_outcome IN ('Formal action is not in the public interest',
                              'Further investigation is not in the public interest',
                              'Further action is not in the public interest')
            THEN 'Closed: not in the public interest'
        WHEN last_outcome IN ('Under investigation', 'Status update unavailable')
             OR last_outcome IS NULL
            THEN 'Still in progress / no update'
        ELSE 'Other'
    END AS outcome_group
FROM crimes
WHERE crime_type <> 'Anti-social behaviour';

-- Exact outcome strings with counts: the audit trail for the CASE above.
CREATE VIEW v_outcome_detail AS
SELECT
    coalesce(last_outcome, '(blank)') AS last_outcome,
    outcome_group,
    count(*) AS crimes,
    round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct_of_all
FROM v_outcomes_base
GROUP BY 1, 2
ORDER BY crimes DESC;

-- Outcome mix by crime type (whole period, both forces broken out).
CREATE VIEW v_outcomes_by_type AS
SELECT
    force,
    crime_type,
    outcome_group,
    count(*) AS crimes,
    round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY force, crime_type), 2)
        AS pct_of_type
FROM v_outcomes_base
GROUP BY force, crime_type, outcome_group
ORDER BY force, crime_type, crimes DESC;

-- Outcome mix by month. 'Still in progress' share will rise towards the most
-- recent months — that is censoring, not a performance change.
CREATE VIEW v_outcomes_over_time AS
SELECT
    force,
    month,
    outcome_group,
    count(*) AS crimes,
    round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY force, month), 2)
        AS pct_of_month
FROM v_outcomes_base
GROUP BY force, month, outcome_group
ORDER BY force, month, outcome_group;
