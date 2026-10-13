# Builds the Windows release and packages it as a portable .zip in dist/.
#
#   powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$version = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*([^+\s]+)').Matches[0].Groups[1].Value)
$name = "catplay-v$version-windows-x64"

flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }

$stage = Join-Path ([IO.Path]::GetTempPath()) $name
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
Copy-Item -Recurse build\windows\x64\runner\Release $stage
Rename-Item (Join-Path $stage 'iptv_player.exe') 'CAT.exe'

New-Item -ItemType Directory -Force dist | Out-Null
$zip = "dist\$name.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Remove-Item -Recurse -Force $stage
Get-Item $zip | Select-Object Name, @{n='MB';e={[math]::Round($_.Length / 1MB, 1)}}
