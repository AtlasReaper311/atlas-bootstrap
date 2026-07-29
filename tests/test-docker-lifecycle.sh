#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_pass() {
  "$@"
}

assert_fail() {
  if ( "$@" ); then
    echo "expected failure: $*" >&2
    exit 1
  fi
}

write_fake_docker() {
  local os name root image restart mode networks
  os="$1"
  name="$2"
  root="$3"
  image="${4:-ghcr.io/open-webui/open-webui:v0.11.0}"
  restart="${5:-unless-stopped}"
  mode="${6:-bridge}"
  networks="${7:-1}"

  cat >"$TMP/docker" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "info" ]; then
  case "\$3" in
    *OperatingSystem*) echo "$os" ;;
    *Name*) echo "$name" ;;
    *DockerRootDir*) echo "$root" ;;
  esac
  exit 0
fi
if [ "\$1" = "inspect" ]; then
  case "\${*: -1}" in
    *Config.Image*) echo "$image" ;;
    *RestartPolicy.Name*) echo "$restart" ;;
    *HostConfig.NetworkMode*) echo "$mode" ;;
    *NetworkSettings.Networks*) echo "$networks" ;;
  esac
  exit 0
fi
exit 0
EOF
  chmod +x "$TMP/docker"
}

write_fake_ss() {
  cat >"$TMP/ss" <<EOF
#!/usr/bin/env bash
${1:-true}
EOF
  chmod +x "$TMP/ss"
}

write_fake_docker "Ubuntu 26.04 LTS" "SPECULAR-CORE" "/var/lib/docker"
write_fake_ss "true"
DOCKER_BIN="$TMP/docker"
SS_BIN="$TMP/ss"
. "$ROOT/lib/docker-lifecycle.sh"

assert_pass assert_native_docker_authority
assert_pass assert_openwebui_container_shape open-webui
assert_pass assert_port_not_stale 3000

write_fake_docker "Docker Desktop" "docker-desktop" "/var/lib/docker"
assert_fail assert_native_docker_authority

write_fake_docker "Ubuntu 26.04 LTS" "SPECULAR-CORE" "/var/lib/docker" "ghcr.io/open-webui/open-webui:v0.11.0" "always"
assert_fail assert_openwebui_container_shape open-webui

write_fake_docker "Ubuntu 26.04 LTS" "SPECULAR-CORE" "/var/lib/docker" "ghcr.io/open-webui/open-webui:v0.11.0" "unless-stopped" "bridge" "0"
assert_fail assert_openwebui_container_shape open-webui

write_fake_docker "Ubuntu 26.04 LTS" "SPECULAR-CORE" "/var/lib/docker"
write_fake_ss "echo 'LISTEN 0 4096 *:3000 *:* users:((\"python\",pid=99,fd=3))'"
assert_fail assert_port_not_stale 3000

echo "docker lifecycle tests passed"
