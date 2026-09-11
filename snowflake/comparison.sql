-- =============================================================================
-- Performance Comparison: External Table vs Iceberg
--
-- Run these queries and compare query profiles in Snowsight.
-- Key metrics to observe:
--   - Partitions scanned vs total (Iceberg prunes, external flat doesn't)
--   - Bytes scanned (Iceberg reads far less data)
--   - Files scanned
--   - Query duration
--
-- Dataset: ~1M orders, partitioned by order_year (2022-2025) / order_month (01-12)
--          = 48 partitions, ~20K rows each
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE SCHEMA dmichalk_glue_db.glue_tables;
USE WAREHOUSE COMPUTE_WH;

-- =============================================================================
-- TEST 1: Point query on a single month
--         Iceberg: reads 1/48 partitions. External flat: reads all 48.
-- =============================================================================

-- 1a. External table (no partitions) — full scan
SELECT COUNT(*), SUM(amount), AVG(amount)
  FROM orders_external_flat
  WHERE order_date LIKE '2024-06%';
-- Check query profile: scans ALL files (no partition awareness)

-- 1b. External table (with partitions) — partition-pruned
SELECT COUNT(*), SUM(amount), AVG(amount)
  FROM orders_external_partitioned
  WHERE order_year = 2024 AND order_month = 6;
-- Check query profile: scans 1 partition file, but still opens remote S3 per-row

-- 1c. Iceberg table — partition-pruned + Parquet stats + columnar pushdown
SELECT COUNT(*), SUM(amount), AVG(amount)
  FROM orders_iceberg_partitioned
  WHERE order_year = 2024 AND order_month = 6;
-- Check query profile: scans 1 partition, uses Parquet row-group stats,
-- predicate pushdown, and Snowflake's optimized Iceberg reader

-- =============================================================================
-- TEST 2: Range query across 6 months
--         Iceberg prunes to 6/48. External flat scans all.
-- =============================================================================

-- 2a. External flat — full scan
SELECT customer_tier, COUNT(*) AS orders, SUM(amount) AS revenue
  FROM orders_external_flat
  WHERE order_date >= '2024-01-01' AND order_date < '2024-07-01'
  GROUP BY customer_tier
  ORDER BY revenue DESC;

-- 2b. External partitioned — 6 partitions
SELECT customer_tier, COUNT(*) AS orders, SUM(amount) AS revenue
  FROM orders_external_partitioned
  WHERE order_year = 2024 AND order_month BETWEEN 1 AND 6
  GROUP BY customer_tier
  ORDER BY revenue DESC;

-- 2c. Iceberg — 6 partitions + stats pruning
SELECT customer_tier, COUNT(*) AS orders, SUM(amount) AS revenue
  FROM orders_iceberg_partitioned
  WHERE order_year = 2024 AND order_month BETWEEN 1 AND 6
  GROUP BY customer_tier
  ORDER BY revenue DESC;

-- =============================================================================
-- TEST 3: Aggregation across full dataset
--         All three scan everything, but Iceberg benefits from column pruning
--         and Parquet statistics (min/max on amount column).
-- =============================================================================

-- 3a. External flat
SELECT order_year, order_month,
       COUNT(*) AS orders,
       ROUND(SUM(amount), 2) AS total_revenue,
       ROUND(AVG(amount), 2) AS avg_order_value
  FROM orders_external_flat
  -- Derive year/month from order_date since flat external table has no partition cols
  CROSS JOIN LATERAL (
    SELECT YEAR(TO_DATE(order_date)) AS order_year,
           MONTH(TO_DATE(order_date)) AS order_month
  )
  GROUP BY order_year, order_month
  ORDER BY order_year, order_month;

-- 3b. External partitioned
SELECT order_year, order_month,
       COUNT(*) AS orders,
       ROUND(SUM(amount), 2) AS total_revenue,
       ROUND(AVG(amount), 2) AS avg_order_value
  FROM orders_external_partitioned
  GROUP BY order_year, order_month
  ORDER BY order_year, order_month;

-- 3c. Iceberg
SELECT order_year, order_month,
       COUNT(*) AS orders,
       ROUND(SUM(amount), 2) AS total_revenue,
       ROUND(AVG(amount), 2) AS avg_order_value
  FROM orders_iceberg_partitioned
  GROUP BY order_year, order_month
  ORDER BY order_year, order_month;

-- =============================================================================
-- TEST 4: Top-N with filter — shows predicate pushdown advantage
--         Iceberg pushes the WHERE + ORDER BY into the Parquet reader.
-- =============================================================================

-- 4a. External flat
SELECT order_id, product, amount, order_date
  FROM orders_external_flat
  WHERE amount > 200
  ORDER BY amount DESC
  LIMIT 20;

-- 4b. External partitioned
SELECT order_id, product, amount, order_date
  FROM orders_external_partitioned
  WHERE amount > 200
  ORDER BY amount DESC
  LIMIT 20;

-- 4c. Iceberg — uses Parquet min/max stats to skip row groups where max(amount) <= 200
SELECT order_id, product, amount, order_date
  FROM orders_iceberg_partitioned
  WHERE amount > 200
  ORDER BY amount DESC
  LIMIT 20;

-- =============================================================================
-- SUMMARY: What to compare in query profiles
-- =============================================================================
--
-- | Metric              | Ext Flat     | Ext Partitioned | Iceberg        |
-- |---------------------|--------------|-----------------|----------------|
-- | Partition pruning   | None         | Path-based      | Spec-based     |
-- | Column pruning      | None (VALUE) | None (VALUE)    | Yes (native)   |
-- | Row-group stats     | No           | No              | Yes (min/max)  |
-- | Predicate pushdown  | No           | No              | Yes            |
-- | Data format         | Semi-struct  | Semi-struct     | Native Parquet |
-- | Schema evolution    | Manual       | Manual          | Iceberg spec   |
-- | Time travel         | No           | No              | Yes (snapshots)|
--
-- External tables parse Parquet as semi-structured (value:col::TYPE), so
-- every column access is a JSON-like extraction. Iceberg tables read
-- Parquet natively with full columnar projection.
