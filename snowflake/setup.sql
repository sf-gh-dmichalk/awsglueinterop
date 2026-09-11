-- =============================================================================
-- Snowflake setup for AWS Glue catalog integration
-- Account: 913524911227 | Region: us-west-2 | Glue DB: dmichalk_sandbox_db
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- 1. External Volume (needed for S3 data access)
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

-- Run this, then update IAM trust policy with the ARN + external ID:
DESCRIBE EXTERNAL VOLUME dmichalk_glue_ext_vol;

-- -----------------------------------------------------------------------------
-- 2. Glue Iceberg Catalog Integration (non-REST, uses IAM directly)
--    Works for Iceberg tables registered in Glue. Bypasses Lake Formation
--    credential vending which requires LF admin access.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE CATALOG INTEGRATION dmichalk_glue_iceberg_int
  CATALOG_SOURCE = GLUE
  TABLE_FORMAT = ICEBERG
  GLUE_CATALOG_ID = '913524911227'
  GLUE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
  GLUE_REGION = 'us-west-2'
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db'
  ENABLED = TRUE;

-- Run this, then update IAM trust policy with the ARN + external ID:
DESCRIBE CATALOG INTEGRATION dmichalk_glue_iceberg_int;

-- -----------------------------------------------------------------------------
-- 3. Iceberg Tables (referencing Glue catalog)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DATABASE dmichalk_glue_db;
CREATE OR REPLACE SCHEMA dmichalk_glue_db.glue_tables;

CREATE OR REPLACE ICEBERG TABLE dmichalk_glue_db.glue_tables.products
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_glue_iceberg_int'
  CATALOG_TABLE_NAME = 'products'
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db';

-- -----------------------------------------------------------------------------
-- 4. Hive Catalog Integration (for Parquet tables)
--    NOTE: TABLE_FORMAT = HIVE is private preview / not enabled on FXC11617.
--    Uncomment when feature is enabled on your account.
-- -----------------------------------------------------------------------------
-- CREATE OR REPLACE CATALOG INTEGRATION dmichalk_glue_hive_int
--   CATALOG_SOURCE = GLUE
--   TABLE_FORMAT = HIVE
--   GLUE_CATALOG_ID = '913524911227'
--   GLUE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
--   ENABLED = TRUE;
--
-- DESCRIBE CATALOG INTEGRATION dmichalk_glue_hive_int;
--
-- CREATE OR REPLACE ICEBERG TABLE dmichalk_glue_db.glue_tables.customers
--   EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
--   CATALOG = 'dmichalk_glue_hive_int'
--   CATALOG_TABLE_NAME = 'customers'
--   CATALOG_NAMESPACE = 'dmichalk_sandbox_db';
--
-- CREATE OR REPLACE ICEBERG TABLE dmichalk_glue_db.glue_tables.orders
--   EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
--   CATALOG = 'dmichalk_glue_hive_int'
--   CATALOG_TABLE_NAME = 'orders'
--   CATALOG_NAMESPACE = 'dmichalk_sandbox_db';

-- -----------------------------------------------------------------------------
-- 5. Iceberg REST Catalog Integration + Catalog-Linked Database
--    NOTE: Requires Lake Formation admin to grant GetTemporaryCredentialsForTableV2.
--    Your SSO role is not an LF admin on 913524911227. Ask cshimmin or sf-afe-skumar
--    (the LF admins) to grant the snowflake-glue-access role LF table permissions,
--    then uncomment this section.
-- -----------------------------------------------------------------------------
-- CREATE OR REPLACE CATALOG INTEGRATION dmichalk_glue_iceberg_rest_int
--   CATALOG_SOURCE = ICEBERG_REST
--   TABLE_FORMAT = ICEBERG
--   CATALOG_NAMESPACE = 'dmichalk_sandbox_db'
--   REST_CONFIG = (
--     CATALOG_URI = 'https://glue.us-west-2.amazonaws.com/iceberg'
--     CATALOG_API_TYPE = AWS_GLUE
--     CATALOG_NAME = '913524911227'
--   )
--   REST_AUTHENTICATION = (
--     TYPE = SIGV4
--     SIGV4_IAM_ROLE = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
--     SIGV4_SIGNING_REGION = 'us-west-2'
--   )
--   ENABLED = TRUE;
--
-- DESCRIBE CATALOG INTEGRATION dmichalk_glue_iceberg_rest_int;
--
-- CREATE OR REPLACE DATABASE dmichalk_glue_catalog_db
--   LINKED_CATALOG = (
--     CATALOG = 'dmichalk_glue_iceberg_rest_int'
--     ALLOWED_NAMESPACES = ('dmichalk_sandbox_db')
--   )
--   EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
--   CATALOG_CASE_SENSITIVITY = CASE_INSENSITIVE;

-- -----------------------------------------------------------------------------
-- 6. Verify
-- -----------------------------------------------------------------------------
SELECT * FROM dmichalk_glue_db.glue_tables.products LIMIT 10;
