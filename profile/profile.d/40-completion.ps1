if ($script:__PwshProfileIsInteractive) {
# >>> zsh-style path completion >>>
if (-not (Test-Path function:\__PwshZshDefaultTabExpansion2)) {
    Copy-Item function:\TabExpansion2 function:\__PwshZshDefaultTabExpansion2
}

function Add-PwshZshDirectorySuffix {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $slashText = ConvertTo-LeanPromptSlashPath $Text
    if ($slashText.EndsWith('/')) { return $slashText }
    if (($slashText.StartsWith("'") -and $slashText.EndsWith("'")) -or
        ($slashText.StartsWith('"') -and $slashText.EndsWith('"'))) {
        if ($slashText.Length -ge 2 -and $slashText[$slashText.Length - 2] -eq '/') { return $slashText }
        return $slashText.Insert($slashText.Length - 1, '/')
    }
    $slashText + '/'
}

function Add-PwshZshFileSuffix {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    if ([char]::IsWhiteSpace($Text[$Text.Length - 1])) { return $Text }
    $Text + ' '
}

function Get-PwshCompletionLiteralPath {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    ($Text.Trim().Trim('''"').TrimEnd('/', '\')) -replace '/', '\'
}

function Test-PwshPathCompletionResult {
    param([System.Management.Automation.CompletionResult] $Match)
    if (-not $Match) { return $false }
    $path = Get-PwshCompletionLiteralPath $Match.CompletionText
    $item = if ($path) { Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    if ($item -and $item.PSProvider.Name -ne 'FileSystem') { return $false }
    if ($item) { return $true }
    if ($Match.ResultType -in @(
        [System.Management.Automation.CompletionResultType]::ProviderItem,
        [System.Management.Automation.CompletionResultType]::ProviderContainer
    )) { return $true }
    $false
}

function Test-PwshZshPathPrefix {
    param([string] $TypedWord, [string] $CandidateText)
    if ([string]::IsNullOrEmpty($TypedWord)) { return $true }

    $typed = $TypedWord.Trim('''"') -replace '\\', '/'
    $candidate = ($CandidateText.Trim().Trim('''"') -replace '\\', '/').TrimEnd('/')
    if (-not $typed.StartsWith('./') -and $candidate.StartsWith('./')) { $candidate = $candidate.Substring(2) }
    $typedParts = @($typed.Split([char]'/', [System.StringSplitOptions]::None))
    $candidateParts = @($candidate.Split([char]'/', [System.StringSplitOptions]::None))
    if ($candidateParts.Count -lt $typedParts.Count) { return $false }
    for ($i = 0; $i -lt $typedParts.Count; $i++) {
        $typedPart = $typedParts[$i]
        $candidatePart = $candidateParts[$i]
        if ($candidatePart.StartsWith('.') -and -not $typedPart.StartsWith('.')) { return $false }
        if (-not $candidatePart.StartsWith($typedPart, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $true
}

function Convert-CompletionDisplayToSlashPath {
    param(
        [System.Management.Automation.CommandCompletion] $Completion,
        [string] $InputScript,
        [int] $CursorColumn
    )
    if (-not $Completion -or $Completion.CompletionMatches.Count -eq 0) { return $Completion }
    if (-not $script:__PwshZshPathCompletionEnabled) { return $Completion }

    $typedWord = $null
    if ($InputScript -and $Completion.ReplacementIndex -ge 0 -and
        $Completion.ReplacementIndex -le $CursorColumn) {
        $typedLength = [Math]::Min($Completion.ReplacementLength, $CursorColumn - $Completion.ReplacementIndex)
        $typedWord = $InputScript.Substring($Completion.ReplacementIndex, $typedLength)
    }

    $matches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    foreach ($match in $Completion.CompletionMatches) {
        if (-not (Test-PwshPathCompletionResult $match)) { $matches.Add($match); continue }
        if ($typedWord -and -not (Test-PwshZshPathPrefix $typedWord $match.CompletionText)) { continue }

        $literalPath = Get-PwshCompletionLiteralPath $match.CompletionText
        $isContainer = $match.ResultType -eq [System.Management.Automation.CompletionResultType]::ProviderContainer -or
            ($literalPath -and (Test-Path -LiteralPath $literalPath -PathType Container -ErrorAction SilentlyContinue))
        $resultType = if ($isContainer) {
            [System.Management.Automation.CompletionResultType]::ProviderContainer
        } else { [System.Management.Automation.CompletionResultType]::ProviderItem }
        $completionText = ConvertTo-LeanPromptSlashPath $match.CompletionText
        if ($typedWord -and -not (($typedWord.Trim('''"') -replace '\\', '/').StartsWith('./'))) {
            if ($completionText.StartsWith('./')) {
                $completionText = $completionText.Substring(2)
            } elseif (($completionText.StartsWith("'./") -and $completionText.EndsWith("'")) -or
                ($completionText.StartsWith('"./') -and $completionText.EndsWith('"'))) {
                $completionText = $completionText.Remove(1, 2)
            }
        }
        $completionText = if ($isContainer) {
            Add-PwshZshDirectorySuffix $completionText
        } else { Add-PwshZshFileSuffix $completionText }
        $listItemText = ConvertTo-LeanPromptSlashPath $match.ListItemText
        if ($isContainer) { $listItemText = Add-PwshZshDirectorySuffix $listItemText }
        $toolTip = ConvertTo-LeanPromptSlashPath $match.ToolTip

        $matches.Add([System.Management.Automation.CompletionResult]::new(
            $completionText,
            $listItemText,
            $resultType,
            $toolTip
        ))
    }

    [System.Management.Automation.CommandCompletion]::new(
        $matches,
        $Completion.CurrentMatchIndex,
        $Completion.ReplacementIndex,
        $Completion.ReplacementLength
    )
}

function New-PwshPathCompletionResult {
    param(
        [Parameter(Mandatory)][System.IO.FileSystemInfo] $Item,
        [Parameter(Mandatory)][string] $CandidateText,   # anchor-preserving path without trailing separator
        [string] $ListItemText                            # defaults to the item name
    )

    $candidate = ConvertTo-LeanPromptSlashPath $CandidateText
    $listItemDisplay = if ($ListItemText) { $ListItemText } else { $Item.Name }
    $completionText = if ($candidate -match '[\s''"`$]') {
        "'" + ($candidate -replace "'", "''") + "'"
    } else { $candidate }
    $listItemDisplay = ConvertTo-LeanPromptSlashPath $listItemDisplay
    if ($Item.PSIsContainer) {
        $completionText = Add-PwshZshDirectorySuffix $completionText
        $listItemDisplay = Add-PwshZshDirectorySuffix $listItemDisplay
    } else { $completionText = Add-PwshZshFileSuffix $completionText }
    $resultType = if ($Item.PSIsContainer) { 'ProviderContainer' } else { 'ProviderItem' }

    [System.Management.Automation.CompletionResult]::new(
        $completionText,
        $listItemDisplay,
        $resultType,
        (ConvertTo-LeanPromptSlashPath $Item.FullName)
    )
}

# Ctrl+C must win during Tab completion the way SIGINT does on Unix.
# On Windows, PSReadLine clears ENABLE_PROCESSED_INPUT while ReadLine runs, so Ctrl+C is queued as
# a normal key (not CTRL_C_EVENT). Do NOT re-enable ENABLE_PROCESSED_INPUT here: that would steal
# Ctrl+C from PSReadLine's MenuComplete loop and leave the user stuck in the Tab menu.
# Instead, detect pending console input (Ctrl+C / Esc / typing) via KeyAvailable and abort
# cooperative stages; interruptible native commands poll the same flag and Kill on break.
$script:__PwshCompletionInterruptState = [hashtable]::Synchronized(@{ CtrlC = $false })
$script:__PwshCompletionInterruptDepth = 0

if (-not ('PwshProfile.ConsoleInput' -as [type])) {
    Add-Type -Namespace PwshProfile -Name ConsoleInput -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr CreateFile(
    string fileName, uint desiredAccess, uint shareMode, System.IntPtr securityAttributes,
    uint creationDisposition, uint flagsAndAttributes, System.IntPtr templateFile);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(System.IntPtr handle);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetNumberOfConsoleInputEvents(System.IntPtr hConsoleInput, out uint lpcNumberOfEvents);

[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool PeekConsoleInput(
    System.IntPtr hConsoleInput, [Out] INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsRead);

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct COORD { public short X; public short Y; }

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit)]
public struct INPUT_RECORD {
    [System.Runtime.InteropServices.FieldOffset(0)] public ushort EventType;
    [System.Runtime.InteropServices.FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
}

[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit)]
public struct KEY_EVENT_RECORD {
    [System.Runtime.InteropServices.FieldOffset(0)] public int bKeyDown;
    [System.Runtime.InteropServices.FieldOffset(4)] public ushort wRepeatCount;
    [System.Runtime.InteropServices.FieldOffset(6)] public ushort wVirtualKeyCode;
    [System.Runtime.InteropServices.FieldOffset(8)] public ushort wVirtualScanCode;
    [System.Runtime.InteropServices.FieldOffset(10)] public ushort UnicodeChar;
    [System.Runtime.InteropServices.FieldOffset(12)] public uint dwControlKeyState;
}

public const uint GENERIC_READ = 0x80000000;
public const uint GENERIC_WRITE = 0x40000000;
public const uint FILE_SHARE_READ = 0x00000001;
public const uint FILE_SHARE_WRITE = 0x00000002;
public const uint OPEN_EXISTING = 3;
public const ushort KEY_EVENT = 0x0001;
public const uint LEFT_CTRL_PRESSED = 0x0008;
public const uint RIGHT_CTRL_PRESSED = 0x0004;
public const int VK_C = 0x43;
'@
}

function Test-PwshCompletionCtrlCPending {
    # Peek the real console input buffer for Ctrl+C without consuming it, so MenuComplete can
    # still see the key after we bail out of TabExpansion2.
    try {
        $handle = [PwshProfile.ConsoleInput]::CreateFile(
            'CONIN$',
            [PwshProfile.ConsoleInput]::GENERIC_READ -bor [PwshProfile.ConsoleInput]::GENERIC_WRITE,
            [PwshProfile.ConsoleInput]::FILE_SHARE_READ -bor [PwshProfile.ConsoleInput]::FILE_SHARE_WRITE,
            [System.IntPtr]::Zero,
            [PwshProfile.ConsoleInput]::OPEN_EXISTING,
            0,
            [System.IntPtr]::Zero
        )
        if ($handle -eq [System.IntPtr]::Zero -or $handle -eq [System.IntPtr]::new(-1)) { return $false }
        try {
            $eventCount = [uint32]0
            if (-not [PwshProfile.ConsoleInput]::GetNumberOfConsoleInputEvents($handle, [ref]$eventCount)) { return $false }
            if ($eventCount -eq 0) { return $false }
            $readCount = [Math]::Min([int]$eventCount, 64)
            $records = [PwshProfile.ConsoleInput+INPUT_RECORD[]]::new($readCount)
            $got = [uint32]0
            if (-not [PwshProfile.ConsoleInput]::PeekConsoleInput($handle, $records, [uint32]$readCount, [ref]$got)) { return $false }
            for ($i = 0; $i -lt $got; $i++) {
                $record = $records[$i]
                if ($record.EventType -ne [PwshProfile.ConsoleInput]::KEY_EVENT) { continue }
                $key = $record.KeyEvent
                if ($key.bKeyDown -eq 0) { continue }
                $ctrl = ($key.dwControlKeyState -band (
                    [PwshProfile.ConsoleInput]::LEFT_CTRL_PRESSED -bor
                    [PwshProfile.ConsoleInput]::RIGHT_CTRL_PRESSED)) -ne 0
                if ($ctrl -and ($key.wVirtualKeyCode -eq [PwshProfile.ConsoleInput]::VK_C -or $key.UnicodeChar -eq 3)) {
                    return $true
                }
            }
            $false
        }
        finally {
            [void][PwshProfile.ConsoleInput]::CloseHandle($handle)
        }
    }
    catch { $false }
}

function Test-PwshCompletionInterrupted {
    if ($script:__PwshCompletionInterruptState.CtrlC) { return $true }
    if (Test-PwshCompletionCtrlCPending) {
        $script:__PwshCompletionInterruptState.CtrlC = $true
        return $true
    }
    # Any other pending key also means the user wants out of a slow completer; leave the key queued.
    try { [Console]::KeyAvailable } catch { $false }
}

function Enter-PwshCompletionInterruptScope {
    $script:__PwshCompletionInterruptDepth++
    if ($script:__PwshCompletionInterruptDepth -gt 1) { return }
    $script:__PwshCompletionInterruptState.CtrlC = $false
}

function Exit-PwshCompletionInterruptScope {
    if ($script:__PwshCompletionInterruptDepth -le 0) { return }
    $script:__PwshCompletionInterruptDepth--
}

# Run a console tool so Ctrl+C / pending input can abort it: poll the interrupt flag while waiting,
# and Kill the process tree if the user breaks. Redirected ProcessStartInfo is used so stdout is
# captured without depending on PowerShell's native-command wait (which cannot poll).
function Invoke-PwshInterruptibleNativeCommand {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $ArgumentList = @()
    )

    if (Test-PwshCompletionInterrupted) { return @() }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($argument in $ArgumentList) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    # Process.Start inherits Environment.CurrentDirectory, which often diverges from PowerShell's
    # Set-Location. Native & calls use the provider location; match that so git -C-less probes work.
    try {
        $location = Get-Location
        if ($location.Provider.Name -eq 'FileSystem' -and $location.ProviderPath) {
            $psi.WorkingDirectory = $location.ProviderPath
        }
    }
    catch {}

    $process = [System.Diagnostics.Process]::Start($psi)
    if (-not $process) { return @() }
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.HasExited) {
            if (Test-PwshCompletionInterrupted) {
                try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
                return @()
            }
            Start-Sleep -Milliseconds 20
        }
        $null = $stdoutTask.Wait(1000)
        $null = $stderrTask.Wait(1000)
        if (Test-PwshCompletionInterrupted) { return @() }
        if ($process.ExitCode -ne 0) { return @() }
        @($stdoutTask.Result -split '\r?\n' | Where-Object { $_ })
    }
    finally {
        if (-not $process.HasExited) {
            try { $process.Kill($true) } catch { try { $process.Kill() } catch {} }
        }
        $process.Dispose()
    }
}

# A word is in command position when it starts a CommandAst (zsh completes command names there).
function Test-PwshCommandPositionWord {
    param(
        [string] $InputScript,
        [int] $WordStart
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($InputScript, [ref]$tokens, [ref]$parseErrors)
    foreach ($commandAst in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $firstElement = $commandAst.CommandElements[0]
        if ($firstElement -and $firstElement.Extent.StartOffset -eq $WordStart) { return $true }
    }
    $false
}

function Get-PwshZshPathCompletion {
    param(
        [string] $Word,
        [int] $ReplacementIndex,
        [int] $ReplacementLength,
        [switch] $DirectoriesOnly
    )

    if ($Word -match '^(\\\\|//)') { return $null }              # UNC paths stay with the native completer.
    if ($Word -match '^[A-Za-z][A-Za-z0-9]+:') { return $null }     # Non-drive PSProviders stay native.

    $segments = $Word -split '[\\/]'
    $segmentIndex = 0
    $typedPrefix = ''
    $baseDir = $null
    if ($segments[0] -eq '~') {
        $baseDir = [Environment]::GetFolderPath('UserProfile')
        $typedPrefix = '~/'
        $segmentIndex = 1
    }
    elseif ($segments[0] -match '^[A-Za-z]:$') {
        $baseDir = $segments[0] + [System.IO.Path]::DirectorySeparatorChar
        $typedPrefix = $segments[0] + '/'
        $segmentIndex = 1
    }
    elseif ($segments[0] -eq '') {
        $baseDir = [System.IO.Path]::GetPathRoot((Get-Location).Path)
        $typedPrefix = '/'
        $segmentIndex = 1
    }
    else {
        if ((Get-Location).Provider.Name -ne 'FileSystem') { return $null }
        $baseDir = (Get-Location).Path
    }
    while ($segmentIndex -lt $segments.Count - 1 -and $segments[$segmentIndex] -in '.', '..') {
        $baseDir = Join-Path $baseDir $segments[$segmentIndex]
        $typedPrefix += $segments[$segmentIndex] + '/'
        $segmentIndex++
    }
    if (-not $baseDir -or -not (Test-Path -LiteralPath $baseDir -PathType Container)) { return $null }

    $lastIndex = $segments.Count - 1
    for ($i = $segmentIndex; $i -lt $lastIndex; $i++) {
        if (Test-PwshCompletionInterrupted) { return $null }
        $segment = $segments[$i]
        if ([string]::IsNullOrEmpty($segment)) { return $null }
        if ($segment -in '.', '..') {
            $baseDir = Join-Path $baseDir $segment
            $typedPrefix += $segment + '/'
            continue
        }
        $matched = @(Get-ChildItem -LiteralPath $baseDir -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object {
                (-not $_.Name.StartsWith('.') -or $segment.StartsWith('.')) -and
                $_.Name.StartsWith($segment, [System.StringComparison]::OrdinalIgnoreCase)
            } | Sort-Object Name)
        $exact = @($matched | Where-Object { $_.Name.Equals($segment, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($exact.Count -eq 1) { $matched = $exact }
        if ($matched.Count -ne 1) {
            if ($matched.Count -eq 0) { return $null }
            $completionMatches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
            foreach ($directory in $matched) {
                $completionMatches.Add((New-PwshPathCompletionResult -Item $directory `
                    -CandidateText ($typedPrefix + $directory.Name) -ListItemText ($typedPrefix + $directory.Name)))
            }
            return [System.Management.Automation.CommandCompletion]::new(
                $completionMatches, -1, $ReplacementIndex, $ReplacementLength
            )
        }
        $baseDir = $matched[0].FullName
        $typedPrefix += $matched[0].Name + '/'
    }

    $leaf = $segments[$lastIndex]
    $completionMatches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    $children = Get-ChildItem -LiteralPath $baseDir -Force -ErrorAction SilentlyContinue |
        Where-Object {
            (-not $DirectoriesOnly -or $_.PSIsContainer) -and
            (-not $_.Name.StartsWith('.') -or $leaf.StartsWith('.')) -and
            $_.Name.StartsWith($leaf, [System.StringComparison]::OrdinalIgnoreCase)
        } | Sort-Object -Property @{ Expression = 'PSIsContainer'; Descending = $true }, Name
    foreach ($item in $children) {
        $candidate = $typedPrefix + $item.Name
        $completionMatches.Add((New-PwshPathCompletionResult -Item $item -CandidateText $candidate -ListItemText $candidate))
        if ($completionMatches.Count -ge 100) { break }
    }
    if ($completionMatches.Count -eq 0) { return $null }

    [System.Management.Automation.CommandCompletion]::new(
        $completionMatches,
        -1,
        $ReplacementIndex,
        $ReplacementLength
    )
}
function TabExpansion2 {
    param(
        [string] $inputScript,
        [int] $cursorColumn,
        [hashtable] $options
    )

    if (-not $script:__PwshZshPathCompletionEnabled) {
        return __PwshZshDefaultTabExpansion2 @PSBoundParameters
    }

    # Honor a break that arrived before this Tab press (or a test-injected flag) before the
    # interrupt scope clears/re-arms Ctrl+C handling for the new attempt.
    if (Test-PwshCompletionInterrupted) {
        return [System.Management.Automation.CommandCompletion]::new(
            [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new(),
            -1,
            $cursorColumn,
            0
        )
    }

    Enter-PwshCompletionInterruptScope
    try {
        if (Test-PwshCompletionInterrupted) {
            return [System.Management.Automation.CommandCompletion]::new(
                [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new(),
                -1,
                $cursorColumn,
                0
            )
        }

        $defaultRaw = $null
        try { $defaultRaw = __PwshZshDefaultTabExpansion2 @PSBoundParameters } catch { $defaultRaw = $null }
        if (Test-PwshCompletionInterrupted) {
            return [System.Management.Automation.CommandCompletion]::new(
                [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new(),
                -1,
                $cursorColumn,
                0
            )
        }
        if (-not $defaultRaw) {
            $defaultRaw = [System.Management.Automation.CommandCompletion]::new(
                [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new(),
                -1,
                $cursorColumn,
                0
            )
        }
        $default = Convert-CompletionDisplayToSlashPath -Completion $defaultRaw `
            -InputScript $inputScript -CursorColumn $cursorColumn
        if ($default.CompletionMatches.Count -gt 0) { return $default }

        $lineBeforeCursor = $inputScript.Substring(0, $cursorColumn)
        if ($lineBeforeCursor -notmatch '([^\s''"]+)$') { return $default }
        $word = $Matches[1]
        if ([string]::IsNullOrWhiteSpace($word) -or $word -match '[`''"\[\]*?$(){};,|&<>]') { return $default }
        $wordStart = $cursorColumn - $word.Length
        if ($word.StartsWith('-') -or $word.StartsWith('@') -or
            (Test-PwshCommandPositionWord -InputScript $inputScript -WordStart $wordStart)) { return $default }

        $directoriesOnly = $lineBeforeCursor.Substring(0, $wordStart) -match
            '(?i)(?:^|[;|]\s*)(?:cd|chdir|sl|Set-Location|pushd)\s+$'
        $pathCompletion = Get-PwshZshPathCompletion -Word $word.Trim('''"') `
            -ReplacementIndex $wordStart -ReplacementLength $word.Length -DirectoriesOnly:$directoriesOnly
        if ($pathCompletion) { return $pathCompletion }
        $default
    }
    finally {
        Exit-PwshCompletionInterruptScope
    }
}
# <<< zsh-style path completion <<<

# ---- Carapace: Tab completion for git/npm/docker/gh and ~1000 external commands ----
# (Similar to bash/zsh command completion on Linux; works with Tab=MenuComplete above.)
if (Get-Command carapace -CommandType Application -ErrorAction SilentlyContinue) {
    $env:CARAPACE_BRIDGES = 'zsh,fish,bash,inshellisense'   # Fall back to other shells when a command is missing
    $__profileCacheDir = Join-Path $env:LOCALAPPDATA 'PowerShell\ProfileCache'
    $__carapaceCache = Join-Path $__profileCacheDir 'carapace.ps1'
    $__carapaceRefresh = Join-Path $__profileCacheDir 'Update-CarapaceCache.ps1'
    $__carapaceRefreshScript = @'
    param([Parameter(Mandatory)][string] $CachePath)
    $ErrorActionPreference = 'Stop'
    $env:CARAPACE_BRIDGES = 'zsh,fish,bash,inshellisense'
    $cacheDir = Split-Path -Parent $CachePath
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $script = carapace _carapace powershell | Out-String
    $old = '$_.ListItemText.replace(''`e['', "`e[")'
    $old = $old -replace '\"','"'
    $script = $script.Replace($old, '(' + $old + ' -replace "\x1b\[[0-9;]*m","")')
    $tmp = "$CachePath.tmp"
    Set-Content -LiteralPath $tmp -Value $script -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $CachePath -Force
'@

    New-Item -ItemType Directory -Force -Path $__profileCacheDir | Out-Null
    if ((-not (Test-Path -LiteralPath $__carapaceRefresh)) -or ((Get-Content -LiteralPath $__carapaceRefresh -Raw -ErrorAction SilentlyContinue) -ne $__carapaceRefreshScript)) {
        Set-Content -LiteralPath $__carapaceRefresh -Value $__carapaceRefreshScript -Encoding UTF8
    }

    if (-not (Test-Path -LiteralPath $__carapaceCache)) {
        & $__carapaceRefresh -CachePath $__carapaceCache
    }

    if (Test-Path -LiteralPath $__carapaceCache) {
        . $__carapaceCache

        $__carapaceCacheItem = Get-Item -LiteralPath $__carapaceCache
        $__carapaceCommand = Get-Command carapace -CommandType Application -ErrorAction SilentlyContinue
        $__carapaceStale = $__carapaceCacheItem.LastWriteTime -lt (Get-Date).AddDays(-7)
        if ($__carapaceCommand -and $__carapaceCommand.Source -and (Test-Path -LiteralPath $__carapaceCommand.Source)) {
            $__carapaceStale = $__carapaceStale -or ((Get-Item -LiteralPath $__carapaceCommand.Source).LastWriteTime -gt $__carapaceCacheItem.LastWriteTime)
        }

        if ($__carapaceStale) {
            $__pwsh = Join-Path $PSHOME 'pwsh.exe'
            if (Test-Path -LiteralPath $__pwsh) {
                Start-ProfileBackgroundPowerShell -ScriptPath $__carapaceRefresh -Arguments @('-CachePath', $__carapaceCache) | Out-Null
            }
        }
    }

    Remove-Variable __profileCacheDir, __carapaceCache, __carapaceRefresh, __carapaceRefreshScript, __carapaceCacheItem, __carapaceCommand, __carapaceStale, __pwsh -ErrorAction SilentlyContinue

    # ---- git path completion: status-aware, stepwise directory completion by subcommand (like native Linux git completion) ----
    # Problem: carapace cannot descend directories step by step on Windows (known bug), and each subcommand should get different candidates.
    # Approach: copy git-completion-style filters, pick git file lists by subcommand, then expand step by step from the typed prefix:
    #       add/stage -> modified + untracked working tree files (exclude fully staged files); rm/mv -> tracked files; clean -> untracked files;
    #       commit -> staged files; restore -> modified working tree files (or staged files with --staged/-S).
    #       Directory candidates are marked ProviderContainer so the shared path layer adds `/`.
    # Leave checkout/reset/diff alone (they mainly complete refs/branches); hand all other subcommands/flags to carapace.
    if (Get-Variable -Name _carapace_completer -ErrorAction SilentlyContinue) {
        $__carapaceNative = $_carapace_completer
        $__gitPathSubcmds = @('add', 'stage', 'restore', 'rm', 'mv', 'clean', 'commit')
        Register-ArgumentCompleter -Native -CommandName 'git', 'git.exe' -ScriptBlock {
            param($wordToComplete, $commandAst, $cursorPosition)
            $elems = @($commandAst.CommandElements | ForEach-Object { $_.Extent.Text })
            $sub = $elems | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^-' } | Select-Object -First 1
            if (($sub -in $__gitPathSubcmds) -and ($wordToComplete -notmatch '^-')) {
                if (Test-PwshCompletionInterrupted) { return }
                $gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
                if (-not $gitCommand) { return }
                $gitExe = $gitCommand.Source
                $root = Invoke-PwshInterruptibleNativeCommand -FilePath $gitExe -ArgumentList @('rev-parse', '--show-toplevel') |
                    Select-Object -First 1
                if (Test-PwshCompletionInterrupted) { return }
                if ($root) {
                    # $root (from rev-parse, forward slashes) is used for git -C across the whole repo; $rootBS (backslashes) is used for path math.
                    $rootBS = $root -replace '/', '\'
                    # Note: do not use $PWD -- GetNewClosure() would freeze it to the directory where the profile loaded;
                    # use Get-Location so cd changes are reflected.
                    $cwd = (Get-Location).Path
                    $hasStaged = ($elems -contains '--staged') -or ($elems -ccontains '-S') -or ($elems -contains '--cached')
                    if (Test-PwshCompletionInterrupted) { return }
                    # Cache the file list briefly so quickly repeated Tabs do not rescan a large repository.
                    $completionCacheKey = "$root|$sub|$hasStaged"
                    $completionCache = $script:__GitPathCompletionFileCache
                    if ($completionCache -and $completionCache.Key -eq $completionCacheKey -and
                        ([datetime]::UtcNow - $completionCache.StampUtc).TotalSeconds -lt 2.5) {
                        $src = $completionCache.Files
                    }
                    else {
                        # Pick the file list by subcommand (all output is repo-root-relative); ls-files defaults to cwd, so use git -C <root> to see the whole repo.
                        $gitBase = @('-C', $root, '-c', 'core.quotepath=false')
                        $src = @(switch ($sub) {
                            { $_ -in 'add', 'stage' } {
                                # Working-tree column (porcelain second char) is non-space = unstaged changes or untracked files remain; exclude fully staged files.
                                Invoke-PwshInterruptibleNativeCommand -FilePath $gitExe -ArgumentList ($gitBase + @('status', '--porcelain', '--untracked-files=all')) | ForEach-Object {
                                    if ($_.Length -lt 4 -or $_[1] -eq ' ') { return }
                                    $p = $_.Substring(3)
                                    if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }   # For renames, use the new name
                                    $p.Trim('"')
                                }
                                break
                            }
                            'commit' {
                                Invoke-PwshInterruptibleNativeCommand -FilePath $gitExe -ArgumentList ($gitBase + @('diff', '--cached', '--name-only'))
                                break
                            }
                            'clean' {
                                Invoke-PwshInterruptibleNativeCommand -FilePath $gitExe -ArgumentList ($gitBase + @('ls-files', '--others', '--exclude-standard', '--full-name'))
                                break
                            }
                            { $_ -in 'rm', 'mv' } {
                                Invoke-PwshInterruptibleNativeCommand -FilePath $gitExe -ArgumentList ($gitBase + @('ls-files', '--full-name'))
                                break
                            }
                            'restore' {
                                if ($hasStaged) {
                                    Invoke-PwshInterruptibleNativeCommand -FilePath $gitExe -ArgumentList ($gitBase + @('diff', '--cached', '--name-only'))
                                }
                                else {
                                    Invoke-PwshInterruptibleNativeCommand -FilePath $gitExe -ArgumentList ($gitBase + @('ls-files', '--modified', '--full-name'))
                                }
                                break
                            }
                        })
                        if (Test-PwshCompletionInterrupted) { return }
                        $script:__GitPathCompletionFileCache = @{
                            Key = $completionCacheKey
                            StampUtc = [datetime]::UtcNow
                            Files = $src
                        }
                    }
                    $dirty = $src | Where-Object { $_ } | ForEach-Object {
                        [System.IO.Path]::GetRelativePath($cwd, (Join-Path $rootBS ($_ -replace '/', '\')))
                    }
                    $word = ($wordToComplete -replace '/', '\').Trim("'`"")
                    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($f0 in $dirty) {
                        if (Test-PwshCompletionInterrupted) { return }
                        $f = $f0 -replace '/', '\'
                        if (-not $f.StartsWith($word, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                        $rest = $f.Substring($word.Length)
                        $i = $rest.IndexOf('\')
                        if ($i -ge 0) {
                            $cand = $f.Substring(0, $word.Length + $i + 1)          # Directory, with trailing \
                            $type = [System.Management.Automation.CompletionResultType]::ProviderContainer
                        }
                        else {
                            $cand = $f                                             # File
                            $type = [System.Management.Automation.CompletionResultType]::ProviderItem
                        }
                        if ($seen.Add($cand)) {
                            $text = if ($cand -match '\s') { "'$cand'" } else { $cand }
                            [System.Management.Automation.CompletionResult]::new($text, $cand, $type, $cand)
                        }
                    }
                    return
                }
            }
            & $__carapaceNative $wordToComplete $commandAst $cursorPosition
        }.GetNewClosure()
    }
}
}
