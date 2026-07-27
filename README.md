# VOC Project — Vulnerability Operations Center

A self-hosted, open-source vulnerability management platform. Scanners push findings into DefectDojo, a FastAPI prioritization service scores them on **CVSS + EPSS + CISA KEV weighted by asset business context**, and n8n routes what actually matters into TheHive cases and chat notifications.

The prioritization model is the point of the project: severity alone ranks a HIGH on an internal HR box above a MEDIUM on the internet-facing payments portal, and that is the wrong order. See [Prioritization](#prioritization) below.

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
1. Builds the Docker Toolbox container (skipped when unchanged)
2. Spins up a `k3d` Kubernetes cluster
3. Deploys DefectDojo, n8n, TheHive, targets (Juice Shop, DVWA), and the prioritization service — in parallel
4. Waits for all services to be healthy (concurrently; DefectDojo is the long pole at ~5-10 min on first run)
5. Starts background port-forwards
6. On a **first** run only: runs the full scan pipeline and prioritizes the results

**Warm restarts are fast.** Every deploy step is fingerprinted against the
cluster it was applied to, so a second `./start.sh` skips the Helm upgrades,
image builds, `k3d image import`s and the scan pipeline that would all be
no-ops — typically under a minute instead of 10+.

| Switch | Effect |
|---|---|
| `VOC_SCAN_ON_START=1` | always run scans on start (`0` = never) |
| `VOC_FORCE_DEPLOY=1` | ignore the state cache, redeploy everything |
| `VOC_ENABLE_WAZUH=1` | deploy the Wazuh manager (SIEM, ~1.5 GB) |
| `VOC_ENABLE_MONITORING=1` | deploy Grafana + Prometheus (~2 GB) |

Inside the toolbox, `voc-refresh` clears the state cache and `voc-help` lists everything.

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
  | prioritization-   | CVSS + EPSS +  |   n8n workflows     |
  | service (FastAPI) | KEV x context  |  poll + branch      |
  |                   |<---- tags ---->|                     |
  +---------+---------+                +---------+-----------+
            ^        |                           |
    asset   |        | priority tag +            | severity/priority branch
  inventory |        | risk score + severity     v
  ConfigMap |        v                 +---------------------+
            |   +-------------------+  | TheHive (cases) +   |
            |   |   DefectDojo      |  | Slack/Discord notify|
            |   |   (updated)       |  +---------------------+
            |   +-------------------+
            |
     business context: internet exposure, criticality 1-5, data class

  Targets: Juice Shop + DVWA (lab scan targets)
  Cluster: k3d (k3s-in-Docker) inside the VOC dev toolbox
  Optional: Wazuh manager (SIEM), Grafana + Prometheus — both off by default
```

---

## Prioritization

A score is three things multiplied together, not one number copied off a CVE page:

```
priority = base(technical, threat) x context(asset)
```

| Term | Source | Notes |
|---|---|---|
| **technical** | CVSS v3/v2, else the scanner's severity word | Most DAST findings (nuclei, sqlmap, ffuf, xsstrike) carry no CVSS at all — the severity fallback is what keeps them in the ranking |
| **threat** | EPSS probability + percentile; CISA KEV | KEV means exploited *today*, so it pins the threat term to 1.0 and floors the final priority at 70 |
| **context** | `prioritization-service/asset-inventory.yaml` | Internet exposure, business criticality 1-5, data classification |

Context is a multiplier in `[0.5, 1.6]` — wide enough to reorder findings
**across** severity bands, which is the entire point:

```
MEDIUM (CVSS 5.5) on juice-shop  — internet-facing, crit 5/5, financial
    base 52 x 1.60  ->  84  CRITICAL
HIGH   (CVSS 8.0) on dvwa        — internal, crit 1/5, internal data
    base 65 x 0.87  ->  57  MEDIUM
```

**Editing business context** — `prioritization-service/asset-inventory.yaml` is
mounted as a ConfigMap, so no image rebuild is needed:

```bash
vi prioritization-service/asset-inventory.yaml
voc-deploy prio          # re-applies the ConfigMap and reloads the service
```

**Inspecting decisions:**

```bash
voc-assets                 # the inventory and its derived factors
voc-prio                   # run a scoring pass now
voc-prio-explain 1234      # why finding 1234 scored what it did
```

Every weight, the multiplier range and the KEV floor are settings in
`prioritization-service/deployment.yaml` (the `prioritization-config`
ConfigMap). Setting `CONTEXT_MIN_MULTIPLIER` and `CONTEXT_MAX_MULTIPLIER`
both to `1.0` disables context and reverts to pure CVSS+EPSS scoring.
`python test_scoring.py` in that directory pins the behaviour.

---

## Components (all open-source, community editions)

| Layer          | Tool                    | Why                                           |
|----------------|-------------------------|-----------------------------------------------|
| Infra/Net scan | Nuclei                  | Ultra-light, low false positives, k8s Job     |
| Web app scan   | OWASP ZAP               | Free, headless, active+passive, DD parser     |
| Container/SCA  | Grype                   | No supply-chain incidents, EPSS+KEV built-in  |
| Findings store | DefectDojo              | Mature, dedup, full REST API, dozens of parsers|
| Prioritization | FastAPI service         | CVSS + EPSS + KEV weighted by asset business context |
| Orchestration  | n8n (self-hosted)       | Visual workflows, rich connectors, error handling|
| Case mgmt      | TheHive Community Ed.   | Built for security incidents, playbooks, Cortex|
| SIEM *(opt-in)*| Wazuh manager           | HIDS + rules engine; API feeds the existing pipeline |
| Monitoring *(opt-in)* | Grafana + Prometheus | Off by default — DefectDojo + n8n already cover the lab, and the stack costs ~2 GB |

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
