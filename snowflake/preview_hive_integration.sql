-- =============================================================================
-- Preview SQL: Hive Catalog Integration (TABLE_FORMAT = HIVE)
-- Status: PRIVATE PREVIEW — not enabled on FXC11617
-- Request enablement from your Snowflake account team.
--
-- What it does:
--   Query Hive/Parquet tables registered in AWS Glue Data Catalog via a Glue
--   catalog integration with TABLE_FORMAT = HIVE.
--
-- How it works:
--   1. Catalog Integration with CATALOG_SOURCE = GLUE, TABLE_FORMAT = HIVE
--   2. Iceberg tables referencing Glue table names + external volume for S3
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- Uses the same external volume already created:
--   DMICHALK_GLUE_EXT_VOL -> s3://dmichalk-glue-sandbox/

-- -----------------------------------------------------------------------------
-- 1. Hive Catalog Integration
-- -----------------------------------------------------------------------------
CREATE OR REPLACE CATALOG INTEGRATION dmichalk_glue_hive_int
  CATALOG_SOURCE = GLUE
  TABLE_FORMAT = HIVE
  GLUE_CATALOG_ID = '913524911227'
  GLUE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
  GLUE_REGION = 'us-west-2'
  ENABLED = TRUE;

-- Get the IAM user ARN + external ID, then add to terraform.tfvars and re-apply:
DESCRIBE CATALOG INTEGRATION dmichalk_glue_hive_int;

-- -----------------------------------------------------------------------------
-- 2. Customers table (Hive via Glue)
--    Reads Glue table: dmichalk_sandbox_db.customers
-- -----------------------------------------------------------------------------
CREATE OR REPLACE ICEBERG TABLE dmichalk_glue_db.glue_tables.customers_hive
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_glue_hive_int'
  CATALOG_TABLE_NAME = 'customers'
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db';

-- -----------------------------------------------------------------------------
-- 3. Orders table (Hive via Glue)
--    Reads Glue table: dmichalk_sandbox_db.orders
-- -----------------------------------------------------------------------------
CREATE OR REPLACE ICEBERG TABLE dmichalk_glue_db.glue_tables.orders_hive
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_glue_hive_int'
  CATALOG_TABLE_NAME = 'orders'
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db';

-- -----------------------------------------------------------------------------
-- 4. Verify
-- -----------------------------------------------------------------------------
SELECT * FROM dmichalk_glue_db.glue_tables.customers_hive LIMIT 10;
SELECT * FROM dmichalk_glue_db.glue_tables.orders_hive LIMIT 10;
