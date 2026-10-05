<#
.SYNOPSIS
Packs the staged layout (stage.ps1) as an MSIX: for the Microsoft Store, or signed for direct download.

.DESCRIPTION
The package holds the staged folder as it is, plus:

    AppxManifest.xml   msix\AppxManifest.xml with the identity, version and architecture filled in
    Assets\            the logos, drawn from the Mac app's icon at each scale
    resources.pri      Garage.pri (the app's XAML and strings) merged with the logos' index: a
                       packaged app's resources are read from resources.pri
    postgres\bin\      the Visual C++ runtime DLLs, from Microsoft's signed Redistributable. An MSIX
                       cannot run the Redistributable's installer, and Microsoft's framework package
                       for it (Microsoft.VCLibs.140.00.UWPDesktop) stops at 14.39, older than the
                       toolset that builds Postgres

For the Store, pass the identity Partner Center shows (Product management > Product identity) and
leave the package unsigned: the Store signs it. For direct download, sign it with a certificate
whose subject is -Publisher, and pass -AppInstallerUri to write the .appinstaller feed beside it.

.EXAMPLE
# Microsoft Store (upload the .msix in Partner Center)
.\msix.ps1 -IdentityName 12345Example.Garage -Publisher 'CN=0A1B2C3D-...' -PublisherDisplayName 'Example'

.EXAMPLE
# Direct download, signed, with its App Installer feed
.\msix.ps1 -Publisher 'CN=Example, O=Example, C=US' -CertificatePath garage.pfx -CertificatePassword $pw `
    -AppInstallerUri https://garagerag.app/windows/garage.appinstaller
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    # MAJOR.MINOR.BUILD; the package version is MAJOR.MINOR.BUILD.0, as the Store requires.
    [string]$Version,
    # The staged layout; defaults to winapp\packaging\out\stage-<arch>.
    [string]$Stage,
    # Package/Identity/Name: Partner Center's for the Store.
    [string]$IdentityName = 'GarageRAG.Garage',
    # Package/Identity/Publisher: Partner Center's for the Store, else the signing certificate's subject.
    [string]$Publisher = 'CN=Garage Development',
    [string]$PublisherDisplayName = 'Garage',
    # Signing: a .pfx (and its password) or a certificate's thumbprint in the current user's store.
    [string]$CertificatePath,
    [string]$CertificatePassword,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    # The feed's own URL. The MSIX is expected beside it, under its file name.
    [string]$AppInstallerUri,
    # A vc_redist.<arch>.exe to take the runtime from; defaults to Microsoft's latest (common.ps1).
    [string]$VCRedist
)

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $Version) { $Version = Get-GarageVersion }
Assert-Version $Version
if (-not $Stage) { $Stage = Get-StageDirectory $Arch }
if (-not (Test-Path (Join-Path $Stage 'Garage.exe'))) {
    throw "No staged Garage in $Stage; run stage.ps1 -Arch $Arch first"
}
$Stage = (Resolve-Path $Stage).Path
$packageVersion = "$Version.0"
$work = Join-Path $OutDir "msix-$Arch"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work | Out-Null

function Expand-Template {
    param([string]$Path, [hashtable]$Values)
    $text = Get-Content $Path -Raw -Encoding UTF8
    foreach ($key in $Values.Keys) {
        $text = $text.Replace("{{$key}}", [System.Security.SecurityElement]::Escape([string]$Values[$key]))
    }
    if ($text -match '\{\{\w+\}\}') { throw "$Path still has a field to fill: $($Matches[0])" }
    return $text
}

$fields = @{
    IdentityName = $IdentityName
    Publisher = $Publisher
    PublisherDisplayName = $PublisherDisplayName
    Version = $packageVersion
    Arch = $Arch
}

# --- The manifest and the logos.
$manifest = Join-Path $work 'AppxManifest.xml'
[System.IO.File]::WriteAllText($manifest, (Expand-Template (Join-Path $PackagingDir 'msix\AppxManifest.xml') $fields), (New-Object System.Text.UTF8Encoding $false))
$priRoot = Join-Path $work 'pri'
New-GarageMsixAssets -Destination (Join-Path $priRoot 'Assets')

# --- resources.pri: the logos (folder indexer, so their scale and target-size qualifiers count) and
# Garage.pri's resources (PRI indexer), in the package's main resource map. One index from the root,
# so a logo's name keeps its folder (Files/Assets/StoreLogo.png), as the manifest refers to it.
Copy-Item (Join-Path $Stage 'Garage.pri') $priRoot
$priConfig = Join-Path $work 'priconfig.xml'
@'
<?xml version="1.0" encoding="utf-8"?>
<resources targetOsVersion="10.0.0" majorVersion="1">
  <index root="\" startIndexAt="\">
    <default>
      <qualifier name="Language" value="en-US" />
      <qualifier name="Contrast" value="standard" />
      <qualifier name="Scale" value="200" />
      <qualifier name="HomeRegion" value="001" />
      <qualifier name="TargetSize" value="256" />
      <qualifier name="LayoutDirection" value="LTR" />
      <qualifier name="DXFeatureLevel" value="DX9" />
      <qualifier name="Configuration" value="" />
      <qualifier name="AlternateForm" value="" />
      <qualifier name="Platform" value="UAP" />
    </default>
    <indexer-config type="folder" foldernameAsQualifier="true" filenameAsQualifier="true" qualifierDelimiter="." />
    <indexer-config type="PRI" />
  </index>
</resources>
'@ | Set-Content -Encoding UTF8 $priConfig
$resources = Join-Path $work 'resources.pri'
Write-Host '  indexing resources'
Invoke-Native (Get-SdkTool 'makepri') @('new', '/pr', $priRoot, '/cf', $priConfig, '/mn', $manifest, '/of', $resources, '/o') | Out-Null

# --- The mapping: every staged file at its own path, plus what this script made. Packing from a
# mapping file reads the stage in place rather than copying a gigabyte.
$mapping = Join-Path $work 'mapping.txt'
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('[Files]')
$lines.Add("`"$manifest`" `"AppxManifest.xml`"")
$lines.Add("`"$resources`" `"resources.pri`"")
foreach ($asset in Get-ChildItem (Join-Path $priRoot 'Assets') -File) {
    $lines.Add("`"$($asset.FullName)`" `"Assets\$($asset.Name)`"")
}
# --- The Visual C++ runtime, beside the Postgres binaries that import it.
$required = Get-RequiredVCRuntime (Join-Path $Stage 'postgres')
$redist = Get-VCRedist -Arch $Arch -Required $required -Path $VCRedist
Write-Host "  adding the Visual C++ runtime $($redist.Version) (Postgres needs $required)"
foreach ($dll in Expand-VCRuntime -Redist $redist -Arch $Arch -Destination (Join-Path $work 'vcruntime')) {
    $lines.Add("`"$dll`" `"postgres\bin\$(Split-Path $dll -Leaf)`"")
}

$prefix = $Stage.Length + 1
$staged = Get-ChildItem $Stage -Recurse -File
# makeappx fails on these with only "the filename ... syntax is incorrect"; name them instead.
$reserved = @($staged | Where-Object { $_.Name -eq '[Content_Types].xml' -or $_.Name -eq 'AppxManifest.xml' -or $_.Name -like 'AppxBlockMap.xml' })
if ($reserved.Count -gt 0) {
    throw "An MSIX cannot carry these package-reserved names; leave them out in stage.ps1:`n$(($reserved | ForEach-Object { $_.FullName }) -join "`n")"
}
foreach ($file in $staged) {
    $lines.Add("`"$($file.FullName)`" `"$($file.FullName.Substring($prefix))`"")
}
[System.IO.File]::WriteAllLines($mapping, $lines, (New-Object System.Text.UTF8Encoding $false))

$package = Join-Path $OutDir "Garage_${packageVersion}_$Arch.msix"
Write-Host "  packing $($lines.Count - 1) files"
Invoke-Native (Get-SdkTool 'makeappx') @('pack', '/f', $mapping, '/p', $package, '/o') | Out-Null

if ($CertificatePath -or $CertificateThumbprint) {
    Write-Host '  signing'
    Invoke-GarageSign -Files @($package) -CertificatePath $CertificatePath -CertificatePassword $CertificatePassword `
        -CertificateThumbprint $CertificateThumbprint -TimestampUrl $TimestampUrl
}

if ($AppInstallerUri) {
    $feed = [uri]$AppInstallerUri
    $packageUri = New-Object System.Uri($feed, (Split-Path $package -Leaf))
    $fields['FeedUri'] = $feed.AbsoluteUri
    $fields['PackageUri'] = $packageUri.AbsoluteUri
    $appInstaller = Join-Path $OutDir ($feed.Segments[-1])
    [System.IO.File]::WriteAllText($appInstaller, (Expand-Template (Join-Path $PackagingDir 'msix\Garage.appinstaller') $fields), (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Wrote $appInstaller"
}

Write-Host ("Packed {0} ({1:N0} MB)" -f $package, ((Get-Item $package).Length / 1MB))
