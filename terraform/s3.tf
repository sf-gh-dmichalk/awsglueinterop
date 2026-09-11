resource "aws_s3_bucket" "data" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "parquet_orders_prefix" {
  bucket  = aws_s3_bucket.data.id
  key     = "data/parquet/orders/"
  content = ""
}

resource "aws_s3_object" "iceberg_orders_prefix" {
  bucket  = aws_s3_bucket.data.id
  key     = "data/iceberg/orders/"
  content = ""
}
