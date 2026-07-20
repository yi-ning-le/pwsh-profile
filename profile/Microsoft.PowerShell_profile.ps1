$profileModulePath = Join-Path $PSScriptRoot 'profile.d\PwshProfile.psm1'

try {
    Remove-Module -Name PwshProfile -Force -ErrorAction SilentlyContinue
    $profileModule = Import-Module $profileModulePath -Global -PassThru -ErrorAction Stop
    $restoreProfileCallerState = {
        param([hashtable] $PriorAliases, [scriptblock] $DefaultTabExpansion2)
        foreach ($entry in $PriorAliases.GetEnumerator()) {
            $currentAlias = Get-Alias -Name $entry.Key -ErrorAction SilentlyContinue
            $currentFunction = Get-Command -Name $entry.Key -CommandType Function -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($currentAlias -or ($currentFunction -and $currentFunction.ModuleName -cne 'PwshProfile')) {
                continue
            }
            Set-Alias -Name $entry.Key -Value $entry.Value.Definition -Description $entry.Value.Description `
                -Option $entry.Value.Options -Scope Global -Force
        }
        $currentTabExpansion2 = Get-Command TabExpansion2 -CommandType Function -ErrorAction SilentlyContinue
        if ($DefaultTabExpansion2 -and
            (-not $currentTabExpansion2 -or $currentTabExpansion2.ModuleName -ceq 'PwshProfile')) {
            Set-Item Function:global:TabExpansion2 -Value $DefaultTabExpansion2 -Force
        }
    }
    & $profileModule {
        param([scriptblock] $RestoreCallerState)
        $script:State.Resources.RestoreCallerState = $RestoreCallerState
    } $restoreProfileCallerState
    $escapedProfileEntryPath = $PSCommandPath.Replace("'", "''")
    $reloadScript = [scriptblock]::Create(@"
Update-Path
. '$escapedProfileEntryPath'
Write-Host 'env + profile reloaded.' -ForegroundColor Green
"@)
    Set-Item Function:global:reload -Force -Value $reloadScript
}
catch {
    Write-Warning "PowerShell profile module failed: $profileModulePath"
    Write-Warning $_.Exception.Message
}

Remove-Variable profileModulePath, profileModule, restoreProfileCallerState, `
    escapedProfileEntryPath, reloadScript -ErrorAction SilentlyContinue
