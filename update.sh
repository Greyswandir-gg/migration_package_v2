#!/usr/bin/env bash
# =============================================================================
#  update.sh — Pull latest code from GitHub and restart changed containers
#
#  Usage (on the server):
#    bash update.sh
# =============================================================================

set -euo pipefail

PROJECT_NAME="migration_package_v2"
COMPOSE_FILE="docker-compose.remote.yml"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()    { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[!]${RESET} $*"; }
header() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${RESET}"; }

cd "$(dirname "$0")"

header "Pulling latest code"
git fetch origin
CHANGES=$(git log HEAD..origin/main --oneline)

if [[ -z "$CHANGES" ]]; then
  warn "Already up to date — nothing to update"
  exit 0
fi

echo -e "${BOLD}New commits:${RESET}"
echo "$CHANGES" | while read -r line; do echo "  • $line"; done

git pull --rebase origin main
log "Code updated"

header "Restarting containers"
docker compose -p "$PROJECT_NAME" -f "$COMPOSE_FILE" up -d --build
log "Containers restarted"

header "Done"
echo -e "${GREEN}${BOLD}✅ Project updated successfully!${RESET}"
echo ""
docker ps --format "  {{.Names}}  →  {{.Status}}" | grep "$PROJECT_NAME"
echo ""
