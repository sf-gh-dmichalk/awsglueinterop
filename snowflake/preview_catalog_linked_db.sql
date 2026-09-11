-- =============================================================================
-- Preview SQL: Catalog-Linked Database (Glue Iceberg REST)
-- Status: BLOCKED — requires Lake Formation admin on AWS account 913524911227
-- Ask cshimmin or sf-afe-skumar to grant LF table permissions to
-- arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access
--
-- What it does:
--   Auto-discovers and syncs all Iceberg tables from a Glue database into
--   Snowflake as a catalog-linked database. No manual table creation needed.
--
-- How it works:
--   1. Catalog Integration with CATALOG_SOURCE = ICEBERG_REST pointing at
--      the Glue Iceberg REST endpoint (SigV4 auth)
--   2. CREATE DATABASE ... LINKED_CATALOG auto-syncs namespaces and tables
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- Uses the same external volume already created:
--   DMICHALK_GLUE_EXT_VOL -> s3://dmichalk-glue-sandbox/

-- -----------------------------------------------------------------------------
-- 1. Glue Iceberg REST Catalog Integration
-- -----------------------------------------------------------------------------
CREATE OR REPLACE CATALOG INTEGRATION dmichalk_glue_iceberg_rest_int
  CATALOG_SOURCE = ICEBERG_REST
  TABLE_FORMAT = ICEBERG
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db'
  REST_CONFIG = (
    CATALOG_URI = 'https://glue.us-west-2.amazonaws.com/iceberg'
    CATALOG_API_TYPE = AWS_GLUE
    CATALOG_NAME = '913524911227'
  )
  REST_AUTHENTICATION = (
    TYPE = SIGV4
    SIGV4_IAM_ROLE = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
    SIGV4_SIGNING_REGION = 'us-west-2'
  )
  ENABLED = TRUE;

-- Get the IAM user ARN + external ID, then add to terraform.tfvars and re-apply:
DESCRIBE CATALOG INTEGRATION dmichalk_glue_iceberg_rest_int;

-- -----------------------------------------------------------------------------
-- 2. Catalog-Linked Database
--    Auto-discovers all Iceberg tables in dmichalk_sandbox_db
-- -----------------------------------------------------------------------------
CREATE OR REPLACE DATABASE dmichalk_glue_catalog_db
  LINKED_CATALOG = (
    CATALOG = 'dmichalk_glue_iceberg_rest_int'
    ALLOWED_NAMESPACES = ('dmichalk_sandbox_db')
  )
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG_CASE_SENSITIVITY = CASE_INSENSITIVE;

-- -----------------------------------------------------------------------------
-- 3. Verify
-- -----------------------------------------------------------------------------
SHOW SCHEMAS IN DATABASE dmichalk_glue_catalog_db;
SHOW TABLES IN dmichalk_glue_catalog_db.dmichalk_sandbox_db;
SELECT * FROM dmichalk_glue_catalog_db.dmichalk_sandbox_db.products LIMIT 10;
