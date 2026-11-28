<#
.SYNOPSIS
  Builds the Windows release of GOTTA.BIKE: BLE Watts: a portable zip and an
  Inno Setup installer, plus SHA256SUMS-windows.txt.

.DESCRIPTION
  Needs Windows 10/11 x64 with Flutter, Visual Studio 2022 (or its Build
  Tools) with the "Desktop development with C++" workload, and Inno Setup 6
  (`choco install innosetup` or `winget install JRSoftware.InnoSetup`).
  Flutter can't cross-compile Windows apps, so this runs on Windows only:
  on a Windows PC, or in .github/workflows/windows.yml.

  Output, in build\windows\dist\:
    GOTTA.BIKE-BLE-Watts-<version>-windows-x64-setup.exe   installer
    GOTTA.BIKE-BLE-Watts-<version>-windows-x64.zip         portable copy
    SHA256SUMS-windows.txt

  The files are NOT code-signed; see store/windows-distribution.md.

.PARAMETER Version
  X.Y.Z. Defaults to the X.Y.Z part of `version:` in pubspec.yaml.

.EXAMPLE
  pwsh tool/build_windows.ps1
  pwsh tool/build_windows.ps1 -Version 1.2.0
#>
param([string]$Version = "")

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Checked {
  param([string]$Exe, [string[]]$Arguments)
  & $Exe @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $root

if (-not $Version) {
  $line = Select-String -Path pubspec.yaml -Pattern '^version:\s*(\d+\.\d+\.\d+)' |
    Select-Object -First 1
  if (-not $line) { throw "couldn't read version: from pubspec.yaml" }
  $Version = $line.Matches[0].Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "the version must look like 1.2.3 (got '$Version')" }
Write-Host "==> Building GOTTA.BIKE BLE Watts $Version for Windows x64"

# Windows file versions hold 16-bit parts, so the Android-style build number
# (e.g. 1002000) doesn't fit; Windows gets X.Y.Z.0.
Invoke-Checked flutter @("build", "windows", "--release", "--build-name", $Version, "--build-number", "0")

$release = Join-Path $root "build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $release "gotta_bike_ble_watts.exe"))) {
  throw "the build didn't produce $release\gotta_bike_ble_watts.exe"
}

# App-local Visual C++ runtime, so a PC without the VC++ Redistributable can
# run the app (Microsoft allows redistributing these files with an app).
foreach ($dll in @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")) {
  $src = Join-Path $env:WINDIR "System32\$dll"
  if (-not (Test-Path $src)) { throw "$src is missing; install the VC++ 2015-2022 x64 Redistributable" }
  Copy-Item $src $release -Force
}

$dist = Join-Path $root "build\windows\dist"
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist | Out-Null
$base = "GOTTA.BIKE-BLE-Watts-$Version-windows-x64"

Write-Host "==> Zipping the portable copy"
Compress-Archive -Path (Join-Path $release "*") -DestinationPath (Join-Path $dist "$base.zip")

Write-Host "==> Building the installer"
$iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
$isccPath = if ($iscc) { $iscc.Source } else { Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe" }
if (-not (Test-Path $isccPath)) { throw "Inno Setup 6 (ISCC.exe) not found; install it with: choco install innosetup" }
Invoke-Checked $isccPath @("/Qp", "/DAppVersion=$Version", "/DSourceDir=$release", "/O$dist", (Join-Path $root "windows\installer\setup.iss"))

Write-Host "==> Checksums"
$sums = @(Get-ChildItem $dist -File | Sort-Object Name | ForEach-Object {
  "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
})
Set-Content -Path (Join-Path $dist "SHA256SUMS-windows.txt") -Value $sums -Encoding ascii

Get-ChildItem $dist | Format-Table Name, Length -AutoSize
