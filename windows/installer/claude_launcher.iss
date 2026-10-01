; Установщик ClaudeLauncher для Windows (Inno Setup 6).
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

#define AppName "ClaudeLauncher"
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
; Значок приложения в углу мастера: область 58 px при 100 % масштаба, до 159 px
; при 250 % — установщик выберет подходящий файл (рисует tool/generate_icons.py).
WizardSmallImageFile=wizard_small_58.bmp,wizard_small_87.bmp,wizard_small_116.bmp,wizard_small_159.bmp
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

[InstallDelete]
; Ярлыки версий до переименования в ClaudeLauncher. Папку установки обновление
; сохраняет прежнюю — по AppId.
Type: files; Name: "{userprograms}\Claude Launcher.lnk"
Type: files; Name: "{userdesktop}\Claude Launcher.lnk"
Type: files; Name: "{userstartup}\Claude Launcher.lnk"

[Icons]
Name: "{userprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{userdesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon
Name: "{userstartup}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: startup

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
; Обновление из самого лаунчера (/update=1): он уже вышел — запускаем новую версию.
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: IsUpdate

[UninstallRun]
; Убирает хуки лаунчера из ~/.claude/settings.json и возвращает значок Claude
; в трей. Профили Claude и их данные не трогает.
Filename: "{app}\{#AppExe}"; Parameters: "--cleanup"; Flags: runhidden waituntilterminated; RunOnceId: "ClaudeLauncherCleanup"

[Code]
// Обновление из лаунчера: он запускает установщик и сразу выходит.
function IsUpdate: Boolean;
begin
  Result := ExpandConstant('{param:update|0}') = '1';
end;

// Ждём, пока лаунчер выйдет и отпустит мьютекс «один экземпляр», — до 15 секунд.
function InitializeSetup: Boolean;
var
  I: Integer;
begin
  if IsUpdate then
  begin
    I := 0;
    while CheckForMutexes('ClaudeLauncher.SingleInstance') and (I < 75) do
    begin
      Sleep(200);
      I := I + 1;
    end;
  end;
  Result := True;
end;
