param(
    [Parameter(Mandatory)][string] $Cwd,
    [Parameter(Mandatory)][string] $CachePath,
    [Parameter(Mandatory)][string] $LockPath
)

$ErrorActionPreference = 'SilentlyContinue'
try {
    $cacheDir = Split-Path -Parent $CachePath
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $parts = @()

    $nodeVersionFile = $null
    foreach ($name in '.node-version', '.nvmrc') {
        $candidate = Join-Path $Cwd $name
        if (Test-Path -LiteralPath $candidate) { $nodeVersionFile = $candidate; break }
    }
    if ($nodeVersionFile) {
        $nodeVersion = ''
        & fnm use --silent-if-unchanged *> $null
        $nodeVersion = (& node -v 2>$null | Select-Object -First 1).Trim()
        if (-not $nodeVersion) { $nodeVersion = (Get-Content -LiteralPath $nodeVersionFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -First 1).Trim() }
        if ($nodeVersion) { $parts += "node $nodeVersion" }
    }

    $pythonVersionFile = Join-Path $Cwd '.python-version'
    if (Test-Path -LiteralPath $pythonVersionFile) {
        $pythonVersion = (Get-Content -LiteralPath $pythonVersionFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
        if ($pythonVersion) { $parts += "py $pythonVersion" }
    }

    $goMod = Join-Path $Cwd 'go.mod'
    if (Test-Path -LiteralPath $goMod) {
        $goVersion = Get-Content -LiteralPath $goMod -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_ -match '^\s*go\s+([^\s]+)') { $Matches[1] }
        } | Select-Object -First 1
        if ($goVersion) { $parts += "go $goVersion" }
    }

    $rustToolchainToml = Join-Path $Cwd 'rust-toolchain.toml'
    $rustToolchain = Join-Path $Cwd 'rust-toolchain'
    if (Test-Path -LiteralPath $rustToolchainToml) {
        $rustVersion = Get-Content -LiteralPath $rustToolchainToml -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_ -match '^\s*channel\s*=\s*["'']?([^"''\s]+)') { $Matches[1] }
        } | Select-Object -First 1
        if ($rustVersion) { $parts += "rs $rustVersion" }
    }
    elseif (Test-Path -LiteralPath $rustToolchain) {
        $rustVersion = (Get-Content -LiteralPath $rustToolchain -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
        if ($rustVersion) { $parts += "rs $rustVersion" }
    }

    $globalJson = Join-Path $Cwd 'global.json'
    if (Test-Path -LiteralPath $globalJson) {
        try {
            $dotnetVersion = (Get-Content -LiteralPath $globalJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).sdk.version
            if ($dotnetVersion) { $parts += ".NET $dotnetVersion" }
        }
        catch {}
    }

    $status = [pscustomobject]@{
        Path = $Cwd
        IsProject = ($parts.Count -gt 0)
        Text = ($parts -join ' ')
        Updated = (Get-Date).ToString('o')
    }
    try { $cached = Get-Content -LiteralPath $CachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { $cached = $null }
    if ($cached -and [string]$cached.Path -ceq $status.Path -and
        [bool]$cached.IsProject -eq $status.IsProject -and [string]$cached.Text -ceq $status.Text) {
        [System.IO.File]::SetLastWriteTimeUtc($CachePath, [datetime]::UtcNow)
        return
    }

    $tempPath = "$CachePath.$PID.tmp"
    try {
        $status | ConvertTo-Json -Compress | Set-Content -LiteralPath $tempPath -Encoding UTF8 -ErrorAction Stop
        [System.IO.File]::Move($tempPath, $CachePath, $true)
    }
    finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}
catch {}
finally {
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
}
