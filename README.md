# VOC Project — Vulnerability Operations Center

A self-hosted, open-source vulnerability management platform. Scanners push
findings into DefectDojo, a FastAPI prioritization service blends CVSS + EPSS
into a priority score, n8n routes critical/high findings into TheHive cases
and chat notifications, and Grafana dashboards report MTTR, SLA breaches,
and scan coverage.

Built for resource-constrained lab environments (≤ 16 GB RAM). Runs on k3d
(k3s-in-Docker) inside a dev toolbox container.

> Tool-selection rationale: see [`etude_comparative.html`](etude_comparative.html)
> (covers all 7 components: Nuclei, ZAP, Grype, DefectDojo, n8n, TheHive,
> Grafana+Prometheus).
>
> Deployment progress: see [`docs/checklist.md`](docs/checklist.md).

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

Full write-up: [`docs/architecture.md`](docs/architecture.md).

---

## Quick start

```powershell
# 0. Prerequisites: Docker Desktop + this repo
cd C:\Users\Regal\Desktop\voc

# 1. Build the toolbox image (3-5 min first time)
docker compose build

# 2. Copy .env and fill in real values later
Copy-Item .env.example .env

# 3. Enter the toolbox
docker compose run --rm voc
```

Inside the toolbox:

```bash
voc-up           # create k3d cluster + namespaces
voc-deploy all   # deploy the full stack (DefectDojo, n8n, targets, scanners, monitoring)
voc-status       # check pod status
voc-forward voc-core/defectdojo-django-svc 8080:8080  # access DefectDojo UI
voc-scan         # run Grype + Nuclei + ZAP, import to DefectDojo
```

Full walkthrough: [`docs/setup.md`](docs/setup.md).

---

## Repo layout

```
voc/
├── toolbox/                # dev toolbox (Dockerfile + entrypoint + helpers)
├── docker-compose.yml      # runs the toolbox with repo + docker socket mounted
├── .env.example            # copy to .env, fill in DD_API_KEY etc.
├── k8s/
│   ├── namespaces/         # namespace manifests (voc-core, scanning, monitoring, targets)
│   ├── defectdojo/         # helm values (low-resource profile for ≤16GB RAM)
│   ├── n8n/                # helm values
│   ├── thehive/            # helm values
│   ├── monitoring/         # kube-prometheus-stack values + Grafana dashboard JSON
│   └── targets/            # Juice Shop + DVWA deployments
├── scanners/               # Grype / ZAP / Nuclei CronJob manifests
├── config/
│   └── zap-plan.yaml       # OWASP ZAP Automation Framework plan
├── prioritization-service/ # FastAPI service (CVSS + EPSS scoring)
├── n8n-workflows/          # exported n8n workflow JSON
├── scripts/
│   ├── k3d-up.sh           # create k3d cluster + namespaces
│   └── scan-all.sh         # scan pipeline (Grype + Nuclei + ZAP → DefectDojo)
├── etude_comparative.html  # tool selection rationale (7 components)
└── docs/
    ├── architecture.md     # architecture + data flow + scoring formula
    ├── setup.md            # step-by-step setup guide
    └── checklist.md        # deployment progress tracker
```

---

## Components (all open-source, community editions)

| Layer          | Tool                    | Why (see etude_comparative.html)              |
|----------------|-------------------------|-----------------------------------------------|
| Infra/Net scan | Nuclei                  | Ultra-light, low false positives, k8s Job     |
| Web app scan   | OWASP ZAP               | Free, headless, active+passive, DD parser     |
| Container/SCA  | Grype                   | No supply-chain incidents, EPSS+KEV built-in  |
| Findings store | DefectDojo              | Mature, dedup, full REST API, dozens of parsers|
| Orchestration  | n8n (self-hosted)       | Visual workflows, rich connectors, error handling|
| Case mgmt      | TheHive Community Ed.   | Built for security incidents, playbooks, Cortex|
| Monitoring     | Grafana + Prometheus    | Light, native k8s, customizable dashboards    |

---

## Free / community editions only

No paid tiers. All components are open-source community editions. The only
external dependency is the EPSS API (api.first.org) which is free.

## Notes

- Do not commit real kubeconfig, secrets, or `.env` files (see `.gitignore`).
- Change default admin passwords on first login; store in a password manager.
- Lab targets (Juice Shop, DVWA) must never be exposed outside the cluster.
- WSL2 is not required — k3d runs k3s inside Docker containers.
