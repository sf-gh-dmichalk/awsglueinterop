-- =============================================================================
-- Preview: Parquet Direct (TABLE_FORMAT = NONE)
-- Status: PRIVATE PREVIEW — not enabled on FXC11617
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE SCHEMA dmichalk_glue_db.glue_tables;

CREATE OR REPLACE CATALOG INTEGRATION dmichalk_parquet_direct_int
  CATALOG_SOURCE = OBJECT_STORE
  TABLE_FORMAT = NONE
  ENABLED = TRUE;

CREATE OR REPLACE ICEBERG TABLE orders_parquet_direct
  EXTERNAL_VOLUME = 'dmichalk_glue_ext_vol'
  CATALOG = 'dmichalk_parquet_direct_int'
  BASE_LOCATION = 'data/parquet/orders/'
  AUTO_REFRESH = TRUE;

SELECT COUNT(*) AS row_count FROM orders_parquet_direct;
SELECT * FROM orders_parquet_direct WHERE order_year = 2024 AND order_month = 6 LIMIT 10;
