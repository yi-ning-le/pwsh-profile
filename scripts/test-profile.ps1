[CmdletBinding()]
param(
    [ValidateRange(1, 50)]
    [int]$Runs = 5,

    [ValidateRange(0, 50)]
    [int]$InteractiveRuns = 0
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$interactiveTimeoutMilliseconds = 30000

if ($InteractiveRuns -gt 0 -and ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) {
    throw '-InteractiveRuns requires an unredirected ConsoleHost such as Windows Terminal.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$profileSource = Join-Path $repoRoot 'profile\Microsoft.PowerShell_profile.ps1'
$profilePartsDir = Join-Path $repoRoot 'profile\profile.d'

if (-not (Test-Path -LiteralPath $profileSource)) {
    throw "Profile source not found: $profileSource"
}

$profileFiles = @($profileSource)
if (Test-Path -LiteralPath $profilePartsDir) {
    $profileFiles += Get-ChildItem -LiteralPath $profilePartsDir -Recurse -Filter '*.ps1' | Sort-Object FullName | ForEach-Object FullName
}

$parseErrors = foreach ($profileFile in $profileFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($profileFile, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($errorRecord in $errors) {
        [pscustomobject]@{
            File = $profileFile
            Message = $errorRecord.Message
        }
    }
}

if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error "$($_.File): $($_.Message)" }
    exit 1
}

$content = ($profileFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
$checks = [ordered]@{
    ParserClean = $true
    NoBase64Helper = $content -notmatch 'FromBase64String'
    NoZoxideInit = $content -notmatch 'zoxide\s+init\s+powershell'
    NoFzfInit = $content -notmatch 'PSFzf|Invoke-Fzf|Set-PsFzfOption'
    DirectLsd = $content -match '(?s)function\s+ls\s*\{.*?\blsd\b'
    DirectBat = $content -match '(?s)function\s+cat\s*\{.*?\bbat\b'
    DirectRg = $content -match '(?s)function\s+grep\s*\{.*?\brg\b'
    NoGitInternalRefParsing = $content -notmatch '\.git[\\/](HEAD|refs)'
}

$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })
foreach ($check in $checks.GetEnumerator()) {
    $status = if ($check.Value) { 'PASS' } else { 'FAIL' }
    Write-Host "[$status] $($check.Key)"
}

if ($failed.Count -gt 0) {
    throw "Profile checks failed: $($failed.Key -join ', ')"
}

$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$interactiveCommand = '$ErrorActionPreference = ''Stop''; $WarningPreference = ''Stop''; try { . $env:PWSH_PROFILE_SOURCE } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }; exit 0'

function Invoke-PwshChecked {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = @(& $pwsh @Arguments *>&1)
    $exitCode = $global:LASTEXITCODE
    if ($exitCode -ne 0 -or $output.Count -gt 0) {
        $details = ($output | Out-String).Trim()
        throw "$Name failed (exit $exitCode): $details"
    }
}

function Get-RelativePs1Paths {
    param([Parameter(Mandatory)][string]$Root)

    @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.ps1' | ForEach-Object {
        [System.IO.Path]::GetRelativePath($Root, $_.FullName) -replace '\\', '/'
    } | Sort-Object)
}

function Assert-ProfileMirror {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $difference = @(Compare-Object (Get-RelativePs1Paths $SourceRoot) (Get-RelativePs1Paths $TargetRoot))
    if ($difference.Count -gt 0) { throw "Installed profile.d does not mirror source: $($difference | Out-String)" }
}

function Assert-NoInstallTransients {
    param([Parameter(Mandatory)][string]$Root)

    $leftovers = @(Get-ChildItem -LiteralPath $Root -Force | Where-Object {
        $_.Name -match '^\.pwsh-profile-stage-' -or $_.Name -match '^\.profile(?:-entry|\.d)\.rollback-'
    })
    if ($leftovers.Count -gt 0) { throw "Installer left transient paths: $($leftovers.Name -join ', ')" }
}

function Get-StartupMedian {
    param([Parameter(Mandatory)][double[]]$Values)

    $sorted = @($Values | Sort-Object)
    $middle = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return $sorted[$middle] }
    ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

if ((Get-StartupMedian -Values @(1, 2, 100)) -ne 2 -or
    (Get-StartupMedian -Values @(1, 2, 3, 100)) -ne 2.5) {
    throw 'startup median self-check failed'
}

function Measure-PwshStartup {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$SampleCount,
        [switch]$InheritConsole
    )

    $samples = for ($i = 0; $i -lt $SampleCount; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        if ($InheritConsole) {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $pwsh
            $psi.UseShellExecute = $false
            foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
            $process = [System.Diagnostics.Process]::Start($psi)
            try {
                if (-not $process.WaitForExit($interactiveTimeoutMilliseconds)) {
                    $sw.Stop()
                    try { $process.Kill($true) } catch {}
                    try { [void]$process.WaitForExit(5000) } catch {}
                    throw "$Name startup run $($i + 1) timed out after 30 seconds"
                }
                $exitCode = $process.ExitCode
            }
            finally {
                $process.Dispose()
            }
            $output = @()
        }
        else {
            $output = @(& $pwsh @Arguments *>&1)
            $exitCode = $global:LASTEXITCODE
        }
        $sw.Stop()
        if ($exitCode -ne 0 -or $output.Count -gt 0) {
            $details = ($output | Out-String).Trim()
            throw "$Name startup run $($i + 1) failed (exit $exitCode): $details"
        }
        [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    }

    [pscustomobject]@{
        Name = $Name
        Runs = $SampleCount
        MedianMs = [math]::Round((Get-StartupMedian -Values $samples), 1)
        AverageMs = [math]::Round(($samples | Measure-Object -Average).Average, 1)
        SamplesMs = ($samples -join ', ')
    }
}

$oldLocalAppData = $env:LOCALAPPDATA
$oldPath = $env:PATH
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pwsh-profile-test-$PID"
$env:PWSH_PROFILE_SOURCE = $profileSource

try {
    $env:LOCALAPPDATA = Join-Path $testRoot 'LocalAppData'
    New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA | Out-Null

    $failingInteractiveProfile = Join-Path $testRoot 'failing-interactive-profile.ps1'
    Set-Content -LiteralPath $failingInteractiveProfile -Value "throw 'interactive profile smoke failure'"
    $savedProfileSource = $env:PWSH_PROFILE_SOURCE
    $env:PWSH_PROFILE_SOURCE = $failingInteractiveProfile
    $failurePsi = [System.Diagnostics.ProcessStartInfo]::new()
    $failurePsi.FileName = $pwsh
    $failurePsi.UseShellExecute = $false
    $failurePsi.CreateNoWindow = $true
    $failurePsi.RedirectStandardInput = $true
    $failurePsi.RedirectStandardOutput = $true
    $failurePsi.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NoExit', '-Command', $interactiveCommand)) {
        [void]$failurePsi.ArgumentList.Add($argument)
    }
    $failureProcess = [System.Diagnostics.Process]::Start($failurePsi)
    try {
        if (-not $failureProcess.WaitForExit(5000)) {
            throw 'interactive failure command remained open after its profile error'
        }
        $failureError = $failureProcess.StandardError.ReadToEnd()
        if ($failureProcess.ExitCode -eq 0 -or $failureError -notmatch 'interactive profile smoke failure') {
            throw "interactive failure command returned an invalid result: exit $($failureProcess.ExitCode), stderr [$failureError]"
        }
    }
    finally {
        if (-not $failureProcess.HasExited) {
            try { $failureProcess.Kill($true) } catch {}
            try { [void]$failureProcess.WaitForExit(5000) } catch {}
        }
        $failureProcess.Dispose()
        $env:PWSH_PROFILE_SOURCE = $savedProfileSource
    }

    $smokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
. $env:PWSH_PROFILE_SOURCE

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "$Name expected [$Expected], got [$Actual]" }
}

$homePath = [Environment]::GetFolderPath('UserProfile') -replace '\\', '/'
Assert-Equal (ConvertTo-LeanPromptSlashPath $homePath) '~' 'home path'
Assert-Equal (ConvertTo-LeanPromptSlashPath "$homePath/project") '~/project' 'home child'
Assert-Equal (ConvertTo-LeanPromptSlashPath "${homePath}2/project") "${homePath}2/project" 'home sibling prefix'
Assert-Equal (ConvertTo-LeanPromptSlashPath ("'" + $homePath + "/project'")) "'~/project'" 'single-quoted home child'
Assert-Equal (ConvertTo-LeanPromptSlashPath ('"' + $homePath + '/project"')) '"~/project"' 'double-quoted home child'

$expectedClassic = @{
    PathContinueSeparator = ''; SegmentSeparator = ''; RightSegmentSeparator = ''; PromptChar = '❯'; ReadOnly = ''
    GitBranch = ''; GitStaged = '+'; GitModified = '!'; GitUntracked = '?'; GitDeleted = 'x'; GitRenamed = '»'
    GitAhead = '⇡'; GitBehind = '⇣'; GitStash = '≡'; GitConflict = ''
    Node = ''; Python = ''; Go = ''; Rust = ''; DotNet = ''
}
$classic = Get-LeanPromptSymbols
Assert-Equal $classic.Count $expectedClassic.Count 'classic symbol count'
foreach ($name in $expectedClassic.Keys) { Assert-Equal $classic[$name] $expectedClassic[$name] "classic symbol $name" }
$esc = [char]27
$expectedClassicPath = "${esc}[48;5;238m${esc}[38;5;39m ${esc}[38;5;248mR:/${esc}[38;5;81mDesign-Service ${esc}[0m${esc}[38;5;238m${esc}[0m"
$classicPath = Format-LeanPromptLeftSegment -Text (Colorize-LeanPromptPath 'R:/Design-Service') -Foreground $script:LeanPromptPalette.Path
Assert-Equal $classicPath $expectedClassicPath 'classic path snapshot'

$classicGitStatus = [pscustomobject]@{
    IsRepo = $true; Staged = 1; Modified = 2; Untracked = 3; Deleted = 4; Renamed = 5
    Ahead = 6; Behind = 7; Stash = 8; Conflict = 9; Action = 'rebasing'
}
$expectedClassicGit = @(
    "${esc}[48;5;238m${esc}[38;5;252m "
    "${esc}[38;5;76m main${esc}[38;5;252m "
    "${esc}[38;5;76m+1${esc}[38;5;252m "
    "${esc}[38;5;178m!2${esc}[38;5;252m "
    "${esc}[38;5;39m?3${esc}[38;5;252m "
    "${esc}[38;5;196mx4${esc}[38;5;252m "
    "${esc}[38;5;81m»5${esc}[38;5;252m "
    "${esc}[38;5;81m⇡6${esc}[38;5;252m "
    "${esc}[38;5;178m⇣7${esc}[38;5;252m "
    "${esc}[38;5;248m≡8${esc}[38;5;252m "
    "${esc}[38;5;196m9${esc}[38;5;252m "
    "${esc}[38;5;196mrebasing${esc}[38;5;252m "
    "${esc}[0m${esc}[38;5;238m${esc}[0m"
) -join ''
Assert-Equal (Format-LeanPromptGitStatusText -Branch 'main' -Status $classicGitStatus) $expectedClassicGit 'classic git snapshot'

$expectedClassicToolchain = @(
    "${esc}[38;5;76m ${esc}[38;5;248mv22 "
    "${esc}[38;5;178m ${esc}[38;5;248m3.13 "
    "${esc}[38;5;81m ${esc}[38;5;248m1.24 "
    "${esc}[38;5;208m ${esc}[38;5;248mstable "
    "${esc}[38;5;141m ${esc}[38;5;248m9.0"
) -join ''
Assert-Equal (Format-ToolchainStatusText 'node v22 py 3.13 go 1.24 rs stable .NET 9.0') $expectedClassicToolchain 'classic toolchain snapshot'

$script:LeanPromptSymbolSet = 'ascii'
$asciiSymbols = Get-LeanPromptSymbols
if (($asciiSymbols.Values -join '') -match '[\uE000-\uF8FF]') { throw 'ascii symbol map contains private-use glyphs' }
$asciiToolchain = Remove-LeanPromptAnsi (Format-ToolchainStatusText 'node v22 py 3.13 go 1.24 rs stable .NET 9.0')
Assert-Equal $asciiToolchain 'node v22 py 3.13 go 1.24 rs stable .NET 9.0' 'ascii toolchain'
$asciiGit = Remove-LeanPromptAnsi (Format-LeanPromptGitStatusText -Branch 'main' -Status ([pscustomobject]@{ IsRepo = $true; Staged = 1 }))
if ($asciiGit -notmatch 'git main' -or $asciiGit -notmatch '\+1') { throw "ascii git output is incomplete: $asciiGit" }
$script:LeanPromptSymbolSet = 'classic'

$projectPath = Join-Path ([System.IO.Path]::GetTempPath()) "lean-prompt-project-$PID"
try {
    New-Item -ItemType Directory -Force -Path $projectPath | Out-Null
    if (Get-LeanPromptProjectRoot -Path $projectPath) { throw 'empty directory was detected as a project' }
    Set-Content -LiteralPath (Join-Path $projectPath 'package.json') -Value '{}'
    $script:__LeanPromptProjectRootCache[$projectPath].ExpiresUtc = [datetime]::MinValue
    Assert-Equal (Get-LeanPromptProjectRoot -Path $projectPath) $projectPath 'project marker addition'
    Remove-Item -LiteralPath (Join-Path $projectPath 'package.json') -Force
    $script:__LeanPromptProjectRootCache[$projectPath].ExpiresUtc = [datetime]::MinValue
    if (Get-LeanPromptProjectRoot -Path $projectPath) { throw 'removed project marker remained cached' }
}
finally {
    Remove-Item -LiteralPath $projectPath -Recurse -Force -ErrorAction SilentlyContinue
}

$lockTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "lean-prompt-lock-$PID"
try {
    $script:__LockTestStarts = 0
    function global:Start-ProfileBackgroundPowerShell {
        param($ScriptPath, $Arguments)
        $script:__LockTestStarts++
        $true
    }
    $cachePath = Join-Path $lockTestRoot 'status.json'
    $lockPath = Join-Path $lockTestRoot 'status.lock'
    Start-AsyncStatusRefresh -Path $lockTestRoot -CachePath $cachePath -LockPath $lockPath -UpdaterPath 'unused.ps1' -LockSeconds 30
    Start-AsyncStatusRefresh -Path $lockTestRoot -CachePath $cachePath -LockPath $lockPath -UpdaterPath 'unused.ps1' -LockSeconds 30
    Assert-Equal $script:__LockTestStarts 1 'fresh lock suppression'
    (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-1)
    Start-AsyncStatusRefresh -Path $lockTestRoot -CachePath $cachePath -LockPath $lockPath -UpdaterPath 'unused.ps1' -LockSeconds 30
    Assert-Equal $script:__LockTestStarts 2 'stale lock retry'
}
finally {
    Remove-Item -LiteralPath $lockTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$watcherTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "lean-prompt-watcher-$PID"
$watcherJobIds = @()
try {
    New-Item -ItemType Directory -Force -Path $watcherTestRoot | Out-Null
    $script:__LeanPromptAsyncGitRedrawWatcher = [System.IO.FileSystemWatcher]::new($watcherTestRoot, '*.json')
    foreach ($eventName in 'Created', 'Changed', 'Renamed') {
        $job = Register-ObjectEvent -InputObject $script:__LeanPromptAsyncGitRedrawWatcher -EventName $eventName `
            -SourceIdentifier "$($script:__LeanPromptAsyncGitRedrawSourceId).$eventName" -Action {}
        $watcherJobIds += $job.Id
    }

    Disable-LeanPromptAsyncRedraw
    Disable-LeanPromptAsyncRedraw
    $remainingSubscribers = @(Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object {
        $_.SourceIdentifier.StartsWith("$($script:__LeanPromptAsyncGitRedrawSourceId).", [System.StringComparison]::Ordinal)
    })
    $remainingJobs = @(Get-Job -Id $watcherJobIds -ErrorAction SilentlyContinue)
    if ($remainingSubscribers.Count -or $remainingJobs.Count -or $script:__LeanPromptAsyncGitRedrawWatcher) {
        throw 'async redraw cleanup left subscriptions, jobs, or watcher state behind'
    }
}
finally {
    Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object {
        $_.SourceIdentifier.StartsWith("$($script:__LeanPromptAsyncGitRedrawSourceId).", [System.StringComparison]::Ordinal)
    } | ForEach-Object { Unregister-Event -SubscriptionId $_.SubscriptionId -ErrorAction SilentlyContinue }
    if ($watcherJobIds.Count) { Remove-Job -Id $watcherJobIds -Force -ErrorAction SilentlyContinue }
    if ($script:__LeanPromptAsyncGitRedrawWatcher) { $script:__LeanPromptAsyncGitRedrawWatcher.Dispose() }
    $script:__LeanPromptAsyncGitRedrawWatcher = $null
    Remove-Item -LiteralPath $watcherTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function global:git { throw 'prompt made a synchronous git call' }
function global:Start-AsyncGitStatusRefresh { param($Path, $CachePath, $LockPath) }
$script:__AsyncGitStatusCacheDir = Join-Path $env:LOCALAPPDATA 'NoSyncGit'
$null = Get-AsyncGitStatusText

function global:Get-LeanPromptPath { param([switch]$Continue) if ($Continue) { 'PATH-C' } else { 'PATH' } }
function global:Get-AsyncGitStatusText { 'GIT' }
function global:Get-AsyncToolchainStatusText { '' }
function global:Get-LeanPromptCommandDurationText { '' }
$global:LASTEXITCODE = 37
Write-Error 'force failed prompt state' -ErrorAction SilentlyContinue
$failedPrompt = prompt
Assert-Equal $failedPrompt "PATH-CGIT`n${esc}[38;5;196m❯${esc}[0m " 'classic failed prompt snapshot'
Assert-Equal $global:LASTEXITCODE 37 'failed prompt LASTEXITCODE'

$global:LASTEXITCODE = 42
$null = 1
$successfulPrompt = prompt
Assert-Equal $successfulPrompt "PATH-CGIT`n${esc}[38;5;76m❯${esc}[0m " 'classic successful prompt snapshot'
Assert-Equal $global:LASTEXITCODE 42 'successful prompt LASTEXITCODE'
if ($failedPrompt -ceq $successfulPrompt) { throw 'successful and failed prompt snapshots are identical' }
'@
    Invoke-PwshChecked -Name 'RuntimeSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $smokeScript)

    $slashCompletionSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
. $env:PWSH_PROFILE_SOURCE
$script:__PwshProfileIsInteractive = $true
$parts = Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d'
. (Join-Path $parts '30-psreadline.ps1')
. (Join-Path $parts '40-completion.ps1')

function Assert-Equal([object]$Actual, [object]$Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "$Name expected [$Expected], got [$Actual]" }
}

function Get-TestCommandAst([string]$Line) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "failed to parse test command [$Line]" }
    @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))[0]
}

$validationHandler = (Get-PSReadLineOption).CommandValidationHandler
if (-not $validationHandler) { throw 'PSReadLine command validation handler was not installed' }
foreach ($line in 'git switch feature', 'git.exe switch feature', 'g switch feature', 'gco feature', 'gcb feature', 'gb -m renamed') {
    $script:__LeanPromptGitBranchRefreshPending = $false
    $validationHandler.Invoke((Get-TestCommandAst $line))
    if (-not $script:__LeanPromptGitBranchRefreshPending) { throw "Git command did not request a branch refresh: $line" }
}
$script:__LeanPromptGitBranchRefreshPending = $false
$validationHandler.Invoke((Get-TestCommandAst 'Write-Host ok'))
if ($script:__LeanPromptGitBranchRefreshPending) { throw 'non-Git command requested a branch refresh' }

if (-not $script:__PwshZshPathCompletionEnabled) { throw 'zsh-style path completion was not enabled' }
foreach ($selfInsertKey in '/', '\', 'Spacebar', ';', '&', '|') {
    $selfInsertHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ $selfInsertKey
    Assert-Equal $selfInsertHandler.Function 'ZshAutoRemoveSlash' "$selfInsertKey key handler"
}
$enterHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ 'Enter'
Assert-Equal $enterHandler.Function 'ZshAcceptLine' 'enter key handler'
$tabHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ 'Tab'
Assert-Equal $tabHandler.Function 'ZshTwoStageTabComplete' 'tab key handler'
$shiftTabHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ 'Shift+Tab'
Assert-Equal $shiftTabHandler.Function 'ZshMenuCompleteBackward' 'shift+tab key handler'
$ctrlCHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ 'Ctrl+c'
Assert-equal $ctrlCHandler.Function 'CancelLine' 'ctrl+c key handler'

Assert-Equal (Get-PwshTabCompletionAction -Line 'git ch' -Cursor 6 -LastLine 'git ch' -LastCursor 6) 'MenuComplete' 'two-stage repeated tab'
Assert-Equal (Get-PwshTabCompletionAction -Line 'git ch' -Cursor 6 -LastLine $null -LastCursor $null) 'Complete' 'two-stage first tab'
Assert-Equal (Get-PwshTabCompletionAction -Line 'git che' -Cursor 7 -LastLine 'git ch' -LastCursor 6) 'Complete' 'two-stage edited line'
Assert-Equal (Get-PwshTabCompletionAction -Line 'git ch' -Cursor 3 -LastLine 'git ch' -LastCursor 6) 'Complete' 'two-stage moved cursor'

if (-not (Test-PwshCommandPositionWord -InputScript 'ge' -WordStart 0)) { throw 'first word was not treated as command position' }
if (Test-PwshCommandPositionWord -InputScript 'git ch' -WordStart 4) { throw 'argument word was treated as command position' }
if (-not (Test-PwshCommandPositionWord -InputScript 'ls | ge' -WordStart 5)) { throw 'pipeline word was not treated as command position' }

$field = [Microsoft.PowerShell.PSConsoleReadLine].GetField(
    'KeysEndingCompletion',
    [System.Reflection.BindingFlags]'NonPublic, Static'
)
$endingKeys = $field.GetValue($null)
$parameterSlashes = @($endingKeys[[System.Management.Automation.CompletionResultType]::ParameterValue] | Where-Object KeyChar -CEQ '/')
Assert-Equal $parameterSlashes.Count 0 'ParameterValue slash ending key count'

$separatorBefore = $script:__PwshDirectorySeparatorField.GetValue($script:__PwshReadLineSingleton)
$separatorDuring = Invoke-PwshWithDirectorySeparator {
    $script:__PwshDirectorySeparatorField.GetValue($script:__PwshReadLineSingleton)
}
Assert-Equal $separatorDuring ([char]'/') 'temporary completion separator'
Assert-Equal ($script:__PwshDirectorySeparatorField.GetValue($script:__PwshReadLineSingleton)) $separatorBefore 'separator after success'
try {
    Invoke-PwshWithDirectorySeparator { throw 'expected separator restoration test failure' }
    throw 'separator restoration exception did not escape'
}
catch {
    if ($_.Exception.Message -cne 'expected separator restoration test failure') { throw }
}
Assert-Equal ($script:__PwshDirectorySeparatorField.GetValue($script:__PwshReadLineSingleton)) $separatorBefore 'separator after exception'

$beforeAutoSlash = [pscustomobject]@{ Line = 'cd Pro'; Cursor = 6 }
$afterAutoSlash = [pscustomobject]@{ Line = 'cd Projects/'; Cursor = 12 }
Set-PwshAutoSlashState -Before $beforeAutoSlash -After $afterAutoSlash
Assert-Equal $script:__PwshAutoSlashState.Line 'cd Projects/' 'automatic slash state'
Set-PwshAutoSlashState -Before $afterAutoSlash -After $afterAutoSlash
Assert-Equal $null $script:__PwshAutoSlashState 'unchanged completion must not mark a slash automatic'

$matches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
$matches.Add([System.Management.Automation.CompletionResult]::new(
    'Backend\Tests\',
    'Backend\Tests\',
    [System.Management.Automation.CompletionResultType]::ProviderContainer,
    'R:\Repo\Backend\Tests'
))
$matches.Add([System.Management.Automation.CompletionResult]::new(
    'Backend\Tests\File.txt',
    'Backend\Tests\File.txt',
    [System.Management.Automation.CompletionResultType]::ProviderItem,
    'R:\Repo\Backend\Tests\File.txt'
))
$matches.Add([System.Management.Automation.CompletionResult]::new(
    "'Space Dir\'",
    'Space Dir',
    [System.Management.Automation.CompletionResultType]::ProviderContainer,
    'R:\Repo\Space Dir'
))
$raw = [System.Management.Automation.CommandCompletion]::new($matches, -1, 0, 0)
$converted = Convert-CompletionDisplayToSlashPath $raw

Assert-Equal $converted.CompletionMatches[0].CompletionText 'Backend/Tests/' 'directory completion text'
Assert-Equal $converted.CompletionMatches[0].ListItemText 'Backend/Tests/' 'directory list item'
Assert-Equal $converted.CompletionMatches[0].ResultType ([System.Management.Automation.CompletionResultType]::ProviderContainer) 'directory result type'
Assert-Equal $converted.CompletionMatches[1].CompletionText 'Backend/Tests/File.txt ' 'file completion text'
Assert-Equal $converted.CompletionMatches[1].ResultType ([System.Management.Automation.CompletionResultType]::ProviderItem) 'file result type'
Assert-Equal $converted.CompletionMatches[2].CompletionText "'Space Dir/'" 'quoted directory completion text'
Assert-Equal $converted.CompletionMatches[2].ListItemText 'Space Dir/' 'quoted directory list item'

if (-not (Test-PwshZshPathPrefix 'Al' 'Alpha')) { throw 'strict prefix rejected matching case' }
if (Test-PwshZshPathPrefix 'al' 'Alpha') { throw 'strict prefix accepted the wrong case' }
if (Test-PwshZshPathPrefix 'pha' 'Alpha') { throw 'strict prefix accepted a substring' }
if (Test-PwshZshPathPrefix 'my_' 'my-file') { throw 'strict prefix interchanged underscore and hyphen' }
if (Test-PwshZshPathPrefix './' './.hidden') { throw 'bare dot path exposed a hidden item' }
if (-not (Test-PwshZshPathPrefix './.h' './.hidden')) { throw 'explicit dot prefix rejected a hidden item' }
if (-not (Test-PwshZshPathPrefix '\\server\Sh' '\\server\Share')) { throw 'UNC segment prefix was rejected' }

$anchorMatches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
foreach ($anchor in '~\Config\', 'R:\Repo\', '\\server\share\Dir\') {
    $anchorMatches.Add([System.Management.Automation.CompletionResult]::new(
        $anchor, $anchor, [System.Management.Automation.CompletionResultType]::ProviderContainer, $anchor
    ))
}
$anchors = Convert-CompletionDisplayToSlashPath ([System.Management.Automation.CommandCompletion]::new($anchorMatches, -1, 0, 0))
Assert-Equal $anchors.CompletionMatches[0].CompletionText '~/Config/' 'tilde anchor'
Assert-Equal $anchors.CompletionMatches[1].CompletionText 'R:/Repo/' 'drive anchor'
Assert-Equal $anchors.CompletionMatches[2].CompletionText '//server/share/Dir/' 'UNC anchor'

if (Test-Path -LiteralPath 'Registry::HKEY_CURRENT_USER') {
    $providerMatches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    $providerMatches.Add([System.Management.Automation.CompletionResult]::new(
        'Registry::HKEY_CURRENT_USER', 'HKEY_CURRENT_USER',
        [System.Management.Automation.CompletionResultType]::ProviderContainer, 'Registry::HKEY_CURRENT_USER'
    ))
    $providerRaw = [System.Management.Automation.CommandCompletion]::new($providerMatches, -1, 0, 0)
    $providerResult = Convert-CompletionDisplayToSlashPath $providerRaw
    Assert-Equal $providerResult.CompletionMatches[0].CompletionText 'Registry::HKEY_CURRENT_USER' 'PowerShell provider completion'
}

$script:__PwshZshPathCompletionEnabled = $false
$native = Convert-CompletionDisplayToSlashPath $raw
Assert-Equal $native.CompletionMatches[0].CompletionText 'Backend\Tests\' 'native fallback completion text'
Assert-Equal $native.CompletionMatches[0].ResultType ([System.Management.Automation.CompletionResultType]::ProviderContainer) 'native fallback result type'
Disable-LeanPromptAsyncRedraw
exit 0
'@
    Invoke-PwshChecked -Name 'ZshKeyAndResultCompletionSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $slashCompletionSmokeScript)

    $env:PWSH_ZSH_COMPLETION_ROOT = Join-Path $testRoot 'zsh-completion'
    $zshPathCompletionSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
. $env:PWSH_PROFILE_SOURCE
$script:__PwshProfileIsInteractive = $true
$parts = Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d'
. (Join-Path $parts '30-psreadline.ps1')
. (Join-Path $parts '40-completion.ps1')

$root = $env:PWSH_ZSH_COMPLETION_ROOT
New-Item -ItemType Directory -Force -Path (Join-Path $root 'Projects\modules\example') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'sub_dir\inner') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'BranchOne\leaf') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'BranchTwo\leaf') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'AlphaUpper\nested') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'alphaLower\nested') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root '.hiddenDir\nested') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'Space Dir\nested') | Out-Null
Set-Content -LiteralPath (Join-Path $root 'my-file.txt') -Value 'flex completion smoke'
Set-Location $root

function Assert-Completion([string]$Line, [string]$Text, [string]$ListItem, [System.Management.Automation.CompletionResultType]$Type) {
    $completion = TabExpansion2 -inputScript $Line -cursorColumn $Line.Length -options @{}
    $matches = @($completion.CompletionMatches)
    if ($matches.Count -ne 1) {
        throw "$Line expected one completion, got [$($matches.CompletionText -join ', ')]"
    }
    $match = $matches[0]
    if ($match.CompletionText -cne $Text -or $match.ListItemText -cne $ListItem -or $match.ResultType -ne $Type) {
        throw "$Line expected [$Text | $ListItem | $Type], got [$($match.CompletionText) | $($match.ListItemText) | $($match.ResultType)]"
    }
    $match
}
function Assert-NoCompletion([string]$Line) {
    $completion = TabExpansion2 -inputScript $Line -cursorColumn $Line.Length -options @{}
    if ($completion.CompletionMatches.Count -ne 0) {
        throw "$Line expected no completions, got [$(@($completion.CompletionMatches).CompletionText -join ', ')]"
    }
}
function Assert-Includes([string]$Line, [string]$Text) {
    $completion = TabExpansion2 -inputScript $Line -cursorColumn $Line.Length -options @{}
    if (@($completion.CompletionMatches | Where-Object CompletionText -CEQ $Text).Count -ne 1) {
        throw "$Line did not include [$Text]: [$(@($completion.CompletionMatches).CompletionText -join ', ')]"
    }
}
function Assert-Excludes([string]$Line, [string]$Text) {
    $completion = TabExpansion2 -inputScript $Line -cursorColumn $Line.Length -options @{}
    if (@($completion.CompletionMatches | Where-Object CompletionText -CEQ $Text).Count -ne 0) {
        throw "$Line unexpectedly included [$Text]"
    }
}
function Assert-CompletionSet([string]$Line, [string[]]$Texts) {
    $completion = TabExpansion2 -inputScript $Line -cursorColumn $Line.Length -options @{}
    $actual = @($completion.CompletionMatches.CompletionText | Sort-Object)
    $expected = @($Texts | Sort-Object)
    if (($actual -join '|') -cne ($expected -join '|')) {
        throw "$Line expected [$($expected -join ', ')], got [$($actual -join ', ')]"
    }
}

function global:__PwshZebraTestWidget {}
function global:Test-PwshFlexWidget {}

$null = Assert-Completion 'Get-Content my-fi' 'my-file.txt ' 'my-file.txt' ProviderItem
Assert-NoCompletion 'Get-Content my_fi'
$null = Assert-Completion 'cd Projects' 'Projects/' 'Projects/' ProviderContainer
$null = Assert-Completion 'cd ./Projects' './Projects/' 'Projects/' ProviderContainer
$null = Assert-Completion 'cd Proj/mod/ex' 'Projects/modules/example/' 'Projects/modules/example/' ProviderContainer
$null = Assert-Completion 'cd Proj/mo/' 'Projects/modules/example/' 'Projects/modules/example/' ProviderContainer
$null = Assert-Completion 'cd sub_/in' 'sub_dir/inner/' 'sub_dir/inner/' ProviderContainer
Assert-CompletionSet 'cd Bra/le' @('BranchOne/', 'BranchTwo/')
Assert-NoCompletion 'cd pro/mo/ex'
Assert-NoCompletion 'cd sub-d/in'
$null = Assert-Completion 'cd A' 'AlphaUpper/' 'AlphaUpper/' ProviderContainer
$null = Assert-Completion 'cd a' 'alphaLower/' 'alphaLower/' ProviderContainer
$null = Assert-Completion 'cd .h' '.hiddenDir/' '.hiddenDir/' ProviderContainer
$null = Assert-Completion 'cd "Space D' '"Space Dir/"' 'Space Dir/' ProviderContainer
Assert-Excludes 'cd ./' './.hiddenDir/'
Assert-Includes 'cd ./.h' './.hiddenDir/'
Assert-NoCompletion 'ebratestwid'
Assert-NoCompletion 'Test_PwshFlexWi'
Assert-NoCompletion 'Get-Content zzqqxx'
Assert-NoCompletion 'Get-ChildItem -Rec_rse'

# Ctrl+C interrupt: a pending break flag aborts TabExpansion2 immediately, and the interruptible
# native helper kills a long-running child instead of waiting it out.
$script:__PwshCompletionInterruptState.CtrlC = $true
$interrupted = TabExpansion2 -inputScript 'Get-Content my-fi' -cursorColumn 16 -options @{}
if ($interrupted.CompletionMatches.Count -ne 0) {
    throw 'pending Ctrl+C should abort TabExpansion2 before producing matches'
}
$script:__PwshCompletionInterruptState.CtrlC = $false

$pwsh = Join-Path $PSHOME 'pwsh.exe'
$script:__PwshCompletionInterruptState.CtrlC = $false
$timer = [System.Timers.Timer]::new(100)
$timer.AutoReset = $false
$subscriber = Register-ObjectEvent -InputObject $timer -EventName Elapsed `
    -MessageData $script:__PwshCompletionInterruptState -Action {
        $Event.MessageData.CtrlC = $true
    }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$timer.Start()
$lines = @(Invoke-PwshInterruptibleNativeCommand -FilePath $pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 8; "late"'))
$sw.Stop()
$timer.Stop()
$timer.Dispose()
Unregister-Event -SourceIdentifier $subscriber.Name -Force -ErrorAction SilentlyContinue
Remove-Job -Id $subscriber.Id -Force -ErrorAction SilentlyContinue
if ($lines.Count -ne 0) { throw "interruptible native command returned unexpected output: [$($lines -join ', ')]" }
if ($sw.Elapsed.TotalSeconds -gt 3) { throw "interruptible native command did not abort promptly ($($sw.Elapsed.TotalSeconds)s)" }
if (-not $script:__PwshCompletionInterruptState.CtrlC) { throw 'Ctrl+C interrupt flag was not set during native-command abort test' }
$script:__PwshCompletionInterruptState.CtrlC = $false

# Interrupt scope is cooperative (flag + pending-input peek); Enter/Exit must nest safely.
Enter-PwshCompletionInterruptScope
Enter-PwshCompletionInterruptScope
Exit-PwshCompletionInterruptScope
Exit-PwshCompletionInterruptScope
if ($script:__PwshCompletionInterruptDepth -ne 0) {
    throw "interrupt scope depth leak: $($script:__PwshCompletionInterruptDepth)"
}

Disable-LeanPromptAsyncRedraw
exit 0
'@
    Invoke-PwshChecked -Name 'ZshPathCompletionSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $zshPathCompletionSmokeScript)

    if (Get-Command carapace -CommandType Application -ErrorAction SilentlyContinue) {
        $env:PWSH_COMPLETION_TEST_ROOT = Join-Path $testRoot 'git-completion-case'
        $completionSmokeScript = @'
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repo = Join-Path $env:PWSH_COMPLETION_TEST_ROOT 'Repo'
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'ActualCase\Nested') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'Space Dir\Nested') | Out-Null
Set-Content -LiteralPath (Join-Path $repo 'ActualCase\Nested\File.txt') -Value 'completion smoke'
Set-Content -LiteralPath (Join-Path $repo 'Space Dir\Nested\File.txt') -Value 'completion smoke'
& git init --quiet --initial-branch=main $repo
if ($global:LASTEXITCODE -ne 0) { throw 'failed to initialize Git completion smoke repository' }
& git -C $repo config core.ignorecase false
if ($global:LASTEXITCODE -ne 0) { throw 'failed to configure case-sensitive Git completion smoke repository' }

. $env:PWSH_PROFILE_SOURCE
$script:__PwshProfileIsInteractive = $true
$parts = Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d'
. (Join-Path $parts '30-psreadline.ps1')
. (Join-Path $parts '40-completion.ps1')
Set-Location $repo

function Assert-Completion([string]$Line, [string]$Text, [string]$ListItem, [System.Management.Automation.CompletionResultType]$Type) {
    $completion = TabExpansion2 -inputScript $Line -cursorColumn $Line.Length -options @{}
    $matches = @($completion.CompletionMatches)
    if ($matches.Count -ne 1) {
        throw "$Line expected one completion, got [$($matches.CompletionText -join ', ')]"
    }
    $match = $matches[0]
    if ($match.CompletionText -cne $Text -or $match.ListItemText -cne $ListItem -or $match.ResultType -ne $Type) {
        throw "$Line expected [$Text | $ListItem | $Type], got [$($match.CompletionText) | $($match.ListItemText) | $($match.ResultType)]"
    }
    $match
}

$directoryCompletion = Assert-Completion 'git add Act' 'ActualCase/' 'ActualCase/' ProviderContainer
$null = Assert-Completion 'git add ActualCase' 'ActualCase/' 'ActualCase/' ProviderContainer
$null = Assert-Completion 'git add ActualCase/Nest' 'ActualCase/Nested/' 'ActualCase/Nested/' ProviderContainer
$null = Assert-Completion 'git add ActualCase/Nested/Fi' 'ActualCase/Nested/File.txt ' 'ActualCase/Nested/File.txt' ProviderItem
$null = Assert-Completion 'git add Spa' "'Space Dir/'" 'Space Dir/' ProviderContainer

$flexCompletion = TabExpansion2 -inputScript 'git cherry_pi' -cursorColumn 13 -options @{}
if ($flexCompletion.CompletionMatches.Count -ne 0) {
    throw "git cherry_pi unexpectedly produced fuzzy matches: [$(@($flexCompletion.CompletionMatches).CompletionText -join ', ')]"
}
& git add --dry-run -- $directoryCompletion.CompletionText.TrimEnd() *> $null
if ($global:LASTEXITCODE -ne 0) { throw 'case-preserving Git completion did not match git add pathspec' }
Disable-LeanPromptAsyncRedraw
exit 0
'@
        Invoke-PwshChecked -Name 'GitPathCompletionCaseSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $completionSmokeScript)
    }
    else {
        Write-Host '[SKIP] GitPathCompletionCaseSmoke (carapace is not installed)'
    }

    $fakeFnmDir = Join-Path $testRoot 'fake-fnm'
    New-Item -ItemType Directory -Force -Path $fakeFnmDir | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeFnmDir 'fnm.cmd') -Encoding ASCII -Value "@echo off`r`necho throw 'fnm output must not run'`r`nexit /b 1"
    $env:PATH = "$fakeFnmDir;$oldPath"
    $fnmFailureScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
. $env:PWSH_PROFILE_SOURCE
if (Test-Path function:\node) { throw 'node wrapper was installed after fnm failure' }
if (-not (Test-Path function:\icons) -or -not (Test-Path function:\grep)) { throw 'profile loading stopped after fnm failure' }
exit 0
'@
    Invoke-PwshChecked -Name 'FnmFailureSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $fnmFailureScript)
    $env:PATH = $oldPath

    $env:PWSH_WINGET_SCRIPT = Join-Path $repoRoot 'packages\winget.ps1'
    $fakeWingetDir = Join-Path $testRoot 'fake-winget'
    New-Item -ItemType Directory -Force -Path $fakeWingetDir | Out-Null
    $env:PWSH_WINGET_LOG = Join-Path $fakeWingetDir 'calls.log'
    $env:PWSH_WINGET_PATH = "$fakeWingetDir;$oldPath"
    Set-Content -LiteralPath (Join-Path $fakeWingetDir 'winget.cmd') -Encoding ASCII `
        -Value "@echo off`r`necho %*>>`"%PWSH_WINGET_LOG%`"`r`nexit /b 7"
    $wingetFailureScript = @'
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:PATH = $env:PWSH_WINGET_PATH

$message = ''
try { & $env:PWSH_WINGET_SCRIPT *> $null }
catch { $message = $_.Exception.Message }
$calls = @(Get-Content -LiteralPath $env:PWSH_WINGET_LOG -ErrorAction SilentlyContinue)
if ($calls.Count -ne 1) { throw "winget failure was not fail-fast: $($calls.Count) calls" }
if ($calls[0] -notmatch '(?:^| )--exact(?: |$)') { throw "winget install did not request an exact package ID: $($calls[0])" }
if ($message -notmatch 'Git\.Git' -or $message -notmatch 'exit 7') { throw "winget failure did not preserve package context: $message" }
exit 0
'@
    Invoke-PwshChecked -Name 'WingetFailureSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $wingetFailureScript)

    $installSmokeRoot = Join-Path $testRoot 'installer'
    $installSmokeScripts = Join-Path $installSmokeRoot 'scripts'
    $installSmokeProfile = Join-Path $installSmokeRoot 'profile'
    New-Item -ItemType Directory -Force -Path $installSmokeScripts, $installSmokeProfile | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install.ps1') -Destination (Join-Path $installSmokeScripts 'install.ps1')
    Copy-Item -Path (Join-Path $repoRoot 'profile\*') -Destination $installSmokeProfile -Recurse
    Set-Content -LiteralPath (Join-Path $installSmokeProfile 'profile.d\99-invalid.ps1') -Value 'function Invalid-ProfilePart {'
    $installTarget = Join-Path $testRoot 'install-invalid\Microsoft.PowerShell_profile.ps1'
    $installTargetParts = Join-Path (Split-Path -Parent $installTarget) 'profile.d'
    New-Item -ItemType Directory -Force -Path $installTargetParts | Out-Null
    Set-Content -LiteralPath $installTarget -Value 'sentinel'
    Set-Content -LiteralPath (Join-Path $installTargetParts 'keep.ps1') -Value '# keep'
    $env:PWSH_INSTALL_SCRIPT = Join-Path $installSmokeScripts 'install.ps1'
    $env:PWSH_INSTALL_TARGET = $installTarget
    $installFailureScript = @'
$ErrorActionPreference = 'Stop'
$PROFILE.CurrentUserCurrentHost = $env:PWSH_INSTALL_TARGET
$rejected = $false
try { & $env:PWSH_INSTALL_SCRIPT -NoBackup }
catch { $rejected = $true }
if (-not $rejected) { throw 'installer accepted invalid source' }
exit 0
'@
    Invoke-PwshChecked -Name 'InvalidInstallSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $installFailureScript)
    if ((Get-Content -LiteralPath $installTarget -Raw).Trim() -ne 'sentinel' -or
        (Get-Content -LiteralPath (Join-Path $installTargetParts 'keep.ps1') -Raw).Trim() -ne '# keep' -or
        @(Get-ChildItem -LiteralPath $installTargetParts -File).Count -ne 1) {
        throw 'installer changed existing target content before source validation'
    }
    Assert-NoInstallTransients -Root (Split-Path -Parent $installTarget)
    Remove-Item -LiteralPath (Join-Path $installSmokeProfile 'profile.d\99-invalid.ps1') -Force

    $lockedTarget = Join-Path $testRoot 'install-locked\Microsoft.PowerShell_profile.ps1'
    $lockedParts = Join-Path (Split-Path -Parent $lockedTarget) 'profile.d'
    New-Item -ItemType Directory -Force -Path $lockedParts | Out-Null
    Set-Content -LiteralPath $lockedTarget -Value 'sentinel'
    foreach ($name in 'a.ps1', 'locked.ps1', 'z.ps1') {
        Set-Content -LiteralPath (Join-Path $lockedParts $name) -Value "# $name"
    }
    $env:PWSH_INSTALL_TARGET = $lockedTarget
    $lockedInstallScript = @'
$ErrorActionPreference = 'Stop'
$PROFILE.CurrentUserCurrentHost = $env:PWSH_INSTALL_TARGET
$rejected = $false
try { & $env:PWSH_INSTALL_SCRIPT -NoBackup *> $null }
catch { $rejected = $true }
if (-not $rejected) { throw 'installer accepted a locked target profile.d' }
exit 0
'@
    $lockedStream = [System.IO.File]::Open(
        (Join-Path $lockedParts 'locked.ps1'),
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    try {
        Invoke-PwshChecked -Name 'LockedInstallRollbackSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $lockedInstallScript)
    }
    finally {
        $lockedStream.Dispose()
    }
    $lockedFiles = @(Get-ChildItem -LiteralPath $lockedParts -File | Sort-Object Name | ForEach-Object Name)
    if ((Get-Content -LiteralPath $lockedTarget -Raw).Trim() -ne 'sentinel' -or
        ($lockedFiles -join ',') -ne 'a.ps1,locked.ps1,z.ps1' -or
        (Get-Content -LiteralPath (Join-Path $lockedParts 'a.ps1') -Raw).Trim() -ne '# a.ps1' -or
        (Get-Content -LiteralPath (Join-Path $lockedParts 'locked.ps1') -Raw).Trim() -ne '# locked.ps1' -or
        (Get-Content -LiteralPath (Join-Path $lockedParts 'z.ps1') -Raw).Trim() -ne '# z.ps1') {
        throw 'installer changed target content after an atomic directory move failure'
    }
    if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $lockedTarget) -Filter '*.bak-*').Count -gt 0) {
        throw 'failed -NoBackup install left permanent backups'
    }
    Assert-NoInstallTransients -Root (Split-Path -Parent $lockedTarget)

    $installSuccessScript = @'
$ErrorActionPreference = 'Stop'
$PROFILE.CurrentUserCurrentHost = $env:PWSH_INSTALL_TARGET
& $env:PWSH_INSTALL_SCRIPT *> $null
exit 0
'@
    $defaultTarget = Join-Path $testRoot 'install-default\Microsoft.PowerShell_profile.ps1'
    $defaultParts = Join-Path (Split-Path -Parent $defaultTarget) 'profile.d'
    New-Item -ItemType Directory -Force -Path $defaultParts | Out-Null
    Set-Content -LiteralPath $defaultTarget -Value 'sentinel'
    Set-Content -LiteralPath (Join-Path $defaultParts 'stale-invalid.ps1') -Value 'function Broken {'
    $env:PWSH_INSTALL_TARGET = $defaultTarget
    Invoke-PwshChecked -Name 'DefaultInstallSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $installSuccessScript)
    Assert-ProfileMirror -SourceRoot (Join-Path $installSmokeProfile 'profile.d') -TargetRoot $defaultParts
    if ((Get-FileHash $defaultTarget).Hash -ne (Get-FileHash (Join-Path $installSmokeProfile 'Microsoft.PowerShell_profile.ps1')).Hash) {
        throw 'default install entry does not match source'
    }
    $entryBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $defaultTarget) -File -Filter 'Microsoft.PowerShell_profile.ps1.bak-*')
    $partsBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $defaultTarget) -Directory -Filter 'profile.d.bak-*')
    if ($entryBackups.Count -ne 1 -or (Get-Content -LiteralPath $entryBackups[0].FullName -Raw).Trim() -ne 'sentinel' -or
        $partsBackups.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $partsBackups[0].FullName 'stale-invalid.ps1'))) {
        throw 'default install did not preserve complete backups'
    }
    Assert-NoInstallTransients -Root (Split-Path -Parent $defaultTarget)

    $noBackupScript = @'
$ErrorActionPreference = 'Stop'
$PROFILE.CurrentUserCurrentHost = $env:PWSH_INSTALL_TARGET
& $env:PWSH_INSTALL_SCRIPT -NoBackup *> $null
exit 0
'@
    $noBackupTarget = Join-Path $testRoot 'install-no-backup\Microsoft.PowerShell_profile.ps1'
    $noBackupParts = Join-Path (Split-Path -Parent $noBackupTarget) 'profile.d'
    New-Item -ItemType Directory -Force -Path $noBackupParts | Out-Null
    Set-Content -LiteralPath $noBackupTarget -Value 'sentinel'
    Set-Content -LiteralPath (Join-Path $noBackupParts 'stale-invalid.ps1') -Value 'function Broken {'
    $env:PWSH_INSTALL_TARGET = $noBackupTarget
    Invoke-PwshChecked -Name 'NoBackupInstallSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $noBackupScript)
    Assert-ProfileMirror -SourceRoot (Join-Path $installSmokeProfile 'profile.d') -TargetRoot $noBackupParts
    if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $noBackupTarget) -Filter '*.bak-*').Count -gt 0) {
        throw '-NoBackup install left permanent backups'
    }
    Assert-NoInstallTransients -Root (Split-Path -Parent $noBackupTarget)

    $updaterRoot = Join-Path $testRoot 'updaters'
    New-Item -ItemType Directory -Force -Path $updaterRoot | Out-Null
    $filesGitRoot = Join-Path $testRoot 'git-files'
    & git init --quiet --initial-branch=main $filesGitRoot
    if ($global:LASTEXITCODE -ne 0) { throw 'failed to initialize files Git smoke repository' }
    $gitSmokeCases = @([pscustomobject]@{ Name = 'Files'; Root = $filesGitRoot })

    $reftableGitRoot = Join-Path $testRoot 'git-reftable'
    $gitInitHelp = (& git init -h 2>&1 | Out-String)
    if ($gitInitHelp -match '--ref-format') {
        & git init --quiet --initial-branch=main --ref-format=reftable $reftableGitRoot
        if ($global:LASTEXITCODE -ne 0) { throw 'failed to initialize supported reftable Git smoke repository' }
        $gitSmokeCases += [pscustomobject]@{ Name = 'Reftable'; Root = $reftableGitRoot }
    }
    else {
        Write-Host '[SKIP] ReftableGitUpdater (git does not support --ref-format=reftable)'
    }

    $gitUpdater = Join-Path $profilePartsDir 'prompt-updaters\Update-AsyncGitStatus.ps1'
    $gitPromptBranchSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. $env:PWSH_PROFILE_SOURCE

$repo = $env:PWSH_GIT_PROMPT_ROOT
$seedCachePath = $env:PWSH_GIT_PROMPT_SEED
$cacheDir = Join-Path (Split-Path -Parent $seedCachePath) (([System.IO.Path]::GetFileNameWithoutExtension($seedCachePath)) + '-prompt')
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
Set-Location $repo
$script:__AsyncGitStatusCacheDir = $cacheDir
$script:LeanPromptSymbolSet = 'ascii'
$script:__GitPromptCacheStamp = 0
$script:__GitPromptRefreshes = 0

function global:Start-AsyncGitStatusRefresh {
    param($Path, $CachePath, $LockPath)
    $script:__GitPromptRefreshes++
}

$key = Get-AsyncStatusKey -Path $repo
$cachePath = Join-Path $cacheDir "$key.json"
$status = Get-Content -LiteralPath $seedCachePath -Raw | ConvertFrom-Json

function Write-TestGitPromptCache([string]$Branch, [int]$Staged) {
    $status.Path = $repo
    $status.Branch = $Branch
    $status.Staged = $Staged
    $status | ConvertTo-Json -Compress | Set-Content -LiteralPath $cachePath -Encoding UTF8
    $script:__GitPromptCacheStamp++
    (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds($script:__GitPromptCacheStamp)
}

Write-TestGitPromptCache -Branch 'main' -Staged 7
$warm = Remove-LeanPromptAnsi (Get-AsyncGitStatusText)
if ($warm -notmatch 'git main' -or $warm -notmatch '\+7' -or $script:__GitPromptRefreshes -ne 0) {
    throw "Git prompt cache did not warm from main: [$warm]"
}

$gitExe = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
& $gitExe -C $repo switch --quiet -c prompt-feature *> $null
if ($global:LASTEXITCODE -ne 0) { throw 'failed to switch Git prompt smoke branch' }

$script:__GitPromptExecutable = $gitExe
$script:__GitPromptCalls = @()
function global:git {
    if ($args -contains 'status' -or $args -contains 'diff' -or $args -contains 'rev-list') {
        throw "prompt made a synchronous Git status call: $args"
    }
    $script:__GitPromptCalls += ($args -join ' ')
    $output = & $script:__GitPromptExecutable @args
    $exitCode = $global:LASTEXITCODE
    $output
    $global:LASTEXITCODE = $exitCode
}

$script:__LeanPromptGitBranchRefreshPending = $true
$global:LASTEXITCODE = 73
$immediate = Get-AsyncGitStatusText
if ($global:LASTEXITCODE -ne 73) { throw 'synchronous branch refresh changed LASTEXITCODE' }
$immediatePlain = Remove-LeanPromptAnsi $immediate
if ($immediatePlain -notmatch 'git prompt-feature' -or $immediatePlain -match 'git main|\+7') {
    throw "switched branch prompt reused stale cache: [$immediatePlain]"
}
if ($script:__GitPromptCalls.Count -ne 1 -or $script:__GitPromptCalls[0] -notmatch 'symbolic-ref --quiet --short HEAD') {
    throw "attached branch prompt used unexpected Git plumbing: [$($script:__GitPromptCalls -join '; ')]"
}
if ($script:__GitPromptRefreshes -ne 1 -or -not $script:__LeanPromptGitBranchOverride -or
    $script:__LeanPromptGitBranchOverride.Branch -cne 'prompt-feature') {
    throw 'attached branch override was not retained while cache was stale'
}
$diskStatus = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
if ($diskStatus.Branch -cne 'main') { throw 'synchronous branch refresh modified the async cache' }

$repeatPlain = Remove-LeanPromptAnsi (Get-AsyncGitStatusText)
if ($repeatPlain -notmatch 'git prompt-feature' -or $repeatPlain -match 'git main|\+7' -or $script:__GitPromptCalls.Count -ne 1) {
    throw "branch override was not reused without another Git call: [$repeatPlain]"
}

Write-TestGitPromptCache -Branch 'prompt-feature' -Staged 3
$caughtUpPlain = Remove-LeanPromptAnsi (Get-AsyncGitStatusText)
if ($caughtUpPlain -notmatch 'git prompt-feature' -or $caughtUpPlain -notmatch '\+3' -or $script:__LeanPromptGitBranchOverride) {
    throw "matching async cache did not replace the branch override: [$caughtUpPlain]"
}

& $gitExe -C $repo switch --quiet --detach HEAD *> $null
if ($global:LASTEXITCODE -ne 0) { throw 'failed to detach Git prompt smoke repository' }
$shortHead = (& $gitExe -C $repo rev-parse --short HEAD | Select-Object -First 1).Trim()
$script:__LeanPromptGitBranchRefreshPending = $true
$global:LASTEXITCODE = 91
$detached = Get-AsyncGitStatusText
if ($global:LASTEXITCODE -ne 91) { throw 'detached branch refresh changed LASTEXITCODE' }
$detachedPlain = Remove-LeanPromptAnsi $detached
if ($detachedPlain -notmatch "git $([regex]::Escape($shortHead))" -or $detachedPlain -match 'git prompt-feature|\+3') {
    throw "detached HEAD prompt is invalid: [$detachedPlain]"
}
if ($script:__GitPromptCalls.Count -ne 3 -or
    $script:__GitPromptCalls[1] -notmatch 'symbolic-ref --quiet --short HEAD' -or
    $script:__GitPromptCalls[2] -notmatch 'rev-parse --short HEAD') {
    throw "detached branch prompt used unexpected Git plumbing: [$($script:__GitPromptCalls -join '; ')]"
}

& $gitExe -C $repo switch --quiet -c prompt-external *> $null
if ($global:LASTEXITCODE -ne 0) { throw 'failed to switch externally during Git prompt smoke' }
Write-TestGitPromptCache -Branch 'prompt-external' -Staged 4
$global:LASTEXITCODE = 109
$external = Get-AsyncGitStatusText
if ($global:LASTEXITCODE -ne 109) { throw 'external branch convergence changed LASTEXITCODE' }
$externalPlain = Remove-LeanPromptAnsi $external
if ($externalPlain -notmatch 'git prompt-external' -or $externalPlain -notmatch '\+4' -or $script:__LeanPromptGitBranchOverride) {
    throw "new async cache did not converge an older branch override: [$externalPlain]"
}
if ($script:__GitPromptCalls.Count -ne 4 -or $script:__GitPromptCalls[3] -notmatch 'symbolic-ref --quiet --short HEAD') {
    throw "external branch convergence used unexpected Git plumbing: [$($script:__GitPromptCalls -join '; ')]"
}
exit 0
'@
    foreach ($gitCase in $gitSmokeCases) {
        & git -C $gitCase.Root -c 'user.name=Profile Test' -c 'user.email=profile@example.invalid' `
            -c commit.gpgSign=true -c gpg.program=definitely-missing-gpg `
            commit --quiet --allow-empty --no-gpg-sign --no-verify -m 'smoke'
        if ($global:LASTEXITCODE -ne 0) { throw "failed to commit in $($gitCase.Name) Git smoke repository" }

        $cacheName = $gitCase.Name.ToLowerInvariant()
        $gitCache = Join-Path $updaterRoot "$cacheName.json"
        $gitLock = Join-Path $updaterRoot "$cacheName.lock"
        New-Item -ItemType File -Path $gitLock | Out-Null
        Invoke-PwshChecked -Name "$($gitCase.Name)GitUpdaterSmoke" -Arguments @(
            '-NoLogo', '-NoProfile', '-File', $gitUpdater,
            '-Cwd', $gitCase.Root, '-CachePath', $gitCache, '-LockPath', $gitLock
        )
        $gitStatus = Get-Content -LiteralPath $gitCache -Raw | ConvertFrom-Json
        if (-not $gitStatus.IsRepo -or $gitStatus.Branch -ne 'main' -or $gitStatus.PSObject.Properties['Signature']) {
            throw "$($gitCase.Name) Git updater cache contract is invalid"
        }

        $env:PWSH_GIT_PROMPT_ROOT = $gitCase.Root
        $env:PWSH_GIT_PROMPT_SEED = $gitCache
        Invoke-PwshChecked -Name "$($gitCase.Name)GitPromptBranchSmoke" -Arguments @(
            '-NoLogo', '-NoProfile', '-Command', $gitPromptBranchSmokeScript
        )
    }

    $toolCache = Join-Path $updaterRoot 'toolchain.json'
    $toolLock = Join-Path $updaterRoot 'toolchain.lock'
    $toolProject = Join-Path $testRoot 'toolchain-project'
    New-Item -ItemType Directory -Force -Path $toolProject | Out-Null
    Set-Content -LiteralPath (Join-Path $toolProject '.python-version') -Value '3.13.1'
    New-Item -ItemType File -Path $toolLock | Out-Null
    Invoke-PwshChecked -Name 'ToolchainUpdaterSmoke' -Arguments @(
        '-NoLogo', '-NoProfile', '-File', (Join-Path $profilePartsDir 'prompt-updaters\Update-AsyncToolchainStatus.ps1'),
        '-Cwd', $toolProject, '-CachePath', $toolCache, '-LockPath', $toolLock
    )
    $toolStatus = Get-Content -LiteralPath $toolCache -Raw | ConvertFrom-Json
    if (-not $toolStatus.IsProject -or $toolStatus.Text -notmatch 'py 3\.13\.1') { throw 'toolchain updater positive cache is invalid' }
    if (@(Get-ChildItem -LiteralPath $updaterRoot -Filter '*.lock').Count -or @(Get-ChildItem -LiteralPath $updaterRoot -Filter '*.tmp').Count) {
        throw 'updater left lock or temporary files behind'
    }

    Measure-PwshStartup -Name 'NoProfile' -Arguments @('-NoLogo', '-NoProfile', '-Command', '$null') -SampleCount $Runs
    Measure-PwshStartup -Name 'BatchSourceProfile' -Arguments @('-NoLogo', '-NoProfile', '-File', $profileSource) -SampleCount $Runs
    if ($InteractiveRuns -gt 0) {
        Measure-PwshStartup -Name 'InteractiveSourceProfile' `
            -Arguments @('-NoLogo', '-NoProfile', '-NoExit', '-Command', $interactiveCommand) `
            -SampleCount $InteractiveRuns -InheritConsole
    }
}
finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:PATH = $oldPath
    Remove-Item Env:PWSH_PROFILE_SOURCE, Env:PWSH_COMPLETION_TEST_ROOT, Env:PWSH_ZSH_COMPLETION_ROOT, `
        Env:PWSH_GIT_PROMPT_ROOT, Env:PWSH_GIT_PROMPT_SEED, `
        Env:PWSH_INSTALL_SCRIPT, Env:PWSH_INSTALL_TARGET, Env:PWSH_WINGET_SCRIPT, `
        Env:PWSH_WINGET_LOG, Env:PWSH_WINGET_PATH -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
