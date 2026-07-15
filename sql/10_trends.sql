-- 10_trends.sql
-- Question 1: how have overall and per-category crime volumes moved month by
-- month, and how much of the movement is seasonal?
--
-- Method: count crimes per force / category / month, then use LAG to compute
--   * month-over-month change  (LAG 1)  -> short-term movement, noisy, seasonal
--   * year-over-year change    (LAG 12) -> compares like-for-like months, so
--     seasonality cancels out and what remains is trend.
-- An 'All crime' rollup per force is unioned in so the headline series sits
-- in the same export as the per-category ones.
--
-- All recorded crimes count here, including rows with no location.

DROP VIEW IF EXISTS v_monthly_trends;

CREATE VIEW v_monthly_trends AS
WITH by_category AS (
    SELECT force, crime_type, month, count(*) AS crimes
    FROM crimes
    GROUP BY force, crime_type, month
),
with_total AS (
    SELECT force, 'All crime' AS crime_type, month, sum(crimes) AS crimes
    FROM by_category
    GROUP BY force, month
    UNION ALL
    SELECT force, crime_type, month, crimes FROM by_category
),
changes AS (
    SELECT
        force,
        crime_type,
        month,
        crimes,
        crimes - lag(crimes, 1)  OVER w AS mom_change,
        crimes - lag(crimes, 12) OVER w AS yoy_change,
        round(100.0 * (crimes - lag(crimes, 1)  OVER w) / lag(crimes, 1)  OVER w, 1) AS mom_pct,
        round(100.0 * (crimes - lag(crimes, 12) OVER w) / lag(crimes, 12) OVER w, 1) AS yoy_pct
    FROM with_total
    WINDOW w AS (PARTITION BY force, crime_type ORDER BY month)
)
SELECT * FROM changes;

-- Seasonality check: average each calendar month's share of its year's crime.
-- If (say) July consistently runs above 1/12 = 8.33%, that is seasonality
-- rather than trend. Uses the 24 complete months (May 2024 - Apr 2026).
DROP VIEW IF EXISTS v_seasonality;

CREATE VIEW v_seasonality AS
WITH monthly AS (
    SELECT force, month, count(*) AS crimes
    FROM crimes
    GROUP BY force, month
),
share AS (
    SELECT
        force,
        month,
        extract(month FROM month)::int AS calendar_month,
        crimes,
        round(100.0 * crimes / sum(crimes) OVER (
            PARTITION BY force, extract(year FROM month + interval '8 months')
        ), 2) AS pct_of_rolling_year   -- years cut May-Apr so both are complete
    FROM monthly
    WHERE month BETWEEN date '2024-05-01' AND date '2026-04-01'
)
SELECT
    force,
    calendar_month,
    to_char(to_date(calendar_month::text, 'MM'), 'Mon') AS month_name,
    round(avg(pct_of_rolling_year), 2) AS avg_pct_of_year,
    round(avg(crimes), 0) AS avg_crimes
FROM share
GROUP BY force, calendar_month
ORDER BY force, calendar_month;
