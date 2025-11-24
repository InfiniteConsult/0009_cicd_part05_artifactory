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

