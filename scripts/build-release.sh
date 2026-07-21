#!/bin/sh
# Build a distributable kitterm tarball: universal Swift binaries + prebuilt web UI.
#
#   ./scripts/build-release.sh [VERSION]
#
# Output: dist/kitterm-<version>-macos-universal.tar.gz (+ .sha256)
#
# Requires Swift 6 and pnpm on the build machine — never on the user's machine.
set -eu

VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STAGE="$ROOT/dist/stage"
OUT="$ROOT/dist/kitterm-${VERSION}-macos-universal.tar.gz"

echo "==> kitterm ${VERSION}"
rm -rf "$STAGE" && mkdir -p "$STAGE/bin" "$STAGE/lib/kitterm" "$STAGE/share/kitterm"

# --- Swift: build each slice, then lipo into one universal binary -------------
for ARCH in arm64 x86_64; do
    echo "==> swift build ($ARCH)"
    swift build -c release --arch "$ARCH" --product kitterm
    swift build -c release --arch "$ARCH" --product kitterm-spawn-helper
done

# SwiftPM writes per-arch products under .build/<arch>-apple-macosx/release.
for BIN in kitterm kitterm-spawn-helper; do
    echo "==> lipo $BIN"
    lipo -create -output "$STAGE/lib/kitterm/$BIN" \
        ".build/arm64-apple-macosx/release/$BIN" \
        ".build/x86_64-apple-macosx/release/$BIN"
    chmod 755 "$STAGE/lib/kitterm/$BIN"
done

# The real binary lives in lib/ so that SpawnHelperPath's sibling lookup finds
# kitterm-spawn-helper. bin/kitterm is a wrapper: exec makes argv[0] the lib
# path, so the sibling resolves even when bin/ is on PATH.
cat > "$STAGE/bin/kitterm" <<'WRAPPER'
#!/bin/sh
# Resolve this wrapper's real directory, following symlinks.
SELF="$0"
while [ -L "$SELF" ]; do
    LINK="$(readlink "$SELF")"
    case "$LINK" in
        /*) SELF="$LINK" ;;
        *)  SELF="$(dirname "$SELF")/$LINK" ;;
    esac
done
PREFIX="$(cd "$(dirname "$SELF")/.." && pwd)"
exec "$PREFIX/lib/kitterm/kitterm" "$@"
WRAPPER
chmod 755 "$STAGE/bin/kitterm"

# --- Web UI: ship the built bundle so users need no Node -----------------------
echo "==> pnpm build"
(cd Web/terminal && pnpm install --frozen-lockfile && pnpm build)
cp -R Web/terminal/dist "$STAGE/share/kitterm/web"

[ -f "$STAGE/share/kitterm/web/index.html" ] || {
    echo "error: web bundle missing index.html" >&2
    exit 1
}

# --- Package -----------------------------------------------------------------
cp README.md LICENSE "$STAGE/share/kitterm/" 2>/dev/null || true
echo "$VERSION" > "$STAGE/share/kitterm/VERSION"

tar -czf "$OUT" -C "$STAGE" bin lib share
shasum -a 256 "$OUT" | awk '{print $1}' > "$OUT.sha256"

echo
echo "==> $OUT"
echo "    sha256 $(cat "$OUT.sha256")"
lipo -archs "$STAGE/lib/kitterm/kitterm"
