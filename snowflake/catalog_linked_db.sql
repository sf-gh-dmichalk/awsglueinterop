-- =============================================================================
-- Catalog-Linked Database via Glue Iceberg REST
-- Status: GA feature — blocked by Lake Formation admin permissions on 913524911227
-- Ask cshimmin or sf-afe-skumar to grant LF table permissions to the IAM role
-- =============================================================================

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE CATALOG INTEGRATION dmichalk_glue_iceberg_rest_int
  CATALOG_SOURCE = ICEBERG_REST
  TABLE_FORMAT = ICEBERG
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db'
  REST_CONFIG = (
    CATALOG_URI = 'https://glue.us-east-1.amazonaws.com/iceberg'
    CATALOG_API_TYPE = AWS_GLUE
    CATALOG_NAME = '913524911227'
  )
  REST_AUTHENTICATION = (
    TYPE = SIGV4
    SIGV4_IAM_ROLE = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
    SIGV4_SIGNING_REGION = 'us-east-1'
  )
  ENABLED = TRUE;

DESCRIBE CATALOG INTEGRATION dmichalk_glue_iceberg_rest_int;

CREATE OR REPLACE DATABASE dmichalk_glue_catalog_db
  LINKED_CATALOG = (
    CATALOG = 'dmichalk_glue_iceberg_rest_int'
    ALLOWED_NAMESPACES = ('dmichalk_sandbox_db')
  )
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG_CASE_SENSITIVITY = CASE_INSENSITIVE;

-- Verify
SHOW SCHEMAS IN DATABASE dmichalk_glue_catalog_db;
SHOW TABLES IN dmichalk_glue_catalog_db.dmichalk_sandbox_db;
SELECT * FROM dmichalk_glue_catalog_db.dmichalk_sandbox_db.orders LIMIT 10;
