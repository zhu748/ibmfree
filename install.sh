#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly SING_BOX_VERSION="1.13.19"
readonly CLOUDFLARED_VERSION="2026.8.2"
readonly CLOUDFLARED_RELEASE_TAG="cloudflared-${CLOUDFLARED_VERSION}-s390x"
readonly CLOUDFLARED_RELEASE_BASE="https://github.com/zhu748/ibmfree/releases/download/${CLOUDFLARED_RELEASE_TAG}"
readonly CLOUDFLARED_INSTALL_PATH="/usr/local/bin/cloudflared"
readonly SERVICE_NAME="edge-router"
readonly TUNNEL_SERVICE_NAME="edge-tunnel"
readonly CONFIG_DIR="/etc/edge-router"
readonly CONFIG_PATH="${CONFIG_DIR}/config.json"
readonly CLIENT_PATH="${CONFIG_DIR}/client.txt"
readonly TOKEN_PATH="${CONFIG_DIR}/tunnel.token"
readonly TLS_CERT_PATH="${CONFIG_DIR}/tls/origin.crt"
readonly TLS_KEY_PATH="${CONFIG_DIR}/tls/origin.key"
readonly SING_BOX_BIN="/usr/local/libexec/edge-router"
readonly SITE_ROOT="/var/www/edge-router"
readonly BACKUP_ROOT="/var/backups/edge-router"
readonly NGINX_CONFIG="/etc/nginx/conf.d/edge-router.conf"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMPLATE_DIR="${SCRIPT_DIR}/templates"

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_CYAN='\033[0;36m'
COLOR_RESET='\033[0m'

PUBLIC_DOMAIN="${PUBLIC_DOMAIN:-}"
DEPLOY_MODE="${DEPLOY_MODE:-tunnel}"
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
  printf '%b\n' "${COLOR_RED}安装在第 ${BASH_LINENO[0]} 行失败（退出码: ${exit_code}）。${COLOR_RESET}" >&2
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
  local attempts=0

  while ((attempts < 100)); do
    candidate=$((20000 + (((RANDOM << 1) ^ RANDOM) % 20000)))
    if ! ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$candidate$"; then
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

  curl --fail --location --silent --show-error \
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
  install -o root -g root -m 0755 "$binary" "$CLOUDFLARED_INSTALL_PATH"
  CLOUDFLARED_BIN=$CLOUDFLARED_INSTALL_PATH
  success "cloudflared s390x 发布包校验并安装完成。"
}

ensure_cloudflared() {
  local help_output=""

  if [[ -z "$CLOUDFLARED_BIN" ]]; then
    CLOUDFLARED_BIN=$(command -v cloudflared || true)
  fi

  if [[ -z "$CLOUDFLARED_BIN" ]]; then
    install_cloudflared_s390x
  fi

  [[ $CLOUDFLARED_BIN =~ ^/[A-Za-z0-9_./-]+$ ]] || die "cloudflared 路径包含不安全字符。"
  [[ -x $CLOUDFLARED_BIN ]] || die "cloudflared 不存在或不可执行: ${CLOUDFLARED_BIN}"
  help_output=$("$CLOUDFLARED_BIN" tunnel run --help 2>&1) || \
    die "cloudflared 无法执行，请检查二进制架构和文件权限。"
  [[ $help_output == *"--token-file"* ]] || \
    die "当前 cloudflared 版本不支持 --token-file，请升级。"
}

install_packages() {
  info "检查基础依赖……"

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates coreutils curl iproute2 nginx tar
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates coreutils curl iproute nginx tar
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates coreutils curl iproute nginx tar
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install ca-certificates coreutils curl iproute2 nginx tar
  else
    die "不支持的包管理器，请先安装 curl、tar、ca-certificates 和 nginx。"
  fi

  command -v curl >/dev/null 2>&1 || die "curl 安装失败。"
  command -v nginx >/dev/null 2>&1 || die "nginx 安装失败。"
  command -v ss >/dev/null 2>&1 || die "缺少 ss 命令（通常由 iproute2 提供）。"
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

  if [[ -e $CONFIG_PATH || -L $CONFIG_PATH ]]; then
    [[ -r $CONFIG_PATH && -s $CONFIG_PATH ]] || die "现有配置为空或不可读，已停止以保留原连接参数: ${CONFIG_PATH}"
    existing_uuid=$(read_json_string "$CONFIG_PATH" uuid)
    existing_path=$(read_json_string "$CONFIG_PATH" path)
    existing_port=$(read_json_number "$CONFIG_PATH" listen_port)

    validate_uuid "$existing_uuid" && validate_ws_path "$existing_path" && validate_port "$existing_port" || \
      die "无法唯一读取现有 UUID、WS 路径和端口，已停止；请检查 ${CONFIG_PATH}，不要直接删除旧配置。"

    if [[ -z "$WS_PATH" ]] && validate_ws_path "$existing_path"; then
      WS_PATH=$existing_path
    fi
    if [[ -z "$SING_BOX_PORT" ]] && validate_port "$existing_port"; then
      SING_BOX_PORT=$existing_port
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
  validate_ws_path "$WS_PATH" || die "WS_PATH 必须是 16-120 位安全路径，且不能以 / 结尾。"

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

  if systemctl cat "$unit" >/dev/null 2>&1; then
    if [[ $was_enabled == "true" ]]; then
      systemctl enable "$unit" >/dev/null 2>&1 || true
    else
      systemctl disable "$unit" >/dev/null 2>&1 || true
    fi

    if [[ $was_active == "true" ]]; then
      systemctl restart "$unit" >/dev/null 2>&1 || true
    else
      systemctl stop "$unit" >/dev/null 2>&1 || true
    fi
  else
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
  fi
}

restore_backup_file() {
  local backup=$1
  local target=$2
  local staged=""

  # Keep the live file intact until a same-directory backup copy is ready.
  staged=$(mktemp "${target}.restore.XXXXXXXX") || return 1
  if cp --archive --no-dereference --remove-destination --no-target-directory "$backup" "$staged" &&
    mv --force --no-target-directory "$staged" "$target"; then
    return 0
  fi
  rm -f -- "$staged"
  return 1
}

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

  systemctl daemon-reload >/dev/null 2>&1 || true
  restore_service_state "$SERVICE_NAME" "$EDGE_WAS_ACTIVE" "$EDGE_WAS_ENABLED"
  restore_service_state nginx "$NGINX_WAS_ACTIVE" "$NGINX_WAS_ENABLED"
  restore_service_state "$TUNNEL_SERVICE_NAME" "$TUNNEL_WAS_ACTIVE" "$TUNNEL_WAS_ENABLED"
  if ((failed)); then
    warn "部分文件未能回滚，请根据上方路径手动检查；已尝试恢复服务状态。"
  else
    warn "配置文件已恢复；已尝试恢复原服务状态，备份文件保留在 ${BACKUP_ROOT}。"
  fi
  return "$failed"
}

backup_file() {
  local path=$1
  local backup="" existing_target
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

install_managed_file() {
  local owner=$1
  local group=$2
  local mode=$3
  local source=$4
  local destination=$5

  if [[ -e $destination && $source -ef $destination ]]; then
    chown "$owner:$group" "$destination"
    chmod "$mode" "$destination"
  else
    install -o "$owner" -g "$group" -m "$mode" "$source" "$destination"
  fi
}

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
  install -o root -g root -m 0755 "$source_bin" "$SING_BOX_BIN"
  success "sing-box 官方发布包校验并安装完成。"
}

render_file() {
  local template=$1
  local destination=$2

  sed \
    -e "s|{{UUID}}|${CUSTOM_UUID}|g" \
    -e "s|{{WS_PATH}}|${WS_PATH}|g" \
    -e "s|{{PUBLIC_DOMAIN}}|${PUBLIC_DOMAIN}|g" \
    -e "s|{{ORIGIN_PORT}}|${ORIGIN_PORT}|g" \
    -e "s|{{SING_BOX_PORT}}|${SING_BOX_PORT}|g" \
    -e "s|{{SITE_ROOT}}|${SITE_ROOT}|g" \
    -e "s|{{TLS_CERT_PATH}}|${TLS_CERT_PATH}|g" \
    -e "s|{{TLS_KEY_PATH}}|${TLS_KEY_PATH}|g" \
    -e "s|{{SING_BOX_BIN}}|${SING_BOX_BIN}|g" \
    -e "s|{{CONFIG_PATH}}|${CONFIG_PATH}|g" \
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
    "$template" >"$destination"
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

  render_file "${TEMPLATE_DIR}/sing-box.json.tpl" "$rendered_config"
  if [[ $DEPLOY_MODE == "tunnel" ]]; then
    nginx_template="${TEMPLATE_DIR}/nginx-tunnel.conf.tpl"
  else
    nginx_template="${TEMPLATE_DIR}/nginx-direct.conf.tpl"
  fi
  render_file "$nginx_template" "$rendered_nginx"
  render_file "${TEMPLATE_DIR}/edge-router.service.tpl" "$rendered_service"
  render_site "$rendered_site"

  "$SING_BOX_BIN" check -c "$rendered_config"

  install -d -o root -g edge-router -m 0750 "$CONFIG_DIR"
  install -d -o root -g root -m 0755 "$SITE_ROOT"
  install -d -o root -g root -m 0755 "$(dirname "$NGINX_CONFIG")"

  backup_file "$CONFIG_PATH"
  backup_file "$NGINX_CONFIG"
  backup_file "${SITE_ROOT}/index.html"
  backup_file "${SYSTEMD_DIR}/${SERVICE_NAME}.service"
  install -o root -g edge-router -m 0640 "$rendered_config" "$CONFIG_PATH"
  install -o root -g root -m 0644 "$rendered_nginx" "$NGINX_CONFIG"
  install -o root -g root -m 0644 "$rendered_site" "${SITE_ROOT}/index.html"
  install -o root -g root -m 0644 "$rendered_service" "${SYSTEMD_DIR}/${SERVICE_NAME}.service"

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
    install -o root -g root -m 0644 "$rendered_tunnel" "${SYSTEMD_DIR}/${TUNNEL_SERVICE_NAME}.service"
  fi
}

write_client_link() {
  local client_json encoded_link

  client_json=$(printf \
    '{"v":"2","ps":"%s","add":"%s","port":"443","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","fp":"chrome"}' \
    "$PUBLIC_DOMAIN" "$PUBLIC_DOMAIN" "$CUSTOM_UUID" "$PUBLIC_DOMAIN" "$WS_PATH" "$PUBLIC_DOMAIN")
  encoded_link=$(printf '%s' "$client_json" | base64 | tr -d '\r\n')
  backup_file "$CLIENT_PATH"
  printf 'vmess://%s\n' "$encoded_link" | install -o root -g root -m 0600 /dev/stdin "$CLIENT_PATH"
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

  die "本地 HTTP/WebSocket 检查失败（首页 HTTP: ${status}）。请检查 edge-router/nginx 服务和监听端口；未确认公网连通。"
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
  ROLLBACK_ACTIVE=false
}

show_summary() {
  printf '\n%b\n' "${COLOR_GREEN}部署完成${COLOR_RESET}"
  printf '  公网域名: https://%s\n' "$PUBLIC_DOMAIN"
  printf '  模式: %s\n' "$DEPLOY_MODE"
  printf '  客户端配置: %s（仅 root 可读）\n' "$CLIENT_PATH"
  printf '  核心配置: %s\n' "$CONFIG_PATH"
  if [[ -n $BACKUP_DIR ]]; then
    printf '  本次备份: %s（仅 root 可读；paths.tsv 记录原路径）\n' "$BACKUP_DIR"
  fi
  printf '  WebSocket 路径: %s…%s\n' "${WS_PATH:0:12}" "${WS_PATH: -4}"
  printf '\n%b\n' "${COLOR_GREEN}VMess 链接:${COLOR_RESET}"
  cat "$CLIENT_PATH"

  if [[ $DEPLOY_MODE == "tunnel" ]]; then
    warn "请确认 Cloudflare Tunnel 的 Published application 指向 http://127.0.0.1:${ORIGIN_PORT}。"
  else
    warn "direct 模式请确保域名已解析到本机，并仅开放必要的 443/TCP 入站。"
  fi
  warn "已验证本地 HTTP/WebSocket；仍需使用客户端确认公网 Tunnel/TLS 和 VMess 认证连通。"
}

main() {
  ((EUID == 0)) || die "请使用 sudo 运行此脚本。"
  [[ $(uname -s) == "Linux" ]] || die "仅支持 Linux。"
  command -v systemctl >/dev/null 2>&1 || die "当前系统不使用 systemd。"
  capture_service_state

  require_file "${TEMPLATE_DIR}/sing-box.json.tpl"
  require_file "${TEMPLATE_DIR}/nginx-tunnel.conf.tpl"
  require_file "${TEMPLATE_DIR}/nginx-direct.conf.tpl"
  require_file "${TEMPLATE_DIR}/edge-router.service.tpl"
  require_file "${TEMPLATE_DIR}/edge-tunnel.service.tpl"
  require_file "${TEMPLATE_DIR}/index.html"

  install_packages
  collect_configuration
  if [[ $DEPLOY_MODE == "tunnel" ]]; then
    ensure_cloudflared
  fi
  create_service_user
  install_sing_box
  write_configuration
  write_client_link
  activate_services
  show_summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
