-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  3. ICEBERG (via Glue Catalog Integration + Catalog-Linked Database)      ║
-- ║  Region: us-east-1 | AWS: 913524911227 | Snowflake: FXC11617             ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- Approach: External volume + Glue catalog integration → Iceberg table.
-- Same 1M orders, but Iceberg metadata gives Snowflake:
--   - Partition pruning from manifest (not file paths)
--   - Row-group min/max stats → skip groups that can't match predicate
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
-- PRESENTER: Filter on amount, NOT a partition column. External tables read
-- every row in every file. Iceberg checks row-group footer min/max and skips
-- groups where the predicate can't be satisfied.
--
-- amount > 240 hits ~4% of rows. Even the partitioned external table reads
-- ALL files because the filter isn't on a partition column.

SELECT COUNT(*), SUM(amount) FROM orders_external_flat WHERE amount > 240;
SELECT COUNT(*), SUM(amount) FROM orders_external_partitioned WHERE amount > 240;
SELECT COUNT(*), SUM(amount) FROM orders_iceberg WHERE amount > 240;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;

-- Narrow range: amount BETWEEN 100 AND 110 (~4% of rows)
-- Iceberg skips groups where min(amount) > 110 OR max(amount) < 100.

SELECT COUNT(*), SUM(amount) FROM orders_external_flat WHERE amount BETWEEN 100 AND 110;
SELECT COUNT(*), SUM(amount) FROM orders_external_partitioned WHERE amount BETWEEN 100 AND 110;
SELECT COUNT(*), SUM(amount) FROM orders_iceberg WHERE amount BETWEEN 100 AND 110;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;


-- ─────────────────────────────────────────────────────────────────────────────
-- TEST 3: COLUMN PRUNING (semi-structured vs native columnar)
-- ─────────────────────────────────────────────────────────────────────────────
-- PRESENTER: SELECT SUM(amount) only needs 1 column. Iceberg reads just that
-- column from Parquet. External tables read the full row as VARIANT then
-- extract the field — no columnar projection at the storage layer.

SELECT SUM(amount) FROM orders_external_flat WHERE order_year = 2024;
SELECT SUM(amount) FROM orders_external_partitioned WHERE order_year = 2024;
SELECT SUM(amount) FROM orders_iceberg WHERE order_year = 2024;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;


-- ─────────────────────────────────────────────────────────────────────────────
-- TEST 4: THE MONEY SHOT — ALL THREE OPTIMIZATIONS COMBINED
-- ─────────────────────────────────────────────────────────────────────────────
-- PRESENTER: Partition pruning + row-group stats + column pruning in one query.
-- Iceberg: 1 partition, skips groups where max(amount)<=200, reads 3 columns.
-- Flat external: 48 files, all rows, all columns. Potentially 50-100x gap.

SELECT order_id, product, amount FROM orders_external_flat
 WHERE order_year = 2025 AND order_month = 3 AND amount > 200;

SELECT order_id, product, amount FROM orders_external_partitioned
 WHERE order_year = 2025 AND order_month = 3 AND amount > 200;

SELECT order_id, product, amount FROM orders_iceberg
 WHERE order_year = 2025 AND order_month = 3 AND amount > 200;

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
       COUNT(*) AS orders, SUM(amount) AS revenue, AVG(amount) AS avg_order
  FROM orders_external_flat GROUP BY 1,2,3;

SELECT order_year, order_month, customer_tier,
       COUNT(*) AS orders, SUM(amount) AS revenue, AVG(amount) AS avg_order
  FROM orders_external_partitioned GROUP BY 1,2,3;

SELECT order_year, order_month, customer_tier,
       COUNT(*) AS orders, SUM(amount) AS revenue, AVG(amount) AS avg_order
  FROM orders_iceberg GROUP BY 1,2,3;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;


-- ═══════════════════════════════════════════════════════════════════════════════
-- SUMMARY
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- ┌─────────────────────┬──────────────────┬──────────────────┬──────────────────┐
-- │ Feature             │ External Flat    │ External Part.   │ Iceberg          │
-- ├─────────────────────┼──────────────────┼──────────────────┼──────────────────┤
-- │ Partition pruning   │ ✗ scans all 48   │ ✓ prunes to 1    │ ✓ prunes to 1    │
-- │ Row-group stats     │ ✗ reads all rows │ ✗ reads all rows │ ✓ skips groups   │
-- │ Column pruning      │ ✗ full VARIANT   │ ✗ full VARIANT   │ ✓ named columns  │
-- │ Native typed reads  │ ✗ value:col cast │ ✗ value:col cast │ ✓ direct Parquet │
-- │ Schema evolution    │ ✗ manual         │ ✗ manual         │ ✓ Iceberg spec   │
-- │ Time travel         │ ✗ none           │ ✗ none           │ ✓ snapshots      │
-- └─────────────────────┴──────────────────┴──────────────────┴──────────────────┘
--
-- ┌─────────────────────────────────┬──────────────┬─────────────────────────────┐
-- │ Additional Tech                 │ Status       │ What it adds                │
-- ├─────────────────────────────────┼──────────────┼─────────────────────────────┤
-- │ Iceberg CLD (Glue REST)         │ GA (LF req.) │ Auto-discover Iceberg tables│
-- │ Hive Direct CLD (FORMAT=HIVE)   │ Priv. Preview│ Auto-discover Hive tables   │
-- │ Parquet Direct (FORMAT=NONE)    │ Priv. Preview│ No catalog, auto-refresh    │
-- └─────────────────────────────────┴──────────────┴─────────────────────────────┘
