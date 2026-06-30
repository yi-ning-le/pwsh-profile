if ($script:__PwshProfileIsInteractive) {
# >>> zsh-style substring path completion >>>
# When default completion has no matches, make web<Tab> match names like MyWebProject.
# This is a fallback for PSReadLine menu completion, not an fzf popup search.
if (-not (Test-Path function:\__PwshZshDefaultTabExpansion2)) {
    Copy-Item function:\TabExpansion2 function:\__PwshZshDefaultTabExpansion2
}

function Convert-ToSlashPathDisplay {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $display = $Text -replace '\\', '/'
    $homePath = [Environment]::GetFolderPath('UserProfile') -replace '\\', '/'
    if ($homePath) {
        if ($display.StartsWith($homePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $display = '~' + $display.Substring($homePath.Length)
        }
        elseif ($display.StartsWith("'$homePath", [System.StringComparison]::OrdinalIgnoreCase)) {
            $display = "'~" + $display.Substring($homePath.Length + 1)
        }
        elseif ($display.StartsWith('"' + $homePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $display = '"~' + $display.Substring($homePath.Length + 1)
        }
    }

    $display
}

function Add-SlashPathContainerSuffix {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    if ($Text.EndsWith('/') -or $Text.EndsWith('\')) { return (Convert-ToSlashPathDisplay $Text) }
    if (($Text.StartsWith("'") -and $Text.EndsWith("'")) -or ($Text.StartsWith('"') -and $Text.EndsWith('"'))) {
        return $Text.Substring(0, $Text.Length - 1) + '/' + $Text.Substring($Text.Length - 1)
    }

    $Text + '/'
}

function Test-SlashPathLikeText {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    $candidate = $Text.Trim().Trim('''"')
    $candidate -match '(?i)(^|[\s''"])(?:\.{1,2}\\|[A-Z]:\\|~\\)' -or $candidate.Contains('\')
}

function Test-SlashPathCompletionResult {
    param([System.Management.Automation.CompletionResult] $Match)
    if (-not $Match) { return $false }

    $pathResultTypes = @(
        [System.Management.Automation.CompletionResultType]::ProviderItem,
        [System.Management.Automation.CompletionResultType]::ProviderContainer
    )
    if ($Match.ResultType -in $pathResultTypes) { return $true }

    if ($Match.ResultType -eq [System.Management.Automation.CompletionResultType]::ParameterValue) {
        foreach ($text in @($Match.CompletionText, $Match.ListItemText, $Match.ToolTip)) {
            if (Test-SlashPathLikeText $text) { return $true }
        }
    }

    $false
}

function Convert-CompletionDisplayToSlashPath {
    param([System.Management.Automation.CommandCompletion] $Completion)
    if (-not $Completion -or $Completion.CompletionMatches.Count -eq 0) { return $Completion }

    $matches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    foreach ($match in $Completion.CompletionMatches) {
        $useSlashCompletionText = Test-SlashPathCompletionResult $match
        $isContainer = $match.ResultType -eq [System.Management.Automation.CompletionResultType]::ProviderContainer

        $completionText = if ($useSlashCompletionText) { Convert-ToSlashPathDisplay $match.CompletionText } else { $match.CompletionText }
        if ($useSlashCompletionText -and $isContainer) {
            $completionText = Add-SlashPathContainerSuffix $completionText
        }

        $listItemText = if ($useSlashCompletionText) { Convert-ToSlashPathDisplay $match.ListItemText } else { $match.ListItemText }
        $toolTip = if ($useSlashCompletionText) { Convert-ToSlashPathDisplay $match.ToolTip } else { $match.ToolTip }
        $resultType = if ($useSlashCompletionText -and $isContainer) {
            [System.Management.Automation.CompletionResultType]::ParameterValue
        }
        else {
            $match.ResultType
        }

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
function TabExpansion2 {
    param(
        [string] $inputScript,
        [int] $cursorColumn,
        [hashtable] $options
    )

    $lineBeforeCursor = $inputScript.Substring(0, $cursorColumn)
    $defaultRaw = __PwshZshDefaultTabExpansion2 @PSBoundParameters
    $default = Convert-CompletionDisplayToSlashPath $defaultRaw
    if ($default.CompletionMatches.Count -gt 0) { return $default }

    if ($lineBeforeCursor -notmatch '([^\s''"]+)$') { return $default }

    $word = $Matches[1]
    if ([string]::IsNullOrWhiteSpace($word)) { return $default }

    $unquotedWord = $word.Trim('''"')
    $parent = Split-Path -Path $unquotedWord -Parent
    $leaf = Split-Path -Path $unquotedWord -Leaf

    if ([string]::IsNullOrEmpty($parent)) { $parent = '.' }
    if ([string]::IsNullOrEmpty($leaf)) { $leaf = $unquotedWord }
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $default }

    $pattern = '*' + [System.Management.Automation.WildcardPattern]::Escape($leaf) + '*'
    $completionMatches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()

    Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like $pattern } |
        Sort-Object -Property PSIsContainer, Name -Descending |
        ForEach-Object {
            $candidate = if ($parent -eq '.') { $_.Name } else { Join-Path $parent $_.Name }
            $resultType = if ($_.PSIsContainer) {
                $candidate += [System.IO.Path]::DirectorySeparatorChar
                [System.Management.Automation.CompletionResultType]::ProviderContainer
            }
            else {
                [System.Management.Automation.CompletionResultType]::ProviderItem
            }

            $completionText = if ($candidate -match '[\s''"`$]') {
                "'" + ($candidate -replace "'", "''") + "'"
            }
            else {
                $candidate
            }

            $completionInsertText = Convert-ToSlashPathDisplay $completionText
            if ($_.PSIsContainer) { $completionInsertText = Add-SlashPathContainerSuffix $completionInsertText }
            $toolTip = Convert-ToSlashPathDisplay $_.FullName
            $completionResultType = if ($_.PSIsContainer) {
                [System.Management.Automation.CompletionResultType]::ParameterValue
            }
            else {
                $resultType
            }
            $completionMatches.Add(
                [System.Management.Automation.CompletionResult]::new(
                    $completionInsertText,
                    $_.Name,
                    $completionResultType,
                    $toolTip
                )
            )
        }

    if ($completionMatches.Count -eq 0) { return $default }

    $replacementIndex = $cursorColumn - $word.Length
    [System.Management.Automation.CommandCompletion]::new(
        $completionMatches,
        -1,
        $replacementIndex,
        $word.Length
    )
}
# <<< zsh-style substring path completion <<<

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
    #       Directory candidates are marked ProviderContainer (no trailing space, so Tab can descend further or Enter can accept the whole directory).
    # Leave checkout/reset/diff alone (they mainly complete refs/branches); hand all other subcommands/flags to carapace.
    if (Get-Variable -Name _carapace_completer -ErrorAction SilentlyContinue) {
        $__carapaceNative = $_carapace_completer
        $__gitPathSubcmds = @('add', 'stage', 'restore', 'rm', 'mv', 'clean', 'commit')
        Register-ArgumentCompleter -Native -CommandName 'git', 'git.exe' -ScriptBlock {
            param($wordToComplete, $commandAst, $cursorPosition)
            $elems = @($commandAst.CommandElements | ForEach-Object { $_.Extent.Text })
            $sub = $elems | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^-' } | Select-Object -First 1
            if (($sub -in $__gitPathSubcmds) -and ($wordToComplete -notmatch '^-')) {
                $root = & git rev-parse --show-toplevel 2>$null
                if ($LASTEXITCODE -eq 0 -and $root) {
                    # $root (from rev-parse, forward slashes) is used for git -C across the whole repo; $rootBS (backslashes) is used for path math.
                    $rootBS = $root -replace '/', '\'
                    # Note: do not use $PWD -- GetNewClosure() would freeze it to the directory where the profile loaded;
                    # use Get-Location so cd changes are reflected.
                    $cwd = (Get-Location).Path
                    $hasStaged = ($elems -contains '--staged') -or ($elems -ccontains '-S') -or ($elems -contains '--cached')
                    # Pick the file list by subcommand (all output is repo-root-relative); ls-files defaults to cwd, so use git -C <root> to see the whole repo.
                    $src = switch ($sub) {
                        { $_ -in 'add', 'stage' } {
                            # Working-tree column (porcelain second char) is non-space = unstaged changes or untracked files remain; exclude fully staged files.
                            & git -C $root -c core.quotepath=false status --porcelain --untracked-files=all 2>$null | ForEach-Object {
                                if ($_[1] -eq ' ') { return }
                                $p = $_.Substring(3)
                                if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1] }   # For renames, use the new name
                                $p.Trim('"')
                            }
                            break
                        }
                        'commit' { & git -C $root -c core.quotepath=false diff --cached --name-only 2>$null; break }
                        'clean' { & git -C $root -c core.quotepath=false ls-files --others --exclude-standard --full-name 2>$null; break }
                        { $_ -in 'rm', 'mv' } { & git -C $root -c core.quotepath=false ls-files --full-name 2>$null; break }
                        'restore' {
                            if ($hasStaged) { & git -C $root -c core.quotepath=false diff --cached --name-only 2>$null }
                            else { & git -C $root -c core.quotepath=false ls-files --modified --full-name 2>$null }
                            break
                        }
                    }
                    $dirty = $src | Where-Object { $_ } | ForEach-Object {
                        [System.IO.Path]::GetRelativePath($cwd, (Join-Path $rootBS ($_ -replace '/', '\')))
                    }
                    $word = ($wordToComplete -replace '/', '\').Trim("'`"")
                    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($f0 in $dirty) {
                        $f = $f0 -replace '/', '\'
                        if (-not $f.StartsWith($word, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                        $rest = $f.Substring($word.Length)
                        $i = $rest.IndexOf('\')
                        if ($i -ge 0) {
                            $cand = $word + $rest.Substring(0, $i + 1)              # Directory, with trailing \
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
