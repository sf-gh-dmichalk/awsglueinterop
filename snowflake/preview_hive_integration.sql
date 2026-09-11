-- =============================================================================
-- Preview: Hive Catalog Integration (TABLE_FORMAT = HIVE)
-- Status: PRIVATE PREVIEW — not enabled on FXC11617
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE SCHEMA dmichalk_glue_db.glue_tables;

CREATE OR REPLACE CATALOG INTEGRATION dmichalk_glue_hive_int
  CATALOG_SOURCE = GLUE
  TABLE_FORMAT = HIVE
  GLUE_CATALOG_ID = '913524911227'
  GLUE_AWS_ROLE_ARN = 'arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access'
  GLUE_REGION = 'us-east-1'
  ENABLED = TRUE;

DESCRIBE CATALOG INTEGRATION dmichalk_glue_hive_int;

-- Same 1M orders, read as Hive/Parquet via Glue metadata
CREATE OR REPLACE ICEBERG TABLE orders_hive
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_glue_hive_int'
  CATALOG_TABLE_NAME = 'orders'
  CATALOG_NAMESPACE = 'dmichalk_sandbox_db';

SELECT COUNT(*) AS row_count FROM orders_hive;
SELECT * FROM orders_hive WHERE order_year = 2024 AND order_month = 6 LIMIT 10;
