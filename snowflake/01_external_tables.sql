-- ╔══════════════════════════════════════════════════════════════════════════════╗
-- ║  1. EXTERNAL TABLES (Parquet on S3 via Stage)                             ║
-- ║  Region: us-east-1 | AWS: 913524911227 | Snowflake: FXC11617             ║
-- ╚══════════════════════════════════════════════════════════════════════════════╝
--
-- Approach: Storage integration → S3 stage → external tables over Parquet.
-- Same 1M orders as the Iceberg table, read through semi-structured access.
-- Two variants: flat (no pruning) and partitioned (hive-path pruning).


-- ═══════════════════════════════════════════════════════════════════════════════
-- SETUP
-- ═══════════════════════════════════════════════════════════════════════════════

USE ROLE ACCOUNTADMIN;
CREATE DATABASE IF NOT EXISTS dmichalk_glue_db;
CREATE SCHEMA IF NOT EXISTS dmichalk_glue_db.glue_tables;

-- Storage Integration
CREATE OR REPLACE STORAGE INTEGRATION dmichalk_s3_integration
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
  ENABLED = TRUE
  STORAGE_ALLOWED_LOCATIONS = ('s3://dmichalk-glue-sandbox/');

DESCRIBE STORAGE INTEGRATION dmichalk_s3_integration;
-- Record STORAGE_AWS_EXTERNAL_ID → add to terraform.tfvars → terraform apply

-- Stage
CREATE OR REPLACE STAGE dmichalk_glue_db.glue_tables.dmichalk_s3_stage
  URL = 's3://dmichalk-glue-sandbox/'
  STORAGE_INTEGRATION = dmichalk_s3_integration;

-- Verify files visible
LIST @dmichalk_glue_db.glue_tables.dmichalk_s3_stage/data/parquet/orders/ PATTERN='.*parquet';

-- External Table: FLAT (no partition columns — scans all 48 files every query)
CREATE OR REPLACE EXTERNAL TABLE dmichalk_glue_db.glue_tables.orders_external_flat
  (
    order_id      INT    AS (value:order_id::INT),
    customer_id   INT    AS (value:customer_id::INT),
    product       STRING AS (value:product::STRING),
    amount        DOUBLE AS (value:amount::DOUBLE),
    customer_tier STRING AS (value:customer_tier::STRING),
    order_date    STRING AS (value:order_date::STRING)
  )
  WITH LOCATION = @dmichalk_glue_db.glue_tables.dmichalk_s3_stage/data/parquet/orders/
  FILE_FORMAT = (TYPE = PARQUET)
  AUTO_REFRESH = FALSE;

-- External Table: PARTITIONED (derives year/month from hive-style file paths)
CREATE OR REPLACE EXTERNAL TABLE dmichalk_glue_db.glue_tables.orders_external_partitioned
  (
    order_year    INT    AS (SPLIT_PART(SPLIT_PART(metadata$filename, 'order_year=', 2), '/', 1)::INT),
    order_month   INT    AS (SPLIT_PART(SPLIT_PART(metadata$filename, 'order_month=', 2), '/', 1)::INT),
    order_id      INT    AS (value:order_id::INT),
    customer_id   INT    AS (value:customer_id::INT),
    product       STRING AS (value:product::STRING),
    amount        DOUBLE AS (value:amount::DOUBLE),
    customer_tier STRING AS (value:customer_tier::STRING),
    order_date    STRING AS (value:order_date::STRING)
  )
  PARTITION BY (order_year, order_month)
  WITH LOCATION = @dmichalk_glue_db.glue_tables.dmichalk_s3_stage/data/parquet/orders/
  FILE_FORMAT = (TYPE = PARQUET)
  AUTO_REFRESH = FALSE;

-- Verify
SELECT 'flat' AS variant, COUNT(*) AS row_count FROM dmichalk_glue_db.glue_tables.orders_external_flat
UNION ALL
SELECT 'partitioned', COUNT(*) FROM dmichalk_glue_db.glue_tables.orders_external_partitioned;


-- ═══════════════════════════════════════════════════════════════════════════════
-- DEMO: EXTERNAL TABLE BEHAVIOR
-- ═══════════════════════════════════════════════════════════════════════════════

USE SCHEMA dmichalk_glue_db.glue_tables;
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- DEMO 1: Flat table — no partition pruning
-- PRESENTER: Open query profile. Check "Partitions scanned" = all files.
-- The WHERE clause filters AFTER reading every file.
SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_flat
 WHERE order_date LIKE '2024-06%';

-- DEMO 2: Partitioned table — hive-path pruning works
-- PRESENTER: Same query but using partition columns. Check profile: 1 file scanned.
SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_partitioned
 WHERE order_year = 2024 AND order_month = 6;

-- DEMO 3: Limitation — no row-group stats even with partitions
-- PRESENTER: Filter on amount (not a partition col). Both variants scan all rows.
-- External tables ignore Parquet footer min/max statistics entirely.
SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_flat
 WHERE amount > 240;

SELECT COUNT(*) AS cnt, SUM(amount) AS total
  FROM orders_external_partitioned
 WHERE amount > 240;

-- Compare bytes
SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 4;

-- DEMO 4: Limitation — semi-structured column access
-- PRESENTER: Even SELECT SUM(amount) reads the entire row as VARIANT,
-- then extracts amount. There's no columnar projection at the storage layer.
SELECT SUM(amount) AS total_revenue
  FROM orders_external_flat;

SELECT SUM(amount) AS total_revenue
  FROM orders_external_partitioned;

SELECT query_text, bytes_scanned, rows_produced, total_elapsed_time
  FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 10))
 WHERE query_text NOT LIKE '%QUERY_HISTORY%' AND query_text NOT LIKE '%ALTER%'
 ORDER BY start_time DESC LIMIT 2;

-- ┌───────────────────────┬──────────────────┬──────────────────────┐
-- │ Limitation            │ Flat External    │ Partitioned External │
-- ├───────────────────────┼──────────────────┼──────────────────────┤
-- │ Partition pruning     │ ✗ none           │ ✓ hive path only     │
-- │ Row-group stats       │ ✗ ignored        │ ✗ ignored            │
-- │ Column pruning        │ ✗ full VARIANT   │ ✗ full VARIANT       │
-- │ Predicate pushdown    │ ✗ none           │ ✗ none               │
-- └───────────────────────┴──────────────────┴──────────────────────┘
