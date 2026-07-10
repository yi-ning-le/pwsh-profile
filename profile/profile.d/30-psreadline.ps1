if ($script:__PwshProfileIsInteractive) {
# ---- PSReadLine: history autosuggestions + syntax highlighting + key bindings (like zsh plugins) ----
Import-Module PSReadLine
Enable-LeanPromptAsyncRedraw
Set-PSReadLineOption -HistoryNoDuplicates
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineOption -EditMode Emacs                      # Emacs keybindings (change to Vi for vi mode)
Set-PSReadLineOption -BellStyle None

# History autosuggestions: keep inline gray suggestions (InlineView), disable noisy multi-line dropdowns (ListView).
# Press RightArrow / End to accept gray suggestions; Ctrl+R searches history; UpArrow searches by current prefix.
if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) {
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
    Set-PSReadLineOption -PredictionViewStyle InlineView
}

# Up/Down arrows: search history by current prefix (zsh history-substring-search feel)
Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
# Tab: menu completion
Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete
Set-PSReadLineKeyHandler -Key '/' `
    -BriefDescription SlashPathMenuComplete `
    -Description 'Accept selected menu completion, insert slash, and continue path completion.' `
    -ScriptBlock {
        param($key, $arg)

        $beforeLine = $null
        $beforeCursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$beforeLine, [ref]$beforeCursor)

        [Microsoft.PowerShell.PSConsoleReadLine]::SelfInsert($key, $arg)

        $line = $null
        $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

        $plainSlashInsert = $false
        if ($null -ne $beforeLine -and $beforeCursor -ge 0 -and $beforeCursor -le $beforeLine.Length) {
            $plainSlashInsert = ($line -eq $beforeLine.Insert($beforeCursor, '/')) -and ($cursor -eq ($beforeCursor + 1))
        }

        if ($plainSlashInsert) { return }

        if ($cursor -ge 2 -and $line.Substring($cursor - 2, 2) -eq '//' -and ($beforeCursor -eq 0 -or $beforeLine[$beforeCursor - 1] -ne '/')) {
            [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar($key, $arg)
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        }

        if ($cursor -gt 0 -and $line[$cursor - 1] -eq '/') {
            [Microsoft.PowerShell.PSConsoleReadLine]::MenuComplete($key, $arg)
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
    }
    $script:__LeanPromptDurationEnabled = $true
}
catch {
    $script:__LeanPromptDurationEnabled = $false
}
}
