# VOC Project — Vulnerability Operations Center

A self-hosted, open-source vulnerability management platform running on a local
k3s cluster. Scanners push findings into DefectDojo, a FastAPI prioritization
service blends CVSS + EPSS into a priority score, n8n routes critical/high
findings into TheHive cases and chat notifications, and Grafana dashboards
report MTTR, SLA breaches, and scan coverage.

> Status: scaffolding. Items in [`docs/checklist.md`](docs/checklist.md) track
> what is done vs pending.

---

## Architecture (summary)

```
            +-----------+   +-----------+   +-----------+
  scheduled |  Grype    |   |   ZAP     |   |  Nuclei   |
  CronJobs  | (image)   |   | (DAST)    |   | (DAST)    |
            +-----+-----+   +-----+-----+   +-----+-----+
                  \              |              /
                   \             |             /
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
  Targets ns: Juice Shop + DVWA (lab scan targets)
```

Full write-up: [`docs/architecture.md`](docs/architecture.md).

---

## Repo layout

```
voc/
├── k8s/
│   ├── namespaces/      # namespace manifests
│   ├── defectdojo/      # helm values + manifests
│   ├── n8n/             # helm values + manifests
│   ├── thehive/         # helm values + manifests
│   ├── monitoring/      # kube-prometheus-stack values + grafana dashboards
│   └── targets/         # Juice Shop + DVWA deployments
├── scanners/            # Grype / ZAP / Nuclei Job + CronJob manifests
├── prioritization-service/  # FastAPI service (CVSS + EPSS scoring)
├── n8n-workflows/       # exported n8n workflow JSON
└── docs/                # architecture + checklist
```

---

## Prerequisites (host = this PC, via WSL2)

- Windows 11 with WSL2 + Ubuntu
- Inside WSL Ubuntu: k3s, helm
- On Windows side: kubectl, helm, git, python (installed via Scoop)
- Docker Desktop (WSL2 backend) — for local image builds

See [`docs/setup.md`](docs/setup.md) for the step-by-step.

---

## Quick start (once cluster is up)

```bash
# from Windows side, kubeconfig points at WSL2 k3s over localhost
kubectl create -f k8s/namespaces/namespaces.yaml
helm repo add defectdojo https://raw.githubusercontent.com/DefectDojo/django-DefectDojo/helm-charts
helm install defectdojo defectdojo/defectdojo -n voc-core -f k8s/defectdojo/values.yaml
# ... n8n, thehive, targets, scanners, prioritization-service
```

---

## Free / community editions only

No paid tiers are used. All components are open-source community editions:
DefectDojo, n8n (self-hosted), TheHive Community Edition, Prometheus/Grafana
(kube-prometheus-stack), Grype/ZAP/Nuclei, k3s.

## Notes

- Do not commit real kubeconfig, secrets, or `.env` files (see `.gitignore`).
- Default admin passwords must be changed on first login and stored outside git.
