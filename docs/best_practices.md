# Best Practices Applied

## Data Lake Architecture

- **Raw zone (`raw/`)** — immutable, as-landed CSVs. Never mutated; any bug in
  downstream logic can be fixed by re-running ETL from raw. One prefix per logical
  dataset (`raw/meter_readings/`) so crawlers map prefix → table cleanly.
- **Curated zone (`curated/`)** — analytics-ready, schema-enforced, business-rule
  enriched Parquet. Consumers (Athena/QuickSight) only ever touch curated.
- **Separation of concerns** — `scripts/` (code) and `athena-results/` (transient
  query output) are isolated prefixes with their own access rules and lifecycle.

## File format

- **Parquet**: columnar (Athena reads only referenced columns), typed schema
  travels with the data, splittable for parallelism.
- **Snappy compression**: ~85–90% size reduction on this dataset with negligible
  CPU cost; the Athena default and safe choice.
- **Partitioning `year/month`**: matches the dominant query filter (time). Avoid
  over-partitioning (e.g. by day+meter → millions of tiny files); two levels keep
  partitions ~10–100 MB.
- **Avoid small files**: `repartition("year","month")` before write produces few,
  larger Parquet files per partition.

## Glue

- Job bookmarks (transformation_ctx) for incremental runs when new files land.
- Defensive column matching — crawler-normalized names differ across classifiers.
- Explicit casts + range filters: never trust inferred CSV types.
- G.1X auto-scaled workers; timeout set; metrics + continuous logging enabled.
- Crawler with `--table-prefix` and a single prefix target to prevent table sprawl.

## Athena optimization

- Always filter on partition columns (`year`, `month`) first.
- `SELECT` only needed columns — never `SELECT *` on interval tables.
- Use `approx_percentile`/`approx_distinct` where exactness isn't required.
- CTEs + window functions instead of self-joins (see queries.sql #16, #23).
- Dedicated workgroup with result location, per-query scan cap, and metrics.
- `MSCK REPAIR TABLE` (or partition projection for high-cardinality) after loads.

## QuickSight optimization

- SPICE import of an **hourly pre-aggregate**, not 21M interval rows; daily
  scheduled refresh after ETL.
- Dataset-level calculated fields (health flags) instead of per-visual calcs.
- ML forecast/anomaly widgets on aggregated series (fast + more accurate).
- Row-level security by town (BR/MH) if multiple ops teams onboard.

## CloudWatch monitoring

- Event-driven failure alerts (EventBridge → SNS) for job/crawler — no polling.
- Duration alarm catches hangs before the job timeout burns DPU-hours.
- Athena workgroup metrics watch both failures and bytes scanned (cost creep).
- One ops dashboard aggregating Glue, Athena, S3 signals.

## IAM security

- Least privilege per principal: Glue writes only `curated/`; analysts read-only
  on curated + write only to `athena-results/`; raw is write-once by ingest.
- Resource-scoped ARNs (bucket/prefix, specific database/tables, one workgroup).
- Default bucket encryption (SSE-S3), TLS-only bucket policy, no public access.
- Temporary credentials (STS session) rather than long-lived keys.
