#!/usr/bin/env bash
# All-in-one Ubuntu host bootstrap for:
# - host Asterisk + local-core AAVA services
# - manual FreePBX 17 framework install on the same host
#
# This wrapper intentionally reuses the repo's validated component installers
# instead of duplicating their logic. It is the single entrypoint to run when
# an operator wants "host Asterisk + AAVA + FreePBX" on an Ubuntu machine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRECHECK_ONLY=false
SKIP_AAVA=false
SKIP_FREEPBX=false
SKIP_MODELS=false
SKIP_STACK=false
PROVISION_AI_ROUTE=false
CHECK_AI_ROUTE=false
OPERATOR_USER="${SUDO_USER:-${USER:-root}}"
ARI_USER="${ASTERISK_ARI_USERNAME:-aava}"
ARI_PASSWORD="${ASTERISK_ARI_PASSWORD:-AAVAchangeMeNow123!}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"
PHP_MINOR="${PHP_MINOR:-8.2}"
FREEPBX_URL="${FREEPBX_TARBALL_URL:-https://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz}"
AI_ROUTE_TARGET="${AI_ROUTE_TARGET:-from-ai-agent,s,1}"
AI_ROUTE_EXTENSION="${AI_ROUTE_EXTENSION:-7000}"
AI_ROUTE_DESCRIPTION="${AI_ROUTE_DESCRIPTION:-AI Agent Entry}"
AI_CUSTOM_DEST_DESCRIPTION="${AI_CUSTOM_DEST_DESCRIPTION:-AI Agent Entry}"
AI_ROUTE_NOTES="${AI_ROUTE_NOTES:-Provisioned by Asterisk AI Voice Agent installer}"

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
Usage: scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh [options]

Single entrypoint for an Ubuntu host that should run:
- host Asterisk
- local-core AAVA services
- manual FreePBX 17 framework install on top of host Asterisk

Options:
  --check                 Run verification mode only (no changes)
  --operator-user USER    Add this user to docker + asterisk groups
  --ari-user USER         ARI username for host Asterisk bootstrap
  --ari-password PASS     ARI password for host Asterisk bootstrap
  --db-root-pass PASS     MariaDB root password for FreePBX bootstrap
  --php-minor VER         PHP minor version for FreePBX bootstrap (default: 8.2)
  --freepbx-url URL       Override FreePBX framework tarball URL
  --check-ai-route        Verify the FreePBX AI route objects plus compiled dialplan readback
  --provision-ai-route    Create/update the FreePBX Custom Destination + Misc Application
  --ai-route-target TGT   Dialplan target for the FreePBX route (default: from-ai-agent,s,1)
  --ai-route-extension E  Misc Application extension/feature code (default: 7000)
  --ai-route-description  Misc Application description (default: AI Agent Entry)
  --ai-custom-dest-description TEXT  Custom Destination description (default: AI Agent Entry)
  --ai-route-notes TEXT   Notes stored on the Custom Destination
  --skip-models           Skip `make model-setup` during AAVA bootstrap
  --skip-stack            Skip `docker compose up` during AAVA bootstrap
  --skip-aava             Run only the FreePBX half
  --skip-freepbx          Run only the host-Asterisk/AAVA half
  -h, --help              Show this help

Examples:
  sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh --operator-user "$USER"
  sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh --check
  sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh --skip-freepbx
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      PRECHECK_ONLY=true
      shift
      ;;
    --operator-user)
      OPERATOR_USER="$2"
      shift 2
      ;;
    --ari-user)
      ARI_USER="$2"
      shift 2
      ;;
    --ari-password)
      ARI_PASSWORD="$2"
      shift 2
      ;;
    --db-root-pass)
      DB_ROOT_PASS="$2"
      shift 2
      ;;
    --php-minor)
      PHP_MINOR="$2"
      shift 2
      ;;
    --freepbx-url)
      FREEPBX_URL="$2"
      shift 2
      ;;
    --check-ai-route)
      CHECK_AI_ROUTE=true
      shift
      ;;
    --provision-ai-route)
      PROVISION_AI_ROUTE=true
      shift
      ;;
    --ai-route-target)
      AI_ROUTE_TARGET="$2"
      shift 2
      ;;
    --ai-route-extension)
      AI_ROUTE_EXTENSION="$2"
      shift 2
      ;;
    --ai-route-description)
      AI_ROUTE_DESCRIPTION="$2"
      shift 2
      ;;
    --ai-custom-dest-description)
      AI_CUSTOM_DEST_DESCRIPTION="$2"
      shift 2
      ;;
    --ai-route-notes)
      AI_ROUTE_NOTES="$2"
      shift 2
      ;;
    --skip-models)
      SKIP_MODELS=true
      shift
      ;;
    --skip-stack)
      SKIP_STACK=true
      shift
      ;;
    --skip-aava)
      SKIP_AAVA=true
      shift
      ;;
    --skip-freepbx)
      SKIP_FREEPBX=true
      shift
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

require_repo() {
  [[ -f "$REPO_DIR/scripts/install-barebones-server.sh" ]] || die "Missing scripts/install-barebones-server.sh"
  [[ -f "$REPO_DIR/scripts/install-freepbx-ubuntu-host.sh" ]] || die "Missing scripts/install-freepbx-ubuntu-host.sh"
  [[ -f /etc/os-release ]] || die "Missing /etc/os-release"
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This wrapper is validated for Ubuntu hosts only"
}

run_checked() {
  local label="$1"
  shift
  info "$label"
  "$@"
}

run_aava() {
  local -a args=(--operator-user "$OPERATOR_USER" --ari-user "$ARI_USER" --ari-password "$ARI_PASSWORD")
  $SKIP_MODELS && args+=(--skip-models)
  $SKIP_STACK && args+=(--skip-stack)
  $PRECHECK_ONLY && args=(--check)
  run_checked "Running host Asterisk + local-core AAVA installer" "$REPO_DIR/scripts/install-barebones-server.sh" "${args[@]}"
}

run_freepbx() {
  local -a args=(--operator-user "$OPERATOR_USER" --php-minor "$PHP_MINOR" --freepbx-url "$FREEPBX_URL")
  [[ -n "$DB_ROOT_PASS" ]] && args+=(--db-root-pass "$DB_ROOT_PASS")
  $PRECHECK_ONLY && args+=(--check)
  if $CHECK_AI_ROUTE; then
    args+=(--check-ai-route)
  fi
  if $PROVISION_AI_ROUTE; then
    args+=(
      --provision-ai-route
      --ai-route-target "$AI_ROUTE_TARGET"
      --ai-route-extension "$AI_ROUTE_EXTENSION"
      --ai-route-description "$AI_ROUTE_DESCRIPTION"
      --ai-custom-dest-description "$AI_CUSTOM_DEST_DESCRIPTION"
      --ai-route-notes "$AI_ROUTE_NOTES"
    )
  fi
  run_checked "Running Ubuntu FreePBX bootstrap" "$REPO_DIR/scripts/install-freepbx-ubuntu-host.sh" "${args[@]}"
}

print_next_steps() {
  cat <<EOF

Next steps after the installer finishes:

1. Open FreePBX at:
   http://YOUR-HOST/admin

2. If the FreePBX first-run admin wizard appears, complete it.
EOF

  if $PROVISION_AI_ROUTE; then
    cat <<EOF

3. The FreePBX AI route was provisioned automatically:
   - Misc Application extension: ${AI_ROUTE_EXTENSION}
   - Dialplan target: ${AI_ROUTE_TARGET}
EOF
  elif $CHECK_AI_ROUTE; then
    cat <<EOF

3. The existing FreePBX AI route was verified automatically:
   - Misc Application extension: ${AI_ROUTE_EXTENSION}
   - Dialplan target: ${AI_ROUTE_TARGET}
EOF
  else
    cat <<'EOF'

3. In FreePBX, create the PBX-facing AI route:
   - Custom Destination -> from-ai-agent,s,1
   - Misc Application (or another GUI-managed route) -> that Custom Destination

   Or have the installer do it for you next time:
   sudo scripts/install-ubuntu-host-aava-freepbx-all-in-one.sh \
     --operator-user "$USER" \
     --provision-ai-route
EOF
  fi

  cat <<'EOF'

4. Verify the compiled route from the Asterisk CLI:
   asterisk -rx 'dialplan show from-ai-agent'
   asterisk -rx 'dialplan show 7000@app-miscapps'

5. For full end-to-end PBX proof, register a softphone and call the FreePBX route.

Docs:
- docs/UBUNTU_HOST_AIO_INSTALL.md
- docs/FREEPBX_UBUNTU_HOST_BOOTSTRAP.md
- docs/freepbx/FreePBX-Ubuntu-Host-Validation.md
EOF
}

main() {
  require_repo

  if ! $SKIP_AAVA; then
    run_aava
  else
    warn "Skipping host Asterisk + AAVA bootstrap by request"
  fi

  if ! $SKIP_FREEPBX; then
    run_freepbx
  else
    warn "Skipping FreePBX bootstrap by request"
  fi

  if $PRECHECK_ONLY; then
    success "All-in-one verification complete"
  else
    success "All-in-one Ubuntu host bootstrap complete"
    print_next_steps
  fi
}

main "$@"
