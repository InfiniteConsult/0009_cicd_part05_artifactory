#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               05-deploy-artifactory.sh
#
#  This is the "Construction Crew" script.
#  It launches the Artifactory container.
#
# -----------------------------------------------------------

set -e

# --- 1. Define Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ARTIFACTORY_BASE="$HOST_CICD_ROOT/artifactory"
VAR_ETC="$ARTIFACTORY_BASE/var/etc"

SYSTEM_YAML="$VAR_ETC/system.yaml"
MASTER_KEY="$VAR_ETC/security/master.key"
JOIN_KEY="$VAR_ETC/security/join.key"

echo "Starting Artifactory Deployment..."

# --- 2. Prerequisite Checks ---
if [ ! -f "$SYSTEM_YAML" ]; then
    echo "ERROR: system.yaml not found. Run 04-setup-artifactory.sh first."
    exit 1
fi
if [ ! -f "$MASTER_KEY" ]; then
    echo "ERROR: master.key not found. Run 04-setup-artifactory.sh first."
    exit 1
fi
if [ ! -f "$JOIN_KEY" ]; then
    echo "ERROR: join.key not found. Run 04-setup-artifactory.sh first."
    exit 1
fi

# --- 3. Clean Slate Protocol ---
if [ "$(docker ps -q -f name=artifactory)" ]; then
    echo "Stopping existing 'artifactory' container..."
    docker stop artifactory
fi
if [ "$(docker ps -aq -f name=artifactory)" ]; then
    echo "Removing existing 'artifactory' container..."
    docker rm artifactory
fi

# --- 4. Launch Container ---
echo "Launching Artifactory OSS container..."

# Mount Fix Explanation:
# 1. artifactory-data -> /var/opt/jfrog/artifactory
#    This is the volume root. It contains 'data', 'etc', 'logs', etc.
#
# 2. $VAR_ETC -> /var/opt/jfrog/artifactory/etc
#    We explicitly overlay ONLY the 'etc' directory.
#    This puts system.yaml exactly where Artifactory looks for it.

docker run -d \
  --name artifactory \
  --restart always \
  --network cicd-net \
  --hostname artifactory.cicd.local \
  --publish 127.0.0.1:10500:10500 \
  --publish 127.0.0.1:10501:10501 \
  --volume artifactory-data:/var/opt/jfrog/artifactory \
  --volume "$VAR_ETC":/var/opt/jfrog/artifactory/etc \
  releases-docker.jfrog.io/jfrog/artifactory-oss:latest

echo "Artifactory container started."
echo "   This is a heavy Java application."
echo "   It will take 1-2 minutes to initialize."
echo "   Monitor logs with: docker logs -f artifactory"
echo ""
echo "   Look for: 'Artifactory Protocol (http) service is listening on port 10500'"
echo "   Then access: https://artifactory.cicd.local:10500"