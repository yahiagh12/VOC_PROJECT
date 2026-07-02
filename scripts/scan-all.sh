#!/bin/bash
set -euo pipefail

# ============================================================
# VOC - Scan Pipeline (k8s-native)
# Runs Grype + Nuclei + ZAP as Kubernetes Jobs and imports
# results to DefectDojo via the port-forwarded API.
# Designed to run inside the VOC toolbox container.
#
# Caching strategy (so nothing re-downloads every run):
#   - Grype vuln DB:  Docker named volume "voc-grype-db"
#   - Nuclei templates: baked into container image (pulled once by k3d)
#   - Scanner images:  cached on k3d node after first pull
# ============================================================

# --- Configuration (from .env or env vars) ---
DD_API_KEY="${DD_API_KEY:?ERROR: DD_API_KEY is required (set in .env)}"
DD_URL="http://localhost:8080"
DD_PRODUCT_NAME="${DD_PRODUCT_NAME:-Lab Targets}"
DD_ENGAGEMENT_NAME="${DD_ENGAGEMENT_NAME:-Continuous Scanning}"
DD_ENGAGEMENT_ID="${DD_ENGAGEMENT_ID:-}"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
REPORTS_DIR="/workspace/scanners/reports"

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Helper: upload to DefectDojo (with retry for 5xx/000) ---
dd_import() {
  local file="$1" scan_type="$2" tags="$3"
  local max_retries=3 attempt=1

  while [ "$attempt" -le "$max_retries" ]; do
    local response_file curl_err
    response_file=$(mktemp)
    curl_err=$(mktemp)

    # Build curl args as an array to avoid shell quoting issues
    local -a curl_args=(
      -sS -X POST "$DD_URL/api/v2/reimport-scan/"
      -H "Authorization: Token $DD_API_KEY"
      -F "scan_type=$scan_type"
      -F "test_title=$scan_type"
      -F "file=@$file"
      -F "tags=$tags"
      --max-time 600
      --retry 2
      --retry-delay 5
    )

    if [ -n "$DD_ENGAGEMENT_ID" ]; then
      curl_args+=(-F "engagement=$DD_ENGAGEMENT_ID")
    else
      curl_args+=(-F "product_name=$DD_PRODUCT_NAME")
      curl_args+=(-F "engagement_name=$DD_ENGAGEMENT_NAME")
      curl_args+=(-F "auto_create_context=true")
      curl_args+=(-F "product_type_name=Research")
    fi

    local code
    code=$(curl "${curl_args[@]}" -o "$response_file" -w "%{http_code}" 2>"$curl_err") || code="000"

    if [ "$code" = "201" ] || [ "$code" = "200" ]; then
      log_success "Imported to DefectDojo (HTTP $code)"
      rm -f "$response_file" "$curl_err"
      return 0
    elif [ "${code:0:1}" = "5" ] || [ "$code" = "000" ]; then
      if [ "$attempt" -lt "$max_retries" ]; then
        log_warning "DefectDojo returned HTTP $code — retrying in 15s (attempt $attempt/$max_retries)"
        [ "$code" = "000" ] && log_warning "Curl error: $(cat "$curl_err" 2>/dev/null)"
        rm -f "$response_file" "$curl_err"
        sleep 15
        attempt=$((attempt + 1))
      else
        log_error "DefectDojo upload failed (HTTP $code) after $max_retries attempts"
        [ "$code" = "000" ] && log_error "Curl error: $(cat "$curl_err" 2>/dev/null)"
        head -c 500 "$response_file" 2>/dev/null | sed 's/^/  > /' || true
        echo ""
        rm -f "$response_file" "$curl_err"
        return 1
      fi
    else
      log_error "DefectDojo upload failed (HTTP $code)"
      head -c 500 "$response_file" 2>/dev/null | sed 's/^/  > /' || true
      echo ""
      rm -f "$response_file" "$curl_err"
      return 1
    fi
  done
}

# --- Prep ---
mkdir -p "$REPORTS_DIR"

# --- Step 0: Check DefectDojo reachability ---
log_info "=== Step 0: Checking DefectDojo API ==="
DD_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Token $DD_API_KEY" "$DD_URL/api/v2/findings/?limit=1" 2>/dev/null) || DD_HTTP="000"
if [ "$DD_HTTP" = "200" ]; then
  log_success "DefectDojo API is reachable and authenticated"
elif [ "$DD_HTTP" = "403" ]; then
  log_error "DefectDojo returned 403 Forbidden. Check DD_API_KEY in .env"
  exit 1
else
  log_error "Cannot reach DefectDojo API (HTTP $DD_HTTP). Is port-forward running on 8080?"
  exit 1
fi

# --- Step 1: Check targets are running ---
log_info "=== Step 1: Checking scan targets ==="
JUICE_READY=$(kubectl get pods -n targets -l app=juice-shop --no-headers 2>/dev/null | grep Running | wc -l)
DVWA_READY=$(kubectl get pods -n targets -l app=dvwa --no-headers 2>/dev/null | grep Running | wc -l)
[ "$JUICE_READY" -gt 0 ] && log_success "Juice Shop is running" || log_warning "Juice Shop not running"
[ "$DVWA_READY" -gt 0 ] && log_success "DVWA is running" || log_warning "DVWA not running"

# ============================================================
# Step 2: Grype SCA scan (Docker-based, DB cached in volume)
# ============================================================
log_info "=== Step 2: Grype SCA scan ==="

for GRYPE_IMAGE in "bkimminich/juice-shop:latest" "vulnerables/web-dvwa:latest"; do
  IMAGE_SHORT=$(echo "$GRYPE_IMAGE" | sed 's|.*/||; s|:.*||')
  GRYPE_REPORT="$REPORTS_DIR/grype_${IMAGE_SHORT}_$TIMESTAMP.json"

  log_info "Grype -> $GRYPE_IMAGE (via Docker)"

  # "voc-grype-db" is a Docker named volume that persists the Grype
  # vulnerability database (~100 MB). First run downloads it; subsequent
  # runs reuse the cached copy (saves 30-60 s per run).
  if docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v voc-grype-db:/root/.cache/grype \
    anchore/grype:latest "$GRYPE_IMAGE" -o json > "$GRYPE_REPORT" 2>/dev/null; then

    if [ -s "$GRYPE_REPORT" ]; then
      FINDING_COUNT=$(jq '.matches | length' "$GRYPE_REPORT" 2>/dev/null || echo "?")
      log_success "Grype found $FINDING_COUNT vulnerabilities in $IMAGE_SHORT"
      dd_import "$GRYPE_REPORT" "Anchore Grype" "container,grype,$IMAGE_SHORT"
    else
      log_warning "Grype report is empty for $IMAGE_SHORT"
    fi
  else
    log_error "Grype scan failed for $IMAGE_SHORT"
  fi
done

# --- Helper: wait for a k8s Job to complete or fail, with diagnostics ---
wait_for_job() {
  local job_name="$1" namespace="$2" timeout_sec="$3" label="$4"
  local elapsed=0 interval=5

  while [ "$elapsed" -lt "$timeout_sec" ]; do
    # Check for success
    if kubectl wait --for=condition=complete "job/$job_name" -n "$namespace" --timeout=0s 2>/dev/null; then
      return 0
    fi
    # Check for failure (OOM, crash, deadline exceeded, etc.)
    if kubectl wait --for=condition=failed "job/$job_name" -n "$namespace" --timeout=0s 2>/dev/null; then
      log_error "$label FAILED. Diagnostics:"
      local pod
      pod=$(kubectl get pods -n "$namespace" -l "job-name=$job_name" --no-headers -o name 2>/dev/null | head -1)
      if [ -n "$pod" ]; then
        echo "  --- Pod status ---"
        kubectl get pods -n "$namespace" -l "job-name=$job_name" --no-headers 2>/dev/null | sed 's/^/  /'
        echo "  --- Last 30 log lines ---"
        kubectl logs -n "$namespace" "${pod#pod/}" --tail=30 2>/dev/null | sed 's/^/  /' || true
      fi
      return 1
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  # Timed out — show diagnostics
  log_error "$label timed out after ${timeout_sec}s. Diagnostics:"
  local pod
  pod=$(kubectl get pods -n "$namespace" -l "job-name=$job_name" --no-headers -o name 2>/dev/null | head -1)
  if [ -n "$pod" ]; then
    echo "  --- Pod status ---"
    kubectl get pods -n "$namespace" -l "job-name=$job_name" --no-headers 2>/dev/null | sed 's/^/  /'
    echo "  --- Last 30 log lines ---"
    kubectl logs -n "$namespace" "${pod#pod/}" --tail=30 2>/dev/null | sed 's/^/  /' || true
  fi
  return 1
}

# --- Helper: extract Nuclei results from a completed job ---
extract_nuclei_results() {
  local job_name="$1" target_short="$2"
  local nuclei_report="$REPORTS_DIR/nuclei_${target_short}_$TIMESTAMP.json"
  local nuclei_log="$REPORTS_DIR/nuclei_${target_short}_${TIMESTAMP}_debug.log"

  local nuclei_pod
  nuclei_pod=$(kubectl get pods -n scanning -l "job-name=$job_name" --no-headers -o name 2>/dev/null | head -1)
  local pod_name="${nuclei_pod#pod/}"

  kubectl logs -n scanning "$pod_name" > "$nuclei_log" 2>/dev/null || true
  log_info "Full Nuclei logs saved to $nuclei_log"

  # Extract JSONL results from between markers, convert to JSON array
  sed -n '/===NUCLEI_RESULTS_START===/,/===NUCLEI_RESULTS_END===/{ /===NUCLEI_RESULTS/d; p; }' "$nuclei_log" \
    | grep '^{' \
    | jq -s '.' > "$nuclei_report" 2>/dev/null || true

  if [ -s "$nuclei_report" ] && [ "$(cat "$nuclei_report" 2>/dev/null)" != "[]" ]; then
    local count
    count=$(jq 'length' "$nuclei_report" 2>/dev/null || echo "?")
    log_success "Nuclei found $count findings for $target_short"
    dd_import "$nuclei_report" "Nuclei Scan" "web,nuclei,$target_short"
  else
    log_warning "Nuclei: no findings for $target_short — check $nuclei_log"
  fi

  kubectl delete job "$job_name" -n scanning --ignore-not-found >/dev/null 2>&1 || true
}

# ============================================================
# Step 3: Nuclei DAST scan (k8s Jobs — both targets in parallel)
#
# Templates are baked into the projectdiscovery/nuclei image and
# cached on the k3d node after first pull — NO re-download.
# ============================================================
# --- Step 2: Nuclei DAST scan (Parallel) ---
log_info "=== Step 3: Nuclei DAST scan ==="
NUCLEI_TARGETS=("juice-shop.targets.svc.cluster.local:3000" "dvwa.targets.svc.cluster.local:80")
NUCLEI_JOB_NAMES=()
NUCLEI_TARGET_SHORTS=()

for target_pair in "${NUCLEI_TARGETS[@]}"; do
    target_short="${target_pair%%.*}"
    JOB_NAME="nuclei-${target_short}-${TIMESTAMP}"
    TARGET_URL="http://$target_pair"

    NUCLEI_JOB_NAMES+=("$JOB_NAME")
    NUCLEI_TARGET_SHORTS+=("$target_short")

    kubectl delete job "$JOB_NAME" -n scanning --ignore-not-found >/dev/null 2>&1

    sed -e "s|__JOB_NAME__|$JOB_NAME|g" \
        -e "s|__TARGET__|$TARGET_URL|g" \
        <<'JOBEOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB_NAME__
  namespace: scanning
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      volumes:
        - name: work
          emptyDir: {}
      initContainers:
        - name: crawler
          image: nenadzaric/gospider:a4244c8
          command: ["/bin/sh", "-c"]
          args:
            - gospider -s "__TARGET__" --sitemap --robots --depth 1 --js=false -q | sort -u > /work/urls_clean.txt
          volumeMounts:
            - name: work
              mountPath: /work
      containers:
        - name: nuclei
          image: projectdiscovery/nuclei:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              nuclei -update-templates
              nuclei -l /work/urls_clean.txt -severity info,low,medium,high,critical -jsonl -o /work/nuclei.jsonl
              echo "===NUCLEI_RESULTS_START==="
              cat /work/nuclei.jsonl
              echo "===NUCLEI_RESULTS_END==="
          volumeMounts:
            - name: work
              mountPath: /work
          resources:
            limits:
              memory: "2048Mi"
              cpu: "1"
JOBEOF
done

# --- Waiting and Extracting ---
for i in "${!NUCLEI_JOB_NAMES[@]}"; do
    JOB_NAME="${NUCLEI_JOB_NAMES[$i]}"
    target_short="${NUCLEI_TARGET_SHORTS[$i]}"
    
    log_info "Attente de la fin du job: $JOB_NAME"
    kubectl wait --for=condition=complete "job/$JOB_NAME" -n scanning --timeout=600s >/dev/null
    
    # Extraction
    nuclei_report="$REPORTS_DIR/nuclei_${target_short}_$TIMESTAMP.json"
    pod_name=$(kubectl get pods -n scanning -l "job-name=$JOB_NAME" --no-headers -o name | head -1)
    
    kubectl logs -n scanning "$pod_name" -c nuclei | sed -n '/===NUCLEI_RESULTS_START===/,/===NUCLEI_RESULTS_END===/{ /===NUCLEI_RESULTS/d; p; }' | jq -s '.' > "$nuclei_report"
    
    if [ -s "$nuclei_report" ] && [ "$(cat "$nuclei_report")" != "[]" ]; then
        dd_import "$nuclei_report" "Nuclei Scan" "web,nuclei,$target_short"
    fi
    kubectl delete job "$JOB_NAME" -n scanning
done

# (ZAP scan removed due to high memory consumption on k3d node)

# --- Summary ---
echo ""
log_info "========================================================"
log_success "SCAN PIPELINE COMPLETE!"
log_info "========================================================"
log_info "Reports : $REPORTS_DIR"
log_info "DefectDojo: $DD_URL"
log_info "========================================================"
echo ""
ls -lh "$REPORTS_DIR" 2>/dev/null | grep "$TIMESTAMP" || log_warning "No reports for this run"
