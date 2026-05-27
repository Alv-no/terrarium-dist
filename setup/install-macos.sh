#!/usr/bin/env bash
#
# install-macos.sh — install terrarium + Claude Code CLI prerequisites
#                     on macOS. Uses the Seatbelt sandbox backend.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Alv-no/terrarium-dist/main/setup/install-macos.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/Alv-no/terrarium-dist/main/setup/install-macos.sh | bash -s -- --terrarium-version v0.1.0
#
# What this script does:
#   1. Verify we're on macOS.
#   2. Install Homebrew if missing.
#   3. Install Node.js LTS via Homebrew (if missing).
#   4. Install Claude Code CLI globally.
#   5. Download the latest terrarium binary for the host architecture
#      (Apple Silicon or Intel); verify SHA-256; install to /usr/local/bin
#      (or ~/.local/bin if non-admin).
#   6. Print next-steps for interactive authentication.

set -euo pipefail

REPO="Alv-no/terrarium-dist"
TERRARIUM_VERSION="${TERRARIUM_VERSION:-latest}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --terrarium-version) TERRARIUM_VERSION="$2"; shift 2;;
        --prefix) INSTALL_PREFIX="$2"; shift 2;;
        --quiet) QUIET=1; shift;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

log() { [ "$QUIET" = 1 ] || echo "[install-macos] $*"; }
err() { echo "[install-macos] error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. macOS check
# ---------------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || err "this script is for macOS; on Linux use install-linux.sh"

# ---------------------------------------------------------------------------
# 2. Homebrew
# ---------------------------------------------------------------------------

if ! command -v brew >/dev/null 2>&1; then
    log "Homebrew not found — installing"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Make brew available on PATH for the rest of this script (the installer
    # prints instructions but doesn't apply them in our subshell).
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Node.js
# ---------------------------------------------------------------------------

if ! command -v node >/dev/null 2>&1; then
    log "installing Node.js"
    brew install node
else
    log "Node $(node -v) already installed"
fi

# ---------------------------------------------------------------------------
# 4. Claude Code CLI
# ---------------------------------------------------------------------------

if command -v claude >/dev/null 2>&1; then
    log "claude $(claude --version 2>&1 | head -1) already installed"
else
    log "installing Claude Code CLI"
    npm install -g @anthropic-ai/claude-code
fi

# ---------------------------------------------------------------------------
# 5. terrarium binary
# ---------------------------------------------------------------------------

arch="$(uname -m)"
case "$arch" in
    arm64) target="aarch64-apple-darwin";;
    x86_64) target="x86_64-apple-darwin";;
    *) err "unsupported architecture: $arch";;
esac
log "target: $target"

resolve_tag() {
    if [ "$TERRARIUM_VERSION" != "latest" ]; then
        echo "terrarium-$TERRARIUM_VERSION"
        return
    fi
    curl -fsSL "https://api.github.com/repos/${REPO}/releases" \
        | grep -oE '"tag_name": "terrarium-v[^"]+"' \
        | head -1 \
        | sed -E 's/.*"(terrarium-v[^"]+)".*/\1/'
}

tag="$(resolve_tag)"
[ -n "$tag" ] || err "could not resolve a terrarium-v* tag from GitHub Releases"
version="${tag#terrarium-v}"
archive_name="terrarium-${version}-${target}.tar.gz"
url="https://github.com/${REPO}/releases/download/${tag}/${archive_name}"
log "downloading $url"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "$url" -o "$tmp/$archive_name"
curl -fsSL "${url}.sha256" -o "$tmp/${archive_name}.sha256"

(cd "$tmp" && shasum -a 256 -c "${archive_name}.sha256") \
    || err "SHA-256 checksum mismatch — refusing to install"

tar -C "$tmp" -xzf "$tmp/$archive_name"

# Try /usr/local/bin (needs sudo for most users); fall back to ~/.local/bin.
if [ -w "$INSTALL_PREFIX/bin" ] || sudo -n true 2>/dev/null; then
    sudo mkdir -p "$INSTALL_PREFIX/bin"
    sudo mv "$tmp/terrarium" "$INSTALL_PREFIX/bin/terrarium"
    sudo chmod 0755 "$INSTALL_PREFIX/bin/terrarium"
    log "installed: $INSTALL_PREFIX/bin/terrarium"
else
    INSTALL_PREFIX="$HOME/.local"
    mkdir -p "$INSTALL_PREFIX/bin"
    mv "$tmp/terrarium" "$INSTALL_PREFIX/bin/terrarium"
    chmod 0755 "$INSTALL_PREFIX/bin/terrarium"
    log "installed: $INSTALL_PREFIX/bin/terrarium (no sudo; using ~/.local fallback)"
    case ":$PATH:" in
        *":$INSTALL_PREFIX/bin:"*) ;;
        *) log "WARNING: $INSTALL_PREFIX/bin not in PATH. Add: export PATH=\"$INSTALL_PREFIX/bin:\$PATH\"";;
    esac
fi

cat <<'NEXT_STEPS'

╭─────────────────────────────────────────────────────────────────╮
│  Install done. Two more interactive steps:                      │
│                                                                 │
│  1. Authenticate Claude Code (opens a browser):                 │
│         claude                                                  │
│                                                                 │
│  2. Smoke-test the Seatbelt sandbox:                            │
│         terrarium run -- /bin/echo hi                           │
╰─────────────────────────────────────────────────────────────────╯

NEXT_STEPS
