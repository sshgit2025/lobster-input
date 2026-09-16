#define MyAppId "lobster-input-installer"
#define MyVeloPackId "lobster-input"
#define MyAppName "龙虾输入法"
#define MyAppPublisher "行唐县落云网络工作室"
#define MyAppURL "https://example.com"
#define MyAppExeName "LobsterInput.exe"
#define InnerSetupFile "..\Releases\" + Channel + "\lobster-input-" + Channel + "-Setup.exe"

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={localappdata}\Programs\lobster-input
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
SetupIconFile=..\LobsterInput\Resources\Images\lobster.ico
UninstallDisplayIcon={app}\app\current\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
UninstallFilesDir={app}
OutputDir=..\Releases\{#Channel}
OutputBaseFilename=龙虾输入法-{#Channel}-{#AppVersion}-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=yes
DisableProgramGroupPage=no
DisableReadyPage=no
DisableFinishedPage=no
CloseApplications=yes
RestartApplications=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"; LicenseFile: "license-en.txt"
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"; LicenseFile: "license-zh.txt"
Name: "zhhant"; MessagesFile: "ChineseTraditional.isl"; LicenseFile: "license-zh-Hant.txt"
Name: "yue"; MessagesFile: "Cantonese.isl"; LicenseFile: "license-yue.txt"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"; LicenseFile: "license-ko.txt"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"; LicenseFile: "license-ru.txt"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopShortcut}"; GroupDescription: "{cm:AdditionalTasks}"; Flags: checkedonce
Name: "startup"; Description: "{cm:LaunchAtStartup}"; GroupDescription: "{cm:AdditionalTasks}"

[Files]
Source: "{#InnerSetupFile}"; DestDir: "{tmp}"; DestName: "velopack-setup.exe"; Flags: deleteafterinstall

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\app\Update.exe"; Parameters: "start"; WorkingDir: "{app}\app"; IconFilename: "{app}\app\current\{#MyAppExeName}"
Name: "{group}\{cm:UninstallShortcut}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\app\Update.exe"; Parameters: "start"; WorkingDir: "{app}\app"; IconFilename: "{app}\app\current\{#MyAppExeName}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "LobsterInput"; ValueData: """{app}\app\Update.exe"" start"; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{tmp}\velopack-setup.exe"; Parameters: "--silent --installto ""{app}\app"""; StatusMsg: "{cm:InstallingApp}"; Flags: waituntilterminated
Filename: "{app}\app\Update.exe"; Parameters: "start"; Description: "{cm:LaunchApp}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\app\Update.exe"; Parameters: "uninstall --silent"; Flags: waituntilterminated skipifdoesntexist; RunOnceId: "VelopackUninstall"
Filename: "{cmd}"; Parameters: "/C timeout /T 4 /NOBREAK >nul & rmdir /S /Q ""{app}\app"""; Flags: runhidden waituntilterminated; RunOnceId: "VelopackCleanup"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[CustomMessages]
english.AppDisplayName=Lobster Input
english.AdditionalTasks=Additional tasks:
english.CreateDesktopShortcut=Create a desktop shortcut
english.LaunchAtStartup=Start Lobster Input when I sign in to Windows
english.InstallingApp=Installing Lobster Input...
english.LaunchApp=Launch Lobster Input
english.UninstallShortcut=Uninstall Lobster Input
english.ExistingInstallTitle=Existing installation detected
english.ExistingInstallIntro=Lobster Input is already installed on this computer.
english.ExistingInstallYes=Choose "Yes" to uninstall the old version first, then continue installation.
english.ExistingInstallNo=Choose "No" to install over or repair the current installation.
english.ExistingInstallCancel=Choose "Cancel" to exit Setup.

chinesesimp.AppDisplayName=龙虾输入法
chinesesimp.AdditionalTasks=附加任务：
chinesesimp.CreateDesktopShortcut=创建桌面快捷方式
chinesesimp.LaunchAtStartup=开机时自动启动龙虾输入法
chinesesimp.InstallingApp=正在安装 龙虾输入法...
chinesesimp.LaunchApp=启动 龙虾输入法
chinesesimp.UninstallShortcut=卸载龙虾输入法
chinesesimp.ExistingInstallTitle=检测到已安装版本
chinesesimp.ExistingInstallIntro=检测到本机已经安装过龙虾输入法。
chinesesimp.ExistingInstallYes=选择“是”：先卸载旧版本，然后继续安装。
chinesesimp.ExistingInstallNo=选择“否”：直接覆盖安装/修复当前安装。
chinesesimp.ExistingInstallCancel=选择“取消”：退出安装程序。

zhhant.AppDisplayName=龍蝦輸入法
zhhant.AdditionalTasks=附加工作：
zhhant.CreateDesktopShortcut=建立桌面捷徑
zhhant.LaunchAtStartup=Windows 登入時自動啟動龍蝦輸入法
zhhant.InstallingApp=正在安裝 龍蝦輸入法...
zhhant.LaunchApp=啟動 龍蝦輸入法
zhhant.UninstallShortcut=解除安裝龍蝦輸入法
zhhant.ExistingInstallTitle=偵測到已安裝版本
zhhant.ExistingInstallIntro=偵測到本機已經安裝過龍蝦輸入法。
zhhant.ExistingInstallYes=選擇「是」：先解除安裝舊版本，然後繼續安裝。
zhhant.ExistingInstallNo=選擇「否」：直接覆蓋安裝/修復目前安裝。
zhhant.ExistingInstallCancel=選擇「取消」：退出安裝程式。

yue.AppDisplayName=龍蝦輸入法
yue.AdditionalTasks=附加工作：
yue.CreateDesktopShortcut=建立桌面捷徑
yue.LaunchAtStartup=Windows 登入時自動啟動龍蝦輸入法
yue.InstallingApp=正在安裝 龍蝦輸入法...
yue.LaunchApp=啟動 龍蝦輸入法
yue.UninstallShortcut=解除安裝龍蝦輸入法
yue.ExistingInstallTitle=偵測到已安裝版本
yue.ExistingInstallIntro=偵測到本機已經安裝過龍蝦輸入法。
yue.ExistingInstallYes=揀「是」：先解除安裝舊版本，然後繼續安裝。
yue.ExistingInstallNo=揀「否」：直接覆蓋安裝/修復目前安裝。
yue.ExistingInstallCancel=揀「取消」：退出安裝程式。

korean.AppDisplayName=Lobster Input
korean.AdditionalTasks=추가 작업:
korean.CreateDesktopShortcut=바탕 화면 바로가기 만들기
korean.LaunchAtStartup=Windows 로그인 시 Lobster Input 자동 시작
korean.InstallingApp=Lobster Input을 설치하는 중...
korean.LaunchApp=Lobster Input 실행
korean.UninstallShortcut=Lobster Input 제거
korean.ExistingInstallTitle=기존 설치가 감지되었습니다
korean.ExistingInstallIntro=이 컴퓨터에 Lobster Input이 이미 설치되어 있습니다.
korean.ExistingInstallYes="예"를 선택하면 이전 버전을 먼저 제거한 후 설치를 계속합니다.
korean.ExistingInstallNo="아니요"를 선택하면 현재 설치를 덮어쓰거나 복구합니다.
korean.ExistingInstallCancel="취소"를 선택하면 설치 프로그램을 종료합니다.

russian.AppDisplayName=Lobster Input
russian.AdditionalTasks=Дополнительные задачи:
russian.CreateDesktopShortcut=Создать ярлык на рабочем столе
russian.LaunchAtStartup=Запускать Lobster Input при входе в Windows
russian.InstallingApp=Установка Lobster Input...
russian.LaunchApp=Запустить Lobster Input
russian.UninstallShortcut=Удалить Lobster Input
russian.ExistingInstallTitle=Обнаружена установленная версия
russian.ExistingInstallIntro=Lobster Input уже установлен на этом компьютере.
russian.ExistingInstallYes=Выберите «Да», чтобы сначала удалить старую версию, а затем продолжить установку.
russian.ExistingInstallNo=Выберите «Нет», чтобы установить поверх текущей версии или восстановить ее.
russian.ExistingInstallCancel=Выберите «Отмена», чтобы выйти из установщика.

[Code]
const
  InstallerUninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#MyAppId}_is1';
  VelopackUninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#MyVeloPackId}';
  StartupRunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  StartupRunValue = 'LobsterInput';

function GetExistingUninstallCommand(): String;
var
  value: String;
begin
  Result := '';
  if RegQueryStringValue(HKCU, InstallerUninstallKey, 'UninstallString', value) then begin
    Result := RemoveQuotes(value);
    exit;
  end;

  if RegQueryStringValue(HKCU, VelopackUninstallKey, 'UninstallString', value) then begin
    Result := value;
    exit;
  end;
end;

procedure RunExistingUninstaller(command: String);
var
  resultCode: Integer;
begin
  if command = '' then
    exit;

  if Pos('Update.exe', command) > 0 then
    Exec(ExpandConstant('{cmd}'), '/C ' + command + ' --silent', '', SW_HIDE, ewWaitUntilTerminated, resultCode)
  else
    Exec(command, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_SHOWNORMAL, ewWaitUntilTerminated, resultCode);
end;

function InitializeSetup(): Boolean;
var
  command: String;
  answer: Integer;
begin
  Result := True;
  command := GetExistingUninstallCommand();
  if command = '' then
    exit;

  answer := MsgBox(
    CustomMessage('ExistingInstallIntro') + #13#10#13#10 +
    CustomMessage('ExistingInstallYes') + #13#10 +
    CustomMessage('ExistingInstallNo') + #13#10 +
    CustomMessage('ExistingInstallCancel'),
    mbConfirmation,
    MB_YESNOCANCEL);

  if answer = IDCANCEL then begin
    Result := False;
    exit;
  end;

  if answer = IDYES then
    RunExistingUninstaller(command);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    RegDeleteKeyIncludingSubkeys(HKCU, VelopackUninstallKey);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    RegDeleteValue(HKCU, StartupRunKey, StartupRunValue);
  end;
end;
