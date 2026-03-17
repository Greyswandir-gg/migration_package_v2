#!/usr/bin/env bash
# =============================================================================
#  scripts/setup_users.sh — Create Grafana employee users
#
#  Run this AFTER uploading Excel data via the Admin App.
#  It reads employees from xl_projecttimes, creates a Grafana login for each,
#  populates work_logs, and sets folder permissions.
#
#  Usage:
#    bash scripts/setup_users.sh
#    bash scripts/setup_users.sh --pass "MySecret123!" --admin-pass "grafana_admin"
#    bash scripts/setup_users.sh --help
# =============================================================================

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────
PROJECT_NAME="${PROJECT_NAME:-migration_package_v2}"
DB_USER="admin"
DB_PASS="secretpassword"
DB_NAME="analytics_db"
G_ADMIN_USER="admin"
G_ADMIN_PASS="${G_ADMIN_PASS:-admin}"
DEFAULT_PASS="${DEFAULT_PASS:-Welcome2026!}"
G_BASE="http://127.0.0.1:3000/grafana"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()    { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[!]${RESET} $*"; }
error()  { echo -e "${RED}[✗]${RESET} $*" >&2; }
header() { echo -e "\n${CYAN}${BOLD}═══ $* ═══${RESET}"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
show_help() {
  echo -e "${BOLD}Setup Users — Employee Grafana User Creation${RESET}"
  echo ""
  echo "Usage: bash scripts/setup_users.sh [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --pass PASS          Default employee password (default: Welcome2026!)"
  echo "  --admin-pass PASS    Grafana admin password (default: admin)"
  echo "  --project NAME       Docker Compose project name (default: migration_package_v2)"
  echo "  --help               Show this help"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pass)       DEFAULT_PASS="$2";   shift 2 ;;
    --admin-pass) G_ADMIN_PASS="$2";   shift 2 ;;
    --project)    PROJECT_NAME="$2";   shift 2 ;;
    --help|-h)    show_help ;;
    *) error "Unknown argument: $1"; exit 1 ;;
  esac
done

echo -e "${CYAN}${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   Analytics Dashboard — User Setup         ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${RESET}"

DB_CONTAINER="${PROJECT_NAME}-db-1"
GRAFANA_CONTAINER="${PROJECT_NAME}-grafana-1"

# ─── Helpers ─────────────────────────────────────────────────────────────────
psql_exec() {
  docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -A -c "$1" 2>/dev/null
}

g_api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    docker exec "$GRAFANA_CONTAINER" curl -sf \
      -u "${G_ADMIN_USER}:${G_ADMIN_PASS}" \
      -H "Content-Type: application/json" \
      -X "$method" "${G_BASE}${path}" \
      -d "$body" 2>/dev/null || echo "{}"
  else
    docker exec "$GRAFANA_CONTAINER" curl -sf \
      -u "${G_ADMIN_USER}:${G_ADMIN_PASS}" \
      "${G_BASE}${path}" 2>/dev/null || echo "[]"
  fi
}

# ─── Check containers are running ────────────────────────────────────────────
header "Step 1: Checking containers"

if ! docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"; then
  error "Database container '${DB_CONTAINER}' is not running."
  error "Run './deploy.sh' first."
  exit 1
fi
log "DB container: $DB_CONTAINER"

if ! docker ps --format '{{.Names}}' | grep -q "^${GRAFANA_CONTAINER}$"; then
  error "Grafana container '${GRAFANA_CONTAINER}' is not running."
  exit 1
fi
log "Grafana container: $GRAFANA_CONTAINER"

# ─── Check data exists ────────────────────────────────────────────────────────
header "Step 2: Checking data"

ROW_COUNT=$(psql_exec "SELECT COUNT(*) FROM xl_projecttimes;" 2>/dev/null || echo "0")
ROW_COUNT=$(echo "$ROW_COUNT" | tr -d ' ')

if [[ "$ROW_COUNT" -eq 0 ]]; then
  error "xl_projecttimes is empty. Please upload Excel data via the Admin App first."
  error "Then re-run this script."
  exit 1
fi

log "Found $ROW_COUNT rows in xl_projecttimes"

# ─── Create employees table and derive logins ────────────────────────────────
header "Step 3: Building employees table"

# Create employees table if not exists
psql_exec "
CREATE TABLE IF NOT EXISTS employees (
    id SERIAL PRIMARY KEY,
    mitarbeiter TEXT NOT NULL UNIQUE,
    login VARCHAR(100) NOT NULL UNIQUE,
    ma_kat TEXT,
    created_at TIMESTAMP DEFAULT NOW()
);" > /dev/null

# Use Python inside web_app container to derive logins (uses same logic as main.py)
log "Deriving logins from employee names..."
docker exec "${PROJECT_NAME}-web_app-1" python3 - << 'PYEOF'
import sys, unicodedata, re
from sqlalchemy import create_engine, text
import os

DB_URL = os.getenv("DATABASE_URL", "postgresql://admin:secretpassword@db:5432/analytics_db")
engine = create_engine(DB_URL)

def sanitize_login_part(value):
    raw = str(value or "").strip().lower()
    raw = unicodedata.normalize("NFKD", raw).encode("ascii", "ignore").decode("ascii")
    raw = re.sub(r"[^a-z0-9]+", ".", raw)
    raw = re.sub(r"[.]+", ".", raw).strip(".")
    return raw

def derive_login(employee_name):
    name = str(employee_name or "").strip()
    if not name:
        return "unassigned"
    if "," in name:
        last = sanitize_login_part(name.split(",", 1)[0])
        first = sanitize_login_part(name.split(",", 1)[1])
        candidate = ".".join([p for p in (last, first) if p])
        return candidate or "unassigned"
    parts = [sanitize_login_part(p) for p in name.split() if sanitize_login_part(p)]
    if len(parts) >= 2:
        return f"{parts[0]}.{parts[1]}"
    return parts[0] if parts else "unassigned"

def make_unique(login_map):
    seen = {}
    result = {}
    for name, lg in login_map.items():
        cnt = seen.get(lg, 0) + 1
        seen[lg] = cnt
        result[name] = lg if cnt == 1 else f"{lg}_{cnt}"
    return result

with engine.begin() as conn:
    rows = conn.execute(text(
        "SELECT DISTINCT mitarbeiter FROM xl_projecttimes "
        "WHERE mitarbeiter IS NOT NULL AND mitarbeiter <> '' "
        "ORDER BY mitarbeiter"
    )).fetchall()

    raw_map = {r[0]: derive_login(r[0]) for r in rows}
    unique_map = make_unique(raw_map)

    inserted = 0
    for mitarbeiter, login in unique_map.items():
        if login == "unassigned":
            continue
        m_esc = mitarbeiter.replace("'", "''")
        l_esc = login.replace("'", "''")
        try:
            conn.execute(text(
                f"INSERT INTO employees (mitarbeiter, login) "
                f"VALUES ('{m_esc}', '{l_esc}') ON CONFLICT DO NOTHING"
            ))
            inserted += 1
        except Exception:
            pass

    # Update ma_kat
    conn.execute(text("""
        UPDATE employees e
        SET ma_kat = sub.ma_kat
        FROM (
            SELECT DISTINCT ON (mitarbeiter) mitarbeiter, ma_kat
            FROM xl_projecttimes
            WHERE ma_kat IS NOT NULL
            ORDER BY mitarbeiter, ma_kat
        ) sub
        WHERE e.mitarbeiter = sub.mitarbeiter
    """))

    total = conn.execute(text("SELECT COUNT(*) FROM employees")).scalar()
    print(f"employees table: {total} records")
PYEOF

EMP_COUNT=$(psql_exec "SELECT COUNT(*) FROM employees;" | tr -d ' ')
log "employees table: $EMP_COUNT employees"

# ─── Populate work_logs ───────────────────────────────────────────────────────
header "Step 4: Populating work_logs"

psql_exec "TRUNCATE TABLE work_logs RESTART IDENTITY;" > /dev/null

psql_exec "
INSERT INTO work_logs (owner_login, upload_date, work_date, duration, department, project_number, activity_type, employee_name, description, employment_type)
SELECT
    COALESCE(emp.login, 'unassigned')    AS owner_login,
    NOW()                                AS upload_date,
    xp.datum::date                       AS work_date,
    xp.dauer                             AS duration,
    xp.bereich_neu                       AS department,
    xp.projekt_nr                        AS project_number,
    xp.task_new                          AS activity_type,
    xp.mitarbeiter                       AS employee_name,
    xp.bemerkung                         AS description,
    CASE
        WHEN xp.ma_kat = 'RW'   THEN 'Full-time'
        WHEN xp.ma_kat = 'Sub'  THEN 'Subcontractor'
        WHEN xp.ma_kat = 'Temp' THEN 'Temporary'
        ELSE xp.ma_kat
    END                                  AS employment_type
FROM xl_projecttimes xp
LEFT JOIN employees emp ON emp.mitarbeiter = xp.mitarbeiter
WHERE xp.datum IS NOT NULL AND xp.dauer IS NOT NULL;" > /dev/null

WL_COUNT=$(psql_exec "SELECT COUNT(*) FROM work_logs;" | tr -d ' ')
log "work_logs populated: $WL_COUNT rows"

# ─── Create Grafana users ─────────────────────────────────────────────────────
header "Step 5: Creating Grafana users"

# Get all existing logins
EXISTING_LOGINS=$(g_api GET "/api/org/users" | \
  grep -o '"login":"[^"]*"' | cut -d'"' -f4 | sort)

# Get employees from DB
EMPLOYEES=$(psql_exec "SELECT mitarbeiter || '|' || login FROM employees ORDER BY mitarbeiter;")

CREATED=0
SKIPPED=0

while IFS='|' read -r mitarbeiter login; do
  mitarbeiter=$(echo "$mitarbeiter" | xargs)
  login=$(echo "$login" | xargs)
  [[ -z "$login" || "$login" == "unassigned" ]] && continue

  if echo "$EXISTING_LOGINS" | grep -qx "$login"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Display name: "Lastname, Firstname" → "Firstname Lastname"
  if echo "$mitarbeiter" | grep -q ","; then
    last=$(echo "$mitarbeiter" | cut -d',' -f1 | xargs)
    first=$(echo "$mitarbeiter" | cut -d',' -f2 | xargs)
    display="${first} ${last}"
  else
    display="$mitarbeiter"
  fi

  email="${login}@company.local"
  payload="{\"name\":\"${display}\",\"email\":\"${email}\",\"login\":\"${login}\",\"password\":\"${DEFAULT_PASS}\"}"

  resp=$(g_api POST "/api/admin/users" "$payload")
  uid=$(echo "$resp" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

  if [[ -n "$uid" && "$uid" != "null" ]]; then
    g_api PATCH "/api/org/users/${uid}" '{"role":"Viewer"}' > /dev/null
    CREATED=$((CREATED + 1))
  else
    warn "Could not create user '$login': $resp"
  fi
done <<< "$EMPLOYEES"

log "Users created: $CREATED, already existed: $SKIPPED"

# ─── Folder permissions ───────────────────────────────────────────────────────
header "Step 6: Setting Grafana folder permissions"

FOLDERS=$(g_api GET "/api/folders?limit=100")

ADMIN_UID=$(echo "$FOLDERS" | grep -o '"uid":"[^"]*","title":"Admin"' | \
  grep -o '"uid":"[^"]*"' | cut -d'"' -f4 || true)
PERSONAL_UID=$(echo "$FOLDERS" | grep -o '"uid":"[^"]*","title":"Personal"' | \
  grep -o '"uid":"[^"]*"' | cut -d'"' -f4 || true)

if [[ -n "$ADMIN_UID" ]]; then
  g_api POST "/api/folders/${ADMIN_UID}/permissions" \
    '{"items":[{"role":"Editor","permission":1},{"role":"Admin","permission":4}]}' \
    > /dev/null
  log "Admin folder: restricted to Editor+ only"
else
  warn "Admin folder not found"
fi

if [[ -n "$PERSONAL_UID" ]]; then
  g_api POST "/api/folders/${PERSONAL_UID}/permissions" \
    '{"items":[{"role":"Viewer","permission":1},{"role":"Editor","permission":2},{"role":"Admin","permission":4}]}' \
    > /dev/null
  log "Personal folder: open to all Viewers"
else
  warn "Personal folder not found"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
header "Done"

echo -e ""
echo -e "${GREEN}${BOLD}✅ Employee user setup complete!${RESET}"
echo -e ""
echo -e "  Total employees: ${BOLD}$EMP_COUNT${RESET}"
echo -e "  Users created:   ${BOLD}$CREATED${RESET}"
echo -e "  Default password: ${BOLD}${DEFAULT_PASS}${RESET}"
echo -e ""
echo -e "${BOLD}Login format:${RESET}"
echo -e "  'Afanasjevs, Artjoms' → login: ${CYAN}afanasjevs.artjoms${RESET}"
echo -e "  'Müller, Hans'        → login: ${CYAN}muller.hans${RESET}"
echo -e ""
echo -e "${YELLOW}Note:${RESET} Each employee sees only the Personal dashboard after login."
echo -e "      They can change their password in Grafana profile settings."
echo -e ""
