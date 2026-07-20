[CmdletBinding(DefaultParameterSetName = 'Once')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Once')][string] $Cwd,
    [Parameter(Mandatory, ParameterSetName = 'Once')][string] $CachePath,
    [Parameter(Mandatory, ParameterSetName = 'Once')][string] $LockPath,
    [Parameter(ParameterSetName = 'Once')][string] $SessionId = '',
    [Parameter(ParameterSetName = 'Once')][long] $Generation = 0,
    [Parameter(Mandatory, ParameterSetName = 'Worker')] $RequestQueue,
    [Parameter(ParameterSetName = 'Worker')][string] $GitExecutable = '',
    [Parameter(ParameterSetName = 'Worker')][ValidateRange(100, 30000)][int] $GitStatusTimeoutMilliseconds = 3000
)

$ErrorActionPreference = 'SilentlyContinue'

$gitStatusDisplayProperties = @(
    'IsRepo', 'Branch', 'Text', 'Staged', 'Modified', 'Untracked', 'Deleted', 'Renamed',
    'Ahead', 'Behind', 'Stash', 'Conflict', 'Action'
)

function Test-GitStatusCacheMatch {
    param(
        [Parameter(Mandatory)][hashtable] $Status,
        [Parameter(Mandatory)] $Cached
    )

    foreach ($name in $gitStatusDisplayProperties) {
        $property = $Cached.PSObject.Properties[$name]
        if (-not $property -or [string]($property.Value) -cne [string]($Status[$name])) { return $false }
    }
    $true
}

function Write-GitStatusCache {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][hashtable] $Status,
        [string] $WorkerSessionId = '',
        [long] $WorkerGeneration = 0
    )

    $cacheDir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    try { $cached = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { $cached = $null }
    if ($cached -and (Test-GitStatusCacheMatch -Status $Status -Cached $cached)) {
        if (-not $Status.IsRepo) { [System.IO.File]::SetLastWriteTimeUtc($Path, [datetime]::UtcNow) }
        return
    }

    $Status.SessionId = $WorkerSessionId
    $Status.Generation = $WorkerGeneration
    $Status.Updated = [datetime]::UtcNow.ToString('o')
    $tempPath = "$Path.$PID.tmp"
    try {
        [pscustomobject]$Status | ConvertTo-Json -Compress | Set-Content -LiteralPath $tempPath -Encoding UTF8 -ErrorAction Stop
        [System.IO.File]::Move($tempPath, $Path, $true)
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Stop-GitStatusProcess {
    param([Parameter(Mandatory)][System.Diagnostics.Process] $Process)

    try {
        if (-not $Process.HasExited) { $Process.Kill($true) }
    }
    catch {}
    try { $null = $Process.WaitForExit(1000) } catch {}
}

function Invoke-WorkerGitStatus {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)] $Queue,
        [Parameter(Mandatory)][int] $TimeoutMilliseconds,
        [bool] $SkipUntracked = $false
    )

    if ($Queue.Count -gt 0) {
        return [pscustomobject]@{ Result = 'Superseded'; ExitCode = 0; Lines = @() }
    }

    $process = [System.Diagnostics.Process]::new()
    $started = $false
    try {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $Executable
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $untrackedMode = if ($SkipUntracked) { 'no' } else { 'normal' }
        foreach ($argument in @(
                '-C', $WorkingDirectory, 'status', '--porcelain=v2', '--branch', '--show-stash', "--untracked-files=$untrackedMode"
            )) {
            [void] $startInfo.ArgumentList.Add($argument)
        }
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'Failed to start Git status.' }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        while (-not $process.WaitForExit(50)) {
            if ($Queue.Count -gt 0) {
                Stop-GitStatusProcess -Process $process
                return [pscustomobject]@{ Result = 'Superseded'; ExitCode = 0; Lines = @() }
            }
            if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                Stop-GitStatusProcess -Process $process
                return [pscustomobject]@{ Result = 'TimedOut'; ExitCode = 0; Lines = @() }
            }
        }
        if ($Queue.Count -gt 0) {
            return [pscustomobject]@{ Result = 'Superseded'; ExitCode = 0; Lines = @() }
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $null = $stderrTask.GetAwaiter().GetResult()
        [pscustomobject]@{
            Result = 'Completed'
            ExitCode = $process.ExitCode
            Lines = if ($stdout) { @($stdout -split '\r?\n') } else { @() }
        }
    }
    finally {
        if ($started -and -not $process.HasExited) { Stop-GitStatusProcess -Process $process }
        $process.Dispose()
    }
}

function Invoke-GitStatusUpdate {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $OutputPath,
        [string] $WorkerSessionId = '',
        [long] $WorkerGeneration = 0,
        [string] $CleanupLockPath = '',
        [string] $WorkerGitExecutable = '',
        $WorkerRequestQueue,
        [int] $StatusTimeoutMilliseconds = 3000,
        [switch] $SkipUntracked
    )

    try {
        if ($WorkerRequestQueue) {
            $statusResult = Invoke-WorkerGitStatus -WorkingDirectory $WorkingDirectory -Executable $WorkerGitExecutable `
                -Queue $WorkerRequestQueue -TimeoutMilliseconds $StatusTimeoutMilliseconds `
                -SkipUntracked $SkipUntracked
            if ($statusResult.Result -ne 'Completed') { return $statusResult.Result }
            $lines = $statusResult.Lines
            $statusExitCode = $statusResult.ExitCode
        }
        else {
            $lines = & git -C $WorkingDirectory status --porcelain=v2 --branch --show-stash --untracked-files=normal 2>$null
            $statusExitCode = $global:LASTEXITCODE
        }
        if ($statusExitCode -ne 0) {
            Write-GitStatusCache -Path $OutputPath -WorkerSessionId $WorkerSessionId -WorkerGeneration $WorkerGeneration -Status @{
                Path = $WorkingDirectory; IsRepo = $false; Branch = ''; Text = ''; Staged = 0; Modified = 0; Untracked = 0
                Deleted = 0; Renamed = 0; Ahead = 0; Behind = 0; Stash = 0; Conflict = 0; Action = ''
            }
            return 'Completed'
        }

        $branch = ''
        $headOid = ''
        $staged = 0; $modified = 0; $untracked = if ($SkipUntracked) { -1 } else { 0 }
        $deleted = 0; $renamed = 0; $ahead = 0; $behind = 0; $stash = 0; $conflict = 0
        $conflictCodes = @('DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU')
        foreach ($line in $lines) {
            if ($line -match '^# branch\.oid (.+)$') { $headOid = $Matches[1]; continue }
            if ($line -match '^# branch\.head (.+)$') { $branch = $Matches[1]; continue }
            if ($line -match '^# branch\.ab \+(\d+) -(\d+)$') {
                $ahead = [int]$Matches[1]
                $behind = [int]$Matches[2]
                continue
            }
            if ($line -match '^# stash (\d+)$') { $stash = [int]$Matches[1]; continue }
            if ($line.StartsWith('? ')) {
                if (-not $SkipUntracked) { $untracked++ }
                continue
            }
            if ($line.Length -lt 4 -or $line[0] -notin '1', '2', 'u') { continue }

            $fields = $line -split ' +'
            if ($fields.Count -lt 2) { continue }
            $code = [string]$fields[1]
            if ($line[0] -eq 'u' -or $code -in $conflictCodes) { $conflict++; continue }
            if ($code.Length -lt 2) { continue }
            $x = [string]$code[0]; $y = [string]$code[1]
            if ($line[0] -eq '2' -and $fields.Count -gt 8 -and $fields[8].StartsWith('R')) { $renamed++ }
            if ($x -eq 'D' -or $y -eq 'D') { $deleted++ }
            if ($x -ne '.' -and $x -ne '?' -and $x -ne 'R') { $staged++ }
            if ($y -ne '.' -and $y -ne '?') { $modified++ }
        }

        if ($branch -eq '(detached)') {
            $shortHead = (& git -C $WorkingDirectory rev-parse --short HEAD 2>$null | Select-Object -First 1)
            $branch = if ($global:LASTEXITCODE -eq 0 -and $shortHead) { ([string]$shortHead).Trim() }
                elseif ($headOid -match '^[0-9a-fA-F]{7,}$') { $headOid.Substring(0, 7) }
                else { '' }
        }

        $action = ''
        $stateNames = @('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD')
        $gitPathArguments = foreach ($name in $stateNames) { '--git-path'; $name }
        $statePaths = @(& git -C $WorkingDirectory rev-parse @gitPathArguments 2>$null)
        $states = @{}
        for ($index = 0; $index -lt [Math]::Min($stateNames.Count, $statePaths.Count); $index++) {
            $path = ([string]$statePaths[$index]).Trim()
            if (-not [System.IO.Path]::IsPathRooted($path)) { $path = [System.IO.Path]::GetFullPath((Join-Path $WorkingDirectory $path)) }
            $states[$stateNames[$index]] = Test-Path -LiteralPath $path
        }
        if ($states['rebase-merge'] -or $states['rebase-apply']) { $action = 'rebasing' }
        elseif ($states['MERGE_HEAD']) { $action = 'merging' }
        elseif ($states['CHERRY_PICK_HEAD']) { $action = 'cherry-picking' }
        elseif ($states['REVERT_HEAD']) { $action = 'reverting' }

        Write-GitStatusCache -Path $OutputPath -WorkerSessionId $WorkerSessionId -WorkerGeneration $WorkerGeneration -Status @{
            Path = $WorkingDirectory; IsRepo = $true; Branch = $branch; Text = ''; Staged = $staged; Modified = $modified
            Untracked = $untracked; Deleted = $deleted; Renamed = $renamed; Ahead = $ahead; Behind = $behind
            Stash = $stash; Conflict = $conflict; Action = $action
        }
        'Completed'
    }
    catch { 'Failed' }
    finally {
        if ($CleanupLockPath) { Remove-Item -LiteralPath $CleanupLockPath -Force -ErrorAction SilentlyContinue }
        $global:LASTEXITCODE = 0
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Worker') {
    if (-not $GitExecutable) {
        $GitExecutable = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    }
    # ponytail: remember slow working directories for five minutes; key by repository root only if subdirectory churn becomes measurable.
    $slowPaths = [System.Collections.Generic.Dictionary[string, datetime]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($request in $RequestQueue.GetConsumingEnumerable()) {
        if (-not $request.Cwd -or -not $request.CachePath) { continue }
        $workingDirectory = [string]$request.Cwd
        $slowUntil = [datetime]::MinValue
        $skipUntracked = [int]$request.Attempt -gt 0
        if (-not $skipUntracked -and $slowPaths.TryGetValue($workingDirectory, [ref]$slowUntil)) {
            if ($slowUntil -gt [datetime]::UtcNow) { $skipUntracked = $true }
            else { [void] $slowPaths.Remove($workingDirectory) }
        }
        $timeout = if ($skipUntracked) {
            [Math]::Min(30000, $GitStatusTimeoutMilliseconds * 3)
        }
        else { $GitStatusTimeoutMilliseconds }

        $result = Invoke-GitStatusUpdate -WorkingDirectory $workingDirectory -OutputPath ([string]$request.CachePath) `
            -WorkerSessionId ([string]$request.SessionId) -WorkerGeneration ([long]$request.Generation) `
            -WorkerGitExecutable $GitExecutable -WorkerRequestQueue $RequestQueue `
            -StatusTimeoutMilliseconds $timeout -SkipUntracked:$skipUntracked
        if ($result -eq 'Completed' -and -not $skipUntracked) {
            [void] $slowPaths.Remove($workingDirectory)
        }
        elseif ($result -eq 'TimedOut' -and -not $skipUntracked) {
            $slowPaths[$workingDirectory] = [datetime]::UtcNow.AddMinutes(5)
        }
        if (($result -in 'TimedOut', 'Failed') -and [int]$request.Attempt -lt 1) {
            try {
                $request | Add-Member -NotePropertyName Attempt -NotePropertyValue 1 -Force
                [void] $RequestQueue.TryAdd($request)
            }
            catch {}
        }
    }
}
else {
    Invoke-GitStatusUpdate -WorkingDirectory $Cwd -OutputPath $CachePath -WorkerSessionId $SessionId `
        -WorkerGeneration $Generation -CleanupLockPath $LockPath | Out-Null
}
