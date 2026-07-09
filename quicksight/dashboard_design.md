# QuickSight Dashboard Design — "Smart Meter Operations & Health"

**Data source:** Athena workgroup `meter-health-wg` → `meter_health_db.meter_readings_curated`

## ⚠️ Dataset import mode: SPICE — required, not optional

When creating the QuickSight dataset, on the "Finish dataset creation" screen you
**must** select **Import to SPICE for quicker analytics** (the default option) —
do **not** select "Directly query your data". This project requires SPICE because:

- **ML Insights** (forecast, anomaly detection — used throughout this dashboard)
  only run against SPICE datasets, not direct-query datasets.
- **Cost/performance**: without SPICE, every filter click re-runs the Athena query
  against 21M+ curated rows and re-bills bytes scanned; SPICE loads once and all
  interactions are free/instant afterward.
- **Consistency**: SPICE gives every viewer/session the same as-of-refresh
  snapshot instead of drifting live results.

Steps in the console:
1. QuickSight → **Datasets → New dataset → Athena** → data source name
   `meter-health-athena` → workgroup `meter-health-wg`.
2. Choose **Use custom SQL** and paste the hourly-aggregate query below (not the
   raw 21M-row table — SPICE has a per-dataset row/capacity limit, and BI doesn't
   need interval grain).
3. On the next screen, select **Import to SPICE for quicker analytics** → **Visualize**.
4. After the dataset is created: **Dataset → Refresh → Schedule a refresh** → daily,
   timed to run after the nightly Glue job finishes (e.g. 03:00 local).

For SPICE efficiency, build the dataset from a custom SQL that pre-aggregates to
hourly grain (interval grain × 21M rows is unnecessary for BI):

```sql
SELECT meter_id, year, month, day, hour, day_of_week, is_weekend,
       date_trunc('hour', reading_ts)      AS hour_ts,
       sum(energy_kwh)                     AS energy_kwh,
       avg(avg_voltage)                    AS avg_voltage,
       avg(avg_current)                    AS avg_current,
       avg(power_kw)                       AS avg_power_kw,
       max(power_kw)                       AS peak_power_kw,
       avg(health_score)                   AS health_score,
       min_by(health_status, health_score) AS worst_health_status
FROM meter_health_db.meter_readings_curated
GROUP BY 1,2,3,4,5,6,7,8
```

## Layout (3 sheets)

### Sheet 1 — Executive Overview

**Row 1 — KPI tiles (7 KPIs):**

| KPI | Visual | Field / calc |
|---|---|---|
| Total Meters | KPI | `distinct_count(meter_id)` |
| Healthy Meters | KPI (green) | `distinct_countIf(meter_id, worst_health_status='HEALTHY')` |
| Warning Meters | KPI (amber) | `distinct_countIf(meter_id, worst_health_status='WARNING')` |
| Critical Meters | KPI (red) | `distinct_countIf(meter_id, worst_health_status='CRITICAL')` |
| Avg Daily Consumption | KPI | `sum(energy_kwh) / distinct_count(truncDate('DD', hour_ts)) / distinct_count(meter_id)` |
| Average Voltage | KPI | `avg(avg_voltage)` |
| Average Current | KPI | `avg(avg_current)` |

**Row 2:**
- **Gauge — Average Health Score**: `avg(health_score)`, axis 0–100, bands
  red < 60, amber 60–80, green > 80.
- **Pie — Health Distribution**: `worst_health_status` by
  `distinct_count(meter_id)`; colors: HEALTHY green, WARNING amber, CRITICAL red,
  HIGH_LOAD purple, POSSIBLE_METER_ISSUE grey.

**Row 3:**
- **Line — Monthly Consumption** (`hour_ts` aggregated MONTH, `sum(energy_kwh)`)
  → **enable ML Forecast, 3 periods ahead, 90% interval** — this is the
  energy-consumption prediction widget.
- **Bar — Meter Health Status**: count of meters by `worst_health_status`.

### Sheet 2 — Consumption Analytics

- **Line — Daily Consumption** (`hour_ts` by DAY, `sum(energy_kwh)`), with
  ML Forecast 14 days ahead + **ML anomaly detection insight** widget beside it
  ("Top consumption anomalies" auto-narrative).
- **Horizontal bar — Top 10 Consumers**: `meter_id` by `sum(energy_kwh)`, sorted desc.
- **Heat map — Hour vs Consumption**: rows `day_of_week` (Mon→Sun), columns
  `hour` (0–23), values `sum(energy_kwh)`, sequential color ramp.
- **Line — Weekend vs Weekday** consumption trend (color by `is_weekend`).
- **Combo — Avg vs Peak power by hour**: bars `avg(avg_power_kw)`, line
  `max(peak_power_kw)`.
- **Insight widget — Forecast narrative**: auto "expected consumption next month"
  from the monthly line.

### Sheet 3 — Power Quality & Meter Health

- **Line — Voltage Trend**: `avg(avg_voltage)` by day, reference lines at 240 V
  (red) and 200 V (amber).
- **Line — Current Trend**: `avg(avg_current)` by day.
- **Bar — Voltage band distribution**: readings by `voltage_band`.
- **Table — Top 20 Unhealthy Meters**: `meter_id`, `avg(health_score)` (conditional
  red formatting < 60), `% CRITICAL readings`, `% WARNING readings`; sorted by
  score asc.
- **Line — Health Score Trend**: `avg(health_score)` by month, y-axis 0–100.
- **Bar — Outage hours by meter** (top 20): built on A3 insights query as a second
  dataset, or calc `countIf(avg_voltage = 0) * 3 / 60`.

## Interactivity

- **Filters (all sheets):** date range on `hour_ts`; multi-select `meter_id`;
  `town` (calculated field `left(meter_id, 2)`: BR = Bareilly, MH = Mathura);
  `worst_health_status`.
- **Actions:** click a meter in "Top Unhealthy Meters" table → filters sheets 2–3
  to that meter (navigation + filter action).
- **Refresh:** SPICE dataset, daily scheduled refresh after the nightly Glue run
  (see setup steps above — this dashboard will not render ML forecast/anomaly
  widgets on a direct-query dataset).

## Prediction & ML Insights summary (no SageMaker needed)

| Insight | Mechanism |
|---|---|
| Monthly consumption forecast (3 mo) | QuickSight ML forecast on monthly line chart |
| Daily consumption forecast (14 d) | QuickSight ML forecast on daily line chart |
| Consumption anomalies | QuickSight ML anomaly-detection insight widget |
| Per-meter next-day / next-month prediction | Athena SQL regression (insights.sql P1/P2) surfaced as a table visual |
| Seasonality index, segmentation, theft indicators, outages, peak-demand contributors | Athena SQL (insights.sql P4, A1–A6) as additional QuickSight datasets |

## Theming

- 12-column layout, KPI tiles 3-col each; consistent green/amber/red semantics for
  health everywhere; title block with last-refresh timestamp parameter.
