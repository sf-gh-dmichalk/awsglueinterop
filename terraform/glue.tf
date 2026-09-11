resource "aws_glue_catalog_database" "main" {
  name = var.glue_database_name

  description = "Sandbox database for Snowflake catalog integration demo (Iceberg + Hive Parquet)"

  location_uri = "s3://${var.bucket_name}/data/"
}

# The Iceberg table (dmichalk_sandbox_db.orders) is created by
# scripts/generate_data.py via pyiceberg, not Terraform.

# -----------------------------------------------------------------------------
# Hive / Parquet table: orders_hive
# Same 1M rows as the Iceberg table, registered as Hive format so Snowflake
# can query via TABLE_FORMAT=HIVE catalog integration or Hive Direct CLD.
# Partitioned by order_year / order_month using hive-style S3 paths.
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "orders_hive" {
  database_name = aws_glue_catalog_database.main.name
  name          = "orders_hive"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification" = "parquet"
    "EXTERNAL"       = "TRUE"
  }

  storage_descriptor {
    location      = "s3://${var.bucket_name}/data/parquet/orders/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "order_id"
      type = "int"
    }
    columns {
      name = "customer_id"
      type = "int"
    }
    columns {
      name = "product"
      type = "string"
    }
    columns {
      name = "amount"
      type = "double"
    }
    columns {
      name = "customer_tier"
      type = "string"
    }
    columns {
      name = "order_date"
      type = "string"
    }
    columns {
      name = "discount"
      type = "double"
    }
  }

  partition_keys {
    name = "order_year"
    type = "int"
  }
  partition_keys {
    name = "order_month"
    type = "int"
  }
}
