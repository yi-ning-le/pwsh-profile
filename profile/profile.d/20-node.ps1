# ---- fnm (Node version manager, replaces nvm-windows) ----
$__fnmCommand = Get-Command fnm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $__fnmCommand) {
    Remove-Variable __fnmCommand -ErrorAction SilentlyContinue
    return
}

function Reset-FnmState {
    param([Parameter(Mandatory)][string] $Executable)

    $oldProcessProperty = if ($global:__FnmState) { $global:__FnmState.PSObject.Properties['Process'] }
    if ($oldProcessProperty -and $oldProcessProperty.Value) {
        try { $oldProcessProperty.Value.Dispose() } catch {}
    }
    $global:__FnmState = @{
        SchemaVersion = 1; Status = 'NotStarted'; Executable = $Executable; Process = $null
        StdoutTask = $null; StderrTask = $null; LaunchPath = $null
        LastVersionPath = $null; UseRetryAttempted = $false; WarningShown = $false
    }
}

$__fnmExecutable = [System.IO.Path]::GetFullPath($__fnmCommand.Source)
if (-not ($global:__FnmState -is [hashtable]) -or
    $global:__FnmState['SchemaVersion'] -ne 1 -or
    -not $global:__FnmState.Executable.Equals($__fnmExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
    Reset-FnmState -Executable $__fnmExecutable
}
$global:__PwshFnmExecutable = $__fnmExecutable
Remove-Variable __fnmCommand, __fnmExecutable -ErrorAction SilentlyContinue

function Clear-FnmEnvironmentProcess {
    if ($global:__FnmState.Process) { try { $global:__FnmState.Process.Dispose() } catch {} }
    $global:__FnmState.Process = $null
    $global:__FnmState.StdoutTask = $null
    $global:__FnmState.StderrTask = $null
    $global:__FnmState.LaunchPath = $null
}

function Start-FnmEnvironmentInitialization {
    if ($global:__FnmState.Status -in 'Running', 'Ready') { return }

    Clear-FnmEnvironmentProcess
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        if ([System.IO.Path]::GetExtension($global:__FnmState.Executable) -in '.cmd', '.bat') {
            $psi.FileName = $env:ComSpec
            [void]$psi.ArgumentList.Add('/d')
            [void]$psi.ArgumentList.Add('/c')
            [void]$psi.ArgumentList.Add($global:__FnmState.Executable)
        }
        else { $psi.FileName = $global:__FnmState.Executable }
        [void]$psi.ArgumentList.Add('env')
        [void]$psi.ArgumentList.Add('--json')
        [void]$psi.ArgumentList.Add('--resolve-engines=false')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        $global:__FnmState.LaunchPath = $env:PATH
        [void]$process.Start()
        $global:__FnmState.Process = $process
        $global:__FnmState.StdoutTask = $process.StandardOutput.ReadToEndAsync()
        $global:__FnmState.StderrTask = $process.StandardError.ReadToEndAsync()
        $global:__FnmState.Status = 'Running'
    }
    catch {
        Clear-FnmEnvironmentProcess
        $global:__FnmState.Status = 'Unavailable'
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

    if ($global:__FnmState.Status -eq 'Ready') { return $true }
    if ($global:__FnmState.Status -ne 'Running') { return $false }
    $process = $global:__FnmState.Process
    if (-not $Wait -and -not $process.HasExited) { return $false }
    try {
        if ($Wait) { $process.WaitForExit() }
        $stdout = $global:__FnmState.StdoutTask.GetAwaiter().GetResult()
        $null = $global:__FnmState.StderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) { throw 'fnm env failed.' }
        $data = $stdout | ConvertFrom-Json -ErrorAction Stop
        Set-FnmEnvironmentFromJson -Data $data -LaunchPath $global:__FnmState.LaunchPath
        $global:__FnmState.Status = 'Ready'
        return $true
    }
    catch {
        $global:__FnmState.Status = 'Unavailable'
        return $false
    }
    finally { Clear-FnmEnvironmentProcess }
}

function Initialize-FnmForUse {
    if (-not ($global:__FnmState -is [hashtable]) -or $global:__FnmState['SchemaVersion'] -ne 1) {
        Reset-FnmState -Executable $global:__PwshFnmExecutable
    }

    $retryUnavailable = $global:__FnmState.Status -eq 'Unavailable'
    if ($global:__FnmState.Status -eq 'NotStarted') { Start-FnmEnvironmentInitialization }
    if ($global:__FnmState.Status -eq 'Running' -and (Complete-FnmEnvironmentInitialization -Wait)) { return $true }
    if ($global:__FnmState.Status -eq 'Ready') { return $true }

    if ($retryUnavailable -and -not $global:__FnmState.UseRetryAttempted) {
        $global:__FnmState.UseRetryAttempted = $true
        $global:__FnmState.Status = 'NotStarted'
        Start-FnmEnvironmentInitialization
        if (Complete-FnmEnvironmentInitialization -Wait) { return $true }
    }
    if (-not $global:__FnmState.WarningShown) {
        $global:__FnmState.WarningShown = $true
        Write-Warning 'fnm environment initialization failed; Node commands may be unavailable.'
    }
    $false
}

function Update-FnmVersionForCurrentDirectory {
    param([switch] $Wait)

    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        $global:__FnmState.LastVersionPath = $null
        return
    }
    $path = $location.ProviderPath
    $hasVersionFile = [System.IO.File]::Exists([System.IO.Path]::Combine($path, '.node-version')) -or
        [System.IO.File]::Exists([System.IO.Path]::Combine($path, '.nvmrc'))
    if (-not $hasVersionFile) {
        $global:__FnmState.LastVersionPath = $null
        return
    }
    if ($global:__FnmState.LastVersionPath -eq $path) { return }
    if ($Wait) {
        if ($global:__FnmState.Status -eq 'NotStarted') { Start-FnmEnvironmentInitialization }
        if ($global:__FnmState.Status -eq 'Running') { $null = Complete-FnmEnvironmentInitialization -Wait }
        if ($global:__FnmState.Status -ne 'Ready') { return }
    }
    elseif (-not (Complete-FnmEnvironmentInitialization)) { return }
    & $global:__FnmState.Executable use --silent-if-unchanged 2>$null | Out-Null
    if ($global:LASTEXITCODE -eq 0) { $global:__FnmState.LastVersionPath = $path }
}

function Update-FnmEnvironmentForPrompt {
    if ($global:__FnmState.Status -eq 'Running') { $null = Complete-FnmEnvironmentInitialization }
    Update-FnmVersionForCurrentDirectory -Wait
}

foreach ($__fnmWrapperName in 'node', 'npm', 'npx', 'pnpm', 'yarn', 'corepack') {
    Set-Item -Path "function:\$__fnmWrapperName" -Value {
        $null = Initialize-FnmForUse
        Update-FnmVersionForCurrentDirectory -Wait
        $__commandName = $MyInvocation.MyCommand.Name
        $__target = Get-Command "$__commandName.exe", "$__commandName.cmd", "$__commandName.ps1" -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $__target) { $__target = Get-Command $__commandName -CommandType Application -ErrorAction Stop | Select-Object -First 1 }
        & $__target.Source @args
    }.GetNewClosure()
}
Remove-Variable __fnmWrapperName -ErrorAction SilentlyContinue

if ($global:__PwshProfileIsInteractive -and $global:__FnmState.Status -eq 'NotStarted') {
    Start-FnmEnvironmentInitialization
}
