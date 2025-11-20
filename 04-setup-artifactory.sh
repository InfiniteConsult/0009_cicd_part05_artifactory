#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               04-setup-artifactory.sh
#
#  This is the "Architect" script for Artifactory.
#
#  UPDATED: "Docs Compliance Mode"
#  1. Generates Certificate with clientAuth + Critical KeyUsage.
#  2. Sets shared.node.ip to match Certificate CN.
#  3. Uses Bootstrap mechanism for SSL ingest.
#
# -----------------------------------------------------------

set -e

# --- 1. Define Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ARTIFACTORY_BASE="$HOST_CICD_ROOT/artifactory"
VAR_ETC="$ARTIFACTORY_BASE/var/etc"
VAR_BOOTSTRAP="$ARTIFACTORY_BASE/var/bootstrap"
MASTER_ENV_FILE="$HOST_CICD_ROOT/cicd.env"

# CA Paths
CA_DIR="$HOST_CICD_ROOT/ca"
CA_CERT="$CA_DIR/pki/certs/ca.pem"
CA_KEY="$CA_DIR/pki/private/ca.key"
CA_PASSWORD="your_secure_password"

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
mkdir -p "$VAR_BOOTSTRAP/router/keys"

# --- 4. Strict Certificate Generation ---
echo "--- Phase 3: Generating Strict Compliance Certificate ---"

ROUTER_CERT_DIR="$VAR_BOOTSTRAP/router/keys"
ROUTER_KEY="$ROUTER_CERT_DIR/custom-server.key"
ROUTER_CSR="$ROUTER_CERT_DIR/custom-server.csr"
ROUTER_CRT="$ROUTER_CERT_DIR/custom-server.crt"
ROUTER_CNF="$ROUTER_CERT_DIR/router.cnf"

# 1. Generate Private Key
openssl genrsa -out "$ROUTER_KEY" 4096
chmod 600 "$ROUTER_KEY"

# 2. Create OpenSSL Config (The Requirements from Docs)
cat > "$ROUTER_CNF" <<EOF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C=ZA
ST=Gauteng
L=Johannesburg
O=Local CICD Stack
CN=artifactory.cicd.local

[v3_req]
# REQ 1: Key usage extension must be marked CRITICAL
# REQ 2: digitalSignature + keyEncipherment must be enabled
keyUsage = critical, digitalSignature, keyEncipherment

# REQ 3: Extended key usage tlsWebServerAuthentication + tlsWebClientAuthentication
extendedKeyUsage = serverAuth, clientAuth

basicConstraints = critical, CA:FALSE
subjectAltName = @alt_names

[alt_names]
# REQ 4: SANs must include the subject (CN)
DNS.1 = artifactory.cicd.local
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

# 3. Generate CSR
openssl req -new -key "$ROUTER_KEY" -out "$ROUTER_CSR" -config "$ROUTER_CNF"

# 4. Sign with Root CA
openssl x509 -req -in "$ROUTER_CSR" \
    -CA "$CA_CERT" -CAkey "$CA_KEY" \
    -CAcreateserial -out "$ROUTER_CRT" \
    -days 365 \
    -sha256 \
    -extensions v3_req -extfile "$ROUTER_CNF" \
    -passin pass:$CA_PASSWORD

# Cleanup
rm "$ROUTER_CSR" "$ROUTER_CNF"
chmod 644 "$ROUTER_CRT"
echo "Compliant Certificate generated."

# --- 5. Trust Staging ---
# Docs: "Copy the CA of the custom TLS certificate in etc/security/keys/trusted/"
cp "$CA_CERT" "$VAR_ETC/security/keys/trusted/ca.pem"
echo "Root CA staged."

# --- 6. Secret File Generation ---
echo -n "$ARTIFACTORY_MASTER_KEY" > "$VAR_ETC/security/master.key"
chmod 600 "$VAR_ETC/security/master.key"
echo -n "$ARTIFACTORY_JOIN_KEY" > "$VAR_ETC/security/join.key"
chmod 600 "$VAR_ETC/security/join.key"
echo "admin@*=$ARTIFACTORY_ADMIN_PASSWORD" > "$VAR_ETC/access/bootstrap.creds"
chmod 600 "$VAR_ETC/access/bootstrap.creds"
echo "Secret files created."

# --- 7. Configuration Imports ---

# A. Access Config (Enable TLS)
ACCESS_IMPORT="$VAR_ETC/access/access.config.import.yml"
cat << EOF > "$ACCESS_IMPORT"
security:
  tls: true
EOF

# B. Artifactory Config (Base URL)
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

# --- 8. System Configuration (system.yaml) ---
echo "--- Phase 5: Generating system.yaml ---"
SYSTEM_YAML="$VAR_ETC/system.yaml"

cat << EOF > "$SYSTEM_YAML"
configVersion: 1

shared:
  # REQ 5: The certificate's subject must match the property shared.node.ip
  node:
    ip: artifactory.cicd.local

  # IPv4 Fix (Still required for Docker stability)
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
      # We do not specify file paths. We rely on Bootstrap to import them
      # into the internal keystore.
EOF

echo "system.yaml generated."

# --- 9. Final Permissions ---
sudo chown -R 1030:1030 "$ARTIFACTORY_BASE"
echo "--- Setup Complete ---"