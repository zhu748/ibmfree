#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

readonly CLOUDFLARED_VERSION="2026.8.2"
readonly GO_MIN_VERSION="1.26"
readonly OUTPUT_DIR="${1:-dist}"

TEMP_DIR=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    case "$TEMP_DIR" in
      "${TMPDIR:-/tmp}"/cloudflared-build.*)
        find "$TEMP_DIR" -xdev -depth -delete 2>/dev/null || true
        ;;
      *)
        printf 'warning: refusing to clean unexpected path: %s\n' "$TEMP_DIR" >&2
        ;;
    esac
  fi
}

trap cleanup EXIT

command -v git >/dev/null 2>&1 || die "git is required"
command -v go >/dev/null 2>&1 || die "Go ${GO_MIN_VERSION}+ is required"

go_version=$(go env GOVERSION | sed 's/^go//')
if [[ $(printf '%s\n%s\n' "$GO_MIN_VERSION" "$go_version" | sort -V | head -n1) != "$GO_MIN_VERSION" ]]; then
  die "Go ${GO_MIN_VERSION}+ is required; found ${go_version}"
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cloudflared-build.XXXXXXXX")
git clone --quiet --depth 1 --branch "$CLOUDFLARED_VERSION" \
  https://github.com/cloudflare/cloudflared.git "$TEMP_DIR/source"

pushd "$TEMP_DIR/source" >/dev/null
CGO_ENABLED=0 GOOS=linux GOARCH=s390x \
  go build -mod=vendor -trimpath \
  -ldflags="-s -w -X main.Version=${CLOUDFLARED_VERSION}" \
  -o "$TEMP_DIR/cloudflared-linux-s390x" \
  ./cmd/cloudflared
popd >/dev/null

mkdir -p "$OUTPUT_DIR"
install -m 0755 "$TEMP_DIR/cloudflared-linux-s390x" "${OUTPUT_DIR%/}/cloudflared-linux-s390x"
sha256sum "${OUTPUT_DIR%/}/cloudflared-linux-s390x" >"${OUTPUT_DIR%/}/cloudflared-linux-s390x.sha256"

printf 'Built cloudflared %s for linux/s390x\n' "$CLOUDFLARED_VERSION"
cat "${OUTPUT_DIR%/}/cloudflared-linux-s390x.sha256"
