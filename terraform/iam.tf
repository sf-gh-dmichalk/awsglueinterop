locals {
  # When Snowflake identity is not yet known, trust our own account so
  # terraform apply can succeed on the first pass.
  use_snowflake_trust = var.snowflake_iam_user_arn != "" && var.snowflake_external_id != ""
}

# -----------------------------------------------------------------------------
# IAM Role — assumed by Snowflake
# -----------------------------------------------------------------------------
resource "aws_iam_role" "snowflake_glue_access" {
  name = "snowflake-glue-access"

  assume_role_policy = local.use_snowflake_trust ? jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SnowflakeAccess"
        Effect = "Allow"
        Principal = {
          AWS = var.snowflake_iam_user_arn
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.snowflake_external_id
          }
        }
      }
    ]
  }) : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SelfAccountBootstrap"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.aws_account_id}:root"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Glue catalog access policy
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy" "glue_access" {
  name = "glue-catalog-access"
  role = aws_iam_role.snowflake_glue_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GlueCatalogAccess"
        Effect = "Allow"
        Action = [
          "glue:GetCatalog",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:CreateDatabase",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:DeleteTable"
        ]
        Resource = [
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:table/${var.glue_database_name}/*",
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:catalog",
          "arn:aws:glue:${var.aws_region}:${var.aws_account_id}:database/${var.glue_database_name}"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# S3 data access policy
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-data-access"
  role = aws_iam_role.snowflake_glue_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3DataAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "arn:aws:s3:::${var.bucket_name}",
          "arn:aws:s3:::${var.bucket_name}/*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Lake Formation GetDataAccess (needed for Iceberg REST with vended creds)
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy" "lakeformation_access" {
  name = "lakeformation-get-data-access"
  role = aws_iam_role.snowflake_glue_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "LakeFormationDataAccess"
        Effect   = "Allow"
        Action   = "lakeformation:GetDataAccess"
        Resource = "*"
      }
    ]
  })
}
