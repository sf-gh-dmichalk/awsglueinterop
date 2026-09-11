# AWS Glue + Snowflake Catalog Integration

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          AWS Account 913524911227                           │
│                               (us-west-2)                                  │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  S3: dmichalk-glue-sandbox                                          │   │
│  │                                                                      │   │
│  │  data/hive/customers/data.parquet ◄──┐                              │   │
│  │  data/hive/orders/data.parquet    ◄──┤  Parquet files               │   │
│  │                                      │  (Hive SerDe format)         │   │
│  │  data/iceberg/products/           ◄──┤                              │   │
│  │    ├── data/*.parquet                │  Iceberg table               │   │
│  │    └── metadata/*.json,*.avro        │  (metadata + data files)     │   │
│  └──────────────────────────────────────┴──────────────────────────────┘   │
│           ▲                                          ▲                      │
│           │ s3:GetObject/PutObject/ListBucket        │                      │
│           │                                          │                      │
│  ┌────────┴──────────────────────────────────────────┴─────────────────┐   │
│  │  IAM Role: dmichalk-snowflake-glue-access                           │   │
│  │                                                                      │   │
│  │  Policies:                   Trust Policy:                          │   │
│  │  ├─ glue-catalog-access      Snowflake IAM user                    │   │
│  │  ├─ s3-data-access           arn:aws:iam::877013879214:user/...    │   │
│  │  └─ lakeformation-access     + 3 external IDs (ext vol, catalog    │   │
│  │                                int, REST int)                       │   │
│  └────────┬──────────────────────────────────────────┬─────────────────┘   │
│           │ glue:GetTable/GetTables/...              │                      │
│           ▼                                          │                      │
│  ┌───────────────────────────────────────────┐       │                      │
│  │  Glue Data Catalog                        │       │                      │
│  │  Database: dmichalk_sandbox_db            │       │                      │
│  │                                           │       │                      │
│  │  ┌─────────────┐  ┌─────────────┐        │       │                      │
│  │  │ customers   │  │ orders      │        │       │                      │
│  │  │ (Hive/Prqt) │  │ (Hive/Prqt) │        │       │                      │
│  │  │ 100 rows    │  │ 500 rows    │        │       │                      │
│  │  └─────────────┘  └─────────────┘        │       │                      │
│  │  ┌─────────────┐                         │       │                      │
│  │  │ products    │                         │       │                      │
│  │  │ (Iceberg)   │                         │       │                      │
│  │  │ 50 rows     │                         │       │                      │
│  │  └─────────────┘                         │       │                      │
│  └───────────────────────────────────────────┘       │                      │
│           ▲                                          │                      │
│  ┌────────┴──────────────────────────────────────────┘                      │
│  │  Lake Formation                                                          │
│  │  ├─ S3 location registered                                              │
│  │  ├─ DB-level grants to IAM role (DESCRIBE, ALTER, CREATE_TABLE, DROP)   │
│  │  └─ IAM_ALLOWED_PRINCIPALS = ALL (table access via IAM policies)        │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
           │
           │  sts:AssumeRole (with ExternalId)
           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Snowflake Account FXC11617                              │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  External Volume: DMICHALK_GLUE_EXT_VOL                             │   │
│  │  └─ Storage: s3://dmichalk-glue-sandbox/                            │   │
│  │     └─ Role: dmichalk-snowflake-glue-access                         │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                          │                                                  │
│                          ▼                                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Catalog Integration: DMICHALK_GLUE_ICEBERG_INT          ✅ WORKING │   │
│  │  └─ CATALOG_SOURCE = GLUE, TABLE_FORMAT = ICEBERG                   │   │
│  │     └─ Glue DB: dmichalk_sandbox_db (us-west-2)                     │   │
│  └──────────┬───────────────────────────────────────────────────────────┘   │
│             │                                                               │
│             ▼                                                               │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Database: DMICHALK_GLUE_DB                                         │   │
│  │  Schema:   GLUE_TABLES                                              │   │
│  │                                                                      │   │
│  │  ┌──────────────────────────────────────┐                           │   │
│  │  │ PRODUCTS (Iceberg table)  ✅ WORKING │                           │   │
│  │  │ 50 rows from Glue products           │                           │   │
│  │  │ SELECT * FROM ...products LIMIT 10;  │                           │   │
│  │  └──────────────────────────────────────┘                           │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  BLOCKED — Hive Catalog Integration               ⛔ PRIVATE PREVIEW │   │
│  │  TABLE_FORMAT = HIVE not enabled on FXC11617                        │   │
│  │  Would expose: customers (100 rows), orders (500 rows)              │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  BLOCKED — Catalog-Linked Database                ⛔ NEEDS LF ADMIN │   │
│  │  Glue REST + LINKED_CATALOG requires                                │   │
│  │  GetTemporaryCredentialsForTableV2 in Lake Formation                │   │
│  │  Ask cshimmin or sf-afe-skumar (LF admins on 913524911227)          │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Asset Inventory

### AWS Resources (Terraform-managed)

| Resource | Name / ID | File |
|---|---|---|
| S3 Bucket | `dmichalk-glue-sandbox` | `terraform/s3.tf` |
| S3 Versioning | Enabled | `terraform/s3.tf` |
| S3 Public Access Block | All blocked | `terraform/s3.tf` |
| Glue Database | `dmichalk_sandbox_db` | `terraform/glue.tf` |
| Glue Table | `customers` (Hive/Parquet, 100 rows) | `terraform/glue.tf` |
| Glue Table | `orders` (Hive/Parquet, 500 rows) | `terraform/glue.tf` |
| Glue Table | `products` (Iceberg, 50 rows) | created by `scripts/generate_data.py` |
| Glue Table | `orders_partitioned` (Iceberg, 1M rows, partitioned by year/month) | created by `scripts/generate_perf_data.py` |
| IAM Role | `dmichalk-snowflake-glue-access` | `terraform/iam.tf` |
| IAM Policy | `glue-catalog-access` (inline) | `terraform/iam.tf` |
| IAM Policy | `s3-data-access` (inline) | `terraform/iam.tf` |
| IAM Policy | `lakeformation-get-data-access` (inline) | `terraform/iam.tf` |
| LF Resource | S3 bucket registered | `terraform/lakeformation.tf` |
| LF Permissions | DB-level grants to IAM role | `terraform/lakeformation.tf` |

### S3 Data Layout

```
dmichalk-glue-sandbox/
├── data/
│   ├── hive/
│   │   ├── customers/
│   │   │   └── data.parquet                 (4 KB, 100 rows)
│   │   └── orders/
│   │       └── data.parquet                 (11 KB, 500 rows)
│   ├── partitioned/
│   │   └── orders/                          (17 MB total, 1M rows)
│   │       ├── order_year=2022/
│   │       │   ├── order_month=01/data.parquet
│   │       │   ├── order_month=02/data.parquet
│   │       │   └── ... (12 months)
│   │       ├── order_year=2023/ ...
│   │       ├── order_year=2024/ ...
│   │       └── order_year=2025/ ...         (48 partition files total)
│   └── iceberg/
│       ├── products/                        (3 KB, 50 rows)
│       │   ├── data/*.parquet
│       │   └── metadata/*.json,*.avro
│       └── orders_partitioned/              (32 MB, 1M rows)
│           ├── data/*.parquet               (partitioned by year/month)
│           └── metadata/*.json,*.avro
```

### Snowflake Objects

| Object | Name | Status |
|---|---|---|
| External Volume | `DMICHALK_GLUE_EXT_VOL` | ✅ Active |
| Storage Integration | `DMICHALK_S3_INTEGRATION` (for external tables/stage) | ✅ Active |
| Stage | `DMICHALK_GLUE_DB.GLUE_TABLES.DMICHALK_S3_STAGE` | ✅ Active |
| Catalog Integration | `DMICHALK_GLUE_ICEBERG_INT` (GLUE, TABLE_FORMAT=ICEBERG) | ✅ Active |
| Catalog Integration | `DMICHALK_GLUE_ICEBERG_REST_INT` (ICEBERG_REST) | ✅ Created, blocked by LF |
| Database | `DMICHALK_GLUE_DB` | ✅ Active |
| Schema | `DMICHALK_GLUE_DB.GLUE_TABLES` | ✅ Active |
| Iceberg Table | `GLUE_TABLES.PRODUCTS` | ✅ Queryable (50 rows) |
| Iceberg Table | `GLUE_TABLES.ORDERS_ICEBERG_PARTITIONED` | ✅ Queryable (1M rows, partitioned) |
| External Table | `GLUE_TABLES.ORDERS_EXTERNAL_FLAT` | ✅ Queryable (1M rows, no pruning) |
| External Table | `GLUE_TABLES.ORDERS_EXTERNAL_PARTITIONED` | ✅ Queryable (1M rows, path-based pruning) |

### Glue Table Schemas

**customers** (Hive/Parquet)
| Column | Type |
|---|---|
| customer_id | int |
| name | string |
| email | string |
| signup_date | string |
| tier | string (bronze/silver/gold/platinum) |

**orders** (Hive/Parquet)
| Column | Type |
|---|---|
| order_id | int |
| customer_id | int |
| product | string |
| amount | double |
| order_date | string |

**products** (Iceberg)
| Column | Type |
|---|---|
| product_id | int |
| name | string |
| category | string (food/toys/beds/accessories/health/grooming) |
| price | double |
| in_stock | boolean |

**orders_partitioned** (Iceberg, 1M rows — perf comparison dataset)
| Column | Type | Notes |
|---|---|---|
| order_id | int | |
| customer_id | int | 1-50,000 |
| product | string | 30 product SKUs |
| amount | double | 5.99-249.99 |
| customer_tier | string | bronze/silver/gold/platinum |
| order_date | string | 2022-01-01 to 2025-12-31 |
| order_year | int | Partition key |
| order_month | int | Partition key |

---

## Performance Comparison: External Tables vs Iceberg

The 1M-row `orders_partitioned` dataset exists in three forms for comparison:

| Table | Type | Partition Pruning | Column Pruning | Row-group Stats | Predicate Pushdown |
|---|---|---|---|---|---|
| `orders_external_flat` | External Table | None — scans all 48 files | No (semi-structured) | No | No |
| `orders_external_partitioned` | External Table | Path-based (year/month from filename) | No (semi-structured) | No | No |
| `orders_iceberg_partitioned` | Iceberg Table | Spec-based (year/month) | Yes (native Parquet) | Yes (min/max) | Yes |

### Why Iceberg is faster

1. **Partition pruning**: `WHERE order_year = 2024 AND order_month = 6` reads 1 of 48 partitions. The flat external table reads all 48.
2. **Native columnar reads**: External tables parse Parquet as semi-structured (`value:col::TYPE`), requiring JSON-like extraction per row. Iceberg reads Parquet columns natively — direct memory mapping.
3. **Row-group statistics**: Iceberg uses Parquet footer min/max stats to skip row groups. `WHERE amount > 200` skips groups where `max(amount) <= 200`. External tables can't do this.
4. **Predicate pushdown**: Iceberg pushes filters into the Parquet reader. External tables apply filters after full extraction.

### How to run the comparison

See `snowflake/comparison.sql` for 4 test queries with instructions on what to observe in query profiles. Run each test's three variants (flat, partitioned ext, Iceberg) and compare:
- **Partitions/files scanned** in the query profile
- **Bytes scanned**
- **Query duration**

---

## How It Works

### Working Path: Glue (non-REST) Iceberg Integration

1. **Snowflake** assumes the `dmichalk-snowflake-glue-access` IAM role via `sts:AssumeRole` using the external ID from the catalog integration
2. **Catalog Integration** (`DMICHALK_GLUE_ICEBERG_INT`) calls the Glue Data Catalog API (`glue:GetTable`) to read the Iceberg table metadata (table location, current snapshot, schema)
3. **External Volume** (`DMICHALK_GLUE_EXT_VOL`) provides S3 credentials via the same IAM role to read the actual Iceberg data files (Parquet) and metadata files (Avro manifests, JSON metadata) from `s3://dmichalk-glue-sandbox/data/iceberg/products/`
4. **Snowflake Iceberg Table** (`PRODUCTS`) materializes the result — you query it like any Snowflake table

### Blocked Path 1: Hive Parquet Tables

The `customers` and `orders` tables are registered in Glue as Hive-format external tables backed by Parquet files. To expose these in Snowflake requires `TABLE_FORMAT = HIVE` on the catalog integration, which is a **private preview feature not enabled on account FXC11617**.

**Action:** Request enablement from your Snowflake account team, then uncomment section 4 in `snowflake/setup.sql`.

### Blocked Path 2: Catalog-Linked Database (Glue REST)

A catalog-linked database auto-discovers and syncs all tables from a remote Iceberg REST catalog into Snowflake. The Glue Iceberg REST endpoint (`https://glue.us-west-2.amazonaws.com/iceberg`) requires Lake Formation to vend temporary credentials via `GetTemporaryCredentialsForTableV2`. Your SSO role (`Contributor`) is not a Lake Formation admin.

**Action:** Ask **cshimmin** or **sf-afe-skumar** (the LF admins on 913524911227) to grant `SELECT` and `DESCRIBE` table permissions to `arn:aws:iam::913524911227:role/dmichalk-snowflake-glue-access` on `dmichalk_sandbox_db`, then uncomment section 5 in `snowflake/setup.sql`.

---

## File Structure

```
awsglueinterop/
├── plan.md                          # This file — architecture, assets, diagram
├── .gitignore                       # Excludes .venv, .terraform, tfstate, tfvars
├── terraform/
│   ├── main.tf                      # AWS provider (us-west-2), caller identity
│   ├── variables.tf                 # aws_region, bucket_name, glue_database_name,
│   │                                  snowflake_iam_user_arn, snowflake_external_ids
│   ├── outputs.tf                   # bucket_name/arn, glue_database_name, iam_role_arn
│   ├── s3.tf                        # S3 bucket + versioning + public access block
│   ├── glue.tf                      # Glue DB + customers/orders Hive tables
│   ├── iam.tf                       # IAM role + 3 inline policies + trust policy
│   ├── lakeformation.tf             # LF resource registration + DB grants
│   └── terraform.tfvars.example     # Example variable values
├── scripts/
│   ├── generate_data.py             # Small datasets: Parquet (customers/orders) +
│   │                                  Iceberg (products) via pyarrow/pyiceberg
│   ├── generate_perf_data.py        # 1M-row partitioned orders: hive-style Parquet
│   │                                  (48 files) + partitioned Iceberg table in Glue
│   └── requirements.txt             # pyarrow, boto3, pyiceberg
└── snowflake/
    ├── setup.sql                    # Core: external volume, catalog integration, Iceberg table
    ├── external_tables.sql          # Storage integration, stage, external tables (flat + partitioned)
    ├── comparison.sql               # 4 perf test queries: ext flat vs ext partitioned vs Iceberg
    ├── preview_parquet_direct.sql   # PP: TABLE_FORMAT=NONE (Parquet Direct)
    ├── preview_hive_integration.sql # PP: TABLE_FORMAT=HIVE (Glue Hive tables)
    └── preview_catalog_linked_db.sql # Blocked: Glue REST + catalog-linked DB (needs LF admin)
```

---

## Execution Order

1. **`terraform apply`** — creates S3, Glue DB + Hive tables, IAM role, Lake Formation grants
2. **`python scripts/generate_data.py`** — uploads small Parquet files + Iceberg products table
3. **`python scripts/generate_perf_data.py`** — uploads 1M-row partitioned Parquet + Iceberg orders
4. **Snowflake DDL** (`snowflake/setup.sql`) — creates external volume, catalog integration, Iceberg tables
5. **Snowflake DDL** (`snowflake/external_tables.sql`) — creates storage integration, stage, external tables
6. **`DESCRIBE` integrations** — get Snowflake IAM user ARN + external IDs
7. **Set `snowflake_iam_user_arn` + `snowflake_external_ids` in `terraform.tfvars`**
8. **`terraform apply`** again — updates IAM trust policy with Snowflake identity
9. **Run `snowflake/comparison.sql`** — benchmark external tables vs Iceberg

---

## Trust Policy Bootstrap

The IAM role trust policy requires Snowflake's IAM user ARN and external IDs, but these are only generated after creating the Snowflake integrations. This creates a two-pass workflow:

| Pass | What happens |
|---|---|
| 1st `terraform apply` | IAM role trusts own account (`913524911227:root`) as bootstrap |
| Create Snowflake objects | External volume + catalog integrations generate unique external IDs |
| `DESCRIBE` each | Record `*_IAM_USER_ARN` + `*_EXTERNAL_ID` values |
| 2nd `terraform apply` | Trust policy updated to only allow Snowflake's IAM user with correct external IDs |

The Terraform `iam.tf` handles this automatically: when `snowflake_external_ids` is empty, it falls back to the self-account bootstrap trust; when populated, it switches to the Snowflake-specific trust with `StringEquals` condition on all external IDs.
