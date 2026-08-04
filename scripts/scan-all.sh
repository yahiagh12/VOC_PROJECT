#!/bin/bash
set -euo pipefail

# ============================================================
# VOC - Scan Pipeline (k8s-native)
#
# Phase 1 DISCOVERY  : katana crawls each target once -> ConfigMap of URLs
# Phase 2 EXPLOIT    : nuclei / sqlmap / xsstrike / ffuf read that ConfigMap
# Phase 3 STORE/TRI  : every normalized result -> DefectDojo (central store)
#                      which the prioritization-service + n8n workflow read.
#
# Designed to run inside the VOC toolbox container.
#
# Usage:
#   voc-scan           # full scan (~10-12 min)
#   voc-scan --quick   # skip nuclei + xss (~6 min)
#
# Caching strategy (so nothing re-downloads every run):
#   - Grype vuln DB:  PersistentVolumeClaim "grype-db-cache" (namespace
#                      scanning, k3d local-path storage class). Mounted by
#                      both grype-db-warm-job.yaml and grype-job.yaml at
#                      /cache/grype/db via GRYPE_DB_CACHE_DIR. Warmed
#                      synchronously once per run (Step 3) before the
#                      parallel per-image scans start, so they never race
#                      to download the DB into the same cache concurrently.
#                      Survives pod restarts and `k3d cluster start/stop`;
#                      wiped only on a full `k3d cluster delete` (expected).
#   - Nuclei templates: baked into container image (pulled once by k3d)
#   - Scanner images:  cached on k3d node after first pull
#
# Performance:
#   - Grype scans run in parallel (Step 3)
#   - Nuclei harvest runs in background, overlapping with Step 5
#   - Step 5 scanners (sqlmap/ffuf/xss) run in parallel per-target
# ============================================================

START_TIME=$SECONDS

# --- Mode ---
QUICK_MODE="${QUICK_MODE:-0}"
[[ "${1:-}" == "--quick" ]] && { QUICK_MODE=1; shift; }

# --- Configuration (from .env or env vars) ---
DD_API_KEY="${DD_API_KEY:?ERROR: DD_API_KEY is required}"
DD_URL="${DD_URL:-http://localhost:8080}"
DD_PRODUCT_NAME="${DD_PRODUCT_NAME:-Lab Targets}"
DD_ENGAGEMENT_NAME="${DD_ENGAGEMENT_NAME:-Continuous Scanning}"
DD_ENGAGEMENT_ID="${DD_ENGAGEMENT_ID:-}"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNERS_DIR="$(dirname "$SCRIPT_DIR")/scanners"
REPORTS_DIR="/workspace/scanners/reports"

# --- Targets that participate in Phase 1 discovery + Phase 2 DAST ---
# Each entry: "<svc>.<ns>.svc.cluster.local:<port>" -- target_short is the
# part before the first dot (e.g. "juice-shop" / "dvwa").
DISCOVERY_TARGETS=(
  "juice-shop.targets.svc.cluster.local:3000"
  "dvwa.targets.svc.cluster.local:80"
)

# --- Targets for which sqlmap/xss are SKIPPED in Phase 2 (auth-gated) ---
# These targets' interesting injection endpoints sit behind a login flow
# (e.g. DVWA's vulnerabilities/xss_r/?name=... needs a PHPSESSID cookie).
# Running sqlmap/xss against them unauthenticated produces 0 findings and
# wastes minutes per scan. ffuf (path discovery) + nuclei (passive
# templates) + grype (image SCA) still run for these targets.
# Phase A (later phase) will replace this hardcoded list with a per-target
# `enabled_dast:` field read from scanners/targets.yaml. For now this is
# a targeted Phase 0 workaround so DVWA runs are not pointlessly slow.
DAST_DISABLED_TARGETS=(
  # DVWA is now fully scanned with authentication
)

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================
# Helper functions (defined before any Step uses them)
# ============================================================

# --- Helper: upload to DefectDojo (with retry for 5xx/000) ---
# Tries reimport-scan first (deduplicates against existing test). If reimport
# returns 400/404 (no prior test exists), falls back to import-scan (creates
# a fresh test). This makes the first-ever run succeed without manual setup.
# The optional 4th arg is a per-target slug used in test_title so parallel
# imports of the SAME scan_type for DIFFERENT targets (e.g. grype on
# juice-shop vs web-dvwa) land in separate tests — otherwise reimport
# closes the other target's findings on every run.
dd_import() {
  local file="$1" scan_type="$2" tags="$3" test_slug="${4:-}"
  local test_title="$scan_type"
  [ -n "$test_slug" ] && test_title="$scan_type - $test_slug"
  local max_retries=3

  # Try reimport first, then import as fallback
  local endpoints=("reimport-scan" "import-scan")
  for endpoint in "${endpoints[@]}"; do
    local attempt=1
    while [ "$attempt" -le "$max_retries" ]; do
      local response_file curl_err
      response_file=$(mktemp)
      curl_err=$(mktemp)

      # Build curl args as an array to avoid shell quoting issues
      local -a curl_args=(
        -sS -X POST "$DD_URL/api/v2/${endpoint}/"
        -H "Authorization: Token $DD_API_KEY"
        -F "scan_type=$scan_type"
        -F "test_title=$test_title"
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
        log_success "Imported to DefectDojo via $endpoint (HTTP $code)"
        rm -f "$response_file" "$curl_err"
        return 0
      elif [ "$code" = "400" ] || [ "$code" = "404" ]; then
        if [ "$endpoint" = "reimport-scan" ]; then
          log_info "reimport returned $code (no prior test) — falling back to import-scan"
          rm -f "$response_file" "$curl_err"
          break  # Break inner retry loop, try next endpoint
        else
          log_error "DefectDojo import-scan failed (HTTP $code)"
          head -c 500 "$response_file" 2>/dev/null | sed 's/^/  > /' || true
          echo ""
          rm -f "$response_file" "$curl_err"
          return 1
        fi
      elif [ "${code:0:1}" = "5" ] || [ "$code" = "000" ]; then
        if [ "$attempt" -lt "$max_retries" ]; then
          log_warning "DefectDojo returned HTTP $code -- retrying in 15s (attempt $attempt/$max_retries)"
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
  done
  log_error "DefectDojo upload failed after trying both reimport-scan and import-scan"
  return 1
}

# wait_for_job  : poll a k8s Job until complete/failed/timeout. On failure
#                 dump pod status + last 30 log lines so the user sees *why*
#                 without a manual kubectl.
#                 `kubectl get job` failing is NOT proof the job is gone —
#                 transient API/serverlb hiccups (observed under parallel
#                 scan load) make it return non-zero for existing jobs.
#                 Treating that as "not found" caused the cleanup path to
#                 delete perfectly healthy running jobs, so we require
#                 several consecutive misses before giving up.
wait_for_job() {
  local job_name="$1" namespace="$2" timeout_sec="$3" label="$4"
  local elapsed=0 interval=5
  local misses=0 max_misses=6

  while [ "$elapsed" -lt "$timeout_sec" ]; do
    # Check if job still exists. Only after SEVERAL consecutive misses do
    # we conclude it was really deleted (e.g. by ttlSecondsAfterFinished).
    if ! kubectl get job "$job_name" -n "$namespace" >/dev/null 2>&1; then
      misses=$((misses + 1))
      if [ "$misses" -ge "$max_misses" ]; then
        log_warning "Job $job_name not found in namespace $namespace after $max_misses checks. Stopping wait."
        return 1
      fi
      sleep "$interval"
      elapsed=$((elapsed + interval))
      continue
    fi
    misses=0
    if kubectl wait --for=condition=complete "job/$job_name" -n "$namespace" --timeout=0s 2>/dev/null; then
      return 0
    fi
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

# apply_job_template : read a Job YAML from scanners/, __PLACEHOLDER__
#                      substitution, kubectl apply. Accepts any number of
#                      PH=VALUE pairs after the job name so one call can
#                      substitute every marker.
#   apply_job_template <template> <job_name> [PH=VALUE] [PH=VALUE] ...
apply_job_template() {
  local template="$1" job_name="$2"; shift 2
  kubectl delete job "$job_name" -n scanning --ignore-not-found >/dev/null 2>&1
  local content pair ph val
  content="$(cat "$template")"
  for pair in "$@"; do
    ph="__${pair%%=*}__"
    val="${pair#*=}"
    content="${content//"$ph"/"$val"}"
  done
  printf '%s' "$content" | kubectl apply -f - >/dev/null 2>&1
}

# extract_marker_results : pull raw result out of a finished Job's pod log,
#                          between ===MARKER_RESULTS_START=== / ===_END===.
#                          Returns non-zero if no marker text was found.
extract_marker_results() {
  local job_name="$1" marker="$2" out_file="$3"
  local pod
  pod=$(kubectl get pods -n scanning -l "job-name=$job_name" --no-headers -o name 2>/dev/null | head -1)
  [ -z "${pod#pod/}" ] && return 1
  kubectl logs -n scanning "${pod#pod/}" 2>/dev/null \
    | sed -n "/===${marker}_RESULTS_START===/,/===${marker}_RESULTS_END===/{ /===${marker}_RESULTS/d; p; }" \
    > "$out_file"
  [ -s "$out_file" ]
}

# run_generic_scanner : end-to-end driver for sqlmap/ffuf/xss/crawler.
#   Fixed args after marker-scan_type: optional numeric timeout, then any
#   PH=VALUE pairs which are forwarded to apply_job_template (used to pass
#   __TARGETS_CM__ / __TARGET_URL__).
run_generic_scanner() {
  local tool="$1" template="$2" target_short="$3" marker="$4" scan_type="$5"
  local timeout_sec="600"
  shift 5
  # Optional numeric timeout as first extra arg
  if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
    timeout_sec="$1"; shift
  fi
  local job_name="${tool}-${target_short}-${TIMESTAMP}"
  local raw="$REPORTS_DIR/${tool}_${target_short}_${TIMESTAMP}.raw"
  local norm="$REPORTS_DIR/${tool}_${target_short}_${TIMESTAMP}.json"
  local debug_log="$REPORTS_DIR/${tool}_${target_short}_${TIMESTAMP}_debug.log"

  log_info "$tool -> $target_short (template=$(basename "$template"))"
  if ! apply_job_template "$template" "$job_name" JOB_NAME="$job_name" "$@"; then
    log_error "failed to apply $tool job template"; return 1
  fi

  if ! wait_for_job "$job_name" scanning "$timeout_sec" "$tool scan ($target_short)"; then
    kubectl delete job "$job_name" -n scanning --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi

  local pod
  pod=$(kubectl get pods -n scanning -l "job-name=$job_name" --no-headers -o name 2>/dev/null | head -1)
  [ -n "$pod" ] && kubectl logs -n scanning "${pod#pod/}" > "$debug_log" 2>/dev/null || true
  log_info "$tool raw pod logs saved to $debug_log"

  if ! extract_marker_results "$job_name" "$marker" "$raw"; then
    log_warning "$tool produced no marker output for $target_short (see $debug_log)"
    kubectl delete job "$job_name" -n scanning --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi

  if ! python3 "$SCRIPT_DIR/normalize-findings.py" "$tool" "$raw" "$norm" "$target_short" --db "/workspace/scanners/voc-scans.db" >/dev/null 2>&1; then
    log_error "$tool normalizer failed for $target_short (raw kept at $raw)"
    kubectl delete job "$job_name" -n scanning --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi

  local count
  count=$(jq '.findings | length' "$norm" 2>/dev/null || echo "!")

  if [ "$count" = "0" ]; then
    log_info "$tool: 0 findings for $target_short -- keeping normalized file, skipping DefectDojo import"
  else
    log_success "$tool: $count findings for $target_short -- normalizing + pushing to DefectDojo"
    dd_import "$norm" "$scan_type" "web,$tool,$target_short" "$tool-$target_short" \
      || log_warning "$tool: DefectDojo import failed (raw kept at $raw, normalized at $norm)"
  fi

  kubectl delete job "$job_name" -n scanning --ignore-not-found >/dev/null 2>&1 || true
  return 0
}

# ============================================================
# Prep
# ============================================================
mkdir -p "$REPORTS_DIR"

# --- Step 0: Check DefectDojo reachability ---
# Retried because run-all.sh kicks this off right after (re)starting the
# port-forwards -- the tunnel can accept a bare GET / a beat before the
# Django/DRF API layer underneath is actually answering authenticated
# requests, which previously showed up as a one-shot HTTP 000 failure.
log_info "=== Step 0: Checking DefectDojo API ==="
DD_HTTP="000"
for attempt in $(seq 1 6); do
  DD_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Token $DD_API_KEY" "$DD_URL/api/v2/findings/?limit=1" 2>/dev/null) || DD_HTTP="000"
  [ "$DD_HTTP" = "200" ] || [ "$DD_HTTP" = "403" ] && break
  log_warning "DefectDojo API not responding yet (HTTP $DD_HTTP) -- retrying in 5s (attempt $attempt/6)"
  sleep 5
done

if [ "$DD_HTTP" = "200" ]; then
  log_success "DefectDojo API is reachable and authenticated"
elif [ "$DD_HTTP" = "403" ]; then
  log_error "DefectDojo returned 403 Forbidden. Check DD_API_KEY in .env"
  exit 1
else
  log_error "Cannot reach DefectDojo API (HTTP $DD_HTTP) after 6 attempts. Is port-forward running on 8080?"
  exit 1
fi

# Ensure ffuf wordlist ConfigMap is applied to the scanning namespace
kubectl apply -f "$SCANNERS_DIR/ffuf-wordlist-cm.yaml" >/dev/null 2>&1 || log_warning "Failed to apply ffuf-wordlist configmap"

# Ensure the Grype DB cache PVC exists (idempotent — no-op if already created).
kubectl apply -f "$SCANNERS_DIR/grype-db-pvc.yaml" >/dev/null 2>&1 || log_warning "Failed to apply grype-db-cache PVC"

# --- Step 1: Check targets are running ---
log_info "=== Step 1: Checking scan targets ==="
JUICE_READY=$(kubectl get pods -n targets -l app=juice-shop --no-headers 2>/dev/null | grep Running | wc -l)
DVWA_READY=$(kubectl get pods -n targets -l app=dvwa --no-headers 2>/dev/null | grep Running | wc -l)
[ "$JUICE_READY" -gt 0 ] && log_success "Juice Shop is running" || log_warning "Juice Shop not running"
[ "$DVWA_READY" -gt 0 ] && log_success "DVWA is running" || log_warning "DVWA not running"

# ============================================================
# Step 2: Phase 1 -- Discovery (katana)
#
# Crawl each target ONCE, harvest the discovered URLs from the pod log
# (between ===DISCOVERY_RESULTS_START=== / ===_END=== markers), split
# them into:
#   all_urls.txt   -- every URL discovered (-> nuclei)
#   param_urls.txt -- URLs containing ?param=...   (-> sqlmap / xsstrike)
# then bake both into a per-target ConfigMap that every Phase 2 scanner
# mounts at /targets. Mapping kept in TARGETS_CM (bash assoc. array).
# ============================================================
declare -A TARGETS_CM=()
log_info "=== Step 2: Discovery (katana) -- building URL inventory ==="

for target_pair in "${DISCOVERY_TARGETS[@]}"; do
  target_short="${target_pair%%.*}"
  target_url="http://$target_pair"
  disc_job="discovery-${target_short}-${TIMESTAMP}"
  disc_raw="$REPORTS_DIR/discovery_${target_short}_${TIMESTAMP}.txt"
  disc_dbg="$REPORTS_DIR/discovery_${target_short}_${TIMESTAMP}_debug.log"
  all_urls="$REPORTS_DIR/all_urls_${target_short}_${TIMESTAMP}.txt"
  param_urls="$REPORTS_DIR/param_urls_${target_short}_${TIMESTAMP}.txt"
  cm_name="voc-targets-${target_short}-${TIMESTAMP}"

  log_info "Discovery -> $target_short ($target_url)"
  if ! apply_job_template "$SCANNERS_DIR/discovery-job.yaml" "$disc_job" \
          JOB_NAME="$disc_job" TARGET_URL="$target_url"; then
    log_error "failed to apply discovery job for $target_short"
    continue
  fi

  if ! wait_for_job "$disc_job" scanning 300 "discovery ($target_short)"; then
    log_warning "discovery failed for $target_short -- Phase 2 will fall back to root URL only"
    printf 'http://%s\n' "$target_pair" > "$all_urls"
    : > "$param_urls"
  else
    disc_pod=$(kubectl get pods -n scanning -l "job-name=$disc_job" --no-headers -o name 2>/dev/null | head -1)
    [ -n "$disc_pod" ] && kubectl logs -n scanning "${disc_pod#pod/}" > "$disc_dbg" 2>/dev/null || true
    if ! extract_marker_results "$disc_job" "DISCOVERY" "$disc_raw"; then
      log_warning "discovery produced no marker output for $target_short (see $disc_dbg)"
      printf 'http://%s\n' "$target_pair" > "$all_urls"
    else
      cp "$disc_raw" "$all_urls"
      log_success "discovery: $(wc -l < "$all_urls") URLs for $target_short (saved $disc_raw)"
    fi
  fi

  # Supplement katana's crawl with a hand-curated seed list of known
  # endpoints (scanners/seed-urls.<short>.txt). This covers SPA routes,
  # REST APIs, and auth-gated pages that katana's static crawl misses.
  seed_urls_file="$SCANNERS_DIR/seed-urls.${target_short}.txt"
  if [ -f "$seed_urls_file" ]; then
    before_count=$(wc -l < "$all_urls" 2>/dev/null || echo 0)
    # Strip comments/blank lines, append, then dedup.
    grep -vE '^\s*(#|$)' "$seed_urls_file" >> "$all_urls" 2>/dev/null || true
    sort -u -o "$all_urls" "$all_urls"
    after_count=$(wc -l < "$all_urls" 2>/dev/null || echo 0)
    added=$((after_count - before_count))
    [ "$added" -gt 0 ] && log_info "seed URLs: +$added new URLs from $seed_urls_file (total: $after_count)"
  fi

  # Filter to URLs WITH parameters -- these are the sqlmap/xss candidates.
  if [ -s "$all_urls" ]; then
    grep -E '\?[A-Za-z0-9_.-]+=' "$all_urls" > "$param_urls" 2>/dev/null || true
  else
    : > "$param_urls"
  fi
  # Katana's static crawl misses SPA/JS-reachable and REST-API routes,
  # so param_urls.txt is often empty even on real targets. Fall back to a
  # hand-curated seed list (scanners/seed-params.<short>.txt) of known
  # parameter-bearing endpoints so sqlmap/xss still have something to
  # attack instead of exiting with "no parameter-bearing URLs".
  seed_file="$SCANNERS_DIR/seed-params.${target_short}.txt"
  if [ ! -s "$param_urls" ] && [ -f "$seed_file" ]; then
    # Strip comments/blank lines, preserve only real URLs.
    grep -vE '^\s*(#|$)' "$seed_file" > "$param_urls" 2>/dev/null || true
    log_info "crawl found 0 param URLs -- supplemented from $seed_file ($(wc -l < "$param_urls" 2>/dev/null || echo 0) URLs)"
  fi
  log_info "param-bearing URLs for $target_short: $(wc -l < "$param_urls" 2>/dev/null || echo 0)"

  [ -s "$all_urls" ] || : > "$all_urls"

  # Create / refresh the ConfigMap.
  kubectl delete configmap "$cm_name" -n scanning --ignore-not-found >/dev/null 2>&1 || true
  if kubectl create configmap "$cm_name" -n scanning \
        --from-file=all_urls.txt="$all_urls" \
        --from-file=param_urls.txt="$param_urls" >/dev/null 2>&1; then
    log_success "ConfigMap $cm_name created ($target_short)"
    TARGETS_CM["$target_short"]="$cm_name"
  else
    log_error "failed to create ConfigMap $cm_name -- Phase 2 for $target_short will have no targets"
  fi

  kubectl delete job "$disc_job" -n scanning --ignore-not-found >/dev/null 2>&1 || true
done

# ============================================================
# Step 3: Grype SCA scan (Kubernetes-based, DB cached in PVC)
#
# Performance: warm the shared DB cache ONCE, synchronously, before
# launching the two per-image scans in parallel. This avoids a race
# where both jobs hit an empty/stale cache simultaneously and try to
# download+extract the DB into the same PVC at once. On a warm cache
# the warm-up job finishes in seconds (checksum check only).
# ============================================================
log_info "=== Step 3: Grype SCA scan ==="

# Performance: check if the Grype DB cache is fresh (updated < 24h ago).
# If so, skip the warm-up entirely — saves 1-3 minutes on repeat scans.
GRYPE_SKIP_WARM=0
grype_age_check=$(mktemp)
cat > "$grype_age_check" <<'AGECHECK'
apiVersion: batch/v1
kind: Job
metadata:
  name: grype-db-age-check
  namespace: scanning
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: check
          image: alpine:3.20
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - |
              DB_DIR=/cache/grype/db
              if [ -d "$DB_DIR" ] && find "$DB_DIR" -name '*.db' -mmin -1440 2>/dev/null | grep -q .; then
                echo "===GRYPE_AGE_FRESH==="
              else
                echo "===GRYPE_AGE_STALE==="
              fi
          volumeMounts:
            - name: grype-db
              mountPath: /cache/grype/db
          resources:
            requests: { cpu: "50m", memory: "32Mi" }
            limits:   { cpu: "100m", memory: "64Mi" }
      volumes:
        - name: grype-db
          persistentVolumeClaim:
            claimName: grype-db-cache
AGECHECK
kubectl delete job grype-db-age-check -n scanning --ignore-not-found >/dev/null 2>&1 || true
if kubectl apply -f "$grype_age_check" >/dev/null 2>&1; then
  if wait_for_job grype-db-age-check scanning 60 "grype DB age check"; then
    age_pod=$(kubectl get pods -n scanning -l "job-name=grype-db-age-check" --no-headers -o name 2>/dev/null | head -1)
    if [ -n "$age_pod" ] && kubectl logs -n scanning "${age_pod#pod/}" 2>/dev/null | grep -q 'GRYPE_AGE_FRESH'; then
      GRYPE_SKIP_WARM=1
      log_success "Grype DB cache is fresh (<24h) -- skipping warm-up"
    fi
  fi
  kubectl delete job grype-db-age-check -n scanning --ignore-not-found >/dev/null 2>&1 || true
fi
rm -f "$grype_age_check"

if [ "$GRYPE_SKIP_WARM" = "0" ]; then
  warm_job="grype-db-warm-${TIMESTAMP}"
  log_info "Warming Grype DB cache (shared across scans)..."
  if apply_job_template "$SCANNERS_DIR/grype-db-warm-job.yaml" "$warm_job" JOB_NAME="$warm_job"; then
    if wait_for_job "$warm_job" scanning 600 "grype db warm"; then
      log_success "Grype DB cache warm"
    else
      log_warning "Grype DB warm-up failed/timed out -- scans below will each attempt their own DB update"
    fi
    kubectl delete job "$warm_job" -n scanning --ignore-not-found >/dev/null 2>&1 || true
  else
    log_warning "Failed to apply grype-db-warm job -- skipping warm-up, scans will update DB individually"
  fi
fi

# run_grype <image> : scan a single container image with Grype via Kubernetes Job,
# import results to DefectDojo. Designed to run inside a subshell.
run_grype() {
  local GRYPE_IMAGE="$1"
  local IMAGE_SHORT
  IMAGE_SHORT=$(echo "$GRYPE_IMAGE" | sed 's|.*/||; s|:.*||')
  [ "$IMAGE_SHORT" = "web-dvwa" ] && IMAGE_SHORT="dvwa"
  local JOB_NAME="grype-${IMAGE_SHORT}-${TIMESTAMP}"
  local GRYPE_REPORT="$REPORTS_DIR/grype_${IMAGE_SHORT}_$TIMESTAMP.json"

  log_info "Grype -> $GRYPE_IMAGE (via Kubernetes)"
  apply_job_template "$SCANNERS_DIR/grype-job.yaml" "$JOB_NAME" JOB_NAME="$JOB_NAME" TARGET_IMAGE="$GRYPE_IMAGE"
  
  if wait_for_job "$JOB_NAME" scanning 900 "grype scan ($IMAGE_SHORT)"; then
    if extract_marker_results "$JOB_NAME" GRYPE "$GRYPE_REPORT"; then
      local FINDING_COUNT
      FINDING_COUNT=$(jq '.matches | length' "$GRYPE_REPORT" 2>/dev/null || echo "?")
      log_success "Grype found $FINDING_COUNT vulnerabilities in $IMAGE_SHORT"
      dd_import "$GRYPE_REPORT" "Anchore Grype" "container,grype,$IMAGE_SHORT" "$IMAGE_SHORT"

      # Store grype findings in SQLite — convert matches to normalized format on the fly.
      # Uses jq to transform grype JSON → normalized findings JSON, then pipes to voc-db.py.
      local GRYPE_NORM="$REPORTS_DIR/grype_${IMAGE_SHORT}_${TIMESTAMP}_norm.json"
      jq '{
        name: "grype normalized",
        type: "Generic Findings Import",
        version: "1.0",
        findings: [.matches[]? | {
          title: ("CVE: " + (.vulnerability.id // "unknown") + " in " + (.artifact.name // "unknown") + ":" + (.artifact.version // "?")),
          severity: (.vulnerability.severity // "Medium"),
          cwe: null,
          description: ((.vulnerability.description // "No description") + "\nPackage: " + (.artifact.name // "?") + " " + (.artifact.version // "?") + "\nFixed in: " + ((.vulnerability.fix.versions // []) | join(", ") // "no fix available")),
          impact: "Vulnerable dependency detected in container image.",
          mitigation: ("Update " + (.artifact.name // "package") + " to a patched version."),
          param: null,
          payload: null,
          endpoints: [],
          tags: ["grype", "container"],
          unique_id_from_tool: ("grype-" + (.vulnerability.id // "unknown") + "-" + (.artifact.name // "unknown") + "-" + (.artifact.version // "?")),
          active: true,
          verified: false,
          date: (now | strftime("%Y-%m-%d"))
        }]
      }' "$GRYPE_REPORT" > "$GRYPE_NORM" 2>/dev/null || true
      if [ -s "$GRYPE_NORM" ]; then
        python3 "$SCRIPT_DIR/voc-db.py" --db "/workspace/scanners/voc-scans.db" \
          store-findings --json-file "$GRYPE_NORM" --scanner grype --target "$IMAGE_SHORT" \
          2>/dev/null || true
        rm -f "$GRYPE_NORM"
      fi
    else
      log_warning "Grype report extraction failed for $IMAGE_SHORT"
    fi
  else
    log_error "Grype job failed for $IMAGE_SHORT"
  fi
}

# Launch Grype scans in parallel — one subshell per image.
grype_pids=()
grype_logs=()
for GRYPE_IMAGE in "bkimminich/juice-shop:latest" "vulnerables/web-dvwa:latest"; do
  tmplog=$(mktemp)
  grype_logs+=("$tmplog")
  ( run_grype "$GRYPE_IMAGE" > "$tmplog" 2>&1 ) &
  grype_pids+=($!)
done
# Wait for all Grype scans to finish, then print buffered output.
for i in "${!grype_pids[@]}"; do
  wait "${grype_pids[$i]}" || true
  cat "${grype_logs[$i]}"
  rm -f "${grype_logs[$i]}"
done

# ============================================================
# Step 3b: Authenticate to targets
# ============================================================
declare -A TARGETS_COOKIE=()
if [ -n "${TARGETS_CM["dvwa"]+x}" ]; then
  log_info "=== Step 3b: Authenticating to DVWA ==="
  auth_job="auth-dvwa-${TIMESTAMP}"
  auth_raw="$REPORTS_DIR/auth_dvwa_${TIMESTAMP}.txt"
  target_url=""
  for pair in "${DISCOVERY_TARGETS[@]}"; do
    if [ "${pair%%.*}" = "dvwa" ]; then target_url="http://$pair"; break; fi
  done
  
  if apply_job_template "$SCANNERS_DIR/dvwa-auth-job.yaml" "$auth_job" \
          JOB_NAME="$auth_job" TARGET_URL="$target_url"; then
    if wait_for_job "$auth_job" scanning 120 "dvwa auth"; then
      extract_marker_results "$auth_job" "AUTH" "$auth_raw"
      if [ -s "$auth_raw" ]; then
        TARGETS_COOKIE["dvwa"]=$(cat "$auth_raw" | tr -d '\r' | head -n1)
        log_success "DVWA authenticated (cookie obtained)"
      fi
    fi
    kubectl delete job "$auth_job" -n scanning --ignore-not-found >/dev/null 2>&1 || true
  fi
fi

# ============================================================
# Step 4: Nuclei DAST scan per discovered target
#
# Performance: Nuclei jobs are submitted here but the wait+extract
# ("harvest") runs in a background function so Step 5 can start
# immediately.  The harvest PID is joined after Step 5 completes.
# In --quick mode nuclei is skipped entirely.
# ============================================================
NUCLEI_HARVEST_PID=""

if [ "$QUICK_MODE" = "1" ]; then
  log_info "=== Step 4: Nuclei DAST scan (SKIPPED — quick mode) ==="
else
  log_info "=== Step 4: Nuclei DAST scan ==="
  NUCLEI_JOB_NAMES=()
  NUCLEI_TARGET_SHORTS=()

  for target_short in "${!TARGETS_CM[@]}"; do
    cm_name="${TARGETS_CM[$target_short]}"
    JOB_NAME="nuclei-${target_short}-${TIMESTAMP}"
    NUCLEI_JOB_NAMES+=("$JOB_NAME")
    NUCLEI_TARGET_SHORTS+=("$target_short")

    kubectl delete job "$JOB_NAME" -n scanning --ignore-not-found >/dev/null 2>&1
    content="$(cat "$SCANNERS_DIR/nuclei-phase2-job.yaml")"
    content="${content//__JOB_NAME__/$JOB_NAME}"
    content="${content//__TARGETS_CM__/$cm_name}"
    auth_cookie="${TARGETS_COOKIE[$target_short]:-}"
    content="${content//__COOKIE__/$auth_cookie}"
    printf '%s' "$content" | kubectl apply -f - >/dev/null 2>&1
    log_info "Submitted Nuclei job $JOB_NAME reading ConfigMap $cm_name"
  done

  # --- Nuclei harvest function (runs in background) ---
  # Waits for each Nuclei job, extracts results, imports to DefectDojo.
  # Output is buffered to a temp file and printed when joined.
  nuclei_harvest() {
    for i in "${!NUCLEI_JOB_NAMES[@]}"; do
      JOB_NAME="${NUCLEI_JOB_NAMES[$i]}"
      target_short="${NUCLEI_TARGET_SHORTS[$i]}"

      log_info "Waiting for $JOB_NAME ..."
      # 900s was not enough: nuclei downloads and signature-verifies its
      # template set on every run before issuing a single request, and the
      # job was being killed mid-scan and reported as SKIP. Trimming the
      # template set (see nuclei-phase2-job.yaml) is the real fix; this is
      # the safety margin behind it.
      if ! wait_for_job "$JOB_NAME" scanning 1800 "nuclei scan ($target_short)"; then
        kubectl delete job "$JOB_NAME" -n scanning >/dev/null 2>&1 || true
        continue
      fi

      nuclei_report="$REPORTS_DIR/nuclei_${target_short}_${TIMESTAMP}.json"
      nuclei_log="$REPORTS_DIR/nuclei_${target_short}_${TIMESTAMP}_debug.log"
      pod_name=$(kubectl get pods -n scanning -l "job-name=$JOB_NAME" --no-headers -o name | head -1)
      [ -n "$pod_name" ] && kubectl logs -n scanning "${pod_name#pod/}" > "$nuclei_log" 2>/dev/null || true

      kubectl logs -n scanning "${pod_name#pod/}" -c nuclei 2>/dev/null \
        | sed -n '/===NUCLEI_RESULTS_START===/,/===NUCLEI_RESULTS_END===/{ /===NUCLEI_RESULTS/d; p; }' \
        | grep '^{' \
        | jq -s '.' > "$nuclei_report" 2>/dev/null || echo '[]' > "$nuclei_report"

      if [ -s "$nuclei_report" ] && [ "$(cat "$nuclei_report")" != "[]" ]; then
        count=$(jq 'length' "$nuclei_report" 2>/dev/null || echo "?")
        log_success "Nuclei found $count findings for $target_short"
        dd_import "$nuclei_report" "Nuclei Scan" "web,nuclei,$target_short" "$target_short"
      else
        log_warning "Nuclei: no findings for $target_short -- check $nuclei_log"
      fi
      kubectl delete job "$JOB_NAME" -n scanning --ignore-not-found >/dev/null 2>&1 || true
    done
  }

  # Launch harvest in background — Step 5 starts immediately.
  nuclei_harvest_log=$(mktemp)
  nuclei_harvest > "$nuclei_harvest_log" 2>&1 &
  NUCLEI_HARVEST_PID=$!
  log_info "Nuclei harvest running in background (PID $NUCLEI_HARVEST_PID) — starting Step 5 immediately"
fi

# ============================================================
# Step 5: SQLMap / ffuf / XSStrike DAST scans per discovered target
#
# Performance: scanners within a single target run in parallel.
# Each subshell buffers its output to a temp file; after all
# three finish, the buffered logs are printed sequentially.
# In --quick mode, xss is skipped.
# ============================================================
log_info "=== Step 5: SQLMap / ffuf / XSStrike scans ==="
GENERIC_SCAN_TYPE="Generic Findings Import"

# Launch scanners in parallel (each in a subshell, output buffered) across all targets.
step5_pids=()
step5_logs=()

for target_short in "${!TARGETS_CM[@]}"; do
  cm_name="${TARGETS_CM[$target_short]}"
  # Derive the target URL from the still-available DISCOVERY_TARGETS array.
  target_url=""
  for pair in "${DISCOVERY_TARGETS[@]}"; do
    if [ "${pair%%.*}" = "$target_short" ]; then target_url="http://$pair"; break; fi
  done

  log_info "-- target=$target_short (cm=$cm_name, url=$target_url) --"

  # Phase 0: skip sqlmap/xss for auth-gated targets (DVWA etc).
  dast_disabled=0
  for disabled in "${DAST_DISABLED_TARGETS[@]:-}"; do
    [ "$disabled" = "$target_short" ] && dast_disabled=1
  done
  if [ "$dast_disabled" = "1" ]; then
    log_info "$target_short: skipping sqlmap/xss (auth-gated target, see DAST_DISABLED_TARGETS in scan-all.sh)"
  fi

  auth_cookie="${TARGETS_COOKIE[$target_short]:-}"

  if [ "$dast_disabled" = "0" ]; then
    tmplog=$(mktemp)
    step5_logs+=("$tmplog")
    ( run_generic_scanner sqlmap "$SCANNERS_DIR/sqlmap-job.yaml" "$target_short" SQLMAP "$GENERIC_SCAN_TYPE" 600 TARGETS_CM="$cm_name" COOKIE="$auth_cookie" ) > "$tmplog" 2>&1 &
    step5_pids+=($!)
  fi

  tmplog=$(mktemp)
  step5_logs+=("$tmplog")
  ( run_generic_scanner ffuf "$SCANNERS_DIR/ffuf-job.yaml" "$target_short" FFUF "$GENERIC_SCAN_TYPE" 600 TARGET_URL="$target_url" ) > "$tmplog" 2>&1 &
  step5_pids+=($!)

  if [ "$dast_disabled" = "0" ] && [ "$QUICK_MODE" = "0" ]; then
    tmplog=$(mktemp)
    step5_logs+=("$tmplog")
    ( run_generic_scanner xss "$SCANNERS_DIR/xss-job.yaml" "$target_short" XSS "$GENERIC_SCAN_TYPE" 600 TARGETS_CM="$cm_name" COOKIE="$auth_cookie" ) > "$tmplog" 2>&1 &
    step5_pids+=($!)
  fi
done

# Wait for all scanners for all targets, then print buffered output.
for i in "${!step5_pids[@]}"; do
  wait "${step5_pids[$i]}" || true
  cat "${step5_logs[$i]}"
  rm -f "${step5_logs[$i]}"
done

# ============================================================
# Step 5b: Join Nuclei harvest (background from Step 4)
#
# If Nuclei harvest is still running, wait for it here. Its output
# was buffered to a temp file; print it now.
# ============================================================
if [ -n "$NUCLEI_HARVEST_PID" ]; then
  log_info "Waiting for Nuclei harvest to finish (background PID $NUCLEI_HARVEST_PID)..."
  wait "$NUCLEI_HARVEST_PID" || true
  log_info "=== Nuclei results (from background harvest) ==="
  cat "$nuclei_harvest_log" 2>/dev/null || true
  rm -f "$nuclei_harvest_log"
fi

# ============================================================
# Step 6: Cleanup + Status -- remove per-run ConfigMaps, write status CM.
# ============================================================
for target_short in "${!TARGETS_CM[@]}"; do
  kubectl delete configmap "${TARGETS_CM[$target_short]}" -n scanning --ignore-not-found >/dev/null 2>&1 || true
done

# (ZAP scan removed due to high memory consumption on k3d node)

# --- Summary Table ---
echo ""
log_info "========================================================"
if [ "$QUICK_MODE" = "1" ]; then
  log_success "SCAN PIPELINE COMPLETE! (quick mode — nuclei + xss skipped)"
else
  log_success "SCAN PIPELINE COMPLETE!"
fi
DURATION=$((SECONDS - START_TIME))
log_info "Total execution time: $((DURATION / 60))m $((DURATION % 60))s"
log_info "========================================================"
echo ""
echo "╔══════════════════════╦═══════╦════════╦══════╦════════╦══════╗"
echo "║ Target               ║ Grype ║ Nuclei ║ ffuf ║ sqlmap ║ xss  ║"
echo "╠══════════════════════╬═══════╬════════╬══════╬════════╬══════╣"

for target_pair in "${DISCOVERY_TARGETS[@]}"; do
  ts="${target_pair%%.*}"
  # The scan step normalizes the image shortname `web-dvwa` to `dvwa`, so the
  # report is grype_dvwa_<ts>.json. This table used to look only for the
  # legacy grype_web-dvwa_<ts>.json name and printed "--" for DVWA even
  # though 2097 findings had just been imported. Try current name first,
  # then legacy, so old report sets still render.
  grype_file=""
  for _cand in "$REPORTS_DIR/grype_${ts}_${TIMESTAMP}.json" \
               "$REPORTS_DIR/grype_web-${ts}_${TIMESTAMP}.json"; do
    if [ -s "$_cand" ]; then grype_file="$_cand"; break; fi
  done

  if [ -n "$grype_file" ] && [ -s "$grype_file" ]; then
    g_count=$(jq '.matches | length' "$grype_file" 2>/dev/null || echo "ERR")
  else
    g_count="--"
  fi
  
  # Helper to parse standard tool reports
  get_count() {
    local t=$1
    local file="$REPORTS_DIR/${t}_${ts}_${TIMESTAMP}.json"
    if [ ! -f "$file" ]; then
      # If the raw log exists but no JSON, it might have timed out or failed parsing
      local raw="$REPORTS_DIR/${t}_${ts}_${TIMESTAMP}.raw"
      local txt="$REPORTS_DIR/${t}_${ts}_${TIMESTAMP}.txt" # Some like nuclei don't have .raw but .jsonl
      if [ -f "$raw" ] || ls "$REPORTS_DIR/${t}_${ts}_${TIMESTAMP}"* >/dev/null 2>&1; then
        echo "ERR"
      else
        echo "SKIP"
      fi
    else
      jq '.findings | length' "$file" 2>/dev/null || jq 'length' "$file" 2>/dev/null || echo "0"
    fi
  }

  n_count=$(get_count nuclei)
  f_count=$(get_count ffuf)
  s_count=$(get_count sqlmap)
  x_count=$(get_count xss)
  
  # Format with printf for alignment
  printf "║ %-20s ║ %-5s ║ %-6s ║ %-4s ║ %-6s ║ %-4s ║\n" "$ts" "$g_count" "$n_count" "$f_count" "$s_count" "$x_count"
done
echo "╚══════════════════════╩═══════╩════════╩══════╩════════╩══════╝"
echo ""

log_info "Reports : $REPORTS_DIR"
log_info "DefectDojo: $DD_URL"
log_info "========================================================"
echo ""
ls -lh "$REPORTS_DIR" 2>/dev/null | grep "$TIMESTAMP" || log_warning "No reports for this run"

# --- Collect per-scanner counts for SQLite + ConfigMap ---
# Parse the count from normalized JSON files produced by each scanner.
get_norm_count() {
  local t=$1 ts=$2
  local file="$REPORTS_DIR/${t}_${ts}_${TIMESTAMP}.json"
  if [ -f "$file" ]; then
    jq '.findings | length' "$file" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# Sum across all targets for each scanner
TOTAL_GRYPE=0 TOTAL_NUCLEI=0 TOTAL_FFUF=0 TOTAL_SQLMAP=0 TOTAL_XSS=0
TARGET_COUNTS_CSV=""
for target_pair in "${DISCOVERY_TARGETS[@]}"; do
  ts="${target_pair%%.*}"
  # Grype report filename. The scan step normalizes the image shortname
  # `web-dvwa` to `dvwa` (see IMAGE_SHORT above), so the file is
  # grype_dvwa_<ts>.json — but this counter was still looking for
  # grype_web-dvwa_<ts>.json. jq failed, `|| echo 0` swallowed it, and
  # DVWA's Grype findings (2097 in the last run) were recorded as zero
  # everywhere downstream: SQLite, voc-history, the Grafana ConfigMap and
  # the summary table. Try the current name first, fall back to the legacy
  # one so older report sets still total correctly.
  g=0
  for _cand in "$REPORTS_DIR/grype_${ts}_${TIMESTAMP}.json" \
               "$REPORTS_DIR/grype_web-${ts}_${TIMESTAMP}.json"; do
    if [ -s "$_cand" ]; then
      g=$(jq '.matches | length' "$_cand" 2>/dev/null || echo 0)
      break
    fi
  done
  n=$(get_norm_count nuclei "$ts")
  f=$(get_norm_count ffuf "$ts")
  s=$(get_norm_count sqlmap "$ts")
  x=$(get_norm_count xss "$ts")
  TOTAL_GRYPE=$((TOTAL_GRYPE + g))
  TOTAL_NUCLEI=$((TOTAL_NUCLEI + n))
  TOTAL_FFUF=$((TOTAL_FFUF + f))
  TOTAL_SQLMAP=$((TOTAL_SQLMAP + s))
  TOTAL_XSS=$((TOTAL_XSS + x))
  # Build CSV for target-level breakdown
  [ -n "$TARGET_COUNTS_CSV" ] && TARGET_COUNTS_CSV="${TARGET_COUNTS_CSV},"
  TARGET_COUNTS_CSV="${TARGET_COUNTS_CSV}${ts}:grype:${g},${ts}:nuclei:${n},${ts}:ffuf:${f},${ts}:sqlmap:${s},${ts}:xss:${x}"
done

# --- Record scan run in SQLite ---
VOC_DB="/workspace/scanners/voc-scans.db"
TARGET_NAMES=""
for tp in "${DISCOVERY_TARGETS[@]}"; do
  TARGET_NAMES="$TARGET_NAMES ${tp%%.*}"
done
TARGET_NAMES="${TARGET_NAMES# }"

if python3 "$SCRIPT_DIR/voc-db.py" --db "$VOC_DB" record \
    --timestamp "$TIMESTAMP" \
    --duration "$DURATION" \
    --quick-mode "$QUICK_MODE" \
    --targets "$TARGET_NAMES" \
    --counts "grype:$TOTAL_GRYPE,nuclei:$TOTAL_NUCLEI,ffuf:$TOTAL_FFUF,sqlmap:$TOTAL_SQLMAP,xss:$TOTAL_XSS" \
    --target-counts "$TARGET_COUNTS_CSV" \
    --reports-dir "$REPORTS_DIR" 2>/dev/null; then
  log_success "Scan recorded in SQLite database ($VOC_DB)"
else
  log_warning "Failed to record scan in SQLite (non-critical)"
fi

# --- Rotate old report files (keep last 7 runs) ---
ROTATED=$(python3 "$SCRIPT_DIR/voc-db.py" --db "$VOC_DB" rotate --keep 7 --reports-dir "$REPORTS_DIR" 2>/dev/null) || true
[ -n "$ROTATED" ] && log_info "$ROTATED"

# --- Write scan status ConfigMap for n8n dashboard ---
SCAN_STATUS_JSON=$(cat <<EOJSON
{
  "timestamp": "$TIMESTAMP",
  "duration_seconds": $DURATION,
  "quick_mode": $( [ "$QUICK_MODE" = "1" ] && echo 'true' || echo 'false' ),
  "targets": "${DISCOVERY_TARGETS[*]}",
  "reports_dir": "$REPORTS_DIR",
  "defectdojo_url": "$DD_URL",
  "grype_count": $TOTAL_GRYPE,
  "nuclei_count": $TOTAL_NUCLEI,
  "ffuf_count": $TOTAL_FFUF,
  "sqlmap_count": $TOTAL_SQLMAP,
  "xss_count": $TOTAL_XSS
}
EOJSON
)
kubectl delete configmap voc-scan-status -n scanning --ignore-not-found >/dev/null 2>&1 || true
# Retry the write — the Grafana "Last Scan" panels read this ConfigMap,
# and a transient API hiccup here must not blank the dashboard.
STATUS_WRITTEN=0
for attempt in 1 2 3 4 5; do
  if kubectl create configmap voc-scan-status -n scanning \
    --from-literal=status.json="$SCAN_STATUS_JSON" >/dev/null 2>&1; then
    STATUS_WRITTEN=1
    log_info "Scan status written to ConfigMap voc-scan-status"
    break
  fi
  sleep 5
done
[ "$STATUS_WRITTEN" = "0" ] && log_warning "Failed to write scan status ConfigMap after 5 attempts"

# --- Automatic Post-Scan Pipeline Automation ---
log_info "Running post-scan automation (prioritization pass & credential sync)..."
# 1. Sync API keys across all namespaces & env
# TOOLBOX_DIR was never defined: under `set -u` the expansion below aborted
# the whole script right here, so neither the key sync nor the prioritization
# pass that follows it ever ran after a scan. The redirect and `|| true` did
# not help — an unbound variable fails during expansion, before the command
# is executed. Findings therefore sat unscored until the service's hourly pass.
TOOLBOX_DIR="${TOOLBOX_DIR:-$(dirname "$SCRIPT_DIR")/toolbox}"
if [ -f "$TOOLBOX_DIR/profile.sh" ]; then
  # shellcheck disable=SC1091
  source "$TOOLBOX_DIR/profile.sh" 2>/dev/null || true
  voc_sync_keys 2>/dev/null || true
else
  log_warning "toolbox profile not found at $TOOLBOX_DIR — skipping key sync"
fi

# 2. Trigger Prioritization Service scoring pass
kubectl exec -n voc-core deploy/prioritization-service -- python3 -c "
import urllib.request, json
try:
    req = urllib.request.Request('http://localhost:8000/score', method='POST')
    urllib.request.urlopen(req, timeout=120)
except Exception: pass
" 2>/dev/null || true

# 3. Refresh voc-metrics-exporter to stream fresh scan metrics to Grafana immediately
kubectl rollout restart deployment/voc-metrics-exporter -n monitoring >/dev/null 2>&1 || true

log_success "Post-scan pipeline automation completed successfully!"
exit 0