# Shared by stage.ps1, msix.ps1 and msi.ps1 (dot-sourced). Runs on Windows PowerShell 5.1 and pwsh 7.

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'

$PackagingDir = $PSScriptRoot
$WinappDir = Split-Path $PackagingDir -Parent
$RepoRoot = Split-Path $WinappDir -Parent
$OutDir = Join-Path $PackagingDir 'out'

# The Mac app's 1024-pixel icon: every Windows icon and tile is drawn from it.
$IconSource = Join-Path $RepoRoot 'macapp\GarageApp.xcassets\AppIcon.appiconset\AppIcon-512@2x.png'

function Invoke-Native {
    # Runs a program and throws when it fails, as $PSNativeCommandUseErrorActionPreference does in pwsh 7.3+.
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$Arguments = @())
    # Windows PowerShell 5.1 turns a program's stderr into error records, which 'Stop' throws on (a
    # warning would end the script); only the exit code decides.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { "$_" })
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) {
        # The tail of what it said, even when the caller discards the output.
        $tail = ($output | Select-Object -Last 40) -join "`n"
        throw "$(Split-Path $FilePath -Leaf) exited with $LASTEXITCODE`n$tail"
    }
    $output
}

function Copy-Tree {
    # robocopy, mirroring $Source into $Destination; exit codes below 8 are success.
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirectories = @(),
        [string[]]$ExcludeFiles = @()
    )
    $arguments = @($Source, $Destination, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    if ($ExcludeDirectories.Count -gt 0) { $arguments += '/XD'; $arguments += $ExcludeDirectories }
    if ($ExcludeFiles.Count -gt 0) { $arguments += '/XF'; $arguments += $ExcludeFiles }
    & robocopy @arguments | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy $Source -> $Destination failed with $LASTEXITCODE"
    }
    $global:LASTEXITCODE = 0
}

function Get-GarageVersion {
    # garage_python/pyproject.toml's version: the one the Mac app and the CLI report.
    $pyproject = Get-Content (Join-Path $RepoRoot 'garage_python\pyproject.toml') -Raw
    if ($pyproject -notmatch '(?m)^version\s*=\s*"(\d+\.\d+\.\d+)"') {
        throw 'no version = "X.Y.Z" in garage_python/pyproject.toml'
    }
    return $Matches[1]
}

function Assert-Version {
    param([Parameter(Mandatory)][string]$Version)
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw "version $Version is not MAJOR.MINOR.BUILD (the MSI ignores a fourth part, and the Store needs it to be 0)"
    }
}

function Get-StageDirectory {
    param([Parameter(Mandatory)][string]$Arch)
    return Join-Path $OutDir "stage-$Arch"
}

function Get-SdkTool {
    # makeappx, makepri and signtool from the Microsoft.Windows.SDK.BuildTools package the app already
    # restores (Directory.Packages.props pins it), so no Windows SDK install is needed.
    param([Parameter(Mandatory)][string]$Name)
    [xml]$props = Get-Content (Join-Path $WinappDir 'Directory.Packages.props')
    $version = ($props.Project.ItemGroup.PackageVersion | Where-Object { $_.Include -eq 'Microsoft.Windows.SDK.BuildTools' }).Version
    $packages = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }
    $hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $tool = Get-ChildItem (Join-Path $packages "microsoft.windows.sdk.buildtools\$version\bin\*\$hostArch\$Name.exe") -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $tool) {
        throw "$Name.exe not found in Microsoft.Windows.SDK.BuildTools $version; build winapp first (stage.ps1 does) so NuGet restores it"
    }
    return $tool.FullName
}

function Invoke-GarageSign {
    # Authenticode-signs files with a .pfx or a certificate in the current user's store, timestamped.
    param(
        [Parameter(Mandatory)][string[]]$Files,
        [string]$CertificatePath,
        [string]$CertificatePassword,
        [string]$CertificateThumbprint,
        [string]$TimestampUrl = 'http://timestamp.digicert.com'
    )
    $arguments = @('sign', '/fd', 'SHA256')
    if ($CertificatePath) {
        $arguments += @('/f', $CertificatePath)
        if ($CertificatePassword) { $arguments += @('/p', $CertificatePassword) }
    } elseif ($CertificateThumbprint) {
        $arguments += @('/sha1', $CertificateThumbprint)
    } else {
        throw 'signing needs -CertificatePath or -CertificateThumbprint'
    }
    if ($TimestampUrl) { $arguments += @('/tr', $TimestampUrl, '/td', 'SHA256') }
    Invoke-Native (Get-SdkTool 'signtool') ($arguments + $Files)
}

function Invoke-Wix {
    # WiX's command-line tool at the version dotnet-tools.json pins (5.0.2, as the installer projects use).
    param([Parameter(Mandatory)][string[]]$Arguments)
    Push-Location $PackagingDir
    try {
        Invoke-Native dotnet @('tool', 'restore') | Out-Null
        Invoke-Native dotnet (@('tool', 'run', 'wix') + $Arguments)
    } finally {
        Pop-Location
    }
}

# --- The Visual C++ runtime -----------------------------------------------------------------------
# Postgres and ICU import msvcp140, vcruntime140 and vcruntime140_1, which a clean Windows lacks.
# It comes from Microsoft's own Redistributable, never a Visual Studio folder: the MSIX carries its
# DLLs (an MSIX cannot run an installer), Garage-Setup.exe runs it, and the bare MSI requires it.

function Get-RequiredVCRuntime {
    # The newest MSVC toolset (each PE header's linker version) among the binaries under $Directory
    # that import the runtime. The installed runtime must be at least that new: Microsoft supports no
    # older one, and code built with 14.40 or later crashes in std::mutex on an older msvcp140.
    param([Parameter(Mandatory)][string]$Directory)
    $required = [version]'0.0'
    foreach ($file in Get-ChildItem $Directory -Recurse -File -Include '*.dll', '*.exe') {
        if ($file.Name -match '^(msvcp|vcruntime|concrt)140') { continue }
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
        if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { continue }
        if ([System.Text.Encoding]::ASCII.GetString($bytes) -notmatch '(?i)(msvcp140|vcruntime140)[_a-z0-9]*\.dll') { continue }
        # The optional header follows "PE\0\0" and the 20-byte file header; its linker version is at 2 and 3.
        $pe = [BitConverter]::ToInt32($bytes, 0x3C)
        $linker = [version]"$($bytes[$pe + 26]).$($bytes[$pe + 27])"
        if ($linker -gt $required) { $required = $linker }
    }
    return $required
}

function Get-VCRedist {
    # Microsoft's Visual C++ Redistributable for $Arch: $Path when given (an offline build), else the
    # newest from Microsoft's permalink, kept in out\vcredist (delete it to fetch a newer one). Throws
    # unless Microsoft signed it and it covers $Required.
    param([Parameter(Mandatory)][string]$Arch, [Parameter(Mandatory)][version]$Required, [string]$Path)
    if (-not $Path) {
        $Path = Join-Path $OutDir "vcredist\vc_redist.$Arch.exe"
        if (-not (Test-Path $Path)) {
            New-Item -ItemType Directory -Force (Split-Path $Path -Parent) | Out-Null
            Write-Host "  downloading vc_redist.$Arch.exe from Microsoft"
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $progress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest "https://aka.ms/vc14/vc_redist.$Arch.exe" -OutFile $Path -UseBasicParsing
            } finally {
                $ProgressPreference = $progress
            }
        }
    }
    $Path = (Resolve-Path $Path).Path
    $signature = Get-AuthenticodeSignature $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notlike 'CN=Microsoft Corporation,*') {
        throw "$Path is not a Redistributable signed by Microsoft (signature: $($signature.Status))"
    }
    $version = [version](Get-Item $Path).VersionInfo.FileVersion
    if ($version -lt $Required) {
        throw "$Path is runtime $version, older than the MSVC $Required that built Postgres; delete it (or pass a newer one) to use Microsoft's latest"
    }
    return [pscustomobject]@{ Path = $Path; Version = $version }
}

function Invoke-MsiQuery {
    # Rows of a SQL query on an .msi, through the Windows Installer automation interface.
    param([Parameter(Mandatory)][string]$Database, [Parameter(Mandatory)][string]$Query)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Database, 0))
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @($Query))
    [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
    try {
        while ($record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)) {
            $count = $record.GetType().InvokeMember('FieldCount', 'GetProperty', $null, $record, $null)
            , @(1..$count | ForEach-Object { $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, $_) })
        }
    } finally {
        [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db)
    }
}

function Expand-VCRuntime {
    # The runtime DLLs (msvcp140*, vcruntime140*, concrt140) for $Arch from the Redistributable, into
    # $Destination, for the MSIX to carry. WiX unpacks the bundle; the MSI whose File table names
    # msvcp140 for this architecture (the Minimum Runtime) identifies its cabinet, which expand.exe
    # unpacks by file key.
    param([Parameter(Mandatory)]$Redist, [Parameter(Mandatory)][string]$Arch, [Parameter(Mandatory)][string]$Destination)
    $suffix = if ($Arch -eq 'arm64') { '_arm64' } else { '_amd64' }
    $work = Join-Path $OutDir "vcredist\extract-$Arch"
    if (Test-Path $work) { Remove-Item -Recurse -Force $work }
    Invoke-Wix @('burn', 'extract', $Redist.Path, '-o', $work) | Out-Null

    $payloads = Get-ChildItem $work -File
    $files = @{}
    foreach ($payload in $payloads) {
        $head = New-Object byte[] 4
        $stream = [System.IO.File]::OpenRead($payload.FullName)
        try { [void]$stream.Read($head, 0, 4) } finally { $stream.Dispose() }
        if ([BitConverter]::ToString($head) -ne 'D0-CF-11-E0') { continue }
        $rows = @(Invoke-MsiQuery $payload.FullName 'SELECT `File`, `FileName` FROM `File`')
        if (@($rows | Where-Object { $_[0] -eq "msvcp140.dll$suffix" }).Count -eq 0) { continue }
        foreach ($row in $rows) {
            $name = ($row[1] -split '\|')[-1]
            if ($name -match '^(msvcp140.*|vcruntime140.*|concrt140)\.dll$') { $files[$row[0]] = $name }
        }
        break
    }
    if ($files.Count -eq 0) { throw "no MSI in $($Redist.Path) installs msvcp140.dll for $Arch" }

    $cabinet = $payloads | Where-Object { (& expand.exe -D $_.FullName 2>$null) -match [regex]::Escape("msvcp140.dll$suffix") } | Select-Object -First 1
    if (-not $cabinet) { throw "no cabinet in $($Redist.Path) holds msvcp140.dll$suffix" }
    New-Item -ItemType Directory -Force $Destination | Out-Null
    foreach ($key in $files.Keys) {
        Invoke-Native expand.exe @($cabinet.FullName, "-F:$key", $Destination) | Out-Null
        Move-Item -Force (Join-Path $Destination $key) (Join-Path $Destination $files[$key])
    }
    return @($files.Values | ForEach-Object { Join-Path $Destination $_ })
}

function Save-ResizedPng {
    # Draws the icon centred on a transparent $Width x $Height canvas, $Size pixels square.
    param([System.Drawing.Image]$Image, [string]$Path, [int]$Width, [int]$Height, [int]$Size)
    $bitmap = New-Object System.Drawing.Bitmap $Width, $Height
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.DrawImage($Image, [int](($Width - $Size) / 2), [int](($Height - $Size) / 2), $Size, $Size)
        } finally { $graphics.Dispose() }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
}

function New-GarageIco {
    # Garage.ico (16 to 256 pixels, PNG-compressed entries) for Garage.exe, the MSI's shortcut and
    # Add or Remove Programs.
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.Drawing
    $sizes = 16, 24, 32, 48, 64, 128, 256
    $image = [System.Drawing.Image]::FromFile($IconSource)
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $temp | Out-Null
    try {
        $entries = foreach ($size in $sizes) {
            $png = Join-Path $temp "$size.png"
            Save-ResizedPng -Image $image -Path $png -Width $size -Height $size -Size $size
            , [System.IO.File]::ReadAllBytes($png)
        }
    } finally {
        $image.Dispose()
        Remove-Item -Recurse -Force $temp
    }
    New-Item -ItemType Directory -Force (Split-Path $Path -Parent) | Out-Null
    $stream = [System.IO.File]::Create($Path)
    $writer = New-Object System.IO.BinaryWriter $stream
    try {
        # ICONDIR, then one ICONDIRENTRY per image, then the images.
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dimension = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
            $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
            $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([uint16]1); $writer.Write([uint16]32)
            $writer.Write([uint32]$entries[$i].Length); $writer.Write([uint32]$offset)
            $offset += $entries[$i].Length
        }
        foreach ($entry in $entries) { $writer.Write([byte[]]$entry) }
    } finally {
        $writer.Dispose()
    }
}

function New-GarageMsixAssets {
    # The manifest's logos at each scale and target size. makepri indexes the qualifiers, so the Start
    # menu, taskbar and Store each pick the sharpest one.
    param([Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.Drawing
    New-Item -ItemType Directory -Force $Destination | Out-Null
    $image = [System.Drawing.Image]::FromFile($IconSource)
    try {
        foreach ($scale in 100, 125, 150, 200, 400) {
            $factor = $scale / 100
            $square44 = [int][math]::Round(44 * $factor)
            Save-ResizedPng $image (Join-Path $Destination "Square44x44Logo.scale-$scale.png") $square44 $square44 $square44
            $square150 = [int][math]::Round(150 * $factor)
            Save-ResizedPng $image (Join-Path $Destination "Square150x150Logo.scale-$scale.png") $square150 $square150 ([int]($square150 * 0.66))
            $wideWidth = [int][math]::Round(310 * $factor); $wideHeight = [int][math]::Round(150 * $factor)
            Save-ResizedPng $image (Join-Path $Destination "Wide310x150Logo.scale-$scale.png") $wideWidth $wideHeight ([int]($wideHeight * 0.66))
            $store = [int][math]::Round(50 * $factor)
            Save-ResizedPng $image (Join-Path $Destination "StoreLogo.scale-$scale.png") $store $store $store
        }
        foreach ($target in 16, 24, 32, 48, 256) {
            Save-ResizedPng $image (Join-Path $Destination "Square44x44Logo.targetsize-$target.png") $target $target $target
            # The taskbar and Start's app list draw the unplated form, with no tile behind it.
            Save-ResizedPng $image (Join-Path $Destination "Square44x44Logo.targetsize-${target}_altform-unplated.png") $target $target $target
        }
    } finally {
        $image.Dispose()
    }
}
