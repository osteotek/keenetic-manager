#!/usr/bin/env bash

set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DIST=${1:-$ROOT/dist}
VERSION=$("$ROOT/keenetic-policy.sh" --version)
VERSION=${VERSION##* }
PACKAGE=keenetic-policy-$VERSION

rm -rf -- "$DIST"
mkdir -p -- "$DIST"
work=$(mktemp -d)
cleanup() {
    rm -rf -- "$work"
}
trap cleanup EXIT

mkdir -p -- "$work/$PACKAGE/completions"
install -m755 "$ROOT/keenetic-policy.sh" "$work/$PACKAGE/keenetic-policy.sh"
install -m644 "$ROOT/completions/keenetic-policy.bash" "$work/$PACKAGE/completions/keenetic-policy.bash"
install -m644 "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/CHANGELOG.md" "$ROOT/config.example" "$work/$PACKAGE/"
install -m755 "$ROOT/keenetic-policy.sh" "$DIST/keenetic-policy"

tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    -C "$work" -czf "$DIST/$PACKAGE.tar.gz" "$PACKAGE"
(
    cd -- "$DIST"
    sha256sum keenetic-policy "$PACKAGE.tar.gz" > SHA256SUMS
)
printf 'Built %s and standalone executable in %s\n' "$PACKAGE.tar.gz" "$DIST"
