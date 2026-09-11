-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  AWS GLUE + SNOWFLAKE INTEROP DEMO                                        ║
-- ║  1M Orders — External Tables vs Iceberg vs Preview Tech                   ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- Region: us-east-1 | AWS Account: 913524911227 | Snowflake: FXC11617
-- Dataset: 1M orders, 48 monthly partitions (~20K rows each)
--          amount range 5.99-249.99, customer_tier: bronze/silver/gold/platinum
--
-- Three tables, same data, different access methods:
--   orders_external_flat         — External table, no partition awareness
--   orders_external_partitioned  — External table, hive-style partition paths
--   orders_iceberg               — Iceberg table via Glue catalog, partitioned

USE DATABASE dmichalk_glue_db;
USE SCHEMA glue_tables;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;  -- force fresh reads for fair comparison


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  SECTION 1: EXTERNAL TABLES (Parquet on S3)                               ║
-- ╠══════════════════════════════════════════════════════════════════════════════╣
-- ║  Shows how external tables work and their limitations:                     ║
-- ║  - Semi-structured column access (value:col::TYPE)                        ║
-- ║  - No Parquet row-group stats usage                                       ║
-- ║  - Partition pruning only if hive paths are explicitly wired up           ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- Verify row counts
SELECT 'external_flat' AS table_type, COUNT(*) AS row_count FROM orders_external_flat
UNION ALL
SELECT 'external_partitioned', COUNT(*) FROM orders_external_partitioned
UNION ALL
SELECT 'iceberg', COUNT(*) FROM orders_iceberg;

-- Quick look at the data
SELECT * FROM orders_external_flat LIMIT 5;

-- DEMO: Flat external table — scans ALL 48 files regardless of filter
SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_flat
 WHERE order_date LIKE '2024-06%';

-- DEMO: Partitioned external table — prunes to 1 file via hive path
SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_partitioned
 WHERE order_year = 2024 AND order_month = 6;


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  SECTION 2: ICEBERG TABLE (via Glue Catalog Integration)                  ║
-- ╠══════════════════════════════════════════════════════════════════════════════╣
-- ║  Same data, but Iceberg metadata gives Snowflake:                         ║
-- ║  - Partition pruning from manifest (not file paths)                       ║
-- ║  - Row-group min/max stats → skip groups that can't match predicate       ║
-- ║  - Native columnar reads → only reads projected columns from Parquet      ║
-- ║  - Predicate pushdown into the Parquet reader                             ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- Same query, Iceberg table — prunes partition + uses stats
SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_iceberg
 WHERE order_year = 2024 AND order_month = 6;


-- ═══════════════════════════════════════════════════════════════════════════════
-- PERF TEST 1: PARTITION PRUNING GAP
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: Open query profiles side by side. Check "Partitions scanned"
-- and "Files scanned". Flat = 48 files, Partitioned = 1, Iceberg = 1.

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


-- ═══════════════════════════════════════════════════════════════════════════════
-- PERF TEST 2: ROW-GROUP STATISTICS (Iceberg's secret weapon)
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: Filter on amount, NOT a partition column. External tables must
-- read every row. Iceberg checks row-group footer min/max and skips groups
-- where the predicate can't be satisfied.
--
-- amount > 240 hits ~4% of rows. amount BETWEEN 100 AND 110 hits ~4%.

-- Highly selective: amount > 240
SELECT COUNT(*), SUM(amount) FROM orders_external_flat WHERE amount > 240;
SELECT COUNT(*), SUM(amount) FROM orders_external_partitioned WHERE amount > 240;
SELECT COUNT(*), SUM(amount) FROM orders_iceberg WHERE amount > 240;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;

-- Narrow range: amount BETWEEN 100 AND 110
SELECT COUNT(*), SUM(amount) FROM orders_external_flat WHERE amount BETWEEN 100 AND 110;
SELECT COUNT(*), SUM(amount) FROM orders_external_partitioned WHERE amount BETWEEN 100 AND 110;
SELECT COUNT(*), SUM(amount) FROM orders_iceberg WHERE amount BETWEEN 100 AND 110;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;


-- ═══════════════════════════════════════════════════════════════════════════════
-- PERF TEST 3: COLUMN PRUNING (semi-structured vs native)
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: SELECT SUM(amount) only needs 1 column. Iceberg reads just that
-- column from Parquet. External tables deserialize the full row (VARIANT).

SELECT SUM(amount) FROM orders_external_flat WHERE order_year = 2024;
SELECT SUM(amount) FROM orders_external_partitioned WHERE order_year = 2024;
SELECT SUM(amount) FROM orders_iceberg WHERE order_year = 2024;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 3;


-- ═══════════════════════════════════════════════════════════════════════════════
-- PERF TEST 4: THE MONEY SHOT — ALL THREE OPTIMIZATIONS COMBINED
-- ═══════════════════════════════════════════════════════════════════════════════
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


-- ═══════════════════════════════════════════════════════════════════════════════
-- PERF TEST 5: FULL SCAN AGGREGATION
-- ═══════════════════════════════════════════════════════════════════════════════
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


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  SECTION 3: ICEBERG CATALOG-LINKED DATABASE (Glue Iceberg REST)      [GA] ║
-- ╠══════════════════════════════════════════════════════════════════════════════╣
-- ║  Auto-discovers Iceberg tables from Glue via the Iceberg REST endpoint.   ║
-- ║  No manual CREATE TABLE — tables appear automatically.                    ║
-- ║  BLOCKED: needs LF admin to grant GetTemporaryCredentialsForTableV2.      ║
-- ║  Ask cshimmin or sf-afe-skumar (LF admins on 913524911227).               ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

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


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  SECTION 4: HIVE DIRECT CATALOG-LINKED DATABASE              [PP - HIVE]  ║
-- ╠══════════════════════════════════════════════════════════════════════════════╣
-- ║  Auto-discovers Hive/Parquet tables from Glue. Read-only.                 ║
-- ║  Two paths: vended credentials (no ext vol) or external volume.           ║
-- ║  Glue table: dmichalk_sandbox_db.orders_hive (48 hive partitions)         ║
-- ║  PP not enabled on FXC11617.                                              ║
-- ║  Ref: docs.snowflake.com/en/LIMITEDACCESS/iceberg/tutorials/              ║
-- ║       tables-hive-direct-set-up-catalog-linked-database                   ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- Option A: Vended credentials (recommended — no external volume needed)
--
-- CREATE OR REPLACE CATALOG INTEGRATION dmichalk_hive_direct_int
--   CATALOG_SOURCE = GLUE
--   TABLE_FORMAT = HIVE
--   CATALOG_NAMESPACE = 'dmichalk_sandbox_db'
--   REST_CONFIG = (
--     CATALOG_API_TYPE = AWS_GLUE
--     CATALOG_NAME = '913524911227'
--     ACCESS_DELEGATION_MODE = 'VENDED_CREDENTIALS'
--   )
--   REST_AUTHENTICATION = (
--     TYPE = SIGV4
--     SIGV4_IAM_ROLE = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
--     SIGV4_SIGNING_REGION = 'us-east-1'
--   )
--   ENABLED = TRUE;
--
-- DESCRIBE CATALOG INTEGRATION dmichalk_hive_direct_int;
-- -- Record GLUE_AWS_IAM_USER_ARN + SIGV4_EXTERNAL_ID → update IAM trust policy
--
-- CREATE OR REPLACE DATABASE dmichalk_glue_hive_cld
--   LINKED_CATALOG = (
--     CATALOG = dmichalk_hive_direct_int
--     ALLOWED_NAMESPACES = ('dmichalk_sandbox_db')
--     ALLOWED_WRITE_OPERATIONS = NONE
--   );
--
-- SELECT SYSTEM$CATALOG_LINK_STATUS('dmichalk_glue_hive_cld');
-- SELECT * FROM dmichalk_glue_hive_cld.dmichalk_sandbox_db.orders_hive LIMIT 10;

-- Option B: External volume (uses IAM role for S3 access directly)
--
-- CREATE OR REPLACE CATALOG INTEGRATION dmichalk_hive_direct_extv_int
--   CATALOG_SOURCE = GLUE
--   TABLE_FORMAT = HIVE
--   CATALOG_NAMESPACE = 'dmichalk_sandbox_db'
--   GLUE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
--   GLUE_CATALOG_ID = '913524911227'
--   GLUE_REGION = 'us-east-1'
--   ENABLED = TRUE;
--
-- DESCRIBE CATALOG INTEGRATION dmichalk_hive_direct_extv_int;
-- -- Record GLUE_AWS_IAM_USER_ARN + GLUE_AWS_EXTERNAL_ID → update IAM trust policy
--
-- CREATE OR REPLACE DATABASE dmichalk_glue_hive_cld
--   LINKED_CATALOG = (
--     CATALOG = dmichalk_hive_direct_extv_int
--     ALLOWED_NAMESPACES = ('dmichalk_sandbox_db')
--     ALLOWED_WRITE_OPERATIONS = NONE
--   )
--   EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol';
--
-- SELECT SYSTEM$CATALOG_LINK_STATUS('dmichalk_glue_hive_cld');
-- SELECT * FROM dmichalk_glue_hive_cld.dmichalk_sandbox_db.orders_hive LIMIT 10;


-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  SECTION 5: PARQUET DIRECT (TABLE_FORMAT = NONE)         [PP - PARQUET]   ║
-- ╠══════════════════════════════════════════════════════════════════════════════╣
-- ║  Query Parquet files directly from S3 — no Glue metadata needed.          ║
-- ║  Auto-refresh, hive-style partitioning, Iceberg-grade performance.        ║
-- ║  PP not enabled on FXC11617.                                              ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝

-- CREATE OR REPLACE CATALOG INTEGRATION dmichalk_parquet_direct_int
--   CATALOG_SOURCE = OBJECT_STORE
--   TABLE_FORMAT = NONE
--   ENABLED = TRUE;
--
-- CREATE OR REPLACE ICEBERG TABLE orders_parquet_direct
--   EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
--   CATALOG = 'dmichalk_parquet_direct_int'
--   BASE_LOCATION = 'data/parquet/orders/'
--   AUTO_REFRESH = TRUE;
--
-- SELECT * FROM orders_parquet_direct WHERE order_year = 2024 AND order_month = 6 LIMIT 10;


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
-- Upcoming tech (Sections 3-5):
-- ┌─────────────────────────────────┬──────────────┬─────────────────────────────┐
-- │ Tech                            │ Status       │ What it adds                │
-- ├─────────────────────────────────┼──────────────┼─────────────────────────────┤
-- │ Catalog-Linked DB (Glue REST)   │ GA (LF req.) │ Auto-discover tables        │
-- │ Parquet Direct (FORMAT=NONE)    │ Priv. Preview│ No catalog, auto-refresh    │
-- │ Hive Integration (FORMAT=HIVE)  │ Priv. Preview│ Glue Hive metadata support  │
-- └─────────────────────────────────┴──────────────┴─────────────────────────────┘
