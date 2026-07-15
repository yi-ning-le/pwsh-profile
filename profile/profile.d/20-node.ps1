# ---- fnm (Node version manager, replaces nvm-windows) ----
$__fnmCommand = Get-Command fnm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $__fnmCommand) {
    Remove-Variable __fnmCommand -ErrorAction SilentlyContinue
    return
}

$__fnmExecutable = [System.IO.Path]::GetFullPath($__fnmCommand.Source)
if (-not $script:__FnmState -or
    -not $script:__FnmState.Executable.Equals($__fnmExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
    if ($script:__FnmState.Process) { try { $script:__FnmState.Process.Dispose() } catch {} }
    $script:__FnmState = @{
        Status = 'NotStarted'; Executable = $__fnmExecutable; Process = $null
        StdoutTask = $null; StderrTask = $null; LaunchPath = $null
        LastVersionPath = $null; UseRetryAttempted = $false; WarningShown = $false
    }
}
$script:__fnmExecutable = $__fnmExecutable
Remove-Variable __fnmCommand, __fnmExecutable -ErrorAction SilentlyContinue

function Clear-FnmEnvironmentProcess {
    if ($script:__FnmState.Process) { try { $script:__FnmState.Process.Dispose() } catch {} }
    $script:__FnmState.Process = $null
    $script:__FnmState.StdoutTask = $null
    $script:__FnmState.StderrTask = $null
    $script:__FnmState.LaunchPath = $null
}

function Start-FnmEnvironmentInitialization {
    if ($script:__FnmState.Status -in 'Running', 'Ready') { return }

    Clear-FnmEnvironmentProcess
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        if ([System.IO.Path]::GetExtension($script:__FnmState.Executable) -in '.cmd', '.bat') {
            $psi.FileName = $env:ComSpec
            [void]$psi.ArgumentList.Add('/d')
            [void]$psi.ArgumentList.Add('/c')
            [void]$psi.ArgumentList.Add($script:__FnmState.Executable)
        }
        else { $psi.FileName = $script:__FnmState.Executable }
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
        $script:__FnmState.LaunchPath = $env:PATH
        [void]$process.Start()
        $script:__FnmState.Process = $process
        $script:__FnmState.StdoutTask = $process.StandardOutput.ReadToEndAsync()
        $script:__FnmState.StderrTask = $process.StandardError.ReadToEndAsync()
        $script:__FnmState.Status = 'Running'
    }
    catch {
        Clear-FnmEnvironmentProcess
        $script:__FnmState.Status = 'Unavailable'
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

    if ($script:__FnmState.Status -eq 'Ready') { return $true }
    if ($script:__FnmState.Status -ne 'Running') { return $false }
    $process = $script:__FnmState.Process
    if (-not $Wait -and -not $process.HasExited) { return $false }
    try {
        if ($Wait) { $process.WaitForExit() }
        $stdout = $script:__FnmState.StdoutTask.GetAwaiter().GetResult()
        $null = $script:__FnmState.StderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) { throw 'fnm env failed.' }
        $data = $stdout | ConvertFrom-Json -ErrorAction Stop
        Set-FnmEnvironmentFromJson -Data $data -LaunchPath $script:__FnmState.LaunchPath
        $script:__FnmState.Status = 'Ready'
        return $true
    }
    catch {
        $script:__FnmState.Status = 'Unavailable'
        return $false
    }
    finally { Clear-FnmEnvironmentProcess }
}

function Initialize-FnmForUse {
    $retryUnavailable = $script:__FnmState.Status -eq 'Unavailable'
    if ($script:__FnmState.Status -eq 'NotStarted') { Start-FnmEnvironmentInitialization }
    if ($script:__FnmState.Status -eq 'Running' -and (Complete-FnmEnvironmentInitialization -Wait)) { return $true }
    if ($script:__FnmState.Status -eq 'Ready') { return $true }

    if ($retryUnavailable -and -not $script:__FnmState.UseRetryAttempted) {
        $script:__FnmState.UseRetryAttempted = $true
        $script:__FnmState.Status = 'NotStarted'
        Start-FnmEnvironmentInitialization
        if (Complete-FnmEnvironmentInitialization -Wait) { return $true }
    }
    if (-not $script:__FnmState.WarningShown) {
        $script:__FnmState.WarningShown = $true
        Write-Warning 'fnm environment initialization failed; Node commands may be unavailable.'
    }
    $false
}

function Update-FnmVersionForCurrentDirectory {
    param([switch] $Wait)

    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        $script:__FnmState.LastVersionPath = $null
        return
    }
    $path = $location.ProviderPath
    $hasVersionFile = [System.IO.File]::Exists([System.IO.Path]::Combine($path, '.node-version')) -or
        [System.IO.File]::Exists([System.IO.Path]::Combine($path, '.nvmrc'))
    if (-not $hasVersionFile) {
        $script:__FnmState.LastVersionPath = $null
        return
    }
    if ($script:__FnmState.LastVersionPath -eq $path) { return }
    if ($Wait) {
        if ($script:__FnmState.Status -eq 'NotStarted') { Start-FnmEnvironmentInitialization }
        if ($script:__FnmState.Status -eq 'Running') { $null = Complete-FnmEnvironmentInitialization -Wait }
        if ($script:__FnmState.Status -ne 'Ready') { return }
    }
    elseif (-not (Complete-FnmEnvironmentInitialization)) { return }
    & $script:__FnmState.Executable use --silent-if-unchanged 2>$null | Out-Null
    if ($global:LASTEXITCODE -eq 0) { $script:__FnmState.LastVersionPath = $path }
}

function Update-FnmEnvironmentForPrompt {
    if ($script:__FnmState.Status -eq 'Running') { $null = Complete-FnmEnvironmentInitialization }
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

if ($script:__PwshProfileIsInteractive -and $script:__FnmState.Status -eq 'NotStarted') {
    Start-FnmEnvironmentInitialization
}
