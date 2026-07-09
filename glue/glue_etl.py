"""
AWS Glue ETL job: smart-meter-curation
=====================================
Reads raw CEEW smart-meter CSVs from the raw zone (via the Glue Data Catalog),
cleans and enriches them, and writes partitioned Parquet to the curated zone.

Glue version : 4.0 (Spark 3.3, Python 3)
Worker type  : G.1X, 2-5 workers (auto scaling)

Job parameters (pass via --arguments or console):
    --DATABASE_NAME     meter_health_db
    --TABLE_NAME        raw            (table created by the crawler on raw/)
    --OUTPUT_PATH       s3://<bucket>/curated/meter_readings/

Transformations:
    - rename columns to snake_case business names
    - drop duplicates and nulls
    - cast types, parse timestamp
    - derive year/month/day/hour/day_of_week/is_weekend
    - derive power_kw (V * I / 1000), voltage/current/power bands
    - derive health_score (0-100) and health_status business rules
    - write Parquet, Snappy-compressed, partitioned by year, month
"""
import sys

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.types import DoubleType, StringType

args = getResolvedOptions(
    sys.argv, ["JOB_NAME", "DATABASE_NAME", "TABLE_NAME", "OUTPUT_PATH"]
)

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

# ---------------------------------------------------------------------------
# 1. Read raw data from the Glue Data Catalog
# ---------------------------------------------------------------------------
raw_dyf = glueContext.create_dynamic_frame.from_catalog(
    database=args["DATABASE_NAME"],
    table_name=args["TABLE_NAME"],
    transformation_ctx="raw_source",  # enables job bookmarks
)
df = raw_dyf.toDF()

# ---------------------------------------------------------------------------
# 2. Rename columns (crawler lower-cases and strips special chars differently
#    depending on the classifier, so match defensively)
# ---------------------------------------------------------------------------
RENAMES = {
    "x_timestamp": "reading_ts",
    "t_kwh": "energy_kwh",
    "z_avg voltage (volt)": "avg_voltage",
    "z_avg_voltage (volt)": "avg_voltage",
    "z_avg_voltage_(volt)": "avg_voltage",
    "z_avg current (amp)": "avg_current",
    "z_avg_current (amp)": "avg_current",
    "z_avg_current_(amp)": "avg_current",
    "y_freq (hz)": "frequency_hz",
    "y_freq_(hz)": "frequency_hz",
    "meter": "meter_id",
}
for old in df.columns:
    key = old.lower().strip()
    if key in RENAMES:
        df = df.withColumnRenamed(old, RENAMES[key])

required = ["reading_ts", "energy_kwh", "avg_voltage", "avg_current",
            "frequency_hz", "meter_id"]
missing = [c for c in required if c not in df.columns]
if missing:
    raise ValueError(f"Missing expected columns after rename: {missing}. "
                     f"Got: {df.columns}")
df = df.select(*required)

# ---------------------------------------------------------------------------
# 3. Type casting & timestamp parsing
# ---------------------------------------------------------------------------
df = (
    df.withColumn("reading_ts", F.to_timestamp("reading_ts", "yyyy-MM-dd HH:mm:ss"))
      .withColumn("energy_kwh", F.col("energy_kwh").cast(DoubleType()))
      .withColumn("avg_voltage", F.col("avg_voltage").cast(DoubleType()))
      .withColumn("avg_current", F.col("avg_current").cast(DoubleType()))
      .withColumn("frequency_hz", F.col("frequency_hz").cast(DoubleType()))
      .withColumn("meter_id", F.trim(F.col("meter_id").cast(StringType())))
)

# ---------------------------------------------------------------------------
# 4. Data quality: nulls, duplicates, physical range checks
# ---------------------------------------------------------------------------
df = df.dropna(subset=required)
df = df.dropDuplicates(["meter_id", "reading_ts"])
df = df.filter(
    (F.col("energy_kwh") >= 0) & (F.col("energy_kwh") <= 50)
    & (F.col("avg_voltage") >= 0) & (F.col("avg_voltage") <= 400)
    & (F.col("avg_current") >= 0) & (F.col("avg_current") <= 200)
    & (F.col("frequency_hz") >= 0) & (F.col("frequency_hz") <= 70)
)

# ---------------------------------------------------------------------------
# 5. Derived time columns
# ---------------------------------------------------------------------------
df = (
    df.withColumn("year", F.year("reading_ts"))
      .withColumn("month", F.month("reading_ts"))
      .withColumn("day", F.dayofmonth("reading_ts"))
      .withColumn("hour", F.hour("reading_ts"))
      .withColumn("day_of_week", F.date_format("reading_ts", "EEEE"))
      .withColumn("is_weekend",
                  F.dayofweek("reading_ts").isin(1, 7))  # Sun=1, Sat=7
)

# ---------------------------------------------------------------------------
# 6. Derived electrical columns & bands
# ---------------------------------------------------------------------------
df = df.withColumn(
    "power_kw", F.round(F.col("avg_voltage") * F.col("avg_current") / 1000.0, 4)
)

df = df.withColumn(
    "voltage_band",
    F.when(F.col("avg_voltage") > 240, "OVER_VOLTAGE")
     .when(F.col("avg_voltage") >= 220, "NORMAL")
     .when(F.col("avg_voltage") >= 200, "LOW")
     .otherwise("CRITICAL_LOW"),
)

# LT residential meters: > 9 A sustained is heavy load for this population
df = df.withColumn(
    "current_band",
    F.when(F.col("avg_current") > 9, "HIGH_LOAD")
     .when(F.col("avg_current") >= 3, "MEDIUM_LOAD")
     .when(F.col("avg_current") > 0, "LIGHT_LOAD")
     .otherwise("NO_LOAD"),
)

df = df.withColumn(
    "power_band",
    F.when(F.col("power_kw") > 2.0, "HIGH")
     .when(F.col("power_kw") >= 0.5, "MEDIUM")
     .when(F.col("power_kw") > 0, "LOW")
     .otherwise("IDLE"),
)

# ---------------------------------------------------------------------------
# 7. Health score (0-100) and health status business rules
#    Start at 100 and subtract penalties per interval reading.
# ---------------------------------------------------------------------------
df = df.withColumn(
    "health_score",
    F.greatest(
        F.lit(0.0),
        F.lit(100.0)
        # voltage penalties
        - F.when(F.col("avg_voltage") > 240, 30.0)
           .when(F.col("avg_voltage") < 200, 25.0)
           .when(F.col("avg_voltage") < 220, 10.0)
           .otherwise(0.0)
        # over-current penalty
        - F.when(F.col("avg_current") > 9, 20.0).otherwise(0.0)
        # frequency deviation penalty (nominal 50 Hz, band 49.5-50.5)
        - F.when((F.col("frequency_hz") < 49.5) | (F.col("frequency_hz") > 50.5),
                 15.0).otherwise(0.0)
        # dead/near-dead meter penalty: voltage present but zero energy
        - F.when((F.col("energy_kwh") <= 0.0005) & (F.col("avg_voltage") > 100),
                 20.0).otherwise(0.0),
    ),
)

df = df.withColumn(
    "health_status",
    F.when(F.col("avg_voltage") > 240, "CRITICAL")               # over-voltage
     .when(F.col("avg_voltage") < 200, "WARNING")                # under-voltage
     .when(F.col("avg_current") > 9, "HIGH_LOAD")                # over-current
     .when((F.col("energy_kwh") <= 0.0005) & (F.col("avg_voltage") > 100),
           "POSSIBLE_METER_ISSUE")                               # energized, no use
     .when((F.col("avg_voltage") >= 220) & (F.col("avg_voltage") <= 240),
           "HEALTHY")
     .otherwise("HEALTHY"),
)

# ---------------------------------------------------------------------------
# 8. Write curated Parquet, partitioned by year/month
# ---------------------------------------------------------------------------
(
    df.repartition("year", "month")
      .write.mode("overwrite")
      .partitionBy("year", "month")
      .option("compression", "snappy")
      .parquet(args["OUTPUT_PATH"])
)

print(f"Curated rows written: {df.count()}")
job.commit()
