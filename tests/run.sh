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
  choose_internal_port() { printf '23456'; }
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
  [[ -z $(find "$TEST_ROOT" -name '*.restore.*' -print) ]] || fail 'staging file left behind'
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
  install() { cat >"${@: -1}"; }
  write_client_link
  node -e 'const fs=require("fs"),assert=require("assert/strict"); const link=fs.readFileSync(process.argv[1],"utf8").trim(); assert.ok(link.startsWith("vmess://")); const c=JSON.parse(Buffer.from(link.slice(8),"base64").toString("utf8")); assert.equal(c.id,"11111111-1111-4111-8111-111111111111"); assert.equal(c.add,"edge.example.com"); assert.equal(c.path,Buffer.from(process.argv[2],"base64").toString("utf8")); assert.equal(c.net,"ws"); assert.equal(c.tls,"tls"); assert.equal(c.port,"443"); assert.ok(!JSON.stringify(c).includes("test-only-token"));' "$CLIENT_PATH" "$(printf '%s' "$WS_PATH" | base64 | tr -d '\r\n')"
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
  load_installer
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
count=0
for test in test_first_install test_repeat_install test_explicit_values test_invalid_config \
  test_empty_config test_ambiguous_config test_three_inputs test_port_validation test_same_port \
  test_large_cloudflared_help test_broken_cloudflared test_websocket_upgrade \
  test_http_only_fails test_forged_accept_fails test_curl_failure_fails \
  test_backup_once test_missing_backup test_atomic_restore_copy_failure test_rollback_restores_files \
  test_exit_rolls_back test_signal_rolls_back test_committed_exit_preserves_files test_render_config test_client_link \
  test_real_http test_bootstrap_download_failure test_bootstrap_archive test_bootstrap_bad_archive; do
  ((count += 1))
  mkdir "${TEST_ROOT}/${test}"
  if bash "$SELF" --case "$test" "${TEST_ROOT}/${test}" >"${TEST_ROOT}/${test}.log" 2>&1; then
    printf 'PASS %s\n' "$test"
  else
    cat "${TEST_ROOT}/${test}.log"
    printf 'FAIL %s\n' "$test"
    ((failures += 1))
  fi
done
printf '%s tests, %s failures\n' "$count" "$failures"
((failures == 0))
