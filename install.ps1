[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TvIp,
    [string]$TizenStudioPath = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'TizenStudio'),
    [ValidatePattern('\.wgt$')]
    [string]$AssetName = 'Jellyfin.wgt',
    [string]$DownloadDirectory,
    [switch]$ValidateOnly,
    [switch]$SkipTizenInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DownloadDirectory)) {
    $DownloadDirectory = Join-Path $PSScriptRoot 'downloads'
}

$repository = 'jeppevinkel/jellyfin-tizen-builds'
$latestReleaseApi = "https://api.github.com/repos/$repository/releases/latest"
$tizenSdkVersion = '10.0'
$tizenInstallerUri = "https://download.tizen.org/sdk/Installer/tizen-sdk_$tizenSdkVersion/web-cli_Tizen_SDK_${tizenSdkVersion}_windows-64.exe"
$tizenInstallerSize = 373556224

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$Quiet
    )

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(
            & $FilePath @ArgumentList 2>&1 | ForEach-Object {
                $line = $_.ToString()
                if (-not $Quiet) { Write-Host $line }
                $line
            }
        )
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }

    [PSCustomObject]@{
        ExitCode = $exitCode
        Lines = $lines
        Text = $lines -join [Environment]::NewLine
    }
}

function Get-LocalAddressForTarget {
    param([string]$RemoteAddress)
    $udpClient = New-Object System.Net.Sockets.UdpClient
    try {
        $udpClient.Connect($RemoteAddress, 26101)
        return $udpClient.Client.LocalEndPoint.Address.IPAddressToString
    }
    finally {
        $udpClient.Dispose()
    }
}

function Get-SafeDirectoryName {
    param([string]$Name)
    return $Name -replace '[\\/:*?"<>|]', '_'
}

function Get-TizenToolPaths {
    param([string]$Root)
    [PSCustomObject]@{
        Sdb = Join-Path $Root 'tools\sdb.exe'
        Tizen = Join-Path $Root 'tools\ide\bin\tizen.bat'
    }
}

function Test-TizenTools {
    param([string]$Root)
    $paths = Get-TizenToolPaths -Root $Root
    return (Test-Path -LiteralPath $paths.Sdb -PathType Leaf) -and
        (Test-Path -LiteralPath $paths.Tizen -PathType Leaf)
}

function Install-TizenCli {
    param([string]$Destination)

    if ($SkipTizenInstall) {
        throw "Tizen Studio CLI no esta disponible en '$Destination' y -SkipTizenInstall esta habilitado."
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'La auto-instalacion de Tizen SDK requiere Windows de 64 bits.'
    }

    Write-Step "Tizen CLI no encontrado; instalando Tizen SDK $tizenSdkVersion"
    Write-Host "Destino: $Destination"
    Write-Host "Fuente: $tizenInstallerUri"

    $installerPath = Join-Path ([IO.Path]::GetTempPath()) "jellyfin-tizen-autoinstall-$PID.exe"
    try {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force
        }

        $installerUri = [Uri]$tizenInstallerUri
        if ($installerUri.Scheme -ne 'https' -or $installerUri.Host -ne 'download.tizen.org') {
            throw "Origen no permitido para el instalador de Tizen SDK: $tizenInstallerUri"
        }

        Invoke-WebRequest -Uri $tizenInstallerUri -OutFile $installerPath -UseBasicParsing

        $downloadedInstaller = Get-Item -LiteralPath $installerPath
        if ($downloadedInstaller.Length -ne [long]$tizenInstallerSize) {
            throw "Tamano inesperado del instalador de Tizen SDK: $($downloadedInstaller.Length) bytes. Esperado: $tizenInstallerSize."
        }

        $signature = Get-AuthenticodeSignature -FilePath $installerPath
        switch ($signature.Status) {
            ([System.Management.Automation.SignatureStatus]::Valid) {
                Write-Host 'OK: firma Authenticode valida.'
            }
            ([System.Management.Automation.SignatureStatus]::NotSigned) {
                Write-Warning 'El instalador Web CLI oficial de Tizen no tiene firma Authenticode. Se continuara tras validar origen HTTPS oficial y tamano exacto.'
            }
            default {
                throw "La firma Authenticode del instalador de Tizen SDK tiene un estado invalido: $($signature.Status)."
            }
        }

        $parentDirectory = Split-Path -Parent $Destination
        if (-not [string]::IsNullOrWhiteSpace($parentDirectory)) {
            New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
        }

        $installResult = Invoke-NativeCapture -FilePath $installerPath -ArgumentList @(
            '--accept-license', '--no-java-check', $Destination
        )
        if ($installResult.ExitCode -ne 0) {
            throw "El instalador de Tizen SDK termino con codigo $($installResult.ExitCode).`n$($installResult.Text)"
        }

        if (-not (Test-TizenTools -Root $Destination)) {
            throw "Tizen SDK termino de instalarse, pero no se encontraron sdb.exe y tizen.bat en '$Destination'."
        }

        Write-Host "OK: Tizen SDK instalado en $Destination"
    }
    finally {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force
        }
    }
}

try {
    Write-Step 'Validando parametros y Tizen Studio'

    $parsedTvIp = $null
    if (-not [System.Net.IPAddress]::TryParse($TvIp, [ref]$parsedTvIp) -or
        $parsedTvIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "La IP de la TV no es una direccion IPv4 valida: $TvIp"
    }
    if ([System.IO.Path]::GetFileName($AssetName) -ne $AssetName) {
        throw "AssetName debe ser solamente un nombre de archivo .wgt: $AssetName"
    }

    if (-not (Test-TizenTools -Root $TizenStudioPath)) {
        Install-TizenCli -Destination $TizenStudioPath
    }

    $resolvedTizenStudioPath = (Resolve-Path -LiteralPath $TizenStudioPath).Path
    $tizenTools = Get-TizenToolPaths -Root $resolvedTizenStudioPath
    $sdbPath = $tizenTools.Sdb
    $tizenPath = $tizenTools.Tizen

    $tizenVersion = Invoke-NativeCapture -FilePath $tizenPath -ArgumentList @('version') -Quiet
    if ($tizenVersion.ExitCode -ne 0) {
        throw "Tizen CLI no funciona correctamente.`n$($tizenVersion.Text)"
    }
    $versionLine = $tizenVersion.Lines | Where-Object { $_ -match 'Tizen CLI|Tizen SDK' } | Select-Object -First 1
    if ($versionLine) { Write-Host "OK: $versionLine" } else { Write-Host 'OK: Tizen CLI respondio correctamente.' }

    $pcIp = Get-LocalAddressForTarget -RemoteAddress $TvIp
    Write-Host "IP de esta PC para Developer Mode: $pcIp"
    Write-Host "IP de la TV: $TvIp"

    $pingSucceeded = Test-Connection -ComputerName $TvIp -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($pingSucceeded) { Write-Host 'OK: la TV responde en la red.' }
    else { Write-Warning 'La TV no respondio al ping. Se intentara SDB porque algunos dispositivos bloquean ICMP.' }

    Write-Step 'Validando Developer Mode y conexion SDB'
    $null = Invoke-NativeCapture -FilePath $sdbPath -ArgumentList @('start-server') -Quiet
    $endpoint = "${TvIp}:26101"
    $connectResult = Invoke-NativeCapture -FilePath $sdbPath -ArgumentList @('connect', $endpoint)
    $devicesResult = Invoke-NativeCapture -FilePath $sdbPath -ArgumentList @('devices') -Quiet

    $escapedIp = [regex]::Escape($TvIp)
    $devicePattern = "(?m)^\s*$escapedIp(?::26101)?\s+device\s+(\S+)\s*$"
    $deviceMatch = [regex]::Match($devicesResult.Text, $devicePattern)
    if (-not $deviceMatch.Success) {
        throw @"
No se pudo validar la TV mediante SDB.

En la TV abre Apps, pulsa 1 2 3 4 5 y confirma:
  Developer Mode: ON
  Host PC IP: $pcIp

Despues reinicia completamente la TV y vuelve a ejecutar el script.
Detalle SDB:
$($connectResult.Text)
$($devicesResult.Text)
"@
    }

    $targetName = $deviceMatch.Groups[1].Value
    Write-Host "OK: dispositivo detectado: $targetName ($endpoint)"

    Write-Step 'Consultando el release estable mas reciente'

    if (-not ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12)) {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'jellyfin-tizen-autoinstall'
    }
    $release = Invoke-RestMethod -Uri $latestReleaseApi -Headers $headers
    $asset = @($release.assets | Where-Object { $_.name -eq $AssetName }) | Select-Object -First 1

    if ($null -eq $asset) {
        throw "El release $($release.tag_name) no contiene el asset $AssetName."
    }
    if ([string]::IsNullOrWhiteSpace([string]$asset.digest) -or
        -not ([string]$asset.digest).StartsWith('sha256:', [StringComparison]::OrdinalIgnoreCase)) {
        throw "GitHub no publico un digest SHA-256 valido para $AssetName; no se instalara un paquete sin verificar."
    }

    Write-Host "OK: release $($release.tag_name)"
    Write-Host "Asset: $($asset.name) ($($asset.size) bytes)"
    Write-Host "Digest esperado: $($asset.digest)"

    if ($ValidateOnly) {
        Write-Host "`nValidacion completada. No se descargo ni instalo ningun paquete Jellyfin." -ForegroundColor Green
        exit 0
    }

    Write-Step 'Descargando y verificando el paquete'
    $safeTag = Get-SafeDirectoryName -Name ([string]$release.tag_name)
    $releaseDirectory = Join-Path $DownloadDirectory $safeTag
    $packagePath = Join-Path $releaseDirectory $AssetName
    $partialPath = "$packagePath.partial"
    New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null

    $packageIsValid = $false
    if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
        $existingHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $packageIsValid = "sha256:$existingHash" -eq ([string]$asset.digest).ToLowerInvariant()
        if ($packageIsValid) { Write-Host 'El paquete ya existe y su SHA-256 es correcto; se reutilizara.' }
        else {
            Write-Warning 'El paquete existente no coincide con GitHub y sera reemplazado.'
            Remove-Item -LiteralPath $packagePath -Force
        }
    }

    if (-not $packageIsValid) {
        if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force }
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $partialPath -UseBasicParsing
            $downloadedFile = Get-Item -LiteralPath $partialPath
            if ($downloadedFile.Length -ne [long]$asset.size) {
                throw "Tamano incorrecto: se descargaron $($downloadedFile.Length) bytes y GitHub anuncio $($asset.size)."
            }
            $actualHash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $actualDigest = "sha256:$actualHash"
            if ($actualDigest -ne ([string]$asset.digest).ToLowerInvariant()) {
                throw "SHA-256 incorrecto. Esperado: $($asset.digest). Obtenido: $actualDigest"
            }
            Move-Item -LiteralPath $partialPath -Destination $packagePath -Force
            $packageIsValid = $true
        }
        finally {
            if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force }
        }
    }

    if (-not $packageIsValid) { throw 'No se pudo validar el paquete descargado.' }

    $finalDigest = 'sha256:' + (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "OK: paquete verificado: $packagePath"
    Write-Host "SHA-256: $finalDigest"

    Write-Step "Instalando $AssetName en $targetName"
    Push-Location -LiteralPath $releaseDirectory
    try {
        $installResult = Invoke-NativeCapture -FilePath $tizenPath -ArgumentList @(
            'install', '-n', $AssetName, '-t', $targetName
        )
    }
    finally {
        Pop-Location
    }

    if ($installResult.ExitCode -ne 0 -or
        $installResult.Text -notmatch 'Tizen application is successfully installed|Installed the package') {
        throw @"
Tizen Studio no confirmo la instalacion.
Si existe otra compilacion firmada con un certificado diferente, desinstalala desde el menu de aplicaciones de la TV y vuelve a intentarlo.
"@
    }

    $appId = $null
    if ($installResult.Text -match 'Id\(([^)]+)\)') { $appId = $Matches[1] }
    elseif ($installResult.Text -match 'app_id\[([^]]+)\]') { $appId = $Matches[1] }

    Write-Step 'Verificando la aplicacion instalada'
    $appListResult = Invoke-NativeCapture -FilePath $sdbPath -ArgumentList @('shell', '0', 'applist') -Quiet
    if ($appListResult.ExitCode -ne 0) {
        throw "No se pudo consultar la lista final de aplicaciones.`n$($appListResult.Text)"
    }

    $appWasFound = $appListResult.Text -match "(?i)\bJellyfin\b"
    if ($appId) { $appWasFound = $appWasFound -and $appListResult.Text.Contains($appId) }
    if (-not $appWasFound) {
        throw 'La instalacion informo exito, pero Jellyfin no aparece en la lista de aplicaciones de la TV.'
    }

    Write-Host "`nJellyfin se instalo y verifico correctamente." -ForegroundColor Green
    Write-Host "TV: $targetName ($TvIp)"
    Write-Host "Release: $($release.tag_name)"
    if ($appId) { Write-Host "App ID: $appId" }
    Write-Host "Paquete: $packagePath"
    exit 0
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
