#!/usr/bin/env python3
"""VOC Scan History — SQLite storage for scan run metadata and finding counts.

Usage from scan-all.sh:
    python3 scripts/voc-db.py record \
        --db /workspace/scanners/voc-scans.db \
        --timestamp "$TIMESTAMP" \
        --duration "$DURATION" \
        --quick-mode "$QUICK_MODE" \
        --targets "juice-shop dvwa" \
        --counts "grype:75,nuclei:0,ffuf:509,sqlmap:0,xss:701" \
        --target-counts "juice-shop:grype:75:High,dvwa:grype:2097:Medium" \
        --reports-dir "/workspace/scanners/reports"

    python3 scripts/voc-db.py history --db /workspace/scanners/voc-scans.db
    python3 scripts/voc-db.py rotate  --db /workspace/scanners/voc-scans.db --keep 7
    python3 scripts/voc-db.py init    --db /workspace/scanners/voc-scans.db
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
from datetime import datetime
from pathlib import Path


DB_DEFAULT = "/workspace/scanners/voc-scans.db"

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS scan_runs (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp           TEXT    NOT NULL,
    started_at          TEXT,
    duration_seconds    INTEGER,
    quick_mode          BOOLEAN DEFAULT 0,
    targets             TEXT,       -- JSON array of target names
    grype_count         INTEGER DEFAULT 0,
    nuclei_count        INTEGER DEFAULT 0,
    ffuf_count          INTEGER DEFAULT 0,
    sqlmap_count        INTEGER DEFAULT 0,
    xss_count           INTEGER DEFAULT 0,
    total_findings      INTEGER DEFAULT 0,
    defectdojo_imported BOOLEAN DEFAULT 1,
    reports_dir         TEXT
);

CREATE TABLE IF NOT EXISTS finding_snapshots (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_run_id INTEGER NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    scanner     TEXT    NOT NULL,
    target      TEXT    NOT NULL,
    severity    TEXT,
    count       INTEGER DEFAULT 0
);

-- Individual findings store — replaces stacking JSON files.
-- Each row is one vulnerability finding from any scanner.
CREATE TABLE IF NOT EXISTS findings (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    scan_run_id         INTEGER REFERENCES scan_runs(id) ON DELETE CASCADE,
    scanner             TEXT    NOT NULL,     -- grype, nuclei, ffuf, sqlmap, xss, crawler
    target              TEXT    NOT NULL,     -- juice-shop, dvwa
    title               TEXT    NOT NULL,
    severity            TEXT    DEFAULT 'Info',
    cwe                 INTEGER,
    description         TEXT,
    impact              TEXT,
    mitigation          TEXT,
    param               TEXT,
    payload             TEXT,
    endpoints           TEXT,                 -- JSON array
    tags                TEXT,                 -- JSON array
    unique_id_from_tool TEXT,
    active              BOOLEAN DEFAULT 1,
    verified            BOOLEAN DEFAULT 0,
    date_found          TEXT,
    raw_json            TEXT                  -- full original finding dict for lossless storage
);

CREATE INDEX IF NOT EXISTS idx_snapshots_run ON finding_snapshots(scan_run_id);
CREATE INDEX IF NOT EXISTS idx_runs_ts ON scan_runs(timestamp);
CREATE INDEX IF NOT EXISTS idx_findings_run ON findings(scan_run_id);
CREATE INDEX IF NOT EXISTS idx_findings_scanner ON findings(scanner);
CREATE INDEX IF NOT EXISTS idx_findings_target ON findings(target);
CREATE INDEX IF NOT EXISTS idx_findings_severity ON findings(severity);
CREATE INDEX IF NOT EXISTS idx_findings_uid ON findings(unique_id_from_tool);
"""


def init_db(db_path: str) -> sqlite3.Connection:
    """Create/open the database and ensure tables exist."""
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    conn.executescript(SCHEMA_SQL)
    conn.commit()
    return conn


def record_scan_run(
    conn: sqlite3.Connection,
    timestamp: str,
    duration: int,
    quick_mode: bool,
    targets: list[str],
    counts: dict[str, int],
    reports_dir: str,
) -> int:
    """Insert a scan run record. Returns the new row id."""
    total = sum(counts.values())
    cur = conn.execute(
        """INSERT INTO scan_runs
           (timestamp, started_at, duration_seconds, quick_mode, targets,
            grype_count, nuclei_count, ffuf_count, sqlmap_count, xss_count,
            total_findings, defectdojo_imported, reports_dir)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)""",
        (
            timestamp,
            datetime.utcnow().isoformat(),
            duration,
            quick_mode,
            json.dumps(targets),
            counts.get("grype", 0),
            counts.get("nuclei", 0),
            counts.get("ffuf", 0),
            counts.get("sqlmap", 0),
            counts.get("xss", 0),
            total,
            reports_dir,
        ),
    )
    conn.commit()
    return cur.lastrowid


def record_findings(
    conn: sqlite3.Connection,
    scan_run_id: int,
    entries: list[dict],
) -> None:
    """Insert per-scanner/target/severity finding counts.

    Each entry: {"scanner": "grype", "target": "juice-shop", "severity": "High", "count": 42}
    """
    conn.executemany(
        """INSERT INTO finding_snapshots (scan_run_id, scanner, target, severity, count)
           VALUES (?, ?, ?, ?, ?)""",
        [(scan_run_id, e["scanner"], e["target"], e.get("severity", ""), e.get("count", 0)) for e in entries],
    )
    conn.commit()


def get_history(conn: sqlite3.Connection, limit: int = 10) -> list[dict]:
    """Return the last N scan runs as dicts."""
    cur = conn.execute(
        "SELECT * FROM scan_runs ORDER BY id DESC LIMIT ?", (limit,)
    )
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def get_run_detail(conn: sqlite3.Connection, run_id: int) -> dict | None:
    """Return a single run with its finding snapshots."""
    cur = conn.execute("SELECT * FROM scan_runs WHERE id = ?", (run_id,))
    cols = [d[0] for d in cur.description]
    row = cur.fetchone()
    if not row:
        return None
    run = dict(zip(cols, row))
    cur2 = conn.execute(
        "SELECT scanner, target, severity, count FROM finding_snapshots WHERE scan_run_id = ? ORDER BY scanner, target",
        (run_id,),
    )
    run["findings"] = [
        {"scanner": r[0], "target": r[1], "severity": r[2], "count": r[3]}
        for r in cur2.fetchall()
    ]
    return run


def rotate_reports(reports_dir: str, keep: int = 7, conn: sqlite3.Connection | None = None) -> int:
    """Delete report files from runs older than the Nth most recent.

    Uses timestamps embedded in filenames (YYYYMMDD-HHMMSS pattern) to group
    files by run. Returns the number of files deleted.
    """
    if not os.path.isdir(reports_dir):
        return 0

    # Discover all unique timestamps from filenames
    ts_pattern = re.compile(r"(\d{8}-\d{6})")
    timestamps: set[str] = set()
    for f in os.listdir(reports_dir):
        m = ts_pattern.search(f)
        if m:
            timestamps.add(m.group(1))

    if len(timestamps) <= keep:
        return 0  # Nothing to rotate

    # Sort descending, keep the newest `keep` timestamps
    sorted_ts = sorted(timestamps, reverse=True)
    old_ts = set(sorted_ts[keep:])

    deleted = 0
    for f in os.listdir(reports_dir):
        m = ts_pattern.search(f)
        if m and m.group(1) in old_ts:
            filepath = os.path.join(reports_dir, f)
            try:
                os.remove(filepath)
                deleted += 1
            except OSError:
                pass
    return deleted


def store_findings(
    conn: sqlite3.Connection,
    scan_run_id: int | None,
    scanner: str,
    target: str,
    findings_list: list[dict],
) -> int:
    """Bulk-insert normalized findings into the findings table.

    Each item in findings_list is a dict as produced by normalize-findings.py.
    Returns the number of rows inserted.
    """
    rows = []
    for f in findings_list:
        rows.append((
            scan_run_id,
            scanner,
            target,
            f.get("title", ""),
            f.get("severity", "Info"),
            f.get("cwe"),
            f.get("description", ""),
            f.get("impact", ""),
            f.get("mitigation", ""),
            f.get("param", ""),
            f.get("payload", ""),
            json.dumps(f.get("endpoints", [])),
            json.dumps(f.get("tags", [])),
            f.get("unique_id_from_tool", ""),
            f.get("active", True),
            f.get("verified", False),
            f.get("date", ""),
            json.dumps(f),  # raw_json: full original dict
        ))
    conn.executemany(
        """INSERT INTO findings
           (scan_run_id, scanner, target, title, severity, cwe,
            description, impact, mitigation, param, payload,
            endpoints, tags, unique_id_from_tool, active, verified,
            date_found, raw_json)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        rows,
    )
    conn.commit()
    return len(rows)


def get_findings(
    conn: sqlite3.Connection,
    scanner: str | None = None,
    target: str | None = None,
    severity: str | None = None,
    run_id: int | None = None,
    limit: int = 50,
) -> list[dict]:
    """Query findings with optional filters."""
    clauses = []
    params: list = []
    if scanner:
        clauses.append("scanner = ?")
        params.append(scanner)
    if target:
        clauses.append("target = ?")
        params.append(target)
    if severity:
        clauses.append("severity = ?")
        params.append(severity)
    if run_id is not None:
        clauses.append("scan_run_id = ?")
        params.append(run_id)
    where = (" WHERE " + " AND ".join(clauses)) if clauses else ""
    params.append(limit)
    cur = conn.execute(
        f"SELECT id, scan_run_id, scanner, target, title, severity, cwe, "
        f"param, payload, unique_id_from_tool, active, verified, date_found "
        f"FROM findings{where} ORDER BY id DESC LIMIT ?",
        params,
    )
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


def get_findings_summary(conn: sqlite3.Connection, run_id: int | None = None) -> list[dict]:
    """Return finding counts grouped by scanner+target+severity."""
    where = "WHERE scan_run_id = ? " if run_id else ""
    params: list = [run_id] if run_id else []
    cur = conn.execute(
        f"SELECT scanner, target, severity, COUNT(*) as count "
        f"FROM findings {where}"
        f"GROUP BY scanner, target, severity "
        f"ORDER BY scanner, target, severity",
        params,
    )
    cols = [d[0] for d in cur.description]
    return [dict(zip(cols, row)) for row in cur.fetchall()]


# ── CLI ─────────────────────────────────────────────────────────────

def cmd_init(args):
    db = init_db(args.db)
    db.close()
    print(f"Database initialized: {args.db}")


def cmd_record(args):
    db = init_db(args.db)

    # Parse counts: "grype:75,nuclei:0,ffuf:509"
    counts: dict[str, int] = {}
    if args.counts:
        for pair in args.counts.split(","):
            parts = pair.strip().split(":")
            if len(parts) == 2:
                counts[parts[0].strip()] = int(parts[1].strip())

    targets = args.targets.split() if args.targets else []
    quick = args.quick_mode in ("1", "true", "True", "yes")

    run_id = record_scan_run(
        db,
        timestamp=args.timestamp,
        duration=int(args.duration) if args.duration else 0,
        quick_mode=quick,
        targets=targets,
        counts=counts,
        reports_dir=args.reports_dir or "",
    )

    # Parse target-counts: "juice-shop:grype:75:High,dvwa:grype:2097:Medium"
    if args.target_counts:
        entries = []
        for item in args.target_counts.split(","):
            parts = item.strip().split(":")
            if len(parts) >= 3:
                entry = {
                    "target": parts[0],
                    "scanner": parts[1],
                    "count": int(parts[2]) if parts[2].isdigit() else 0,
                    "severity": parts[3] if len(parts) > 3 else "",
                }
                entries.append(entry)
        if entries:
            record_findings(db, run_id, entries)

    db.close()
    print(f"Scan run #{run_id} recorded (timestamp={args.timestamp})")


def cmd_history(args):
    db = init_db(args.db)
    limit = 999999 if args.all else (args.limit or 10)
    runs = get_history(db, limit)
    db.close()

    if not runs:
        print("No scan runs recorded yet.")
        return

    # Print table
    print(f"{'#':>4}  {'Timestamp':<17}  {'Dur':>5}  {'Mode':<5}  {'Grype':>5}  {'Nucl':>5}  {'ffuf':>5}  {'SQLm':>5}  {'XSS':>5}  {'Total':>6}")
    print("─" * 85)
    for r in runs:
        mode = "quick" if r["quick_mode"] else "full"
        dur = f"{r['duration_seconds'] // 60}m{r['duration_seconds'] % 60:02d}s" if r["duration_seconds"] else "---"
        print(
            f"{r['id']:>4}  {r['timestamp']:<17}  {dur:>5}  {mode:<5}  "
            f"{r['grype_count']:>5}  {r['nuclei_count']:>5}  {r['ffuf_count']:>5}  "
            f"{r['sqlmap_count']:>5}  {r['xss_count']:>5}  {r['total_findings']:>6}"
        )


def cmd_detail(args):
    db = init_db(args.db)
    run = get_run_detail(db, args.run_id)
    db.close()

    if not run:
        print(f"Run #{args.run_id} not found.")
        return

    print(f"Scan Run #{run['id']}")
    print(f"  Timestamp:  {run['timestamp']}")
    print(f"  Duration:   {run['duration_seconds']}s")
    print(f"  Mode:       {'quick' if run['quick_mode'] else 'full'}")
    print(f"  Targets:    {run['targets']}")
    print(f"  Reports:    {run['reports_dir']}")
    print(f"  Total:      {run['total_findings']} findings")
    print(f"  Counts:     grype={run['grype_count']} nuclei={run['nuclei_count']} "
          f"ffuf={run['ffuf_count']} sqlmap={run['sqlmap_count']} xss={run['xss_count']}")
    if run.get("findings"):
        print("\n  Per-scanner/target breakdown:")
        for f in run["findings"]:
            print(f"    {f['scanner']:<8} {f['target']:<15} {f['severity']:<8} {f['count']}")


def cmd_rotate(args):
    keep = args.keep or 7
    reports_dir = args.reports_dir or "/workspace/scanners/reports"
    deleted = rotate_reports(reports_dir, keep)
    print(f"Rotated {deleted} old report file(s) (keeping last {keep} runs)")


def cmd_store_findings(args):
    """Store findings from a normalized JSON file into SQLite."""
    db = init_db(args.db)
    json_path = Path(args.json_file)
    if not json_path.exists():
        print(f"File not found: {json_path}")
        return
    try:
        doc = json.loads(json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"Invalid JSON: {e}")
        return
    findings_list = doc.get("findings", [])
    if not findings_list:
        print(f"No findings in {json_path}")
        db.close()
        return
    run_id = int(args.run_id) if args.run_id else None
    count = store_findings(db, run_id, args.scanner, args.target, findings_list)
    db.close()
    print(f"Stored {count} {args.scanner} findings for {args.target} in SQLite")


def cmd_findings(args):
    """Query and display findings from SQLite."""
    db = init_db(args.db)

    if args.summary:
        rows = get_findings_summary(db, run_id=int(args.run) if args.run else None)
        db.close()
        if not rows:
            print("No findings stored yet.")
            return
        print(f"{'Scanner':<10} {'Target':<15} {'Severity':<10} {'Count':>6}")
        print("─" * 45)
        for r in rows:
            print(f"{r['scanner']:<10} {r['target']:<15} {r['severity']:<10} {r['count']:>6}")
        total = sum(r['count'] for r in rows)
        print(f"{'─' * 45}")
        print(f"{'TOTAL':<35} {total:>6}")
        return

    results = get_findings(
        db,
        scanner=args.scanner,
        target=args.target,
        severity=args.severity,
        run_id=int(args.run) if args.run else None,
        limit=int(args.limit) if args.limit else 50,
    )
    db.close()

    if not results:
        print("No findings match the query.")
        return

    for f in results:
        verified = "✓" if f["verified"] else " "
        print(
            f"  [{f['severity']:<8}] {f['scanner']:<8} {f['target']:<12} "
            f"{verified} {f['title'][:70]}"
        )
    print(f"\n  Showing {len(results)} finding(s)")


def main():
    parser = argparse.ArgumentParser(description="VOC Scan History Database")
    parser.add_argument("--db", default=DB_DEFAULT, help="Path to SQLite database file")
    sub = parser.add_subparsers(dest="command")

    # init
    sub.add_parser("init", help="Initialize database schema")

    # record
    rec = sub.add_parser("record", help="Record a scan run")
    rec.add_argument("--timestamp", required=True)
    rec.add_argument("--duration", default="0")
    rec.add_argument("--quick-mode", default="0")
    rec.add_argument("--targets", default="")
    rec.add_argument("--counts", default="")
    rec.add_argument("--target-counts", default="")
    rec.add_argument("--reports-dir", default="")

    # history
    hist = sub.add_parser("history", help="Show scan history")
    hist.add_argument("--all", action="store_true")
    hist.add_argument("--limit", type=int, default=10)

    # detail
    det = sub.add_parser("detail", help="Show details for a specific run")
    det.add_argument("run_id", type=int)

    # rotate
    rot = sub.add_parser("rotate", help="Rotate old report files")
    rot.add_argument("--keep", type=int, default=7)
    rot.add_argument("--reports-dir", default="/workspace/scanners/reports")

    # store-findings  (called by normalize-findings.py)
    sf = sub.add_parser("store-findings", help="Store findings from normalized JSON into SQLite")
    sf.add_argument("--json-file", required=True, help="Path to normalized JSON file")
    sf.add_argument("--scanner", required=True)
    sf.add_argument("--target", required=True)
    sf.add_argument("--run-id", default=None, help="Scan run ID to associate with")

    # findings  (query stored findings)
    fq = sub.add_parser("findings", help="Query stored findings")
    fq.add_argument("--scanner", default=None)
    fq.add_argument("--target", default=None)
    fq.add_argument("--severity", default=None)
    fq.add_argument("--run", default=None, help="Filter by scan run ID")
    fq.add_argument("--limit", default="50")
    fq.add_argument("--summary", action="store_true", help="Show count summary instead of individual findings")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return 1

    cmds = {
        "init": cmd_init,
        "record": cmd_record,
        "history": cmd_history,
        "detail": cmd_detail,
        "rotate": cmd_rotate,
        "store-findings": cmd_store_findings,
        "findings": cmd_findings,
    }
    cmds[args.command](args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
