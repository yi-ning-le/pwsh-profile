if ($script:State.Session.IsInteractive) {
# ---- PSReadLine: history autosuggestions + syntax highlighting + key bindings (like zsh plugins) ----
Import-Module PSReadLine
$script:State.Completion.ZshPathCompletionEnabled = & {
    try {
        $type = [Microsoft.PowerShell.PSConsoleReadLine]
        $script:State.Completion.ReadLineSingletonField = $type.GetField(
            '_singleton', [System.Reflection.BindingFlags]'NonPublic, Static'
        )
        $script:State.Completion.DirectorySeparatorField = $type.GetField(
            '_directorySeparator', [System.Reflection.BindingFlags]'NonPublic, Instance'
        )
        $script:State.Completion.QueuedKeysField = $type.GetField(
            '_queuedKeys', [System.Reflection.BindingFlags]'NonPublic, Instance'
        )
        if (-not $script:State.Completion.ReadLineSingletonField -or -not $script:State.Completion.DirectorySeparatorField -or
            -not $script:State.Completion.QueuedKeysField) {
            throw 'Required PSReadLine fields were not found.'
        }
        $script:State.Completion.ReadLineSingleton = $script:State.Completion.ReadLineSingletonField.GetValue($null)
        if (-not $script:State.Completion.ReadLineSingleton) { throw 'PSReadLine singleton was not found.' }
        $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.QueuedKeys =
            $script:State.Completion.QueuedKeysField.GetValue($script:State.Completion.ReadLineSingleton)
        $separator = $script:State.Completion.DirectorySeparatorField.GetValue($script:State.Completion.ReadLineSingleton)
        try { $script:State.Completion.DirectorySeparatorField.SetValue($script:State.Completion.ReadLineSingleton, '/') }
        finally { $script:State.Completion.DirectorySeparatorField.SetValue($script:State.Completion.ReadLineSingleton, $separator) }
        $true
    }
    catch {
        if (-not $script:State.Completion.ZshPathCompletionWarningShown) {
            $script:State.Completion.ZshPathCompletionWarningShown = $true
            Write-Warning "Zsh-style slash path completion is unavailable; using native PSReadLine completion. $($_.Exception.Message)" `
                -WarningAction Continue
        }
        $false
    }
}
Set-PSReadLineOption -HistoryNoDuplicates
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineOption -EditMode Emacs                      # Emacs keybindings (change to Vi for vi mode)
Set-PSReadLineOption -BellStyle None
Set-PSReadLineOption -ExtraPromptLineCount 1
$script:State.Completion.CompletionActionState = $null
function Get-PwshCtrlCAction {
    param(
        [bool] $CompletionActive = ($null -ne $script:State.Completion.CompletionActionState),
        [bool] $CompletionInterrupted = [bool]($script:State.Completion.CompletionInterruptState -and $script:State.Completion.CompletionInterruptState.CtrlC)
    )

    if ($CompletionActive) { return 'Abort' }
    if ($CompletionInterrupted) { return 'Consume' }
    'CancelLine'
}
$script:State.Completion.CtrlCHandler = {
    param($key, $arg)

    $action = Get-PwshCtrlCAction
    if ($action -eq 'Consume') {
        # TabExpansion2 already stopped and restored the buffer; only consume its queued Ctrl+C.
        $script:State.Completion.CompletionInterruptState.CtrlC = $false
        return
    }
    if ($action -eq 'Abort') {
        $script:State.Completion.CompletionInterruptState.CtrlC = $true
        $script:State.Completion.CompletionActionState.CtrlCHandled = $true
        [Microsoft.PowerShell.PSConsoleReadLine]::Abort($key, $arg)
        return
    }

    $script:State.Prompt.__LeanPromptStatusOverride = $false
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.InputActive = $false
    [Microsoft.PowerShell.PSConsoleReadLine]::CancelLine($key, $arg)
}
Set-PSReadLineKeyHandler -Key Ctrl+c `
    -BriefDescription PwshCompletionAwareCtrlC `
    -Description 'Abort completion without clearing its input; cancel the line otherwise.' `
    -ScriptBlock $script:State.Completion.CtrlCHandler

# History autosuggestions: keep inline gray suggestions (InlineView), disable noisy multi-line dropdowns (ListView).
# Press RightArrow / End to accept gray suggestions; Ctrl+R searches history; UpArrow searches by current prefix.
if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
    Set-PSReadLineOption -PredictionViewStyle InlineView
}

# Up/Down arrows: search history by current prefix (zsh history-substring-search feel)
Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key Ctrl+w    -Function BackwardKillWord
# Tab opens the interactive candidate menu immediately.
# Shift+Tab opens the menu directly (and moves backward once a menu is open).
function Get-PwshBufferState {
    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    [pscustomobject]@{ Line = $line; Cursor = $cursor }
}
function Restore-PwshCompletionBuffer {
    param([Parameter(Mandatory)] $Before)

    $current = Get-PwshBufferState
    $line = [string]$Before.Line
    [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $current.Line.Length, $line, $null, $null)
    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition([Math]::Min([int]$Before.Cursor, $line.Length))
}
function Test-PwshQueuedCtrlC {
    try {
        $queue = $script:State.Completion.QueuedKeysField.GetValue($script:State.Completion.ReadLineSingleton)
        if (-not $queue -or $queue.Count -eq 0) { return $false }
        $key = $queue.Peek().AsConsoleKeyInfo()
        $key.KeyChar -ceq [char]3 -or
            ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control))
    }
    catch { $false }
}
function Set-PwshAutoSlashState {
    param($Before, $After)

    $script:State.Completion.AutoSlashState = $null
    if ($After.Line -cne $Before.Line -and $After.Cursor -gt 0 -and
        $After.Line[$After.Cursor - 1] -ceq '/') {
        $script:State.Completion.AutoSlashState = $After
    }
}
function Remove-PwshAutoSlash {
    $state = Get-PwshBufferState
    if (-not $script:State.Completion.AutoSlashState -or $state.Cursor -ne $script:State.Completion.AutoSlashState.Cursor -or
        $state.Line -cne $script:State.Completion.AutoSlashState.Line -or $state.Cursor -le 0 -or
        $state.Line[$state.Cursor - 1] -cne '/') {
        $script:State.Completion.AutoSlashState = $null
        return
    }
    [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar($null, $null)
    $script:State.Completion.AutoSlashState = $null
}
function Invoke-PwshWithDirectorySeparator {
    param([Parameter(Mandatory)][scriptblock] $ScriptBlock)

    if (-not $script:State.Completion.ZshPathCompletionEnabled) { return & $ScriptBlock }
    $previousSeparator = $script:State.Completion.DirectorySeparatorField.GetValue($script:State.Completion.ReadLineSingleton)
    try {
        $script:State.Completion.DirectorySeparatorField.SetValue($script:State.Completion.ReadLineSingleton, '/')
        & $ScriptBlock
    }
    finally {
        $script:State.Completion.DirectorySeparatorField.SetValue($script:State.Completion.ReadLineSingleton, $previousSeparator)
    }
}
function Invoke-PwshCompletionAction {
    param(
        $Key,
        $Arg
    )

    $before = Get-PwshBufferState
    $previousActionState = $script:State.Completion.CompletionActionState
    $actionState = [pscustomobject]@{ Before = $before; CtrlCHandled = $false }
    $script:State.Completion.CompletionActionState = $actionState
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.CompletionActive = $true
    $previousTreatControlCAsInput = [Console]::TreatControlCAsInput
    $interrupted = $false
    try {
        # Keep Ctrl+C in PSReadLine's input stream for the whole completion transaction. If it
        # becomes a console control event during completion, PowerShell cancels the entire line.
        [Console]::TreatControlCAsInput = $true
        Invoke-PwshWithDirectorySeparator {
            [Microsoft.PowerShell.PSConsoleReadLine]::MenuComplete($Key, $Arg)
        }
        # MenuComplete handles Ctrl+C as an ordinary chord and prepends it for the outer input
        # loop. Mark it before leaving this transaction so the snapshot is restored first.
        if (Test-PwshQueuedCtrlC) {
            $script:State.Completion.CompletionInterruptState.CtrlC = $true
        }
    }
    finally {
        [Console]::TreatControlCAsInput = $previousTreatControlCAsInput
        $interrupted = [bool]($script:State.Completion.CompletionInterruptState -and $script:State.Completion.CompletionInterruptState.CtrlC)
        if ($interrupted) {
            try { Restore-PwshCompletionBuffer -Before $before } catch {}
            $script:State.Completion.AutoSlashState = $null
        }
        $script:State.Completion.CompletionActionState = $previousActionState
        $redrawState = $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState
        $redrawState.CompletionActive = $null -ne $previousActionState
        if (-not $redrawState.CompletionActive -and $redrawState.Pending -and
            $script:State.Prompt.__LeanPromptAsyncRedrawTimer) {
            $script:State.Prompt.__LeanPromptAsyncRedrawTimer.Interval = 25
            $script:State.Prompt.__LeanPromptAsyncRedrawTimer.Start()
        }
        if ($actionState.CtrlCHandled -and $script:State.Completion.CompletionInterruptState) {
            $script:State.Completion.CompletionInterruptState.CtrlC = $false
        }
    }
    if ($interrupted) {
        $script:State.Prompt.__LeanPromptStatusOverride = $false
        try { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt() } catch {}
    }
    else {
        Set-PwshAutoSlashState -Before $before -After (Get-PwshBufferState)
    }
    -not $interrupted
}
if ($script:State.Completion.ZshPathCompletionEnabled) {
Set-PSReadLineKeyHandler -Key Tab `
    -BriefDescription ZshMenuComplete `
    -Description 'Open menu completion immediately.' `
    -ScriptBlock {
        param($key, $arg)

        $null = Invoke-PwshCompletionAction -Key $key -Arg $arg
    }
Set-PSReadLineKeyHandler -Key Shift+Tab `
    -BriefDescription ZshMenuCompleteBackward `
    -Description 'Open menu completion; move backward when the menu is already open.' `
    -ScriptBlock {
        param($key, $arg)
        $null = Invoke-PwshCompletionAction -Key $key -Arg $arg
    }

# Zsh AUTO_REMOVE_SLASH: a separator added by directory completion is replaceable. A slash
# typed normally is still just SelfInsert and never starts completion.
$script:State.Completion.AutoSlashSelfInsert = {
    param($key, $arg)
    Remove-PwshAutoSlash
    [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg)
}
Set-PSReadLineKeyHandler -Key '/', '\', Spacebar, ';', '&', '|' `
    -BriefDescription ZshAutoRemoveSlash `
    -Description 'Insert the key, removing an automatically completed directory slash first.' `
    -ScriptBlock $script:State.Completion.AutoSlashSelfInsert

function Test-LeanPromptGitBranchRefreshCommand {
    param([Parameter(Mandatory)][System.Management.Automation.Language.CommandAst] $CommandAst)

    $commandName = $CommandAst.GetCommandName()
    if ($commandName -in 'gco', 'gcb') { return $true }

    $arguments = @($CommandAst.CommandElements | Select-Object -Skip 1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            [string]$_.Value
        }
        elseif ($_ -is [System.Management.Automation.Language.CommandParameterAst]) {
            "-$($_.ParameterName)"
        }
    })
    if ($commandName -eq 'gb') {
        return [bool]($arguments | Where-Object { $_ -in '-m', '-M', '--move' } | Select-Object -First 1)
    }
    if ($commandName -notin 'git', 'git.exe', 'g') { return $false }

    $subcommandIndex = 0
    while ($subcommandIndex -lt $arguments.Count -and $arguments[$subcommandIndex] -in '-C', '-c') {
        $subcommandIndex += 2
    }
    if ($subcommandIndex -ge $arguments.Count) { return $false }

    $subcommand = $arguments[$subcommandIndex]
    if ($subcommand -in 'switch', 'checkout') { return $true }
    if ($subcommand -ne 'branch' -or $subcommandIndex + 1 -ge $arguments.Count) { return $false }
    [bool]($arguments[($subcommandIndex + 1)..($arguments.Count - 1)] |
        Where-Object { $_ -in '-m', '-M', '--move' } | Select-Object -First 1)
}

function Update-LeanPromptAcceptedLineState {
    param([AllowEmptyString()][string] $Line)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$errors)
    if ($errors | Where-Object IncompleteInput | Select-Object -First 1) { return $false }
    $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
    if ($commands.Count -eq 0) { return $true }

    $script:State.Prompt.__LeanPromptCommandStartUtc = [datetime]::UtcNow
    foreach ($commandAst in $commands) {
        if (Test-LeanPromptGitBranchRefreshCommand -CommandAst $commandAst) {
            $script:State.Prompt.__LeanPromptGitBranchRefreshPending = $true
            break
        }
    }
    $true
}

$script:State.Completion.AcceptLine = {
    param($key, $arg)
    $script:State.Prompt.__LeanPromptStatusOverride = $null
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.InputActive = $false
    Remove-PwshAutoSlash
    try {
        $buffer = Get-PwshBufferState
        $null = Update-LeanPromptAcceptedLineState -Line $buffer.Line
    }
    catch {}
    finally {
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine($key, $arg)
    }
}
Set-PSReadLineKeyHandler -Key Enter `
    -BriefDescription ZshAcceptLine `
    -Description 'Accept the line after removing an automatically completed directory slash.' `
    -ScriptBlock $script:State.Completion.AcceptLine
$script:State.Prompt.__LeanPromptDurationEnabled = $true
}
# RightArrow / End: accept the full inline suggestion at end of line; Ctrl+RightArrow accepts one word (zsh feel)
Set-PSReadLineKeyHandler -Key RightArrow      -Function ForwardChar
Set-PSReadLineKeyHandler -Key Ctrl+RightArrow -Function AcceptNextSuggestionWord

# Inline suggestion color (like zsh-autosuggestions gray) + Tab menu selected-item highlight color
# Selection uses ANSI escape sequences for a true background highlight (48;2=background, 38;2=foreground);
# Plain '#xxxxxx' only changes text color. One Half Dark palette: dark text (#282c34) over bright blue (#61afef).
Set-PSReadLineOption -Colors @{
    InlinePrediction = '#5c6370'                              # Gray history suggestion
    Selection        = "`e[38;2;40;44;52;48;2;97;175;239m"    # Tab menu selection: blue background with dark text
}
}
