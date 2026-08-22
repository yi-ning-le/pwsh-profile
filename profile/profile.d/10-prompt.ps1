# ============================================================
#  PowerShell profile -- zsh + oh-my-zsh + p10k-like feel
#  Goals: Starship-style prompt / history autosuggestions / syntax highlighting /
#         path completion / ls icons / omz-style aliases
# ============================================================

# ---- Pure PowerShell prompt (Starship lean / powerlevel10k inspired) ----
if (-not ($script:State -is [hashtable])) { $script:State = @{} }
if (-not ($script:State.Prompt -is [hashtable])) { $script:State.Prompt = @{} }

$previousDisablePromptRedraw = Get-Item Function:\Disable-LeanPromptAsyncRedraw -ErrorAction SilentlyContinue
if ($previousDisablePromptRedraw -and $previousDisablePromptRedraw.ModuleName -ceq 'PwshProfile') {
    & $previousDisablePromptRedraw
}
$promptSessionId = [guid]::NewGuid().ToString('N')
$script:State.Prompt = @{
    __LeanPromptAnsiRegex = [regex]::new(([regex]::Escape([string][char]27)) + '\[[0-9;]*m')
    __LeanPromptProjectRootCache = @{}
    __LeanPromptProjectRootCacheTtlSeconds = 60
    __LeanPromptCommandStartUtc = $null
    __LeanPromptDurationEnabled = $false
    __LeanPromptStatusOverride = $null
    __LeanPromptRightMinWidth = 50
    __LeanPromptRightGapCells = 2
    LeanPromptPalette = @{
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
    LeanPromptSymbolSet = 'classic'
    LeanPromptSymbolsBySet = @{
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
    __AsyncGitStatusSessionId = $promptSessionId
    __AsyncGitStatusCacheDir = Join-Path $env:LOCALAPPDATA "PowerShell\ProfileCache\AsyncGitStatus\$promptSessionId"
    __AsyncGitStatusUpdater = Join-Path $PSScriptRoot 'prompt-updaters\Update-AsyncGitStatus.ps1'
    __AsyncGitStatusLockSeconds = 30
    __AsyncGitStatusRequestQueue = $null
    __AsyncGitStatusWorkerPowerShell = $null
    __AsyncGitStatusWorkerAsyncResult = $null
    __AsyncGitStatusMemoryPath = $null
    __AsyncGitStatusMemoryCachePath = $null
    __AsyncGitStatusMemoryLastWriteTimeUtc = [datetime]::MinValue
    __AsyncGitStatusMemoryExpiresUtc = [datetime]::MinValue
    __AsyncGitStatusMemoryText = ''
    __LeanPromptGitLastPath = $null
    __LeanPromptGitGeneration = 0L
    __LeanPromptGitRequestedPath = $null
    __LeanPromptGitRequestedGeneration = -1L
    __LeanPromptGitCompletedPath = $null
    __LeanPromptGitCompletedGeneration = -1L
    __LeanPromptGitBranchRefreshPending = $false
    __LeanPromptGitBranchOverride = $null
    __LeanPromptAsyncGitRedrawState = [hashtable]::Synchronized(@{
        CachePath = ''
        LastUtc = [datetime]::MinValue
    })
    __LeanPromptAsyncGitRedrawSourceId = "LeanPrompt.AsyncGitStatus.Redraw.$promptSessionId"
    __LeanPromptAsyncGitRedrawWatcher = $null
    __LeanPromptAsyncToolchainRedrawState = [hashtable]::Synchronized(@{
        CachePath = ''
        LastUtc = [datetime]::MinValue
    })
    __LeanPromptAsyncRedrawDispatchState = [hashtable]::Synchronized(@{
        LastUtc = [datetime]::MinValue
        Count = 0L
        Pending = $false
        Rendering = $false
        InputActive = $false
        CompletionActive = $false
        QueuedKeys = $null
        CacheDriven = $false
        PromptCompletedUtc = [datetime]::MinValue
    })
    __LeanPromptAsyncToolchainRedrawWatcher = $null
    __LeanPromptAsyncRedrawTimer = $null
    __LeanPromptAsyncGitExitSubscriptionId = $null
    __LeanPromptAsyncGitExitJobId = $null
    __AsyncToolchainStatusCacheDir = Join-Path $env:LOCALAPPDATA 'PowerShell\ProfileCache\AsyncToolchainStatus'
    __AsyncToolchainStatusUpdater = Join-Path $PSScriptRoot 'prompt-updaters\Update-AsyncToolchainStatus.ps1'
    __AsyncToolchainStatusTtlSeconds = 30
    __AsyncToolchainStatusLockSeconds = 30
    __AsyncToolchainStatusMemoryPath = $null
    __AsyncToolchainStatusMemoryCachePath = $null
    __AsyncToolchainStatusMemoryLastWriteTimeUtc = [datetime]::MinValue
    __AsyncToolchainStatusMemoryExpiresUtc = [datetime]::MinValue
    __AsyncToolchainStatusMemoryText = ''
}
Remove-Variable previousDisablePromptRedraw, promptSessionId -ErrorAction SilentlyContinue

function Set-LeanPromptSymbolSet {
    param([Parameter(Mandatory)][ValidateSet('classic', 'ascii')][string] $Name)
    $script:State.Prompt.LeanPromptSymbolSet = $Name
}

function Get-LeanPromptSymbols {
    $setName = if ($script:State.Prompt.LeanPromptSymbolSet) { [string]$script:State.Prompt.LeanPromptSymbolSet } else { 'classic' }
    if ($script:State.Prompt.LeanPromptSymbolsBySet.ContainsKey($setName)) { return $script:State.Prompt.LeanPromptSymbolsBySet[$setName] }
    $script:State.Prompt.LeanPromptSymbolsBySet['classic']
}

function Test-LeanPromptGlyphs {
    $rows = foreach ($setName in ($script:State.Prompt.LeanPromptSymbolsBySet.Keys | Sort-Object)) {
        $symbols = $script:State.Prompt.LeanPromptSymbolsBySet[$setName]
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
    foreach ($setName in ($script:State.Prompt.LeanPromptSymbolsBySet.Keys | Sort-Object)) {
        $symbols = $script:State.Prompt.LeanPromptSymbolsBySet[$setName]
        $path = "R:/Design-Service $($symbols.ReadOnly) $($symbols.PathContinueSeparator) $($symbols.SegmentSeparator)"
        $git = "$($symbols.GitBranch) branch $($symbols.GitStaged)1 $($symbols.GitModified)2 $($symbols.GitUntracked)3 $($symbols.GitDeleted)4 $($symbols.GitRenamed)5 $($symbols.GitAhead)6 $($symbols.GitBehind)7 $($symbols.GitStash)8 $($symbols.GitConflict)9"
        Write-Host ("{0}: {1} | {2} | {3}" -f $setName, $path, $git, $symbols.PromptChar)
    }
}

function Remove-LeanPromptAnsi {
    param([AllowNull()][string] $Text)
    if ($null -eq $Text) { return '' }
    $script:State.Prompt.__LeanPromptAnsiRegex.Replace($Text, '')
}

function Get-LeanPromptDisplayWidth {
    param([AllowNull()][string] $Text)

    $plain = Remove-LeanPromptAnsi $Text
    if ([string]::IsNullOrEmpty($plain)) { return 0 }

    try { return $Host.UI.RawUI.LengthInBufferCells($plain) }
    catch { return $plain.Length }
}

function Limit-LeanPromptDisplayWidth {
    param(
        [AllowNull()][string] $Text,
        [Parameter(Mandatory)][int] $MaxWidth
    )

    if ([string]::IsNullOrEmpty($Text) -or $MaxWidth -le 0) { return '' }
    if ((Get-LeanPromptDisplayWidth $Text) -le $MaxWidth) { return $Text }

    $ellipsis = '…'
    $contentWidth = [Math]::Max(0, $MaxWidth - (Get-LeanPromptDisplayWidth $ellipsis))
    $result = [System.Text.StringBuilder]::new()
    $width = 0
    for ($index = 0; $index -lt $Text.Length;) {
        $ansi = $script:State.Prompt.__LeanPromptAnsiRegex.Match($Text, $index)
        if ($ansi.Success -and $ansi.Index -eq $index) {
            $null = $result.Append($ansi.Value)
            $index += $ansi.Length
            continue
        }

        $element = [System.Globalization.StringInfo]::GetNextTextElement($Text, $index)
        $elementWidth = Get-LeanPromptDisplayWidth $element
        if (($width + $elementWidth) -gt $contentWidth) { break }
        $null = $result.Append($element)
        $width += $elementWidth
        $index += $element.Length
    }

    $result.ToString() + $ellipsis + $script:State.Prompt.LeanPromptPalette.Reset
}

function Format-LeanPromptLeftSegment {
    param(
        [AllowNull()][string] $Text,
        [string] $Foreground = $script:State.Prompt.LeanPromptPalette.SegmentText,
        [switch] $Continue
    )

    if ([string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $Text))) { return '' }

    $palette = $script:State.Prompt.LeanPromptPalette
    $symbols = Get-LeanPromptSymbols
    if ($Continue) {
        return "$($palette.SegmentBg)$Foreground $Text $($palette.PathMuted)$($symbols.PathContinueSeparator)"
    }

    "$($palette.SegmentBg)$Foreground $Text $($palette.Reset)$($palette.SegmentSeparator)$($symbols.SegmentSeparator)$($palette.Reset)"
}

function Format-LeanPromptRightSegment {
    param(
        [AllowNull()][string] $Text,
        [string] $Foreground = $script:State.Prompt.LeanPromptPalette.SegmentText
    )

    if ([string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $Text))) { return '' }

    $palette = $script:State.Prompt.LeanPromptPalette
    $symbols = Get-LeanPromptSymbols
    "$($palette.SegmentSeparator)$($symbols.RightSegmentSeparator)$($palette.SegmentBg)$Foreground $Text $($palette.Reset)"
}

function Join-LeanPromptAlignedLine {
    param(
        [Parameter(Mandatory)][string] $Left,
        [AllowNull()][string] $Right,
        [int] $WindowWidth = 0
    )

    if ($WindowWidth -le 0) {
        try { $WindowWidth = $Host.UI.RawUI.WindowSize.Width }
        catch { return $Left }
    }

    # Leave the last cell unused so writing the newline cannot trigger delayed terminal wrapping.
    $usableWidth = [Math]::Max(0, $WindowWidth - 1)
    $Left = Limit-LeanPromptDisplayWidth -Text $Left -MaxWidth $usableWidth
    if ([string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $Right)) -or
        $WindowWidth -lt $script:State.Prompt.__LeanPromptRightMinWidth) { return $Left }

    $leftWidth = Get-LeanPromptDisplayWidth $Left
    $rightWidth = Get-LeanPromptDisplayWidth $Right
    if (($leftWidth + $script:State.Prompt.__LeanPromptRightGapCells + $rightWidth) -gt $usableWidth) { return $Left }

    $rightColumn = $usableWidth - $rightWidth + 1
    $Left + "`e[$rightColumn`G" + $Right
}

function ConvertTo-LeanPromptSlashPath {
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

function Test-LeanPromptProjectMarker {
    param([Parameter(Mandatory)][string] $Path)

    try {
        $gitPath = [System.IO.Path]::Combine($Path, '.git')
        if ([System.IO.File]::Exists($gitPath) -or [System.IO.Directory]::Exists($gitPath)) { return $true }
        foreach ($marker in 'package.json', 'go.mod', 'Cargo.toml', 'pyproject.toml', 'global.json',
            'rust-toolchain.toml', 'rust-toolchain', '.python-version', '.node-version', '.nvmrc') {
            if ([System.IO.File]::Exists([System.IO.Path]::Combine($Path, $marker))) { return $true }
        }

        $enumerator = [System.IO.Directory]::EnumerateFiles($Path, '*.sln').GetEnumerator()
        try { return $enumerator.MoveNext() }
        finally { $enumerator.Dispose() }
    }
    catch [System.UnauthorizedAccessException] { $false }
    catch [System.Security.SecurityException] { $false }
    catch [System.IO.DirectoryNotFoundException] { $false }
    catch [System.IO.IOException] { $false }
}

function Get-LeanPromptProjectRoot {
    param([Parameter(Mandatory)][string] $Path)

    $now = [datetime]::UtcNow
    if ($script:State.Prompt.__LeanPromptProjectRootCache.ContainsKey($Path)) {
        $cached = $script:State.Prompt.__LeanPromptProjectRootCache[$Path]
        if ($cached.ExpiresUtc -gt $now) {
            if ($cached.Root) { return $cached.Root }
            return $null
        }
        $script:State.Prompt.__LeanPromptProjectRootCache.Remove($Path)
    }

    try {
        $dir = if ([System.IO.Directory]::Exists($Path)) {
            [System.IO.DirectoryInfo]::new($Path)
        }
        elseif ([System.IO.File]::Exists($Path)) {
            [System.IO.FileInfo]::new($Path).Directory
        }
        else { return $null }
    }
    catch { return $null }

    $visited = [System.Collections.Generic.List[string]]::new()
    $expiresUtc = $now.AddSeconds($script:State.Prompt.__LeanPromptProjectRootCacheTtlSeconds)
    for ($depth = 0; $dir -and $depth -lt 8; $depth++) {
        $visited.Add($dir.FullName)
        if (Test-LeanPromptProjectMarker -Path $dir.FullName) {
            $entry = [pscustomobject]@{ Root = $dir.FullName; ExpiresUtc = $expiresUtc }
            foreach ($visitedPath in $visited) {
                $script:State.Prompt.__LeanPromptProjectRootCache[$visitedPath] = $entry
            }
            $script:State.Prompt.__LeanPromptProjectRootCache[$Path] = $entry
            return $dir.FullName
        }
        $dir = $dir.Parent
    }

    $entry = [pscustomobject]@{ Root = ''; ExpiresUtc = $expiresUtc }
    foreach ($visitedPath in $visited) {
        $script:State.Prompt.__LeanPromptProjectRootCache[$visitedPath] = $entry
    }
    $script:State.Prompt.__LeanPromptProjectRootCache[$Path] = $entry
    $null
}

function Compress-LeanPromptRootDisplay {
    param([Parameter(Mandatory)][string] $Display)

    $parts = @($Display -split '/' | Where-Object { $_ })
    if ($parts.Count -le 2) { return $Display }

    if ($Display.StartsWith('~/')) {
        return '~/…/' + $parts[-1]
    }

    if ($parts.Count -le 3) { return $Display }
    $parts[0] + '/…/' + $parts[-1]
}

function Compress-LeanPromptRelativePath {
    param([AllowNull()][string] $RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -eq '.') { return '' }

    $relative = $RelativePath -replace '\\', '/'
    $parts = @($relative -split '/' | Where-Object { $_ })
    if ($parts.Count -le 2) { return $relative }

    '…/' + (($parts | Select-Object -Last 2) -join '/')
}

function Colorize-LeanPromptPath {
    param([Parameter(Mandatory)][string] $Display)

    $palette = $script:State.Prompt.LeanPromptPalette
    $idx = $Display.LastIndexOf('/')
    if ($idx -lt 0) { return $palette.PathAnchor + $Display }

    $palette.PathMuted + $Display.Substring(0, $idx + 1) + $palette.PathAnchor + $Display.Substring($idx + 1)
}

function Get-LeanPromptPath {
    param([switch] $Continue)
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        return Format-LeanPromptLeftSegment -Text ($script:State.Prompt.LeanPromptPalette.PathAnchor + [string]$location) -Foreground $script:State.Prompt.LeanPromptPalette.Path -Continue:$Continue
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
            $colored += " $($script:State.Prompt.LeanPromptPalette.GitModified)$($symbols.ReadOnly)"
        }
    }
    catch { }

    Format-LeanPromptLeftSegment -Text $colored -Foreground $script:State.Prompt.LeanPromptPalette.Path -Continue:$Continue
}

function Format-LeanPromptCommandDurationText {
    param([Parameter(Mandatory)][timespan] $Duration)

    if ($Duration.TotalSeconds -lt 2) { return '' }

    $palette = $script:State.Prompt.LeanPromptPalette
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

function Get-LeanPromptCommandDurationText {
    if (-not $script:State.Prompt.__LeanPromptDurationEnabled -or -not $script:State.Prompt.__LeanPromptCommandStartUtc) { return '' }

    $duration = [datetime]::UtcNow - $script:State.Prompt.__LeanPromptCommandStartUtc
    $script:State.Prompt.__LeanPromptCommandStartUtc = $null
    Format-LeanPromptCommandDurationText -Duration $duration
}

function Start-ProfileBackgroundPowerShell {
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
# Starship built-in git_status and language modules scan synchronously; use a per-session worker so stale status never masquerades as current.

function Get-AsyncStatusKey {
    param([Parameter(Mandatory)][string] $Path)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    -join ($hash | ForEach-Object { $_.ToString('x2') })
}

function Start-AsyncStatusRefresh {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $CachePath,
        [Parameter(Mandatory)][string] $LockPath,
        [Parameter(Mandatory)][string] $UpdaterPath,
        [Parameter(Mandatory)][int] $LockSeconds,
        [string[]] $UpdaterArguments = @()
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
        $started = Start-ProfileBackgroundPowerShell -ScriptPath $UpdaterPath -Arguments (@(
            '-Cwd', $Path,
            '-CachePath', $CachePath,
            '-LockPath', $LockPath
        ) + $UpdaterArguments)
        if (-not $started) {
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        $global:LASTEXITCODE = $lastExitCode
    }
}
function Stop-LeanPromptGitWorker {
    $queue = $script:State.Prompt.__AsyncGitStatusRequestQueue
    $worker = $script:State.Prompt.__AsyncGitStatusWorkerPowerShell
    try { if ($queue -and -not $queue.IsAddingCompleted) { $queue.CompleteAdding() } } catch {}
    try {
        if ($worker -and $script:State.Prompt.__AsyncGitStatusWorkerAsyncResult -and -not $script:State.Prompt.__AsyncGitStatusWorkerAsyncResult.IsCompleted) {
            $worker.BeginStop($null, $null) | Out-Null
        }
    }
    catch {}
    try { if ($worker) { $worker.Dispose() } } catch {}
    try { if ($queue) { $queue.Dispose() } } catch {}
    $script:State.Prompt.__AsyncGitStatusRequestQueue = $null
    $script:State.Prompt.__AsyncGitStatusWorkerPowerShell = $null
    $script:State.Prompt.__AsyncGitStatusWorkerAsyncResult = $null
}

function Start-LeanPromptGitWorker {
    if ($script:State.Prompt.__AsyncGitStatusWorkerPowerShell -and $script:State.Prompt.__AsyncGitStatusWorkerAsyncResult -and
        -not $script:State.Prompt.__AsyncGitStatusWorkerAsyncResult.IsCompleted) { return $true }

    Stop-LeanPromptGitWorker
    Enable-LeanPromptAsyncRedraw
    $queue = $null
    $worker = $null
    try {
        $queue = [System.Collections.Concurrent.BlockingCollection[object]]::new(1)
        $worker = [powershell]::Create()
        $null = $worker.AddCommand($script:State.Prompt.__AsyncGitStatusUpdater).AddParameter('RequestQueue', $queue)
        $asyncResult = $worker.BeginInvoke()
        if ($asyncResult.IsCompleted) { throw 'Git prompt worker stopped during startup.' }
        $script:State.Prompt.__AsyncGitStatusRequestQueue = $queue
        $script:State.Prompt.__AsyncGitStatusWorkerPowerShell = $worker
        $script:State.Prompt.__AsyncGitStatusWorkerAsyncResult = $asyncResult
        $true
    }
    catch {
        try { if ($worker) { $worker.Dispose() } } catch {}
        try { if ($queue) { $queue.Dispose() } } catch {}
        $false
    }
}

function Start-AsyncGitStatusRefresh {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $CachePath, [Parameter(Mandatory)][string] $LockPath)

    $generation = [long]$script:State.Prompt.__LeanPromptGitGeneration
    if ($script:State.Prompt.__LeanPromptGitRequestedGeneration -eq $generation -and
        $script:State.Prompt.__LeanPromptGitRequestedPath -and
        $script:State.Prompt.__LeanPromptGitRequestedPath.Equals($Path, [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not $script:State.Session.IsInteractive -or
            ($script:State.Prompt.__AsyncGitStatusWorkerAsyncResult -and -not $script:State.Prompt.__AsyncGitStatusWorkerAsyncResult.IsCompleted)) { return }
        $script:State.Prompt.__LeanPromptGitRequestedGeneration = -1L
    }

    if ($script:State.Session.IsInteractive -and (Start-LeanPromptGitWorker)) {
        $request = [pscustomobject]@{
            Cwd = $Path
            CachePath = $CachePath
            SessionId = $script:State.Prompt.__AsyncGitStatusSessionId
            Generation = $generation
        }
        try {
            if (-not $script:State.Prompt.__AsyncGitStatusRequestQueue.TryAdd($request)) {
                $dropped = $null
                $null = $script:State.Prompt.__AsyncGitStatusRequestQueue.TryTake([ref]$dropped)
                if (-not $script:State.Prompt.__AsyncGitStatusRequestQueue.TryAdd($request)) { return }
            }
            $script:State.Prompt.__LeanPromptGitRequestedPath = $Path
            $script:State.Prompt.__LeanPromptGitRequestedGeneration = $generation
            return
        }
        catch { Stop-LeanPromptGitWorker }
    }

    Start-AsyncStatusRefresh -Path $Path -CachePath $CachePath -LockPath $LockPath `
        -UpdaterPath $script:State.Prompt.__AsyncGitStatusUpdater -LockSeconds $script:State.Prompt.__AsyncGitStatusLockSeconds `
        -UpdaterArguments @('-SessionId', $script:State.Prompt.__AsyncGitStatusSessionId, '-Generation', [string]$generation)
    $script:State.Prompt.__LeanPromptGitRequestedPath = $Path
    $script:State.Prompt.__LeanPromptGitRequestedGeneration = $generation
}

function Get-LeanPromptGitBranch {
    param([Parameter(Mandatory)][string] $Path)

    $lastExitCode = $global:LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $probe = @(& git -C $Path rev-parse --abbrev-ref HEAD 2>$null)
        $probeExitCode = $global:LASTEXITCODE
        $head = if ($probe.Count) { ([string]$probe[0]).Trim() } else { '' }
        if ($head -cne 'HEAD') { return $head }

        $fallback = if ($probeExitCode -eq 0) { @('rev-parse', '--short', 'HEAD') }
            else { @('symbolic-ref', '--quiet', '--short', 'HEAD') }
        $resolved = @(& git -C $Path @fallback 2>$null)
        if ($global:LASTEXITCODE -ne 0 -or -not $resolved.Count) { return '' }
        ([string]$resolved[0]).Trim()
    }
    finally {
        $global:LASTEXITCODE = $lastExitCode
    }
}

function Start-AsyncToolchainStatusRefresh {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $CachePath, [Parameter(Mandatory)][string] $LockPath)
    Start-AsyncStatusRefresh -Path $Path -CachePath $CachePath -LockPath $LockPath -UpdaterPath $script:State.Prompt.__AsyncToolchainStatusUpdater -LockSeconds $script:State.Prompt.__AsyncToolchainStatusLockSeconds
}

function Get-AsyncCachedStatusText {
    param(
        [Parameter(Mandatory)][string] $Kind,
        [Parameter(Mandatory)][string] $CacheDir,
        [Parameter(Mandatory)][int] $TtlSeconds,
        [Parameter(Mandatory)][scriptblock] $Formatter,
        [Parameter(Mandatory)][scriptblock] $Refresh,
        [int] $NegativeTtlSeconds = 0,
        [string] $NegativeProperty = '',
        [string] $StatusPath = ''
    )

    if ($StatusPath) {
        $cwd = $StatusPath
    }
    else {
        $location = Get-Location
        if ($location.Provider.Name -ne 'FileSystem') { return '' }
        $cwd = $location.ProviderPath
    }
    $key = Get-AsyncStatusKey -Path $cwd
    $cachePath = Join-Path $CacheDir "$key.json"
    $lockPath = Join-Path $CacheDir "$key.lock"
    $pathVar = "__Async${Kind}StatusMemoryPath"
    $cacheVar = "__Async${Kind}StatusMemoryCachePath"
    $timeVar = "__Async${Kind}StatusMemoryLastWriteTimeUtc"
    $expiresVar = "__Async${Kind}StatusMemoryExpiresUtc"
    $textVar = "__Async${Kind}StatusMemoryText"

    $text = ''
    $stale = $true
    $now = [datetime]::UtcNow
    $item = Get-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue
    if ($item) {
        $memoryMatches = $script:State.Prompt[$pathVar] -eq $cwd -and
            $script:State.Prompt[$cacheVar] -eq $cachePath -and
            $script:State.Prompt[$timeVar] -eq $item.LastWriteTimeUtc
        if ($memoryMatches) {
            $text = $script:State.Prompt[$textVar]
            $stale = $now -ge $script:State.Prompt[$expiresVar]
        }
        else {
            try { $cached = Get-Content -LiteralPath $cachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
            catch { $cached = $null }
            if ($cached) {
                $ttl = $TtlSeconds
                if ($NegativeTtlSeconds -gt 0 -and $NegativeProperty -and
                    $cached.PSObject.Properties[$NegativeProperty] -and -not [bool]$cached.$NegativeProperty) {
                    $ttl = $NegativeTtlSeconds
                }
                $expiresUtc = $item.LastWriteTimeUtc.AddSeconds($ttl)
                if ($cached.Path -eq $cwd) { $text = & $Formatter $cached $item.LastWriteTimeUtc }
                $stale = $now -ge $expiresUtc
                $script:State.Prompt[$pathVar] = $cwd
                $script:State.Prompt[$cacheVar] = $cachePath
                $script:State.Prompt[$timeVar] = $item.LastWriteTimeUtc
                $script:State.Prompt[$expiresVar] = $expiresUtc
                $script:State.Prompt[$textVar] = $text
            }
        }
    }
    if (-not $item -or ($item -and -not $memoryMatches -and -not $cached)) {
        $script:State.Prompt[$pathVar] = $cwd
        $script:State.Prompt[$cacheVar] = $cachePath
        $script:State.Prompt[$timeVar] = [datetime]::MinValue
        $script:State.Prompt[$expiresVar] = [datetime]::MinValue
        $script:State.Prompt[$textVar] = ''
        $text = ''
        $stale = $true
    }

    if ($stale) { & $Refresh $cwd $cachePath $lockPath }
    $text
}
function Format-LeanPromptGitStatusText {
    param(
        [AllowNull()] $Status,
        [AllowNull()][string] $Branch
    )

    $palette = $script:State.Prompt.LeanPromptPalette
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
            $actionColor = if ($action -eq 'rebasing' -or $action -eq 'merging') { $palette.GitConflict }
                else { $palette.GitModified }
            $parts += (Format-LeanPromptGitToken $actionColor $action)
        }

    }

    if ($parts.Count -eq 0) { return '' }
    Format-LeanPromptLeftSegment -Text ($parts -join ' ') -Foreground $palette.GitText
}

function Limit-LeanPromptGitStatusWidth {
    param(
        [AllowNull()][string] $Text,
        [Parameter(Mandatory)][int] $MaxWidth
    )

    $currentWidth = Get-LeanPromptDisplayWidth $Text
    if ([string]::IsNullOrEmpty($Text) -or $MaxWidth -le 0 -or $currentWidth -le $MaxWidth) { return $Text }

    $palette = $script:State.Prompt.LeanPromptPalette
    $symbols = Get-LeanPromptSymbols
    $branchPrefix = "$($palette.GitBranch)$($symbols.GitBranch) "
    $branchStart = $Text.IndexOf($branchPrefix, [System.StringComparison]::Ordinal)
    if ($branchStart -lt 0) { return $Text }
    $branchStart += $branchPrefix.Length
    $branchEnd = $Text.IndexOf($palette.GitText, $branchStart, [System.StringComparison]::Ordinal)
    if ($branchEnd -le $branchStart) { return $Text }

    $branch = $Text.Substring($branchStart, $branchEnd - $branchStart)
    $branchWidth = Get-LeanPromptDisplayWidth $branch
    $branchMaxWidth = [Math]::Max(1, $branchWidth - ($currentWidth - $MaxWidth))
    $shortBranch = Remove-LeanPromptAnsi (Limit-LeanPromptDisplayWidth -Text $branch -MaxWidth $branchMaxWidth)
    $Text.Substring(0, $branchStart) + $shortBranch + $Text.Substring($branchEnd)
}
function Get-LeanPromptStatusNumber {
    param(
        [Parameter(Mandatory)] $Status,
        [Parameter(Mandatory)][string] $Name
    )

    $prop = $Status.PSObject.Properties[$Name]
    if (-not $prop -or $null -eq $prop.Value) { return 0 }
    try { [int]$prop.Value } catch { 0 }
}

function Format-LeanPromptGitToken {
    param(
        [Parameter(Mandatory)][string] $Color,
        [Parameter(Mandatory)][string] $Text
    )

    $Color + $Text + $script:State.Prompt.LeanPromptPalette.GitText
}

function Format-LeanPromptGitCount {
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

function Get-AsyncGitStatusText {
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') { return '' }

    $cwd = $location.ProviderPath
    $key = Get-AsyncStatusKey -Path $cwd
    $cachePath = Join-Path $script:State.Prompt.__AsyncGitStatusCacheDir "$key.json"
    $lockPath = Join-Path $script:State.Prompt.__AsyncGitStatusCacheDir "$key.lock"
    $script:State.Prompt.__LeanPromptAsyncGitRedrawState.CachePath = $cachePath
    $forceRefresh = $false
    $pathChanged = $script:State.Prompt.__LeanPromptGitLastPath -and
        -not $script:State.Prompt.__LeanPromptGitLastPath.Equals($cwd, [System.StringComparison]::OrdinalIgnoreCase)
    $script:State.Prompt.__LeanPromptGitLastPath = $cwd

    if ($script:State.Prompt.__LeanPromptGitBranchRefreshPending -or $pathChanged) {
        $script:State.Prompt.__LeanPromptGitBranchRefreshPending = $false
        $forceRefresh = $true
        $cacheItem = Get-Item -LiteralPath $cachePath -ErrorAction SilentlyContinue
        $script:State.Prompt.__LeanPromptGitBranchOverride = [pscustomobject]@{
            Path = $cwd
            Branch = Get-LeanPromptGitBranch -Path $cwd
            CacheLastWriteTimeUtc = if ($cacheItem) { $cacheItem.LastWriteTimeUtc } else { [datetime]::MinValue }
        }
        $script:State.Prompt.__AsyncGitStatusMemoryLastWriteTimeUtc = [datetime]::MinValue
    }

    $generation = [long]$script:State.Prompt.__LeanPromptGitGeneration
    $sessionId = [string]$script:State.Prompt.__AsyncGitStatusSessionId
    $text = Get-AsyncCachedStatusText -Kind 'Git' -CacheDir $script:State.Prompt.__AsyncGitStatusCacheDir -TtlSeconds 0 `
        -NegativeTtlSeconds 5 -NegativeProperty 'IsRepo' `
        -Formatter {
            param($status, [datetime]$cacheLastWriteTimeUtc)

            $branch = [string]$status.Branch
            $displayStatus = $status
            $statusSession = $status.PSObject.Properties['SessionId']
            $statusGeneration = $status.PSObject.Properties['Generation']
            $isFresh = $statusSession -and $statusGeneration -and
                [string]$statusSession.Value -ceq $sessionId -and [long]$statusGeneration.Value -eq $generation
            if ($isFresh) {
                $script:State.Prompt.__LeanPromptGitCompletedPath = [string]$status.Path
                $script:State.Prompt.__LeanPromptGitCompletedGeneration = $generation
            }
            elseif ($script:State.Prompt.__LeanPromptGitCompletedGeneration -eq $generation -and
                $script:State.Prompt.__LeanPromptGitCompletedPath -and
                $script:State.Prompt.__LeanPromptGitCompletedPath.Equals([string]$status.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                $script:State.Prompt.__LeanPromptGitRequestedGeneration = -1L
            }
            $override = $script:State.Prompt.__LeanPromptGitBranchOverride
            if ($override -and $override.Path.Equals([string]$status.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                $branch = [string]$override.Branch
                if ([string]$status.Branch -cne $branch -and $override.CacheLastWriteTimeUtc -ne $cacheLastWriteTimeUtc) {
                    $branch = Get-LeanPromptGitBranch -Path $status.Path
                    $override.Branch = $branch
                    $override.CacheLastWriteTimeUtc = $cacheLastWriteTimeUtc
                }
                if ([string]$status.Branch -ceq $branch) {
                    $script:State.Prompt.__LeanPromptGitBranchOverride = $null
                }
                else {
                    $displayStatus = $null
                }
            }

            Format-LeanPromptGitStatusText -Status $displayStatus -Branch $branch
        } `
        -Refresh { param($path, $cachePath, $lockPath) Start-AsyncGitStatusRefresh -Path $path -CachePath $cachePath -LockPath $lockPath }

    $override = $script:State.Prompt.__LeanPromptGitBranchOverride
    $overrideApplies = $override -and $override.Path.Equals($cwd, [System.StringComparison]::OrdinalIgnoreCase)
    if ([string]::IsNullOrEmpty($text) -and $overrideApplies) {
        $text = Format-LeanPromptGitStatusText -Status $null -Branch $override.Branch
    }
    if ($forceRefresh -or $overrideApplies) { Start-AsyncGitStatusRefresh -Path $cwd -CachePath $cachePath -LockPath $lockPath }
    $text
}
function Format-ToolchainStatusText {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $palette = $script:State.Prompt.LeanPromptPalette
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

function Get-AsyncToolchainStatusText {
    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        $script:State.Prompt.__LeanPromptAsyncToolchainRedrawState.CachePath = ''
        return ''
    }

    $projectRoot = Get-LeanPromptProjectRoot -Path $location.ProviderPath
    if (-not $projectRoot) {
        $script:State.Prompt.__LeanPromptAsyncToolchainRedrawState.CachePath = ''
        return ''
    }

    $key = Get-AsyncStatusKey -Path $projectRoot
    $script:State.Prompt.__LeanPromptAsyncToolchainRedrawState.CachePath = Join-Path $script:State.Prompt.__AsyncToolchainStatusCacheDir "$key.json"
    Get-AsyncCachedStatusText -Kind 'Toolchain' -CacheDir $script:State.Prompt.__AsyncToolchainStatusCacheDir -TtlSeconds $script:State.Prompt.__AsyncToolchainStatusTtlSeconds `
        -NegativeTtlSeconds 120 -NegativeProperty 'IsProject' `
        -Formatter { param($status) Format-ToolchainStatusText $status.Text } `
        -Refresh { param($cwd, $cachePath, $lockPath) Start-AsyncToolchainStatusRefresh -Path $cwd -CachePath $cachePath -LockPath $lockPath } `
        -StatusPath $projectRoot
}
function prompt {
    $pipelineSucceeded = $?
    $lastExitCode = $global:LASTEXITCODE
    $redrawState = $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState
    $cacheDriven = [bool]$redrawState.CacheDriven
    $redrawState.CacheDriven = $false
    if (-not $cacheDriven) {
        $script:State.Prompt.__LeanPromptGitGeneration = [long]$script:State.Prompt.__LeanPromptGitGeneration + 1
    }
    if ($script:State.Prompt.__LeanPromptAsyncRedrawTimer) {
        $script:State.Prompt.__LeanPromptAsyncRedrawTimer.Stop()
        $redrawState.Pending = $false
        $redrawState.InputActive = $false
        $redrawState.Rendering = $true
    }
    try {
        $lastCommandSucceeded = if ($null -ne $script:State.Prompt.__LeanPromptStatusOverride) {
            [bool]$script:State.Prompt.__LeanPromptStatusOverride
        } else { $pipelineSucceeded }
        $palette = $script:State.Prompt.LeanPromptPalette
        $gitText = Get-AsyncGitStatusText
        $rightParts = @()
        $toolchainText = Get-AsyncToolchainStatusText
        if (-not [string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $toolchainText))) {
            $rightParts += (Format-LeanPromptRightSegment -Text $toolchainText -Foreground $script:State.Prompt.LeanPromptPalette.Version)
        }
        $durationText = Get-LeanPromptCommandDurationText
        if (-not [string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $durationText))) {
            $rightParts += (Format-LeanPromptRightSegment -Text $durationText -Foreground $script:State.Prompt.LeanPromptPalette.DurationNormal)
        }
        $rightText = $rightParts -join ''

        $hasGitText = -not [string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $gitText))
        $pathText = Get-LeanPromptPath -Continue:$hasGitText
        $leftLine = $pathText + $gitText
        $windowWidth = 0
        try { $windowWidth = $Host.UI.RawUI.WindowSize.Width } catch {}
        if ($hasGitText -and $windowWidth -gt 1) {
            $leftBudget = $windowWidth - 1
            if ($windowWidth -ge $script:State.Prompt.__LeanPromptRightMinWidth -and
                -not [string]::IsNullOrWhiteSpace((Remove-LeanPromptAnsi $rightText))) {
                $rightBudget = $leftBudget - $script:State.Prompt.__LeanPromptRightGapCells - (Get-LeanPromptDisplayWidth $rightText)
                if ($rightBudget -gt 0) { $leftBudget = $rightBudget }
            }
            if ((Get-LeanPromptDisplayWidth $leftLine) -gt $leftBudget) {
                $gitBudget = $leftBudget - (Get-LeanPromptDisplayWidth $pathText)
                if ($gitBudget -gt 0) {
                    $gitText = Limit-LeanPromptGitStatusWidth -Text $gitText -MaxWidth $gitBudget
                    $leftLine = $pathText + $gitText
                }
            }
        }
        $firstLine = Join-LeanPromptAlignedLine -Left $leftLine -Right $rightText -WindowWidth $windowWidth
        $symbolColor = if ($lastCommandSucceeded) { $palette.Success } else { $palette.Error }
        $symbols = Get-LeanPromptSymbols
        $global:LASTEXITCODE = $lastExitCode
        $promptText = "$firstLine`n$symbolColor$($symbols.PromptChar)$($palette.Reset) "
    }
    finally {
        if ($script:State.Prompt.__LeanPromptAsyncRedrawTimer) {
            $redrawState.Rendering = $false
            $redrawState.PromptCompletedUtc = [datetime]::UtcNow
            $redrawState.InputActive = $true
        }
    }
    $promptText
}
function Remove-LeanPromptGitCache {
    $cacheDir = $script:State.Prompt.__AsyncGitStatusCacheDir
    if (-not $cacheDir -or -not (Test-Path -LiteralPath $cacheDir)) { return }

    Get-ChildItem -LiteralPath $cacheDir -Force -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $cacheDir -Force -ErrorAction SilentlyContinue
}

function Disable-LeanPromptAsyncRedraw {
    $sourceId = $script:State.Prompt.__LeanPromptAsyncGitRedrawSourceId
    if ($sourceId) {
        Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object {
            $_.SourceIdentifier.StartsWith("$sourceId.", [System.StringComparison]::Ordinal)
        } | ForEach-Object {
            $actionJob = $_.Action
            Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue
            if ($actionJob) { Remove-Job -Job $actionJob -Force -ErrorAction SilentlyContinue }
        }
    }

    if ($script:State.Prompt.__LeanPromptAsyncGitExitSubscriptionId) {
        $exitSubscriber = Get-EventSubscriber -SubscriptionId $script:State.Prompt.__LeanPromptAsyncGitExitSubscriptionId -ErrorAction SilentlyContinue
        if ($exitSubscriber) {
            $actionJob = $exitSubscriber.Action
            Unregister-Event -SubscriptionId $exitSubscriber.SubscriptionId -ErrorAction SilentlyContinue
            if ($actionJob) { Remove-Job -Job $actionJob -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($script:State.Prompt.__LeanPromptAsyncGitExitJobId) {
        Get-Job -Id $script:State.Prompt.__LeanPromptAsyncGitExitJobId -ErrorAction SilentlyContinue |
            Remove-Job -Force -ErrorAction SilentlyContinue
    }

    if ($script:State.Prompt.__LeanPromptAsyncGitRedrawWatcher) {
        try { $script:State.Prompt.__LeanPromptAsyncGitRedrawWatcher.Dispose() } catch {}
        $script:State.Prompt.__LeanPromptAsyncGitRedrawWatcher = $null
    }
    if ($script:State.Prompt.__LeanPromptAsyncToolchainRedrawWatcher) {
        try { $script:State.Prompt.__LeanPromptAsyncToolchainRedrawWatcher.Dispose() } catch {}
        $script:State.Prompt.__LeanPromptAsyncToolchainRedrawWatcher = $null
    }
    if ($script:State.Prompt.__LeanPromptAsyncRedrawTimer) {
        try { $script:State.Prompt.__LeanPromptAsyncRedrawTimer.Dispose() } catch {}
        $script:State.Prompt.__LeanPromptAsyncRedrawTimer = $null
    }

    Stop-LeanPromptGitWorker
    Remove-LeanPromptGitCache
    $script:State.Prompt.__LeanPromptAsyncGitExitSubscriptionId = $null
    $script:State.Prompt.__LeanPromptAsyncGitExitJobId = $null
}

function Enable-LeanPromptAsyncRedraw {
    if (-not $script:State.Session.IsInteractive -or
        ($script:State.Prompt.__LeanPromptAsyncGitRedrawWatcher -and $script:State.Prompt.__LeanPromptAsyncToolchainRedrawWatcher -and
            $script:State.Prompt.__LeanPromptAsyncRedrawTimer)) { return }

    try { [Microsoft.PowerShell.PSConsoleReadLine] | Out-Null }
    catch { return }

    try {
        New-Item -ItemType Directory -Force -Path $script:State.Prompt.__AsyncGitStatusCacheDir -ErrorAction Stop | Out-Null
        New-Item -ItemType Directory -Force -Path $script:State.Prompt.__AsyncToolchainStatusCacheDir -ErrorAction Stop | Out-Null

        # ponytail: one short debounce timer is enough for the two cache watchers; split it only if redraw latency becomes visible.
        $timer = [System.Timers.Timer]::new(25)
        $timer.AutoReset = $false
        $script:State.Prompt.__LeanPromptAsyncRedrawTimer = $timer
        Register-ObjectEvent -InputObject $timer -EventName Elapsed `
            -SourceIdentifier "$($script:State.Prompt.__LeanPromptAsyncGitRedrawSourceId).Dispatch" `
            -MessageData ([pscustomobject]@{
                    State = $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState
                    Timer = $timer
                }) -Action {
                try {
                    $message = $Event.MessageData
                    $state = $message.State
                    if (-not $state.Pending) { return }
                    if ($state.Rendering) {
                        $message.Timer.Start()
                        return
                    }
                    if ($state.CompletionActive) { return }
                    if ($state.QueuedKeys -and $state.QueuedKeys.Count -gt 0) {
                        $message.Timer.Interval = 25
                        $message.Timer.Start()
                        return
                    }
                    if (-not $state.InputActive) {
                        $state.Pending = $false
                        return
                    }
                    $notBefore = ([datetime]$state.PromptCompletedUtc).AddMilliseconds(25)
                    if ($notBefore -gt [datetime]::UtcNow) {
                        $message.Timer.Interval = [Math]::Max(1, ($notBefore - [datetime]::UtcNow).TotalMilliseconds)
                        $message.Timer.Start()
                        return
                    }
                    $state.Pending = $false
                    $state.LastUtc = [datetime]::UtcNow
                    $state.Count = [long]$state.Count + 1
                    $state.CacheDriven = $true
                    try { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt() }
                    finally { $state.CacheDriven = $false }
                }
                catch {}
            } | Out-Null

        $redrawAction = {
            try {
                $message = $Event.MessageData
                $state = $message.State
                $changedPath = $Event.SourceEventArgs.FullPath
                $currentPath = [string]$state.CachePath
                if ([string]::IsNullOrWhiteSpace($currentPath) -or
                    -not $changedPath.Equals($currentPath, [System.StringComparison]::OrdinalIgnoreCase)) { return }

                $state.LastUtc = [datetime]::UtcNow
                $message.Dispatch.Pending = $true
                $message.Timer.Interval = 25
                $message.Timer.Stop()
                $message.Timer.Start()
            }
            catch {}
        }

        foreach ($watcherConfig in @(
                @{
                    CacheDir = $script:State.Prompt.__AsyncGitStatusCacheDir
                    State = $script:State.Prompt.__LeanPromptAsyncGitRedrawState
                    Source = "$($script:State.Prompt.__LeanPromptAsyncGitRedrawSourceId).Git.Renamed"
                    Variable = '__LeanPromptAsyncGitRedrawWatcher'
                }
                @{
                    CacheDir = $script:State.Prompt.__AsyncToolchainStatusCacheDir
                    State = $script:State.Prompt.__LeanPromptAsyncToolchainRedrawState
                    Source = "$($script:State.Prompt.__LeanPromptAsyncGitRedrawSourceId).Toolchain.Renamed"
                    Variable = '__LeanPromptAsyncToolchainRedrawWatcher'
                }
            )) {
            $watcher = [System.IO.FileSystemWatcher]::new($watcherConfig.CacheDir, '*.json')
            $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
            $script:State.Prompt[$watcherConfig.Variable] = $watcher
            Register-ObjectEvent -InputObject $watcher -EventName Renamed `
                -SourceIdentifier $watcherConfig.Source `
                -MessageData ([pscustomobject]@{
                        State = $watcherConfig.State
                        Dispatch = $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState
                        Timer = $timer
                    }) `
                -Action $redrawAction | Out-Null
            $watcher.EnableRaisingEvents = $true
        }
        $exitJob = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
            $module = Get-Module -Name PwshProfile | Select-Object -First 1
            if ($module) {
                & $module {
                    try { Stop-LeanPromptGitWorker }
                    finally { Remove-LeanPromptGitCache }
                }
            }
        }
        $exitSubscriber = Get-EventSubscriber -SourceIdentifier PowerShell.Exiting |
            Where-Object Action -EQ $exitJob |
            Select-Object -First 1
        $script:State.Prompt.__LeanPromptAsyncGitExitSubscriptionId = $exitSubscriber.SubscriptionId
        $script:State.Prompt.__LeanPromptAsyncGitExitJobId = $exitJob.Id
    }
    catch {
        Disable-LeanPromptAsyncRedraw
    }
}
# <<< async git status prompt <<<
