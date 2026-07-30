# ---- fnm (Node version manager, replaces nvm-windows) ----
if (-not ($script:State -is [hashtable])) { $script:State = @{} }

$__fnmCommand = Get-Command fnm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $__fnmCommand) {
    Remove-Variable __fnmCommand -ErrorAction SilentlyContinue
    return
}

function Reset-FnmState {
    param([Parameter(Mandatory)][string] $Executable)

    $oldProcessProperty = if ($script:State.Fnm) { $script:State.Fnm.PSObject.Properties['Process'] }
    if ($oldProcessProperty -and $oldProcessProperty.Value) {
        try { $oldProcessProperty.Value.Dispose() } catch {}
    }
    $script:State.Fnm = @{
        SchemaVersion = 1; Status = 'NotStarted'; Executable = $Executable; Process = $null
        StdoutTask = $null; StderrTask = $null; LaunchPath = $null
        LastVersionPath = $null; UseRetryAttempted = $false; WarningShown = $false
    }
}

$__fnmExecutable = [System.IO.Path]::GetFullPath($__fnmCommand.Source)
if (-not ($script:State.Fnm -is [hashtable]) -or
    $script:State.Fnm['SchemaVersion'] -ne 1 -or
    -not $script:State.Fnm.Executable.Equals($__fnmExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
    Reset-FnmState -Executable $__fnmExecutable
}
$script:State.FnmExecutable = $__fnmExecutable
Remove-Variable __fnmCommand, __fnmExecutable -ErrorAction SilentlyContinue

function Clear-FnmEnvironmentProcess {
    if ($script:State.Fnm.Process) { try { $script:State.Fnm.Process.Dispose() } catch {} }
    $script:State.Fnm.Process = $null
    $script:State.Fnm.StdoutTask = $null
    $script:State.Fnm.StderrTask = $null
    $script:State.Fnm.LaunchPath = $null
}

function Start-FnmEnvironmentInitialization {
    if ($script:State.Fnm.Status -in 'Running', 'Ready') { return }

    Clear-FnmEnvironmentProcess
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        if ([System.IO.Path]::GetExtension($script:State.Fnm.Executable) -in '.cmd', '.bat') {
            $psi.FileName = $env:ComSpec
            [void]$psi.ArgumentList.Add('/d')
            [void]$psi.ArgumentList.Add('/c')
            [void]$psi.ArgumentList.Add($script:State.Fnm.Executable)
        }
        else { $psi.FileName = $script:State.Fnm.Executable }
        [void]$psi.ArgumentList.Add('env')
        [void]$psi.ArgumentList.Add('--json')
        [void]$psi.ArgumentList.Add('--resolve-engines=false')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        # Codex's Windows sandbox can write TEMP but may deny LOCALAPPDATA.
        if ($env:CODEX_SHELL -eq '1') {
            $psi.Environment['LOCALAPPDATA'] = $env:TEMP
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        $script:State.Fnm.LaunchPath = $env:PATH
        [void]$process.Start()
        $script:State.Fnm.Process = $process
        $script:State.Fnm.StdoutTask = $process.StandardOutput.ReadToEndAsync()
        $script:State.Fnm.StderrTask = $process.StandardError.ReadToEndAsync()
        $script:State.Fnm.Status = 'Running'
    }
    catch {
        Clear-FnmEnvironmentProcess
        $script:State.Fnm.Status = 'Unavailable'
    }
}

function Set-FnmEnvironmentFromJson {
    param([Parameter(Mandatory)] $Data, [AllowEmptyString()][string] $LaunchPath)

    foreach ($property in $Data.PSObject.Properties) {
        if ($property.Name -ne 'PATH') {
            [System.Environment]::SetEnvironmentVariable($property.Name, [string]$property.Value, 'Process')
        }
    }

    $separator = [System.IO.Path]::PathSeparator
    $launchEntries = @($LaunchPath -split [regex]::Escape([string]$separator) | Where-Object { $_ })
    $candidateEntries = @()
    if ($Data.PSObject.Properties['PATH']) {
        $candidateEntries += @(([string]$Data.PATH) -split [regex]::Escape([string]$separator) | Where-Object { $_ })
    }
    if ($Data.PSObject.Properties['FNM_MULTISHELL_PATH'] -and $Data.FNM_MULTISHELL_PATH) {
        $candidateEntries += [string]$Data.FNM_MULTISHELL_PATH
    }

    $launchSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $launchEntries) { [void]$launchSet.Add($entry.TrimEnd('\', '/')) }
    $additions = foreach ($entry in $candidateEntries) {
        if ($launchSet.Add($entry.TrimEnd('\', '/'))) { $entry }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $currentEntries = @($env:PATH -split [regex]::Escape([string]$separator) | Where-Object { $_ })
    $env:PATH = @(foreach ($entry in @($additions) + $currentEntries) {
        if ($seen.Add($entry.TrimEnd('\', '/'))) { $entry }
    }) -join $separator
}

function Complete-FnmEnvironmentInitialization {
    param([switch] $Wait)

    if ($script:State.Fnm.Status -eq 'Ready') { return $true }
    if ($script:State.Fnm.Status -ne 'Running') { return $false }
    $process = $script:State.Fnm.Process
    if (-not $Wait -and -not $process.HasExited) { return $false }
    try {
        if ($Wait) { $process.WaitForExit() }
        $stdout = $script:State.Fnm.StdoutTask.GetAwaiter().GetResult()
        $null = $script:State.Fnm.StderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) { throw 'fnm env failed.' }
        $data = $stdout | ConvertFrom-Json -ErrorAction Stop
        Set-FnmEnvironmentFromJson -Data $data -LaunchPath $script:State.Fnm.LaunchPath
        $script:State.Fnm.Status = 'Ready'
        return $true
    }
    catch {
        $script:State.Fnm.Status = 'Unavailable'
        return $false
    }
    finally { Clear-FnmEnvironmentProcess }
}

function Initialize-FnmForUse {
    if (-not ($script:State.Fnm -is [hashtable]) -or $script:State.Fnm['SchemaVersion'] -ne 1) {
        Reset-FnmState -Executable $script:State.FnmExecutable
    }

    $retryUnavailable = $script:State.Fnm.Status -eq 'Unavailable'
    if ($script:State.Fnm.Status -eq 'NotStarted') { Start-FnmEnvironmentInitialization }
    if ($script:State.Fnm.Status -eq 'Running' -and (Complete-FnmEnvironmentInitialization -Wait)) { return $true }
    if ($script:State.Fnm.Status -eq 'Ready') { return $true }

    if ($retryUnavailable -and -not $script:State.Fnm.UseRetryAttempted) {
        $script:State.Fnm.UseRetryAttempted = $true
        $script:State.Fnm.Status = 'NotStarted'
        Start-FnmEnvironmentInitialization
        if (Complete-FnmEnvironmentInitialization -Wait) { return $true }
    }
    if (-not $script:State.Fnm.WarningShown) {
        $script:State.Fnm.WarningShown = $true
        Write-Warning 'fnm environment initialization failed; Node commands may be unavailable.'
    }
    $false
}

function Update-FnmVersionForCurrentDirectory {
    param([switch] $Wait)

    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        $script:State.Fnm.LastVersionPath = $null
        return
    }
    $path = $location.ProviderPath
    $hasVersionFile = [System.IO.File]::Exists([System.IO.Path]::Combine($path, '.node-version')) -or
        [System.IO.File]::Exists([System.IO.Path]::Combine($path, '.nvmrc'))
    if (-not $hasVersionFile) {
        $script:State.Fnm.LastVersionPath = $null
        return
    }
    if ($script:State.Fnm.LastVersionPath -eq $path) { return }
    if ($Wait) {
        if ($script:State.Fnm.Status -eq 'NotStarted') { Start-FnmEnvironmentInitialization }
        if ($script:State.Fnm.Status -eq 'Running') { $null = Complete-FnmEnvironmentInitialization -Wait }
        if ($script:State.Fnm.Status -ne 'Ready') { return }
    }
    elseif (-not (Complete-FnmEnvironmentInitialization)) { return }
    & $script:State.Fnm.Executable use --silent-if-unchanged 2>$null | Out-Null
    if ($global:LASTEXITCODE -eq 0) { $script:State.Fnm.LastVersionPath = $path }
}

function Update-FnmEnvironmentForPrompt {
    if ($script:State.Fnm.Status -eq 'Running') { $null = Complete-FnmEnvironmentInitialization }
    Update-FnmVersionForCurrentDirectory -Wait
}

foreach ($__fnmWrapperName in 'node', 'npm', 'npx', 'pnpm', 'yarn', 'corepack') {
    Set-Item -Path "function:\$__fnmWrapperName" -Value {
        $__commandName = $MyInvocation.MyCommand.Name
        $__target = Resolve-PwshNativeCommand -Name $__commandName
        if ($__commandName -eq 'npm' -and $args.Count -gt 0 -and $args[0] -in 'run', 'run-script') {
            Invoke-JobProcess -FilePath $__target.Source -ArgumentList ([string[]]$args)
        }
        else { & $__target.Source @args }
    }
}
Remove-Variable __fnmWrapperName -ErrorAction SilentlyContinue

if ($script:State.Session.IsInteractive -and $script:State.Fnm.Status -eq 'NotStarted') {
    Start-FnmEnvironmentInitialization
}
