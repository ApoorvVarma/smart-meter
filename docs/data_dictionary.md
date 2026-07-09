# Data Dictionary — CEEW Smart Meter Dataset

Source: [Kaggle — electricity smart meter data from India](https://www.kaggle.com/datasets/pythonafroz/electricity-smart-meter-data-from-india)
(CEEW deployment in Bareilly and Mathura, Uttar Pradesh; ~3-minute interval readings, 2019–2021,
21.4M rows across 6 interval files + 2 daily-aggregated files.)

## Raw schema (interval files)

| Raw column | Curated name | Type | Description | Example |
|---|---|---|---|---|
| `x_Timestamp` | `reading_ts` | timestamp | Reading time, 3-minute cadence, local time (IST) | `2020-01-01 00:03:00` |
| `t_kWh` | `energy_kwh` | double | Energy consumed **during the interval** (kWh) | `0.002` |
| `z_Avg Voltage (Volt)` | `avg_voltage` | double | Average supply voltage over the interval; nominal 230 V single-phase | `251.26` |
| `z_Avg Current (Amp)` | `avg_current` | double | Average current drawn over the interval | `0.15` |
| `y_Freq (Hz)` | `frequency_hz` | double | Average grid frequency; nominal 50 Hz | `49.97` |
| `meter` | `meter_id` | string | Meter identifier: `BR*` = Bareilly, `MH*` = Mathura | `BR02` |

The two `*Aggregated.csv` files contain daily rollups (`meter, Date, t_kWh`) and are
excluded from the pipeline (we derive our own aggregates from interval data).

## Column identification (per project spec)

- **Meter ID** → `meter`
- **Timestamp** → `x_Timestamp`
- **Voltage** → `z_Avg Voltage (Volt)`
- **Current** → `z_Avg Current (Amp)`
- **Power** → *not present in raw*; derived in ETL as `power_kw = V × I / 1000`
  (apparent power approximation, PF assumed ≈ 1 for residential LT loads)
- **Energy Consumption** → `t_kWh`

## Curated schema (adds derived columns)

| Column | Type | Derivation |
|---|---|---|
| `year`, `month` | int (partition) | from `reading_ts` |
| `day`, `hour` | int | from `reading_ts` |
| `day_of_week` | string | `Monday`…`Sunday` |
| `is_weekend` | boolean | Saturday/Sunday |
| `power_kw` | double | `avg_voltage × avg_current / 1000` |
| `voltage_band` | string | `OVER_VOLTAGE` (>240), `NORMAL` (220–240), `LOW` (200–220), `CRITICAL_LOW` (<200) |
| `current_band` | string | `HIGH_LOAD` (>9 A), `MEDIUM_LOAD` (3–9), `LIGHT_LOAD` (>0–3), `NO_LOAD` (0) |
| `power_band` | string | `HIGH` (>2 kW), `MEDIUM` (0.5–2), `LOW` (>0–0.5), `IDLE` (0) |
| `health_score` | double | 100 − penalties (voltage ±, over-current, frequency deviation, zero-energy-while-energized); floor 0 |
| `health_status` | string | `CRITICAL` (V>240), `WARNING` (V<200), `HIGH_LOAD` (I>9 A), `POSSIBLE_METER_ISSUE` (energized, ~0 kWh), `HEALTHY` |

## Data quality findings (local validation, all 6 interval files)

- Rows in: **21,394,429** → rows out: **21,393,836** (99.997% retained)
- Exact duplicates: ~0 within files; a small number of duplicate `(meter, ts)` keys across chunk boundaries
- Nulls: 0 in required columns
- Out-of-physical-range readings removed: 593 (e.g. voltage > 400 V spikes)
- Notable characteristics (not errors, handled by business rules):
  - Voltage = 0 / frequency = 0 rows → supply outages
  - Sustained `energy_kwh = 0` while voltage present → possible meter/CT issue
  - Voltage frequently **above 240 V** in this feeder area — drives the over-voltage analytics
- Expected 480 readings/meter/day (3-min cadence); completeness query (#28) flags gaps

Full run log: [local_validation_report.txt](local_validation_report.txt)
