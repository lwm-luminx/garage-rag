<#
.SYNOPSIS
Lays out Garage for Windows as it ships: the folder msix.ps1 and msi.ps1 package.

.DESCRIPTION
The layout is the one ServiceHostLayout.Locate and PostgresLayout.Locate look for beside Garage.exe:

    Garage.exe ...        the app, published self-contained (.NET and the Windows App SDK inside)
    services\             Garage.Services.exe, published self-contained
    native\               the Rust libraries the services run: garage_service_ffi.dll,
                          garage_ingest_ffi.dll, garage_mcp_ffi.dll (windows.yaml's rust-windows-x64 build)
    schema\               data\sql, the schema InitDb applies
    postgres\             Postgres + pgvector (windows.yaml's postgres-windows-x64 build)

The stage holds no Visual C++ runtime, which Postgres and ICU need: msix.ps1 adds Microsoft's to the
package, and msi.ps1's Garage-Setup.exe installs it (common.ps1, "The Visual C++ runtime").

.EXAMPLE
.\stage.ps1 -NativeDir C:\build\native -PostgresHome C:\build\pgsql
#>
[CmdletBinding()]
param(
    # The folder holding the three Rust libraries (a checkout's rust\target\release). Defaults to GARAGE_NATIVE_DIR.
    [string]$NativeDir = $env:GARAGE_NATIVE_DIR,
    # The Postgres build to ship (bin, lib, share). Defaults to GARAGE_POSTGRES_HOME.
    [string]$PostgresHome = $env:GARAGE_POSTGRES_HOME,
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    # MAJOR.MINOR.BUILD; defaults to GarageService's version (rust/garage-service/src/service.rs).
    [string]$Version,
    # Where to lay it out; defaults to winapp\packaging\out\stage-<arch>.
    [string]$Out
)

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $Version) { $Version = Get-GarageVersion }
Assert-Version $Version
if (-not $Out) { $Out = Get-StageDirectory $Arch }
$natives = @('garage_service_ffi.dll', 'garage_ingest_ffi.dll', 'garage_mcp_ffi.dll')
if (-not $NativeDir -or @($natives | Where-Object { -not (Test-Path (Join-Path $NativeDir $_)) }).Count -gt 0) {
    throw "-NativeDir (or GARAGE_NATIVE_DIR) must name a folder holding $($natives -join ', '); got '$NativeDir'"
}
if (-not $PostgresHome -or -not (Test-Path (Join-Path $PostgresHome 'bin\postgres.exe'))) {
    throw "-PostgresHome (or GARAGE_POSTGRES_HOME) must name a Postgres build with bin\postgres.exe; got '$PostgresHome'"
}
$NativeDir = (Resolve-Path $NativeDir).Path
$PostgresHome = (Resolve-Path $PostgresHome).Path
$platform = if ($Arch -eq 'arm64') { 'ARM64' } else { 'x64' }
$rid = "win-$Arch"

Write-Host "Staging Garage $Version ($Arch) in $Out"
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force $Out | Out-Null
$work = Join-Path $OutDir "work-$Arch"
New-Item -ItemType Directory -Force $work | Out-Null

# --- The app and the services, self-contained, so the machine needs no .NET or Windows App SDK runtime.
$icon = Join-Path $work 'Garage.ico'
New-GarageIco -Path $icon
$common = @('-c', 'Release', '-r', $rid, '--self-contained', "-p:Version=$Version", '-p:DebugType=none', '-p:GenerateDocumentationFile=false', '-nologo', '-v', 'q')
Write-Host '  publishing Garage.App'
Invoke-Native dotnet (@('publish', (Join-Path $WinappDir 'src\Garage.App\Garage.App.csproj'), "-p:Platform=$platform", "-p:ApplicationIcon=$icon", '-o', $Out) + $common)
Write-Host '  publishing Garage.Services'
Invoke-Native dotnet (@('publish', (Join-Path $WinappDir 'src\Garage.Services\Garage.Services.csproj'), '-o', (Join-Path $Out 'services')) + $common)

# --- The Rust libraries the services run, and the schema they apply.
Write-Host '  copying the service libraries'
$nativeOut = Join-Path $Out 'native'
New-Item -ItemType Directory -Force $nativeOut | Out-Null
foreach ($dll in $natives) { Copy-Item (Join-Path $NativeDir $dll) $nativeOut }
Write-Host '  copying the schema'
Copy-Tree (Join-Path $RepoRoot 'data\sql') (Join-Path $Out 'schema')

# --- Postgres, without headers, import libraries and symbols, nor any Visual C++ runtime a build left
# beside it: the packages decide where the runtime comes from.
Write-Host '  copying Postgres'
$postgresOut = Join-Path $Out 'postgres'
Copy-Tree $PostgresHome $postgresOut -ExcludeDirectories @((Join-Path $PostgresHome 'include'), (Join-Path $PostgresHome 'symbols')) `
    -ExcludeFiles @('*.pdb', '*.lib', '*.a', 'msvcp140*.dll', 'vcruntime140*.dll', 'concrt140.dll')
Write-Host "  Postgres needs the Visual C++ runtime $(Get-RequiredVCRuntime $postgresOut) or newer"

# --- Audit (windows.md section 5.5): no GPL library, nor the MinGW runtime, may ship.
$denied = 'libjbig*', 'libgcc_s*', 'libstdc++*', 'libwinpthread*', '*pango*', '*cairo*', 'libglib*', 'libgio*'
$offending = Get-ChildItem $Out -Recurse -File -Include '*.dll' |
    Where-Object { $name = $_.Name; @($denied | Where-Object { $name -like $_ }).Count -gt 0 }
if ($offending) {
    throw "These must not ship (windows.md section 5.5):`n$(($offending | ForEach-Object { $_.FullName }) -join "`n")"
}

$files = Get-ChildItem $Out -Recurse -File
Write-Host ("Staged {0:N0} files, {1:N0} MB, in {2}" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB), $Out)
