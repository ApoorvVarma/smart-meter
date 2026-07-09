# IAM — Least-Privilege Policies

Replace `<BUCKET>` (e.g. `meter-health-demo-123456789012`), `<ACCOUNT_ID>`, `<REGION>`.

## 1. Glue service role — `meter-health-glue-role`

Used by **both** the crawler and the ETL job. Trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "glue.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

Inline policy `meter-health-glue-policy`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3ReadRawAndScripts",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::<BUCKET>",
        "arn:aws:s3:::<BUCKET>/raw/*",
        "arn:aws:s3:::<BUCKET>/scripts/*"
      ]
    },
    {
      "Sid": "S3WriteCurated",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<BUCKET>/curated/*"
    },
    {
      "Sid": "GlueCatalog",
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase", "glue:GetDatabases",
        "glue:GetTable", "glue:GetTables", "glue:GetPartition", "glue:GetPartitions",
        "glue:CreateTable", "glue:UpdateTable",
        "glue:BatchCreatePartition", "glue:BatchGetPartition", "glue:UpdatePartition",
        "glue:GetJobBookmark", "glue:ResetJobBookmark"
      ],
      "Resource": [
        "arn:aws:glue:<REGION>:<ACCOUNT_ID>:catalog",
        "arn:aws:glue:<REGION>:<ACCOUNT_ID>:database/meter_health_db",
        "arn:aws:glue:<REGION>:<ACCOUNT_ID>:table/meter_health_db/*"
      ]
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:<REGION>:<ACCOUNT_ID>:log-group:/aws-glue/*"
    },
    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*",
      "Condition": { "StringEquals": { "cloudwatch:namespace": "Glue" } }
    }
  ]
}
```

> Shortcut for the demo: attach the AWS-managed `AWSGlueServiceRole` policy plus the
> two S3 statements above. The inline policy above is the production-grade version.

## 2. Athena analyst policy — `meter-health-athena-analyst`

Attach to the human analyst user/role or the workgroup users:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AthenaWorkgroup",
      "Effect": "Allow",
      "Action": [
        "athena:StartQueryExecution", "athena:GetQueryExecution",
        "athena:GetQueryResults", "athena:StopQueryExecution",
        "athena:GetWorkGroup", "athena:ListQueryExecutions"
      ],
      "Resource": "arn:aws:athena:<REGION>:<ACCOUNT_ID>:workgroup/meter-health-wg"
    },
    {
      "Sid": "CatalogRead",
      "Effect": "Allow",
      "Action": [
        "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable",
        "glue:GetTables", "glue:GetPartition", "glue:GetPartitions"
      ],
      "Resource": [
        "arn:aws:glue:<REGION>:<ACCOUNT_ID>:catalog",
        "arn:aws:glue:<REGION>:<ACCOUNT_ID>:database/meter_health_db",
        "arn:aws:glue:<REGION>:<ACCOUNT_ID>:table/meter_health_db/*"
      ]
    },
    {
      "Sid": "S3ReadCurated",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::<BUCKET>",
        "arn:aws:s3:::<BUCKET>/curated/*"
      ]
    },
    {
      "Sid": "S3AthenaResults",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::<BUCKET>",
        "arn:aws:s3:::<BUCKET>/athena-results/*"
      ]
    }
  ]
}
```

## 3. QuickSight

QuickSight uses its service role `aws-quicksight-service-role-v0`. In
**Manage QuickSight → Security & permissions**, grant access to:
- **Athena** (workgroup `meter-health-wg`)
- **S3 buckets**: `<BUCKET>` — with *write permission for Athena Workgroup* enabled
  (needed for `athena-results/`)

That console flow attaches an equivalent of:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["athena:StartQueryExecution", "athena:GetQueryExecution",
                  "athena:GetQueryResults", "athena:StopQueryExecution",
                  "athena:GetWorkGroup", "athena:ListDataCatalogs",
                  "athena:GetDataCatalog", "athena:ListDatabases",
                  "athena:ListTableMetadata", "athena:GetTableMetadata"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable",
                  "glue:GetTables", "glue:GetPartition", "glue:GetPartitions"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket", "s3:PutObject", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::<BUCKET>", "arn:aws:s3:::<BUCKET>/*"]
    }
  ]
}
```

## 4. CloudWatch operator policy — `meter-health-cw-operator`

For the person/automation managing alarms and dashboards:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricAlarm", "cloudwatch:DescribeAlarms",
        "cloudwatch:DeleteAlarms", "cloudwatch:GetMetricData",
        "cloudwatch:ListMetrics", "cloudwatch:PutDashboard",
        "logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogGroups",
        "logs:DescribeLogStreams", "logs:PutMetricFilter"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["sns:Publish", "sns:Subscribe", "sns:CreateTopic"],
      "Resource": "arn:aws:sns:<REGION>:<ACCOUNT_ID>:meter-health-alerts"
    }
  ]
}
```

## Security principles applied

- **Separate read and write prefixes** — Glue can only write to `curated/`; analysts
  can only read `curated/` and write `athena-results/`; nobody but the ingest user
  writes `raw/`.
- **Resource-scoped catalog access** — policies name `meter_health_db`, not `*`.
- **No wildcard S3 access** — bucket + prefix ARNs everywhere.
- **Workgroup isolation** — Athena access is scoped to `meter-health-wg`, which also
  enforces the result location and per-query scan limits.
- **Encryption** — enable SSE-S3 (or SSE-KMS) default encryption on the bucket; add
  `aws:SecureTransport` deny-if-false bucket policy for TLS-only access.
