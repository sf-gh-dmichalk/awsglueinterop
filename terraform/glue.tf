resource "aws_glue_catalog_database" "main" {
  name = var.glue_database_name

  description = "Sandbox database for Snowflake catalog integration testing (Hive Parquet + Iceberg)"

  location_uri = "s3://${var.bucket_name}/data/"
}

# -----------------------------------------------------------------------------
# Hive / Parquet table: customers
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "customers" {
  database_name = aws_glue_catalog_database.main.name
  name          = "customers"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification" = "parquet"
    "EXTERNAL"       = "TRUE"
  }

  storage_descriptor {
    location      = "s3://${var.bucket_name}/data/hive/customers/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "customer_id"
      type = "int"
    }
    columns {
      name = "name"
      type = "string"
    }
    columns {
      name = "email"
      type = "string"
    }
    columns {
      name = "signup_date"
      type = "string"
    }
    columns {
      name = "tier"
      type = "string"
    }
  }
}

# -----------------------------------------------------------------------------
# Hive / Parquet table: orders
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_table" "orders" {
  database_name = aws_glue_catalog_database.main.name
  name          = "orders"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification" = "parquet"
    "EXTERNAL"       = "TRUE"
  }

  storage_descriptor {
    location      = "s3://${var.bucket_name}/data/hive/orders/"
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
      name = "order_date"
      type = "string"
    }
  }
}
