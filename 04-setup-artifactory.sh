#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               04-setup-artifactory.sh
#
#  This is the "Architect" script for Artifactory.
#  It prepares the host environment configuration.
#
#  1. Secrets: Generates/Persists Master Key and Join Key.
#  2. Certs: Stages Service Certs and Root CA for Trust.
#  3. Config: Generates system.yaml connected to Postgres.
#  4. Permissions: Enforces UID 1030 ownership.
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
SERVICE_NAME="artifactory.cicd.local"
SRC_CRT="$CA_DIR/pki/services/$SERVICE_NAME/$SERVICE_NAME.crt.pem"
SRC_KEY="$CA_DIR/pki/services/$SERVICE_NAME/$SERVICE_NAME.key.pem"
SRC_ROOT_CA="$CA_DIR/pki/certs/ca.pem"

echo "Starting Artifactory 'Architect' Setup..."

# --- 2. Secrets Management ---
echo "--- Phase 1: Secrets Management ---"

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
echo "--- Phase 2: Directory Structure & Permissions ---"
mkdir -p "$VAR_ETC/security/ssl"
mkdir -p "$VAR_ETC/security/keys/trusted"
mkdir -p "$VAR_ETC/access"

# --- 4. Certificate Staging ---
echo "--- Phase 3: Staging Certificates ---"
if [ ! -f "$SRC_CRT" ]; then
    echo "ERROR: Certificate for $SERVICE_NAME not found."
    exit 1
fi
cp "$SRC_CRT" "$VAR_ETC/security/ssl/server.crt"
cp "$SRC_KEY" "$VAR_ETC/security/ssl/server.key"
cp "$SRC_ROOT_CA" "$VAR_ETC/security/keys/trusted/ca.pem"
echo "Certificates staged."


# --- 5. Secret File Generation ---
echo "--- Phase 4: Writing Secret Files ---"
echo -n "$ARTIFACTORY_MASTER_KEY" > "$VAR_ETC/security/master.key"
chmod 600 "$VAR_ETC/security/master.key"
echo -n "$ARTIFACTORY_JOIN_KEY" > "$VAR_ETC/security/join.key"
chmod 600 "$VAR_ETC/security/join.key"
echo "admin@*=$ARTIFACTORY_ADMIN_PASSWORD" > "$VAR_ETC/access/bootstrap.creds"
chmod 600 "$VAR_ETC/access/bootstrap.creds"
echo "Secret files created with 0600 permissions."


# --- 6. System Configuration (system.yaml) ---
echo "--- Phase 5: Generating system.yaml ---"
SYSTEM_YAML="$VAR_ETC/system.yaml"

# We explicitly define the 'sslrootcert' parameter in the JDBC URL.
# This points to the location where we just staged 'ca.pem'.
# Path: /var/opt/jfrog/artifactory/etc/security/keys/trusted/ca.pem

cat << EOF > "$SYSTEM_YAML"
configVersion: 1

shared:
  node:
    ip: artifactory.cicd.local

  database:
    type: postgresql
    driver: org.postgresql.Driver
    # FIXED: Added sslrootcert to point to our staged CA
    url: "jdbc:postgresql://postgres.cicd.local:5432/artifactory?sslmode=verify-full&sslrootcert=/var/opt/jfrog/artifactory/etc/security/keys/trusted/ca.pem"
    username: "artifactory"
    password: "${ARTIFACTORY_DB_PASSWORD}"

artifactory:
  tomcat:
    httpsConnector:
      enabled: true
      port: 10500
      certificateFile: "/var/opt/jfrog/artifactory/etc/security/ssl/server.crt"
      certificateKeyFile: "/var/opt/jfrog/artifactory/etc/security/ssl/server.key"

router:
  entrypoints:
    externalPort: 10501

event:
  security:
    blacklist:
      enabled: false
EOF

echo "system.yaml generated."

# --- 7. Final Permissions Handover ---
echo "--- Phase 6: Enforcing UID 1030 Ownership ---"
sudo chown -R 1030:1030 "$ARTIFACTORY_BASE"

echo "--- Setup Complete ---"
echo "Ready to run 05-deploy-artifactory.sh"