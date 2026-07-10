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
    Remove-Item Env:PWSH_PROFILE_SOURCE, Env:PWSH_INSTALL_SCRIPT, Env:PWSH_INSTALL_TARGET, Env:PWSH_WINGET_SCRIPT, `
        Env:PWSH_WINGET_LOG, Env:PWSH_WINGET_PATH -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
