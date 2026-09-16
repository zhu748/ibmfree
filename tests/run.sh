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
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' '--token-file'" \
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
  test_large_cloudflared_help test_broken_cloudflared test_websocket_upgrade \
  test_http_only_fails test_forged_accept_fails test_curl_failure_fails \
  test_backup_once test_site_preserved test_site_no_deployment_marker test_site_backup_private \
  test_atomic_install test_atomic_install_copy_failure test_atomic_install_rename_failure \
  test_atomic_install_stage_failure test_atomic_install_same_file test_atomic_install_signals \
  test_managed_directory_rejected test_atomic_install_symlink test_atomic_install_running_binary \
  test_missing_backup test_atomic_restore_copy_failure test_atomic_restore_rename_failure \
  test_atomic_restore_signal test_rollback_restores_files \
  test_exit_rolls_back test_signal_rolls_back test_committed_exit_preserves_files test_render_config test_client_link test_vmess_fixture \
  test_real_http test_real_socket_preflight \
  test_bootstrap_download_failure test_bootstrap_archive test_bootstrap_bad_archive; do
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
