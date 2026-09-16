# install.ps1
# Copies src\ into Playnite's extension folder. Re-run after any edit, then
# restart Playnite (it loads extensions once, at startup).
#
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$KeepSettings   # with -Uninstall, leave config.json in place
)

$ErrorActionPreference = 'Stop'

$ExtensionId  = 'AutoGameImporter_9f3c1a52-7d41-4b8e-9c20-5e6a1b8d4f77'
$FolderName   = 'AutoGameImporter'
$src          = Join-Path $PSScriptRoot 'src'
$extensions   = Join-Path $env:APPDATA 'Playnite\Extensions'
$target       = Join-Path $extensions $FolderName
$dataPath     = Join-Path $env:APPDATA "Playnite\ExtensionsData\$ExtensionId"

if (-not (Test-Path -LiteralPath $extensions)) {
    throw "Playnite extensions folder not found at $extensions. Is Playnite installed for this user?"
}

if (Get-Process -Name 'Playnite*' -ErrorAction SilentlyContinue) {
    Write-Warning 'Playnite is running. Close it before installing, or it will overwrite nothing until restart.'
}

if ($Uninstall) {
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
        Write-Host "Removed $target" -ForegroundColor Yellow
    }
    else { Write-Host 'Nothing installed.' }

    if (-not $KeepSettings -and (Test-Path -LiteralPath $dataPath)) {
        Remove-Item -LiteralPath $dataPath -Recurse -Force
        Write-Host "Removed $dataPath" -ForegroundColor Yellow
    }
    return
}

New-Item -ItemType Directory -Path $target -Force | Out-Null

# Mirror src\ without touching anything else in the folder.
Get-ChildItem -LiteralPath $src -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target $_.Name) -Force
    Write-Host "  $($_.Name)"
}

Write-Host "`nInstalled to $target" -ForegroundColor Green
Write-Host "Settings live in $dataPath\config.json"
Write-Host 'Restart Playnite to load it.' -ForegroundColor Cyan
