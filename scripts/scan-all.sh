#!/bin/bash
set -euo pipefail

# ============================================================
# VOC - Scan Pipeline (k8s-native)
#
# Phase 1 DISCOVERY  : gospider crawls each target once -> ConfigMap of URLs
# Phase 2 EXPLOIT    : nuclei / sqlmap / xsstrike / ffuf read that ConfigMap
# Phase 3 STORE/TRI  : every normalized result -> DefectDojo (central store)
#                      which the prioritization-service + n8n workflow read.
#
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
  "dvwa"
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
}

# wait_for_job  : poll a k8s Job until complete/failed/timeout. On failure
#                 dump pod status + last 30 log lines so the user sees *why*
#                 without a manual kubectl.
wait_for_job() {
  local job_name="$1" namespace="$2" timeout_sec="$3" label="$4"
  local elapsed=0 interval=5

  while [ "$elapsed" -lt "$timeout_sec" ]; do
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

  if ! python3 "$SCRIPT_DIR/normalize-findings.py" "$tool" "$raw" "$norm" "$target_short" >/dev/null 2>&1; then
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
    dd_import "$norm" "$scan_type" "web,$tool,$target_short" \
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
# Step 2: Phase 1 -- Discovery (gospider)
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
log_info "=== Step 2: Discovery (gospider) -- building URL inventory ==="

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

  # Filter to URLs WITH parameters -- these are the sqlmap/xss candidates.
  if [ -s "$all_urls" ]; then
    grep -E '\?[A-Za-z0-9_.-]+=' "$all_urls" > "$param_urls" 2>/dev/null || true
  else
    : > "$param_urls"
  fi
  # Gospider's static crawl misses SPA/JS-reachable and REST-API routes,
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
# Step 3: Grype SCA scan (Docker-based, DB cached in volume)
# ============================================================
log_info "=== Step 3: Grype SCA scan ==="

for GRYPE_IMAGE in "bkimminich/juice-shop:latest" "vulnerables/web-dvwa:latest"; do
  IMAGE_SHORT=$(echo "$GRYPE_IMAGE" | sed 's|.*/||; s|:.*||')
  GRYPE_REPORT="$REPORTS_DIR/grype_${IMAGE_SHORT}_$TIMESTAMP.json"
  # Phase 0 fix: previously Grype stderr was sent to /dev/null, so a Grype
  # run that failed (stale DB snapshot, image pull error, rate limit,
  # etc.) showed only "[ERROR] Grype scan failed for X" with no detail.
  # Capture stderr to a sidecar log so the cause is diagnosable.
  GRYPE_STDERR="$REPORTS_DIR/grype_${IMAGE_SHORT}_${TIMESTAMP}_stderr.log"

  log_info "Grype -> $GRYPE_IMAGE (via Docker)"

  # "voc-grype-db" is a Docker named volume that persists the Grype
  # vulnerability database (~100 MB). First run downloads it; subsequent
  # runs reuse the cached copy (saves 30-60 s per run).
  if docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v voc-grype-db:/root/.cache/grype \
    anchore/grype:latest "$GRYPE_IMAGE" -o json > "$GRYPE_REPORT" 2>"$GRYPE_STDERR"; then

    if [ -s "$GRYPE_REPORT" ]; then
      FINDING_COUNT=$(jq '.matches | length' "$GRYPE_REPORT" 2>/dev/null || echo "?")
      log_success "Grype found $FINDING_COUNT vulnerabilities in $IMAGE_SHORT"
      dd_import "$GRYPE_REPORT" "Anchore Grype" "container,grype,$IMAGE_SHORT"
    else
      log_warning "Grype report is empty for $IMAGE_SHORT (stderr at $GRYPE_STDERR)"
    fi
  else
    log_error "Grype scan failed for $IMAGE_SHORT -- stderr logged to $GRYPE_STDERR"
    # Show the first 20 lines of stderr inline so the operator doesn't
    # always have to open the sidecar file.
    tail -n 20 "$GRYPE_STDERR" 2>/dev/null | sed 's/^/  > /' || true
  fi
done

# ============================================================
# Step 4: Nuclei DAST scan per discovered target
#
# Phase 1 already crawled each target, so here we drop the gospider init
# container that the previous version ran per-Nuclei-job (duplicate work)
# and instead mount the per-target ConfigMap's all_urls.txt directly into
# /targets. Result extraction is unchanged (sed/jq between markers).
# ============================================================
log_info "=== Step 4: Nuclei DAST scan ==="
NUCLEI_JOB_NAMES=()
NUCLEI_TARGET_SHORTS=()

for target_short in "${!TARGETS_CM[@]}"; do
  cm_name="${TARGETS_CM[$target_short]}"
  JOB_NAME="nuclei-${target_short}-${TIMESTAMP}"
  NUCLEI_JOB_NAMES+=("$JOB_NAME")
  NUCLEI_TARGET_SHORTS+=("$target_short")

  kubectl delete job "$JOB_NAME" -n scanning --ignore-not-found >/dev/null 2>&1
  # Substitute the two markers we care about, then apply.
  content="$(cat "$SCANNERS_DIR/nuclei-phase2-job.yaml")"
  content="${content//__JOB_NAME__/$JOB_NAME}"
  content="${content//__TARGETS_CM__/$cm_name}"
  printf '%s' "$content" | kubectl apply -f - >/dev/null 2>&1
  log_info "Submitted Nuclei job $JOB_NAME reading ConfigMap $cm_name"
done

# --- Wait + extract per Nuclei job ---
for i in "${!NUCLEI_JOB_NAMES[@]}"; do
  JOB_NAME="${NUCLEI_JOB_NAMES[$i]}"
  target_short="${NUCLEI_TARGET_SHORTS[$i]}"

  log_info "Waiting for $JOB_NAME ..."
  if ! wait_for_job "$JOB_NAME" scanning 600 "nuclei scan ($target_short)"; then
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
    dd_import "$nuclei_report" "Nuclei Scan" "web,nuclei,$target_short"
  else
    log_warning "Nuclei: no findings for $target_short -- check $nuclei_log"
  fi
  kubectl delete job "$JOB_NAME" -n scanning --ignore-not-found >/dev/null 2>&1 || true
done

# ============================================================
# Step 5: SQLMap / ffuf / XSStrike DAST scans per discovered target
#
# Each Phase 2 scanner reads the per-target ConfigMap (sqlmap/xss need
# param_urls.txt; ffuf fuzzes paths off __TARGET_URL__). Raw output is
# re-emitted between ===<TOOL>_RESULTS_START=== / ===_END=== markers,
# pulled via kubectl logs, normalized by scripts/normalize-findings.py
# into DefectDojo "Generic Findings Import" JSON, then re-imported via
# the same dd_import() path used by Grype/Nuclei.
# ============================================================
log_info "=== Step 5: SQLMap / ffuf / XSStrike scans ==="
GENERIC_SCAN_TYPE="Generic Findings Import"

for target_short in "${!TARGETS_CM[@]}"; do
  cm_name="${TARGETS_CM[$target_short]}"
  # Derive the target URL from the still-available DISCOVERY_TARGETS array.
  target_url=""
  for pair in "${DISCOVERY_TARGETS[@]}"; do
    if [ "${pair%%.*}" = "$target_short" ]; then target_url="http://$pair"; break; fi
  done

  log_info "-- target=$target_short (cm=$cm_name, url=$target_url) --"

  # Phase 0: skip sqlmap/xss for auth-gated targets (DVWA etc).
  # Their interesting injection endpoints sit behind a login cookie and
  # unauthenticated scanning produces 0 findings + wasted minutes.
  # ffuf + nuclei still run for these targets. Phase A will replace this
  # check with a per-target `enabled_dast:` field from scanners/targets.yaml.
  dast_disabled=0
  for disabled in "${DAST_DISABLED_TARGETS[@]:-}"; do
    [ "$disabled" = "$target_short" ] && dast_disabled=1
  done
  if [ "$dast_disabled" = "1" ]; then
    log_info "$target_short: skipping sqlmap/xss (auth-gated target, see DAST_DISABLED_TARGETS in scan-all.sh)"
  fi

  # Each scanner is independent -- a single failure must NOT abort the
  # loop (otherwise a flaky ffuf run also skips sqlmap/xss for the same
  # target and the rest of the pipeline). `|| true` keeps the for-loop
  # alive under `set -e`; run_generic_scanner already logs the failure.
  if [ "$dast_disabled" = "0" ]; then
    run_generic_scanner sqlmap "$SCANNERS_DIR/sqlmap-job.yaml"  "$target_short" SQLMAP "$GENERIC_SCAN_TYPE" 600 TARGETS_CM="$cm_name" || true
  fi
  run_generic_scanner ffuf   "$SCANNERS_DIR/ffuf-job.yaml"    "$target_short" FFUF   "$GENERIC_SCAN_TYPE" 600 TARGET_URL="$target_url" || true
  if [ "$dast_disabled" = "0" ]; then
    run_generic_scanner xss    "$SCANNERS_DIR/xss-job.yaml"    "$target_short" XSS    "$GENERIC_SCAN_TYPE" 600 TARGETS_CM="$cm_name" || true
  fi
done

# ============================================================
# Step 6: Cleanup -- remove the per-run ConfigMaps (raw URLs persisted
# in $REPORTS_DIR for forensics, so the CM is no longer needed).
# ============================================================
for target_short in "${!TARGETS_CM[@]}"; do
  kubectl delete configmap "${TARGETS_CM[$target_short]}" -n scanning --ignore-not-found >/dev/null 2>&1 || true
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