param(
    [Parameter(Mandatory)][string] $Cwd,
    [Parameter(Mandatory)][string] $CachePath,
    [Parameter(Mandatory)][string] $LockPath
)

$ErrorActionPreference = 'SilentlyContinue'
try {
    $cacheDir = Split-Path -Parent $CachePath
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

    function Get-GitStatusPath {
        param([Parameter(Mandatory)][string] $Name)

        $path = (& git -C $Cwd rev-parse --git-path $Name 2>$null | Select-Object -First 1)
        if (-not $path) { return '' }

        $path = ([string]$path).Trim()
        if ([System.IO.Path]::IsPathRooted($path)) { return $path }
        [System.IO.Path]::GetFullPath((Join-Path $Cwd $path))
    }

    function Write-GitStatusCache {
        param([hashtable] $Status)

        $Status.Updated = (Get-Date).ToString('o')
        $tempPath = "$CachePath.$PID.tmp"
        try {
            [pscustomobject]$Status | ConvertTo-Json -Compress | Set-Content -LiteralPath $tempPath -Encoding UTF8 -ErrorAction Stop
            [System.IO.File]::Move($tempPath, $CachePath, $true)
        }
        finally {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    $lines = & git -C $Cwd status --porcelain=v1 --branch --untracked-files=normal 2>$null
    if ($global:LASTEXITCODE -ne 0) {
        Write-GitStatusCache @{ Path = $Cwd; IsRepo = $false; Branch = ''; Text = ''; Staged = 0; Modified = 0; Untracked = 0; Deleted = 0; Renamed = 0; Ahead = 0; Behind = 0; Stash = 0; Conflict = 0; Action = '' }
        return
    }

    $branch = (& git -C $Cwd symbolic-ref --quiet --short HEAD 2>$null | Select-Object -First 1)
    if ($global:LASTEXITCODE -ne 0 -or -not $branch) {
        $branch = (& git -C $Cwd rev-parse --short HEAD 2>$null | Select-Object -First 1)
    }
    $branch = if ($branch) { ([string]$branch).Trim() } else { '' }

    $staged = 0; $modified = 0; $untracked = 0; $deleted = 0; $renamed = 0; $ahead = 0; $behind = 0; $stash = 0; $conflict = 0
    $conflictCodes = @('DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU')
    foreach ($line in $lines) {
        if ($line -like '## *') {
            if ($line -match 'ahead (\d+)') { $ahead = [int]$Matches[1] }
            if ($line -match 'behind (\d+)') { $behind = [int]$Matches[1] }
            continue
        }
        if ($line.StartsWith('??')) { $untracked++; continue }
        if ($line.Length -lt 2) { continue }
        $x = [string]$line[0]; $y = [string]$line[1]
        $code = $x + $y
        if ($code -in $conflictCodes) { $conflict++; continue }
        if ($x -eq 'R' -or $y -eq 'R') { $renamed++ }
        if ($x -eq 'D' -or $y -eq 'D') { $deleted++ }
        if ($x -ne ' ' -and $x -ne '?' -and $x -ne 'R') { $staged++ }
        if ($y -ne ' ' -and $y -ne '?') { $modified++ }
    }

    $stashText = (& git -C $Cwd rev-list --walk-reflogs --count refs/stash 2>$null | Select-Object -First 1)
    if ($stashText -match '^\d+$') { $stash = [int]$stashText }

    function Test-GitPath {
        param([Parameter(Mandatory)][string] $Name)
        $path = Get-GitStatusPath $Name
        if (-not $path) { return $false }
        Test-Path -LiteralPath $path
    }

    $action = ''
    if ((Test-GitPath 'rebase-merge') -or (Test-GitPath 'rebase-apply')) { $action = 'rebasing' }
    elseif (Test-GitPath 'MERGE_HEAD') { $action = 'merging' }
    elseif (Test-GitPath 'CHERRY_PICK_HEAD') { $action = 'cherry-picking' }
    elseif (Test-GitPath 'REVERT_HEAD') { $action = 'reverting' }

    Write-GitStatusCache @{ Path = $Cwd; IsRepo = $true; Branch = $branch; Text = ''; Staged = $staged; Modified = $modified; Untracked = $untracked; Deleted = $deleted; Renamed = $renamed; Ahead = $ahead; Behind = $behind; Stash = $stash; Conflict = $conflict; Action = $action }
}
catch {}
finally {
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
}
