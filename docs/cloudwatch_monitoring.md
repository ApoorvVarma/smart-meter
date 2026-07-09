# CloudWatch Monitoring & Alarms

All alerts publish to one SNS topic:

```bash
aws sns create-topic --name meter-health-alerts
aws sns subscribe --topic-arn arn:aws:sns:<REGION>:<ACCOUNT_ID>:meter-health-alerts \
  --protocol email --notification-endpoint ops-team@example.com
```

## 1. Glue ETL job

Enable on the job: **Job metrics**, **Continuous logging**, **Spark UI logs**.
Log groups: `/aws-glue/jobs/output`, `/aws-glue/jobs/error`.

Key metrics (namespace `Glue`): `glue.driver.aggregate.numFailedTasks`,
`glue.driver.aggregate.elapsedTime`, `glue.driver.jvm.heap.usage`.

**Alarm — job failure** (event-driven, catches every failed run):

```bash
# EventBridge rule matching Glue job state changes to FAILED/TIMEOUT
aws events put-rule --name meter-health-glue-job-failed \
  --event-pattern '{
    "source": ["aws.glue"],
    "detail-type": ["Glue Job State Change"],
    "detail": {"jobName": ["smart-meter-curation"],
               "state": ["FAILED", "TIMEOUT", "ERROR"]}
  }'
aws events put-targets --rule meter-health-glue-job-failed \
  --targets "Id"="sns","Arn"="arn:aws:sns:<REGION>:<ACCOUNT_ID>:meter-health-alerts"
```

**Alarm — job running too long** (metric alarm):

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name meter-health-glue-elapsed-time \
  --namespace Glue --metric-name glue.driver.aggregate.elapsedTime \
  --dimensions Name=JobName,Value=smart-meter-curation Name=JobRunId,Value=ALL Name=Type,Value=count \
  --statistic Maximum --period 300 --evaluation-periods 1 \
  --threshold 3600000 --comparison-operator GreaterThanThreshold \
  --alarm-actions arn:aws:sns:<REGION>:<ACCOUNT_ID>:meter-health-alerts
```

## 2. Glue Crawler

Crawler logs: log group `/aws-glue/crawlers`. Failure alerting via EventBridge:

```bash
aws events put-rule --name meter-health-crawler-failed \
  --event-pattern '{
    "source": ["aws.glue"],
    "detail-type": ["Glue Crawler State Change"],
    "detail": {"crawlerName": ["meter-raw-crawler"], "state": ["Failed"]}
  }'
aws events put-targets --rule meter-health-crawler-failed \
  --targets "Id"="sns","Arn"="arn:aws:sns:<REGION>:<ACCOUNT_ID>:meter-health-alerts"
```

Also review crawler run metrics: `TablesCreated`, `TablesUpdated` (namespace `Glue`).

## 3. Athena

Metrics (namespace `AWS/Athena`, per workgroup): `ProcessedBytes`,
`QueryExecutionTime`, `QueryQueueTime`.

**Alarm — failed queries** in workgroup:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name meter-health-athena-failed-queries \
  --namespace AWS/Athena --metric-name QueryExecutionTime \
  --dimensions Name=QueryState,Value=FAILED Name=QueryType,Value=DML Name=WorkGroup,Value=meter-health-wg \
  --statistic SampleCount --period 300 --evaluation-periods 1 \
  --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions arn:aws:sns:<REGION>:<ACCOUNT_ID>:meter-health-alerts
```

**Cost guardrails in the workgroup itself** (preferred over alarms):

```bash
aws athena update-work-group --work-group meter-health-wg \
  --configuration-updates \
  'BytesScannedCutoffPerQuery=1073741824,EnforceWorkGroupConfiguration=true,PublishCloudWatchMetricsEnabled=true'
# 1 GiB per-query scan cap + metrics publishing on
```

## 4. S3

- Enable **request metrics** on the bucket (filter per prefix `raw/`, `curated/`) to
  watch `NumberOfObjects`, `BucketSizeBytes`, 4xx/5xx errors.
- **Storage growth alarm**:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name meter-health-s3-size \
  --namespace AWS/S3 --metric-name BucketSizeBytes \
  --dimensions Name=BucketName,Value=<BUCKET> Name=StorageType,Value=StandardStorage \
  --statistic Average --period 86400 --evaluation-periods 1 \
  --threshold 53687091200 --comparison-operator GreaterThanThreshold \
  --alarm-actions arn:aws:sns:<REGION>:<ACCOUNT_ID>:meter-health-alerts
# alert if bucket exceeds 50 GB
```

- Optional: S3 server access logging or CloudTrail data events on `raw/` for audit.

## 5. Ops dashboard

Create one CloudWatch dashboard `meter-health-ops` with widgets for: Glue job
success/failure + duration, crawler tables created/updated, Athena
ProcessedBytes + failed query count, S3 bucket size. All widgets use the metrics
above; no extra instrumentation needed.

## Troubleshooting quick reference

| Symptom | Where to look |
|---|---|
| Glue job failed | `/aws-glue/jobs/error` log stream for the run ID |
| Job slow / OOM | Job metrics: heap usage, shuffle bytes; consider more workers |
| Crawler created wrong schema | `/aws-glue/crawlers` log; check CSV header/classifier |
| Athena `HIVE_PARTITION_SCHEMA_MISMATCH` | Curated table schema vs Parquet footer; re-crawl or drop/recreate table |
| Athena scans too many bytes | Check partition filters (`year`, `month`) in WHERE clause |
