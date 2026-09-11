-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  2. PARQUET DIRECT + HIVE DIRECT                                          ║
-- ║  Region: us-east-1 | AWS: 913524911227 | Snowflake: FXC11617             ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- Two approaches for querying Parquet files with Iceberg-grade performance:
--
-- A. PARQUET DIRECT (TABLE_FORMAT = HIVE) ← ENABLED on this account
--    Object Store catalog integration. No Glue metadata needed.
--    Auto-infers schema + hive-style partitions from S3 file structure.
--    Same row-group stats, column pruning, partition pruning as Iceberg.
--
-- B. HIVE DIRECT CATALOG-LINKED DATABASE ← Private Preview, not yet enabled
--    Auto-discovers Hive/Parquet tables from Glue. Read-only CLD.


-- ═══════════════════════════════════════════════════════════════════════════════
-- SETUP A: PARQUET DIRECT                                          ✅ WORKING
-- ═══════════════════════════════════════════════════════════════════════════════
-- Requires external volume from 03_iceberg.sql (dmichalk_glue_ext_vol)

USE ROLE ACCOUNTADMIN;
USE SCHEMA dmichalk_glue_db.glue_tables;

-- Catalog integration: TABLE_FORMAT = HIVE auto-infers partition columns
-- from hive-style paths (order_year=YYYY/order_month=MM/)
CREATE OR REPLACE CATALOG INTEGRATION dmichalk_parquet_hive_int
  CATALOG_SOURCE = OBJECT_STORE
  TABLE_FORMAT = HIVE
  ENABLED = TRUE;

-- Iceberg table: schema + partitions inferred from Parquet files
CREATE OR REPLACE ICEBERG TABLE orders_parquet_direct
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_parquet_hive_int'
  BASE_LOCATION = 'data/parquet/orders/'
  ENABLE_SCHEMA_INFERENCE = TRUE
  ENABLE_SCHEMA_EVOLUTION = TRUE
  AUTO_REFRESH = FALSE;

-- Verify schema was inferred correctly
DESCRIBE ICEBERG TABLE orders_parquet_direct;
SELECT COUNT(*) AS row_count FROM orders_parquet_direct;


-- ═══════════════════════════════════════════════════════════════════════════════
-- SETUP B: HIVE DIRECT CLD                                  [PP - NOT ENABLED]
-- ═══════════════════════════════════════════════════════════════════════════════
-- Auto-discovers Hive/Parquet tables from Glue. Read-only.
-- Glue table: dmichalk_sandbox_db.orders_hive (48 hive partitions, 1M rows)
-- Ref: docs.snowflake.com/en/LIMITEDACCESS/iceberg/tutorials/
--      tables-hive-direct-set-up-catalog-linked-database

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
--
-- CREATE OR REPLACE DATABASE dmichalk_glue_hive_cld
--   LINKED_CATALOG = (
--     CATALOG = dmichalk_hive_direct_int
--     ALLOWED_NAMESPACES = ('dmichalk_sandbox_db')
--     ALLOWED_WRITE_OPERATIONS = NONE
--   );

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
-- CREATE OR REPLACE DATABASE dmichalk_glue_hive_cld
--   LINKED_CATALOG = (
--     CATALOG = dmichalk_hive_direct_extv_int
--     ALLOWED_NAMESPACES = ('dmichalk_sandbox_db')
--     ALLOWED_WRITE_OPERATIONS = NONE
--   )
--   EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol';


-- ═══════════════════════════════════════════════════════════════════════════════
-- DEMO: PARQUET DIRECT — SAME PERF AS ICEBERG, NO CATALOG NEEDED
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: Same Parquet files as external tables, but Snowflake builds
-- Iceberg metadata internally. Gets all the optimizations: partition pruning,
-- row-group stats, column pruning, null count stats. No Glue required.

ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Verify: 1M rows, same data as all other tables
SELECT COUNT(*) AS row_count FROM orders_parquet_direct;

-- TEST 1: Partition pruning — prunes to 1 of 48 partitions
SELECT COUNT(*), SUM(amount) FROM orders_parquet_direct
 WHERE order_year = 2024 AND order_month = 6;

-- TEST 2: Row-group stats — amount > 200 only exists in 2025 ($100-250)
-- Parquet Direct skips all 2022-2024 row groups via min/max stats
SELECT COUNT(*), SUM(amount) FROM orders_parquet_direct WHERE amount > 200;

-- TEST 3: NULL stats — discount is 100% NULL in months 1-3
-- Parquet Direct skips Q1 partitions entirely via null count metadata
SELECT COUNT(*), SUM(discount) FROM orders_parquet_direct WHERE discount IS NOT NULL;

-- TEST 4: Sorted key lookup — customer_id sorted within partitions
-- Skips row groups where min(customer_id) > 42 or max(customer_id) < 42
SELECT COUNT(*), SUM(amount) FROM orders_parquet_direct
 WHERE customer_id = 42 AND order_year = 2024;

-- TEST 5: Money shot — combines everything
-- Partition prune (month 3) + amount stats (>200) + null stats (discount NOT NULL)
-- Month 3 has 100% NULL discount → returns 0 rows from metadata alone
SELECT order_id, product, amount, discount FROM orders_parquet_direct
 WHERE order_year = 2025 AND order_month = 3 AND amount > 200 AND discount IS NOT NULL;

-- Compare Parquet Direct vs External Tables vs Iceberg on the same query
SELECT 'parquet_direct' AS source, COUNT(*), SUM(amount) FROM orders_parquet_direct WHERE amount > 200
UNION ALL
SELECT 'iceberg', COUNT(*), SUM(amount) FROM orders_iceberg WHERE amount > 200
UNION ALL
SELECT 'ext_flat', COUNT(*), SUM(amount) FROM orders_external_flat WHERE amount > 200
UNION ALL
SELECT 'ext_partitioned', COUNT(*), SUM(amount) FROM orders_external_partitioned WHERE amount > 200;


-- ═══════════════════════════════════════════════════════════════════════════════
-- DEMO: HIVE DIRECT CLD                                     [PP - NOT ENABLED]
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: Tables auto-discovered from Glue — no manual CREATE TABLE.
-- Read-only access to Hive/Parquet data with Iceberg-grade performance.

-- SELECT SYSTEM$CATALOG_LINK_STATUS('dmichalk_glue_hive_cld');
-- SHOW TABLES IN dmichalk_glue_hive_cld.dmichalk_sandbox_db;
-- SELECT * FROM dmichalk_glue_hive_cld.dmichalk_sandbox_db.orders_hive LIMIT 10;
-- SELECT COUNT(*), SUM(amount) FROM dmichalk_glue_hive_cld.dmichalk_sandbox_db.orders_hive
--  WHERE order_year = 2024 AND order_month = 6;


-- ═══════════════════════════════════════════════════════════════════════════════
-- PARQUET DIRECT vs EXTERNAL TABLES — KEY DIFFERENCE
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- Both read the SAME Parquet files from S3. But:
--
-- External tables:          Parquet Direct:
-- ─────────────────         ─────────────────────────────
-- value:col::TYPE           Native typed columns
-- No row-group stats        Reads Parquet footer min/max
-- No null count stats       Tracks null counts per group
-- No column pruning         Reads only projected columns
-- Manual partition wiring   Auto-infers hive partitions
-- Per-file refresh charge   Serverless refresh, no per-file cost
-- No schema evolution       Auto-evolves on refresh
--
-- Parquet Direct is essentially "Iceberg-grade access to raw Parquet."
-- Same performance as a Glue-backed Iceberg table, but no catalog needed.
