# ---- Node toolchain (mise shims on PATH; npm/npx run through mise and the job runner) ----
# `npm` and `npx` skip the npm.cmd/npx.cmd batch wrappers: `mise x` resolves node for the current
# directory (installing a pinned version when needed) and runs npm-cli.js / npx-cli.js directly, so
# no cmd.exe batch layer sits between Ctrl+C and node. `npm run`, `npm run-script`, and every `npx`
# invocation execute under the Job Object runner. For the duration of a call, npm scripts run in Git
# Bash with MSYS path conversion disabled; the session environment is restored afterwards.
$script:State.Node = @{
    Mise = $null
    ScriptShell = $null
}

function Resolve-NodeScriptShell {
    if ($env:npm_config_script_shell) { return $env:npm_config_script_shell }
    if ($null -ne $script:State.Node.ScriptShell) { return $script:State.Node.ScriptShell }

    $shell = ''
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $directory = Split-Path -Parent $git.Source
        for ($depth = 0; $depth -lt 3 -and $directory; $depth++) {
            $candidate = Join-Path $directory 'bin\bash.exe'
            if ([System.IO.File]::Exists($candidate)) { $shell = $candidate; break }
            $directory = Split-Path -Parent $directory
        }
    }
    if (-not $shell) { Write-Warning 'Git Bash was not found; npm scripts will run under cmd.exe.' }
    $script:State.Node.ScriptShell = $shell
    $shell
}

function Resolve-MiseNodeCli {
    param([Parameter(Mandatory)][string] $CliName)

    if (-not $script:State.Node.Mise) {
        $script:State.Node.Mise = if ($env:PWSH_MISE_PATH) {
            $env:PWSH_MISE_PATH
        }
        else {
            (Resolve-PwshNativeCommand -Name 'mise').Source
        }
    }
    $mise = $script:State.Node.Mise

    $nodeExe = @(& $mise x -- node -p 'process.execPath' | Where-Object { "$_".Trim() }) | Select-Object -Last 1
    if ($global:LASTEXITCODE -ne 0 -or -not $nodeExe) {
        throw "mise could not resolve node for $PWD"
    }
    $cli = Join-Path (Split-Path -Parent "$nodeExe".Trim()) "node_modules\npm\bin\$CliName"
    if (-not [System.IO.File]::Exists($cli)) {
        throw "$CliName not found next to node: $cli"
    }

    [pscustomobject]@{
        Mise = $mise
        Arguments = [string[]]@('x', '--', 'node', $cli)
    }
}

function Invoke-NodeCli {
    param(
        [Parameter(Mandatory)][string] $CliName,
        [Parameter(Mandatory)][bool] $UseJobRunner,
        [AllowEmptyCollection()][string[]] $Arguments = @()
    )

    $resolved = Resolve-MiseNodeCli -CliName $CliName
    $cliArguments = [string[]]($resolved.Arguments + $Arguments)
    $oldScriptShell = $env:npm_config_script_shell
    $oldPathConversion = $env:MSYS_NO_PATHCONV
    try {
        $scriptShell = Resolve-NodeScriptShell
        if ($scriptShell) {
            $env:npm_config_script_shell = $scriptShell
            $env:MSYS_NO_PATHCONV = '1'
        }
        if ($UseJobRunner) {
            Invoke-JobProcess -FilePath $resolved.Mise -ArgumentList $cliArguments
        }
        else {
            & $resolved.Mise @cliArguments
        }
    }
    finally {
        if ($null -eq $oldScriptShell) { Remove-Item Env:npm_config_script_shell -ErrorAction SilentlyContinue }
        else { $env:npm_config_script_shell = $oldScriptShell }
        if ($null -eq $oldPathConversion) { Remove-Item Env:MSYS_NO_PATHCONV -ErrorAction SilentlyContinue }
        else { $env:MSYS_NO_PATHCONV = $oldPathConversion }
    }
}

function npm {
    $useJobRunner = $args.Count -gt 0 -and $args[0] -in 'run', 'run-script'
    Invoke-NodeCli -CliName 'npm-cli.js' -UseJobRunner $useJobRunner -Arguments ([string[]]$args)
}

function npx {
    Invoke-NodeCli -CliName 'npx-cli.js' -UseJobRunner $true -Arguments ([string[]]$args)
}
