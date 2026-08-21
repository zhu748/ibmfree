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

((EUID == 0)) || die "请先执行 sudo -i 切换到 root，再运行一键安装命令。"
[[ $(uname -s) == "Linux" ]] || die "仅支持 Linux。"
[[ $(uname -m) == "s390x" || $(uname -m) == "s390" ]] || die "此一键入口仅用于 s390x。"
command -v curl >/dev/null 2>&1 || die "缺少 curl，请先通过系统包管理器安装。"
command -v tar >/dev/null 2>&1 || die "缺少 tar，请先通过系统包管理器安装。"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ibmfree-bootstrap.XXXXXXXX")
curl --fail --location --silent --show-error \
  --retry 3 --connect-timeout 15 --max-time 300 \
  "$REPOSITORY_ARCHIVE" | tar -xz --strip-components=1 -C "$TEMP_DIR"

export DEPLOY_MODE=tunnel
export ORIGIN_PORT=8001
bash "${TEMP_DIR}/install.sh"
