# -----------------------------------------------------------------------------
# Register S3 location with Lake Formation
# -----------------------------------------------------------------------------
resource "aws_lakeformation_resource" "data_bucket" {
  arn = aws_s3_bucket.data.arn
}

# -----------------------------------------------------------------------------
# Grant the Snowflake IAM role Lake Formation permissions on the database
# -----------------------------------------------------------------------------
resource "aws_lakeformation_permissions" "database" {
  principal   = aws_iam_role.snowflake_glue_access.arn
  permissions = ["DESCRIBE", "ALTER", "CREATE_TABLE", "DROP"]

  database {
    name = aws_glue_catalog_database.main.name
  }
}

# -----------------------------------------------------------------------------
# Grant the Snowflake IAM role Lake Formation permissions on all tables
# -----------------------------------------------------------------------------
resource "aws_lakeformation_permissions" "tables" {
  principal   = aws_iam_role.snowflake_glue_access.arn
  permissions = ["SELECT", "DESCRIBE", "ALTER", "INSERT", "DELETE"]

  table {
    database_name = aws_glue_catalog_database.main.name
    wildcard {}
  }
}
