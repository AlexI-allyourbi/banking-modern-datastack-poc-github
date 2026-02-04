"""
Kafka to MinIO Consumer
-----------------------
This script consumes Change Data Capture (CDC) events from Kafka topics
and writes them to MinIO (S3-compatible storage) in Parquet format.

Steps:
1. Load environment variables for Kafka and MinIO configuration.
2. Initialize a Kafka Consumer to listen to specific topics (customers, accounts, transactions).
3. Initialize a MinIO (S3) client and ensure the target bucket exists.
4. Define a helper function `write_to_minio` to save batched records as Parquet files in MinIO.
5. Enter a continuous loop to consume messages from Kafka:
    a. Extract the 'after' state from the Debezium JSON payload.
    b. Buffer records in memory until a batch size is reached.
    c. Once the batch is full, write the data to MinIO and clear the buffer.
"""
import boto3
from kafka import KafkaConsumer
import json
import pandas as pd
from datetime import datetime
import os
from dotenv import load_dotenv

# -----------------------------
# Load secrets from .env
# -----------------------------
load_dotenv()

# -----------------------------
# Step 2: Initialize Kafka Consumer
# -----------------------------
# We subscribe to the Debezium topics corresponding to our Postgres tables.
consumer = KafkaConsumer(
    'banking_server.public.customers',
    'banking_server.public.accounts',
    'banking_server.public.transactions',
    bootstrap_servers=os.getenv("KAFKA_BOOTSTRAP"),
    auto_offset_reset='earliest', #this line renders messages from the start of the topic, earliest means from beginning, latest means only new messages
    enable_auto_commit=True,
    group_id=os.getenv("KAFKA_GROUP"), #group is used so to save offset where machine stopped last time, avoid duplicate reading
    value_deserializer=lambda x: json.loads(x.decode('utf-8')) #data is in binary form when we consume it and this block decodes binary bits to regular json string
)

# -----------------------------
# Step 3: Initialize MinIO (S3) Client
# -----------------------------
s3 = boto3.client(
    's3',
    endpoint_url=os.getenv("MINIO_ENDPOINT"),
    aws_access_key_id=os.getenv("MINIO_ACCESS_KEY"),
    aws_secret_access_key=os.getenv("MINIO_SECRET_KEY")
)

bucket = os.getenv("MINIO_BUCKET")

# Ensure the bucket exists before attempting uploads
#if bucket not exists in the list of buckets then create it
if bucket not in [b['Name'] for b in s3.list_buckets()['Buckets']]: 
    s3.create_bucket(Bucket=bucket)

# -----------------------------
# Step 4: Define Write Function
# -----------------------------
def write_to_minio(table_name, records):
    """
    Converts a list of dictionary records into a Parquet file and uploads it to MinIO.
    """
    if not records:
        return
    
    # Convert list of dicts to DataFrame
    df = pd.DataFrame(records)
    
    # Generate a unique filename based on timestamp
    date_str = datetime.now().strftime('%Y-%m-%d')
    file_path = f'{table_name}_{date_str}.parquet'
    
    # Write locally first
    df.to_parquet(file_path, engine='fastparquet', index=False)
    
    # Upload to S3/MinIO with a hive-style partition (date=...)
    s3_key = f'{table_name}/date={date_str}/{table_name}_{datetime.now().strftime("%H%M%S%f")}.parquet'
    s3.upload_file(file_path, bucket, s3_key)
    
    # Clean up local file
    os.remove(file_path)
    print(f'✅ Uploaded {len(records)} records to s3://{bucket}/{s3_key}')

# -----------------------------
# Step 5: Main Consumption Loop
# -----------------------------
batch_size = 50 # Number of records to buffer before writing to MinIO
buffer = {
    'banking_server.public.customers': [],
    'banking_server.public.accounts': [],
    'banking_server.public.transactions': []
}

print("✅ Connected to Kafka. Listening for messages...")

for message in consumer:
    topic = message.topic
    event = message.value # The Debezium JSON event
    payload = event.get("payload", {})
    
    # 'after' contains the state of the row after the change (INSERT/UPDATE).
    # We skip 'before' (deletes) for this simple ingestion.
    record = payload.get("after")  

    if record:
        buffer[topic].append(record)
        print(f"[{topic}] -> {record}")  # Debugging

    # Check if buffer is full for this specific topic
    if len(buffer[topic]) >= batch_size:
        # Extract table name from topic (e.g., 'banking_server.public.customers' -> 'customers')
        write_to_minio(topic.split('.')[-1], buffer[topic])
        buffer[topic] = []