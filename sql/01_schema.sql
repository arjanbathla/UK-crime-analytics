-- 01_schema.sql
-- Two tables: a raw landing table that mirrors the CSV exactly (all text,
-- no constraints, so the load can never fail on a bad value), and a clean
-- typed table that 03_clean.sql builds from it. Keeping raw data untouched
-- means every cleaning decision is reproducible and auditable with SQL.

DROP TABLE IF EXISTS raw_crimes;

CREATE TABLE raw_crimes (
    crime_id      text,   -- 64-char hash; EMPTY for all Anti-social behaviour rows
    month         text,   -- 'YYYY-MM'
    reported_by   text,   -- force that recorded the crime
    falls_within  text,   -- force area; same as reported_by in this dataset
    longitude     text,
    latitude      text,
    location      text,   -- anonymised 'On or near ...' snap point, not the true address
    lsoa_code     text,
    lsoa_name     text,
    crime_type    text,
    last_outcome  text,   -- latest outcome at time of publication (snapshot, not final)
    context       text    -- documented as unused by police.uk; always empty in practice
);

-- The clean table is created in 03_clean.sql so that dropping/rebuilding it
-- doesn't require reloading 3M raw rows.
