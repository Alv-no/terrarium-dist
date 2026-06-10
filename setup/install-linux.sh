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

# `-u` (nounset) is intentionally NOT enabled. nvm.sh — which this script
# sources via ensure_node — references several variables (PROVIDED_VERSION,
# NVM_LTS, ...) without declaring defaults; with `-u` active the second-
# pass invocation aborts with "unbound variable" even when wrapped in
# `set +u/-u`, because some nvm internals re-enter via subshell-like paths.
# `-e` and pipefail are still enabled so genuine command failures abort.
set -eo pipefail

REPO="Alv-no/terrarium-dist"
TERRARIUM_VERSION="${TERRARIUM_VERSION:-latest}"  # override with --terrarium-version
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
    # shellcheck disable=SC1090
    source "$HOME/.nvm/nvm.sh"
    nvm install --lts
    nvm use --lts
}
ensure_node

# Re-source nvm so the rest of this script (and `claude` install) finds node.
if [ -f "$HOME/.nvm/nvm.sh" ]; then
    # shellcheck disable=SC1090
    source "$HOME/.nvm/nvm.sh"
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
curl -fsSL "${url}.sig" -o "$tmp/${archive_name}.sig" \
    || err "could not download the Ed25519 signature (.sig) — refusing to install"

# Verify SHA-256 (cheap corruption check; NOT the security boundary).
(cd "$tmp" && sha256sum -c "${archive_name}.sha256") \
    || err "SHA-256 checksum mismatch — refusing to install"

# Verify the Ed25519 signature against the trusted key — the real boundary.
# Catches a binary swapped on terrarium-dist even when this script is intact.
# Node (>=20, installed in step 3) avoids the LibreSSL-vs-OpenSSL3 `-rawin`
# portability problem and reproduces org_baseline::verify_sig's format.
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

# Extract and place.
tar -C "$tmp" -xzf "$tmp/$archive_name"
mkdir -p "$INSTALL_PREFIX/bin"
mv "$tmp/terrarium" "$INSTALL_PREFIX/bin/terrarium"
chmod 0755 "$INSTALL_PREFIX/bin/terrarium"
log "installed: $INSTALL_PREFIX/bin/terrarium"

# Shadow check: if another terrarium binary exists earlier on PATH (e.g. a
# `cargo install`-style installation under ~/.cargo/bin), our freshly
# installed copy will be silently shadowed. The user will see the old
# version's behavior even though "install succeeded" — which is exactly
# the trap that consumed several debug iterations during MVP5. Warn
# loudly and offer the remove command.
existing="$(command -v terrarium 2>/dev/null || true)"
if [ -n "$existing" ] && [ "$existing" != "$INSTALL_PREFIX/bin/terrarium" ]; then
    log "WARNING: a different terrarium is earlier on PATH and will win lookups:"
    log "         $existing"
    log "         To use the version we just installed, remove the shadowing copy:"
    log "         rm $existing"
    log "         (then re-run \`which terrarium\` to confirm it resolves to $INSTALL_PREFIX/bin/terrarium)"
fi

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
