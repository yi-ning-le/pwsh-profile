# ============================================================
#  PowerShell profile -- zsh + oh-my-zsh + p10k-like feel
#  Goals: Starship-style prompt / history autosuggestions / syntax highlighting /
#         path completion / ls icons / omz-style aliases
# ============================================================

# ---- Pure PowerShell prompt (Starship lean / powerlevel10k inspired) ----
$script:__LeanPromptAnsiRegex = [regex]::new(([regex]::Escape([string][char]27)) + '\[[0-9;]*m')
$script:__LeanPromptProjectRootCache = @{}
$script:__LeanPromptProjectRootCacheTtlSeconds = 5
$script:__LeanPromptCommandStartUtc = $null
$script:__LeanPromptDurationEnabled = $false
$script:__LeanPromptRightMinWidth = 50
$script:__LeanPromptRightGapCells = 2
$script:__LeanPromptAsyncGitRedrawDebounceMs = 250

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

$script:LeanPromptSymbolSet = 'classic'
$script:LeanPromptSymbolsBySet = @{
    classic = @{
        PathContinueSeparator = ''
        SegmentSeparator      = ''
        RightSegmentSeparator = ''
        PromptChar            = '❯'
        ReadOnly              = ''
        GitBranch             = ''
        GitStaged             = '+'
        GitModified           = '!'
        GitUntracked          = '?'
        GitDeleted            = 'x'
        GitRenamed            = '»'
        GitAhead              = '⇡'
        GitBehind             = '⇣'
        GitStash              = '≡'
        GitConflict           = ''
        Node                  = ''
        Python                = ''
        Go                    = ''
        Rust                  = ''
        DotNet                = ''
    }
    ascii = @{
        PathContinueSeparator = '|'
        SegmentSeparator      = '>'
        RightSegmentSeparator = '<'
        PromptChar            = '>'
        ReadOnly              = '[ro]'
        GitBranch             = 'git'
        GitStaged             = '+'
        GitModified           = '!'
        GitUntracked          = '?'
        GitDeleted            = 'x'
        GitRenamed            = '>'
        GitAhead              = '^'
        GitBehind             = 'v'
        GitStash              = '='
        GitConflict           = 'x'
        Node                  = 'node'
        Python                = 'py'
        Go                    = 'go'
        Rust                  = 'rs'
        DotNet                = '.NET'
    }
}

function global:Get-LeanPromptSymbols {
    $setName = if ($script:LeanPromptSymbolSet) { [string]$script:LeanPromptSymbolSet } else { 'classic' }
    if ($script:LeanPromptSymbolsBySet.ContainsKey($setName)) { return $script:LeanPromptSymbolsBySet[$setName] }
    $script:LeanPromptSymbolsBySet['classic']
}

function global:Test-LeanPromptGlyphs {
    $rows = foreach ($setName in ($script:LeanPromptSymbolsBySet.Keys | Sort-Object)) {
        $symbols = $script:LeanPromptSymbolsBySet[$setName]
        foreach ($name in ($symbols.Keys | Sort-Object)) {
            $glyph = [string]$symbols[$name]
            $runes = @($glyph.EnumerateRunes())
            $codepoints = ($runes | ForEach-Object { 'U+{0:X}' -f $_.Value }) -join ' '

            [pscustomobject]@{
                Set       = $setName
                Name      = $name
                Glyph     = $glyph
                Codepoint = $codepoints
                Cells     = Get-LeanPromptDisplayWidth $glyph
            }
        }
    }

    $rows | Format-Table -AutoSize

    Write-Host ''
    Write-Host 'Samples:'
    foreach ($setName in ($script:LeanPromptSymbolsBySet.Keys | Sort-Object)) {
        $symbols = $script:LeanPromptSymbolsBySet[$setName]
        $path = "R:/Design-Service $($symbols.ReadOnly) $($symbols.PathContinueSeparator) $($symbols.SegmentSeparator)"
        $git = "$($symbols.GitBranch) branch $($symbols.GitStaged)1 $($symbols.GitModified)2 $($symbols.GitUntracked)3 $($symbols.GitDeleted)4 $($symbols.GitRenamed)5 $($symbols.GitAhead)6 $($symbols.GitBehind)7 $($symbols.GitStash)8 $($symbols.GitConflict)9"
        Write-Host ("{0}: {1} | {2} | {3}" -f $setName, $path, $git, $symbols.PromptChar)
    }
}

function global:Remove-LeanPromptAnsi {
    param([AllowNull()][string] $Text)
    if ($null -eq $Text) { return '' }
    $script:__LeanPromptAnsiRegex.Replace($Text, '')
}

function global:Get-LeanPromptDisplayWidth {
    param([AllowNull()][string] $Text)

    $plain = Remove-LeanPromptAnsi $Text
    if ([string]::IsNullOrEmpty($plain)) { return 0 }

    try { return $Host.UI.RawUI.LengthInBufferCells($plain) }
    catch { return $plain.Length }
}

function global:Format-LeanPromptLeftSegment {
    param(
        [AllowNull()][string] $Text,
        [string] $Foreground = $script:LeanPromptPalette.SegmentText,
        [switch] $Continue
    )

    if ([string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $Text))) { return '' }

    $palette = $script:LeanPromptPalette
    $symbols = Get-LeanPromptSymbols
    if ($Continue) {
        return "$($palette.SegmentBg)$Foreground $Text $($palette.PathMuted)$($symbols.PathContinueSeparator)"
    }

    "$($palette.SegmentBg)$Foreground $Text $($palette.Reset)$($palette.SegmentSeparator)$($symbols.SegmentSeparator)$($palette.Reset)"
}

function global:Format-LeanPromptRightSegment {
    param(
        [AllowNull()][string] $Text,
        [string] $Foreground = $script:LeanPromptPalette.SegmentText
    )

    if ([string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $Text))) { return '' }

    $palette = $script:LeanPromptPalette
    $symbols = Get-LeanPromptSymbols
    "$($palette.SegmentSeparator)$($symbols.RightSegmentSeparator)$($palette.SegmentBg)$Foreground $Text $($palette.Reset)"
}

function global:Join-LeanPromptAlignedLine {
    param(
        [Parameter(Mandatory)][string] $Left,
        [AllowNull()][string] $Right
    )

    if ([string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $Right))) { return $Left }

    try { $width = $Host.UI.RawUI.WindowSize.Width }
    catch { return $Left }

    if ($width -lt $script:__LeanPromptRightMinWidth) { return $Left }

    $leftWidth = Get-LeanPromptDisplayWidth $Left
    $rightWidth = Get-LeanPromptDisplayWidth $Right
    if (($leftWidth + $script:__LeanPromptRightGapCells + $rightWidth) -gt $width) { return $Left }

    $rightColumn = $width - $rightWidth + 1
    $Left + "`e[$rightColumn`G" + $Right
}

function global:ConvertTo-LeanPromptSlashPath {
    param([Parameter(Mandatory)][string] $Path)

    $display = $Path -replace '\\', '/'
    $homePath = ([Environment]::GetFolderPath('UserProfile')) -replace '\\', '/'
    if ($homePath) {
        foreach ($homePrefix in @(
                @{ Path = $homePath; Replacement = '~'; ClosingQuote = '' }
                @{ Path = "'$homePath"; Replacement = "'~"; ClosingQuote = "'" }
                @{ Path = '"' + $homePath; Replacement = '"~'; ClosingQuote = '"' }
            )) {
            $prefix = $homePrefix.Path
            $replacement = $homePrefix.Replacement
            $closingQuote = $homePrefix.ClosingQuote
            if ($display.Equals($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $replacement
            }
            if ($closingQuote -and $display.Equals($prefix + $closingQuote, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $replacement + $closingQuote
            }
            if ($display.StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                return $replacement + $display.Substring($prefix.Length)
            }
        }
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

    $now = [datetime]::UtcNow
    if ($script:__LeanPromptProjectRootCache.ContainsKey($Path)) {
        $cached = $script:__LeanPromptProjectRootCache[$Path]
        if ($cached.ExpiresUtc -gt $now) {
            if ($cached.Root) { return $cached.Root }
            return $null
        }
        $script:__LeanPromptProjectRootCache.Remove($Path)
    }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }

    $dir = if ($item.PSIsContainer) { $item } else { $item.Directory }
    for ($depth = 0; $dir -and $depth -lt 8; $depth++) {
        if (Test-LeanPromptProjectMarker -Path $dir.FullName) {
            $script:__LeanPromptProjectRootCache[$Path] = [pscustomobject]@{
                Root = $dir.FullName
                ExpiresUtc = $now.AddSeconds($script:__LeanPromptProjectRootCacheTtlSeconds)
            }
            return $dir.FullName
        }
        $dir = $dir.Parent
    }

    $script:__LeanPromptProjectRootCache[$Path] = [pscustomobject]@{
        Root = ''
        ExpiresUtc = $now.AddSeconds($script:__LeanPromptProjectRootCacheTtlSeconds)
    }
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
    $symbols = Get-LeanPromptSymbols
    try {
        $item = Get-Item -LiteralPath $location.ProviderPath -Force -ErrorAction Stop
        if ($item.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
            $colored += " $($script:LeanPromptPalette.GitModified)$($symbols.ReadOnly)"
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
$script:__AsyncGitStatusCacheDir = Join-Path $env:LOCALAPPDATA 'PowerShell\ProfileCache\AsyncGitStatus'
$script:__AsyncGitStatusUpdater = Join-Path $PSScriptRoot 'prompt-updaters\Update-AsyncGitStatus.ps1'
$script:__AsyncGitStatusTtlSeconds = 2
$script:__AsyncGitStatusNegativeTtlSeconds = 5
$script:__AsyncGitStatusLockSeconds = 30
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
$script:__AsyncToolchainStatusLockSeconds = 30
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

function global:Start-AsyncStatusRefresh {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $CachePath,
        [Parameter(Mandatory)][string] $LockPath,
        [Parameter(Mandatory)][string] $UpdaterPath,
        [Parameter(Mandatory)][int] $LockSeconds
    )

    $lastExitCode = $global:LASTEXITCODE
    try {
        $cacheDir = Split-Path -Parent $CachePath
        try { New-Item -ItemType Directory -Force -Path $cacheDir -ErrorAction Stop | Out-Null }
        catch { return }

        $lockAcquired = $false
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            try {
                $stream = [System.IO.File]::Open(
                    $LockPath,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None
                )
                $stream.Dispose()
                $lockAcquired = $true
                break
            }
            catch [System.IO.IOException] {
                $lock = Get-Item -LiteralPath $LockPath -ErrorAction SilentlyContinue
                if ($attempt -gt 0 -or ($lock -and $lock.LastWriteTimeUtc -gt [datetime]::UtcNow.AddSeconds(-$LockSeconds))) { return }

                # ponytail: 30s stale locks keep this lock file simple; use a held handle only if refreshes measurably exceed that ceiling.
                Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
            }
            catch { return }
        }

        if (-not $lockAcquired) { return }
        $started = Start-ProfileBackgroundPowerShell -ScriptPath $UpdaterPath -Arguments @(
            '-Cwd', $Path,
            '-CachePath', $CachePath,
            '-LockPath', $LockPath
        )
        if (-not $started) {
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        $global:LASTEXITCODE = $lastExitCode
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

    if (Test-Path -LiteralPath $cachePath -ErrorAction SilentlyContinue) {
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
function global:Format-LeanPromptGitStatusText {
    param(
        [AllowNull()] $Status,
        [AllowNull()][string] $Branch
    )

    $palette = $script:LeanPromptPalette
    $symbols = Get-LeanPromptSymbols
    $parts = @()

    if ($Branch) {
        $parts += "$($palette.GitBranch)$($symbols.GitBranch) $Branch$($palette.GitText)"
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

        foreach ($token in @(
                Format-LeanPromptGitCount $palette.GitStaged 'GitStaged' $staged
                Format-LeanPromptGitCount $palette.GitModified 'GitModified' $modified
                Format-LeanPromptGitCount $palette.GitUntracked 'GitUntracked' $untracked
                Format-LeanPromptGitCount $palette.GitDeleted 'GitDeleted' $deleted
                Format-LeanPromptGitCount $palette.GitRenamed 'GitRenamed' $renamed
                Format-LeanPromptGitCount $palette.GitAhead 'GitAhead' $ahead
                Format-LeanPromptGitCount $palette.GitBehind 'GitBehind' $behind
                Format-LeanPromptGitCount $palette.GitStash 'GitStash' $stash
                Format-LeanPromptGitCount $palette.GitConflict 'GitConflict' $conflict
            )) {
            if ($token) { $parts += $token }
        }

        $actionProp = $Status.PSObject.Properties['Action']
        $action = if ($actionProp) { [string]$actionProp.Value } else { '' }
        if ($action) {
            $actionColor = if ($action -eq 'rebasing' -or $action -eq 'merging') { $palette.GitConflict } else { $palette.GitModified }
            $parts += (Format-LeanPromptGitToken $actionColor $action)
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

function global:Format-LeanPromptGitCount {
    param(
        [Parameter(Mandatory)][string] $Color,
        [Parameter(Mandatory)][string] $SymbolName,
        [Parameter(Mandatory)][int] $Count
    )

    if ($Count -le 0) { return '' }
    $symbols = Get-LeanPromptSymbols
    $symbol = if ($symbols.ContainsKey($SymbolName)) { $symbols[$SymbolName] } else { '' }
    Format-LeanPromptGitToken $Color "$symbol$Count"
}

function global:Get-AsyncGitStatusText {
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return '' }

    $cwd = $location.ProviderPath
    $key = Get-AsyncStatusKey -Path $cwd
    $script:__LeanPromptAsyncGitRedrawCachePath = Join-Path $script:__AsyncGitStatusCacheDir "$key.json"

    Get-AsyncCachedStatusText -Kind 'Git' -CacheDir $script:__AsyncGitStatusCacheDir -TtlSeconds $script:__AsyncGitStatusTtlSeconds `
        -NegativeTtlSeconds $script:__AsyncGitStatusNegativeTtlSeconds -NegativeProperty 'IsRepo' `
        -Formatter { param($status) Format-LeanPromptGitStatusText -Status $status -Branch $status.Branch } `
        -Refresh { param($path, $cachePath, $lockPath) Start-AsyncGitStatusRefresh -Path $path -CachePath $cachePath -LockPath $lockPath }
}
function global:Format-ToolchainStatusText {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $palette = $script:LeanPromptPalette
    $symbols = Get-LeanPromptSymbols
    $styles = @{
        'node' = @{ Symbol = 'Node'; Color = $palette.Node }
        'py'   = @{ Symbol = 'Python'; Color = $palette.Python }
        'go'   = @{ Symbol = 'Go'; Color = $palette.Go }
        'rs'   = @{ Symbol = 'Rust'; Color = $palette.Rust }
        '.NET' = @{ Symbol = 'DotNet'; Color = $palette.DotNet }
    }
    $versionColor = $palette.Version

    $parts = @()
    foreach ($match in [regex]::Matches($Text, '(node|py|go|rs|\.NET)\s+(\S+)')) {
        $name = $match.Groups[1].Value
        $version = $match.Groups[2].Value
        $style = $styles[$name]
        $parts += "$($style.Color)$($symbols[$style.Symbol]) $versionColor$version"
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
    $lastCommandSucceeded = $?
    $lastExitCode = $global:LASTEXITCODE
    $palette = $script:LeanPromptPalette
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

    $hasGitText = -not [string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $gitText))
    $leftLine = (Get-LeanPromptPath -Continue:$hasGitText) + $gitText
    $firstLine = Join-LeanPromptAlignedLine -Left $leftLine -Right $rightText
    $symbolColor = if ($lastCommandSucceeded) { $palette.Success } else { $palette.Error }
    $symbols = Get-LeanPromptSymbols
    $global:LASTEXITCODE = $lastExitCode
    "$firstLine`n$symbolColor$($symbols.PromptChar)$($palette.Reset) "
}
function global:Disable-LeanPromptAsyncRedraw {
    $sourceId = $script:__LeanPromptAsyncGitRedrawSourceId
    if ($sourceId) {
        Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object {
            $_.SourceIdentifier -eq $sourceId -or $_.SourceIdentifier.StartsWith("$sourceId.", [System.StringComparison]::Ordinal)
        } | ForEach-Object {
            $actionJob = $_.Action
            Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue
            if ($actionJob) { Remove-Job -Job $actionJob -Force -ErrorAction SilentlyContinue }
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
    try {
        New-Item -ItemType Directory -Force -Path $script:__AsyncGitStatusCacheDir -ErrorAction Stop | Out-Null
        $watcher = [System.IO.FileSystemWatcher]::new($script:__AsyncGitStatusCacheDir, '*.json')
        $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
        $script:__LeanPromptAsyncGitRedrawWatcher = $watcher

        $redrawAction = {
            try {
                $changedPath = $Event.SourceEventArgs.FullPath
                $currentPath = $script:__LeanPromptAsyncGitRedrawCachePath
                if ([string]::IsNullOrWhiteSpace($currentPath) -or -not $changedPath.Equals($currentPath, [System.StringComparison]::OrdinalIgnoreCase)) { return }

                $now = [datetime]::UtcNow
                if (($now - $script:__LeanPromptAsyncGitRedrawLastUtc).TotalMilliseconds -lt $script:__LeanPromptAsyncGitRedrawDebounceMs) { return }
                $script:__LeanPromptAsyncGitRedrawLastUtc = $now

                [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
            }
            catch {}
        }

        foreach ($eventName in 'Created', 'Changed', 'Renamed') {
            Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier "$($script:__LeanPromptAsyncGitRedrawSourceId).$eventName" -Action $redrawAction | Out-Null
        }
        $watcher.EnableRaisingEvents = $true
    }
    catch {
        Disable-LeanPromptAsyncRedraw
    }
}
# <<< async git status prompt <<<
