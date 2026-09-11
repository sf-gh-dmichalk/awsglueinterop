-- =============================================================================
-- Snowflake setup for AWS Glue catalog integration
-- Account: 913524911227 | Region: us-west-2 | Glue DB: chewy_sandbox_db
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- 1. External Volume (needed for S3 data access)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE EXTERNAL VOLUME chewy_glue_ext_vol
  STORAGE_LOCATIONS = (
    (
      NAME = 'chewy-s3'
      STORAGE_BASE_URL = 's3://chewy-glue-sandbox-913524911227/'
      STORAGE_PROVIDER = 'S3'
      STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/snowflake-glue-access'
    )
  );

-- Run this, then update IAM trust policy with the ARN + external ID:
DESCRIBE EXTERNAL VOLUME chewy_glue_ext_vol;

-- -----------------------------------------------------------------------------
-- 2. Hive Catalog Integration (for Parquet tables)
--    NOTE: TABLE_FORMAT = HIVE is private preview. If not enabled on your
--    account, skip this section and use the Iceberg REST path for everything.
-- -----------------------------------------------------------------------------
-- CREATE OR REPLACE CATALOG INTEGRATION glue_hive_int
--   CATALOG_SOURCE = GLUE
--   TABLE_FORMAT = HIVE
--   GLUE_CATALOG_ID = '913524911227'
--   GLUE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/snowflake-glue-access'
--   ENABLED = TRUE;
--
-- DESCRIBE CATALOG INTEGRATION glue_hive_int;
--
-- CREATE OR REPLACE ICEBERG TABLE customers
--   EXTERNAL_VOLUME = 'chewy_glue_ext_vol'
--   CATALOG = 'glue_hive_int'
--   CATALOG_TABLE_NAME = 'customers'
--   CATALOG_NAMESPACE = 'chewy_sandbox_db';
--
-- CREATE OR REPLACE ICEBERG TABLE orders
--   EXTERNAL_VOLUME = 'chewy_glue_ext_vol'
--   CATALOG = 'glue_hive_int'
--   CATALOG_TABLE_NAME = 'orders'
--   CATALOG_NAMESPACE = 'chewy_sandbox_db';

-- -----------------------------------------------------------------------------
-- 3. Iceberg REST Catalog Integration (for Iceberg tables + catalog-linked DB)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE CATALOG INTEGRATION glue_iceberg_rest_int
  CATALOG_SOURCE = ICEBERG_REST
  TABLE_FORMAT = ICEBERG
  CATALOG_NAMESPACE = 'chewy_sandbox_db'
  REST_CONFIG = (
    CATALOG_URI = 'https://glue.us-west-2.amazonaws.com/iceberg'
    CATALOG_API_TYPE = AWS_GLUE
    CATALOG_NAME = '913524911227'
  )
  REST_AUTHENTICATION = (
    TYPE = SIGV4
    SIGV4_IAM_ROLE = 'arn:aws:iam::913524911227:role/snowflake-glue-access'
    SIGV4_SIGNING_REGION = 'us-west-2'
  )
  ENABLED = TRUE;

-- Run this, then update IAM trust policy with the ARN + external ID:
DESCRIBE CATALOG INTEGRATION glue_iceberg_rest_int;

-- -----------------------------------------------------------------------------
-- 4. Catalog-Linked Database (auto-discovers Iceberg tables from Glue)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DATABASE chewy_glue_catalog_db
  LINKED_CATALOG = (
    CATALOG = 'glue_iceberg_rest_int'
    ALLOWED_NAMESPACES = ('chewy_sandbox_db')
  )
  CATALOG_CASE_SENSITIVITY = CASE_INSENSITIVE;

-- -----------------------------------------------------------------------------
-- 5. Verify
-- -----------------------------------------------------------------------------
-- After trust policy is updated, the Iceberg "products" table should appear:
-- SHOW SCHEMAS IN DATABASE chewy_glue_catalog_db;
-- SHOW TABLES IN chewy_glue_catalog_db.chewy_sandbox_db;
-- SELECT * FROM chewy_glue_catalog_db.chewy_sandbox_db.products LIMIT 10;
