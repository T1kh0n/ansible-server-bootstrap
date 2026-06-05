# ansible-server-bootstrap

An Ansible playbook for bootstrapping secured Debian servers with automated core infrastructure.

## What it does:

1. **System Hardening:** Configures SSH on custom port, disables root login, enforces key-based access, and sets up sysctl limits and a 4GB swap file.
2. **OS Optimization & Storage Mounting:** Automatically identifies a non-OS secondary drive (`sdb`, `sda`, or `vdb`), formats it to ext4 if unformatted, and mounts it to `/mnt/storage`.
3. **Core Infrastructure:** Deploys Docker, Traefik v3, CrowdSec, and Oxker.
4. **Zero-Touch WAF:** Integrates a local CrowdSec AppSec middleware at the entrypoint level via an automated LAPI token exchange scheme.
5. **Secure Networking:** Creates an isolated `secure-network` for cross-container proxying.
6. **Unified Storage Layer:** Deploys SeaweedFS with metadata stored on the root partition and file volume slices on the mounted high-capacity disk (`/mnt/storage`).
7. **Production Data Layers:** Deploys resource-constrained instances of PostgreSQL 16 and Redis 7.
8. **SRE Monitoring Stack:** Deploys VictoriaMetrics (vmsingle and vmagent) alongside Grafana, dynamically exposing components over secure subdomains.

## Group Variables Configuration

Configure the environment by filling the structural files inside the `group_vars/` directory.

### `group_vars/all.yaml`
```yaml
---
domain: "domain.com"
acme_email: "email@example.com"
ssh_port: "2222"

```

### `group_vars/database.yaml`

```yaml
---
db_user: "portfolio_user"
db_password: "ChooseSecurePassword"
db_name: "portfolio"
redis_maxmemory: "256mb"

```

### `group_vars/storage.yaml`

```yaml
---
s3_root_user: "seaweedfs_admin"
s3_root_password: "ChooseSecureStorageKey"
s3_bucket_media: "media"
s3_bucket_resumes: "resumes"

```

### `group_vars/monitoring.yaml`

```yaml
---
grafana_admin_password: "ChooseGrafanaPassword"

```

## Cross-Service Interoperability & Application Environment (.env)

The deployment automates infrastructure configurations, creating internal parameters shared securely between services inside the isolated Docker environment. When constructing your client application (FastAPI + Vue.js SSR), you must map your runtime `.env` file to target these specific cross-service endpoints:

### Database Endpoints

* **PostgreSQL Network Address:** `postgres:5432`
* **Redis Cache Network Address:** `redis:6379`

### Object Storage (SeaweedFS S3-Compatible API)

* **Internal S3 Endpoint:** `http://seaweedfs:8333`
* **External S3 Endpoint:** `https://s3.<yourdomain.com>`

### Production Application `.env` Template

```env
DATABASE_URL=postgresql+asyncpg://${db_user}:${db_password}@postgres:5432/${db_name}
REDIS_URL=redis://redis:6379/0

S3_ENDPOINT_URL=http://seaweedfs:8333
S3_ACCESS_KEY=${s3_root_user}
S3_SECRET_KEY=${s3_root_password}
S3_MEDIA_BUCKET=${s3_bucket_media}
S3_RESUMES_BUCKET=${s3_bucket_resumes}

```

## Setup & Execution

### 1. Prerequisites

Ensure you have the required external Ansible dependencies installed on your control system or local host:

```bash
ansible-galaxy collection install ansible.posix community.docker community.general

```

### 2. DNS Requirements

Before running the playbook, configure your domain registrar's zone entries to map infrastructure components to the targeted machine's IPv4 address:

* **A Record:** `@` -> `YOUR_SERVER_IP`
* **A Record (Wildcard):** `*` -> `YOUR_SERVER_IP`

### 3. Execution Command

To initiate the full local provisioning and application stack deployment sequence, execute:

```bash
ansible-playbook bootstrap.yaml -K

```

## Post-Deployment Verification

Verify service orchestration and system layout configurations using the standard diagnostics suite:

```bash
findmnt /mnt/storage
swapon --show
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
sudo docker exec -it infra_core-crowdsec-1 cscli decisions list

```

