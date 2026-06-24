# VOC Project — Deployment Checklist

Source of truth to-do list. Check items off as you go.

---

## 0. Accounts & Access

- [x] Decide GitHub hosting: local-only for now (push to GitHub later)
- [x] Confirm tier strategy: free / community editions only
- [ ] Install Tailscale on both machines — tailscale.com/download
- [x] Decide host: k3d (k3s-in-Docker) inside the VOC dev toolbox
- [ ] Confirm Tailscale mesh works (if working from two laptops)

---

## 1. Repo Setup

- [x] Create main repo `voc` (local; push later)
- [x] Initialize structure
- [x] Add `.gitignore` (kubeconfig, secrets, .env, scanner reports, .kube/)
- [x] Add README.md with project summary + setup instructions
- [x] Add `etude_comparative.html` — tool selection rationale (7 components)
- [ ] Set up branch protection on `main` (after GitHub push)
- [ ] Agree on commit convention

---

## 2. Dev Toolbox (Docker container)

- [x] Write `toolbox/Dockerfile` (kubectl, helm, k3d, docker CLI, jq, yq, python, git)
- [x] Write `toolbox/entrypoint.sh` + `toolbox/profile.sh` (voc-up, voc-deploy, voc-scan, etc.)
- [x] Write `docker-compose.yml` (mounts repo + docker socket + persistent volumes)
- [x] Write `.env.example` at repo root
- [x] Write `scripts/k3d-up.sh` (creates k3d cluster + namespaces)
- [x] Write `scripts/scan-all.sh` (adapted from colleague's pipeline)
- [ ] Build toolbox image: `docker compose build`
- [ ] Enter toolbox: `docker compose run --rm voc`
- [ ] Run `voc-up` to create k3d cluster
- [ ] Confirm `voc-status` shows a Ready node + 4 namespaces

---

## 3. Core Platform Deployment

- [x] Write DefectDojo values (low-resource ≤16GB, valkey, memory caps)
- [x] Write n8n values
- [x] Write TheHive values
- [ ] `voc-deploy dd` — deploy DefectDojo into `voc-core`
- [ ] Verify DefectDojo UI reachable (port-forward), log in as admin
- [ ] Change default admin password, store in password manager (not git)
- [ ] `voc-deploy n8n` — deploy n8n
- [ ] Verify n8n UI reachable, complete initial setup
- [ ] `voc-deploy thehive` — deploy TheHive CE (confirm free edition + 5.x version)
- [ ] Verify TheHive UI reachable

---

## 4. Lab Targets

- [x] Write Juice Shop Deployment (k8s/targets/juice-shop.yaml)
- [x] Write DVWA Deployment (k8s/targets/dvwa.yaml)
- [ ] `voc-deploy targets` — apply manifests
- [ ] Confirm both targets reachable from within cluster

---

## 5. Scanners

### Grype
- [x] Write Grype CronJob manifest (scan_type=Anchore Grype)
- [ ] `voc-deploy scanners` — apply manifests
- [ ] Run manually: `kubectl create job manual-grype --from=cronjob/grype -n scanning`
- [ ] Confirm findings show up in DefectDojo UI

### ZAP
- [x] Write ZAP CronJob manifest (headless, Automation Framework)
- [x] Write `config/zap-plan.yaml` (checked-in ZAP automation plan)
- [ ] Run manually, confirm scan completes and produces XML report
- [ ] Confirm findings show up in DefectDojo

### Nuclei
- [x] Write Nuclei CronJob manifest (with jq JSONL→JSON array conversion)
- [ ] Run manually against targets
- [ ] Confirm findings show up in DefectDojo

### OpenVAS (optional/stretch)
- [ ] Deploy Greenbone Community Container
- [ ] Sync reduced feed
- [ ] Run test scan, push to DefectDojo

---

## 6. Scan Pipeline (scan-all.sh)

- [x] Adapt colleague's scan-all.sh: env-driven, no hardcoded secrets
- [x] Keep jq Nuclei JSONL→JSON array conversion
- [x] Keep ZAP Automation Framework approach
- [x] Use checked-in `config/zap-plan.yaml`
- [ ] Run `voc-scan` from toolbox, confirm all 3 scanners import to DefectDojo
- [ ] Verify findings in DefectDojo UI

---

## 7. Automation Layer (n8n)

- [x] Stub n8n workflow: poll DefectDojo, branch on priority, notify + create case
- [ ] Import into n8n UI, wire credentials + env vars
- [ ] Test: trigger a finding manually, confirm notification fires
- [ ] Test: Critical/High → TheHive case created
- [ ] Re-export working workflow JSON, commit to `n8n-workflows/`

---

## 8. TheHive Integration

- [ ] Confirm TheHive CE deployed and reachable
- [ ] Connect TheHive to n8n workflow: Critical/High → auto-create case
- [ ] Test end-to-end: scanner → DefectDojo → n8n → TheHive case
- [ ] Document the working flow in `docs/architecture.md`

---

## 9. Prioritization Microservice

- [x] Scaffold FastAPI project (DefectDojo + EPSS clients, scoring logic)
- [x] Write Dockerfile + k8s Deployment
- [ ] Build image, import into k3d: `k3d image import prioritization-service:0.1.0 -c voc`
- [ ] Deploy: `voc-deploy prio`
- [ ] Test with known CVEs, confirm scoring makes sense
- [ ] Confirm priority tags visible in DefectDojo UI

---

## 10. Dashboards

- [x] Write kube-prometheus-stack values (monitoring namespace)
- [x] Stub Grafana dashboard (5 required panels + cluster sanity panel)
- [ ] `voc-deploy monitoring` — deploy Prometheus + Grafana
- [ ] Confirm Prometheus scraping cluster metrics
- [ ] Build/verify dashboard panels:
  - [ ] Open vulnerabilities by severity over time
  - [ ] Mean time to remediate (MTTR)
  - [ ] SLA breach count
  - [ ] Top vulnerable assets
  - [ ] Scan coverage (% assets scanned in last 7 days)
- [ ] Export final dashboard JSON, commit to `k8s/monitoring/`
- [ ] Write DefectDojo metrics exporter (prometheus /metrics endpoint)

---

## 11. Stretch Goals

- [ ] Set up ArgoCD or Flux for GitOps deployment
- [ ] Add NetworkPolicies for namespace isolation
- [ ] Jira/GitLab issue auto-creation for remediation tracking
- [ ] Add CI pipeline (GitHub Actions) to lint/validate YAML on PR
- [ ] Add KEV (CISA Known Exploited Vulnerabilities) feed to prioritization service
- [ ] Add Cortex integration with TheHive

---

## 12. Documentation (ongoing)

- [x] `docs/architecture.md` — architecture + data flow + scoring formula
- [x] `docs/setup.md` — step-by-step for k3d + toolbox workflow
- [x] `docs/checklist.md` — this file
- [x] `etude_comparative.html` — tool selection rationale (7 components)
- [ ] Screenshot key dashboards/workflows for the final report
- [ ] Note any deviations from the original plan and why
