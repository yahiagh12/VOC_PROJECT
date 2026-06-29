#!/bin/bash
set -euo pipefail

# ============================================================
# VOC - Scan Pipeline (k8s-native)
# Runs Grype + Nuclei + ZAP as Kubernetes Jobs and imports
# results to DefectDojo via the port-forwarded API.
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

  local response_file
  response_file=$(mktemp)

  local code
  code=$(curl -sS -X POST "$DD_URL/api/v2/import-scan/" \
    -H "Authorization: Token $DD_API_KEY" \
    -F "scan_type=$scan_type" \
    -F "file=@$file" \
    -F "tags=$tags" \
    $extra_args \
    -o "$response_file" -w "%{http_code}" 2>/dev/null) || code="000"

  if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    log_success "Imported to DefectDojo (HTTP $code)"
  else
    log_error "DefectDojo upload failed (HTTP $code)"
    # Show first 200 chars of the error response for debugging
    head -c 200 "$response_file" 2>/dev/null | sed 's/^/  > /' || true
    echo ""
  fi
  rm -f "$response_file"
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
# Scan the ACTUAL target images (not alpine) for real vulnerability data
log_info "=== Step 2: Grype SCA scan ==="

GRYPE_TARGETS="bkimminich/juice-shop:latest vulnerables/web-dvwa:latest"

for GRYPE_IMAGE in $GRYPE_TARGETS; do
  IMAGE_SHORT=$(echo "$GRYPE_IMAGE" | sed 's|.*/||; s|:.*||')
  GRYPE_REPORT="$REPORTS_DIR/grype_${IMAGE_SHORT}_$TIMESTAMP.json"
  GRYPE_JOB="grype-${IMAGE_SHORT}-${TIMESTAMP}"

  log_info "Grype -> $GRYPE_IMAGE"

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $GRYPE_JOB
  namespace: scanning
spec:
  ttlSecondsAfterFinished: 120
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: grype
          image: anchore/grype:latest
          command: ["grype", "$GRYPE_IMAGE", "-o", "json"]
          resources:
            limits:
              memory: "1Gi"
              cpu: "1"
EOF

  log_info "Waiting for Grype ($IMAGE_SHORT) to complete (up to 10 min)..."
  if kubectl wait --for=condition=complete "job/$GRYPE_JOB" -n scanning --timeout=600s 2>/dev/null; then
    GRYPE_POD=$(kubectl get pods -n scanning -l "job-name=$GRYPE_JOB" --no-headers -o name | head -1)
    kubectl logs -n scanning "$GRYPE_POD" > "$GRYPE_REPORT" 2>/dev/null || true
    kubectl delete job "$GRYPE_JOB" -n scanning --ignore-not-found >/dev/null 2>&1

    if [ -s "$GRYPE_REPORT" ]; then
      FINDING_COUNT=$(jq '.matches | length' "$GRYPE_REPORT" 2>/dev/null || echo "?")
      log_success "Grype found $FINDING_COUNT vulnerabilities in $IMAGE_SHORT"
      dd_import "$GRYPE_REPORT" "Anchore Grype" "container,grype,$IMAGE_SHORT"
    else
      log_warning "Grype report is empty for $IMAGE_SHORT"
    fi
  else
    log_error "Grype ($IMAGE_SHORT) job timed out or failed"
    kubectl get pods -n scanning -l "job-name=$GRYPE_JOB" --no-headers 2>/dev/null || true
    kubectl delete job "$GRYPE_JOB" -n scanning --ignore-not-found >/dev/null 2>&1
  fi
done

# --- Step 3: Nuclei (DAST - multi target) ---
log_info "=== Step 3: Nuclei DAST scan ==="

for target_pair in "juice-shop.targets.svc.cluster.local:3000" "dvwa.targets.svc.cluster.local:80"; do
  target_host="${target_pair%%:*}"
  target_port="${target_pair##*:}"
  target_short="${target_host%%.*}"
  NUCLEI_REPORT="$REPORTS_DIR/nuclei_${target_short}_$TIMESTAMP.json"
  JOB_NAME="nuclei-${target_short}-${TIMESTAMP}"

  log_info "Nuclei -> http://$target_pair"

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: scanning
spec:
  ttlSecondsAfterFinished: 120
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: nuclei
          image: projectdiscovery/nuclei:latest
          command:
            - nuclei
            - "-u"
            - "http://$target_pair"
            - "-severity"
            - "low,medium,high,critical"
            - "-tags"
            - "cve,exposure,misconfig,tech"
            - "-timeout"
            - "5"
            - "-jsonl"
            - "-o"
            - "/tmp/results.jsonl"
          resources:
            limits:
              memory: "1Gi"
              cpu: "1"
          volumeMounts:
            - name: results
              mountPath: /tmp
      volumes:
        - name: results
          emptyDir: {}
EOF

  log_info "Waiting for Nuclei ($target_short) to complete (up to 10 min)..."
  if kubectl wait --for=condition=complete "job/$JOB_NAME" -n scanning --timeout=600s 2>/dev/null; then
    NUCLEI_POD=$(kubectl get pods -n scanning -l "job-name=$JOB_NAME" --no-headers -o name | head -1)
    NUCLEI_POD_NAME="${NUCLEI_POD#pod/}"

    # Extract results file using kubectl exec + cat (not kubectl cp which needs tar)
    kubectl exec -n scanning "$NUCLEI_POD_NAME" -- cat /tmp/results.jsonl 2>/dev/null | jq -s '.' > "$NUCLEI_REPORT" 2>/dev/null || true
    kubectl delete job "$JOB_NAME" -n scanning --ignore-not-found >/dev/null 2>&1

    if [ -s "$NUCLEI_REPORT" ] && [ "$(cat "$NUCLEI_REPORT")" != "[]" ] && [ "$(cat "$NUCLEI_REPORT")" != "null" ]; then
      FINDING_COUNT=$(jq 'length' "$NUCLEI_REPORT" 2>/dev/null || echo "?")
      log_success "Nuclei found $FINDING_COUNT findings for $target_short"
      dd_import "$NUCLEI_REPORT" "Nuclei Scan" "web,nuclei,$target_short"
    else
      log_warning "Nuclei: no findings for $target_short"
    fi
  else
    log_warning "Nuclei ($target_short) job timed out or failed"
    kubectl get pods -n scanning -l "job-name=$JOB_NAME" --no-headers 2>/dev/null || true
    kubectl delete job "$JOB_NAME" -n scanning --ignore-not-found >/dev/null 2>&1
  fi
done

# --- Step 4: ZAP (deep DAST — full active scan) ---
log_info "=== Step 4: ZAP active scan ==="

for zap_target in "juice-shop.targets.svc.cluster.local:3000" "dvwa.targets.svc.cluster.local:80"; do
  zap_short="${zap_target%%.*}"
  ZAP_REPORT="$REPORTS_DIR/zap_${zap_short}_$TIMESTAMP.xml"
  ZAP_JOB="zap-${zap_short}-${TIMESTAMP}"

  log_info "ZAP full-scan -> http://$zap_target"

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $ZAP_JOB
  namespace: scanning
spec:
  ttlSecondsAfterFinished: 120
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: zap
          image: zaproxy/zap-stable:latest
          command:
            - zap-full-scan.py
            - "-t"
            - "http://$zap_target"
            - "-x"
            - "/tmp/zap-report.xml"
            - "-I"
            - "-m"
            - "5"
          resources:
            limits:
              memory: "4Gi"
              cpu: "2"
          volumeMounts:
            - name: results
              mountPath: /tmp
      volumes:
        - name: results
          emptyDir: {}
EOF

  log_info "Waiting for ZAP ($zap_short) to complete (up to 20 min)..."
  if kubectl wait --for=condition=complete "job/$ZAP_JOB" -n scanning --timeout=1200s 2>/dev/null; then
    ZAP_POD=$(kubectl get pods -n scanning -l "job-name=$ZAP_JOB" --no-headers -o name | head -1)
    ZAP_POD_NAME="${ZAP_POD#pod/}"

    # Extract report using exec+cat (avoids tar dependency issues with kubectl cp)
    kubectl exec -n scanning "$ZAP_POD_NAME" -- cat /tmp/zap-report.xml > "$ZAP_REPORT" 2>/dev/null || true
    kubectl delete job "$ZAP_JOB" -n scanning --ignore-not-found >/dev/null 2>&1

    if [ -s "$ZAP_REPORT" ]; then
      log_success "ZAP scan complete for $zap_short"
      dd_import "$ZAP_REPORT" "ZAP Scan" "web,zap,$zap_short"
    else
      log_warning "ZAP report is empty for $zap_short — trying logs fallback"
      kubectl logs -n scanning "$ZAP_POD" --tail=20 2>/dev/null || true
    fi
  else
    log_warning "ZAP ($zap_short) job timed out or failed"
    kubectl get pods -n scanning -l "job-name=$ZAP_JOB" --no-headers 2>/dev/null || true
    kubectl delete job "$ZAP_JOB" -n scanning --ignore-not-found >/dev/null 2>&1
  fi
done

# --- Summary ---
echo ""
log_info "========================================================"
log_success "SCAN PIPELINE COMPLETE!"
log_info "========================================================"
log_info "Reports : $REPORTS_DIR"
log_info "DefectDojo: $DD_URL (from browser: http://localhost:8080)"
log_info "========================================================"
echo ""
log_info "Reports generated:"
ls -lh "$REPORTS_DIR" 2>/dev/null | grep "$TIMESTAMP" || log_warning "No reports found for this run"
