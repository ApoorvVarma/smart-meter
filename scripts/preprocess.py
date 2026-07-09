#!/usr/bin/env python3
"""
Local data validation & cleaning for the CEEW smart-meter dataset (Part 4).

For each raw interval CSV this script:
  1. Reads the CSV (chunked, so 300 MB files are fine on a laptop)
  2. Prints the schema
  3. Removes exact-duplicate rows
  4. Removes rows with null values in required columns
  5. Fixes data types (timestamp, floats, meter id as string)
  6. Drops physically impossible readings (negative energy, voltage > 400 V, etc.)
  7. Prints summary statistics
  8. Writes a cleaned CSV to datasets/cleaned/

Usage:
    python scripts/preprocess.py                       # all interval CSVs in datasets/
    python scripts/preprocess.py --file "SM Cleaned Data MH2021.csv"
"""
import argparse
from pathlib import Path

import pandas as pd

RAW_COLUMNS = {
    "x_Timestamp": "reading_ts",
    "t_kWh": "energy_kwh",
    "z_Avg Voltage (Volt)": "avg_voltage",
    "z_Avg Current (Amp)": "avg_current",
    "y_Freq (Hz)": "frequency_hz",
    "meter": "meter_id",
}

# Physical sanity limits for Indian LT single-phase supply (nominal 230 V / 50 Hz)
LIMITS = {
    "energy_kwh": (0.0, 50.0),      # kWh per 3-minute interval
    "avg_voltage": (0.0, 400.0),
    "avg_current": (0.0, 200.0),
    "frequency_hz": (0.0, 70.0),    # 0 kept: meter reports 0 during outage
}

CHUNK = 500_000


def clean_file(path: Path, out_dir: Path) -> dict:
    print(f"\n=== {path.name} ===")
    stats = {"rows_in": 0, "dupes": 0, "nulls": 0, "out_of_range": 0, "rows_out": 0}
    cleaned_chunks = []

    for chunk in pd.read_csv(path, chunksize=CHUNK):
        stats["rows_in"] += len(chunk)
        missing = [c for c in RAW_COLUMNS if c not in chunk.columns]
        if missing:
            raise ValueError(f"{path.name}: missing expected columns {missing}")
        chunk = chunk.rename(columns=RAW_COLUMNS)[list(RAW_COLUMNS.values())]

        before = len(chunk)
        chunk = chunk.drop_duplicates()
        stats["dupes"] += before - len(chunk)

        before = len(chunk)
        chunk = chunk.dropna()
        stats["nulls"] += before - len(chunk)

        # Fix data types
        chunk["reading_ts"] = pd.to_datetime(chunk["reading_ts"], errors="coerce")
        for col in ("energy_kwh", "avg_voltage", "avg_current", "frequency_hz"):
            chunk[col] = pd.to_numeric(chunk[col], errors="coerce")
        chunk["meter_id"] = chunk["meter_id"].astype(str).str.strip()
        before = len(chunk)
        chunk = chunk.dropna()  # rows that failed type coercion
        stats["nulls"] += before - len(chunk)

        # Range checks
        before = len(chunk)
        for col, (lo, hi) in LIMITS.items():
            chunk = chunk[(chunk[col] >= lo) & (chunk[col] <= hi)]
        stats["out_of_range"] += before - len(chunk)

        cleaned_chunks.append(chunk)

    df = pd.concat(cleaned_chunks, ignore_index=True)
    # Duplicates can also straddle chunk boundaries
    before = len(df)
    df = df.drop_duplicates(subset=["meter_id", "reading_ts"]).sort_values(
        ["meter_id", "reading_ts"]
    )
    stats["dupes"] += before - len(df)
    stats["rows_out"] = len(df)

    print("Schema:")
    print(df.dtypes.to_string())
    print("\nSummary statistics:")
    print(df.describe(include="all").to_string())
    print(f"\nMeters: {df['meter_id'].nunique()}  "
          f"Range: {df['reading_ts'].min()} -> {df['reading_ts'].max()}")
    print(f"Rows in={stats['rows_in']:,}  dupes={stats['dupes']:,}  "
          f"nulls={stats['nulls']:,}  out_of_range={stats['out_of_range']:,}  "
          f"out={stats['rows_out']:,}")

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"cleaned_{path.stem.replace(' ', '_').lower()}.csv"
    df.to_csv(out_path, index=False)
    print(f"Wrote {out_path} ({out_path.stat().st_size/1e6:.1f} MB)")
    return stats


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--datasets", default="datasets")
    parser.add_argument("--file", help="Clean only this file (name relative to datasets/)")
    args = parser.parse_args()

    data_dir = Path(args.datasets)
    out_dir = data_dir / "cleaned"

    if args.file:
        files = [data_dir / args.file]
    else:
        # Interval-level files only (the *Aggregated* files have a different schema)
        files = [p for p in sorted(data_dir.glob("*.csv")) if "Aggregated" not in p.name]

    totals = {"rows_in": 0, "rows_out": 0}
    for f in files:
        s = clean_file(f, out_dir)
        totals["rows_in"] += s["rows_in"]
        totals["rows_out"] += s["rows_out"]

    print(f"\nDONE. {totals['rows_in']:,} rows in -> {totals['rows_out']:,} rows out "
          f"across {len(files)} file(s)")


if __name__ == "__main__":
    main()
