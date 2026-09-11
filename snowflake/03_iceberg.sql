-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  3. ICEBERG (via Glue Catalog Integration + Catalog-Linked Database)      ║
-- ║  Region: us-east-1 | AWS: 913524911227 | Snowflake: FXC11617             ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- Approach: External volume + Glue catalog integration → Iceberg table.
-- Same 1M orders, but Iceberg metadata gives Snowflake:
--   - Partition pruning from manifest (not file paths)
--   - Row-group min/max stats → skip groups that can't match predicate
--   - NULL count stats → skip groups that are entirely NULL for a column
--   - Sorted key stats → skip row groups for point lookups on sorted columns
--   - Native columnar reads → only reads projected columns from Parquet
--   - Predicate pushdown into the Parquet reader
--
-- Also includes: Iceberg Catalog-Linked Database via Glue REST (GA, needs LF admin)


-- ═══════════════════════════════════════════════════════════════════════════════
-- SETUP
-- ═══════════════════════════════════════════════════════════════════════════════

USE ROLE ACCOUNTADMIN;
CREATE DATABASE IF NOT EXISTS dmichalk_glue_db;
CREATE SCHEMA IF NOT EXISTS dmichalk_glue_db.glue_tables;

-- External Volume
CREATE OR REPLACE EXTERNAL VOLUME dmichalk_glue_ext_vol
  STORAGE_LOCATIONS = (
    (
      NAME = 'dmichalk-s3'
      STORAGE_BASE_URL = 's3://dmichalk-glue-sandbox/'
      STORAGE_PROVIDER = 'S3'
      STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
    )
  );

DESCRIBE EXTERNAL VOLUME dmichalk_glue_ext_vol;
-- Record STORAGE_AWS_EXTERNAL_ID → add to terraform.tfvars → terraform apply

-- Glue Catalog Integration (non-REST, uses IAM directly — no LF admin needed)
CREATE OR REPLACE CATALOG INTEGRATION dmichalk_glue_iceberg_int
  CATALOG_SOURCE = GLUE
  TABLE_FORMAT = ICEBERG
  GLUE_CATALOG_ID = '913524911227'
  GLUE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
  GLUE_REGION = 'us-east-1'
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db'
  ENABLED = TRUE;

DESCRIBE CATALOG INTEGRATION dmichalk_glue_iceberg_int;
-- Record GLUE_AWS_EXTERNAL_ID → add to terraform.tfvars → terraform apply

-- Iceberg Table (from Glue catalog — 1M rows, partitioned by year/month)
CREATE OR REPLACE ICEBERG TABLE dmichalk_glue_db.glue_tables.orders_iceberg
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_glue_iceberg_int'
  CATALOG_TABLE_NAME = 'orders'
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db';

-- Verify
SELECT COUNT(*) AS row_count FROM dmichalk_glue_db.glue_tables.orders_iceberg;
SELECT * FROM dmichalk_glue_db.glue_tables.orders_iceberg LIMIT 5;


-- ═══════════════════════════════════════════════════════════════════════════════
-- SETUP: ICEBERG CATALOG-LINKED DATABASE (Glue Iceberg REST)            [GA]
-- ═══════════════════════════════════════════════════════════════════════════════
-- Auto-discovers Iceberg tables from Glue via the Iceberg REST endpoint.
-- No manual CREATE TABLE — tables appear automatically.
-- BLOCKED: needs LF admin to grant GetTemporaryCredentialsForTableV2.
-- Ask cshimmin or sf-afe-skumar (LF admins on 913524911227).

-- CREATE OR REPLACE CATALOG INTEGRATION dmichalk_glue_iceberg_rest_int
--   CATALOG_SOURCE = ICEBERG_REST
--   TABLE_FORMAT = ICEBERG
--   CATALOG_NAMESPACE = 'dmichalk_sandbox_db'
--   REST_CONFIG = (
--     CATALOG_URI = 'https://glue.us-east-1.amazonaws.com/iceberg'
--     CATALOG_API_TYPE = AWS_GLUE
--     CATALOG_NAME = '913524911227'
--   )
--   REST_AUTHENTICATION = (
--     TYPE = SIGV4
--     SIGV4_IAM_ROLE = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
--     SIGV4_SIGNING_REGION = 'us-east-1'
--   )
--   ENABLED = TRUE;
--
-- DESCRIBE CATALOG INTEGRATION dmichalk_glue_iceberg_rest_int;
--
-- CREATE OR REPLACE DATABASE dmichalk_glue_iceberg_cld
--   LINKED_CATALOG = (
--     CATALOG = dmichalk_glue_iceberg_rest_int
--     ALLOWED_NAMESPACES = ('dmichalk_sandbox_db')
--   )
--   EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
--   CATALOG_CASE_SENSITIVITY = CASE_INSENSITIVE;
--
-- SELECT SYSTEM$CATALOG_LINK_STATUS('dmichalk_glue_iceberg_cld');
-- SELECT * FROM dmichalk_glue_iceberg_cld.dmichalk_sandbox_db.orders LIMIT 10;


-- ═══════════════════════════════════════════════════════════════════════════════
-- DEMO: ICEBERG PERFORMANCE — HEAD TO HEAD vs EXTERNAL TABLES
-- ═══════════════════════════════════════════════════════════════════════════════
-- Run 01_external_tables.sql first to create the external tables.
-- All queries compare the same 1M rows across all three access methods.
--
-- Data characteristics (important for understanding the tests):
--   - amount correlated with year: 2022=$5-50, 2023=$20-100, 2024=$50-180, 2025=$100-250
--   - discount: NULL 100% months 1-3, ~70% NULL months 4-6, ~50% NULL 7-9, ~30% NULL 10-12
--   - Sorted by (order_year, order_month, customer_id) → non-overlapping row groups
--   - 48 partitions: 4 years × 12 months

USE SCHEMA dmichalk_glue_db.glue_tables;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;


-- ─────────────────────────────────────────────────────────────────────────────
-- TEST 1: PARTITION PRUNING
-- ─────────────────────────────────────────────────────────────────────────────
-- PRESENTER: "Give me June 2024." Check query profiles:
--   Flat external    → 48 files scanned
--   Partitioned ext  → 1 file scanned
--   Iceberg          → 1 file scanned (manifest-level pruning)

SELECT COUNT(*), SUM(amount) FROM orders_external_flat
 WHERE order_date LIKE '2024-06%';

SELECT COUNT(*), SUM(amount) FROM orders_external_partitioned
 WHERE order_year = 2024 AND order_month = 6;

SELECT COUNT(*), SUM(amount) FROM orders_iceberg
 WHERE order_year = 2024 AND order_month = 6;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;


-- ─────────────────────────────────────────────────────────────────────────────
-- TEST 2: ROW-GROUP STATISTICS (Iceberg's secret weapon)
-- ─────────────────────────────────────────────────────────────────────────────
-- PRESENTER: Filters on non-partition columns. External tables read every row
-- in every file. Iceberg checks row-group footer min/max and NULL counts,
-- skipping groups where the predicate can't be satisfied.

-- 2a: amount > 200 — only 2025 data can have amount > 200
-- Iceberg skips ALL 2022-2024 partitions (max amount in those years < 200).
-- External tables read everything regardless.
SELECT COUNT(*), SUM(amount) FROM orders_external_flat WHERE amount > 200;
SELECT COUNT(*), SUM(amount) FROM orders_external_partitioned WHERE amount > 200;
SELECT COUNT(*), SUM(amount) FROM orders_iceberg WHERE amount > 200;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;

-- 2b: discount IS NOT NULL — Q1 months are 100% NULL
-- Iceberg skips row groups where null_count = row_count (all Q1 partitions).
-- External tables scan everything and discard NULLs after the fact.
SELECT COUNT(*), SUM(discount) FROM orders_external_flat WHERE discount IS NOT NULL;
SELECT COUNT(*), SUM(discount) FROM orders_external_partitioned WHERE discount IS NOT NULL;
SELECT COUNT(*), SUM(discount) FROM orders_iceberg WHERE discount IS NOT NULL;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;


-- ─────────────────────────────────────────────────────────────────────────────
-- TEST 3: CUSTOMER_ID POINT LOOKUP (sorted-data row-group skipping)
-- ─────────────────────────────────────────────────────────────────────────────
-- PRESENTER: customer_id is sorted within each partition, so row groups have
-- tight, non-overlapping min/max ranges for customer_id.
-- Iceberg: prunes to 2024 (partition), then skips row groups where
--   min(customer_id) > 42 OR max(customer_id) < 42.
-- Partitioned ext: prunes to 2024 files but reads all rows in those files.
-- Flat ext: scans everything.

SELECT COUNT(*), SUM(amount) FROM orders_external_flat
 WHERE customer_id = 42 AND order_year = 2024;

SELECT COUNT(*), SUM(amount) FROM orders_external_partitioned
 WHERE customer_id = 42 AND order_year = 2024;

SELECT COUNT(*), SUM(amount) FROM orders_iceberg
 WHERE customer_id = 42 AND order_year = 2024;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;


-- ─────────────────────────────────────────────────────────────────────────────
-- TEST 4: THE MONEY SHOT — ALL OPTIMIZATIONS COMBINED
-- ─────────────────────────────────────────────────────────────────────────────
-- PRESENTER: This query combines every advantage at once:
--   1. Partition pruning: order_year=2025 AND order_month=3 → 1 of 48 partitions
--   2. Row-group stats on amount: skip groups where max(amount) <= 200
--   3. NULL skipping on discount: month 3 is 100% NULL for discount
--      → Iceberg sees null_count = row_count in the manifest and returns 0 rows
--         INSTANTLY without reading any data at all.
-- External flat: scans all 48 files, all rows, all columns.
-- External partitioned: prunes to 1 file but still reads everything in it.
-- Iceberg: prunes to 1 partition, then sees discount is 100% NULL → 0 rows, near-zero I/O.

SELECT order_id, product, amount, discount FROM orders_external_flat
 WHERE order_year = 2025 AND order_month = 3 AND amount > 200 AND discount IS NOT NULL;

SELECT order_id, product, amount, discount FROM orders_external_partitioned
 WHERE order_year = 2025 AND order_month = 3 AND amount > 200 AND discount IS NOT NULL;

SELECT order_id, product, amount, discount FROM orders_iceberg
 WHERE order_year = 2025 AND order_month = 3 AND amount > 200 AND discount IS NOT NULL;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;


-- ─────────────────────────────────────────────────────────────────────────────
-- TEST 5: FULL SCAN AGGREGATION
-- ─────────────────────────────────────────────────────────────────────────────
-- PRESENTER: Even scanning all data, Iceberg reads native typed columns.
-- External tables do JSON-like extraction per row (value:col::TYPE).

SELECT order_year, order_month, customer_tier,
       COUNT(*) AS orders, SUM(amount) AS revenue, AVG(amount) AS avg_order,
       SUM(discount) AS total_discount
  FROM orders_external_flat GROUP BY 1,2,3;

SELECT order_year, order_month, customer_tier,
       COUNT(*) AS orders, SUM(amount) AS revenue, AVG(amount) AS avg_order,
       SUM(discount) AS total_discount
  FROM orders_external_partitioned GROUP BY 1,2,3;

SELECT order_year, order_month, customer_tier,
       COUNT(*) AS orders, SUM(amount) AS revenue, AVG(amount) AS avg_order,
       SUM(discount) AS total_discount
  FROM orders_iceberg GROUP BY 1,2,3;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;


-- ═══════════════════════════════════════════════════════════════════════════════
-- SUMMARY
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- ┌─────────────────────────┬──────────────────┬──────────────────┬──────────────────┐
-- │ Feature                 │ External Flat    │ External Part.   │ Iceberg          │
-- ├─────────────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ Partition pruning       │ ✗ scans all 48   │ ✓ prunes to 1    │ ✓ prunes to 1    │
-- │ Row-group min/max stats │ ✗ reads all rows │ ✗ reads all rows │ ✓ skips groups   │
-- │ NULL count skipping     │ ✗ reads all rows │ ✗ reads all rows │ ✓ skips all-NULL │
-- │ Sorted-key skipping     │ ✗ reads all rows │ ✗ reads all rows │ ✓ tight ranges   │
-- │ Column pruning          │ ✗ full VARIANT   │ ✗ full VARIANT   │ ✓ named columns  │
-- │ Native typed reads      │ ✗ value:col cast │ ✗ value:col cast │ ✓ direct Parquet │
-- │ Schema evolution        │ ✗ manual         │ ✗ manual         │ ✓ Iceberg spec   │
-- │ Time travel             │ ✗ none           │ ✗ none           │ ✓ snapshots      │
-- └─────────────────────────┴──────────────────┴──────────────────┴──────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────────────────┐
-- │ Test Highlights (clustered data)                                                   │
-- ├───────────────────────────────┬─────────────────────────────────────────────────────┤
-- │ amount > 200                  │ Iceberg skips all 2022-2024 (max < 200)            │
-- │ discount IS NOT NULL          │ Iceberg skips Q1 groups (100% NULL)                │
-- │ customer_id = 42 (2024)       │ Iceberg skips groups via sorted min/max            │
-- │ 2025/03 + amount>200 + disc.  │ Iceberg: 0 rows (month 3 discount 100% NULL)       │
-- └───────────────────────────────┴─────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────┬──────────────┬─────────────────────────────┐
-- │ Additional Tech                 │ Status       │ What it adds                │
-- ├─────────────────────────────────┼──────────────┼─────────────────────────────┤
-- │ Iceberg CLD (Glue REST)         │ GA (LF req.) │ Auto-discover Iceberg tables│
-- │ Hive Direct CLD (FORMAT=HIVE)   │ Priv. Preview│ Auto-discover Hive tables   │
-- │ Parquet Direct (FORMAT=NONE)    │ Priv. Preview│ No catalog, auto-refresh    │
-- └─────────────────────────────────┴──────────────┴─────────────────────────────┘
