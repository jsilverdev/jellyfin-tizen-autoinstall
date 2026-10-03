# Jellyfin Tizen Auto-Install

A PowerShell installer that deploys the latest stable Jellyfin build to a
Samsung TV running Tizen.

The script performs the following steps in order:

1. Validates the TV address and the local Tizen Studio tools.
2. Detects the local IP address that must be configured as the TV's
   `Host PC IP`.
3. Connects to the TV over SDB and identifies the target device.
4. Queries the latest release from
   [`jeppevinkel/jellyfin-tizen-builds`](https://github.com/jeppevinkel/jellyfin-tizen-builds).
5. Downloads `Jellyfin.wgt` and verifies its size and SHA-256 digest against
   the release metadata returned by GitHub.
6. Installs the package with the Tizen CLI.
7. Confirms that Jellyfin appears in the TV's application list.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- Tizen Studio with its CLI tools. The default path is `C:\tizen-studio`.
- A Samsung TV running Tizen and connected to the same network as the PC.
- Developer Mode enabled on the TV.
- The TV's Developer Mode `Host PC IP` set to the local address displayed by
  the script.

No GitHub token, Samsung account credentials, or local certificate files are
required. The installer uses the prebuilt and signed packages published by the
upstream project.

## Usage

Open PowerShell in this directory and enter the TV address when prompted:

```powershell
$tvIp = Read-Host 'TV IP address'
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-JellyfinTizen.ps1 -TvIp $tvIp
```

Validate the tools, network connection, TV, and release metadata without
downloading or installing anything:

```powershell
$tvIp = Read-Host 'TV IP address'
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-JellyfinTizen.ps1 -TvIp $tvIp -ValidateOnly
```

Use a non-default Tizen Studio location:

```powershell
$tvIp = Read-Host 'TV IP address'
.\Install-JellyfinTizen.ps1 -TvIp $tvIp -TizenStudioPath D:\tizen-studio
```

Install another `.wgt` variant from the latest release:

```powershell
$tvIp = Read-Host 'TV IP address'
.\Install-JellyfinTizen.ps1 -TvIp $tvIp -AssetName Jellyfin-GrayFix.wgt
```

The default stable package is always `Jellyfin.wgt`.

## Enabling Developer Mode

If SDB cannot find the TV:

1. Open **Apps** on the TV.
2. Press `1 2 3 4 5` on the remote.
3. Enable **Developer Mode**.
4. Set **Host PC IP** to the local address displayed by the script.
5. Fully restart the TV and run the installer again.

## Downloads and local data

Verified packages are cached under `downloads/<release>/` and reused when the
SHA-256 digest still matches. The `downloads` directory and common credential,
certificate, environment, and log files are excluded by `.gitignore`.

The script does not store the TV address, the PC address, credentials, or Tizen
Studio session data in the repository.
