-- =============================================================================
-- Core Setup: External Volume, Catalog Integration, Iceberg Table, External Tables
-- Region: us-east-1 | AWS Account: 913524911227
-- Dataset: 1M orders (2022-2025), partitioned by order_year/order_month
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- 1. External Volume
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 2. Glue Iceberg Catalog Integration
-- -----------------------------------------------------------------------------
CREATE OR REPLACE CATALOG INTEGRATION dmichalk_glue_iceberg_int
  CATALOG_SOURCE = GLUE
  TABLE_FORMAT = ICEBERG
  GLUE_CATALOG_ID = '913524911227'
  GLUE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
  GLUE_REGION = 'us-east-1'
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db'
  ENABLED = TRUE;

DESCRIBE CATALOG INTEGRATION dmichalk_glue_iceberg_int;

-- -----------------------------------------------------------------------------
-- 3. Storage Integration + Stage (for external tables)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE STORAGE INTEGRATION dmichalk_s3_integration
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
  ENABLED = TRUE
  STORAGE_ALLOWED_LOCATIONS = ('s3://dmichalk-glue-sandbox/');

DESCRIBE STORAGE INTEGRATION dmichalk_s3_integration;

-- -----------------------------------------------------------------------------
-- 4. Database + Schema + Stage
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS dmichalk_glue_db;
CREATE SCHEMA IF NOT EXISTS dmichalk_glue_db.glue_tables;

CREATE OR REPLACE STAGE dmichalk_glue_db.glue_tables.dmichalk_s3_stage
  URL = 's3://dmichalk-glue-sandbox/'
  STORAGE_INTEGRATION = dmichalk_s3_integration;

-- -----------------------------------------------------------------------------
-- 5. Iceberg Table (from Glue catalog — same 1M rows)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE ICEBERG TABLE dmichalk_glue_db.glue_tables.orders_iceberg
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_glue_iceberg_int'
  CATALOG_TABLE_NAME = 'orders'
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db';

-- -----------------------------------------------------------------------------
-- 6. External Table: FLAT (no partition pruning — same 1M rows)
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 7. External Table: PARTITIONED (hive-style path pruning — same 1M rows)
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 8. Verify — all three should return 1,000,000
-- -----------------------------------------------------------------------------
SELECT 'iceberg' AS source, COUNT(*) AS row_count FROM dmichalk_glue_db.glue_tables.orders_iceberg
UNION ALL
SELECT 'external_flat', COUNT(*) FROM dmichalk_glue_db.glue_tables.orders_external_flat
UNION ALL
SELECT 'external_partitioned', COUNT(*) FROM dmichalk_glue_db.glue_tables.orders_external_partitioned;
