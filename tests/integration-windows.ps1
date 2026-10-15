[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootDirectory = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $rootDirectory 'install.ps1'
$driver = Join-Path $PSScriptRoot 'windows-driver.ps1'
$tempDirectory = Join-Path $env:RUNNER_TEMP "jellyfin-tizen-tests-$PID"
$fakeTizen = Join-Path $tempDirectory 'tizen-studio'
$downloadDirectory = Join-Path $tempDirectory 'downloads'
$badDownloadDirectory = Join-Path $tempDirectory 'bad-downloads'
$sdbPath = Join-Path $fakeTizen 'tools\sdb.exe'
$tizenPath = Join-Path $fakeTizen 'tools\ide\bin\tizen.bat'

New-Item -ItemType Directory -Path (Split-Path -Parent $sdbPath) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $tizenPath) -Force | Out-Null

$sdbProjectDirectory = Join-Path $tempDirectory 'sdb-project'
New-Item -ItemType Directory -Path $sdbProjectDirectory -Force | Out-Null
$sdbSourcePath = Join-Path $sdbProjectDirectory 'Program.cs'
$sdbProjectPath = Join-Path $sdbProjectDirectory 'sdb.csproj'
@'
using System;

public static class Program
{
    public static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("Missing sdb command");
            return 2;
        }

        switch (args[0])
        {
            case "start-server":
                return 0;
            case "connect":
                Console.WriteLine("connected to " + (args.Length > 1 ? args[1] : "unknown"));
                return 0;
            case "devices":
                Console.WriteLine("List of devices attached");
                if (Environment.GetEnvironmentVariable("MOCK_NO_DEVICE") != "1")
                {
                    Console.WriteLine("127.0.0.1:26101 device MOCK-TV");
                }
                return 0;
            case "shell":
                if (args.Length >= 3 && args[1] == "0" && args[2] == "applist")
                {
                    if (Environment.GetEnvironmentVariable("MOCK_APP_MISSING") == "1")
                    {
                        Console.WriteLine("mock.other OtherApp");
                    }
                    else
                    {
                        Console.WriteLine("mock.jellyfin Jellyfin");
                    }
                    return 0;
                }
                break;
        }

        Console.Error.WriteLine("Unexpected sdb invocation: " + string.Join(" ", args));
        return 2;
    }
}
'@ | Set-Content -LiteralPath $sdbSourcePath -Encoding UTF8

@'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <UseAppHost>true</UseAppHost>
    <ImplicitUsings>disable</ImplicitUsings>
    <Nullable>disable</Nullable>
  </PropertyGroup>
</Project>
'@ | Set-Content -LiteralPath $sdbProjectPath -Encoding UTF8

$nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
if ($null -ne $nativePreferenceVariable) {
    $global:PSNativeCommandUseErrorActionPreference = $false
}

& dotnet publish $sdbProjectPath --configuration Release --output (Split-Path -Parent $sdbPath) --nologo
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $sdbPath -PathType Leaf)) {
    throw 'Failed to build the mock sdb.exe.'
}

@'

@echo off
if "%1"=="version" (
  echo Tizen CLI 1.0 mock
  exit /b 0
)
if "%1"=="install" (
  if "%MOCK_INSTALL_FAIL%"=="1" (
    echo Simulated install failure 1>&2
    exit /b 1
  )
  echo Tizen application is successfully installed. app_id[mock.jellyfin]
  exit /b 0
)
echo Unexpected tizen invocation: %* 1>&2
exit /b 2
'@ | Set-Content -LiteralPath $tizenPath -Encoding ASCII

function Invoke-Installer {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$InstallerArguments,
        [hashtable]$Environment = @{},
        [switch]$UseDownloadDriver
    )

    $savedEnvironment = @{}
    foreach ($name in $Environment.Keys) {
        $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name], 'Process')
    }

    try {
        if ($UseDownloadDriver) {
            $lines = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $driver -Installer $installer @InstallerArguments 2>&1)
        }
        else {
            $lines = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $installer @InstallerArguments 2>&1)
        }
        $exitCode = $LASTEXITCODE
        $output = $lines -join [Environment]::NewLine
        Write-Host $output
        return [PSCustomObject]@{
            ExitCode = $exitCode
            Output = $output
        }
    }
    finally {
        foreach ($name in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }
}

function Assert-Success {
    param(
        [string]$name,
        [string[]]$InstallerArguments,
        [hashtable]$Environment = @{},
        [switch]$UseDownloadDriver
    )
    Write-Host "`n--- $name ---"
    $result = Invoke-Installer -InstallerArguments $InstallerArguments -Environment $Environment -UseDownloadDriver:$UseDownloadDriver
    if ($result.ExitCode -ne 0) {
        throw "$name failed with exit code $($result.ExitCode)."
    }
    return $result
}

function Assert-FailureContains {
    param(
        [string]$name,
        [string]$Expected,
        [string[]]$InstallerArguments,
        [hashtable]$Environment = @{},
        [switch]$UseDownloadDriver
    )
    Write-Host "`n--- $name ---"
    $result = Invoke-Installer -InstallerArguments $InstallerArguments -Environment $Environment -UseDownloadDriver:$UseDownloadDriver
    if ($result.ExitCode -eq 0) {
        throw "$name unexpectedly succeeded."
    }
    if (-not $result.Output.Contains($Expected)) {
        throw "$name did not contain expected text: $Expected"
    }
    return $result
}

try {
    $common = @(
        '-TvIp', '127.0.0.1',
        '-TizenStudioPath', $fakeTizen,
        '-DownloadDirectory', $downloadDirectory
    )

    $null = Assert-FailureContains -Name 'invalid IPv4' -Expected 'no es una direccion IPv4 valida' -InstallerArguments @(
        '-TvIp', '999.1.1.1', '-TizenStudioPath', $fakeTizen
    )

    $null = Assert-FailureContains -Name 'invalid asset path' -Expected 'AssetName debe ser solamente' -InstallerArguments @(
        '-TvIp', '127.0.0.1', '-TizenStudioPath', $fakeTizen, '-AssetName', 'nested\bad.wgt'
    )

    $null = Assert-FailureContains -Name 'missing Tizen with skip flag' -Expected '-SkipTizenInstall esta habilitado' -InstallerArguments @(
        '-TvIp', '127.0.0.1', '-TizenStudioPath', (Join-Path $tempDirectory 'missing-tizen'), '-SkipTizenInstall'
    )

    $validateResult = Assert-Success -Name 'validate-only against real GitHub release' -InstallerArguments ($common + '-ValidateOnly')
    if (-not $validateResult.Output.Contains('Validacion completada')) {
        throw 'validate-only confirmation missing.'
    }
    if (Get-ChildItem -LiteralPath $downloadDirectory -Filter '*.wgt' -File -Recurse -ErrorAction SilentlyContinue) {
        throw 'validate-only downloaded a WGT file.'
    }

    $successResult = Assert-Success -Name 'full install flow with real WGT and mocked TV' -InstallerArguments $common
    if (-not $successResult.Output.Contains('Jellyfin se instalo y verifico correctamente')) {
        throw 'success confirmation missing.'
    }
    $package = Get-ChildItem -LiteralPath $downloadDirectory -Filter 'Jellyfin.wgt' -File -Recurse | Select-Object -First 1
    if ($null -eq $package -or $package.Length -eq 0) {
        throw 'verified WGT was not cached.'
    }

    Set-Content -LiteralPath $package.FullName -Value 'corrupt-cache' -NoNewline
    $cacheResult = Assert-Success -Name 'corrupt cached package is replaced' -InstallerArguments $common
    if (-not $cacheResult.Output.Contains('no coincide con GitHub y sera reemplazado')) {
        throw 'corrupt cache was not detected.'
    }
    if ((Get-Item -LiteralPath $package.FullName).Length -le 1000) {
        throw 'corrupt cache was not replaced.'
    }

    $null = Assert-FailureContains -Name 'SHA-256 mismatch is rejected' -Expected 'SHA-256 incorrecto' -InstallerArguments @(
        '-TvIp', '127.0.0.1',
        '-TizenStudioPath', $fakeTizen,
        '-DownloadDirectory', $badDownloadDirectory
    ) -Environment @{ MOCK_CORRUPT_DOWNLOAD = '1' } -UseDownloadDriver

    $null = Assert-FailureContains -Name 'missing release asset' -Expected 'no contiene el asset' -InstallerArguments ($common + @(
        '-AssetName', 'DoesNotExist.wgt'
    ))

    $null = Assert-FailureContains -Name 'SDB without TV' -Expected 'No se pudo validar la TV mediante SDB' -InstallerArguments $common -Environment @{
        MOCK_NO_DEVICE = '1'
    }

    $null = Assert-FailureContains -Name 'Tizen install failure' -Expected 'Tizen Studio no confirmo la instalacion' -InstallerArguments $common -Environment @{
        MOCK_INSTALL_FAIL = '1'
    }

    $null = Assert-FailureContains -Name 'installed app missing from applist' -Expected 'Jellyfin no aparece en la lista de aplicaciones' -InstallerArguments $common -Environment @{
        MOCK_APP_MISSING = '1'
    }

    Write-Host "`nAll Windows integration tests passed."
}
finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
