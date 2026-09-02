[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$oldNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false

$packages = @(
    @{ Id = 'Git.Git'; Name = 'Git' },
    @{ Id = 'lsd-rs.lsd'; Name = 'lsd' },
    @{ Id = 'sharkdp.bat'; Name = 'bat' },
    @{ Id = 'BurntSushi.ripgrep.MSVC'; Name = 'ripgrep' },
    @{ Id = 'sharkdp.fd'; Name = 'fd' },
    @{ Id = 'chmln.sd'; Name = 'sd' },
    @{ Id = 'jdx.mise'; Name = 'mise' },
    @{ Id = 'rsteube.Carapace'; Name = 'Carapace' },
    @{ Id = 'Rustlang.Rustup'; Name = 'Rustup' }
)

try {
    foreach ($package in $packages) {
        Write-Host "Installing $($package.Name) [$($package.Id)]"
        winget install --id $package.Id --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
        $exitCode = $global:LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "winget install failed for $($package.Name) [$($package.Id)] (exit $exitCode)"
        }
    }
}
finally {
    $PSNativeCommandUseErrorActionPreference = $oldNativeErrorPreference
}
