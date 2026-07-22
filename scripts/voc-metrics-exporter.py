#!/usr/bin/env python3
"""VOC Metrics Exporter — exposes DefectDojo findings as Prometheus metrics.

Runs as a lightweight HTTP server on :9091/metrics. Queries DefectDojo API
every POLL_INTERVAL seconds and exposes gauge metrics for Grafana dashboards.

Metrics exposed:
  voc_findings_total{severity,target,scanner}  - open finding count
  voc_findings_by_severity{severity}           - breakdown by severity
  voc_findings_by_scanner{scanner}             - breakdown by scanner
  voc_findings_by_target{target}               - breakdown by target
  voc_scan_last_timestamp                      - epoch of last scan
  voc_scan_last_duration_seconds               - duration of last scan
  voc_findings_mttr_days                       - mean time to remediate (30d window)

Environment variables:
  DD_URL          - DefectDojo base URL (default: http://defectdojo-django.voc-core.svc.cluster.local)
  DD_API_KEY      - DefectDojo API token
  POLL_INTERVAL   - seconds between polls (default: 60)
  EXPORTER_PORT   - HTTP port (default: 9091)
"""

from __future__ import annotations

import json
import os
import sys
import time
import threading
import urllib.request
import urllib.error
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler


DD_URL = os.environ.get("DD_URL", "http://defectdojo-django.voc-core.svc.cluster.local")
DD_API_KEY = os.environ.get("DD_API_KEY", "")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "60"))
EXPORTER_PORT = int(os.environ.get("EXPORTER_PORT", "9091"))

# Shared state
metrics_text = "# No data yet\n"
metrics_lock = threading.Lock()


def fetch_all_pages(path: str) -> list[dict]:
    """Fetch ALL pages of a DefectDojo API list endpoint."""
    if not DD_API_KEY:
        return []
    results: list[dict] = []
    url = f"{DD_URL}{path}"
    while url:
        req = urllib.request.Request(url, headers={
            "Authorization": f"Token {DD_API_KEY}",
            "Accept": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read())
        except Exception as e:
            print(f"[voc-exporter] Error fetching {path}: {e}", file=sys.stderr)
            break
        results.extend(data.get("results", []))
        # DRF pagination: "next" is a full URL pointing at the same host
        # we queried, so it can be followed directly. None when done.
        url = data.get("next") or None
    return results


def fetch_findings() -> list[dict]:
    """Fetch ALL active findings from DefectDojo API (paginated)."""
    return fetch_all_pages("/api/v2/findings/?active=true&limit=1000")


def fetch_test_tags() -> dict[int, list[str]]:
    """Fetch tests and map test id -> tags.

    Import-scan applies tags (e.g. "web,grype,juice-shop") to the TEST,
    not the individual findings — so scanner/target attribution must be
    read from the finding's parent test.
    """
    return {t["id"]: (t.get("tags") or []) for t in fetch_all_pages("/api/v2/tests/?limit=1000") if "id" in t}



def fetch_scan_status() -> dict:
    """Read scan status from the ConfigMap via K8s API (if available)."""
    # Try reading from local file first (mounted ConfigMap), then K8s API
    status_file = "/tmp/voc-scan-status.json"
    if os.path.exists(status_file):
        try:
            with open(status_file) as f:
                return json.load(f)
        except Exception:
            pass

    # Try K8s API
    token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    if os.path.exists(token_path):
        try:
            with open(token_path) as f:
                token = f.read().strip()
            url = "https://kubernetes.default.svc/api/v1/namespaces/scanning/configmaps/voc-scan-status"
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
            import ssl
            ctx = ssl.create_default_context()
            ctx.load_verify_locations("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
            with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
                cm = json.loads(resp.read())
                return json.loads(cm.get("data", {}).get("status.json", "{}"))
        except Exception:
            pass
    return {}


def build_metrics() -> str:
    """Build Prometheus text exposition format from DefectDojo data."""
    findings = fetch_findings()
    test_tags = fetch_test_tags()
    scan_status = fetch_scan_status()

    lines: list[str] = []

    # Severity breakdown
    by_severity: dict[str, int] = {"Critical": 0, "High": 0, "Medium": 0, "Low": 0, "Info": 0}
    by_scanner: dict[str, int] = {}
    by_target: dict[str, int] = {}

    scanners_set = {"nuclei", "sqlmap", "ffuf", "xss", "grype", "xsstrike", "crawler"}
    targets_set = {"juice-shop", "dvwa", "web-dvwa"}

    for f in findings:
        sev = f.get("severity", "Info")
        by_severity[sev] = by_severity.get(sev, 0) + 1

        # Tags live on the parent test (import-scan behavior) AND on the
        # finding itself — take the union so each finding is counted once
        # per tag even when both levels carry it.
        tags = set(test_tags.get(f.get("test"), [])) | set(f.get("tags") or [])
        for t in tags:
            if t in scanners_set:
                by_scanner[t] = by_scanner.get(t, 0) + 1
            if t in targets_set:
                by_target[t] = by_target.get(t, 0) + 1

    # MTTR calculation (30-day window)
    now = datetime.utcnow()
    thirty_days_ago = now - timedelta(days=30)
    closed_count = 0
    total_resolution_days = 0.0
    for f in findings:
        if f.get("is_mitigated") and f.get("mitigated"):
            try:
                created = datetime.fromisoformat(f.get("date", f.get("created", ""))[:19])
                mitigated = datetime.fromisoformat(f["mitigated"][:19])
                if mitigated > thirty_days_ago:
                    closed_count += 1
                    total_resolution_days += (mitigated - created).total_seconds() / 86400
            except (ValueError, TypeError):
                pass

    mttr = total_resolution_days / closed_count if closed_count > 0 else 0

    # Build text
    lines.append("# HELP voc_findings_by_severity Number of open findings by severity")
    lines.append("# TYPE voc_findings_by_severity gauge")
    for sev, count in by_severity.items():
        lines.append(f'voc_findings_by_severity{{severity="{sev}"}} {count}')

    lines.append("# HELP voc_findings_by_scanner Number of open findings by scanner")
    lines.append("# TYPE voc_findings_by_scanner gauge")
    for scanner, count in by_scanner.items():
        lines.append(f'voc_findings_by_scanner{{scanner="{scanner}"}} {count}')

    lines.append("# HELP voc_findings_by_target Number of open findings by target")
    lines.append("# TYPE voc_findings_by_target gauge")
    for target, count in by_target.items():
        lines.append(f'voc_findings_by_target{{target="{target}"}} {count}')

    lines.append("# HELP voc_findings_total Total open findings")
    lines.append("# TYPE voc_findings_total gauge")
    lines.append(f"voc_findings_total {len(findings)}")

    lines.append("# HELP voc_findings_critical_high Critical + High severity findings")
    lines.append("# TYPE voc_findings_critical_high gauge")
    lines.append(f"voc_findings_critical_high {by_severity.get('Critical', 0) + by_severity.get('High', 0)}")

    lines.append("# HELP voc_findings_mttr_days Mean Time To Remediate in days (30d window)")
    lines.append("# TYPE voc_findings_mttr_days gauge")
    lines.append(f"voc_findings_mttr_days {mttr:.1f}")

    # Scan status metrics
    if scan_status:
        lines.append("# HELP voc_scan_last_duration_seconds Duration of last scan in seconds")
        lines.append("# TYPE voc_scan_last_duration_seconds gauge")
        lines.append(f"voc_scan_last_duration_seconds {scan_status.get('duration_seconds', 0)}")

        ts = scan_status.get("timestamp", "")
        if ts:
            try:
                # Parse YYYYMMDD-HHMMSS
                dt = datetime.strptime(ts, "%Y%m%d-%H%M%S")
                epoch = dt.timestamp()
                lines.append("# HELP voc_scan_last_timestamp Epoch timestamp of last scan")
                lines.append("# TYPE voc_scan_last_timestamp gauge")
                lines.append(f"voc_scan_last_timestamp {epoch:.0f}")
            except ValueError:
                pass

    lines.append("")
    return "\n".join(lines)


def poll_loop():
    """Background thread that polls DefectDojo and updates metrics."""
    global metrics_text
    while True:
        try:
            text = build_metrics()
            with metrics_lock:
                metrics_text = text
        except Exception as e:
            print(f"[voc-exporter] Poll error: {e}", file=sys.stderr)
        time.sleep(POLL_INTERVAL)


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            with metrics_lock:
                body = metrics_text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Suppress default access logging
        pass


def main():
    if "--dry-run" in sys.argv:
        print(build_metrics())
        return

    print(f"[voc-exporter] Starting on :{EXPORTER_PORT} (poll interval: {POLL_INTERVAL}s)")
    print(f"[voc-exporter] DefectDojo URL: {DD_URL}")

    # Start background poller
    t = threading.Thread(target=poll_loop, daemon=True)
    t.start()

    server = HTTPServer(("0.0.0.0", EXPORTER_PORT), MetricsHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[voc-exporter] Shutting down.")
        server.shutdown()


if __name__ == "__main__":
    main()
