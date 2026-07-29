#!/usr/bin/env bash
# Not run by bootstrap. Execute only after explicit live migration approval.

set -eu

PART() { printf '\nPART %s\n' "$1"; }
STEP() { printf 'STEP %s\n' "$1"; }
STOP() { printf 'STOP %s\n' "$1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE="${ATLAS_BASE:-/mnt/l/Atlas-Systems}"
COMPOSE_DIR="${ATLAS_OPENWEBUI_COMPOSE_DIR:-$BASE/atlas-bootstrap/services/open-webui}"
DATA_DIR="${ATLAS_OPENWEBUI_DATA:-/home/atlas/openwebui-core-data}"
DB_PATH="$DATA_DIR/webui.db"
BACKUP_ROOT="${ATLAS_BACKUP_ROOT:-/mnt/l/Backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/openwebui-live-recovery-$STAMP"
BACKUP_DB="$BACKUP_DIR/webui.db.before-openwebui-native-recovery"
POSTMORTEM_ENV="${ATLAS_POSTMORTEM_API_ENV:-$HOME/.config/atlas-postmortem/api.env}"

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ] && [ -f "$ROOT/services/open-webui/docker-compose.yml" ]; then
  COMPOSE_DIR="$ROOT/services/open-webui"
fi

. "$ROOT/lib/docker-lifecycle.sh"

PART "0 - manual boundary"
STEP "confirm Docker Desktop is not the estate authority"
assert_native_docker_authority

STEP "confirm postmortem drafting is not enabled by this script"
test "${DRAFT_ENABLED:-false}" = "false"

PART "1 - backup"
STEP "create backup directory"
mkdir -p "$BACKUP_DIR"

STEP "copy Open WebUI SQLite database"
cp "$DB_PATH" "$BACKUP_DB"

STEP "verify copied database exists"
test -s "$BACKUP_DB"

STEP "verify copied database is readable"
python3 - "$BACKUP_DB" <<'PY'
import sqlite3
import sys

path = sys.argv[1]
conn = sqlite3.connect(path)
try:
    result = conn.execute("pragma integrity_check").fetchone()
finally:
    conn.close()

if result != ("ok",):
    raise SystemExit("SQLite integrity check failed")
PY

PART "2 - preflight"
STEP "check Open WebUI compose file"
test -f "$COMPOSE_DIR/docker-compose.yml"

STEP "check stale port owner"
assert_port_not_stale 3000

PART "3 - canonical recreate"
STEP "stop only canonical Open WebUI if it exists"
if container_exists open-webui
then
  "$DOCKER_BIN" stop open-webui
fi

STEP "remove only canonical Open WebUI if it exists"
if container_exists open-webui
then
  "$DOCKER_BIN" rm open-webui
fi

STEP "recreate Open WebUI from canonical compose"
cd "$COMPOSE_DIR"
"$DOCKER_BIN" compose up -d

PART "4 - verify"
STEP "validate canonical container shape"
assert_openwebui_container_shape open-webui

STEP "wait for network, default route, published port, and health"
wait_openwebui_ready open-webui

STEP "check postmortem bridge from Open WebUI without printing token"
if [ ! -f "$POSTMORTEM_ENV" ]
then
  STOP "postmortem API env file missing; leave DRAFT_ENABLED=false and configure the bridge token manually"
fi

set -a
. "$POSTMORTEM_ENV"
set +a

if [ -z "${ATLAS_PM_API_TOKEN:-}" ]
then
  STOP "postmortem bearer token is missing; leave DRAFT_ENABLED=false"
fi

"$DOCKER_BIN" exec -e ATLAS_PM_API_TOKEN="$ATLAS_PM_API_TOKEN" open-webui python -c 'import os, urllib.request as r; req = r.Request("http://host.docker.internal:8765/health", headers={"Authorization": "Bearer " + os.environ["ATLAS_PM_API_TOKEN"]}); r.urlopen(req, timeout=5)'

PART "5 - rollback"
STEP "manual rollback command, not executed"
printf 'docker stop open-webui\n'
printf 'cp %s %s\n' "$BACKUP_DB" "$DB_PATH"
printf 'cd %s\n' "$COMPOSE_DIR"
printf 'docker compose up -d\n'

PART "6 - done"
STEP "Open WebUI recovered under native Docker; DRAFT_ENABLED remains false"
