#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

readonly CLOUDFLARED_VERSION="2026.8.2"
readonly CLOUDFLARED_COMMIT="733bfb939963e150dcf5c4faddb1603f744fbc98"
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
git init --quiet "$TEMP_DIR/source"
git -C "$TEMP_DIR/source" remote add origin https://github.com/cloudflare/cloudflared.git
git -C "$TEMP_DIR/source" fetch --quiet --depth 1 origin "$CLOUDFLARED_COMMIT"
git -C "$TEMP_DIR/source" checkout --quiet --detach FETCH_HEAD
[[ $(git -C "$TEMP_DIR/source" rev-parse HEAD) == "$CLOUDFLARED_COMMIT" ]] || \
  die "cloudflared source commit verification failed"

pushd "$TEMP_DIR/source" >/dev/null
export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
CGO_ENABLED=0 GOOS=linux GOARCH=s390x \
  go build -mod=vendor -trimpath -buildvcs=false \
  -ldflags="-s -w -buildid= -X main.Version=${CLOUDFLARED_VERSION}" \
  -o "$TEMP_DIR/cloudflared-linux-s390x" \
  ./cmd/cloudflared
popd >/dev/null

mkdir -p "$OUTPUT_DIR"
install -m 0755 "$TEMP_DIR/cloudflared-linux-s390x" "${OUTPUT_DIR%/}/cloudflared-linux-s390x"
(
  cd "$OUTPUT_DIR"
  sha256sum cloudflared-linux-s390x >cloudflared-linux-s390x.sha256
)
{
  printf 'cloudflared_version=%s\n' "$CLOUDFLARED_VERSION"
  printf 'cloudflared_commit=%s\n' "$CLOUDFLARED_COMMIT"
  printf 'go_version=%s\n' "$(go env GOVERSION)"
  printf 'target=linux/s390x\n'
  printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
} >"${OUTPUT_DIR%/}/cloudflared-linux-s390x.manifest"

printf 'Built cloudflared %s for linux/s390x\n' "$CLOUDFLARED_VERSION"
cat "${OUTPUT_DIR%/}/cloudflared-linux-s390x.sha256"
