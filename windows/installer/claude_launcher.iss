; Установщик Claude Launcher для Windows (Inno Setup 6).
;
; Сборка (после `flutter build windows --release`), из корня репозитория:
;   iscc /DAppVersion=1.0.0 windows\installer\claude_launcher.iss
; Готовый установщик: build\installer\ClaudeLauncher-Setup-<версия>.exe
;
; Ставит для текущего пользователя, без прав администратора: лаунчер и так
; работает только с данными пользователя (%APPDATA%, реестр HKCU).

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#define AppName "Claude Launcher"
#define AppExe "claude_launcher.exe"
#define ReleaseDir "..\..\build\windows\x64\runner\Release"

[Setup]
; Постоянный идентификатор: по нему Windows узнаёт обновление той же программы.
AppId={{6F3B2C1E-8C4A-4F1B-9C57-2D6A7E91B4C3}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=NotCode
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\installer
OutputBaseFilename=ClaudeLauncher-Setup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Лаунчер держит мьютекс «один экземпляр» — по нему установщик и деинсталлятор
; видят, что лаунчер запущен, и просят его закрыть.
AppMutex=ClaudeLauncher.SingleInstance
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "startup"; Description: "Запускать {#AppName} при входе в Windows"; GroupDescription: "Автозапуск:"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: startup

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Убирает хуки лаунчера из ~/.claude/settings.json и возвращает значок Claude
; в трей. Профили Claude и их данные не трогает.
Filename: "{app}\{#AppExe}"; Parameters: "--cleanup"; Flags: runhidden waituntilterminated; RunOnceId: "ClaudeLauncherCleanup"
