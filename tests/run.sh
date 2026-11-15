#!/usr/bin/env bash

set -Eeuo pipefail
readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SELF="${REPO_ROOT}/tests/run.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [[ $1 == "$2" ]] || fail "expected [$2], got [$1]"; }

load_installer() {
  # Redirect every managed path in a private test copy, never the host's /etc.
  sed -e 's/\r$//' \
    -e 's|^readonly CONFIG_DIR=.*|readonly CONFIG_DIR="${TEST_ROOT}/config"|' \
    -e 's|^readonly SITE_ROOT=.*|readonly SITE_ROOT="${TEST_ROOT}/site"|' \
    -e 's|^readonly BACKUP_ROOT=.*|readonly BACKUP_ROOT="${TEST_ROOT}/backups"|' \
    -e 's|^readonly INSTALL_LOCK_PATH=.*|readonly INSTALL_LOCK_PATH="${TEST_ROOT}/install.lock"|' \
    -e 's|^readonly NGINX_CONFIG=.*|readonly NGINX_CONFIG="${TEST_ROOT}/nginx.conf"|' \
    -e 's|^readonly SYSTEMD_DIR=.*|readonly SYSTEMD_DIR="${TEST_ROOT}/units"|' \
    -e 's|^readonly SING_BOX_BIN=.*|readonly SING_BOX_BIN="${TEST_ROOT}/edge-router"|' \
    -e 's|^readonly MANAGER_DIR=.*|readonly MANAGER_DIR="${TEST_ROOT}/manager"|' \
    -e 's|^readonly COMMAND_PATH=.*|readonly COMMAND_PATH="${TEST_ROOT}/bin/fczd"|' \
    -e 's|^readonly CLOUDFLARED_INSTALL_PATH=.*|readonly CLOUDFLARED_INSTALL_PATH="${TEST_ROOT}/cloudflared"|' \
    -e 's|^readonly TEMPLATE_DIR=.*|readonly TEMPLATE_DIR="${REPO_ROOT}/templates"|' \
    "${REPO_ROOT}/install.sh" >"${TEST_ROOT}/install.sh"
  source "${TEST_ROOT}/install.sh"
  trap - ERR EXIT
  assert_equal "$CONFIG_DIR" "${TEST_ROOT}/config"
  mkdir -p "$CONFIG_DIR" "${TEST_ROOT}/work"
  TEMP_DIR="${TEST_ROOT}/work"
  PUBLIC_DOMAIN=edge.example.com
  DEPLOY_MODE=tunnel
  PROXY_MODE=vmess-ws
  CUSTOM_UUID=""
  WS_PATH=""
  ORIGIN_PORT=8001
  SING_BOX_PORT=""
  SITE_INDEX_FILE=""
  CLOUDFLARED_BIN=""
  TUNNEL_TOKEN_FILE="${TEST_ROOT}/input.token"
  printf 'test-only-token' >"$TUNNEL_TOKEN_FILE"

  generate_uuid() { printf '11111111-1111-4111-8111-111111111111'; }
  if [[ ${2-} != test_choose_port_* ]]; then
    choose_internal_port() { printf '23456'; }
  fi
  ss() { fail 'unexpected host socket inspection'; }
  systemctl() { fail 'unexpected systemctl call'; }
  install() { fail 'unexpected host installation'; }
  download_file() { fail 'unexpected network download'; }
  sleep() { :; }
}

write_existing_config() {
  printf '%s\n' '{"inbounds":[{"listen_port":24567,"users":[{"uuid":"22222222-2222-4222-8222-222222222222"}],"transport":{"type":"ws","path":"/existing/0123456789abcdef"}}]}' >"$CONFIG_PATH"
}

test_first_install() {
  collect_configuration <<<''
  assert_equal "$CUSTOM_UUID" 11111111-1111-4111-8111-111111111111
  assert_equal "$SING_BOX_PORT" 23456
  assert_equal "$ORIGIN_PORT" 8001
  validate_ws_path "$WS_PATH"
  [[ -z "$CLOUDFLARED_BIN" ]] || fail 'configuration installed cloudflared'
}

test_repeat_install() {
  write_existing_config
  collect_configuration <<<''
  assert_equal "$CUSTOM_UUID" 22222222-2222-4222-8222-222222222222
  assert_equal "$WS_PATH" /existing/0123456789abcdef
  assert_equal "$SING_BOX_PORT" 24567
}

test_explicit_values() {
  write_existing_config
  CUSTOM_UUID=33333333-3333-4333-8333-333333333333
  WS_PATH=/custom/0123456789abcdef
  SING_BOX_PORT=25000
  collect_configuration </dev/null
  assert_equal "$CUSTOM_UUID" 33333333-3333-4333-8333-333333333333
  assert_equal "$WS_PATH" /custom/0123456789abcdef
  assert_equal "$SING_BOX_PORT" 25000
}

test_invalid_config() {
  printf '{}' >"$CONFIG_PATH"
  if (collect_configuration </dev/null) >"${TEST_ROOT}/error" 2>&1; then
    fail 'invalid existing config was accepted'
  fi
  assert_equal "$(<"$CONFIG_PATH")" '{}'
}

test_empty_config() {
  : >"$CONFIG_PATH"
  if (collect_configuration </dev/null) >"${TEST_ROOT}/error" 2>&1; then
    fail 'empty existing config was accepted'
  fi
  [[ -f $CONFIG_PATH ]] || fail 'empty existing config was removed'
}

test_ambiguous_config() {
  write_existing_config
  printf '\n"uuid": "33333333-3333-4333-8333-333333333333"\n' >>"$CONFIG_PATH"
  if (collect_configuration </dev/null) >"${TEST_ROOT}/error" 2>&1; then
    fail 'ambiguous credentials were accepted'
  fi
}

test_three_inputs() {
  PUBLIC_DOMAIN=""
  TUNNEL_TOKEN_FILE=""
  collect_configuration <<<'11111111-1111-4111-8111-111111111111
edge.example.com
test-only-token'
  assert_equal "$PUBLIC_DOMAIN" edge.example.com
  assert_equal "$(<"$TUNNEL_TOKEN_FILE")" test-only-token
  assert_equal "$DEPLOY_MODE" tunnel
  assert_equal "$CLOUDFLARED_BIN" ''
}

test_port_validation() {
  for port in 1024 8001 65535 08001; do validate_port "$port"; done
  for port in 0 1023 65536 -1 99999999999999999999999999999 x ''; do
    if validate_port "$port"; then fail 'invalid port accepted'; fi
  done
  CUSTOM_UUID=11111111-1111-4111-8111-111111111111
  ORIGIN_PORT=08001
  SING_BOX_PORT=02345
  collect_configuration </dev/null
  assert_equal "$ORIGIN_PORT" 8001
  assert_equal "$SING_BOX_PORT" 2345
}

test_same_port() {
  CUSTOM_UUID=11111111-1111-4111-8111-111111111111
  ORIGIN_PORT=8001
  SING_BOX_PORT=08001
  if (collect_configuration </dev/null) >"${TEST_ROOT}/error" 2>&1; then
    fail 'numerically identical ports accepted'
  fi
}

test_systemd_available() {
  systemctl() {
    assert_equal "$*" 'show --property=Version --value'
    printf '255.4-1ubuntu8.11\n'
  }
  preflight_environment
}

test_systemd_unavailable() {
  systemctl() { return 1; }
  if (preflight_environment) >"${TEST_ROOT}/error" 2>&1; then
    fail 'unreachable systemd manager accepted'
  fi
  grep -q '无法连接 systemd' "${TEST_ROOT}/error"
  systemctl() { :; }
  if (preflight_environment) >"${TEST_ROOT}/error" 2>&1; then
    fail 'empty systemd manager property accepted'
  fi
  grep -q '无法读取 systemd' "${TEST_ROOT}/error"
}

test_install_lock_failure() {
  flock() { assert_equal "$1" --nonblock; return 1; }
  if (acquire_install_lock) >"${TEST_ROOT}/error" 2>&1; then
    fail 'failed installation lock accepted'
  fi
  grep -q '无法取得安装锁' "${TEST_ROOT}/error"
}

test_install_lock_real() {
  if [[ $(uname -s) != Linux ]]; then
    printf 'SKIP: real flock semantics require Linux (covered by CI)\n'
    return 77
  fi
  acquire_install_lock
  local first_fd=$INSTALL_LOCK_FD
  acquire_install_lock
  assert_equal "$INSTALL_LOCK_FD" "$first_fd"
  if (
    exec {INSTALL_LOCK_FD}>&-
    acquire_install_lock
  ) >"${TEST_ROOT}/error" 2>&1; then
    fail 'second installer acquired a held lock'
  fi
  grep -q '无法取得安装锁' "${TEST_ROOT}/error"
  exec {INSTALL_LOCK_FD}>&-
  acquire_install_lock
  exec {INSTALL_LOCK_FD}>&-
  [[ -f $INSTALL_LOCK_PATH ]] || fail 'lock inode removed on release'
  mv "$INSTALL_LOCK_PATH" "${TEST_ROOT}/other.lock"
  ln -s "${TEST_ROOT}/other.lock" "$INSTALL_LOCK_PATH"
  if (acquire_install_lock) >"${TEST_ROOT}/error" 2>&1; then
    fail 'symbolic link accepted as installation lock'
  fi
  grep -q '安装锁不能是符号链接' "${TEST_ROOT}/error"
}

mock_listeners() {
  ss() {
    assert_equal "$1 $2" '-H -lntp'
    assert_equal "$3" 'sport = :8001'
    printf '%s' "${MOCK_LISTENERS:-}"
    return "${MOCK_SS_STATUS:-0}"
  }
  systemctl() {
    assert_equal "$*" 'show nginx --property=MainPID --value'
    printf '%s' "${MOCK_MAIN_PID:-123}"
    return "${MOCK_SYSTEMCTL_STATUS:-0}"
  }
}

test_port_preflight_free() {
  mock_listeners
  systemctl() { fail 'unused port queried a service PID'; }
  assert_port_compatible 8001 nginx
}

test_port_preflight_owned() {
  mock_listeners
  MOCK_LISTENERS='LISTEN 0 511 127.0.0.1:8001 0.0.0.0:* users:(("nginx",pid=124,fd=8),("nginx",pid=123,fd=8))'
  assert_port_compatible 8001 nginx
  MOCK_LISTENERS+=$'\nLISTEN 0 511 [::1]:8001 [::]:* users:(("nginx",pid=123,fd=9))'
  assert_port_compatible 8001 nginx
}

test_port_preflight_conflicts() {
  mock_listeners
  local listener
  for listener in \
    'LISTEN 0 511 127.0.0.1:8001 0.0.0.0:* users:(("nginx",pid=1234,fd=8))' \
    'LISTEN 0 511 127.0.0.1:8001 0.0.0.0:*' \
    $'LISTEN 0 511 127.0.0.1:8001 0.0.0.0:* users:(("nginx",pid=123,fd=8))\nLISTEN 0 511 [::1]:8001 [::]:* users:(("other",pid=789,fd=9))'; do
    MOCK_LISTENERS=$listener
    if (assert_port_compatible 8001 nginx) >"${TEST_ROOT}/error" 2>&1; then
      fail 'foreign or unidentified listener accepted'
    fi
    grep -q '不属于 nginx' "${TEST_ROOT}/error"
  done
}

test_port_preflight_errors() {
  mock_listeners
  MOCK_SS_STATUS=1
  if (assert_port_compatible 8001 nginx) >"${TEST_ROOT}/error" 2>&1; then
    fail 'failed socket inspection treated as free port'
  fi
  grep -q '无法检查 TCP 8001' "${TEST_ROOT}/error"
  MOCK_SS_STATUS=0
  MOCK_LISTENERS='LISTEN 0 511 127.0.0.1:8001 0.0.0.0:* users:(("other",pid=123,fd=8))'
  MOCK_SYSTEMCTL_STATUS=1
  if (assert_port_compatible 8001 nginx) >"${TEST_ROOT}/error" 2>&1; then
    fail 'failed service inspection accepted'
  fi
  grep -q '无法确认是否属于 nginx' "${TEST_ROOT}/error"
  MOCK_SYSTEMCTL_STATUS=0
  for MOCK_MAIN_PID in 0 unknown; do
    if (assert_port_compatible 8001 nginx) >"${TEST_ROOT}/error" 2>&1; then
      fail 'invalid service PID accepted'
    fi
    grep -q '已被其他进程占用' "${TEST_ROOT}/error"
  done
}

test_port_preflight_modes() {
  SING_BOX_PORT=23456
  assert_port_compatible() { printf '%s %s\n' "$1" "$2" >>"${TEST_ROOT}/ports"; }
  preflight_ports
  assert_equal "$(<"${TEST_ROOT}/ports")" $'23456 edge-router\n8001 nginx'
  : >"${TEST_ROOT}/ports"
  DEPLOY_MODE=direct
  preflight_ports
  assert_equal "$(<"${TEST_ROOT}/ports")" $'23456 edge-router\n443 nginx'
}

test_choose_port_free() {
  ss() { assert_equal "$*" '-H -lnt'; }
  local selected
  selected=$(choose_internal_port)
  validate_port "$selected"
  ((selected >= 20000 && selected < 40000))
  [[ $selected != "$ORIGIN_PORT" ]]
}

test_choose_port_failure() {
  ss() { return 1; }
  if (choose_internal_port) >"${TEST_ROOT}/error" 2>&1; then
    fail 'random port chosen after socket inspection failure'
  fi
  grep -q '无法读取 TCP 监听状态' "${TEST_ROOT}/error"
}

test_choose_port_exhausted() {
  ss() {
    local port
    for ((port = 20000; port < 40000; port++)); do
      printf 'LISTEN 0 511 127.0.0.1:%s 0.0.0.0:*\n' "$port"
    done
  }
  if (choose_internal_port) >"${TEST_ROOT}/error" 2>&1; then
    fail 'occupied port chosen after retry limit'
  fi
  grep -q '无法选择空闲的内部端口' "${TEST_ROOT}/error"
}

test_large_cloudflared_help() {
  CLOUDFLARED_BIN="${TEST_ROOT}/cloudflared"
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ $* == "tunnel --no-autoupdate --metrics 127.0.0.1:0 run --help" ]] || exit 2' \
    "printf '%s\n' '--token-file'" \
    "printf '%200000s\n' x" >"$CLOUDFLARED_BIN"
  chmod 0755 "$CLOUDFLARED_BIN"
  ensure_cloudflared
}

test_broken_cloudflared() {
  CLOUDFLARED_BIN="${TEST_ROOT}/cloudflared"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' '--token-file'" 'exit 1' >"$CLOUDFLARED_BIN"
  chmod 0755 "$CLOUDFLARED_BIN"
  if (ensure_cloudflared) >"${TEST_ROOT}/error" 2>&1; then
    fail 'failed executable was accepted'
  fi
}

test_cloudflared_arch_dispatch() {
  local mock="${TEST_ROOT}/cloudflared"
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ $* == "tunnel --no-autoupdate --metrics 127.0.0.1:0 run --help" ]] || exit 2' \
    "printf '%s\n' '--token-file'" >"$mock"
  chmod 0755 "$mock"
  command() { if [[ $1 == -v && $2 == cloudflared ]]; then return 1; fi; builtin command "$@"; }
  install_cloudflared_s390x() { CLOUDFLARED_BIN="$mock"; printf 's390x\n' >>"${TEST_ROOT}/dispatch"; }
  install_cloudflared_official() { CLOUDFLARED_BIN="$mock"; printf 'official\n' >>"${TEST_ROOT}/dispatch"; }
  uname() { printf x86_64; }
  CLOUDFLARED_BIN=""
  ensure_cloudflared
  uname() { printf aarch64; }
  CLOUDFLARED_BIN=""
  ensure_cloudflared
  uname() { printf s390x; }
  CLOUDFLARED_BIN=""
  ensure_cloudflared
  assert_equal "$(<"${TEST_ROOT}/dispatch")" $'official\nofficial\ns390x'
  uname() { printf riscv64; }
  CLOUDFLARED_BIN=""
  if (ensure_cloudflared) >"${TEST_ROOT}/error" 2>&1; then
    fail 'unknown architecture accepted'
  fi
  grep -q 'CLOUDFLARED_BIN' "${TEST_ROOT}/error"
}

test_cloudflared_official_install() {
  local case_arch asset expected_hash captured_url
  for case_arch in x86_64 aarch64; do
    uname() { printf "$case_arch"; }
    read -r asset expected_hash _ < <(detect_cloudflared_arch)
    captured_url=""
    download_file() { captured_url=$1; printf binary >"$2"; }
    sha256_file() { printf '%s' "$expected_hash"; }
    mock_file_install
    install_cloudflared_official
    [[ $captured_url == "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${asset}" ]] ||
      fail 'unexpected official cloudflared download URL'
    [[ -x $CLOUDFLARED_INSTALL_PATH ]] || fail 'official cloudflared not installed'
    assert_equal "$CLOUDFLARED_BIN" "$CLOUDFLARED_INSTALL_PATH"
    CLOUDFLARED_BIN=""
  done
  assert_no_file_stages
}

test_cloudflared_checksum_failure() {
  uname() { printf x86_64; }
  download_file() { printf corrupt >"$2"; }
  if (install_cloudflared_official) >"${TEST_ROOT}/error" 2>&1; then
    fail 'bad official cloudflared checksum accepted'
  fi
  grep -q SHA-256 "${TEST_ROOT}/error"
  [[ ! -e $CLOUDFLARED_INSTALL_PATH ]] || fail 'unverified binary installed'
}

test_tunnel_metrics_private() {
  CLOUDFLARED_BIN=/usr/local/bin/cloudflared
  render_file "${TEMPLATE_DIR}/edge-tunnel.service.tpl" "${TEST_ROOT}/tunnel.service"
  grep -Fqx -- "ExecStart=${CLOUDFLARED_BIN} tunnel --no-autoupdate --metrics 127.0.0.1:0 run --token-file ${TOKEN_PATH}" \
    "${TEST_ROOT}/tunnel.service"
  if grep -q 'test-only-token' "${TEST_ROOT}/tunnel.service"; then fail 'service contains token contents'; fi
}

test_tunnel_core_independent() {
  render_file "${TEMPLATE_DIR}/edge-tunnel.service.tpl" "${TEST_ROOT}/tunnel.service"
  grep -Fqx 'Wants=network-online.target edge-router.service' "${TEST_ROOT}/tunnel.service"
  grep -Fqx 'Requires=nginx.service' "${TEST_ROOT}/tunnel.service"
  grep -Fqx 'After=network-online.target nginx.service edge-router.service' "${TEST_ROOT}/tunnel.service"
  if grep -Eq '^(Requires|Requisite|BindsTo|PartOf)=.*edge-router' "${TEST_ROOT}/tunnel.service"; then
    fail 'core shutdown can stop the static-site tunnel'
  fi
}

mock_listener_audit() {
  ss() {
    assert_equal "$*" '-H -lntp'
    printf '%s' "${MOCK_LISTENERS:-}"
    return "${MOCK_SS_STATUS:-0}"
  }
  systemctl() {
    assert_equal "$1" show
    assert_equal "$3 $4" '--property=MainPID --value'
    case "$2" in
      edge-router) printf 100 ;;
      nginx) printf 200 ;;
      edge-tunnel) printf 300 ;;
      *) fail 'unrelated service queried' ;;
    esac
  }
}

test_listener_audit_loopback() {
  mock_listener_audit
  MOCK_LISTENERS=$'LISTEN 0 511 127.0.0.1:23456 0.0.0.0:* users:(("core",pid=100,fd=8))\nLISTEN 0 511 127.0.0.1:8001 0.0.0.0:* users:(("nginx",pid=200,fd=9))\nLISTEN 0 511 [::1]:20241 [::]:* users:(("connector",pid=300,fd=10))\nLISTEN 0 511 127.0.0.2:20242 0.0.0.0:* users:(("connector",pid=300,fd=11))\nLISTEN 0 511 [::ffff:127.0.0.1]:20243 [::]:* users:(("connector",pid=300,fd=12))'
  warn_extra_tcp_listeners 2>"${TEST_ROOT}/warnings"
  [[ ! -s ${TEST_ROOT}/warnings ]] || fail 'loopback listener reported as external'
}

test_listener_audit_exposure() {
  mock_listener_audit
  MOCK_LISTENERS=$'LISTEN 0 511 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=200,fd=9))\nLISTEN 0 511 [::]:20241 [::]:* users:(("connector",pid=300,fd=10))\nLISTEN 0 511 192.0.2.1:23456 0.0.0.0:* users:(("core",pid=100,fd=8))'
  warn_extra_tcp_listeners 2>"${TEST_ROOT}/warnings"
  for address in '0.0.0.0:80' '[::]:20241' '192.0.2.1:23456'; do
    grep -Fq -- "$address" "${TEST_ROOT}/warnings"
  done
  assert_equal "$(wc -l <"${TEST_ROOT}/warnings" | tr -d ' ')" 3
  grep -q '安装器未关闭该入口' "${TEST_ROOT}/warnings"
}

test_listener_audit_direct() {
  mock_listener_audit
  DEPLOY_MODE=direct
  MOCK_LISTENERS=$'LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:(("nginx",pid=200,fd=8))\nLISTEN 0 511 [::]:443 [::]:* users:(("nginx",pid=200,fd=9))\nLISTEN 0 511 *:80 *:* users:(("nginx",pid=200,fd=10))\nLISTEN 0 511 127.0.0.1:23456 0.0.0.0:* users:(("core",pid=100,fd=8))'
  warn_extra_tcp_listeners 2>"${TEST_ROOT}/warnings"
  grep -Fq '*:80' "${TEST_ROOT}/warnings"
  if grep -q ':443' "${TEST_ROOT}/warnings"; then fail 'expected Direct TLS port reported'; fi
  assert_equal "$(wc -l <"${TEST_ROOT}/warnings" | tr -d ' ')" 1
}

test_listener_audit_unrelated() {
  mock_listener_audit
  MOCK_LISTENERS=$'LISTEN 0 511 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=999,fd=8))\nLISTEN 0 511 0.0.0.0:8080 0.0.0.0:* users:(("other",pid=1000,fd=8))'
  warn_extra_tcp_listeners 2>"${TEST_ROOT}/warnings"
  if grep -q '额外非回环' "${TEST_ROOT}/warnings"; then fail 'unrelated process or PID prefix matched'; fi
  assert_equal "$(wc -l <"${TEST_ROOT}/warnings" | tr -d ' ')" 3
  grep -q '无法确认其绑定范围' "${TEST_ROOT}/warnings"
}

test_listener_audit_unavailable() {
  mock_listener_audit
  MOCK_SS_STATUS=1
  warn_extra_tcp_listeners 2>"${TEST_ROOT}/warnings"
  grep -q '无法检查额外 TCP 监听' "${TEST_ROOT}/warnings"
  MOCK_SS_STATUS=0
  systemctl() { return 1; }
  warn_extra_tcp_listeners 2>"${TEST_ROOT}/warnings"
  assert_equal "$(wc -l <"${TEST_ROOT}/warnings" | tr -d ' ')" 3
  grep -q '未完成该服务的额外监听检查' "${TEST_ROOT}/warnings"
}

mock_http() {
  curl() {
    assert_equal "$1" --disable
    [[ " $* " == *" --noproxy * "* ]] || fail 'local request can use a proxy'
    [[ " $* " == *' --http1.1 '* ]] || fail 'HTTP/1.1 not forced'
    local headers=""
    while (($#)); do
      if [[ $1 == --dump-header ]]; then headers=$2; shift; fi
      shift
    done
    if [[ -z $headers ]]; then
      printf '%s' "${MOCK_HTTP_STATUS:-200}"
    else
      printf 'HTTP/1.1 %s Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: %s\r\n\r\n' \
        "${MOCK_WS_STATUS:-101}" "${MOCK_ACCEPT:-s3pPLMBiTxaQ9kYGzzhZRbK+xOo=}" >"$headers"
      return "${MOCK_CURL_STATUS:-28}"
    fi
  }
  WS_PATH=/existing/0123456789abcdef
}

test_websocket_upgrade() {
  mock_http
  check_local_site
  DEPLOY_MODE=direct
  check_local_site
}

test_http_only_fails() {
  mock_http
  MOCK_WS_STATUS=502
  if (check_local_site) >"${TEST_ROOT}/error" 2>&1; then fail 'homepage alone passed'; fi
}

test_forged_accept_fails() {
  mock_http
  MOCK_ACCEPT=wrong
  if (check_local_site) >"${TEST_ROOT}/error" 2>&1; then fail 'invalid accept passed'; fi
}

test_curl_failure_fails() {
  mock_http
  MOCK_CURL_STATUS=7
  if (check_local_site) >"${TEST_ROOT}/error" 2>&1; then fail 'connection failure passed'; fi
}

test_backup_once() {
  local file="${TEST_ROOT}/original"
  printf original >"$file"
  backup_file "$file"
  printf modified >"$file"
  backup_file "$file"
  assert_equal "${#ROLLBACK_TARGETS[@]}" 1
  assert_equal "$(<"${ROLLBACK_BACKUPS[0]}")" original
  [[ ${ROLLBACK_BACKUPS[0]} == "$BACKUP_ROOT"/* ]] || fail 'backup outside private directory'
  grep -Fq -- "$file" "${BACKUP_DIR}/paths.tsv"
  [[ -z $(find "$TEST_ROOT" -maxdepth 1 -name '*.bak*' -print) ]] || fail 'backup left beside original'
}

test_site_preserved() {
  mkdir -p "$SITE_ROOT"
  printf '<html>user-owned site</html>' >"${SITE_ROOT}/index.html"
  render_site "${TEST_ROOT}/rendered.html"
  assert_equal "$(<"${TEST_ROOT}/rendered.html")" '<html>user-owned site</html>'
  SITE_INDEX_FILE="${TEST_ROOT}/custom.html"
  printf '<html>replacement site</html>' >"$SITE_INDEX_FILE"
  render_site "${TEST_ROOT}/rendered.html"
  assert_equal "$(<"${TEST_ROOT}/rendered.html")" '<html>replacement site</html>'
}

test_site_no_deployment_marker() {
  render_site "${TEST_ROOT}/rendered.html"
  if grep -qE -- '--site-key|\{\{SITE_' "${TEST_ROOT}/rendered.html"; then
    fail 'public deployment marker left in page'
  fi
}

test_site_backup_private() {
  mkdir -p "$SITE_ROOT"
  printf old >"${SITE_ROOT}/index.html"
  backup_file "${SITE_ROOT}/index.html"
  assert_equal "$(<"${ROLLBACK_BACKUPS[0]}")" old
  assert_equal "$(find "$SITE_ROOT" -type f | wc -l | tr -d ' ')" 1
  if [[ $(uname -s) == Linux ]]; then
    assert_equal "$(stat -c '%a' "$BACKUP_ROOT")" 700
    assert_equal "$(stat -c '%a' "$BACKUP_DIR")" 700
  fi
}

test_missing_backup() {
  local file="${TEST_ROOT}/original"
  printf current >"$file"
  ROLLBACK_TARGETS=("$file")
  ROLLBACK_BACKUPS=("${TEST_ROOT}/missing")
  ROLLBACK_ACTIVE=true
  systemctl() { :; }
  restore_service_state() { :; }
  if rollback_installation; then fail 'missing backup was reported as restored'; fi
  assert_equal "$(<"$file")" current
}

assert_no_file_stages() {
  [[ -z $(find "$TEST_ROOT" -name '.edge-stage.*' -print) ]] || fail 'private staging directory left behind'
}

mock_file_install() {
  install() {
    if [[ $# -ge 8 && $1 == -d && $2 == -o && $4 == -g && $6 == -m ]]; then
      local mode=$7 directory
      shift 7
      for directory in "$@"; do
        [[ $directory == "${TEST_ROOT}" || $directory == "${TEST_ROOT}/"* ]] ||
          fail 'unexpected directory installation'
      done
      command mkdir -p -m "$mode" -- "$@"
      return
    fi
    [[ $# == 8 && $1 == -o && $3 == -g && $5 == -m &&
      $8 == "${TEST_ROOT}/"* && $8 == */.edge-stage.*/payload ]] || fail 'unexpected file installation'
    if [[ $(uname -s) == Linux ]]; then
      assert_equal "$(stat -c '%a' "${8%/*}")" 700
    fi
    command install -m "$6" -- "$7" "$8"
  }
}

test_atomic_install() {
  local source="${TEST_ROOT}/source" file="${TEST_ROOT}/live"
  printf complete >"$source"
  printf original >"$file"
  mock_file_install
  mv() {
    assert_equal "$(<"$file")" original
    assert_equal "$(<"$4")" complete
    assert_equal "$5" "$file"
    if [[ $(uname -s) == Linux ]]; then assert_equal "$(stat -c '%a' "$4")" 640; fi
    command mv "$@"
  }
  install_managed_file root root 0640 "$source" "$file"
  assert_equal "$(<"$file")" complete
  assert_no_file_stages
}

test_atomic_install_copy_failure() {
  local source="${TEST_ROOT}/source" file="${TEST_ROOT}/live"
  printf complete >"$source"
  printf original >"$file"
  install() { printf partial >"${@: -1}"; return 1; }
  if install_managed_file root root 0644 "$source" "$file"; then fail 'partial copy accepted'; fi
  assert_equal "$(<"$file")" original
  if install_managed_file root root 0644 "$source" "${TEST_ROOT}/new"; then fail 'partial new file accepted'; fi
  [[ ! -e ${TEST_ROOT}/new ]] || fail 'partial new file published'
  assert_no_file_stages
}

test_atomic_install_rename_failure() {
  local source="${TEST_ROOT}/source" file="${TEST_ROOT}/live"
  printf complete >"$source"
  printf original >"$file"
  mock_file_install
  mv() { return 1; }
  if install_managed_file root root 0644 "$source" "$file"; then fail 'failed rename accepted'; fi
  assert_equal "$(<"$file")" original
  assert_no_file_stages
}

test_atomic_install_stage_failure() {
  local file="${TEST_ROOT}/live"
  printf original >"$file"
  mktemp() { return 1; }
  if install_managed_file root root 0644 "$file" "$file"; then fail 'failed staging allocation accepted'; fi
  assert_equal "$(<"$file")" original
  assert_no_file_stages
}

test_atomic_install_same_file() {
  local file="${TEST_ROOT}/live"
  printf original >"$file"
  mock_file_install
  install_managed_file root root 0600 "$file" "$file"
  assert_equal "$(<"$file")" original
  if [[ $(uname -s) == Linux ]]; then assert_equal "$(stat -c '%a' "$file")" 600; fi
  assert_no_file_stages
}

test_atomic_install_signals() {
  local file="${TEST_ROOT}/live" signal expected status
  printf original >"$file"
  install() { printf partial >"${@: -1}"; kill -"$signal" "$BASHPID"; fail 'signal ignored'; }
  for signal in INT TERM; do
    status=0
    expected=130
    [[ $signal != TERM ]] || expected=143
    install_managed_file root root 0644 "$file" "$file" || status=$?
    assert_equal "$status" "$expected"
    assert_equal "$(<"$file")" original
    assert_no_file_stages
  done
}

test_managed_directory_rejected() {
  mkdir "${TEST_ROOT}/directory"
  printf retained >"${TEST_ROOT}/directory/content"
  if (backup_file "${TEST_ROOT}/directory") >"${TEST_ROOT}/error" 2>&1; then
    fail 'managed directory accepted as a file'
  fi
  grep -q '托管文件路径不是普通文件' "${TEST_ROOT}/error"
  if install_managed_file root root 0644 /dev/null "${TEST_ROOT}/directory"; then
    fail 'directory accepted as atomic destination'
  fi
  assert_equal "$(<"${TEST_ROOT}/directory/content")" retained
  assert_no_file_stages
}

test_atomic_install_symlink() {
  if [[ $(uname -s) != Linux ]]; then
    printf 'SKIP: native symlink semantics require Linux (covered by CI)\n'
    return 77
  fi
  local file="${TEST_ROOT}/live" outside="${TEST_ROOT}/outside" source="${TEST_ROOT}/source"
  printf external >"$outside"
  printf complete >"$source"
  ln -s "$outside" "$file"
  backup_file "$file"
  mock_file_install
  install_managed_file root root 0644 "$source" "$file"
  [[ ! -L $file ]] || fail 'new file still follows old target symlink'
  assert_equal "$(<"$outside")" external
  assert_equal "$(<"$file")" complete
  restore_backup_file "${ROLLBACK_BACKUPS[0]}" "$file"
  [[ -L $file ]] || fail 'original symlink not restored'
  assert_equal "$(readlink "$file")" "$outside"
  assert_equal "$(<"$outside")" external
  assert_no_file_stages
}

test_atomic_install_running_binary() {
  if [[ $(uname -s) != Linux ]]; then
    printf 'SKIP: live executable replacement requires Linux (covered by CI)\n'
    return 77
  fi
  local file="${TEST_ROOT}/live" pid attempt
  cp "$(type -P sleep)" "$file"
  "$file" 30 &
  pid=$!
  trap "kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true" EXIT
  for attempt in {1..20}; do
    [[ /proc/${pid}/exe -ef $file ]] && break
    command sleep 0.05
  done
  [[ /proc/${pid}/exe -ef $file ]] || fail 'fixture executable did not start'
  mock_file_install
  install_managed_file root root 0755 "$(type -P true)" "$file"
  kill -0 "$pid" || fail 'updating executable stopped existing process'
  "$file"
  assert_no_file_stages
}

test_atomic_restore_copy_failure() {
  local file="${TEST_ROOT}/original"
  printf original >"$file"
  backup_file "$file"
  printf modified >"$file"
  cp() { return 1; }
  if restore_backup_file "${ROLLBACK_BACKUPS[0]}" "$file"; then
    fail 'failed backup copy was accepted'
  fi
  assert_equal "$(<"$file")" modified
  assert_equal "$(<"${ROLLBACK_BACKUPS[0]}")" original
  assert_no_file_stages
}

test_atomic_restore_rename_failure() {
  local file="${TEST_ROOT}/live"
  printf original >"$file"
  backup_file "$file"
  printf modified >"$file"
  mv() { return 1; }
  if restore_backup_file "${ROLLBACK_BACKUPS[0]}" "$file"; then fail 'failed restore rename accepted'; fi
  assert_equal "$(<"$file")" modified
  assert_equal "$(<"${ROLLBACK_BACKUPS[0]}")" original
  assert_no_file_stages
}

test_atomic_restore_signal() {
  local file="${TEST_ROOT}/live" status=0
  printf original >"$file"
  backup_file "$file"
  printf modified >"$file"
  cp() { printf partial >"${@: -1}"; kill -TERM "$BASHPID"; fail 'signal ignored'; }
  restore_backup_file "${ROLLBACK_BACKUPS[0]}" "$file" || status=$?
  assert_equal "$status" 143
  assert_equal "$(<"$file")" modified
  assert_equal "$(<"${ROLLBACK_BACKUPS[0]}")" original
  assert_no_file_stages
}

test_rollback_restores_files() {
  local file="${TEST_ROOT}/original" created="${TEST_ROOT}/created"
  printf original >"$file"
  backup_file "$file"
  backup_file "$created"
  printf modified >"$file"
  printf new >"$created"
  systemctl() { :; }
  restore_service_state() { :; }
  rollback_installation
  assert_equal "$(<"$file")" original
  [[ ! -e $created ]] || fail 'new file left after rollback'
  assert_equal "$(<"${ROLLBACK_BACKUPS[0]}")" original
}

test_exit_rolls_back() {
  local file="${TEST_ROOT}/original" status=0
  printf original >"$file"
  (
    trap on_exit EXIT
    systemctl() { :; }
    restore_service_state() { :; }
    backup_file "$file"
    printf modified >"$file"
    exit 42
  ) >"${TEST_ROOT}/exit.log" 2>&1 || status=$?
  assert_equal "$status" 42
  assert_equal "$(<"$file")" original
}

test_signal_rolls_back() {
  local file="${TEST_ROOT}/original" status=0
  printf original >"$file"
  (
    trap on_exit EXIT
    trap 'exit 143' TERM
    systemctl() { :; }
    restore_service_state() { :; }
    backup_file "$file"
    printf modified >"$file"
    kill -TERM "$BASHPID"
    fail 'termination signal ignored'
  ) >"${TEST_ROOT}/signal.log" 2>&1 || status=$?
  assert_equal "$status" 143
  assert_equal "$(<"$file")" original
}

test_committed_exit_preserves_files() {
  local file="${TEST_ROOT}/original" status=0
  printf original >"$file"
  (
    trap on_exit EXIT
    backup_file "$file"
    printf installed >"$file"
    ROLLBACK_ACTIVE=false
    exit 0
  ) >"${TEST_ROOT}/exit.log" 2>&1 || status=$?
  assert_equal "$status" 0
  assert_equal "$(<"$file")" installed
}

test_render_config() {
  collect_configuration <<<''
  render_file "${TEMPLATE_DIR}/sing-box.json.tpl" "${TEST_ROOT}/rendered.json"
  render_file "${TEMPLATE_DIR}/nginx-tunnel.conf.tpl" "${TEST_ROOT}/rendered.conf"
  grep -q 'listen 127.0.0.1:8001' "${TEST_ROOT}/rendered.conf"
  if grep -q '{{' "${TEST_ROOT}/rendered.json"; then fail 'unrendered template'; fi
  node -e 'const fs=require("fs"),assert=require("assert/strict"); const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); assert.equal(c.inbounds[0].type,"vmess"); assert.equal(c.inbounds[0].listen,"127.0.0.1"); assert.equal(c.inbounds[0].transport.type,"ws");' "${TEST_ROOT}/rendered.json"
}

test_client_link() {
  collect_configuration <<<''
  mock_file_install
  write_client_link
  node -e 'const fs=require("fs"),assert=require("assert/strict"); const link=fs.readFileSync(process.argv[1],"utf8").trim(); assert.ok(link.startsWith("vmess://")); const c=JSON.parse(Buffer.from(link.slice(8),"base64").toString("utf8")); assert.equal(c.id,"11111111-1111-4111-8111-111111111111"); assert.equal(c.add,"edge.example.com"); assert.equal(c.path,Buffer.from(process.argv[2],"base64").toString("utf8")); assert.equal(c.net,"ws"); assert.equal(c.tls,"tls"); assert.equal(c.port,"443"); assert.ok(!JSON.stringify(c).includes("test-only-token"));' "$CLIENT_PATH" "$(printf '%s' "$WS_PATH" | base64 | tr -d '\r\n')"
}

test_vmess_fixture() {
  mkdir "${TEST_ROOT}/fixture"
  local metadata
  metadata=$(bash "${REPO_ROOT}/tests/prepare-vmess.sh" "${TEST_ROOT}/fixture" 23456 23457)
  [[ $metadata =~ ^[0-9]+\.[0-9]+\.[0-9]+\ (amd64|arm64|s390x)\ [a-f0-9]{64}$ ]] || fail 'invalid release fixture metadata'
  node -e 'const fs=require("fs"),path=require("path"),assert=require("assert/strict"); const root=process.argv[1]; const c=JSON.parse(fs.readFileSync(path.join(root,"config/config.json"),"utf8")); const uri=fs.readFileSync(path.join(root,"config/client.txt"),"utf8").trim(); assert.ok(uri.startsWith("vmess://")); const v=JSON.parse(Buffer.from(uri.slice(8),"base64").toString("utf8")); assert.equal(v.id,c.inbounds[0].users[0].uuid); assert.equal(v.path,c.inbounds[0].transport.path); assert.equal(c.inbounds[0].listen_port,23456); assert.equal(v.net,"ws"); assert.equal(v.tls,"tls"); for (const mode of ["tunnel","direct"]) { const n=fs.readFileSync(path.join(root,mode+".tpl.conf"),"utf8"); assert.ok(n.includes(v.path)); assert.ok(n.includes("127.0.0.1:23456")); assert.ok(!n.includes("{{")); }' "${TEST_ROOT}/fixture"
}

test_profile_selection() {
  local choice expected
  for choice in 1 2 3; do
    PROXY_MODE=""
    collect_configuration <<<"$choice"
    case $choice in
      1) expected=vmess-ws ;; 2) expected=vless-xhttp ;; 3) expected=vless-xhttp-encryption ;;
    esac
    assert_equal "$PROXY_MODE" "$expected"
  done
  PROXY_MODE=invalid
  if (collect_configuration </dev/null) >"${TEST_ROOT}/error" 2>&1; then fail 'invalid profile accepted'; fi
}

set_fixture_keys() {
  VLESS_DECRYPTION="mlkem768x25519plus.native.600s.$(printf 'a%.0s' {1..43})"
  VLESS_ENCRYPTION="mlkem768x25519plus.native.0rtt.$(printf 'b%.0s' {1..43})"
}

test_vless_reinstall_and_switch() {
  PROXY_MODE=vless-xhttp-encryption
  collect_configuration </dev/null
  set_fixture_keys
  render_core_configuration "$CONFIG_PATH"
  printf '{"decryption":"%s","encryption":"%s"}\n' "$VLESS_DECRYPTION" "$VLESS_ENCRYPTION" >"$ENCRYPTION_PATH"
  local old_uuid=$CUSTOM_UUID old_path=$WS_PATH old_port=$SING_BOX_PORT old_key=$VLESS_DECRYPTION
  PROXY_MODE="" CUSTOM_UUID="" WS_PATH="" SING_BOX_PORT=""
  collect_configuration </dev/null
  assert_equal "$PROXY_MODE" vless-xhttp-encryption
  assert_equal "$CUSTOM_UUID" "$old_uuid"
  assert_equal "$WS_PATH" "$old_path"
  assert_equal "$SING_BOX_PORT" "$old_port"
  assert_equal "$VLESS_DECRYPTION" "$old_key"
  PROXY_MODE=vmess-ws
  collect_configuration </dev/null
  render_core_configuration "$CONFIG_PATH"
  PROXY_MODE=vless-xhttp-encryption
  collect_configuration </dev/null
  assert_equal "$VLESS_DECRYPTION" "$old_key"
}

test_vless_missing_or_mismatched_keys() {
  PROXY_MODE=vless-xhttp-encryption
  collect_configuration </dev/null
  set_fixture_keys
  render_core_configuration "$CONFIG_PATH"
  if (collect_configuration </dev/null) >"${TEST_ROOT}/error" 2>&1; then fail 'missing existing keys silently rotated'; fi
  printf '{}' >"$ENCRYPTION_PATH"
  if (collect_configuration </dev/null) >"${TEST_ROOT}/error" 2>&1; then fail 'invalid key file accepted'; fi
  printf '{"decryption":"mlkem768x25519plus.native.600s.%s","encryption":"%s"}\n' \
    "$(printf 'c%.0s' {1..43})" "$VLESS_ENCRYPTION" >"$ENCRYPTION_PATH"
  if (collect_configuration </dev/null) >"${TEST_ROOT}/error" 2>&1; then fail 'mismatched keys accepted'; fi
}

test_xray_checksum_failure() {
  download_file() { printf corrupt >"$2"; }
  if (install_xray) >"${TEST_ROOT}/error" 2>&1; then fail 'bad Xray checksum accepted'; fi
  grep -q SHA-256 "${TEST_ROOT}/error"
  [[ ! -e $SING_BOX_BIN ]] || fail 'unverified binary installed'
}

test_vless_output_contract() {
  local profile
  for profile in vless-xhttp vless-xhttp-encryption; do
    PROXY_MODE=$profile
    collect_configuration </dev/null
    if [[ $profile == vless-xhttp-encryption ]]; then set_fixture_keys; fi
    render_core_configuration "${TEST_ROOT}/rendered.json"
    render_file "${TEMPLATE_DIR}/edge-router.service.tpl" "${TEST_ROOT}/edge.service"
    grep -Fq "run -config ${CONFIG_PATH}" "${TEST_ROOT}/edge.service"
    render_file "${TEMPLATE_DIR}/nginx-tunnel.conf.tpl" "${TEST_ROOT}/rendered.conf"
    grep -Fq "location ^~ ${WS_PATH}/" "${TEST_ROOT}/rendered.conf"
    grep -q 'proxy_request_buffering off' "${TEST_ROOT}/rendered.conf"
    mock_file_install
    write_client_link
    node - "$CLIENT_PATH" "${TEST_ROOT}/rendered.json" "$profile" <<'NODE'
const fs = require('node:fs'), assert = require('node:assert/strict');
const [linkFile, configFile, profile] = process.argv.slice(2);
const uri = fs.readFileSync(linkFile, 'utf8').trim(), link = new URL(uri);
const config = JSON.parse(fs.readFileSync(configFile, 'utf8')), inbound = config.inbounds[0];
assert.equal(link.protocol, 'vless:'); assert.equal(link.port, '443');
assert.equal(link.hostname, 'edge.example.com'); assert.equal(link.username, inbound.settings.clients[0].id);
assert.equal(link.searchParams.get('path'), inbound.streamSettings.xhttpSettings.path);
assert.equal(link.searchParams.get('type'), 'xhttp'); assert.equal(link.searchParams.get('mode'), 'packet-up');
assert.equal(link.searchParams.get('security'), 'tls'); assert.equal(inbound.listen, '127.0.0.1');
assert.equal(inbound.protocol, 'vless'); assert.equal(inbound.streamSettings.security, 'none');
assert.equal(link.searchParams.has('flow'), false);
const encrypted = profile.endsWith('-encryption');
assert.equal(inbound.settings.decryption !== 'none', encrypted);
assert.equal(link.searchParams.get('encryption') !== 'none', encrypted);
assert.ok(!uri.includes('test-only-token'));
if (encrypted) assert.ok(!uri.includes(inbound.settings.decryption.split('.').at(-1)), 'private key leaked');
NODE
  done
}

test_xhttp_health_requires_core() {
  PROXY_MODE=vless-xhttp
  collect_configuration </dev/null
  local_http_request() { [[ $1 == / ]] && printf 200 || printf 404; }
  if (check_local_site) >"${TEST_ROOT}/error" 2>&1; then fail 'static site alone passed XHTTP health'; fi
  local_http_request() {
    if [[ $1 != / ]]; then
      [[ $1 == "$WS_PATH/"*/0 && $* == *'--request POST --data-binary'* ]] || fail 'not a packet-up probe'
    fi
    printf 200
  }
  check_local_site
}

test_management_bundle() {
  collect_configuration </dev/null
  mock_file_install
  install_management
  [[ -s ${MANAGER_DIR}/install.sh && -s ${MANAGER_DIR}/templates/xray.json.tpl && -x $COMMAND_PATH ]]
  ! grep -q '{{' "$COMMAND_PATH" || fail 'unrendered manager entry'
  env TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" "$COMMAND_PATH" help >"${TEST_ROOT}/help"
  grep -q 'uninstall' "${TEST_ROOT}/help"
  check_manager_destination
}

test_management_conflicts() {
  mkdir -p "${COMMAND_PATH%/*}"
  printf 'other-program\n' >"$COMMAND_PATH"
  if (check_manager_destination) >"${TEST_ROOT}/error" 2>&1; then fail 'unrelated fczd command overwritten'; fi
  assert_equal "$(<"$COMMAND_PATH")" other-program
  rm "$COMMAND_PATH"
  mkdir "$MANAGER_DIR"
  if (check_manager_destination) >"${TEST_ROOT}/error" 2>&1; then fail 'unrelated manager directory accepted'; fi
}

test_management_bundle_rollback() {
  cat >"${TEST_ROOT}/management-worker.sh" <<'WORKER'
source "${TEST_ROOT}/install.sh"
TEMP_DIR="${TEST_ROOT}/work"
install() {
  if [[ $1 == -d ]]; then
    shift 7
    command mkdir -p -- "$@"
  else
    command install -m "$6" -- "$7" "$8"
  fi
}
restore_service_state() { :; }
install_management
exit 42
WORKER
  local status=0
  env TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" bash "${TEST_ROOT}/management-worker.sh" >"${TEST_ROOT}/worker.log" 2>&1 || status=$?
  assert_equal "$status" 42
  [[ ! -e $COMMAND_PATH && ! -e $MANAGER_DIR ]] || fail 'failed install left an unusable manager directory'
  check_manager_destination
}

prepare_management_fixture() {
  PROXY_MODE=vless-xhttp-encryption
  collect_configuration </dev/null
  set_fixture_keys
  render_core_configuration "$CONFIG_PATH"
  render_file "${TEMPLATE_DIR}/nginx-tunnel.conf.tpl" "$NGINX_CONFIG"
  printf '{"deploy_mode":"tunnel","public_domain":"edge.example.com","origin_port":8001}\n' >"$STATE_PATH"
  printf '#!/usr/bin/env bash\nprintf "Xray fixture version\\n"\n' >"$SING_BOX_BIN"
  chmod 0755 "$SING_BOX_BIN"
  printf 'secret-client-link' >"$CLIENT_PATH"
  printf 'secret-token' >"$TOKEN_PATH"
}

test_management_list_private() {
  prepare_management_fixture
  systemctl() { printf inactive; return 3; }
  list_installed >"${TEST_ROOT}/listing"
  grep -Eq '^  vless-xhttp-encryption[[:space:]]+已安装$' "${TEST_ROOT}/listing"
  assert_equal "$(grep -c '已安装$' "${TEST_ROOT}/listing")" 1
  ! grep -Fq "$CUSTOM_UUID" "${TEST_ROOT}/listing" || fail 'UUID in list'
  ! grep -Fq "$WS_PATH" "${TEST_ROOT}/listing" || fail 'secret path in list'
  ! grep -Eq 'secret-client|secret-token|mlkem768' "${TEST_ROOT}/listing" || fail 'credentials in list'
}

test_management_legacy_configuration() {
  local profile
  for profile in vmess-ws vless-xhttp vless-xhttp-encryption; do
    PROXY_MODE=$profile
    collect_configuration </dev/null
    if [[ $profile == vless-xhttp-encryption ]]; then set_fixture_keys; fi
    render_core_configuration "$CONFIG_PATH"
    render_file "${TEMPLATE_DIR}/nginx-tunnel.conf.tpl" "$NGINX_CONFIG"
    PUBLIC_DOMAIN="" WS_PATH="" SING_BOX_PORT=""
    load_management_configuration
    assert_equal "$PROXY_MODE" "$profile"
    assert_equal "$PUBLIC_DOMAIN" edge.example.com
    assert_equal "$ORIGIN_PORT" 8001
  done
}

test_management_install_reuses_token() {
  prepare_management_fixture
  TUNNEL_TOKEN_FILE=""
  preflight_environment() { :; }
  acquire_install_lock() { :; }
  main() {
    assert_equal "$PROXY_MODE" 2
    assert_equal "$PUBLIC_DOMAIN" edge.example.com
    assert_equal "$TUNNEL_TOKEN_FILE" "$TOKEN_PATH"
    assert_equal "$WS_PATH" "$(read_json_string "$CONFIG_PATH" path)"
  }
  manage_install 2
}

test_management_service_scope() {
  prepare_management_fixture
  preflight_environment() { :; }
  acquire_install_lock() { :; }
  check_local_site() { :; }
  check_core_configuration() { :; }
  nginx() { :; }
  systemctl() {
    printf '%s\n' "$*" >>"${TEST_ROOT}/service-calls"
    if [[ $1 == is-active && $* != 'is-active --quiet nginx' ]]; then return 3; fi
  }
  manage_services restart
  grep -qx 'restart edge-router' "${TEST_ROOT}/service-calls"
  grep -qx 'restart edge-tunnel' "${TEST_ROOT}/service-calls"
  grep -qx 'reload nginx' "${TEST_ROOT}/service-calls"
  : >"${TEST_ROOT}/service-calls"
  manage_services stop
  grep -qx 'stop edge-router' "${TEST_ROOT}/service-calls"
  grep -qx 'stop edge-tunnel' "${TEST_ROOT}/service-calls"
  ! grep -Eq 'stop nginx|disable' "${TEST_ROOT}/service-calls" || fail 'shared nginx/boot settings changed by stop'
}

test_management_menu_dispatch() {
  bash() {
    assert_equal "$1" "${SCRIPT_DIR}/install.sh"
    assert_equal "$2" --manage
    assert_equal "$3" list
    printf called >"${TEST_ROOT}/menu-called"
    return 1
  }
  manager_menu <<<'2
0'
  [[ -f ${TEST_ROOT}/menu-called ]] || fail 'menu did not dispatch'
  manager_menu </dev/null
}

test_management_site() {
  prepare_management_fixture
  mkdir -p "$SITE_ROOT"
  printf original >"${SITE_ROOT}/index.html"
  printf '<h1>My real site</h1>' >"${TEST_ROOT}/custom.html"
  preflight_environment() { :; }
  acquire_install_lock() { :; }
  capture_service_state() { :; }
  mock_file_install
  manage_site "${TEST_ROOT}/custom.html"
  assert_equal "$(<"${SITE_ROOT}/index.html")" '<h1>My real site</h1>'
  [[ $ROLLBACK_ACTIVE == false ]] || fail 'site update did not commit'
  [[ -f $CONFIG_PATH && -s $TOKEN_PATH ]] || fail 'site update changed proxy configuration'
}

test_uninstall_cancel() {
  prepare_management_fixture
  uninstall_deployment <<<''
  [[ -f $CONFIG_PATH && -f $SING_BOX_BIN && -f $TOKEN_PATH ]] || fail 'cancel removed files'
}

prepare_uninstall_fixture() {
  prepare_management_fixture
  mock_file_install
  install_management
  mkdir -p "$SYSTEMD_DIR" "$SITE_ROOT" "${CONFIG_DIR}/tls"
  printf 'unit core' >"${SYSTEMD_DIR}/${SERVICE_NAME}.service"
  printf 'unit tunnel' >"${SYSTEMD_DIR}/${TUNNEL_SERVICE_NAME}.service"
  printf 'keep custom website' >"${SITE_ROOT}/index.html"
  printf 'keep user file' >"${CONFIG_DIR}/custom.txt"
  printf 'keep shared connector' >"$CLOUDFLARED_INSTALL_PATH"
  printf 'keep other nginx site' >"${TEST_ROOT}/other.conf"
  printf 'keep audit' >"${TEST_ROOT}/system.log"
  ROLLBACK_TARGETS=() ROLLBACK_BACKUPS=() BACKUP_DIR="" ROLLBACK_ACTIVE=false
}

test_uninstall_scope() {
  prepare_uninstall_fixture
  preflight_environment() { :; }
  acquire_install_lock() { :; }
  capture_service_state() { NGINX_WAS_ACTIVE=true; }
  systemctl() {
    printf '%s\n' "$*" >>"${TEST_ROOT}/service-calls"
    [[ $1 != is-active ]]
  }
  nginx() { assert_equal "$*" -t; [[ ! -e $NGINX_CONFIG ]]; }
  uninstall_deployment --yes
  [[ ! -e $CONFIG_PATH && ! -e $TOKEN_PATH && ! -e $COMMAND_PATH && ! -e $MANAGER_DIR ]] || fail 'managed files remain'
  [[ -s ${CONFIG_DIR}/custom.txt && -s ${SITE_ROOT}/index.html && -s $CLOUDFLARED_INSTALL_PATH &&
     -s ${TEST_ROOT}/other.conf && -s ${TEST_ROOT}/system.log ]] || fail 'shared/user/audit files removed'
  [[ -s ${BACKUP_DIR}/paths.tsv ]] || fail 'uninstall lost recovery backups'
  ! grep -Eq 'disable --now nginx|stop nginx' "${TEST_ROOT}/service-calls" || fail 'shared nginx stopped'
}

test_uninstall_rollback() {
  prepare_uninstall_fixture
  cp "$NGINX_CONFIG" "${TEST_ROOT}/nginx.before"
  cat >"${TEST_ROOT}/uninstall-worker.sh" <<'WORKER'
source "${TEST_ROOT}/install.sh"
preflight_environment() { :; }
acquire_install_lock() { :; }
systemctl() { [[ $1 != is-active && $1 != is-enabled ]]; }
nginx() { return 1; }
restore_service_state() { printf '%s\n' "$*" >>"${TEST_ROOT}/restore-calls"; }
uninstall_deployment --yes
WORKER
  if env TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" bash "${TEST_ROOT}/uninstall-worker.sh" >"${TEST_ROOT}/worker.log" 2>&1; then
    fail 'failed nginx validation committed uninstall'
  fi
  cmp "$NGINX_CONFIG" "${TEST_ROOT}/nginx.before"
  [[ -s $CONFIG_PATH && -s $TOKEN_PATH && -x $SING_BOX_BIN && -x $COMMAND_PATH ]] || fail 'failed uninstall lost files'
  grep -q edge-router "${TEST_ROOT}/restore-calls"
  grep -q nginx "${TEST_ROOT}/restore-calls"
}

test_repeat_ingress_settings() {
  write_existing_config
  printf '{"deploy_mode":"tunnel","origin_port":9123}\n' >"$STATE_PATH"
  collect_configuration </dev/null
  assert_equal "$ORIGIN_PORT" 9123
  rm "$STATE_PATH"
  render_file "${TEMPLATE_DIR}/nginx-tunnel.conf.tpl" "$NGINX_CONFIG"
  ORIGIN_PORT=8001
  REQUESTED_DEPLOY_MODE=TUNNEL DEPLOY_MODE=TUNNEL
  collect_configuration </dev/null
  assert_equal "$ORIGIN_PORT" 9123
  REQUESTED_DEPLOY_MODE=""
  printf '{"deploy_mode":"direct","origin_port":9123}\n' >"$STATE_PATH"
  printf cert >"${TEST_ROOT}/cert"
  printf key >"${TEST_ROOT}/key"
  TLS_CERT_FILE="${TEST_ROOT}/cert" TLS_KEY_FILE="${TEST_ROOT}/key"
  DEPLOY_MODE=tunnel ORIGIN_PORT=8001
  collect_configuration </dev/null
  assert_equal "$DEPLOY_MODE" direct
  assert_equal "$ORIGIN_PORT" 9123
}

test_management_install_overrides() {
  prepare_management_fixture
  WS_PATH=/new-path/0123456789abcdef
  SING_BOX_PORT=25001
  REQUESTED_DEPLOY_MODE=DIRECT REQUESTED_ORIGIN_PORT=9090
  printf cert >"${TEST_ROOT}/cert"
  printf key >"${TEST_ROOT}/key"
  TLS_CERT_FILE="${TEST_ROOT}/cert" TLS_KEY_FILE="${TEST_ROOT}/key"
  preflight_environment() { :; }
  acquire_install_lock() { printf locked >"${TEST_ROOT}/locked"; }
  installed_proxy_mode() { [[ -f ${TEST_ROOT}/locked ]] || fail 'read before lock'; printf vless-xhttp-encryption; }
  main() {
    collect_configuration </dev/null
    assert_equal "$PROXY_MODE" vless-xhttp
    assert_equal "$WS_PATH" /new-path/0123456789abcdef
    assert_equal "$SING_BOX_PORT" 25001
    assert_equal "$ORIGIN_PORT" 9090
    assert_equal "$DEPLOY_MODE" direct
    assert_equal "$TLS_CERT_FILE" "${TEST_ROOT}/cert"
  }
  manage_install 2
}

test_management_direct_cert_reuse() {
  prepare_management_fixture
  printf '{"deploy_mode":"direct","origin_port":8001}\n' >"$STATE_PATH"
  mkdir -p "${CONFIG_DIR}/tls"
  printf cert >"$TLS_CERT_PATH"
  printf key >"$TLS_KEY_PATH"
  preflight_environment() { :; }
  acquire_install_lock() { :; }
  main() {
    assert_equal "$DEPLOY_MODE" direct
    assert_equal "$TLS_CERT_FILE" "$TLS_CERT_PATH"
    assert_equal "$TLS_KEY_FILE" "$TLS_KEY_PATH"
  }
  manage_install 2
  rm "$TLS_CERT_PATH" "$TLS_KEY_PATH"
  TLS_CERT_FILE="" TLS_KEY_FILE=""
  main() {
    [[ -z $TLS_CERT_FILE && -z $TLS_KEY_FILE ]] || fail 'missing certificates blocked interactive replacement'
  }
  manage_install 2
}

test_management_stop_broken() {
  prepare_management_fixture
  rm "$SING_BOX_BIN"
  printf broken >"$CONFIG_PATH"
  load_management_configuration() { fail 'stop parsed broken configuration'; }
  preflight_environment() { :; }
  acquire_install_lock() { :; }
  local core_stopped=false tunnel_stopped=false
  systemctl() {
    printf '%s\n' "$*" >>"${TEST_ROOT}/calls"
    case "$*" in
      'is-active --quiet edge-router') [[ $core_stopped == false ]] ;;
      'is-active --quiet edge-tunnel') [[ $tunnel_stopped == false ]] ;;
      'stop edge-router') core_stopped=true ;;
      'stop edge-tunnel') tunnel_stopped=true ;;
    esac
  }
  manage_services stop
  [[ $core_stopped == true && $tunnel_stopped == true ]] || fail 'broken install not stopped'
  assert_equal "$(<"$CONFIG_PATH")" broken
  ! grep -Eq 'stop nginx|disable|restart' "${TEST_ROOT}/calls" || fail 'stop affected other state'
}

test_management_restart_preflight() {
  prepare_management_fixture
  cat >"${TEST_ROOT}/preflight-worker.sh" <<'WORKER'
source "${TEST_ROOT}/install.sh"
preflight_environment() { :; }
acquire_install_lock() { :; }
check_core_configuration() { [[ $FAIL_STAGE != core ]]; }
nginx() { [[ $FAIL_STAGE != nginx ]]; }
systemctl() { printf '%s\n' "$*" >>"${TEST_ROOT}/mutations"; }
manage_services restart
WORKER
  local stage
  for stage in core nginx; do
    if env FAIL_STAGE="$stage" TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" bash "${TEST_ROOT}/preflight-worker.sh" >"${TEST_ROOT}/worker.log" 2>&1; then
      fail 'invalid configuration restarted services'
    fi
    [[ ! -e ${TEST_ROOT}/mutations ]] || fail 'preflight failure touched services'
  done
}

test_manager_cli_arguments() {
  validate_manager_arguments install 3
  validate_manager_arguments site '/some path/index.html'
  validate_manager_arguments uninstall --yes
  local args
  local -a parts
  for args in 'install 2 extra' 'install invalid' 'uninstall --yes extra' 'uninstall --force' 'restart extra' 'help extra' 'status extra' 'unknown'; do
    read -r -a parts <<<"$args"
    if (validate_manager_arguments "${parts[@]}") >"${TEST_ROOT}/error" 2>&1; then fail 'unexpected arguments accepted'; fi
  done
}

test_status_omits_journal() {
  systemctl() {
    assert_equal "$*" '--no-pager --full --lines=0 status edge-router edge-tunnel nginx'
    return 3
  }
  show_service_status
  systemctl() { return 1; }
  if show_service_status; then fail 'systemd status error hidden'; fi
}

test_file_rollback_no_service_change() {
  local original="${TEST_ROOT}/original"
  printf before >"$original"
  backup_file "$original"
  printf after >"$original"
  systemctl() { fail 'file-only rollback changed services'; }
  restore_service_state() { fail 'file-only rollback restarted services'; }
  rollback_installation
  assert_equal "$(<"$original")" before
}

test_nginx_restore_and_failure() {
  systemctl() {
    printf '%s\n' "$*" >>"${TEST_ROOT}/calls"
    [[ $1 != restart ]] || fail 'running shared nginx restarted'
  }
  restore_service_state nginx true true
  grep -qx 'reload nginx' "${TEST_ROOT}/calls"
  systemctl() { [[ $1 != reload ]]; }
  if restore_service_state nginx true true >"${TEST_ROOT}/error" 2>&1; then fail 'reload failure reported as restored'; fi
  grep -q '无法完整恢复 nginx' "${TEST_ROOT}/error"
  systemctl() {
    printf '%s\n' "$*" >>"${TEST_ROOT}/missing-calls"
    [[ $1 != cat ]]
  }
  restore_service_state edge-router false false
  grep -qx 'stop edge-router' "${TEST_ROOT}/missing-calls"
}

test_service_rollback_reports_failure() {
  local original="${TEST_ROOT}/original"
  printf before >"$original"
  backup_file "$original"
  printf after >"$original"
  SERVICE_STATE_DIRTY=true
  systemctl() { :; }
  restore_service_state() { return 1; }
  if rollback_installation >"${TEST_ROOT}/error" 2>&1; then fail 'partial service rollback reported as complete'; fi
  assert_equal "$(<"$original")" before
  grep -q '部分文件或服务未能回滚' "${TEST_ROOT}/error"
}

test_uninstall_snapshot_failure() {
  prepare_uninstall_fixture
  rm "$CLIENT_PATH"
  mkdir "$CLIENT_PATH"
  printf keep >"${CLIENT_PATH}/user-file"
  cat >"${TEST_ROOT}/snapshot-worker.sh" <<'WORKER'
source "${TEST_ROOT}/install.sh"
preflight_environment() { :; }
acquire_install_lock() { :; }
systemctl() {
  case $1 in
    is-active | is-enabled) return 3 ;;
    *) printf '%s\n' "$*" >>"${TEST_ROOT}/mutations" ;;
  esac
}
uninstall_deployment --yes
WORKER
  if env TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" bash "${TEST_ROOT}/snapshot-worker.sh" >"${TEST_ROOT}/worker.log" 2>&1; then fail 'invalid managed path accepted'; fi
  [[ ! -e ${TEST_ROOT}/mutations ]] || fail 'backup failure changed service states'
  [[ -s $CONFIG_PATH && -s $NGINX_CONFIG && -x $COMMAND_PATH && -s ${CLIENT_PATH}/user-file ]] || fail 'backup failure lost files'
}

test_management_service_failure_restore() {
  prepare_management_fixture
  cat >"${TEST_ROOT}/restart-worker.sh" <<'WORKER'
source "${TEST_ROOT}/install.sh"
preflight_environment() { :; }
acquire_install_lock() { :; }
check_core_configuration() { :; }
nginx() { :; }
systemctl() {
  printf '%s\n' "$*" >>"${TEST_ROOT}/calls"
  [[ $* != 'reload nginx' ]]
}
restore_service_state() { printf '%s\n' "$*" >>"${TEST_ROOT}/restored"; }
manage_services restart
WORKER
  if env TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" bash "${TEST_ROOT}/restart-worker.sh" >"${TEST_ROOT}/worker.log" 2>&1; then fail 'failed restart committed'; fi
  grep -qx 'restart edge-router' "${TEST_ROOT}/calls"
  grep -qx 'edge-router true true' "${TEST_ROOT}/restored"
  grep -qx 'nginx true true' "${TEST_ROOT}/restored"
  [[ -s $CONFIG_PATH && -s $TOKEN_PATH ]] || fail 'service rollback changed credentials'
}

test_uninstall_ownership_recheck() {
  prepare_uninstall_fixture
  cat >"${TEST_ROOT}/ownership-worker.sh" <<'WORKER'
source "${TEST_ROOT}/install.sh"
preflight_environment() { :; }
acquire_install_lock() { printf 'other-program\n' >"$COMMAND_PATH"; }
capture_service_state() { printf called >"${TEST_ROOT}/mutations"; }
uninstall_deployment --yes
WORKER
  if env TEST_ROOT="$TEST_ROOT" REPO_ROOT="$REPO_ROOT" bash "${TEST_ROOT}/ownership-worker.sh" >"${TEST_ROOT}/worker.log" 2>&1; then fail 'changed ownership ignored'; fi
  [[ ! -e ${TEST_ROOT}/mutations && -s $CONFIG_PATH && -s $NGINX_CONFIG ]] || fail 'ownership conflict changed installation'
  assert_equal "$(<"$COMMAND_PATH")" other-program
}

test_real_http() {
  local pid attempt
  node "${REPO_ROOT}/tests/http-server.cjs" "${TEST_ROOT}/port" >"${TEST_ROOT}/server.log" 2>&1 &
  pid=$!
  trap "kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true" EXIT
  for attempt in 1 2 3 4 5; do
    [[ -s ${TEST_ROOT}/port ]] && break
    command sleep 1
  done
  [[ -s ${TEST_ROOT}/port ]] || fail 'loopback server did not start'
  ORIGIN_PORT=$(<"${TEST_ROOT}/port")
  WS_PATH=/probe/0123456789abcdef
  # Even a deliberately unusable environment proxy must not affect the probe.
  export http_proxy=http://127.0.0.1:1 ALL_PROXY=http://127.0.0.1:1
  check_local_site
}

test_real_socket_preflight() {
  if [[ $(uname -s) != Linux ]]; then
    printf 'SKIP: real ss process inspection requires Linux (covered by CI)\n'
    return 77
  fi
  local pid attempt port
  node "${REPO_ROOT}/tests/http-server.cjs" "${TEST_ROOT}/port" >"${TEST_ROOT}/server.log" 2>&1 &
  pid=$!
  trap "kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true" EXIT
  for attempt in 1 2 3 4 5; do
    [[ -s ${TEST_ROOT}/port ]] && break
    command sleep 1
  done
  [[ -s ${TEST_ROOT}/port ]] || fail 'loopback server did not start'
  port=$(<"${TEST_ROOT}/port")
  unset -f ss
  systemctl() {
    assert_equal "$*" 'show nginx --property=MainPID --value'
    printf '%s' "$pid"
  }
  assert_port_compatible "$port" nginx
  systemctl() { printf '0'; }
  if (assert_port_compatible "$port" nginx) >"${TEST_ROOT}/error" 2>&1; then
    fail 'real socket owned by another process accepted'
  fi
  grep -q '已被其他进程占用' "${TEST_ROOT}/error"
}

load_bootstrap() {
  source "${REPO_ROOT}/bootstrap.sh"
  trap - EXIT
  TEMP_DIR="${TEST_ROOT}/work"
}

load_vps_bootstrap() {
  source "${REPO_ROOT}/bootstrap-vps.sh"
  trap - EXIT
  TEMP_DIR="${TEST_ROOT}/work"
}

test_bootstrap_download_failure() {
  load_bootstrap
  curl() { return 22; }
  tar() { touch "${TEST_ROOT}/extracted"; }
  if (download_repository) >"${TEST_ROOT}/error" 2>&1; then fail 'download failure ignored'; fi
  [[ ! -e ${TEST_ROOT}/extracted ]] || fail 'extraction ran after download failure'
}

test_bootstrap_archive() {
  load_bootstrap
  mkdir -p "${TEST_ROOT}/fixture/repo/templates"
  printf 'exit 99\n' >"${TEST_ROOT}/fixture/repo/install.sh"
  tar -czf "${TEST_ROOT}/fixture.tar.gz" -C "${TEST_ROOT}/fixture" repo
  curl() {
    while (($#)); do
      if [[ $1 == --output ]]; then cp "${TEST_ROOT}/fixture.tar.gz" "$2"; return 0; fi
      shift
    done
    fail 'archive streamed instead of downloaded to file'
  }
  download_repository
  [[ -s ${TEMP_DIR}/source/install.sh && -d ${TEMP_DIR}/source/templates ]]
}

test_bootstrap_bad_archive() {
  load_bootstrap
  curl() {
    while (($#)); do
      if [[ $1 == --output ]]; then printf broken >"$2"; return 0; fi
      shift
    done
    return 1
  }
  if (download_repository) >"${TEST_ROOT}/error" 2>&1; then fail 'bad archive accepted'; fi
  [[ ! -e ${TEMP_DIR}/source/install.sh ]] || fail 'bad archive left installer'
}

test_vps_bootstrap_arch_gate() {
  load_vps_bootstrap
  uname() { printf x86_64; }
  check_supported_arch
  uname() { printf amd64; }
  check_supported_arch
  uname() { printf aarch64; }
  check_supported_arch
  uname() { printf arm64; }
  check_supported_arch
  uname() { printf s390x; }
  if (check_supported_arch) >"${TEST_ROOT}/error" 2>&1; then
    fail 's390x accepted by the mainstream entry'
  fi
  grep -q 'bootstrap.sh' "${TEST_ROOT}/error"
  uname() { printf riscv64; }
  if (check_supported_arch) >"${TEST_ROOT}/error" 2>&1; then
    fail 'unknown architecture accepted'
  fi
}

if [[ ${1-} == --case ]]; then
  readonly TEST_ROOT=$3
  load_installer "$@"
  "$2"
  exit 0
fi

readonly TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ibmfree-tests.XXXXXXXX")
cleanup_tests() {
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/ibmfree-tests.*)
      find "$TEST_ROOT" -xdev -depth -delete
      ;;
  esac
}
trap cleanup_tests EXIT

failures=0
skipped=0
count=0
for test in test_first_install test_repeat_install test_explicit_values test_invalid_config \
  test_empty_config test_ambiguous_config test_three_inputs test_port_validation test_same_port \
  test_systemd_available test_systemd_unavailable test_install_lock_failure test_install_lock_real \
  test_port_preflight_free test_port_preflight_owned test_port_preflight_conflicts \
  test_port_preflight_errors test_port_preflight_modes \
  test_choose_port_free test_choose_port_failure test_choose_port_exhausted \
  test_large_cloudflared_help test_broken_cloudflared test_cloudflared_arch_dispatch \
  test_cloudflared_official_install test_cloudflared_checksum_failure \
  test_tunnel_metrics_private test_tunnel_core_independent \
  test_listener_audit_loopback test_listener_audit_exposure test_listener_audit_direct \
  test_listener_audit_unrelated test_listener_audit_unavailable test_websocket_upgrade \
  test_http_only_fails test_forged_accept_fails test_curl_failure_fails \
  test_backup_once test_site_preserved test_site_no_deployment_marker test_site_backup_private \
  test_atomic_install test_atomic_install_copy_failure test_atomic_install_rename_failure \
  test_atomic_install_stage_failure test_atomic_install_same_file test_atomic_install_signals \
  test_managed_directory_rejected test_atomic_install_symlink test_atomic_install_running_binary \
  test_missing_backup test_atomic_restore_copy_failure test_atomic_restore_rename_failure \
  test_atomic_restore_signal test_rollback_restores_files \
  test_exit_rolls_back test_signal_rolls_back test_committed_exit_preserves_files test_render_config test_client_link test_vmess_fixture \
  test_profile_selection test_vless_reinstall_and_switch test_vless_missing_or_mismatched_keys \
  test_xray_checksum_failure test_vless_output_contract test_xhttp_health_requires_core \
  test_management_bundle test_management_conflicts test_management_bundle_rollback test_management_list_private test_management_legacy_configuration \
  test_management_install_reuses_token test_management_service_scope test_management_menu_dispatch test_management_site \
  test_uninstall_cancel test_uninstall_scope test_uninstall_rollback \
  test_repeat_ingress_settings test_management_install_overrides test_management_direct_cert_reuse test_management_stop_broken test_management_restart_preflight \
  test_manager_cli_arguments test_status_omits_journal test_file_rollback_no_service_change test_nginx_restore_and_failure \
  test_service_rollback_reports_failure test_uninstall_snapshot_failure test_management_service_failure_restore test_uninstall_ownership_recheck \
  test_real_http test_real_socket_preflight \
  test_bootstrap_download_failure test_bootstrap_archive test_bootstrap_bad_archive test_vps_bootstrap_arch_gate; do
  ((count += 1))
  mkdir "${TEST_ROOT}/${test}"
  if bash "$SELF" --case "$test" "${TEST_ROOT}/${test}" >"${TEST_ROOT}/${test}.log" 2>&1; then
    printf 'PASS %s\n' "$test"
  else
    status=$?
    cat "${TEST_ROOT}/${test}.log"
    if ((status == 77)); then
      printf 'SKIP %s\n' "$test"
      ((skipped += 1))
    else
      printf 'FAIL %s\n' "$test"
      ((failures += 1))
    fi
  fi
done
printf '%s tests, %s failures, %s skipped\n' "$count" "$failures" "$skipped"
((failures == 0))
