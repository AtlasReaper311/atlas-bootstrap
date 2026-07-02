#!/usr/bin/env bash
# bootstrap.sh
#
# WSL2 Ubuntu (or plain Ubuntu) side of the Atlas Systems environment.
# Fully idempotent: every section checks before it changes, so re-runs
# converge instead of duplicating. Run everything, or one section:
#
#   bash bootstrap.sh
#   bash bootstrap.sh --base /mnt/l/Atlas-Systems
#   bash bootstrap.sh --only docker_engine
#   bash bootstrap.sh --skip-models
#
# Sections, in order: preflight apt_packages docker_engine
# node_toolchain cloudflared_cli ollama_setup clone_repos seed_envs
# pull_models start_services health_check

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib"

BASE="${ATLAS_BASE:-/mnt/l/Atlas-Systems}"
ONLY=""
SKIP_MODELS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --skip-models) SKIP_MODELS=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

log()  { printf '\033[33m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[31m[bootstrap]\033[0m %s\n' "$*"; }
die()  { warn "$*"; exit 1; }

# Docker without a re-login: after usermod -aG docker the current shell
# still lacks the group, so this run falls back to sudo transparently.
docker_cmd() {
  if id -nG "$USER" | grep -qw docker; then docker "$@"; else sudo docker "$@"; fi
}

# --------------------------------------------------------------------- #
preflight() {
  log "preflight"
  if grep -qi microsoft /proc/version 2>/dev/null; then
    log "  environment: WSL2"
  else
    log "  environment: plain Linux (fine; portproxy is a Windows-side concern)"
  fi
  pidof systemd >/dev/null 2>&1 || die \
"systemd is not running. In WSL2, add to /etc/wsl.conf:
  [boot]
  systemd=true
then run 'wsl --shutdown' from Windows and re-run this script."
  sudo -v
  mkdir -p "$BASE" 2>/dev/null || die "cannot create base dir $BASE (is the drive mounted?)"
  log "  base directory: $BASE"
}

# --------------------------------------------------------------------- #
apt_packages() {
  log "apt_packages"
  sudo apt-get update -y -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl jq unzip ca-certificates gnupg lsb-release \
    python3 python3-venv python3-pip
  if ! command -v gh >/dev/null 2>&1; then
    log "  installing gh (GitHub CLI)"
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -y -qq
    sudo apt-get install -y -qq gh
  fi
  log "  apt packages present"
}

# --------------------------------------------------------------------- #
docker_engine() {
  log "docker_engine (native Linux Engine, the estate standard)"
  if command -v docker >/dev/null 2>&1 && docker_cmd compose version >/dev/null 2>&1; then
    log "  docker + compose already present"
  else
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  sudo systemctl enable --now docker
  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    log "  added $USER to the docker group (takes effect on next login; this run uses sudo)"
  fi
  log "  docker engine ready"
}

# --------------------------------------------------------------------- #
node_toolchain() {
  log "node_toolchain"
  if ! command -v node >/dev/null 2>&1; then
    log "  installing Node LTS (NodeSource 22.x)"
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null
    sudo apt-get install -y -qq nodejs
  fi
  log "  node $(node --version), npm $(npm --version)"
  if ! npm ls -g --depth=0 wrangler >/dev/null 2>&1; then
    log "  installing wrangler globally"
    sudo npm install -g wrangler >/dev/null
  fi
  log "  wrangler $(wrangler --version 2>/dev/null | head -n1)"
}

# --------------------------------------------------------------------- #
cloudflared_cli() {
  log "cloudflared_cli (CLI convenience; the tunnel service stays on Windows)"
  if command -v cloudflared >/dev/null 2>&1; then
    log "  cloudflared already present"
    return
  fi
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  sudo apt-get update -y -qq
  sudo apt-get install -y -qq cloudflared
  log "  cloudflared installed"
}

# --------------------------------------------------------------------- #
ollama_setup() {
  log "ollama_setup"
  if ! command -v ollama >/dev/null 2>&1; then
    log "  installing Ollama"
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  # The estate requirement: Ollama binds 0.0.0.0 so containers and (in
  # future) other machines can reach it. A drop-in survives upgrades;
  # editing the unit itself does not.
  sudo mkdir -p /etc/systemd/system/ollama.service.d
  printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\n' \
    | sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable ollama >/dev/null 2>&1 || true
  sudo systemctl restart ollama
  for _ in $(seq 1 15); do
    if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      log "  ollama answering on 11434 (bound 0.0.0.0)"
      return
    fi
    sleep 2
  done
  die "ollama did not answer /api/tags within 30s; inspect: journalctl -u ollama -n 50"
}

# --------------------------------------------------------------------- #
clone_repos() {
  log "clone_repos into $BASE"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"
  local owner
  owner=$(jq -r '.owner' "$LIB/repos.json")
  while IFS= read -r entry; do
    local name path target
    name=$(jq -r '.name' <<<"$entry")
    path=$(jq -r '.path' <<<"$entry")
    target="$BASE/$path"
    if [ -d "$target/.git" ]; then
      log "  $name: present, pulling"
      git -C "$target" pull --ff-only --quiet || warn "  $name: pull did not fast-forward (local work? left as-is)"
    else
      log "  $name: cloning"
      gh repo clone "$owner/$name" "$target" -- --quiet \
        || warn "  $name: clone failed (private without access, or not created yet); continuing"
    fi
  done < <(jq -c '.repos[]' "$LIB/repos.json")
}

# --------------------------------------------------------------------- #
seed_envs() {
  log "seed_envs (.env.example -> .env where missing)"
  local seeded=0
  while IFS= read -r example; do
    local dir="${example%/.env.example}"
    if [ ! -f "$dir/.env" ]; then
      cp "$example" "$dir/.env"
      log "  seeded ${dir#"$BASE"/}/.env"
      seeded=$((seeded + 1))
    fi
  done < <(find "$BASE" -maxdepth 2 -name ".env.example" 2>/dev/null)
  if [ "$seeded" -gt 0 ]; then
    warn "  $seeded .env file(s) seeded with defaults; secrets are NOT invented."
    warn "  Fill from Proton Pass before start_services: CORPUS_SECRET, GITHUB_TOKEN, ATLAS_SECRET."
    warn "  (RUNBOOK.md, section 'Seeding secrets'.)"
  else
    log "  nothing to seed"
  fi
}

# --------------------------------------------------------------------- #
pull_models() {
  if [ "$SKIP_MODELS" -eq 1 ]; then
    log "pull_models skipped (--skip-models)"
    return
  fi
  log "pull_models"
  while IFS= read -r model; do
    if ollama list | awk '{print $1}' | grep -qx "$model"; then
      log "  $model: present"
    else
      log "  $model: pulling (large; qwen2.5:32b is ~20GB)"
      ollama pull "$model"
    fi
  done < <(jq -r '.[]' "$LIB/models.json")
}

# --------------------------------------------------------------------- #
start_services() {
  log "start_services"
  while IFS= read -r entry; do
    local name path external dir
    name=$(jq -r '.name' <<<"$entry")
    path=$(jq -r '.path' <<<"$entry")
    external=$(jq -r '.external' <<<"$entry")
    if [ "$external" = "true" ]; then
      log "  $name: external lifecycle, not started here"
      continue
    fi
    dir="$BASE/$path"
    if [ ! -f "$dir/docker-compose.yml" ]; then
      warn "  $name: no docker-compose.yml at $dir; skipping"
      continue
    fi
    log "  $name: docker compose up -d"
    (cd "$dir" && docker_cmd compose up -d) \
      || warn "  $name: compose up failed (unset secret? see RUNBOOK 'Seeding secrets')"
  done < <(jq -c '.services[]' "$LIB/services.json")
}

# --------------------------------------------------------------------- #
health_check() {
  log "health_check"
  bash "$LIB/health-check.sh" || warn "  some services are down; RUNBOOK.md maps each to its fix"
}

# --------------------------------------------------------------------- #
SECTIONS="preflight apt_packages docker_engine node_toolchain cloudflared_cli ollama_setup clone_repos seed_envs pull_models start_services health_check"

if [ -n "$ONLY" ]; then
  case " $SECTIONS " in
    *" $ONLY "*) "$ONLY" ;;
    *) die "unknown section: $ONLY (valid: $SECTIONS)" ;;
  esac
else
  for section in $SECTIONS; do "$section"; done
  log "done. If docker group membership was added this run, log out and back in."
fi
