variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-west-2"
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
  default     = "913524911227"
}

variable "bucket_name" {
  description = "S3 bucket name for Glue data"
  type        = string
  default     = "dmichalk-glue-sandbox"
}

variable "glue_database_name" {
  description = "Glue database name"
  type        = string
  default     = "dmichalk_sandbox_db"
}

variable "snowflake_iam_user_arn" {
  description = "Snowflake IAM user ARN from DESCRIBE CATALOG INTEGRATION (set after Step 3)"
  type        = string
  default     = ""
}

variable "snowflake_external_ids" {
  description = "Snowflake external IDs from DESCRIBE CATALOG INTEGRATION and DESCRIBE EXTERNAL VOLUME"
  type        = list(string)
  default     = []
}
