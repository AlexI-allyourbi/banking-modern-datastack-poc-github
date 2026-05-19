# Banking Modern Data Stack - Training Guide

## Project Overview

This project builds an **end-to-end modern data stack pipeline** for a banking domain. It simulates customer, account, and transaction data, moves it through a series of data engineering tools, and produces analytics-ready models in Snowflake.

**Architecture Flow:**
```
PostgreSQL (OLTP) → Faker (Data Gen) → MinIO (Object Storage) → Snowflake (Data Warehouse) → dbt (Transformations) → Airflow (Orchestration)
```

---

## Step 1: Set Up PostgreSQL Database

PostgreSQL is used as the **source OLTP (Online Transaction Processing)** database. It simulates a real banking system where transactions happen in real-time.

### What You Need
- Docker Desktop installed and running
- The `docker-compose.yml` file in the project root

### How It Works
The `docker-compose.yml` defines a PostgreSQL 15 container with:
- **WAL (Write-Ahead Logging)** set to `logical` — required for Change Data Capture (CDC)
- Credentials loaded from the `.env` file (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`)
- Data persisted to `./docker/postgres/data`
- Exposed on port `5432`

### Commands
```bash
# Start only the postgres service
docker-compose up -d postgres

# Connect to verify
psql -h localhost -U aismr_admin -d banking
```

---

## Step 2: Create Tables Using schema.sql

The file `postgres/schema.sql` defines three core banking tables:

### Tables

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| **customers** | Stores bank customers | `id`, `first_name`, `last_name`, `email`, `created_at` |
| **accounts** | Customer bank accounts | `id`, `customer_id`, `account_type`, `balance`, `currency`, `created_at` |
| **transactions** | Financial transactions | `id`, `account_id`, `txn_type`, `amount`, `related_account_id`, `status`, `created_at` |

### Key Design Decisions
- `customers.email` has a **UNIQUE constraint** — no duplicate emails
- `accounts.balance` has a **CHECK constraint** — cannot go below 0
- `transactions.amount` has a **CHECK constraint** — must be positive
- **Foreign keys** link accounts → customers and transactions → accounts
- An **index** on `transactions(account_id, created_at)` for query performance

### How to Run
```sql
-- Execute the schema file against your database
psql -h localhost -U aismr_admin -d banking -f postgres/schema.sql
```

---

## Step 3: Generate Fake Data with Faker

The file `data-generator/faker_generator.py` simulates a live banking environment by continuously generating synthetic data.

### What It Does
1. Connects to PostgreSQL using credentials from `.env`
2. Each iteration generates:
   - **10 customers** with random names and emails
   - **2 accounts per customer** (SAVINGS or CHECKING) with random initial balances ($10–$1,000)
   - **50 transactions** (DEPOSIT, WITHDRAWAL, or TRANSFER) with random amounts up to $1,000
3. Loops continuously with a 2-second sleep between iterations (simulating real-time activity)

### Configuration
| Setting | Default Value | Description |
|---------|---------------|-------------|
| `NUM_CUSTOMERS` | 10 | Customers per iteration |
| `ACCOUNTS_PER_CUSTOMER` | 2 | Accounts opened per customer |
| `NUM_TRANSACTIONS` | 50 | Transactions per iteration |
| `MAX_TXN_AMOUNT` | 1000.00 | Maximum transaction amount |
| `SLEEP_SECONDS` | 2 | Pause between iterations |

### How to Run
```bash
# Continuous mode (loops forever)
python data-generator/faker_generator.py

# Single iteration mode
python data-generator/faker_generator.py --once
```

### Required Environment Variables (in `.env`)
```
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
POSTGRES_DB=banking
POSTGRES_USER=aismr_admin
POSTGRES_PASSWORD=<your_password>
```

---

## Step 4: Set Up Airflow

Apache Airflow is the **orchestration engine** that schedules and monitors all pipeline tasks.

### How It's Set Up
The project uses a **custom Docker image** built from `dockerfile-airflow.dockerfile`:
```dockerfile
FROM apache/airflow:2.9.3
USER airflow
RUN pip install --no-cache-dir dbt-core dbt-snowflake
```

This installs `dbt-core` and `dbt-snowflake` inside the Airflow container so DAGs can run dbt commands.

### Docker-Compose Services
Two Airflow containers run:
1. **airflow-webserver** — The UI (accessible at `http://localhost:8080`)
2. **airflow-scheduler** — Executes DAGs on schedule

Both share these volume mounts:
| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `./docker/dags` | `/opt/airflow/dags` | DAG Python files |
| `./docker/logs` | `/opt/airflow/logs` | Execution logs |
| `./banking_dbt` | `/opt/airflow/banking_dbt` | dbt project |
| `./banking_dbt/.dbt` | `/home/airflow/.dbt` | dbt profiles.yml |

A separate **airflow-postgres** database runs on port `5433` for Airflow's internal metadata.

### Commands
```bash
# Start all Airflow services
docker-compose up -d airflow-webserver airflow-scheduler airflow-postgres

# Access the UI
# Open http://localhost:8080
```

---

## Step 5: Set Up MinIO

MinIO is an **S3-compatible object storage** service that acts as the intermediate data lake between PostgreSQL and Snowflake.

### How It's Set Up
The `docker-compose.yml` defines a MinIO container:
- **API** on port `9000`
- **Console UI** on port `9001` (accessible at `http://localhost:9001`)
- Data stored in `./docker/minio/data`
- Credentials from `.env` (`MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`)

### What Gets Stored
Data is organized in MinIO as Parquet files:
```
raw/                          ← bucket name
├── customers/
│   └── customers_2026-05-15_143022.parquet
├── accounts/
│   └── accounts_2026-05-15_143022.parquet
└── transactions/
    └── transactions_2026-05-15_143022.parquet
```

### Moving Data to MinIO
The script `consumer/postgres_to_minio.py` reads all data from PostgreSQL and uploads it directly to MinIO as Parquet files:
1. Connects to PostgreSQL and MinIO using `.env` credentials
2. Reads each table with `SELECT * FROM {table}`
3. Converts to Parquet format using pandas + fastparquet
4. Uploads to MinIO with a timestamped filename

```bash
python consumer/postgres_to_minio.py
```

---

## Step 6: Set Up Snowflake Account

Snowflake is the **cloud data warehouse** where all analytics-ready data lives.

### Getting Started
1. Sign up for a **30-day free trial** at [signup.snowflake.com](https://signup.snowflake.com)
2. Note your **account identifier** (e.g., `gx83958.west-europe.azure`)
3. Create a user with appropriate permissions

### Required Environment Variables
```
SNOWFLAKE_USER=alexjanitor
SNOWFLAKE_PASSWORD=<your_password>
SNOWFLAKE_ACCOUNT=gx83958.west-europe.azure
SNOWFLAKE_WAREHOUSE=COMPUTE_WH
SNOWFLAKE_DB=banking
SNOWFLAKE_SCHEMA=raw
```

---

## Step 7: Create Snowflake Tables

The file `snowflake/queries.txt` contains the initial setup queries.

### Queries to Run in Snowflake
```sql
-- Create the database
CREATE DATABASE banking;

-- Create the raw schema (landing zone for MinIO data)
CREATE SCHEMA banking.raw;

-- Create VARIANT tables (flexible schema for Parquet ingestion)
CREATE TABLE customers (v VARIANT);
CREATE TABLE accounts (v VARIANT);
CREATE TABLE transactions (v VARIANT);
```

### Why VARIANT?
Snowflake's `VARIANT` data type stores semi-structured data (JSON, Parquet). This means:
- No need to define column schemas upfront
- Parquet files load directly without schema mapping
- Data is extracted later using dbt staging models (e.g., `v:id::string`)

---

## Step 8: Set Up the MinIO to Snowflake DAG

The file `docker/dags/minio_to_snowflake_dag.py` is an Airflow DAG that moves data from MinIO into Snowflake.

### DAG: `minio_to_snowflake_banking`
- **Schedule:** Every 1 minute (`*/1 * * * *`)
- **Tasks:**

| Task | Type | What It Does |
|------|------|-------------|
| `download_minio` | PythonOperator | Downloads Parquet files from MinIO to `/tmp/minio_downloads` |
| `load_snowflake` | PythonOperator | Uploads files to Snowflake stage and runs COPY INTO |

### Data Flow
```
MinIO (S3) → Download to /tmp → PUT to Snowflake Stage → COPY INTO table
```

### Key Details
- Uses **XCom** to pass file paths between tasks
- Uses Snowflake's `PUT` command to upload to internal stage (`@%tablename`)
- Uses `COPY INTO` with `FILE_FORMAT=(TYPE=PARQUET)` and `ON_ERROR='CONTINUE'`

---

## Step 9: Run the MinIO to Snowflake DAG

### Steps
1. Ensure all Docker services are running (`docker-compose up -d`)
2. Open Airflow UI at `http://localhost:8080`
3. Find the DAG `minio_to_snowflake_banking`
4. Toggle it ON (enable the DAG)
5. It runs every minute automatically, or you can trigger manually

### Verification
Check Snowflake to confirm data arrived:
```sql
SELECT COUNT(*) FROM banking.raw.customers;
SELECT COUNT(*) FROM banking.raw.accounts;
SELECT COUNT(*) FROM banking.raw.transactions;

-- Preview the VARIANT data
SELECT v FROM banking.raw.customers LIMIT 5;
```

---

## Step 10: Initialize dbt

dbt (data build tool) handles all **data transformations** in Snowflake.

### Project Structure
```
banking_dbt/
├── dbt_project.yml          # Project configuration
├── .dbt/
│   └── profiles.yml         # Snowflake connection settings
├── models/
│   ├── sources.yml          # Source table definitions
│   ├── staging/             # Staging views (clean raw data)
│   │   ├── stg_customers.sql
│   │   ├── stg_accounts.sql
│   │   └── stg_transactions.sql
│   └── marts/               # Business-ready tables
│       ├── dimensions/
│       │   ├── dim_customers.sql
│       │   └── dim_accounts.sql
│       └── facts/
│           └── fact_transactions.sql
└── snapshots/               # SCD Type-2 snapshots
    ├── customers_snapshot.sql
    └── accounts_snapshot.sql
```

### dbt Profiles (profiles.yml)
The `banking_dbt/.dbt/profiles.yml` configures the Snowflake connection:
```yaml
banking_dbt:
  outputs:
    dev:
      type: snowflake
      account: <your_account>
      user: <your_user>
      password: <your_password>
      database: banking
      schema: analytics
      warehouse: COMPUTE_WH
      threads: 4
  target: dev
```

### Commands
```bash
cd banking_dbt

# Verify connection
dbt debug

# Should output: "All checks passed!"
```

### Layers Explained

**Sources** (`sources.yml`): Points to the raw Snowflake tables
```yaml
sources:
  - name: raw
    database: BANKING
    schema: RAW
    tables:
      - name: customers
      - name: accounts
      - name: transactions
```

**Staging Models**: Extract fields from VARIANT and deduplicate
- `stg_customers.sql` — Extracts `v:id`, `v:first_name`, etc. and deduplicates by `id`
- `stg_accounts.sql` — Extracts account fields, deduplicates by `id`
- `stg_transactions.sql` — Extracts transaction fields

**Marts**: Business-ready dimension and fact tables
- `dim_customers` — Customer dimension with SCD2 history from snapshots
- `dim_accounts` — Account dimension with SCD2 history from snapshots
- `fact_transactions` — Transaction fact table joined with account data

---

## Step 11: Run dbt

```bash
cd banking_dbt

# Run all models
dbt run
```

This creates the following objects in Snowflake `BANKING.ANALYTICS`:
| Object | Type | Description |
|--------|------|-------------|
| `stg_customers` | View | Cleaned customer data |
| `stg_accounts` | View | Cleaned account data |
| `stg_transactions` | View | Cleaned transaction data |
| `dim_customers` | Table | Customer dimension (SCD2) |
| `dim_accounts` | Table | Account dimension (SCD2) |
| `fact_transactions` | Table | Transaction fact (incremental) |

---

## Step 12: Run the SCD2 Snapshots DAG

The file `docker/dags/scd_snapshots.py` is an Airflow DAG that runs dbt snapshots and rebuilds marts.

### DAG: `SCD2_snapshots`
- **Schedule:** Daily (`@daily`)
- **Tasks:**

| Task | Type | What It Does |
|------|------|-------------|
| `dbt_snapshot` | BashOperator | Runs `dbt snapshot` to capture SCD2 changes |
| `dbt_run_marts` | BashOperator | Runs `dbt run --select marts` to rebuild dimension/fact tables |

### What Are Snapshots (SCD Type-2)?
Slowly Changing Dimensions track **historical changes** to data:
- When a customer's email changes, the old record gets a `dbt_valid_to` timestamp
- A new record is created with the updated email and `dbt_valid_from` = now
- The `is_current` flag marks the latest version

Example:
| customer_id | email | effective_from | effective_to | is_current |
|------------|-------|---------------|-------------|------------|
| 1 | old@email.com | 2026-01-01 | 2026-05-15 | FALSE |
| 1 | new@email.com | 2026-05-15 | NULL | TRUE |

### Snapshot Configuration
- **Strategy:** `check` — compares specified columns for changes
- **customers_snapshot:** Monitors `first_name`, `last_name`, `email`
- **accounts_snapshot:** Monitors `customer_id`, `account_type`, `balance`

---

## Step 13: Verify Data in Snowflake

### Queries to Run
```sql
-- Check raw data landed
SELECT COUNT(*) FROM banking.raw.customers;
SELECT COUNT(*) FROM banking.raw.accounts;
SELECT COUNT(*) FROM banking.raw.transactions;

-- Check staging views
SELECT * FROM banking.analytics.stg_customers LIMIT 10;
SELECT * FROM banking.analytics.stg_accounts LIMIT 10;

-- Check dimension tables (SCD2 history)
SELECT * FROM banking.analytics.dim_customers WHERE customer_id = '1';
SELECT * FROM banking.analytics.dim_accounts WHERE is_current = TRUE LIMIT 10;

-- Check fact table
SELECT * FROM banking.analytics.fact_transactions LIMIT 10;

-- Check snapshot history
SELECT * FROM banking.analytics.customers_snapshot
WHERE customer_id = '1'
ORDER BY dbt_valid_from;
```

---

## Complete Architecture Summary

```
┌─────────────┐    ┌──────────┐    ┌───────────┐    ┌─────────────┐    ┌───────────┐
│  Faker      │───▶│ Postgres │───▶│   MinIO   │───▶│  Snowflake  │───▶│    dbt    │
│ (Data Gen)  │    │  (OLTP)  │    │  (S3/Lake)│    │  (Raw/DW)   │    │ (Transform)│
└─────────────┘    └──────────┘    └───────────┘    └─────────────┘    └───────────┘
                                                           │                  │
                                                           ▼                  ▼
                                                    ┌─────────────┐   ┌──────────────┐
                                                    │  RAW Layer  │   │ ANALYTICS    │
                                                    │ (VARIANT)   │   │ Staging/Marts│
                                                    └─────────────┘   └──────────────┘
                                                    
                        ┌──────────────────────────────────────┐
                        │         Apache Airflow               │
                        │  • minio_to_snowflake (every 1 min)  │
                        │  • SCD2_snapshots (daily)            │
                        └──────────────────────────────────────┘
```

### Docker Services (docker-compose.yml)
| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| postgres | postgres:15 | 5432 | Banking OLTP database |
| minio | minio/minio | 9000/9001 | S3-compatible object storage |
| zookeeper | confluentinc/cp-zookeeper | 2181 | Kafka dependency |
| kafka | confluentinc/cp-kafka | 9092/29092 | Event streaming |
| connect | debezium/connect | 8083 | CDC connector |
| airflow-webserver | Custom (apache/airflow) | 8080 | Airflow UI |
| airflow-scheduler | Custom (apache/airflow) | — | DAG executor |
| airflow-postgres | postgres:15 | 5433 | Airflow metadata DB |
