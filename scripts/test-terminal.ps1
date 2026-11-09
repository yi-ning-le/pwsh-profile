# Run in a disposable, unredirected Windows console or Windows ConPTY session.
# This deliberately changes screen contents to test the real terminal parser.
$ErrorActionPreference = 'Stop'
if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    throw 'Terminal cursor tests require an unredirected Windows console.'
}
. (Join-Path $PSScriptRoot '../profile/profile.d/35-terminal.ps1')

function Assert-TerminalCursor([int] $Left, [int] $Top, [string] $Case) {
    $actual = [Console]::GetCursorPosition()
    if ($actual.Item1 -ne $Left -or $actual.Item2 -ne $Top) {
        throw "$Case expected ($Left, $Top), got $actual"
    }
}

# A stale saved cursor must not replace the current position on normal SSH exit.
[Console]::Write("`e[2;2H`e7`e[12;8H")
Reset-Terminal
Assert-TerminalCursor 7 11 'Main buffer recovery'
Reset-Terminal
Assert-TerminalCursor 7 11 'Repeated recovery'

# A disconnected TUI can leave the alternate buffer active. Restore the main
# buffer's return position, not the alternate buffer's unrelated coordinates.
[Console]::Write("`e[15;5H`e[?1049h`e[4;3H")
Reset-Terminal
Assert-TerminalCursor 4 14 'Alternate buffer recovery'

# Reset restricted margins without homing. A newline at the former bottom
# margin must advance instead of scrolling within that old region.
[Console]::Write("`e[3;10r`e[10;6H")
Reset-Terminal
Assert-TerminalCursor 5 9 'Scrolling margin recovery'
[Console]::Write("`r`n")
Assert-TerminalCursor 0 10 'Default scrolling margins'

Reset-Terminal -Clear
Assert-TerminalCursor 0 0 'Explicit clear'
Write-Output '[PASS] Terminal cursor preservation, alternate buffer, scrolling margins, and explicit clear'
