-- ============================================================================
-- Smart Meter Health Monitoring — Athena SQL
-- Database: meter_health_db
-- Curated table over Parquet written by glue_etl.py (partitioned year, month)
-- Replace <BUCKET> with your bucket name (e.g. meter-health-demo-<account-id>)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0a. Workgroup setup note: set query result location to
--     s3://<BUCKET>/athena-results/ in the Athena workgroup settings.
-- ----------------------------------------------------------------------------

-- 0b. DDL — external table over the curated zone
--     (Alternatively run a second Glue crawler on curated/ to create this.)
CREATE EXTERNAL TABLE IF NOT EXISTS meter_health_db.meter_readings_curated (
    reading_ts    timestamp,
    energy_kwh    double,
    avg_voltage   double,
    avg_current   double,
    frequency_hz  double,
    meter_id      string,
    day           int,
    hour          int,
    day_of_week   string,
    is_weekend    boolean,
    power_kw      double,
    voltage_band  string,
    current_band  string,
    power_band    string,
    health_score  double,
    health_status string
)
PARTITIONED BY (year int, month int)
STORED AS PARQUET
LOCATION 's3://<BUCKET>/curated/meter_readings/'
TBLPROPERTIES ('parquet.compression' = 'SNAPPY');

-- 0c. Load partitions after every ETL run
MSCK REPAIR TABLE meter_health_db.meter_readings_curated;

-- ============================================================================
-- BUSINESS QUERIES
-- ============================================================================

-- 1. Average daily consumption per meter
SELECT meter_id,
       date(reading_ts)      AS reading_date,
       round(sum(energy_kwh), 3) AS daily_kwh
FROM meter_health_db.meter_readings_curated
GROUP BY meter_id, date(reading_ts)
ORDER BY meter_id, reading_date;

-- 2. Fleet-wide average daily consumption
WITH per_meter_daily AS (
    SELECT meter_id, date(reading_ts) AS reading_date, sum(energy_kwh) AS daily_kwh
    FROM meter_health_db.meter_readings_curated
    GROUP BY meter_id, date(reading_ts)
)
SELECT reading_date, round(avg(daily_kwh), 3) AS avg_daily_kwh_per_meter
FROM per_meter_daily
GROUP BY reading_date
ORDER BY reading_date;

-- 3. Monthly consumption per meter
SELECT meter_id, year, month,
       round(sum(energy_kwh), 2) AS monthly_kwh
FROM meter_health_db.meter_readings_curated
GROUP BY meter_id, year, month
ORDER BY year, month, meter_id;

-- 4. Top 10 consumers (total energy)
SELECT meter_id, round(sum(energy_kwh), 2) AS total_kwh
FROM meter_health_db.meter_readings_curated
GROUP BY meter_id
ORDER BY total_kwh DESC
LIMIT 10;

-- 5. Peak consumption hours (fleet)
SELECT hour, round(sum(energy_kwh), 2) AS total_kwh
FROM meter_health_db.meter_readings_curated
GROUP BY hour
ORDER BY total_kwh DESC;

-- 6. Voltage distribution by band
SELECT voltage_band,
       count(*)                             AS readings,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM meter_health_db.meter_readings_curated
GROUP BY voltage_band
ORDER BY readings DESC;

-- 7. Current distribution by band
SELECT current_band,
       count(*) AS readings,
       round(avg(avg_current), 2) AS avg_amps
FROM meter_health_db.meter_readings_curated
GROUP BY current_band
ORDER BY readings DESC;

-- 8. Meter health summary (latest month)
SELECT health_status,
       count(*) AS readings,
       count(DISTINCT meter_id) AS meters,
       round(avg(health_score), 1) AS avg_score
FROM meter_health_db.meter_readings_curated
WHERE year = (SELECT max(year) FROM meter_health_db.meter_readings_curated)
GROUP BY health_status
ORDER BY readings DESC;

-- 9. Health score trend (monthly fleet average)
SELECT year, month, round(avg(health_score), 2) AS avg_health_score
FROM meter_health_db.meter_readings_curated
GROUP BY year, month
ORDER BY year, month;

-- 10. Weekend vs weekday consumption
SELECT is_weekend,
       round(sum(energy_kwh), 2) AS total_kwh,
       round(avg(energy_kwh), 5) AS avg_interval_kwh
FROM meter_health_db.meter_readings_curated
GROUP BY is_weekend;

-- 11. Power consumption by hour of day (average kW demand)
SELECT hour, round(avg(power_kw), 3) AS avg_power_kw,
       round(max(power_kw), 3) AS max_power_kw
FROM meter_health_db.meter_readings_curated
GROUP BY hour
ORDER BY hour;

-- 12. Meters with abnormal voltage (>5% of readings out of 220-240 V)
SELECT meter_id,
       count(*) AS total_readings,
       sum(CASE WHEN avg_voltage NOT BETWEEN 220 AND 240 THEN 1 ELSE 0 END) AS abnormal,
       round(100.0 * sum(CASE WHEN avg_voltage NOT BETWEEN 220 AND 240 THEN 1 ELSE 0 END)
             / count(*), 2) AS abnormal_pct
FROM meter_health_db.meter_readings_curated
GROUP BY meter_id
HAVING 100.0 * sum(CASE WHEN avg_voltage NOT BETWEEN 220 AND 240 THEN 1 ELSE 0 END)
       / count(*) > 5
ORDER BY abnormal_pct DESC;

-- 13. Top 20 unhealthiest meters (lowest average health score)
SELECT meter_id,
       round(avg(health_score), 1) AS avg_health_score,
       count(*) AS readings
FROM meter_health_db.meter_readings_curated
GROUP BY meter_id
ORDER BY avg_health_score ASC
LIMIT 20;

-- 14. Maximum daily load per meter
SELECT meter_id, date(reading_ts) AS reading_date,
       round(max(power_kw), 3) AS peak_kw
FROM meter_health_db.meter_readings_curated
GROUP BY meter_id, date(reading_ts)
ORDER BY peak_kw DESC
LIMIT 50;

-- 15. Minimum daily load (base load) per meter
SELECT meter_id, date(reading_ts) AS reading_date,
       round(min(power_kw), 4) AS base_load_kw
FROM meter_health_db.meter_readings_curated
WHERE power_kw > 0
GROUP BY meter_id, date(reading_ts)
ORDER BY base_load_kw ASC
LIMIT 50;

-- 16. Overall consumption trend (daily fleet total, 7-day moving average)
WITH daily AS (
    SELECT date(reading_ts) AS d, sum(energy_kwh) AS kwh
    FROM meter_health_db.meter_readings_curated
    GROUP BY date(reading_ts)
)
SELECT d, round(kwh, 2) AS daily_kwh,
       round(avg(kwh) OVER (ORDER BY d ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2)
           AS kwh_7day_ma
FROM daily
ORDER BY d;

-- 17. Voltage trend by month (min / avg / max)
SELECT year, month,
       round(min(avg_voltage), 1) AS min_v,
       round(avg(avg_voltage), 1) AS avg_v,
       round(max(avg_voltage), 1) AS max_v
FROM meter_health_db.meter_readings_curated
GROUP BY year, month
ORDER BY year, month;

-- 18. Over-voltage (CRITICAL) incidents per meter per month
SELECT meter_id, year, month, count(*) AS critical_readings
FROM meter_health_db.meter_readings_curated
WHERE health_status = 'CRITICAL'
GROUP BY meter_id, year, month
ORDER BY critical_readings DESC
LIMIT 50;

-- 19. Possible dead / faulty meters (energized but ~zero consumption for a day)
SELECT meter_id, date(reading_ts) AS reading_date,
       count(*) AS zero_readings
FROM meter_health_db.meter_readings_curated
WHERE health_status = 'POSSIBLE_METER_ISSUE'
GROUP BY meter_id, date(reading_ts)
HAVING count(*) > 400              -- >20 hours of a 3-min-interval day
ORDER BY zero_readings DESC;

-- 20. Frequency stability by meter (deviation from 50 Hz)
SELECT meter_id,
       round(avg(frequency_hz), 3) AS avg_hz,
       round(stddev(frequency_hz), 3) AS stddev_hz,
       sum(CASE WHEN frequency_hz NOT BETWEEN 49.5 AND 50.5 THEN 1 ELSE 0 END)
           AS out_of_band_readings
FROM meter_health_db.meter_readings_curated
WHERE frequency_hz > 0
GROUP BY meter_id
ORDER BY out_of_band_readings DESC;

-- 21. Hour x day-of-week consumption heat map (feeds QuickSight)
SELECT day_of_week, hour, round(sum(energy_kwh), 2) AS total_kwh
FROM meter_health_db.meter_readings_curated
GROUP BY day_of_week, hour
ORDER BY day_of_week, hour;

-- 22. High-load events (current > 9 A) by meter and day
SELECT meter_id, date(reading_ts) AS reading_date,
       count(*) AS high_load_intervals,
       round(max(avg_current), 2) AS peak_amps
FROM meter_health_db.meter_readings_curated
WHERE current_band = 'HIGH_LOAD'
GROUP BY meter_id, date(reading_ts)
ORDER BY high_load_intervals DESC
LIMIT 50;

-- 23. Month-over-month consumption growth per meter
WITH monthly AS (
    SELECT meter_id, year, month, sum(energy_kwh) AS kwh
    FROM meter_health_db.meter_readings_curated
    GROUP BY meter_id, year, month
)
SELECT meter_id, year, month, round(kwh, 2) AS kwh,
       round(100.0 * (kwh - lag(kwh) OVER (PARTITION BY meter_id ORDER BY year, month))
             / NULLIF(lag(kwh) OVER (PARTITION BY meter_id ORDER BY year, month), 0), 1)
           AS mom_growth_pct
FROM monthly
ORDER BY meter_id, year, month;

-- 24. Executive KPI snapshot (single row — feeds dashboard KPI tiles)
SELECT count(DISTINCT meter_id)                          AS total_meters,
       count(DISTINCT CASE WHEN health_status = 'HEALTHY' THEN meter_id END)
                                                          AS meters_seen_healthy,
       count(DISTINCT CASE WHEN health_status = 'WARNING' THEN meter_id END)
                                                          AS meters_seen_warning,
       count(DISTINCT CASE WHEN health_status = 'CRITICAL' THEN meter_id END)
                                                          AS meters_seen_critical,
       round(avg(energy_kwh), 5)                          AS avg_interval_kwh,
       round(avg(avg_voltage), 1)                         AS avg_voltage,
       round(avg(avg_current), 2)                         AS avg_current,
       round(avg(health_score), 1)                        AS avg_health_score
FROM meter_health_db.meter_readings_curated;

-- 25. Dominant health status per meter (latest month) — meter-level roll-up
WITH latest AS (
    SELECT max(year * 100 + month) AS ym
    FROM meter_health_db.meter_readings_curated
),
ranked AS (
    SELECT meter_id, health_status, count(*) AS n,
           row_number() OVER (PARTITION BY meter_id ORDER BY count(*) DESC) AS rn
    FROM meter_health_db.meter_readings_curated, latest
    WHERE year * 100 + month = latest.ym
    GROUP BY meter_id, health_status
)
SELECT health_status, count(*) AS meters
FROM ranked
WHERE rn = 1
GROUP BY health_status
ORDER BY meters DESC;

-- 26. Load factor per meter per month (avg demand / peak demand)
SELECT meter_id, year, month,
       round(avg(power_kw) / NULLIF(max(power_kw), 0), 3) AS load_factor
FROM meter_health_db.meter_readings_curated
GROUP BY meter_id, year, month
ORDER BY load_factor ASC
LIMIT 50;

-- 27. Voltage sag/swell events per day (fleet) — power quality trend
SELECT date(reading_ts) AS reading_date,
       sum(CASE WHEN avg_voltage > 240 THEN 1 ELSE 0 END) AS swell_readings,
       sum(CASE WHEN avg_voltage BETWEEN 1 AND 200 THEN 1 ELSE 0 END) AS sag_readings,
       sum(CASE WHEN avg_voltage = 0 THEN 1 ELSE 0 END)   AS outage_readings
FROM meter_health_db.meter_readings_curated
GROUP BY date(reading_ts)
ORDER BY reading_date;

-- 28. Data completeness per meter per day (expected 480 3-min intervals/day)
SELECT meter_id, date(reading_ts) AS reading_date,
       count(*) AS readings,
       round(100.0 * count(*) / 480, 1) AS completeness_pct
FROM meter_health_db.meter_readings_curated
GROUP BY meter_id, date(reading_ts)
HAVING count(*) < 432               -- flag days with <90% data
ORDER BY completeness_pct ASC
LIMIT 100;
