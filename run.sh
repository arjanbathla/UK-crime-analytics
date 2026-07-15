#!/usr/bin/env bash
# One command to reproduce everything: start Postgres, load the CSVs, clean,
# run the three analyses, write /exports, print headline numbers.
set -euo pipefail
cd "$(dirname "$0")"

PSQL="docker compose exec -T db psql -U crime -d crime -v ON_ERROR_STOP=1 -q"

echo "== starting postgres =="
docker compose up -d --wait

echo "== schema =="
$PSQL < sql/01_schema.sql

echo "== loading CSVs (one COPY per file) =="
shopt -s nullglob
files=(data/*/*-street.csv)
if [ ${#files[@]} -eq 0 ]; then
    echo "no CSVs found under data/ — see README for how to download them" >&2
    exit 1
fi
for f in "${files[@]}"; do
    echo "  $f"
    $PSQL -c "COPY raw_crimes FROM STDIN WITH (FORMAT csv, HEADER, NULL '')" < "$f"
done

echo "== cleaning (decisions + counts land in data_quality_log) =="
$PSQL < sql/03_clean.sql

echo "== analyses =="
$PSQL < sql/10_trends.sql
$PSQL < sql/20_concentration.sql
$PSQL < sql/30_outcomes.sql

echo "== exports =="
mkdir -p exports
export_csv () {  # export_csv <query> <outfile>
    $PSQL -c "COPY ($1) TO STDOUT WITH (FORMAT csv, HEADER)" > "exports/$2"
    echo "  exports/$2  ($(wc -l < "exports/$2" | tr -d ' ') lines)"
}
export_csv "SELECT * FROM data_quality_log ORDER BY step"                          data_quality_log.csv
export_csv "SELECT * FROM v_monthly_trends ORDER BY force, crime_type, month"      monthly_trends.csv
export_csv "SELECT * FROM v_seasonality"                                           seasonality.csv
export_csv "SELECT * FROM v_lsoa_ranking ORDER BY force, crime_rank"               lsoa_ranking.csv
export_csv "SELECT * FROM v_concentration_by_decile"                               concentration_by_decile.csv
export_csv "SELECT * FROM v_hotspot_category_mix"                                  hotspot_category_mix.csv
export_csv "SELECT * FROM v_outcome_detail"                                        outcome_detail.csv
export_csv "SELECT * FROM v_outcomes_by_type"                                      outcomes_by_type.csv
export_csv "SELECT * FROM v_outcomes_over_time ORDER BY force, month, outcome_group" outcomes_over_time.csv

echo
echo "== headline numbers =="
$PSQL <<'SQL'
SELECT 'rows in clean table: ' || count(*) FROM crimes;

SELECT 'date range: ' || min(month) || ' to ' || max(month) FROM crimes;

SELECT force || ' latest complete month (' || month || '): '
       || crimes || ' crimes, YoY ' || coalesce(yoy_pct::text, 'n/a') || '%'
FROM v_monthly_trends
WHERE crime_type = 'All crime' AND month = (SELECT max(month) FROM crimes);

SELECT force || ': top 10% of LSOAs hold '
       || pct_of_force_crime || '% of located crime'
FROM v_concentration_by_decile WHERE decile = 1;

SELECT force || ': ' || pct || '% of non-ASB crimes ended with a charge or court process'
FROM (
    SELECT force,
           round(100.0 * count(*) FILTER (WHERE outcome_group = 'Charged or court process')
                 / count(*), 1) AS pct
    FROM v_outcomes_base GROUP BY force
) t;
SQL

echo
echo "done. exports/ is ready."
