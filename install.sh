#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly SING_BOX_VERSION="1.13.19"
readonly XRAY_VERSION="26.11.9"
readonly CLOUDFLARED_VERSION="2026.8.2"
readonly CLOUDFLARED_RELEASE_TAG="cloudflared-${CLOUDFLARED_VERSION}-s390x"
readonly CLOUDFLARED_RELEASE_BASE="https://github.com/zhu748/ibmfree/releases/download/${CLOUDFLARED_RELEASE_TAG}"
readonly CLOUDFLARED_INSTALL_PATH="/usr/local/bin/cloudflared"
readonly SERVICE_NAME="edge-router"
readonly TUNNEL_SERVICE_NAME="edge-tunnel"
readonly CONFIG_DIR="/etc/edge-router"
readonly CONFIG_PATH="${CONFIG_DIR}/config.json"
readonly CLIENT_PATH="${CONFIG_DIR}/client.txt"
readonly ENCRYPTION_PATH="${CONFIG_DIR}/vless-keys.json"
readonly STATE_PATH="${CONFIG_DIR}/install-state.json"
readonly MANAGER_DIR="/usr/local/lib/fczd"
readonly COMMAND_PATH="/usr/local/bin/fczd"
readonly TOKEN_PATH="${CONFIG_DIR}/tunnel.token"
readonly TLS_CERT_PATH="${CONFIG_DIR}/tls/origin.crt"
readonly TLS_KEY_PATH="${CONFIG_DIR}/tls/origin.key"
readonly SING_BOX_BIN="/usr/local/libexec/edge-router"
readonly SITE_ROOT="/var/www/edge-router"
readonly BACKUP_ROOT="/var/backups/edge-router"
readonly INSTALL_LOCK_PATH="/run/edge-router-install.lock"
readonly NGINX_CONFIG="/etc/nginx/conf.d/edge-router.conf"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMPLATE_DIR="${SCRIPT_DIR}/templates"
readonly -a MANAGED_TEMPLATES=(
  sing-box.json.tpl xray.json.tpl nginx-tunnel.conf.tpl nginx-direct.conf.tpl
  nginx-ws-location.conf.tpl nginx-xhttp-location.conf.tpl edge-router.service.tpl
  edge-tunnel.service.tpl index.html fczd-command.tpl
)

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"
REQUESTED_DEPLOY_MODE="${DEPLOY_MODE:-}"
REQUESTED_ORIGIN_PORT="${ORIGIN_PORT:-}"
DEPLOY_MODE="${DEPLOY_MODE:-tunnel}"
PROXY_MODE="${PROXY_MODE:-}"
VLESS_DECRYPTION="none"
VLESS_ENCRYPTION="none"
CUSTOM_UUID="${UUID:-}"
WS_PATH="${WS_PATH:-}"
ORIGIN_PORT="${ORIGIN_PORT:-8001}"
SING_BOX_PORT="${SING_BOX_PORT:-}"
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
TUNNEL_TOKEN_FILE="${TUNNEL_TOKEN_FILE:-}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-}"
SITE_INDEX_FILE="${SITE_INDEX_FILE:-}"
TEMP_DIR=""
BACKUP_DIR=""
INSTALL_LOCK_FD=""
MANAGER_CREATED=false

SITE_NONCE=""
SITE_HUE=""
SITE_GRID_SIZE=""
SITE_TITLE=""
SITE_RAIL=""
SITE_EYEBROW=""
SITE_HEADING=""
SITE_SUMMARY=""
SITE_STATE=""

declare -a ROLLBACK_TARGETS=()
declare -a ROLLBACK_BACKUPS=()
ROLLBACK_ACTIVE=false
EDGE_WAS_ACTIVE=false
EDGE_WAS_ENABLED=false
NGINX_WAS_ACTIVE=false
NGINX_WAS_ENABLED=false
TUNNEL_WAS_ACTIVE=false
TUNNEL_WAS_ENABLED=false
SERVICE_STATE_DIRTY=false

info() {
  printf '%b\n' "${COLOR_CYAN}$*${COLOR_RESET}"
}

success() {
  printf '%b\n' "${COLOR_GREEN}$*${COLOR_RESET}"
}

warn() {
  printf '%b\n' "${COLOR_YELLOW}$*${COLOR_RESET}" >&2
}

die() {
  printf '%b\n' "${COLOR_RED}错误: $*${COLOR_RESET}" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    find "$TEMP_DIR" -mindepth 1 -maxdepth 3 -type f -delete 2>/dev/null || true
    find "$TEMP_DIR" -mindepth 1 -maxdepth 3 -type d -empty -delete 2>/dev/null || true
    rmdir "$TEMP_DIR" 2>/dev/null || true
  fi
}

on_error() {
  local exit_code=$?
  printf '%b\n' "${COLOR_RED}操作在第 ${BASH_LINENO[0]} 行失败（退出码: ${exit_code}）。${COLOR_RESET}" >&2
  exit "$exit_code"
}

on_exit() {
  local exit_code=$?
  trap - EXIT ERR INT TERM
  if [[ $ROLLBACK_ACTIVE == "true" ]]; then
    # An uncommitted transaction must never be reported as a successful install.
    ((exit_code != 0)) || exit_code=1
    rollback_installation || true
  fi
  if ((exit_code != 0)) && [[ $MANAGER_CREATED == true ]]; then
    # Only empty directories created by this failed install are removed.
    rmdir -- "${MANAGER_DIR}/templates" "$MANAGER_DIR" 2>/dev/null || true
  fi
  cleanup
  exit "$exit_code"
}

trap on_exit EXIT
trap on_error ERR
trap 'exit 130' INT
trap 'exit 143' TERM

require_file() {
  [[ -f $1 ]] || die "缺少仓库文件: $1。请克隆完整仓库后运行，不要使用 curl | bash。"
}

preflight_environment() {
  local manager_version=""
  command -v systemctl >/dev/null 2>&1 || die "当前系统不使用 systemd。"
  manager_version=$(systemctl show --property=Version --value 2>/dev/null) || \
    die "无法连接 systemd 系统管理器；请在正常启动 systemd 的 VPS 上运行。"
  [[ -n $manager_version ]] || die "无法读取 systemd 系统管理器状态。"
}

acquire_install_lock() {
  command -v flock >/dev/null 2>&1 || die "缺少 flock，请先安装系统基础包 util-linux。"
  [[ ! -L $INSTALL_LOCK_PATH ]] || die "安装锁不能是符号链接: ${INSTALL_LOCK_PATH}"
  [[ ! -e $INSTALL_LOCK_PATH || -f $INSTALL_LOCK_PATH ]] || die "安装锁路径不是普通文件: ${INSTALL_LOCK_PATH}"
  # Management can acquire the lock before loading defaults, then enter main().
  # Reuse only a descriptor that is still open in this process.
  if [[ $INSTALL_LOCK_FD =~ ^[0-9]+$ ]] && ( : >&"$INSTALL_LOCK_FD" ) 2>/dev/null; then
    return 0
  fi
  exec {INSTALL_LOCK_FD}>>"$INSTALL_LOCK_PATH"
  flock --nonblock "$INSTALL_LOCK_FD" || die "另一个安装进程正在运行，或无法取得安装锁；请等待它结束后重试。"
  # Keep the inode in place; the descriptor releases the lock after exit/rollback.
}

assert_port_compatible() {
  local port=$1 unit=$2 listeners="" main_pid="" listener=""
  listeners=$(ss -H -lntp "sport = :${port}" 2>/dev/null) || \
    die "无法检查 TCP ${port} 的占用情况，已停止安装。"
  [[ -n $listeners ]] || return 0

  main_pid=$(systemctl show "$unit" --property=MainPID --value 2>/dev/null) || \
    die "TCP ${port} 已被占用，无法确认是否属于 ${unit}；未停止任何服务。"
  [[ $main_pid =~ ^[1-9][0-9]*$ ]] || \
    die "TCP ${port} 已被其他进程占用；请先检查监听服务，安装器不会自动结束进程或改端口。"
  while IFS= read -r listener; do
    [[ $listener == *"pid=${main_pid},"* ]] || \
      die "TCP ${port} 存在不属于 ${unit} 的监听进程；请先检查，安装器不会自动结束进程或改端口。"
  done <<<"$listeners"
}

preflight_ports() {
  assert_port_compatible "$SING_BOX_PORT" "$SERVICE_NAME"
  if [[ $DEPLOY_MODE == "tunnel" ]]; then
    assert_port_compatible "$ORIGIN_PORT" nginx
  else
    assert_port_compatible 443 nginx
  fi
}

read_value() {
  local variable_name=$1
  local prompt_text=$2
  local default_value=${3-}
  local secret=${4-false}
  local current_value=${!variable_name-}
  local user_input=""

  [[ -n "$current_value" ]] && return 0

  if [[ -n "$default_value" ]]; then
    prompt_text+=" [${default_value}]"
  fi
  prompt_text+=": "

  if [[ "$secret" == "true" ]]; then
    IFS= read -r -s -p "$prompt_text" user_input || true
    printf '\n'
  else
    IFS= read -r -p "$prompt_text" user_input || true
  fi

  printf -v "$variable_name" '%s' "${user_input:-$default_value}"
}

random_hex() {
  local byte_count=${1:-12}

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$byte_count"
  elif [[ -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
    od -An -N "$byte_count" -tx1 /dev/urandom | tr -d ' \n'
  else
    die "无法生成安全随机值，请安装 openssl 或提供 /dev/urandom。"
  fi
}

generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '\r\n' </proc/sys/kernel/random/uuid
  else
    die "无法生成 UUID，请安装 uuidgen。"
  fi
}

prepare_site_profile() {
  local selector
  local -a labels=("Service desk" "Project space" "Public workspace" "Documentation")
  local -a eyebrows=("Service availability" "Workspace status" "Public service" "Site status")
  local -a headings=("Available now." "Service online." "Welcome." "Everything is ready.")
  local -a summaries=(
    "此站点用于提供公开资料与服务信息，计划维护和状态变化会在这里更新。"
    "这里发布项目说明与公共内容。如有计划维护，相关通知会在本页面更新。"
    "公开页面当前可正常访问。服务信息和维护公告将在这里发布。"
    "此页面承载公开内容与状态信息，必要的维护通知会提前更新。"
  )
  local -a states=("Available" "Operational" "Online" "Ready")

  SITE_NONCE=$(random_hex 12)
  selector=$((16#${SITE_NONCE:0:2}))
  SITE_HUE=$((16#${SITE_NONCE:2:4} % 321))
  SITE_GRID_SIZE=$(printf '%d.%d' "$((4 + selector % 2))" "$((selector % 9))")
  SITE_TITLE="${PUBLIC_DOMAIN} - ${labels[selector % ${#labels[@]}]}"
  SITE_RAIL="${PUBLIC_DOMAIN} / ${labels[(selector + 1) % ${#labels[@]}]}"
  SITE_EYEBROW=${eyebrows[(selector + 2) % ${#eyebrows[@]}]}
  SITE_HEADING=${headings[(selector + 3) % ${#headings[@]}]}
  SITE_SUMMARY=${summaries[selector % ${#summaries[@]}]}
  SITE_STATE=${states[(selector + 1) % ${#states[@]}]}
}

validate_uuid() {
  [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

validate_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_port() {
  [[ $1 =~ ^[0-9]{4,5}$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535))
}

validate_ws_path() {
  [[ $1 =~ ^/[A-Za-z0-9/_-]{15,119}$ ]] && [[ $1 != *//* ]] && [[ $1 != */ ]]
}

choose_internal_port() {
  local candidate=""
  local listeners=""
  local attempts=0

  listeners=$(ss -H -lnt 2>/dev/null) || die "无法读取 TCP 监听状态，不能安全选择内部端口。"
  while ((attempts < 100)); do
    candidate=$((20000 + (((RANDOM << 1) ^ RANDOM) % 20000)))
    if [[ $candidate != "$ORIGIN_PORT" ]] &&
      ! awk -v port="$candidate" '$4 ~ (":" port "$") { found = 1 } END { exit !found }' <<<"$listeners"; then
      printf '%s' "$candidate"
      return 0
    fi
    ((attempts += 1))
  done

  die "无法选择空闲的内部端口。"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)
      printf '%s %s\n' "amd64" "ef88a9e577d474210867bd708933d042e9b70106529df2656182c9db90106aa1"
      ;;
    aarch64 | arm64)
      printf '%s %s\n' "arm64" "7fe3597a95a3c5ad67477b1d7653b9ce097e0be7c676758eba1fcf558f353d57"
      ;;
    s390x | s390)
      printf '%s %s\n' "s390x" "23843202066901798b1df4a136a9c275f82e2ac3f27f24e82604206bcfd717b0"
      ;;
    *)
      die "不支持的系统架构: $(uname -m)"
      ;;
  esac
}

detect_xray_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)
      printf '%s %s\n' "64" "b651f7e1d9966ee2c1b1ee1bf8b52c72771824d3065dce96bbc8bcc19ed95f82" ;;
    aarch64 | arm64)
      printf '%s %s\n' "arm64-v8a" "64ed6858982a7f5eb85d88b811089063bd4f17561f4c8f44e0f1dc8e6f6430be" ;;
    s390x | s390)
      printf '%s %s\n' "s390x" "5657912fbd7429d8a0202dccd8815a297fe49d009216a5359af238ebb6f0db4c" ;;
    *) die "不支持的系统架构: $(uname -m)" ;;
  esac
}

sha256_file() {
  local file=$1

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    die "找不到 SHA-256 校验工具。"
  fi
}

download_file() {
  local url=$1
  local output=$2

  curl --disable --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' \
    --retry 3 --connect-timeout 15 --max-time 300 \
    --output "$output" "$url"
}

install_cloudflared_s390x() {
  local binary checksum checksum_name expected_hash actual_hash

  [[ $(uname -m) == "s390x" || $(uname -m) == "s390" ]] || \
    die "当前架构没有自动 cloudflared 安装包，请通过 CLOUDFLARED_BIN 指定可执行文件。"

  TEMP_DIR=${TEMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/edge-install.XXXXXXXX")}
  binary="${TEMP_DIR}/cloudflared-linux-s390x"
  checksum="${TEMP_DIR}/cloudflared-linux-s390x.sha256"

  info "下载 cloudflared ${CLOUDFLARED_VERSION} s390x 发布包……"
  download_file "${CLOUDFLARED_RELEASE_BASE}/cloudflared-linux-s390x" "$binary"
  download_file "${CLOUDFLARED_RELEASE_BASE}/cloudflared-linux-s390x.sha256" "$checksum"

  expected_hash=$(awk 'NR == 1 { print $1 }' "$checksum")
  checksum_name=$(awk 'NR == 1 { name=$2; sub(/^\*/, "", name); print name }' "$checksum")
  [[ $expected_hash =~ ^[0-9a-fA-F]{64}$ ]] || die "cloudflared 校验文件格式无效。"
  [[ $checksum_name == "cloudflared-linux-s390x" ]] || die "cloudflared 校验文件名无效。"
  actual_hash=$(sha256_file "$binary")
  [[ ${actual_hash,,} == "${expected_hash,,}" ]] || \
    die "cloudflared 校验失败。期望 ${expected_hash}，实际 ${actual_hash}。"

  install -d -o root -g root -m 0755 "$(dirname "$CLOUDFLARED_INSTALL_PATH")"
  backup_file "$CLOUDFLARED_INSTALL_PATH"
  install_managed_file root root 0755 "$binary" "$CLOUDFLARED_INSTALL_PATH"
  CLOUDFLARED_BIN=$CLOUDFLARED_INSTALL_PATH
  success "cloudflared s390x 发布包校验并安装完成。"
}

detect_cloudflared_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)
      printf '%s %s\n' "amd64" "fcfb02b575a52ca1af2e3267af4e1517bcdeb30ac48c834c69abaed3c0576ad2"
      ;;
    aarch64 | arm64)
      printf '%s %s\n' "arm64" "7747d94570fb390cf47dcb4f9555c193c6355cda9793f0d878d9049e5d6a7790"
      ;;
    *)
      die "当前架构没有官方 cloudflared 发布包，请通过 CLOUDFLARED_BIN 指定可执行文件。"
      ;;
  esac
}

install_cloudflared_official() {
  local arch expected_hash actual_hash binary url

  read -r arch expected_hash < <(detect_cloudflared_arch)
  TEMP_DIR=${TEMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/edge-install.XXXXXXXX")}
  binary="${TEMP_DIR}/cloudflared-linux-${arch}"
  url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${arch}"

  info "下载 cloudflared ${CLOUDFLARED_VERSION} 官方 ${arch} 发布包……"
  download_file "$url" "$binary"
  actual_hash=$(sha256_file "$binary")
  [[ ${actual_hash,,} == "$expected_hash" ]] || \
    die "cloudflared 发布包 SHA-256 校验失败。期望 ${expected_hash}，实际 ${actual_hash}。"

  install -d -o root -g root -m 0755 "$(dirname "$CLOUDFLARED_INSTALL_PATH")"
  backup_file "$CLOUDFLARED_INSTALL_PATH"
  install_managed_file root root 0755 "$binary" "$CLOUDFLARED_INSTALL_PATH"
  CLOUDFLARED_BIN=$CLOUDFLARED_INSTALL_PATH
  success "cloudflared 官方发布包校验并安装完成。"
}

ensure_cloudflared() {
  local help_output=""

  if [[ -z "$CLOUDFLARED_BIN" ]]; then
    CLOUDFLARED_BIN=$(command -v cloudflared || true)
  fi

  if [[ -z "$CLOUDFLARED_BIN" ]]; then
    case "$(uname -m)" in
      s390x | s390) install_cloudflared_s390x ;;
      x86_64 | amd64 | aarch64 | arm64) install_cloudflared_official ;;
      *)
        die "当前架构没有自动 cloudflared 安装包，请通过 CLOUDFLARED_BIN 指定可执行文件。"
        ;;
    esac
  fi

  [[ $CLOUDFLARED_BIN =~ ^/[A-Za-z0-9_./-]+$ ]] || die "cloudflared 路径包含不安全字符。"
  [[ -x $CLOUDFLARED_BIN ]] || die "cloudflared 不存在或不可执行: ${CLOUDFLARED_BIN}"
  help_output=$("$CLOUDFLARED_BIN" tunnel --no-autoupdate --metrics 127.0.0.1:0 run --help 2>&1) || \
    die "cloudflared 参数检查失败，请检查二进制架构、文件权限和 --metrics 支持。"
  [[ $help_output == *"--token-file"* ]] || \
    die "当前 cloudflared 版本不支持 --token-file，请升级。"
}

install_packages() {
  info "检查基础依赖……"

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates coreutils curl iproute2 nginx tar unzip
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates coreutils curl iproute nginx tar unzip
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates coreutils curl iproute nginx tar unzip
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install ca-certificates coreutils curl iproute2 nginx tar unzip
  else
    die "不支持的包管理器，请先安装 curl、tar、unzip、ca-certificates 和 nginx。"
  fi

  command -v curl >/dev/null 2>&1 || die "curl 安装失败。"
  command -v nginx >/dev/null 2>&1 || die "nginx 安装失败。"
  command -v ss >/dev/null 2>&1 || die "缺少 ss 命令（通常由 iproute2 提供）。"
  command -v unzip >/dev/null 2>&1 || die "缺少 unzip 命令。"
}

read_json_string() {
  local file=$1
  local key=$2

  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$file" 2>/dev/null | \
    sed -E 's/^[^:]+:[[:space:]]*"//; s/"$//' || true
}

read_json_number() {
  local file=$1
  local key=$2

  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[0-9]+" "$file" 2>/dev/null | \
    sed -E 's/^[^:]+:[[:space:]]*//' || true
}

collect_configuration() {
  local existing_path=""
  local existing_port=""
  local existing_uuid=""
  local generated_uuid=""
  local tunnel_token=""
  local existing_mode="vmess-ws" existing_decryption="none"
  local existing_protocols=""

  if [[ -e $CONFIG_PATH || -L $CONFIG_PATH ]]; then
    [[ -r $CONFIG_PATH && -s $CONFIG_PATH ]] || die "现有配置为空或不可读，已停止以保留原连接参数: ${CONFIG_PATH}"
    existing_uuid=$(read_json_string "$CONFIG_PATH" uuid)
    existing_path=$(read_json_string "$CONFIG_PATH" path)
    existing_port=$(read_json_number "$CONFIG_PATH" listen_port)
    existing_protocols=$(read_json_string "$CONFIG_PATH" protocol)
    if [[ -z $existing_uuid && ${existing_protocols%%$'\n'*} == vless ]]; then
      [[ $(read_json_string "$CONFIG_PATH" network) == xhttp ]] || die "现有 VLESS 配置不是本安装器支持的 XHTTP 配置。"
      existing_uuid=$(read_json_string "$CONFIG_PATH" id)
      existing_port=$(read_json_number "$CONFIG_PATH" port)
      existing_decryption=$(read_json_string "$CONFIG_PATH" decryption)
      [[ -n $existing_decryption && $existing_decryption != *$'\n'* ]] || die "无法读取现有 VLESS 加密设置。"
      existing_mode=vless-xhttp
      [[ $existing_decryption == none ]] || existing_mode=vless-xhttp-encryption
    fi

    validate_uuid "$existing_uuid" && validate_ws_path "$existing_path" && validate_port "$existing_port" || \
      die "无法唯一读取现有 UUID、代理路径和端口，已停止；请检查 ${CONFIG_PATH}，不要直接删除旧配置。"

    if [[ -z "$WS_PATH" ]] && validate_ws_path "$existing_path"; then
      WS_PATH=$existing_path
    fi
    if [[ -z "$SING_BOX_PORT" ]] && validate_port "$existing_port"; then
      SING_BOX_PORT=$existing_port
    fi
    if [[ -z $REQUESTED_DEPLOY_MODE && ( -r $STATE_PATH || -r $NGINX_CONFIG ) ]]; then
      DEPLOY_MODE=$(installed_deploy_mode) || die "无法读取已有部署模式，请显式设置 DEPLOY_MODE。"
    fi
    if [[ -z $REQUESTED_ORIGIN_PORT && $ORIGIN_PORT == 8001 && ( -r $STATE_PATH || -r $NGINX_CONFIG ) ]]; then
      ORIGIN_PORT=$(installed_origin_port "$DEPLOY_MODE") || die "无法读取已有入口端口，请显式设置 ORIGIN_PORT。"
    fi
  fi

  if [[ -z $PROXY_MODE ]]; then
    info "代理方案：1) VMess + WS + TLS  2) VLESS + XHTTP + TLS  3) VLESS + XHTTP + TLS + Encryption"
    read_value PROXY_MODE "选择方案（1/2/3）" "$existing_mode"
  fi
  case "${PROXY_MODE,,}" in
    1 | vmess-ws) PROXY_MODE=vmess-ws ;;
    2 | vless-xhttp) PROXY_MODE=vless-xhttp ;;
    3 | vless-xhttp-encryption) PROXY_MODE=vless-xhttp-encryption ;;
    *) die "PROXY_MODE 只能是 vmess-ws、vless-xhttp 或 vless-xhttp-encryption（也可填 1/2/3）。" ;;
  esac
  VLESS_DECRYPTION=none
  VLESS_ENCRYPTION=none
  if [[ $PROXY_MODE == vless-xhttp-encryption ]]; then
    if [[ -e $ENCRYPTION_PATH || -L $ENCRYPTION_PATH ]]; then
      [[ -r $ENCRYPTION_PATH && -s $ENCRYPTION_PATH ]] || die "VLESS 密钥文件为空或不可读。"
      VLESS_DECRYPTION=$(read_json_string "$ENCRYPTION_PATH" decryption)
      VLESS_ENCRYPTION=$(read_json_string "$ENCRYPTION_PATH" encryption)
      validate_vless_keys || die "VLESS 密钥文件无效，已停止以避免更换现有密钥。"
    elif [[ $existing_mode == vless-xhttp-encryption ]]; then
      die "现有加密配置缺少 ${ENCRYPTION_PATH}，已停止以避免旧客户端失效。请恢复该文件。"
    fi
    if [[ $existing_mode == vless-xhttp-encryption && $VLESS_DECRYPTION != "$existing_decryption" ]]; then
      die "现有配置与 VLESS 密钥文件不匹配，已停止。"
    fi
  fi

  if [[ -z "$CUSTOM_UUID" ]]; then
    if validate_uuid "$existing_uuid"; then
      generated_uuid=$existing_uuid
    else
      generated_uuid=$(generate_uuid)
    fi
    read_value CUSTOM_UUID "UUID（回车使用默认值）" "$generated_uuid"
  fi
  validate_uuid "$CUSTOM_UUID" || die "UUID 格式无效。"

  read_value PUBLIC_DOMAIN "公网域名"
  validate_domain "$PUBLIC_DOMAIN" || die "公网域名格式无效。"

  if [[ -n "$SITE_INDEX_FILE" ]]; then
    [[ -s $SITE_INDEX_FILE ]] || die "SITE_INDEX_FILE 不存在或为空。"
  fi

  read_value DEPLOY_MODE "部署模式（tunnel/direct）" "tunnel"
  DEPLOY_MODE=${DEPLOY_MODE,,}
  [[ $DEPLOY_MODE == "tunnel" || $DEPLOY_MODE == "direct" ]] || die "部署模式只能是 tunnel 或 direct。"

  if [[ -z "$WS_PATH" ]]; then
    WS_PATH="/$(random_hex 12)/$(random_hex 16)"
  fi
  validate_ws_path "$WS_PATH" || die "WS_PATH（WS/XHTTP 共用）必须是 16-120 位安全路径，且不能以 / 结尾。"

  validate_port "$ORIGIN_PORT" || die "ORIGIN_PORT 必须是 1024-65535 之间的端口。"
  ORIGIN_PORT=$((10#$ORIGIN_PORT))
  if [[ -z "$SING_BOX_PORT" ]]; then
    SING_BOX_PORT=$(choose_internal_port)
  fi
  validate_port "$SING_BOX_PORT" || die "SING_BOX_PORT 必须是 1024-65535 之间的端口。"
  SING_BOX_PORT=$((10#$SING_BOX_PORT))
  [[ $SING_BOX_PORT != "$ORIGIN_PORT" ]] || die "两个内部端口不能相同。"

  if [[ $DEPLOY_MODE == "direct" ]]; then
    read_value TLS_CERT_FILE "TLS 证书文件路径"
    read_value TLS_KEY_FILE "TLS 私钥文件路径"
    [[ -s $TLS_CERT_FILE ]] || die "TLS 证书不存在或为空。"
    [[ -s $TLS_KEY_FILE ]] || die "TLS 私钥不存在或为空。"
  else
    if [[ -n "$TUNNEL_TOKEN_FILE" ]]; then
      [[ -s $TUNNEL_TOKEN_FILE ]] || die "TUNNEL_TOKEN_FILE 不存在或为空。"
    else
      read_value tunnel_token "Cloudflare Tunnel Token" "" true
      [[ -n "$tunnel_token" ]] || die "Tunnel Token 不能为空。"
      TEMP_DIR=${TEMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/edge-install.XXXXXXXX")}
      TUNNEL_TOKEN_FILE="${TEMP_DIR}/tunnel.token"
      printf '%s' "$tunnel_token" >"$TUNNEL_TOKEN_FILE"
      unset tunnel_token
    fi
  fi
}

create_service_user() {
  if ! getent group edge-router >/dev/null 2>&1; then
    groupadd --system edge-router
  fi
  if ! id edge-router >/dev/null 2>&1; then
    useradd --system --gid edge-router --no-create-home --home-dir /nonexistent \
      --shell /usr/sbin/nologin edge-router
  fi
}

capture_service_state() {
  EDGE_WAS_ACTIVE=false EDGE_WAS_ENABLED=false
  NGINX_WAS_ACTIVE=false NGINX_WAS_ENABLED=false
  TUNNEL_WAS_ACTIVE=false TUNNEL_WAS_ENABLED=false
  systemctl is-active --quiet "$SERVICE_NAME" && EDGE_WAS_ACTIVE=true || true
  systemctl is-enabled --quiet "$SERVICE_NAME" && EDGE_WAS_ENABLED=true || true
  systemctl is-active --quiet nginx && NGINX_WAS_ACTIVE=true || true
  systemctl is-enabled --quiet nginx && NGINX_WAS_ENABLED=true || true
  systemctl is-active --quiet "$TUNNEL_SERVICE_NAME" && TUNNEL_WAS_ACTIVE=true || true
  systemctl is-enabled --quiet "$TUNNEL_SERVICE_NAME" && TUNNEL_WAS_ENABLED=true || true
}

restore_service_state() {
  local unit=$1
  local was_active=$2
  local was_enabled=$3
  local failed=0

  if systemctl cat "$unit" >/dev/null 2>&1; then
    if [[ $was_enabled == "true" ]]; then
      systemctl enable "$unit" >/dev/null 2>&1 || failed=1
    else
      systemctl disable "$unit" >/dev/null 2>&1 || failed=1
    fi

    if [[ $was_active == "true" ]]; then
      if [[ $unit == nginx ]] && systemctl is-active --quiet nginx; then
        systemctl reload nginx >/dev/null 2>&1 || failed=1
      else
        systemctl restart "$unit" >/dev/null 2>&1 || failed=1
      fi
    else
      systemctl stop "$unit" >/dev/null 2>&1 || failed=1
    fi
  else
    if [[ $was_active == true || $was_enabled == true ]]; then
      failed=1
    else
      # A newly installed unit may still be running after its file was removed.
      if systemctl is-active --quiet "$unit"; then
        systemctl stop "$unit" >/dev/null 2>&1 || failed=1
      fi
      systemctl disable "$unit" >/dev/null 2>&1 || true
    fi
  fi
  ((failed == 0)) || warn "无法完整恢复 ${unit} 的服务状态，请手动检查。"
  return "$failed"
}

cleanup_file_stage() {
  local exit_code=$?
  local directory=$1
  trap - EXIT ERR INT TERM
  if [[ -n $directory ]]; then
    # Only this operation's payload and now-empty directory may be removed.
    rm -f -- "${directory}/payload" || warn "暂存文件清理失败: ${directory}/payload"
    rmdir -- "$directory" || warn "暂存目录保留，请检查: ${directory}"
  fi
  exit "$exit_code"
}

restore_backup_file() (
  local backup=$1
  local target=$2
  local stage_dir=""
  trap - ERR
  trap 'cleanup_file_stage "$stage_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  [[ -f $backup || -L $backup ]] || return 1
  [[ $target == /* && $target != */ ]] || return 1
  # The private directory keeps even public-site rollback payloads unreadable.
  stage_dir=$(mktemp -d "${target%/*}/.edge-stage.XXXXXXXX") || return 1
  cp --archive --no-dereference --remove-destination --no-target-directory \
    "$backup" "${stage_dir}/payload" || return 1
  mv --force --no-target-directory -- "${stage_dir}/payload" "$target"
)

rollback_installation() {
  local index target backup
  local failed=0

  [[ $ROLLBACK_ACTIVE == "true" ]] || return 0
  ROLLBACK_ACTIVE=false
  warn "正在恢复本次安装前的配置……"

  for ((index = ${#ROLLBACK_TARGETS[@]} - 1; index >= 0; index--)); do
    target=${ROLLBACK_TARGETS[index]}
    backup=${ROLLBACK_BACKUPS[index]}
    if [[ -n $backup ]]; then
      if [[ ! -e $backup && ! -L $backup ]]; then
        warn "备份缺失，保留当前文件而不删除: ${target}"
        failed=1
        continue
      fi
      if ! restore_backup_file "$backup" "$target"; then
        warn "备份恢复失败，当前文件和备份均已保留: ${target}"
        failed=1
      fi
    else
      if ! rm -f -- "$target"; then
        warn "无法移除本次安装创建的文件: ${target}"
        failed=1
      fi
    fi
  done

  if [[ $SERVICE_STATE_DIRTY == true ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || { failed=1; warn "systemd 重新加载失败。"; }
    restore_service_state "$SERVICE_NAME" "$EDGE_WAS_ACTIVE" "$EDGE_WAS_ENABLED" || failed=1
    restore_service_state nginx "$NGINX_WAS_ACTIVE" "$NGINX_WAS_ENABLED" || failed=1
    restore_service_state "$TUNNEL_SERVICE_NAME" "$TUNNEL_WAS_ACTIVE" "$TUNNEL_WAS_ENABLED" || failed=1
  fi
  if ((failed)); then
    warn "部分文件或服务未能回滚，请根据上方信息手动检查。"
  elif [[ -n $BACKUP_DIR ]]; then
    warn "已完成回滚，备份文件保留在 ${BACKUP_DIR}。"
  else
    warn "已完成回滚。"
  fi
  return "$failed"
}

backup_file() {
  local path=$1
  local backup="" existing_target
  [[ ! -e $path || -f $path || -L $path ]] || die "托管文件路径不是普通文件或符号链接: ${path}"
  for existing_target in "${ROLLBACK_TARGETS[@]}"; do
    [[ $existing_target != "$path" ]] || return 0
  done
  if [[ -e $path || -L $path ]]; then
    if [[ -z $BACKUP_DIR ]]; then
      [[ ! -L $BACKUP_ROOT ]] || die "备份目录不能是符号链接: ${BACKUP_ROOT}"
      mkdir -p -m 0700 "$BACKUP_ROOT"
      chmod 0700 "$BACKUP_ROOT"
      BACKUP_DIR=$(mktemp -d "${BACKUP_ROOT}/install.XXXXXXXX")
    fi
    backup=$(mktemp "${BACKUP_DIR}/file.XXXXXXXX")
    cp --archive --no-dereference --remove-destination "$path" "$backup"
    printf '%s\t%s\n' "$backup" "$path" >>"${BACKUP_DIR}/paths.tsv"
  fi

  ROLLBACK_TARGETS+=("$path")
  ROLLBACK_BACKUPS+=("$backup")
  ROLLBACK_ACTIVE=true
}

install_managed_file() (
  local owner=$1
  local group=$2
  local mode=$3
  local source=$4
  local destination=$5
  local stage_dir=""
  trap - ERR
  trap 'cleanup_file_stage "$stage_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  [[ $destination == /* && $destination != */ ]] || return 1
  [[ ! -e $destination || -f $destination || -L $destination ]] || return 1
  stage_dir=$(mktemp -d "${destination%/*}/.edge-stage.XXXXXXXX") || return 1
  install -o "$owner" -g "$group" -m "$mode" "$source" "${stage_dir}/payload" || return 1
  # Same-filesystem rename also supports source == destination and live binaries.
  mv --force --no-target-directory -- "${stage_dir}/payload" "$destination"
)

install_sing_box() {
  local arch expected_hash actual_hash archive extract_dir source_bin url

  read -r arch expected_hash < <(detect_arch)
  TEMP_DIR=${TEMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/edge-install.XXXXXXXX")}
  archive="${TEMP_DIR}/sing-box.tar.gz"
  extract_dir="${TEMP_DIR}/extract"
  url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${arch}.tar.gz"

  info "下载 sing-box ${SING_BOX_VERSION} 官方 ${arch} 发布包……"
  download_file "$url" "$archive"
  actual_hash=$(sha256_file "$archive")
  [[ ${actual_hash,,} == "$expected_hash" ]] || \
    die "sing-box 校验失败。期望 ${expected_hash}，实际 ${actual_hash}。"

  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir"
  source_bin="${extract_dir}/sing-box-${SING_BOX_VERSION}-linux-${arch}/sing-box"
  [[ -f $source_bin ]] || die "发布包结构不符合预期。"

  install -d -m 0755 "$(dirname "$SING_BOX_BIN")"
  backup_file "$SING_BOX_BIN"
  install_managed_file root root 0755 "$source_bin" "$SING_BOX_BIN"
  success "sing-box 官方发布包校验并安装完成。"
}

install_xray() {
  local arch expected_hash archive extract_dir
  read -r arch expected_hash < <(detect_xray_arch)
  TEMP_DIR=${TEMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/edge-install.XXXXXXXX")}
  archive="${TEMP_DIR}/xray.zip"
  extract_dir="${TEMP_DIR}/xray"
  info "下载 Xray ${XRAY_VERSION} 官方 ${arch} 发布包……"
  download_file "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${arch}.zip" "$archive"
  [[ $(sha256_file "$archive") == "$expected_hash" ]] || die "Xray 发布包 SHA-256 校验失败。"
  mkdir -p "$extract_dir"
  unzip -q "$archive" xray -d "$extract_dir"
  [[ -f ${extract_dir}/xray ]] || die "Xray 发布包结构不符合预期。"
  install -d -m 0755 "$(dirname "$SING_BOX_BIN")"
  backup_file "$SING_BOX_BIN"
  install_managed_file root root 0755 "${extract_dir}/xray" "$SING_BOX_BIN"
  success "Xray 官方发布包校验并安装完成。"
}

validate_vless_keys() {
  # Use the short X25519 authentication pair from the pinned xray vlessenc.
  # Its ephemeral key exchange also uses ML-KEM; this is not PQ authentication.
  [[ $VLESS_DECRYPTION =~ ^mlkem768x25519plus\.native\.600s\.[A-Za-z0-9_-]{43}$ ]] &&
    [[ $VLESS_ENCRYPTION =~ ^mlkem768x25519plus\.native\.0rtt\.[A-Za-z0-9_-]{43}$ ]]
}

prepare_vless_encryption() {
  local generated
  [[ $PROXY_MODE == vless-xhttp-encryption ]] || return 0
  if [[ $VLESS_DECRYPTION == none && $VLESS_ENCRYPTION == none ]]; then
    generated=$("$SING_BOX_BIN" vlessenc) || die "生成 VLESS Encryption 密钥失败。"
    VLESS_DECRYPTION=$(awk -F '"' '/^"decryption":/ { print $4; exit }' <<<"$generated")
    VLESS_ENCRYPTION=$(awk -F '"' '/^"encryption":/ { print $4; exit }' <<<"$generated")
    unset generated
  fi
  validate_vless_keys || die "Xray 返回的 VLESS Encryption 密钥格式不符合预期。"
}

render_core_configuration() {
  if [[ $PROXY_MODE == vmess-ws ]]; then
    render_file "${TEMPLATE_DIR}/sing-box.json.tpl" "$1"
  else
    render_file "${TEMPLATE_DIR}/xray.json.tpl" "$1"
  fi
}

check_core_configuration() {
  if [[ $PROXY_MODE == vmess-ws ]]; then
    "$SING_BOX_BIN" check -c "$1"
  else
    "$SING_BOX_BIN" run -test -config "$1"
  fi
}

render_file() {
  local template=$1
  local destination=$2
  local location_template="${TEMPLATE_DIR}/nginx-ws-location.conf.tpl"
  local core_args="run -c"
  if [[ $PROXY_MODE != vmess-ws ]]; then
    location_template="${TEMPLATE_DIR}/nginx-xhttp-location.conf.tpl"
    core_args="run -config"
  fi

  awk -v fragment="$location_template" '
    /\{\{PROXY_LOCATION\}\}/ {
      while ((result = getline line < fragment) > 0) print line
      if (result < 0) exit 1
      close(fragment)
      next
    }
    { print }
  ' "$template" | sed \
    -e "s|{{UUID}}|${CUSTOM_UUID}|g" \
    -e "s|{{WS_PATH}}|${WS_PATH}|g" \
    -e "s|{{PUBLIC_DOMAIN}}|${PUBLIC_DOMAIN}|g" \
    -e "s|{{ORIGIN_PORT}}|${ORIGIN_PORT}|g" \
    -e "s|{{SING_BOX_PORT}}|${SING_BOX_PORT}|g" \
    -e "s|{{SITE_ROOT}}|${SITE_ROOT}|g" \
    -e "s|{{TLS_CERT_PATH}}|${TLS_CERT_PATH}|g" \
    -e "s|{{TLS_KEY_PATH}}|${TLS_KEY_PATH}|g" \
    -e "s|{{SING_BOX_BIN}}|${SING_BOX_BIN}|g" \
    -e "s|{{CORE_EXEC_ARGS}}|${core_args}|g" \
    -e "s|{{VLESS_DECRYPTION}}|${VLESS_DECRYPTION}|g" \
    -e "s|{{CONFIG_PATH}}|${CONFIG_PATH}|g" \
    -e "s|{{MANAGER_DIR}}|${MANAGER_DIR}|g" \
    -e "s|{{CLOUDFLARED_BIN}}|${CLOUDFLARED_BIN}|g" \
    -e "s|{{TOKEN_FILE}}|${TOKEN_PATH}|g" \
    -e "s|{{SITE_NONCE}}|${SITE_NONCE}|g" \
    -e "s|{{SITE_HUE}}|${SITE_HUE}|g" \
    -e "s|{{SITE_GRID_SIZE}}|${SITE_GRID_SIZE}|g" \
    -e "s|{{SITE_TITLE}}|${SITE_TITLE}|g" \
    -e "s|{{SITE_RAIL}}|${SITE_RAIL}|g" \
    -e "s|{{SITE_EYEBROW}}|${SITE_EYEBROW}|g" \
    -e "s|{{SITE_HEADING}}|${SITE_HEADING}|g" \
    -e "s|{{SITE_SUMMARY}}|${SITE_SUMMARY}|g" \
    -e "s|{{SITE_STATE}}|${SITE_STATE}|g" \
    >"$destination"
}

render_site() {
  local destination=$1

  if [[ -n "$SITE_INDEX_FILE" ]]; then
    cp -- "$SITE_INDEX_FILE" "$destination"
  elif [[ -s ${SITE_ROOT}/index.html ]]; then
    cp -- "${SITE_ROOT}/index.html" "$destination"
  else
    prepare_site_profile
    render_file "${TEMPLATE_DIR}/index.html" "$destination"
    ! grep -Eq '\{\{SITE_[A-Z_]+\}\}' "$destination" || die "伪装页模板渲染不完整。"
  fi
}

write_configuration() {
  local nginx_template rendered_config rendered_nginx rendered_service rendered_site rendered_tunnel

  TEMP_DIR=${TEMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/edge-install.XXXXXXXX")}
  rendered_config="${TEMP_DIR}/config.json"
  rendered_nginx="${TEMP_DIR}/nginx.conf"
  rendered_service="${TEMP_DIR}/edge-router.service"
  rendered_site="${TEMP_DIR}/index.html"
  rendered_tunnel="${TEMP_DIR}/edge-tunnel.service"

  render_core_configuration "$rendered_config"
  if [[ $DEPLOY_MODE == "tunnel" ]]; then
    nginx_template="${TEMPLATE_DIR}/nginx-tunnel.conf.tpl"
  else
    nginx_template="${TEMPLATE_DIR}/nginx-direct.conf.tpl"
  fi
  render_file "$nginx_template" "$rendered_nginx"
  render_file "${TEMPLATE_DIR}/edge-router.service.tpl" "$rendered_service"
  render_site "$rendered_site"

  check_core_configuration "$rendered_config"

  install -d -o root -g edge-router -m 0750 "$CONFIG_DIR"
  install -d -o root -g root -m 0755 "$SITE_ROOT"
  install -d -o root -g root -m 0755 "$(dirname "$NGINX_CONFIG")"

  if [[ $PROXY_MODE == vless-xhttp-encryption ]]; then
    validate_vless_keys || die "VLESS Encryption 密钥未准备好。"
    printf '{"decryption":"%s","encryption":"%s"}\n' "$VLESS_DECRYPTION" "$VLESS_ENCRYPTION" >"${TEMP_DIR}/vless-keys.json"
    backup_file "$ENCRYPTION_PATH"
    install_managed_file root root 0600 "${TEMP_DIR}/vless-keys.json" "$ENCRYPTION_PATH"
  fi

  backup_file "$CONFIG_PATH"
  backup_file "$NGINX_CONFIG"
  backup_file "${SITE_ROOT}/index.html"
  backup_file "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
  install_managed_file root edge-router 0640 "$rendered_config" "$CONFIG_PATH"
  install_managed_file root root 0644 "$rendered_nginx" "$NGINX_CONFIG"
  install_managed_file root root 0644 "$rendered_site" "${SITE_ROOT}/index.html"
  install_managed_file root root 0644 "$rendered_service" "${SYSTEMD_DIR}/${SERVICE_NAME}.service"

  printf '{"proxy_mode":"%s","deploy_mode":"%s","public_domain":"%s","origin_port":%s}\n' \
    "$PROXY_MODE" "$DEPLOY_MODE" "$PUBLIC_DOMAIN" "$ORIGIN_PORT" >"${TEMP_DIR}/install-state.json"
  backup_file "$STATE_PATH"
  install_managed_file root root 0600 "${TEMP_DIR}/install-state.json" "$STATE_PATH"

  if [[ $DEPLOY_MODE == "direct" ]]; then
    install -d -o root -g root -m 0700 "${CONFIG_DIR}/tls"
    backup_file "$TLS_CERT_PATH"
    backup_file "$TLS_KEY_PATH"
    install_managed_file root root 0600 "$TLS_CERT_FILE" "$TLS_CERT_PATH"
    install_managed_file root root 0600 "$TLS_KEY_FILE" "$TLS_KEY_PATH"
  else
    backup_file "$TOKEN_PATH"
    install_managed_file edge-router edge-router 0400 "$TUNNEL_TOKEN_FILE" "$TOKEN_PATH"
    render_file "${TEMPLATE_DIR}/edge-tunnel.service.tpl" "$rendered_tunnel"
    backup_file "${SYSTEMD_DIR}/${TUNNEL_SERVICE_NAME}.service"
    install_managed_file root root 0644 "$rendered_tunnel" "${SYSTEMD_DIR}/${TUNNEL_SERVICE_NAME}.service"
  fi
}

check_manager_destination() {
  if [[ -e $COMMAND_PATH || -L $COMMAND_PATH ]]; then
    [[ -f $COMMAND_PATH && ! -L $COMMAND_PATH ]] &&
      grep -Fqx '# fczd: ibmfree managed entry' "$COMMAND_PATH" || die "${COMMAND_PATH} 已被其他程序使用，未覆盖。"
  fi
  [[ ! -L $MANAGER_DIR && ! -L ${MANAGER_DIR}/templates ]] || die "管理器目录不能是符号链接。"
  if [[ -e $MANAGER_DIR ]]; then
    [[ -d $MANAGER_DIR && -f ${MANAGER_DIR}/.fczd-managed ]] &&
      grep -Fqx 'ibmfree-fczd-v1' "${MANAGER_DIR}/.fczd-managed" || die "${MANAGER_DIR} 不是本项目的管理器目录，未覆盖。"
  fi
}

install_management() {
  local name rendered_command
  check_manager_destination
  [[ -d $MANAGER_DIR ]] || MANAGER_CREATED=true
  install -d -o root -g root -m 0755 "$MANAGER_DIR" "${MANAGER_DIR}/templates" "${COMMAND_PATH%/*}"
  backup_file "${MANAGER_DIR}/install.sh"
  install_managed_file root root 0644 "${SCRIPT_DIR}/install.sh" "${MANAGER_DIR}/install.sh"
  for name in "${MANAGED_TEMPLATES[@]}"; do
    backup_file "${MANAGER_DIR}/templates/${name}"
    install_managed_file root root 0644 "${TEMPLATE_DIR}/${name}" "${MANAGER_DIR}/templates/${name}"
  done
  backup_file "${MANAGER_DIR}/.fczd-managed"
  printf 'ibmfree-fczd-v1\n' >"${TEMP_DIR}/manager.marker"
  install_managed_file root root 0644 "${TEMP_DIR}/manager.marker" "${MANAGER_DIR}/.fczd-managed"
  rendered_command="${TEMP_DIR}/fczd"
  render_file "${TEMPLATE_DIR}/fczd-command.tpl" "$rendered_command"
  backup_file "$COMMAND_PATH"
  install_managed_file root root 0755 "$rendered_command" "$COMMAND_PATH"
}

write_client_link() {
  local client_json encoded_link client_uri

  if [[ $PROXY_MODE == vmess-ws ]]; then
    client_json=$(printf \
    '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","fp":"chrome"}' \
    "$PUBLIC_DOMAIN" "$PUBLIC_DOMAIN" "$CUSTOM_UUID" "$PUBLIC_DOMAIN" "$WS_PATH" "$PUBLIC_DOMAIN")
    encoded_link=$(printf '%s' "$client_json" | base64 | tr -d '\r\n')
    client_uri="vmess://${encoded_link}"
  else
    # All values are validated ASCII. Encode slashes in the path for URI clients.
    client_uri="vless://${CUSTOM_UUID}@${PUBLIC_DOMAIN}:443?encryption=${VLESS_ENCRYPTION}&security=tls&sni=${PUBLIC_DOMAIN}&fp=chrome&type=xhttp&host=${PUBLIC_DOMAIN}&path=${WS_PATH//\//%2F}&mode=packet-up#${PUBLIC_DOMAIN}"
  fi
  backup_file "$CLIENT_PATH"
  printf '%s\n' "$client_uri" | install_managed_file root root 0600 /dev/stdin "$CLIENT_PATH"
}

local_http_request() {
  local path=$1
  shift
  # Ignore shell proxy settings and ~/.curlrc for loopback-only diagnostics.
  if [[ $DEPLOY_MODE == "tunnel" ]]; then
    curl --disable --noproxy '*' --silent --http1.1 --output /dev/null \
      --connect-timeout 2 --max-time 3 --header "Host: ${PUBLIC_DOMAIN}" \
      "$@" "http://127.0.0.1:${ORIGIN_PORT}${path}"
  else
    # This checks only the local route, including Origin CA certificates.
    curl --disable --noproxy '*' --silent --http1.1 --insecure --output /dev/null \
      --connect-timeout 2 --max-time 3 --resolve "${PUBLIC_DOMAIN}:443:127.0.0.1" \
      "$@" "https://${PUBLIC_DOMAIN}${path}"
  fi
}

check_local_site() {
  local attempt status="" headers="" curl_status=0
  TEMP_DIR=${TEMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/edge-install.XXXXXXXX")}
  headers="${TEMP_DIR}/websocket.headers"

  for attempt in 1 2 3 4 5; do
    status=$(local_http_request / --write-out '%{http_code}') || status="000"
    if [[ $status == "200" ]]; then
      if [[ $PROXY_MODE != vmess-ws ]]; then
        # A real packet-up POST checks nginx -> Xray, not just the static page.
        # This intentionally does not claim UUID/Encryption or public TLS health.
        status=$(local_http_request "${WS_PATH}/$(generate_uuid)/0" \
          --request POST --data-binary '' \
          --header "Referer: https://${PUBLIC_DOMAIN}/?x_padding=$(printf '%100s' '' | tr ' ' X)" \
          --write-out '%{http_code}') || status="000"
        [[ $status != 200 ]] || return 0
        ((attempt == 5)) || sleep 1
        continue
      fi
      : >"$headers"
      curl_status=0
      local_http_request "$WS_PATH" --dump-header "$headers" \
        --header 'Connection: Upgrade' --header 'Upgrade: websocket' \
        --header 'Sec-WebSocket-Version: 13' \
        --header 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' || curl_status=$?

      # curl may time out after a successful upgrade because the socket stays open.
      if ((curl_status == 0 || curl_status == 28)) &&
        grep -Eiq '^HTTP/1\.1 101([[:space:]]|$)' "$headers" &&
        grep -Eiq '^Upgrade:[[:space:]]*websocket[[:space:]]*$' "$headers" &&
        grep -Eiq '^Connection:[[:space:]]*([^,]+,[[:space:]]*)*upgrade([[:space:]]*,|[[:space:]]*$)' "$headers" &&
        awk -F ':' '
          tolower($1) == "sec-websocket-accept" {
            value = substr($0, index($0, ":") + 1)
            gsub(/^[ \t]+|[ \t\r]+$/, "", value)
            if (value == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") valid = 1
          }
          END { exit !valid }
        ' "$headers"; then
        return 0
      fi
    fi
    ((attempt == 5)) || sleep 1
  done

  die "本地 HTTP/代理传输检查失败（HTTP: ${status}）。请检查 edge-router/nginx 服务和监听端口；未确认公网连通。"
}

warn_extra_tcp_listeners() {
  local listeners="" unit main_pid="" state recv_queue send_queue endpoint peer processes host port seen_listener
  local -a units=("$SERVICE_NAME" nginx)
  [[ $DEPLOY_MODE != tunnel ]] || units+=("$TUNNEL_SERVICE_NAME")
  if ! listeners=$(ss -H -lntp 2>/dev/null); then
    warn "无法检查额外 TCP 监听；请手动运行 sudo ss -lntp 核对公开入口。"
    return 0
  fi
  for unit in "${units[@]}"; do
    if ! main_pid=$(systemctl show "$unit" --property=MainPID --value 2>/dev/null) ||
      [[ ! $main_pid =~ ^[1-9][0-9]*$ ]]; then
      warn "无法确认 ${unit} 的进程，未完成该服务的额外监听检查。"
      continue
    fi
    seen_listener=false
    while read -r state recv_queue send_queue endpoint peer processes; do
      [[ $processes == *"pid=${main_pid},"* ]] || continue
      seen_listener=true
      host=${endpoint%:*}
      host=${host#[}
      host=${host%]}
      port=${endpoint##*:}
      case "$host" in
        127.* | ::1 | 0:0:0:0:0:0:0:1 | ::ffff:127.*) continue ;;
      esac
      [[ $unit != nginx || $DEPLOY_MODE != direct || $port != 443 ]] || continue
      warn "${unit} 存在额外非回环 TCP 监听: ${endpoint}。请核对站点和防火墙；安装器未关闭该入口。"
    done <<<"$listeners"
    [[ $seen_listener == true ]] || warn "未取得 ${unit} 可归属的 TCP 监听信息，无法确认其绑定范围。"
  done
}

activate_services() {
  local nginx_dump

  nginx -t
  nginx_dump=$(nginx -T 2>&1)
  [[ $nginx_dump == *"configuration file ${NGINX_CONFIG}:"* ]] || \
    die "nginx 主配置未包含 ${NGINX_CONFIG}。"

  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
    if [[ $DEPLOY_MODE == "tunnel" ]]; then
      systemd-analyze verify "${SYSTEMD_DIR}/${TUNNEL_SERVICE_NAME}.service"
    fi
  fi

  SERVICE_STATE_DIRTY=true
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" nginx >/dev/null
  systemctl restart "$SERVICE_NAME"

  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl start nginx
  fi

  if [[ $DEPLOY_MODE == "tunnel" ]]; then
    systemctl enable "$TUNNEL_SERVICE_NAME" >/dev/null
    systemctl restart "$TUNNEL_SERVICE_NAME"
  else
    systemctl disable --now "$TUNNEL_SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  systemctl is-active --quiet "$SERVICE_NAME" || die "${SERVICE_NAME} 未成功启动。"
  systemctl is-active --quiet nginx || die "nginx 未成功启动。"
  if [[ $DEPLOY_MODE == "tunnel" ]]; then
    systemctl is-active --quiet "$TUNNEL_SERVICE_NAME" || die "${TUNNEL_SERVICE_NAME} 未成功启动。"
  fi

  check_local_site
  warn_extra_tcp_listeners
  ROLLBACK_ACTIVE=false
}

show_summary() {
  printf '\n%b\n' "${COLOR_GREEN}部署完成${COLOR_RESET}"
  printf '  公网域名: https://%s\n' "$PUBLIC_DOMAIN"
  printf '  模式: %s\n' "$DEPLOY_MODE"
  printf '  客户端配置: %s（仅 root 可读）\n' "$CLIENT_PATH"
  printf '  核心配置: %s\n' "$CONFIG_PATH"
  printf '  管理命令: fczd\n'
  if [[ -n $BACKUP_DIR ]]; then
    printf '  本次备份: %s（仅 root 可读；paths.tsv 记录原路径）\n' "$BACKUP_DIR"
  fi
  printf '  代理方案: %s\n' "$PROXY_MODE"
  printf '  代理路径: %s…%s\n' "${WS_PATH:0:12}" "${WS_PATH: -4}"
  printf '\n%b\n' "${COLOR_GREEN}客户端链接:${COLOR_RESET}"
  cat "$CLIENT_PATH"

  if [[ $DEPLOY_MODE == "tunnel" ]]; then
    warn "请确认 Cloudflare Tunnel 的 Published application 指向 http://127.0.0.1:${ORIGIN_PORT}。"
  else
    warn "direct 模式请确保域名已解析到本机，并仅开放必要的 443/TCP 入站。"
  fi
  warn "已验证本地 HTTP/代理传输；仍需导入链接确认公网 Tunnel/TLS、UUID 和可选 Encryption 连通。"
}

installed_proxy_mode() {
  local protocols decryption
  [[ -s $CONFIG_PATH ]] || return 1
  protocols=$(read_json_string "$CONFIG_PATH" protocol)
  if [[ ${protocols%%$'\n'*} == vless ]]; then
    [[ $(read_json_string "$CONFIG_PATH" network) == xhttp ]] || return 1
    decryption=$(read_json_string "$CONFIG_PATH" decryption)
    [[ -n $decryption && $decryption != *$'\n'* ]] || return 1
    if [[ $decryption == none ]]; then printf 'vless-xhttp'; else printf 'vless-xhttp-encryption'; fi
  elif validate_uuid "$(read_json_string "$CONFIG_PATH" uuid)"; then
    printf 'vmess-ws'
  else
    return 1
  fi
}

installed_deploy_mode() {
  local mode
  mode=$(read_json_string "$STATE_PATH" deploy_mode)
  if [[ $mode == tunnel || $mode == direct ]]; then
    printf '%s' "$mode"
  elif [[ -r $NGINX_CONFIG ]] && grep -Eq 'listen[[:space:]]+127\.0\.0\.1:' "$NGINX_CONFIG"; then
    printf tunnel
  elif [[ -r $NGINX_CONFIG ]] && grep -Eq 'listen[[:space:]]+443[[:space:]]+ssl' "$NGINX_CONFIG"; then
    printf direct
  else
    return 1
  fi
}

installed_origin_port() {
  local mode=${1,,} port
  port=$(read_json_number "$STATE_PATH" origin_port)
  if [[ -z $port && $mode == tunnel && -r $NGINX_CONFIG ]]; then
    port=$(sed -nE 's/^[[:space:]]*listen 127\.0\.0\.1:([0-9]+).*;/\1/p' "$NGINX_CONFIG" | sort -u)
  fi
  port=${port:-8001}
  validate_port "$port" || return 1
  printf '%s' "$((10#$port))"
}

load_management_configuration() {
  PROXY_MODE=$(installed_proxy_mode) || die "没有可识别的已安装配置，请先安装或检查 ${CONFIG_PATH}。"
  DEPLOY_MODE=$(installed_deploy_mode) || die "无法识别部署模式，请检查本项目 Nginx 配置。"
  if [[ -z $PUBLIC_DOMAIN ]]; then
    PUBLIC_DOMAIN=$(read_json_string "$STATE_PATH" public_domain)
    if [[ -z $PUBLIC_DOMAIN && -r $NGINX_CONFIG ]]; then
      PUBLIC_DOMAIN=$(awk '$1 == "server_name" && $2 != "_;" { sub(/;$/, "", $2); print $2; exit }' "$NGINX_CONFIG")
    fi
  fi
  WS_PATH=$(read_json_string "$CONFIG_PATH" path)
  if [[ $PROXY_MODE == vmess-ws ]]; then
    SING_BOX_PORT=$(read_json_number "$CONFIG_PATH" listen_port)
  else
    SING_BOX_PORT=$(read_json_number "$CONFIG_PATH" port)
  fi
  ORIGIN_PORT=$(installed_origin_port "$DEPLOY_MODE") || die "已安装配置的入口端口无效。"
  validate_domain "$PUBLIC_DOMAIN" && validate_ws_path "$WS_PATH" &&
    validate_port "$SING_BOX_PORT" && validate_port "$ORIGIN_PORT" || die "已安装配置的域名、路径或端口无效。"
}

list_installed() {
  local profile="" mode="" domain="" selected unit state version=""
  profile=$(installed_proxy_mode) || true
  mode=$(installed_deploy_mode) || true
  domain=$(read_json_string "$STATE_PATH" public_domain)
  printf '代理方案（同一时间只安装一种）：\n'
  for selected in vmess-ws vless-xhttp vless-xhttp-encryption; do
    state="未安装"
    if [[ $selected == "$profile" ]]; then
      if [[ -x $SING_BOX_BIN ]]; then state="已安装"; else state="配置存在，核心缺失"; fi
    fi
    printf '  %-26s %s\n' "$selected" "$state"
  done
  if [[ -z $profile && -e $CONFIG_PATH ]]; then warn "核心配置存在但无法识别，请检查 ${CONFIG_PATH}。"; fi
  [[ -z $mode ]] || printf '部署模式: %s\n' "$mode"
  if validate_domain "$domain"; then printf '公网域名: %s\n' "$domain"; fi
  if [[ -x $SING_BOX_BIN ]]; then
    version=$("$SING_BOX_BIN" version 2>/dev/null) || version="版本读取失败"
    printf '核心: %s\n' "${version%%$'\n'*}"
  fi
  for unit in "$SERVICE_NAME" "$TUNNEL_SERVICE_NAME" nginx; do
    state=$(systemctl is-active "$unit" 2>/dev/null) || true
    printf '  %-12s %s\n' "$unit" "${state:-unknown}"
  done
  printf '管理入口: %s\n' "$COMMAND_PATH"
}

manage_install() {
  local requested_profile=${1:-$PROXY_MODE}
  local requested_path=$WS_PATH requested_core_port=$SING_BOX_PORT
  preflight_environment
  acquire_install_lock
  if [[ -s $CONFIG_PATH ]]; then
    load_management_configuration
    WS_PATH=${requested_path:-$WS_PATH}
    SING_BOX_PORT=${requested_core_port:-$SING_BOX_PORT}
    DEPLOY_MODE=${REQUESTED_DEPLOY_MODE:-$DEPLOY_MODE}
    DEPLOY_MODE=${DEPLOY_MODE,,}
    ORIGIN_PORT=${REQUESTED_ORIGIN_PORT:-$ORIGIN_PORT}
    if [[ $DEPLOY_MODE == tunnel && -z $TUNNEL_TOKEN_FILE && -s $TOKEN_PATH ]]; then
      TUNNEL_TOKEN_FILE=$TOKEN_PATH
    elif [[ $DEPLOY_MODE == direct ]]; then
      if [[ -z $TLS_CERT_FILE && -s $TLS_CERT_PATH ]]; then TLS_CERT_FILE=$TLS_CERT_PATH; fi
      if [[ -z $TLS_KEY_FILE && -s $TLS_KEY_PATH ]]; then TLS_KEY_FILE=$TLS_KEY_PATH; fi
    fi
  fi
  PROXY_MODE=$requested_profile
  main
}

manage_services() {
  local action=$1
  local unit
  preflight_environment
  acquire_install_lock
  if [[ $action != stop ]]; then
    load_management_configuration
    [[ -x $SING_BOX_BIN ]] || die "核心程序不存在，请重新安装。"
    check_core_configuration "$CONFIG_PATH"
    nginx -t
  fi
  capture_service_state
  ROLLBACK_ACTIVE=true
  SERVICE_STATE_DIRTY=true
  if [[ $action == stop ]]; then
    for unit in "$TUNNEL_SERVICE_NAME" "$SERVICE_NAME"; do
      if systemctl cat "$unit" >/dev/null 2>&1 || systemctl is-active --quiet "$unit"; then
        systemctl stop "$unit"
        if systemctl is-active --quiet "$unit"; then die "${unit} 未停止。"; fi
      fi
    done
  else
    systemctl "$action" "$SERVICE_NAME"
    if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl start nginx; fi
    if [[ $DEPLOY_MODE == tunnel ]]; then systemctl "$action" "$TUNNEL_SERVICE_NAME"; fi
    check_local_site
  fi
  ROLLBACK_ACTIVE=false
  SERVICE_STATE_DIRTY=false
  success "服务操作完成: ${action}"
}

manage_site() {
  local html_file=${1-}
  [[ -s $CONFIG_PATH && -d $SITE_ROOT ]] || die "请先安装。"
  read_value html_file "新的本地 HTML 首页路径"
  [[ -f $html_file && -s $html_file ]] || die "首页文件不存在或为空。"
  preflight_environment
  acquire_install_lock
  capture_service_state
  backup_file "${SITE_ROOT}/index.html"
  install_managed_file root root 0644 "$html_file" "${SITE_ROOT}/index.html"
  ROLLBACK_ACTIVE=false
  success "首页已更新。原首页备份保存在 ${BACKUP_DIR}。"
}

uninstall_deployment() {
  local confirmation="" target name unit
  local -a targets=(
    "$NGINX_CONFIG" "${SYSTEMD_DIR}/${SERVICE_NAME}.service" "${SYSTEMD_DIR}/${TUNNEL_SERVICE_NAME}.service"
    "$CONFIG_PATH" "$CLIENT_PATH" "$ENCRYPTION_PATH" "$STATE_PATH" "$TOKEN_PATH" "$TLS_CERT_PATH" "$TLS_KEY_PATH"
    "$SING_BOX_BIN" "$COMMAND_PATH" "${MANAGER_DIR}/install.sh" "${MANAGER_DIR}/.fczd-managed"
  )
  [[ ${1-} == '' || ${1-} == --yes ]] || die "卸载参数只接受 --yes。"
  check_manager_destination
  printf '将停止本项目服务，移除配置/密钥、Nginx 站点、核心和 fczd 管理入口。\n'
  printf '保留 Nginx/cloudflared 软件包、服务账户、静态站点目录、历史备份和系统日志。\n'
  if [[ ${1-} != --yes ]]; then
    read_value confirmation "输入 UNINSTALL 确认卸载"
    [[ $confirmation == UNINSTALL ]] || { info "已取消卸载。"; return 0; }
  fi
  preflight_environment
  acquire_install_lock
  check_manager_destination
  capture_service_state
  for name in "${MANAGED_TEMPLATES[@]}"; do targets+=("${MANAGER_DIR}/templates/${name}"); done
  # Snapshot every managed file before stopping anything. The normal EXIT/signal
  # rollback restores files and service states if a removal/reload fails.
  for target in "${targets[@]}"; do backup_file "$target"; done
  for unit in "$TUNNEL_SERVICE_NAME" "$SERVICE_NAME"; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      SERVICE_STATE_DIRTY=true
      systemctl disable --now "$unit"
      if systemctl is-active --quiet "$unit"; then die "${unit} 未停止，已中止卸载。"; fi
    fi
  done
  rm -f -- "$NGINX_CONFIG"
  if command -v nginx >/dev/null 2>&1; then nginx -t; fi
  if [[ $NGINX_WAS_ACTIVE == true ]]; then SERVICE_STATE_DIRTY=true; systemctl reload nginx; fi
  for target in "${targets[@]}"; do rm -f -- "$target"; done
  SERVICE_STATE_DIRTY=true
  systemctl daemon-reload
  ROLLBACK_ACTIVE=false
  rmdir -- "${CONFIG_DIR}/tls" "$CONFIG_DIR" "${MANAGER_DIR}/templates" "$MANAGER_DIR" 2>/dev/null || true
  success "卸载完成。备份保留在 ${BACKUP_DIR:-$BACKUP_ROOT}；静态站点保留在 ${SITE_ROOT}。"
}

manager_menu() {
  local choice command
  while true; do
    printf '\nFCZD 管理菜单\n1) 安装 / 切换方案\n2) 列出已安装\n3) 服务状态\n4) 重启\n5) 停止\n6) 启动\n7) 检查配置与本地链路\n8) 显示客户端链接\n9) 更换网站首页\n10) 卸载\n0) 退出\n'
    choice=""
    read_value choice "请选择" 0
    case $choice in
      0) return 0 ;; 1) command=install ;; 2) command=list ;; 3) command=status ;;
      4) command=restart ;; 5) command=stop ;; 6) command=start ;; 7) command=check ;;
      8) command=link ;; 9) command=site ;; 10) command=uninstall ;;
      *) warn "无效选项。"; continue ;;
    esac
    # A fresh Bash keeps errexit/rollback active even though this parent handles
    # a failed command and returns to the menu. Never call mutations in `if fn`.
    if ! bash "${SCRIPT_DIR}/install.sh" --manage "$command"; then warn "操作失败，请检查上方信息。"; fi
    if [[ $command == uninstall && ! -e $COMMAND_PATH && ! -e $CONFIG_PATH ]]; then return 0; fi
  done
}

validate_manager_arguments() {
  local action=${1:-menu}
  (($# == 0)) || shift
  case $action in
    install)
      (($# <= 1)) || die "用法: fczd install [1/2/3]"
      if (($#)); then
        case $1 in 1 | 2 | 3 | vmess-ws | vless-xhttp | vless-xhttp-encryption) : ;; *) die "无效的代理方案: $1" ;; esac
      fi
      ;;
    site) (($# <= 1)) || die "用法: fczd site [HTML文件]" ;;
    uninstall)
      (($# <= 1)) && [[ ${1-} == '' || ${1-} == --yes ]] || die "用法: fczd uninstall [--yes]"
      ;;
    menu | list | status | start | stop | restart | check | link | help | --help | -h)
      (($# == 0)) || die "${action} 不接受额外参数。"
      ;;
    *) die "未知命令: ${action}。运行 fczd help 查看用法。" ;;
  esac
}

show_service_status() {
  local status=0
  # Status output is often copied to support chats. Keep journal history opt-in.
  systemctl --no-pager --full --lines=0 status "$SERVICE_NAME" "$TUNNEL_SERVICE_NAME" nginx || status=$?
  ((status == 0 || status == 3 || status == 4)) || return "$status"
}

manager_main() {
  local action=${1:-menu}
  validate_manager_arguments "$@"
  if [[ $action == help || $action == --help || $action == -h ]]; then
    printf 'fczd [menu|install [1/2/3]|list|status|start|stop|restart|check|link|site [HTML文件]|uninstall [--yes]]\n'
    return 0
  fi
  if ((EUID != 0)); then
    command -v sudo >/dev/null 2>&1 || die "请先 sudo -i 切换到 root，再运行 fczd。"
    exec sudo -- /bin/bash "${SCRIPT_DIR}/install.sh" --manage "$@"
  fi
  (($# == 0)) || shift
  case $action in
    menu) manager_menu ;;
    install) manage_install "$@" ;;
    list) list_installed ;;
    status)
      list_installed
      show_service_status
      ;;
    start | stop | restart) manage_services "$action" ;;
    check)
      preflight_environment
      acquire_install_lock
      load_management_configuration
      check_core_configuration "$CONFIG_PATH"
      check_local_site
      warn_extra_tcp_listeners
      success "本地检查通过；公网 Cloudflare/TLS 仍需客户端验证。"
      ;;
    link) [[ -s $CLIENT_PATH ]] || die "没有客户端链接，请先安装。"; cat "$CLIENT_PATH" ;;
    site) manage_site "$@" ;;
    uninstall) uninstall_deployment "$@" ;;
    *) die "未知命令: ${action}。运行 fczd help 查看用法。" ;;
  esac
}

main() {
  ((EUID == 0)) || die "请使用 sudo 运行此脚本。"
  [[ $(uname -s) == "Linux" ]] || die "仅支持 Linux。"
  preflight_environment
  check_manager_destination
  acquire_install_lock
  capture_service_state

  require_file "${TEMPLATE_DIR}/sing-box.json.tpl"
  require_file "${TEMPLATE_DIR}/xray.json.tpl"
  require_file "${TEMPLATE_DIR}/nginx-ws-location.conf.tpl"
  require_file "${TEMPLATE_DIR}/nginx-xhttp-location.conf.tpl"
  require_file "${TEMPLATE_DIR}/nginx-tunnel.conf.tpl"
  require_file "${TEMPLATE_DIR}/nginx-direct.conf.tpl"
  require_file "${TEMPLATE_DIR}/edge-router.service.tpl"
  require_file "${TEMPLATE_DIR}/edge-tunnel.service.tpl"
  require_file "${TEMPLATE_DIR}/index.html"
  require_file "${TEMPLATE_DIR}/fczd-command.tpl"

  install_packages
  collect_configuration
  preflight_ports
  if [[ $DEPLOY_MODE == "tunnel" ]]; then
    ensure_cloudflared
  fi
  create_service_user
  if [[ $PROXY_MODE == vmess-ws ]]; then
    install_sing_box
  else
    install_xray
  fi
  prepare_vless_encryption
  write_configuration
  write_client_link
  install_management
  activate_services
  show_summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  if [[ ${1-} == --manage ]]; then
    shift
    manager_main "$@"
  else
    main "$@"
  fi
fi
