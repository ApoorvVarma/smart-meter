#!/usr/bin/env python3
"""
Download the CEEW India smart-meter dataset from Kaggle and stage it in datasets/.

Prerequisites:
    pip install kaggle
    # Auth (either):
    #   export KAGGLE_API_TOKEN=<token>
    #   mkdir -p ~/.kaggle && echo <token> > ~/.kaggle/access_token && chmod 600 ~/.kaggle/access_token
    # or the classic ~/.kaggle/kaggle.json with {"username": ..., "key": ...}

Usage:
    python scripts/download_dataset.py [--dest datasets/]
"""
import argparse
import subprocess
import sys
import zipfile
from pathlib import Path

DATASET = "pythonafroz/electricity-smart-meter-data-from-india"
ZIP_NAME = "electricity-smart-meter-data-from-india.zip"


def main() -> None:
    parser = argparse.ArgumentParser(description="Download smart meter dataset")
    parser.add_argument("--dest", default="datasets", help="Destination directory")
    args = parser.parse_args()

    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)

    zip_path = dest / ZIP_NAME
    if not zip_path.exists():
        print(f"Downloading {DATASET} -> {dest}/")
        subprocess.run(
            ["kaggle", "datasets", "download", DATASET, "--path", str(dest)],
            check=True,
        )
    else:
        print(f"{zip_path} already present, skipping download")

    print("Extracting ...")
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(dest)

    csvs = sorted(dest.glob("*.csv"))
    if not csvs:
        print("ERROR: no CSV files extracted", file=sys.stderr)
        sys.exit(1)

    print("Extracted CSV files:")
    total = 0
    for c in csvs:
        size = c.stat().st_size
        total += size
        print(f"  {c.name:55s} {size/1e6:8.1f} MB")
    print(f"Total: {total/1e9:.2f} GB across {len(csvs)} files")


if __name__ == "__main__":
    main()
