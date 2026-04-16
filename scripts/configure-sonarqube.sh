#!/usr/bin/env bash
# =============================================================================
# configure-sonarqube.sh
# Configura SonarQube vía API REST:
#   1. Espera a que SonarQube esté listo
#   2. Crea el Quality Gate con las condiciones de la imagen
#   3. Crea el proyecto WebGoat
#   4. Asigna el Quality Gate al proyecto
# =============================================================================

set -euo pipefail

SONAR_URL="${SONAR_URL:-http://localhost:9000}"
SONAR_ADMIN_USER="${SONAR_ADMIN_USER:-admin}"
SONAR_ADMIN_PASS="${SONAR_ADMIN_PASS:-admin}"
PROJECT_KEY="webgoat"
QG_NAME="Custom-QG-DevSecOps"

AUTH="-u ${SONAR_ADMIN_USER}:${SONAR_ADMIN_PASS}"

echo "──────────────────────────────────────────"
echo " Configurando SonarQube en ${SONAR_URL}"
echo "──────────────────────────────────────────"

# ─── 1. Esperar a SonarQube ───────────────────────────────────────────────────
wait_for_sonarqube() {
  echo "⏳ Esperando a que SonarQube esté disponible..."
  for i in $(seq 1 40); do
    STATUS=$(curl -sf ${AUTH} "${SONAR_URL}/api/system/status" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
    if [[ "$STATUS" == "UP" ]]; then
      echo "✅ SonarQube está listo."
      return 0
    fi
    echo "   intento $i/40 – estado: ${STATUS:-no responde}"
    sleep 10
  done
  echo "❌ SonarQube no respondió a tiempo."
  exit 1
}

wait_for_sonarqube

# ─── 2. Cambiar contraseña por defecto ────────────────────────────────────────
echo ""
echo "🔑 Verificando credenciales de administrador..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" ${AUTH} "${SONAR_URL}/api/authentication/validate")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "   Cambiando contraseña por defecto (admin/admin → admin/admin)..."
  curl -sf -X POST -u "admin:admin" \
    "${SONAR_URL}/api/users/change_password" \
    -d "login=admin&previousPassword=admin&password=${SONAR_ADMIN_PASS}" || true
fi
echo "✅ Credenciales OK."

# ─── 3. Crear el Quality Gate ─────────────────────────────────────────────────
echo ""
echo "🔧 Creando Quality Gate: ${QG_NAME}..."

# Eliminar si ya existe
EXISTING_ID=$(curl -sf ${AUTH} "${SONAR_URL}/api/qualitygates/list" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
gates = data.get('qualitygates', [])
match = [g['id'] for g in gates if g['name'] == '${QG_NAME}']
print(match[0] if match else '')
" 2>/dev/null || true)

if [[ -n "$EXISTING_ID" ]]; then
  echo "   Quality Gate ya existe (id=$EXISTING_ID) – eliminando para recrear..."
  curl -sf -X POST ${AUTH} "${SONAR_URL}/api/qualitygates/destroy" \
    -d "id=${EXISTING_ID}"
fi

# Crear nuevo Quality Gate
QG_ID=$(curl -sf -X POST ${AUTH} "${SONAR_URL}/api/qualitygates/create" \
  -d "name=${QG_NAME}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

echo "   Quality Gate creado con id=${QG_ID}"

# ─── 4. Agregar condiciones (según la imagen) ─────────────────────────────────
echo ""
echo "📋 Agregando condiciones al Quality Gate..."

add_condition() {
  local metric="$1"
  local op="$2"
  local error="$3"
  echo "   + ${metric} ${op} ${error}"
  curl -sf -X POST ${AUTH} "${SONAR_URL}/api/qualitygates/create_condition" \
    -d "gateId=${QG_ID}" \
    -d "metric=${metric}" \
    -d "op=${op}" \
    -d "error=${error}" > /dev/null
}

# Condiciones extraídas de la imagen
# new_* → métricas que aplican al código nuevo (new code)
add_condition "new_violations"              "GT" "12"   # Issues > 12
add_condition "new_security_hotspots_reviewed" "LT" "100" # Security Hotspots < 100%
add_condition "new_coverage"               "LT" "70"   # Coverage < 70%
add_condition "new_duplicated_lines_density" "GT" "10" # Duplicated Lines > 10%
add_condition "new_maintainability_rating" "GT" "1"    # Maintainability Rating worse than A (1=A,2=B...)
add_condition "new_blocker_violations"     "GT" "0"    # Blocker Issues > 0
add_condition "new_critical_violations"    "GT" "0"    # Critical Issues > 0
add_condition "new_info_violations"        "GT" "10"   # Info Issues > 10
add_condition "new_major_violations"       "GT" "3"    # Major Issues > 3
add_condition "new_minor_violations"       "GT" "6"    # Minor Issues > 6
add_condition "new_vulnerabilities"        "GT" "0"    # Vulnerabilities > 0
add_condition "new_reliability_rating"     "GT" "4"    # Reliability Rating worse than D (4=D)
add_condition "new_security_rating"        "GT" "1"    # Security Rating worse than A

echo "✅ Condiciones agregadas."

# ─── 5. Establecer como Quality Gate por defecto (opcional) ──────────────────
echo ""
echo "⭐  Estableciendo '${QG_NAME}' como Quality Gate por defecto..."
curl -sf -X POST ${AUTH} "${SONAR_URL}/api/qualitygates/set_as_default" \
  -d "id=${QG_ID}" > /dev/null
echo "✅ Quality Gate establecido como predeterminado."

# ─── 6. Crear el proyecto WebGoat ─────────────────────────────────────────────
echo ""
echo "📁 Creando proyecto: ${PROJECT_KEY}..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST ${AUTH} \
  "${SONAR_URL}/api/projects/create" \
  -d "project=${PROJECT_KEY}" \
  -d "name=WebGoat – Security Training App" \
  -d "visibility=public")

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "✅ Proyecto creado."
elif [[ "$HTTP_CODE" == "400" ]]; then
  echo "ℹ️  El proyecto ya existía."
else
  echo "⚠️  Respuesta inesperada: HTTP $HTTP_CODE"
fi

# ─── 7. Asignar Quality Gate al proyecto ──────────────────────────────────────
echo ""
echo "🔗 Asignando Quality Gate al proyecto ${PROJECT_KEY}..."
curl -sf -X POST ${AUTH} "${SONAR_URL}/api/qualitygates/select" \
  -d "gateId=${QG_ID}" \
  -d "projectKey=${PROJECT_KEY}" > /dev/null
echo "✅ Quality Gate asignado."

# ─── 8. Generar token de análisis ─────────────────────────────────────────────
echo ""
echo "🔐 Generando token de análisis para '${PROJECT_KEY}'..."

TOKEN_RESPONSE=$(curl -sf -X POST ${AUTH} "${SONAR_URL}/api/user_tokens/generate" \
  -d "name=scanner-${PROJECT_KEY}-$(date +%s)" \
  -d "type=PROJECT_ANALYSIS_TOKEN" \
  -d "projectKey=${PROJECT_KEY}" 2>/dev/null || \
  curl -sf -X POST ${AUTH} "${SONAR_URL}/api/user_tokens/generate" \
    -d "name=scanner-${PROJECT_KEY}-$(date +%s)")

SONAR_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)

if [[ -n "$SONAR_TOKEN" ]]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  ✅ CONFIGURACIÓN COMPLETADA                                 ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║  SonarQube:   ${SONAR_URL}"
  echo "║  Proyecto:    ${PROJECT_KEY}"
  echo "║  QualityGate: ${QG_NAME} (id=${QG_ID})"
  echo "║  Token:       ${SONAR_TOKEN}"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Guarda el token y úsalo así:"
  echo "  export SONAR_TOKEN=${SONAR_TOKEN}"
  echo ""
  # Guardar en fichero para uso posterior
  echo "SONAR_TOKEN=${SONAR_TOKEN}" > /tmp/sonar-token.env
  echo "  Token guardado en /tmp/sonar-token.env"
else
  echo "⚠️  No se pudo recuperar el token. Créalo manualmente en:"
  echo "   ${SONAR_URL} → My Account → Security → Generate Token"
fi
