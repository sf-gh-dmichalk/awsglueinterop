# Plan: AWS Glue + Snowflake Catalog Integration (Hive Parquet + Iceberg)

## Goal

Stand up an AWS Glue Data Catalog with:
1. **Hive/Parquet tables** — registered in Glue, backed by Parquet files on S3
2. **Iceberg table** — in the same Glue database, backed by Iceberg format on S3

Then connect it all to Snowflake via:
- A **Hive catalog integration** (`TABLE_FORMAT = HIVE`) for the Parquet tables
- A **Glue Iceberg REST catalog integration** (`CATALOG_SOURCE = ICEBERG_REST`) for the Iceberg table, enabling a **catalog-linked database**

---

## Part 1: Terraform — AWS Infrastructure

All Terraform goes in `terraform/` directory.

### 1.1 S3 Bucket (`s3.tf`)

- Create a bucket (e.g. `chewy-glue-sandbox-<account_id>`) in `us-west-2`
- Enable versioning (required for Iceberg)
- Block public access
- Create prefixes/paths:
  - `data/hive/customers/` — Parquet files
  - `data/hive/orders/` — Parquet files
  - `data/iceberg/products/` — Iceberg table location

### 1.2 AWS Glue Database & Tables (`glue.tf`)

- Create a Glue database: `chewy_sandbox_db`
- Create two Hive-format Glue tables pointing at the S3 Parquet locations:
  - **`customers`** — columns: `customer_id (int)`, `name (string)`, `email (string)`, `signup_date (string)`, `tier (string)`
  - **`orders`** — columns: `order_id (int)`, `customer_id (int)`, `product (string)`, `amount (double)`, `order_date (string)`
- These are `EXTERNAL_TABLE` with `InputFormat = org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat` / `OutputFormat = ...ParquetOutputFormat` and SerDe `org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe`

### 1.3 IAM Role for Snowflake (`iam.tf`)

Create an IAM role `snowflake-glue-access` with **two policies attached**:

**Policy 1 — Glue access (for both Hive and Iceberg REST):**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GlueCatalogAccess",
      "Effect": "Allow",
      "Action": [
        "glue:GetCatalog",
        "glue:GetDatabase",
        "glue:GetDatabases",
        "glue:GetTable",
        "glue:GetTables",
        "glue:CreateDatabase",
        "glue:CreateTable",
        "glue:UpdateTable",
        "glue:DeleteTable"
      ],
      "Resource": [
        "arn:aws:glue:*:ACCOUNT_ID:table/chewy_sandbox_db/*",
        "arn:aws:glue:*:ACCOUNT_ID:catalog",
        "arn:aws:glue:*:ACCOUNT_ID:database/chewy_sandbox_db"
      ]
    }
  ]
}
```

**Policy 2 — S3 access (for reading Parquet and Iceberg data/metadata):**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3DataAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::BUCKET_NAME",
        "arn:aws:s3:::BUCKET_NAME/*"
      ]
    }
  ]
}
```

**Trust policy** — initially allows your own AWS account. After creating the Snowflake catalog integration, you update this with `GLUE_AWS_IAM_USER_ARN` and `GLUE_AWS_EXTERNAL_ID` from `DESCRIBE CATALOG INTEGRATION`. Terraform includes a placeholder for this.

### 1.4 Lake Formation Permissions (`lakeformation.tf`)

- Register the S3 bucket location with Lake Formation
- Grant the `snowflake-glue-access` IAM role:
  - `DATABASE` permissions on `chewy_sandbox_db` (DESCRIBE, ALTER, CREATE_TABLE, DROP)
  - `TABLE` permissions on all tables in the database (SELECT, DESCRIBE, ALTER, INSERT, DELETE)
- Grant `lakeformation:GetDataAccess` in the IAM policy (required for Iceberg REST with catalog-vended credentials)

```json
{
  "Effect": "Allow",
  "Action": "lakeformation:GetDataAccess",
  "Resource": "*"
}
```

### 1.5 Variables & Outputs (`variables.tf`, `outputs.tf`)

**Variables:**
- `aws_region` (default `us-west-2`)
- `aws_account_id` — your sandbox account ID
- `bucket_name` — override or auto-generate
- `snowflake_iam_user_arn` — set after creating Snowflake catalog integration (default `""`)
- `snowflake_external_id` — set after creating Snowflake catalog integration (default `""`)

**Outputs:**
- `bucket_name`
- `bucket_arn`
- `glue_database_name`
- `iam_role_arn`
- `glue_catalog_id` (= AWS account ID)

### 1.6 Provider & Backend (`main.tf`)

- AWS provider targeting `var.aws_region`
- Local backend (or S3 if you prefer)
- `data "aws_caller_identity"` to auto-detect account ID

---

## Part 2: Generate Sample Parquet + Iceberg Data

### 2.1 Python Script (`scripts/generate_data.py`)

Uses `pyarrow` and `pyarrow.parquet` (no Spark needed):

**Parquet tables (Hive format):**
- Generate ~100 rows of `customers` data -> write to `s3://BUCKET/data/hive/customers/data.parquet`
- Generate ~500 rows of `orders` data -> write to `s3://BUCKET/data/hive/orders/data.parquet`

**Iceberg table:**
- Uses `pyiceberg` library to:
  1. Connect to AWS Glue catalog
  2. Create table `chewy_sandbox_db.products` with schema: `product_id (int)`, `name (string)`, `category (string)`, `price (double)`, `in_stock (boolean)`
  3. Write ~50 rows of sample data
  4. Table location: `s3://BUCKET/data/iceberg/products/`

### 2.2 Requirements (`scripts/requirements.txt`)

```
pyarrow>=14.0
boto3
pyiceberg[glue,s3]>=0.6.0
```

---

## Part 3: Snowflake — Catalog Integrations & Catalog-Linked Database

All SQL goes in `snowflake/setup.sql`.

### 3.1 External Volume (for Hive Parquet tables)

Required for Hive-format tables since they don't support catalog-vended credentials:

```sql
CREATE OR REPLACE EXTERNAL VOLUME chewy_glue_ext_vol
  STORAGE_LOCATIONS = (
    (
      NAME = 'chewy-s3'
      STORAGE_BASE_URL = 's3://BUCKET_NAME/'
      STORAGE_PROVIDER = 'S3'
      STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::ACCOUNT_ID:role/snowflake-glue-access'
    )
  );
```

After creation, run `DESCRIBE EXTERNAL VOLUME chewy_glue_ext_vol` to get the IAM user ARN and external ID, then update the IAM role trust policy.

### 3.2 Hive Catalog Integration (for Parquet tables)

```sql
CREATE OR REPLACE CATALOG INTEGRATION glue_hive_int
  CATALOG_SOURCE = GLUE
  TABLE_FORMAT = HIVE
  GLUE_CATALOG_ID = '<aws-account-id>'
  GLUE_AWS_ROLE_ARN = 'arn:aws:iam::<aws-account-id>:role/snowflake-glue-access'
  ENABLED = TRUE;
```

After creation:
```sql
DESCRIBE CATALOG INTEGRATION glue_hive_int;
```
Record `GLUE_AWS_IAM_USER_ARN` and `GLUE_AWS_EXTERNAL_ID` -> update IAM role trust policy in AWS.

Then create Iceberg tables referencing the Hive/Parquet data:
```sql
CREATE OR REPLACE ICEBERG TABLE customers
  EXTERNAL_VOLUME = 'chewy_glue_ext_vol'
  CATALOG = 'glue_hive_int'
  CATALOG_TABLE_NAME = 'customers'
  CATALOG_NAMESPACE = 'chewy_sandbox_db';

CREATE OR REPLACE ICEBERG TABLE orders
  EXTERNAL_VOLUME = 'chewy_glue_ext_vol'
  CATALOG = 'glue_hive_int'
  CATALOG_TABLE_NAME = 'orders'
  CATALOG_NAMESPACE = 'chewy_sandbox_db';
```

### 3.3 Iceberg REST Catalog Integration (for Iceberg table + catalog-linked DB)

```sql
CREATE OR REPLACE CATALOG INTEGRATION glue_iceberg_rest_int
  CATALOG_SOURCE = ICEBERG_REST
  TABLE_FORMAT = ICEBERG
  CATALOG_NAMESPACE = 'chewy_sandbox_db'
  REST_CONFIG = (
    CATALOG_URI = 'https://glue.us-west-2.amazonaws.com/iceberg'
    CATALOG_API_TYPE = AWS_GLUE
    CATALOG_NAME = '<aws-account-id>'
  )
  REST_AUTHENTICATION = (
    TYPE = SIGV4
    SIGV4_IAM_ROLE = 'arn:aws:iam::<aws-account-id>:role/snowflake-glue-access'
    SIGV4_SIGNING_REGION = 'us-west-2'
  )
  ENABLED = TRUE;
```

After creation:
```sql
DESCRIBE CATALOG INTEGRATION glue_iceberg_rest_int;
```
Record `GLUE_AWS_IAM_USER_ARN` and `GLUE_AWS_EXTERNAL_ID` -> update IAM role trust policy.

### 3.4 Catalog-Linked Database

```sql
CREATE OR REPLACE DATABASE chewy_glue_catalog_db
  LINKED_CATALOG = (
    CATALOG = 'glue_iceberg_rest_int'
    ALLOWED_NAMESPACES = ('chewy_sandbox_db')
  )
  CATALOG_CASE_SENSITIVITY = CASE_INSENSITIVE;
```

This auto-discovers all Iceberg tables in `chewy_sandbox_db` and syncs them into Snowflake. The `products` Iceberg table will appear as `chewy_glue_catalog_db.chewy_sandbox_db.products`.

### 3.5 Hive Catalog-Linked Database (for Parquet tables)

> **Note:** Hive catalog-linked databases are currently in limited access. The syntax is:

```sql
CREATE OR REPLACE DATABASE chewy_glue_hive_catalog_db
  LINKED_CATALOG = (
    CATALOG = 'glue_hive_int'
    ALLOWED_NAMESPACES = ('chewy_sandbox_db')
  )
  EXTERNAL_VOLUME = 'chewy_glue_ext_vol'
  CATALOG_CASE_SENSITIVITY = CASE_INSENSITIVE;
```

If Hive catalog-linked DBs are not yet available on your account, use the individual table approach from 3.2 instead.

---

## Part 4: Trust Policy Bootstrap (chicken-and-egg)

The IAM role trust policy needs Snowflake's IAM user ARN and external ID, but you only get those after creating the integrations. The workflow is:

1. `terraform apply` — creates IAM role with a **permissive initial trust policy** (trusts your own account)
2. Create Snowflake catalog integrations and external volume
3. Run `DESCRIBE` on each to get `GLUE_AWS_IAM_USER_ARN` + `GLUE_AWS_EXTERNAL_ID`
4. Set `snowflake_iam_user_arn` and `snowflake_external_id` in `terraform.tfvars`
5. `terraform apply` again — updates trust policy with Snowflake's identity
6. Verify by querying the tables in Snowflake

---

## File Structure

```
awsglueinterop/
├── plan.md                          # This file
├── terraform/
│   ├── main.tf                      # Provider, backend, data sources
│   ├── variables.tf                 # Input variables
│   ├── outputs.tf                   # Outputs (role ARN, bucket, etc.)
│   ├── s3.tf                        # S3 bucket
│   ├── glue.tf                      # Glue database + Hive tables
│   ├── iam.tf                       # IAM role + policies
│   ├── lakeformation.tf             # Lake Formation permissions
│   └── terraform.tfvars.example     # Example variable values
├── scripts/
│   ├── generate_data.py             # Generate Parquet + Iceberg data
│   └── requirements.txt             # Python deps
└── snowflake/
    └── setup.sql                    # All Snowflake DDL
```

---

## Execution Order

1. **Terraform apply** (Part 1) — creates S3, Glue, IAM, Lake Formation
2. **Generate data** (Part 2) — write Parquet + Iceberg to S3/Glue
3. **Snowflake DDL** (Part 3) — create external volume, catalog integrations, tables, catalog-linked DB
4. **Update trust policy** (Part 4) — second `terraform apply` with Snowflake identity values
5. **Verify** — `SELECT * FROM chewy_glue_catalog_db.chewy_sandbox_db.products;`
