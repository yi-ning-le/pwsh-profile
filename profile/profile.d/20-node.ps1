# ---- fnm (Node version manager, replaces nvm-windows) ----
# Auto-switch Node versions when entering directories with .node-version / .nvmrc (--use-on-cd, like zsh nvm autoload).
if (Get-Command fnm -CommandType Application -ErrorAction SilentlyContinue) {
    $__fnmEnv = fnm env --use-on-cd --shell powershell | Out-String
    $__fnmExitCode = $global:LASTEXITCODE
    if ($__fnmExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($__fnmEnv)) {
        Remove-Variable __fnmEnv, __fnmExitCode -ErrorAction SilentlyContinue
        Write-Warning 'fnm environment initialization failed; Node command wrappers were not installed.'
        return
    }

    $__fnmEnv = $__fnmEnv -replace '\s*-Or\s*\(Test-Path\s+package\.json\)', ''
    $__fnmEnv | Invoke-Expression
    Remove-Variable __fnmEnv, __fnmExitCode -ErrorAction SilentlyContinue

    # Lazy-load fallback: on first node/npm/pnpm/yarn call, switch default to a concrete version.
    # This avoids running fnm list/fnm use on every shell start while still bypassing Windows junction double-hop resolution issues.
    $script:__fnmDefaultInitialized = $false
    function Initialize-FnmDefaultOnce {
        if ($script:__fnmDefaultInitialized) { return }
        if ((Test-Path .node-version) -or (Test-Path .nvmrc)) { return }

        $script:__fnmDefaultInitialized = $true
        $__fnmDefault = (fnm list 2>$null | Where-Object { $_ -match 'default' } |
            ForEach-Object { if ($_ -match 'v(\d+\.\d+\.\d+)') { $Matches[1] } } | Select-Object -First 1)
        if ($__fnmDefault) { fnm use $__fnmDefault 2>$null | Out-Null }
        Remove-Variable __fnmDefault -ErrorAction SilentlyContinue
    }

    foreach ($__fnmCommand in 'node', 'npm', 'npx', 'pnpm', 'yarn', 'corepack') {
        Set-Item -Path "function:\$__fnmCommand" -Value {
            Initialize-FnmDefaultOnce
            $__cmd = $MyInvocation.MyCommand.Name
            $__target = Get-Command "$__cmd.exe", "$__cmd.cmd", "$__cmd.ps1" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $__target) { $__target = Get-Command $__cmd -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
            & $__target.Source @args
        }.GetNewClosure()
    }
    Remove-Variable __fnmCommand -ErrorAction SilentlyContinue
}
