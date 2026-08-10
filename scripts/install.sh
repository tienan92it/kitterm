#!/bin/sh
# kitterm installer
#
#   curl -fsSL https://kitterm.dev/install.sh | sh
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

# Every release publishes a .sha256 next to the tarball — verify or fail.
curl -fsSL "$BASE/$TARBALL.sha256" -o "$TMP/sum" \
    || die "checksum download failed: $BASE/$TARBALL.sha256"
EXPECTED="$(cat "$TMP/sum")"
ACTUAL="$(shasum -a 256 "$TMP/$TARBALL" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch (expected $EXPECTED, got $ACTUAL)"
echo "==> checksum ok"

# --- Validate the new build before touching the existing install ---------------
tar -xzf "$TMP/$TARBALL" -C "$TMP"

# Unsigned build: clear the quarantine bit Gatekeeper sets on downloads,
# otherwise the first launch is blocked with "cannot be opened".
xattr -dr com.apple.quarantine "$TMP/bin" "$TMP/lib" "$TMP/share" 2>/dev/null || true

# Smoke-test in the staging dir so a non-launching binary (wrong macOS
# minimum, bad slice) is caught while the old install is still intact.
"$TMP/lib/kitterm/kitterm" --help >/dev/null 2>&1 \
    || die "downloaded binary failed to run; existing install left untouched"

# --- Install ------------------------------------------------------------------
SERVICE_PLIST="$HOME/Library/LaunchAgents/com.kitterm.daemon.plist"
SERVICE_INSTALLED=0
[ -f "$SERVICE_PLIST" ] && SERVICE_INSTALLED=1

# KITTERM_DEFER_RESTART=1 (what `kitterm upgrade` sets) stages the new build
# without touching the running daemon, so live panes survive. The daemon owns
# every PTY master fd — stopping it kills every shell — which is why upgrading
# otherwise has to happen from outside kitterm.
DEFER="${KITTERM_DEFER_RESTART:-0}"

# Deferring is only safe once the web bundle is a versioned directory behind a
# symlink: the running daemon resolved that symlink at start-up and keeps
# serving its own bundle, so its UI can never get ahead of its own API. An
# install predating this layout has a real directory there, and replacing it
# would pull the UI out from under the daemon — so that one upgrade restarts.
if [ "$DEFER" = 1 ] && [ -e "$PREFIX/share/kitterm/web" ] \
    && [ ! -L "$PREFIX/share/kitterm/web" ]; then
    echo "==> migrating to the versioned web layout; restarting the daemon this once"
    DEFER=0
fi

if [ "$DEFER" = 1 ]; then
    echo "==> staging alongside the running daemon (live panes keep running)"
else
    # Quiesce whichever mechanism owns a running daemon. A plain `kitterm stop`
    # is not enough when the LaunchAgent is installed: KeepAlive would respawn
    # the old binary while we replace the files under it.
    launchctl bootout "gui/$(id -u)/com.kitterm.daemon" >/dev/null 2>&1 || true
    if [ -x "$PREFIX/bin/kitterm" ]; then
        "$PREFIX/bin/kitterm" stop >/dev/null 2>&1 || true
    fi
fi

echo "==> installing to $PREFIX"
mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/share/kitterm" \
    || die "cannot write to $PREFIX (set KITTERM_PREFIX to a writable path)"

# Binaries: stage beside the old tree and swap by rename, so there is never a
# moment where <prefix>/lib/kitterm is absent — a running daemon spawning a pane
# resolves its helper through that path. The old binary is only unlinked; a live
# daemon keeps running from its inode.
rm -rf "$PREFIX/lib/kitterm.new" "$PREFIX/lib/kitterm.old"
cp -R "$TMP/lib/kitterm" "$PREFIX/lib/kitterm.new" \
    || die "cannot stage new binaries in $PREFIX/lib"
if [ -e "$PREFIX/lib/kitterm" ]; then
    mv "$PREFIX/lib/kitterm" "$PREFIX/lib/kitterm.old"
fi
mv "$PREFIX/lib/kitterm.new" "$PREFIX/lib/kitterm"
rm -rf "$PREFIX/lib/kitterm.old"

# Rename rather than overwrite: another shell may be reading this wrapper right
# now, and a partially rewritten script would fail in a confusing way.
cp "$TMP/bin/kitterm" "$PREFIX/bin/kitterm.new"
chmod 755 "$PREFIX/bin/kitterm.new"
mv -f "$PREFIX/bin/kitterm.new" "$PREFIX/bin/kitterm"

# Web bundle into its own versioned directory, then flip the symlink by rename
# so no request can observe a half-written root.
WEB_DIR="web-$VERSION"
rm -rf "$PREFIX/share/kitterm/$WEB_DIR"
cp -R "$TMP/share/kitterm/web" "$PREFIX/share/kitterm/$WEB_DIR" \
    || die "cannot stage the web bundle in $PREFIX/share/kitterm"
# A pre-symlink install has a real directory here; it is dead weight once the
# daemon has been stopped above (DEFER is always 0 on that path).
if [ -e "$PREFIX/share/kitterm/web" ] && [ ! -L "$PREFIX/share/kitterm/web" ]; then
    rm -rf "$PREFIX/share/kitterm/web"
fi
ln -sfn "$WEB_DIR" "$PREFIX/share/kitterm/web.new"
mv -f "$PREFIX/share/kitterm/web.new" "$PREFIX/share/kitterm/web"

# Drop superseded bundles, except the one a live daemon pinned at start-up and
# recorded for us. Without that marker, keep everything rather than risk
# deleting the bundle something is still serving.
PINNED=""
[ -f "$HOME/.kitterm/web-root" ] && PINNED="$(basename "$(cat "$HOME/.kitterm/web-root")")"
for dir in "$PREFIX/share/kitterm"/web-*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    [ "$name" = "$WEB_DIR" ] && continue
    if [ "$DEFER" = 1 ]; then
        [ -z "$PINNED" ] && continue
        [ "$name" = "$PINNED" ] && continue
    fi
    rm -rf "$dir"
done

cp "$TMP/share/kitterm/VERSION" "$PREFIX/share/kitterm/VERSION"
for extra in README.md LICENSE; do
    # Explicit `if`: a trailing failed test would be the loop's exit status and
    # `set -e` would abort the install over a missing LICENSE.
    if [ -f "$TMP/share/kitterm/$extra" ]; then
        cp "$TMP/share/kitterm/$extra" "$PREFIX/share/kitterm/$extra"
    fi
done

# The plist template ships inside the binary, so a release that changes it (a
# new key, a different ProcessType) never reaches an already-installed service
# on its own: this script replaces binaries, then re-bootstraps whatever file
# was already on disk. Regenerate it from the build we just installed, before
# that re-bootstrap. The binary preserves the ProgramArguments already in the
# file, so the port and flags chosen at install time survive.
#
# Runs in the deferred case too — it only rewrites the file, never restarts the
# daemon, so live panes are safe. It does not land at the next daemon start:
# launchd keeps the definition it read at bootstrap, and a KeepAlive respawn
# reuses it. `service sync` says so on screen when the loaded job disagrees, and
# names the two ways to reload it (next login, or `kitterm restart`).
if [ "$SERVICE_INSTALLED" = 1 ]; then
    "$PREFIX/bin/kitterm" service sync \
        || echo "warning: could not refresh $SERVICE_PLIST; run: kitterm service install"
fi

# Re-load the login agent we booted out, now pointing at the new build.
if [ "$DEFER" != 1 ] && [ "$SERVICE_INSTALLED" = 1 ]; then
    echo "==> restarting kitterm service"
    launchctl bootstrap "gui/$(id -u)" "$SERVICE_PLIST" >/dev/null 2>&1 \
        || echo "warning: could not reload the kitterm service; run: kitterm service install"
fi

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
        # ${SHELL##*/} would abort under set -u when SHELL is unset (cron/CI).
        SHELL_NAME="${SHELL:-}"
        case "${SHELL_NAME##*/}" in
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
