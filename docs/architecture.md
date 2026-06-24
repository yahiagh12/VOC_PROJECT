# Architecture

## Goal

A single-node k3s cluster (running inside WSL2 Ubuntu on the host PC) that runs
an end-to-end vulnerability operations pipeline: scan → ingest → prioritize →
route → track → report. All components are open-source community editions.

## Components

| Layer            | Component                 | Namespace    | Role                                   |
|------------------|---------------------------|--------------|----------------------------------------|
| Findings store   | DefectDojo                | voc-core     | Central API + UI for all findings      |
| Workflow engine  | n8n (self-hosted)         | voc-core     | Polls findings, branches, notifies     |
| Case management  | TheHive Community Edition | voc-core     | Auto-creates cases for Critical/High   |
| Prioritization   | prioritization-service    | voc-core     | FastAPI: CVSS + EPSS -> priority score |
| Scanning         | Grype / ZAP / Nuclei      | scanning     | CronJobs that publish to DefectDojo    |
| Monitoring       | kube-prometheus-stack     | monitoring   | Prometheus + Grafana                   |
| Targets          | Juice Shop, DVWA          | targets      | Intentionally vulnerable lab apps      |

## Data flow

1. **Scan** — CronJobs in `scanning` namespace run Grype (image), ZAP (DAST
   against Juice Shop), and Nuclei (DAST against all targets) on a schedule.
   Each job writes a JSON report to an output volume and calls the DefectDojo
   `import-scan` REST API with the right parser type.

2. **Ingest** — DefectDojo stores findings, deduplicates, and exposes them via
   its REST API. Each scan run is a distinct `Test` under an `Engagement`.

3. **Prioritize** — `prioritization-service` (FastAPI) pulls findings from
   DefectDojo, looks up EPSS scores by CVE from the FIRST.org API, blends
   CVSS + EPSS into a 0-100 priority score, and writes the score back to
   DefectDojo as a tag (`priority=87`) so it is visible in the UI and
   queryable by n8n.

4. **Route** — n8n polls DefectDojo for findings with `priority >= threshold`
   (or Critical/High severity). Branching logic:
   - Critical/High + high priority -> create TheHive case + alert channel.
   - Medium -> alert channel only.
   - Low/Info -> logged, no alert.

5. **Track** — TheHive cases hold the remediation workflow; status flows back
   manually or (stretch) via Jira/GitLab integration.

6. **Report** — Grafana dashboards read from Prometheus (cluster metrics) and
   from DefectDojo (via a simple exporter or direct Postgres queries, TBD):
   - Open vulnerabilities by severity over time
   - Mean time to remediate (MTTR)
   - SLA breach count
   - Top vulnerable assets
   - Scan coverage (% assets scanned in last 7 days)

## Priority score formula (initial, tunable)

```
priority = round( 0.5 * (CVSS / 10 * 100) + 0.5 * (EPSS_percentile * 100) )
```

- CVSS v3.x base score (0-10) normalized to 0-100.
- EPSS percentile (0-1) scaled to 0-100.
- Weights 50/50 initially; expose `CVSS_WEIGHT` / `EPSS_WEIGHT` env vars to tune.
- If EPSS lookup fails, fall back to CVSS-only with a warning logged.

## Networking

- Single-node k3s with its embedded Traefik ingress.
- WSL2 port-forwarding exposes cluster ports to the Windows host on `localhost`.
- Tailscale (optional, later) exposes UIs to the second teammate's laptop
  without opening firewall ports.
- Intra-cluster: scanners reach `targets` services via `<svc>.targets.svc.cluster.local`.

## Security notes

- Lab targets (Juice Shop, DVWA) must NEVER be exposed outside the cluster.
- DefectDojo/n8n/TheHive admin passwords changed on first login, stored in a
  team password manager (not git).
- NetworkPolicies (stretch goal) will isolate `targets` so only `scanning` and
  `voc-core` can reach them.
- k3s uses embedded containerd; Docker Desktop is only for local image builds.

## Known constraints (WSL2 host)

- WSL2 is not truly "always-on" — it suspends when the Windows session locks.
  For the PFA demo this is acceptable. If 24/7 uptime is needed later, migrate
  the cluster to a dedicated Linux box or cheap VPS and repoint kubeconfig.
- Resource ceiling = this PC's RAM/CPU minus Windows overhead. DefectDojo +
  TheHive + Prometheus together are the heaviest; may need to drop OpenVAS
  (stretch) if RAM is tight.
