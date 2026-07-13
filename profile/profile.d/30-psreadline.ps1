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
        if (-not $script:__PwshReadLineSingletonField -or -not $script:__PwshDirectorySeparatorField) {
            throw 'PSReadLine directory separator fields were not found.'
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
# Always cancel on Ctrl+C, including when MenuComplete has selected completion text.
# CopyOrCancelLine would copy that selection instead of providing Unix-style interrupt behavior.
Set-PSReadLineKeyHandler -Key Ctrl+c -Function CancelLine

# History autosuggestions: keep inline gray suggestions (InlineView), disable noisy multi-line dropdowns (ListView).
# Press RightArrow / End to accept gray suggestions; Ctrl+R searches history; UpArrow searches by current prefix.
if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
    Set-PSReadLineOption -PredictionViewStyle InlineView
}

# Up/Down arrows: search history by current prefix (zsh history-substring-search feel)
Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
# Tab: zsh auto_menu feel -- the first Tab completes the longest common prefix (keep typing to
# narrow the candidates), a second Tab on an unchanged buffer opens the interactive menu.
# Shift+Tab opens the menu directly (and moves backward once a menu is open).
$script:__PwshTabLastLine = $null
$script:__PwshTabLastCursor = $null
function Get-PwshTabCompletionAction {
    param(
        [string] $Line,
        [int] $Cursor,
        [string] $LastLine,
        [Nullable[int]] $LastCursor
    )

    # Same buffer state as right after the previous Tab press: escalate to the menu.
    # A buffer edited back to an identical state also lands here; the menu is harmless there.
    if ($null -ne $LastCursor -and $Cursor -eq $LastCursor -and $Line -ceq $LastLine) {
        return 'MenuComplete'
    }
    'Complete'
}
function Get-PwshBufferState {
    $line = $null
    $cursor = $null
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    [pscustomobject]@{ Line = $line; Cursor = $cursor }
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
        [ValidateSet('Complete', 'MenuComplete')][string] $Action,
        $Key,
        $Arg
    )

    $before = Get-PwshBufferState
    Invoke-PwshWithDirectorySeparator {
        if ($Action -eq 'MenuComplete') {
            # Custom handlers run with Windows processed input restored. Make Ctrl+C a key while
            # the nested menu is reading input so CancelLine can receive it after the menu returns.
            $previousTreatControlCAsInput = [Console]::TreatControlCAsInput
            try {
                [Console]::TreatControlCAsInput = $true
                [Microsoft.PowerShell.PSConsoleReadLine]::MenuComplete($Key, $Arg)
            }
            finally { [Console]::TreatControlCAsInput = $previousTreatControlCAsInput }
        }
        else {
            [Microsoft.PowerShell.PSConsoleReadLine]::Complete($Key, $Arg)
        }
    }
    Set-PwshAutoSlashState -Before $before -After (Get-PwshBufferState)
}
if ($script:__PwshZshPathCompletionEnabled) {
Set-PSReadLineKeyHandler -Key Tab `
    -BriefDescription ZshTwoStageTabComplete `
    -Description 'Complete the longest common prefix first; open menu completion on a repeated Tab.' `
    -ScriptBlock {
        param($key, $arg)

        $line = $null
        $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        $action = Get-PwshTabCompletionAction -Line $line -Cursor $cursor `
            -LastLine $script:__PwshTabLastLine -LastCursor $script:__PwshTabLastCursor
        if ($action -eq 'MenuComplete') {
            Invoke-PwshCompletionAction -Action MenuComplete -Key $key -Arg $arg
        }
        else {
            Invoke-PwshCompletionAction -Action Complete -Key $key -Arg $arg
        }
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        $script:__PwshTabLastLine = $line
        $script:__PwshTabLastCursor = $cursor
    }
Set-PSReadLineKeyHandler -Key Shift+Tab `
    -BriefDescription ZshMenuCompleteBackward `
    -Description 'Open menu completion; move backward when the menu is already open.' `
    -ScriptBlock {
        param($key, $arg)
        Invoke-PwshCompletionAction -Action MenuComplete -Key $key -Arg $arg
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
Set-PSReadLineKeyHandler -Key Enter `
    -BriefDescription ZshAcceptLine `
    -Description 'Accept the line after removing an automatically completed directory slash.' `
    -ScriptBlock {
        param($key, $arg)
        Remove-PwshAutoSlash
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine($key, $arg)
    }
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
# Command duration: record start time only in interactive PSReadLine sessions; prompt displays it by threshold.
try {
    Set-PSReadLineOption -CommandValidationHandler {
        param($CommandAst)
        $script:__LeanPromptCommandStartUtc = [datetime]::UtcNow
        if ($CommandAst.GetCommandName() -in 'git', 'git.exe', 'g', 'gco', 'gcb', 'gb') {
            $script:__LeanPromptGitBranchRefreshPending = $true
        }
    }
    $script:__LeanPromptDurationEnabled = $true
}
catch {
    $script:__LeanPromptDurationEnabled = $false
}
}
