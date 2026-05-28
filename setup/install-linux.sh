#!/usr/bin/env bash
#
# install-linux.sh — install terrarium + Claude Code CLI prerequisites
#                     on a Linux host (including WSL2 distributions).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Alv-no/terrarium-dist/main/setup/install-linux.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/Alv-no/terrarium-dist/main/setup/install-linux.sh | bash -s -- --terrarium-version v0.1.0
#
# Idempotent — safe to re-run. Each step checks if the target is already
# in place before acting.
#
# What this script does:
#   1. Detect distro (apt vs dnf vs unknown).
#   2. Install bubblewrap + build deps (if missing).
#   3. Ensure Node.js >= 20 is available (installs NVM if Node is missing).
#   4. Install Claude Code CLI globally (`npm install -g @anthropic-ai/claude-code`).
#   5. Download the latest terrarium binary from GitHub Releases for the
#      current architecture; verify SHA-256; install to ~/.local/bin/terrarium.
#   6. Print next-steps (run `claude` once to authenticate; optionally
#      `terrarium run -- /bin/echo hi` to smoke-test the sandbox).
#
# What this script does NOT do:
#   - Configure your shell PATH (you may need to add ~/.local/bin yourself).
#   - Authenticate Claude Code (it opens a browser; must be interactive).
#   - Install AIvDesktop. That's a Windows/macOS install — get it from
#     the AIvDesktop GitHub Releases.

set -euo pipefail

REPO="Alv-no/terrarium-dist"
TERRARIUM_VERSION="${TERRARIUM_VERSION:-latest}"  # override with --terrarium-version
INSTALL_PREFIX="${INSTALL_PREFIX:-$HOME/.local}"
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --terrarium-version) TERRARIUM_VERSION="$2"; shift 2;;
        --prefix) INSTALL_PREFIX="$2"; shift 2;;
        --quiet) QUIET=1; shift;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

log() { [ "$QUIET" = 1 ] || echo "[install-linux] $*"; }
err() { echo "[install-linux] error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Detect distro + package manager
# ---------------------------------------------------------------------------

if command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MGR="pacman"
else
    err "no supported package manager found (apt, dnf, pacman). Install bubblewrap manually and re-run."
fi
log "package manager: $PKG_MGR"

# ---------------------------------------------------------------------------
# 2. Install bubblewrap + minimal build deps
# ---------------------------------------------------------------------------

apt_install() { sudo apt-get update -qq && sudo apt-get install -y "$@"; }
dnf_install() { sudo dnf install -y "$@"; }
pacman_install() { sudo pacman -S --needed --noconfirm "$@"; }

case "$PKG_MGR" in
    apt) need_install() { dpkg -s "$1" >/dev/null 2>&1 || return 1; };;
    dnf) need_install() { rpm -q "$1" >/dev/null 2>&1 || return 1; };;
    pacman) need_install() { pacman -Qi "$1" >/dev/null 2>&1 || return 1; };;
esac

want_pkgs=(bubblewrap curl ca-certificates)
missing_pkgs=()
for p in "${want_pkgs[@]}"; do
    need_install "$p" || missing_pkgs+=("$p")
done

if [ ${#missing_pkgs[@]} -gt 0 ]; then
    log "installing: ${missing_pkgs[*]}"
    case "$PKG_MGR" in
        apt) apt_install "${missing_pkgs[@]}";;
        dnf) dnf_install "${missing_pkgs[@]}";;
        pacman) pacman_install "${missing_pkgs[@]}";;
    esac
else
    log "system deps already installed"
fi

# ---------------------------------------------------------------------------
# 3. Node.js >= 20 (via NVM if not present)
# ---------------------------------------------------------------------------

ensure_node() {
    if command -v node >/dev/null 2>&1; then
        node_major=$(node -v | sed -E 's/^v([0-9]+).*/\1/')
        if [ "$node_major" -ge 20 ] 2>/dev/null; then
            log "Node $(node -v) already installed"
            return 0
        fi
        log "Node $(node -v) is older than 20 — will install via NVM"
    else
        log "Node not found — installing via NVM"
    fi

    if [ ! -d "$HOME/.nvm" ]; then
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    fi
    # nvm.sh references variables like PROVIDED_VERSION that aren't set
    # before being read, which trips our `set -u`. Disable nounset for the
    # source + nvm subcommands; re-enable immediately after.
    set +u
    # shellcheck disable=SC1090
    source "$HOME/.nvm/nvm.sh"
    nvm install --lts
    nvm use --lts
    set -u
}
ensure_node

# Re-source nvm so the rest of this script (and `claude` install) finds node.
if [ -f "$HOME/.nvm/nvm.sh" ]; then
    set +u
    # shellcheck disable=SC1090
    source "$HOME/.nvm/nvm.sh"
    set -u
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
# 5. terrarium binary from GitHub Releases
# ---------------------------------------------------------------------------

arch="$(uname -m)"
case "$arch" in
    x86_64|amd64) target="x86_64-unknown-linux-gnu";;
    aarch64|arm64) target="aarch64-unknown-linux-gnu";;
    *) err "unsupported architecture: $arch";;
esac
log "target: $target"

# Resolve the actual tag. If user passed --terrarium-version v0.2.0, we use
# it verbatim; otherwise we ask the GitHub API for the latest non-draft
# terrarium-v* release.
resolve_tag() {
    if [ "$TERRARIUM_VERSION" != "latest" ]; then
        echo "terrarium-$TERRARIUM_VERSION"
        return
    fi
    # Public repo: no auth needed for /releases/latest.
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

# Verify SHA-256.
(cd "$tmp" && sha256sum -c "${archive_name}.sha256") \
    || err "SHA-256 checksum mismatch — refusing to install"

# Extract and place.
tar -C "$tmp" -xzf "$tmp/$archive_name"
mkdir -p "$INSTALL_PREFIX/bin"
mv "$tmp/terrarium" "$INSTALL_PREFIX/bin/terrarium"
chmod 0755 "$INSTALL_PREFIX/bin/terrarium"
log "installed: $INSTALL_PREFIX/bin/terrarium"

# ---------------------------------------------------------------------------
# 6. PATH check + next-steps
# ---------------------------------------------------------------------------

case ":$PATH:" in
    *":$INSTALL_PREFIX/bin:"*) ;;
    *)
        log "WARNING: $INSTALL_PREFIX/bin is NOT in your PATH."
        log "         Add this to your shell rc to fix:"
        log "         export PATH=\"$INSTALL_PREFIX/bin:\$PATH\""
        ;;
esac

cat <<'NEXT_STEPS'

╭─────────────────────────────────────────────────────────────────╮
│  Install done. Two more interactive steps you must run:         │
│                                                                 │
│  1. Authenticate Claude Code (opens a browser):                 │
│         claude                                                  │
│     Sign in with your Anthropic account. Choose OAuth, not API. │
│                                                                 │
│  2. Smoke-test the sandbox:                                     │
│         terrarium run -- /bin/echo hi                           │
│     Should print "hi" via the bubblewrap-managed child.         │
│                                                                 │
│  After that you can use `terrarium run claude` in any project,  │
│  or pair this with AIvDesktop on a Windows host pointing here.  │
╰─────────────────────────────────────────────────────────────────╯

NEXT_STEPS
