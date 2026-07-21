#!/bin/sh
# kitterm installer
#
#   curl -fsSL https://raw.githubusercontent.com/tienan92it/kitterm/main/scripts/install.sh | sh
#
# Env:
#   KITTERM_PREFIX   install prefix (default: ~/.local)
#   KITTERM_VERSION  release tag to install (default: latest)
set -eu

REPO="tienan92it/kitterm"
PREFIX="${KITTERM_PREFIX:-$HOME/.local}"
VERSION="${KITTERM_VERSION:-latest}"

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "kitterm is macOS-only (found $(uname -s))"

# macOS 13+ — the daemon targets it.
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 13 ] 2>/dev/null || die "macOS 13+ required (found $(sw_vers -productVersion))"

command -v curl >/dev/null 2>&1 || die "curl is required"

# --- Resolve the release ------------------------------------------------------
if [ "$VERSION" = "latest" ]; then
    echo "==> resolving latest release"
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$VERSION" ] || die "could not resolve latest release; set KITTERM_VERSION"
fi

TARBALL="kitterm-${VERSION}-macos-universal.tar.gz"
BASE="https://github.com/$REPO/releases/download/$VERSION"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "==> downloading kitterm $VERSION"
curl -fsSL "$BASE/$TARBALL" -o "$TMP/$TARBALL" \
    || die "download failed: $BASE/$TARBALL"

# Checksum is advisory — a missing .sha256 must not block install.
if curl -fsSL "$BASE/$TARBALL.sha256" -o "$TMP/sum" 2>/dev/null; then
    EXPECTED="$(cat "$TMP/sum")"
    ACTUAL="$(shasum -a 256 "$TMP/$TARBALL" | awk '{print $1}')"
    [ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch (expected $EXPECTED, got $ACTUAL)"
    echo "==> checksum ok"
fi

# --- Install ------------------------------------------------------------------
# Stop a running daemon first: replacing the binary underneath it leaves a live
# process serving a stale build with state files pointing at the new one.
if [ -x "$PREFIX/bin/kitterm" ]; then
    "$PREFIX/bin/kitterm" stop >/dev/null 2>&1 || true
fi

echo "==> installing to $PREFIX"
mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/share" \
    || die "cannot write to $PREFIX (set KITTERM_PREFIX to a writable path)"

tar -xzf "$TMP/$TARBALL" -C "$TMP"
rm -rf "$PREFIX/lib/kitterm" "$PREFIX/share/kitterm"
cp -R "$TMP/bin/kitterm" "$PREFIX/bin/kitterm"
cp -R "$TMP/lib/kitterm" "$PREFIX/lib/kitterm"
cp -R "$TMP/share/kitterm" "$PREFIX/share/kitterm"

# Unsigned build: clear the quarantine bit Gatekeeper sets on downloads,
# otherwise the first launch is blocked with "cannot be opened".
xattr -dr com.apple.quarantine \
    "$PREFIX/bin/kitterm" "$PREFIX/lib/kitterm" 2>/dev/null || true

"$PREFIX/lib/kitterm/kitterm" --help >/dev/null 2>&1 \
    || die "installed binary failed to run"

echo
echo "kitterm $VERSION installed."
echo

case ":$PATH:" in
    *":$PREFIX/bin:"*)
        echo "  kitterm start        # → http://kitterm.localhost:3418/"
        ;;
    *)
        echo "  $PREFIX/bin is not on your PATH. Add it:"
        echo
        case "${SHELL##*/}" in
            zsh)  echo "    echo 'export PATH=\"$PREFIX/bin:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
            bash) echo "    echo 'export PATH=\"$PREFIX/bin:\$PATH\"' >> ~/.bash_profile && exec bash" ;;
            *)    echo "    export PATH=\"$PREFIX/bin:\$PATH\"" ;;
        esac
        echo
        echo "  then: kitterm start"
        ;;
esac
echo
echo "  kitterm service install   # optional: start on login"
