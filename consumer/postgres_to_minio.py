"""
PostgreSQL to MinIO Direct Transfer
------------------------------------
This script reads all data from the PostgreSQL OLTP tables (customers, accounts, transactions)
and uploads each table as a single Parquet file to MinIO with a timestamp.
"""
import boto3
import psycopg2
import pandas as pd
from datetime import datetime
import os
from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(__file__), '.env'))

# -----------------------------
# Connect to PostgreSQL
# -----------------------------
conn = psycopg2.connect(
    host=os.getenv("POSTGRES_HOST"),
    port=os.getenv("POSTGRES_PORT"),
    dbname=os.getenv("POSTGRES_DB"),
    user=os.getenv("POSTGRES_USER"),
    password=os.getenv("POSTGRES_PASSWORD"),
)

# -----------------------------
# Initialize MinIO (S3) Client
# -----------------------------
s3 = boto3.client(
    's3',
    endpoint_url=os.getenv("MINIO_ENDPOINT"),
    aws_access_key_id=os.getenv("MINIO_ACCESS_KEY"),
    aws_secret_access_key=os.getenv("MINIO_SECRET_KEY"),
)

bucket = os.getenv("MINIO_BUCKET_NAME")

if bucket not in [b['Name'] for b in s3.list_buckets()['Buckets']]:
    s3.create_bucket(Bucket=bucket)

# -----------------------------
# Tables to export
# -----------------------------
tables = ['customers', 'accounts', 'transactions']

# -----------------------------
# Read each table and upload to MinIO
# -----------------------------
timestamp = datetime.now().strftime('%Y-%m-%d_%H%M%S')

for table in tables:
    print(f"Reading {table} from PostgreSQL...")
    df = pd.read_sql(f"SELECT * FROM {table}", conn)

    if df.empty:
        print(f"  ⚠️  {table} is empty, skipping.")
        continue

    local_file = f"{table}_{timestamp}.parquet"
    df.to_parquet(local_file, engine='fastparquet', index=False)

    s3_key = f"{table}/{table}_{timestamp}.parquet"
    s3.upload_file(local_file, bucket, s3_key)
    os.remove(local_file)

    print(f"  ✅ Uploaded {len(df)} rows to s3://{bucket}/{s3_key}")

conn.close()
print("\nDone.")
