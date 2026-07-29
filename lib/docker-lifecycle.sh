#!/usr/bin/env bash
# Shared lifecycle checks for SPECULAR-CORE Docker startup.

set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
SS_BIN="${SS_BIN:-ss}"

docker_lifecycle_log() {
  printf '[docker-lifecycle] %s\n' "$*"
}

docker_lifecycle_die() {
  docker_lifecycle_log "$*" >&2
  exit 1
}

docker_os() {
  "$DOCKER_BIN" info --format '{{.OperatingSystem}}'
}

docker_name() {
  "$DOCKER_BIN" info --format '{{.Name}}'
}

docker_root_dir() {
  "$DOCKER_BIN" info --format '{{.DockerRootDir}}'
}

assert_native_docker_authority() {
  local os name root sock_target
  os="$(docker_os 2>/dev/null || true)"
  name="$(docker_name 2>/dev/null || true)"
  root="$(docker_root_dir 2>/dev/null || true)"
  sock_target="$(readlink -f /var/run/docker.sock 2>/dev/null || true)"

  case "$os:$name:$sock_target" in
    *"Docker Desktop"*|*"docker-desktop"*|*"/mnt/wsl/docker-desktop"*)
      docker_lifecycle_die "Docker Desktop may be installed, but must not own the estate Docker context or port bindings. Stop Desktop/integration manually, then retry."
      ;;
  esac

  if [ "$root" != "/var/lib/docker" ]; then
    docker_lifecycle_die "Unexpected Docker root '$root'; expected native WSL Engine root /var/lib/docker."
  fi

  if [ ! -S /var/run/docker.sock ]; then
    docker_lifecycle_die "Docker socket /var/run/docker.sock is not a native Unix socket."
  fi
}

container_exists() {
  "$DOCKER_BIN" inspect "$1" >/dev/null 2>&1
}

container_network_count() {
  "$DOCKER_BIN" inspect "$1" --format '{{len .NetworkSettings.Networks}}'
}

container_network_mode() {
  "$DOCKER_BIN" inspect "$1" --format '{{.HostConfig.NetworkMode}}'
}

container_image() {
  "$DOCKER_BIN" inspect "$1" --format '{{.Config.Image}}'
}

container_restart_policy() {
  "$DOCKER_BIN" inspect "$1" --format '{{.HostConfig.RestartPolicy.Name}}'
}

assert_container_network_attached() {
  local name mode count
  name="$1"
  mode="$(container_network_mode "$name")"
  count="$(container_network_count "$name")"

  if [ "$mode" = "bridge" ] && [ "$count" = "0" ]; then
    docker_lifecycle_die "$name has NetworkMode=bridge but no attached Docker networks; treat it as unhealthy even if an internal health check passes."
  fi
}

assert_openwebui_container_shape() {
  local name image restart
  name="${1:-open-webui}"

  container_exists "$name" || return 0
  image="$(container_image "$name")"
  restart="$(container_restart_policy "$name")"

  if [ "$image" != "ghcr.io/open-webui/open-webui:v0.11.0" ]; then
    docker_lifecycle_die "$name uses $image; expected ghcr.io/open-webui/open-webui:v0.11.0."
  fi

  if [ "$restart" != "unless-stopped" ]; then
    docker_lifecycle_die "$name has restart=$restart; expected unless-stopped."
  fi

  assert_container_network_attached "$name"
}

assert_port_not_stale() {
  local port owner
  port="$1"
  owner="$("$SS_BIN" -ltnp "sport = :$port" 2>/dev/null || true)"

  if printf '%s\n' "$owner" | grep -q LISTEN; then
    if ! printf '%s\n' "$owner" | grep -q 'docker-proxy'; then
      docker_lifecycle_die "Port $port is already listening outside Docker's native proxy. Clear that owner manually before recreating Open WebUI."
    fi
  fi
}

wait_http() {
  local label url tries sleep_seconds code
  label="$1"
  url="$2"
  tries="${3:-30}"
  sleep_seconds="${4:-2}"

  while [ "$tries" -gt 0 ]; do
    code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
    case "$code" in
      2*|3*|401|403)
        docker_lifecycle_log "$label ready: HTTP $code"
        return 0
        ;;
    esac
    tries=$((tries - 1))
    sleep "$sleep_seconds"
  done

  docker_lifecycle_die "$label did not become reachable at $url."
}

wait_openwebui_ready() {
  local name
  name="${1:-open-webui}"

  assert_container_network_attached "$name"
  "$DOCKER_BIN" exec "$name" sh -lc 'ip route | grep -q "^default "' >/dev/null 2>&1 \
    || docker_lifecycle_die "$name has no default route."
  wait_http "Open WebUI" "http://127.0.0.1:3000/health" 45 2
}
