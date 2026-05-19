"""
AIRFLOW DAG: MinIO to Snowflake Data Pipeline

PURPOSE:
    This DAG orchestrates the process of downloading parquet files from MinIO object storage
    and loading them into Snowflake data warehouse tables. It runs every minute and handles
    three core banking tables: customers, accounts, and transactions.

WORKFLOW:
    1. Download files from MinIO S3-compatible storage
    2. Upload files to Snowflake's internal stage
    3. Copy data from stage into Snowflake tables

SCHEDULE: Every minute (*/1 * * * *)
"""

import os
import boto3
import snowflake.connector
from airflow import DAG
from airflow.operators.python import PythonOperator
from datetime import datetime, timedelta
from dotenv import load_dotenv

# STEP 1: Load environment variables from .env file
# This retrieves all connection credentials and configuration from environment
load_dotenv()

# ========== MinIO Configuration ==========
# MinIO is an S3-compatible object storage service
# These credentials connect to the MinIO instance where raw data files are stored
MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT")  # e.g., "minio:9000"
MINIO_ACCESS_KEY = os.getenv("MINIO_ACCESS_KEY")  # AWS-style access key
MINIO_SECRET_KEY = os.getenv("MINIO_SECRET_KEY")  # AWS-style secret key
BUCKET = os.getenv("MINIO_BUCKET")  # Bucket name containing raw data (e.g., "banking")
LOCAL_DIR = os.getenv("MINIO_LOCAL_DIR", "/tmp/minio_downloads")  # Temporary directory for downloaded files

# ========== Snowflake Configuration ==========
# These credentials connect to Snowflake cloud data warehouse
SNOWFLAKE_USER = os.getenv("SNOWFLAKE_USER")  # Snowflake username
SNOWFLAKE_PASSWORD = os.getenv("SNOWFLAKE_PASSWORD")  # Snowflake password
SNOWFLAKE_ACCOUNT = os.getenv("SNOWFLAKE_ACCOUNT")  # Snowflake account identifier
SNOWFLAKE_WAREHOUSE = os.getenv("SNOWFLAKE_WAREHOUSE")  # Compute warehouse to use
SNOWFLAKE_DB = os.getenv("SNOWFLAKE_DB")  # Target database name
SNOWFLAKE_SCHEMA = os.getenv("SNOWFLAKE_SCHEMA")  # Target schema name

# Tables to process - these correspond to MinIO folders and Snowflake tables
TABLES = ["customers", "accounts", "transactions"]

# ========== Python Functions (Tasks) ==========
# These functions are executed as Airflow tasks in the DAG

def download_from_minio():
    """
    STEP 1: Download files from MinIO to local filesystem
    
    PROCESS:
        1. Create local directory if it doesn't exist
        2. Connect to MinIO using S3 client (boto3)
        3. For each table (customers, accounts, transactions):
           - List all objects in MinIO under that table's prefix folder
           - Download each parquet file to local directory
           - Track downloaded files in a dictionary
        4. Return dictionary mapping table names to local file paths
    
    RETURNS:
        dict: {
            "customers": ["/tmp/minio_downloads/customers_file1.parquet", ...],
            "accounts": [...],
            "transactions": [...]
        }
    """
    # Create local download directory
    os.makedirs(LOCAL_DIR, exist_ok=True)
    
    # Initialize S3 client configured for MinIO endpoint
    s3 = boto3.client(
        "s3",
        endpoint_url=MINIO_ENDPOINT,
        aws_access_key_id=MINIO_ACCESS_KEY,
        aws_secret_access_key=MINIO_SECRET_KEY
    )
    
    # Dictionary to store downloaded file paths organized by table
    local_files = {}
    
    # Process each table
    for table in TABLES:
        prefix = f"{table}/"  # MinIO folder structure: "customers/", "accounts/", etc.
        
        # List all objects in MinIO bucket under this table's prefix
        resp = s3.list_objects_v2(Bucket=BUCKET, Prefix=prefix)
        objects = resp.get("Contents", [])  # Get list of objects, default to empty if none
        local_files[table] = []
        
        # Download each object from MinIO to local filesystem
        for obj in objects:
            key = obj["Key"]  # Full path in MinIO
            # Create local file path by extracting just the filename
            local_file = os.path.join(LOCAL_DIR, os.path.basename(key))
            # Download the file
            s3.download_file(BUCKET, key, local_file)
            print(f"Downloaded {key} -> {local_file}")
            # Track the local file path
            local_files[table].append(local_file)
    
    return local_files

def load_to_snowflake(**kwargs):
    """
    STEP 2: Load downloaded files into Snowflake tables
    
    PROCESS:
        1. Retrieve downloaded file paths from previous task (using XCom)
        2. Connect to Snowflake data warehouse
        3. For each table with files:
           - Upload files to Snowflake's internal stage (temporary storage)
           - Execute COPY command to load parquet data into table
           - Skip on errors to ensure robustness
        4. Close connection
    
    INPUTS:
        **kwargs: Airflow context containing task instance and cross-communication data
    
    WORKFLOW:
        download_minio output -> Snowflake stage -> COPY command -> Snowflake tables
    """
    # Get file paths from previous task using cross-task communication (XCom)
    local_files = kwargs["ti"].xcom_pull(task_ids="download_minio")
    
    # If no files were downloaded, exit early
    if not local_files:
        print("No files found in MinIO.")
        return

    # Connect to Snowflake using credentials
    conn = snowflake.connector.connect(
        user=SNOWFLAKE_USER,
        password=SNOWFLAKE_PASSWORD,
        account=SNOWFLAKE_ACCOUNT,
        warehouse=SNOWFLAKE_WAREHOUSE,
        database=SNOWFLAKE_DB,
        schema=SNOWFLAKE_SCHEMA,
    )
    cur = conn.cursor()

    # Process each table and its downloaded files
    for table, files in local_files.items():
        # Skip if no files for this table
        if not files:
            print(f"No files for {table}, skipping.")
            continue

        # Upload each file to Snowflake's internal stage for that table
        for f in files:
            # PUT command uploads local file to Snowflake stage (@%tablename)
            cur.execute(f"PUT file://{f} @%{table}")
            print(f"Uploaded {f} -> @{table} stage")

        # Execute COPY command to load staged parquet files into table
        # FILE_FORMAT=PARQUET: tells Snowflake files are parquet format
        # ON_ERROR='CONTINUE': continue loading even if some rows fail
        copy_sql = f"""
        COPY INTO {table}
        FROM @%{table}
        FILE_FORMAT=(TYPE=PARQUET)
        ON_ERROR='CONTINUE'
        """
        cur.execute(copy_sql)
        print(f"Data loaded into {table}")

    # Clean up: close cursor and connection
    cur.close()
    conn.close()

# ========== Airflow DAG Definition ==========
# This section configures the DAG (Directed Acyclic Graph) and its tasks

# Default configuration applied to all tasks in this DAG
default_args = {
    "owner": "airflow",  # Owner for auditing/documentation
    "retries": 1,  # Retry failed tasks once
    "retry_delay": timedelta(minutes=1),  # Wait 1 minute before retrying
}

# Define the DAG
with DAG(
    dag_id="minio_to_snowflake_banking",  # Unique identifier for this DAG
    default_args=default_args,
    description="Load MinIO parquet into Snowflake RAW tables",  # DAG documentation
    schedule_interval="*/1 * * * *",  # Run every 1 minute (cron expression)
    start_date=datetime(2025, 1, 1),  # DAG starts running from this date
    catchup=False,  # Don't backfill missed runs from start_date
) as dag:

    # ========== Task 1: Download from MinIO ==========
    # This task calls the download_from_minio() function
    task1 = PythonOperator(
        task_id="download_minio",  # Unique task identifier
        python_callable=download_from_minio,  # Function to execute
    )

    # ========== Task 2: Load to Snowflake ==========
    # This task calls the load_to_snowflake() function
    task2 = PythonOperator(
        task_id="load_snowflake",  # Unique task identifier
        python_callable=load_to_snowflake,  # Function to execute
        provide_context=True,  # Pass Airflow context to function (for XCom access)
    )

    # ========== Task Dependencies ==========
    # Define execution order: Task 1 must complete before Task 2 starts
    # Data from task1 is passed to task2 via XCom
    task1 >> task2