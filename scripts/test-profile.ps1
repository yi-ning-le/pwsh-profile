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
    $profileFiles += Get-ChildItem -LiteralPath $profilePartsDir -Recurse -File |
        Where-Object Extension -in '.ps1', '.psm1' |
        Sort-Object FullName |
        ForEach-Object FullName
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
    NoLegacyScriptState = $content -notmatch '\$script:__[A-Za-z0-9_]+'
    NoGlobalInternalState = $content -notmatch '\$global:__(Async|Fnm|LeanPrompt|Pwsh)[A-Za-z0-9_]*'
    NoGlobalPromptConfiguration = $content -notmatch '\$global:LeanPrompt(Palette|SymbolsBySet|SymbolSet)'
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
$interactiveCommand = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
try {
    . $env:PWSH_PROFILE_SOURCE
    $module = Get-Module PwshProfile -ErrorAction Stop
    $completionEnabled = & $module { $script:State.Completion.ZshPathCompletionEnabled }
    $interactive = & $module { $script:State.Session.IsInteractive }
    if (-not $interactive -or -not $completionEnabled) {
        throw 'interactive profile parts were not loaded'
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
exit 0
'@

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

function Get-RelativeProfilePaths {
    param([Parameter(Mandatory)][string]$Root)

    @(Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object Extension -in '.ps1', '.psm1' |
        ForEach-Object {
        [System.IO.Path]::GetRelativePath($Root, $_.FullName) -replace '\\', '/'
    } | Sort-Object)
}

function Assert-ProfileMirror {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $difference = @(Compare-Object (Get-RelativeProfilePaths $SourceRoot) (Get-RelativeProfilePaths $TargetRoot))
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
$module = Get-Module PwshProfile -ErrorAction Stop

$expectedFunctions = @(
    'prompt', 'Set-LeanPromptSymbolSet', 'Test-LeanPromptGlyphs'
    'icons'
    'ls', 'l', 'll', 'la', 'lt'
    'pwd', 'mkdir', '..', '...', '....'
    'g', 'gst', 'gss', 'ga', 'gaa', 'gco', 'gcb', 'gb', 'gc', 'gcmsg', 'gca'
    'gp', 'gl', 'gf', 'gd', 'gds', 'glog', 'gloga'
    'cat', 'grep'
    'which', 'whereis', 'touch', 'mkcd', 'head', 'tail'
    'export', 'env', 'open', 'df', 'Update-Path'
)
$optionalFunctions = 'TabExpansion2', 'node', 'npm', 'npx', 'pnpm', 'yarn', 'corepack'
$actualFunctions = @($module.ExportedFunctions.Keys | Sort-Object)
$missingFunctions = @($expectedFunctions | Where-Object { $_ -notin $actualFunctions })
$unexpectedFunctions = @($actualFunctions | Where-Object { $_ -notin $expectedFunctions -and $_ -notin $optionalFunctions })
if ($missingFunctions.Count -or $unexpectedFunctions.Count) {
    throw "module function surface mismatch: missing=[$($missingFunctions -join ',')] unexpected=[$($unexpectedFunctions -join ',')]"
}
$actualAliases = @($module.ExportedAliases.Keys | Sort-Object)
if (($actualAliases -join ',') -cne 'refreshenv,xdg-open') {
    throw "module alias surface mismatch: [$($actualAliases -join ',')]"
}
if (-not (Test-Path function:\reload)) { throw 'entry profile did not install the reload bridge' }
$leakedVariables = @(Get-Variable -Scope Global | Where-Object Name -Match '^__(Async|Fnm|LeanPrompt|Pwsh)')
if ($leakedVariables.Count) { throw "profile leaked internal global variables: [$($leakedVariables.Name -join ',')]" }
$entryVariables = @(
    'profileModulePath', 'profileModule', 'restoreProfileCallerState',
    'escapedProfileEntryPath', 'reloadScript'
)
$leakedEntryVariables = @(Get-Variable -Scope Global | Where-Object Name -In $entryVariables)
if ($leakedEntryVariables.Count) {
    throw "profile leaked entry variables: [$($leakedEntryVariables.Name -join ',')]"
}

if (& $module { $script:State.Session.IsInteractive }) { throw 'redirected command session was classified as interactive' }
if (Test-Path function:\Invoke-PwshCompletionAction) { throw 'PSReadLine profile part loaded in a batch command session' }
if (Test-Path function:\__PwshZshDefaultTabExpansion2) { throw 'completion profile part loaded in a batch command session' }
if (Get-EventSubscriber -SourceIdentifier 'PowerShell.OnIdle' -ErrorAction SilentlyContinue) {
    throw 'completion prewarm was registered in a batch command session'
}
if (-not (Test-Path function:\prompt) -or -not (Test-Path function:\icons) -or -not (Test-Path function:\grep)) {
    throw 'non-interactive profile parts did not finish loading'
}

& $module {
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
$classicPath = Format-LeanPromptLeftSegment -Text (Colorize-LeanPromptPath 'R:/Design-Service') -Foreground $script:State.Prompt.LeanPromptPalette.Path
Assert-Equal $classicPath $expectedClassicPath 'classic path snapshot'

$longBranchLine = $classicPath + (Format-LeanPromptGitStatusText -Branch ('feature/' + ('x' * 200)) -Status $null)
$wideBranchLine = Join-LeanPromptAlignedLine -Left $longBranchLine -Right '' -WindowWidth 120
$narrowBranchLine = Join-LeanPromptAlignedLine -Left $longBranchLine -Right '' -WindowWidth 40
if ((Get-LeanPromptDisplayWidth $wideBranchLine) -gt 119 -or
    (Get-LeanPromptDisplayWidth $narrowBranchLine) -gt 39) {
    throw 'long branch prompt exceeded the single-line width budget'
}
if ((Remove-LeanPromptAnsi $wideBranchLine) -notmatch '…$' -or
    (Remove-LeanPromptAnsi $narrowBranchLine) -notmatch '…$') {
    throw 'long branch prompt was not visibly truncated after resize'
}
$unicodeLine = Join-LeanPromptAlignedLine -Left ($script:State.Prompt.LeanPromptPalette.Path + ('目录🙂' * 30)) -Right '' -WindowWidth 24
if ((Get-LeanPromptDisplayWidth $unicodeLine) -gt 23 -or
    (Remove-LeanPromptAnsi $unicodeLine) -notmatch '…$' -or $unicodeLine -match [char]0xFFFD) {
    throw 'Unicode prompt truncation split a display element or exceeded its width budget'
}
$alignedRight = Join-LeanPromptAlignedLine -Left 'left' -Right 'right' -WindowWidth 80
Assert-Equal $alignedRight "left${esc}[75Gright" 'right prompt safe-column alignment'

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

$budgetedGit = Format-LeanPromptGitStatusText -Branch ('feature/' + ('long-' * 30)) -Status ([pscustomobject]@{
        IsRepo = $true; Staged = 1; Modified = 2; Untracked = 3; Ahead = 4; Stash = 5
    })
$budgetedGit = Limit-LeanPromptGitStatusWidth -Text $budgetedGit -MaxWidth 45
$budgetedGitPlain = Remove-LeanPromptAnsi $budgetedGit
if ((Get-LeanPromptDisplayWidth $budgetedGit) -gt 45 -or $budgetedGitPlain -notmatch 'feature/.+…' -or
    $budgetedGitPlain -notmatch '\+1' -or $budgetedGitPlain -notmatch '!2' -or
    $budgetedGitPlain -notmatch '\?3' -or $budgetedGitPlain -notmatch '⇡4' -or $budgetedGitPlain -notmatch '≡5') {
    throw "semantic Git shortening lost status information: [$budgetedGitPlain]"
}

$expectedClassicToolchain = @(
    "${esc}[38;5;76m ${esc}[38;5;248mv22 "
    "${esc}[38;5;178m ${esc}[38;5;248m3.13 "
    "${esc}[38;5;81m ${esc}[38;5;248m1.24 "
    "${esc}[38;5;208m ${esc}[38;5;248mstable "
    "${esc}[38;5;141m ${esc}[38;5;248m9.0"
) -join ''
Assert-Equal (Format-ToolchainStatusText 'node v22 py 3.13 go 1.24 rs stable .NET 9.0') $expectedClassicToolchain 'classic toolchain snapshot'

$script:State.Prompt.LeanPromptSymbolSet = 'ascii'
$asciiSymbols = Get-LeanPromptSymbols
if (($asciiSymbols.Values -join '') -match '[\uE000-\uF8FF]') { throw 'ascii symbol map contains private-use glyphs' }
$asciiToolchain = Remove-LeanPromptAnsi (Format-ToolchainStatusText 'node v22 py 3.13 go 1.24 rs stable .NET 9.0')
Assert-Equal $asciiToolchain 'node v22 py 3.13 go 1.24 rs stable .NET 9.0' 'ascii toolchain'
$asciiGit = Remove-LeanPromptAnsi (Format-LeanPromptGitStatusText -Branch 'main' -Status ([pscustomobject]@{ IsRepo = $true; Staged = 1 }))
if ($asciiGit -notmatch 'git main' -or $asciiGit -notmatch '\+1') { throw "ascii git output is incomplete: $asciiGit" }
$script:State.Prompt.LeanPromptSymbolSet = 'classic'

$projectPath = Join-Path ([System.IO.Path]::GetTempPath()) "lean-prompt-project-$PID"
try {
    New-Item -ItemType Directory -Force -Path $projectPath | Out-Null
    if (Get-LeanPromptProjectRoot -Path $projectPath) { throw 'empty directory was detected as a project' }
    Set-Content -LiteralPath (Join-Path $projectPath 'package.json') -Value '{}'
    $script:State.Prompt.__LeanPromptProjectRootCache[$projectPath].ExpiresUtc = [datetime]::MinValue
    Assert-Equal (Get-LeanPromptProjectRoot -Path $projectPath) $projectPath 'project marker addition'
    Remove-Item -LiteralPath (Join-Path $projectPath 'package.json') -Force
    $script:State.Prompt.__LeanPromptProjectRootCache[$projectPath].ExpiresUtc = [datetime]::MinValue
    if (Get-LeanPromptProjectRoot -Path $projectPath) { throw 'removed project marker remained cached' }
    Set-Content -LiteralPath (Join-Path $projectPath 'global.json') -Value '{"sdk":{"version":"9.0.100"}}'
    $script:State.Prompt.__LeanPromptProjectRootCache[$projectPath].ExpiresUtc = [datetime]::MinValue
    Assert-Equal (Get-LeanPromptProjectRoot -Path $projectPath) $projectPath 'toolchain-only project marker'
    Remove-Item -LiteralPath (Join-Path $projectPath 'global.json') -Force
    $script:State.Prompt.__LeanPromptProjectRootCache.Clear()

    $nestedPath = Join-Path $projectPath 'one\two\three'
    New-Item -ItemType Directory -Force -Path $nestedPath | Out-Null
    Set-Content -LiteralPath (Join-Path $projectPath '.git') -Value 'gitdir: elsewhere'
    Assert-Equal (Get-LeanPromptProjectRoot -Path $nestedPath) $projectPath '.git file project marker'
    foreach ($cachedPath in $nestedPath, (Split-Path $nestedPath), (Split-Path (Split-Path $nestedPath))) {
        if (-not $script:State.Prompt.__LeanPromptProjectRootCache.ContainsKey($cachedPath)) { throw "project root did not cache traversed path: $cachedPath" }
    }
    Remove-Item -LiteralPath (Join-Path $projectPath '.git') -Force
    $script:State.Prompt.__LeanPromptProjectRootCache.Clear()
    Set-Content -LiteralPath (Join-Path $projectPath 'solution.sln') -Value ''
    Assert-Equal (Get-LeanPromptProjectRoot -Path $nestedPath) $projectPath '.sln project marker'
    Remove-Item -LiteralPath (Join-Path $projectPath 'solution.sln') -Force
    $script:State.Prompt.__LeanPromptProjectRootCache.Clear()
    if (Get-LeanPromptProjectRoot -Path $nestedPath) { throw 'negative project scan found a marker' }
    foreach ($cachedPath in $nestedPath, (Split-Path $nestedPath), (Split-Path (Split-Path $nestedPath))) {
        if (-not $script:State.Prompt.__LeanPromptProjectRootCache.ContainsKey($cachedPath)) { throw "negative project scan did not cache traversed path: $cachedPath" }
    }

    $deepRoot = Join-Path $projectPath 'depth-root'
    New-Item -ItemType Directory -Force -Path $deepRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $deepRoot 'go.mod') -Value 'module test'
    $deepPaths = @($deepRoot)
    $deep = $deepRoot
    1..8 | ForEach-Object { $deep = Join-Path $deep "d$_"; New-Item -ItemType Directory -Force -Path $deep | Out-Null; $deepPaths += $deep }
    $script:State.Prompt.__LeanPromptProjectRootCache.Clear()
    Assert-Equal (Get-LeanPromptProjectRoot -Path $deepPaths[7]) $deepRoot 'project marker eight-level boundary'
    $script:State.Prompt.__LeanPromptProjectRootCache.Clear()
    if (Get-LeanPromptProjectRoot -Path $deepPaths[8]) { throw 'project scan crossed the eight-level limit' }
}
finally {
    Remove-Item -LiteralPath $projectPath -Recurse -Force -ErrorAction SilentlyContinue
}

$toolchainProject = Join-Path ([System.IO.Path]::GetTempPath()) "lean-prompt-toolchain-project-$PID"
$toolchainLocation = Get-Location
$originalToolchainCacheDir = $script:State.Prompt.__AsyncToolchainStatusCacheDir
try {
    $toolchainRoot = Join-Path $toolchainProject 'root'
    $toolchainNested = Join-Path $toolchainRoot 'src\feature'
    $toolchainCacheDir = Join-Path $toolchainProject 'cache'
    New-Item -ItemType Directory -Force -Path $toolchainNested, $toolchainCacheDir | Out-Null
    Set-Content -LiteralPath (Join-Path $toolchainRoot '.python-version') -Value '3.13.1'
    $script:State.Prompt.__AsyncToolchainStatusCacheDir = $toolchainCacheDir
    $toolchainCachePath = Join-Path $toolchainCacheDir "$((Get-AsyncStatusKey -Path $toolchainRoot)).json"
    [pscustomobject]@{
        Path = $toolchainRoot; IsProject = $true; Text = 'py 3.13.1'; Updated = [datetime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $toolchainCachePath
    $script:State.Prompt.__AsyncToolchainStatusMemoryPath = $null
    Set-Location $toolchainNested
    $nestedToolchain = Remove-LeanPromptAnsi (Get-AsyncToolchainStatusText)
    if ($nestedToolchain -notmatch '3\.13\.1' -or
        $script:State.Prompt.__LeanPromptAsyncToolchainRedrawState.CachePath -cne $toolchainCachePath) {
        throw "nested directory did not reuse project-root toolchain status: [$nestedToolchain]"
    }
}
finally {
    Set-Location $toolchainLocation
    $script:State.Prompt.__AsyncToolchainStatusCacheDir = $originalToolchainCacheDir
    Remove-Item -LiteralPath $toolchainProject -Recurse -Force -ErrorAction SilentlyContinue
}

$lockTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "lean-prompt-lock-$PID"
try {
    $global:__LockTestStarts = 0
    function script:Start-ProfileBackgroundPowerShell {
        param($ScriptPath, $Arguments)
        $global:__LockTestStarts++
        $true
    }
    $cachePath = Join-Path $lockTestRoot 'status.json'
    $lockPath = Join-Path $lockTestRoot 'status.lock'
    Start-AsyncStatusRefresh -Path $lockTestRoot -CachePath $cachePath -LockPath $lockPath -UpdaterPath 'unused.ps1' -LockSeconds 30
    Start-AsyncStatusRefresh -Path $lockTestRoot -CachePath $cachePath -LockPath $lockPath -UpdaterPath 'unused.ps1' -LockSeconds 30
    Assert-Equal $global:__LockTestStarts 1 'fresh lock suppression'
    (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-1)
    Start-AsyncStatusRefresh -Path $lockTestRoot -CachePath $cachePath -LockPath $lockPath -UpdaterPath 'unused.ps1' -LockSeconds 30
    Assert-Equal $global:__LockTestStarts 2 'stale lock retry'
}
finally {
    Remove-Item -LiteralPath $lockTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function script:git { throw 'prompt made a synchronous git call' }
function script:Start-AsyncGitStatusRefresh { param($Path, $CachePath, $LockPath) }
$script:State.Prompt.__AsyncGitStatusCacheDir = Join-Path $env:LOCALAPPDATA 'NoSyncGit'
$null = Get-AsyncGitStatusText

$locationBranchRoot = Join-Path ([System.IO.Path]::GetTempPath()) "lean-prompt-location-branch-$PID"
$locationBranchStart = Get-Location
try {
    New-Item -ItemType Directory -Force -Path $locationBranchRoot | Out-Null
    $script:State.Prompt.__AsyncGitStatusCacheDir = Join-Path $locationBranchRoot 'cache'
    $global:__LocationBranchGitCalls = @()
    function script:git {
        $global:__LocationBranchGitCalls += ($args -join ' ')
        $global:LASTEXITCODE = 0
        'entered-branch'
    }

    Set-Location $locationBranchRoot
    $locationBranchText = Remove-LeanPromptAnsi (Get-AsyncGitStatusText)
    if ($locationBranchText -notmatch 'entered-branch') {
        throw "location change did not refresh the Git branch immediately: [$locationBranchText]"
    }
    if ($global:__LocationBranchGitCalls.Count -ne 1 -or
        $global:__LocationBranchGitCalls[0] -notmatch 'rev-parse --abbrev-ref HEAD') {
        throw "location change used unexpected Git plumbing: [$($global:__LocationBranchGitCalls -join '; ')]"
    }
}
finally {
    Set-Location $locationBranchStart
    Remove-Item -LiteralPath $locationBranchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$memoryCacheRoot = Join-Path ([System.IO.Path]::GetTempPath()) "lean-prompt-memory-$PID"
$memoryLocation = Get-Location
try {
    New-Item -ItemType Directory -Force -Path $memoryCacheRoot | Out-Null
    Set-Location $memoryCacheRoot
    $key = Get-AsyncStatusKey -Path $memoryCacheRoot
    $cacheFile = Join-Path $memoryCacheRoot "$key.json"
    @{ Path = $memoryCacheRoot; Value = 'first'; IsRepo = $true } | ConvertTo-Json -Compress | Set-Content -LiteralPath $cacheFile
    $script:State.Prompt.__AsyncGitStatusMemoryPath = $null
    $global:__MemoryReadCount = 0
    $global:__MemoryJsonCount = 0
    function script:Get-Content {
        param([string]$LiteralPath, [switch]$Raw, $ErrorAction)
        $global:__MemoryReadCount++
        Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw:$Raw -ErrorAction $ErrorAction
    }
    function script:ConvertFrom-Json {
        param([Parameter(ValueFromPipeline)]$InputObject)
        process {
            $global:__MemoryJsonCount++
            Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject -ErrorAction Stop
        }
    }
    $formatter = { param($status) $status.Value }
    $refresh = { param($cwd, $cachePath, $lockPath) }
    Assert-Equal (Get-AsyncCachedStatusText -Kind Git -CacheDir $memoryCacheRoot -TtlSeconds 30 -Formatter $formatter -Refresh $refresh) 'first' 'async first cache read'
    Assert-Equal (Get-AsyncCachedStatusText -Kind Git -CacheDir $memoryCacheRoot -TtlSeconds 30 -Formatter $formatter -Refresh $refresh) 'first' 'async memory cache read'
    Assert-Equal $global:__MemoryReadCount 1 'async memory cache Get-Content count'
    Assert-Equal $global:__MemoryJsonCount 1 'async memory cache JSON count'
    @{ Path = $memoryCacheRoot; Value = 'second'; IsRepo = $true } | ConvertTo-Json -Compress |
        Microsoft.PowerShell.Management\Set-Content -LiteralPath $cacheFile
    (Microsoft.PowerShell.Management\Get-Item -LiteralPath $cacheFile).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(1)
    Assert-Equal (Get-AsyncCachedStatusText -Kind Git -CacheDir $memoryCacheRoot -TtlSeconds 30 -Formatter $formatter -Refresh $refresh) 'second' 'async changed cache read'
    Assert-Equal $global:__MemoryReadCount 2 'async changed cache Get-Content count'
    'broken json' | Microsoft.PowerShell.Management\Set-Content -LiteralPath $cacheFile
    (Microsoft.PowerShell.Management\Get-Item -LiteralPath $cacheFile).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(2)
    Assert-Equal (Get-AsyncCachedStatusText -Kind Git -CacheDir $memoryCacheRoot -TtlSeconds 30 -Formatter $formatter -Refresh $refresh) '' 'async corrupt cache read'
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $cacheFile -Force
    Assert-Equal (Get-AsyncCachedStatusText -Kind Git -CacheDir $memoryCacheRoot -TtlSeconds 30 -Formatter $formatter -Refresh $refresh) '' 'async missing cache read'
    Assert-Equal $script:State.Prompt.__AsyncGitStatusMemoryText '' 'async missing cache memory clear'

    @{ Path = $memoryCacheRoot; Value = 'negative'; IsRepo = $false } | ConvertTo-Json -Compress |
        Microsoft.PowerShell.Management\Set-Content -LiteralPath $cacheFile
    (Microsoft.PowerShell.Management\Get-Item -LiteralPath $cacheFile).LastWriteTimeUtc = [datetime]::UtcNow
    $global:__NegativeRefreshCount = 0
    $negativeRefresh = { param($cwd, $cachePath, $lockPath) $global:__NegativeRefreshCount++ }
    Assert-Equal (Get-AsyncCachedStatusText -Kind Git -CacheDir $memoryCacheRoot -TtlSeconds 0 `
        -NegativeTtlSeconds 5 -NegativeProperty IsRepo -Formatter $formatter -Refresh $negativeRefresh) `
        'negative' 'async negative cache read'
    Assert-Equal $global:__NegativeRefreshCount 0 'fresh negative cache refresh count'
    (Microsoft.PowerShell.Management\Get-Item -LiteralPath $cacheFile).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-6)
    $null = Get-AsyncCachedStatusText -Kind Git -CacheDir $memoryCacheRoot -TtlSeconds 0 `
        -NegativeTtlSeconds 5 -NegativeProperty IsRepo -Formatter $formatter -Refresh $negativeRefresh
    Assert-Equal $global:__NegativeRefreshCount 1 'expired negative cache refresh count'
    Remove-Item function:script:Get-Content, function:script:ConvertFrom-Json -Force
}
finally {
    Set-Location $memoryLocation
    Remove-Item function:script:Get-Content, function:script:ConvertFrom-Json -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $memoryCacheRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function script:Get-LeanPromptPath { param([switch]$Continue) if ($Continue) { 'PATH-C' } else { 'PATH' } }
function script:Get-AsyncGitStatusText { 'GIT' }
function script:Get-AsyncToolchainStatusText { '' }
function script:Get-LeanPromptCommandDurationText { '' }
$generationBeforePrompt = [long]$script:State.Prompt.__LeanPromptGitGeneration
$global:LASTEXITCODE = 37
Write-Error 'force failed prompt state' -ErrorAction SilentlyContinue
$failedPrompt = prompt
Assert-Equal $failedPrompt "PATH-CGIT`n${esc}[38;5;196m❯${esc}[0m " 'classic failed prompt snapshot'
Assert-Equal $global:LASTEXITCODE 37 'failed prompt LASTEXITCODE'
Assert-Equal $script:State.Prompt.__LeanPromptGitGeneration ($generationBeforePrompt + 1) 'normal prompt Git generation'

$global:LASTEXITCODE = 42
$null = 1
$successfulPrompt = prompt
Assert-Equal $successfulPrompt "PATH-CGIT`n${esc}[38;5;76m❯${esc}[0m " 'classic successful prompt snapshot'
Assert-Equal $global:LASTEXITCODE 42 'successful prompt LASTEXITCODE'
if ($failedPrompt -ceq $successfulPrompt) { throw 'successful and failed prompt snapshots are identical' }
$script:State.Prompt.__LeanPromptStatusOverride = $false
$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.CacheDriven = $true
$generationBeforeCacheRedraw = [long]$script:State.Prompt.__LeanPromptGitGeneration
$null = 1
$interruptedPrompt = prompt
Assert-Equal $interruptedPrompt $failedPrompt 'interrupted prompt snapshot'
Assert-Equal $script:State.Prompt.__LeanPromptGitGeneration $generationBeforeCacheRedraw 'cache-driven prompt Git generation'
if ($script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.CacheDriven) {
    throw 'cache-driven prompt did not consume its redraw marker'
}
$script:State.Prompt.__LeanPromptStatusOverride = $null
}
'@
    Invoke-PwshChecked -Name 'RuntimeSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $smokeScript)

    $batchGateFile = Join-Path $testRoot 'batch-gate.ps1'
    Set-Content -LiteralPath $batchGateFile -Encoding UTF8 -Value @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
. $env:PWSH_PROFILE_SOURCE
$module = Get-Module PwshProfile -ErrorAction Stop
if (& $module { $script:State.Session.IsInteractive }) { throw 'file session was classified as interactive' }
if (Test-Path function:\Invoke-PwshCompletionAction) { throw 'PSReadLine profile part loaded in a file session' }
if (Test-Path function:\__PwshZshDefaultTabExpansion2) { throw 'completion profile part loaded in a file session' }
if (-not (Test-Path function:\prompt) -or -not (Test-Path function:\grep)) { throw 'base profile parts did not load in a file session' }
'@
    Invoke-PwshChecked -Name 'BatchFileGateSmoke' -Arguments @('-NoLogo', '-NoProfile', '-File', $batchGateFile)

    $redirectedNoExitCommand = '$ErrorActionPreference = ''Stop''; $WarningPreference = ''Stop''; . $env:PWSH_PROFILE_SOURCE; $module = Get-Module PwshProfile -ErrorAction Stop; if ((& $module { $script:State.Session.IsInteractive }) -or (Test-Path function:\Invoke-PwshCompletionAction) -or (Test-Path function:\__PwshZshDefaultTabExpansion2)) { throw ''redirected NoExit session loaded interactive profile parts'' }; exit 0'
    Invoke-PwshChecked -Name 'RedirectedNoExitGateSmoke' `
        -Arguments @('-NoLogo', '-NoProfile', '-NoExit', '-Command', $redirectedNoExitCommand)

    $slashCompletionSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
. $env:PWSH_PROFILE_SOURCE
$modulePath = Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d\PwshProfile.psm1'
Remove-Module PwshProfile -Force
Import-Module $modulePath -Global -ArgumentList $true
$module = Get-Module PwshProfile -ErrorAction Stop
& $module {
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

Assert-Equal (Get-PSReadLineOption).ExtraPromptLineCount 1 'multiline prompt line count'
if ((Get-PSReadLineOption).CommandValidationHandler) { throw 'dead PSReadLine command validation handler is still installed' }
foreach ($line in @(
        'git switch feature',
        'git.exe checkout feature',
        'g switch feature',
        'git -C repo switch feature',
        'git -c core.foo=bar checkout feature',
        'git branch -m renamed',
        'git branch -M renamed',
        'git branch --move renamed',
        'gco feature',
        'gcb feature',
        'gb -m renamed'
    )) {
    if (-not (Test-LeanPromptGitBranchRefreshCommand -CommandAst (Get-TestCommandAst $line))) {
        throw "Git command did not request a branch refresh: $line"
    }
}
foreach ($line in 'git status', 'git log', 'git add .', 'git commit', 'gst', 'gss', 'git branch', 'gb', 'Write-Host ok') {
    if (Test-LeanPromptGitBranchRefreshCommand -CommandAst (Get-TestCommandAst $line)) {
        throw "Command unexpectedly requested a branch refresh: $line"
    }
}

$script:State.Prompt.__LeanPromptCommandStartUtc = $null
$script:State.Prompt.__LeanPromptGitBranchRefreshPending = $false
$generationBeforeAcceptedLine = $script:State.Prompt.__LeanPromptGitGeneration
if (-not (Update-LeanPromptAcceptedLineState -Line 'Write-Host ok') -or -not $script:State.Prompt.__LeanPromptCommandStartUtc) {
    throw 'accepted command did not record its start time'
}
if ($script:State.Prompt.__LeanPromptGitBranchRefreshPending) { throw 'non-Git accepted command requested a branch refresh' }
if ($script:State.Prompt.__LeanPromptGitGeneration -ne $generationBeforeAcceptedLine) {
    throw 'accepted command changed the Git generation before prompt rendering'
}

$script:State.Prompt.__LeanPromptCommandStartUtc = $null
$generationBeforeEmptyLine = $script:State.Prompt.__LeanPromptGitGeneration
if (-not (Update-LeanPromptAcceptedLineState -Line '') -or $script:State.Prompt.__LeanPromptCommandStartUtc -or
    $script:State.Prompt.__LeanPromptGitGeneration -ne $generationBeforeEmptyLine) {
    throw 'empty accepted line changed prompt timing or Git generation before prompt rendering'
}

$script:State.Prompt.__LeanPromptCommandStartUtc = $null
$script:State.Prompt.__LeanPromptGitBranchRefreshPending = $false
$generationBeforeIncompleteLine = $script:State.Prompt.__LeanPromptGitGeneration
if (Update-LeanPromptAcceptedLineState -Line "git switch 'feature") { throw 'incomplete command was accepted for prompt tracking' }
if ($script:State.Prompt.__LeanPromptCommandStartUtc -or $script:State.Prompt.__LeanPromptGitBranchRefreshPending -or
    $script:State.Prompt.__LeanPromptGitGeneration -ne $generationBeforeIncompleteLine) {
    throw 'incomplete command changed prompt tracking state'
}

$script:State.Prompt.__LeanPromptCommandStartUtc = $null
$script:State.Prompt.__LeanPromptGitBranchRefreshPending = $false
if (-not (Update-LeanPromptAcceptedLineState -Line 'Write-Host ok; git switch feature') -or
    -not $script:State.Prompt.__LeanPromptCommandStartUtc -or -not $script:State.Prompt.__LeanPromptGitBranchRefreshPending) {
    throw 'multi-command line did not request a branch refresh'
}

if (-not $script:State.Completion.AcceptLine -or
    $script:State.Completion.AcceptLine.Ast.Extent.Text -notmatch '(?s)try\s*\{.*Update-LeanPromptAcceptedLineState.*\}\s*catch\s*\{\s*\}\s*finally\s*\{.*AcceptLine') {
    throw 'Enter handler does not guarantee AcceptLine after prompt tracking'
}
if ($script:State.Completion.AcceptLine.Ast.Extent.Text -notmatch '\$script:State.Prompt.__LeanPromptStatusOverride\s*=\s*\$null') {
    throw 'Enter handler does not clear the interrupted prompt state'
}
if ($script:State.Completion.AcceptLine.Ast.Extent.Text -notmatch '__LeanPromptAsyncRedrawDispatchState\.InputActive\s*=\s*\$false') {
    throw 'Enter handler does not suspend async prompt redraw'
}

if (-not $script:State.Completion.ZshPathCompletionEnabled) { throw 'zsh-style path completion was not enabled' }
foreach ($selfInsertKey in '/', '\', 'Spacebar', ';', '&', '|') {
    $selfInsertHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ $selfInsertKey
    Assert-Equal $selfInsertHandler.Function 'ZshAutoRemoveSlash' "$selfInsertKey key handler"
}
$enterHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ 'Enter'
Assert-Equal $enterHandler.Function 'ZshAcceptLine' 'enter key handler'
$tabHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ 'Tab'
Assert-Equal $tabHandler.Function 'ZshMenuComplete' 'tab key handler'
$shiftTabHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ 'Shift+Tab'
Assert-Equal $shiftTabHandler.Function 'ZshMenuCompleteBackward' 'shift+tab key handler'
$ctrlCHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ 'Ctrl+c'
Assert-Equal $ctrlCHandler.Function 'PwshCompletionAwareCtrlC' 'ctrl+c key handler'
$ctrlWHandler = Get-PSReadLineKeyHandler -Bound | Where-Object Key -CEQ 'Ctrl+w'
Assert-Equal $ctrlWHandler.Function 'BackwardKillWord' 'ctrl+w key handler'
Assert-Equal (Get-PwshCtrlCAction -CompletionActive $false -CompletionInterrupted $false) 'CancelLine' 'ordinary ctrl+c action'
Assert-Equal (Get-PwshCtrlCAction -CompletionActive $true -CompletionInterrupted $false) 'Abort' 'active completion ctrl+c action'
Assert-Equal (Get-PwshCtrlCAction -CompletionActive $false -CompletionInterrupted $true) 'Consume' 'pending completion interrupt ctrl+c action'
$queuedKeys = $script:State.Completion.QueuedKeysField.GetValue($script:State.Completion.ReadLineSingleton)
if ($queuedKeys.Count -ne 0) { throw 'PSReadLine queued-key test did not start with an empty queue' }
if (-not [object]::ReferenceEquals($queuedKeys, $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.QueuedKeys)) {
    throw 'PSReadLine queued-key state was not shared with async prompt redraw'
}
$keyType = $queuedKeys.GetType().GenericTypeArguments[0]
$fromConsoleKeyInfo = $keyType.GetMethod(
    'FromConsoleKeyInfo', [System.Reflection.BindingFlags]'Public, Static'
)
$queuedCtrlC = $fromConsoleKeyInfo.Invoke($null, @(
    [ConsoleKeyInfo]::new([char]3, [ConsoleKey]::C, $false, $false, $true)
))
try {
    $queuedKeys.Enqueue($queuedCtrlC)
    Assert-Equal (Test-PwshQueuedCtrlC) $true 'deferred menu ctrl+c detection'
}
finally {
    if ($queuedKeys.Count -gt 0) { [void]$queuedKeys.Dequeue() }
}
Assert-Equal (Test-PwshQueuedCtrlC) $false 'empty deferred-key queue'
$script:State.Completion.CompletionInterruptState.CtrlC = $true
& $script:State.Completion.CtrlCHandler $null $null
Assert-Equal $script:State.Completion.CompletionInterruptState.CtrlC $false 'queued completion ctrl+c was consumed'
$interruptDefinition = (Get-Command Test-PwshCompletionInterrupted).Definition
if ($interruptDefinition.IndexOf('[Console]::KeyAvailable') -gt $interruptDefinition.IndexOf('Test-PwshCompletionCtrlCPending')) {
    throw 'completion checked for Ctrl+C before confirming that input was pending'
}
$completionActionDefinition = (Get-Command Invoke-PwshCompletionAction).Definition
$completionGuardStart = $completionActionDefinition.IndexOf('__LeanPromptAsyncRedrawDispatchState.CompletionActive = $true')
$enableCtrlCInput = $completionActionDefinition.IndexOf('[Console]::TreatControlCAsInput = $true')
$completionDispatch = $completionActionDefinition.IndexOf('[Microsoft.PowerShell.PSConsoleReadLine]::MenuComplete($Key, $Arg)')
$deferredCtrlCCheck = $completionActionDefinition.IndexOf('(Test-PwshQueuedCtrlC)')
$restoreCtrlCInput = $completionActionDefinition.IndexOf('[Console]::TreatControlCAsInput = $previousTreatControlCAsInput')
if ($enableCtrlCInput -lt 0 -or $enableCtrlCInput -gt $completionDispatch -or $restoreCtrlCInput -lt $completionDispatch) {
    throw 'Ctrl+C input mode does not cover MenuComplete'
}
if ($completionGuardStart -lt 0 -or $completionGuardStart -gt $completionDispatch -or
    $completionActionDefinition.IndexOf('$redrawState.CompletionActive = $null -ne $previousActionState') -lt $restoreCtrlCInput) {
    throw 'async prompt redraw is not guarded for the whole completion transaction'
}
if ($deferredCtrlCCheck -lt $completionDispatch -or $deferredCtrlCCheck -gt $restoreCtrlCInput) {
    throw 'deferred menu Ctrl+C is not detected inside the completion transaction'
}
$promptFailureState = $completionActionDefinition.IndexOf('$script:State.Prompt.__LeanPromptStatusOverride = $false')
$promptRedraw = $completionActionDefinition.IndexOf('[Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()')
if ($promptFailureState -lt $restoreCtrlCInput -or $promptRedraw -lt $promptFailureState) {
    throw 'completion Ctrl+C does not redraw the prompt with failed status'
}
$ctrlCHandlerDefinition = $script:State.Completion.CtrlCHandler.ToString()
if ($ctrlCHandlerDefinition.IndexOf('$script:State.Prompt.__LeanPromptStatusOverride = $false') -lt 0 -or
    $ctrlCHandlerDefinition.IndexOf('$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.InputActive = $false') -lt 0 -or
    $ctrlCHandlerDefinition.IndexOf('[Microsoft.PowerShell.PSConsoleReadLine]::CancelLine') -lt 0) {
    throw 'ordinary Ctrl+C does not mark the prompt as failed'
}

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

$separatorBefore = $script:State.Completion.DirectorySeparatorField.GetValue($script:State.Completion.ReadLineSingleton)
$separatorDuring = Invoke-PwshWithDirectorySeparator {
    $script:State.Completion.DirectorySeparatorField.GetValue($script:State.Completion.ReadLineSingleton)
}
Assert-Equal $separatorDuring ([char]'/') 'temporary completion separator'
Assert-Equal ($script:State.Completion.DirectorySeparatorField.GetValue($script:State.Completion.ReadLineSingleton)) $separatorBefore 'separator after success'
try {
    Invoke-PwshWithDirectorySeparator { throw 'expected separator restoration test failure' }
    throw 'separator restoration exception did not escape'
}
catch {
    if ($_.Exception.Message -cne 'expected separator restoration test failure') { throw }
}
Assert-Equal ($script:State.Completion.DirectorySeparatorField.GetValue($script:State.Completion.ReadLineSingleton)) $separatorBefore 'separator after exception'

$beforeAutoSlash = [pscustomobject]@{ Line = 'cd Pro'; Cursor = 6 }
$afterAutoSlash = [pscustomobject]@{ Line = 'cd Projects/'; Cursor = 12 }
Set-PwshAutoSlashState -Before $beforeAutoSlash -After $afterAutoSlash
Assert-Equal $script:State.Completion.AutoSlashState.Line 'cd Projects/' 'automatic slash state'
Set-PwshAutoSlashState -Before $afterAutoSlash -After $afterAutoSlash
Assert-Equal $null $script:State.Completion.AutoSlashState 'unchanged completion must not mark a slash automatic'

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

if (-not (Test-PwshZshPathPrefix 'Al' 'Alpha')) { throw 'prefix rejected matching case' }
if (-not (Test-PwshZshPathPrefix 'al' 'Alpha')) { throw 'prefix rejected lowercase input' }
if (-not (Test-PwshZshPathPrefix 'AL' 'Alpha')) { throw 'prefix rejected uppercase input' }
if (Test-PwshZshPathPrefix 'pha' 'Alpha') { throw 'prefix accepted a substring' }
if (Test-PwshZshPathPrefix 'my_' 'my-file') { throw 'prefix interchanged underscore and hyphen' }
if (Test-PwshZshPathPrefix './' './.hidden') { throw 'bare dot path exposed a hidden item' }
if (-not (Test-PwshZshPathPrefix './.h' './.hidden')) { throw 'explicit dot prefix rejected a hidden item' }
if (-not (Test-PwshZshPathPrefix '\\SERVER\sh' '\\server\Share')) { throw 'case-insensitive UNC prefix was rejected' }

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

$script:State.Completion.ZshPathCompletionEnabled = $false
$native = Convert-CompletionDisplayToSlashPath $raw
Assert-Equal $native.CompletionMatches[0].CompletionText 'Backend\Tests\' 'native fallback completion text'
Assert-Equal $native.CompletionMatches[0].ResultType ([System.Management.Automation.CompletionResultType]::ProviderContainer) 'native fallback result type'
Disable-LeanPromptAsyncRedraw
}
exit 0
'@
    Invoke-PwshChecked -Name 'ZshKeyAndResultCompletionSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $slashCompletionSmokeScript)

    $env:PWSH_ZSH_COMPLETION_ROOT = Join-Path $testRoot 'zsh-completion'
    $zshPathCompletionSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
. $env:PWSH_PROFILE_SOURCE
$modulePath = Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d\PwshProfile.psm1'
Remove-Module PwshProfile -Force
Import-Module $modulePath -Global -ArgumentList $true
$module = Get-Module PwshProfile -ErrorAction Stop
& $module {
$root = $env:PWSH_ZSH_COMPLETION_ROOT
New-Item -ItemType Directory -Force -Path (Join-Path $root 'Projects\modules\example') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'sub_dir\inner') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'BranchOne\leaf') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'BranchTwo\leaf') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'AlphaUpper\nested') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'alphaLower\nested') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root '.hiddenDir\nested') | Out-Null
$dotGitPath = Join-Path $root '.git'
New-Item -ItemType Directory -Force -Path (Join-Path $dotGitPath 'nested') | Out-Null
[System.IO.File]::SetAttributes($dotGitPath,
    [System.IO.File]::GetAttributes($dotGitPath) -bor
    [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)
New-Item -ItemType Directory -Force -Path (Join-Path $root 'Space Dir\nested') | Out-Null
$hiddenWindowsPath = Join-Path $root 'HiddenWindows'
New-Item -ItemType Directory -Force -Path $hiddenWindowsPath | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $hiddenWindowsPath 'nested') | Out-Null
[System.IO.File]::SetAttributes($hiddenWindowsPath,
    [System.IO.File]::GetAttributes($hiddenWindowsPath) -bor
    [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)
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
function Assert-Context([string]$Line, [string]$Backend, [string]$Kind, [string]$Parameter) {
    $context = Get-PwshFileSystemCompletionContext -InputScript $Line -CursorColumn $Line.Length
    if ($context.Backend -cne $Backend -or $context.ItemKind -cne $Kind -or
        ([string]$context.ParameterName) -cne $Parameter) {
        throw "$Line expected context [$Backend | $Kind | $Parameter], got [$($context.Backend) | $($context.ItemKind) | $($context.ParameterName)]"
    }
}

function global:__PwshZebraTestWidget {}
function global:Test-PwshFlexWidget {}

$defaultPathMatches = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
$defaultPathMatches.Add([System.Management.Automation.CompletionResult]::new(
    'alphaupper', 'alphaupper', [System.Management.Automation.CompletionResultType]::ProviderContainer, 'alphaupper'
))
$defaultPathRaw = [System.Management.Automation.CommandCompletion]::new($defaultPathMatches, -1, 8, 5)
$defaultPathConverted = Convert-CompletionDisplayToSlashPath -Completion $defaultPathRaw -InputScript 'git add alpha' -CursorColumn 13
if ($defaultPathConverted.CompletionMatches.Count -ne 1 -or
    $defaultPathConverted.CompletionMatches[0].CompletionText -cne 'AlphaUpper/') {
    throw "default path case correction changed its candidate set: [$(@($defaultPathConverted.CompletionMatches).CompletionText -join ', ')]"
}

Assert-Context 'cd ' FileSystem Container Path
Assert-Context 'sl ' FileSystem Container Path
Assert-Context 'pushd ' FileSystem Container Path
Assert-Context 'Get-Content value' FileSystem Any Path
Assert-Context 'Get-Content -LiteralPath value' FileSystem Any LiteralPath
Assert-Context 'Copy-Item source destination' FileSystem Any Destination
Assert-Context 'Copy-Item -Path source ' FileSystem Any Destination
Assert-Context 'Copy-Item -LiteralPath source ' FileSystem Any Destination
Assert-Context 'Remove-Item value' FileSystem Any Path
Assert-Context 'git feature/foo' Default Any ''
Assert-Context 'git ./Projects' FileSystem Any ''
Assert-Context 'cd Registry:' Default Any ''
Assert-Context 'cd \\server\share' Default Any ''
Assert-Context 'cd *.txt' Default Any ''
Assert-Context 'cd $value' Default Any ''
Assert-Context 'Get-Con' Default Any ''
if ((Get-Command TabExpansion2).Definition -match '(?i)cd\|chdir\|sl\|Set-Location\|pushd') {
    throw 'TabExpansion2 still contains a command-name location branch'
}

$carapaceExpectedState = if (Get-Command carapace -CommandType Application -ErrorAction SilentlyContinue) { 'Ready' } else { 'Unavailable' }
if ($script:State.Completion.CarapaceInitializationState -cne 'NotStarted') {
    throw "Carapace initialized before the first Tab: [$script:State.Completion.CarapaceInitializationState]"
}

# Confirmed filesystem parameters bypass both Carapace and the default completer, including the
# handled-but-empty and cooperatively interrupted cases.
$global:__PwshTestDefaultCompletion = (Get-Command __PwshZshDefaultTabExpansion2).ScriptBlock
$global:__PwshTestDefaultCompletionCalls = 0
function __PwshZshDefaultTabExpansion2 {
    param([string] $inputScript, [int] $cursorColumn, [hashtable] $options)
    $global:__PwshTestDefaultCompletionCalls++
    & $global:__PwshTestDefaultCompletion @PSBoundParameters
}
$null = Assert-Completion 'cd Projects' 'Projects/' 'Projects/' ProviderContainer
Assert-Includes 'cd ' 'Projects/'
Assert-NoCompletion 'cd DoesNotExist'
if ($global:__PwshTestDefaultCompletionCalls -ne 0 -or
    $script:State.Completion.CarapaceInitializationState -cne 'NotStarted') {
    throw 'confirmed filesystem completion called the default completer or initialized Carapace'
}
$null = Assert-Completion 'sl Projects' 'Projects/' 'Projects/' ProviderContainer
$null = Assert-Completion 'pushd Projects' 'Projects/' 'Projects/' ProviderContainer
$null = Assert-Completion 'Get-Content my-fi' 'my-file.txt ' 'my-file.txt' ProviderItem
Assert-NoCompletion 'Get-Content my_fi'
$null = Assert-Completion 'Copy-Item my-fi Proj' 'Projects/' 'Projects/' ProviderContainer
if ($global:__PwshTestDefaultCompletionCalls -ne 0 -or
    $script:State.Completion.CarapaceInitializationState -cne 'NotStarted') {
    throw 'generic filesystem routing fell back to the default completer'
}

0..63 | ForEach-Object { New-Item -ItemType Directory -Force -Path (Join-Path $root "Cancel$_") | Out-Null }
$global:__PwshTestInterrupt = (Get-Command Test-PwshCompletionInterrupted).ScriptBlock
$global:__PwshTestInterruptChecks = 0
function Test-PwshCompletionInterrupted {
    $global:__PwshTestInterruptChecks++
    if ($global:__PwshTestInterruptChecks -ge 5) {
        $script:State.Completion.CompletionInterruptState.CtrlC = $true
        return $true
    }
    $false
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
    Assert-NoCompletion 'Get-Content Cancel'
$sw.Stop()
Set-Item Function:Test-PwshCompletionInterrupted $global:__PwshTestInterrupt
if ($sw.Elapsed.TotalMilliseconds -gt 500 -or $global:__PwshTestDefaultCompletionCalls -ne 0 -or
    $script:State.Completion.CarapaceInitializationState -cne 'NotStarted' -or
    -not $script:State.Completion.CompletionInterruptState.CtrlC) {
    throw "interrupted local cd completion did not stop cleanly ($($sw.Elapsed.TotalMilliseconds)ms)"
}
$script:State.Completion.CompletionInterruptState.CtrlC = $false

$defaultCallsBeforeProvider = $global:__PwshTestDefaultCompletionCalls
$WarningPreference = 'SilentlyContinue'
$null = TabExpansion2 -inputScript 'cd Env:' -cursorColumn 7 -options @{}
$WarningPreference = 'Stop'
if ($global:__PwshTestDefaultCompletionCalls -le $defaultCallsBeforeProvider) {
    throw 'provider path did not fall back to the default completer'
}
if ($script:State.Completion.CarapaceInitializationState -cne $carapaceExpectedState) {
    throw "default routing left Carapace in [$script:State.Completion.CarapaceInitializationState], expected [$carapaceExpectedState]"
}
Set-Item Function:__PwshZshDefaultTabExpansion2 $global:__PwshTestDefaultCompletion
$null = Assert-Completion 'cd Projects' 'Projects/' 'Projects/' ProviderContainer
$null = Assert-Completion 'cd ./Projects' './Projects/' 'Projects/' ProviderContainer
$null = Assert-Completion 'cd Proj/mod/ex' 'Projects/modules/example/' 'Projects/modules/example/' ProviderContainer
$null = Assert-Completion 'cd Proj/mo/' 'Projects/modules/example/' 'Projects/modules/example/' ProviderContainer
$null = Assert-Completion 'cd sub_/in' 'sub_dir/inner/' 'sub_dir/inner/' ProviderContainer
Assert-CompletionSet 'cd Bra/le' @('BranchOne/', 'BranchTwo/')
$null = Assert-Completion 'cd pro/mo/ex' 'Projects/modules/example/' 'Projects/modules/example/' ProviderContainer
Assert-NoCompletion 'cd sub-d/in'
$null = Assert-Completion 'cd alphau' 'AlphaUpper/' 'AlphaUpper/' ProviderContainer
$null = Assert-Completion 'cd ALPHAL' 'alphaLower/' 'alphaLower/' ProviderContainer
Assert-CompletionSet 'cd alpha' @('AlphaUpper/', 'alphaLower/')
$null = Assert-Completion 'cd .H' '.hiddenDir/' '.hiddenDir/' ProviderContainer
Assert-Excludes 'cd ' '.git/'
$null = Assert-Completion 'cd .g' '.git/' '.git/' ProviderContainer
$null = Assert-Completion 'cd .git/ne' '.git/nested/' '.git/nested/' ProviderContainer
Assert-Excludes 'cd ' 'HiddenWindows/'
Assert-Excludes 'cd HiddenW' 'HiddenWindows/'
Assert-NoCompletion 'cd HiddenW/ne'
$quoteContext = Get-PwshFileSystemCompletionContext -InputScript 'cd "Space D' -CursorColumn 11
if ($quoteContext.Backend -cne 'Default') { throw 'unclosed quote did not select the default backend' }
Assert-Excludes 'cd ./' './.hiddenDir/'
Assert-Includes 'cd ./.h' './.hiddenDir/'
Assert-NoCompletion 'ebratestwid'
Assert-NoCompletion 'Test_PwshFlexWi'
Assert-NoCompletion 'Get-Content zzqqxx'
Assert-NoCompletion 'Get-ChildItem -Rec_rse'

# Ctrl+C interrupt: a pending break flag aborts TabExpansion2 immediately, and the interruptible
# native helper kills a long-running child instead of waiting it out.
$script:State.Completion.CompletionInterruptState.CtrlC = $true
$interrupted = TabExpansion2 -inputScript 'Get-Content my-fi' -cursorColumn 16 -options @{}
if ($interrupted.CompletionMatches.Count -ne 0) {
    throw 'pending Ctrl+C should abort TabExpansion2 before producing matches'
}
$script:State.Completion.CompletionInterruptState.CtrlC = $false

$pwsh = Join-Path $PSHOME 'pwsh.exe'
$script:State.Completion.CompletionInterruptState.CtrlC = $false
$timer = [System.Timers.Timer]::new(100)
$timer.AutoReset = $false
$subscriber = Register-ObjectEvent -InputObject $timer -EventName Elapsed `
    -MessageData $script:State.Completion.CompletionInterruptState -Action {
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
if (-not $script:State.Completion.CompletionInterruptState.CtrlC) { throw 'Ctrl+C interrupt flag was not set during native-command abort test' }
$script:State.Completion.CompletionInterruptState.CtrlC = $false

# Interrupt scope is cooperative (flag + pending-input peek); Enter/Exit must nest safely.
Enter-PwshCompletionInterruptScope
Enter-PwshCompletionInterruptScope
Exit-PwshCompletionInterruptScope
Exit-PwshCompletionInterruptScope
if ($script:State.Completion.CompletionInterruptDepth -ne 0) {
    throw "interrupt scope depth leak: $($script:State.Completion.CompletionInterruptDepth)"
}

Disable-LeanPromptAsyncRedraw
}
exit 0
'@
    Invoke-PwshChecked -Name 'ZshPathCompletionSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $zshPathCompletionSmokeScript)

    $fakeCarapaceDir = Join-Path $testRoot 'fake-carapace'
    $fakeCarapaceLocalAppData = Join-Path $testRoot 'carapace-localappdata'
    $emptyCarapacePath = Join-Path $testRoot 'empty-path'
    New-Item -ItemType Directory -Force -Path $fakeCarapaceDir, $fakeCarapaceLocalAppData, $emptyCarapacePath | Out-Null
    $env:PWSH_CARAPACE_LOG = Join-Path $fakeCarapaceDir 'calls.log'
    $env:PWSH_CARAPACE_TEST_LOCALAPPDATA = $fakeCarapaceLocalAppData
    $env:PWSH_CARAPACE_EMPTY_PATH = $emptyCarapacePath
    $env:PWSH_CARAPACE_PWSH = $pwsh
    Set-Content -LiteralPath (Join-Path $fakeCarapaceDir 'carapace.cmd') -Encoding ASCII -Value @(
        '@echo off'
        'echo %*>>"%PWSH_CARAPACE_LOG%"'
        'if /I "%PWSH_CARAPACE_MODE%"=="slow" "%PWSH_CARAPACE_PWSH%" -NoLogo -NoProfile -Command "Start-Sleep -Seconds 8"'
        'if /I "%PWSH_CARAPACE_MODE%"=="fail" exit /b 1'
        'echo Set-Variable -Name _carapace_completer -Scope Global -Value {}'
        'exit /b 0'
    )
    $env:PATH = "$fakeCarapaceDir;$oldPath"
    $carapaceLifecycleSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
. $env:PWSH_PROFILE_SOURCE
$env:LOCALAPPDATA = $env:PWSH_CARAPACE_TEST_LOCALAPPDATA
$modulePath = Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d\PwshProfile.psm1'
Remove-Module PwshProfile -Force
Import-Module $modulePath -Global -ArgumentList $true
$module = Get-Module PwshProfile -ErrorAction Stop
& $module {
$parts = Split-Path -Parent $modulePath
$cache = Join-Path $env:LOCALAPPDATA 'PowerShell\ProfileCache\carapace.ps1'

if ($script:State.Completion.CarapaceInitializationState -cne 'NotStarted' -or (Test-Path -LiteralPath $env:PWSH_CARAPACE_LOG)) {
    throw 'Carapace ran before Tab or OnIdle'
}
if ('PwshProfile.ConsoleInput' -as [type]) { throw 'completion input bridge loaded before Tab or OnIdle' }
$prewarmSourceId = $script:State.Completion.CompletionPrewarmSourceId
$prewarmSubscriptionId = $script:State.Completion.CompletionPrewarmSubscriptionId
$prewarmJobId = $script:State.Completion.CompletionPrewarmJobId
if (@(Get-EventSubscriber -SourceIdentifier $prewarmSourceId -ErrorAction SilentlyContinue).Count -ne 1) {
    throw 'completion prewarm did not register exactly once'
}
. (Join-Path $parts '40-completion.ps1')
if (@(Get-EventSubscriber -SourceIdentifier $prewarmSourceId -ErrorAction SilentlyContinue).Count -ne 1 -or
    $script:State.Completion.CompletionPrewarmSubscriptionId -ne $prewarmSubscriptionId -or
    $script:State.Completion.CompletionPrewarmJobId -ne $prewarmJobId) {
    throw 'reloading completion registered a duplicate prewarm'
}

# Interrupt OnIdle cache generation while its native child is still running.
$env:PWSH_CARAPACE_MODE = 'slow'
$script:State.Completion.CompletionInterruptState.CtrlC = $true
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$prewarmEvent = New-Event -SourceIdentifier $prewarmSourceId
Start-Sleep -Milliseconds 20
$sw.Stop()
Remove-Event -EventIdentifier $prewarmEvent.EventIdentifier -ErrorAction SilentlyContinue
if ($sw.Elapsed.TotalSeconds -gt 3 -or $script:State.Completion.CarapaceInitializationState -cne 'NotStarted') {
    throw "interrupted OnIdle prewarm did not return promptly for retry ($($sw.Elapsed.TotalSeconds)s)"
}
if ((Test-Path -LiteralPath $cache) -or (Test-Path -LiteralPath "$cache.tmp")) {
    throw 'interrupted OnIdle prewarm published a cache or left a temporary file'
}
if ($script:State.Completion.CompletionInterruptState.CtrlC) {
    throw 'OnIdle prewarm leaked its Ctrl+C interrupt flag'
}
if (-not ('PwshProfile.ConsoleInput' -as [type])) { throw 'OnIdle prewarm did not initialize the input bridge' }
if ((Get-EventSubscriber -SubscriptionId $prewarmSubscriptionId -ErrorAction SilentlyContinue) -or
    (Get-Job -Id $prewarmJobId -ErrorAction SilentlyContinue)) {
    throw 'triggered OnIdle prewarm left its subscriber or event job behind'
}

# A later OnIdle retries successfully; once Ready, Tab does not run Carapace again.
. (Join-Path $parts '40-completion.ps1')
if (@(Get-EventSubscriber -SourceIdentifier $prewarmSourceId -ErrorAction SilentlyContinue).Count -ne 1) {
    throw 'completion prewarm did not re-register after its one-shot event'
}
$prewarmSubscriptionId = $script:State.Completion.CompletionPrewarmSubscriptionId
$prewarmJobId = $script:State.Completion.CompletionPrewarmJobId
$env:PWSH_CARAPACE_MODE = 'success'
$prewarmEvent = New-Event -SourceIdentifier $prewarmSourceId
Start-Sleep -Milliseconds 20
Remove-Event -EventIdentifier $prewarmEvent.EventIdentifier -ErrorAction SilentlyContinue
if ($script:State.Completion.CarapaceInitializationState -cne 'Ready' -or
    -not (Test-Path -LiteralPath $cache) -or
    (Get-Variable -Name _carapace_completer -ErrorAction SilentlyContinue).Value -isnot [scriptblock]) {
    throw 'OnIdle retry did not produce a ready cache'
}
if (Test-Path -LiteralPath "$cache.tmp") { throw 'successful Carapace initialization left a temporary file' }
$callsAfterReady = @(Get-Content -LiteralPath $env:PWSH_CARAPACE_LOG).Count
$null = TabExpansion2 -inputScript 'Write-Ho' -cursorColumn 8 -options @{}
if (@(Get-Content -LiteralPath $env:PWSH_CARAPACE_LOG).Count -ne $callsAfterReady) {
    throw 'Ready Carapace initialization ran more than once'
}

# A prewarm failure stays silent and retryable; the first Tab warns and disables it for the session.
Remove-Item -LiteralPath $cache -Force
$env:PWSH_CARAPACE_MODE = 'fail'
. (Join-Path $parts '40-completion.ps1')
$callsBeforeFailure = @(Get-Content -LiteralPath $env:PWSH_CARAPACE_LOG).Count
$WarningPreference = 'Stop'
Start-PwshCompletionPrewarm
if ($script:State.Completion.CarapaceInitializationState -cne 'NotStarted' -or $script:State.Completion.CarapaceInitializationWarningShown) {
    throw 'failed prewarm was not silent and retryable'
}
$WarningPreference = 'SilentlyContinue'
$null = TabExpansion2 -inputScript 'Write-Ho' -cursorColumn 8 -options @{}
if ($script:State.Completion.CarapaceInitializationState -cne 'Unavailable' -or -not $script:State.Completion.CarapaceInitializationWarningShown) {
    throw 'failed Carapace generation did not enter the warned Unavailable state'
}
$null = TabExpansion2 -inputScript 'Write-Ho' -cursorColumn 8 -options @{}
if (@(Get-Content -LiteralPath $env:PWSH_CARAPACE_LOG).Count -ne ($callsBeforeFailure + 2)) {
    throw 'failed Carapace generation retried in the same session'
}
if ((Test-Path -LiteralPath $cache) -or (Test-Path -LiteralPath "$cache.tmp")) {
    throw 'failed Carapace generation left a cache or temporary file'
}

# Missing Carapace is silent during prewarm, then follows the one-warning Unavailable Tab path.
$env:PATH = $env:PWSH_CARAPACE_EMPTY_PATH
. (Join-Path $parts '40-completion.ps1')
$WarningPreference = 'Stop'
Start-PwshCompletionPrewarm
if ($script:State.Completion.CarapaceInitializationState -cne 'NotStarted' -or $script:State.Completion.CarapaceInitializationWarningShown) {
    throw 'missing Carapace prewarm was not silent and retryable'
}
$WarningPreference = 'SilentlyContinue'
$null = TabExpansion2 -inputScript 'Write-Ho' -cursorColumn 8 -options @{}
if ($script:State.Completion.CarapaceInitializationState -cne 'Unavailable' -or -not $script:State.Completion.CarapaceInitializationWarningShown) {
    throw 'missing Carapace did not enter the warned Unavailable state'
}
Unregister-Event -SubscriptionId $script:State.Completion.CompletionPrewarmSubscriptionId -Force -ErrorAction SilentlyContinue
Remove-Job -Id $script:State.Completion.CompletionPrewarmJobId -Force -ErrorAction SilentlyContinue
Disable-LeanPromptAsyncRedraw
}
exit 0
'@
    Invoke-PwshChecked -Name 'CarapaceLazyLifecycleSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $carapaceLifecycleSmokeScript)
    $env:PATH = $oldPath

    if (Get-Command carapace -CommandType Application -ErrorAction SilentlyContinue) {
        $env:PWSH_COMPLETION_TEST_ROOT = Join-Path $testRoot 'git-completion-case'
        $completionSmokeScript = @'
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repo = Join-Path $env:PWSH_COMPLETION_TEST_ROOT 'Repo'
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'ActualCase\Nested') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'Space Dir\Nested') | Out-Null
Set-Content -LiteralPath (Join-Path $repo 'ActualCase\Nested\File.txt') -Value 'completion smoke'
Set-Content -LiteralPath (Join-Path $repo 'ActualCase\Nested\Ignored.txt') -Value 'completion smoke'
Set-Content -LiteralPath (Join-Path $repo 'Space Dir\Nested\File.txt') -Value 'completion smoke'
Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value 'ActualCase/Nested/Ignored.txt'
& git init --quiet --initial-branch=main $repo
if ($global:LASTEXITCODE -ne 0) { throw 'failed to initialize Git completion smoke repository' }
& git -C $repo config core.ignorecase false
if ($global:LASTEXITCODE -ne 0) { throw 'failed to configure case-sensitive Git completion smoke repository' }
& git -C $repo config user.email completion-smoke@example.invalid
& git -C $repo config user.name 'Completion Smoke'
& git -C $repo add --all
& git -C $repo commit --quiet -m baseline
if ($global:LASTEXITCODE -ne 0) { throw 'failed to commit Git completion smoke baseline' }
Set-Content -LiteralPath (Join-Path $repo 'ActualCase\Nested\File.txt') -Value 'changed completion smoke'
Set-Content -LiteralPath (Join-Path $repo 'Space Dir\Nested\File.txt') -Value 'changed completion smoke'

. $env:PWSH_PROFILE_SOURCE
$modulePath = Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d\PwshProfile.psm1'
Remove-Module PwshProfile -Force
Import-Module $modulePath -Global -ArgumentList $true
$module = Get-Module PwshProfile -ErrorAction Stop
& $module {
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

$directoryCompletion = Assert-Completion 'git add actual' 'ActualCase/' 'ActualCase/' ProviderContainer
$null = Assert-Completion 'git add ActualCase' 'ActualCase/' 'ActualCase/' ProviderContainer
$null = Assert-Completion 'git add actualcase/nest' 'ActualCase/Nested/' 'ActualCase/Nested/' ProviderContainer
$null = Assert-Completion 'git add ActualCase/Nested/' 'ActualCase/Nested/File.txt ' 'ActualCase/Nested/File.txt' ProviderItem
$null = Assert-Completion 'git add ACTUALCASE/NESTED/fi' 'ActualCase/Nested/File.txt ' 'ActualCase/Nested/File.txt' ProviderItem
$null = Assert-Completion 'git add spa' "'Space Dir/'" 'Space Dir/' ProviderContainer

$genericPathCompleter = {
    param($wordToComplete)
    if ($wordToComplete -and $wordToComplete -notmatch '\\') { return }
    [System.Management.Automation.CompletionResult]::new(
        'ActualCase\Nested\File.txt',
        'ActualCase\Nested\File.txt',
        [System.Management.Automation.CompletionResultType]::ParameterValue,
        'generic native path'
    )
}
$script:State.Completion.CarapaceNativeArgumentCompleters['tar'] = $genericPathCompleter
$script:State.Completion.CarapaceNativeArgumentCompleters['tar.exe'] = $genericPathCompleter
$null = Assert-Completion 'tar -cf out.tar act' 'ActualCase/' 'ActualCase/' ProviderContainer
$null = Assert-Completion 'tar -cf out.tar ActualCase/' 'ActualCase/Nested/' 'ActualCase/Nested/' ProviderContainer
$null = Assert-Completion 'tar -cf out.tar ActualCase/Nested/' 'ActualCase/Nested/File.txt ' 'ActualCase/Nested/File.txt' ProviderItem

$flexCompletion = TabExpansion2 -inputScript 'git cherry_pi' -cursorColumn 13 -options @{}
if ($flexCompletion.CompletionMatches.Count -ne 0) {
    throw "git cherry_pi unexpectedly produced fuzzy matches: [$(@($flexCompletion.CompletionMatches).CompletionText -join ', ')]"
}
& git add --dry-run -- $directoryCompletion.CompletionText.TrimEnd() *> $null
if ($global:LASTEXITCODE -ne 0) { throw 'case-preserving Git completion did not match git add pathspec' }
Disable-LeanPromptAsyncRedraw
}
exit 0
'@
        Invoke-PwshChecked -Name 'NativePathCompletionCaseSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $completionSmokeScript)
    }
    else {
        Write-Host '[SKIP] NativePathCompletionCaseSmoke (carapace is not installed)'
    }

    $fakeFnmDir = Join-Path $testRoot 'fake-fnm'
    New-Item -ItemType Directory -Force -Path $fakeFnmDir | Out-Null
    $env:PWSH_FNM_LOG = Join-Path $fakeFnmDir 'calls.log'
    $env:PWSH_FNM_MULTISHELL = $fakeFnmDir -replace '\\', '/'
    Set-Content -LiteralPath (Join-Path $fakeFnmDir 'fnm.cmd') -Encoding ASCII -Value @(
        '@echo off'
        'echo %*>>"%PWSH_FNM_LOG%"'
        'if /I "%~1"=="env" echo LOCALAPPDATA=%LOCALAPPDATA%>>"%PWSH_FNM_LOG%"'
        'if /I "%~1"=="env" echo {"FNM_MULTISHELL_PATH":"%PWSH_FNM_MULTISHELL%","PWSH_FNM_APPLIED":"true"}'
        'exit /b 0'
    )
    Set-Content -LiteralPath (Join-Path $fakeFnmDir 'node.cmd') -Encoding ASCII -Value @(
        '@echo off'
        'echo node %*>>"%PWSH_FNM_LOG%"'
        'echo v99.0.0'
        'exit /b 0'
    )
    $env:PATH = "$fakeFnmDir;$oldPath"
    $fnmSuccessScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
$env:CODEX_SHELL = '1'
$parentLocalAppData = $env:LOCALAPPDATA
. $env:PWSH_PROFILE_SOURCE
$module = Get-Module PwshProfile -ErrorAction Stop
$fnmState = & $module { $script:State.Fnm }
if ($fnmState.Status -cne 'NotStarted') { throw 'batch session prewarmed fnm' }
if (-not (Test-Path function:\node)) { throw 'node wrapper was not installed before fnm initialization' }
$version = node --version
if ($version -cne 'v99.0.0' -or $env:PWSH_FNM_APPLIED -cne 'true' -or $fnmState.Status -cne 'Ready') {
    throw 'node wrapper did not wait for and apply fnm JSON'
}
if ($env:LOCALAPPDATA -cne $parentLocalAppData) { throw 'fnm initialization changed parent LOCALAPPDATA' }
$fnmState.Remove('SchemaVersion')
. $env:PWSH_PROFILE_SOURCE
$module = Get-Module PwshProfile -ErrorAction Stop
$freshFnmState = & $module { $script:State.Fnm }
if ($freshFnmState.SchemaVersion -ne 1 -or $freshFnmState.Status -cne 'NotStarted' -or
    -not $freshFnmState.ContainsKey('WarningShown') -or [object]::ReferenceEquals($freshFnmState, $fnmState)) {
    throw 'reload did not create fresh module-private fnm state'
}
exit 0
'@
    Invoke-PwshChecked -Name 'FnmSingleInitializationSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $fnmSuccessScript)
    $fnmCalls = @(Get-Content -LiteralPath $env:PWSH_FNM_LOG)
    if (@($fnmCalls | Where-Object { $_ -ceq 'env --json --resolve-engines=false' }).Count -ne 1 -or
        @($fnmCalls | Where-Object { $_ -ceq 'node --version' }).Count -ne 1 -or
        @($fnmCalls | Where-Object { $_ -ceq "LOCALAPPDATA=$env:TEMP" }).Count -ne 1) {
        throw "fnm initialization calls were invalid: [$($fnmCalls -join '; ')]"
    }

    Clear-Content -LiteralPath $env:PWSH_FNM_LOG
    $fnmShadowScriptPath = Join-Path $testRoot 'fnm-script-state-shadow.ps1'
    Set-Content -LiteralPath $fnmShadowScriptPath -Value @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
. $env:PWSH_PROFILE_SOURCE
$script:__FnmState = [pscustomobject]@{ Status = 'Unavailable'; UseRetryAttempted = $true }
$version = node --version
$module = Get-Module PwshProfile -ErrorAction Stop
$fnmState = & $module { $script:State.Fnm }
if ($version -cne 'v99.0.0' -or $fnmState.Status -cne 'Ready') {
    throw 'caller script state shadowed module-private fnm state'
}
exit 0
'@
    Invoke-PwshChecked -Name 'FnmScriptStateShadowSmoke' -Arguments @(
        '-NoLogo', '-NoProfile', '-File', $fnmShadowScriptPath
    )
    $fnmCalls = @(Get-Content -LiteralPath $env:PWSH_FNM_LOG)
    if (@($fnmCalls | Where-Object { $_ -ceq 'env --json --resolve-engines=false' }).Count -ne 1 -or
        @($fnmCalls | Where-Object { $_ -ceq 'node --version' }).Count -ne 1) {
        throw "script-scoped fnm initialization calls were invalid: [$($fnmCalls -join '; ')]"
    }

    Clear-Content -LiteralPath $env:PWSH_FNM_LOG
    Set-Content -LiteralPath (Join-Path $fakeFnmDir 'fnm.cmd') -Encoding ASCII -Value @(
        '@echo off'
        'echo %*>>"%PWSH_FNM_LOG%"'
        'if /I "%~1"=="env" ping -n 3 127.0.0.1 >nul'
        'if /I "%~1"=="env" echo {"FNM_MULTISHELL_PATH":"%PWSH_FNM_MULTISHELL%","PWSH_FNM_APPLIED":"true"}'
        'exit /b 0'
    )
    $env:PWSH_FNM_VERSION_DIR = Join-Path $fakeFnmDir 'version-project'
    New-Item -ItemType Directory -Force -Path $env:PWSH_FNM_VERSION_DIR | Out-Null
    Set-Content -LiteralPath (Join-Path $env:PWSH_FNM_VERSION_DIR '.nvmrc') -Value '99'
$fnmPrewarmScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
$script:State = @{ Session = @{ IsInteractive = $true } }
$nodePart = Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d\20-node.ps1'
$sw = [Diagnostics.Stopwatch]::StartNew()
. $nodePart
. $nodePart
$sw.Stop()
if ($sw.Elapsed.TotalMilliseconds -gt 500 -or $script:State.Fnm.Status -cne 'Running') {
    throw "slow fnm prewarm blocked profile sourcing or did not remain running: $($sw.Elapsed.TotalMilliseconds)ms/$($script:State.Fnm.Status)"
}
if (Complete-FnmEnvironmentInitialization) { throw 'nonblocking fnm completion waited for a running process' }
if (-not (Complete-FnmEnvironmentInitialization -Wait) -or $script:State.Fnm.Status -cne 'Ready') {
    throw 'fnm prewarm result was not applied'
}
Set-Location $env:PWSH_FNM_VERSION_DIR
Update-FnmEnvironmentForPrompt
Update-FnmEnvironmentForPrompt
exit 0
'@
    Invoke-PwshChecked -Name 'FnmAsyncPrewarmSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $fnmPrewarmScript)
    $fnmCalls = @(Get-Content -LiteralPath $env:PWSH_FNM_LOG)
    if (@($fnmCalls | Where-Object { $_ -ceq 'env --json --resolve-engines=false' }).Count -ne 1 -or
        @($fnmCalls | Where-Object { $_ -ceq 'use --silent-if-unchanged' }).Count -ne 1) {
        throw "fnm async/reload/use calls were invalid: [$($fnmCalls -join '; ')]"
    }

    Clear-Content -LiteralPath $env:PWSH_FNM_LOG
    Set-Content -LiteralPath (Join-Path $fakeFnmDir 'fnm.cmd') -Encoding ASCII -Value "@echo off`r`necho %*>>`"%PWSH_FNM_LOG%`"`r`nexit /b 1"
    $fnmFailureScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
. $env:PWSH_PROFILE_SOURCE
$module = Get-Module PwshProfile -ErrorAction Stop
$fnmState = & $module { $script:State.Fnm }
if (-not (Test-Path function:\node) -or $fnmState.Status -cne 'NotStarted') { throw 'batch fnm wrapper/state was invalid' }
if (& $module { Initialize-FnmForUse }) { throw 'failed fnm initialization reported success' }
if ($fnmState.Status -cne 'Unavailable') { throw 'failed fnm initialization did not become unavailable' }
if (-not (Test-Path function:\icons) -or -not (Test-Path function:\grep)) { throw 'profile loading stopped after fnm failure' }
exit 0
'@
    Invoke-PwshChecked -Name 'FnmFailureSmoke' -Arguments @('-NoLogo', '-NoProfile', '-Command', $fnmFailureScript)
    $env:PATH = $oldPath

    $moduleLifecycleSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d\PwshProfile.psm1'
Set-Alias -Name ls -Value Get-ChildItem -Scope Global -Force
$global:PromptPrivateCollisionCalled = $false
function global:Disable-LeanPromptAsyncRedraw {
    $global:PromptPrivateCollisionCalled = $true
    throw 'global prompt helper collision was invoked'
}
foreach ($cycle in 1..10) {
    Import-Module $modulePath -Global -ArgumentList $true
    $module = Get-Module PwshProfile -ErrorAction Stop
    if ($global:PromptPrivateCollisionCalled) {
        throw "cycle $cycle invoked a same-named global prompt helper"
    }
    $restoreCallerState = {
        param([hashtable] $PriorAliases, [scriptblock] $DefaultTabExpansion2)
        foreach ($entry in $PriorAliases.GetEnumerator()) {
            $currentAlias = Get-Alias -Name $entry.Key -ErrorAction SilentlyContinue
            $currentFunction = Get-Command -Name $entry.Key -CommandType Function -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($currentAlias -or ($currentFunction -and $currentFunction.ModuleName -cne 'PwshProfile')) {
                continue
            }
            Set-Alias -Name $entry.Key -Value $entry.Value.Definition -Description $entry.Value.Description `
                -Option $entry.Value.Options -Scope Global -Force
        }
        $currentTabExpansion2 = Get-Command TabExpansion2 -CommandType Function -ErrorAction SilentlyContinue
        if ($DefaultTabExpansion2 -and
            (-not $currentTabExpansion2 -or $currentTabExpansion2.ModuleName -ceq 'PwshProfile')) {
            Set-Item Function:global:TabExpansion2 -Value $DefaultTabExpansion2 -Force
        }
    }
    & $module {
        param([scriptblock] $RestoreCallerState)
        $script:State.Resources.RestoreCallerState = $RestoreCallerState
    } $restoreCallerState
    if (@(Get-Module PwshProfile).Count -ne 1) { throw "cycle $cycle loaded duplicate profile modules" }
    & $module {
        if (-not (Start-LeanPromptGitWorker)) { throw 'module lifecycle worker did not start' }
        Enable-LeanPromptAsyncRedraw
    }
    $state = & $module { $script:State }
    $sourceId = $state.Prompt.__LeanPromptAsyncGitRedrawSourceId
    $cacheDir = $state.Prompt.__AsyncGitStatusCacheDir
    $prewarmSubscriptionId = $state.Completion.CompletionPrewarmSubscriptionId
    $exitSubscriptionId = $state.Prompt.__LeanPromptAsyncGitExitSubscriptionId
    $fnmProcess = if ($state.Fnm -is [hashtable]) { $state.Fnm.Process }
    $fnmProcessId = if ($fnmProcess) { try { $fnmProcess.Id } catch { $null } }

    Remove-Module PwshProfile -Force
    if (Get-Module PwshProfile) { throw "cycle $cycle did not remove the profile module" }
    if (-not $state.Resources.Stopped) { throw "cycle $cycle did not run module cleanup" }
    if (@(Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object {
                $_.SourceIdentifier.StartsWith("$sourceId.", [System.StringComparison]::Ordinal)
            }).Count) {
        throw "cycle $cycle leaked prompt event subscribers"
    }
    foreach ($subscriptionId in $prewarmSubscriptionId, $exitSubscriptionId) {
        if ($subscriptionId -and (Get-EventSubscriber -SubscriptionId $subscriptionId -ErrorAction SilentlyContinue)) {
            throw "cycle $cycle leaked event subscription $subscriptionId"
        }
    }
    if (Test-Path -LiteralPath $cacheDir) { throw "cycle $cycle leaked the prompt cache" }
    if ($state.Fnm.Process) { throw "cycle $cycle retained its fnm process reference" }
    if ($fnmProcessId -and (Get-Process -Id $fnmProcessId -ErrorAction SilentlyContinue)) {
        throw "cycle $cycle left fnm initialization process $fnmProcessId running"
    }
    $restoredAlias = Get-Alias -Name ls -ErrorAction Stop
    if ($restoredAlias.Definition -cne 'Get-ChildItem') { throw "cycle $cycle did not restore the ls alias" }
}

Import-Module $modulePath -Global -ArgumentList $true
$module = Get-Module PwshProfile -ErrorAction Stop
& $module {
    param([scriptblock] $RestoreCallerState)
    $script:State.Resources.RestoreCallerState = $RestoreCallerState
} $restoreCallerState
Set-Item Function:global:ls -Value { 'user-ls' } -Force
Set-Alias -Name pwd -Value Write-Output -Scope Global -Force
Set-Item Function:global:TabExpansion2 -Value { 'user-tab' } -Force
Remove-Module PwshProfile -Force
if ((& ls) -cne 'user-ls') { throw 'module cleanup replaced a newer user ls function' }
if ((Get-Alias pwd -ErrorAction Stop).Definition -cne 'Write-Output') {
    throw 'module cleanup replaced a newer user pwd alias'
}
if ((& TabExpansion2) -cne 'user-tab') { throw 'module cleanup replaced a newer user TabExpansion2 function' }
exit 0
'@
    Invoke-PwshChecked -Name 'ModuleLifecycleSmoke' -Arguments @(
        '-NoLogo', '-NoProfile', '-Command', $moduleLifecycleSmokeScript
    )

    $reloadLifecycleSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
. $env:PWSH_PROFILE_SOURCE
$expectedPath = ([Environment]::GetEnvironmentVariable('Path', 'Machine'),
                 [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'

foreach ($cycle in 1..10) {
    $previousModule = Get-Module PwshProfile -ErrorAction Stop
    $previousState = & $previousModule { $script:State }
    $env:PATH = "stale-path-$cycle"
    $reloadOutput = reload 6>&1 | Out-String
    $currentModule = Get-Module PwshProfile -ErrorAction Stop

    if ($env:PATH -cne $expectedPath) { throw "reload cycle $cycle did not refresh PATH" }
    if ($reloadOutput -notmatch 'env \+ profile reloaded\.') {
        throw "reload cycle $cycle did not report success"
    }
    if (@(Get-Module PwshProfile).Count -ne 1) {
        throw "reload cycle $cycle loaded duplicate profile modules"
    }
    if ([object]::ReferenceEquals($previousModule, $currentModule)) {
        throw "reload cycle $cycle reused the previous module instance"
    }
    if (-not $previousState.Resources.Stopped) {
        throw "reload cycle $cycle did not clean up the previous module instance"
    }
    if (& $currentModule { $script:State.Resources.Stopped }) {
        throw "reload cycle $cycle imported an already-stopped module instance"
    }
}

$entryVariables = @(
    'profileModulePath', 'profileModule', 'restoreProfileCallerState',
    'escapedProfileEntryPath', 'reloadScript'
)
$leakedEntryVariables = @(Get-Variable -Scope Global | Where-Object Name -In $entryVariables)
if ($leakedEntryVariables.Count) {
    throw "reload leaked entry variables: [$($leakedEntryVariables.Name -join ',')]"
}
Remove-Module PwshProfile -Force
if ((Get-Alias ls -ErrorAction Stop).Definition -cne 'Get-ChildItem') {
    throw 'reload lifecycle did not restore the original ls alias'
}
exit 0
'@
    Invoke-PwshChecked -Name 'ReloadLifecycleSmoke' -Arguments @(
        '-NoLogo', '-NoProfile', '-Command', $reloadLifecycleSmokeScript
    )

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
    Set-Content -LiteralPath (Join-Path $installSmokeProfile 'profile.d\98-test-module.psm1') -Value '# installer module fixture'
    Set-Content -LiteralPath (Join-Path $installSmokeProfile 'profile.d\99-invalid.psm1') -Value 'function Invalid-ProfilePart {'
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
    Remove-Item -LiteralPath (Join-Path $installSmokeProfile 'profile.d\99-invalid.psm1') -Force

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
    $gitUpdaterContractSmokeScript = @'
$ErrorActionPreference = 'Stop'
$root = $env:PWSH_GIT_UPDATER_CONTRACT_ROOT
$cachePath = Join-Path $root 'status.json'
$global:MockGitCalls = @()
$global:MockAhead = 6
$global:MockIsRepo = $true
New-Item -ItemType Directory -Force -Path $root | Out-Null

function global:git {
    $global:MockGitCalls += ,@($args)
    if ($args -contains 'status') {
        if (-not $global:MockIsRepo) {
            $global:LASTEXITCODE = 128
            return
        }
        @(
            '# branch.oid 0123456789abcdef0123456789abcdef01234567'
            '# branch.head main'
            '# branch.upstream origin/main'
            "# branch.ab +$($global:MockAhead) -7"
            '# stash 8'
            '1 M. N... 100644 100644 100644 1111111 2222222 staged.txt'
            '1 .M N... 100644 100644 100644 1111111 2222222 modified.txt'
            '? untracked.txt'
            '1 D. N... 100644 000000 000000 1111111 0000000 deleted.txt'
            "2 R. N... 100644 100644 100644 1111111 2222222 R100 renamed.txt`told.txt"
            'u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 conflict.txt'
        )
        $global:LASTEXITCODE = 0
        return
    }
    if ($args -contains 'rev-parse') {
        1..5 | ForEach-Object { Join-Path $root "missing$_" }
        $global:LASTEXITCODE = 0
        return
    }
    $global:LASTEXITCODE = 1
}

. $env:PWSH_GIT_UPDATER -Cwd $root -CachePath $cachePath -LockPath (Join-Path $root 'status.lock') `
    -SessionId contract -Generation 1
$status = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
if ($status.Branch -cne 'main' -or $status.Ahead -ne 6 -or $status.Behind -ne 7 -or $status.Stash -ne 8 -or
    $status.Staged -ne 2 -or $status.Modified -ne 1 -or $status.Untracked -ne 1 -or
    $status.Deleted -ne 1 -or $status.Renamed -ne 1 -or $status.Conflict -ne 1) {
    throw "porcelain v2 fixture was parsed incorrectly: $($status | ConvertTo-Json -Compress)"
}
$calls = @($global:MockGitCalls | ForEach-Object { $_ -join ' ' })
if ($calls.Count -ne 2 -or
    $calls[0] -notmatch 'status --porcelain=v2 --branch --show-stash --untracked-files=normal' -or
    $calls[1] -notmatch 'rev-parse --git-path rebase-merge') {
    throw "Git updater did not consolidate status plumbing: [$($calls -join '; ')]"
}

$firstWriteUtc = (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc
. $env:PWSH_GIT_UPDATER -Cwd $root -CachePath $cachePath -LockPath (Join-Path $root 'status.lock') `
    -SessionId contract -Generation 2
$unchanged = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
if ($unchanged.Generation -ne 1 -or (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc -ne $firstWriteUtc) {
    throw 'unchanged repository status rewrote the redraw cache'
}

$global:MockAhead = 9
. $env:PWSH_GIT_UPDATER -Cwd $root -CachePath $cachePath -LockPath (Join-Path $root 'status.lock') `
    -SessionId contract -Generation 3
$changed = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
if ($changed.Generation -ne 3 -or $changed.Ahead -ne 9) {
    throw 'changed repository status did not publish a new cache generation'
}

$global:MockIsRepo = $false
$negativePath = Join-Path $root 'negative.json'
. $env:PWSH_GIT_UPDATER -Cwd $root -CachePath $negativePath -LockPath (Join-Path $root 'negative.lock') `
    -SessionId contract -Generation 4
$negativeOldUtc = [datetime]::UtcNow.AddSeconds(-10)
(Get-Item -LiteralPath $negativePath).LastWriteTimeUtc = $negativeOldUtc
. $env:PWSH_GIT_UPDATER -Cwd $root -CachePath $negativePath -LockPath (Join-Path $root 'negative.lock') `
    -SessionId contract -Generation 5
$negative = Get-Content -LiteralPath $negativePath -Raw | ConvertFrom-Json
if ($negative.Generation -ne 4 -or (Get-Item -LiteralPath $negativePath).LastWriteTimeUtc -le $negativeOldUtc) {
    throw 'unchanged non-repository status did not refresh only its negative-cache timestamp'
}
'@
    $env:PWSH_GIT_UPDATER = $gitUpdater
    $env:PWSH_GIT_UPDATER_CONTRACT_ROOT = Join-Path $updaterRoot 'git-updater-contract'
    Invoke-PwshChecked -Name 'GitUpdaterContractSmoke' -Arguments @(
        '-NoLogo', '-NoProfile', '-Command', $gitUpdaterContractSmokeScript
    )
    $gitWorkerControlSmokeScript = @'
$ErrorActionPreference = 'Stop'
$root = $env:PWSH_GIT_UPDATER_CONTRACT_ROOT
$fakeGit = Join-Path $PSHOME 'pwsh.exe'
$oid = '0123456789abcdef0123456789abcdef01234567'

$supersedeMarker = Join-Path $root 'supersede-started'
$supersededCache = Join-Path $root 'superseded.json'
$latestCache = Join-Path $root 'latest.json'
$markerLiteral = $supersedeMarker.Replace("'", "''")
$hangCommand = "Set-Content -LiteralPath '$markerLiteral' -Value started; Start-Sleep -Seconds 10; exit 0 #"
$completeCommand = "Write-Output '# branch.oid $oid'; Write-Output '# branch.head main'; exit 0 #"
$queue = [System.Collections.Concurrent.BlockingCollection[object]]::new(1)
$worker = [powershell]::Create()
$asyncResult = $null
try {
    $queue.Add([pscustomobject]@{
        Cwd = $hangCommand; CachePath = $supersededCache; SessionId = 'control'; Generation = 1L
    })
    $null = $worker.AddCommand($env:PWSH_GIT_UPDATER).
        AddParameter('RequestQueue', $queue).
        AddParameter('GitExecutable', $fakeGit).
        AddParameter('GitStatusTimeoutMilliseconds', 5000)
    $asyncResult = $worker.BeginInvoke()

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $supersedeMarker) -and $stopwatch.ElapsedMilliseconds -lt 4000) {
        Start-Sleep -Milliseconds 10
    }
    if (-not (Test-Path -LiteralPath $supersedeMarker)) { throw 'fake Git status did not start' }

    $stopwatch.Restart()
    if (-not $queue.TryAdd([pscustomobject]@{
                Cwd = $completeCommand; CachePath = $latestCache; SessionId = 'control'; Generation = 2L
            }, 1000)) {
        throw 'latest Git request could not be queued'
    }
    $queue.CompleteAdding()
    if (-not $asyncResult.AsyncWaitHandle.WaitOne(5000)) { throw 'superseded Git status process was not cancelled' }
    $null = $worker.EndInvoke($asyncResult)
    if ($worker.Streams.Error.Count) { throw [string]$worker.Streams.Error[0] }
    if ($stopwatch.ElapsedMilliseconds -ge 3000) { throw 'latest Git request waited too long for the superseded process' }
    if (Test-Path -LiteralPath $supersededCache) { throw 'superseded Git request published stale cache data' }
    $latest = Get-Content -LiteralPath $latestCache -Raw | ConvertFrom-Json
    if ($latest.Generation -ne 2 -or $latest.Branch -cne 'main') {
        throw 'latest Git request did not publish after cancelling its predecessor'
    }
}
finally {
    try { if ($asyncResult -and -not $asyncResult.IsCompleted) { $worker.BeginStop($null, $null) | Out-Null } } catch {}
    $worker.Dispose()
    $queue.Dispose()
}

$retryMarker = Join-Path $root 'retry-started'
$retryCache = Join-Path $root 'retry.json'
$markerLiteral = $retryMarker.Replace("'", "''")
$retryCommand = "if (Test-Path -LiteralPath '$markerLiteral') { Write-Output '# branch.oid $oid'; Write-Output '# branch.head main'; Write-Output '? ignored.txt'; exit 0 }; Set-Content -LiteralPath '$markerLiteral' -Value started; Start-Sleep -Seconds 10; exit 0 #"
$request = [pscustomobject]@{
    Cwd = $retryCommand; CachePath = $retryCache; SessionId = 'control'; Generation = 3L
}
$queue = [System.Collections.Concurrent.BlockingCollection[object]]::new(1)
$worker = [powershell]::Create()
$asyncResult = $null
try {
    $queue.Add($request)
    $null = $worker.AddCommand($env:PWSH_GIT_UPDATER).
        AddParameter('RequestQueue', $queue).
        AddParameter('GitExecutable', $fakeGit).
        AddParameter('GitStatusTimeoutMilliseconds', 2000)
    $asyncResult = $worker.BeginInvoke()

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $retryCache) -and $stopwatch.ElapsedMilliseconds -lt 7000) {
        Start-Sleep -Milliseconds 10
    }
    if (-not (Test-Path -LiteralPath $retryCache)) { throw 'timed-out Git status was not retried once' }
    $retried = Get-Content -LiteralPath $retryCache -Raw | ConvertFrom-Json
    if ($retried.Generation -ne 3 -or $retried.Branch -cne 'main' -or
        $retried.Untracked -ne -1 -or [int]$request.Attempt -ne 1) {
        throw 'Git timeout retry contract is invalid'
    }

    $rememberedCache = Join-Path $root 'remembered-slow.json'
    if (-not $queue.TryAdd([pscustomobject]@{
                Cwd = $retryCommand; CachePath = $rememberedCache; SessionId = 'control'; Generation = 4L
            }, 1000)) {
        throw 'remembered slow Git request could not be queued'
    }
    $stopwatch.Restart()
    while (-not (Test-Path -LiteralPath $rememberedCache) -and $stopwatch.ElapsedMilliseconds -lt 4000) {
        Start-Sleep -Milliseconds 10
    }
    if (-not (Test-Path -LiteralPath $rememberedCache)) { throw 'slow Git path was not reused' }
    $remembered = Get-Content -LiteralPath $rememberedCache -Raw | ConvertFrom-Json
    if ($remembered.Generation -ne 4 -or $remembered.Untracked -ne -1) {
        throw 'slow Git path did not retain the reduced scan mode'
    }

    $queue.CompleteAdding()
    if (-not $asyncResult.AsyncWaitHandle.WaitOne(3000)) { throw 'Git retry worker did not stop' }
    $null = $worker.EndInvoke($asyncResult)
    if ($worker.Streams.Error.Count) { throw [string]$worker.Streams.Error[0] }
}
finally {
    try { if (-not $queue.IsAddingCompleted) { $queue.CompleteAdding() } } catch {}
    try { if ($asyncResult -and -not $asyncResult.IsCompleted) { $worker.BeginStop($null, $null) | Out-Null } } catch {}
    $worker.Dispose()
    $queue.Dispose()
}
'@
    Invoke-PwshChecked -Name 'GitWorkerControlSmoke' -Arguments @(
        '-NoLogo', '-NoProfile', '-Command', $gitWorkerControlSmokeScript
    )
    $gitPromptBranchSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. $env:PWSH_PROFILE_SOURCE
$module = Get-Module PwshProfile -ErrorAction Stop
& $module {
$script:State.Session.IsInteractive = $true
. (Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d\30-psreadline.ps1')
Disable-LeanPromptAsyncRedraw

$repo = $env:PWSH_GIT_PROMPT_ROOT
$seedCachePath = $env:PWSH_GIT_PROMPT_SEED
$cacheDir = Join-Path (Split-Path -Parent $seedCachePath) (([System.IO.Path]::GetFileNameWithoutExtension($seedCachePath)) + '-prompt')
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
Set-Location $repo
$script:State.Prompt.__AsyncGitStatusCacheDir = $cacheDir
$script:State.Prompt.LeanPromptSymbolSet = 'ascii'
$global:__GitPromptCacheStamp = 0
$global:__GitPromptRefreshes = 0

function script:Start-AsyncGitStatusRefresh {
    param($Path, $CachePath, $LockPath)
    $global:__GitPromptRefreshes++
}

$key = Get-AsyncStatusKey -Path $repo
$cachePath = Join-Path $cacheDir "$key.json"
$status = Get-Content -LiteralPath $seedCachePath -Raw | ConvertFrom-Json

function Write-TestGitPromptCache([string]$Branch, [int]$Staged) {
    $status.Path = $repo
    $status.Branch = $Branch
    $status.Staged = $Staged
    $status | ConvertTo-Json -Compress | Set-Content -LiteralPath $cachePath -Encoding UTF8
    $global:__GitPromptCacheStamp++
    (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds($global:__GitPromptCacheStamp)
}

Write-TestGitPromptCache -Branch 'main' -Staged 7
$warm = Remove-LeanPromptAnsi (Get-AsyncGitStatusText)
if ($warm -notmatch 'git main' -or $warm -notmatch '\+7' -or $global:__GitPromptRefreshes -ne 0) {
    throw "Git prompt cache did not warm from main: [$warm]"
}

$gitExe = @(Get-Command git -CommandType Application -ErrorAction Stop)[0].Source
$global:LASTEXITCODE = 67
$nativeBranch = Get-LeanPromptGitBranch -Path $repo
if ($nativeBranch -cne 'main' -or $global:LASTEXITCODE -ne 67) {
    throw "native attached branch probe was affected by the previous exit code: branch=[$nativeBranch] exit=$global:LASTEXITCODE"
}
$script:State.Prompt.__LeanPromptGitBranchRefreshPending = $false
if (-not (Update-LeanPromptAcceptedLineState -Line 'git switch --quiet -c prompt-feature') -or
    -not $script:State.Prompt.__LeanPromptGitBranchRefreshPending) {
    throw 'accepted switch command did not request an immediate branch refresh'
}
& $gitExe -C $repo switch --quiet -c prompt-feature *> $null
if ($global:LASTEXITCODE -ne 0) { throw 'failed to switch Git prompt smoke branch' }

$global:__GitPromptExecutable = $gitExe
$global:__GitPromptCalls = @()
function script:git {
    if ($args -contains 'status' -or $args -contains 'diff' -or $args -contains 'rev-list') {
        throw "prompt made a synchronous Git status call: $args"
    }
    $global:__GitPromptCalls += ($args -join ' ')
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & $global:__GitPromptExecutable @args
    $exitCode = $global:LASTEXITCODE
    $output
    $global:LASTEXITCODE = $exitCode
}

$global:LASTEXITCODE = 73
$immediate = Get-AsyncGitStatusText
if ($global:LASTEXITCODE -ne 73) { throw 'synchronous branch refresh changed LASTEXITCODE' }
$immediatePlain = Remove-LeanPromptAnsi $immediate
if ($immediatePlain -notmatch 'git prompt-feature' -or $immediatePlain -match 'git main|\+7') {
    throw "switched branch prompt reused stale cache: [$immediatePlain]"
}
if ($global:__GitPromptCalls.Count -ne 1 -or $global:__GitPromptCalls[0] -notmatch 'rev-parse --abbrev-ref HEAD') {
    throw "attached branch prompt used unexpected Git plumbing: [$($global:__GitPromptCalls -join '; ')]"
}
if ($global:__GitPromptRefreshes -ne 1 -or -not $script:State.Prompt.__LeanPromptGitBranchOverride -or
    $script:State.Prompt.__LeanPromptGitBranchOverride.Branch -cne 'prompt-feature') {
    throw 'attached branch override was not retained while cache was stale'
}
$diskStatus = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
if ($diskStatus.Branch -cne 'main') { throw 'synchronous branch refresh modified the async cache' }

$repeatPlain = Remove-LeanPromptAnsi (Get-AsyncGitStatusText)
if ($repeatPlain -notmatch 'git prompt-feature' -or $repeatPlain -match 'git main|\+7' -or $global:__GitPromptCalls.Count -ne 1) {
    throw "branch override was not reused without another Git call: [$repeatPlain]"
}

Write-TestGitPromptCache -Branch 'prompt-feature' -Staged 3
$caughtUpPlain = Remove-LeanPromptAnsi (Get-AsyncGitStatusText)
if ($caughtUpPlain -notmatch 'git prompt-feature' -or $caughtUpPlain -notmatch '\+3' -or $script:State.Prompt.__LeanPromptGitBranchOverride) {
    throw "matching async cache did not replace the branch override: [$caughtUpPlain]"
}

$script:State.Prompt.__LeanPromptGitBranchRefreshPending = $false
if (-not (Update-LeanPromptAcceptedLineState -Line 'git switch --quiet --detach HEAD') -or
    -not $script:State.Prompt.__LeanPromptGitBranchRefreshPending) {
    throw 'accepted detach command did not request an immediate branch refresh'
}
& $gitExe -C $repo switch --quiet --detach HEAD *> $null
if ($global:LASTEXITCODE -ne 0) { throw 'failed to detach Git prompt smoke repository' }
$shortHead = (& $gitExe -C $repo rev-parse --short HEAD | Select-Object -First 1).Trim()
$global:LASTEXITCODE = 91
$detached = Get-AsyncGitStatusText
if ($global:LASTEXITCODE -ne 91) { throw 'detached branch refresh changed LASTEXITCODE' }
$detachedPlain = Remove-LeanPromptAnsi $detached
if ($detachedPlain -notmatch "git $([regex]::Escape($shortHead))" -or $detachedPlain -match 'git prompt-feature|\+3') {
    throw "detached HEAD prompt is invalid: [$detachedPlain]"
}
if ($global:__GitPromptCalls.Count -ne 3 -or
    $global:__GitPromptCalls[1] -notmatch 'rev-parse --abbrev-ref HEAD' -or
    $global:__GitPromptCalls[2] -notmatch 'rev-parse --short HEAD') {
    throw "detached branch prompt used unexpected Git plumbing: [$($global:__GitPromptCalls -join '; ')]"
}

& $gitExe -C $repo switch --quiet -c prompt-external *> $null
if ($global:LASTEXITCODE -ne 0) { throw 'failed to switch externally during Git prompt smoke' }
Write-TestGitPromptCache -Branch 'prompt-external' -Staged 4
$global:LASTEXITCODE = 109
$external = Get-AsyncGitStatusText
if ($global:LASTEXITCODE -ne 109) { throw 'external branch convergence changed LASTEXITCODE' }
$externalPlain = Remove-LeanPromptAnsi $external
if ($externalPlain -notmatch 'git prompt-external' -or $externalPlain -notmatch '\+4' -or $script:State.Prompt.__LeanPromptGitBranchOverride) {
    throw "new async cache did not converge an older branch override: [$externalPlain]"
}
if ($global:__GitPromptCalls.Count -ne 4 -or $global:__GitPromptCalls[3] -notmatch 'rev-parse --abbrev-ref HEAD') {
    throw "external branch convergence used unexpected Git plumbing: [$($global:__GitPromptCalls -join '; ')]"
}

$nonRepo = Join-Path $cacheDir 'not-a-repository'
New-Item -ItemType Directory -Force -Path $nonRepo | Out-Null
$callsBefore = $global:__GitPromptCalls.Count
$global:LASTEXITCODE = 113
$nonRepoBranch = Get-LeanPromptGitBranch -Path $nonRepo
$nonRepoCalls = @($global:__GitPromptCalls | Select-Object -Skip $callsBefore)
if ($nonRepoBranch -or $global:LASTEXITCODE -ne 113 -or $nonRepoCalls.Count -ne 1 -or
    $nonRepoCalls[0] -notmatch 'rev-parse --abbrev-ref HEAD') {
    throw "non-repository branch probe was not a single plumbing call: branch=[$nonRepoBranch] exit=$global:LASTEXITCODE calls=[$($nonRepoCalls -join '; ')]"
}

& $gitExe -C $repo switch --quiet --orphan prompt-unborn *> $null
if ($global:LASTEXITCODE -ne 0) { throw 'failed to create unborn Git prompt branch' }
$callsBefore = $global:__GitPromptCalls.Count
$global:LASTEXITCODE = 127
$unbornBranch = Get-LeanPromptGitBranch -Path $repo
$unbornCalls = @($global:__GitPromptCalls | Select-Object -Skip $callsBefore)
if ($unbornBranch -cne 'prompt-unborn' -or $global:LASTEXITCODE -ne 127 -or $unbornCalls.Count -ne 2 -or
    $unbornCalls[0] -notmatch 'rev-parse --abbrev-ref HEAD' -or
    $unbornCalls[1] -notmatch 'symbolic-ref --quiet --short HEAD') {
    throw "unborn branch probe contract is invalid: branch=[$unbornBranch] exit=$global:LASTEXITCODE calls=[$($unbornCalls -join '; ')]"
}
}
exit 0
'@
$gitWorkerSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. $env:PWSH_PROFILE_SOURCE
$module = Get-Module PwshProfile -ErrorAction Stop
& $module {
$script:State.Session.IsInteractive = $true

$repo = $env:PWSH_GIT_PROMPT_ROOT
$cacheDir = $env:PWSH_GIT_WORKER_CACHE
$dirtyFile = Join-Path $repo 'worker-dirty.txt'
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
Set-Location $repo
$script:State.Prompt.__AsyncGitStatusCacheDir = $cacheDir
$script:State.Prompt.__AsyncGitStatusSessionId = 'worker-smoke'
$script:State.Prompt.__LeanPromptGitGeneration = 7L
$script:State.Prompt.__LeanPromptGitRequestedPath = $null
$script:State.Prompt.__LeanPromptGitRequestedGeneration = -1L
$script:State.Prompt.__LeanPromptGitCompletedPath = $null
$script:State.Prompt.__LeanPromptGitCompletedGeneration = -1L
$script:State.Prompt.__AsyncGitStatusMemoryPath = $null

function Wait-TestGitGeneration([long]$Generation) {
    $key = Get-AsyncStatusKey -Path $repo
    $cachePath = Join-Path $cacheDir "$key.json"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.ElapsedMilliseconds -lt 3000) {
        try {
            $status = Get-Content -LiteralPath $cachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($status.SessionId -ceq 'worker-smoke' -and [long]$status.Generation -eq $Generation) { return $status }
        }
        catch {}
        Start-Sleep -Milliseconds 10
    }
    throw "Git worker did not publish generation $Generation (requested=$script:State.Prompt.__LeanPromptGitRequestedGeneration completed=$script:State.Prompt.__LeanPromptGitCompletedGeneration)"
}

try {
    Set-Content -LiteralPath $dirtyFile -Value 'dirty'
    $null = Get-AsyncGitStatusText
    $status = Wait-TestGitGeneration 7
    if (-not $status.IsRepo -or $status.Untracked -ne 1) { throw 'Git worker initial result was invalid' }
    $freshDirty = Get-AsyncGitStatusText
    if ((Remove-LeanPromptAnsi $freshDirty) -notmatch '\?1' -or $freshDirty -notmatch "`e\[38;5;39m") {
        throw 'current Git worker result was not rendered as fresh'
    }

    Remove-Item -LiteralPath $dirtyFile -Force
    $script:State.Prompt.__LeanPromptGitGeneration = 8L
    $cachedDirty = Get-AsyncGitStatusText
    if ((Remove-LeanPromptAnsi $cachedDirty) -notmatch '\?1' -or $cachedDirty -notmatch "`e\[38;5;39m") {
        throw 'previous Git generation was not retained in color while refresh was pending'
    }
    $null = Wait-TestGitGeneration 8
    $freshClean = Get-AsyncGitStatusText
    if ((Remove-LeanPromptAnsi $freshClean) -match '\?1') {
        throw 'fresh clean Git generation did not replace stale status'
    }

    $key = Get-AsyncStatusKey -Path $repo
    $cachePath = Join-Path $cacheDir "$key.json"
    $regressed = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
    $regressed.Generation = 7
    $regressed | ConvertTo-Json -Compress | Set-Content -LiteralPath $cachePath -Encoding UTF8
    $script:State.Prompt.__AsyncGitStatusMemoryLastWriteTimeUtc = [datetime]::MinValue
    Set-Content -LiteralPath $dirtyFile -Value 'dirty again'
    $null = Get-AsyncGitStatusText
    $retried = Wait-TestGitGeneration 8
    if ($retried.Untracked -ne 1) { throw 'regressed Git generation was not retried with current status' }
    $null = Get-AsyncGitStatusText
}
finally {
    Stop-LeanPromptGitWorker
    Remove-Item -LiteralPath $dirtyFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $cacheDir -Recurse -Force -ErrorAction SilentlyContinue
}
}
'@
    $gitLifecycleSmokeScript = @'
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Stop'
. $env:PWSH_PROFILE_SOURCE
$module = Get-Module PwshProfile -ErrorAction Stop
& $module {
$script:State.Session.IsInteractive = $true
Import-Module PSReadLine

$cacheDir = $env:PWSH_GIT_LIFECYCLE_CACHE
$script:State.Prompt.__AsyncGitStatusCacheDir = $cacheDir
$script:State.Prompt.__AsyncToolchainStatusCacheDir = "$cacheDir-toolchain"
$script:State.Prompt.__AsyncGitStatusSessionId = 'lifecycle-smoke'
try {
    if (-not (Start-LeanPromptGitWorker)) { throw 'Git worker lifecycle smoke did not start the worker' }
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.InputActive = $true
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.PromptCompletedUtc = [datetime]::UtcNow.AddSeconds(-1)
    $oldAsyncResult = $script:State.Prompt.__AsyncGitStatusWorkerAsyncResult
    $oldSourceId = $script:State.Prompt.__LeanPromptAsyncGitRedrawSourceId
    $oldExitSubscriptionId = $script:State.Prompt.__LeanPromptAsyncGitExitSubscriptionId
    $redrawSubscribers = @(Get-EventSubscriber | Where-Object {
        $_.SourceIdentifier.StartsWith("$oldSourceId.", [System.StringComparison]::Ordinal)
    })
    $watcherSubscribers = @($redrawSubscribers | Where-Object SourceIdentifier -Like '*.Renamed')
    $dispatchSubscribers = @($redrawSubscribers | Where-Object SourceIdentifier -Like '*.Dispatch')
    if ($watcherSubscribers.Count -ne 2 -or
        @($watcherSubscribers | Where-Object { $_.Action.Command -notmatch 'Timer\.Start' }).Count -or
        $dispatchSubscribers.Count -ne 1 -or
        $dispatchSubscribers[0].Action.Command -notmatch 'PSConsoleReadLine\]::InvokePrompt') {
        throw 'Git worker did not register the expected prompt redraw watchers'
    }
    if (-not $oldExitSubscriptionId -or
        -not (Get-EventSubscriber -SubscriptionId $oldExitSubscriptionId -ErrorAction SilentlyContinue)) {
        throw 'Git worker did not register session cache cleanup'
    }

    $cachePath = Join-Path $cacheDir 'status.json'
    $script:State.Prompt.__LeanPromptAsyncGitRedrawState.CachePath = $cachePath
    $toolchainCachePath = Join-Path $script:State.Prompt.__AsyncToolchainStatusCacheDir 'status.json'
    $script:State.Prompt.__LeanPromptAsyncToolchainRedrawState.CachePath = $toolchainCachePath
    $generationBeforeCacheRedraw = [long]$script:State.Prompt.__LeanPromptGitGeneration
    Start-Sleep -Milliseconds 100
    $tempPath = "$cachePath.tmp"
    Set-Content -LiteralPath $tempPath -Value '{}'
    [System.IO.File]::Move($tempPath, $cachePath, $true)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -lt 1 -and
        $stopwatch.ElapsedMilliseconds -lt 2000) {
        Start-Sleep -Milliseconds 10
    }
    if ([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -lt 1) {
        throw 'Git cache update did not trigger the prompt redraw action'
    }
    if ([long]$script:State.Prompt.__LeanPromptGitGeneration -ne $generationBeforeCacheRedraw -or
        $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.CacheDriven) {
        throw 'cache-driven prompt redraw advanced the Git generation or retained its redraw marker'
    }

    $firstRedrawCount = [long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count
    $firstGitEventUtc = [datetime]$script:State.Prompt.__LeanPromptAsyncGitRedrawState.LastUtc
    $toolchainTempPath = "$toolchainCachePath.tmp"
    Set-Content -LiteralPath $tempPath -Value '{"Generation":2}'
    [System.IO.File]::Move($tempPath, $cachePath, $true)
    Set-Content -LiteralPath $toolchainTempPath -Value '{"Text":"py 3.13"}'
    [System.IO.File]::Move($toolchainTempPath, $toolchainCachePath, $true)
    $stopwatch.Restart()
    while (([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -le $firstRedrawCount -or
            [datetime]$script:State.Prompt.__LeanPromptAsyncGitRedrawState.LastUtc -le $firstGitEventUtc -or
            [datetime]$script:State.Prompt.__LeanPromptAsyncToolchainRedrawState.LastUtc -eq [datetime]::MinValue) -and
        $stopwatch.ElapsedMilliseconds -lt 2000) {
        Start-Sleep -Milliseconds 10
    }
    Start-Sleep -Milliseconds 100
    if ([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -ne ($firstRedrawCount + 1) -or
        [datetime]$script:State.Prompt.__LeanPromptAsyncGitRedrawState.LastUtc -le $firstGitEventUtc -or
        [datetime]$script:State.Prompt.__LeanPromptAsyncToolchainRedrawState.LastUtc -eq [datetime]::MinValue) {
        throw 'Git and toolchain cache updates were not merged into one prompt redraw'
    }

    $redrawCountBeforeCompletion = [long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.CompletionActive = $true
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Pending = $true
    $script:State.Prompt.__LeanPromptAsyncRedrawTimer.Interval = 25
    $script:State.Prompt.__LeanPromptAsyncRedrawTimer.Start()
    Start-Sleep -Milliseconds 100
    if ([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -ne $redrawCountBeforeCompletion -or
        -not $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Pending) {
        throw 'completion did not defer async prompt redraw'
    }
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.CompletionActive = $false
    $script:State.Prompt.__LeanPromptAsyncRedrawTimer.Start()
    $stopwatch.Restart()
    while ([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -le $redrawCountBeforeCompletion -and
        $stopwatch.ElapsedMilliseconds -lt 2000) {
        Start-Sleep -Milliseconds 10
    }
    if ([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -ne ($redrawCountBeforeCompletion + 1) -or
        $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Pending) {
        throw 'deferred completion redraw did not resume'
    }

    $queuedKeys = [System.Collections.Queue]::new()
    $queuedKeys.Enqueue('pending')
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.QueuedKeys = $queuedKeys
    $redrawCountBeforeQueuedKey = [long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Pending = $true
    $script:State.Prompt.__LeanPromptAsyncRedrawTimer.Start()
    Start-Sleep -Milliseconds 100
    if ([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -ne $redrawCountBeforeQueuedKey -or
        -not $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Pending) {
        throw 'queued input did not defer async prompt redraw'
    }
    $null = $queuedKeys.Dequeue()
    $stopwatch.Restart()
    while ([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -le $redrawCountBeforeQueuedKey -and
        $stopwatch.ElapsedMilliseconds -lt 2000) {
        Start-Sleep -Milliseconds 10
    }
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.QueuedKeys = $null
    if ([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -ne ($redrawCountBeforeQueuedKey + 1) -or
        $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Pending) {
        throw 'deferred queued-input redraw did not resume'
    }

    $redrawCountBeforeCommand = [long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count
    $lastGitEventUtc = [datetime]$script:State.Prompt.__LeanPromptAsyncGitRedrawState.LastUtc
    $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.InputActive = $false
    Set-Content -LiteralPath $tempPath -Value '{"Generation":3}'
    [System.IO.File]::Move($tempPath, $cachePath, $true)
    $stopwatch.Restart()
    while ([datetime]$script:State.Prompt.__LeanPromptAsyncGitRedrawState.LastUtc -le $lastGitEventUtc -and
        $stopwatch.ElapsedMilliseconds -lt 2000) {
        Start-Sleep -Milliseconds 10
    }
    $stopwatch.Restart()
    while ($script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Pending -and $stopwatch.ElapsedMilliseconds -lt 2000) {
        Start-Sleep -Milliseconds 10
    }
    if ([long]$script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count -ne $redrawCountBeforeCommand -or
        $script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Pending) {
        throw "cache update redrew the prompt while a command was running: before=$redrawCountBeforeCommand after=$($script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Count) pending=$($script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Pending) input=$($script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.InputActive) rendering=$($script:State.Prompt.__LeanPromptAsyncRedrawDispatchState.Rendering)"
    }

    . (Join-Path (Split-Path -Parent $env:PWSH_PROFILE_SOURCE) 'profile.d\10-prompt.ps1')
    $null = $oldAsyncResult.AsyncWaitHandle.WaitOne(1000)
    if (-not $oldAsyncResult.IsCompleted) { throw 'profile reload left the previous Git worker running' }
    if (Test-Path -LiteralPath $cacheDir) { throw 'profile reload left the previous Git cache directory behind' }
    if (@(Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object {
            $_.SourceIdentifier.StartsWith("$oldSourceId.", [System.StringComparison]::Ordinal)
        }).Count) {
        throw 'profile reload left previous Git redraw subscriptions behind'
    }
    if (Get-EventSubscriber -SubscriptionId $oldExitSubscriptionId -ErrorAction SilentlyContinue) {
        throw 'profile reload left the previous Git exit subscription behind'
    }
}
finally {
    Disable-LeanPromptAsyncRedraw
}
}
'@
    $env:PWSH_GIT_LIFECYCLE_CACHE = Join-Path $updaterRoot 'git-lifecycle-cache'
    Invoke-PwshChecked -Name 'GitWorkerLifecycleSmoke' -Arguments @(
        '-NoLogo', '-NoProfile', '-Command', $gitLifecycleSmokeScript
    )
    $env:PWSH_GIT_EXIT_CACHE = Join-Path $updaterRoot 'git-exit-cache'
    $gitExitCleanupSmokeScript = @'
. $env:PWSH_PROFILE_SOURCE
$module = Get-Module PwshProfile -ErrorAction Stop
& $module {
$script:State.Session.IsInteractive = $true
Import-Module PSReadLine
$script:State.Prompt.__AsyncGitStatusCacheDir = $env:PWSH_GIT_EXIT_CACHE
if (-not (Start-LeanPromptGitWorker)) { exit 1 }
Set-Content -LiteralPath (Join-Path $script:State.Prompt.__AsyncGitStatusCacheDir 'sentinel.json') -Value '{}'
}
exit 0
'@
    Invoke-PwshChecked -Name 'GitWorkerExitCleanupSmoke' -Arguments @(
        '-NoLogo', '-NoProfile', '-Command', $gitExitCleanupSmokeScript
    )
    if (Test-Path -LiteralPath $env:PWSH_GIT_EXIT_CACHE) {
        throw 'PowerShell exit left the Git cache directory behind'
    }

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
        $env:PWSH_GIT_WORKER_CACHE = Join-Path $updaterRoot "$cacheName-worker"
        Invoke-PwshChecked -Name "$($gitCase.Name)GitWorkerSmoke" -Arguments @(
            '-NoLogo', '-NoProfile', '-Command', $gitWorkerSmokeScript
        )
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
    $toolUpdated = [string]$toolStatus.Updated
    (Get-Item -LiteralPath $toolCache).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-1)
    $oldToolWriteUtc = (Get-Item -LiteralPath $toolCache).LastWriteTimeUtc
    New-Item -ItemType File -Path $toolLock | Out-Null
    Invoke-PwshChecked -Name 'ToolchainUpdaterUnchangedSmoke' -Arguments @(
        '-NoLogo', '-NoProfile', '-File', (Join-Path $profilePartsDir 'prompt-updaters\Update-AsyncToolchainStatus.ps1'),
        '-Cwd', $toolProject, '-CachePath', $toolCache, '-LockPath', $toolLock
    )
    $unchangedToolStatus = Get-Content -LiteralPath $toolCache -Raw | ConvertFrom-Json
    if ([string]$unchangedToolStatus.Updated -cne $toolUpdated -or
        (Get-Item -LiteralPath $toolCache).LastWriteTimeUtc -le $oldToolWriteUtc) {
        throw 'unchanged toolchain status rewrote the redraw cache instead of refreshing its TTL'
    }
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
        Env:PWSH_WINGET_LOG, Env:PWSH_WINGET_PATH, Env:PWSH_FNM_LOG, `
        Env:PWSH_CARAPACE_LOG, Env:PWSH_CARAPACE_TEST_LOCALAPPDATA, Env:PWSH_CARAPACE_EMPTY_PATH, `
        Env:PWSH_CARAPACE_PWSH, Env:PWSH_CARAPACE_MODE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
