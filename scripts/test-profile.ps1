[CmdletBinding()]
param(
    [ValidateRange(1, 50)]
    [int]$Runs = 5
)

$ErrorActionPreference = 'Stop'

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
    DirectEza = $content -match '(?s)function\s+ls\s*\{.*?\beza\b'
    DirectBat = $content -match '(?s)function\s+cat\s*\{.*?\bbat\b'
    DirectRg = $content -match '(?s)function\s+grep\s*\{.*?\brg\b'
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

function Measure-PwshStartup {
    param(
        [string]$Name,
        [string[]]$Arguments
    )

    $samples = for ($i = 0; $i -lt $Runs; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $pwsh @Arguments | Out-Null
        $sw.Stop()
        [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    }

    [pscustomobject]@{
        Name = $Name
        Runs = $Runs
        AverageMs = [math]::Round(($samples | Measure-Object -Average).Average, 1)
        SamplesMs = ($samples -join ', ')
    }
}

Measure-PwshStartup -Name 'NoProfile' -Arguments @('-NoLogo', '-NoProfile', '-Command', '$null')
Measure-PwshStartup -Name 'CurrentProfile' -Arguments @('-NoLogo', '-Command', '$null')

