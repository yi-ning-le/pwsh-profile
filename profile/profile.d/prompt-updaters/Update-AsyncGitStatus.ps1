[CmdletBinding(DefaultParameterSetName = 'Once')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Once')][string] $Cwd,
    [Parameter(Mandatory, ParameterSetName = 'Once')][string] $CachePath,
    [Parameter(Mandatory, ParameterSetName = 'Once')][string] $LockPath,
    [Parameter(ParameterSetName = 'Once')][string] $SessionId = '',
    [Parameter(ParameterSetName = 'Once')][long] $Generation = 0,
    [Parameter(Mandatory, ParameterSetName = 'Worker')] $RequestQueue
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

function Invoke-GitStatusUpdate {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $OutputPath,
        [string] $WorkerSessionId = '',
        [long] $WorkerGeneration = 0,
        [string] $CleanupLockPath = ''
    )

    try {
        $lines = & git -C $WorkingDirectory status --porcelain=v2 --branch --show-stash --untracked-files=normal 2>$null
        if ($global:LASTEXITCODE -ne 0) {
            Write-GitStatusCache -Path $OutputPath -WorkerSessionId $WorkerSessionId -WorkerGeneration $WorkerGeneration -Status @{
                Path = $WorkingDirectory; IsRepo = $false; Branch = ''; Text = ''; Staged = 0; Modified = 0; Untracked = 0
                Deleted = 0; Renamed = 0; Ahead = 0; Behind = 0; Stash = 0; Conflict = 0; Action = ''
            }
            return
        }

        $branch = ''
        $headOid = ''
        $staged = 0; $modified = 0; $untracked = 0; $deleted = 0; $renamed = 0; $ahead = 0; $behind = 0; $stash = 0; $conflict = 0
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
            if ($line.StartsWith('? ')) { $untracked++; continue }
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
    }
    catch {}
    finally {
        if ($CleanupLockPath) { Remove-Item -LiteralPath $CleanupLockPath -Force -ErrorAction SilentlyContinue }
        $global:LASTEXITCODE = 0
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Worker') {
    foreach ($request in $RequestQueue.GetConsumingEnumerable()) {
        if (-not $request.Cwd -or -not $request.CachePath) { continue }
        Invoke-GitStatusUpdate -WorkingDirectory ([string]$request.Cwd) -OutputPath ([string]$request.CachePath) `
            -WorkerSessionId ([string]$request.SessionId) -WorkerGeneration ([long]$request.Generation)
    }
}
else {
    Invoke-GitStatusUpdate -WorkingDirectory $Cwd -OutputPath $CachePath -WorkerSessionId $SessionId `
        -WorkerGeneration $Generation -CleanupLockPath $LockPath
}
