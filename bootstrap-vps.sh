#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly REPOSITORY_ARCHIVE="https://github.com/zhu748/ibmfree/archive/refs/heads/main.tar.gz"
TEMP_DIR=""

die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    case "$TEMP_DIR" in
      "${TMPDIR:-/tmp}"/ibmfree-bootstrap.*)
        find "$TEMP_DIR" -mindepth 1 -depth -delete 2>/dev/null || true
        rmdir "$TEMP_DIR" 2>/dev/null || true
        ;;
      *)
        printf '警告: 拒绝清理意外路径: %s\n' "$TEMP_DIR" >&2
        ;;
    esac
  fi
}

trap cleanup EXIT

download_repository() {
  local archive="${TEMP_DIR}/repository.tar.gz"
  local source_dir="${TEMP_DIR}/source"

  # Finish retries before extracting: a partial stream must never reach bash.
  curl --disable --fail --location --silent --show-error \
    --proto '=https' --proto-redir '=https' \
    --retry 3 --connect-timeout 15 --max-time 300 \
    --output "$archive" "$REPOSITORY_ARCHIVE" || die "仓库下载失败，尚未执行安装器；请稍后重试。"
  mkdir -p "$source_dir"
  tar -xzf "$archive" --strip-components=1 --no-same-owner -C "$source_dir" || \
    die "仓库归档无效，尚未执行安装器。"
  [[ -s ${source_dir}/install.sh && -d ${source_dir}/templates ]] || \
    die "仓库归档不完整，缺少安装器或模板。"
}

check_supported_arch() {
  case $(uname -m) in
    x86_64 | amd64 | aarch64 | arm64) : ;;
    s390x | s390)
      die "此入口用于 x86_64/AMD64 与 ARM64；s390x（IBM LinuxONE）请使用原有的一键入口 bootstrap.sh。"
      ;;
    *)
      die "不支持的系统架构: $(uname -m)。"
      ;;
  esac
}

main() {
  ((EUID == 0)) || die "请先执行 sudo -i 切换到 root，再运行一键安装命令。"
  [[ $(uname -s) == "Linux" ]] || die "仅支持 Linux。"
  check_supported_arch
  command -v curl >/dev/null 2>&1 || die "缺少 curl，请先通过系统包管理器安装。"
  command -v tar >/dev/null 2>&1 || die "缺少 tar，请先通过系统包管理器安装。"

  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ibmfree-bootstrap.XXXXXXXX")
  download_repository

  export DEPLOY_MODE=tunnel
  export ORIGIN_PORT=8001
  bash "${TEMP_DIR}/source/install.sh"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
