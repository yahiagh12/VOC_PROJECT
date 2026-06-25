#!/bin/bash
set -euo pipefail

# ============================================================
# VOC - Scan Pipeline (k8s-native)
# Runs Grype + Nuclei + ZAP as Kubernetes Jobs and imports
# results to DefectDojo via the internal cluster API.
# Designed to run inside the VOC toolbox container.
# ============================================================

# --- Configuration (from .env or env vars) ---
DD_API_KEY="${DD_API_KEY:?ERROR: DD_API_KEY is required (set in .env)}"
# The toolbox container reaches DefectDojo via port-forward on localhost.
# k8s Jobs inside the cluster use the internal service name automatically.
DD_URL="http://localhost:8080"
DD_PRODUCT_NAME="${DD_PRODUCT_NAME:-Lab Targets}"
DD_ENGAGEMENT_NAME="${DD_ENGAGEMENT_NAME:-Continuous Scanning}"
DD_ENGAGEMENT_ID="${DD_ENGAGEMENT_ID:-}"
GRYPE_IMAGE="${GRYPE_IMAGE:-alpine:latest}"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
REPORTS_DIR="/workspace/scanners/reports"

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Helper: upload to DefectDojo ---
dd_import() {
  local file="$1" scan_type="$2" tags="$3"
  local extra_args=""
  if [ -n "$DD_ENGAGEMENT_ID" ]; then
    extra_args="-F engagement=$DD_ENGAGEMENT_ID"
  else
    extra_args="-F product_name=\"$DD_PRODUCT_NAME\" -F engagement_name=\"$DD_ENGAGEMENT_NAME\" -F auto_create_context=true -F product_type_name=Research"
  fi
  local code
  code=$(curl -sS -X POST "$DD_URL/api/v2/import-scan/" \
    -H "Authorization: Token $DD_API_KEY" \
    -F "scan_type=$scan_type" \
    -F "file=@$file" \
    -F "tags=$tags" \
    $extra_args \
    -o /dev/null -w "%{http_code}" 2>/dev/null) || code="000"
  echo "$code"
}

# --- Prep ---
mkdir -p "$REPORTS_DIR"

# --- Step 0: Check DefectDojo reachability via port-forward ---
log_info "=== Step 0: Checking DefectDojo API ==="
DD_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Token $DD_API_KEY" "$DD_URL/api/v2/findings/?limit=1" 2>/dev/null) || DD_HTTP="000"
if [ "$DD_HTTP" = "200" ]; then
  log_success "DefectDojo API is reachable and authenticated"
elif [ "$DD_HTTP" = "403" ]; then
  log_error "DefectDojo returned 403 Forbidden. Check DD_API_KEY in .env"
  exit 1
else
  log_error "Cannot reach DefectDojo API (HTTP $DD_HTTP). Is port-forward running on 8080?"
  log_error "Run: voc-forward voc-core/defectdojo-django 8080:80 &"
  exit 1
fi

# --- Step 1: Check targets are running ---
log_info "=== Step 1: Checking scan targets ==="
JUICE_READY=$(kubectl get pods -n targets -l app=juice-shop --no-headers 2>/dev/null | grep Running | wc -l)
DVWA_READY=$(kubectl get pods -n targets -l app=dvwa --no-headers 2>/dev/null | grep Running | wc -l)

if [ "$JUICE_READY" -gt 0 ]; then
  log_success "Juice Shop is running"
else
  log_warning "Juice Shop not running. Deploy with: voc-deploy targets"
fi
if [ "$DVWA_READY" -gt 0 ]; then
  log_success "DVWA is running"
else
  log_warning "DVWA not running. Deploy with: voc-deploy targets"
fi

# --- Step 2: Grype (SCA - container image scan) ---
log_info "=== Step 2: Grype scan (image: $GRYPE_IMAGE) ==="
GRYPE_REPORT="$REPORTS_DIR/grype_$TIMESTAMP.json"

# Run Grype as a k8s Job
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: grype-scan-$TIMESTAMP
  namespace: scanning
spec:
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: grype
          image: anchore/grype:latest
          command: ["grype", "$GRYPE_IMAGE", "-o", "json"]
EOF

log_info "Waiting for Grype job to complete (up to 5 min)..."
if kubectl wait --for=condition=complete job/grype-scan-$TIMESTAMP -n scanning --timeout=300s 2>/dev/null; then
  GRYPE_POD=$(kubectl get pods -n scanning -l job-name=grype-scan-$TIMESTAMP --no-headers -o name | head -1)
  kubectl logs -n scanning "$GRYPE_POD" > "$GRYPE_REPORT" 2>/dev/null || true
  kubectl delete job grype-scan-$TIMESTAMP -n scanning --ignore-not-found >/dev/null 2>&1

  if [ -s "$GRYPE_REPORT" ]; then
    log_success "Grype scan complete"
    code=$(dd_import "$GRYPE_REPORT" "Anchore Grype" "container,grype")
    log_success "Grype report imported to DefectDojo (HTTP $code)"
  else
    log_warning "Grype report is empty"
  fi
else
  log_error "Grype job timed out"
  kubectl delete job grype-scan-$TIMESTAMP -n scanning --ignore-not-found >/dev/null 2>&1
fi

# --- Step 3: Nuclei (DAST - multi target) ---
log_info "=== Step 3: Nuclei scan ==="

for target_pair in "juice-shop.targets.svc.cluster.local:3000" "dvwa.targets.svc.cluster.local:80"; do
  target_host="${target_pair%%:*}"
  target_port="${target_pair##*:}"
  target_short="${target_host%%.*}"
  NUCLEI_REPORT="$REPORTS_DIR/nuclei_${target_short}_$TIMESTAMP.json"
  JOB_NAME="nuclei-${target_short}-$(echo $TIMESTAMP | tr '_' '-')"

  log_info "Nuclei -> http://$target_pair ..."

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: scanning
spec:
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: nuclei
          image: projectdiscovery/nuclei:latest
          command: ["nuclei", "-u", "http://$target_pair", "-jsonl", "-o", "/tmp/results.jsonl"]
          volumeMounts:
            - name: results
              mountPath: /tmp
      volumes:
        - name: results
          emptyDir: {}
EOF

  log_info "Waiting for Nuclei ($target_short) to complete (up to 10 min)..."
  if kubectl wait --for=condition=complete job/$JOB_NAME -n scanning --timeout=600s 2>/dev/null; then
    NUCLEI_POD=$(kubectl get pods -n scanning -l job-name=$JOB_NAME --no-headers -o name | head -1)
    # Get the JSONL output from stdout and convert to JSON array
    kubectl logs -n scanning "$NUCLEI_POD" 2>/dev/null | grep '^{' | jq -s '.' > "$NUCLEI_REPORT" 2>/dev/null || true
    kubectl delete job $JOB_NAME -n scanning --ignore-not-found >/dev/null 2>&1

    if [ -s "$NUCLEI_REPORT" ] && [ "$(cat "$NUCLEI_REPORT")" != "[]" ]; then
      code=$(dd_import "$NUCLEI_REPORT" "Nuclei Scan" "web,nuclei,$target_short")
      log_success "Nuclei ($target_short) report imported (HTTP $code)"
    else
      log_warning "Nuclei: no findings for $target_short"
    fi
  else
    log_warning "Nuclei ($target_short) job timed out or failed"
    kubectl delete job $JOB_NAME -n scanning --ignore-not-found >/dev/null 2>&1
  fi
done

# --- Step 4: ZAP (deep DAST) ---
log_info "=== Step 4: ZAP scan ==="
ZAP_REPORT="$REPORTS_DIR/zap_$TIMESTAMP.xml"
ZAP_JOB="zap-scan-$(echo $TIMESTAMP | tr '_' '-')"

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $ZAP_JOB
  namespace: scanning
spec:
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: zap
          image: zaproxy/zap-stable:latest
          command:
            - zap-baseline.py
            - "-t"
            - "http://juice-shop.targets.svc.cluster.local:3000"
            - "-x"
            - "/tmp/zap-report.xml"
            - "-I"
          resources:
            limits:
              memory: "3Gi"
              cpu: "2"
          volumeMounts:
            - name: results
              mountPath: /tmp
      volumes:
        - name: results
          emptyDir: {}
EOF

log_info "Waiting for ZAP to complete (up to 15 min)..."
if kubectl wait --for=condition=complete job/$ZAP_JOB -n scanning --timeout=900s 2>/dev/null; then
  ZAP_POD=$(kubectl get pods -n scanning -l job-name=$ZAP_JOB --no-headers -o name | head -1)
  kubectl cp "scanning/${ZAP_POD#pod/}:/tmp/zap-report.xml" "$ZAP_REPORT" 2>/dev/null || true
  kubectl delete job $ZAP_JOB -n scanning --ignore-not-found >/dev/null 2>&1

  if [ -s "$ZAP_REPORT" ]; then
    code=$(dd_import "$ZAP_REPORT" "ZAP Scan" "web,zap,juice-shop")
    log_success "ZAP report imported to DefectDojo (HTTP $code)"
  else
    log_warning "ZAP report is empty — trying to get from logs"
    kubectl delete job $ZAP_JOB -n scanning --ignore-not-found >/dev/null 2>&1
  fi
else
  log_warning "ZAP job timed out or failed"
  kubectl delete job $ZAP_JOB -n scanning --ignore-not-found >/dev/null 2>&1
fi

# --- Summary ---
echo ""
log_info "========================================================"
log_success "SCAN PIPELINE COMPLETE!"
log_info "========================================================"
log_info "Reports   : $REPORTS_DIR"
log_info "DefectDojo: $DD_URL (from browser: http://localhost:8080)"
log_info "========================================================"
ls -lh "$REPORTS_DIR" 2>/dev/null | grep "$TIMESTAMP" || true
