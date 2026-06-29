# VOC Project — Vulnerability Operations Center

A self-hosted, open-source vulnerability management platform. Scanners push findings into DefectDojo, a FastAPI prioritization service blends CVSS + EPSS into a priority score, n8n routes critical/high findings into TheHive cases and chat notifications, and Grafana dashboards report MTTR, SLA breaches, and scan coverage.

Built for resource-constrained lab environments (≤ 16 GB RAM). Runs on k3d (k3s-in-Docker) inside a dev toolbox container.

---

## Quick Start Guide

We have completely automated the setup. You just need to run one script and it will handle everything: building the container, deploying the Kubernetes cluster, installing all services, port-forwarding, and running the initial vulnerability scans.

### 1. Prerequisites
- **Docker Desktop**: Installed and running.
- **Git**: To clone this repository.

### 2. Run the One-Click Installer
Open your terminal (PowerShell on Windows, Bash on Linux/Mac) and run the startup script:

**On Windows:**
```powershell
.\start.ps1
```

**On Linux/Mac:**
```bash
./start.sh
```

**What the script does automatically:**
1. Builds the Docker Toolbox container
2. Spins up a `k3d` Kubernetes cluster
3. Deploys DefectDojo, n8n, targets (Juice Shop, DVWA), and prioritization services
4. Waits for all services to be fully healthy (DefectDojo takes ~10-15 mins on first run)
5. Starts background port-forwards
6. Runs a full vulnerability scan (Grype, Nuclei, ZAP) and uploads the results

### 3. Access the Web Interfaces
Once the script finishes, you will be left inside the toolbox shell (`root@...:/workspace#`). The following services will be available in your host browser:

**DefectDojo (Vulnerability Management)**
- **URL**: http://localhost:8080
- **User**: `admin`
- **Password**: Shown in the terminal output at the end of the script

**n8n (Workflow Automation)**
- **URL**: http://localhost:5678

**Juice Shop (Vulnerable Target App)**
- **URL**: http://localhost:3000

### 4. Running Additional Scans
If you ever want to re-run the vulnerability scanners against the targets, just type this inside the toolbox shell:
```bash
voc-scan
```

If your port-forwards ever drop (or if you restart your computer tomorrow), just run `.\start.ps1` again. It will detect the cluster already exists and instantly reconnect everything!

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
