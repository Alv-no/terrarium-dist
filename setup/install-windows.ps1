# install-windows.ps1 — provision a Windows host for AIvDesktop +
#                       terrarium-in-WSL2.
#
# Usage (admin PowerShell):
#   iwr -useb https://raw.githubusercontent.com/Alv-no/terrarium-dist/main/setup/install-windows.ps1 | iex
#
# Or with arguments:
#   $script = iwr -useb https://raw.githubusercontent.com/Alv-no/terrarium-dist/main/setup/install-windows.ps1
#   Invoke-Expression "$script -Distro Ubuntu-24.04"
#
# What this script does:
#   1. Verify it's running as Administrator (WSL feature install needs it).
#   2. Enable Windows Hypervisor Platform + Virtual Machine Platform if not
#      already, install WSL2 + an Ubuntu distro.
#   3. Inside that WSL distro, run install-linux.sh non-interactively
#      (downloads prebuilt terrarium binary, installs Claude Code CLI).
#   4. Print instructions for the user to interactively authenticate Claude.
#
# What this script does NOT do:
#   - Install AIvDesktop itself. Download AIvDesktop's .msi or .exe from
#     https://github.com/Alv-no/terrarium-dist/releases — those tags are
#     `aivdesktop-v*` (not `terrarium-v*`).
#   - Configure your Windows Defender / AppLocker rules.
#   - Authenticate Claude Code (must be interactive, opens a browser).

[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu",
    [string]$TerrariumVersion = "latest"
)

$ErrorActionPreference = "Stop"

function Log {
    param([string]$Message)
    Write-Host "[install-windows] $Message"
}

function Fail {
    param([string]$Message)
    Write-Error "[install-windows] $Message"
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Admin check
# ---------------------------------------------------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] "Administrator"
)
if (-not $isAdmin) {
    Fail "This script must run in an elevated (Administrator) PowerShell."
}

# ---------------------------------------------------------------------------
# 2. WSL2 + distro
# ---------------------------------------------------------------------------

Log "checking WSL state"
$wslPresent = $false
try {
    $null = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -eq 0) { $wslPresent = $true }
} catch {}

if (-not $wslPresent) {
    Log "installing WSL2 + $Distro (this may require a reboot)"
    & wsl.exe --install -d $Distro
    Log ""
    Log "WSL was newly installed. You MUST reboot and re-run this script to continue."
    exit 0
}

Log "WSL is available"

# Check if the requested distro is installed.
$distros = & wsl.exe --list --quiet 2>&1 | Out-String
# `wsl --list` output uses UTF-16; PowerShell sometimes shows it with \0 bytes.
# Normalize.
$distros = $distros.Replace("`0", "")

if ($distros -notmatch [regex]::Escape($Distro)) {
    Log "installing distro: $Distro"
    & wsl.exe --install -d $Distro --no-launch
    Log "distro installed. Launching it once so first-run user setup completes..."
    Log "  (you'll be prompted for a Unix username + password)"
    & wsl.exe -d $Distro -- echo "first-run complete"
}

# ---------------------------------------------------------------------------
# 3. Run install-linux.sh inside the distro
# ---------------------------------------------------------------------------

Log "running install-linux.sh inside $Distro"
$linuxScriptUrl = "https://raw.githubusercontent.com/Alv-no/terrarium-dist/main/setup/install-linux.sh"

$args = @("--terrarium-version", $TerrariumVersion)

# Pipe the script via curl|bash inside WSL so we can re-run idempotently.
& wsl.exe -d $Distro -- bash -lc "curl -fsSL $linuxScriptUrl | bash -s -- $($args -join ' ')"

if ($LASTEXITCODE -ne 0) {
    Fail "Linux-side install failed. Re-run this script after fixing the issue inside $Distro."
}

# ---------------------------------------------------------------------------
# 4. Next steps
# ---------------------------------------------------------------------------

Write-Host @"

╭─────────────────────────────────────────────────────────────────╮
│  Windows-side install done. Two more interactive steps:         │
│                                                                 │
│  1. Open a $Distro shell and authenticate Claude (opens browser):│
│         wsl.exe -d $Distro                                     │
│         claude                                                  │
│     Sign in with your Anthropic account.                        │
│                                                                 │
│  2. Smoke-test the sandbox from PowerShell:                     │
│         wsl.exe -d $Distro -- bash -lc 'terrarium run -- /bin/echo hi' │
│     Should print "hi".                                          │
│                                                                 │
│  Then download AIvDesktop's .msi or .exe installer from         │
│  https://github.com/Alv-no/terrarium-dist/releases (tag aivdesktop-v*). │
╰─────────────────────────────────────────────────────────────────╯

"@
