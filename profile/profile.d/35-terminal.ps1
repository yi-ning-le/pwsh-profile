# Loaded only in interactive sessions. Write directly to the console so recovery
# sequences never become part of captured SSH stdout or a redirected file.
function Test-ProfileTerminalAttached {
    $Host.Name -eq 'ConsoleHost' -and
        -not [Console]::IsInputRedirected -and
        -not [Console]::IsOutputRedirected
}

function Reset-Terminal {
    [CmdletBinding()]
    param([switch] $Clear)

    if (-not (Test-ProfileTerminalAttached)) { return }

    # Save in the current buffer before DECRST 1049: Windows restores the saved
    # cursor even when already in the main buffer. In the alternate buffer this
    # leaves the main buffer's saved return position intact.
    # DECSTR resets scrolling margins without moving the active cursor. Do not
    # append DECSTBM (CSI r): it homes the cursor and overwrites earlier output.
    $sequence = "`e7`e[?1049l`e[?1000l`e[?1002l`e[?1003l`e[?1006l`e[?1004l`e[?2004l" +
        "`e[!p`e[0m`e[?7h`e[?25h"
    if ($Clear) { $sequence += "`e[2J`e[H" }
    [Console]::Write($sequence)
}

function ssh {
    # Keep native option parsing: an advanced function would consume SSH options
    # such as -Debug or -ErrorAction rather than forwarding them unchanged.
    $recoverTerminal = (Test-ProfileTerminalAttached) -and
        -not $MyInvocation.ExpectingInput -and $MyInvocation.PipelineLength -eq 1
    $nativeSucceeded = $false
    $exitCode = $null
    try {
        if ($MyInvocation.ExpectingInput) {
            $input | & ssh.exe @args
        }
        else {
            & ssh.exe @args
        }
        $nativeSucceeded = $?
    }
    finally {
        $exitCode = $global:LASTEXITCODE
        if ($recoverTerminal) {
            try { Reset-Terminal }
            catch { Write-Verbose "Terminal recovery failed: $_" }
            # Cleanup commands otherwise hide the native failure from prompt().
            $script:State.Prompt.__LeanPromptStatusOverride = $nativeSucceeded
        }
        $global:LASTEXITCODE = $exitCode
    }
}
