#!/bin/bash
set -euo pipefail

# ============================================================
# VOC - Scan Pipeline
# Adapted from colleague's scan-all.sh with env-driven config.
# Runs Grype + Nuclei + ZAP and imports results to DefectDojo.
# Designed to run inside the VOC toolbox container.
# ============================================================

# --- Configuration (override via .env or env vars) ---
REPO_DIR="${REPO_DIR:-/workspace}"
SCANNERS_DIR="${SCANNERS_DIR:-$REPO_DIR/scanners}"
REPORTS_DIR="${REPORTS_DIR:-$SCANNERS_DIR/reports}"
CONFIG_DIR="${CONFIG_DIR:-$REPO_DIR/config}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

DD_API_KEY="${DD_API_KEY:?ERROR: DD_API_KEY is required (set in .env)}"
DD_URL="${DD_URL:-http://localhost:8080}"
DD_ENGAGEMENT_ID="${DD_ENGAGEMENT_ID:-}"
DD_PRODUCT_NAME="${DD_PRODUCT_NAME:-Lab Targets}"
DD_ENGAGEMENT_NAME="${DD_ENGAGEMENT_NAME:-Continuous Scanning}"

DOCKER_NETWORK="${DOCKER_NETWORK:-voc-scan}"
TARGETS="${TARGETS:-juice-shop:3000 dvwa:80}"
GRYPE_IMAGE="${GRYPE_IMAGE:-alpine:latest}"
CLEANUP_TARGETS="${CLEANUP_TARGETS:-true}"

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Helper: upload to DefectDojo ---
dd_import() {
  local file="$1" scan_type="$2" tags="$3"
  local extra_args=""
  if [ -n "$DD_ENGAGEMENT_ID" ]; then
    extra_args="-F engagement=$DD_ENGAGEMENT_ID"
  else
    extra_args="-F product_name=$DD_PRODUCT_NAME -F engagement_name=$DD_ENGAGEMENT_NAME -F auto_create_contexts=true"
  fi
  curl -sS -X POST "$DD_URL/api/v2/import-scan/" \
    -H "Authorization: Token $DD_API_KEY" \
    -F "scan_type=$scan_type" \
    -F "file=@$file" \
    -F "tags=$tags" \
    $extra_args \
    -o /dev/null -w "%{http_code}"
}

# --- Prep ---
mkdir -p "$REPORTS_DIR" "$SCANNERS_DIR/zap" "$SCANNERS_DIR/nuclei-templates"

# --- Step 0: Check prerequisites ---
log_info "=== ÉTAPE 0 : Vérification des prérequis ==="
if ! curl -s -o /dev/null -w "%{http_code}" "$DD_URL" | grep -q "200\|302"; then
  log_error "DefectDojo inaccessible sur $DD_URL"
  log_error "Lance un port-forward : kubectl port-forward -n voc-core svc/defectdojo-django-svc 8080:8080"
  exit 1
fi
log_success "DefectDojo accessible"

docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || docker network create "$DOCKER_NETWORK"

# --- Step 1: Ensure targets are running ---
log_info "=== ÉTAPE 1 : Démarrage des cibles ==="

launch_target() {
  local name="$1" image="$2" port="$3"
  if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
    log_warning "Conteneur $name déjà en cours -> remplacement"
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
  log_info "Lancement de $name..."
  docker run -d --name "$name" --network "$DOCKER_NETWORK" -p "${port}:${port}" "$image" >/dev/null
}

launch_target juice-shop "bkimminich/juice-shop" 3000
launch_target dvwa "vulnerables/web-dvwa:latest" 8082

sleep 5
log_success "Cibles opérationnelles sur le réseau '$DOCKER_NETWORK'"

# --- Step 2: Grype (SCA - container image scan) ---
log_info "=== ÉTAPE 2 : Scan Grype (image: $GRYPE_IMAGE) ==="
GRYPE_REPORT="$REPORTS_DIR/grype_$TIMESTAMP.json"

docker run --rm anchore/grype:latest "$GRYPE_IMAGE" -o json > "$GRYPE_REPORT" 2>/dev/null || true

if [ -s "$GRYPE_REPORT" ]; then
  log_success "Scan Grype terminé"
  log_info "Import dans DefectDojo..."
  code=$(dd_import "$GRYPE_REPORT" "Anchore Grype" "container")
  log_success "Rapport Grype importé (HTTP $code)"
else
  log_error "Rapport Grype vide ou manquant"
fi

# --- Step 3: Nuclei (multi-target DAST) ---
log_info "=== ÉTAPE 3 : Scan Nuclei (cibles: $TARGETS) ==="
set +e

for target in $TARGETS; do
  name="${target%%:*}"
  port="${target##*:}"
  clean="${name}_${port}"
  NUCLEI_REPORT="$REPORTS_DIR/nuclei_${clean}_$TIMESTAMP.jsonl"
  NUCLEI_VALID="$REPORTS_DIR/nuclei_${clean}_$TIMESTAMP.json"

  log_info "Nuclei -> http://$target ..."
  docker run --rm --network "$DOCKER_NETWORK" \
    -v "$REPORTS_DIR:/output" \
    projectdiscovery/nuclei:latest \
    -u "http://$target" -jsonl -o "/output/$(basename "$NUCLEI_REPORT")"

  if [ -s "$NUCLEI_REPORT" ]; then
    # Convert JSONL to JSON array for DefectDojo parser
    jq -s '.' "$NUCLEI_REPORT" > "$NUCLEI_VALID" 2>/dev/null || true
    if [ -s "$NUCLEI_VALID" ]; then
      code=$(dd_import "$NUCLEI_VALID" "Nuclei Scan" "web")
      log_success "Rapport Nuclei ($target) importé (HTTP $code)"
    fi
  else
    log_warning "Nuclei : aucune vulnérabilité pour $target"
  fi
done

set -e

# --- Step 4: ZAP (deep DAST with AJAX spider) ---
log_info "=== ÉTAPE 4 : Scan ZAP (DAST avec AJAX) ==="
ZAP_REPORT="$REPORTS_DIR/zap_$TIMESTAMP.xml"

ZAP_PLAN="$CONFIG_DIR/zap-plan.yaml"
if [ ! -f "$ZAP_PLAN" ]; then
  log_warning "Plan ZAP non trouvé ($ZAP_PLAN). Génération dynamique..."
  mkdir -p "$CONFIG_DIR"
  cat > "$ZAP_PLAN" << 'ZAPEOF'
env:
  contexts:
    - name: "juice-shop"
      urls:
        - "http://juice-shop:3000"
    - name: "dvwa"
      urls:
        - "http://dvwa:80"
  parameters:
    failOnError: false
jobs:
  - type: spider
    parameters:
      context: juice-shop
      maxDuration: 3
  - type: spider
    parameters:
      context: dvwa
      maxDuration: 3
  - type: passiveScan-wait
    parameters:
      maxDuration: 2
  - type: activeScan
    parameters:
      context: juice-shop
      maxScanDurationInMins: 5
      policy: Default Policy
  - type: report
    parameters:
      template: traditional-xml
      reportDir: /zap/wrk
      reportFile: zap-report-auto.xml
ZAPEOF
fi

log_info "Lancement du moteur ZAP (Automation Framework)..."
set +e
docker run --rm -t \
  -v "$SCANNERS_DIR:/zap/wrk" \
  -v "$CONFIG_DIR:/zap/config" \
  --network "$DOCKER_NETWORK" \
  --memory=3g --cpus=2 \
  zaproxy/zap-stable zap.sh -cmd \
  -autorun /zap/config/zap-plan.yaml 2>&1
set -e

# ZAP may write the report to /zap/wrk/ or /zap/wrk/zap/
ZAP_FOUND=""
for path in "$SCANNERS_DIR/zap-report-auto.xml" "$SCANNERS_DIR/zap/zap-report-auto.xml"; do
  if [ -f "$path" ]; then
    cp "$path" "$ZAP_REPORT"
    ZAP_FOUND="$path"
    break
  fi
done

if [ -n "$ZAP_FOUND" ]; then
  log_success "Scan ZAP complété : $ZAP_REPORT"
  code=$(dd_import "$ZAP_REPORT" "ZAP Scan" "web")
  log_success "Rapport ZAP importé (HTTP $code)"
  rm -f "$SCANNERS_DIR/zap-report-auto.xml" "$SCANNERS_DIR/zap/zap-report-auto.xml" 2>/dev/null || true
else
  log_error "ZAP n'a pas généré de rapport XML"
fi

# --- Cleanup ---
if [ "$CLEANUP_TARGETS" = "true" ]; then
  log_info "Nettoyage des conteneurs cibles..."
  docker rm -f juice-shop dvwa >/dev/null 2>&1 || true
fi

# --- Summary ---
echo ""
log_info "========================================================"
log_success "PIPELINE DE SCAN TERMINÉ !"
log_info "========================================================"
log_info "Rapports   : $REPORTS_DIR"
log_info "DefectDojo : $DD_URL"
log_info "========================================================"
ls -lh "$REPORTS_DIR" | grep "$TIMESTAMP" || true
