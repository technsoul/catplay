; Inno Setup script for the Windows installer. Built by tool\package_windows.ps1:
;   ISCC /DAppVersion=0.1.2 /DSourceDir=<release folder> /DOutputDir=dist tool\windows_installer.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6B8E2C4A-9F1D-4E7B-A3C5-2D8F0E1B7C94}
AppName=CAT
AppVersion={#AppVersion}
AppPublisher=CAT
DefaultDirName={autopf}\CAT
DefaultGroupName=CAT
DisableProgramGroupPage=yes
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=catplay-v{#AppVersion}-windows-x64-setup
SetupIconFile=..\desktop\assets\app_icon.ico
UninstallDisplayIcon={app}\CAT.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Files of the older Flutter build, replaced by the Rust app.
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\flutter_windows.dll"
Type: files; Name: "{app}\*_plugin.dll"
Type: files; Name: "{app}\sqlite3.dll"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\CAT"; Filename: "{app}\CAT.exe"
Name: "{autodesktop}\CAT"; Filename: "{app}\CAT.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\CAT.exe"; Description: "{cm:LaunchProgram,CAT}"; Flags: nowait postinstall skipifsilent
