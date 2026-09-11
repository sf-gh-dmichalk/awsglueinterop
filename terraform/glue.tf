resource "aws_glue_catalog_database" "main" {
  name = var.glue_database_name

  description = "Sandbox database for Snowflake catalog integration demo (Iceberg + External Tables)"

  location_uri = "s3://${var.bucket_name}/data/"
}

# The Iceberg table (dmichalk_sandbox_db.orders) is created by
# scripts/generate_data.py via pyiceberg, not Terraform.
# It lives at s3://BUCKET/data/iceberg/orders/ with partition spec
# on order_year + order_month.
#
# The hive-partitioned Parquet files at s3://BUCKET/data/parquet/orders/
# are also written by the same script. External tables in Snowflake
# point at these files via a stage.
