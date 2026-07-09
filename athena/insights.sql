-- ============================================================================
-- Advanced Insights & Energy Consumption Prediction — Athena (engine v3 / Trino)
-- All prediction is done with in-SQL statistics (regression, z-scores) plus
-- QuickSight ML forecasting on the dashboard — no SageMaker/Lambda/EMR needed.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- P1. Next-day consumption prediction per meter (linear trend over last 30 days)
--     Uses built-in regr_slope / regr_intercept over day-indexed daily totals.
-- ----------------------------------------------------------------------------
WITH daily AS (
    SELECT meter_id,
           date(reading_ts) AS d,
           sum(energy_kwh)  AS kwh
    FROM meter_health_db.meter_readings_curated
    GROUP BY meter_id, date(reading_ts)
),
windowed AS (
    SELECT meter_id, d, kwh,
           date_diff('day', min(d) OVER (PARTITION BY meter_id), d) AS day_idx,
           max(d) OVER (PARTITION BY meter_id) AS last_day
    FROM daily
),
fit AS (
    SELECT meter_id,
           regr_slope(kwh, day_idx)     AS slope,
           regr_intercept(kwh, day_idx) AS intercept,
           max(day_idx)                 AS last_idx,
           max(last_day)                AS last_day,
           avg(kwh)                     AS avg_kwh
    FROM windowed
    WHERE d >= date_add('day', -30, last_day)
    GROUP BY meter_id
)
SELECT meter_id,
       last_day,
       round(avg_kwh, 3)                                   AS avg_daily_kwh_30d,
       round(intercept + slope * (last_idx + 1), 3)        AS predicted_next_day_kwh,
       round(slope, 4)                                     AS trend_kwh_per_day
FROM fit
ORDER BY predicted_next_day_kwh DESC;

-- ----------------------------------------------------------------------------
-- P2. Next-month consumption projection per meter
--     Linear regression over monthly totals; projects one month ahead.
-- ----------------------------------------------------------------------------
WITH monthly AS (
    SELECT meter_id, year * 12 + month AS m_idx, year, month,
           sum(energy_kwh) AS kwh
    FROM meter_health_db.meter_readings_curated
    GROUP BY meter_id, year, month
),
fit AS (
    SELECT meter_id,
           regr_slope(kwh, m_idx)     AS slope,
           regr_intercept(kwh, m_idx) AS intercept,
           max(m_idx)                 AS last_m,
           count(*)                   AS months_observed
    FROM monthly
    GROUP BY meter_id
    HAVING count(*) >= 3
)
SELECT meter_id,
       months_observed,
       ((last_m + 1) - 1) / 12                AS pred_year,
       ((last_m + 1) - 1) % 12 + 1            AS pred_month,
       round(greatest(0, intercept + slope * (last_m + 1)), 2) AS predicted_kwh,
       round(slope, 2)                        AS monthly_trend_kwh
FROM fit
ORDER BY predicted_kwh DESC;

-- ----------------------------------------------------------------------------
-- P3. Typical-day load profile per meter (baseline for prediction & planning)
--     Average kWh per hour-of-day; the fleet version feeds demand forecasting.
-- ----------------------------------------------------------------------------
SELECT meter_id, hour,
       round(avg(energy_kwh) * 20, 4) AS avg_hourly_kwh   -- 20 x 3-min intervals/hr
FROM meter_health_db.meter_readings_curated
GROUP BY meter_id, hour
ORDER BY meter_id, hour;

-- ----------------------------------------------------------------------------
-- P4. Seasonal pattern: month-of-year consumption index (fleet)
--     Index >1 = above-average month (cooling/heating season detection).
-- ----------------------------------------------------------------------------
WITH monthly AS (
    SELECT month, sum(energy_kwh) / count(DISTINCT meter_id) AS kwh_per_meter
    FROM meter_health_db.meter_readings_curated
    GROUP BY month
)
SELECT month,
       round(kwh_per_meter, 2) AS kwh_per_meter,
       round(kwh_per_meter / avg(kwh_per_meter) OVER (), 3) AS seasonal_index
FROM monthly
ORDER BY month;

-- ----------------------------------------------------------------------------
-- A1. Anomaly detection: days where a meter's usage deviates >3 sigma from
--     its own 30-day rolling mean (spike or collapse).
-- ----------------------------------------------------------------------------
WITH daily AS (
    SELECT meter_id, date(reading_ts) AS d, sum(energy_kwh) AS kwh
    FROM meter_health_db.meter_readings_curated
    GROUP BY meter_id, date(reading_ts)
),
scored AS (
    SELECT meter_id, d, kwh,
           avg(kwh)    OVER w AS mu,
           stddev(kwh) OVER w AS sigma
    FROM daily
    WINDOW w AS (PARTITION BY meter_id ORDER BY d ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING)
)
SELECT meter_id, d, round(kwh, 3) AS kwh,
       round(mu, 3) AS rolling_mean_30d,
       round((kwh - mu) / NULLIF(sigma, 0), 2) AS z_score,
       CASE WHEN kwh > mu THEN 'SPIKE' ELSE 'COLLAPSE' END AS anomaly_type
FROM scored
WHERE sigma > 0 AND abs(kwh - mu) > 3 * sigma
ORDER BY abs((kwh - mu) / sigma) DESC
LIMIT 200;

-- ----------------------------------------------------------------------------
-- A2. Possible theft / tamper indicator: meter whose consumption dropped >60%
--     month-over-month while the rest of its town grew or stayed flat.
-- ----------------------------------------------------------------------------
WITH monthly AS (
    SELECT meter_id,
           substr(meter_id, 1, 2) AS town,       -- BR = Bareilly, MH = Mathura
           year, month, sum(energy_kwh) AS kwh
    FROM meter_health_db.meter_readings_curated
    GROUP BY meter_id, substr(meter_id, 1, 2), year, month
),
with_lag AS (
    SELECT *,
           lag(kwh) OVER (PARTITION BY meter_id ORDER BY year, month) AS prev_kwh
    FROM monthly
),
town_trend AS (
    SELECT town, year, month,
           sum(kwh) / NULLIF(sum(prev_kwh), 0) AS town_ratio
    FROM with_lag
    GROUP BY town, year, month
)
SELECT w.meter_id, w.year, w.month,
       round(w.prev_kwh, 1) AS prev_month_kwh,
       round(w.kwh, 1)      AS this_month_kwh,
       round(100.0 * (w.kwh / NULLIF(w.prev_kwh, 0) - 1), 1) AS meter_change_pct,
       round(100.0 * (t.town_ratio - 1), 1)                  AS town_change_pct
FROM with_lag w
JOIN town_trend t ON w.town = t.town AND w.year = t.year AND w.month = t.month
WHERE w.prev_kwh > 5                       -- ignore near-zero meters
  AND w.kwh < 0.4 * w.prev_kwh             -- >60% drop
  AND t.town_ratio > 0.9                   -- town itself did not drop
ORDER BY meter_change_pct ASC;

-- ----------------------------------------------------------------------------
-- A3. Outage analysis: count and duration of zero-voltage spells per meter/day
-- ----------------------------------------------------------------------------
SELECT meter_id, date(reading_ts) AS d,
       count(*)                    AS outage_intervals,
       round(count(*) * 3 / 60.0, 2) AS est_outage_hours
FROM meter_health_db.meter_readings_curated
WHERE avg_voltage = 0
GROUP BY meter_id, date(reading_ts)
HAVING count(*) >= 10                       -- >= 30 minutes without supply
ORDER BY est_outage_hours DESC
LIMIT 100;

-- ----------------------------------------------------------------------------
-- A4. Consumer segmentation by usage level & pattern (SQL-based clustering)
-- ----------------------------------------------------------------------------
WITH per_meter AS (
    SELECT meter_id,
           avg(energy_kwh) * 480          AS avg_daily_kwh,   -- 480 intervals/day
           stddev(energy_kwh) / NULLIF(avg(energy_kwh), 0) AS variability,
           avg(CASE WHEN hour BETWEEN 18 AND 23 THEN energy_kwh END)
             / NULLIF(avg(energy_kwh), 0) AS evening_ratio
    FROM meter_health_db.meter_readings_curated
    GROUP BY meter_id
)
SELECT meter_id,
       round(avg_daily_kwh, 2) AS avg_daily_kwh,
       CASE WHEN avg_daily_kwh >= 8 THEN 'HIGH'
            WHEN avg_daily_kwh >= 3 THEN 'MEDIUM'
            ELSE 'LOW' END AS usage_segment,
       CASE WHEN evening_ratio > 1.3 THEN 'EVENING_PEAKER'
            WHEN variability   > 2.0 THEN 'ERRATIC'
            ELSE 'FLAT' END AS pattern_segment
FROM per_meter
ORDER BY avg_daily_kwh DESC;

-- ----------------------------------------------------------------------------
-- A5. Voltage-quality league table by town (regulatory reporting: % time
--     within IS 12360 band 216.2-253 V, and within contract band 220-240 V)
-- ----------------------------------------------------------------------------
SELECT substr(meter_id, 1, 2) AS town,
       count(*) AS readings,
       round(100.0 * sum(CASE WHEN avg_voltage BETWEEN 216.2 AND 253 THEN 1 ELSE 0 END)
             / count(*), 2) AS pct_within_is12360,
       round(100.0 * sum(CASE WHEN avg_voltage BETWEEN 220 AND 240 THEN 1 ELSE 0 END)
             / count(*), 2) AS pct_within_220_240
FROM meter_health_db.meter_readings_curated
WHERE avg_voltage > 0
GROUP BY substr(meter_id, 1, 2);

-- ----------------------------------------------------------------------------
-- A6. Peak-demand contribution: which meters drive the fleet's top-1% demand
--     intervals (targets for demand-response programs)
-- ----------------------------------------------------------------------------
WITH fleet AS (
    SELECT reading_ts, sum(power_kw) AS fleet_kw
    FROM meter_health_db.meter_readings_curated
    GROUP BY reading_ts
),
threshold AS (
    SELECT approx_percentile(fleet_kw, 0.99) AS p99 FROM fleet
),
peaks AS (
    SELECT f.reading_ts FROM fleet f, threshold t WHERE f.fleet_kw >= t.p99
)
SELECT m.meter_id,
       count(*)                    AS peak_intervals,
       round(avg(m.power_kw), 3)   AS avg_kw_during_peaks,
       round(sum(m.power_kw) / (SELECT sum(fleet_kw) FROM fleet
                                WHERE reading_ts IN (SELECT reading_ts FROM peaks)) * 100, 2)
                                    AS pct_of_peak_load
FROM meter_health_db.meter_readings_curated m
JOIN peaks p ON m.reading_ts = p.reading_ts
GROUP BY m.meter_id
ORDER BY pct_of_peak_load DESC
LIMIT 20;
