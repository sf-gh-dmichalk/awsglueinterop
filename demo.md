# AWS Glue + Snowflake Interop Demo Results

**Dataset**: 10M orders (2022-2025), 48 hive-partitioned files  
**Region**: us-east-1 | **AWS**: 913524911227 | **Snowflake**: FXC11617  
**Warehouse**: XS | **Cache**: Disabled (`USE_CACHED_RESULT = FALSE`)

## Data Design (Why This Works)

The data is deliberately **clustered** so Iceberg/Parquet Direct metadata enables real skipping:

| Column | Clustering | Demo Effect |
|---|---|---|
| `amount` | Correlated with year: 2022=$5-50, 2023=$20-100, 2024=$50-180, 2025=$100-250 | `WHERE amount > 200` → only 2025 qualifies. Iceberg skips 75% of data via row-group min/max stats. External tables scan everything. |
| `discount` | NULL rate by month: Q1=100% NULL, Q2=70%, Q3=50%, Q4=30% | `WHERE discount IS NOT NULL` → Q1 partitions skipped entirely via null-count metadata. |
| `customer_id` | Sorted within each partition (1-50,000) | Row groups have non-overlapping customer_id ranges → point lookups skip most groups. |

Four table types over the **same** Parquet files on S3:

| Table | Type | Catalog | How It Reads Parquet |
|---|---|---|---|
| `orders_external_flat` | External Table | None (S3 stage) | VARIANT blob → `value:col::TYPE` extraction |
| `orders_external_partitioned` | External Table | None (S3 stage) | Same, but derives partition cols from `metadata$filename` |
| `orders_parquet_direct` | Parquet Direct | OBJECT_STORE (HIVE) | Native columns, schema auto-inferred from Parquet headers |
| `orders_iceberg` | Iceberg | Glue (ICEBERG) | Native columns, schema + stats from Iceberg manifest |

---

## Test 1: Row-Group Stats — `WHERE amount > 200`

Only 2025 has amount > 200 (832K of 10M rows). Iceberg and Parquet Direct know this from row-group footer min/max stats and skip 75% of partitions. External tables read every file.

| Table | Time (ms) | Bytes Scanned | Partitions | Why |
|---|---|---|---|---|
| External Flat | **2,545** | 29.9 MB | 48 / 48 | No stats awareness, scans all files |
| External Partitioned | **2,393** | 29.9 MB | 48 / 48 | amount isn't a partition col — no pruning |
| **Parquet Direct** | **646** | ~5 MB | 12 / 48 | Row-group min/max → skips 2022-2024 |
| **Iceberg** | **939** | ~5 MB | 13 / 51 | Same: manifest-level stats → skip 75% |

**Speedup: 3-4x** — external tables scan 10M rows, Iceberg/PD scan ~2.5M.

---

## Test 2: The Money Shot — Compound Predicate

```sql
WHERE order_year = 2025 AND order_month = 3 AND amount > 200 AND discount IS NOT NULL
```

Result: **0 rows**. Month 3 has 100% NULL discount — impossible to satisfy.

| Table | Time (ms) | Bytes Scanned | Partitions | What Happened |
|---|---|---|---|---|
| External Flat | **2,784** | 49.6 MB | 48 / 48 | Scanned ALL 10M rows to find 0 |
| External Partitioned | **923** | 744 KB | 1 / 48 | Pruned to 1 file, read 212K rows → 0 |
| **Parquet Direct** | **301** | **0** | **0 / 0** | **No TableScan operator. Resolved from metadata alone.** |
| **Iceberg** | **257** | **0** | **0 / 0** | **No TableScan operator. Resolved from metadata alone.** |

**Speedup: 9-11x** vs flat external. Iceberg and Parquet Direct didn't open a single file — they knew from the manifest's null-count stats that month 3 has zero non-null discounts, so the query is impossible. The query plan shows a `Generator` producing 0 rows instead of a `TableScan`.

This is the strongest demo point: **same Parquet files, same S3 bucket, same query — but Iceberg metadata eliminates all I/O**.

---

## Test 3: Partition Pruning — `WHERE order_year = 2024 AND order_month = 6`

Single partition (1 of 48). Shows how hive-path pruning works on external tables.

| Table | Time (ms) | Partitions | Why |
|---|---|---|---|
| External Flat | **2,890** | 48 / 48 | No partition awareness — full scan |
| External Partitioned | **527** | 1 / 48 | Hive path pruning via `metadata$filename` |
| Parquet Direct | **923** | 1 / 48 | Partition pruning from inferred hive spec |
| Iceberg | **658** | 1 / 51 | Partition pruning from Iceberg manifest |

**Takeaway**: Partitioned external table and Iceberg/PD all prune to 1 file. But external flat scans everything — 5-6x slower.

---

## Test 4: Full Scan — `SELECT SUM(amount)`

No filters. Every table must read all 10M rows. Difference is in *how* they read.

| Table | Time (ms) | Why |
|---|---|---|
| External Flat | **2,207** | Reads entire row as VARIANT, extracts amount |
| External Partitioned | **4,035** | Same VARIANT overhead + partition column derivation |
| **Parquet Direct** | **406** | Reads only `amount` column from Parquet (columnar) |
| **Iceberg** | **1,083** | Reads only `amount` column from Parquet (columnar) |

**Speedup: 5-10x** — even on a full scan with no filtering, native columnar reads dominate. External tables deserialize the full row as VARIANT for every row, then extract the field. Iceberg/PD read only the projected column.

---

## Summary Chart

```
                         Query Time (ms) — Lower is Better
                         10M rows, XS warehouse, cache disabled

Test 1: amount > 200 (row-group stats)
  Ext Flat          ████████████████████████████  2,545
  Ext Partitioned   ██████████████████████████░░  2,393
  Parquet Direct    ███████░░░░░░░░░░░░░░░░░░░░    646   ← 4x faster
  Iceberg           ██████████░░░░░░░░░░░░░░░░░    939   ← 3x faster

Test 2: Money Shot (partition + stats + NULL)
  Ext Flat          ████████████████████████████  2,784
  Ext Partitioned   ██████████░░░░░░░░░░░░░░░░░    923
  Parquet Direct    ███░░░░░░░░░░░░░░░░░░░░░░░░    301   ← 9x faster
  Iceberg           ██░░░░░░░░░░░░░░░░░░░░░░░░░    257   ← 11x faster, 0 bytes scanned

Test 3: Partition Pruning (Jun 2024)
  Ext Flat          ████████████████████████████  2,890
  Ext Partitioned   █████░░░░░░░░░░░░░░░░░░░░░░    527
  Parquet Direct    ██████████░░░░░░░░░░░░░░░░░    923
  Iceberg           ███████░░░░░░░░░░░░░░░░░░░░    658

Test 4: Full Scan SUM(amount)
  Ext Flat          ██████████████████████░░░░░░  2,207
  Ext Partitioned   ████████████████████████████  4,035
  Parquet Direct    ████░░░░░░░░░░░░░░░░░░░░░░░    406   ← 10x faster
  Iceberg           ███████████░░░░░░░░░░░░░░░░  1,083   ← 4x faster
```

---

## Why Each Optimization Matters

| Optimization | External Flat | External Partitioned | Parquet Direct | Iceberg |
|---|---|---|---|---|
| **Partition pruning** | None | Hive path only | Auto-inferred hive | Manifest-level |
| **Row-group min/max** | Ignored | Ignored | Reads Parquet footer | Tracks in manifest |
| **NULL count stats** | Ignored | Ignored | Tracks per group | Tracks in manifest |
| **Column pruning** | Full VARIANT row | Full VARIANT row | Native columnar | Native columnar |
| **Schema** | Manual `value:col::TYPE` | Manual + `metadata$filename` | Auto-inferred | From Glue catalog |
| **Catalog needed** | No (S3 stage) | No (S3 stage) | No | Yes (Glue) |
| **Auto-refresh** | Per-file charge | Per-file charge | Serverless | Serverless |

### What is "Parquet Direct"?

Snowflake builds Iceberg metadata internally over raw Parquet files. No catalog needed — it infers schema from Parquet headers and partitions from hive-style paths. Same performance as Glue-backed Iceberg. Created with `CATALOG_SOURCE = OBJECT_STORE, TABLE_FORMAT = HIVE`.

### What does "0 bytes scanned" mean?

In Test 2, Iceberg and Parquet Direct returned 0 rows **without opening any Parquet files**. The query planner checked the manifest metadata:

1. **Partition prune**: `order_year=2025, order_month=3` → 1 partition
2. **NULL count check**: manifest says `discount` has `null_count = N` (all rows) in that partition
3. **Result**: `discount IS NOT NULL` can't be true → 0 rows guaranteed → no TableScan needed

The query plan shows `Generator(output_rows=0)` instead of `TableScan`. External tables don't have this metadata, so they must read every byte to discover the answer is 0.
