; Inno Setup 6 script for the Windows installer of GOTTA.BIKE: BLE Watts.
;
; Built by tool/build_windows.ps1, which passes the version and the folder
; holding the release build (exe, flutter_windows.dll, plugin DLLs, data\
; and the app-local VC++ runtime):
;
;   ISCC.exe /DAppVersion=1.2.0 /DSourceDir=C:\...\Release /OC:\...\dist setup.iss
;
; Installs per user by default (no admin prompt), into
; %LOCALAPPDATA%\Programs\GOTTA.BIKE BLE Watts; choosing "all users" in the
; dialog installs into Program Files instead. Upgrades in place: keep AppId
; unchanged forever, or Windows treats a new version as a different app.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<the build\windows\x64\runner\Release folder>
#endif

; Shortcut and folder names can't contain ':', so they use this name.
#define AppName "GOTTA.BIKE BLE Watts"
#define AppExe "gotta_bike_ble_watts.exe"

[Setup]
AppId={{80EC89AB-EAAF-4C30-9B1B-3970FD2CAB78}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=GOTTA.BIKE
AppPublisherURL=https://github.com/vincentdavis/GOTTA.BIKE-BLE-Watts
AppSupportURL=https://github.com/vincentdavis/GOTTA.BIKE-BLE-Watts/issues
VersionInfoVersion={#AppVersion}
VersionInfoProductName=GOTTA.BIKE: BLE Watts
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; x64 build; Windows 11 on ARM runs it under emulation.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 1809 (build 17763): share_plus needs it to share files, and
; the BLE peripheral role (GattServiceProvider) is reliable from there on.
MinVersion=10.0.17763
LicenseFile=..\..\LICENSE
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
OutputBaseFilename=GOTTA.BIKE-BLE-Watts-{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Close a running copy before replacing its files.
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
