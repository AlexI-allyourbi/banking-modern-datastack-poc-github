"""
Debezium Connector Setup
------------------------
This script automates the registration of the Debezium PostgreSQL connector
by sending a JSON configuration payload to the Kafka Connect REST API.
It tells Debezium how to connect to Postgres and which tables to monitor.

Steps:
1. Load environment variables for database and Kafka Connect configuration.
2. Construct the JSON configuration payload defining the Postgres connector settings (host, user, tables to capture, etc.).
3. Send a POST request to the Kafka Connect REST API to register the connector.
4. Handle the API response to confirm success or report errors.
"""
import os
import json
import requests
from dotenv import load_dotenv

# -----------------------------
# Step 1: Load Environment Variables
# -----------------------------
load_dotenv()

# -----------------------------
# Build connector JSON in memory
# -----------------------------
connector_config = {
    "name": "postgres-connector",
    "config": {
        # The Java class for the Debezium Postgres Connector
        "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
        
        # Database connection details (from .env)
        "database.hostname": os.getenv("POSTGRES_HOST"),
        "database.port": os.getenv("POSTGRES_PORT"), 
        "database.user": os.getenv("POSTGRES_USER"),
        "database.password": os.getenv("POSTGRES_PASSWORD"),
        "database.dbname": os.getenv("POSTGRES_DB"),
        
        # Prefix for the generated Kafka topics (e.g., banking_server.public.customers)
        "topic.prefix": "banking_server",
        "table.include.list": "public.customers,public.accounts,public.transactions",
        
        # Logical decoding plugin (pgoutput is standard for Postgres 10+)
        "plugin.name": "pgoutput",
        "slot.name": "banking_slot",
        "publication.autocreate.mode": "filtered",
        
        # Data handling preferences
        "tombstones.on.delete": "false", # Don't send null messages on delete
        "decimal.handling.mode": "double",
    },
}

# -----------------------------
# Step 3: Send Request to Kafka Connect
# -----------------------------
# Kafka Connect runs on port 8083 by default
url = "http://localhost:8083/connectors"
headers = {"Content-Type": "application/json"}

response = requests.post(url, headers=headers, data=json.dumps(connector_config))

# -----------------------------
# Step 4: Handle Response
# -----------------------------
if response.status_code == 201:
    print("✅ Connector created successfully!")
elif response.status_code == 409:
    print("⚠️ Connector already exists.")
else:
    print(f"❌ Failed to create connector ({response.status_code}): {response.text}")