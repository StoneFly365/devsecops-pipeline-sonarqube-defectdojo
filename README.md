# DevSecOps Pipeline – SonarQube + DefectDojo + GitHub Actions

Pipeline completo para analizar **WebGoat** (proyecto de prueba estándar de OWASP),
con Quality Gate personalizado según las condiciones de la imagen y envío automático
de resultados a DefectDojo.

---

## Arquitectura

```
GitHub Actions
     │
     ├─── Build + Test (Maven + JaCoCo)
     │
     ├─── SonarQube Scan ──→ Quality Gate (13 condiciones)
     │         │
     │         └──→ API /issues/search → sonar-issues.json
     │
     └─── DefectDojo Import ──→ Producto / Engagement / Findings
```

### Servicios del entorno local

| Servicio     | Puerto | Credenciales    | Descripción                          |
|--------------|--------|-----------------|--------------------------------------|
| SonarQube    | 9000   | admin / admin   | Análisis estático de código          |
| DefectDojo   | 8080   | admin / admin   | Gestión centralizada de findings     |
| PostgreSQL   | 5432   | sonar / sonar   | Base de datos compartida             |

---

## Quality Gate configurado

Las siguientes condiciones se aplican al **código nuevo** (new code):

| Métrica                     | Operador     | Umbral  |
|-----------------------------|--------------|---------|
| Issues                      | >            | 12      |
| Security Hotspots Reviewed  | <            | 100%    |
| Coverage                    | <            | 70%     |
| Duplicated Lines (%)        | >            | 10%     |
| Maintainability Rating      | worse than   | A       |
| Blocker Issues              | >            | 0       |
| Critical Issues             | >            | 0       |
| Info Issues                 | >            | 10      |
| Major Issues                | >            | 3       |
| Minor Issues                | >            | 6       |
| Vulnerabilities             | >            | 0       |
| Reliability Rating          | worse than   | D       |
| Security Rating             | worse than   | A       |

> **Nota:** WebGoat es intencionalmente inseguro, por lo que el Quality Gate
> fallará (que es el comportamiento esperado para probar el pipeline).

---

## Requisitos

- Docker Desktop o Docker Engine 24+
- docker compose v2
- Git
- curl
- python3
- 6 GB de RAM libres (SonarQube ~2 GB, DefectDojo ~1.5 GB)
- `vm.max_map_count` ≥ 262144 (Linux/WSL)

### Ajustar vm.max_map_count (Linux/WSL)

```bash
# Temporal (se pierde al reiniciar)
sudo sysctl -w vm.max_map_count=262144

# Permanente
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## Instalación y uso – entorno local

### 1. Clonar este repositorio

```bash
git clone https://github.com/tu-org/devsecops-pipeline.git
cd devsecops-pipeline
```

### 2. Ejecutar el script de instalación completo

```bash
chmod +x scripts/*.sh
./scripts/setup.sh
```

El script hace todo automáticamente:
1. Arranca PostgreSQL, SonarQube y DefectDojo
2. Crea el Quality Gate con las 13 condiciones
3. Crea el proyecto `webgoat`
4. Genera un token de análisis
5. Clona WebGoat desde GitHub
6. Ejecuta el análisis con sonar-scanner
7. Sube los resultados a DefectDojo

### 3. Verificar resultados

- **SonarQube:** http://localhost:9000/dashboard?id=webgoat
- **DefectDojo:** http://localhost:8080 → Products → WebGoat

---

## Instalación paso a paso (manual)

### Paso 1 – Arrancar los servicios

```bash
docker compose up -d
```

### Paso 2 – Configurar SonarQube

```bash
SONAR_URL=http://localhost:9000 \
SONAR_ADMIN_PASS=admin \
  ./scripts/configure-sonarqube.sh
```

### Paso 3 – Clonar WebGoat

```bash
git clone --depth=1 https://github.com/WebGoat/WebGoat.git webgoat
```

### Paso 4 – Ejecutar el análisis

```bash
export SONAR_TOKEN=<token-generado-en-paso-2>

docker compose --profile scan run --rm sonar-scanner \
  sonar-scanner -Dsonar.token="${SONAR_TOKEN}"
```

### Paso 5 – Subir a DefectDojo

```bash
# Obtener API Key de DefectDojo
DOJO_API_KEY=$(curl -sf -X POST \
  -H "Content-Type: application/json" \
  http://localhost:8080/api/v2/api-token-auth/ \
  -d '{"username":"admin","password":"admin"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

SONAR_URL=http://localhost:9000 \
SONAR_TOKEN="${SONAR_TOKEN}" \
PROJECT_KEY=webgoat \
DOJO_URL=http://localhost:8080 \
DOJO_API_KEY="${DOJO_API_KEY}" \
  ./scripts/upload-to-defectdojo.sh
```

---

## GitHub Actions

### Secrets requeridos

Ve a tu repositorio → **Settings → Secrets and variables → Actions** y añade:

| Secret          | Descripción                                    |
|-----------------|------------------------------------------------|
| `SONAR_HOST_URL`| URL de tu SonarQube (ej. https://sonar.mi.org) |
| `SONAR_TOKEN`   | Token de proyecto de SonarQube                 |
| `DOJO_URL`      | URL de DefectDojo                              |
| `DOJO_API_KEY`  | API Key de DefectDojo                          |

### Instalar el workflow

```bash
# En tu repositorio de WebGoat (fork)
mkdir -p .github/workflows
cp devsecops-pipeline.yml .github/workflows/
git add .github/workflows/devsecops-pipeline.yml
git commit -m "ci: add DevSecOps pipeline (SonarQube + DefectDojo)"
git push
```

### Jobs del pipeline

| Job                    | Descripción                                        |
|------------------------|----------------------------------------------------|
| `build-and-test`       | Compila WebGoat y genera cobertura JaCoCo          |
| `sonarqube-analysis`   | Ejecuta el análisis y espera el Quality Gate       |
| `defectdojo-import`    | Importa los findings en DefectDojo                 |
| `quality-gate-check`   | Falla el pipeline en `main` si el QG no pasa      |

---

## Estructura del proyecto

```
devsecops-pipeline/
├── .env                            # Variables de entorno (SONAR_TOKEN, etc.)
├── docker-compose.yml              # SonarQube + DefectDojo + PostgreSQL
├── devsecops-pipeline.yml          # GitHub Actions workflow
├── config/
│   ├── sonar-project.properties    # Configuración del proyecto WebGoat
│   └── initdb/
│       └── init.sql                # Crea las bases de datos (montado como directorio)
├── docs/
│   └── resultados-analisis-sonarqube-WebGoat.md  # Informe de análisis
├── scripts/
│   ├── setup.sh                    # Script maestro (todo en uno)
│   ├── configure-sonarqube.sh      # Configura QG y proyecto vía API
│   └── upload-to-defectdojo.sh     # Descarga issues y los sube a Dojo
├── webgoat/                        # Código fuente de WebGoat (proyecto de prueba)
└── README.md
```

---

## Comandos útiles

```bash
# Ver logs de SonarQube
docker compose logs -f sonarqube

# Ver logs de DefectDojo
docker compose logs -f defectdojo

# Reiniciar solo SonarQube
docker compose restart sonarqube

# Parar todo
docker compose down

# Parar y eliminar todos los volúmenes (reset completo)
docker compose down -v

# Ejecutar solo el scanner
docker compose --profile scan run --rm sonar-scanner \
  sonar-scanner -Dsonar.token=TU_TOKEN
```

---

## Solución de problemas

### SonarQube no arranca (Elasticsearch error)

```bash
sudo sysctl -w vm.max_map_count=262144
docker compose restart sonarqube
```

### DefectDojo devuelve 500

Espera 2-3 minutos mientras completa la migración de la base de datos:

```bash
docker compose logs -f defectdojo | grep -E "Starting|migration|ready"
```

### Error "project not found" en SonarQube

El proyecto debe crearse antes del primer análisis. Ejecuta:

```bash
./scripts/configure-sonarqube.sh
```

### Token inválido

Los tokens de proyecto solo son válidos para el proyecto al que están asignados.
Genera un nuevo token en: SonarQube → My Account → Security → Generate Token.
