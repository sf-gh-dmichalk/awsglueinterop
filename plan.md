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
│   │   │   └── data.parquet          (4 KB, 100 rows)
│   │   └── orders/
│   │       └── data.parquet          (11 KB, 500 rows)
│   └── iceberg/
│       └── products/
│           ├── data/
│           │   └── 00000-*.parquet   (3 KB, 50 rows)
│           └── metadata/
│               ├── 00000-*.metadata.json
│               ├── 00001-*.metadata.json
│               ├── *-m0.avro
│               └── snap-*.avro
```

### Snowflake Objects

| Object | Name | Status |
|---|---|---|
| External Volume | `DMICHALK_GLUE_EXT_VOL` | ✅ Active |
| Catalog Integration | `DMICHALK_GLUE_ICEBERG_INT` (GLUE, TABLE_FORMAT=ICEBERG) | ✅ Active |
| Catalog Integration | `DMICHALK_GLUE_ICEBERG_REST_INT` (ICEBERG_REST) | ✅ Created, blocked by LF |
| Database | `DMICHALK_GLUE_DB` | ✅ Active |
| Schema | `DMICHALK_GLUE_DB.GLUE_TABLES` | ✅ Active |
| Iceberg Table | `DMICHALK_GLUE_DB.GLUE_TABLES.PRODUCTS` | ✅ Queryable (50 rows) |

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
│   ├── generate_data.py             # Generates Parquet (customers/orders) +
│   │                                  Iceberg (products) via pyarrow/pyiceberg
│   └── requirements.txt             # pyarrow, boto3, pyiceberg
└── snowflake/
    └── setup.sql                    # External volume, catalog integrations,
                                       Iceberg table DDL, blocked sections commented
```

---

## Execution Order

1. **`terraform apply`** — creates S3, Glue DB + Hive tables, IAM role, Lake Formation grants
2. **`python scripts/generate_data.py`** — uploads Parquet files, creates Iceberg table + data in Glue
3. **Snowflake DDL** (`snowflake/setup.sql`) — creates external volume, catalog integration, Iceberg table
4. **`DESCRIBE CATALOG INTEGRATION`** + **`DESCRIBE EXTERNAL VOLUME`** — get Snowflake IAM user ARN + external IDs
5. **Set `snowflake_iam_user_arn` + `snowflake_external_ids` in `terraform.tfvars`**
6. **`terraform apply`** again — updates IAM trust policy with Snowflake identity
7. **Verify** — `SELECT * FROM dmichalk_glue_db.glue_tables.products LIMIT 10;`

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
