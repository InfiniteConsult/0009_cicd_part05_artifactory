#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               04-setup-artifactory.sh
#
#  This is the "Architect" script for Artifactory.
#
#  UPDATED STRATEGY (HTTP ONLY):
#  1. Generates Secrets.
#  2. Stages Root CA (For DB Trust).
#  3. NO Router SSL (Standard HTTP).
#
# -----------------------------------------------------------

set -e

# --- 1. Define Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ARTIFACTORY_BASE="$HOST_CICD_ROOT/artifactory"
VAR_ETC="$ARTIFACTORY_BASE/var/etc"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

# Certificate Source Paths
CA_DIR="$HOST_CICD_ROOT/ca"
SRC_ROOT_CA="$CA_DIR/pki/certs/ca.pem"

echo "Starting Artifactory 'Architect' Setup..."

# --- 2. Secrets Management ---
if [ ! -f "$MASTER_ENV_FILE" ]; then
    echo "ERROR: Master env file not found at $MASTER_ENV_FILE"
    exit 1
fi
source "$MASTER_ENV_FILE"

if [ -z "$ARTIFACTORY_DB_PASSWORD" ]; then
    echo "ERROR: ARTIFACTORY_DB_PASSWORD not found in cicd.env"
    echo "Please run 01-setup-database.sh first."
    exit 1
fi

check_and_generate_secret() {
    local var_name=$1
    local var_value=${!var_name}
    local description=$2
    local length=$3 # bytes

    if [ -z "$var_value" ]; then
        echo "Generating new $description ($var_name)..."
        local new_secret=$(openssl rand -hex $length)
        echo "" >> "$MASTER_ENV_FILE"
        echo "# $description" >> "$MASTER_ENV_FILE"
        echo "$var_name=\"$new_secret\"" >> "$MASTER_ENV_FILE"
        export $var_name="$new_secret"
    else
        echo "Found existing $var_name."
    fi
}

check_and_generate_secret "ARTIFACTORY_MASTER_KEY" "Artifactory Master Key" 32
check_and_generate_secret "ARTIFACTORY_JOIN_KEY" "Artifactory Join Key" 16
check_and_generate_secret "ARTIFACTORY_ADMIN_PASSWORD" "Artifactory Initial Admin Password" 16

# --- 3. Directory Preparation ---
# We clean up any old bootstrap keys to ensure HTTP mode
if [ -d "$ARTIFACTORY_BASE/var/bootstrap" ]; then
    echo "Cleaning up old bootstrap keys to force HTTP mode..."
    rm -rf "$ARTIFACTORY_BASE/var/bootstrap"
fi

mkdir -p "$VAR_ETC/security/keys/trusted"
mkdir -p "$VAR_ETC/access"

# --- 4. Trust Staging ---
# We still need the CA to trust the Postgres DB connection
cp "$SRC_ROOT_CA" "$VAR_ETC/security/keys/trusted/ca.pem"
echo "Root CA staged."

# --- 5. Secret File Generation ---
echo -n "$ARTIFACTORY_MASTER_KEY" > "$VAR_ETC/security/master.key"
chmod 600 "$VAR_ETC/security/master.key"
echo -n "$ARTIFACTORY_JOIN_KEY" > "$VAR_ETC/security/join.key"
chmod 600 "$VAR_ETC/security/join.key"
echo "admin@*=$ARTIFACTORY_ADMIN_PASSWORD" > "$VAR_ETC/access/bootstrap.creds"
chmod 600 "$VAR_ETC/access/bootstrap.creds"
echo "Secret files created."

# --- 6. System Configuration (system.yaml) ---
echo "--- Phase 5: Generating system.yaml ---"
SYSTEM_YAML="$VAR_ETC/system.yaml"

cat << EOF > "$SYSTEM_YAML"
configVersion: 1

shared:
  node:
    ip: artifactory.cicd.local

  # Fix internal connection issues (IPv4)
  extraJavaOpts: "-Djava.net.preferIPv4Stack=true"

  database:
    type: postgresql
    driver: org.postgresql.Driver
    url: "jdbc:postgresql://postgres.cicd.local:5432/artifactory?sslmode=verify-full&sslrootcert=/var/opt/jfrog/artifactory/etc/security/keys/trusted/ca.pem"
    username: "artifactory"
    password: "${ARTIFACTORY_DB_PASSWORD}"
EOF

echo "system.yaml generated."

# --- 7. Final Permissions ---
sudo chown -R 1030:1030 "$ARTIFACTORY_BASE"
echo "--- Setup Complete ---"