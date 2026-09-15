#!/usr/bin/env bash

set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DIST=${1:-$ROOT/dist}
VERSION=$("$ROOT/keenetic" --version)
VERSION=${VERSION##* }
PACKAGE=keenetic-manager-$VERSION

# The archive must be byte-identical across platforms, so require GNU tar,
# GNU gzip, and coreutils sha256sum. Apple gzip produces different deflate
# output. On macOS: `brew install gnu-tar gzip coreutils`.
TAR=$(command -v gtar || command -v tar) || { echo 'tar not found' >&2; exit 1; }
"$TAR" --version 2>/dev/null | grep -q 'GNU tar' \
    || { echo "GNU tar is required for reproducible archives (found $TAR)" >&2; exit 1; }
GZIP_BIN=
for candidate in gzip /opt/homebrew/bin/gzip /usr/local/bin/gzip; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" --version 2>/dev/null | head -n1 | grep -q '^gzip '; then
        GZIP_BIN=$(command -v "$candidate")
        break
    fi
done
[[ -n $GZIP_BIN ]] || { echo 'GNU gzip is required for reproducible archives (brew install gzip)' >&2; exit 1; }
SHA256SUM=$(command -v sha256sum || command -v gsha256sum) \
    || { echo 'sha256sum not found (install coreutils)' >&2; exit 1; }

rm -rf -- "$DIST"
mkdir -p -- "$DIST"
work=$(mktemp -d)
cleanup() {
    rm -rf -- "$work"
}
trap cleanup EXIT

mkdir -p -- "$work/$PACKAGE/completions"
install -m755 "$ROOT/keenetic" "$work/$PACKAGE/keenetic"
install -m644 "$ROOT/completions/keenetic.bash" "$work/$PACKAGE/completions/keenetic.bash"
install -m644 "$ROOT/completions/_keenetic" "$work/$PACKAGE/completions/_keenetic"
install -m644 "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/CHANGELOG.md" "$ROOT/config.example" "$work/$PACKAGE/"
install -m755 "$ROOT/keenetic" "$DIST/keenetic"

"$TAR" --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
    -C "$work" -cf - "$PACKAGE" | "$GZIP_BIN" -n > "$DIST/$PACKAGE.tar.gz"
(
    cd -- "$DIST"
    "$SHA256SUM" keenetic "$PACKAGE.tar.gz" > SHA256SUMS
)
printf 'Built %s and standalone executable in %s\n' "$PACKAGE.tar.gz" "$DIST"
