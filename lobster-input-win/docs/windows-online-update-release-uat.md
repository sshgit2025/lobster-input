# Windows 在线更新与发布流程(uat 公测环境)

本文档只覆盖 **uat 环境**(公测环境,对外发布,客户端徽章显示"正式版")。preview 内测环境见 `windows-online-update-release-preview.md`,两环境的包与清单绝不交叉。

Windows 端使用 Velopack 作为安装、更新、差分包和重启应用更新的唯一方案,更新文件发布到 Cloudflare R2。

## 环境信息

- 后端 API:`https://api.example.com/lobster`(客户端编译常量 `LOBSTER_UAT` 激活 `ApiConfig.Uat`)
- 更新源(客户端读取):`https://downloads.example.com/uat/windows`
- R2 上传前缀:`uat/windows`(新布局 `<env>/<platform>`,环境在前)
- 客户端环境徽章:设置页版本号旁显示"正式版"(由 `ApiConfig.EnvName` 派生,随语言包本地化)

> 历史说明:旧前缀 `windows/preview`、`windows/prod`(平台在前的旧布局)已弃用,不要再向其上传任何文件。Windows 端此前未对外发过版,无老用户迁移问题。

发布脚本会根据 `-Environment uat` 自动注入编译常量 `LOBSTER_UAT`、选择 Velopack channel 和 R2 上传目录,不需要手动改代码。

## 首次准备

安装 Velopack CLI:

```powershell
dotnet tool install --global vpk
```

安装 Inno Setup 6,用于生成带标准安装向导的外层安装包:

```powershell
winget install JRSoftware.InnoSetup
```

如果机器没有 `winget`,可从 Inno Setup 官网安装:https://jrsoftware.org/isdl.php

如果已经安装过,可以升级:

```powershell
dotnet tool update --global vpk
```

配置 Cloudflare R2 上传环境变量:

```powershell
$env:R2_ENDPOINT = "https://YOUR_CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
$env:R2_BUCKET = "lobster-mac"
$env:R2_KEY_ID = "YOUR_SECRET_FROM_SECRET_STORE"
$env:R2_SECRET = "YOUR_SECRET_FROM_SECRET_STORE"
```

Windows 发布文档自包含 R2 上传配置。uat 与 preview 的更新文件复用同一个 R2 bucket,通过 `uat/windows` 和 `preview/windows` 前缀隔离;不要再到 Mac 或 Android 发布文档查 Windows 上传参数。后续更换 R2 配置时,只需要替换这一组变量和 `ApiConfig` 里的公开更新源。

当前发布脚本只从以上环境变量或同名命令行参数读取密钥,不把密钥写进客户端包体。如果需要固定在某台发布机上,可以把这些值写入该机器的 PowerShell Profile,或在执行发布前手动设置:

```powershell
.\scripts\release-windows-velopack.ps1 `
  -Version 1.0.0 `
  -Environment uat `
  -OutputDir .\Releases `
  -Upload `
  -R2Endpoint "https://YOUR_CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com" `
  -R2Bucket "lobster-mac" `
  -R2KeyId "YOUR_SECRET_FROM_SECRET_STORE" `
  -R2Secret "YOUR_SECRET_FROM_SECRET_STORE"
```

R2 bucket 需要允许客户端通过公开 URL 读取对应目录下的 release 文件。

## 发布 uat

只生成本地安装包和更新包:

```powershell
.\scripts\release-windows-velopack.ps1 -Version 1.0.0 -Environment uat -OutputDir .\Releases
```

生成并上传到 R2:

```powershell
.\scripts\release-windows-velopack.ps1 -Version 1.0.0 -Environment uat -OutputDir .\Releases -Upload
```

上传后客户端会从 `uat/windows` 目录读取更新。

## 版本递增规范

- 版本号为 SemVer(如 `1.0.0`),同一环境内必须单调递增,不能重复发布相同版本号。
- uat 与 preview 版本号相互独立,但同一个版本号不要在两个环境复用,避免排查问题时混淆。
- 发布 uat 前确认要发布的代码已合入正确分支并通过 `dotnet build .\LobsterInput.sln -c Debug`。

## 安装包名称

Velopack 包 ID 固定为 `lobster-input`,安装器展示名称固定为 `龙虾输入法`。channel 默认等于环境名(uat)。

外层安装器是多语言安装器。启动安装包时会先显示语言选择窗口,默认会按 Windows 当前 UI 语言预选;用户也可以手动切换。当前安装器覆盖:

- English
- 简体中文
- 繁體中文
- 粵語(廣東省版)
- 한국어
- Русский

生成后重点关注这些文件:

- `龙虾输入法-uat-<version>-Setup.exe`:正式对用户发布的安装包,包含许可协议、安装目录、桌面快捷方式可选项、开机自启可选项、重复安装检测和卸载入口
- `lobster-input-uat-Setup.exe`:Velopack 内层安装包,不直接发给普通用户
- `releases.uat.json`:在线更新 feed
- `lobster-input-<version>-full.nupkg`:完整更新包
- `lobster-input-<version>-delta.nupkg`:差分更新包,存在历史版本时生成

## 自定义安装目录

Velopack 的 `Setup.exe` 支持通过命令行指定安装目录,在线更新仍然会在该安装目录内继续工作:

```powershell
.\龙虾输入法-uat-1.0.0-Setup.exe
```

普通用户双击安装时可以在安装向导中选择安装目录。默认目录是当前用户目录下的 `AppData\Local\Programs\lobster-input`,这样后续在线更新不需要管理员权限,体验更稳定。

安装向导的"附加任务"页面提供:

- 创建桌面快捷方式:默认按安装器历史选择记忆,首次安装会勾选。
- 开机时自动启动龙虾输入法:默认不勾选,需要用户明确选择;安装后也可以在客户端 `设置` 页随时开启或关闭。

开机自启使用当前用户级 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`,不需要管理员权限。正式安装环境写入 `{install}\app\Update.exe start`,保证 Velopack 更新后启动入口仍稳定。

如果需要命令行静默指定目录,可使用内层 Velopack 安装包:

```powershell
.\lobster-input-uat-Setup.exe --silent --installto "D:\Apps\lobster-input"
```

对外分发仍建议使用 `龙虾输入法-uat-<version>-Setup.exe`。

## 发布前检查

每次发布前至少执行:

```powershell
dotnet build .\LobsterInput.sln -c Debug
```

然后生成 uat 安装包并在测试机安装:

```powershell
.\scripts\release-windows-velopack.ps1 -Version <new-version> -Environment uat -OutputDir .\Releases
.\Releases\uat\龙虾输入法-uat-<new-version>-Setup.exe
```

安装完成后检查:

- 登录、引导页、主界面能正常打开,请求走 `https://api.example.com/lobster`
- 设置页版本号旁显示环境徽章"正式版"(英文界面为 Official)
- 安装器语言选择、许可协议语言和"附加任务"文案能随选择语言变化
- 许可协议里的官网、用户服务协议、隐私政策链接分别指向 `https://example.com`、`https://example.com/terms.html`、`https://example.com/privacy.html`
- 托盘菜单、主窗口菜单、设置页都能点击"检查更新"
- 当前版本无更新时会显示"当前已是最新版本"
- 发布更高版本到 uat 环境后,旧版本能检查到更新并完成重启更新,且更新请求指向 `uat/windows`
- 安装向导可以选择是否创建桌面快捷方式、是否开机自启
- 设置页可以手动开启和关闭开机自启
- 再次运行正式安装包时,会提示已安装,并允许选择卸载后重装、覆盖修复或取消
- 安装目录、开始菜单、Windows 设置 > 应用中都能找到卸载入口

## 注意事项

- 不再维护 `windows-update.json`,也不要新增备用更新策略。
- uat 和 preview 使用不同更新目录(`uat/windows` / `preview/windows`),不能混传;uat 客户端的 feed 永不指向 preview 的包。
- 同一环境的版本号必须递增,不能重复发布相同版本号。
- 如果需要测试在线更新,必须先用 Velopack 安装包安装应用;直接运行 `bin\Debug` 或 `dotnet run` 的开发版无法在线更新。
