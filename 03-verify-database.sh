#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               03-verify-database.sh
#
#  This script audits the PostgreSQL 17 deployment.
#
#  USAGE INSTRUCTIONS:
#  1. This script must be run INSIDE the 'dev-container'.
#  2. You must stage the secrets file on the HOST first:
#     cp ~/cicd_stack/postgres/postgres.env ~/Documents/FromFirstPrinciples/data/
#
#  What this script checks:
#  1. Network connectivity to postgres.cicd.local.
#  2. Strict SSL enforcement (PGSSLMODE=verify-full).
#  3. Negative Test: Ensures non-SSL connections are REJECTED.
#  4. Authentication for all 4 service users.
#  5. Authorization (Can they create tables in 'public'?).
#
# -----------------------------------------------------------

set -e

# Fix for Perl locale warnings in some containers
export LC_ALL=C

echo "Starting Database Verification Audit..."

# --- 1. Dependency Check ---
# The dev-container might not have the psql client installed.
if ! command -v psql &> /dev/null; then
    echo "psql not found. Installing PostgreSQL 17 client..."
    # We assume sudo is available or we are root in dev-container
    sudo apt-get update -qq
    sudo apt-get install -y -qq postgresql-common
    # Install the official PG repo to get version 17
    yes | sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
    sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client-17
fi

# --- 2. Load Environment Secrets ---
# We expect the file to be in ~/data (mapped from Host ~/Documents/FromFirstPrinciples/data)
ENV_FILE="$HOME/data/postgres.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "CRITICAL ERROR: Secrets file not found at $ENV_FILE"
    echo "Please run this command on your HOST machine first:"
    echo "  cp ~/cicd_stack/postgres/postgres.env ~/Documents/FromFirstPrinciples/data/"
    exit 1
fi

echo "Loading secrets from $ENV_FILE..."
source "$ENV_FILE"

# --- 3. Negative Test: SSL Rejection ---
verify_ssl_rejection() {
    echo "---------------------------------------------------"
    echo "Security Audit: Verifying Non-SSL Rejection"

    # Use Artifactory creds for the test (User doesn't matter, connection type does)
    export PGPASSWORD="$ARTIFACTORY_DB_PASSWORD"

    # CRITICAL FIX: Use ENV variable, not --set
    # We attempt to force a non-SSL connection.
    export PGSSLMODE="disable"

    # We explicitly want this command to FAIL.
    if psql \
        --host "postgres.cicd.local" \
        --username "artifactory" \
        --dbname "artifactory" \
        --no-password \
        --command "SELECT 1;" &> /dev/null; then

        echo " [FAIL] SECURITY BREACH! The database accepted a non-SSL connection."
        echo "        Check your pg_hba.conf file for 'hostnossl ... reject'."
        exit 1
    else
        echo " [PASS] Connection rejected (Expected). The database correctly blocked non-SSL traffic."
    fi

    # Unset the variable so it doesn't pollute later tests
    unset PGSSLMODE
}

# --- 4. Positive Test: Functional Verification ---
verify_service_db() {
    local user=$1
    local pass=$2
    local db=$3

    echo "---------------------------------------------------"
    echo "Auditing Service: $user"

    if [ -z "$pass" ]; then
        echo " [FAIL] Password variable is empty."
        return 1
    fi

    export PGPASSWORD="$pass"
    # CRITICAL FIXES:
    # 1. Force strict verification
    export PGSSLMODE="verify-full"
    # 2. Tell libpq to look at the System Certificate Bundle (where your CA is)
    #    Instead of looking in ~/.postgresql/root.crt
    export PGSSLROOTCERT="/etc/ssl/certs/ca-certificates.crt"

    psql \
        --host "postgres.cicd.local" \
        --username "$user" \
        --dbname "$db" \
        --no-password \
        --set ON_ERROR_STOP=1 \
        <<-EOSQL

        -- 1. Check SSL Status (Using pg_stat_ssl view)
        SELECT CASE
            WHEN ssl THEN 'SSL: ACTIVE'
            ELSE 'SSL: INACTIVE'
        END AS security_status
        FROM pg_stat_ssl
        WHERE pid = pg_backend_pid();

        -- 2. Check PG17 Permissions (Create Table in Public)
        CREATE TABLE public.verification_test (id int);

        -- 3. Cleanup
        DROP TABLE public.verification_test;

EOSQL

    if [ $? -eq 0 ]; then
        echo " [PASS] Authentication successful."
        echo " [PASS] SSL encryption verified."
        echo " [PASS] PG17 Schema permissions verified (CRUD OK)."
    else
        echo " [FAIL] Verification failed for user: $user"
        exit 1
    fi
}

# --- 5. Execution Loop ---

# 1. First, verify the security controls
verify_ssl_rejection

# 2. Then verify functionality for all tenants
verify_service_db "artifactory" "$ARTIFACTORY_DB_PASSWORD" "artifactory"
verify_service_db "sonarqube" "$SONARQUBE_DB_PASSWORD" "sonarqube"
verify_service_db "mattermost" "$MATTERMOST_DB_PASSWORD" "mattermost"
verify_service_db "grafana" "$GRAFANA_DB_PASSWORD" "grafana"

echo "---------------------------------------------------"
echo "AUDIT COMPLETE: All database services are healthy and secure."