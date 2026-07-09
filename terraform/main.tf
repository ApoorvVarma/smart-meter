# Optional IaC for the smart-meter data lake (mirrors what the runbook does via CLI).
# Usage: terraform init && terraform apply -var="account_id=<ACCOUNT_ID>"

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "region" { default = "us-east-1" }
variable "account_id" {}
variable "glue_role_name" {
  default     = "ServerlessAnalyticsRole"
  description = "Existing Glue-trusted role; see docs/iam_policies.md to create one"
}

provider "aws" { region = var.region }

locals { bucket = "meter-health-demo-${var.account_id}" }

resource "aws_s3_bucket" "lake" { bucket = local.bucket }

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    id     = "expire-athena-results"
    status = "Enabled"
    filter { prefix = "athena-results/" }
    expiration { days = 30 }
  }
  rule {
    id     = "raw-to-ia"
    status = "Enabled"
    filter { prefix = "raw/" }
    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.lake.id
  key    = "scripts/glue_etl.py"
  source = "${path.module}/../glue/glue_etl.py"
  etag   = filemd5("${path.module}/../glue/glue_etl.py")
}

resource "aws_glue_catalog_database" "db" { name = "meter_health_db" }

resource "aws_glue_crawler" "raw" {
  name          = "meter-raw-crawler"
  role          = var.glue_role_name
  database_name = aws_glue_catalog_database.db.name
  table_prefix  = "raw_"
  s3_target { path = "s3://${local.bucket}/raw/meter_readings/" }
}

resource "aws_glue_job" "curation" {
  name              = "smart-meter-curation"
  role_arn          = "arn:aws:iam::${var.account_id}:role/${var.glue_role_name}"
  glue_version      = "5.1"
  worker_type       = "G.1X"
  number_of_workers = 5
  timeout           = 60

  command {
    script_location = "s3://${local.bucket}/scripts/glue_etl.py"
    python_version  = "3"
  }

  default_arguments = {
    "--DATABASE_NAME"                    = aws_glue_catalog_database.db.name
    "--TABLE_NAME"                       = "raw_meter_readings"
    "--OUTPUT_PATH"                      = "s3://${local.bucket}/curated/meter_readings/"
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
  }
}

resource "aws_athena_workgroup" "wg" {
  name = "meter-health-wg"
  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 1073741824
    result_configuration {
      output_location = "s3://${local.bucket}/athena-results/"
    }
  }
}

resource "aws_sns_topic" "alerts" { name = "meter-health-alerts" }

resource "aws_cloudwatch_event_rule" "glue_failed" {
  name = "meter-health-glue-job-failed"
  event_pattern = jsonencode({
    source        = ["aws.glue"]
    "detail-type" = ["Glue Job State Change"]
    detail = {
      jobName = ["smart-meter-curation", "smart-meter-curation-visual"]
      state   = ["FAILED", "TIMEOUT", "ERROR"]
    }
  })
}

resource "aws_cloudwatch_event_target" "glue_failed_sns" {
  rule = aws_cloudwatch_event_rule.glue_failed.name
  arn  = aws_sns_topic.alerts.arn
}

output "bucket" { value = aws_s3_bucket.lake.id }
output "sns_topic" { value = aws_sns_topic.alerts.arn }
