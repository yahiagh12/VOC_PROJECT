# n8n workflows

This directory holds exported n8n workflow JSON, imported via the n8n UI
(**Workflows → ⋯ → Import from File**).

## `defectdojo-routing.json`

Polls DefectDojo for findings, branches on the `priority-NN` tag written by
the prioritization service, and:

- Critical/High (priority ≥ 60) → create a TheHive case + post a chat alert.
- Medium (priority 40–59) → chat alert only.
- Low/Info (priority < 40) → no alert (logged).

## Credentials to set up in n8n first

- **DefectDojo API key** — define an HTTP Header auth credential
  (`Authorization: Token <KEY>`) named `DefectDojo API`.
- **TheHive API key** — HTTP Header auth (`Authorization: Bearer <KEY>`)
  named `TheHive API`.
- **Slack/Discord webhook** — no n8n credential needed; the webhook URL goes
  in the HTTP Request node URL.

## Environment the workflow assumes

- DefectDojo reachable at `http://defectdojo-django-svc.voc-core.svc.cluster.local:8080`
- TheHive reachable at `http://thehive-svc.voc-core.svc.cluster.local:9000`
- `prioritization-service` has already tagged findings with `priority-NN`.

The exported JSON here is a scaffold — refine nodes/URLs in the n8n UI after
import, then re-export the working version back into this file.
