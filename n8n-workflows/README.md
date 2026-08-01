# n8n Workflows

This directory holds exported n8n workflow JSON, imported via the n8n UI
(**Workflows → ⋯ → Import from File**).

## `voc-master-dashboard.json`

The single, consolidated workflow for the entire VOC pipeline. It replaces the
old `scan-trigger.json` and `defectdojo-routing.json` with a unified dashboard.

### Features

| Feature | Description |
|---------|-------------|
| **Scan Triggers** | Nightly cron (02:00) + manual webhooks for full/quick scans |
| **Job Orchestration** | Creates K8s orchestrator Job, polls status until complete |
| **Dashboard API** | `GET /webhook/voc/dashboard` returns full findings summary |
| **Priority Routing** | Polls DefectDojo every 5 min, routes findings by priority tag |
| **Health Checks** | Pings all services every 5 min, stores status in workflow static data |
| **SIEM Ingest** | Receives Wazuh alerts (level 7+) and turns them into TheHive alerts |
| **Error Handling** | On scan failure, captures diagnostics and logs to execution history |

### Webhook Endpoints

After importing and activating the workflow in n8n:

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/webhook/voc/scan/full` | Start a full scan pipeline |
| `POST` | `/webhook/voc/scan/quick` | Start a quick scan (skip nuclei + xss) |
| `GET`  | `/webhook/voc/dashboard` | Get current findings summary + metrics |
| `POST` | `/webhook/voc/alert/wazuh` | SIEM ingest — called by the Wazuh manager, not by humans |

### SIEM ingest (`/webhook/voc/alert/wazuh`)

The Wazuh manager's `integrator` daemon POSTs every alert at level 7 or above
to this endpoint (there is no indexer to poll — see
`k8s/wazuh/wazuh-manager.yaml`). The payload is Wazuh's `shuffle` integration
format, so the full alert is under `all_fields`.

`Normalize Wazuh Alert` maps it onto TheHive: rule level 0-15 becomes severity
1-4 (7-9 → medium, 10-11 → high, 12+ → critical), rule groups and MITRE
technique IDs become tags, and source IP, agent hostname, tampered file path
and usernames become observables. `alert.id` is used as the `sourceRef`, so a
replayed alert dedupes instead of creating a second case.

Nothing to configure: the endpoint exists whenever the workflow is active, and
it is only reachable inside the cluster.

### Dashboard API Response

The `/webhook/voc/dashboard` endpoint returns:

```json
{
  "pipelineStatus": "operational",
  "findings": {
    "total": 42,
    "bySeverity": { "Critical": 3, "High": 12, "Medium": 18, "Low": 7, "Info": 2 },
    "byScanner": { "nuclei": 15, "sqlmap": 5, "grype": 20, "ffuf": 2 },
    "byTarget": { "juice-shop": 25, "dvwa": 17 },
    "byPriority": { "critical": 3, "high": 9, "medium": 18, "low": 12 }
  },
  "metrics": { "mttrDays": 4.2, "closedLast30d": 8, "scannerCount": 4, "targetCount": 2 },
  "topFindings": [ ... ],
  "scanHistory": [ ... ]
}
```

## Credentials to set up in n8n first

1. **DefectDojo API Key** — Create an HTTP Header Auth credential in n8n:
   - Name: `DefectDojo API`
   - Header Name: `Authorization`
   - Header Value: `Token <YOUR_DD_API_KEY>`
   - Used by all nodes that query the DefectDojo API.

2. **Kubernetes API** — The workflow uses the n8n pod's projected ServiceAccount
   token (automatically available when `serviceAccount.create: true` is set in
   `k8s/n8n/values.yaml`). If you prefer explicit auth, create an HTTP Header
   Auth credential with the SA token.

## Environment the workflow assumes

- DefectDojo reachable at `http://defectdojo-django.voc-core.svc.cluster.local`
- Prioritization service at `http://prioritization-service.voc-core.svc.cluster.local:8000`
- Targets at `juice-shop.targets:3000` and `dvwa.targets:80`
- `prioritization-service` has already tagged findings with `priority-NN`.

## Notification Channels

Notifications currently log to n8n's execution history (visible in the n8n UI
under Executions). To wire real alerts:

1. Replace the `Alert: Critical` / `Alert: High` Code nodes with HTTP Request
   nodes pointing to your Slack/Discord webhook URL.
2. Set the webhook URL as an n8n environment variable or credential.
