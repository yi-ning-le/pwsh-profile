# ============================================================
#  PowerShell profile -- zsh + oh-my-zsh + p10k-like feel
#  Goals: Starship-style prompt / history autosuggestions / syntax highlighting /
#         path completion / ls icons / omz-style aliases
# ============================================================

# ---- Pure PowerShell prompt (Starship lean / powerlevel10k inspired) ----
$script:__LeanPromptAnsiRegex = [regex]::new(([regex]::Escape([string][char]27)) + '\[[0-9;]*m')
$script:__LeanPromptProjectRootCache = @{}
$script:__LeanPromptCommandStartUtc = $null
$script:__LeanPromptDurationEnabled = $false

$script:LeanPromptPalette = @{
    Reset            = "`e[0m"
    SegmentBg        = "`e[48;5;238m"
    SegmentText      = "`e[38;5;252m"
    SegmentSeparator = "`e[38;5;238m"
    Path             = "`e[38;5;39m"
    PathMuted        = "`e[38;5;248m"
    PathAnchor       = "`e[38;5;81m"
    GitText          = "`e[38;5;252m"
    GitBranch        = "`e[38;5;76m"
    GitStatus        = "`e[38;5;178m"
    GitStaged        = "`e[38;5;76m"
    GitModified      = "`e[38;5;178m"
    GitUntracked     = "`e[38;5;39m"
    GitDeleted       = "`e[38;5;196m"
    GitRenamed       = "`e[38;5;81m"
    GitAhead         = "`e[38;5;81m"
    GitBehind        = "`e[38;5;178m"
    GitStash         = "`e[38;5;248m"
    GitConflict      = "`e[38;5;196m"
    Success          = "`e[38;5;76m"
    Error            = "`e[38;5;196m"
    Version          = "`e[38;5;248m"
    DurationNormal   = "`e[38;5;248m"
    DurationSlow     = "`e[38;5;178m"
    DurationVerySlow = "`e[38;5;196m"
    Node             = "`e[38;5;76m"
    Python           = "`e[38;5;178m"
    Go               = "`e[38;5;81m"
    Rust             = "`e[38;5;208m"
    DotNet           = "`e[38;5;141m"
}

function global:Remove-LeanPromptAnsi {
    param([AllowNull()][string] $Text)
    if ($null -eq $Text) { return '' }
    $script:__LeanPromptAnsiRegex.Replace($Text, '')
}

function global:Get-LeanPromptDisplayWidth {
    param([AllowNull()][string] $Text)
    (Remove-LeanPromptAnsi $Text).Length
}

function global:Format-LeanPromptLeftSegment {
    param(
        [AllowNull()][string] $Text,
        [string] $Foreground = $script:LeanPromptPalette.SegmentText,
        [switch] $Continue
    )

    if ([string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $Text))) { return '' }

    $palette = $script:LeanPromptPalette
    if ($Continue) {
        return "$($palette.SegmentBg)$Foreground $Text $($palette.PathMuted)"
    }

    "$($palette.SegmentBg)$Foreground $Text $($palette.Reset)$($palette.SegmentSeparator)$($palette.Reset)"
}

function global:Format-LeanPromptRightSegment {
    param(
        [AllowNull()][string] $Text,
        [string] $Foreground = $script:LeanPromptPalette.SegmentText
    )

    if ([string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $Text))) { return '' }

    $palette = $script:LeanPromptPalette
    "$($palette.SegmentSeparator)$($palette.SegmentBg)$Foreground $Text $($palette.Reset)"
}

function global:Join-LeanPromptAlignedLine {
    param(
        [Parameter(Mandatory)][string] $Left,
        [AllowNull()][string] $Right
    )

    if ([string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $Right))) { return $Left }

    try { $width = $Host.UI.RawUI.WindowSize.Width }
    catch { return $Left }

    if ($width -lt 40) { return $Left }

    $leftWidth = Get-LeanPromptDisplayWidth $Left
    $rightWidth = Get-LeanPromptDisplayWidth $Right
    $spaces = $width - $leftWidth - $rightWidth - 2
    if ($spaces -lt 2) { return $Left }

    $Left + (' ' * $spaces) + $Right
}

function global:ConvertTo-LeanPromptSlashPath {
    param([Parameter(Mandatory)][string] $Path)

    $display = $Path -replace '\\', '/'
    $homePath = ([Environment]::GetFolderPath('UserProfile')) -replace '\\', '/'
    if ($homePath -and $display.StartsWith($homePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        $display = '~' + $display.Substring($homePath.Length)
    }

    $display
}

function global:Test-LeanPromptProjectMarker {
    param([Parameter(Mandatory)][string] $Path)

    foreach ($marker in '.git', 'package.json', 'go.mod', 'Cargo.toml', 'pyproject.toml', '.python-version', '.node-version', '.nvmrc') {
        if (Test-Path -LiteralPath (Join-Path $Path $marker)) { return $true }
    }

    [bool](Get-ChildItem -LiteralPath $Path -Filter '*.sln' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function global:Get-LeanPromptProjectRoot {
    param([Parameter(Mandatory)][string] $Path)

    if ($script:__LeanPromptProjectRootCache.ContainsKey($Path)) {
        $cached = $script:__LeanPromptProjectRootCache[$Path]
        if ($cached) { return $cached }
        return $null
    }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }

    $dir = if ($item.PSIsContainer) { $item } else { $item.Directory }
    for ($depth = 0; $dir -and $depth -lt 8; $depth++) {
        if (Test-LeanPromptProjectMarker -Path $dir.FullName) {
            $script:__LeanPromptProjectRootCache[$Path] = $dir.FullName
            return $dir.FullName
        }
        $dir = $dir.Parent
    }

    $script:__LeanPromptProjectRootCache[$Path] = ''
    $null
}

function global:Compress-LeanPromptRootDisplay {
    param([Parameter(Mandatory)][string] $Display)

    $parts = @($Display -split '/' | Where-Object { $_ })
    if ($parts.Count -le 2) { return $Display }

    if ($Display.StartsWith('~/')) {
        return '~/…/' + $parts[-1]
    }

    if ($parts.Count -le 3) { return $Display }
    $parts[0] + '/…/' + $parts[-1]
}

function global:Compress-LeanPromptRelativePath {
    param([AllowNull()][string] $RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -eq '.') { return '' }

    $relative = $RelativePath -replace '\\', '/'
    $parts = @($relative -split '/' | Where-Object { $_ })
    if ($parts.Count -le 2) { return $relative }

    '…/' + (($parts | Select-Object -Last 2) -join '/')
}

function global:Colorize-LeanPromptPath {
    param([Parameter(Mandatory)][string] $Display)

    $palette = $script:LeanPromptPalette
    $idx = $Display.LastIndexOf('/')
    if ($idx -lt 0) { return $palette.PathAnchor + $Display }

    $palette.PathMuted + $Display.Substring(0, $idx + 1) + $palette.PathAnchor + $Display.Substring($idx + 1)
}

function global:Get-LeanPromptPath {
    param([switch] $Continue)
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        return Format-LeanPromptLeftSegment -Text ($script:LeanPromptPalette.PathAnchor + [string]$location) -Foreground $script:LeanPromptPalette.Path -Continue:$Continue
    }

    $path = $location.ProviderPath
    $projectRoot = Get-LeanPromptProjectRoot -Path $path

    if ($projectRoot) {
        $rootDisplay = Compress-LeanPromptRootDisplay (ConvertTo-LeanPromptSlashPath $projectRoot)
        try { $relative = [System.IO.Path]::GetRelativePath($projectRoot, $path) }
        catch { $relative = '' }
        $relativeDisplay = Compress-LeanPromptRelativePath $relative
        $display = if ($relativeDisplay) { $rootDisplay + '/' + $relativeDisplay } else { $rootDisplay }
    }
    else {
        $display = ConvertTo-LeanPromptSlashPath $path
        $prefix = ''
        $rest = $display
        if ($display.StartsWith('~/')) {
            $prefix = '~'
            $rest = $display.Substring(2)
        }
        elseif ($display -match '^[A-Za-z]:/') {
            $prefix = $display.Substring(0, 2)
            $rest = $display.Substring(3)
        }

        $parts = @($rest -split '/' | Where-Object { $_ })
        if ($parts.Count -gt 3) {
            $tail = ($parts | Select-Object -Last 3) -join '/'
            $display = if ($prefix) { "$prefix/…/$tail" } else { "…/$tail" }
        }
    }

    $colored = Colorize-LeanPromptPath $display
    try {
        $item = Get-Item -LiteralPath $location.ProviderPath -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $colored += " $($script:LeanPromptPalette.GitModified)🔒"
        }
    }
    catch { }

    Format-LeanPromptLeftSegment -Text $colored -Foreground $script:LeanPromptPalette.Path -Continue:$Continue
}

function global:Format-LeanPromptCommandDurationText {
    param([Parameter(Mandatory)][timespan] $Duration)

    if ($Duration.TotalSeconds -lt 2) { return '' }

    $palette = $script:LeanPromptPalette
    $color = if ($Duration.TotalSeconds -ge 60) { $palette.DurationVerySlow }
        elseif ($Duration.TotalSeconds -ge 10) { $palette.DurationSlow }
        else { $palette.DurationNormal }

    $text = if ($Duration.TotalSeconds -ge 60) {
        '{0}m{1:00}s' -f [int][math]::Floor($Duration.TotalMinutes), $Duration.Seconds
    }
    else {
        '{0:N1}s' -f $Duration.TotalSeconds
    }

    $color + $text
}

function global:Get-LeanPromptCommandDurationText {
    if (-not $script:__LeanPromptDurationEnabled -or -not $script:__LeanPromptCommandStartUtc) { return '' }

    $duration = [datetime]::UtcNow - $script:__LeanPromptCommandStartUtc
    $script:__LeanPromptCommandStartUtc = $null
    Format-LeanPromptCommandDurationText -Duration $duration
}

function global:prompt {
    $lastCommandSucceeded = $?
    $lastExitCode = $global:LASTEXITCODE

    $palette = $script:LeanPromptPalette
    $reset = $palette.Reset

    $firstLine = Get-LeanPromptPath
    $symbolColor = if ($lastCommandSucceeded) { $palette.Success } else { $palette.Error }
    $global:LASTEXITCODE = $lastExitCode
    "$firstLine`n$symbolColor❯$reset "
}

$script:__PwshProfileCommandLine = [Environment]::GetCommandLineArgs()
$script:__PwshProfileIsBatch = [bool]($script:__PwshProfileCommandLine -match '(?i)^-(Command|c|File|f|EncodedCommand|ec)$')
$script:__PwshProfileHasNoExit = [bool]($script:__PwshProfileCommandLine -match '(?i)^-(NoExit|noe)$')
$script:__PwshProfileIsInteractive = $Host.Name -eq 'ConsoleHost' -and
    -not [Console]::IsInputRedirected -and
    -not [Console]::IsOutputRedirected -and
    (-not $script:__PwshProfileIsBatch -or $script:__PwshProfileHasNoExit)

function global:Start-ProfileBackgroundPowerShell {
    param(
        [Parameter(Mandatory)][string] $ScriptPath,
        [string[]] $Arguments = @()
    )

    $pwsh = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwsh)) { return $false }

    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $pwsh
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($arg in @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments) {
            [void] $psi.ArgumentList.Add($arg)
        }
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        $true
    }
    catch {
        $false
    }
}

# >>> async git status prompt >>>
# Starship built-in git_status and language modules scan synchronously; use cache + background refresh here to emulate p10k async status.
$script:__AsyncGitStatusOldPrompt = $function:prompt
$script:__AsyncGitStatusCacheDir = Join-Path $env:LOCALAPPDATA 'PowerShell\ProfileCache\AsyncGitStatus'
$script:__AsyncGitStatusUpdater = Join-Path $PSScriptRoot 'prompt-updaters\Update-AsyncGitStatus.ps1'
$script:__AsyncGitStatusTtlSeconds = 2
$script:__AsyncGitStatusLockSeconds = 2
$script:__AsyncGitStatusMemoryPath = $null
$script:__AsyncGitStatusMemoryCachePath = $null
$script:__AsyncGitStatusMemoryLastWriteTimeUtc = [datetime]::MinValue
$script:__AsyncGitStatusMemoryText = ''
$script:__LeanPromptAsyncGitRedrawCachePath = ''
$script:__LeanPromptAsyncGitRedrawLastUtc = [datetime]::MinValue
$script:__LeanPromptAsyncGitRedrawSourceId = 'LeanPrompt.AsyncGitStatus.Redraw'
$script:__LeanPromptAsyncGitRedrawWatcher = $null
$script:__AsyncToolchainStatusCacheDir = Join-Path $env:LOCALAPPDATA 'PowerShell\ProfileCache\AsyncToolchainStatus'
$script:__AsyncToolchainStatusUpdater = Join-Path $PSScriptRoot 'prompt-updaters\Update-AsyncToolchainStatus.ps1'
$script:__AsyncToolchainStatusTtlSeconds = 30
$script:__AsyncToolchainStatusLockSeconds = 2
$script:__AsyncToolchainStatusMemoryPath = $null
$script:__AsyncToolchainStatusMemoryCachePath = $null
$script:__AsyncToolchainStatusMemoryLastWriteTimeUtc = [datetime]::MinValue
$script:__AsyncToolchainStatusMemoryText = ''

function global:Get-AsyncStatusKey {
    param([Parameter(Mandatory)][string] $Path)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    -join ($hash | ForEach-Object { $_.ToString('x2') })
}

function global:Get-AsyncGitStatusKey { param([Parameter(Mandatory)][string] $Path) Get-AsyncStatusKey -Path $Path }

function global:Start-AsyncStatusRefresh {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $CachePath,
        [Parameter(Mandatory)][string] $LockPath,
        [Parameter(Mandatory)][string] $UpdaterPath,
        [Parameter(Mandatory)][int] $LockSeconds
    )

    $cacheDir = Split-Path -Parent $CachePath
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

    $now = Get-Date
    if (Test-Path -LiteralPath $LockPath) {
        $lock = Get-Item -LiteralPath $LockPath -ErrorAction SilentlyContinue
        if ($lock -and $lock.LastWriteTime -gt $now.AddSeconds(-$LockSeconds)) { return }
    }

    New-Item -ItemType File -Force -Path $LockPath | Out-Null
    $started = Start-ProfileBackgroundPowerShell -ScriptPath $UpdaterPath -Arguments @(
        '-Cwd', $Path,
        '-CachePath', $CachePath,
        '-LockPath', $LockPath
    )
    if (-not $started) {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    }
}
function global:Start-AsyncGitStatusRefresh {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $CachePath, [Parameter(Mandatory)][string] $LockPath)
    Start-AsyncStatusRefresh -Path $Path -CachePath $CachePath -LockPath $LockPath -UpdaterPath $script:__AsyncGitStatusUpdater -LockSeconds $script:__AsyncGitStatusLockSeconds
}

function global:Start-AsyncToolchainStatusRefresh {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $CachePath, [Parameter(Mandatory)][string] $LockPath)
    Start-AsyncStatusRefresh -Path $Path -CachePath $CachePath -LockPath $LockPath -UpdaterPath $script:__AsyncToolchainStatusUpdater -LockSeconds $script:__AsyncToolchainStatusLockSeconds
}

function global:Get-AsyncCachedStatusText {
    param(
        [Parameter(Mandatory)][string] $Kind,
        [Parameter(Mandatory)][string] $CacheDir,
        [Parameter(Mandatory)][int] $TtlSeconds,
        [Parameter(Mandatory)][scriptblock] $Formatter,
        [Parameter(Mandatory)][scriptblock] $Refresh,
        [int] $NegativeTtlSeconds = 0,
        [string] $NegativeProperty = ''
    )

    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return '' }

    $cwd = $location.ProviderPath
    $key = Get-AsyncStatusKey -Path $cwd
    $cachePath = Join-Path $CacheDir "$key.json"
    $lockPath = Join-Path $CacheDir "$key.lock"
    $pathVar = "__Async${Kind}StatusMemoryPath"
    $cacheVar = "__Async${Kind}StatusMemoryCachePath"
    $timeVar = "__Async${Kind}StatusMemoryLastWriteTimeUtc"
    $textVar = "__Async${Kind}StatusMemoryText"

    $text = ''
    $stale = $true
    $now = Get-Date
    $item = $null
    $cached = $null

    if (Test-Path -LiteralPath $cachePath) {
        $item = Get-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue
        try { $cached = Get-Content -LiteralPath $cachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { $cached = $null }

        $ttl = $TtlSeconds
        if ($cached -and $NegativeTtlSeconds -gt 0 -and $NegativeProperty -and
            $cached.PSObject.Properties[$NegativeProperty] -and -not [bool]$cached.$NegativeProperty) {
            $ttl = $NegativeTtlSeconds
        }
        $stale = -not $item -or $item.LastWriteTime -lt $now.AddSeconds(-$ttl)

        if ($item -and
            (Get-Variable -Name $pathVar -Scope Script -ValueOnly) -eq $cwd -and
            (Get-Variable -Name $cacheVar -Scope Script -ValueOnly) -eq $cachePath -and
            (Get-Variable -Name $timeVar -Scope Script -ValueOnly) -eq $item.LastWriteTimeUtc) {
            $text = Get-Variable -Name $textVar -Scope Script -ValueOnly
        }
        elseif ($cached) {
            if ($cached.Path -eq $cwd) { $text = & $Formatter $cached }
            Set-Variable -Name $pathVar -Scope Script -Value $cwd
            Set-Variable -Name $cacheVar -Scope Script -Value $cachePath
            Set-Variable -Name $timeVar -Scope Script -Value $(if ($item) { $item.LastWriteTimeUtc } else { [datetime]::MinValue })
            Set-Variable -Name $textVar -Scope Script -Value $text
        }
        else {
            $stale = $true
            Set-Variable -Name $pathVar -Scope Script -Value $cwd
            Set-Variable -Name $cacheVar -Scope Script -Value $cachePath
            Set-Variable -Name $timeVar -Scope Script -Value ([datetime]::MinValue)
            Set-Variable -Name $textVar -Scope Script -Value ''
        }
    }
    else {
        if ((Get-Variable -Name $pathVar -Scope Script -ValueOnly) -eq $cwd -and (Get-Variable -Name $cacheVar -Scope Script -ValueOnly) -eq $cachePath) {
            Set-Variable -Name $timeVar -Scope Script -Value ([datetime]::MinValue)
            Set-Variable -Name $textVar -Scope Script -Value ''
        }
    }

    if ($stale) { & $Refresh $cwd $cachePath $lockPath }
    $text
}
function global:Resolve-LeanPromptGitPath {
    param(
        [Parameter(Mandatory)][string] $BasePath,
        [Parameter(Mandatory)][string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function global:Get-LeanPromptFileStamp {
    param([AllowNull()][string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return 'missing' }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return "missing:${Path}" }

    $kind = if ($item.PSIsContainer) { 'dir' } else { 'file' }
    $length = if ($item.PSIsContainer) { 0 } else { $item.Length }
    "${kind}:${Path}:$($item.LastWriteTimeUtc.Ticks):${length}"
}

function global:Get-LeanPromptGitQuickState {
    param([Parameter(Mandatory)][string] $Path)

    $lastExitCode = $global:LASTEXITCODE
    try {
        if (-not $script:__LeanPromptGitQuickStatePathCache) {
            $script:__LeanPromptGitQuickStatePathCache = @{}
        }

        $cacheKey = $Path.ToLowerInvariant()
        $cachedPaths = $script:__LeanPromptGitQuickStatePathCache[$cacheKey]
        if ($cachedPaths) {
            $gitDir = $cachedPaths.GitDir
            $commonDir = $cachedPaths.CommonDir
        }
        else {
            $revParse = @(& git -C $Path rev-parse --git-dir --git-common-dir 2>$null)
            if ($LASTEXITCODE -ne 0 -or $revParse.Count -lt 2) {
                return [pscustomobject]@{ IsRepo = $false; Branch = ''; Signature = ''; HeadPath = ''; GitPath = '' }
            }

            $gitDir = Resolve-LeanPromptGitPath -BasePath $Path -Path ([string]$revParse[0]).Trim()
            $commonDir = Resolve-LeanPromptGitPath -BasePath $Path -Path ([string]$revParse[1]).Trim()
            $script:__LeanPromptGitQuickStatePathCache[$cacheKey] = [pscustomobject]@{ GitDir = $gitDir; CommonDir = $commonDir }
        }

        $branch = (& git -C $Path symbolic-ref --quiet --short HEAD 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or -not $branch) {
            $branch = (& git -C $Path rev-parse --short HEAD 2>$null | Select-Object -First 1)
        }
        if ($LASTEXITCODE -ne 0 -or -not $branch) {
            $script:__LeanPromptGitQuickStatePathCache.Remove($cacheKey)
            return [pscustomobject]@{ IsRepo = $false; Branch = ''; Signature = ''; HeadPath = ''; GitPath = '' }
        }
        $branch = ([string]$branch).Trim()

        $headOid = (& git -C $Path rev-parse --verify HEAD 2>$null | Select-Object -First 1)
        $headOid = if ($LASTEXITCODE -eq 0 -and $headOid) { ([string]$headOid).Trim() } else { '' }
        $headRef = (& git -C $Path symbolic-ref --quiet HEAD 2>$null | Select-Object -First 1)
        $headRef = if ($LASTEXITCODE -eq 0 -and $headRef) { ([string]$headRef).Trim() } else { '' }

        $stamps = @(
            "HEAD=${headOid}",
            "HEADREF=${headRef}",
            "BRANCH=${branch}"
        )
        foreach ($name in 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'rebase-merge', 'rebase-apply') {
            $stamps += "${name}=$(Get-LeanPromptFileStamp (Join-Path $gitDir $name))"
        }

        [pscustomobject]@{
            IsRepo = $true
            Branch = $branch
            Signature = ($stamps -join '|')
            HeadPath = $headPath
            GitPath = $gitDir
        }
    }
    finally {
        $global:LASTEXITCODE = $lastExitCode
    }
}

function global:Format-LeanPromptGitStatusText {
    param(
        [AllowNull()] $Status,
        [AllowNull()][string] $Branch
    )

    $palette = $script:LeanPromptPalette
    $parts = @()

    if ($Branch) {
        $parts += "$($palette.GitBranch) $Branch$($palette.GitText)"
    }

    if ($Status -and $Status.IsRepo) {
        $staged = Get-LeanPromptStatusNumber $Status 'Staged'
        $modified = Get-LeanPromptStatusNumber $Status 'Modified'
        $untracked = Get-LeanPromptStatusNumber $Status 'Untracked'
        $deleted = Get-LeanPromptStatusNumber $Status 'Deleted'
        $renamed = Get-LeanPromptStatusNumber $Status 'Renamed'
        $ahead = Get-LeanPromptStatusNumber $Status 'Ahead'
        $behind = Get-LeanPromptStatusNumber $Status 'Behind'
        $stash = Get-LeanPromptStatusNumber $Status 'Stash'
        $conflict = Get-LeanPromptStatusNumber $Status 'Conflict'

        if ($staged -gt 0) { $parts += (Format-LeanPromptGitToken $palette.GitStaged "+$staged") }
        if ($modified -gt 0) { $parts += (Format-LeanPromptGitToken $palette.GitModified "!$modified") }
        if ($untracked -gt 0) { $parts += (Format-LeanPromptGitToken $palette.GitUntracked "?$untracked") }
        if ($deleted -gt 0) { $parts += (Format-LeanPromptGitToken $palette.GitDeleted "x$deleted") }
        if ($renamed -gt 0) { $parts += (Format-LeanPromptGitToken $palette.GitRenamed "»$renamed") }
        if ($ahead -gt 0) { $parts += (Format-LeanPromptGitToken $palette.GitAhead "⇡$ahead") }
        if ($behind -gt 0) { $parts += (Format-LeanPromptGitToken $palette.GitBehind "⇣$behind") }
        if ($stash -gt 0) { $parts += (Format-LeanPromptGitToken $palette.GitStash "≡$stash") }
        if ($conflict -gt 0) { $parts += (Format-LeanPromptGitToken $palette.GitConflict "✖$conflict") }

        $actionProp = $Status.PSObject.Properties['Action']
        $action = if ($actionProp) { [string]$actionProp.Value } else { '' }
        if ($action) {
            $actionColor = if ($action -eq 'rebasing' -or $action -eq 'merging') { $palette.GitConflict } else { $palette.GitModified }
            $parts += (Format-LeanPromptGitToken $actionColor $action)
        }

        if ($parts.Count -le 1 -and $Status.Text) {
            $parts += (Format-LeanPromptGitToken $palette.GitModified $Status.Text)
        }
    }

    if ($parts.Count -eq 0) { return '' }
    Format-LeanPromptLeftSegment -Text ($parts -join ' ') -Foreground $palette.GitText
}
function global:Get-LeanPromptStatusNumber {
    param(
        [Parameter(Mandatory)] $Status,
        [Parameter(Mandatory)][string] $Name
    )

    $prop = $Status.PSObject.Properties[$Name]
    if (-not $prop -or $null -eq $prop.Value) { return 0 }
    try { [int]$prop.Value } catch { 0 }
}

function global:Format-LeanPromptGitToken {
    param(
        [Parameter(Mandatory)][string] $Color,
        [Parameter(Mandatory)][string] $Text
    )

    $Color + $Text + $script:LeanPromptPalette.GitText
}

function global:Get-AsyncGitStatusText {
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return '' }

    $cwd = $location.ProviderPath
    $key = Get-AsyncStatusKey -Path $cwd
    $cachePath = Join-Path $script:__AsyncGitStatusCacheDir "$key.json"
    $lockPath = Join-Path $script:__AsyncGitStatusCacheDir "$key.lock"
    $script:__LeanPromptAsyncGitRedrawCachePath = $cachePath

    $quick = Get-LeanPromptGitQuickState -Path $cwd
    if (-not $quick.IsRepo) { return '' }

    $now = Get-Date
    $item = $null
    $cached = $null
    $signatureMatches = $false

    if (Test-Path -LiteralPath $cachePath) {
        $item = Get-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue
        try { $cached = Get-Content -LiteralPath $cachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { $cached = $null }

        if ($cached -and $cached.Path -eq $cwd -and $cached.IsRepo -and
            $cached.PSObject.Properties['Signature'] -and $cached.Signature -eq $quick.Signature) {
            $signatureMatches = $true
        }
    }

    $stale = -not $item -or $item.LastWriteTime -lt $now.AddSeconds(-$script:__AsyncGitStatusTtlSeconds) -or -not $signatureMatches

    $canUseCachedStatus = $signatureMatches -or ($cached -and $cached.Path -eq $cwd -and $cached.IsRepo -and $cached.Branch -eq $quick.Branch)

    if ($canUseCachedStatus -and $item -and
        $script:__AsyncGitStatusMemoryPath -eq $cwd -and
        $script:__AsyncGitStatusMemoryCachePath -eq $cachePath -and
        $script:__AsyncGitStatusMemoryLastWriteTimeUtc -eq $item.LastWriteTimeUtc) {
        $text = $script:__AsyncGitStatusMemoryText
    }
    elseif ($canUseCachedStatus) {
        $text = Format-LeanPromptGitStatusText -Status $cached -Branch $quick.Branch
        $script:__AsyncGitStatusMemoryPath = $cwd
        $script:__AsyncGitStatusMemoryCachePath = $cachePath
        $script:__AsyncGitStatusMemoryLastWriteTimeUtc = if ($item) { $item.LastWriteTimeUtc } else { [datetime]::MinValue }
        $script:__AsyncGitStatusMemoryText = $text
    }
    else {
        $text = Format-LeanPromptGitStatusText -Status $null -Branch $quick.Branch
        $script:__AsyncGitStatusMemoryPath = $cwd
        $script:__AsyncGitStatusMemoryCachePath = $cachePath
        $script:__AsyncGitStatusMemoryLastWriteTimeUtc = [datetime]::MinValue
        $script:__AsyncGitStatusMemoryText = $text
    }

    if ($stale) { Start-AsyncGitStatusRefresh -Path $cwd -CachePath $cachePath -LockPath $lockPath }
    $text
}
function global:Format-ToolchainStatusText {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $palette = $script:LeanPromptPalette
    $styles = @{
        'node' = @{ Icon = ''; Color = $palette.Node }
        'py'   = @{ Icon = ''; Color = $palette.Python }
        'go'   = @{ Icon = ''; Color = $palette.Go }
        'rs'   = @{ Icon = ''; Color = $palette.Rust }
        '.NET' = @{ Icon = ''; Color = $palette.DotNet }
    }
    $versionColor = $palette.Version

    $parts = @()
    foreach ($match in [regex]::Matches($Text, '(node|py|go|rs|\.NET)\s+(\S+)')) {
        $name = $match.Groups[1].Value
        $version = $match.Groups[2].Value
        $style = $styles[$name]
        $parts += "$($style.Color)$($style.Icon) $versionColor$version"
    }

    if ($parts.Count -eq 0) { return $Text }
    $parts -join ' '
}

function global:Get-AsyncToolchainStatusText {
    Get-AsyncCachedStatusText -Kind 'Toolchain' -CacheDir $script:__AsyncToolchainStatusCacheDir -TtlSeconds $script:__AsyncToolchainStatusTtlSeconds `
        -NegativeTtlSeconds 120 -NegativeProperty 'IsProject' `
        -Formatter { param($status) Format-ToolchainStatusText $status.Text } `
        -Refresh { param($cwd, $cachePath, $lockPath) Start-AsyncToolchainStatusRefresh -Path $cwd -CachePath $cachePath -LockPath $lockPath }
}
function global:prompt {
    $lastExitCode = $global:LASTEXITCODE
    $promptOutput = if ($script:__AsyncGitStatusOldPrompt) { @(& $script:__AsyncGitStatusOldPrompt) } else { @("PS $($executionContext.SessionState.Path.CurrentLocation)> ") }
    $promptText = ($promptOutput | ForEach-Object { [string]$_ }) -join ''

    $gitText = Get-AsyncGitStatusText
    $rightParts = @()
    $toolchainText = Get-AsyncToolchainStatusText
    if (-not [string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $toolchainText))) {
        $rightParts += (Format-LeanPromptRightSegment -Text $toolchainText -Foreground $script:LeanPromptPalette.Version)
    }
    $durationText = Get-LeanPromptCommandDurationText
    if (-not [string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $durationText))) {
        $rightParts += (Format-LeanPromptRightSegment -Text $durationText -Foreground $script:LeanPromptPalette.DurationNormal)
    }
    $rightText = $rightParts -join ''

    if ($promptText -match '^(\r?\n*)([^\r\n]+)') {
        $hasGitText = -not [string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $gitText))
        $leftLine = (Get-LeanPromptPath -Continue:$hasGitText) + $gitText
        $firstLine = Join-LeanPromptAlignedLine -Left $leftLine -Right $rightText
        $global:LASTEXITCODE = $lastExitCode
        return $Matches[1] + $firstLine + $promptText.Substring($Matches[0].Length)
    }

    $global:LASTEXITCODE = $lastExitCode
    if ([string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $rightText))) { return $promptText + $gitText }
    $promptText + $gitText + $rightText
}
function global:Disable-LeanPromptAsyncRedraw {
    $sourceId = $script:__LeanPromptAsyncGitRedrawSourceId
    if ($sourceId) {
        Get-EventSubscriber -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | ForEach-Object {
            try { if ($_.SourceObject) { $_.SourceObject.Dispose() } } catch {}
            Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue
        }
    }

    if ($script:__LeanPromptAsyncGitRedrawWatcher) {
        try { $script:__LeanPromptAsyncGitRedrawWatcher.Dispose() } catch {}
        $script:__LeanPromptAsyncGitRedrawWatcher = $null
    }
}

function global:Enable-LeanPromptAsyncRedraw {
    if (-not $script:__PwshProfileIsInteractive) { return }

    try { [Microsoft.PowerShell.PSConsoleReadLine] | Out-Null }
    catch { return }

    Disable-LeanPromptAsyncRedraw
    New-Item -ItemType Directory -Force -Path $script:__AsyncGitStatusCacheDir | Out-Null

    $watcher = [System.IO.FileSystemWatcher]::new($script:__AsyncGitStatusCacheDir, '*.json')
    $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
    $watcher.EnableRaisingEvents = $true

    Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier $script:__LeanPromptAsyncGitRedrawSourceId -Action {
        try {
            $changedPath = $Event.SourceEventArgs.FullPath
            $currentPath = $script:__LeanPromptAsyncGitRedrawCachePath
            if ([string]::IsNullOrWhiteSpace($currentPath) -or -not $changedPath.Equals($currentPath, [System.StringComparison]::OrdinalIgnoreCase)) { return }

            $now = [datetime]::UtcNow
            if (($now - $script:__LeanPromptAsyncGitRedrawLastUtc).TotalMilliseconds -lt 150) { return }
            $script:__LeanPromptAsyncGitRedrawLastUtc = $now

            [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
        }
        catch {}
    } | Out-Null

    $script:__LeanPromptAsyncGitRedrawWatcher = $watcher
}
# <<< async git status prompt <<<

