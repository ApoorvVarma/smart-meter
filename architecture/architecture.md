# AWS Architecture — Smart Meter Health Monitoring Data Lake

## Architecture Diagram

```mermaid
flowchart TB
    subgraph Source["Data Source"]
        K[Kaggle: CEEW Smart Meter CSVs<br/>Bareilly + Mathura, 3-min intervals]
    end

    subgraph Lake["Amazon S3 Data Lake (meter-health-demo)"]
        RAW["s3://.../raw/<br/>Raw CSV (immutable landing zone)"]
        CUR["s3://.../curated/<br/>Parquet, Snappy, partitioned year/month"]
        SCR["s3://.../scripts/<br/>Glue job scripts"]
        RES["s3://.../athena-results/<br/>Query result staging"]
    end

    subgraph Glue["AWS Glue"]
        CRWL["Glue Crawler<br/>(meter-raw-crawler)"]
        CAT["Glue Data Catalog<br/>meter_health_db"]
        ETL["Glue ETL Job (PySpark)<br/>smart-meter-curation"]
    end

    subgraph Analytics["Analytics & BI"]
        ATH["Amazon Athena<br/>SQL over curated Parquet"]
        QS["Amazon QuickSight<br/>Operations dashboard"]
    end

    subgraph Ops["Governance & Ops"]
        IAM["AWS IAM<br/>Least-privilege roles"]
        CW["Amazon CloudWatch<br/>Logs, metrics, alarms"]
    end

    K -->|AWS CLI upload| RAW
    RAW --> CRWL --> CAT
    CAT --> ETL
    RAW --> ETL
    SCR -.script.-> ETL
    ETL -->|Parquet| CUR
    CUR --> ATH
    CAT --> ATH
    ATH -->|results| RES
    ATH --> QS

    IAM -.authorizes.-> Glue
    IAM -.authorizes.-> Analytics
    Glue -.logs/metrics.-> CW
    ATH -.metrics.-> CW
```

## Data Flow (step by step)

1. **Ingest** — CEEW smart-meter CSVs (downloaded from Kaggle) are uploaded with the
   AWS CLI to the **raw zone** `s3://<bucket>/raw/`. Raw is immutable: files are
   never edited in place, only re-landed.
2. **Discover** — A **Glue Crawler** scans `raw/`, infers the CSV schema, and
   registers table `raw` in Glue Data Catalog database **meter_health_db**.
3. **Transform** — The **Glue ETL job** (PySpark, `glue/glue_etl.py`) reads via the
   catalog, deduplicates, drops nulls, enforces physical ranges, renames columns,
   derives time attributes, power, voltage/current/power bands, a 0–100
   `health_score`, and a `health_status` classification.
4. **Curate** — Output is written as **Snappy-compressed Parquet** to
   `curated/meter_readings/`, partitioned by `year` and `month`. A DDL statement
   (or a second crawler on `curated/`) registers `meter_readings_curated`.
5. **Query** — **Athena** runs serverless SQL directly on the curated Parquet;
   partition pruning + columnar format keep scans (and cost) small. Results are
   staged in `athena-results/`.
6. **Visualize** — **QuickSight** connects to Athena (SPICE import) and serves the
   operations dashboard: KPIs, consumption trends, health distribution, heat maps.
7. **Monitor & secure** — **CloudWatch** captures Glue/Athena logs and metrics with
   alarms on job, crawler, and query failures. **IAM** enforces least-privilege
   access per service.

## Service Roles

| Service | Role in this architecture |
|---|---|
| **Amazon S3** | Durable, cheap object store forming the lake's raw and curated zones plus script and query-result staging. |
| **AWS Glue Crawler** | Automatic schema inference over raw CSVs; keeps the catalog in sync as new files land. |
| **AWS Glue Data Catalog** | Central Hive-compatible metastore; single source of truth for schemas used by Glue ETL and Athena. |
| **AWS Glue ETL (PySpark)** | Serverless Spark for cleaning, enrichment, business rules, and CSV→Parquet conversion. No cluster to manage. |
| **Amazon Athena** | Serverless, pay-per-TB-scanned SQL engine for ad-hoc analysis and as the QuickSight data source. |
| **Amazon QuickSight** | Managed BI: executive KPIs, trends, and meter-health visuals for the DISCOM operations team. |
| **AWS IAM** | Least-privilege roles/policies for the Glue job, crawler, Athena users, and QuickSight service role. |
| **Amazon CloudWatch** | Centralized logs, metrics, and failure alarms for Glue jobs, crawlers, and Athena queries. |

## Zone design

| Zone | Path | Format | Purpose |
|---|---|---|---|
| Raw | `raw/` | CSV (as-landed) | Immutable source of truth; enables full reprocessing |
| Curated | `curated/` | Parquet + Snappy, partitioned `year/month` | Analytics-optimized, business-rule enriched |
| Scripts | `scripts/` | py | Glue job code, versioned via deployment |
| Athena results | `athena-results/` | CSV/metadata | Query result staging (lifecycle-expired after 30 days) |
