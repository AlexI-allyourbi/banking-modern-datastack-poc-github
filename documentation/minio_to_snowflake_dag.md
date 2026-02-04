# MinIO to Snowflake Data Pipeline

## Overview

The **minio_to_snowflake_banking** DAG is an Apache Airflow orchestration pipeline that automates the ingestion of banking data from MinIO object storage into Snowflake data warehouse. It runs every minute and continuously processes three core banking datasets: customers, accounts, and transactions.

## Purpose

This pipeline enables real-time data integration between two data infrastructure components:
- **MinIO**: Acts as the raw data lake storing parquet-formatted banking data
- **Snowflake**: Serves as the centralized cloud data warehouse for analytics and reporting

## Architecture

The pipeline follows a three-stage data movement pattern:

```
MinIO (Raw Parquet Files)
    ↓
Local Filesystem (Temporary Storage)
    ↓
Snowflake Internal Stage
    ↓
Snowflake Tables (RAW schema)
```

## Workflow Steps

### Step 1: Download from MinIO

The first task (`download_minio`) performs the following:

1. **Connects to MinIO** using S3-compatible credentials and boto3 client
2. **Scans three bucket prefixes**: `customers/`, `accounts/`, and `transactions/`
3. **Lists available parquet files** in each prefix directory
4. **Downloads files** to local temporary storage (`/tmp/minio_downloads`)
5. **Returns file mappings** to the next task using Airflow's XCom (cross-communication)

#### Key Details:
- Handles missing files gracefully (empty lists if no files exist)
- Organizes downloads by table for better tracking
- Uses boto3 which supports S3-compatible endpoints like MinIO

### Step 2: Load to Snowflake

The second task (`load_snowflake`) completes the data transfer:

1. **Retrieves file paths** from the previous task using XCom
2. **Connects to Snowflake** using provided credentials
3. **For each table**:
   - **Uploads files to Snowflake's internal stage** (table-specific temporary storage)
   - **Executes COPY command** to load parquet data into the target table
   - **Continues on errors** to ensure partial loads don't block the pipeline
4. **Closes connection** and cleans up resources

#### Key Details:
- Uses table-specific stages (`@%tablename`) for file organization
- Parquet format is automatically detected and parsed
- Error handling allows partial loads (useful for incremental updates)

## Configuration

### MinIO Settings

| Setting | Description | Example |
|---------|-------------|---------|
| `MINIO_ENDPOINT` | Connection address | `minio:9000` |
| `MINIO_ACCESS_KEY` | AWS-style access key | Set in environment |
| `MINIO_SECRET_KEY` | AWS-style secret key | Set in environment |
| `MINIO_BUCKET` | Source bucket containing banking data | `banking` |
| `MINIO_LOCAL_DIR` | Temporary local directory for downloads | `/tmp/minio_downloads` |

### Snowflake Settings

| Setting | Description |
|---------|-------------|
| `SNOWFLAKE_USER` | Database user |
| `SNOWFLAKE_PASSWORD` | User password |
| `SNOWFLAKE_ACCOUNT` | Snowflake account identifier |
| `SNOWFLAKE_WAREHOUSE` | Compute warehouse to use |
| `SNOWFLAKE_DB` | Target database |
| `SNOWFLAKE_SCHEMA` | Target schema (typically `RAW`) |

### Tables Processed

- `customers`: Customer dimension data
- `accounts`: Account information
- `transactions`: Transaction records

## Execution Schedule

- **Frequency**: Every 1 minute (`*/1 * * * *` cron expression)
- **Start Date**: January 1, 2025
- **Catchup**: Disabled (no backfilling of missed runs)
- **Retries**: 1 retry on failure with 1-minute delay

## Data Flow Summary

```
MinIO Parquet Files
    ↓ [Task 1: download_minio]
    → Downloads to local /tmp/minio_downloads
    → Returns: {
        "customers": ["file1.parquet", ...],
        "accounts": [...],
        "transactions": [...]
      }
    ↓ [XCom: Cross-task Communication]
    ↓ [Task 2: load_snowflake]
    → Uploads to Snowflake staging area
    → Executes COPY command
    → Loads data into customers, accounts, transactions tables
```

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Missing MinIO files | Pipeline skips gracefully and continues |
| Snowflake load errors | Uses `ON_ERROR='CONTINUE'` to load valid rows and skip problematic ones |
| Task failures | Automatic retry after 1 minute |
| Connection issues | Raises exception (caught by Airflow retry mechanism) |

## Use Cases

- **Real-time data synchronization** between MinIO and Snowflake
- **Incremental data loads** of banking transactions, customers, and accounts
- **Data lake ingestion** into cloud warehouse
- **Continuous data pipeline** for analytics and reporting

## Monitoring & Logs

Monitor the pipeline through:

- **Airflow UI**: View DAG runs, task duration, and logs
- **Task logs**: Located in Airflow logs directory with timestamps
- **Print statements**: Show download and load progress
- **Snowflake query history**: Verify data loads in warehouse

## Dependencies

### Python Libraries
- `boto3`: AWS SDK for Python (used for S3/MinIO operations)
- `snowflake-connector-python`: Snowflake database connector
- `python-dotenv`: Environment variable management
- `apache-airflow`: Orchestration framework

### External Services
- **MinIO**: S3-compatible object storage
- **Snowflake**: Cloud data warehouse
- **Airflow**: Workflow orchestration engine

## Technical Implementation

### Cross-Task Communication

The pipeline uses Airflow's **XCom (cross-communication)** to pass data between tasks:
- Task 1 returns a dictionary of file paths
- Task 2 retrieves this dictionary using `ti.xcom_pull(task_ids="download_minio")`

### S3/MinIO Connection

The `boto3` client is configured with MinIO's S3-compatible endpoint, allowing standard AWS SDK operations to work with MinIO.

### Snowflake Data Loading

Files are loaded using Snowflake's two-stage process:
1. **PUT command**: Uploads files to internal stage
2. **COPY command**: Imports staged files into tables using specified format

## Potential Improvements

- Add data validation checks before/after loading
- Implement quality metrics (row counts, data quality scores)
- Add alerting for failed tasks
- Implement incremental loading with deduplication
- Add archival of processed files
