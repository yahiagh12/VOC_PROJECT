#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: voc-test-tool <tool> <target>"
  echo "Example: voc-test-tool sqlmap dvwa"
  echo "         voc-test-tool ffuf juice-shop"
  echo "Supported tools: sqlmap, ffuf, xss, nuclei"
  exit 1
fi

TOOL="$1"
TARGET_SHORT="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNERS_DIR="$(dirname "$SCRIPT_DIR")/scanners"
REPORTS_DIR="/workspace/scanners/reports"
TIMESTAMP="testrun"
GENERIC_SCAN_TYPE="Generic Findings Import"

# Load .env
if [ -f "$(dirname "$SCRIPT_DIR")/.env" ]; then
  set -a; . "$(dirname "$SCRIPT_DIR")/.env"; set +a
fi

DD_API_KEY="${DD_API_KEY:-}"
DD_URL="http://localhost:8080"
DD_PRODUCT_NAME="${DD_PRODUCT_NAME:-Lab Targets}"
DD_ENGAGEMENT_NAME="${DD_ENGAGEMENT_NAME:-Continuous Scanning}"

# --- Setup Colors & Logging ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Find latest URL lists from previous scan ---
ALL_URLS=$(ls -1t "$REPORTS_DIR"/all_urls_${TARGET_SHORT}_*.txt 2>/dev/null | head -n1 || true)
PARAM_URLS=$(ls -1t "$REPORTS_DIR"/param_urls_${TARGET_SHORT}_*.txt 2>/dev/null | head -n1 || true)

if [ -z "$ALL_URLS" ] || [ -z "$PARAM_URLS" ]; then
  log_error "Could not find previous all_urls.txt or param_urls.txt for $TARGET_SHORT in $REPORTS_DIR."
  log_error "Please run 'voc-scan' at least once to generate the URL inventory."
  exit 1
fi

log_info "Using URL inventory from previous scan:"
log_info "  all_urls: $(basename "$ALL_URLS")"
log_info "  param_urls: $(basename "$PARAM_URLS")"

# --- Merge Seeds (if they exist) ---
MERGED_ALL=$(mktemp)
MERGED_PARAM=$(mktemp)

cp "$ALL_URLS" "$MERGED_ALL"
cp "$PARAM_URLS" "$MERGED_PARAM"

SEED_URLS="$SCANNERS_DIR/seed-urls.${TARGET_SHORT}.txt"
if [ -f "$SEED_URLS" ]; then
  grep -vE '^\s*(#|$)' "$SEED_URLS" >> "$MERGED_ALL" 2>/dev/null || true
  sort -u -o "$MERGED_ALL" "$MERGED_ALL"
fi

SEED_PARAMS="$SCANNERS_DIR/seed-params.${TARGET_SHORT}.txt"
if [ -f "$SEED_PARAMS" ]; then
  # scan-all.sh only uses seed-params if param_urls is empty, but for testing we can just append and dedup
  grep -vE '^\s*(#|$)' "$SEED_PARAMS" >> "$MERGED_PARAM" 2>/dev/null || true
  sort -u -o "$MERGED_PARAM" "$MERGED_PARAM"
fi

# --- Recreate ConfigMap ---
CM_NAME="voc-targets-${TARGET_SHORT}-test"
kubectl delete configmap "$CM_NAME" -n scanning --ignore-not-found >/dev/null 2>&1
kubectl create configmap "$CM_NAME" -n scanning \
  --from-file=all_urls.txt="$MERGED_ALL" \
  --from-file=param_urls.txt="$MERGED_PARAM" >/dev/null 2>&1
log_success "Created ConfigMap $CM_NAME"

rm -f "$MERGED_ALL" "$MERGED_PARAM"

# --- Determine Target URL ---
if [ "$TARGET_SHORT" = "dvwa" ]; then
  TARGET_URL="http://dvwa.targets.svc.cluster.local:80"
elif [ "$TARGET_SHORT" = "juice-shop" ]; then
  TARGET_URL="http://juice-shop.targets.svc.cluster.local:3000"
else
  TARGET_URL="http://${TARGET_SHORT}.targets.svc.cluster.local"
fi

# --- Authenticate if DVWA ---
AUTH_COOKIE=""
if [ "$TARGET_SHORT" = "dvwa" ]; then
  log_info "Authenticating to DVWA..."
  AUTH_JOB="auth-dvwa-test"
  AUTH_RAW="$REPORTS_DIR/auth_dvwa_test.txt"
  
  kubectl delete job "$AUTH_JOB" -n scanning --ignore-not-found >/dev/null 2>&1
  content="$(cat "$SCANNERS_DIR/dvwa-auth-job.yaml")"
  content="${content//__JOB_NAME__/$AUTH_JOB}"
  content="${content//__TARGET_URL__/$TARGET_URL}"
  printf '%s' "$content" | kubectl apply -f - >/dev/null 2>&1
  
  kubectl wait --for=condition=complete "job/$AUTH_JOB" -n scanning --timeout=120s >/dev/null 2>&1 || true
  
  pod=$(kubectl get pods -n scanning -l "job-name=$AUTH_JOB" --no-headers -o name 2>/dev/null | head -1)
  if [ -n "$pod" ]; then
    kubectl logs -n scanning "${pod#pod/}" 2>/dev/null \
      | sed -n "/===AUTH_RESULTS_START===/,/===AUTH_RESULTS_END===/{ /===AUTH_RESULTS/d; p; }" \
      > "$AUTH_RAW"
      
    if [ -s "$AUTH_RAW" ]; then
      AUTH_COOKIE=$(cat "$AUTH_RAW" | tr -d '\r' | head -n1)
      log_success "DVWA authenticated (cookie obtained)"
    fi
  fi
  kubectl delete job "$AUTH_JOB" -n scanning --ignore-not-found >/dev/null 2>&1
fi

# --- Run the Tool ---
JOB_NAME="${TOOL}-${TARGET_SHORT}-test"
RAW_OUT="$REPORTS_DIR/${TOOL}_${TARGET_SHORT}_test.raw"
JSON_OUT="$REPORTS_DIR/${TOOL}_${TARGET_SHORT}_test.json"
DEBUG_LOG="$REPORTS_DIR/${TOOL}_${TARGET_SHORT}_test_debug.log"
TEMPLATE="$SCANNERS_DIR/${TOOL}-job.yaml"

if [ "$TOOL" = "nuclei" ]; then
  TEMPLATE="$SCANNERS_DIR/nuclei-phase2-job.yaml"
fi

if [ ! -f "$TEMPLATE" ]; then
  log_error "Template $TEMPLATE not found!"
  exit 1
fi

log_info "Running $TOOL -> $TARGET_SHORT (job: $JOB_NAME)"
kubectl delete job "$JOB_NAME" -n scanning --ignore-not-found >/dev/null 2>&1

content="$(cat "$TEMPLATE")"
content="${content//__JOB_NAME__/$JOB_NAME}"
content="${content//__TARGETS_CM__/$CM_NAME}"
content="${content//__TARGET_URL__/$TARGET_URL}"
content="${content//__COOKIE__/$AUTH_COOKIE}"
printf '%s' "$content" | kubectl apply -f - >/dev/null 2>&1

# Wait for job
log_info "Waiting for job to complete (tailing logs in background)..."
sleep 3
pod=$(kubectl get pods -n scanning -l "job-name=$JOB_NAME" --no-headers -o name 2>/dev/null | head -1)
if [ -n "$pod" ]; then
  # Show live logs so you can see what's happening
  kubectl logs -n scanning -f "${pod#pod/}" || true
fi

# Make sure job actually finished
kubectl wait --for=condition=complete "job/$JOB_NAME" -n scanning --timeout=600s >/dev/null 2>&1 || true

# Extract marker results
MARKER=$(echo "$TOOL" | tr '[:lower:]' '[:upper:]')
pod=$(kubectl get pods -n scanning -l "job-name=$JOB_NAME" --no-headers -o name 2>/dev/null | head -1)
if [ -n "$pod" ]; then
  kubectl logs -n scanning "${pod#pod/}" > "$DEBUG_LOG" 2>/dev/null || true
  
  if [ "$TOOL" = "nuclei" ]; then
     kubectl logs -n scanning "${pod#pod/}" -c nuclei 2>/dev/null \
        | sed -n '/===NUCLEI_RESULTS_START===/,/===NUCLEI_RESULTS_END===/{ /===NUCLEI_RESULTS/d; p; }' \
        | grep '^{' | jq -s '.' > "$JSON_OUT" 2>/dev/null || echo '[]' > "$JSON_OUT"
  else
    kubectl logs -n scanning "${pod#pod/}" 2>/dev/null \
      | sed -n "/===${MARKER}_RESULTS_START===/,/===${MARKER}_RESULTS_END===/{ /===${MARKER}_RESULTS/d; p; }" \
      > "$RAW_OUT"
      
    if [ -s "$RAW_OUT" ]; then
      log_info "Normalizing findings..."
      python3 "$SCRIPT_DIR/normalize-findings.py" "$TOOL" "$RAW_OUT" "$JSON_OUT" "$TARGET_SHORT" >/dev/null 2>&1 || true
    fi
  fi
fi

if [ -f "$JSON_OUT" ]; then
  count=$(jq '.findings | length' "$JSON_OUT" 2>/dev/null || jq 'length' "$JSON_OUT" 2>/dev/null || echo "0")
  log_success "Scan complete! Found $count findings."
  log_info "Results saved to: $JSON_OUT"
else
  log_error "Failed to generate $JSON_OUT. Check $DEBUG_LOG for errors."
fi

# Cleanup
kubectl delete job "$JOB_NAME" -n scanning --ignore-not-found >/dev/null 2>&1
kubectl delete configmap "$CM_NAME" -n scanning --ignore-not-found >/dev/null 2>&1

log_info "You can view the normalized JSON output with:"
echo "cat $JSON_OUT | jq '.findings[].title'"
