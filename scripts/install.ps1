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

function Assert-PowerShellSyntax {
    param([Parameter(Mandatory)][string[]]$Path)

    foreach ($parseFile in $Path) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($parseFile, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            $messages = $errors | ForEach-Object { "${parseFile}: $($_.Message)" }
            throw ($messages -join [Environment]::NewLine)
        }
    }
}

$sourceFiles = @($source) + @(
    Get-ChildItem -LiteralPath $sourceParts -Recurse -File |
        Where-Object Extension -in '.ps1', '.psm1' |
        Sort-Object FullName |
        ForEach-Object FullName
)
Assert-PowerShellSyntax -Path $sourceFiles

$targetDir = Split-Path -Parent $target
$targetParts = Join-Path $targetDir 'profile.d'
$transactionId = "$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID"
$stageRoot = Join-Path $targetDir ".pwsh-profile-stage-$transactionId"
$stageTarget = Join-Path $stageRoot (Split-Path -Leaf $target)
$stageParts = Join-Path $stageRoot 'profile.d'
$oldTarget = if ($NoBackup) { Join-Path $targetDir ".profile-entry.rollback-$transactionId" } else { "$target.bak-$transactionId" }
$oldParts = if ($NoBackup) { Join-Path $targetDir ".profile.d.rollback-$transactionId" } else { "$targetParts.bak-$transactionId" }

function Remove-InstallPath {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $parentPath = [System.IO.Path]::GetFullPath($targetDir).TrimEnd($trimChars) + [System.IO.Path]::DirectorySeparatorChar
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($parentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove install path outside target directory: $resolvedPath"
    }

    Remove-Item -LiteralPath $resolvedPath -Recurse -Force -ErrorAction Stop
}

New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
$oldTargetMoved = $false
$oldPartsMoved = $false
$newTargetMoved = $false
$newPartsMoved = $false
$installed = $false

try {
    New-Item -ItemType Directory -Force -Path $stageParts | Out-Null
    Copy-Item -LiteralPath $source -Destination $stageTarget
    Get-ChildItem -LiteralPath $sourceParts -Recurse -File |
        Where-Object Extension -in '.ps1', '.psm1' |
        ForEach-Object {
        $relative = [System.IO.Path]::GetRelativePath($sourceParts, $_.FullName)
        $destination = Join-Path $stageParts $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $destination
    }

    $stageFiles = @($stageTarget) + @(
        Get-ChildItem -LiteralPath $stageParts -Recurse -File |
            Where-Object Extension -in '.ps1', '.psm1' |
            Sort-Object FullName |
            ForEach-Object FullName
    )
    Assert-PowerShellSyntax -Path $stageFiles

    if (Test-Path -LiteralPath $target) {
        Move-Item -LiteralPath $target -Destination $oldTarget -ErrorAction Stop
        $oldTargetMoved = $true
    }
    if (Test-Path -LiteralPath $targetParts) {
        [System.IO.Directory]::Move($targetParts, $oldParts)
        $oldPartsMoved = $true
    }

    [System.IO.Directory]::Move($stageParts, $targetParts)
    $newPartsMoved = $true
    Move-Item -LiteralPath $stageTarget -Destination $target -ErrorAction Stop
    $newTargetMoved = $true
    $installed = $true
}
catch {
    $installError = $_
    $rollbackErrors = @()

    if ($newTargetMoved) {
        try { Remove-InstallPath -Path $target }
        catch { $rollbackErrors += $_.Exception.Message }
    }
    if ($newPartsMoved) {
        try { Remove-InstallPath -Path $targetParts }
        catch { $rollbackErrors += $_.Exception.Message }
    }
    if ($oldPartsMoved) {
        try { [System.IO.Directory]::Move($oldParts, $targetParts) }
        catch { $rollbackErrors += $_.Exception.Message }
    }
    if ($oldTargetMoved) {
        try { Move-Item -LiteralPath $oldTarget -Destination $target -ErrorAction Stop }
        catch { $rollbackErrors += $_.Exception.Message }
    }

    if ($rollbackErrors.Count -gt 0) {
        throw "Installation failed: $($installError.Exception.Message) Rollback failed: $($rollbackErrors -join '; ')"
    }
    throw $installError
}
finally {
    try { Remove-InstallPath -Path $stageRoot }
    catch { Write-Warning "Failed to remove staging directory: $($_.Exception.Message)" }
}

if ($installed -and $NoBackup) {
    foreach ($rollbackPath in @($oldTarget, $oldParts)) {
        try { Remove-InstallPath -Path $rollbackPath }
        catch { Write-Warning "Failed to remove rollback path: $($_.Exception.Message)" }
    }
}
elseif ($installed) {
    if ($oldTargetMoved) { Write-Host "Backup: $oldTarget" }
    if ($oldPartsMoved) { Write-Host "Backup: $oldParts" }
}

Write-Host "Installed: $target"
Write-Host "Installed profile parts: $targetParts"
