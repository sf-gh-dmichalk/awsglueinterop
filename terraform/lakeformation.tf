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

# NOTE: Explicit table-level LF grants are not needed because
# CreateTableDefaultPermissions grants ALL to IAM_ALLOWED_PRINCIPALS,
# meaning IAM policies alone control table access in this account.
