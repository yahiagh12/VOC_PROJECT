# VOC Project — Vulnerability Operations Center

A self-hosted, open-source vulnerability management platform. Scanners push findings into DefectDojo, a FastAPI prioritization service blends CVSS + EPSS into a priority score, n8n routes critical/high findings into TheHive cases and chat notifications, and Grafana dashboards report MTTR, SLA breaches, and scan coverage.

Built for resource-constrained lab environments (≤ 16 GB RAM). Runs on k3d (k3s-in-Docker) inside a dev toolbox container.

---

## Quick Start Guide

This guide will walk you through setting up the entire Vulnerability Operations Center locally on Windows using Docker Desktop.

### 1. Prerequisites
- **Docker Desktop**: Installed and running.
- **Git**: To clone this repository.
- Windows PowerShell (Run as Administrator is recommended but not required).

### 2. Build and Start the Toolbox
Open PowerShell, navigate to the cloned repository, and start the development container. The `--service-ports` flag is crucial as it exposes the web interfaces (DefectDojo, n8n, etc.) to your Windows host.

```powershell
# Navigate to the project directory
cd path\to\VOC_PROJECT

# Build the toolbox container (takes ~3-5 minutes the first time)
docker compose build

# Start the toolbox with port forwarding enabled
docker compose run --service-ports --rm voc
```

### 3. Deploy the Kubernetes Cluster
Once inside the container shell (`root@...:/workspace#`), initialize the local Kubernetes cluster (k3d):

```bash
# Load the helper functions
source /workspace/toolbox/profile.sh

# Create the cluster and namespaces
voc-up
```

### 4. Deploy Components
Deploy the complete stack, including DefectDojo, n8n, Juice Shop (target), scanners, and the custom prioritization service:

```bash
# Deploy all services
voc-deploy all

# Check the status of the deployment
voc-status
```
*Note: Wait until all pods in `voc-status` show a `Running` status. DefectDojo usually takes 3-5 minutes to fully initialize.*

### 5. Access the Web Interfaces
To access the applications from your Windows browser, you need to port-forward them from the container.

**DefectDojo (Vulnerability Management)**
1. Run the port-forward command in your container:
   ```bash
   voc-forward voc-core/defectdojo-django 8080:80 &
   ```
   *(The `&` runs it in the background so you can keep using the shell)*
2. Open your browser: **http://localhost:8080**
3. Retrieve the admin password:
   ```bash
   echo $(kubectl get secret defectdojo -n voc-core -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 --decode)
   ```
   *(Username is `admin`)*

**n8n (Workflow Automation)**
1. Port-forward the service:
   ```bash
   voc-forward voc-core/n8n 5678:5678 &
   ```
2. Open your browser: **http://localhost:5678**

**Juice Shop (Vulnerable Target App)**
1. Port-forward the service:
   ```bash
   voc-forward targets/juice-shop 3000:3000 &
   ```
2. Open your browser: **http://localhost:3000**

### 6. Run a Vulnerability Scan
Trigger a scan pipeline (Grype + Nuclei + ZAP) against the targets. The results will be automatically pushed into DefectDojo.

```bash
voc-scan
```

---

## Architecture

```
            +-----------+   +-----------+   +-----------+
  scheduled |  Grype    |   |   ZAP     |   |  Nuclei   |
  CronJobs  | (SCA)     |   | (DAST)    |   | (DAST)    |
            +-----+-----+   +-----+-----+   +-----+-----+
                  \              |              /
                   v            v            v
                 +-----------------------------+
                 |        DefectDojo           |  <-- central findings store
                 |   (API + UI, Postgres)      |
                 +------+--------------+-------+
                        |              |
            +-----------+              +-----------+
            |                                      |
            v                                      v
  +-------------------+                +---------------------+
  | prioritization-   |  (CVSS+EPSS)   |   n8n workflows     |
  | service (FastAPI)  |<---- tags ---->|  poll + branch      |
  +---------+---------+                +---------+-----------+
            |                                    |
            | pushes priority tag                 | severity/priority branch
            v                                    v
  +-------------------+              +---------------------+
  |   DefectDojo      |              | TheHive (cases) +   |
  |   (updated)       |              | Slack/Discord notify|
  +-------------------+              +---------------------+

  Monitoring: Prometheus -> Grafana (MTTR, SLA, scan coverage, top assets)
  Targets: Juice Shop + DVWA (lab scan targets)
  Cluster: k3d (k3s-in-Docker) inside the VOC dev toolbox
```

---

## Components (all open-source, community editions)

| Layer          | Tool                    | Why                                           |
|----------------|-------------------------|-----------------------------------------------|
| Infra/Net scan | Nuclei                  | Ultra-light, low false positives, k8s Job     |
| Web app scan   | OWASP ZAP               | Free, headless, active+passive, DD parser     |
| Container/SCA  | Grype                   | No supply-chain incidents, EPSS+KEV built-in  |
| Findings store | DefectDojo              | Mature, dedup, full REST API, dozens of parsers|
| Orchestration  | n8n (self-hosted)       | Visual workflows, rich connectors, error handling|
| Case mgmt      | TheHive Community Ed.   | Built for security incidents, playbooks, Cortex|
| Monitoring     | Grafana + Prometheus    | Light, native k8s, customizable dashboards    |

---

## Troubleshooting

- **400 Bad Request on DefectDojo:** Ensure you are accessing via `http://localhost:8080` (not 127.0.0.1 or another host), as Django's `ALLOWED_HOSTS` is strictly configured.
- **Port already allocated:** If Docker complains about ports, you might have left a previous container running. Run `docker ps` to find it, and `docker kill <id>` to stop it.
- **Commands not found:** Always run `source /workspace/toolbox/profile.sh` when you open a new shell inside the container to load the `voc-*` commands.

## Notes

- Do not commit real kubeconfig, secrets, or `.env` files (see `.gitignore`).
- Change default admin passwords on first login; store in a password manager.
- Lab targets (Juice Shop, DVWA) must never be exposed outside the cluster.
- WSL2 is not required — k3d runs k3s inside Docker containers.
