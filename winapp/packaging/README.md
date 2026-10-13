# Packaging Garage for Windows (`winapp/packaging`)

Three installers come from one staged layout:

| | MSIX | MSI |
|---|---|---|
| For | The Microsoft Store, and direct download with App Installer updates | `Garage-Setup.exe` (the MSI plus the runtime) for people installing by hand; the bare `.msi` for IT deployment (Intune, Group Policy, Configuration Manager) |
| Visual C++ runtime | Carried in the package, beside Postgres | `Garage-Setup.exe` installs Microsoft's Redistributable when needed; the bare MSI requires it |
| Installs to | `C:\Program Files\WindowsApps\<package>` (per user, no elevation) | `C:\Program Files\Garage` (per machine, one elevation) |
| Data | `%LOCALAPPDATA%\Garage`, which Windows redirects into the package's private `LocalCache` | `%LOCALAPPDATA%\Garage` |
| Launch at sign-in | The manifest's `StartupTask` (`PackagedStartup`) | The account's `Run` key (`RunKeyStartup`) |
| Updates | Store, or App Installer from the `.appinstaller` feed | A newer MSI (`MajorUpgrade`) |
| Settings shows | "Microsoft Store" / "App Installer" | "Windows Installer" |

Uninstalling the MSIX removes its redirected data with it. Uninstalling the MSI leaves `%LOCALAPPDATA%\Garage`.

## Build

From `winapp\packaging`, in Windows PowerShell 5.1 or `pwsh`:

```powershell
.\stage.ps1 -PythonHome C:\build\python -PostgresHome C:\build\pgsql   # out\stage-x64
.\msix.ps1                                                             # out\Garage_1.5.0.0_x64.msix
.\msi.ps1                                                              # out\Garage-1.5.0-x64.msi, out\Garage-Setup-1.5.0-x64.exe
```

- **`stage.ps1`** lays out what `ServiceHostLayout.Locate` and `PostgresLayout.Locate` look for beside
  `Garage.exe`:
  - the app and `services\Garage.Services.exe`, both published self-contained;
  - `python\`, the CPython 3.14 home (`windows.yaml`'s `python-windows-x64`) without headers, tests or
    Tk;
  - `site-packages\`, `garage_python` installed with uv (or pip) for that interpreter;
  - `postgres\`, `windows.yaml`'s `postgres-windows-x64` without headers or symbols.

  It also does two things to the files:
  - compiles all Python to `unchecked-hash` `.pyc`, since the installed folder is read-only;
  - fails if any DLL on the GPL or MinGW denylist ships (windows.md section 5.5).

  The stage holds no Visual C++ runtime; see [The Visual C++ runtime](#the-visual-c-runtime).
- **`msix.ps1`** packs the stage as it is, through a makeappx mapping file, with:
  - `msix\AppxManifest.xml` filled in;
  - logos drawn from the Mac app's icon;
  - a `resources.pri` that merges `Garage.pri` (the app's XAML and strings) with the logos;
  - the Visual C++ runtime DLLs in `postgres\bin`.

  `makeappx`, `makepri` and `signtool` come from the `Microsoft.Windows.SDK.BuildTools` package the app
  already restores, so no Windows SDK install is needed.
- **`msi.ps1`** builds `msi\Garage.Installer.wixproj`, then `setup\Garage.Setup.wixproj` around it,
  with the .NET SDK. It uses WiX v5, which is MS-RL with no maintenance-fee EULA; v6 and later ask
  organizations to accept one. WiX's command-line tool is pinned to the same version in
  `dotnet-tools.json`.

The version defaults to `garage_python/pyproject.toml`'s; pass `-Version X.Y.Z` to every script to
override it. `-Arch arm64` builds for ARM64 once arm64 builds of Python and Postgres exist.

CI builds all three, unsigned, in `windows.yaml`'s `package` job (artifact `garage-windows-x64`).

## The Visual C++ runtime

Postgres and ICU import `msvcp140`, `vcruntime140` and `vcruntime140_1`, which a clean Windows lacks.
The runtime has to be at least as new as the MSVC toolset that built them. Microsoft supports no
older pairing, and code built with 14.40 or later crashes in `std::mutex` on an older `msvcp140`.
The scripts read that toolset from the Postgres binaries' PE headers (`Get-RequiredVCRuntime`), so
a newer CI image moves the requirement with it.

The runtime always comes from Microsoft's signed Redistributable, never from a Visual Studio
install. The scripts download the newest from `https://aka.ms/vc14/vc_redist.<arch>.exe` into
`out\vcredist`, check that Microsoft signed it and that it is new enough, and use it three ways:

- **MSIX:** WiX unpacks its Minimum Runtime DLLs into the package's `postgres\bin`. An MSIX cannot
  run an installer, and Microsoft's framework package for MSIX (`Microsoft.VCLibs.140.00.UWPDesktop`)
  stops at 14.39, older than the toolset.
- **`Garage-Setup.exe`:** carries the Redistributable unmodified, and runs it when `msvcp140.dll` in
  System32 is missing or older than required. It is never uninstalled with Garage, since other
  programs share it.
- **The bare MSI:** refuses to install without the runtime, and names Microsoft's download. IT
  deploys the Redistributable first, as it does for other software that needs it.

Delete `out\vcredist` to fetch a newer Redistributable, or pass `-VCRedist <path>` to build offline.

## Release

### Microsoft Store

1. In Partner Center, reserve the name. **Product management > Product identity** then gives
   `Package/Identity/Name`, `Package/Identity/Publisher` and `Package/Properties/PublisherDisplayName`.
2. Build with those, unsigned (the Store signs):
   ```powershell
   .\msix.ps1 -IdentityName 12345Example.Garage -Publisher 'CN=0A1B2C3D-...' -PublisherDisplayName 'Example'
   ```
3. Upload the `.msix` to a submission.
   - `runFullTrust` is a restricted capability, and the submission asks why. Garage is a desktop app:
     it reads the folders the person adds, and runs its own Postgres and service processes.
   - To ship x64 and arm64 together, bundle them first:
     `makeappx bundle /d <folder with both .msix> /p Garage_X.Y.Z.0.msixbundle`.

The package version is `X.Y.Z.0`: the Store reserves the fourth part.

### Direct download (App Installer)

Sign with a certificate whose subject is exactly `-Publisher`. Use an EV certificate or Azure
Trusted Signing, because a self-signed one only installs where it has been trusted by hand. Then
write the feed:

```powershell
.\msix.ps1 -Publisher 'CN=Example, O=Example, C=US' -CertificateThumbprint <sha1> `
    -AppInstallerUri https://garagerag.app/windows/garage.appinstaller
```

Publish `garage.appinstaller` and the `.msix` side by side at that URL. Settings' channel picker
already points at `garage.appinstaller` and `garage-beta.appinstaller` there (`UpdateFeeds`). Keep
`-IdentityName` and `-Publisher` fixed across releases: App Installer only updates a package with
the same identity.

### MSI

```powershell
.\msi.ps1 -CertificateThumbprint <sha1>
```

Never change the `UpgradeCode` in `msi\Package.wxs`: it is how a newer MSI finds the installed one.
Raise the version for each release. Windows Installer compares only `X.Y.Z`.

## Trying a build locally

- **MSI.** `msiexec /i out\Garage-X.Y.Z-x64.msi` installs it. Run
  `msiexec /a <msi> TARGETDIR=C:\gx ROOTDRIVE=C:\ /qn` to unpack it without installing, and keep the
  target short: paths in the payload reach 110 characters.
- **MSIX.** It needs a signature Windows trusts. Make a test certificate whose subject is the default
  publisher, trust it on this machine (as administrator), sign, and install:
  ```powershell
  $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Garage Development' `
      -CertStoreLocation Cert:\CurrentUser\My -TextExtension @('2.5.29.19={text}')
  Export-Certificate -Cert $cert -FilePath garage-dev.cer
  Import-Certificate -FilePath garage-dev.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople   # elevated
  .\msix.ps1 -CertificateThumbprint $cert.Thumbprint
  Add-AppxPackage out\Garage_X.Y.Z.0_x64.msix
  ```

## Not yet

- **Launchers.** `garage.exe` and `garage-mcp.exe` do not exist yet. When they do, add them to the
  stage and declare them as app execution aliases (`uap5:AppExecutionAlias`) in the manifest
  (windows.md section 2.7).
- **More natives.** llama.cpp, Tesseract and Leptonica have no Windows builds yet. Each joins the
  stage once `windows.yaml` builds it.
- **A locked environment.** `site-packages` is resolved from `pyproject.toml` at stage time, because
  `uv.lock` has no Windows environment yet (windows.md section 4).
- **Closing Garage on upgrade.** Postgres runs detached from the app, so an MSI upgrade or uninstall
  with Garage running finds its files in use and asks for a restart. Quit Garage first.
