# Chapter 1: The Challenge - The "Incinerator" Problem

## 1.1 The Current State: A Factory Without a Warehouse

In the previous articles, we successfully established the two most visible pillars of our CI/CD city. We built the "Central Library" (GitLab) to store our blueprints, and we constructed the "Factory" (Jenkins) to execute our work.

Our architecture is sound. We have a secure, "Control Center" (our `dev-container`) that orchestrates everything. We have a private road network (`cicd-net`) that allows our services to communicate securely over HTTPS using our own internal Certificate Authority. Most importantly, we have a working pipeline. When a developer pushes code to GitLab, a webhook fires, the Jenkins "Foreman" hires a "General Purpose Worker" (our custom Docker agent), and that worker successfully compiles our complex, polyglot "Hero Project."

If you look at the Jenkins dashboard from our last session, you will see a green status. The tests passed. The C++ library (`libhttpc.so`), the Rust binary (`httprust`), and the Python wheel (`.whl`) were all successfully created.

However, despite this success, our system has a critical architectural flaw. We have built a factory that incinerates its products immediately after manufacturing them.

Because our Jenkins agents are ephemeral containers designed to provide a clean slate for every build, they are destroyed the moment the pipeline finishes. When the container is removed, every artifact inside it—the very software we aim to deliver—is deleted along with it. We are verifying the *process*, but we are failing to capture the *product*. We have a factory, but we have no warehouse.

## 1.2 The "Incinerator" Pain Point (Compute vs. Storage)

To understand why this happens, we must distinguish between the **Compute Plane** and the **Storage Plane** of our infrastructure.

Jenkins is a Compute engine. Its agents are designed to be ephemeral "cattle," not persistent "pets." This is a deliberate architectural choice. We want every build to start with a blank slate—a fresh filesystem, no leftover temporary files, and no side effects from previous runs—to guarantee reproducibility. If a build works on Monday, it must work on Tuesday, regardless of what happened in between.

To achieve this, the Docker Plugin destroys the agent container the instant the job completes. This is excellent for hygiene but catastrophic for delivery. By destroying the container, we are effectively incinerating the finished goods.

We are currently stuck in a loop of "verification without retention." We spend compute cycles to compile C++ code, link Rust binaries, and package Python wheels, only to verify that they *can* be built before throwing them away. We cannot deploy these binaries to a staging environment because they no longer exist. We cannot debug a production crash by inspecting the exact version that failed because that file is gone.

We need a dedicated **Storage Plane**. We need a system designed to persist, organize, and secure these binary assets long after the compute resources that created them have vanished.

## 1.3 The "Storage Plane": Why not just commit to Git?

The most common reaction to this problem is to ask: "Why do we need another server? We already have GitLab. Why not just commit the compiled binaries to the repository?"

This is a seductive anti-pattern. It seems efficient to keep the source and the build output together, but it fundamentally misunderstands the mechanics of version control. We must distinguish between the "Filing Cabinet" (Git) and the "Warehouse" (Artifactory).

Git is a "Time Machine" optimized for text. When you change a line of code, Git calculates the difference (the delta) and stores only that tiny change. It is incredibly efficient at tracking the evolution of text files over time.

Binaries, however, are opaque blobs. If you recompile a 50MB executable, almost every bit in that file changes. Git cannot calculate a meaningful delta, so it must store a fresh, full copy of that 50MB file every single time you commit. If you build ten times a day, your repository grows by 500MB a day. Within a month, your agile "Filing Cabinet" is stuffed with heavy machinery. `git clone` operations that used to take seconds will start taking hours, choking the network and slowing down every developer on the team.

We need a system designed for heavy lifting. We need a "Warehouse" optimized for storing large, immutable, checksum-based artifacts, not line-by-line text diffs.

## 1.4 The Architectural Decision: Why Not Use GitLab's Registry?

Before we break ground on a new building, we must address the elephant in the room. Our GitLab container actually comes with a built-in "Package Registry." Why are we incurring the architectural cost of deploying **JFrog Artifactory**, a completely separate, resource-intensive application?

We are choosing a dedicated component for four specific architectural reasons that align with our "City Planning" philosophy.

**1. The "Universal Bucket" (Simplicity & Licensing)**
Our "Hero Project" is polyglot. It produces C/C++ libraries, Rust binaries, and Python wheels. To store these in GitLab's registry, we would need to configure three separate, complex interactions: a PyPI upload for Python, a Cargo registry configuration for Rust, and a Generic upload for C++.

However, there is a pragmatic constraint. We are using the free **Artifactory OSS** version. This version is strictly limited in the package types it supports (primarily Maven, Gradle, and Ivy). It **does not** natively support PyPI, Cargo, or Conan repositories.

Therefore, using Artifactory's **Generic Repository** is not just a simplification; it is a necessity. It allows us to treat all our polyglot artifacts—tarballs, crates, and wheels—as simple files in a folder structure. It is a "Simple Bucket" that lets us focus on the pipeline flow first without needing the paid Enterprise features for specific language protocols.

**2. Decoupling (Resilience)**
We are building a modular city. Ideally, the buildings should be independent. If we decide to demolish our Library (switch from GitLab to GitHub) in the future, our Warehouse should remain standing. By bundling our artifacts inside our SCM, we create vendor lock-in. Separating them ensures that our asset storage is independent of our source control choice.

**3. The "Bunker" Foundation (Virtual Repositories)**
We are simulating a high-security "Air Gapped" environment. While we aren't configuring remote proxies today, deploying Artifactory lays the foundation for its superpower: **Virtual Repositories**. This allows a single URL to transparently aggregate local internal artifacts *and* proxied remote content (like Maven Central). This is the industry standard for secure supply chains, and we are pouring the foundation for it now.

**4. The "Chain of Custody" (Build Info)**
GitLab Releases are designed for humans; they provide download links. Artifactory **Build Info** is designed for machines; it provides forensic audit trails.

We need to capture more than just the file. We need to capture the **context**. The Build Info object links the specific SHA256 checksum of a binary back to the Git Commit hash, the Jenkins Build ID, the environment variables, and the dependencies used to create it. This creates a "Chain of Custody" that turns a random file into a trusted supply chain asset.

# Chapter 2: The Architecture - Designing the Warehouse

## 2.1 The Database Pivot: "City Infrastructure" vs. "Private Utilities"

Before we can deploy the Artifactory container, we must make a fundamental architectural decision regarding its data storage. Unlike Jenkins, which stores its configuration and job history as flat XML files on the filesystem, Artifactory relies heavily on a transactional database to manage metadata, security tokens, and package indexing.

By default, Artifactory ships with an embedded Apache Derby database. This is designed for "zero-config" trials: you run the container, the database spins up inside the same JVM process, and the application starts. While convenient for a five-minute test, this "Private Utility" model is architecturally unsound for a persistent, professional environment.

The embedded database introduces significant risks. It runs within the application container, meaning if the container crashes or is killed abruptly (a common occurrence in Docker development), the database often fails to close its lock files or flush its transaction logs, leading to corruption. Furthermore, in the specific context of Artifactory 7.x running in Docker, the embedded database has known stability issues that can cause boot loops or data loss during upgrades.

We will reject this default. Instead of allowing every new building in our city to drill its own private well, we will build a centralized water treatment plant. We will deploy **PostgreSQL 17** as a first-class piece of "City Infrastructure."

This decision pays dividends beyond just Artifactory. By establishing a robust, SSL-secured, shared database service now, we are laying the foundation for the rest of our stack. When we deploy **SonarQube** (for code quality), **Mattermost** (for ChatOps), and **Grafana** (for monitoring) in future articles, they will not need their own private databases. They will simply plug into this existing, high-performance infrastructure. This reduces our resource footprint and centralizes our backup and security strategy to a single, manageable point.

## 2.2 The Security Shift: Navigating PostgreSQL 15+

Choosing to deploy a modern database comes with modern responsibilities. We are deploying **PostgreSQL 17**, the latest stable version supported by Artifactory and SonarQube. This forces us to confront a significant "breaking change" introduced in version 15 that alters the default security posture of the database.

For decades, PostgreSQL had a permissive default: any user connected to a database had implicit permission to create tables in the default `public` schema. This was convenient for developers but presented a security risk—a compromised low-privilege account could fill the database with garbage data or malicious tables.

In PostgreSQL 15, this default was revoked. The `public` schema is now owned strictly by the database owner, and the `PUBLIC` role (representing all users) no longer has `CREATE` privileges.

This shift breaks the "lazy" setup scripts found in many older tutorials. If we simply create an `artifactory` user and a database, the application will crash on startup with "Permission Denied" errors when it attempts to initialize its schema.

To navigate this, we must adopt a **"Zero Trust"** mindset in our initialization architecture. We cannot rely on implicit permissions. Our setup scripts must now be explicit, executing specific `GRANT CREATE, USAGE ON SCHEMA public` commands for each service user. This ensures that our database environment remains secure by default, with every privilege intentionally defined rather than accidentally inherited.

## 2.3 The "Microservice Explosion" (Artifactory 7 vs. 6)

If you have used older versions of Artifactory (v6 and below), you might remember it as a standard Java web application running inside Apache Tomcat. You deployed a `.war` file, mapped port 8081, and you were done.

Artifactory 7 abandoned this monolithic architecture in favor of a scalable, cloud-native design. It is no longer a single application; it is a **cluster of microservices** running inside a single container.

When we launch our container, we aren't just starting a web app; we are spinning up an entire internal service mesh:

1.  **Artifactory (Service):** The core artifact management engine (Java).
2.  **Access:** A dedicated security service that handles authentication, tokens, and permissions (Java).
3.  **Metadata:** A service for indexing and calculating metadata for packages (Java).
4.  **Frontend:** The web UI service.
5.  **Router:** The API Gateway and service registry (written in Go, based on Traefik).

This architectural shift creates new complexity for our "City Planning." We can no longer simply talk to the Tomcat backend on port 8081. Instead, all traffic must flow through the **Router** on **port 8082**.

The Router is the traffic cop. It acts as the entry point for the "City," terminating SSL and directing requests to the correct internal microservice. This creates a complex internal environment where these services must communicate with each other securely over `localhost`. If this internal network is misconfigured, the Router will fail to connect to the Access service, and the entire container will enter a boot loop.

## 2.4 The TLS Trap: "Strict Compliance" (Go vs. OpenSSL)

The introduction of the Go-based Router brings a subtle but critical compatibility challenge regarding our Public Key Infrastructure (PKI). In Article 2, we built a standard "Passport Printer" script using OpenSSL. We used this to generate certificates for GitLab (Nginx) and Jenkins (Jetty), and both accepted them without complaint.

However, the Artifactory Router is different. It is built on the Go programming language's standard library (`crypto/x509`), which is notorious in the DevOps community for its strict, unforgiving adherence to RFC 5280 standards. While C-based libraries like OpenSSL are often permissive—ignoring minor spec violations—Go will reject a certificate that is technically imperfect.

This creates a "TLS Trap." If we try to reuse our standard certificate generation script for Artifactory, the Router will fail to start, often with cryptic "handshake failure" or "unhandled critical extension" errors.

The issue lies in the **Key Usage** extensions.
1.  **Criticality:** The RFC suggests that if a certificate defines specific Key Usages (like Digital Signature), that extension should be marked **CRITICAL**. Go enforces this; many others do not.
2.  **Dual Role (mTLS):** Because the Router acts as a **Server** (accepting traffic from your browser) *and* a **Client** (sending traffic to internal microservices like Access), it requires a certificate that explicitly permits *both* roles. It needs `ExtendedKeyUsage` values for `serverAuth` and `clientAuth`.

To solve this, we cannot use our existing tools. We must engineer a bespoke "Strict Compliance" certificate generation process specifically for Artifactory, ensuring every flag is set exactly as the Go library expects.

## 2.5 The "Hybrid Persistence" Pattern

Finally, we must address how we store the data. Artifactory creates massive amounts of binary data. Storing this in a standard Docker volume is best practice for performance and safety (preventing accidental deletion). However, Artifactory also relies on complex configuration files (like `system.yaml`) that we need to edit frequently from our host machine.

If we mount a Docker volume to the data directory, the configuration files are buried inside the volume, inaccessible to our host's text editors. If we bind-mount a host directory, we expose the database files to potential permission corruption by the host OS.

To resolve this, we will use a **Hybrid Persistence** pattern using layered mounts.

1.  **The Foundation (Volume):** We will mount a Docker-managed volume (`artifactory-data`) to the root application directory `/var/opt/jfrog/artifactory`. This handles the heavy, opaque data storage safely.
2.  **The Overlays (Bind Mounts):** We will then bind-mount specific subdirectories from our host (`~/cicd_stack/artifactory/var/etc`) *over* the corresponding directories inside the container.

This strategy gives us the best of both worlds: the robustness of a managed volume for the "blob" storage, and the convenience of host-side editing for our configuration files.




# Chapter 3: Action Plan (Part 1) - The Shared Data Layer

## 3.1 The Architect (`01-setup-database.sh`)

We begin by establishing our shared data infrastructure. This script acts as the "Architect" for our database service. It runs entirely on the host machine and is responsible for preparing the filesystem, generating cryptographic secrets, and defining the security policies that the database container will enforce upon startup.

This script creates a directory structure at `~/cicd_stack/postgres`, populating it with SSL certificates, configuration files, and initialization scripts. It solves the "Bootstrap Paradox" by ensuring that all passwords and permissions exist *before* the database process is ever spawned.

Create this file at `~/cicd_stack/postgres/01-setup-database.sh`.

```bash
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
```

### Deconstructing the Architect

This script performs five critical functions that transform a generic PostgreSQL image into a production-grade service.

**1. The "Pre-Computation" Strategy (Phase 1)**
The `check_and_generate_secret` function generates high-entropy passwords using `openssl rand` and saves them to our master `cicd.env` file *before* the container ever starts. This prevents the "First Run" race condition where an application might try to connect before a password is fully established. Note that we generate passwords for Artifactory, SonarQube, Mattermost, and Grafana all at once. We are provisioning the city's infrastructure in one go.

**2. The "Leaky Container" Fix (UID 999) (Phase 2)**
This is one of the most common "gotchas" in Docker database deployments. The official PostgreSQL container runs as user `postgres` with a fixed **UID 999**. When we bind-mount our host's certificate directory (`certs/`) into the container, the permissions bleed through. If the private key is owned by our host user (e.g., UID 1000), the database process inside the container (UID 999) cannot read it and will crash immediately.
We solve this with "Host-Side Surgery": `sudo chown -R 999:999`. We explicitly set the ownership on the host so it matches the guest's expectation.

**3. The "Bouncer" (Phase 3)**
We generate a strict `pg_hba.conf` file. This acts as the firewall for the database application layer.

* **`hostnossl ... reject`**: This is the "No Shirt, No Service" policy. We explicitly reject any connection attempt from the network that does not use SSL.
* **`scram-sha-256`**: We enforce the modern SCRAM authentication method, replacing the vulnerable `md5` default. This adds cryptographic salt and channel binding, preventing "Pass-the-Hash" attacks.

**4. The "Concrete Foundation" and "Zero Trust" (Phase 4)**
The `init.sh` script is where we handle the deep architectural requirements.

* **`DB_COLLATE='C'`**: We hardcode the collation to `C`. This forces the database to use raw byte-value sorting rather than complex, culturally-aware sorting logic. This is a hard requirement for **SonarQube** (our next article), which requires strict case sensitivity. Changing collation later is impossible without wiping the database, so we must pour this concrete correctly now.
* **`GRANT CREATE, USAGE ON SCHEMA public`**: This handles the PostgreSQL 15 security shift. By default, new users can no longer create tables in the public schema. We explicitly `GRANT` these permissions to our service users, adhering to a "Zero Trust" model where access is explicitly defined, not implicitly assumed.



## 3.2 The Launcher (`02-deploy-database.sh`)

With our configuration assets generated and permissions fixed, we can now launch the database container. This script acts as the "Construction Crew," taking the blueprints provided by the Architect and assembling the running service.

It performs a "Clean Slate" protocol—stopping and removing any existing instance—to ensure that configuration changes (like our new `pg_hba.conf`) are always applied fresh.

Create this file at `~/cicd_stack/postgres/02-deploy-database.sh`.

```bash
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
```

### Deconstructing the Launcher

This script connects the dots between our physical assets and the running container.

**1. The Identity Assertion (`--hostname`)**
We explicitly set `--hostname postgres.cicd.local`. This is not cosmetic. This hostname matches the Common Name (CN) of the SSL certificate we generated in the Architect script. This match is what allows clients to use `sslmode=verify-full`. If the container's hostname did not match the certificate, clients would reject the connection as a potential Man-in-the-Middle attack.

**2. The Mount Strategy**
We map four distinct volumes, each serving a specific architectural purpose:

* `postgres-data`: The **Docker Volume** for the actual database files (opaque, high-performance IO).
* `certs`: The **Bind Mount** containing our keys (permission-fixed to UID 999).
* `config`: The **Bind Mount** injecting our strict `pg_hba.conf` "Bouncer."
* `init`: The **Bind Mount** injecting our SQL script. PostgreSQL automatically executes any `.sh` or `.sql` file found in `/docker-entrypoint-initdb.d` during the very first startup.

**3. The Runtime Flags (`-c`)**
We override the default PostgreSQL configuration directly in the command line.

* `-c ssl=on`: Forces the server to enable the SSL subsystem.
* `-c hba_file=...`: Tells PostgreSQL to ignore its default access rules and use our strict `pg_hba.conf` instead.

## 3.3 The Audit (`03-verify-database.sh`)

Deploying the database is not enough. We must verify that our security controls are actually working *before* we try to connect complex applications like Artifactory. If we skip this step, we might spend hours debugging Artifactory connection errors, not knowing if the issue is the network, the password, or the SSL handshake.

We will perform a formal audit using a "Negative Testing" methodology. We want to prove that the database **rejects** insecure connections.

Create this file in your **article source directory** (on your host) at `~/Documents/FromFirstPrinciples/articles/0009_cicd_part05_artifactory/03-verify-database.sh`. This ensures it is mounted into our `dev-container`, where we will run the test.

```bash
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
```

### Deconstructing the Audit

**1. The "Negative Testing" Philosophy**
Most tutorials only show you how to connect successfully. We prioritize verifying that we *cannot* connect insecurely.

* **`PGSSLMODE="disable"`**: We deliberately attempt to break our own rules by forcing a clear-text connection.
* **The Payoff:** The script considers it a **`[PASS]`** only if the connection fails. This proves that our `pg_hba.conf` "Bouncer" is physically rejecting unencrypted traffic.

**2. The "Identity" Check (`verify-full`)**
In the positive tests, we set `PGSSLMODE="verify-full"`.

* **`verify-ca`** only checks the signature (Is this a valid passport?).
* **`verify-full`** checks the hostname (Is this *your* passport?).
  By enforcing this, we validate that the certificate we generated (`postgres.cicd.local`) correctly matches the hostname resolved by our internal DNS. This prevents Man-in-the-Middle attacks within our own network.

### Executing the Audit

This script requires a small "data bridging" step because the `dev-container` cannot see the `cicd_stack` deployment directory on the host (for security reasons).

1.  **On your Host:** Stage the secrets file where the dev container can see it.
    ```bash
    cp ~/cicd_stack/postgres/postgres.env ~/Documents/FromFirstPrinciples/data/
    ```
2.  **Enter the Dev Container:**
    ```bash
    ./dev-container.sh
    ```
    OR, if already started
    ```bash
    ssh -i ~/.ssh/id_rsa -p 10200 <your_username>@127.0.0.1
    ```
    OR
    ```bash
    docker exec -it dev-container bash
    ```

3.  **Run the Audit:**
    ```bash
    # Inside dev-container
    cd articles/0009_cicd_part05_artifactory
    chmod +x 03-verify-database.sh
    ./03-verify-database.sh
    ```

**The Result:**
You will see `[PASS] Connection rejected` when the script attempts an insecure connection. You will then see `[PASS] SSL encryption verified` for every service user, confirming that your `init.sh` script successfully provisioned the multi-tenant architecture with the correct PostgreSQL 17 permissions.

# Chapter 4: Action Plan (Part 2) - The Secure Warehouse

## 4.1 The Architecture: A Cluster in a Container

With our shared database layer operational, we turn our attention to the application itself. Deploying Artifactory 7.x is fundamentally different from deploying a standard web application like Jenkins. While Jenkins is a single process, Artifactory is a distributed system packaged into a single container. It consists of several distinct microservices—**Artifactory** (the core), **Access** (security), **Metadata**, **Router**, and **Frontend**—that must coordinate with one another to function.

This microservice architecture necessitates a sophisticated internal trust model. We are not just managing a username and password; we are managing the cryptographic trust root for a cluster.

To secure this "Cluster in a Container," we must explicitly manage two critical cryptographic assets:

1.  **The Master Key:** This is an AES-256 key used for **Data at Rest** encryption. Artifactory uses this to encrypt sensitive data within the configuration files (like the database password we just generated) and inside the database itself. If you lose this key, the data is cryptographically locked forever.
2.  **The Join Key:** This is a shared secret used for **Data in Motion** trust. When the internal microservices (like Metadata or Access) start up, they use this key to "handshake" with one another and establish a circle of trust. Once trusted, they exchange short-lived tokens for API access.

In a default installation, Artifactory generates these keys automatically on the first run. However, relying on auto-generation creates a "Black Box" deployment where we do not possess the recovery keys for our own infrastructure. It also introduces potential race conditions during the initial boot where services might time out waiting for key generation.

We will define these keys manually on the host *before* the container starts. By generating high-entropy keys ourselves, we ensure we own the "Root of Trust" for our warehouse from the very first second.

## 4.2 The Architect (`04-setup-artifactory.sh`)

To orchestrate this complex internal environment, we need a robust Architect script. This script is responsible for generating the Master and Join keys, creating the specific directory structure required for the bootstrap process, and—most critically—generating the "Strict Compliance" TLS certificates required by the Artifactory Router.

Create this file at `~/cicd_stack/artifactory/04-setup-artifactory.sh`.

```bash
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
```

### Deconstructing the Architect

**1. The "Strict Compliance" Certificate**
This section is the solution to the "Go vs. OpenSSL" conflict we identified in the architectural phase.

* **The Config:** We create a temporary `router.cnf` file.
* **`keyUsage = critical`**: This line is non-negotiable. It satisfies the strict RFC 5280 requirement of the Go crypto library.
* **`extendedKeyUsage = serverAuth, clientAuth`**: This handles the dual role of the Router. It serves the browser (`serverAuth`) and connects to internal services (`clientAuth`). Without this dual designation, the internal mTLS handshake would fail, and the Router would crash.

**2. Fixing "Split Brain" Networking (`extraJavaOpts`)**
In the `system.yaml` generation block, we inject `extraJavaOpts: "-Djava.net.preferIPv4Stack=true"`.
This prevents a common Docker networking issue. The JVM (Tomcat) often attempts to bind to IPv6 (`::1`) by default, while the Go Router attempts to connect via IPv4 (`127.0.0.1`). This mismatch causes "Connection Refused" errors on `localhost`. By forcing the JVM to use the IPv4 stack, we align the internal protocols.

**3. The "Bootstrap" Pattern (`config.import.yml`)**
We use a powerful Artifactory feature called "Configuration Import."
Instead of clicking through the "Welcome Wizard" manually, we write our desired state to `artifactory.config.import.yml` and `access.config.import.yml`. Artifactory detects these files on boot, ingests the configuration (setting the Base URL to `https://artifactory.cicd.local:8443`), enables TLS for the Access service, and then deletes the files. This turns the interactive setup process into immutable Infrastructure-as-Code.

**4. Permission Management (`chown 1030`)**
Just as we handled UID 999 for Postgres, we handle **UID 1030** for Artifactory. The container runs as a non-root user. We must ensure that the configuration directories we just created on the host are readable and writable by this specific internal user ID, or the container will crash with a `Permission Denied` error.

## 4.3 The Launcher (`05-deploy-artifactory.sh`)

With our filesystem prepared and our certificates minted, we are ready to launch the container. This script is the "Construction Crew." It takes the assets prepared by the Architect and brings the application to life.

This script also addresses two specific runtime environment challenges: **Version Stability** and the **Proxy Trap**.

Create this file at `~/cicd_stack/artifactory/05-deploy-artifactory.sh`.

```bash
#!/usr/bin/env bash

#
# -----------------------------------------------------------
#               05-deploy-artifactory.sh
#
#  This is the "Construction Crew" script.
#  It launches the Artifactory container.
#
#  UPDATED:
#  1. Version 7.90.15.
#  2. Ports 8443 (HTTPS) / 8082 (Router).
#  3. Bootstrap Mount Enabled.
#
# -----------------------------------------------------------

set -e

# --- 1. Define Paths ---
HOST_CICD_ROOT="$HOME/cicd_stack"
ARTIFACTORY_BASE="$HOST_CICD_ROOT/artifactory"
VAR_ETC="$ARTIFACTORY_BASE/var/etc"
VAR_BOOTSTRAP="$ARTIFACTORY_BASE/var/bootstrap"

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
echo "Launching Artifactory OSS container (v7.90.15)..."

docker run -d \
  --name artifactory \
  --restart always \
  --network cicd-net \
  --hostname artifactory.cicd.local \
  --publish 127.0.0.1:8443:8443 \
  --publish 127.0.0.1:8082:8082 \
  --env no_proxy="localhost,127.0.0.1,postgres.cicd.local,artifactory.cicd.local" \
  --env NO_PROXY="localhost,127.0.0.1,postgres.cicd.local,artifactory.cicd.local" \
  --volume artifactory-data:/var/opt/jfrog/artifactory \
  --volume "$VAR_ETC":/var/opt/jfrog/artifactory/etc \
  --volume "$VAR_BOOTSTRAP":/var/opt/jfrog/artifactory/bootstrap \
  releases-docker.jfrog.io/jfrog/artifactory-oss:7.90.15

echo "Artifactory container started."
echo "   This is a heavy Java application."
echo "   It will take 1-2 minutes to initialize."
echo "   Monitor logs with: docker logs -f artifactory"
echo ""
echo "   Wait for: 'Router (jfrou) ... Listening on port: 8082'"
echo "   Then access: https://artifactory.cicd.local:8443"
```

### Deconstructing the Launcher

**1. Version Pinning (`7.90.15`)**
We are explicitly pinning the image to version `7.90.15`. In the world of Enterprise Java applications, "latest" is a dangerous tag. We discovered during development that newer versions (v7.90.20+) introduced a race condition where the Frontend (`jffe`) service would crash before the Router was fully initialized, sending the container into a boot loop. By pinning to a known-good version, we ensure stability.

**2. The "Proxy Trap" (`no_proxy`)**
This is a critical fix for corporate or complex network environments.
If your host machine defines `HTTP_PROXY` variables (common in office environments), Docker containers inherit them by default. This creates a routing disaster: when the internal Router tries to talk to the internal Metadata service on `localhost:8081`, the Go HTTP client sees the proxy variable and attempts to route that request *out* to the corporate proxy server. The proxy server, having no idea what "localhost" inside your container refers to, rejects the connection.
By injecting `no_proxy="localhost,127.0.0.1,..."`, we explicitly tell the internal services to bypass the proxy and communicate directly for local addresses.

**3. The Hybrid Mounts**
We mount our three persistence layers:

* `artifactory-data`: The Docker volume for the massive binary blobs.
* `etc`: The host directory containing our keys and `system.yaml`.
* `bootstrap`: The host directory containing our certificates and config import files.
  This structure allows us to "seed" the configuration from the host while keeping the heavy data storage managed by Docker.

## 4.4 Verification (`06-verify-artifactory.py`)

With the container running, we need to verify that the internal "City" is actually functioning. Because Artifactory is a mesh of microservices, a simple "container running" status is insufficient. The container might be up, but the Router could be failing to talk to the Metadata service, or the Database connection might be hanging.

We will use a Python script to perform a "pulse check" on the system. This script hits specific health endpoints that aggregate the status of the internal components. It also attempts to verify our administrative access, though we expect that part to skip until we perform our manual UI setup in the next chapter.

Create this file at `~/Documents/FromFirstPrinciples/articles/0009_cicd_part05_artifactory/06-verify-artifactory.py`.

```python
#!/usr/bin/env python3

import os
import ssl
import urllib.request
import urllib.error
import json
import sys
from pathlib import Path

# --- Configuration ---
ENV_FILE_PATH = Path.home() / "cicd_stack" / "cicd.env"
BASE_URL = "https://artifactory.cicd.local:8082"

# Endpoints
HEALTH_ENDPOINT = f"{BASE_URL}/router/api/v1/system/health"
PING_ENDPOINT = f"{BASE_URL}/artifactory/api/system/ping"
# We use the endpoint you confirmed works with your token
TOKEN_LIST_ENDPOINT = f"{BASE_URL}/access/api/v1/tokens"

def load_env(env_path):
    if not env_path.exists():
        print(f"[FAIL] Configuration error: {env_path} not found.")
        return False

    with open(env_path, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                os.environ[key.strip()] = value.strip().strip('"\'')
    return True

def get_ssl_context():
    # Trusts the system CA store (where our Root CA lives)
    return ssl.create_default_context()

def print_response_error(response):
    """Helper to print the full error body for debugging"""
    try:
        body = response.read().decode()
        print(f"       [SERVER RESPONSE]: {body}")
    except Exception:
        print("       [SERVER RESPONSE]: (Could not decode body)")

def check_health():
    print(f"\n--- Test 1: Router Health (Unauthenticated) ---")
    print(f"GET {HEALTH_ENDPOINT}")

    ctx = get_ssl_context()
    try:
        req = urllib.request.Request(HEALTH_ENDPOINT)
        with urllib.request.urlopen(req, context=ctx) as response:
            if response.status == 200:
                data = json.loads(response.read().decode())
                state = data.get('router', {}).get('state', 'UNKNOWN')
                print(f"[PASS] Status: 200 OK")
                print(f"       Router State: {state}")
            else:
                print(f"[FAIL] Status: {response.status}")
                print_response_error(response)
    except urllib.error.HTTPError as e:
        print(f"[FAIL] HTTP {e.code}: {e.reason}")
        print_response_error(e)
    except Exception as e:
        print(f"[FAIL] {e}")

def check_ping():
    print(f"\n--- Test 2: System Ping (Unauthenticated) ---")
    print(f"GET {PING_ENDPOINT}")

    ctx = get_ssl_context()
    try:
        req = urllib.request.Request(PING_ENDPOINT)
        with urllib.request.urlopen(req, context=ctx) as response:
            body = response.read().decode().strip()
            if response.status == 200 and body == "OK":
                print(f"[PASS] Status: 200 OK")
                print(f"       Response: {body}")
            else:
                print(f"[FAIL] Unexpected response: {body}")
    except urllib.error.HTTPError as e:
        print(f"[FAIL] HTTP {e.code}: {e.reason}")
        print_response_error(e)
    except Exception as e:
        print(f"[FAIL] {e}")

def check_admin_token():
    print(f"\n--- Test 3: Admin Token Verification ---")
    print(f"GET {TOKEN_LIST_ENDPOINT}")

    token = os.getenv("ARTIFACTORY_ADMIN_TOKEN")
    if not token:
        print("[SKIP] ARTIFACTORY_ADMIN_TOKEN not found in cicd.env")
        return

    # We use the Bearer header as confirmed by the search AI
    headers = {"Authorization": f"Bearer {token}"}
    ctx = get_ssl_context()

    try:
        req = urllib.request.Request(TOKEN_LIST_ENDPOINT, headers=headers)
        with urllib.request.urlopen(req, context=ctx) as response:
            if response.status == 200:
                data = json.loads(response.read().decode())
                tokens = data.get('tokens', [])
                print(f"[PASS] Status: 200 OK")
                print(f"       Admin Access Confirmed.")
                print(f"       Visible Tokens: {len(tokens)}")
                if len(tokens) > 0:
                    print(f"       First Token ID: {tokens[0].get('token_id')}")
            else:
                print(f"[FAIL] Status: {response.status}")
                print_response_error(response)
    except urllib.error.HTTPError as e:
        print(f"[FAIL] HTTP {e.code}: {e.reason}")
        print_response_error(e)
        if e.code == 403:
            print("       (Token is valid but lacks permission to list tokens)")
        if e.code == 401:
            print("       (Token is invalid or expired)")
    except Exception as e:
        print(f"[FAIL] {e}")

if __name__ == "__main__":
    if load_env(ENV_FILE_PATH):
        check_health()
        check_ping()
        check_admin_token()
        print("\n--- Verification Complete ---")
```

### Running the Verification

Unlike the database audit, we can run this script directly from the **Host**, provided you have Python 3 installed. We want to prove that our host machine—which will act as the developer workstation—can trust the Artifactory SSL certificate.

```bash
# On the Host Machine
cd ~/Documents/FromFirstPrinciples/articles/0009_cicd_part05_artifactory
chmod +x 06-verify-artifactory.py
./06-verify-artifactory.py
```

You should see `[PASS]` for the Router Health and System Ping. The Admin Token verification will currently `[SKIP]`. This is expected; we have the infrastructure running, but we haven't yet logged in to generate the keys for the castle. We will handle that next.


# Chapter 5: UI Configuration - Opening the Warehouse

## 5.1 First Login & The "Wizard Bypass"

The infrastructure is live. We have a running database, a secure microservice mesh, and a listening web server. Now, we verify the user experience.

Open your browser on your host machine and navigate to:

**`https://artifactory.cicd.local:8443`**

Because we meticulously established our Public Key Infrastructure in Article 2 and imported the Root CA into our host's trust store, the page should load immediately with a secure lock icon. There are no "Your connection is not private" warnings to click through.

You will be greeted by the JFrog login screen. To log in, use the credentials we generated in our `01-setup-database.sh` script.

* **Username:** `admin`
* **Password:** Open your `~/cicd_stack/cicd.env` file and copy the value of `ARTIFACTORY_ADMIN_PASSWORD`.

### The "Wizard Bypass"

Upon logging in, you might expect to see a "Welcome Wizard" asking you to accept terms, set a Base URL, and create default repositories.

You will not see this. You will be taken directly to the main dashboard.

This is the payoff for the `artifactory.config.import.yml` file we injected during the setup phase. By defining our desired state (Base URL and Repository Types) in code and bootstrapping it into the container, we have effectively "skipped" the manual onboarding process. This is a critical pattern for "Infrastructure as Code"—we treat the application configuration just like the server configuration.

To verify this, navigate to **Administration** (on the top menu) -> **General Management** -> **Settings**. You will see that the **Custom Base URL** is already correctly set to `https://artifactory.cicd.local:8443`.

## 5.2 Creating the Admin Token (The Integration Key)

Now that we are logged in, we need to generate the credentials that Jenkins will use. We cannot simply give Jenkins our admin password. Modern CI/CD best practices dictate the use of **Access Tokens**, which provide better auditability and can be revoked without changing the root password.

Specifically, we need a **Global Admin Token**. As we discovered in our research, Artifactory 7.x distinguishes between "Project Admin" tokens (which are sandboxed to specific projects) and "Global" tokens. Since Jenkins acts as the orchestrator for our entire city—publishing global Build Info metadata and interacting with the system APIs—it requires an Admin-scoped token.

Here is the procedure to generate the correct token:

1.  Navigate to **Administration** (top menu) -\> **User Management** -\> **Access Tokens**.
2.  Click the **"Generate Token"** button.
3.  **Token Type:** Select **"Scoped Token"**.
4.  **Token Scope:** Select **"Admin"**. This ensures the token inherits the full administrative power required for global operations.
5.  **User Name:** Enter `admin`.
6.  **Service:** Click the **"All"** checkbox. (Note: In the OSS version, "Artifactory" is likely the only service listed, but checking "All" ensures forward compatibility).
7.  **Expiration Time:** Set to **"Never"** for the purpose of this lab. In a production environment, you would set a rotation policy here.
8.  Click **"Generate"**.

You will be presented with a `Reference Token` (a short string) and an `Access Token` (a very long JWT string). **Copy the long Access Token immediately.** You will not be able to see it again once you close this window.

### Updating the Secrets File

We must now save this token to our master secrets file so our automation scripts can use it.

On your host machine, open `~/cicd_stack/cicd.env` and add the following line:

```bash
ARTIFACTORY_ADMIN_TOKEN="<paste_your_long_token_here>"
```

This token is the "Key to the Warehouse." It will allow our `07-update-jenkins.sh` script to securely inject credentials into the Jenkins container in the next chapter.

## 5.3 Creating the Repository (`generic-local`)

With our admin token secured, we need to prepare the "Landing Zone" for our artifacts.

Recall that in our `artifactory.config.import.yml` bootstrap file, we defined several default repository types (`maven`, `gradle`, `docker`, `npm`). However, we intentionally omitted the **Generic** type. This highlights a key architectural distinction: while package-specific repositories (like Maven) come with complex indexing and metadata rules, a Generic repository is essentially a smart file system.

Because we didn't bootstrap it, we must create it manually. This will be the destination for our C++ SDKs, Rust Crates, and Python Wheels.

1.  Navigate to **Administration** -\> **Repositories**.
2.  Click the **"Create Repository"** button in the top right.
3.  Select **"Local"**. We want a repository that stores files on our own disk (in the PostgreSQL metadata / Docker Volume blob store), not a proxy to a remote URL.
4.  Select **"Generic"** as the package type.
5.  **Repository Key:** Enter `generic-local`.
6.  Click **"Create Local Repository"**.

We now have an empty storage bucket. Unlike the "Filing Cabinet" (Git), this "Warehouse" doesn't care about diffs or merge conflicts. It simply accepts binary blobs and stores them forever.

### A Note on Layouts

By default, a Generic repository treats paths literally. When we configure our pipeline later to upload to `http-client/16/`, Artifactory will simply create a folder named `http-client` and a subfolder named `16`.

It is important to understand that Artifactory does not automatically know that "16" is a version number. In a more advanced setup, we would apply a **Custom Repository Layout** (using Regex) to teach Artifactory how to parse our folder structure (e.g., `[org]/[module]/[baseRev]`). For our current needs, the physical folder structure is sufficient organization.

## 5.4 The "Set Me Up" Experience (Developer Productivity)

Before we leave the UI, we should verify that our repository is accessible to developers. One of the primary benefits of using an Artifact Manager over a simple file server is the **Developer Experience (DX)**.

In the **Application** module (top menu), navigate to **Artifactory** -\> **Artifacts**. Select your new `generic-local` repository in the tree view.

Click the **"Set Me Up"** button in the top right corner.

Artifactory will dynamically generate the exact commands a developer needs to interact with this repository. Because we correctly configured our Base URL (`https://artifactory.cicd.local:8443`) and our SSL certificates, the command provided will be production-ready:

```bash
curl -uadmin:<TOKEN> -T <PATH_TO_FILE> "https://artifactory.cicd.local:8443/artifactory/generic-local/<TARGET_FILE_PATH>"
```

This validates our entire networking stack. It confirms that:

1.  The system knows its own external DNS name (`artifactory.cicd.local`).
2.  It knows it is serving HTTPS on port 8443.
3.  It is ready to accept uploads.

This is the "Warehouse" equivalent of a loading dock with clear signage. We don't force developers to guess the URL structure; we provide it.

# Chapter 6: Action Plan (Part 3) - The Integrator

We have a fully functional Factory (Jenkins) and a fully functional Warehouse (Artifactory). Currently, however, they are completely unaware of each other. To complete our supply chain, we need to introduce them.

This integration requires two distinct operations:
1.  **Authentication:** Jenkins needs the "Keys to the Warehouse" (the Admin Token we just generated).
2.  **Configuration:** Jenkins needs to know the address of the Warehouse (`artifactory.cicd.local`) and be configured to use the Artifactory Plugin.

We will automate this process using a new script, `07-update-jenkins.sh`. However, before we write the code, we must navigate a specific Docker behavior that trips up many DevOps engineers during day-two operations.

## 6.1 The "Stale Env" Trap

Our first task is to get the `ARTIFACTORY_ADMIN_TOKEN` from our host's master secrets file (`cicd.env`) into the Jenkins container.

In Article 4, we established a "Scoped Environment" pattern. We created a specific file, `jenkins.env`, which is passed to the container using the `--env-file` flag. The logical assumption is that if we append a new variable to `jenkins.env` and restart the container, Jenkins will see it.

This assumption is false.

Docker containers are immutable snapshots. When you run `docker run`, the Docker daemon reads the `--env-file`, resolves the variables, and **bakes them into the container's configuration**. The link to the file on the host is severed immediately after creation.

If you run `docker stop jenkins-controller` and then `docker start jenkins-controller`, Docker simply reloads the *original* configuration snapshot. It does **not** re-read the file on the host. The container will come back up, but it will still have the "Stale Environment" from when it was first built, effectively ignoring our new token.

To solve this, we cannot use a simple restart. We must destroy the container (`docker rm`) and recreate it (`docker run`). This forces the daemon to read the modified `jenkins.env` file and generate a new configuration snapshot. Our integration script will handle this by triggering the `03-deploy-controller.sh` script we wrote in the previous article, ensuring a clean environment reload.

## 6.2 The "JCasC Schema" Nightmare

With the credentials ready to be injected, we face our second integration hurdle: configuring the Jenkins plugin itself.

In a standard "Configuration as Code" setup, you would typically find the plugin's YAML schema by looking at the documentation or exporting the current configuration. If you search online for "Jenkins Artifactory JCasC example," 99% of the results—including official JFrog examples from just a year ago—will tell you to use a block named `artifactoryServers`.

If you try to use that block with the modern plugin (version 4.x+), Jenkins will crash on startup.

This is due to a massive, undocumented architectural shift. The newer Jenkins Artifactory Plugin is no longer a standalone integration; it has been re-architected as a wrapper around the JFrog CLI. This change silently broke the JCasC schema. The configuration key `artifactoryServers` was removed and replaced with `jfrogInstances`.

To make matters worse, the internal structure changed as well. Simple fields like `credentialsId` were moved inside nested objects like `deployerCredentialsConfig` and `resolverCredentialsConfig`.

We discovered this only by reverse-engineering the error logs during our build process. The plugin threw an `UnknownAttributesException`, listing `jfrogInstances` as a valid attribute. This validates a core DevOps principle: **Never trust the documentation blindly; trust the error logs.** We must construct our configuration to match this new, strict schema, or the "Foreman" will never be able to talk to the "Warehouse."

## 6.3 Structured Data vs. Text Hacking (The Python Helper)

To inject this complex `jfrogInstances` configuration block into our existing `jenkins.yaml`, we have a choice of tools.

The "quick and dirty" approach would be to use `sed` or `cat` to append text to the end of the file. This is **Text Hacking**. It is fragile, dangerous, and unprofessional. YAML relies on strict indentation. A single misplaced space in a `sed` command can break the entire Jenkins configuration, causing the controller to fail on boot. Furthermore, `sed` has no concept of structure; it cannot check if the configuration already exists, leading to duplicate entries if the script runs twice.

The "First Principles" approach is **Structured Data Manipulation**. We treat the YAML file as a data object, not a text stream.

We will write a Python helper script, `update_jcasc.py`. This script uses the `PyYAML` library to:

1.  **Parse** the existing `jenkins.yaml` into a Python dictionary.
2.  **Check** if the Artifactory configuration already exists (Idempotency).
3.  **Inject** the new `jfrogInstances` block with the correct indentation and structure.
4.  **Dump** the valid YAML back to disk.

Create this file at `~/cicd_stack/jenkins/config/update_jcasc.py`.

```python
#!/usr/bin/env python3

import sys
import yaml
import os

# Path to the JCasC file
JCAS_FILE = os.path.expanduser("~/cicd_stack/jenkins/config/jenkins.yaml")

def update_jcasc():
    print(f"[INFO] Reading JCasC file: {JCAS_FILE}")

    try:
        with open(JCAS_FILE, 'r') as f:
            jcasc = yaml.safe_load(f)
    except FileNotFoundError:
        print(f"[ERROR] File not found: {JCAS_FILE}")
        sys.exit(1)

    # 1. Add Artifactory Credentials
    print("[INFO] Injecting Artifactory credentials block...")

    if 'credentials' not in jcasc:
        jcasc['credentials'] = {'system': {'domainCredentials': [{'credentials': []}]}}

    artifactory_cred = {
        'usernamePassword': {
            'id': 'artifactory-creds',
            'scope': 'GLOBAL',
            'description': 'Artifactory Admin Token',
            'username': '${JENKINS_ARTIFACTORY_USERNAME}',
            'password': '${JENKINS_ARTIFACTORY_PASSWORD}'
        }
    }

    # Navigate to credentials list safely
    if 'system' not in jcasc['credentials']:
        jcasc['credentials']['system'] = {'domainCredentials': [{'credentials': []}]}

    domain_creds = jcasc['credentials']['system']['domainCredentials']
    if not domain_creds:
        domain_creds.append({'credentials': []})

    creds_list = domain_creds[0]['credentials']
    if creds_list is None:
        creds_list = []
        domain_creds[0]['credentials'] = creds_list

    # Check existence (Idempotency)
    exists = False
    for cred in creds_list:
        if 'usernamePassword' in cred and cred['usernamePassword'].get('id') == 'artifactory-creds':
            exists = True
            break

    if not exists:
        creds_list.append(artifactory_cred)
        print("[INFO] Credential 'artifactory-creds' added.")
    else:
        print("[INFO] Credential 'artifactory-creds' already exists. Skipping.")

    # 2. Add Artifactory Server Configuration (Updated Schema)
    print("[INFO] Injecting Artifactory Server configuration (v4+ Schema)...")

    if 'unclassified' not in jcasc:
        jcasc['unclassified'] = {}

    # The v4+ Schema: 'jfrogInstances' instead of 'artifactoryServers'
    jcasc['unclassified']['artifactoryBuilder'] = {
        'useCredentialsPlugin': True,
        'jfrogInstances': [{
            'instanceId': 'artifactory',
            'url': '${JENKINS_ARTIFACTORY_URL}',
            'artifactoryUrl': '${JENKINS_ARTIFACTORY_URL}',
            'deployerCredentialsConfig': {
                'credentialsId': 'artifactory-creds'
            },
            'resolverCredentialsConfig': {
                'credentialsId': 'artifactory-creds'
            },
            'bypassProxy': True,
            'connectionRetry': 3,
            'timeout': 300
        }]
    }

    # 3. Write back to file
    print("[INFO] Writing updated JCasC file...")
    with open(JCAS_FILE, 'w') as f:
        yaml.dump(jcasc, f, default_flow_style=False, sort_keys=False)

    print("[INFO] JCasC update complete.")

if __name__ == "__main__":
    update_jcasc()
```

### Deconstructing the Helper

* **The Schema Logic:** Notice the structure under `artifactoryBuilder`. We define `jfrogInstances` (plural) as a list containing our single server. We use `${JENKINS_ARTIFACTORY_URL}` as a placeholder, which Jenkins will resolve at runtime from the environment variables we are about to inject.
* **`bypassProxy: True`:** This is a critical networking setting for our architecture. If your host machine uses a corporate proxy, Jenkins might try to route requests for `artifactory.cicd.local` through that external proxy, causing a connection failure. This flag forces Jenkins to treat Artifactory as an internal, direct-access service.
* **Idempotency:** The script checks `if not exists` before appending the credential. This allows us to run the integration script multiple times without corrupting the file with duplicate entries.

## 6.4 The Integrator Script (`07-update-jenkins.sh`)

We now have all the components required for integration: the Admin Token in `cicd.env`, the Python helper to patch the YAML, and the understanding that we must recreate the container to apply these changes.

This script is the conductor. It orchestrates the entire update process in a specific order to ensure a clean state transition.

Create this file at `~/cicd_stack/artifactory/07-update-jenkins.sh`.

```bash
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
```

### Deconstructing the Integrator

**1. Prerequisites (The "Python Capability"):**
We cannot assume the host machine has the necessary libraries to run our helper script. The script checks for `python3-yaml` and installs it via `apt` if missing. This ensures our automation doesn't crash due to missing dependencies.

**2. Secret Injection (Bridging the Gap):**
This block acts as the bridge between the two articles. It reads the `ARTIFACTORY_ADMIN_TOKEN` from the central `cicd.env` (created in this article) and appends it to the `jenkins.env` (created in the previous article).
Notice the variable mapping:

* `JENKINS_ARTIFACTORY_PASSWORD` is populated with the value of `ARTIFACTORY_ADMIN_TOKEN`.
  This cleanly injects the secret into the Jenkins container's scope without exposing it in the Docker command history.

**3. The "Re-Deploy" (Solving the Stale Env):**
This is the critical fix for the "Stale Env" trap. Instead of running `docker restart`, the script changes directory (`cd`) to the Jenkins module and executes `./03-deploy-controller.sh`. This effectively stops, removes, and recreates the container using the *newly modified* `jenkins.env` file, ensuring the new token is actually loaded into the environment.

## 6.5 Verification

Run the script:

```bash
chmod +x 07-update-jenkins.sh
./07-update-jenkins.sh
```

Watch the logs. The Jenkins controller will restart. Once it is back online (approx. 2 minutes), perform the final verification:

1.  Log in to Jenkins at `https://jenkins.cicd.local:10400`.
2.  Navigate to **Manage Jenkins** -\> **System**.
3.  Scroll down to the **JFrog** (or Artifactory) section.
4.  You will see the "artifactory" server configuration pre-filled.
5.  Click **Test Connection**.

You should see the message: **"Found JFrog Artifactory 7.90.15 at [https://artifactory.cicd.local:8082/artifactory](https://www.google.com/search?q=https://artifactory.cicd.local:8082/artifactory)"**.

This single green message confirms everything:

* **DNS Resolution:** Jenkins found `artifactory.cicd.local`.
* **SSL Trust:** The JVM trusted the certificate.
* **Authentication:** The injected Admin Token worked.
* **Plugin Logic:** The `jfrogInstances` JCasC schema was parsed correctly.

The "Factory" and the "Warehouse" are now connected.

# Chapter 7: Packaging Theory - From "Binaries" to "Products"

## 7.1 The Concept: A Binary is Not a Product

We have connected our Factory to our Warehouse. We have a secure pipe ready to transport goods. But before we turn on the conveyor belt, we must ask a fundamental question: *what exactly are we shipping?*

In our current V1 pipeline, our build script produces **Raw Binaries**: `libhttpc.so` and `libhttpcpp.so`.

This leads to the **"Raw Binary" Trap**. A shared library file is useless on its own. If a developer downloads `libhttpc.so` from Artifactory, they cannot use it. They are missing the "Contract"—the C header files (`.h`) that define the API. Without the headers, the binary is a black box. Furthermore, they don't know if it was built for Debug or Release, or what dependencies it requires.

To run a professional software supply chain, we must stop thinking in terms of *compiling binaries* and start thinking in terms of **packaging products**.

We are building **Software Development Kits (SDKs)** and **Packages**. A "Product" is a self-contained, versioned, and consumable archive that a downstream developer can ingest without knowing or caring about how it was built.

For our polyglot Hero Project, this means we need to produce three distinct, standardized formats:

1.  **C & C++:** An **SDK Archive** (`.tar.gz`) containing both the "Implementation" (`lib/`) and the "Interface" (`include/`).
2.  **Rust:** A **Standard Crate** (`.crate`) containing source code and metadata, ready for the Rust ecosystem.
3.  **Python:** A **Binary Wheel** (`.whl`) containing pre-compiled bindings and metadata, ready for `pip`.

We will now update our build systems to generate these packages natively.

## 7.2 The C/C++ Strategy: The "SDK" Archive

For our C and C++ artifacts, we will use **CPack**. CPack is bundled with CMake and is the industry standard for creating distribution packages.

Instead of writing a fragile shell script in Jenkins to `cp` files into a temporary directory and `tar` them up, we define "Install Rules" directly in our `CMakeLists.txt`. This pushes the packaging logic down into the build system where it belongs, making it portable and reproducible on any machine (developer workstation or CI agent).

We need to modify `0004_std_lib_http_client/CMakeLists.txt` in two places.

**1. The GoogleTest Fix (The "Pollution" Trap)**
During our initial packaging tests, we discovered that CPack was bundling `libgtest.a` and `libgmock.a` into our SDK. This is because GoogleTest defines its own install rules, and CPack grabs *everything*. We must explicitly disable this to keep our SDK clean.

Locate the `FetchContent` block for GoogleTest and inject the `INSTALL_GTEST OFF` setting:

```cmake
FetchContent_Declare(
        googletest
        GIT_REPOSITORY https://github.com/google/googletest.git
        GIT_TAG        v1.17.0
)

# --- FIX: Disable GTest Installation ---
# Prevents test libraries from polluting our SDK package
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)

FetchContent_MakeAvailable(googletest)
```

**2. The Packaging Logic**
Append the following block to the very end of your `CMakeLists.txt`. This defines the layout of our SDK: headers go to `include/`, and binaries go to `lib/`.

```cmake
# --- Packaging Configuration (CPack) ---

# 1. Define Install Rules
# These tell CMake what files belong in the final package.

# Install the compiled Shared Libraries (.so) into a 'lib/' folder
install(TARGETS httpc_lib httpcpp_lib
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
    RUNTIME DESTINATION bin
)

# Install the Public Headers into an 'include/' folder
install(DIRECTORY include/ DESTINATION include)

# 2. Configure the Package Metadata
set(CPACK_PACKAGE_NAME "http-client-cpp-sdk")
set(CPACK_PACKAGE_VENDOR "Warren Jitsing")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Multi-Language HTTP Client SDK (C/C++)")
set(CPACK_PACKAGE_VERSION "1.0.0")
set(CPACK_PACKAGE_CONTACT "warren.jitsing@infcon.co.za")

# 3. Configure the Generator
# We want a simple .tar.gz (TGZ) archive
set(CPACK_GENERATOR "TGZ")

# This must be the last command in the file
include(CPack)
```

Now, running `cpack -G TGZ` will generate a standardized `http-client-cpp-sdk-1.0.0.tar.gz`.

## 7.3 The Rust Strategy: The ".crate" Standard

For our Rust implementation, the standard distribution format is the **Crate**. Unlike C++, where we often distribute pre-compiled binaries, the Rust ecosystem distributes *source code* bundled with a manifest (`Cargo.toml`). The consumer downloads the crate and compiles it locally, ensuring compatibility with their specific architecture and kernel.

To create a standard crate, we use the `cargo package` command. This command creates a `.crate` file (which is essentially a tarball of the source) in `target/package/`.

However, `cargo package` imposes a "Bureaucracy Check." It enforces strict metadata requirements to ensure the package is publishable to *crates.io* (or Artifactory). If your `Cargo.toml` is missing fields like `description`, `license`, or `repository`, the command will fail.

We must update `src/rust/Cargo.toml` to satisfy these requirements and ensure our package name matches our library name standard.

```toml
[package]
name = "httprust"
version = "0.1.0"
edition = "2021"
# --- Metadata Required for Packaging ---
description = "A standard library HTTP client implementation"
license = "MIT"
repository = "https://gitlab.cicd.local/Articles/0004_std_lib_http_client"
authors = ["Warren Jitsing <warren.jitsing@infcon.co.za>"]

[lib]
name = "httprust"
path = "src/lib.rs"

[dependencies]
libc = "0.2"
reqwest = { version = "0.12.23", features = ["blocking"] }

[[bin]]
name = "httprust_client"
path = "src/bin/httprust_client.rs"

[[bin]]
name = "reqwest_client"
path = "src/bin/reqwest_client.rs"
```

## 7.4 The Python Strategy: The Binary Wheel

For Python, the standard "Product" is the **Binary Wheel (`.whl`)**. This is a pre-compiled package that includes metadata and, crucially, any compiled C-extensions. It allows consumers to install the package via `pip` instantly without needing a compiler toolchain installed on their machine.

Our `setup.sh` script already handles this. It uses the standard `build` module to generate the wheel.

```bash
# (From setup.sh)
python3 -m build --wheel --outdir ${CMAKE_BINARY_DIR}/wheelhouse src/python
```

We do not need to change our build logic here; we simply need to know that our "Product" will be waiting for us in `build_release/wheelhouse/*.whl`.

## 7.5 The "Staging Area" Pattern (`dist/`)

We now have three different build systems (CMake, Cargo, Python Build) outputting artifacts to three different locations (`build_release/`, `src/rust/target/package/`, `build_release/wheelhouse/`).

If we try to configure the Jenkins Artifactory plugin to hunt down these files individually, our pipeline code will become messy and fragile.

Instead, we will adopt the **Staging Area** pattern. Before we trigger the upload, we will move all finished products into a single, clean directory named `dist/`. This decouples the *Build* logic from the *Publish* logic. The Artifactory plugin will have a single, simple instruction: "Upload everything in `dist/`."

This completes our packaging theory. We are ready to implement the V2 Pipeline.

# Chapter 8: Practical Application - The Pipeline V2

## 8.1 The Evolution: From "Build" to "Deliver"

We are now ready to upgrade our pipeline. Our V1 `Jenkinsfile` was a "Continuous Integration" (CI) pipeline; it verified that the code compiled and passed tests. Our V2 `Jenkinsfile` will be a "Continuous Delivery" (CD) pipeline; it will produce shipping-ready artifacts.

To achieve this, we insert a new **Package** stage between "Test" and the final "Publish" step. This stage is responsible for executing the specific packaging commands we enabled in Chapter 7 (`cpack`, `cargo package`) and consolidating the outputs into our "Staging Area" (`dist/`).

Open `0004_std_lib_http_client/Jenkinsfile` and insert the following stage after `Test & Coverage`:

```groovy
        stage('Package') {
            steps {
                echo '--- Packaging Artifacts ---'
                
                // 1. Create the "Staging Area"
                // This is the single folder Artifactory will look at later.
                sh 'mkdir -p dist'

                // 2. Package C/C++ SDK (CPack)
                // We must run inside 'build_release' because CPack relies on 
                // the CMakeCache.txt generated during the build stage.
                dir('build_release') {
                    sh 'cpack -G TGZ -C Release'
                    // Move the resulting tarball to our staging area
                    sh 'mv *.tar.gz ../dist/'
                }

                // 3. Package Rust Crate
                // We run inside the rust source directory.
                dir('src/rust') {
                    // This command generates the .crate file in target/package/
                    sh 'cargo package'
                    // Move it to the staging area
                    sh 'cp target/package/*.crate ../../dist/'
                }

                // 4. Collect Python Wheel
                // The wheel was already built by setup.sh in the earlier stage.
                // We simply retrieve it from the wheelhouse.
                sh 'cp build_release/wheelhouse/*.whl dist/'

                // 5. Verification
                // List the contents so we can see exactly what we are about to ship in the logs.
                sh 'ls -l dist/'
            }
        }
```

### Deconstructing the Package Stage

This stage is the implementation of our "Universal Bucket" strategy. It normalizes the chaos of our polyglot build system into a single, uniform directory.

1.  **The Context Switch (`dir`):** Notice how we repeatedly use the `dir()` directive. This is crucial. `cpack` *must* run in the build directory to find its configuration. `cargo package` *must* run in the source directory to find `Cargo.toml`. The pipeline navigates the filesystem so the tools don't have to guess.
2.  **The Consolidation:** Regardless of where the tool puts the file (`target/package`, `wheelhouse`), we forcefully move it to `dist/`. This means our subsequent "Publish" stage will never need to know about the internal structure of our build. It just needs to know about `dist/`.
3.  **The Artifacts:** At the end of this stage, `dist/` will contain three files:
    * `http-client-cpp-sdk-1.0.0-Linux.tar.gz`
    * `httprust-0.1.0.crate`
    * `httppy-0.1.0-py3-none-any.whl`

## 8.2 The "Publish" Stage and the Syntax Traps

With our artifacts neatly organized in the `dist/` directory, we can define the final stage of our pipeline: **Publish**.

This stage uses the Artifactory Plugin to upload our files and, critically, publish the build metadata. However, configuring this step involves navigating three specific syntax traps that often trip up first-time users: **String Interpolation**, **Pattern Matching**, and **Silent Failures**.

Here is the complete `Publish` stage. Add this to your `Jenkinsfile` immediately after the `Package` stage.

```groovy
        stage('Publish') {
            steps {
                echo '--- Publishing to Artifactory ---'
                
                // 1. Upload the Artifacts
                rtUpload (
                    // Use the ID 'artifactory' defined in our JCasC global config
                    serverId: 'artifactory',
                    
                    // 2. The File Spec
                    // We use Triple Double-Quotes (""") to allow variable interpolation
                    spec: """{
                          "files": [
                            {
                              "pattern": "dist/*", 
                              "target": "generic-local/http-client/${BUILD_NUMBER}/",
                              "flat": "true"
                            }
                          ]
                    }""",
                    
                    // 3. The "Silent Failure" Fix
                    // Force the build to fail if no files match the pattern
                    failNoOp: true,
                    
                    // Associate files with this Jenkins Job
                    buildName: "${JOB_NAME}",
                    buildNumber: "${BUILD_NUMBER}"
                )

                // 4. Publish Build Info (The "Bill of Materials")
                rtPublishBuildInfo (
                    serverId: 'artifactory',
                    buildName: "${JOB_NAME}",
                    buildNumber: "${BUILD_NUMBER}"
                )
            }
        }
```

### Deconstructing the Syntax Traps

**1. The Interpolation Trap (`"""` vs `'''`)**
In Jenkins Groovy, strings behave differently based on quotes.

* `'''Triple Single Quotes'''`: Treat the string literally. If we used this, Jenkins would send the string `${BUILD_NUMBER}` to Artifactory as literal text, resulting in a folder named `${BUILD_NUMBER}` instead of `16`.
* `"""Triple Double Quotes"""`: Enable **Variable Interpolation**. Jenkins replaces `${BUILD_NUMBER}` with the actual build number (e.g., `16`) *before* sending the command. This ensures our artifacts land in the correct versioned folder.

**2. The Pattern Trap (Regex vs. Wildcards)**
The Artifactory File Spec supports both Regex and Wildcards. Regex is powerful but fragile. During our testing, complex regex patterns like `dist/(.*)` failed to match files correctly without specific flags.
We opted for the robust simplicity of **Wildcards**: `"pattern": "dist/*"`.
Combined with `"flat": "true"`, this tells Artifactory: "Take every file inside `dist/`, ignore the folder structure, and upload them directly to the target path."

**3. The "Silent Failure" Trap (`failNoOp`)**
This is the most dangerous default behavior in the Artifactory plugin. By default, if your pattern (`dist/*`) matches **zero files** (perhaps because the package stage failed silently), the `rtUpload` step returns **SUCCESS**.
This leads to "Green Builds" that delivered nothing—a phantom release.
We explicitly set `failNoOp: true`. This forces the pipeline to turn **Red** (Failure) if it uploads nothing. This guarantees that a successful build actually indicates a successful delivery.

**4. The "Chain of Custody" (`rtPublishBuildInfo`)**
The final step, `rtPublishBuildInfo`, does not upload files. It uploads **Metadata**. It scrapes the Jenkins environment (Git Commit Hash, User, Timestamp, Dependencies) and creates a JSON manifest. It sends this manifest to Artifactory, atomically linking it to the files we just uploaded. This is what allows us to trace a binary back to the source code.

# Chapter 9: The Result - Visualizing the Supply Chain

## 9.1 The Artifact Browser: Exploring the Warehouse

The infrastructure is ready, and the pipeline definition is updated. It is time to run the supply chain.

Go to your Jenkins dashboard and navigate to the **`Articles/0004_std_lib_http_client`** job. Click into the **`main`** branch and hit **"Build Now"**.

Watch the console output. You will see the new **Package** stage execute, compressing our artifacts into the `dist/` directory. Then, you will see the **Publish** stage kick in. Unlike our previous tests, this will not be a silent success; the logs will explicitly show the upload of our three specific files to the Artifactory server.

Once the build is green, we can verify the physical results.

Navigate to your Artifactory instance at `https://artifactory.cicd.local:8443` and log in. Open the **Application** module and go to **Artifactory -\> Artifacts**.

In the tree view, expand the `generic-local` repository. You will see a new folder structure that mirrors the logic we defined in our `Jenkinsfile`.

Instead of a flat list of files, you will see a structured hierarchy: `http-client` (the Project), followed by `16` (the Build Number). Inside that versioned folder, you will find our three distinct products sitting side-by-side.

```text
generic-local/
└── http-client/
    └── 16/
        ├── http-client-cpp-sdk-1.0.0-Linux.tar.gz  (The C++ SDK)
        ├── httprust-0.1.0.crate                    (The Rust Source)
        └── httppy-0.1.0-py3-none-any.whl           (The Python Wheel)
```

This view validates our "Universal Bucket" strategy. We did not need to configure a complex PyPI registry, a Cargo registry, and a Conan server to get started. We successfully captured the output of a polyglot build into a single, unified, and versioned location. These files are now immutable; unlike the Jenkins workspace, they will not disappear when the next build starts.

## 9.2 The "Build Info" Ledger

While seeing the files in the repository confirms *storage*, it doesn't confirm *provenance*. To see the "Chain of Custody," we need to look at the metadata generated by our pipeline's `rtPublishBuildInfo` step.

Artifactory stores this metadata as a structured JSON document in a special internal repository.

To view the raw ledger entry:

1.  Navigate to **Application** -\> **Artifacts**.
2.  In the repository tree, select **`artifactory-build-info`**.
3.  Drill down into the folder structure: **`Articles`** -\> **`0004_std_lib_http_client`** -\> **`main`**.
4.  You will see a JSON file named after your build number (e.g., `16-<timestamp>.json`).
5.  Right-click the file and select **View**.

You will see a detailed manifest like this:

```json
{
  "version" : "1.0.1",
  "name" : "Articles/0004_std_lib_http_client/main",
  "number" : "16",
  "agent" : {
    "name" : "Jenkins",
    "version" : "2.528.2"
  },
  "started" : "2025-11-22T14:05:59.821+0000",
  "durationMillis" : 174180,
  "url" : "https://jenkins.cicd.local:10400/job/Articles/job/0004_std_lib_http_client/job/main/16/",
  "vcs" : [ {
    "revision" : "f2fc8640ad0690b94cd7b0536f0c97fcf3afb8fd",
    "message" : ":bug: bug(Jenkinsfile): fix upload spec regexp",
    "url" : "https://gitlab.cicd.local:10300/articles/0004_std_lib_http_client.git"
  } ],
  "modules" : [ {
    "id" : "Articles/0004_std_lib_http_client/main",
    "artifacts" : [ {
      "type" : "gz",
      "sha256" : "1bd7a4407b6e2ac7c3b22eea93f6493992f172fe6f50382dd635401694945e85",
      "name" : "http-client-cpp-sdk-1.0.0-Linux.tar.gz",
      "path" : "http-client/16/http-client-cpp-sdk-1.0.0-Linux.tar.gz"
    }, {
      "type" : "crate",
      "sha256" : "7934cf01ec3331565a97de79d93c07ec1a839c749d546acf9da863c592329526",
      "name" : "rust-0.1.0.crate",
      "path" : "http-client/16/rust-0.1.0.crate"
    }, {
      "type" : "whl",
      "sha256" : "808ffa9c2c532bcf52cf5e3c006ea825cf6e252797657068f5fbc2e506202e9d",
      "name" : "httppy-0.1.0-py3-none-any.whl",
      "path" : "http-client/16/httppy-0.1.0-py3-none-any.whl"
    } ]
  } ]
}
```

## 9.3 Traceability: The "Chain of Custody"

This document is the forensic evidence that links our "Factory" to our "Library."

* **The Source (`vcs.revision`):**
  We see the exact Git Commit SHA: `f2fc8640...`. This is the specific version of the blueprint used to manufacture this release. If a bug is found in this artifact years from now, we know exactly which line of code caused it.

* **The Process (`url`):**
  We have a direct link back to the Jenkins build log: `https://jenkins.cicd.local.../16/`. This provides the context of *how* it was built (logs, environment variables, test results).

* **The Product (`artifacts.sha256`):**
  Most importantly, we have the cryptographic checksums of the output. `1bd7a...` is the unique fingerprint of our C++ SDK. If a user downloads a file claiming to be version 16, we can verify its integrity against this ledger.

This completes the "Chain of Custody." We have successfully linked Binary -\> Build -\> Source.