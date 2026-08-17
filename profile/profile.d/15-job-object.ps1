# ---- Windows Job Object process runner ----
# The installer builds the native helper; profile startup and command execution never invoke Cargo.
$script:State.JobRunner = @{
    Executable = if ($env:PWSH_JRUN_PATH) {
        $env:PWSH_JRUN_PATH
    }
    else {
        Join-Path $PSScriptRoot 'job-runner\jrun.exe'
    }
}

function Resolve-PwshNativeCommand {
    param([Parameter(Mandatory)][string] $Name)

    if ($Name -in 'node', 'npm', 'npx', 'pnpm', 'yarn', 'corepack' -and
        (Get-Command Initialize-FnmForUse -CommandType Function -ErrorAction SilentlyContinue)) {
        $null = Initialize-FnmForUse
        Update-FnmVersionForCurrentDirectory -Wait
    }

    $hasExtensionOrPath = [System.IO.Path]::GetExtension($Name) -or
        $Name.Contains([System.IO.Path]::DirectorySeparatorChar) -or
        $Name.Contains([System.IO.Path]::AltDirectorySeparatorChar)
    $candidates = if ($hasExtensionOrPath) {
        $Name
    }
    else {
        switch ($Name) {
            'node' { 'node.exe'; $Name; break }
            'npm' { 'npm.cmd'; $Name; break }
            default { "$Name.exe"; "$Name.cmd"; "$Name.bat"; $Name }
        }
    }

    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command) { return $command }
    }
    throw "Native command not found: $Name"
}

function Invoke-JobProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string] $FilePath,
        [Parameter(Position = 1, ValueFromRemainingArguments)][AllowEmptyCollection()][string[]] $ArgumentList = @()
    )

    $command = Resolve-PwshNativeCommand -Name $FilePath
    $target = $command.Source
    $targetArguments = @($ArgumentList)
    if ($command.CommandType -eq 'ExternalScript') {
        $targetArguments = @('-NoLogo', '-NoProfile', '-File', $target) + $targetArguments
        $target = (Resolve-PwshNativeCommand -Name 'pwsh').Source
    }

    $location = Get-Location
    if ($location.Provider.Name -ne 'FileSystem') {
        throw 'Invoke-JobProcess requires a FileSystem working directory.'
    }

    $runner = $script:State.JobRunner.Executable
    if (-not [System.IO.File]::Exists($runner)) {
        throw "jrun executable not found: $runner. Run scripts\install.ps1 to build and install it."
    }
    & $runner $target @targetArguments
}

function jrun {
    if ($args.Count -eq 0) { throw 'usage: jrun <command> [arguments]' }
    $command = [string]$args[0]
    $arguments = if ($args.Count -gt 1) { [string[]]$args[1..($args.Count - 1)] } else { @() }
    Invoke-JobProcess -FilePath $command -ArgumentList $arguments
}
