# Builds the Windows release and packages it as an installer (.exe) in dist/.
# Needs Inno Setup 6 (https://jrsoftware.org/isinfo.php, or `choco install innosetup`).
#
#   powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$version = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*([^+\s]+)').Matches[0].Groups[1].Value)

flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }

$stage = Join-Path ([IO.Path]::GetTempPath()) "catplay-$version-windows"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
Copy-Item -Recurse build\windows\x64\runner\Release $stage
Rename-Item (Join-Path $stage 'iptv_player.exe') 'CAT.exe'

$iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
if (-not (Test-Path $iscc)) { throw 'Inno Setup 6 (ISCC.exe) not found' }

New-Item -ItemType Directory -Force dist | Out-Null
$out = (Resolve-Path dist).Path
& $iscc /Q "/DAppVersion=$version" "/DSourceDir=$stage" "/DOutputDir=$out" tool\windows_installer.iss
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed' }
Remove-Item -Recurse -Force $stage
Get-ChildItem dist\*-setup.exe | Select-Object Name, @{n='MB';e={[math]::Round($_.Length / 1MB, 1)}}
