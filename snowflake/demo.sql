-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  ICEBERG vs EXTERNAL TABLES: Why Format Matters                            ║
-- ║  Live Demo — 1M Orders Dataset (2022-2025)                                 ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- PRESENTER NOTES:
-- This demo shows why Iceberg tables outperform external tables on the same
-- underlying Parquet data. Three identical datasets, three different access
-- methods, dramatically different performance.
--
-- Dataset: 1M orders, 48 monthly partitions (~20K rows each), amount range 5.99-249.99
--
-- Tables:
--   orders_external_flat         — External table, no partition awareness
--   orders_external_partitioned  — External table, hive-style partition paths
--   orders_iceberg   — Iceberg table via Glue catalog, partitioned
--
-- After each act, we pull bytes_scanned from QUERY_HISTORY to make the
-- comparison concrete. Tell the audience to watch the query profile too.


-- ═══════════════════════════════════════════════════════════════════════════════
-- ACT 0: SETUP & VERIFY
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: Run these first to set context. Confirm all three tables have
-- the same 1M rows so the audience trusts the comparison is apples-to-apples.

USE DATABASE dmichalk_glue_db;
USE SCHEMA glue_tables;
USE WAREHOUSE dmichalk_wh;

-- Verify row counts — all three should return 1,000,000
SELECT 'external_flat' AS table_type, COUNT(*) AS row_count
  FROM orders_external_flat
UNION ALL
SELECT 'external_partitioned', COUNT(*)
  FROM orders_external_partitioned
UNION ALL
SELECT 'iceberg_partitioned', COUNT(*)
  FROM orders_iceberg;

-- Quick look at the data shape
SELECT * FROM orders_iceberg LIMIT 5;

-- PRESENTER: Point out the DDL differences if asked. External tables access
-- Parquet through semi-structured value extraction (value:col::type).
-- Iceberg tables have native typed columns registered via the Glue catalog.


-- ═══════════════════════════════════════════════════════════════════════════════
-- ACT 1: THE PARTITION PRUNING GAP
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: Same filter — "give me June 2024." Watch how many files each
-- table type touches. Open the query profile and check:
--   • "Partitions scanned" vs "Partitions total"
--   • "Files scanned" in the TableScan node
--
-- Expected:
--   Flat external    → scans all 48 files (no partition awareness)
--   Partitioned ext  → scans 1 file  (hive path pruning works)
--   Iceberg          → scans 1 file  (manifest-level partition pruning)

-- 1a. External flat — no partition pruning
SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_flat
 WHERE order_year = 2024 AND order_month = 6;

-- 1b. External partitioned — hive-style pruning kicks in
SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_partitioned
 WHERE order_year = 2024 AND order_month = 6;

-- 1c. Iceberg — manifest-level pruning
SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_iceberg
 WHERE order_year = 2024 AND order_month = 6;

-- Compare bytes scanned across the three queries
-- PRESENTER: The flat table reads ~48x more data than the other two.
SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%'
 ORDER BY start_time DESC LIMIT 3;


-- ═══════════════════════════════════════════════════════════════════════════════
-- ACT 2: ROW-GROUP STATISTICS — ICEBERG'S SECRET WEAPON
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: This is the key insight. Parquet files store min/max stats in
-- each row-group footer. Iceberg's manifest tracks these stats and uses them
-- to skip row groups entirely. External tables? They ignore the stats and
-- read every row, then filter.
--
-- amount is uniform [5.99, 249.99]. Filtering amount > 240 hits only ~4%
-- of rows, but that data could be in ANY row group. Iceberg checks the
-- row-group max(amount) and skips groups where max <= 240. External tables
-- read everything.

-- 2a. Highly selective filter: amount > 240 (~4% of rows)

SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_flat
 WHERE amount > 240;

SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_partitioned
 WHERE amount > 240;

SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_iceberg
 WHERE amount > 240;

-- PRESENTER: Even the partitioned external table reads ALL files here —
-- the filter is on amount, not a partition column. Iceberg still wins
-- because it skips row groups using footer stats.
SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%'
 ORDER BY start_time DESC LIMIT 3;

-- 2b. Narrow range filter: amount BETWEEN 100 AND 110 (~4% of rows)
-- PRESENTER: Even more dramatic. Iceberg can skip row groups where
-- min(amount) > 110 OR max(amount) < 100. External tables read everything.

SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_flat
 WHERE amount BETWEEN 100 AND 110;

SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_partitioned
 WHERE amount BETWEEN 100 AND 110;

SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_iceberg
 WHERE amount BETWEEN 100 AND 110;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%'
 ORDER BY start_time DESC LIMIT 3;


-- ═══════════════════════════════════════════════════════════════════════════════
-- ACT 3: COLUMN PRUNING — SEMI-STRUCTURED vs NATIVE COLUMNAR
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: External tables store all columns in a single VARIANT (the
-- value column). Even if you only need SUM(amount), the engine reads the
-- entire row from Parquet and extracts the field. Iceberg tables have
-- native typed columns — Snowflake reads ONLY the columns in the query.
--
-- This query needs just `amount` plus partition columns. Watch bytes_scanned:
-- Iceberg should read a fraction of what external tables read.

SELECT SUM(amount) AS total_revenue
  FROM orders_external_flat
 WHERE order_year = 2024;

SELECT SUM(amount) AS total_revenue
  FROM orders_external_partitioned
 WHERE order_year = 2024;

SELECT SUM(amount) AS total_revenue
  FROM orders_iceberg
 WHERE order_year = 2024;

-- PRESENTER: Iceberg reads far fewer bytes — it only touches the `amount`
-- column on disk. External tables must deserialize the full row.
SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%'
 ORDER BY start_time DESC LIMIT 3;


-- ═══════════════════════════════════════════════════════════════════════════════
-- ACT 4: THE MONEY SHOT — ALL THREE OPTIMIZATIONS COMBINED
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: This is the cumulative payoff. One query that benefits from:
--   1. Partition pruning   → order_year=2025 AND order_month=3 → 1 of 48 files
--   2. Row-group stats     → amount > 200 → skip groups where max(amount) <= 200
--   3. Column pruning      → only reads order_id, product, amount columns
--
-- External flat gets NONE of these. External partitioned gets only #1.
-- Iceberg gets all three.

SELECT order_id, product, amount
  FROM orders_external_flat
 WHERE order_year = 2025
   AND order_month = 3
   AND amount > 200;

SELECT order_id, product, amount
  FROM orders_external_partitioned
 WHERE order_year = 2025
   AND order_month = 3
   AND amount > 200;

SELECT order_id, product, amount
  FROM orders_iceberg
 WHERE order_year = 2025
   AND order_month = 3
   AND amount > 200;

-- PRESENTER: Compare the bytes_scanned. The gap between flat and Iceberg
-- should be enormous — potentially 50-100x difference.
SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%'
 ORDER BY start_time DESC LIMIT 3;


-- ═══════════════════════════════════════════════════════════════════════════════
-- ACT 5: FULL SCAN WITH AGGREGATION
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: "But what if I need ALL the data?" Even on a full table scan,
-- Iceberg wins because it reads native typed columns directly from Parquet.
-- External tables do semi-structured extraction (value:col::TYPE) per row —
-- essentially JSON-like parsing overhead on every field.

SELECT order_year, order_month, customer_tier,
       COUNT(*)    AS order_count,
       SUM(amount) AS total_revenue,
       AVG(amount) AS avg_order_value
  FROM orders_external_flat
 GROUP BY 1, 2, 3;

SELECT order_year, order_month, customer_tier,
       COUNT(*)    AS order_count,
       SUM(amount) AS total_revenue,
       AVG(amount) AS avg_order_value
  FROM orders_external_partitioned
 GROUP BY 1, 2, 3;

SELECT order_year, order_month, customer_tier,
       COUNT(*)    AS order_count,
       SUM(amount) AS total_revenue,
       AVG(amount) AS avg_order_value
  FROM orders_iceberg
 GROUP BY 1, 2, 3;

-- PRESENTER: Even scanning all 1M rows, Iceberg reads fewer bytes because
-- it only touches the 4 columns needed (not the full row VARIANT).
SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%'
 ORDER BY start_time DESC LIMIT 3;


-- ═══════════════════════════════════════════════════════════════════════════════
-- SUMMARY
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- ┌───────────────────────┬──────────────────┬──────────────────┬──────────────────┐
-- │ Optimization          │ External Flat    │ External Part.   │ Iceberg          │
-- ├───────────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ Partition pruning     │ ✗ scans all 48   │ ✓ prunes to 1    │ ✓ prunes to 1    │
-- │ Row-group stats       │ ✗ reads all rows │ ✗ reads all rows │ ✓ skips groups   │
-- │ Column pruning        │ ✗ full VARIANT   │ ✗ full VARIANT   │ ✓ named columns  │
-- │ Native typed reads    │ ✗ value:col cast │ ✗ value:col cast │ ✓ direct Parquet │
-- └───────────────────────┴──────────────────┴──────────────────┴──────────────────┘
--
-- KEY TAKEAWAY: Same Parquet files, same S3 bucket, same data — but Iceberg's
-- metadata layer (manifests + stats) lets Snowflake skip work at every level.
-- External tables treat Parquet as a dumb container. Iceberg treats it as an
-- optimized storage format.
--
-- The cost of this advantage? Maintaining a catalog (Glue/Polaris/etc.) that
-- tracks partition manifests and column-level statistics. That's it.
