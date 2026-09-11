#!/usr/bin/env python3
"""Generate sample Parquet (Hive) and Iceberg data, upload to S3 and register in Glue."""

import argparse
import random
from datetime import datetime, timedelta

import boto3
import pyarrow as pa
import pyarrow.parquet as pq
from pyiceberg.catalog.glue import GlueCatalog
from pyiceberg.schema import Schema
from pyiceberg.types import (
    BooleanType,
    DoubleType,
    IntegerType,
    NestedField,
    StringType,
)

BUCKET = "dmichalk-glue-sandbox"
REGION = "us-west-2"
GLUE_DB = "dmichalk_sandbox_db"

TIERS = ["bronze", "silver", "gold", "platinum"]
PRODUCTS = [
    "Dog Food - Chicken", "Dog Food - Beef", "Cat Food - Salmon",
    "Cat Litter - Clumping", "Dog Treats - Dental", "Cat Treats - Tuna",
    "Dog Toy - Rope", "Cat Toy - Feather", "Pet Bed - Large", "Pet Bed - Small",
    "Dog Leash", "Cat Scratcher", "Fish Food - Flakes", "Bird Seed Mix",
    "Hamster Wheel", "Reptile Heat Lamp",
]
CATEGORIES = ["food", "toys", "beds", "accessories", "health", "grooming"]


def random_date(start_year=2022, end_year=2025):
    start = datetime(start_year, 1, 1)
    end = datetime(end_year, 12, 31)
    delta = end - start
    return (start + timedelta(days=random.randint(0, delta.days))).strftime("%Y-%m-%d")


# ── Parquet: customers ──────────────────────────────────────────────────────
def generate_customers(n=100):
    rows = {
        "customer_id": list(range(1, n + 1)),
        "name": [f"Customer_{i}" for i in range(1, n + 1)],
        "email": [f"customer{i}@example.com" for i in range(1, n + 1)],
        "signup_date": [random_date(2020, 2024) for _ in range(n)],
        "tier": [random.choice(TIERS) for _ in range(n)],
    }
    return pa.table(rows)


# ── Parquet: orders ─────────────────────────────────────────────────────────
def generate_orders(n=500, num_customers=100):
    rows = {
        "order_id": list(range(1, n + 1)),
        "customer_id": [random.randint(1, num_customers) for _ in range(n)],
        "product": [random.choice(PRODUCTS) for _ in range(n)],
        "amount": [round(random.uniform(5.99, 149.99), 2) for _ in range(n)],
        "order_date": [random_date() for _ in range(n)],
    }
    return pa.table(rows)


# ── Iceberg: products ──────────────────────────────────────────────────────
def generate_products_data(n=50):
    rows = {
        "product_id": pa.array(list(range(1, n + 1)), type=pa.int32()),
        "name": [random.choice(PRODUCTS) for _ in range(n)],
        "category": [random.choice(CATEGORIES) for _ in range(n)],
        "price": [round(random.uniform(3.99, 89.99), 2) for _ in range(n)],
        "in_stock": [random.choice([True, False]) for _ in range(n)],
    }
    return pa.table(rows)


PRODUCTS_ICEBERG_SCHEMA = Schema(
    NestedField(field_id=1, name="product_id", field_type=IntegerType(), required=False),
    NestedField(field_id=2, name="name", field_type=StringType(), required=False),
    NestedField(field_id=3, name="category", field_type=StringType(), required=False),
    NestedField(field_id=4, name="price", field_type=DoubleType(), required=False),
    NestedField(field_id=5, name="in_stock", field_type=BooleanType(), required=False),
)


def upload_parquet(table: pa.Table, bucket: str, key: str, region: str = REGION):
    s3 = boto3.client("s3", region_name=region)
    buf = pa.BufferOutputStream()
    pq.write_table(table, buf)
    s3.put_object(Bucket=bucket, Key=key, Body=buf.getvalue().to_pybytes())
    print(f"  Uploaded s3://{bucket}/{key}")


def write_iceberg_table(bucket: str, db: str, region: str = REGION):
    catalog = GlueCatalog(
        name="glue",
        **{
            "warehouse": f"s3://{bucket}/data/iceberg",
            "glue.region": region,
            "s3.region": region,
            "region_name": region,
        },
    )

    table_id = f"{db}.products"
    location = f"s3://{bucket}/data/iceberg/products"

    try:
        catalog.drop_table(table_id)
        print(f"  Dropped existing table {table_id}")
    except Exception:
        pass

    tbl = catalog.create_table(
        identifier=table_id,
        schema=PRODUCTS_ICEBERG_SCHEMA,
        location=location,
    )
    print(f"  Created Iceberg table {table_id} at {location}")

    df = generate_products_data()
    tbl.append(df)
    print(f"  Wrote {len(df)} rows to {table_id}")


def main():
    parser = argparse.ArgumentParser(description="Generate sample data for Glue sandbox")
    parser.add_argument("--bucket", default=BUCKET, help="S3 bucket name")
    parser.add_argument("--region", default=REGION, help="AWS region")
    parser.add_argument("--database", default=GLUE_DB, help="Glue database name")
    args = parser.parse_args()
    region = args.region

    print("Generating Parquet data...")
    customers = generate_customers()
    upload_parquet(customers, args.bucket, "data/hive/customers/data.parquet", region)

    orders = generate_orders()
    upload_parquet(orders, args.bucket, "data/hive/orders/data.parquet", region)

    print("\nGenerating Iceberg data...")
    write_iceberg_table(args.bucket, args.database, region)

    print("\nDone.")


if __name__ == "__main__":
    main()
