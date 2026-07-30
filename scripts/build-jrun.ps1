[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$TargetDirectory
)

$ErrorActionPreference = 'Stop'

$source = [System.IO.Path]::GetFullPath($SourceDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $source 'Cargo.toml'))) {
    throw "jrun Cargo.toml not found under: $source"
}

$cargo = Get-Command cargo.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $cargo) { throw 'Cargo was not found; install the Rust MSVC toolchain before installing the profile.' }

if (-not $TargetDirectory) {
    $TargetDirectory = Join-Path $source '..\..\..\.cargo-target\jrun'
}
$target = [System.IO.Path]::GetFullPath($TargetDirectory)
$destination = [System.IO.Path]::GetFullPath($OutputPath)
$oldCargoTargetDirectory = $env:CARGO_TARGET_DIR
$oldNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
try {
    $PSNativeCommandUseErrorActionPreference = $false
    $env:CARGO_TARGET_DIR = $target
    Push-Location $source
    try {
        $output = @(& $cargo.Source build --release --locked --quiet 2>&1)
        $exitCode = $global:LASTEXITCODE
    }
    finally { Pop-Location }

    $built = Join-Path $target 'release\jrun.exe'
    if ($exitCode -ne 0 -or -not [System.IO.File]::Exists($built)) {
        throw "Failed to compile jrun (exit $exitCode): $($output -join ' ')"
    }
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
    Copy-Item -LiteralPath $built -Destination $destination -Force
}
finally {
    $PSNativeCommandUseErrorActionPreference = $oldNativeErrorPreference
    if ($null -eq $oldCargoTargetDirectory) { Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue }
    else { $env:CARGO_TARGET_DIR = $oldCargoTargetDirectory }
}
