#!/bin/sh
# Build a distributable kitterm tarball for Linux: statically linked Swift
# binaries + prebuilt web UI.
#
#   ./scripts/build-release-linux.sh [VERSION]
#
# Output: dist/kitterm-<version>-linux-<arch>.tar.gz (+ .sha256)
#
# Requires the Swift 6 toolchain. The web bundle is built here if pnpm is
# available, or supplied prebuilt via WEB_DIST=<path> — CI builds it once and
# hands the same bundle to every architecture.
#
# The layout matches build-release.sh exactly, because the daemon locates its
# own web assets relative to the executable: lib/kitterm/kitterm resolves
# ../../share/kitterm/web. Extract this anywhere and it works with no env vars.
set -eu

VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Name the tarball the way container images think about architectures, so a
# Dockerfile can interpolate TARGETARCH directly.
case "$(uname -m)" in
    x86_64)         ARCH=amd64 ;;
    aarch64|arm64)  ARCH=arm64 ;;
    *)              echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

STAGE="$ROOT/dist/stage-linux"
OUT="$ROOT/dist/kitterm-${VERSION}-linux-${ARCH}.tar.gz"

echo "==> kitterm ${VERSION} (linux-${ARCH})"
rm -rf "$STAGE" && mkdir -p "$STAGE/bin" "$STAGE/lib/kitterm" "$STAGE/share/kitterm"

# --- Swift -------------------------------------------------------------------
# --static-swift-stdlib on BOTH products. SwiftPM links even the C spawn helper
# against libswiftCore, and a helper that needs the Swift runtime fails to exec
# on any machine without a Swift toolchain — which is every machine this tarball
# is for. The symptom is every session dying instantly with
# "error while loading shared libraries: libswiftCore.so".
for PRODUCT in kitterm kitterm-spawn-helper; do
    echo "==> swift build $PRODUCT"
    swift build -c release --static-swift-stdlib --product "$PRODUCT"
done

BUILD_DIR="$(swift build -c release --static-swift-stdlib --show-bin-path)"
for BIN in kitterm kitterm-spawn-helper; do
    cp "$BUILD_DIR/$BIN" "$STAGE/lib/kitterm/$BIN"
    chmod 755 "$STAGE/lib/kitterm/$BIN"
done

# Refuse to ship a dynamically-linked build. This is the single failure that
# makes an otherwise healthy image unusable, and it is invisible until a shell
# is spawned, so check it here rather than discovering it in production.
for BIN in kitterm kitterm-spawn-helper; do
    if ldd "$STAGE/lib/kitterm/$BIN" 2>/dev/null | grep -q swift; then
        echo "error: $BIN still links the Swift runtime dynamically:" >&2
        ldd "$STAGE/lib/kitterm/$BIN" | grep swift >&2
        exit 1
    fi
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

# --- Web UI: ship the built bundle so users need no Node ----------------------
if [ -n "${WEB_DIST:-}" ]; then
    echo "==> using prebuilt web bundle from $WEB_DIST"
    cp -R "$WEB_DIST" "$STAGE/share/kitterm/web"
else
    echo "==> pnpm build"
    # --ignore-scripts: pnpm 10 blocks esbuild's postinstall by default and
    # fails the install outright. Vite resolves the binary from the platform
    # package, so the build itself is unaffected.
    (cd Web/terminal && pnpm install --frozen-lockfile --ignore-scripts && pnpm build)
    cp -R Web/terminal/dist "$STAGE/share/kitterm/web"
fi

[ -f "$STAGE/share/kitterm/web/index.html" ] || {
    echo "error: web bundle missing index.html" >&2
    exit 1
}

# --- Package -----------------------------------------------------------------
cp README.md LICENSE "$STAGE/share/kitterm/" 2>/dev/null || true
echo "$VERSION" > "$STAGE/share/kitterm/VERSION"

mkdir -p "$ROOT/dist"
tar -czf "$OUT" -C "$STAGE" bin lib share
sha256sum "$OUT" | awk '{print $1}' > "$OUT.sha256"

echo
echo "==> $OUT"
echo "    sha256 $(cat "$OUT.sha256")"
echo "    static: $(ldd "$STAGE/lib/kitterm/kitterm" 2>&1 | grep -c swift) swift libraries linked"
