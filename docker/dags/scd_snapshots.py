"""
AIRFLOW DAG: DBT SCD2 Snapshots and Marts Pipeline

PURPOSE:
    This DAG orchestrates the dbt (data build tool) workflow for maintaining
    Slowly Changing Dimensions (SCD2) using snapshots and rebuilding data marts.
    
    SCD2 (Slowly Changing Dimension Type 2) tracks historical changes by:
    - Creating new records when dimension attributes change
    - Using valid_from and valid_to timestamps to mark time periods
    - Preserving complete history of all changes

WORKFLOW:
    1. Run dbt snapshots: Capture current state of source tables and detect changes
    2. Run dbt marts: Rebuild downstream analytics tables that depend on snapshots
    
SCHEDULE: Daily (can be changed to hourly or other intervals)

TECH STACK:
    - Airflow: Orchestration/scheduling
    - dbt: Data transformation and SCD2 snapshot tracking
    - Snowflake/other DW: Stores snapshots and marts
"""

from airflow import DAG
from airflow.operators.bash import BashOperator
from datetime import datetime, timedelta

# ========== DAG Default Configuration ==========
# Settings applied to all tasks unless overridden
default_args = {
    "owner": "airflow",  # Task owner for auditing
    "depends_on_past": False,  # Tasks don't need previous run to succeed
    "retries": 1,  # Retry failed tasks once
    "retry_delay": timedelta(minutes=1),  # Wait 1 minute before retrying
}

# ========== DAG Definition ==========
with DAG(
    dag_id="SCD2_snapshots",  # Unique identifier for this DAG
    default_args=default_args,
    description="Run dbt snapshots for SCD2",  # DAG documentation
    schedule_interval="@daily",  # Run once per day. Options: @hourly, @daily, @weekly, @monthly, or cron expression
    start_date=datetime(2025, 9, 1),  # DAG starts running from this date
    catchup=False,  # Don't backfill missed runs from start_date
    tags=["dbt", "snapshots"],  # Tags for organizing and filtering DAGs in UI
) as dag:

    # ========== Task 1: Execute dbt Snapshots ==========
    # dbt snapshots capture the current state of source tables
    # and automatically track changes over time (SCD2 pattern)
    dbt_snapshot = BashOperator(
        task_id="dbt_snapshot",  # Unique task identifier
        bash_command=(
            # Navigate to the dbt project directory
            "cd /opt/airflow/banking_dbt && "
            # Run dbt snapshot command to capture table snapshots
            # Snapshots track changes to source tables by comparing current vs previous state
            "dbt snapshot --profiles-dir /home/airflow/.dbt"
        )
    )
    
    # ========== Task 2: Run dbt Marts ==========
    # Data marts are downstream analytical tables that aggregate and
    # transform data from base tables and snapshots
    dbt_run_marts = BashOperator(
        task_id="dbt_run_marts",  # Unique task identifier
        bash_command=(
            # Navigate to the dbt project directory
            "cd /opt/airflow/banking_dbt && "
            # Run dbt run command limited to mart models
            # --select marts: only rebuild models tagged as 'marts'
            # This ensures marts are rebuilt with the latest snapshot data
            "dbt run --select marts --profiles-dir /home/airflow/.dbt"
        )
    )

    # ========== Task Dependencies ==========
    # Define execution order: Snapshots must complete before marts rebuild
    # This ensures marts have the latest SCD2 snapshot data available
    dbt_snapshot >> dbt_run_marts