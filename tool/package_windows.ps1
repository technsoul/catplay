# Builds the Rust desktop app and packages it as an installer (.exe) in dist/.
# Needs Rust, Inno Setup 6 (https://jrsoftware.org/isinfo.php, or `choco install innosetup`)
# and libmpv-2.dll in desktop\mpv\ (from https://github.com/shinchiro/mpv-winbuild-cmake/releases,
# the mpv-dev-x86_64-*.7z archive).
#
#   powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$version = ((Select-String -Path desktop\Cargo.toml -Pattern '^version = "(.+)"').Matches[0].Groups[1].Value)

Push-Location desktop
cargo build --release --locked
if ($LASTEXITCODE -ne 0) { throw 'cargo build failed' }
Pop-Location

$mpv = Get-ChildItem -Recurse desktop\mpv -Filter libmpv-2.dll | Select-Object -First 1
if (-not $mpv) { throw 'libmpv-2.dll not found in desktop\mpv' }

$stage = Join-Path ([IO.Path]::GetTempPath()) "catplay-$version-windows"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory $stage | Out-Null
Copy-Item desktop\target\release\catplay.exe (Join-Path $stage 'CAT.exe')
Copy-Item $mpv.FullName $stage

$iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
if (-not (Test-Path $iscc)) { throw 'Inno Setup 6 (ISCC.exe) not found' }

New-Item -ItemType Directory -Force dist | Out-Null
$out = (Resolve-Path dist).Path
& $iscc /Q "/DAppVersion=$version" "/DSourceDir=$stage" "/DOutputDir=$out" tool\windows_installer.iss
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }
Remove-Item -Recurse -Force $stage
Get-ChildItem dist\*-setup.exe | Select-Object Name, @{n='MB';e={[math]::Round($_.Length / 1MB, 1)}}
