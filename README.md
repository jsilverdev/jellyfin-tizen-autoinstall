# Jellyfin Tizen Auto-Install

Cross-platform installers that deploy the latest stable Jellyfin build to a Samsung TV running Tizen.

- **Windows:** `install.ps1`
- **Linux:** `install.sh`

Both installers validate the TV and Tizen tools, auto-install the official Tizen SDK CLI when it is missing, connect through SDB, download the latest stable Jellyfin Tizen package, verify its size and SHA-256 digest, install it, and confirm that Jellyfin appears in the TV application list.

## Tizen CLI auto-install

Auto-install is enabled by default when `sdb` and `tizen` are missing.

- Windows default: `%LOCALAPPDATA%\TizenStudio`
- Linux default: `~/.local/share/tizen-studio`

These locations are user-writable and do not require changing the system-wide `PATH`. The Windows flow validates the downloaded installer's Authenticode signature before execution. Linux uses the pinned official Tizen SDK 10.0 Web CLI installer from `download.tizen.org` and validates its expected size.

Disable automatic dependency installation with `-SkipTizenInstall` on Windows or `--skip-tizen-install` on Linux.

## Requirements

### Windows

- Windows x64.
- Windows PowerShell 5.1 or PowerShell 7.
- Samsung TV running Tizen on the same network.
- Developer Mode enabled on the TV.

Administrator privileges are not required for the default Tizen path under `%LOCALAPPDATA%`.

### Linux

- x86_64 Linux.
- Bash 4+.
- Python 3 and standard utilities: `sha256sum`, `stat`, `sed`, `awk`, `grep`, and `mktemp`.
- Samsung TV running Tizen on the same network.
- Developer Mode enabled on the TV.

Run as a regular user, not root.

No GitHub token, Samsung credentials, or local certificate files are required. Jellyfin packages are the prebuilt and signed artifacts published by `jeppevinkel/jellyfin-tizen-builds`.

## Usage

### Windows

```powershell
$tvIp = Read-Host 'TV IP address'
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -TvIp $tvIp
```

PowerShell 7:

```powershell
pwsh -NoProfile -File .\install.ps1 -TvIp 192.168.1.100
```

Validate without downloading or installing Jellyfin:

```powershell
.\install.ps1 -TvIp 192.168.1.100 -ValidateOnly
```

Use another Tizen installation:

```powershell
.\install.ps1 -TvIp 192.168.1.100 -TizenStudioPath D:\tizen-studio
```

Require Tizen to already exist:

```powershell
.\install.ps1 -TvIp 192.168.1.100 -SkipTizenInstall
```

### Linux

```bash
chmod +x ./install.sh
./install.sh --tv-ip 192.168.1.100
```

Validate without downloading or installing Jellyfin:

```bash
./install.sh --tv-ip 192.168.1.100 --validate-only
```

Use another Tizen installation:

```bash
./install.sh --tv-ip 192.168.1.100 --tizen-studio-path "$HOME/tizen-studio"
```

Require Tizen to already exist:

```bash
./install.sh --tv-ip 192.168.1.100 --skip-tizen-install
```

### Alternative Jellyfin package

Windows:

```powershell
.\install.ps1 -TvIp 192.168.1.100 -AssetName Jellyfin-GrayFix.wgt
```

Linux:

```bash
./install.sh --tv-ip 192.168.1.100 --asset-name Jellyfin-GrayFix.wgt
```

The default package is `Jellyfin.wgt`.

## Enabling Developer Mode

If SDB cannot find the TV:

1. Open **Apps** on the TV.
2. Press `1 2 3 4 5` on the remote.
3. Enable **Developer Mode**.
4. Set **Host PC IP** to the local address displayed by the installer.
5. Fully restart the TV and run the installer again.

## Downloads and local data

Verified packages are cached under `downloads/<release>/` and reused when their SHA-256 digest still matches. Temporary Tizen installers are removed after installation. Neither installer stores the TV IP, PC IP, credentials, or Tizen Studio session data in the repository.
