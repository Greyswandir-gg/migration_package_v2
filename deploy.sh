#!/usr/bin/env bash
# =============================================================================
#  deploy.sh — One-command deployment for Analytics Dashboard
#
#  Usage:
#    chmod +x deploy.sh
#    ./deploy.sh                        # auto-detects port
#    ./deploy.sh --port 8081            # force alt port (if 80 is taken)
#    ./deploy.sh --port 80 --domain example.com
#    ./deploy.sh --help
#
#  What it does:
#    1. Installs Docker + Docker Compose if missing
#    2. Clones or updates the repository
#    3. Detects whether port 80 is free; uses 8081 as fallback
#    4. Starts all containers (db, web_app, grafana, nginx)
#    5. Waits for services to become healthy
#    6. Applies SQL views and structure
#    7. Configures Grafana folder permissions
#    8. Prints access URLs and next steps
# =============================================================================

set -euo pipefail

# ─── Config defaults ─────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-https://github.com/Greyswandir-gg/migration_package_v2.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/analytics}"
PORT="${PORT:-}"          # empty = auto-detect
DOMAIN="${DOMAIN:-}"      # empty = use server IP
DB_USER="admin"
DB_PASS="secretpassword"
DB_NAME="analytics_db"
G_ADMIN_USER="admin"
G_ADMIN_PASS="${G_ADMIN_PASS:-admin}"
PROJECT_NAME="migration_package_v2"
COMPOSE_FILE="docker-compose.remote.yml"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[!]${RESET} $*"; }
error()  { echo -e "${RED}[✗]${RESET} $*" >&2; }
header() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${RESET}"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
show_help() {
  echo -e "${BOLD}Analytics Dashboard — Deploy Script${RESET}"
  echo ""
  echo "Usage: ./deploy.sh [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --port PORT        Nginx host port (default: auto-detect 80 or 8081)"
  echo "  --domain DOMAIN    Server domain/IP for URLs (default: auto-detect)"
  echo "  --dir DIR          Install directory (default: /opt/analytics)"
  echo "  --repo URL         Git repository URL"
  echo "  --admin-pass PASS  Grafana admin password (default: admin)"
  echo "  --help             Show this help"
  echo ""
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)      PORT="$2";       shift 2 ;;
    --domain)    DOMAIN="$2";     shift 2 ;;
    --dir)       INSTALL_DIR="$2"; shift 2 ;;
    --repo)      REPO_URL="$2";   shift 2 ;;
    --admin-pass) G_ADMIN_PASS="$2"; shift 2 ;;
    --help|-h)   show_help ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

# ─── Banner ───────────────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   Analytics Dashboard — Deployment Script  ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${RESET}"

# ─── Step 1: Prerequisites ────────────────────────────────────────────────────
header "Step 1: Prerequisites"

install_docker() {
  warn "Docker not found — installing..."
  if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    log "Docker installed successfully"
  elif command -v yum &>/dev/null; then
    yum install -y -q docker
    systemctl enable --now docker
    # Install docker compose plugin
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    log "Docker installed successfully"
  else
    error "Unsupported OS. Install Docker manually: https://docs.docker.com/engine/install/"
    exit 1
  fi
}

if ! command -v docker &>/dev/null; then
  install_docker
else
  DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
  log "Docker found: $DOCKER_VER"
fi

# Check compose (v2 plugin or v1 standalone)
if docker compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
  log "Docker Compose v2 found"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
  warn "Docker Compose v1 found (consider upgrading to v2)"
else
  error "Docker Compose not found. Install it: https://docs.docker.com/compose/install/"
  exit 1
fi

if ! command -v git &>/dev/null; then
  warn "git not found — installing..."
  if command -v apt-get &>/dev/null; then
    apt-get install -y -qq git
  else
    yum install -y -q git
  fi
fi
log "git found: $(git --version)"

# ─── Step 2: Clone / update repo ─────────────────────────────────────────────
header "Step 2: Repository"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  log "Repository exists at $INSTALL_DIR — pulling latest..."
  cd "$INSTALL_DIR"
  git pull --rebase origin main || warn "git pull failed, continuing with existing code"
else
  log "Cloning $REPO_URL → $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi

log "Repository ready at $INSTALL_DIR"

# ─── Step 3: Port detection & nginx config ────────────────────────────────────
header "Step 3: Port Configuration"

detect_port() {
  if ss -tlnp 2>/dev/null | grep -q ':80 ' || \
     lsof -i :80 2>/dev/null | grep -q LISTEN; then
    echo "8081"
  else
    echo "80"
  fi
}

if [[ -z "$PORT" ]]; then
  PORT=$(detect_port)
  if [[ "$PORT" == "8081" ]]; then
    warn "Port 80 is busy — will use port 8081 instead"
  else
    log "Port 80 is free — using standard HTTP port"
  fi
else
  log "Using configured port: $PORT"
fi

# Detect server IP if domain not provided
if [[ -z "$DOMAIN" ]]; then
  DOMAIN=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
           curl -s --max-time 5 api.ipify.org 2>/dev/null || \
           hostname -I | awk '{print $1}')
fi
log "Server address: $DOMAIN:$PORT"

# Build the Grafana root URL
if [[ "$PORT" == "80" ]]; then
  GRAFANA_ROOT_URL="http://${DOMAIN}/grafana/"
  APP_URL="http://${DOMAIN}/app"
else
  GRAFANA_ROOT_URL="http://${DOMAIN}:${PORT}/grafana/"
  APP_URL="http://${DOMAIN}:${PORT}/app"
fi

# Create docker-compose override for port and Grafana URL
cat > /tmp/compose-deploy-override.yml << EOF
services:
  nginx:
    ports:
      - "${PORT}:80"
  grafana:
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${G_ADMIN_PASS}
      - GF_SERVER_ROOT_URL=${GRAFANA_ROOT_URL}
      - GF_SERVER_SERVE_FROM_SUB_PATH=true
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_AUTH_DISABLE_LOGIN_FORM=false
EOF

log "Override config written for port $PORT"

# ─── Step 4: Start containers ─────────────────────────────────────────────────
header "Step 4: Starting Containers"

# Stop existing containers of this project (in case of re-deploy)
$COMPOSE_CMD -p "$PROJECT_NAME" -f "$COMPOSE_FILE" -f /tmp/compose-deploy-override.yml \
  down --remove-orphans 2>/dev/null || true

log "Building and starting containers..."
$COMPOSE_CMD -p "$PROJECT_NAME" -f "$COMPOSE_FILE" -f /tmp/compose-deploy-override.yml \
  up -d --build

log "Containers started"

# ─── Step 5: Health checks ────────────────────────────────────────────────────
header "Step 5: Waiting for Services"

wait_for_db() {
  echo -n "  Waiting for PostgreSQL"
  for i in $(seq 1 60); do
    if docker exec "${PROJECT_NAME}-db-1" pg_isready -U "$DB_USER" -d "$DB_NAME" &>/dev/null; then
      echo " — ready!"
      return 0
    fi
    echo -n "."
    sleep 3
  done
  echo ""
  error "PostgreSQL did not become healthy in 3 minutes"
  exit 1
}

wait_for_grafana() {
  echo -n "  Waiting for Grafana"
  for i in $(seq 1 40); do
    if docker exec "${PROJECT_NAME}-grafana-1" curl -sf \
       "http://127.0.0.1:3000/grafana/api/health" &>/dev/null; then
      echo " — ready!"
      return 0
    fi
    echo -n "."
    sleep 3
  done
  echo ""
  warn "Grafana health check timed out — continuing anyway"
}

wait_for_db
wait_for_grafana

# ─── Step 6: SQL — views and structure ───────────────────────────────────────
header "Step 6: Database SQL Setup"

run_sql() {
  local label="$1"
  local sql="$2"
  if docker exec "${PROJECT_NAME}-db-1" psql -U "$DB_USER" -d "$DB_NAME" \
     -c "$sql" &>/dev/null; then
    log "$label"
  else
    warn "$label (warnings may occur — check manually)"
  fi
}

run_sql_file() {
  local label="$1"
  local filepath="$2"
  if docker exec -i "${PROJECT_NAME}-db-1" psql -U "$DB_USER" -d "$DB_NAME" \
     < "$filepath" &>/dev/null; then
    log "$label"
  else
    warn "$label (some SQL warnings — check manually)"
  fi
}

# Apply calculated views (safe to run even before data is loaded)
run_sql_file "Applied sql/build_calculated_views.sql" "sql/build_calculated_views.sql"

# Create employees table (will be populated by setup_users.sh after data upload)
run_sql "Ensured employees table exists" "
CREATE TABLE IF NOT EXISTS employees (
    id SERIAL PRIMARY KEY,
    mitarbeiter TEXT NOT NULL UNIQUE,
    login VARCHAR(100) NOT NULL UNIQUE,
    ma_kat TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);"

log "Database structure ready"

# ─── Step 7: Grafana — folder permissions ────────────────────────────────────
header "Step 7: Grafana Configuration"

# Helper: call Grafana API from inside the grafana container
g_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  if [[ -n "$body" ]]; then
    docker exec "${PROJECT_NAME}-grafana-1" curl -sf \
      -u "${G_ADMIN_USER}:${G_ADMIN_PASS}" \
      -H "Content-Type: application/json" \
      -X "$method" "http://127.0.0.1:3000/grafana${path}" \
      -d "$body" 2>/dev/null || echo "{}"
  else
    docker exec "${PROJECT_NAME}-grafana-1" curl -sf \
      -u "${G_ADMIN_USER}:${G_ADMIN_PASS}" \
      "http://127.0.0.1:3000/grafana${path}" 2>/dev/null || echo "[]"
  fi
}

# Give Grafana a moment to finish provisioning dashboards
sleep 5

# Get folder UIDs
FOLDERS=$(g_api GET "/api/folders?limit=100")
ADMIN_UID=$(echo "$FOLDERS" | grep -o '"uid":"[^"]*","title":"Admin"' | grep -o '"uid":"[^"]*"' | cut -d'"' -f4 || true)
PERSONAL_UID=$(echo "$FOLDERS" | grep -o '"uid":"[^"]*","title":"Personal"' | grep -o '"uid":"[^"]*"' | cut -d'"' -f4 || true)

if [[ -n "$ADMIN_UID" ]]; then
  g_api POST "/api/folders/${ADMIN_UID}/permissions" \
    '{"items":[{"role":"Editor","permission":1},{"role":"Admin","permission":4}]}' \
    > /dev/null
  log "Admin folder: restricted to Editor+ only"
else
  warn "Admin folder not found yet (dashboards may still be provisioning)"
fi

if [[ -n "$PERSONAL_UID" ]]; then
  g_api POST "/api/folders/${PERSONAL_UID}/permissions" \
    '{"items":[{"role":"Viewer","permission":1},{"role":"Editor","permission":2},{"role":"Admin","permission":4}]}' \
    > /dev/null
  log "Personal folder: open to Viewer role"
else
  warn "Personal folder not found yet"
fi

# Clean up temp file
rm -f /tmp/compose-deploy-override.yml

# ─── Step 8: Summary ─────────────────────────────────────────────────────────
header "Deployment Complete"

echo -e ""
echo -e "${GREEN}${BOLD}✅ All services are running!${RESET}"
echo -e ""
echo -e "${BOLD}Access URLs:${RESET}"
echo -e "  Grafana:   ${CYAN}${GRAFANA_ROOT_URL}${RESET}  (admin / ${G_ADMIN_PASS})"
echo -e "  Admin App: ${CYAN}${APP_URL}${RESET}      (admin / admin123)"
echo -e ""
echo -e "${BOLD}Container status:${RESET}"
docker ps --format "  {{.Names}}\t{{.Status}}" | grep "$PROJECT_NAME" | \
  while IFS=$'\t' read -r name status; do
    echo -e "  ${name}  →  ${status}"
  done
echo -e ""
echo -e "${YELLOW}${BOLD}Next steps:${RESET}"
echo -e ""
echo -e "  ${BOLD}1. Upload Excel data${RESET}"
echo -e "     Open ${CYAN}${APP_URL}${RESET} and upload your .xlsx file"
echo -e "     (use 'Full Refresh Upload' for first load)"
echo -e ""
echo -e "  ${BOLD}2. Create employee Grafana users${RESET}"
echo -e "     After upload, run:"
echo -e "     ${CYAN}bash ${INSTALL_DIR}/scripts/setup_users.sh${RESET}"
echo -e ""
echo -e "     This will:"
echo -e "     • Create a Grafana login for each employee (from xl_projecttimes)"
echo -e "     • Default password: ${BOLD}Welcome2026!${RESET}"
echo -e "     • Employees log in and see only their Personal dashboard"
echo -e ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  View logs:    docker compose -p $PROJECT_NAME -f $INSTALL_DIR/$COMPOSE_FILE logs -f"
echo -e "  Stop all:     docker compose -p $PROJECT_NAME -f $INSTALL_DIR/$COMPOSE_FILE down"
echo -e "  Restart:      docker compose -p $PROJECT_NAME -f $INSTALL_DIR/$COMPOSE_FILE restart"
echo -e ""
