#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               07-update-jenkins.sh
#
#  This script integrates Jenkins with Artifactory.
#
#  1. Prereqs: Installs python3-yaml on host.
#  2. Secrets: Injects Artifactory secrets into jenkins.env.
#  3. JCasC:   Updates jenkins.yaml with Artifactory config.
#  4. Apply:   Re-deploys Jenkins (Recreate Container).
#
# -----------------------------------------------------------

set -e

# --- Paths ---
CICD_ROOT="$HOME/cicd_stack"
# The module where we defined the Jenkins deployment scripts
JENKINS_MODULE_DIR="$HOME/Documents/FromFirstPrinciples/articles/0008_cicd_part04_jenkins"
JENKINS_ENV_FILE="$JENKINS_MODULE_DIR/jenkins.env"
DEPLOY_SCRIPT="$JENKINS_MODULE_DIR/03-deploy-controller.sh"

# Path to the Python helper
PY_HELPER="update_jcasc.py"
# Path to master secrets
MASTER_ENV="$CICD_ROOT/cicd.env"

echo "[INFO] Starting Jenkins <-> Artifactory Integration..."

# --- 1. Prerequisites ---
echo "[INFO] Checking for Python YAML library..."
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "[WARN] python3-yaml not found. Installing..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq python3-yaml python3-dotenv
else
    echo "[INFO] python3-yaml is already installed."
fi

# --- 2. Secret Injection ---
if [ ! -f "$MASTER_ENV" ]; then
    echo "[ERROR] Master environment file not found: $MASTER_ENV"
    exit 1
fi

# Load ARTIFACTORY_ADMIN_TOKEN
source "$MASTER_ENV"

if [ -z "$ARTIFACTORY_ADMIN_TOKEN" ]; then
    echo "[ERROR] ARTIFACTORY_ADMIN_TOKEN not found in cicd.env."
    echo "       Please ensure you have completed Module 05 setup."
    exit 1
fi

if [ ! -f "$JENKINS_ENV_FILE" ]; then
    echo "[ERROR] Jenkins env file not found at: $JENKINS_ENV_FILE"
    exit 1
fi

echo "[INFO] Injecting Artifactory secrets into jenkins.env..."

# Append secrets only if they don't exist
grep -q "JENKINS_ARTIFACTORY_URL" "$JENKINS_ENV_FILE" || cat << EOF >> "$JENKINS_ENV_FILE"

# --- Artifactory Integration ---
JENKINS_ARTIFACTORY_URL=https://artifactory.cicd.local:8082/artifactory
JENKINS_ARTIFACTORY_USERNAME=admin
JENKINS_ARTIFACTORY_PASSWORD=$ARTIFACTORY_ADMIN_TOKEN
EOF

echo "[INFO] Secrets injected."

# --- 3. Update JCasC ---
echo "[INFO] Updating JCasC configuration..."
if [ ! -f "$PY_HELPER" ]; then
    echo "[ERROR] Python helper script not found at $PY_HELPER"
    echo "       Please create the update_jcasc.py script first."
    exit 1
fi

python3 "$PY_HELPER"

# --- 4. Re-Deploy Jenkins ---
echo "[INFO] Triggering Jenkins Re-deployment (Container Recreate)..."

if [ ! -x "$DEPLOY_SCRIPT" ]; then
    echo "[ERROR] Deploy script not found or not executable: $DEPLOY_SCRIPT"
    exit 1
fi

# Execute the deploy script from its own directory context
(cd "$JENKINS_MODULE_DIR" && ./03-deploy-controller.sh)

echo "[SUCCESS] Integration update complete."
echo "[INFO] Jenkins is restarting. Wait for initialization."