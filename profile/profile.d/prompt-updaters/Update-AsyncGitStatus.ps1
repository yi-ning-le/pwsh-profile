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

    function Get-GitStatusFileStamp {
        param([AllowNull()][string] $Path)

        if ([string]::IsNullOrWhiteSpace($Path)) { return 'missing' }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if (-not $item) { return "missing:${Path}" }

        $kind = if ($item.PSIsContainer) { 'dir' } else { 'file' }
        $length = if ($item.PSIsContainer) { 0 } else { $item.Length }
        "${kind}:${Path}:$($item.LastWriteTimeUtc.Ticks):${length}"
    }

    function Get-GitStatusSignature {
        $headOid = (& git -C $Cwd rev-parse --verify HEAD 2>$null | Select-Object -First 1)
        $headOid = if ($LASTEXITCODE -eq 0 -and $headOid) { ([string]$headOid).Trim() } else { '' }
        $headRef = (& git -C $Cwd symbolic-ref --quiet HEAD 2>$null | Select-Object -First 1)
        $headRef = if ($LASTEXITCODE -eq 0 -and $headRef) { ([string]$headRef).Trim() } else { '' }

        $stamps = @(
            "HEAD=${headOid}",
            "HEADREF=${headRef}"
        )
        foreach ($name in 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply') {
            $stamps += "${name}=$(Get-GitStatusFileStamp (Get-GitStatusPath $name))"
        }

        $stamps -join '|'
    }

    function Write-GitStatusCache {
        param([hashtable] $Status)
        $Status.Updated = (Get-Date).ToString('o')
        [pscustomobject]$Status | ConvertTo-Json -Compress | Set-Content -LiteralPath $CachePath -Encoding UTF8
    }

    $lines = & git -C $Cwd status --porcelain=v1 --branch --untracked-files=normal 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-GitStatusCache @{ Path = $Cwd; IsRepo = $false; Branch = ''; Text = ''; Staged = 0; Modified = 0; Untracked = 0; Deleted = 0; Renamed = 0; Ahead = 0; Behind = 0; Stash = 0; Conflict = 0; Action = ''; Signature = '' }
        return
    }

    $branch = (& git -C $Cwd symbolic-ref --quiet --short HEAD 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or -not $branch) {
        $branch = (& git -C $Cwd rev-parse --short HEAD 2>$null | Select-Object -First 1)
    }
    $branch = if ($branch) { ([string]$branch).Trim() } else { '' }
    $signature = Get-GitStatusSignature

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

    $parts = @()
    if ($staged -gt 0) { $parts += "+$staged" }
    if ($modified -gt 0) { $parts += "!$modified" }
    if ($untracked -gt 0) { $parts += "?$untracked" }
    if ($deleted -gt 0) { $parts += "x$deleted" }
    if ($renamed -gt 0) { $parts += "»$renamed" }
    if ($ahead -gt 0) { $parts += "⇡$ahead" }
    if ($behind -gt 0) { $parts += "⇣$behind" }
    if ($stash -gt 0) { $parts += "≡$stash" }
    if ($conflict -gt 0) { $parts += "✖$conflict" }
    if ($action) { $parts += $action }

    Write-GitStatusCache @{ Path = $Cwd; IsRepo = $true; Branch = $branch; Text = ($parts -join ' '); Staged = $staged; Modified = $modified; Untracked = $untracked; Deleted = $deleted; Renamed = $renamed; Ahead = $ahead; Behind = $behind; Stash = $stash; Conflict = $conflict; Action = $action; Signature = $signature }
}
finally {
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
}