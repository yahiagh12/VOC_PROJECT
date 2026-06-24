# VOC Project — Deployment Checklist

Source of truth to-do list. Check items off as you go. Ordered so each step
unblocks the next.

---

## 0. Accounts & Access (do first, before any technical work)

- [x] Decide GitHub hosting: local-only for now (push to GitHub later)
- [x] Confirm tier strategy: free / community editions only (no Student Pack)
- [ ] Install Tailscale on both machines (free, no card) — tailscale.com/download
- [ ] Decide which machine is the "always-on" host (this PC via WSL2, for now)
- [ ] Confirm Tailscale mesh works: both can ping/SSH into the host from their laptop

> Note: With the cluster in WSL2 on this PC, "always-on" is best-effort
> (WSL2 suspends when the Windows session locks). If true 24/7 is needed,
> migrate to a dedicated Linux box or cheap VPS and repoint kubeconfig.

---

## 1. Repo Setup

- [x] Create main repo `voc` (local; push later)
- [x] Initialize structure (k8s/, scanners/, prioritization-service/, n8n-workflows/, docs/)
- [x] Add `.gitignore` (kubeconfig, secrets, .env files)
- [x] Add README.md with project summary + setup instructions
- [ ] Set up branch protection on `main` (require PR before merge) — after GitHub push
- [ ] Agree on commit convention (consistent, doesn't need to be fancy)

---

## 2. Host Machine Prep

- [ ] Confirm host machine specs (RAM/CPU) — note them down
- [x] Install/update Ubuntu (via WSL2) on host — pending WSL install step
- [ ] Update system packages (inside WSL Ubuntu)
- [ ] Open required ports if needed (Tailscale usually avoids needing this)
- [ ] Install Docker inside WSL Ubuntu (for local image builds; k3s uses containerd) — script in scripts/wsl-setup.sh

---

## 3. k3s Cluster

- [ ] Install k3s on host (inside WSL Ubuntu): `curl -sfL https://get.k3s.io | sh -`
- [ ] Verify cluster running: `kubectl get nodes`
- [ ] Copy kubeconfig to Windows local machine, point `server` at localhost
- [ ] Confirm Windows `kubectl get pods -A` works
- [ ] Install Helm (Windows: done via Scoop; WSL: pending)
- [x] Create namespaces: voc-core, scanning, monitoring, targets (manifests ready)
- [ ] Apply `kubectl apply -f k8s/namespaces/namespaces.yaml` once cluster is up
- [x] Commit namespace YAMLs to repo

---

## 4. Core Platform Deployment

- [ ] Add DefectDojo Helm repo, review default `values.yaml`
- [ ] Deploy DefectDojo into `voc-core` namespace
- [ ] Verify DefectDojo UI reachable, log in as admin
- [ ] Change default admin password, note credentials somewhere safe (not in git)
- [ ] Add n8n Helm repo / manifest, deploy into `voc-core` namespace
- [ ] Verify n8n UI reachable, complete initial setup
- [x] Commit working `values.yaml` stubs for both to repo (finalize after deploy)

---

## 5. Lab Targets

- [x] Write Juice Shop Deployment (k8s/targets/juice-shop.yaml)
- [x] Write DVWA Deployment (k8s/targets/dvwa.yaml)
- [ ] Apply manifests, confirm both targets reachable from within cluster
- [x] Commit target manifests to `k8s/targets/`

---

## 6. Scanners — one at a time, confirm each works before moving to next

### Grype
- [x] Write Grype CronJob manifest (scans image, outputs JSON)
- [ ] Run manually, confirm output format
- [ ] Confirm findings show up in DefectDojo UI
- [x] Manifest includes scheduled CronJob (manual run via `--from=cronjob/grype`)

### ZAP
- [x] Write ZAP CronJob manifest (headless, against Juice Shop)
- [ ] Run manually, confirm scan completes and produces report
- [ ] Confirm findings show up
- [x] Manifest includes scheduled CronJob

### Nuclei
- [x] Write Nuclei CronJob manifest
- [ ] Run manually against targets
- [ ] Confirm findings show up
- [x] Manifest includes scheduled CronJob

### OpenVAS (do last, optional/stretch)
- [ ] Deploy Greenbone Community Container
- [ ] Sync reduced feed (not full feed, to save time/disk)
- [ ] Run test scan against a target
- [ ] Push results to DefectDojo
- [ ] Keep as on-demand Job, not always-on

---

## 7. Automation Layer (n8n)

- [x] Stub n8n workflow: poll DefectDojo for findings (n8n-workflows/defectdojo-routing.json)
- [x] Add severity/priority-based branching logic
- [x] Connect Slack/Discord webhook node for notifications
- [ ] Import into n8n UI, wire credentials + env vars
- [ ] Test: trigger a finding manually, confirm notification fires
- [ ] Re-export working workflow JSON, commit to `n8n-workflows/`

---

## 8. TheHive Integration

- [ ] Deploy TheHive Community Edition (confirm free edition + 5.x version)
- [ ] Connect TheHive to n8n workflow: Critical/High → auto-create case
- [ ] Test end-to-end: scanner finds critical → DefectDojo → n8n → TheHive case
- [ ] Document the working flow in `docs/architecture.md`

---

## 9. Prioritization Microservice

- [x] Scaffold FastAPI project in `prioritization-service/`
- [x] Write DefectDojo API client (pull findings)
- [x] Write EPSS API client (fetch EPSS scores by CVE)
- [x] Write scoring logic: blend CVSS + EPSS into a priority score
- [x] Write logic to push priority back to DefectDojo (tag + risk_score)
- [x] Containerize (Dockerfile), k8s Deployment manifest written
- [ ] Build image, deploy to cluster
- [ ] Update n8n workflow to route on priority tag (stub already routes on priority)
- [ ] Test with known CVEs, confirm scoring makes sense

---

## 10. Dashboards

- [ ] Deploy kube-prometheus-stack Helm chart into `monitoring` namespace
- [ ] Confirm Prometheus scraping cluster + DefectDojo metrics (exporter TBD)
- [x] Stub Grafana dashboard with panels (k8s/monitoring/grafana-dashboard.json)
  - [ ] Open vulnerabilities by severity over time
  - [ ] Mean time to remediate (MTTR)
  - [ ] SLA breach count
  - [ ] Top vulnerable assets
  - [ ] Scan coverage (% assets scanned in last 7 days)
- [ ] Export final dashboard JSON, commit to `k8s/monitoring/`

---

## 11. Stretch Goals (only if time allows)

- [ ] Set up ArgoCD or Flux for GitOps deployment of the whole stack
- [ ] Add NetworkPolicies for proper namespace isolation
- [ ] Jira/GitLab issue auto-creation for remediation tracking
- [ ] Add CI pipeline (GitHub Actions) to lint/validate YAML on PR

---

## 12. Documentation (ongoing, not a final step)

- [x] Keep `docs/architecture.md` updated as you build (diagram + explanation)
- [ ] Screenshot key dashboards/workflows as you finish them (for the final report)
- [ ] Note any deviations from the original plan and why
