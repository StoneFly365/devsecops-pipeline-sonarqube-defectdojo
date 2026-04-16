#!/usr/bin/env bash
# =============================================================================
# setup.sh  –  Script maestro de instalación del entorno DevSecOps
#
# Orquesta:
#   1. Comprobaciones previas (Docker, recursos)
#   2. Arranque del entorno (docker-compose)
#   3. Configuración de SonarQube (QG + proyecto)
#   4. Clone de WebGoat (proyecto de prueba)
#   5. Ejecución del análisis con sonar-scanner
#   6. Subida de resultados a DefectDojo
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}" >&2; exit 1; }

echo -e "${BLUE}"
cat << 'BANNER'
  ____             ____            ___
 |  _ \  _____   __ ___ ___  ___|  _ \ ___  ___
 | | | |/ _ \ \ / / / __/ _ \/ __| | | / _ \/ __|
 | |_| |  __/\ V /  \__ \  __/ (__| |_| | (_) \__ \
 |____/ \___| \_/   |___/\___|\___|____/ \___/|___/

  SonarQube + DefectDojo + GitHub Actions  |  WebGoat Demo
BANNER
echo -e "${NC}"

# ─── Verificaciones previas ───────────────────────────────────────────────────
log "Comprobando requisitos del sistema..."

command -v docker   >/dev/null 2>&1 || err "Docker no está instalado."
command -v git      >/dev/null 2>&1 || err "Git no está instalado."
command -v curl     >/dev/null 2>&1 || err "curl no está instalado."
command -v python3  >/dev/null 2>&1 || err "python3 no está instalado."

# Comprobar vm.max_map_count para Elasticsearch (SonarQube)
CURRENT_MAP=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
if (( CURRENT_MAP < 262144 )); then
  warn "vm.max_map_count=${CURRENT_MAP} – SonarQube necesita ≥262144"
  warn "Ejecutando: sudo sysctl -w vm.max_map_count=262144"
  sudo sysctl -w vm.max_map_count=262144 || warn "No se pudo ajustar (puede fallar Elasticsearch)"
fi

# Comprobar memoria disponible (mínimo 4 GB)
FREE_MEM=$(free -m | awk '/Mem:/{print $7}')
if (( FREE_MEM < 3000 )); then
  warn "Memoria disponible: ${FREE_MEM}MB – recomendado ≥4GB para SonarQube + DefectDojo"
fi

ok "Requisitos verificados."

# ─── Arranque del entorno ─────────────────────────────────────────────────────
log "Iniciando contenedores (SonarQube, DefectDojo, PostgreSQL)..."
cd "$ROOT_DIR"

docker compose up -d postgres
log "Esperando a que PostgreSQL esté listo..."
sleep 5

docker compose up -d sonarqube defectdojo
ok "Contenedores en marcha. Esperando a que los servicios estén listos..."

# ─── Configurar SonarQube ─────────────────────────────────────────────────────
log "Configurando SonarQube (Quality Gate, proyecto, token)..."
SONAR_URL="http://localhost:9000" \
SONAR_ADMIN_USER="admin" \
SONAR_ADMIN_PASS="${SONAR_ADMIN_PASS:-admin}" \
  bash "${SCRIPT_DIR}/configure-sonarqube.sh"

# Leer el token generado
if [[ -f /tmp/sonar-token.env ]]; then
  source /tmp/sonar-token.env
  ok "Token de análisis cargado: ${SONAR_TOKEN:0:12}..."
else
  echo ""
  warn "No se encontró el token automático."
  read -rp "  Introduce tu SONAR_TOKEN manualmente: " SONAR_TOKEN
fi

export SONAR_TOKEN

# ─── Clonar WebGoat ───────────────────────────────────────────────────────────
if [[ ! -d "$ROOT_DIR/webgoat" ]]; then
  log "Clonando WebGoat (proyecto de prueba estándar para SonarQube)..."
  git clone --depth=1 https://github.com/WebGoat/WebGoat.git "$ROOT_DIR/webgoat"
  ok "WebGoat clonado."
else
  log "WebGoat ya existe, actualizando..."
  cd "$ROOT_DIR/webgoat" && git pull --ff-only && cd "$ROOT_DIR"
fi

# ─── Ejecutar el análisis ─────────────────────────────────────────────────────
log "Ejecutando análisis SonarQube sobre WebGoat..."

docker compose --profile scan run --rm sonar-scanner \
  sonar-scanner \
    -Dsonar.token="${SONAR_TOKEN}" \
    -Dsonar.qualitygate.wait=true || {
  warn "El análisis completó pero el Quality Gate NO ha pasado (esperado en WebGoat)."
}

ok "Análisis completado. Resultados en: http://localhost:9000/dashboard?id=webgoat"

# ─── Obtener API Key de DefectDojo ────────────────────────────────────────────
log "Obteniendo API Key de DefectDojo..."

DOJO_URL="http://localhost:8080"
log "Esperando a que DefectDojo esté listo..."

for i in $(seq 1 20); do
  HTTP=$(curl -so /dev/null -w "%{http_code}" "${DOJO_URL}/api/v2/" 2>/dev/null || echo 0)
  if [[ "$HTTP" == "200" ]]; then break; fi
  echo "   intento $i/20..."
  sleep 10
done

DOJO_API_KEY=$(curl -sf -X POST \
  -H "Content-Type: application/json" \
  "${DOJO_URL}/api/v2/api-token-auth/" \
  -d '{"username":"admin","password":"admin"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)

if [[ -z "$DOJO_API_KEY" ]]; then
  warn "No se pudo obtener la API Key automáticamente."
  warn "Obtén la API Key desde: ${DOJO_URL} → User → API v2 Key"
  read -rp "  Introduce tu DOJO_API_KEY: " DOJO_API_KEY
fi

export DOJO_API_KEY
ok "DefectDojo API Key lista."

# ─── Subir resultados a DefectDojo ────────────────────────────────────────────
log "Subiendo resultados a DefectDojo..."

SONAR_URL="http://localhost:9000" \
SONAR_TOKEN="${SONAR_TOKEN}" \
PROJECT_KEY="webgoat" \
DOJO_URL="${DOJO_URL}" \
DOJO_API_KEY="${DOJO_API_KEY}" \
DOJO_PRODUCT_NAME="WebGoat" \
  bash "${SCRIPT_DIR}/upload-to-defectdojo.sh"

# ─── Resumen final ────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         🎉  ENTORNO DEVSECOPS LISTO                      ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  SonarQube   → http://localhost:9000  (admin/admin)     ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  DefectDojo  → http://localhost:8080  (admin/admin)     ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Quality Gate:  Custom-QG-DevSecOps (13 condiciones)    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Proyecto:      webgoat                                 ${GREEN}║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  GitHub Actions: copiar a .github/workflows/             ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  github/devsecops-pipeline.yml                          ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Para parar el entorno: docker compose down"
echo "  Para parar y eliminar datos: docker compose down -v"
