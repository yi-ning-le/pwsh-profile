[CmdletBinding()]
param(
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repoRoot 'profile\Microsoft.PowerShell_profile.ps1'
$sourceParts = Join-Path $repoRoot 'profile\profile.d'
$target = $PROFILE.CurrentUserCurrentHost

if (-not (Test-Path -LiteralPath $source)) {
    throw "Profile source not found: $source"
}
if (-not (Test-Path -LiteralPath $sourceParts)) {
    throw "Profile parts not found: $sourceParts"
}

$targetDir = Split-Path -Parent $target
$targetParts = Join-Path $targetDir 'profile.d'
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
New-Item -ItemType Directory -Force -Path $targetParts | Out-Null

if ((Test-Path -LiteralPath $target) -and -not $NoBackup) {
    $backup = "$target.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $target -Destination $backup -Force
    Write-Host "Backup: $backup"
}

Copy-Item -LiteralPath $source -Destination $target -Force
Get-ChildItem -LiteralPath $sourceParts -Recurse -File -Filter '*.ps1' | ForEach-Object {
    $relative = $_.FullName.Substring($sourceParts.Length + 1)
    $destination = Join-Path $targetParts $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
}

$parseFiles = @($target) + @(Get-ChildItem -LiteralPath $targetParts -Recurse -File -Filter '*.ps1' | Sort-Object FullName | ForEach-Object FullName)
foreach ($parseFile in $parseFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($parseFile, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Error "${parseFile}: $($_.Message)" }
        exit 1
    }
}

Write-Host "Installed: $target"
Write-Host "Installed profile parts: $targetParts"
