# Setup guide

Get from an empty Windows PC to a running VOC stack on a k3d cluster, all
inside the VOC dev toolbox container. No WSL2, no admin scripts — just Docker
Desktop + this repo.

---

## 0. Prerequisites (Windows host)

- **Docker Desktop** with WSL2 backend — install from docker.com if missing.
  Ensure it's running: `docker --version` in PowerShell.
- **Git** (Scoop: `scoop install git`, or install from git-scm.com).
- **kubectl** on Windows (optional, for accessing the cluster from outside
  the toolbox): `scoop install kubectl`.

That's it. Everything else (helm, k3d, jq, yq, python, scanner CLIs) lives
inside the toolbox container.

---

## 1. Build the toolbox image

```powershell
cd C:\Users\Regal\Desktop\voc
docker compose build
```

This builds `voc-toolbox:latest` from `toolbox/Dockerfile`. It installs
kubectl, helm, k3d, docker CLI, jq, yq, python3, git, vim inside a
Debian bookworm-slim base. Takes ~3-5 min on first build.

---

## 2. Configure secrets

```powershell
Copy-Item .env.example .env
# Edit .env — set DD_API_KEY to a real DefectDojo API token once DefectDojo is up.
# For the first run, the defaults are fine (DD_API_KEY is only needed for scans).
```

---

## 3. Enter the toolbox

```powershell
docker compose run --rm voc
```

You get a bash shell with all VOC helper commands. The repo is mounted at
`/workspace`. Docker socket is mounted so k3d + scanner containers work.

---

## 4. Create the k3d cluster

```bash
voc-up
```

This creates a k3d cluster named `voc` (k3s-in-Docker), writes kubeconfig
to `/workspace/.kube/config` (also accessible from your Windows host), and
creates the four namespaces (`voc-core`, `scanning`, `monitoring`, `targets`).

Verify:
```bash
voc-status
```

From Windows host (outside toolbox), you can also use kubectl directly:
```powershell
$env:KUBECONFIG = "C:\Users\Regal\Desktop\voc\.kube\config"
kubectl get nodes
```

---

## 5. Deploy the full stack

```bash
voc-deploy all
```

This deploys (in order):
1. Namespaces (already done by voc-up, but idempotent)
2. DefectDojo (heaviest — bundled Postgres + Valkey + Celery + Django)
3. n8n
4. Lab targets (Juice Shop + DVWA in `targets` namespace)
5. Waits for DefectDojo to be ready (up to 5 min)
6. Scanners (Grype / ZAP / Nuclei CronJobs + DefectDojo creds secret)
7. Prioritization service (FastAPI)
8. Monitoring (kube-prometheus-stack + Grafana dashboard)

Or deploy individual components:
```bash
voc-deploy dd          # just DefectDojo
voc-deploy n8n         # just n8n
voc-deploy targets     # just Juice Shop + DVWA
voc-deploy scanners    # just scanner CronJobs
voc-deploy monitoring  # just Prometheus + Grafana
```

Check progress:
```bash
voc-status
```

---

## 6. Access UIs

In separate toolbox shells (or from Windows host with kubectl):

```bash
# DefectDojo (http://localhost:8080)
voc-forward voc-core/defectdojo-django-svc 8080:8080

# n8n (http://localhost:5678)
voc-forward voc-core/n8n 5678:5678

# TheHive (http://localhost:9000)
voc-forward voc-core/thehive 9000:9000

# Grafana (http://localhost:3000)
voc-forward monitoring/kps-grafana 3000:80

# Juice Shop (http://localhost:3001 — from targets ns)
kubectl port-forward -n targets svc/juice-shop 3001:3000
```

Get the DefectDojo admin password:
```bash
kubectl -n voc-core get secret defectdojo-django-secret -o jsonpath='{.data.DD_ADMIN_PASSWORD}' | base64 -d
```

**On first login: change the admin password and store it in a password manager
(not in git).**

---

## 7. Run a scan pipeline

```bash
voc-scan
```

This runs the adapted `scripts/scan-all.sh` which:
1. Starts Juice Shop + DVWA as Docker containers on a shared network
2. Runs Grype (SCA scan of a container image)
3. Runs Nuclei (DAST against both targets, converts JSONL→JSON array with jq)
4. Runs ZAP (DAST with AJAX spider via Automation Framework)
5. Imports all results to DefectDojo via `import-scan` API
6. Cleans up target containers

Verify findings in DefectDojo UI (refresh after scan completes).

---

## 8. Import n8n workflow

1. Open n8n UI (http://localhost:5678 after port-forward).
2. Set up credentials:
   - **DefectDojo API** — HTTP Header auth: `Authorization: Token <YOUR_KEY>`
   - **TheHive API** — HTTP Header auth: `Authorization: Bearer <YOUR_KEY>`
3. Configure env vars in n8n: `DD_URL`, `SLACK_WEBHOOK_URL`, `THEHIVE_URL`.
4. Import `n8n-workflows/defectdojo-routing.json` (Workflows → ⋯ → Import from File).
5. Wire credentials to the nodes, activate, trigger manually to test.
6. Re-export the working workflow back to the repo.

---

## 9. Prioritization service

The FastAPI service runs as a k8s Deployment in `voc-core`. It:
- Pulls active findings from DefectDojo API
- Fetches EPSS scores by CVE from FIRST.org
- Blends CVSS + EPSS into a 0-100 priority score
- Writes the score back to DefectDojo as a `priority-NN` tag + `risk_score`

To build and load the image:
```bash
# Inside the toolbox (has docker CLI + socket)
cd /workspace/prioritization-service
docker build -t prioritization-service:0.1.0 .
# Import into k3d's k3s (uses containerd, not docker)
k3d image import prioritization-service:0.1.0 -c voc
# Deploy
voc-deploy prio
```

Trigger a scoring pass:
```bash
voc-forward voc-core/prioritization-service 8000:8000
curl -X POST http://localhost:8000/score
curl http://localhost:8000/state
```

---

## 10. Shut down

```bash
# Delete the cluster (frees all RAM)
voc-down

# Exit the toolbox
exit
```

Or just stop the container — the k3d cluster persists across toolbox
restarts because it runs as Docker containers, not inside the toolbox.

---

## Troubleshooting

- **`docker compose run` fails with socket error**: ensure Docker Desktop is running.
- **`voc-up` hangs on cluster creation**: check Docker Desktop has enough RAM (Settings → Resources → Memory: at least 8 GB recommended for the full stack).
- **`kubectl` can't reach cluster from toolbox**: the kubeconfig server URL uses `host.docker.internal`. On Docker Desktop this resolves automatically. On Linux, `extra_hosts` in docker-compose.yml handles it.
- **DefectDojo pods CrashLoopBackOff**: check `kubectl -n voc-core describe pod <pod-name>` and logs. Common cause: not enough RAM. Reduce memory limits in `k8s/defectdojo/values.yaml`.
- **`voc-scan` can't reach DefectDojo**: start a port-forward first: `voc-forward voc-core/defectdojo-django-svc 8080:8080` in another toolbox shell.
