# What Was Done — Step-by-Step Deployment Record

Account `519628236805` (workshop, `WSParticipantRole`), region **us-east-1**,
deployed 9 July 2026. Everything below is **live in the account right now**.

## Step-by-step

| # | Step | Resource / result |
|---|---|---|
| 1 | Downloaded Kaggle dataset (CEEW smart meters, Bareilly + Mathura) | 176 MB zip → 8 CSVs (~1.1 GB), `datasets/` |
| 2 | Local validation & cleaning (`scripts/preprocess.py`) | 21,394,429 rows in → 21,393,836 clean (0 nulls, 593 out-of-range removed); report in `docs/local_validation_report.txt` |
| 3 | Created data lake bucket | `s3://meter-health-demo-519628236805` with `raw/ curated/ scripts/ athena-results/` |
| 4 | Uploaded 6 interval CSVs via AWS CLI | `raw/meter_readings/` (~995 MiB) |
| 5 | Created Glue database | `meter_health_db` |
| 6 | Created + ran Glue crawler `meter-raw-crawler` (role: existing `ServerlessAnalyticsRole` — participant role can't create IAM roles, so the pre-provisioned Glue role was reused) | Catalog table `raw_meter_readings` (6 columns) |
| 7 | Created Glue **script** job `smart-meter-curation` (`glue/glue_etl.py`), ran it | SUCCEEDED in 142 s → Snappy Parquet in `curated/meter_readings/`, partitioned `year=/month=` (2019–2021) |
| 8 | Upgraded job to **Glue 5.1** (latest) per console suggestion | `smart-meter-curation` now GlueVersion 5.1 |
| 9 | Created Glue **Visual ETL** job `smart-meter-curation-visual` (Glue 5.1) — same logic as canvas nodes: Catalog source → ApplyMapping → SparkSQL (health rules) → S3 Parquet target | Shows as Type **Visual** in Glue Studio; writes to `curated-visual/` (kept separate so it can't clobber the validated curated data) |
| 10 | Created Athena workgroup `meter-health-wg` | Result location `athena-results/`, 1 GiB per-query scan cap, CloudWatch metrics on |
| 11 | Created curated table + loaded partitions | `meter_health_db.meter_readings_curated` (DDL in `athena/queries.sql`) |
| 12 | Validated analytics in Athena | 21,393,836 rows, 84 meters, May 2019–Oct 2021; health summary, top consumers, and regression **consumption predictions** all verified |
| 13 | Monitoring | SNS topic `meter-health-alerts`; EventBridge rules for Glue job & crawler failure; CloudWatch alarm for failed Athena queries in the workgroup |

Still manual (needs console/browser): **QuickSight** signup + dashboard build
(full spec in `quicksight/dashboard_design.md`), and subscribing your email to
alerts: `aws sns subscribe --topic-arn arn:aws:sns:us-east-1:519628236805:meter-health-alerts --protocol email --notification-endpoint <you>`.

## What you can view in Athena (console → Athena → workgroup `meter-health-wg`)

Pick database `meter_health_db`. Tables: `raw_meter_readings` (raw CSV) and
`meter_readings_curated` (Parquet, enriched). Paste queries from
`athena/queries.sql` (28 business queries) and `athena/insights.sql`
(predictions + insights). Highlights already validated:

- **KPI snapshot** (query #24): total/healthy/warning/critical meters, avg voltage 223.1 V, avg health score 76.0
- **Health summary** (#8): CRITICAL 12.5M readings (over-voltage is chronic on this feeder), HEALTHY 5.8M, WARNING 2.2M, POSSIBLE_METER_ISSUE 551k, HIGH_LOAD 255k
- **Top consumers** (#4): BR51 (15,752 kWh), BR06, BR24, BR45, BR49
- **Prediction — next-month kWh per meter** (insights P2, regression): e.g. BR51 → 895 kWh for Nov 2021, trend +21.4 kWh/month; also next-day forecast (P1), seasonality (P4)
- **Insights**: anomaly days (A1), theft/tamper indicators (A2), outage hours (A3), consumer segmentation (A4), voltage-quality league table by town (A5), peak-demand contributors (A6)
- Trends: daily consumption with 7-day moving average (#16), voltage trend (#17), hour×day heat map data (#21), data completeness (#28)

## What you can view/build in QuickSight

After enabling QuickSight (Enterprise trial) and granting it Athena + the bucket
(Manage QuickSight → Security & permissions), create an Athena dataset on
workgroup `meter-health-wg` using the hourly-aggregate SQL in
`quicksight/dashboard_design.md`, import to SPICE, then build 3 sheets:

1. **Executive Overview** — 7 KPI tiles (Total/Healthy/Warning/Critical meters, avg consumption/voltage/current), health-score gauge, health-distribution pie, **monthly consumption line with ML Forecast (3 months ahead)**
2. **Consumption Analytics** — daily consumption line with **14-day ML forecast + anomaly-detection insight**, top-10 consumers bar, hour×day-of-week heat map, weekend/weekday split, avg-vs-peak power combo
3. **Power Quality & Meter Health** — voltage/current trend lines with 240 V/200 V reference lines, voltage-band bar, top-20 unhealthy meters table (red conditional formatting), health-score trend, outage hours

Filters: date range, meter, town (BR/MH), health status; click-through action from
unhealthy-meters table to filter other sheets.

## Where everything lives

- Console quick links: S3 bucket `meter-health-demo-519628236805` · Glue Studio → Jobs (`smart-meter-curation`, `smart-meter-curation-visual`) · Glue → Crawlers (`meter-raw-crawler`) · Athena editor (workgroup `meter-health-wg`) · CloudWatch → Alarms / EventBridge → Rules (`meter-health-*`)
- Repo: code in `glue/`, `athena/`, `scripts/`; docs in `docs/`, `architecture/`, `quicksight/`; IaC in `terraform/`
- Note: workshop STS credentials expire — re-export fresh ones from the workshop portal if CLI calls return `ExpiredToken`.
