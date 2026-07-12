#!/bin/bash
# VOC Scan History — query the SQLite scan history database.
#
# Usage:
#   voc-history                       # last 10 runs
#   voc-history --all                 # all runs
#   voc-history --run 5               # details for run #5
#   voc-history --limit 20            # last 20 runs
#   voc-history --findings            # all findings (last 50)
#   voc-history --findings --summary  # finding counts by scanner/target/severity
#   voc-history --findings --scanner grype        # filter by scanner
#   voc-history --findings --severity High        # filter by severity
#   voc-history --findings --target juice-shop    # filter by target

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${VOC_DB:-/workspace/scanners/voc-scans.db}"

if [ ! -f "$DB" ]; then
  echo "No scan history database found at $DB"
  echo "Run voc-scan to create it."
  exit 1
fi

# Check if --findings flag is present
if echo "$@" | grep -q '\-\-findings'; then
  # Strip --findings from args and pass rest to voc-db.py findings
  ARGS=$(echo "$@" | sed 's/--findings//')
  python3 "$SCRIPT_DIR/voc-db.py" --db "$DB" findings $ARGS
elif [ "${1:-}" = "--run" ] && [ -n "${2:-}" ]; then
  python3 "$SCRIPT_DIR/voc-db.py" --db "$DB" detail "$2"
elif [ "${1:-}" = "--all" ]; then
  python3 "$SCRIPT_DIR/voc-db.py" --db "$DB" history --all
elif [ "${1:-}" = "--limit" ] && [ -n "${2:-}" ]; then
  python3 "$SCRIPT_DIR/voc-db.py" --db "$DB" history --limit "$2"
else
  python3 "$SCRIPT_DIR/voc-db.py" --db "$DB" history
fi
