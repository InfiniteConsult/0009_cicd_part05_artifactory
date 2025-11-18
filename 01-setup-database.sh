#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               01-setup-database.sh
#
#  This is the "Architect" script for the Shared Database.
#  It prepares the host environment for PostgreSQL 17.
#
#  1. Secrets: Generates/Persists passwords for all 4 services.
#  2. Certs: Issues SSL certs and fixes permissions (UID 999).
#  3. Security: Generates pg_hba.conf enforcing SSL for cicd-net.
#  4. Init: Creates the SQL script to initialize databases with
#           PostgreSQL 17 compatible permissions.
#
# -----------------------------------------------------------

set -e

# --- 1. Define Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
POSTGRES_BASE="$HOST_CICD_ROOT/postgres"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

# Directories to be mounted
DIR_CERTS="$POSTGRES_BASE/certs"
DIR_CONFIG="$POSTGRES_BASE/config"
DIR_INIT="$POSTGRES_BASE/init"

# Certificate Authority Paths
CA_DIR="$HOST_CICD_ROOT/ca"
SERVICE_NAME="postgres.cicd.local"
CA_SERVICE_DIR="$CA_DIR/pki/services/$SERVICE_NAME"
SRC_CRT="$CA_SERVICE_DIR/$SERVICE_NAME.crt.pem"
SRC_KEY="$CA_SERVICE_DIR/$SERVICE_NAME.key.pem"
SRC_ROOT_CA="$CA_DIR/pki/certs/ca.pem"

echo "Starting PostgreSQL 'Architect' Setup..."

# --- 2. Secrets Management ---
echo "--- Phase 1: Secrets Management ---"

if [ ! -f "$MASTER_ENV_FILE" ]; then
    echo "ERROR: Master env file not found at $MASTER_ENV_FILE"
    exit 1
fi

source "$MASTER_ENV_FILE"

# Helper function to check and generate secret
check_and_generate_secret() {
    local var_name=$1
    local var_value=${!var_name}
    local description=$2

    if [ -z "$var_value" ]; then
        echo "Generating new $description ($var_name)..."
        # 32 bytes of entropy = 64 hex characters
        local new_secret=$(openssl rand -hex 32)

        echo "" >> "$MASTER_ENV_FILE"
        echo "# $description" >> "$MASTER_ENV_FILE"
        echo "$var_name=\"$new_secret\"" >> "$MASTER_ENV_FILE"

        # Export for current session
        export $var_name="$new_secret"
    else
        echo "Found existing $var_name."
    fi
}

check_and_generate_secret "POSTGRES_ROOT_PASSWORD" "PostgreSQL Root Password"
check_and_generate_secret "ARTIFACTORY_DB_PASSWORD" "Artifactory DB Password"
check_and_generate_secret "SONARQUBE_DB_PASSWORD" "SonarQube DB Password"
check_and_generate_secret "MATTERMOST_DB_PASSWORD" "Mattermost DB Password"
check_and_generate_secret "GRAFANA_DB_PASSWORD" "Grafana DB Password"

# --- 3. Certificate Preparation ---
echo "--- Phase 2: TLS Certificate Preparation ---"

# Ensure local directories exist
mkdir -p "$DIR_CERTS"
mkdir -p "$DIR_CONFIG"
mkdir -p "$DIR_INIT"

# Check if cert already exists in the CA structure
if [ ! -f "$SRC_CRT" ]; then
    echo "Certificate for $SERVICE_NAME not found in CA. Issuing new certificate..."

    # Use a subshell to change directory without affecting the script
    (
        cd ../0006_cicd_part02_certificate_authority || exit 1
        # Check if the script exists
        if [ ! -x "./02-issue-service-cert.sh" ]; then
            echo "ERROR: Cert issuance script not found or not executable."
            exit 1
        fi
        ./02-issue-service-cert.sh "$SERVICE_NAME"
    )
else
    echo "Certificate for $SERVICE_NAME already exists. Skipping issuance."
fi

# Copy certificates to the Postgres mount directory
echo "Copying certificates to $DIR_CERTS..."
# We rename them to standard postgres names for simplicity in the run command
sudo cp "$SRC_CRT" "$DIR_CERTS/server.crt"
sudo cp "$SRC_KEY" "$DIR_CERTS/server.key"
sudo cp "$SRC_ROOT_CA" "$DIR_CERTS/root.crt"

# CRITICAL: Permission Fix for Container UID 999
# PostgreSQL refuses to start if the key file is readable by anyone else.
# The container user 'postgres' usually has UID 999.
echo "Applying strict permissions to SSL keys (requires sudo)..."
echo "Setting ownership to UID 999 and mode 0600."

sudo chown -R 999:999 "$DIR_CERTS"
sudo chmod 600 "$DIR_CERTS/server.key"
# Public certs can be readable
sudo chmod 644 "$DIR_CERTS/server.crt"
sudo chmod 644 "$DIR_CERTS/root.crt"


# --- 4. Security Policy (pg_hba.conf) ---
echo "--- Phase 3: Generating pg_hba.conf ---"
HBA_FILE="$DIR_CONFIG/pg_hba.conf"

# We explicitly restrict access to the docker subnet (172.30.0.0/24)
# and enforce SSL (hostssl).
cat << EOF > "$HBA_FILE"
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# 1. Localhost (Loopback) - Allow for local debugging/healthchecks
local   all             all                                     trust
hostssl all             all             127.0.0.1/32            scram-sha-256

# 2. CICD Network - Reject unencrypted connections
hostnossl all           all             172.30.0.0/24           reject

# 3. CICD Network - Allow SSL connections with password
hostssl all             all             172.30.0.0/24           scram-sha-256

# 4. Reject everything else (Implicit, but good for documentation)
# host    all             all             0.0.0.0/0               reject
EOF
echo "Policy written to $HBA_FILE"


# --- 5. Init Script Generation ---
echo "--- Phase 4: Generating Initialization SQL ---"
INIT_SCRIPT="$DIR_INIT/01-init.sh"

# We use a shell script that calls psql. This allows us to use variables.
# Note: We use 'cat << "EOF"' (quoted EOF) to prevent variable expansion
# by the host shell during generation. The variables ($POSTGRES_USER, etc.)
# will be expanded by the CONTAINER shell at runtime.

cat << "EOF" > "$INIT_SCRIPT"
#!/bin/bash
set -e

echo "--- Initializing Multi-Tenant Databases ---"

# Define constants for PG17 Compatibility
# We use 'C' collation to satisfy SonarQube's strict case-sensitivity requirement
# while maintaining compatibility with Artifactory, Mattermost, and Grafana.
DB_ENCODING='UTF8'
DB_COLLATE='C'
DB_CTYPE='C'

# Execute SQL block
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL

    -- ===================================================
    -- 1. ARTIFACTORY
    -- ===================================================
    CREATE USER artifactory WITH PASSWORD '$ARTIFACTORY_DB_PASSWORD';
    CREATE DATABASE artifactory WITH OWNER artifactory ENCODING='$DB_ENCODING' LC_COLLATE='$DB_COLLATE' LC_CTYPE='$DB_CTYPE' TEMPLATE=template0;
    GRANT ALL PRIVILEGES ON DATABASE artifactory TO artifactory;
    -- PG17 Fix: Explicitly grant creation on public schema
    GRANT CREATE, USAGE ON SCHEMA public TO artifactory;

    -- ===================================================
    -- 2. SONARQUBE
    -- ===================================================
    CREATE USER sonarqube WITH PASSWORD '$SONARQUBE_DB_PASSWORD';
    CREATE DATABASE sonarqube WITH OWNER sonarqube ENCODING='$DB_ENCODING' LC_COLLATE='$DB_COLLATE' LC_CTYPE='$DB_CTYPE' TEMPLATE=template0;
    GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonarqube;
    -- PG17 Fix: Explicitly grant creation on public schema
    GRANT CREATE, USAGE ON SCHEMA public TO sonarqube;

    -- ===================================================
    -- 3. MATTERMOST
    -- ===================================================
    CREATE USER mattermost WITH PASSWORD '$MATTERMOST_DB_PASSWORD';
    CREATE DATABASE mattermost WITH OWNER mattermost ENCODING='$DB_ENCODING' LC_COLLATE='$DB_COLLATE' LC_CTYPE='$DB_CTYPE' TEMPLATE=template0;
    GRANT ALL PRIVILEGES ON DATABASE mattermost TO mattermost;
    -- PG17 Fix: Explicitly grant creation on public schema
    GRANT CREATE, USAGE ON SCHEMA public TO mattermost;

    -- ===================================================
    -- 4. GRAFANA
    -- ===================================================
    CREATE USER grafana WITH PASSWORD '$GRAFANA_DB_PASSWORD';
    CREATE DATABASE grafana WITH OWNER grafana ENCODING='$DB_ENCODING' LC_COLLATE='$DB_COLLATE' LC_CTYPE='$DB_CTYPE' TEMPLATE=template0;
    GRANT ALL PRIVILEGES ON DATABASE grafana TO grafana;
    -- PG17 Fix: Explicitly grant creation on public schema
    GRANT CREATE, USAGE ON SCHEMA public TO grafana;

EOSQL

echo "--- Database Initialization Complete ---"
EOF

# Make the init script executable
chmod +x "$INIT_SCRIPT"
echo "Init script written to $INIT_SCRIPT"


# --- 6. Create Scoped Environment File ---
echo "--- Phase 5: Creating Scoped postgres.env ---"
SCOPED_ENV_FILE="$POSTGRES_BASE/postgres.env"

# We map the variables from our Master Env (Host) to the specific
# variable names expected by the Postgres Image and our Init Script.
cat << EOF > "$SCOPED_ENV_FILE"
# Scoped Environment for PostgreSQL Container
# Auto-generated by 01-setup-database.sh

# 1. Standard PostgreSQL Image Variables
# Note: We map our POSTGRES_ROOT_PASSWORD to POSTGRES_PASSWORD
POSTGRES_PASSWORD=$POSTGRES_ROOT_PASSWORD
POSTGRES_USER=postgres
POSTGRES_DB=postgres

# 2. Application Passwords
# These are required by /docker-entrypoint-initdb.d/01-init.sh
ARTIFACTORY_DB_PASSWORD=$ARTIFACTORY_DB_PASSWORD
SONARQUBE_DB_PASSWORD=$SONARQUBE_DB_PASSWORD
MATTERMOST_DB_PASSWORD=$MATTERMOST_DB_PASSWORD
GRAFANA_DB_PASSWORD=$GRAFANA_DB_PASSWORD
EOF

# Secure the file (contains cleartext passwords)
chmod 600 "$SCOPED_ENV_FILE"
echo "Scoped env file written to $SCOPED_ENV_FILE"


echo "--- Setup Complete ---"
echo "Secrets persisted in cicd.env"
echo "Scoped secrets created in $SCOPED_ENV_FILE"
echo "Certificates prepared in $DIR_CERTS (UID 999)"
echo "Config generated in $DIR_CONFIG"
echo "Ready to run 02-deploy-database.sh"