<#
.SYNOPSIS
Builds the MSI and Garage-Setup.exe from the staged layout (stage.ps1): Garage installed per machine
in Program Files.

.DESCRIPTION
- Garage-X.Y.Z-<arch>.msi (msi\Garage.Installer.wixproj): for IT deployment. It requires the Visual
  C++ runtime Postgres needs and, without it, stops with a message naming Microsoft's download.
- Garage-Setup-X.Y.Z-<arch>.exe (setup\Garage.Setup.wixproj): for people installing by hand. It
  installs Microsoft's Visual C++ Redistributable when this PC's runtime is missing or too old, then
  the MSI.

Both are built with WiX v5 through the .NET SDK. Given a certificate, the MSI, the bootstrapper's
engine and the bootstrapper are signed in that order (a Burn bundle's engine is signed apart from it).

The app it installs has no package identity, so it behaves as a build-folder run does: data in
%LOCALAPPDATA%\Garage, launch at sign-in through the Run key, and Settings says a newer MSI updates it.

.EXAMPLE
.\msi.ps1
.\msi.ps1 -CertificateThumbprint 0123456789ABCDEF0123456789ABCDEF01234567
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    # MAJOR.MINOR.BUILD; defaults to garage_python/pyproject.toml's version.
    [string]$Version,
    # The staged layout; defaults to winapp\packaging\out\stage-<arch>.
    [string]$Stage,
    # A vc_redist.<arch>.exe for Garage-Setup.exe to carry; defaults to Microsoft's latest (common.ps1).
    [string]$VCRedist,
    [string]$CertificatePath,
    [string]$CertificatePassword,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com'
)

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $Version) { $Version = Get-GarageVersion }
Assert-Version $Version
if (-not $Stage) { $Stage = Get-StageDirectory $Arch }
if (-not (Test-Path (Join-Path $Stage 'Garage.exe'))) {
    throw "No staged Garage in $Stage; run stage.ps1 -Arch $Arch first"
}
$Stage = (Resolve-Path $Stage).Path
$icon = Join-Path $OutDir "work-$Arch\Garage.ico"
if (-not (Test-Path $icon)) { New-GarageIco -Path $icon }
$sign = $CertificatePath -or $CertificateThumbprint
function Invoke-Sign([string[]]$Files) {
    Invoke-GarageSign -Files $Files -CertificatePath $CertificatePath -CertificatePassword $CertificatePassword `
        -CertificateThumbprint $CertificateThumbprint -TimestampUrl $TimestampUrl
}

# The runtime Postgres needs, and the version just below it for the MSI's file search.
$required = Get-RequiredVCRuntime (Join-Path $Stage 'postgres')
$below = if ($required.Minor -gt 0) { "$($required.Major).$($required.Minor - 1).65535.65535" } else { "$($required.Major - 1).65535.65535.65535" }
$redist = Get-VCRedist -Arch $Arch -Required $required -Path $VCRedist
Write-Host "Building the MSI for Garage $Version ($Arch); Postgres needs the Visual C++ runtime $required"

$build = Join-Path $OutDir "msi-$Arch"
Invoke-Native dotnet @('build', (Join-Path $PackagingDir 'msi\Garage.Installer.wixproj'), '-c', 'Release', '--no-incremental', '-nologo', '-v', 'q',
    "-p:StageDir=$Stage", "-p:ProductVersion=$Version", "-p:IconPath=$icon", "-p:InstallerPlatform=$Arch",
    "-p:VCRuntimeRequired=$required", "-p:VCRuntimeMinVersion=$below", '-o', $build) | Out-Host
$msi = Join-Path $OutDir "Garage-$Version-$Arch.msi"
Move-Item -Force (Join-Path $build "Garage-$Version-$Arch.msi") $msi
if ($sign) {
    Write-Host '  signing the MSI'
    Invoke-Sign @($msi)
}

Write-Host "Building Garage-Setup.exe with the Visual C++ Redistributable $($redist.Version)"
$setupBuild = Join-Path $OutDir "setup-$Arch"
Invoke-Native dotnet @('build', (Join-Path $PackagingDir 'setup\Garage.Setup.wixproj'), '-c', 'Release', '--no-incremental', '-nologo', '-v', 'q',
    "-p:ProductVersion=$Version", "-p:IconPath=$icon", "-p:InstallerPlatform=$Arch", "-p:MsiPath=$msi",
    "-p:VCRedistPath=$($redist.Path)", "-p:VCRuntimeRequired=$required", '-o', $setupBuild) | Out-Host
$setup = Join-Path $OutDir "Garage-Setup-$Version-$Arch.exe"
Move-Item -Force (Join-Path $setupBuild "Garage-Setup-$Version-$Arch.exe") $setup
if ($sign) {
    Write-Host '  signing Garage-Setup.exe'
    $engine = Join-Path $setupBuild 'engine.exe'
    Invoke-Wix @('burn', 'detach', $setup, '-engine', $engine) | Out-Null
    Invoke-Sign @($engine)
    Invoke-Wix @('burn', 'reattach', $setup, '-engine', $engine, '-o', $setup) | Out-Null
    Invoke-Sign @($setup)
}

foreach ($built in $msi, $setup) {
    Write-Host ("Built {0} ({1:N0} MB)" -f $built, ((Get-Item $built).Length / 1MB))
}
