# Day-wise Runbook — Smart Meter Health Data Lake

Conventions: region `us-east-1`, bucket `meter-health-demo-<ACCOUNT_ID>`,
database `meter_health_db`, Glue role `ServerlessAnalyticsRole` (or
`meter-health-glue-role` from docs/iam_policies.md if you create your own).

---

## Day 1 — Dataset, AWS setup, IAM, S3, upload

1. **Download dataset**
   ```bash
   python -m venv .venv && source .venv/bin/activate
   pip install kaggle pandas pyarrow
   mkdir -p ~/.kaggle && echo <KAGGLE_TOKEN> > ~/.kaggle/access_token && chmod 600 ~/.kaggle/access_token
   python scripts/download_dataset.py
   python scripts/preprocess.py          # local validation report + cleaned CSVs
   ```
2. **Configure AWS CLI** — export the session credentials (or `aws configure`).
   Verify: `aws sts get-caller-identity`.
3. **IAM** — create `meter-health-glue-role` per docs/iam_policies.md, or confirm
   an existing Glue-trusted role exists:
   `aws iam get-role --role-name ServerlessAnalyticsRole`
4. **S3**
   ```bash
   BUCKET=meter-health-demo-$(aws sts get-caller-identity --query Account --output text)
   aws s3 mb s3://$BUCKET
   for p in raw curated scripts athena-results; do aws s3api put-object --bucket $BUCKET --key $p/; done
   ```
5. **Upload**
   ```bash
   cd datasets
   for f in "CEEW - Smart meter data Bareilly 2020.csv" ...; do
     aws s3 cp "$f" "s3://$BUCKET/raw/meter_readings/$f"
   done
   aws s3 ls s3://$BUCKET/raw/meter_readings/ --human-readable   # verify sizes
   ```

**Troubleshooting Day 1**
| Problem | Fix |
|---|---|
| `kaggle: command not found` | activate the venv; `pip install kaggle` |
| Kaggle 401/403 | token expired — regenerate; check `~/.kaggle/access_token` perms 600 |
| `AccessDenied` on `s3 mb` | bucket name taken globally or no `s3:CreateBucket`; add account id suffix |
| `ExpiredToken` | workshop STS creds rotate — re-export fresh credentials |
| Slow upload | use `aws s3 cp --recursive` or `aws s3 sync`; check `multipart_threshold` |

---

## Day 2 — Glue database, crawler, catalog, ETL

1. **Database**
   ```bash
   aws glue create-database --database-input '{"Name":"meter_health_db"}'
   ```
2. **Crawler**
   ```bash
   aws glue create-crawler --name meter-raw-crawler --role ServerlessAnalyticsRole \
     --database-name meter_health_db --table-prefix raw_ \
     --targets '{"S3Targets":[{"Path":"s3://'$BUCKET'/raw/meter_readings/"}]}'
   aws glue start-crawler --name meter-raw-crawler
   aws glue get-crawler --name meter-raw-crawler --query 'Crawler.State'   # wait for READY
   ```
3. **Verify catalog** — expect table `raw_meter_readings` with 6 columns:
   ```bash
   aws glue get-tables --database-name meter_health_db \
     --query 'TableList[].[Name,StorageDescriptor.Columns[].Name]'
   ```
4. **ETL**
   ```bash
   aws s3 cp glue/glue_etl.py s3://$BUCKET/scripts/glue_etl.py
   aws glue create-job --name smart-meter-curation --role ServerlessAnalyticsRole \
     --command '{"Name":"glueetl","ScriptLocation":"s3://'$BUCKET'/scripts/glue_etl.py","PythonVersion":"3"}' \
     --glue-version "4.0" --worker-type G.1X --number-of-workers 5 --timeout 60 \
     --default-arguments '{"--DATABASE_NAME":"meter_health_db","--TABLE_NAME":"raw_meter_readings","--OUTPUT_PATH":"s3://'$BUCKET'/curated/meter_readings/","--enable-metrics":"true","--enable-continuous-cloudwatch-log":"true"}'
   aws glue start-job-run --job-name smart-meter-curation
   aws glue get-job-runs --job-name smart-meter-curation --max-results 1 \
     --query 'JobRuns[0].[JobRunState,ExecutionTime,ErrorMessage]'
   ```
5. **Verify curated output**
   ```bash
   aws s3 ls s3://$BUCKET/curated/meter_readings/ --recursive | head   # year=/month= partitions
   ```

**Troubleshooting Day 2**
| Problem | Fix |
|---|---|
| Crawler creates many tables | schemas/headers differ per file — ensure only interval CSVs (same header) in the prefix |
| Crawler `Failed` | check `/aws-glue/crawlers` log; usually S3 permission on the role |
| Job fails `Missing expected columns` | crawler normalized headers differently — check table columns, extend RENAMES map |
| Job fails `AccessDenied` on write | role lacks `s3:PutObject` on `curated/*` |
| Job slow / OOM | raise workers to 10 G.1X; verify `repartition` not `coalesce(1)` |
| Nothing written | job bookmark skipped already-processed data — rerun with `--job-bookmark-option job-bookmark-disable` |

---

## Day 3 — Athena, business queries, validation

1. **Workgroup**
   ```bash
   aws athena create-work-group --name meter-health-wg --configuration \
     'ResultConfiguration={OutputLocation=s3://'$BUCKET'/athena-results/},EnforceWorkGroupConfiguration=true,PublishCloudWatchMetricsEnabled=true,BytesScannedCutoffPerQuery=1073741824'
   ```
2. **Curated table** — run the DDL at the top of `athena/queries.sql` (replace
   `<BUCKET>`), then `MSCK REPAIR TABLE meter_health_db.meter_readings_curated;`
3. **Business queries** — run queries 1–28 from `athena/queries.sql`.
4. **Prediction & insights** — run P1–P4 / A1–A6 from `athena/insights.sql`.
5. **Validation checks**
   - row count curated ≈ raw minus rejects
   - `SELECT count(*) FROM ... WHERE year IS NULL` → 0
   - KPI query (#24) returns sane averages (V ≈ 230–250, Hz ≈ 50)

**Troubleshooting Day 3**
| Problem | Fix |
|---|---|
| `HIVE_METASTORE_ERROR` / table not found | DDL database prefix; check catalog |
| Query returns 0 rows | partitions not loaded — `MSCK REPAIR TABLE` |
| `HIVE_PARTITION_SCHEMA_MISMATCH` | drop & recreate table; ensure DDL matches Parquet types |
| `Query exhausted resources` | add partition filters; reduce columns |
| Results `AccessDenied` | workgroup result location vs IAM policy mismatch |

---

## Day 4 — QuickSight, dashboard, testing, presentation

1. **Enable QuickSight** (Enterprise trial), region us-east-1.
2. **Permissions**: Manage QuickSight → Security & permissions → allow **Athena**
   and the data-lake **S3 bucket** (with write for workgroup results).
3. **Dataset**: New dataset → Athena → workgroup `meter-health-wg` → custom SQL
   (hourly aggregate from `quicksight/dashboard_design.md`) → SPICE → daily refresh.
4. **Build visuals** per `quicksight/dashboard_design.md` (3 sheets: Executive,
   Consumption + ML forecast, Power Quality & Health).
5. **Testing**: cross-check each KPI tile against the matching Athena query
   (#24, #25); test filters (date, meter, town) and the meter drill-down action.
6. **Presentation**: walk raw→curated lineage, show a CRITICAL meter story
   (over-voltage feeder), show forecast widget for next month's consumption.

**Troubleshooting Day 4**
| Problem | Fix |
|---|---|
| QuickSight can't see Athena | Security & permissions → enable Athena + S3 bucket |
| SPICE import fails | check SPICE capacity; reduce with hourly-aggregate SQL |
| Forecast option greyed out | need date-typed axis + ≥ ~40 points; use daily/monthly series |
| KPI ≠ Athena result | timezone truncation or filter mismatch — compare custom SQL |
| Slow visuals | confirm SPICE (not direct query); pre-aggregate more |
