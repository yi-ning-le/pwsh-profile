$profileRoot = $PSScriptRoot
$script:__PwshProfileCommandLine = [Environment]::GetCommandLineArgs()
$script:__PwshProfileIsBatch = [bool]($script:__PwshProfileCommandLine -match '(?i)^-(Command|c|File|f|EncodedCommand|ec)$')
$script:__PwshProfileHasNoExit = [bool]($script:__PwshProfileCommandLine -match '(?i)^-(NoExit|noe)$')
$script:__PwshProfileIsInteractive = $Host.Name -eq 'ConsoleHost' -and
    -not [Console]::IsInputRedirected -and
    -not [Console]::IsOutputRedirected -and
    (-not $script:__PwshProfileIsBatch -or $script:__PwshProfileHasNoExit)

$profileParts = @(
    'profile.d\20-node.ps1',
    'profile.d\10-prompt.ps1',
    'profile.d\25-icons.ps1'
    if ($script:__PwshProfileIsInteractive) {
        'profile.d\30-psreadline.ps1'
        'profile.d\40-completion.ps1'
    }
    'profile.d\50-aliases.ps1',
    'profile.d\60-utils.ps1'
)

foreach ($profilePart in $profileParts) {
    $profilePartPath = Join-Path $profileRoot $profilePart
    if (-not (Test-Path -LiteralPath $profilePartPath)) {
        Write-Warning "PowerShell profile part not found: $profilePartPath"
        continue
    }

    try {
        . $profilePartPath
    }
    catch {
        Write-Warning "PowerShell profile part failed: $profilePartPath"
        Write-Warning $_.Exception.Message
    }
}
