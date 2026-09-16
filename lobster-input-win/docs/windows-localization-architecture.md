# Windows 国际化架构

Windows 端国际化采用 `Facade + Registry + Provider` 的结构。

## 分层

- `LobsterInput.Helpers.L10n` 是 UI 层唯一入口，保留 `L10n.SidebarHome` 这类静态属性，避免页面和 ViewModel 感知底层语言包结构。
- `LocalizationRegistry` 是语言包注册表，负责按当前语言取文案，并按顺序执行回退：当前语言 -> 简中（繁中/粤语）-> 英文 -> 简中。
- `LocalizationPack` 是语种 Provider 基类，每个语种一个独立 Pack，例如 `ZhLocalizationPack`、`EnLocalizationPack`。
- `Localization/Packs/*.Core.cs` 是当前迁移后的核心文案文件。语种类都是 `partial`，后续可以继续按模块拆成 `*.Settings.cs`、`*.Onboarding.cs`、`*.History.cs` 等文件。

## 新增语种

1. 在 `LanguageManager.AppLanguage` 中新增枚举值。
2. 补充 `GetLanguageCode`、`GetDisplayName`、`TryParseCode`、`DetectSystemLanguage`。
3. 新增 `Localization/Packs/{Lang}LocalizationPack.cs`，继承 `LocalizationPack`。
4. 新增 `{Lang}LocalizationPack.Core.cs` 或按模块拆分的文案文件。
5. 在 `LocalizationRegistry.CreateDefault()` 注册新的 Pack。
6. 运行 `dotnet build .\LobsterInput.sln -c Debug` 检查编译。

## 文案拆分约定

新增大量文案时不要继续堆进一个大文件。推荐按页面或功能域拆分：

- `*.Shell.cs`：侧边栏、标题、通用状态。
- `*.Auth.cs`：登录、邀请码、协议。
- `*.Home.cs`：首页、快捷键、主流程。
- `*.Settings.cs`：设置页、更新、反馈。
- `*.Onboarding.cs`：引导页。
- `*.History.cs`：历史记录。
- `*.Overlay.cs`：录音、识别、搜索、改写浮窗。

同一个 key 只允许在同一语种内出现一次；如果必须覆盖，应该先删除旧 key，避免翻译来源不清晰。
