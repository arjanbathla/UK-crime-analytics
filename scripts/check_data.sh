#!/usr/bin/env bash
# Sanity-check the data/ folder before running the pipeline:
# expects data/YYYY-MM/YYYY-MM-<force>-street.csv for 2024-04..2026-04
# for metropolitan and west-midlands, all with the standard 12-column header.
set -euo pipefail
cd "$(dirname "$0")/.."

expected_header='Crime ID,Month,Reported by,Falls within,Longitude,Latitude,Location,LSOA code,LSOA name,Crime type,Last outcome category,Context'
missing=0
count=0

# 2024-04 .. 2026-04 (macOS ships bash 3.2, which can't zero-pad {04..12})
months=""
y=2024; m=4
while [ "$y$( printf '%02d' "$m" )" -le 202604 ]; do
    months="$months $y-$(printf '%02d' "$m")"
    m=$((m + 1)); if [ "$m" -gt 12 ]; then m=1; y=$((y + 1)); fi
done

for ym in $months; do
    for force in metropolitan west-midlands; do
        f="data/$ym/$ym-$force-street.csv"
        if [ ! -f "$f" ]; then
            echo "MISSING: $f"
            missing=$((missing + 1))
            continue
        fi
        header=$(head -1 "$f" | tr -d '\r')
        if [ "$header" != "$expected_header" ]; then
            echo "BAD HEADER: $f"
            missing=$((missing + 1))
            continue
        fi
        count=$((count + 1))
    done
done

echo "$count files ok, $missing problems"
[ "$missing" -eq 0 ]
