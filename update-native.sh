#!/usr/bin/env bash
# =============================================================================
# update-native.sh — Pull latest code from GitHub and restart native services
#
# Usage (on the server):
#   bash /opt/analytics/update-native.sh
#   bash /opt/analytics/update-native.sh --restart-only
# =============================================================================

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/analytics}"
APP_SERVICE="analytics-app"
DB_USER="admin"
DB_PASS="secretpassword"
DB_NAME="analytics_db"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()    { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[!]${RESET} $*"; }
header() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${RESET}"; }

RESTART_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --restart-only) RESTART_ONLY=true; shift ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

cd "${INSTALL_DIR}"

if [[ "$RESTART_ONLY" == "false" ]]; then
  header "Pulling latest code"

  git fetch origin
  CHANGES=$(git log HEAD..origin/main --oneline)

  if [[ -z "$CHANGES" ]]; then
    warn "Already up to date — nothing to pull"
  else
    echo -e "${BOLD}New commits:${RESET}"
    echo "$CHANGES" | while read -r line; do echo "  • $line"; done
    git pull --rebase origin main
    log "Code updated"
  fi

  # Re-install Python dependencies if requirements.txt changed
  if git diff HEAD@{1} HEAD -- app/requirements.txt 2>/dev/null | grep -q '^[+-]'; then
    header "Updating Python dependencies"
    "${INSTALL_DIR}/app/venv/bin/pip" install --quiet -r "${INSTALL_DIR}/app/requirements.txt"
    log "Dependencies updated"
  fi

  # Re-apply SQL views if sql/ changed
  if git diff HEAD@{1} HEAD -- sql/ 2>/dev/null | grep -q '^[+-]'; then
    header "Re-applying SQL views"
    PGPASSWORD="${DB_PASS}" psql -U "${DB_USER}" -h 127.0.0.1 -d "${DB_NAME}" \
      -f "${INSTALL_DIR}/sql/build_calculated_views.sql" &>/dev/null && \
      log "Calculated views updated" || warn "SQL warnings (may be safe to ignore)"
  fi

  # Sync Grafana dashboard JSONs if grafana_config changed
  if git diff HEAD@{1} HEAD -- grafana_config/ 2>/dev/null | grep -q '^[+-]'; then
    header "Syncing Grafana dashboards"
    cp -r "${INSTALL_DIR}/grafana_config/provisioning/dashboards" \
          /etc/grafana/provisioning/
    chown -R grafana:grafana /etc/grafana/provisioning
    log "Dashboard files synced"
  fi
fi

header "Restarting services"

systemctl restart "${APP_SERVICE}"
log "Streamlit restarted"

# Grafana needs restart only if its config/dashboards changed
systemctl reload-or-restart grafana-server
log "Grafana reloaded"

systemctl reload nginx
log "Nginx reloaded"

header "Done"
echo -e "${GREEN}${BOLD}✅ Update complete!${RESET}"
echo ""
echo -e "${BOLD}Service status:${RESET}"
for svc in postgresql grafana-server "${APP_SERVICE}" nginx; do
  if systemctl is-active --quiet "$svc"; then
    echo -e "  ${svc} → ${GREEN}running${RESET}"
  else
    echo -e "  ${svc} → ${RED}stopped${RESET}"
  fi
done
echo ""
