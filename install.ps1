#Requires -Version 5.1
<#
.SYNOPSIS
    Install bfmediactl for the current user and add it to PATH.

.DESCRIPTION
    Copies bfmediactl.exe into %LOCALAPPDATA%\Programs\bfmediactl and appends
    that directory to the *user* PATH (HKCU\Environment). No administrator
    rights required. Idempotent: re-running updates the binary in place.

.PARAMETER InstallDir
    Target directory. Defaults to %LOCALAPPDATA%\Programs\bfmediactl.

.PARAMETER Binary
    Path to the built bfmediactl.exe. Defaults to zig-out\bin\bfmediactl.exe
    or bfmediactl.exe next to this script.

.PARAMETER Uninstall
    Remove the install directory and its PATH entry.

.EXAMPLE
    zig build; .\install.ps1

.EXAMPLE
    .\install.ps1 -Binary .\zig-out\bin\bfmediactl.exe

.EXAMPLE
    .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\bfmediactl'),
    [string]$Binary,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$exeName = 'bfmediactl.exe'

function Get-UserPath {
    [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Set-UserPath {
    param([string]$Value)
    [Environment]::SetEnvironmentVariable('Path', $Value, 'User')
}

function Test-PathEntry {
    param([string]$PathValue, [string]$Entry)
    if (-not $PathValue) { return $false }
    $target = $Entry.TrimEnd('\')
    foreach ($p in ($PathValue -split ';')) {
        if ($p -and ($p.TrimEnd('\') -ieq $target)) { return $true }
    }
    return $false
}

function Remove-PathEntry {
    param([string]$PathValue, [string]$Entry)
    $target = $Entry.TrimEnd('\')
    (($PathValue -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ine $target) }) -join ';'
}

if ($Uninstall) {
    if (Test-Path -LiteralPath $InstallDir) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Host "Removed $InstallDir"
    }
    $cur = Get-UserPath
    if (Test-PathEntry -PathValue $cur -Entry $InstallDir) {
        Set-UserPath (Remove-PathEntry -PathValue $cur -Entry $InstallDir)
        Write-Host "Removed $InstallDir from your PATH"
    }
    Write-Host 'Uninstalled. Restart your shell for the PATH change to take effect.'
    return
}

if (-not $Binary) {
    $candidates = @(
        (Join-Path $PSScriptRoot 'zig-out\bin\bfmediactl.exe'),
        (Join-Path $PSScriptRoot 'bfmediactl.exe')
    )
    $Binary = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $Binary -or -not (Test-Path -LiteralPath $Binary)) {
    throw "bfmediactl.exe not found. Build it first (zig build) or pass -Binary <path>."
}
$Binary = (Resolve-Path -LiteralPath $Binary).Path

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -LiteralPath $Binary -Destination (Join-Path $InstallDir $exeName) -Force
Write-Host "Installed $exeName -> $InstallDir"

$cur = Get-UserPath
if (Test-PathEntry -PathValue $cur -Entry $InstallDir) {
    Write-Host "$InstallDir is already on your PATH"
} else {
    $new = if ([string]::IsNullOrEmpty($cur)) { $InstallDir } else { $cur.TrimEnd(';') + ';' + $InstallDir }
    Set-UserPath $new
    Write-Host "Added $InstallDir to your PATH"
}

# Make it usable in the current session too.
if (-not (Test-PathEntry -PathValue $env:Path -Entry $InstallDir)) {
    $env:Path = "$InstallDir;$env:Path"
}

Write-Host ''
Write-Host 'Done. Try:  bfmediactl info'
Write-Host "If the command is not found yet, restart your shell."
