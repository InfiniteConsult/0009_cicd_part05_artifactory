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
