#!/usr/bin/env bash
# =============================================================================
# upload-to-defectdojo.sh
# Descarga el informe de SonarQube y lo importa en DefectDojo
# =============================================================================

set -euo pipefail

# ── Parámetros ────────────────────────────────────────────────────────────────
SONAR_URL="${SONAR_URL:-http://localhost:9000}"
SONAR_TOKEN="${SONAR_TOKEN:?'Variable SONAR_TOKEN requerida'}"
PROJECT_KEY="${PROJECT_KEY:-webgoat}"

DOJO_URL="${DOJO_URL:-http://localhost:8080}"
DOJO_API_KEY="${DOJO_API_KEY:?'Variable DOJO_API_KEY requerida'}"
DOJO_PRODUCT_NAME="${DOJO_PRODUCT_NAME:-WebGoat}"
DOJO_ENGAGEMENT_NAME="${DOJO_ENGAGEMENT_NAME:-SonarQube-$(date +%Y%m%d)}"

REPORT_FILE="/tmp/sonar-report-${PROJECT_KEY}-$(date +%s).json"

echo "══════════════════════════════════════════════════════════════════"
echo "  SonarQube → DefectDojo   |   Proyecto: ${PROJECT_KEY}"
echo "══════════════════════════════════════════════════════════════════"

# ─── 1. Comprobar estado del Quality Gate ────────────────────────────────────
echo ""
echo "🔍 Verificando estado del Quality Gate..."

QG_STATUS=$(curl -sf \
  -u "${SONAR_TOKEN}:" \
  "${SONAR_URL}/api/qualitygates/project_status?projectKey=${PROJECT_KEY}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['projectStatus']['status'])")

echo "   Quality Gate: ${QG_STATUS}"
if [[ "$QG_STATUS" == "ERROR" ]]; then
  echo "   ⚠️  El proyecto NO pasa el Quality Gate – se sube igualmente a DefectDojo."
fi

# ─── 2. Descargar issues desde SonarQube ─────────────────────────────────────
echo ""
echo "📥 Descargando issues de SonarQube..."

PAGE=1
PAGE_SIZE=500
TOTAL_ISSUES=()

while true; do
  RESPONSE=$(curl -sf \
    -u "${SONAR_TOKEN}:" \
    "${SONAR_URL}/api/issues/search?componentKeys=${PROJECT_KEY}&ps=${PAGE_SIZE}&p=${PAGE}&statuses=OPEN,REOPENED&s=SEVERITY&asc=false")

  COUNT=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('issues',[])))")
  TOTAL=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total',0))")

  echo "   Página ${PAGE}: ${COUNT} issues (total: ${TOTAL})"

  echo "$RESPONSE" >> /tmp/sonar-raw-${PAGE}.json
  TOTAL_ISSUES+=("$RESPONSE")

  if (( PAGE * PAGE_SIZE >= TOTAL )); then
    break
  fi
  PAGE=$((PAGE + 1))
done

# Combinar páginas en un único JSON
python3 - <<'PYEOF'
import json, glob, sys

all_issues = []
for f in sorted(glob.glob('/tmp/sonar-raw-*.json')):
    with open(f) as fh:
        data = json.load(fh)
        all_issues.extend(data.get('issues', []))

report = {
    "total": len(all_issues),
    "issues": all_issues
}

import os
out_file = os.environ.get('REPORT_FILE', '/tmp/sonar-report.json')
with open(out_file, 'w') as fh:
    json.dump(report, fh, indent=2)

print(f"   Informe guardado: {out_file}  ({len(all_issues)} issues)")
PYEOF

export REPORT_FILE
echo "✅ Issues descargados: ${REPORT_FILE}"

# ─── 3. Transformar al formato CycloneDX / genérico de SonarQube ─────────────
# DefectDojo acepta directamente el formato JSON de SonarQube via parser nativo.
# Lo renombramos a .json y usamos el tipo "SonarQube Scan".

UPLOAD_FILE="${REPORT_FILE}"

# ─── 4. Buscar o crear Producto en DefectDojo ─────────────────────────────────
echo ""
echo "🔍 Buscando producto '${DOJO_PRODUCT_NAME}' en DefectDojo..."

PRODUCT_RESP=$(curl -sf \
  -H "Authorization: Token ${DOJO_API_KEY}" \
  "${DOJO_URL}/api/v2/products/?name=${DOJO_PRODUCT_NAME}")

PRODUCT_ID=$(echo "$PRODUCT_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('results', [])
print(results[0]['id'] if results else '')
" 2>/dev/null || true)

if [[ -z "$PRODUCT_ID" ]]; then
  echo "   Creando producto '${DOJO_PRODUCT_NAME}'..."
  PRODUCT_ID=$(curl -sf -X POST \
    -H "Authorization: Token ${DOJO_API_KEY}" \
    -H "Content-Type: application/json" \
    "${DOJO_URL}/api/v2/products/" \
    -d "{
      \"name\": \"${DOJO_PRODUCT_NAME}\",
      \"description\": \"Aplicación de entrenamiento en seguridad WebGoat\",
      \"prod_type\": 1
    }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  echo "   Producto creado con id=${PRODUCT_ID}"
else
  echo "   Producto encontrado: id=${PRODUCT_ID}"
fi

# ─── 5. Crear Engagement ──────────────────────────────────────────────────────
echo ""
echo "📋 Creando engagement '${DOJO_ENGAGEMENT_NAME}'..."

TODAY=$(date +%Y-%m-%d)
ENGAGEMENT_ID=$(curl -sf -X POST \
  -H "Authorization: Token ${DOJO_API_KEY}" \
  -H "Content-Type: application/json" \
  "${DOJO_URL}/api/v2/engagements/" \
  -d "{
    \"name\": \"${DOJO_ENGAGEMENT_NAME}\",
    \"product\": ${PRODUCT_ID},
    \"target_start\": \"${TODAY}\",
    \"target_end\": \"${TODAY}\",
    \"status\": \"In Progress\",
    \"engagement_type\": \"CI/CD\",
    \"description\": \"Análisis automático desde SonarQube – Quality Gate: ${QG_STATUS}\"
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

echo "   Engagement creado: id=${ENGAGEMENT_ID}"

# ─── 6. Subir el informe a DefectDojo ─────────────────────────────────────────
echo ""
echo "📤 Subiendo informe a DefectDojo..."

IMPORT_RESP=$(curl -sf -X POST \
  -H "Authorization: Token ${DOJO_API_KEY}" \
  -F "scan_type=SonarQube Scan" \
  -F "engagement=${ENGAGEMENT_ID}" \
  -F "file=@${UPLOAD_FILE};type=application/json" \
  -F "active=true" \
  -F "verified=false" \
  -F "close_old_findings=true" \
  -F "push_to_jira=false" \
  "${DOJO_URL}/api/v2/import-scan/")

TEST_ID=$(echo "$IMPORT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('test_id','?'))" 2>/dev/null || echo "?")

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ✅ IMPORTACIÓN COMPLETADA                                       ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  DefectDojo:   ${DOJO_URL}"
echo "║  Producto:     ${DOJO_PRODUCT_NAME} (id=${PRODUCT_ID})"
echo "║  Engagement:   ${DOJO_ENGAGEMENT_NAME} (id=${ENGAGEMENT_ID})"
echo "║  Test id:      ${TEST_ID}"
echo "║  QG Status:    ${QG_STATUS}"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Revisa los findings en:"
echo "  ${DOJO_URL}/engagement/${ENGAGEMENT_ID}"

# Limpiar ficheros temporales
rm -f /tmp/sonar-raw-*.json
