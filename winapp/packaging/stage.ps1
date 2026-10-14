<#
.SYNOPSIS
Lays out Garage for Windows as it ships: the folder msix.ps1 and msi.ps1 package.

.DESCRIPTION
The layout is the one ServiceHostLayout.Locate and PostgresLayout.Locate look for beside Garage.exe:

    Garage.exe ...        the app, published self-contained (.NET and the Windows App SDK inside)
    services\             Garage.Services.exe, published self-contained
    python\               the CPython 3.14 home (windows.yaml's python-windows-x64 build)
    site-packages\        garage_rag and its dependencies
    postgres\             Postgres + pgvector (windows.yaml's postgres-windows-x64 build)

The stage holds no Visual C++ runtime, which Postgres and ICU need: msix.ps1 adds Microsoft's to the
package, and msi.ps1's Garage-Setup.exe installs it (common.ps1, "The Visual C++ runtime").

Python sources are compiled ahead of time (unchecked-hash .pyc), since the installed folder is
read-only and the services never write bytecode.

.EXAMPLE
.\stage.ps1 -PythonHome C:\build\python -PostgresHome C:\build\pgsql
#>
[CmdletBinding()]
param(
    # The CPython 3.14 home to ship: python314.dll, Lib, DLLs. Defaults to GARAGE_PYTHON_HOME.
    [string]$PythonHome = $env:GARAGE_PYTHON_HOME,
    # The Postgres build to ship (bin, lib, share). Defaults to GARAGE_POSTGRES_HOME.
    [string]$PostgresHome = $env:GARAGE_POSTGRES_HOME,
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    # MAJOR.MINOR.BUILD; defaults to garage_python/pyproject.toml's version.
    [string]$Version,
    # Where to lay it out; defaults to winapp\packaging\out\stage-<arch>.
    [string]$Out
)

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not $Version) { $Version = Get-GarageVersion }
Assert-Version $Version
if (-not $Out) { $Out = Get-StageDirectory $Arch }
if (-not $PythonHome -or -not (Test-Path (Join-Path $PythonHome 'python314.dll'))) {
    throw "-PythonHome (or GARAGE_PYTHON_HOME) must name a CPython 3.14 home with python314.dll; got '$PythonHome'"
}
if (-not $PostgresHome -or -not (Test-Path (Join-Path $PostgresHome 'bin\postgres.exe'))) {
    throw "-PostgresHome (or GARAGE_POSTGRES_HOME) must name a Postgres build with bin\postgres.exe; got '$PostgresHome'"
}
$PythonHome = (Resolve-Path $PythonHome).Path
$PostgresHome = (Resolve-Path $PostgresHome).Path
$python = Join-Path $PythonHome 'python.exe'
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

# --- Python: the home, without what a build or a developer adds to it (headers, import libraries,
# scripts, tests, Tk, docs) and without any packages installed into it: the services see only
# site-packages\ (Garage.Python's isolation), so anything there would ship unused.
Write-Host '  copying Python'
$pythonOut = Join-Path $Out 'python'
Copy-Tree $PythonHome $pythonOut `
    -ExcludeDirectories @((Join-Path $PythonHome 'Lib\site-packages'), (Join-Path $PythonHome 'include'), (Join-Path $PythonHome 'libs'),
        (Join-Path $PythonHome 'Scripts'), (Join-Path $PythonHome 'Tools'), (Join-Path $PythonHome 'Doc'), (Join-Path $PythonHome 'tcl'),
        (Join-Path $PythonHome 'Lib\test'), (Join-Path $PythonHome 'Lib\idlelib'), (Join-Path $PythonHome 'Lib\tkinter'),
        (Join-Path $PythonHome 'Lib\turtledemo'), '__pycache__') `
    -ExcludeFiles @('*.pdb', '*.pyc', '_tkinter.pyd', 'tcl*.dll', 'tk*.dll', 'pythonw.exe', 'pythonw_d.exe', 'python_d.exe', '*_d.pyd', '*_d.dll')
New-Item -ItemType Directory -Force (Join-Path $pythonOut 'Lib\site-packages') | Out-Null

# --- garage_rag and its dependencies, installed (not editable) for the shipped interpreter. uv when it
# is on PATH (CI), else pip.
Write-Host '  installing garage_rag into site-packages'
$site = Join-Path $Out 'site-packages'
$project = Join-Path $RepoRoot 'garage_python'
if (Get-Command uv -ErrorAction SilentlyContinue) {
    Invoke-Native uv @('pip', 'install', '--python', $python, '--target', $site, '--no-compile', '--quiet', $project)
} else {
    Invoke-Native $python @('-m', 'pip', 'install', '--target', $site, '--no-compile', '--no-warn-script-location', '--disable-pip-version-check', '--quiet', $project)
}
# Console scripts point at the build machine's python.exe; the launchers replace them. python-docx's
# default-docx-template is the unpacked source of its default.docx, never read at run time, and holds a
# [Content_Types].xml, a name an MSIX (a zip in the Open Packaging Conventions) reserves.
foreach ($unused in 'bin', 'Scripts', 'docx\templates\default-docx-template') {
    $folder = Join-Path $site $unused
    if (Test-Path $folder) { Remove-Item -Recurse -Force $folder }
}

Write-Host '  compiling Python bytecode'
# -W ignore: packages' own tests and samples raise SyntaxWarnings (pywin32's) that say nothing about Garage.
Invoke-Native $python @('-W', 'ignore', '-m', 'compileall', '-q', '-j', '0', '--invalidation-mode', 'unchecked-hash', (Join-Path $pythonOut 'Lib'), $site)

# --- Postgres, without headers, import libraries and symbols, nor any Visual C++ runtime a build left
# beside it: the packages decide where the runtime comes from.
Write-Host '  copying Postgres'
$postgresOut = Join-Path $Out 'postgres'
Copy-Tree $PostgresHome $postgresOut -ExcludeDirectories @((Join-Path $PostgresHome 'include'), (Join-Path $PostgresHome 'symbols')) `
    -ExcludeFiles @('*.pdb', '*.lib', '*.a', 'msvcp140*.dll', 'vcruntime140*.dll', 'concrt140.dll')
Write-Host "  Postgres needs the Visual C++ runtime $(Get-RequiredVCRuntime $postgresOut) or newer"

# --- Audit (windows.md section 5.5): no GPL library, nor the MinGW runtime, may ship.
$denied = 'libjbig*', 'libgcc_s*', 'libstdc++*', 'libwinpthread*', '*pango*', '*cairo*', 'libglib*', 'libgio*'
$offending = Get-ChildItem $Out -Recurse -File -Include '*.dll', '*.pyd' |
    Where-Object { $name = $_.Name; @($denied | Where-Object { $name -like $_ }).Count -gt 0 }
if ($offending) {
    throw "These must not ship (windows.md section 5.5):`n$(($offending | ForEach-Object { $_.FullName }) -join "`n")"
}

$files = Get-ChildItem $Out -Recurse -File
Write-Host ("Staged {0:N0} files, {1:N0} MB, in {2}" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB), $Out)
