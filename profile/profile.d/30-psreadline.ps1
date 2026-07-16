if ($script:__PwshProfileIsInteractive) {
# ---- PSReadLine: history autosuggestions + syntax highlighting + key bindings (like zsh plugins) ----
Import-Module PSReadLine
$script:__PwshZshPathCompletionEnabled = & {
    try {
        $type = [Microsoft.PowerShell.PSConsoleReadLine]
        $script:__PwshReadLineSingletonField = $type.GetField(
            '_singleton', [System.Reflection.BindingFlags]'NonPublic, Static'
        )
        $script:__PwshDirectorySeparatorField = $type.GetField(
            '_directorySeparator', [System.Reflection.BindingFlags]'NonPublic, Instance'
        )
        $script:__PwshQueuedKeysField = $type.GetField(
            '_queuedKeys', [System.Reflection.BindingFlags]'NonPublic, Instance'
        )
        if (-not $script:__PwshReadLineSingletonField -or -not $script:__PwshDirectorySeparatorField -or
            -not $script:__PwshQueuedKeysField) {
            throw 'Required PSReadLine fields were not found.'
        }
        $script:__PwshReadLineSingleton = $script:__PwshReadLineSingletonField.GetValue($null)
        if (-not $script:__PwshReadLineSingleton) { throw 'PSReadLine singleton was not found.' }
        $separator = $script:__PwshDirectorySeparatorField.GetValue($script:__PwshReadLineSingleton)
        try { $script:__PwshDirectorySeparatorField.SetValue($script:__PwshReadLineSingleton, '/') }
        finally { $script:__PwshDirectorySeparatorField.SetValue($script:__PwshReadLineSingleton, $separator) }
        $true
    }
    catch {
        if (-not $script:__PwshZshPathCompletionWarningShown) {
            $script:__PwshZshPathCompletionWarningShown = $true
            Write-Warning "Zsh-style slash path completion is unavailable; using native PSReadLine completion. $($_.Exception.Message)" `
                -WarningAction Continue
        }
        $false
    }
}
Enable-LeanPromptAsyncRedraw
Set-PSReadLineOption -HistoryNoDuplicates
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineOption -EditMode Emacs                      # Emacs keybindings (change to Vi for vi mode)
Set-PSReadLineOption -BellStyle None
$script:__PwshCompletionActionState = $null
function Get-PwshCtrlCAction {
    param(
        [bool] $CompletionActive = ($null -ne $script:__PwshCompletionActionState),
        [bool] $CompletionInterrupted = [bool]($script:__PwshCompletionInterruptState -and $script:__PwshCompletionInterruptState.CtrlC)
    )

    if ($CompletionActive) { return 'Abort' }
    if ($CompletionInterrupted) { return 'Consume' }
    'CancelLine'
}
$script:__PwshCtrlCHandler = {
    param($key, $arg)

    $action = Get-PwshCtrlCAction
    if ($action -eq 'Consume') {
        # TabExpansion2 already stopped and restored the buffer; only consume its queued Ctrl+C.
        $script:__PwshCompletionInterruptState.CtrlC = $false
        return
    }
    if ($action -eq 'Abort') {
        $script:__PwshCompletionInterruptState.CtrlC = $true
        $script:__PwshCompletionActionState.CtrlCHandled = $true
        [Microsoft.PowerShell.PSConsoleReadLine]::Abort($key, $arg)
        return
    }

    $script:__LeanPromptStatusOverride = $false
    [Microsoft.PowerShell.PSConsoleReadLine]::CancelLine($key, $arg)
}
Set-PSReadLineKeyHandler -Key Ctrl+c `
    -BriefDescription PwshCompletionAwareCtrlC `
    -Description 'Abort completion without clearing its input; cancel the line otherwise.' `
    -ScriptBlock $script:__PwshCtrlCHandler

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
        $queue = $script:__PwshQueuedKeysField.GetValue($script:__PwshReadLineSingleton)
        if (-not $queue -or $queue.Count -eq 0) { return $false }
        $key = $queue.Peek().AsConsoleKeyInfo()
        $key.KeyChar -ceq [char]3 -or
            ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control))
    }
    catch { $false }
}
function Set-PwshAutoSlashState {
    param($Before, $After)

    $script:__PwshAutoSlashState = $null
    if ($After.Line -cne $Before.Line -and $After.Cursor -gt 0 -and
        $After.Line[$After.Cursor - 1] -ceq '/') {
        $script:__PwshAutoSlashState = $After
    }
}
function Remove-PwshAutoSlash {
    $state = Get-PwshBufferState
    if (-not $script:__PwshAutoSlashState -or $state.Cursor -ne $script:__PwshAutoSlashState.Cursor -or
        $state.Line -cne $script:__PwshAutoSlashState.Line -or $state.Cursor -le 0 -or
        $state.Line[$state.Cursor - 1] -cne '/') {
        $script:__PwshAutoSlashState = $null
        return
    }
    [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar($null, $null)
    $script:__PwshAutoSlashState = $null
}
function Invoke-PwshWithDirectorySeparator {
    param([Parameter(Mandatory)][scriptblock] $ScriptBlock)

    if (-not $script:__PwshZshPathCompletionEnabled) { return & $ScriptBlock }
    $previousSeparator = $script:__PwshDirectorySeparatorField.GetValue($script:__PwshReadLineSingleton)
    try {
        $script:__PwshDirectorySeparatorField.SetValue($script:__PwshReadLineSingleton, '/')
        & $ScriptBlock
    }
    finally {
        $script:__PwshDirectorySeparatorField.SetValue($script:__PwshReadLineSingleton, $previousSeparator)
    }
}
function Invoke-PwshCompletionAction {
    param(
        $Key,
        $Arg
    )

    $before = Get-PwshBufferState
    $previousActionState = $script:__PwshCompletionActionState
    $actionState = [pscustomobject]@{ Before = $before; CtrlCHandled = $false }
    $script:__PwshCompletionActionState = $actionState
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
            $script:__PwshCompletionInterruptState.CtrlC = $true
        }
    }
    finally {
        [Console]::TreatControlCAsInput = $previousTreatControlCAsInput
        $interrupted = [bool]($script:__PwshCompletionInterruptState -and $script:__PwshCompletionInterruptState.CtrlC)
        if ($interrupted) {
            try { Restore-PwshCompletionBuffer -Before $before } catch {}
            $script:__PwshAutoSlashState = $null
        }
        $script:__PwshCompletionActionState = $previousActionState
        if ($actionState.CtrlCHandled -and $script:__PwshCompletionInterruptState) {
            $script:__PwshCompletionInterruptState.CtrlC = $false
        }
    }
    if ($interrupted) {
        $script:__LeanPromptStatusOverride = $false
        try { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt() } catch {}
    }
    else {
        Set-PwshAutoSlashState -Before $before -After (Get-PwshBufferState)
    }
    -not $interrupted
}
if ($script:__PwshZshPathCompletionEnabled) {
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
$script:__PwshAutoSlashSelfInsert = {
    param($key, $arg)
    Remove-PwshAutoSlash
    [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg)
}
Set-PSReadLineKeyHandler -Key '/', '\', Spacebar, ';', '&', '|' `
    -BriefDescription ZshAutoRemoveSlash `
    -Description 'Insert the key, removing an automatically completed directory slash first.' `
    -ScriptBlock $script:__PwshAutoSlashSelfInsert

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

    $script:__LeanPromptCommandStartUtc = [datetime]::UtcNow
    foreach ($commandAst in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        if (Test-LeanPromptGitBranchRefreshCommand -CommandAst $commandAst) {
            $script:__LeanPromptGitBranchRefreshPending = $true
            break
        }
    }
    $true
}

$script:__PwshAcceptLine = {
    param($key, $arg)
    $script:__LeanPromptStatusOverride = $null
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
    -ScriptBlock $script:__PwshAcceptLine
$script:__LeanPromptDurationEnabled = $true
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
