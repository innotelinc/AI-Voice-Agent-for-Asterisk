#!/usr/bin/env bash
# Bootstrap a barebones Debian/Ubuntu host for local AAVA + host Asterisk.
#
# Scope:
# - installs host dependencies (Docker, Asterisk, git/make/python helpers)
# - prepares repo-local .env for local_hybrid / local-core
# - configures host Asterisk ARI + HTTP + from-ai-agent dialplan
# - ensures operator user can access Asterisk/Docker groups
# - downloads local models and starts local-core services
# - runs preflight + health verification
#
# Non-goals:
# - does NOT install FreePBX. Use the repo docs for FreePBX-specific manual setup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_NAME="asterisk-ai-voice-agent"
ENV_FILE="$REPO_DIR/.env"
ENV_EXAMPLE="$REPO_DIR/.env.example"
PRECHECK_ONLY=false
SKIP_MODELS=false
SKIP_STACK=false
OPERATOR_USER="${SUDO_USER:-${USER:-root}}"
ASTERISK_ARI_USERNAME="${ASTERISK_ARI_USERNAME:-aava}"
ASTERISK_ARI_PASSWORD="${ASTERISK_ARI_PASSWORD:-AAVAchangeMeNow123!}"
ASTERISK_HTTP_BINDADDR="${ASTERISK_HTTP_BINDADDR:-127.0.0.1}"
ASTERISK_HTTP_BINDPORT="${ASTERISK_HTTP_BINDPORT:-8088}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
die() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/install-barebones-server.sh [options]

Bootstrap a barebones Debian/Ubuntu host for:
- host Asterisk
- local-core AAVA Docker services
- local_hybrid dialplan entry at from-ai-agent,s,1

Options:
  --check                 Verify current host/repo state only; make no changes
  --skip-models           Skip `make model-setup`
  --skip-stack            Skip `docker compose up`
  --operator-user USER    User to add to docker + asterisk groups
  --ari-user USER         ARI username to configure in host Asterisk
  --ari-password PASS     ARI password to configure in host Asterisk
  -h, --help              Show this help

Examples:
  sudo scripts/install-barebones-server.sh
  sudo scripts/install-barebones-server.sh --operator-user claude
  sudo scripts/install-barebones-server.sh --check
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      PRECHECK_ONLY=true
      shift
      ;;
    --skip-models)
      SKIP_MODELS=true
      shift
      ;;
    --skip-stack)
      SKIP_STACK=true
      shift
      ;;
    --operator-user)
      OPERATOR_USER="$2"
      shift 2
      ;;
    --ari-user)
      ASTERISK_ARI_USERNAME="$2"
      shift 2
      ;;
    --ari-password)
      ASTERISK_ARI_PASSWORD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    die "Run as root or install sudo"
  fi
fi

require_repo_files() {
  [[ -f "$REPO_DIR/docker-compose.yml" ]] || die "Run this script from inside the AAVA repo"
  [[ -f "$REPO_DIR/docker-compose.local-core.yml" ]] || die "Missing docker-compose.local-core.yml"
  [[ -f "$REPO_DIR/preflight.sh" ]] || die "Missing preflight.sh"
  [[ -f "$ENV_EXAMPLE" ]] || die "Missing .env.example"
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || die "This script currently supports apt-based Debian/Ubuntu hosts only"
}

apt_install() {
  local pkgs=()
  for pkg in "$@"; do
    [[ -n "$pkg" ]] && pkgs+=("$pkg")
  done
  [[ ${#pkgs[@]} -gt 0 ]] || return 0
  if [[ -n "$SUDO" ]]; then
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  fi
}

compose_package_name() {
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    echo docker-compose-v2
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    echo docker-compose-plugin
  else
    echo ""
  fi
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo docker-compose
  else
    return 1
  fi
}

set_env_key() {
  local key="$1"
  local value="$2"
  python3 - "$ENV_FILE" "$key" "$value" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text().splitlines()
out = []
updated = False
for line in lines:
    if line.startswith(f"{key}="):
        out.append(f"{key}={value}")
        updated = True
    else:
        out.append(line)
if not updated:
    if out and out[-1].strip() != "":
        out.append("")
    out.append(f"{key}={value}")
path.write_text("\n".join(out) + "\n")
PY
}

replace_managed_block() {
  local file="$1"
  local block_name="$2"
  local content="$3"
  $SUDO mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || $SUDO touch "$file"
  local tmp
  tmp="$(mktemp)"
  python3 - "$file" "$tmp" "$block_name" "$content" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
name = sys.argv[3]
content = sys.argv[4]
start = f"; >>> AAVA managed block: {name} >>>"
end = f"; <<< AAVA managed block: {name} <<<"
text = src.read_text() if src.exists() else ""
lines = text.splitlines()
out = []
in_block = False
for line in lines:
    if line.strip() == start:
        in_block = True
        continue
    if in_block and line.strip() == end:
        in_block = False
        continue
    if not in_block:
        out.append(line)
while out and out[-1] == "":
    out.pop()
if out:
    out.append("")
out.append(start)
out.extend(content.strip("\n").splitlines())
out.append(end)
out.append("")
dst.write_text("\n".join(out))
PY
  $SUDO cp "$tmp" "$file"
  rm -f "$tmp"
}

ensure_asterisk_ctl_settings() {
  local file="/etc/asterisk/asterisk.conf"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  python3 - "$file" "$tmp" <<'PY'
import re, sys
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
text = src.read_text()
repls = {
    'astctlpermissions': '0660',
    'astctlowner': 'asterisk',
    'astctlgroup': 'asterisk',
}
for key, value in repls.items():
    pattern = re.compile(rf'^(\s*;?\s*{re.escape(key)}\s*=).*$' , re.MULTILINE)
    if pattern.search(text):
        text = pattern.sub(rf'\1 {value}', text)
    else:
        if '[files]' in text:
            text = text.replace('[files]', f'[files]\n{key} = {value}', 1)
        else:
            text += f'\n[files]\n{key} = {value}\n'
dst.write_text(text)
PY
  $SUDO cp "$tmp" "$file"
  rm -f "$tmp"
}

install_packages() {
  info "Installing host packages"
  $SUDO apt-get update
  local compose_pkg
  compose_pkg="$(compose_package_name || true)"
  apt_install \
    ca-certificates curl git jq make python3 python3-venv rsync \
    software-properties-common gnupg lsb-release \
    docker.io ${compose_pkg:-} asterisk asterisk-core-sounds-en-wav
}

ensure_services() {
  info "Enabling and starting docker + asterisk"
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker || true
    $SUDO systemctl enable --now asterisk || true
  fi
}

ensure_groups() {
  local ast_gid=""
  local operator="$OPERATOR_USER"
  getent group asterisk >/dev/null 2>&1 || $SUDO groupadd asterisk || true
  getent group docker >/dev/null 2>&1 || true
  if id "$operator" >/dev/null 2>&1; then
    $SUDO usermod -aG asterisk "$operator" || true
    getent group docker >/dev/null 2>&1 && $SUDO usermod -aG docker "$operator" || true
  else
    warn "Operator user '$operator' does not exist; skipping usermod"
  fi
  ast_gid="$(getent group asterisk | cut -d: -f3 2>/dev/null || echo 995)"
  success "Asterisk group GID: $ast_gid"
}

ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    info "Creating .env from .env.example"
    cp "$ENV_EXAMPLE" "$ENV_FILE"
  fi
  local ast_gid ast_uid
  ast_gid="$(getent group asterisk | cut -d: -f3 2>/dev/null || echo 995)"
  ast_uid="$(id -u asterisk 2>/dev/null || echo 995)"
  set_env_key ASTERISK_HOST 127.0.0.1
  set_env_key ASTERISK_ARI_PORT "$ASTERISK_HTTP_BINDPORT"
  set_env_key ASTERISK_ARI_USERNAME "$ASTERISK_ARI_USERNAME"
  set_env_key ASTERISK_ARI_PASSWORD "$ASTERISK_ARI_PASSWORD"
  set_env_key ASTERISK_UID "$ast_uid"
  set_env_key ASTERISK_GID "$ast_gid"
  set_env_key LOCAL_STT_MODEL_PATH /app/models/stt/vosk-model-small-en-us-0.15
  set_env_key LOCAL_LLM_MODEL_PATH /app/models/llm/qwen2.5-1.5b-instruct-q4_k_m.gguf
  set_env_key LOCAL_LLM_CHAT_FORMAT chatml
  set_env_key LOCAL_TTS_MODEL_PATH /app/models/tts/en_US-lessac-medium.onnx
}

configure_asterisk() {
  info "Configuring host Asterisk for ARI + HTTP + from-ai-agent"
  replace_managed_block \
    /etc/asterisk/ari_additional_custom.conf \
    aava-ari \
    "[general]
enabled = yes
pretty = yes
allowed_origins = *

[${ASTERISK_ARI_USERNAME}]
type = user
read_only = no
password = ${ASTERISK_ARI_PASSWORD}"

  replace_managed_block \
    /etc/asterisk/http_custom.conf \
    aava-http \
    "[general]
enabled=yes
bindaddr=${ASTERISK_HTTP_BINDADDR}
bindport=${ASTERISK_HTTP_BINDPORT}"

  replace_managed_block \
    /etc/asterisk/extensions_custom.conf \
    aava-from-ai-agent \
    "[from-ai-agent]
exten => s,1,NoOp(Asterisk AI Voice Agent)
 same => n,Set(AI_PROVIDER=local_hybrid)
 same => n,Set(AI_CONTEXT=default)
 same => n,Stasis(asterisk-ai-voice-agent)
 same => n,Hangup()"

  ensure_asterisk_ctl_settings

  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl restart asterisk
  else
    $SUDO service asterisk restart
  fi
}

run_model_setup() {
  $SKIP_MODELS && { warn "Skipping model setup"; return 0; }
  info "Downloading/reusing local model set"
  (cd "$REPO_DIR" && make model-setup)
}

run_preflight() {
  info "Running preflight with auto-fixes"
  set +e
  (cd "$REPO_DIR" && bash ./preflight.sh --apply-fixes)
  local rc=$?
  set -e
  if [[ $rc -gt 1 ]]; then
    die "preflight.sh reported blocking failures"
  fi
}

start_stack() {
  $SKIP_STACK && { warn "Skipping docker compose up"; return 0; }
  local dc
  dc="$(compose_cmd)"
  info "Building and starting local-core services"
  (cd "$REPO_DIR" && $dc -p "$PROJECT_NAME" -f docker-compose.yml -f docker-compose.local-core.yml up -d --build --force-recreate local_ai_server ai_engine admin_ui)
}

wait_for_health() {
  local url="http://127.0.0.1:15000/health"
  info "Waiting for ai_engine health on $url"
  for _ in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      success "ai_engine health endpoint is up"
      return 0
    fi
    sleep 2
  done
  die "Timed out waiting for $url"
}

check_state() {
  info "Running verification checks"
  command -v docker >/dev/null 2>&1 || die "docker missing"
  compose_cmd >/dev/null 2>&1 || die "docker compose missing"
  command -v asterisk >/dev/null 2>&1 || die "asterisk missing"
  [[ -f "$ENV_FILE" ]] || die ".env missing"

  echo
  echo "IDENTITY"
  id "$OPERATOR_USER" 2>/dev/null || true
  echo
  echo "ASTERISK"
  asterisk -V
  asterisk -rx 'core show version' 2>&1 | sed -n '1,3p'
  echo
  echo "SOCKET"
  stat -c '%A %a %U %G %n' /run/asterisk /run/asterisk/asterisk.ctl /var/run/asterisk/asterisk.ctl 2>/dev/null || true
  echo
  echo "DIALPLAN"
  asterisk -rx 'dialplan show from-ai-agent' 2>&1 | sed -n '1,60p'
  echo
  echo "ARI USER"
  grep -n "\[${ASTERISK_ARI_USERNAME}\]\|password\|read_only" /etc/asterisk/ari_additional_custom.conf 2>/dev/null || true
  echo
  echo "HTTP"
  grep -n 'enabled\|bindaddr\|bindport' /etc/asterisk/http_custom.conf 2>/dev/null || true
  echo
  echo "HEALTH"
  curl -fsS http://127.0.0.1:15000/health 2>/dev/null | sed -n '1,40p' || true
}

main() {
  require_repo_files
  require_apt

  if $PRECHECK_ONLY; then
    check_state
    return 0
  fi

  install_packages
  ensure_services
  ensure_groups
  ensure_env_file
  configure_asterisk
  run_model_setup
  run_preflight
  start_stack
  wait_for_health
  check_state

  echo
  success "Barebones host bootstrap complete"
  info "Next steps:"
  info "  1. Log out/in once if '$OPERATOR_USER' was newly added to docker or asterisk groups"
  info "  2. Route a real call to from-ai-agent,s,1 (or via FreePBX Custom Destination)"
  info "  3. For FreePBX-managed routing, see docs/FreePBX-Integration-Guide.md"
}

main "$@"
