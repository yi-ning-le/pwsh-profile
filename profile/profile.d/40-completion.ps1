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

function Resolve-PwshCompletionPathCase {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][hashtable] $DirectoryMaps,
        [string] $TypedWord
    )

    $path = Get-PwshCompletionLiteralPath $Text
    if (-not $path -or $path -match '^(\\\\|//)' -or (Get-Location).Provider.Name -ne 'FileSystem') { return $null }
    $slashPath = $path -replace '\\', '/'
    $prefix = ''
    $baseDir = (Get-Location).ProviderPath
    if ($slashPath -match '^~/(.*)$') {
        $baseDir = [Environment]::GetFolderPath('UserProfile'); $prefix = '~/'; $slashPath = $Matches[1]
    }
    elseif ($slashPath -match '^([A-Za-z]:)/?(.*)$') {
        $baseDir = $Matches[1] + [System.IO.Path]::DirectorySeparatorChar
        $prefix = $Matches[1] + '/'; $slashPath = $Matches[2]
    }
    elseif ($slashPath.StartsWith('/')) {
        $baseDir = [System.IO.Path]::GetPathRoot($baseDir); $prefix = '/'; $slashPath = $slashPath.TrimStart('/')
    }
    elseif ($slashPath.StartsWith('./')) {
        if (($TypedWord -replace '\\', '/').StartsWith('./')) { $prefix = './' }
        $slashPath = $slashPath.Substring(2)
    }

    $actualParts = [System.Collections.Generic.List[string]]::new()
    $item = $null
    foreach ($segment in @($slashPath.Split([char]'/', [System.StringSplitOptions]::RemoveEmptyEntries))) {
        if ($segment -in '.', '..') {
            $actualParts.Add($segment)
            try { $baseDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($baseDir, $segment)) }
            catch { return $null }
            continue
        }
        $mapKey = $baseDir.TrimEnd('\', '/')
        if (-not $DirectoryMaps.ContainsKey($mapKey)) {
            $map = [System.Collections.Generic.Dictionary[string, System.IO.FileSystemInfo]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            try {
                foreach ($child in [System.IO.DirectoryInfo]::new($baseDir).EnumerateFileSystemInfos()) {
                    if (-not $map.ContainsKey($child.Name)) { $map.Add($child.Name, $child) }
                }
            }
            catch { return $null }
            $DirectoryMaps[$mapKey] = $map
        }
        $map = $DirectoryMaps[$mapKey]
        if (-not $map.TryGetValue($segment, [ref]$item)) { return $null }
        $actualParts.Add($item.Name)
        $baseDir = $item.FullName
    }
    if (-not $item) { return $null }
    $candidate = $prefix + ($actualParts -join '/')
    [pscustomobject]@{
        Item = $item
        Candidate = $candidate
        ListItem = if ($actualParts.Count -gt 1) { $candidate } else { $item.Name }
    }
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

    $convertedMatches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    $directoryMaps = @{}
    foreach ($match in $Completion.CompletionMatches) {
        if (-not (Test-PwshPathCompletionResult $match)) { $convertedMatches.Add($match); continue }
        $canonical = Resolve-PwshCompletionPathCase -Text $match.CompletionText -DirectoryMaps $directoryMaps -TypedWord $typedWord
        if ($canonical) {
            $convertedMatches.Add((New-PwshPathCompletionResult -Item $canonical.Item `
                -CandidateText $canonical.Candidate -ListItemText $canonical.ListItem))
            continue
        }

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

        $convertedMatches.Add([System.Management.Automation.CompletionResult]::new(
            $completionText,
            $listItemText,
            $resultType,
            $toolTip
        ))
    }

    [System.Management.Automation.CommandCompletion]::new(
        $convertedMatches,
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
    $isContainer = $Item -is [System.IO.DirectoryInfo]
    if ($isContainer) {
        $completionText = Add-PwshZshDirectorySuffix $completionText
        $listItemDisplay = Add-PwshZshDirectorySuffix $listItemDisplay
    } else { $completionText = Add-PwshZshFileSuffix $completionText }
    $resultType = if ($isContainer) { 'ProviderContainer' } else { 'ProviderItem' }

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

function Initialize-PwshCompletionConsoleInput {
    if ('PwshProfile.ConsoleInput' -as [type]) { return $true }
    try {
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
        $true
    }
    catch { $false }
}

function Test-PwshCompletionCtrlCPending {
    # Peek the real console input buffer for Ctrl+C without consuming it, so MenuComplete can
    # still see the key after we bail out of TabExpansion2.
    if (-not (Initialize-PwshCompletionConsoleInput)) { return $false }
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
    # Check availability first so Ctrl+C cannot arrive between the Ctrl+C peek and this check
    # and be mistaken for an unrelated key.
    $inputPending = try { [Console]::KeyAvailable } catch { $false }
    if (-not $inputPending) { return $false }
    if (Test-PwshCompletionCtrlCPending) {
        $script:__PwshCompletionInterruptState.CtrlC = $true
    }
    # Any other pending key also means the user wants out of a slow completer; leave the key queued.
    $true
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
                try { $null = $process.WaitForExit(1000) } catch {}
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

function Test-PwshCommandPositionWord {
    param([string] $InputScript, [int] $WordStart)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($InputScript, [ref]$tokens, [ref]$errors)
    foreach ($commandAst in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if ($commandAst.CommandElements[0].Extent.StartOffset -eq $WordStart) { return $true }
    }
    $false
}

# PowerShell's parameter metadata is sufficient for most path parameters, but it cannot express
# that these two parameters accept containers only. Aliases are resolved before this table is read.
$script:__PwshFileSystemParameterCapabilities = @{
    'Microsoft.PowerShell.Management\Set-Location:Path' = 'Container'
    'Microsoft.PowerShell.Management\Set-Location:LiteralPath' = 'Container'
    'Microsoft.PowerShell.Management\Push-Location:Path' = 'Container'
    'Microsoft.PowerShell.Management\Push-Location:LiteralPath' = 'Container'
}

function Get-PwshFileSystemCompletionContext {
    param(
        [string] $InputScript,
        [int] $CursorColumn
    )

    $lineBeforeCursor = $InputScript.Substring(0, $CursorColumn)
    $wordMatch = [regex]::Match($lineBeforeCursor, '([^\s]*)$')
    $word = $wordMatch.Groups[1].Value
    $wordStart = $wordMatch.Groups[1].Index
    $defaultContext = [pscustomobject]@{
        Backend = 'Default'; ItemKind = 'Any'; ReplacementIndex = $wordStart
        ReplacementLength = $word.Length; TypedWord = $word
        ResolvedCommand = $null; ParameterName = $null
    }

    # Quoting and expressions need PowerShell's binder. The filesystem engine intentionally handles
    # only literal local paths so it cannot change wildcard or provider semantics.
    if ($word -match '[`''"\[\]*?$(){};,|&<>]' -or $word -match '^(\\\\|//)' -or
        ($word -match '^[A-Za-z][A-Za-z0-9]+:' -and $word -notmatch '^[A-Za-z]:')) {
        return $defaultContext
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($InputScript, [ref]$tokens, [ref]$parseErrors)
    $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
        Where-Object { $_.Extent.StartOffset -le $wordStart } | Sort-Object { $_.Extent.StartOffset })
    if ($commands.Count -eq 0) { return $defaultContext }
    $commandAst = $commands[-1]
    if ($commandAst.Extent.EndOffset -lt $wordStart) {
        $gap = $InputScript.Substring($commandAst.Extent.EndOffset, $wordStart - $commandAst.Extent.EndOffset)
        if ($gap -notmatch '^\s+$') { return $defaultContext }
    }

    $firstElement = $commandAst.CommandElements[0]
    if (-not $firstElement -or $firstElement.Extent.StartOffset -eq $wordStart) { return $defaultContext }
    $commandName = $commandAst.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($commandName)) { return $defaultContext }

    $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
    while ($command -is [System.Management.Automation.AliasInfo]) {
        $command = Get-Command $command.Definition -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    $defaultContext.ResolvedCommand = $command
    if (-not $command) { return $defaultContext }

    $isExplicitLocalPath = $word -match '^(?:\.\.?[\\/]|~[\\/]|[A-Za-z]:|[\\/](?![\\/]))'
    if ($command.CommandType -in @(
        [System.Management.Automation.CommandTypes]::Application,
        [System.Management.Automation.CommandTypes]::ExternalScript
    )) {
        if (-not $isExplicitLocalPath) { return $defaultContext }
        $defaultContext.Backend = 'FileSystem'
        return $defaultContext
    }

    if (-not $command.Parameters) { return $defaultContext }
    if (-not $isExplicitLocalPath -and (Get-Location).Provider.Name -ne 'FileSystem') { return $defaultContext }
    $elements = @($commandAst.CommandElements | Select-Object -Skip 1)
    $pendingParameter = $null
    $parameterName = $null
    $position = 0
    $usedPositions = [System.Collections.Generic.HashSet[int]]::new()
    $resolveParameter = {
        param([string] $Name)
        $parameter = $command.Parameters[$Name]
        if ($parameter) { return $parameter }
        $possible = @($command.Parameters.Values | Where-Object {
            $_.Name.StartsWith($Name, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($possible.Count -eq 1) { $possible[0] }
    }
    foreach ($element in $elements) {
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            if ($element.Extent.StartOffset -eq $wordStart) { return $defaultContext }
            $pendingParameter = $element.ParameterName
            if ($element.Argument -and $element.Argument.Extent.StartOffset -le $wordStart -and
                $element.Argument.Extent.EndOffset -ge $wordStart) {
                $parameterName = $pendingParameter
                break
            }
            continue
        }
        if ($element.Extent.StartOffset -gt $wordStart) { break }
        if ($element.Extent.StartOffset -eq $wordStart) {
            if ($pendingParameter) { $parameterName = $pendingParameter }
            break
        }
        if ($pendingParameter) {
            $boundParameter = & $resolveParameter $pendingParameter
            if ($boundParameter) {
                $boundPositionFound = $false
                foreach ($attribute in $boundParameter.Attributes) {
                    if ($attribute -is [System.Management.Automation.ParameterAttribute] -and $attribute.Position -ge 0) {
                        [void]$usedPositions.Add($attribute.Position)
                        $boundPositionFound = $true
                    }
                }
                if (-not $boundPositionFound -and $boundParameter.Name -in 'Path', 'LiteralPath', 'Source', 'SourcePath') {
                    [void]$usedPositions.Add(0)
                }
                elseif (-not $boundPositionFound -and $boundParameter.Name -in 'Destination', 'DestinationPath') {
                    [void]$usedPositions.Add(1)
                }
            }
            $pendingParameter = $null
        }
        else {
            while ($usedPositions.Contains($position)) { $position++ }
            [void]$usedPositions.Add($position)
            $position++
        }
    }
    if (-not $parameterName -and $word.Length -eq 0 -and $pendingParameter) {
        $parameterName = $pendingParameter
    }
    while ($usedPositions.Contains($position)) { $position++ }

    if ($parameterName) {
        $exactParameter = & $resolveParameter $parameterName
        if (-not $exactParameter) { return $defaultContext }
        $parameterName = $exactParameter.Name
    }
    else {
        $positionalNames = @($command.Parameters.Values | Where-Object {
            @($_.Attributes | Where-Object {
                $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Position -eq $position
            }).Count -gt 0
        } | Select-Object -ExpandProperty Name -Unique)
        if ($positionalNames.Count -ne 1) { return $defaultContext }
        $parameterName = $positionalNames[0]
    }

    if ($parameterName -notin @('Path', 'LiteralPath', 'Destination', 'DestinationPath', 'Source', 'SourcePath')) {
        return $defaultContext
    }
    $defaultContext.ParameterName = $parameterName
    $defaultContext.Backend = 'FileSystem'
    $capabilityKey = '{0}\{1}:{2}' -f $command.ModuleName, $command.Name, $parameterName
    if ($script:__PwshFileSystemParameterCapabilities[$capabilityKey] -eq 'Container') {
        $defaultContext.ItemKind = 'Container'
    }
    $defaultContext
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

    $emptyCompletion = [System.Management.Automation.CommandCompletion]::new(
        [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new(),
        -1,
        $ReplacementIndex,
        $ReplacementLength
    )
    if (Test-PwshCompletionInterrupted) { return $emptyCompletion }

    # Local filesystem enumeration is lazy so pending input can stop a large directory without
    # waiting for Get-ChildItem and Sort-Object to materialize the entire provider result first.
    $enumerateFileSystemItems = {
        param([string] $Path, [bool] $DirectoriesOnly)

        if (Test-PwshCompletionInterrupted) { return }
        try {
            $directory = [System.IO.DirectoryInfo]::new($Path)
            $items = if ($DirectoriesOnly) {
                $directory.EnumerateDirectories()
            }
            else {
                $directory.EnumerateFileSystemInfos()
            }
            $index = 0
            foreach ($item in $items) {
                if (($index++ -band 31) -eq 0 -and (Test-PwshCompletionInterrupted)) { return }
                $item
            }
        }
        catch [System.UnauthorizedAccessException] {}
        catch [System.IO.DirectoryNotFoundException] {}
        catch [System.IO.IOException] {}
        catch [System.Security.SecurityException] {}
    }

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
    elseif ($Word.Length -gt 0 -and $segments[0] -eq '') {
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
    if (-not $baseDir -or -not [System.IO.Directory]::Exists($baseDir)) { return $emptyCompletion }

    $hiddenAttributes = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    $lastIndex = $segments.Count - 1
    $resolvedIntermediateSegment = $false
    for ($i = $segmentIndex; $i -lt $lastIndex; $i++) {
        $resolvedIntermediateSegment = $true
        if (Test-PwshCompletionInterrupted) { return $emptyCompletion }
        $segment = $segments[$i]
        if ([string]::IsNullOrEmpty($segment)) { return $emptyCompletion }
        if ($segment -in '.', '..') {
            $baseDir = Join-Path $baseDir $segment
            $typedPrefix += $segment + '/'
            continue
        }
        if (Test-PwshCompletionInterrupted) { return $emptyCompletion }
        $matched = @(& $enumerateFileSystemItems $baseDir $true |
            Where-Object {
                (-not ($_.Attributes -band $hiddenAttributes) -or
                    ($segment.StartsWith('.') -and $_.Name.StartsWith('.'))) -and
                (-not $_.Name.StartsWith('.') -or $segment.StartsWith('.')) -and
                $_.Name.StartsWith($segment, [System.StringComparison]::OrdinalIgnoreCase)
            } | Sort-Object Name)
        if (Test-PwshCompletionInterrupted) { return $emptyCompletion }
        $exact = @($matched | Where-Object { $_.Name.Equals($segment, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($exact.Count -eq 1) { $matched = $exact }
        if ($matched.Count -ne 1) {
            if ($matched.Count -eq 0) { return $emptyCompletion }
            $completionMatches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
            foreach ($directory in $matched) {
                if (Test-PwshCompletionInterrupted) { return $emptyCompletion }
                $completionMatches.Add((New-PwshPathCompletionResult -Item $directory `
                    -CandidateText ($typedPrefix + $directory.Name) -ListItemText ($typedPrefix + $directory.Name)))
                if ($completionMatches.Count -ge 100) { break }
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
    if (Test-PwshCompletionInterrupted) { return $emptyCompletion }
    $children = @(& $enumerateFileSystemItems $baseDir ([bool]$DirectoriesOnly) |
        Where-Object {
            (-not ($_.Attributes -band $hiddenAttributes) -or
                ($leaf.StartsWith('.') -and $_.Name.StartsWith('.'))) -and
            (-not $_.Name.StartsWith('.') -or $leaf.StartsWith('.')) -and
            $_.Name.StartsWith($leaf, [System.StringComparison]::OrdinalIgnoreCase)
        } | Sort-Object -Property @{ Expression = { $_ -is [System.IO.DirectoryInfo] }; Descending = $true }, Name)
    if (Test-PwshCompletionInterrupted) { return $emptyCompletion }
    foreach ($item in $children) {
        if (Test-PwshCompletionInterrupted) { return $emptyCompletion }
        $candidate = $typedPrefix + $item.Name
        $listItemText = if ($resolvedIntermediateSegment) { $candidate } else { $item.Name }
        $completionMatches.Add((New-PwshPathCompletionResult -Item $item `
            -CandidateText $candidate -ListItemText $listItemText))
        if ($completionMatches.Count -ge 100) { break }
    }

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

        $context = Get-PwshFileSystemCompletionContext -InputScript $inputScript -CursorColumn $cursorColumn
        if ($context.Backend -eq 'FileSystem') {
            $pathCompletion = Get-PwshZshPathCompletion -Word $context.TypedWord `
                -ReplacementIndex $context.ReplacementIndex `
                -ReplacementLength $context.ReplacementLength `
                -DirectoriesOnly:($context.ItemKind -eq 'Container')
            if ($pathCompletion) { return $pathCompletion }
        }

        Initialize-PwshCarapaceCompletion
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
        $default
    }
    finally {
        Exit-PwshCompletionInterruptScope
    }
}
# <<< zsh-style path completion <<<

# ---- Carapace: Tab completion for git/npm/docker/gh and ~1000 external commands ----
# Load once on the first Tab so command completion remains rich without delaying the first prompt.
$script:__PwshCarapaceInitializationState = 'NotStarted'
$script:__PwshCarapaceInitializationWarningShown = $false
function Initialize-PwshCarapaceCompletion {
    param([switch] $Prewarm)

    if ($script:__PwshCarapaceInitializationState -in 'Ready', 'Unavailable' -or
        $script:__PwshCarapaceInitializationState -eq 'Initializing') { return }

    $script:__PwshCarapaceInitializationState = 'Initializing'
    try {
        $__carapaceCommand = Get-Command carapace -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $__carapaceCommand) {
            throw 'Carapace executable was not found.'
        }

        $env:CARAPACE_BRIDGES = 'zsh,fish,bash,inshellisense'   # Fall back to other shells when a command is missing
        $__profileCacheDir = Join-Path $env:LOCALAPPDATA 'PowerShell\ProfileCache'
        $__carapaceCache = Join-Path $__profileCacheDir 'carapace.ps1'
        $__carapaceRefresh = Join-Path $__profileCacheDir 'Update-CarapaceCache.ps1'
        $__carapaceRefreshScript = @'
    param(
        [Parameter(Mandatory)][string] $CachePath,
        [Parameter(Mandatory)][string] $CarapacePath
    )
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $env:CARAPACE_BRIDGES = 'zsh,fish,bash,inshellisense'
    $cacheDir = Split-Path -Parent $CachePath
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $tmp = "$CachePath.tmp"
    try {
        $script = & $CarapacePath _carapace powershell | Out-String
        if ($global:LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($script)) {
            throw "carapace cache generation failed (exit $global:LASTEXITCODE)"
        }
        $old = '$_.ListItemText.replace(''`e['', "`e[")'
        $old = $old -replace '\"','"'
        $script = $script.Replace($old, '(' + $old + ' -replace "\x1b\[[0-9;]*m","")')
        Set-Content -LiteralPath $tmp -Value $script -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $CachePath -Force
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
'@

        New-Item -ItemType Directory -Force -Path $__profileCacheDir | Out-Null
        if ((-not (Test-Path -LiteralPath $__carapaceRefresh)) -or ((Get-Content -LiteralPath $__carapaceRefresh -Raw -ErrorAction SilentlyContinue) -ne $__carapaceRefreshScript)) {
            Set-Content -LiteralPath $__carapaceRefresh -Value $__carapaceRefreshScript -Encoding UTF8
        }

        if (-not (Test-Path -LiteralPath $__carapaceCache)) {
            $__pwsh = Join-Path $PSHOME 'pwsh.exe'
            if (-not (Test-Path -LiteralPath $__pwsh)) { throw 'pwsh executable was not found for Carapace cache generation.' }
            Invoke-PwshInterruptibleNativeCommand -FilePath $__pwsh -ArgumentList @(
                '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $__carapaceRefresh,
                '-CachePath', $__carapaceCache, '-CarapacePath', $__carapaceCommand.Source
            ) | Out-Null
            if (Test-PwshCompletionInterrupted) {
                Remove-Item -LiteralPath "$__carapaceCache.tmp" -Force -ErrorAction SilentlyContinue
                $script:__PwshCarapaceInitializationState = 'NotStarted'
                return
            }
            if (-not (Test-Path -LiteralPath $__carapaceCache)) { throw 'Carapace cache was not generated.' }
        }

        if (Test-Path -LiteralPath $__carapaceCache) {
            . $__carapaceCache

            $__carapaceCacheItem = Get-Item -LiteralPath $__carapaceCache
            $__carapaceStale = $__carapaceCacheItem.LastWriteTime -lt (Get-Date).AddDays(-7)
            if ($__carapaceCommand -and $__carapaceCommand.Source -and (Test-Path -LiteralPath $__carapaceCommand.Source)) {
                $__carapaceStale = $__carapaceStale -or ((Get-Item -LiteralPath $__carapaceCommand.Source).LastWriteTime -gt $__carapaceCacheItem.LastWriteTime)
            }

            if ($__carapaceStale) {
                $__pwsh = Join-Path $PSHOME 'pwsh.exe'
                if (Test-Path -LiteralPath $__pwsh) {
                    Start-ProfileBackgroundPowerShell -ScriptPath $__carapaceRefresh -Arguments @(
                        '-CachePath', $__carapaceCache,
                        '-CarapacePath', $__carapaceCommand.Source
                    ) | Out-Null
                }
            }
        }

        # ---- git path completion: status-aware, stepwise directory completion by subcommand (like native Linux git completion) ----
        # Problem: carapace cannot descend directories step by step on Windows (known bug), and each subcommand should get different candidates.
        # Approach: copy git-completion-style filters, pick git file lists by subcommand, then expand step by step from the typed prefix:
        #       add/stage -> modified + untracked working tree files (exclude fully staged files); rm/mv -> tracked files; clean -> untracked files;
        #       commit -> staged files; restore -> modified working tree files (or staged files with --staged/-S).
        #       Directory candidates are marked ProviderContainer so the shared path layer adds `/`.
        # Leave checkout/reset/diff alone (they mainly complete refs/branches); hand all other subcommands/flags to carapace.
        $__carapaceCompleter = Get-Variable -Name _carapace_completer -ErrorAction SilentlyContinue
        if (-not $__carapaceCompleter -or $__carapaceCompleter.Value -isnot [scriptblock]) {
            throw 'Carapace cache did not define its PowerShell completer.'
        }
        $__carapaceNative = $__carapaceCompleter.Value
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
        $script:__PwshCarapaceInitializationState = 'Ready'
    }
    catch {
        Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'PowerShell\ProfileCache\carapace.ps1.tmp') -Force -ErrorAction SilentlyContinue
        if ($Prewarm -or (Test-PwshCompletionInterrupted)) {
            $script:__PwshCarapaceInitializationState = 'NotStarted'
            return
        }
        $script:__PwshCarapaceInitializationState = 'Unavailable'
        if (-not $script:__PwshCarapaceInitializationWarningShown) {
            $script:__PwshCarapaceInitializationWarningShown = $true
            Write-Warning "Carapace completion initialization failed; using native completion. $($_.Exception.Message)"
        }
    }
}

function Start-PwshCompletionPrewarm {
    if ($script:__PwshCarapaceInitializationState -ne 'NotStarted') { return }

    try {
        if (-not (Initialize-PwshCompletionConsoleInput)) { return }
        Initialize-PwshCarapaceCompletion -Prewarm
    }
    finally {
        # OnIdle is outside a completion action; leave queued Ctrl+C for the normal CancelLine handler.
        if ($null -eq $script:__PwshCompletionActionState -and $script:__PwshCompletionInterruptState) {
            $script:__PwshCompletionInterruptState.CtrlC = $false
        }
    }
}

$script:__PwshCompletionPrewarmSourceId = 'PowerShell.OnIdle'
$__pwshCompletionPrewarmSubscriber = if ($script:__PwshCompletionPrewarmSubscriptionId) {
    Get-EventSubscriber -SubscriptionId $script:__PwshCompletionPrewarmSubscriptionId -ErrorAction SilentlyContinue
}
if (-not $__pwshCompletionPrewarmSubscriber) {
    if ($script:__PwshCompletionPrewarmJobId) {
        Get-Job -Id $script:__PwshCompletionPrewarmJobId -ErrorAction SilentlyContinue |
            Where-Object State -NE Running |
            Remove-Job -Force -ErrorAction SilentlyContinue
    }
    $__pwshCompletionPrewarmJob = Register-EngineEvent -SourceIdentifier $script:__PwshCompletionPrewarmSourceId -MaxTriggerCount 1 -Action {
        try { Start-PwshCompletionPrewarm }
        finally { $EventSubscriber.Action | Remove-Job -Force -ErrorAction SilentlyContinue }
    }
    $__pwshCompletionPrewarmSubscriber = Get-EventSubscriber -SourceIdentifier $script:__PwshCompletionPrewarmSourceId |
        Where-Object Action -EQ $__pwshCompletionPrewarmJob |
        Select-Object -First 1
    $script:__PwshCompletionPrewarmSubscriptionId = $__pwshCompletionPrewarmSubscriber.SubscriptionId
    $script:__PwshCompletionPrewarmJobId = $__pwshCompletionPrewarmJob.Id
}
Remove-Variable __pwshCompletionPrewarmSubscriber, __pwshCompletionPrewarmJob -ErrorAction SilentlyContinue
}
