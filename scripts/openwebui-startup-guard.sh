#!/usr/bin/env bash
# Start only the canonical Open WebUI service under native WSL Docker.

set -euo pipefail

PART() { printf '\nPART %s\n' "$1"; }
STEP() { printf 'STEP %s\n' "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASE="${ATLAS_BASE:-/mnt/l/Atlas-Systems}"
COMPOSE_DIR="${ATLAS_OPENWEBUI_COMPOSE_DIR:-$BASE/atlas-bootstrap/services/open-webui}"

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ] && [ -f "$ROOT/services/open-webui/docker-compose.yml" ]; then
  COMPOSE_DIR="$ROOT/services/open-webui"
fi

. "$ROOT/lib/docker-lifecycle.sh"

PART "0 - authority"
STEP "check native Docker authority"
assert_native_docker_authority

PART "1 - preflight"
STEP "check Open WebUI compose file"
test -f "$COMPOSE_DIR/docker-compose.yml"

STEP "check existing canonical container shape"
if container_exists open-webui
then
  assert_openwebui_container_shape open-webui
fi

STEP "check stale port owner"
assert_port_not_stale 3000 open-webui

PART "2 - start"
STEP "start canonical Open WebUI compose service"
cd "$COMPOSE_DIR"
"$DOCKER_BIN" compose up -d

PART "3 - verify"
STEP "validate canonical container shape"
assert_openwebui_container_shape open-webui

STEP "wait for network, default route, published port, and health"
wait_openwebui_ready open-webui

PART "4 - done"
STEP "Open WebUI is canonical and healthy"
