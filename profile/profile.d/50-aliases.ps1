# ============================================================
#  Aliases (common oh-my-zsh plugin style)
# ============================================================

# ---- Directory listing (handled by eza) ----
# eza = modern ls replacement: icons / color / git status / tree view. If eza is missing, calls fail directly.
foreach ($a in 'ls') { if (Test-Path "Alias:$a") { Remove-Item "Alias:$a" -Force } }
function ls { if ($args.Count) { eza --icons --group-directories-first @args } else { eza --icons --group-directories-first . } }
function l  { if ($args.Count) { eza --icons --group-directories-first @args } else { eza --icons --group-directories-first . } }
function ll { if ($args.Count) { eza --icons --group-directories-first -l --git @args } else { eza --icons --group-directories-first -l --git . } }        # Long listing + git status
function la { if ($args.Count) { eza --icons --group-directories-first -la --git @args } else { eza --icons --group-directories-first -la --git . } }      # Include hidden files
function lt { if ($args.Count) { eza --icons --group-directories-first --tree --level=2 @args } else { eza --icons --group-directories-first --tree --level=2 . } } # Two-level tree
# ---- Directory navigation ----
function .. { Set-Location .. }
function ... { Set-Location ../.. }
function .... { Set-Location ../../.. }

# ---- git (common omz git plugin aliases) ----
function g     { git @args }
function gst   { git status @args }
function gss   { git status -s @args }
function ga    { git add @args }
function gaa   { git add --all @args }
function gco   { git checkout @args }
function gcb   { git checkout -b @args }
function gb    { git branch @args }
function gc    { git commit @args }
function gcmsg { git commit -m @args }
function gca   { git commit -a @args }
function gp    { git push @args }
function gl    { git pull @args }
function gf    { git fetch @args }
function gd    { git diff @args }
function gds   { git diff --staged @args }
function glog  { git log --oneline --graph --decorate @args }
function gloga { git log --oneline --graph --decorate --all @args }

# ============================================================
#  Modern CLI replacements (resolve PATH at call time, avoid startup probing)
# ============================================================

# cat -> bat (syntax highlighting/line numbers); --paging=never prints like cat without entering a pager
foreach ($a in 'cat') { if (Test-Path "Alias:$a") { Remove-Item "Alias:$a" -Force } }
$env:BAT_THEME = 'OneHalfDark'                         # Match the One Half Dark palette used by this profile
function cat { bat --paging=never @args }

# grep -> rg (ripgrep): faster, recursive by default, supports stdin and files/directories
function grep { rg @args }

# ---- curl/wget alias fix ----
# PowerShell aliases curl/wget to Invoke-WebRequest by default, which behaves very differently from the real tools.
# Remove aliases directly: curl resolves to real curl.exe (built into Win11); wget resolves via PATH if installed, otherwise remains undefined.
# Do not probe PATH with Get-Command; it scans the whole PATH (~25ms). Here we only check aliases, which is cheap.
foreach ($n in 'curl', 'wget') {
    if (Test-Path "Alias:$n") { Remove-Item "Alias:$n" -Force }
}
