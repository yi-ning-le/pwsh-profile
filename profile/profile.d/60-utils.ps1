# ============================================================
#  coreutils names (Linux muscle memory: PowerShell lacks these names or gives them different behavior)
# ============================================================

# which: print the actual command path (like Linux which, not PS where = Where-Object)
function which {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Name)
    foreach ($n in $Name) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { if ($c.Source) { $c.Source } else { "$($c.Name): $($c.CommandType)" } }
        else { Write-Host "which: ${n}: not found" -ForegroundColor Yellow }
    }
}

# whereis: list all command locations (aliases/functions/every PATH exe), like a show-all-matches whereis
function whereis {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Name)
    foreach ($n in $Name) {
        $cmds = Get-Command $n -All -ErrorAction SilentlyContinue
        if (-not $cmds) { Write-Host "whereis: ${n}: not found" -ForegroundColor Yellow; continue }
        $loc = foreach ($c in $cmds) {
            switch ($c.CommandType) {
                'Application' { $c.Source }
                'Alias'       { "alias->$($c.Definition)" }
                'Function'    { 'function' }
                default       { [string]$c.CommandType }
            }
        }
        "${n}: " + ($loc -join '  ')
    }
}

# touch: create files when missing, otherwise update timestamps
function touch {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Path)
    foreach ($p in $Path) {
        if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTime = Get-Date }
        else { New-Item -ItemType File -Path $p | Out-Null }
    }
}

# mkcd: create a directory and enter it
function mkcd {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Set-Location -LiteralPath $Path
}

# head / tail: usage head [-n N] [file]; pipeline ... | head; tail also supports -f follow
function head {
    param([int]$n = 10, [Parameter(ValueFromRemainingArguments)][string[]]$Path)
    if ($Path) { foreach ($p in $Path) { Get-Content -LiteralPath $p -TotalCount $n } }
    else { $input | Select-Object -First $n }
}
function tail {
    param([int]$n = 10, [switch]$f, [Parameter(ValueFromRemainingArguments)][string[]]$Path)
    if ($Path) { Get-Content -LiteralPath $Path[0] -Tail $n -Wait:$f }
    else { $input | Select-Object -Last $n }
}

# export NAME=value: set environment variables (like bash export)
function export {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Assignment)
    foreach ($a in $Assignment) { $k, $v = $a -split '=', 2; Set-Item -Path "env:$k" -Value $v }
}

# env: list all environment variables (NAME=value)
function env { Get-ChildItem Env: | ForEach-Object { "$($_.Name)=$($_.Value)" } }

# open / xdg-open: open files or directories with the default app (open . = current directory)
function open { param([Parameter(ValueFromRemainingArguments)][string[]]$Path) if ($Path) { Invoke-Item -Path $Path } else { Invoke-Item . } }
Set-Alias xdg-open open

# df: disk usage overview
function df { Get-Volume | Where-Object DriveLetter | Sort-Object DriveLetter }

# refreshenv / Update-Path: reread PATH from the registry into the current session (no terminal restart after installing software)
function Update-Path {
    $env:PATH = ([Environment]::GetEnvironmentVariable('Path', 'Machine'),
                 [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
}
Set-Alias refreshenv Update-Path

# reload: refresh PATH, then reload the profile (one command after installing new tools)
function reload {
    Update-Path
    . $PROFILE.CurrentUserCurrentHost
    Write-Host 'env + profile reloaded.' -ForegroundColor Green
}
