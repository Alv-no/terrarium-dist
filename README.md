# terrarium-dist

Public distribution mirror for **terrarium** binaries and **AIvDesktop** installers.

The source code lives in the private repository [Alv-no/terrarium](https://github.com/Alv-no/terrarium); this repo exists so end users can download release artifacts and run setup scripts without needing a GitHub account or authentication.

## Quick install

### terrarium core (Linux / WSL2)

```bash
curl -fsSL https://raw.githubusercontent.com/Alv-no/terrarium-dist/main/setup/install-linux.sh | bash
```

### terrarium core (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/Alv-no/terrarium-dist/main/setup/install-macos.sh | bash
```

### Windows (sets up WSL2 + Ubuntu + terrarium-in-WSL automatically)

From an **Administrator PowerShell**:

```powershell
iwr -useb https://raw.githubusercontent.com/Alv-no/terrarium-dist/main/setup/install-windows.ps1 | iex
```

After install, authenticate Claude Code:

```bash
claude          # Linux / macOS
wsl claude      # Windows
```

Sign in via the browser flow when prompted. This uses your existing Claude Code subscription (Pro / Max / Team) — no API key required.

### AIvDesktop desktop app

After terrarium prereqs are in place, download the platform installer from the [Releases page](https://github.com/Alv-no/terrarium-dist/releases) (tags starting with `aivdesktop-v`):

- **Windows**: `.msi` or `.exe`
- **macOS**: `.dmg`
- **Linux**: `.deb`, `.AppImage`, or `.rpm`

## What's in this repo

```
terrarium-dist/
├── README.md                 # this file
├── LICENSE                   # Apache 2.0
└── setup/
    ├── install-linux.sh      # Linux / WSL2 prereqs + terrarium binary
    ├── install-macos.sh      # macOS prereqs + terrarium binary
    └── install-windows.ps1   # Windows prereqs (WSL2) + chains to Linux
```

Plus, attached to each Release tag:

- `terrarium-<ver>-<target>.tar.gz` for the terrarium binary on each platform target
- `AIvDesktop_<ver>_<arch>.{msi,exe,dmg,deb,AppImage,rpm}` for the AIvDesktop installer

Each archive has a corresponding `.sha256` file the setup scripts verify against.

## Where the actual code lives

| Component | Repository | Visibility |
|---|---|---|
| terrarium core (Rust) | [Alv-no/terrarium](https://github.com/Alv-no/terrarium) | Private |
| AIvDesktop (Tauri app) | [Alv-no/terrarium](https://github.com/Alv-no/terrarium) (in `AIvDesktop/`) | Private |
| Release binaries + setup scripts | this repo | **Public** |

The release workflows in the private repo automatically push artifacts here when a version tag is pushed. This repo is intentionally tiny — it exists purely as a delivery channel.

## License

Apache 2.0. See [LICENSE](./LICENSE). Same as the upstream `terrarium` project.

## Reporting issues

For bugs in terrarium or AIvDesktop, file an issue against the source repository (Alv-no/terrarium). For issues with these install scripts specifically, file against this repo.
