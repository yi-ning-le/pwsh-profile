[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$packages = @(
    @{ Id = 'Git.Git'; Name = 'Git' },
    @{ Id = 'lsd-rs.lsd'; Name = 'lsd' },
    @{ Id = 'sharkdp.bat'; Name = 'bat' },
    @{ Id = 'BurntSushi.ripgrep.MSVC'; Name = 'ripgrep' },
    @{ Id = 'Schniz.fnm'; Name = 'fnm' },
    @{ Id = 'rsteube.Carapace'; Name = 'Carapace' }
)

foreach ($package in $packages) {
    Write-Host "Installing $($package.Name) [$($package.Id)]"
    winget install --id $package.Id --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
}
