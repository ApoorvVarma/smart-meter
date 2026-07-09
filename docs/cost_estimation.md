# Cost Estimation (us-east-1, on-demand, 2026 list prices — verify current pricing)

Pipeline: monthly pattern of 1 crawler run + 1 Glue ETL run + ~100 Athena queries +
QuickSight refresh. Prices: S3 $0.023/GB-mo; Glue $0.44/DPU-hr; crawler $0.44/DPU-hr
(min 10 min); Athena $5/TB scanned; QuickSight Author $24/mo (Enterprise), Reader from $3.

Parquet+Snappy compresses this dataset ~85–90% vs CSV, and typical dashboards scan
only recent partitions (~20% of data) — that drives the Athena numbers below.

## 100 MB raw

| Item | Estimate |
|---|---|
| S3 (raw 0.1 GB + curated ~0.015 GB) | < $0.01/mo |
| Glue crawler (10 min × 2 DPU) | ~$0.15/run |
| Glue ETL (2 × G.1X ≈ 2 DPU × ~5 min) | ~$0.07/run |
| Athena (100 queries × ~15 MB scanned) | < $0.01/mo |
| QuickSight | 1 author $24/mo (or 30-day free trial) |
| **Total (excl. QuickSight)** | **< $0.25/mo** |

## 1 GB raw (≈ this project: 1.1 GB, 21.4M rows)

| Item | Estimate |
|---|---|
| S3 (1 GB raw + ~0.15 GB curated) | ~$0.03/mo |
| Glue crawler | ~$0.15/run |
| Glue ETL (5 × G.1X = 5 DPU × ~8 min) | ~$0.30/run |
| Athena (100 queries × ~30 MB Parquet scanned) | ~$0.02/mo |
| QuickSight | $24/mo author |
| **Total (excl. QuickSight)** | **~$0.50/mo** |

## 10 GB raw

| Item | Estimate |
|---|---|
| S3 (10 GB raw + 1.5 GB curated) | ~$0.27/mo |
| Glue crawler | ~$0.30/run |
| Glue ETL (10 DPU × ~15 min) | ~$1.10/run |
| Athena (100 queries × ~300 MB scanned) | ~$0.15/mo |
| QuickSight (1 author + 5 readers) | ~$39/mo |
| **Total (excl. QuickSight)** | **~$2/mo** |

> QuickSight dominates cost at every scale; the data pipeline itself is nearly free
> at these volumes.

## Free Tier

- **S3**: 5 GB Standard, 20k GET / 2k PUT (12 months) → covers 100 MB & 1 GB tiers.
- **Glue**: 1M Data Catalog objects + 1M catalog requests/month free, always.
  Crawler/ETL DPU-hours are **not** free.
- **Athena**: no free tier ($5/TB), but scans here are tiny.
- **QuickSight**: 30-day free trial; Reader session pricing after.
- **CloudWatch**: 10 alarms + 5 GB logs free.

## Cost optimization applied in this project

1. **Parquet + Snappy** — columnar + compressed: ~10× smaller than CSV, and Athena
   reads only referenced columns → 90%+ scan reduction.
2. **Partitioning by year/month** — `WHERE year=2021 AND month=2` prunes to one
   partition; dashboards never scan full history.
3. **Athena best practices** — `LIMIT` in exploration; aggregate once into SPICE
   instead of live-querying per dashboard view; workgroup
   `BytesScannedCutoffPerQuery` (1 GiB) as a hard cost guardrail; result reuse for
   repeated queries; lifecycle rule expiring `athena-results/` after 30 days.
4. **Glue** — right-size workers (G.1X), auto-scaling, job timeout 60 min, run
   on-demand (not scheduled hourly) since the dataset is batch-static.
5. **S3 lifecycle** — transition raw/ to Infrequent Access after 90 days; expire
   Athena results.
