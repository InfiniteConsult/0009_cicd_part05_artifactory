#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               04-setup-artifactory.sh
#
#  This is the "Architect" script for Artifactory.
#
#  UPDATED STRATEGY: Internal TLS (Access as CA)
#  1. Enable TLS in Access config.
#  2. Enable HTTPS Connector in Artifactory config.
#  3. Set Base URL to HTTPS port 8443.
#  4. Standard PostgreSQL SSL & IPv4 fixes retained.
#
# -----------------------------------------------------------

set -e

# --- 1. Define Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ARTIFACTORY_BASE="$HOST_CICD_ROOT/artifactory"
VAR_ETC="$ARTIFACTORY_BASE/var/etc"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

# Certificate Source (Still needed for Database Trust)
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
mkdir -p "$VAR_ETC/security/keys/trusted"
mkdir -p "$VAR_ETC/access"
mkdir -p "$VAR_ETC/artifactory"

# --- 4. Trust Staging (DB Only) ---
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

# --- 6. Configuration Imports ---

# A. Access Config (Enable Internal TLS)
ACCESS_IMPORT="$VAR_ETC/access/access.config.import.yml"
cat << EOF > "$ACCESS_IMPORT"
security:
  tls: true
EOF
echo "Access config (TLS enabled) generated."

# B. Artifactory Bootstrap (Base URL & Repos)
ART_IMPORT="$VAR_ETC/artifactory/artifactory.config.import.yml"
cat << EOF > "$ART_IMPORT"
version: 1
GeneralConfiguration:
  # We point to the HTTPS port 8443
  baseUrl: "https://artifactory.cicd.local:8443"

OnboardingConfiguration:
  repoTypes:
    - maven
    - gradle
    - docker
    - pypi
    - npm
EOF
echo "Artifactory bootstrap config generated."

# --- 7. System Configuration (system.yaml) ---
echo "--- Phase 5: Generating system.yaml ---"
SYSTEM_YAML="$VAR_ETC/system.yaml"

cat << EOF > "$SYSTEM_YAML"
configVersion: 1

shared:
  node:
    ip: artifactory.cicd.local

  # IPv4 Fix
  extraJavaOpts: "-Djava.net.preferIPv4Stack=true"

  database:
    type: postgresql
    driver: org.postgresql.Driver
    url: "jdbc:postgresql://postgres.cicd.local:5432/artifactory?sslmode=verify-full&sslrootcert=/var/opt/jfrog/artifactory/etc/security/keys/trusted/ca.pem"
    username: "artifactory"
    password: "${ARTIFACTORY_DB_PASSWORD}"

artifactory:
  tomcat:
    httpsConnector:
      enabled: true
      port: 8443
EOF

echo "system.yaml generated."

# --- 8. Final Permissions ---
sudo chown -R 1030:1030 "$ARTIFACTORY_BASE"
echo "--- Setup Complete ---"