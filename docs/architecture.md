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
| Prioritization   | prioritization-service    | voc-core     | FastAPI: (CVSS + EPSS + KEV) x asset context |
| Scanning         | Grype / Nuclei / sqlmap / ffuf / XSStrike | scanning | Jobs that publish to DefectDojo |
| SIEM *(opt-in)*  | Wazuh manager             | voc-core     | HIDS + rules engine, API-only (no indexer/dashboard) |
| Monitoring *(opt-in)* | kube-prometheus-stack | monitoring  | Prometheus + Grafana — **disabled by default**, see below |
| Targets          | Juice Shop, DVWA          | targets      | Intentionally vulnerable lab apps      |

Both opt-in components are off unless `VOC_ENABLE_WAZUH=1` /
`VOC_ENABLE_MONITORING=1` is set, or they are deployed explicitly with
`voc-deploy wazuh` / `voc-deploy monitoring`. Grafana was disabled because it
duplicated what DefectDojo and the n8n dashboard already show while costing
~2 GB of RAM and a PVC; nothing was deleted, and `voc-deploy no-monitoring`
tears it back down.

## Data flow

1. **Scan** — CronJobs in `scanning` namespace run Grype (image), ZAP (DAST
   against Juice Shop), and Nuclei (DAST against all targets) on a schedule.
   Each job writes a JSON report to an output volume and calls the DefectDojo
   `import-scan` REST API with the right parser type.

2. **Ingest** — DefectDojo stores findings, deduplicates, and exposes them via
   its REST API. Each scan run is a distinct `Test` under an `Engagement`.

3. **Prioritize** — `prioritization-service` (FastAPI) pulls findings from
   DefectDojo, looks up EPSS scores by CVE from the FIRST.org API and checks
   the CISA KEV catalogue, resolves each finding onto an asset from the
   inventory, and writes back a 0-100 priority as a tag (`priority-87`), the
   `risk_score` field, a recomputed `severity`, and context tags
   (`voc-asset-*`, `voc-exposure-*`, `voc-crit-*`, `voc-internet-facing`) so
   both the UI and n8n can filter on it.

4. **Route** — n8n polls DefectDojo for findings with `priority >= threshold`
   (or Critical/High severity). Branching logic:
   - Critical/High + high priority -> create TheHive case + alert channel.
   - Medium -> alert channel only.
   - Low/Info -> logged, no alert.

5. **Track** — TheHive cases hold the remediation workflow; status flows back
   manually or (stretch) via Jira/GitLab integration.

6. **Report** — the n8n master dashboard reads DefectDojo directly. Grafana +
   Prometheus remain available for cluster metrics (`voc-deploy monitoring`)
   but are not deployed by default.

## Priority score formula

```
priority = clamp( base x context , 0 , 100 )

  base    = 100 x (CVSS_WEIGHT x technical + EPSS_WEIGHT x threat)
                  / (CVSS_WEIGHT + EPSS_WEIGHT)

  technical = CVSS / 10                     ... or the scanner's severity
                                                word mapped onto a CVSS
                                                (Critical 9.5 ... Info 1.0)
                                                when no CVSS exists

  threat    = 1.0                           if the CVE is in CISA KEV
            = max(EPSS_percentile,          otherwise
                  sqrt(EPSS_probability))
            = 0.15                          if there is no EPSS data at all

  context = MIN_MULT + (MAX_MULT - MIN_MULT) x C
      C   = (EXPOSURE_WEIGHT x exposure
           + CRITICALITY_WEIGHT x criticality
           + DATA_WEIGHT x data_class) / sum(weights)
```

Defaults: `CVSS_WEIGHT=EPSS_WEIGHT=0.5`,
`EXPOSURE_WEIGHT=CRITICALITY_WEIGHT=0.4`, `DATA_WEIGHT=0.2`,
`CONTEXT_MIN_MULTIPLIER=0.5`, `CONTEXT_MAX_MULTIPLIER=1.6`.

Why each piece is shaped the way it is:

- **Severity fallback.** Nuclei / sqlmap / ffuf / XSStrike findings have a
  severity word and no CVSS. Without the fallback they scored 0 and were
  dropped from prioritisation entirely — i.e. every web finding.
- **sqrt(EPSS).** Raw EPSS probabilities are tiny (median ≈ 0.0005), so using
  them directly flattens the threat term to zero for nearly everything. The
  square root lifts small-but-real probabilities into a usable range
  (1% → 0.10, 25% → 0.50, 90% → 0.95) without inventing signal.
- **KEV as a floor, not a weight.** KEV is not a prediction — it records
  exploitation that already happened. It pins the threat term to 1.0 and the
  final priority to at least `KEV_PRIORITY_FLOOR` (70), so a low-value asset
  cannot bury an actively-exploited bug.
- **Context as a multiplier with a wide range.** The `[0.5, 1.6]` spread is
  what lets a MEDIUM on an internet-facing crown jewel outrank a HIGH on a
  throwaway internal box. Narrow it toward `1.0` to make context advisory;
  set both ends to `1.0` to disable it.

Bands: `>=80` critical, `>=60` high, `>=40` medium, `>=20` low, else info.

Business context lives in `prioritization-service/asset-inventory.yaml`
(mounted as the `voc-asset-inventory` ConfigMap): per asset, an internet
exposure level, a business criticality 1-5, a data classification, an owner,
and the aliases used to match findings onto it (scanner tags first, then
endpoint hostnames, then title/description).

Degradation is deliberate: a missing inventory, an unreachable EPSS API or an
unreachable KEV feed each reduce the model to the terms it still has, log a
note, and keep scoring. Findings with neither a technical score nor threat
data are marked `no-scoreable-data` and left alone rather than given a
confident-looking number.

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
