-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  2. PARQUET DIRECT (TABLE_FORMAT = NONE)                  PRIVATE PREVIEW ║
-- ║  Region: us-east-1 | AWS: 913524911227 | Snowflake: FXC11617             ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- Approach: Object Store catalog integration with TABLE_FORMAT = NONE.
-- Queries Parquet files directly from S3 — no Glue metadata needed.
-- Gets Iceberg-grade performance: auto-refresh, hive-style partitioning,
-- native columnar reads, row-group stats.
--
-- STATUS: Private Preview — not enabled on FXC11617.
-- Uncomment all statements when preview is activated.
--
-- Also includes: Hive Direct Catalog-Linked Database (TABLE_FORMAT = HIVE)
-- which auto-discovers Glue Hive tables as a read-only CLD.


-- ═══════════════════════════════════════════════════════════════════════════════
-- SETUP A: PARQUET DIRECT (no Glue needed)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Requires external volume from 03_iceberg.sql (dmichalk_glue_ext_vol)

USE ROLE ACCOUNTADMIN;
USE SCHEMA dmichalk_glue_db.glue_tables;

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


-- ═══════════════════════════════════════════════════════════════════════════════
-- SETUP B: HIVE DIRECT CATALOG-LINKED DATABASE
-- ═══════════════════════════════════════════════════════════════════════════════
-- Auto-discovers Hive/Parquet tables from Glue. Read-only.
-- Glue table: dmichalk_sandbox_db.orders_hive (48 hive partitions, 1M rows)
-- Two paths: vended credentials (recommended) or external volume.
--
-- STATUS: Private Preview — not enabled on FXC11617.
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
-- -- Record GLUE_AWS_IAM_USER_ARN + SIGV4_EXTERNAL_ID → update IAM trust policy
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


-- ═══════════════════════════════════════════════════════════════════════════════
-- DEMO: PARQUET DIRECT
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: Same Parquet files as external tables, but now with Iceberg-grade
-- performance. No Glue catalog needed — just point at S3.

-- ALTER SESSION SET USE_CACHED_RESULT = FALSE;
--
-- -- Verify
-- SELECT COUNT(*) AS row_count FROM orders_parquet_direct;
--
-- -- Partition pruning — should behave like Iceberg, not external tables
-- SELECT COUNT(*), SUM(amount) FROM orders_parquet_direct
--  WHERE order_year = 2024 AND order_month = 6;
--
-- -- Row-group stats — should skip groups where max(amount) <= 240
-- SELECT COUNT(*), SUM(amount) FROM orders_parquet_direct WHERE amount > 240;
--
-- -- Column pruning — should read only the amount column
-- SELECT SUM(amount) FROM orders_parquet_direct WHERE order_year = 2024;
--
-- SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
--   FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
--  WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
--  ORDER BY start_time DESC LIMIT 3;


-- ═══════════════════════════════════════════════════════════════════════════════
-- DEMO: HIVE DIRECT CLD
-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESENTER: Tables auto-discovered from Glue — no manual CREATE TABLE.
-- Read-only access to Hive/Parquet data with Iceberg-grade performance.

-- SELECT SYSTEM$CATALOG_LINK_STATUS('dmichalk_glue_hive_cld');
-- SHOW TABLES IN dmichalk_glue_hive_cld.dmichalk_sandbox_db;
--
-- -- Query the auto-discovered Hive table
-- SELECT * FROM dmichalk_glue_hive_cld.dmichalk_sandbox_db.orders_hive LIMIT 10;
--
-- -- Same perf tests
-- SELECT COUNT(*), SUM(amount) FROM dmichalk_glue_hive_cld.dmichalk_sandbox_db.orders_hive
--  WHERE order_year = 2024 AND order_month = 6;
--
-- SELECT COUNT(*), SUM(amount) FROM dmichalk_glue_hive_cld.dmichalk_sandbox_db.orders_hive
--  WHERE amount > 240;
