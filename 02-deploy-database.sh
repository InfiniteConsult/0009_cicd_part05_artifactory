#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               02-deploy-database.sh
#
#  This is the "Launcher" script for the Shared Database.
#  It runs the PostgreSQL 17 container using the assets
#  prepared by 01-setup-database.sh.
#
# -----------------------------------------------------------

set -e

# --- 1. Define Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
POSTGRES_BASE="$HOST_CICD_ROOT/postgres"

# Prerequisite files
SCOPED_ENV_FILE="$POSTGRES_BASE/postgres.env"
SSL_KEY="$POSTGRES_BASE/certs/server.key"
HBA_CONF="$POSTGRES_BASE/config/pg_hba.conf"

echo "Starting PostgreSQL Deployment..."

# --- 2. Prerequisite Checks ---
# We fail fast if the architect script has not been run.
if [ ! -f "$SCOPED_ENV_FILE" ]; then
    echo "ERROR: Scoped env file not found at $SCOPED_ENV_FILE"
    echo "Please run 01-setup-database.sh first."
    exit 1
fi

if [ ! -f "$SSL_KEY" ]; then
    echo "ERROR: SSL Key not found at $SSL_KEY"
    echo "Please run 01-setup-database.sh first."
    exit 1
fi

if [ ! -f "$HBA_CONF" ]; then
    echo "ERROR: pg_hba.conf not found at $HBA_CONF"
    echo "Please run 01-setup-database.sh first."
    exit 1
fi

# --- 3. Clean Slate Protocol ---
# Stop and remove any existing container to ensure a clean start
if [ "$(docker ps -q -f name=postgres)" ]; then
    echo "Stopping existing 'postgres' container..."
    docker stop postgres
fi
if [ "$(docker ps -aq -f name=postgres)" ]; then
    echo "Removing existing 'postgres' container..."
    docker rm postgres
fi

# --- 4. Volume Management ---
# Create the persistent data volume if it doesn't exist
docker volume create postgres-data > /dev/null
echo "Verified 'postgres-data' volume."

# --- 5. Deploy Container ---
echo "Launching PostgreSQL 17 container..."

# Notes on Mounts:
# 1. postgres-data: Persists the DB files.
# 2. certs: Provides the SSL keys (Must be owned by UID 999 - fixed in 01).
# 3. config: Provides the strict pg_hba.conf.
# 4. init: Provides the SQL script to create Artifactory/Sonar/etc users.

docker run -d \
  --name postgres \
  --restart always \
  --network cicd-net \
  --hostname postgres.cicd.local \
  --publish 127.0.0.1:5432:5432 \
  --env-file "$SCOPED_ENV_FILE" \
  --volume postgres-data:/var/lib/postgresql/data \
  --volume "$POSTGRES_BASE/certs":/etc/postgresql/ssl \
  --volume "$POSTGRES_BASE/config/pg_hba.conf":/etc/postgresql/pg_hba.conf \
  --volume "$POSTGRES_BASE/init":/docker-entrypoint-initdb.d \
  postgres:17 \
  -c ssl=on \
  -c ssl_cert_file=/etc/postgresql/ssl/server.crt \
  -c ssl_key_file=/etc/postgresql/ssl/server.key \
  -c hba_file=/etc/postgresql/pg_hba.conf

echo "PostgreSQL container started."
echo "Monitor initialization logs with: docker logs -f postgres"
echo "Wait for 'database system is ready to accept connections' before proceeding."