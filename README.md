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