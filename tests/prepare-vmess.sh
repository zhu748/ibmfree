#!/usr/bin/env bash

# Render production templates and the exported link without installing services.
set -Eeuo pipefail
umask 077
readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly FIXTURE_ROOT="$(cd -- "${1:?fixture directory required}" && pwd)"

sed -e 's/\r$//' \
  -e 's|^readonly CONFIG_DIR=.*|readonly CONFIG_DIR="${FIXTURE_ROOT}/config"|' \
  -e 's|^readonly SITE_ROOT=.*|readonly SITE_ROOT="${FIXTURE_ROOT}/site"|' \
  -e 's|^readonly BACKUP_ROOT=.*|readonly BACKUP_ROOT="${FIXTURE_ROOT}/backups"|' \
  -e 's|^readonly INSTALL_LOCK_PATH=.*|readonly INSTALL_LOCK_PATH="${FIXTURE_ROOT}/install.lock"|' \
  -e 's|^readonly NGINX_CONFIG=.*|readonly NGINX_CONFIG="${FIXTURE_ROOT}/nginx.conf"|' \
  -e 's|^readonly SYSTEMD_DIR=.*|readonly SYSTEMD_DIR="${FIXTURE_ROOT}/units"|' \
  -e 's|^readonly SING_BOX_BIN=.*|readonly SING_BOX_BIN="${FIXTURE_ROOT}/edge-router"|' \
  -e 's|^readonly CLOUDFLARED_INSTALL_PATH=.*|readonly CLOUDFLARED_INSTALL_PATH="${FIXTURE_ROOT}/cloudflared"|' \
  -e 's|^readonly TEMPLATE_DIR=.*|readonly TEMPLATE_DIR="${REPO_ROOT}/templates"|' \
  "${REPO_ROOT}/install.sh" >"${FIXTURE_ROOT}/installer.sh"
source "${FIXTURE_ROOT}/installer.sh"

systemctl() { die 'test fixture must not manage system services'; }
download_file() { die 'test fixture must not download files'; }
install() {
  [[ $# == 8 && $1 == -o && $2 == root && $3 == -g && $4 == root && $5 == -m &&
    $6 == 0600 && $7 == /dev/stdin && $8 == "${CONFIG_DIR}/.edge-stage."*/payload ]] || die 'unexpected fixture install'
  command install -m 0600 /dev/stdin "$8"
}

CUSTOM_UUID=11111111-1111-4111-8111-111111111111
PUBLIC_DOMAIN=edge.example.com
WS_PATH="/$(random_hex 12)/$(random_hex 16)"
SING_BOX_PORT=${2:?core port required}
ORIGIN_PORT=${3:?origin port required}
validate_port "$SING_BOX_PORT" && validate_port "$ORIGIN_PORT" || die 'invalid fixture port'
[[ $SING_BOX_PORT != "$ORIGIN_PORT" ]] || die 'fixture ports must differ'
mkdir -p "$CONFIG_DIR" "${CONFIG_DIR}/tls" "$SITE_ROOT"
printf '<html>VMess loopback fixture</html>\n' >"${SITE_ROOT}/index.html"
render_file "${TEMPLATE_DIR}/sing-box.json.tpl" "$CONFIG_PATH"
render_file "${TEMPLATE_DIR}/nginx-tunnel.conf.tpl" "${FIXTURE_ROOT}/tunnel.tpl.conf"
render_file "${TEMPLATE_DIR}/nginx-direct.conf.tpl" "${FIXTURE_ROOT}/direct.tpl.conf"
write_client_link
ROLLBACK_ACTIVE=false

# Use the installer's pinned version and architecture hash, not a separate pin.
read -r arch expected_hash < <(detect_arch)
printf '%s %s %s\n' "$SING_BOX_VERSION" "$arch" "$expected_hash"
