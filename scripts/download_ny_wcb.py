"""Download NY Workers' Compensation Board (WCB) claims from data.ny.gov as Parquet files.

Dataset: "Assembled Workers' Compensation Claims: Beginning 2000" (Socrata id jshw-gkgu)
https://data.ny.gov/d/jshw-gkgu

Run this on your own computer, then upload the Parquet files to the Snowflake stage
(see README step 3). Snowflake trial accounts cannot call the internet directly,
so the download happens locally.

Every column is written as text. Type casting happens later in Snowflake
(sql/03_features.sql), so an unexpected value never breaks the load.

Usage:
    python scripts/download_ny_wcb.py --start-year 2017 --end-year 2023
"""

import argparse
import os
import re
import sys
from pathlib import Path

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
import requests

DATASET_ID = "jshw-gkgu"
BASE_URL = "https://data.ny.gov"
PAGE_SIZE = 50_000

# Columns the feature view (sql/03_features.sql) relies on, after name normalization.
EXPECTED_COLUMNS = [
    "CLAIM_IDENTIFIER",
    "ACCIDENT_DATE",
    "ASSEMBLY_DATE",
    "ATTORNEY_REPRESENTATIVE",
    "AGE_AT_INJURY",
    "GENDER",
    "CARRIER_TYPE",
    "DISTRICT_NAME",
    "COUNTY_OF_INJURY",
    "MEDICAL_FEE_REGION",
    "INDUSTRY_CODE",
    "WCIO_CAUSE_OF_INJURY_CODE",
    "WCIO_NATURE_OF_INJURY_CODE",
    "WCIO_PART_OF_BODY_CODE",
    "COVID_19_INDICATOR",
]


def normalize_name(name: str) -> str:
    """'Attorney/Representative' -> 'ATTORNEY_REPRESENTATIVE' (a safe Snowflake identifier)."""
    return re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").upper()


def fetch_columns(session: requests.Session) -> dict[str, str]:
    """Return {socrata_field_name: normalized display name} for the dataset's data columns."""
    resp = session.get(f"{BASE_URL}/api/views/{DATASET_ID}.json", timeout=60)
    resp.raise_for_status()
    columns = {}
    for col in resp.json()["columns"]:
        field = col["fieldName"]
        if field.startswith(":"):  # Socrata system columns such as :id
            continue
        columns[field] = normalize_name(col["name"])
    return columns


def page_to_table(records: list[dict], columns: dict[str, str]) -> pa.Table:
    """Turn one page of API records into an all-string Arrow table with a fixed column set.

    The API leaves out null fields, so each page is reindexed to the full column list.
    That keeps every Parquet file's schema identical.
    """
    df = pd.DataFrame.from_records(records).reindex(columns=list(columns))
    df = df.rename(columns=columns)
    df = df.astype("string")
    schema = pa.schema([(name, pa.string()) for name in df.columns])
    return pa.Table.from_pandas(df, schema=schema, preserve_index=False)


def find_field(columns: dict[str, str], normalized: str) -> str:
    for field, name in columns.items():
        if name == normalized:
            return field
    sys.exit(f"Column {normalized!r} not found. Available: {sorted(columns.values())}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--start-year", type=int, default=2017, help="first claim assembly year (inclusive)")
    parser.add_argument("--end-year", type=int, default=2023, help="last claim assembly year (inclusive)")
    parser.add_argument("--out-dir", default="data/ny_wcb", help="where to write Parquet files")
    args = parser.parse_args()

    session = requests.Session()
    # Optional free Socrata app token: makes throttling less likely on big downloads.
    if token := os.environ.get("SOCRATA_APP_TOKEN"):
        session.headers["X-App-Token"] = token

    columns = fetch_columns(session)
    missing = [c for c in EXPECTED_COLUMNS if c not in columns.values()]
    if missing:
        print(f"WARNING: expected columns not in dataset: {missing}")
        print("sql/03_features.sql will need these names adjusted.")

    assembly_field = find_field(columns, "ASSEMBLY_DATE")
    where = (
        f"{assembly_field} between '{args.start_year}-01-01T00:00:00' "
        f"and '{args.end_year}-12-31T23:59:59'"
    )

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    offset, part, total = 0, 0, 0
    while True:
        params = {"$where": where, "$order": ":id", "$limit": PAGE_SIZE, "$offset": offset}
        resp = session.get(f"{BASE_URL}/resource/{DATASET_ID}.json", params=params, timeout=300)
        resp.raise_for_status()
        records = resp.json()
        if not records:
            break
        pq.write_table(page_to_table(records, columns), out_dir / f"part-{part:04d}.parquet")
        total += len(records)
        part += 1
        offset += PAGE_SIZE
        print(f"  wrote part {part:4d}  ({total:,} rows so far)")

    print(f"Done: {total:,} claims in {part} files under {out_dir}/")


if __name__ == "__main__":
    main()
