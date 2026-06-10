#!/usr/bin/env bash
# Bootstrap FreePBX 17 on an existing Ubuntu host Asterisk installation.
#
# Scope:
# - Ubuntu 24.04 / 22.04 style hosts with apt
# - existing host Asterisk runtime
# - manual FreePBX framework install (not Sangoma Debian all-in-one)
# - Apache/MariaDB/PHP 8.2/nodejs prerequisites
# - Apache runtime aligned to asterisk:asterisk
# - validated core modules installed for AAVA routing
#
# Non-goals:
# - does not automate the first web-admin account creation flow in the GUI
# - does not route calls into from-ai-agent for you; use the repo docs/host script after install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRECHECK_ONLY=false
PROVISION_AI_ROUTE=false
CHECK_AI_ROUTE=false
OPERATOR_USER="${SUDO_USER:-${USER:-root}}"
FREEPBX_VERSION="${FREEPBX_VERSION:-17.0}"
FREEPBX_TARBALL_URL="${FREEPBX_TARBALL_URL:-https://mirror.freepbx.org/modules/packages/freepbx/freepbx-17.0-latest.tgz}"
FREEPBX_SRC_BASE="${FREEPBX_SRC_BASE:-/usr/src}"
PHP_MINOR="${PHP_MINOR:-8.2}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"
ASTERISK_USER="${ASTERISK_USER:-asterisk}"
ASTERISK_GROUP="${ASTERISK_GROUP:-asterisk}"
ASTERISK_WEB_USER="${ASTERISK_WEB_USER:-asterisk}"
ASTERISK_WEB_GROUP="${ASTERISK_WEB_GROUP:-asterisk}"
AI_ROUTE_TARGET="${AI_ROUTE_TARGET:-from-ai-agent,s,1}"
AI_ROUTE_EXTENSION="${AI_ROUTE_EXTENSION:-7000}"
AI_ROUTE_DESCRIPTION="${AI_ROUTE_DESCRIPTION:-AI Agent Entry}"
AI_CUSTOM_DEST_DESCRIPTION="${AI_CUSTOM_DEST_DESCRIPTION:-AI Agent Entry}"
AI_ROUTE_NOTES="${AI_ROUTE_NOTES:-Provisioned by Asterisk AI Voice Agent installer}"
REQUIRED_MODULES=(framework core sipsettings voicemail dashboard calendar contactmanager certman pm2 userman customappsreg miscapps filestore backup)

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
Usage: scripts/install-freepbx-ubuntu-host.sh [options]

Bootstrap FreePBX 17 on an Ubuntu host that already runs Asterisk locally.

Options:
  --check                         Verify current host FreePBX/Asterisk state only
  --check-ai-route                Verify the FreePBX AI route objects plus compiled dialplan readback
  --provision-ai-route            Create/update a FreePBX Custom Destination + Misc Application
  --ai-route-target TARGET        Dialplan target for the route (default: from-ai-agent,s,1)
  --ai-route-extension EXT        Misc Application extension/feature code (default: 7000)
  --ai-route-description TEXT     Misc Application description (default: AI Agent Entry)
  --ai-custom-dest-description T  Custom Destination description (default: AI Agent Entry)
  --ai-route-notes TEXT           Notes stored on the Custom Destination
  --operator-user USER            Add this user to the asterisk group
  --db-root-pass PASS             MariaDB root password (omit for unix_socket root auth)
  --freepbx-url URL               Override framework tarball URL
  --php-minor VER                 PHP minor to target (default: 8.2)
  -h, --help                      Show this help

Examples:
  sudo scripts/install-freepbx-ubuntu-host.sh
  sudo scripts/install-freepbx-ubuntu-host.sh --operator-user claude
  sudo scripts/install-freepbx-ubuntu-host.sh --check
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      PRECHECK_ONLY=true
      shift
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
    --operator-user)
      OPERATOR_USER="$2"
      shift 2
      ;;
    --db-root-pass)
      DB_ROOT_PASS="$2"
      shift 2
      ;;
    --freepbx-url)
      FREEPBX_TARBALL_URL="$2"
      shift 2
      ;;
    --php-minor)
      PHP_MINOR="$2"
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
if [[ ${EUID} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    die "Run as root or install sudo"
  fi
fi

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

mysql_root() {
  if [[ -n "$DB_ROOT_PASS" ]]; then
    mysql -uroot "-p${DB_ROOT_PASS}" "$@"
  else
    mysql -uroot "$@"
  fi
}

replace_text() {
  local path="$1"
  local old="$2"
  local new="$3"
  python3 - "$path" "$old" "$new" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
old = sys.argv[2]
new = sys.argv[3]
text = path.read_text()
if old not in text:
    sys.exit(2)
path.write_text(text.replace(old, new, 1))
PY
}

set_ini_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  python3 - "$file" "$key" "$value" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
text = path.read_text() if path.exists() else ""
pattern = re.compile(rf'^(\s*{re.escape(key)}\s*=).*$' , re.MULTILINE)
if pattern.search(text):
    text = pattern.sub(rf'\1 {value}', text)
else:
    if text and not text.endswith('\n'):
        text += '\n'
    text += f'{key} = {value}\n'
path.write_text(text)
PY
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_ubuntu() {
  [[ -f /etc/os-release ]] || die "Missing /etc/os-release"
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This script is validated for Ubuntu hosts only"
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found"
}

ensure_sury_php_repo() {
  if apt-cache show "php${PHP_MINOR}" >/dev/null 2>&1; then
    return 0
  fi
  info "Adding Ondrej PHP repository for PHP ${PHP_MINOR}"
  apt_install software-properties-common ca-certificates apt-transport-https lsb-release gnupg2 curl
  $SUDO add-apt-repository -y ppa:ondrej/php
  $SUDO apt-get update
  apt-cache show "php${PHP_MINOR}" >/dev/null 2>&1 || die "PHP ${PHP_MINOR} packages still unavailable after adding repository"
}

install_host_packages() {
  info "Installing Apache, MariaDB, PHP ${PHP_MINOR}, and support packages"
  $SUDO apt-get update
  ensure_sury_php_repo
  apt_install \
    wget curl git unzip jq mariadb-server mariadb-client apache2 \
    nodejs npm \
    "php${PHP_MINOR}" "php${PHP_MINOR}-cli" "php${PHP_MINOR}-common" "php${PHP_MINOR}-mysql" \
    "php${PHP_MINOR}-curl" "php${PHP_MINOR}-mbstring" "php${PHP_MINOR}-xml" "php${PHP_MINOR}-zip" \
    "php${PHP_MINOR}-gd" "php${PHP_MINOR}-intl" "php${PHP_MINOR}-soap" "php${PHP_MINOR}-sqlite3" \
    "php${PHP_MINOR}-bcmath" "php${PHP_MINOR}-ldap" libapache2-mod-php"${PHP_MINOR}"
}

configure_php_alternatives() {
  info "Selecting PHP ${PHP_MINOR} for CLI and Apache"
  need_cmd update-alternatives
  update-alternatives --set php "/usr/bin/php${PHP_MINOR}"
  if [[ -x "/usr/sbin/a2dismod" ]]; then
    $SUDO a2dismod -q php8.3 >/dev/null 2>&1 || true
    $SUDO a2dismod -q php8.1 >/dev/null 2>&1 || true
    $SUDO a2enmod -q "php${PHP_MINOR}" >/dev/null 2>&1 || true
    $SUDO a2enmod -q rewrite >/dev/null 2>&1 || true
  fi
}

ensure_base_services() {
  info "Starting/enabling MariaDB and Apache"
  $SUDO systemctl enable --now mariadb
  $SUDO systemctl enable --now apache2
}

ensure_asterisk_identity() {
  getent passwd "$ASTERISK_USER" >/dev/null 2>&1 || die "Expected Asterisk user '$ASTERISK_USER' not found"
  getent group "$ASTERISK_GROUP" >/dev/null 2>&1 || die "Expected Asterisk group '$ASTERISK_GROUP' not found"
  if id "$OPERATOR_USER" >/dev/null 2>&1; then
    $SUDO usermod -aG "$ASTERISK_GROUP" "$OPERATOR_USER" || true
  else
    warn "Operator user '$OPERATOR_USER' not found; skipping group add"
  fi
}

ensure_apache_as_asterisk() {
  info "Running Apache workers as ${ASTERISK_WEB_USER}:${ASTERISK_WEB_GROUP}"
  local envvars=/etc/apache2/envvars
  python3 - "$envvars" "$ASTERISK_WEB_USER" "$ASTERISK_WEB_GROUP" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
user = sys.argv[2]
group = sys.argv[3]
text = path.read_text()
text = re.sub(r'^export APACHE_RUN_USER=.*$', f'export APACHE_RUN_USER={user}', text, flags=re.MULTILINE)
text = re.sub(r'^export APACHE_RUN_GROUP=.*$', f'export APACHE_RUN_GROUP={group}', text, flags=re.MULTILINE)
path.write_text(text)
PY
}

prepare_freepbx_dirs() {
  info "Preparing webroot and Asterisk-owned directories"
  $SUDO mkdir -p /var/www/html /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk /etc/asterisk
  $SUDO chown -R "$ASTERISK_USER:$ASTERISK_GROUP" /var/www/html /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk
  $SUDO chmod 775 /var/www/html /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk || true
}

ensure_mariadb_schema() {
  info "Ensuring FreePBX databases exist"
  mysql_root -e "CREATE DATABASE IF NOT EXISTS asterisk CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql_root -e "CREATE DATABASE IF NOT EXISTS asteriskcdrdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
}

download_freepbx_framework() {
  info "Downloading FreePBX framework"
  mkdir -p "$FREEPBX_SRC_BASE"
  local tgz="$FREEPBX_SRC_BASE/freepbx-${FREEPBX_VERSION}-latest.tgz"
  curl -fsSL "$FREEPBX_TARBALL_URL" -o "$tgz"
  local srcdir
  srcdir="$(mktemp -d "$FREEPBX_SRC_BASE/freepbx-src.XXXXXX")"
  tar -xzf "$tgz" -C "$srcdir"
  echo "$srcdir/freepbx"
}

install_freepbx_framework() {
  local srcdir="$1"
  info "Installing FreePBX framework from $srcdir"
  (
    cd "$srcdir"
    php install -n --rootdb --dbuser=root --webroot=/var/www/html --user="$ASTERISK_USER" --group="$ASTERISK_GROUP"
  )
}

normalize_freepbx_permissions() {
  info "Normalizing FreePBX ownership and config readability"
  $SUDO chown -R "$ASTERISK_USER:$ASTERISK_GROUP" /var/www/html/admin /etc/freepbx.conf /etc/amportal.conf
  $SUDO chmod 640 /etc/freepbx.conf /etc/amportal.conf
  $SUDO chmod -R g+rX /var/www/html/admin
}

install_validated_modules() {
  info "Installing validated FreePBX modules"
  fwconsole ma refreshsignatures || true
  fwconsole ma downloadinstall "${REQUIRED_MODULES[@]}"
  fwconsole chown
  fwconsole reload
}

configure_socket_permissions() {
  info "Aligning Asterisk control socket ownership/perms"
  local conf=/etc/asterisk/asterisk.conf
  [[ -f "$conf" ]] || return 0
  set_ini_value "$conf" astctlpermissions 0660
  set_ini_value "$conf" astctlowner "$ASTERISK_USER"
  set_ini_value "$conf" astctlgroup "$ASTERISK_GROUP"
  $SUDO systemctl restart asterisk || true
}

restart_services() {
  info "Restarting Apache after ownership/runtime changes"
  $SUDO systemctl restart apache2
}

provision_ai_route() {
  info "Provisioning FreePBX Custom Destination + Misc Application for ${AI_ROUTE_TARGET}"
  local helper="$REPO_DIR/scripts/provision-freepbx-ai-route.php"
  [[ -f "$helper" ]] || die "Missing helper: $helper"
  php "$helper" \
    --target "$AI_ROUTE_TARGET" \
    --route-extension "$AI_ROUTE_EXTENSION" \
    --route-description "$AI_ROUTE_DESCRIPTION" \
    --custom-dest-description "$AI_CUSTOM_DEST_DESCRIPTION" \
    --notes "$AI_ROUTE_NOTES"
  fwconsole reload
}

verify_ai_route() {
  info "Verifying FreePBX AI route objects and compiled dialplan"
  local helper="$REPO_DIR/scripts/provision-freepbx-ai-route.php"
  [[ -f "$helper" ]] || die "Missing helper: $helper"
  php "$helper" \
    --check \
    --target "$AI_ROUTE_TARGET" \
    --route-extension "$AI_ROUTE_EXTENSION" \
    --route-description "$AI_ROUTE_DESCRIPTION" \
    --custom-dest-description "$AI_CUSTOM_DEST_DESCRIPTION"

  local ai_context ai_exten ai_priority route_out entry_out
  IFS=',' read -r ai_context ai_exten ai_priority <<< "$AI_ROUTE_TARGET"
  [[ -n "$ai_context" && -n "$ai_exten" && -n "$ai_priority" ]] || die "Invalid AI route target: $AI_ROUTE_TARGET"

  route_out="$(asterisk -rx "dialplan show ${AI_ROUTE_EXTENSION}@app-miscapps" 2>&1)"
  entry_out="$(asterisk -rx "dialplan show ${ai_exten}@${ai_context}" 2>&1)"

  echo
  echo "AI ROUTE DIALPLAN"
  printf '%s\n' "$route_out" | sed -n '1,80p'
  echo
  echo "AI ENTRY DIALPLAN"
  printf '%s\n' "$entry_out" | sed -n '1,80p'

  grep -q "Goto(customdests,dest-" <<< "$route_out" || die "Misc Application ${AI_ROUTE_EXTENSION} does not route into customdests"
  grep -q "Stasis(asterisk-ai-voice-agent)" <<< "$entry_out" || die "AI entry target ${ai_exten}@${ai_context} does not reach Stasis(asterisk-ai-voice-agent)"
}

check_state() {
  echo "OS"
  . /etc/os-release
  echo "$PRETTY_NAME"
  echo
  echo "PHP"
  php -v | sed -n '1,3p' || true
  update-alternatives --query php 2>/dev/null | sed -n '1,20p' || true
  echo
  echo "APACHE"
  sed -n '1,40p' /etc/apache2/envvars 2>/dev/null | grep -E 'APACHE_RUN_USER|APACHE_RUN_GROUP' || true
  ps -eo user,group,comm | grep '[a]pache2' | sed -n '1,10p' || true
  echo
  echo "FREEPBX"
  command -v fwconsole || true
  fwconsole -V 2>/dev/null | sed -n '1,3p' || true
  ls -ld /var/www/html/admin /etc/freepbx.conf /etc/amportal.conf 2>/dev/null || true
  echo
  echo "FREEPBX CONFIG"
  grep -n 'AMPASTERISKWEBUSER\|AMPWEBROOT\|ASTETCDIR' /etc/amportal.conf 2>/dev/null | sed -n '1,20p' || true
  echo
  echo "MODULES"
  fwconsole ma listonline 2>/dev/null | egrep 'framework|core|sipsettings|voicemail|dashboard|calendar|contactmanager|certman|pm2|userman|customappsreg|miscapps' | sed -n '1,40p' || true
  echo
  echo "HTTP"
  curl -I -s http://127.0.0.1/admin/ | sed -n '1,20p' || true
  echo
  echo "ASTERISK SOCKET"
  stat -c '%A %a %U %G %n' /run/asterisk /run/asterisk/asterisk.ctl /var/run/asterisk/asterisk.ctl 2>/dev/null || true
  echo
  echo "ASTERISK CLI"
  asterisk -rx 'core show version' 2>&1 | sed -n '1,3p' || true
}

main() {
  require_ubuntu
  need_cmd python3
  need_cmd curl

  if $PRECHECK_ONLY; then
    check_state
    if $CHECK_AI_ROUTE; then
      verify_ai_route
    fi
    exit 0
  fi

  install_host_packages
  configure_php_alternatives
  ensure_base_services
  ensure_asterisk_identity
  ensure_apache_as_asterisk
  prepare_freepbx_dirs
  ensure_mariadb_schema
  local srcdir
  srcdir="$(download_freepbx_framework)"
  install_freepbx_framework "$srcdir"
  normalize_freepbx_permissions
  configure_socket_permissions
  restart_services
  install_validated_modules
  if $PROVISION_AI_ROUTE; then
    provision_ai_route
  fi
  restart_services
  check_state
  if $PROVISION_AI_ROUTE || $CHECK_AI_ROUTE; then
    verify_ai_route
  fi

  echo
  success "FreePBX Ubuntu host bootstrap complete"
  info "Next steps:"
  info "  1. Open http://HOST/admin and complete the first-run admin account wizard if prompted"
  if $PROVISION_AI_ROUTE; then
    info "  2. FreePBX AI route was provisioned at extension ${AI_ROUTE_EXTENSION} -> ${AI_ROUTE_TARGET}"
    info "  3. The compiled route was also verified from the Asterisk CLI"
  elif $CHECK_AI_ROUTE; then
    info "  2. The existing FreePBX AI route was verified at extension ${AI_ROUTE_EXTENSION} -> ${AI_ROUTE_TARGET}"
    info "  3. Log out/in once if '$OPERATOR_USER' was newly added to the asterisk group"
  else
    info "  2. Create a Custom Destination to from-ai-agent,s,1 and expose it via Misc Applications"
    info "  3. Log out/in once if '$OPERATOR_USER' was newly added to the asterisk group"
  fi
}

main "$@"
