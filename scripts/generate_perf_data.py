#!/usr/bin/env python3
"""Generate a large hive-partitioned orders dataset for perf comparison.

Writes ~1M rows of orders as Parquet files partitioned by order_year/order_month
in hive-style paths: data/partitioned/orders/order_year=YYYY/order_month=MM/*.parquet

Also writes the same data as a single partitioned Iceberg table via pyiceberg.
"""

import argparse
import random
from datetime import datetime, timedelta

import boto3
import pyarrow as pa
import pyarrow.parquet as pq
from pyiceberg.catalog.glue import GlueCatalog
from pyiceberg.partitioning import PartitionField, PartitionSpec
from pyiceberg.schema import Schema
from pyiceberg.table.sorting import SortField, SortOrder
from pyiceberg.transforms import IdentityTransform
from pyiceberg.types import (
    DoubleType,
    IntegerType,
    NestedField,
    StringType,
)

BUCKET = "dmichalk-glue-sandbox"
REGION = "us-west-2"
GLUE_DB = "dmichalk_sandbox_db"

PRODUCTS = [
    "Dog Food - Chicken 30lb", "Dog Food - Beef 15lb", "Cat Food - Salmon 12pk",
    "Cat Litter - Clumping 40lb", "Dog Treats - Dental 24ct", "Cat Treats - Tuna 6pk",
    "Dog Toy - Rope Large", "Cat Toy - Feather Wand", "Pet Bed - Large Orthopedic",
    "Pet Bed - Small Round", "Dog Leash - Retractable", "Cat Scratcher - Tower",
    "Fish Food - Tropical Flakes", "Bird Seed - Premium Mix", "Hamster Wheel - Silent",
    "Reptile Heat Lamp - 75W", "Dog Shampoo - Oatmeal", "Cat Carrier - Medium",
    "Flea Collar - Dog Large", "Flea Collar - Cat", "Dog Bowl - Stainless 32oz",
    "Cat Fountain - Ceramic", "Puppy Pads - 100ct", "Dog Crate - 42in",
    "Cat Tree - 6ft", "Aquarium Filter - 30gal", "Dog Harness - No Pull",
    "Cat Litter Box - Self Clean", "Dog Jacket - Winter XL", "Bird Cage - Flight",
]

TIERS = ["bronze", "silver", "gold", "platinum"]


def generate_partitioned_orders(
    n_rows: int = 1_000_000,
    n_customers: int = 50_000,
    start_year: int = 2022,
    end_year: int = 2025,
):
    """Generate n_rows orders spread across years/months."""
    random.seed(42)

    start = datetime(start_year, 1, 1)
    end = datetime(end_year, 12, 31)
    delta_days = (end - start).days

    order_ids = list(range(1, n_rows + 1))
    customer_ids = [random.randint(1, n_customers) for _ in range(n_rows)]
    products = [random.choice(PRODUCTS) for _ in range(n_rows)]
    amounts = [round(random.uniform(5.99, 249.99), 2) for _ in range(n_rows)]
    tiers = [random.choice(TIERS) for _ in range(n_rows)]
    dates = [start + timedelta(days=random.randint(0, delta_days)) for _ in range(n_rows)]

    order_years = [d.year for d in dates]
    order_months = [d.month for d in dates]
    order_dates = [d.strftime("%Y-%m-%d") for d in dates]

    return pa.table({
        "order_id": pa.array(order_ids, type=pa.int32()),
        "customer_id": pa.array(customer_ids, type=pa.int32()),
        "product": products,
        "amount": amounts,
        "customer_tier": tiers,
        "order_date": order_dates,
        "order_year": pa.array(order_years, type=pa.int32()),
        "order_month": pa.array(order_months, type=pa.int32()),
    })


def upload_hive_partitioned(table: pa.Table, bucket: str, prefix: str, region: str):
    """Write Parquet files in hive-style partition layout."""
    s3 = boto3.client("s3", region_name=region)
    years = table.column("order_year").to_pylist()
    months = table.column("order_month").to_pylist()

    partitions = {}
    for i, (y, m) in enumerate(zip(years, months)):
        key = (y, m)
        if key not in partitions:
            partitions[key] = []
        partitions[key].append(i)

    total_files = 0
    for (year, month), indices in sorted(partitions.items()):
        partition_table = table.take(indices)
        # Drop partition columns from the data files (they're in the path)
        data_table = partition_table.drop_columns(["order_year", "order_month"])

        s3_key = f"{prefix}/order_year={year}/order_month={month:02d}/data.parquet"
        buf = pa.BufferOutputStream()
        pq.write_table(data_table, buf, row_group_size=50_000)
        s3.put_object(Bucket=bucket, Key=s3_key, Body=buf.getvalue().to_pybytes())
        total_files += 1

    print(f"  Uploaded {total_files} partition files to s3://{bucket}/{prefix}/")
    return total_files


ICEBERG_SCHEMA = Schema(
    NestedField(field_id=1, name="order_id", field_type=IntegerType(), required=False),
    NestedField(field_id=2, name="customer_id", field_type=IntegerType(), required=False),
    NestedField(field_id=3, name="product", field_type=StringType(), required=False),
    NestedField(field_id=4, name="amount", field_type=DoubleType(), required=False),
    NestedField(field_id=5, name="customer_tier", field_type=StringType(), required=False),
    NestedField(field_id=6, name="order_date", field_type=StringType(), required=False),
    NestedField(field_id=7, name="order_year", field_type=IntegerType(), required=False),
    NestedField(field_id=8, name="order_month", field_type=IntegerType(), required=False),
)

PARTITION_SPEC = PartitionSpec(
    PartitionField(source_id=7, field_id=1000, transform=IdentityTransform(), name="order_year"),
    PartitionField(source_id=8, field_id=1001, transform=IdentityTransform(), name="order_month"),
)

SORT_ORDER = SortOrder(SortField(source_id=7), SortField(source_id=8))


def write_iceberg_partitioned(table: pa.Table, bucket: str, db: str, region: str):
    """Create a partitioned Iceberg table in Glue and write data."""
    catalog = GlueCatalog(
        name="glue",
        **{
            "warehouse": f"s3://{bucket}/data/iceberg",
            "glue.region": region,
            "s3.region": region,
            "region_name": region,
        },
    )

    table_id = f"{db}.orders_partitioned"
    location = f"s3://{bucket}/data/iceberg/orders_partitioned"

    try:
        catalog.drop_table(table_id)
        print(f"  Dropped existing table {table_id}")
    except Exception:
        pass

    iceberg_tbl = catalog.create_table(
        identifier=table_id,
        schema=ICEBERG_SCHEMA,
        location=location,
        partition_spec=PARTITION_SPEC,
        sort_order=SORT_ORDER,
    )
    print(f"  Created Iceberg table {table_id} (partitioned by order_year, order_month)")

    # Write in chunks to avoid memory pressure
    chunk_size = 250_000
    n = len(table)
    for start in range(0, n, chunk_size):
        chunk = table.slice(start, min(chunk_size, n - start))
        iceberg_tbl.append(chunk)
        print(f"  Wrote rows {start+1}-{start+len(chunk)} to {table_id}")

    print(f"  Total: {n} rows in {table_id}")


def main():
    parser = argparse.ArgumentParser(description="Generate large partitioned dataset")
    parser.add_argument("--bucket", default=BUCKET)
    parser.add_argument("--region", default=REGION)
    parser.add_argument("--database", default=GLUE_DB)
    parser.add_argument("--rows", type=int, default=1_000_000)
    parser.add_argument("--skip-hive", action="store_true", help="Skip hive-partitioned Parquet upload")
    parser.add_argument("--skip-iceberg", action="store_true", help="Skip Iceberg table creation")
    args = parser.parse_args()

    print(f"Generating {args.rows:,} orders across 2022-2025...")
    data = generate_partitioned_orders(n_rows=args.rows)
    print(f"  Generated {len(data):,} rows, {data.nbytes / 1024 / 1024:.1f} MB in memory")

    if not args.skip_hive:
        print("\nUploading hive-partitioned Parquet files...")
        upload_hive_partitioned(data, args.bucket, "data/partitioned/orders", args.region)

    if not args.skip_iceberg:
        print("\nWriting partitioned Iceberg table...")
        write_iceberg_partitioned(data, args.bucket, args.database, args.region)

    print("\nDone.")


if __name__ == "__main__":
    main()
