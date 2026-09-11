-- =============================================================================
-- External Tables + Iceberg table on the same 1M-row partitioned dataset
--
-- Dataset: 1M orders, hive-partitioned by order_year/order_month (48 partitions)
-- S3 path: s3://dmichalk-glue-sandbox/data/partitioned/orders/
--          order_year=YYYY/order_month=MM/data.parquet
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- 1. Storage Integration + Stage
-- -----------------------------------------------------------------------------
CREATE OR REPLACE STORAGE INTEGRATION dmichalk_s3_integration
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
  ENABLED = TRUE
  STORAGE_ALLOWED_LOCATIONS = ('s3://dmichalk-glue-sandbox/');

-- Get IAM user ARN + external ID, add to terraform.tfvars, re-apply:
DESCRIBE STORAGE INTEGRATION dmichalk_s3_integration;

CREATE OR REPLACE STAGE dmichalk_glue_db.glue_tables.dmichalk_s3_stage
  URL = 's3://dmichalk-glue-sandbox/'
  STORAGE_INTEGRATION = dmichalk_s3_integration;

-- Verify:
-- LIST @dmichalk_glue_db.glue_tables.dmichalk_s3_stage/data/partitioned/orders/;

-- -----------------------------------------------------------------------------
-- 2. External Table: FLAT (no partition pruning)
--    Scans ALL 48 files for every query regardless of WHERE clause.
--    Reads columns as semi-structured (value:col::TYPE).
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
  WITH LOCATION = @dmichalk_glue_db.glue_tables.dmichalk_s3_stage/data/partitioned/orders/
  FILE_FORMAT = (TYPE = PARQUET)
  AUTO_REFRESH = FALSE;

-- -----------------------------------------------------------------------------
-- 3. External Table: PARTITIONED (pruning from hive-style paths)
--    Derives order_year/order_month from metadata$filename.
--    Prunes files when WHERE uses partition columns.
--    Still reads columns as semi-structured.
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
  WITH LOCATION = @dmichalk_glue_db.glue_tables.dmichalk_s3_stage/data/partitioned/orders/
  FILE_FORMAT = (TYPE = PARQUET)
  AUTO_REFRESH = FALSE;

-- -----------------------------------------------------------------------------
-- 4. Iceberg Table: partitioned orders from Glue catalog
--    Iceberg partition spec on order_year + order_month.
--    Native Parquet reader with column pruning, row-group stats, predicate
--    pushdown, and partition pruning — all automatic.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE ICEBERG TABLE dmichalk_glue_db.glue_tables.orders_iceberg_partitioned
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_glue_iceberg_int'
  CATALOG_TABLE_NAME = 'orders_partitioned'
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db';

-- -----------------------------------------------------------------------------
-- 5. Verify row counts (should all be 1,000,000)
-- -----------------------------------------------------------------------------
SELECT 'external_flat' AS source, COUNT(*) AS row_count FROM dmichalk_glue_db.glue_tables.orders_external_flat
UNION ALL
SELECT 'external_partitioned', COUNT(*) FROM dmichalk_glue_db.glue_tables.orders_external_partitioned
UNION ALL
SELECT 'iceberg_partitioned', COUNT(*) FROM dmichalk_glue_db.glue_tables.orders_iceberg_partitioned;
