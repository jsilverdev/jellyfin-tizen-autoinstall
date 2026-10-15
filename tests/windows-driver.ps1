[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Installer,
    [Parameter(Mandatory = $true)]
    [string]$TvIp,
    [string]$TizenStudioPath,
    [string]$AssetName = 'Jellyfin.wgt',
    [string]$DownloadDirectory,
    [switch]$ValidateOnly,
    [switch]$SkipTizenInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Uri]$Uri,
        [hashtable]$Headers,
        [Parameter(Mandatory = $true)]
        [string]$OutFile,
        [switch]$UseBasicParsing
    )

    $parameters = @{
        Uri = $Uri
        OutFile = $OutFile
    }
    if ($null -ne $Headers) {
        $parameters.Headers = $Headers
    }

    Microsoft.PowerShell.Utility\Invoke-WebRequest @parameters

    if ($env:MOCK_CORRUPT_DOWNLOAD -eq '1' -and
        $Uri.Host -eq 'github.com' -and
        $Uri.AbsolutePath -match '/releases/download/' -and
        (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        $bytes = [IO.File]::ReadAllBytes($OutFile)
        if ($bytes.Length -eq 0) {
            throw 'Downloaded fixture is unexpectedly empty.'
        }
        $bytes[0] = $bytes[0] -bxor 1
        [IO.File]::WriteAllBytes($OutFile, $bytes)
    }
}

$forward = @{
    TvIp = $TvIp
    AssetName = $AssetName
}
if ($PSBoundParameters.ContainsKey('TizenStudioPath')) {
    $forward.TizenStudioPath = $TizenStudioPath
}
if ($PSBoundParameters.ContainsKey('DownloadDirectory')) {
    $forward.DownloadDirectory = $DownloadDirectory
}
if ($ValidateOnly) {
    $forward.ValidateOnly = $true
}
if ($SkipTizenInstall) {
    $forward.SkipTizenInstall = $true
}

& $Installer @forward
