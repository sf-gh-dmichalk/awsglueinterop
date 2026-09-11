output "bucket_name" {
  value = aws_s3_bucket.data.id
}

output "bucket_arn" {
  value = aws_s3_bucket.data.arn
}

output "glue_database_name" {
  value = aws_glue_catalog_database.main.name
}

output "iam_role_arn" {
  value = aws_iam_role.snowflake_glue_access.arn
}

output "glue_catalog_id" {
  value = data.aws_caller_identity.current.account_id
}
