#!/usr/bin/env bash
# =============================================================================
# deploy-native.sh — One-command native deployment (NO Docker)
#
# Installs PostgreSQL 15, Grafana OSS, Python 3 + Streamlit, Nginx
# directly on the host system (Ubuntu 20.04+ / Debian 11+).
#
# Usage:
#   chmod +x deploy-native.sh
#   ./deploy-native.sh
#   ./deploy-native.sh --port 8081
#   ./deploy-native.sh --port 80 --domain example.com --admin-pass MyPass
#   ./deploy-native.sh --help
# =============================================================================

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
REPO_URL="${REPO_URL:-https://github.com/Greyswandir-gg/migration_package_v2.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/analytics}"
PORT="${PORT:-}"
DOMAIN="${DOMAIN:-}"
DB_USER="admin"
DB_PASS="secretpassword"
DB_NAME="analytics_db"
G_ADMIN_USER="admin"
G_ADMIN_PASS="${G_ADMIN_PASS:-admin}"
APP_SERVICE="analytics-app"
APP_PORT="8501"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()    { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[!]${RESET} $*"; }
error()  { echo -e "${RED}[✗]${RESET} $*" >&2; }
header() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${RESET}"; }

show_help() {
  echo -e "${BOLD}Analytics Dashboard — Native Deploy Script (no Docker)${RESET}"
  echo ""
  echo "Usage: ./deploy-native.sh [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --port PORT        Nginx host port (default: auto 80 or 8081)"
  echo "  --domain DOMAIN    Server domain/IP for URLs (default: auto-detect)"
  echo "  --dir DIR          Install directory (default: /opt/analytics)"
  echo "  --repo URL         Git repository URL"
  echo "  --admin-pass PASS  Grafana admin password (default: admin)"
  echo "  --help             Show this help"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)       PORT="$2";         shift 2 ;;
    --domain)     DOMAIN="$2";       shift 2 ;;
    --dir)        INSTALL_DIR="$2";  shift 2 ;;
    --repo)       REPO_URL="$2";     shift 2 ;;
    --admin-pass) G_ADMIN_PASS="$2"; shift 2 ;;
    --help|-h)    show_help ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

echo -e "${CYAN}${BOLD}"
echo " ╔══════════════════════════════════════════════════╗"
echo " ║  Analytics Dashboard — Native Deployment Script  ║"
echo " ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

if [[ "$EUID" -ne 0 ]]; then
  error "This script must be run as root (or with sudo)."
  exit 1
fi

# ─── Step 1: System prerequisites ─────────────────────────────────────────────
header "Step 1: System prerequisites"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl wget gnupg ca-certificates lsb-release \
  software-properties-common apt-transport-https \
  git nginx \
  python3 python3-pip python3-venv \
  libpq-dev gcc
log "Base packages installed"

# ─── Step 2: PostgreSQL 15 ────────────────────────────────────────────────────
header "Step 2: PostgreSQL 15"

if ! command -v psql &>/dev/null || ! psql --version | grep -q "15"; then
  warn "Installing PostgreSQL 15..."
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
  echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y -qq postgresql-15
fi

systemctl enable --now postgresql
log "PostgreSQL 15 running"

# Create DB user and database if not exists
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" \
  | grep -q 1 || sudo -u postgres psql -c \
  "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" \
  | grep -q 1 || sudo -u postgres psql -c \
  "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

sudo -u postgres psql -c \
  "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};" &>/dev/null

# Allow md5 auth for the admin user from localhost
PG_HBA=$(find /etc/postgresql -name pg_hba.conf | head -1)
if [[ -n "$PG_HBA" ]]; then
  if ! grep -q "^host.*${DB_NAME}.*${DB_USER}.*127.0.0.1" "$PG_HBA"; then
    echo "host  ${DB_NAME}  ${DB_USER}  127.0.0.1/32  md5" >> "$PG_HBA"
    echo "host  ${DB_NAME}  ${DB_USER}  ::1/128       md5" >> "$PG_HBA"
    systemctl reload postgresql
    log "pg_hba.conf updated for local md5 auth"
  fi
fi

log "Database '${DB_NAME}' with user '${DB_USER}' ready"

# ─── Step 3: Grafana OSS ──────────────────────────────────────────────────────
header "Step 3: Grafana OSS"

if ! command -v grafana-server &>/dev/null; then
  warn "Installing Grafana..."
  wget -q -O /etc/apt/keyrings/grafana.gpg \
    https://apt.grafana.com/gpg.key
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    > /etc/apt/sources.list.d/grafana.list
  apt-get update -qq
  apt-get install -y -qq grafana
fi

log "Grafana installed"

# ─── Step 4: Clone / update repository ────────────────────────────────────────
header "Step 4: Repository"

if [[ -d "${INSTALL_DIR}/.git" ]]; then
  log "Repository exists — pulling latest..."
  git -C "${INSTALL_DIR}" pull --rebase origin main || \
    warn "git pull failed, continuing with existing code"
else
  log "Cloning ${REPO_URL} → ${INSTALL_DIR}"
  mkdir -p "$(dirname "${INSTALL_DIR}")"
  git clone "${REPO_URL}" "${INSTALL_DIR}"
fi
log "Repository ready at ${INSTALL_DIR}"

# ─── Step 5: Port & domain detection ─────────────────────────────────────────
header "Step 5: Network configuration"

detect_port() {
  if ss -tlnp 2>/dev/null | grep -q ':80 '; then echo "8081"; else echo "80"; fi
}

if [[ -z "$PORT" ]]; then
  PORT=$(detect_port)
  [[ "$PORT" == "8081" ]] && warn "Port 80 busy — using 8081" || log "Using port 80"
fi

if [[ -z "$DOMAIN" ]]; then
  DOMAIN=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
           curl -s --max-time 5 api.ipify.org 2>/dev/null || \
           hostname -I | awk '{print $1}')
fi

if [[ "$PORT" == "80" ]]; then
  GRAFANA_ROOT_URL="http://${DOMAIN}/grafana/"
  APP_URL="http://${DOMAIN}/app"
else
  GRAFANA_ROOT_URL="http://${DOMAIN}:${PORT}/grafana/"
  APP_URL="http://${DOMAIN}:${PORT}/app"
fi

log "Server: ${DOMAIN}:${PORT}"

# ─── Step 6: Grafana configuration ────────────────────────────────────────────
header "Step 6: Grafana configuration"

# Write grafana.ini overrides
cat > /etc/grafana/grafana.ini <<EOF
[server]
root_url = ${GRAFANA_ROOT_URL}
serve_from_sub_path = true

[security]
admin_user = ${G_ADMIN_USER}
admin_password = ${G_ADMIN_PASS}

[users]
allow_sign_up = false

[auth]
disable_login_form = false
EOF

# Set up provisioning (datasources, dashboards)
mkdir -p /etc/grafana/provisioning/datasources
mkdir -p /etc/grafana/provisioning/dashboards

# Datasource: point to localhost instead of docker 'db' hostname
cat > /etc/grafana/provisioning/datasources/analytics.yml <<EOF
apiVersion: 1

datasources:
  - name: Postgres
    type: postgres
    access: proxy
    uid: efaktabfc78qof
    url: localhost:5432
    user: ${DB_USER}
    secureJsonData:
      password: "${DB_PASS}"
    jsonData:
      database: ${DB_NAME}
      sslmode: "disable"
    isDefault: true
EOF

# Copy dashboard provisioning config from the repo
if [[ -d "${INSTALL_DIR}/grafana_config/provisioning/dashboards" ]]; then
  cp -r "${INSTALL_DIR}/grafana_config/provisioning/dashboards" \
        /etc/grafana/provisioning/
  log "Dashboard provisioning copied"
fi

chown -R grafana:grafana /etc/grafana/provisioning

systemctl enable --now grafana-server
log "Grafana running"

# ─── Step 7: Python app (Streamlit) ───────────────────────────────────────────
header "Step 7: Streamlit application"

APP_DIR="${INSTALL_DIR}/app"
VENV_DIR="${APP_DIR}/venv"

python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
"${VENV_DIR}/bin/pip" install --quiet -r "${APP_DIR}/requirements.txt"
log "Python dependencies installed"

# Create systemd service for Streamlit
cat > /etc/systemd/system/${APP_SERVICE}.service <<EOF
[Unit]
Description=Analytics Streamlit App
After=network.target postgresql.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=${APP_DIR}
Environment="DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}"
ExecStart=${VENV_DIR}/bin/streamlit run main.py \\
  --server.port=${APP_PORT} \\
  --server.address=127.0.0.1 \\
  --server.baseUrlPath=/app \\
  --server.maxUploadSize=200 \\
  --server.maxMessageSize=200 \\
  --server.enableXsrfProtection=false
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Give www-data access to the app directory
chown -R www-data:www-data "${INSTALL_DIR}"
chmod -R 755 "${INSTALL_DIR}"

systemctl daemon-reload
systemctl enable --now "${APP_SERVICE}"
log "Streamlit service running on 127.0.0.1:${APP_PORT}"

# ─── Step 8: Nginx ────────────────────────────────────────────────────────────
header "Step 8: Nginx"

cat > /etc/nginx/sites-available/analytics <<EOF
server {
    listen ${PORT};
    server_name ${DOMAIN};

    location /grafana/ {
        proxy_pass         http://127.0.0.1:3000/grafana/;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    location = /grafana {
        return 301 /grafana/;
    }

    location /app {
        client_max_body_size 200M;
        proxy_pass         http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_read_timeout 86400;
    }

    location / {
        return 301 /grafana/;
    }
}
EOF

# Disable default site, enable analytics
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/analytics /etc/nginx/sites-enabled/analytics

nginx -t
systemctl enable --now nginx
systemctl reload nginx
log "Nginx configured on port ${PORT}"

# ─── Step 9: Database SQL setup ───────────────────────────────────────────────
header "Step 9: Database SQL setup"

# Wait for PostgreSQL to accept connections
echo -n " Waiting for PostgreSQL"
for i in $(seq 1 30); do
  if PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -h 127.0.0.1 -d "${DB_NAME}" \
     -c "SELECT 1" &>/dev/null; then
    echo " — ready!"
    break
  fi
  echo -n "."; sleep 2
done

# Apply SQL views
if [[ -f "${INSTALL_DIR}/sql/build_calculated_views.sql" ]]; then
  PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -h 127.0.0.1 -d "${DB_NAME}" \
    -f "${INSTALL_DIR}/sql/build_calculated_views.sql" &>/dev/null || \
    warn "build_calculated_views.sql: some warnings (may be safe to ignore)"
  log "Calculated views applied"
fi

if [[ -f "${INSTALL_DIR}/sql/build_dimensions.sql" ]]; then
  PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -h 127.0.0.1 -d "${DB_NAME}" \
    -f "${INSTALL_DIR}/sql/build_dimensions.sql" &>/dev/null || \
    warn "build_dimensions.sql: some warnings (may be safe to ignore)"
  log "Dimension tables applied"
fi

# Ensure employees table
PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -h 127.0.0.1 -d "${DB_NAME}" -c "
CREATE TABLE IF NOT EXISTS employees (
  id         SERIAL PRIMARY KEY,
  mitarbeiter TEXT NOT NULL UNIQUE,
  login       VARCHAR(100) NOT NULL UNIQUE,
  ma_kat      TEXT,
  created_at  TIMESTAMP DEFAULT NOW()
);" &>/dev/null
log "Database structure ready"

# ─── Step 10: Wait for Grafana and configure folders ──────────────────────────
header "Step 10: Grafana folder permissions"

echo -n " Waiting for Grafana"
for i in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:3000/grafana/api/health" &>/dev/null; then
    echo " — ready!"; break
  fi
  echo -n "."; sleep 3
done

g_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sf -u "${G_ADMIN_USER}:${G_ADMIN_PASS}" \
      -H "Content-Type: application/json" \
      -X "$method" "http://127.0.0.1:3000/grafana${path}" \
      -d "$body" 2>/dev/null || echo "{}"
  else
    curl -sf -u "${G_ADMIN_USER}:${G_ADMIN_PASS}" \
      "http://127.0.0.1:3000/grafana${path}" 2>/dev/null || echo "[]"
  fi
}

sleep 5
FOLDERS=$(g_api GET "/api/folders?limit=100")

ADMIN_UID=$(echo "$FOLDERS" | grep -o '"uid":"[^"]*","title":"Admin"' \
  | grep -o '"uid":"[^"]*"' | cut -d'"' -f4 || true)
PERSONAL_UID=$(echo "$FOLDERS" | grep -o '"uid":"[^"]*","title":"Personal"' \
  | grep -o '"uid":"[^"]*"' | cut -d'"' -f4 || true)

[[ -n "$ADMIN_UID" ]] && \
  g_api POST "/api/folders/${ADMIN_UID}/permissions" \
    '{"items":[{"role":"Editor","permission":1},{"role":"Admin","permission":4}]}' \
    > /dev/null && log "Admin folder: restricted to Editor+" || warn "Admin folder not found yet"

[[ -n "$PERSONAL_UID" ]] && \
  g_api POST "/api/folders/${PERSONAL_UID}/permissions" \
    '{"items":[{"role":"Viewer","permission":1},{"role":"Editor","permission":2},{"role":"Admin","permission":4}]}' \
    > /dev/null && log "Personal folder: open to Viewers" || warn "Personal folder not found yet"

# ─── Summary ──────────────────────────────────────────────────────────────────
header "Deployment Complete"

echo -e ""
echo -e "${GREEN}${BOLD}✅ All services running natively (no Docker)!${RESET}"
echo -e ""
echo -e "${BOLD}Access URLs:${RESET}"
echo -e "  Grafana:   ${CYAN}${GRAFANA_ROOT_URL}${RESET}  (${G_ADMIN_USER} / ${G_ADMIN_PASS})"
echo -e "  Admin App: ${CYAN}${APP_URL}${RESET}  (admin / admin123)"
echo -e ""
echo -e "${BOLD}Service status:${RESET}"
systemctl is-active --quiet postgresql && echo -e "  postgresql   → ${GREEN}running${RESET}" || echo -e "  postgresql   → ${RED}stopped${RESET}"
systemctl is-active --quiet grafana-server && echo -e "  grafana      → ${GREEN}running${RESET}" || echo -e "  grafana      → ${RED}stopped${RESET}"
systemctl is-active --quiet "${APP_SERVICE}" && echo -e "  streamlit    → ${GREEN}running${RESET}" || echo -e "  streamlit    → ${RED}stopped${RESET}"
systemctl is-active --quiet nginx && echo -e "  nginx        → ${GREEN}running${RESET}" || echo -e "  nginx        → ${RED}stopped${RESET}"
echo -e ""
echo -e "${YELLOW}${BOLD}Next steps:${RESET}"
echo -e ""
echo -e "  ${BOLD}1. Upload Excel data${RESET}"
echo -e "     Open ${CYAN}${APP_URL}${RESET} → Full Refresh Upload"
echo -e ""
echo -e "  ${BOLD}2. Create employee Grafana users${RESET}"
echo -e "     bash ${INSTALL_DIR}/scripts/setup_users-native.sh"
echo -e ""
echo -e "${BOLD}Useful commands:${RESET}"
echo -e "  Logs (app):     journalctl -u ${APP_SERVICE} -f"
echo -e "  Logs (grafana): journalctl -u grafana-server -f"
echo -e "  Restart all:    bash ${INSTALL_DIR}/update-native.sh --restart-only"
echo -e ""
