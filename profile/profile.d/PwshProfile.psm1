param([switch] $ForceInteractive)

$script:State = @{
    SchemaVersion = 1
    Session = @{}
    Fnm = $null
    Prompt = @{}
    Completion = @{}
    Resources = @{
        Stopped = $false
        PriorAliases = @{}
        DefaultTabExpansion2 = $null
        RestoreCallerState = $null
    }
}

foreach ($alias in @(Get-Alias -Name 'ls', 'pwd', 'cat', 'curl', 'wget' -ErrorAction SilentlyContinue)) {
    $script:State.Resources.PriorAliases[$alias.Name] = @{
        Definition = $alias.Definition
        Description = $alias.Description
        Options = $alias.Options
    }
}

function Stop-PwshProfileRuntime {
    if ($script:State.Resources.Stopped) { return }
    $script:State.Resources.Stopped = $true

    if (Get-Command Disable-LeanPromptAsyncRedraw -CommandType Function -ErrorAction SilentlyContinue) {
        Disable-LeanPromptAsyncRedraw
    }

    $fnmProcess = if ($script:State.Fnm -is [hashtable]) { $script:State.Fnm.Process }
    if ($fnmProcess) {
        try {
            if (-not $fnmProcess.HasExited) {
                $fnmProcess.Kill($true)
                [void] $fnmProcess.WaitForExit(1000)
            }
        }
        catch {}
        finally { try { $fnmProcess.Dispose() } catch {} }
        $script:State.Fnm.Process = $null
    }

    $completion = $script:State.Completion
    if ($completion.CompletionPrewarmSubscriptionId) {
        $subscriber = Get-EventSubscriber -SubscriptionId $completion.CompletionPrewarmSubscriptionId -ErrorAction SilentlyContinue
        if ($subscriber) {
            $actionJob = $subscriber.Action
            Unregister-Event -SubscriptionId $subscriber.SubscriptionId -Force -ErrorAction SilentlyContinue
            if ($actionJob) { Remove-Job -Job $actionJob -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($completion.CompletionPrewarmJobId) {
        Remove-Job -Id $completion.CompletionPrewarmJobId -Force -ErrorAction SilentlyContinue
    }

    if ($script:State.Resources.RestoreCallerState) {
        & $script:State.Resources.RestoreCallerState `
            $script:State.Resources.PriorAliases `
            $script:State.Resources.DefaultTabExpansion2
    }
}

$ExecutionContext.SessionState.Module.OnRemove = { Stop-PwshProfileRuntime }

$script:State.Session.CommandLine = [Environment]::GetCommandLineArgs()
$script:State.Session.IsBatch = [bool]($script:State.Session.CommandLine -match '(?i)^-(Command|c|File|f|EncodedCommand|ec)$')
$script:State.Session.HasNoExit = [bool]($script:State.Session.CommandLine -match '(?i)^-(NoExit|noe)$')
$script:State.Session.IsInteractive = $ForceInteractive -or (
    $Host.Name -eq 'ConsoleHost' -and
    -not [Console]::IsInputRedirected -and
    -not [Console]::IsOutputRedirected -and
    (-not $script:State.Session.IsBatch -or $script:State.Session.HasNoExit)
)
if ($script:State.Session.IsInteractive) {
    $script:State.Resources.DefaultTabExpansion2 =
        (Get-Command TabExpansion2 -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
}

$profileParts = @(
    '20-node.ps1',
    '10-prompt.ps1',
    '25-icons.ps1'
    if ($script:State.Session.IsInteractive) {
        '30-psreadline.ps1'
        '40-completion.ps1'
    }
    '50-aliases.ps1',
    '60-utils.ps1'
)

foreach ($profilePart in $profileParts) {
    $profilePartPath = Join-Path $PSScriptRoot $profilePart
    if (-not (Test-Path -LiteralPath $profilePartPath)) {
        Write-Warning "PowerShell profile part not found: $profilePartPath"
        continue
    }

    try {
        . $profilePartPath
    }
    catch {
        Write-Warning "PowerShell profile part failed: $profilePartPath"
        Write-Warning $_.Exception.Message
    }
}

$publicFunctions = @(
    'prompt', 'TabExpansion2', 'Set-LeanPromptSymbolSet', 'Test-LeanPromptGlyphs'
    'node', 'npm', 'npx', 'pnpm', 'yarn', 'corepack'
    'icons'
    'ls', 'l', 'll', 'la', 'lt'
    'pwd', 'mkdir', '..', '...', '....'
    'g', 'gst', 'gss', 'ga', 'gaa', 'gco', 'gcb', 'gb', 'gc', 'gcmsg', 'gca'
    'gp', 'gl', 'gf', 'gd', 'gds', 'glog', 'gloga'
    'cat', 'grep'
    'which', 'whereis', 'touch', 'mkcd', 'head', 'tail'
    'export', 'env', 'open', 'df', 'Update-Path'
)

Export-ModuleMember -Function $publicFunctions -Alias 'xdg-open', 'refreshenv'
