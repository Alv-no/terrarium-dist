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
#      (Apple Silicon or Intel); verify SHA-256; install to ~/.local/bin
#      (no sudo required) and make sure it is on PATH.
#   6. Print next-steps for interactive authentication.
#
# Why ~/.local/bin and not /usr/local/bin: terrarium is a single self-contained
# binary, and installing it must never need elevation. The previous
# /usr/local/bin default forced `sudo` — which the AIvDesktop in-app upgrade
# flow (a GUI process with no TTY / null stdin) can never satisfy, so the
# "Update terrarium" button silently fell back to an unused location and the
# version never changed. A user-writable prefix fixes that end to end.

set -euo pipefail

REPO="Alv-no/terrarium-dist"
TERRARIUM_VERSION="${TERRARIUM_VERSION:-latest}"
INSTALL_PREFIX="${INSTALL_PREFIX:-$HOME/.local}"
QUIET=0

# Trusted Ed25519 public key (32-byte, lowercase hex) for terrarium release
# archives. The script you chose to run is the trust anchor: we verify the
# downloaded binary's detached .sig against this key before installing, so a
# swapped binary on terrarium-dist is rejected even if this script is intact.
# Replace the sentinel below with the public hex from
# `org_baseline::generate_keypair()` (see AIvDesktop/UPDATES.md). The all-zero
# sentinel disables verification only in an unprovisioned build — a real
# release must ship a real key.
TERRARIUM_UPDATE_PUBKEY_HEX="50b2280a087f9558c0dbe4ed74391ce56e6829bba6c4291f28169828514267fb"

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
curl -fsSL "${url}.sig" -o "$tmp/${archive_name}.sig" \
    || err "could not download the Ed25519 signature (.sig) — refusing to install"

# SHA-256 is a cheap corruption check; NOT the security boundary.
(cd "$tmp" && shasum -a 256 -c "${archive_name}.sha256") \
    || err "SHA-256 checksum mismatch — refusing to install"

# Verify the Ed25519 signature against the trusted key — the real boundary.
# Catches a binary swapped on terrarium-dist even when this script is intact.
# Node (>=20, installed earlier) avoids the LibreSSL-vs-OpenSSL3 `-rawin`
# portability problem on macOS and reproduces org_baseline::verify_sig's format.
if [ "$TERRARIUM_UPDATE_PUBKEY_HEX" = "0000000000000000000000000000000000000000000000000000000000000000" ]; then
    log "WARNING: no terrarium signing key embedded in this script — skipping Ed25519 verification"
else
    PUBHEX="$TERRARIUM_UPDATE_PUBKEY_HEX" node -e '
      const fs = require("fs"), crypto = require("crypto");
      const pub = Buffer.from(process.env.PUBHEX, "hex");
      const key = crypto.createPublicKey({ key: { kty:"OKP", crv:"Ed25519",
        x: pub.toString("base64url") }, format:"jwk" });
      const data = fs.readFileSync(process.argv[1]);
      const sig  = Buffer.from(fs.readFileSync(process.argv[2],"utf8").trim(), "hex");
      process.exit(crypto.verify(null, data, key, sig) ? 0 : 1);
    ' "$tmp/$archive_name" "$tmp/${archive_name}.sig" \
      || err "Ed25519 signature verification failed — refusing to install"
    log "Ed25519 signature verified"
fi

tar -C "$tmp" -xzf "$tmp/$archive_name"

# Install to a user-writable prefix — no sudo, ever. A single binary doesn't
# belong in /usr/local, and requiring sudo here is exactly what broke the
# AIvDesktop in-app upgrade (no TTY → sudo can't prompt → silent no-op).
mkdir -p "$INSTALL_PREFIX/bin"
mv "$tmp/terrarium" "$INSTALL_PREFIX/bin/terrarium"
chmod 0755 "$INSTALL_PREFIX/bin/terrarium"
log "installed: $INSTALL_PREFIX/bin/terrarium"

# Make sure ~/.local/bin is on PATH. Unlike Ubuntu — whose default ~/.profile
# auto-adds ~/.local/bin, which is why the WSL flow "just works" — macOS ships
# no such default. Without this, a freshly installed ~/.local/bin/terrarium is
# invisible to login shells, including the `bash -lc` AIvDesktop uses to
# detect, launch, and upgrade terrarium. Append an idempotent PATH line to the
# bash login file (what `bash -lc` reads) and to zsh's login file (the macOS
# Terminal default), prepending so it wins over any stale /usr/local/bin copy.
ensure_on_path() {
    local prefix_bin="$INSTALL_PREFIX/bin"
    local marker="# added by terrarium install-macos.sh"
    local line="export PATH=\"$prefix_bin:\$PATH\""

    # bash login shell reads the FIRST of these that exists.
    local bash_rc
    if [ -f "$HOME/.bash_profile" ]; then bash_rc="$HOME/.bash_profile"
    elif [ -f "$HOME/.bash_login" ]; then bash_rc="$HOME/.bash_login"
    else bash_rc="$HOME/.profile"; fi

    local changed=0
    for rc in "$bash_rc" "$HOME/.zprofile"; do
        if [ -f "$rc" ] && grep -qF "$marker" "$rc"; then
            continue  # already added previously
        fi
        printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
        log "added $prefix_bin to PATH in $rc"
        changed=1
    done
    if [ "$changed" = 1 ]; then
        log "open a NEW terminal (or run: source \"$bash_rc\") so the PATH change takes effect"
    fi
    return 0
}
case ":$PATH:" in
    *":$INSTALL_PREFIX/bin:"*) ;;       # already active in this shell
    *) ensure_on_path;;
esac

# Shadow check: a different terrarium earlier on PATH would win lookups even
# after we install ours. Warn loudly with the exact removal command — this is
# the trap for users whose first install (pre-this-change) went to
# /usr/local/bin via sudo.
existing="$(command -v terrarium 2>/dev/null || true)"
if [ -n "$existing" ] && [ "$existing" != "$INSTALL_PREFIX/bin/terrarium" ]; then
    log "WARNING: a different terrarium is earlier on PATH and will win lookups:"
    log "         $existing"
    log "         Remove it so the version just installed is used:"
    log "         rm '$existing'   # (use 'sudo rm' if it lives in /usr/local/bin)"
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
