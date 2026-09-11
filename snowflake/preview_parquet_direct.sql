-- =============================================================================
-- Preview SQL: Parquet Direct (TABLE_FORMAT = NONE)
-- Status: PRIVATE PREVIEW — not enabled on FXC11617
-- Request enablement from your Snowflake account team.
--
-- What it does:
--   Query Parquet files in S3 directly without Glue metadata, with auto-refresh,
--   hive-style partitioning support, and Iceberg-grade query performance.
--
-- How it works:
--   1. Catalog Integration with CATALOG_SOURCE = OBJECT_STORE, TABLE_FORMAT = NONE
--   2. Iceberg table pointed at the S3 Parquet directory with AUTO_REFRESH = TRUE
--
-- Reference: Parquet Direct slide (Private Preview, 2025)
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- Uses the same external volume already created:
--   DMICHALK_GLUE_EXT_VOL -> s3://dmichalk-glue-sandbox/

-- -----------------------------------------------------------------------------
-- 1. Parquet Direct Catalog Integration
-- -----------------------------------------------------------------------------
CREATE OR REPLACE CATALOG INTEGRATION dmichalk_parquet_direct_int
  CATALOG_SOURCE = OBJECT_STORE
  TABLE_FORMAT = NONE
  ENABLED = TRUE;

-- -----------------------------------------------------------------------------
-- 2. Customers table (Parquet Direct)
--    Points at: s3://dmichalk-glue-sandbox/data/hive/customers/
-- -----------------------------------------------------------------------------
CREATE OR REPLACE ICEBERG TABLE dmichalk_glue_db.glue_tables.customers_parquet_direct
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_parquet_direct_int'
  BASE_LOCATION = 'data/hive/customers/'
  AUTO_REFRESH = TRUE;

-- -----------------------------------------------------------------------------
-- 3. Orders table (Parquet Direct)
--    Points at: s3://dmichalk-glue-sandbox/data/hive/orders/
-- -----------------------------------------------------------------------------
CREATE OR REPLACE ICEBERG TABLE dmichalk_glue_db.glue_tables.orders_parquet_direct
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_parquet_direct_int'
  BASE_LOCATION = 'data/hive/orders/'
  AUTO_REFRESH = TRUE;

-- -----------------------------------------------------------------------------
-- 4. Verify
-- -----------------------------------------------------------------------------
SELECT * FROM dmichalk_glue_db.glue_tables.customers_parquet_direct LIMIT 10;
SELECT * FROM dmichalk_glue_db.glue_tables.orders_parquet_direct LIMIT 10;
