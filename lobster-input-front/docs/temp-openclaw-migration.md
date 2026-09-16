# OpenClaw 集成方案文档（临时，不提交 git）

> 本文档整理了 feature/diy-customization 分支上已验证可用的 OpenClaw 集成方案，
> 用于指导在 feature/standard 分支上的同款实现。

---

## 一、功能概述

在首页新增 OpenClaw AI 编程代理区域，支持：

1. **一键安装**：检测未安装时展示安装卡片，调用官方安装脚本
2. **启动 Gateway**：检测已安装但服务未运行时展示，智能选择 start/install
3. **停止 Gateway**：运行中时展示，执行 gateway stop（保留 launchd 注册）
4. **卸载**：安装状态下（运行/未运行）均显示卸载按钮
5. **语音操控 OpenClaw**：激活会话后，语音指令通过 Gateway RPC 发送给 OpenClaw

---

## 二、客户端架构

### 新增文件

#### `voice-input/Core/OpenClaw/OpenClawManager.swift`
- 单例，管理安装检测、Gateway 生命周期、Gateway RPC 通信
- `OpenClawStatus` 枚举：`unknown / notInstalled / installedServiceDown / ready`
- `statusString`：上报给后端的字符串（`not_installed / service_down / installed`）
- 关键方法：
  - `isInstalled()`：binary 可访问 AND `~/.openclaw` 目录存在
  - `isGatewayRunning()`：执行 `openclaw gateway status --json --require-rpc --deep` 并检查 `rpc.ok`
  - `ensureGatewayModeConfigured()`：自动写入 `gateway.mode=local`
  - `launchInstaller()`：新终端执行 curl 安装脚本
  - `startGateway()`：优先 `openclaw gateway start --json`，失败后 `openclaw gateway install --json`，再降级 `openclaw gateway run --force`
  - `stopGateway()`：`openclaw gateway stop --json`
  - `launchUninstaller()`：`openclaw gateway stop --json || true; openclaw uninstall --all --yes --non-interactive; npm rm -g openclaw`
  - `readGatewayCredential()`：读取 `~/.openclaw/openclaw.json` 中 `gateway.auth.token/password`
  - `sendToOpenClaw(_ text: String)`：自然语言任务，走 `gateway call sessions.send --expect-final`
  - `sendCommandToOpenClaw(_ command: String)`：`/stop`/`abort`/`cancel`→`gateway call sessions.abort`，交互式→新终端，CLI→复用终端

#### `voice-input/Core/OpenClaw/OpenClawGatewayClient.swift`
- 单例，Gateway RPC 通信
- 发送：`openclaw gateway call sessions.send --expect-final --timeout 120000 --json --params ...`
- 中断：`openclaw gateway call sessions.abort --timeout 10000 --json --params ...`
- 会话：客户端启动生成 `voiceinput:<uuid>`，同一 key 复用会话，开启新会话时切换 key
- 事件：`GatewayAgentEvent.text(chunk, accumulated) / .done(full) / .error(msg)`

### 修改文件

#### `voice-input/Models/APIModels.swift`
`ActionType` 枚举新增：
```swift
case openclawExecute = "openclaw_execute"          // 自然语言任务 → Gateway RPC
case openclawSlashCommand = "openclaw_slash_command" // /stop 等 → Gateway RPC
case openclawCliCommand = "openclaw_cli_command"     // 无交互 CLI → 复用终端
case openclawInteractive = "openclaw_interactive"    // 交互式 CLI → 新建终端
case openclawCommand = "openclaw_command"            // @deprecated 向后兼容
```

#### `voice-input/Core/Network/APIClient.swift`
- `processAudio()` 新增 `openclawStatus` 参数（`OpenClawManager.shared.statusString`）
- `buildMultipartBody()` 新增 `openclawStatus: String?` 字段，写入 `openclaw_status` 表单字段

#### `voice-input/Core/HotKey/AppHotKeyHandler.swift`
`handleAction()` 新增路由：
```swift
case .openclawExecute:
    OpenClawManager.shared.sendToOpenClaw(text)
case .openclawSlashCommand, .openclawCliCommand, .openclawInteractive, .openclawCommand:
    OpenClawManager.shared.sendCommandToOpenClaw(text)
```
tip 处理：`L10n.tipForCode(text)` 已支持 OPENCLAW_* 系列 code

#### `voice-input/Features/Main/HomeView.swift`
新增三张 OpenClaw 卡片（置于 welcomeSection 下方）：
- `openClawPromoCard`（未安装）：霓虹玫红色调，一键安装按钮 + 最低版本提示
- `openClawServiceDownCard`（服务未运行）：霓虹橙色调，启动按钮（含 loading）+ 卸载按钮
- `openClawReadyCard`（运行中）：霓虹绿色调，停止按钮 + 卸载按钮

body 中根据 `openClawManager.status` switch 插入对应卡片。

#### `voice-input/L10n/` 系列文件
新增 key（5 个语言）：
- `openclawPromoTitle/Desc`、`openclawInstallBtn`
- `openclawInstalledTitle/Desc`、`openclawServiceDownTitle/Desc`
- `openclawStartBtn`、`openclawStartingGateway`、`openclawStopBtn`
- `openclawTipNotInstalled`、`openclawTipServiceDown`
- `openclawTipSessionStarted`、`openclawTipSessionEnded`、`openclawTipAlreadyActive`
- `openclawMinVersion`、`openclawUninstallBtn`

---

## 三、后端架构（全分支通用）

### 新增文件
- `backend/app/agent/nodes/openclaw_node.py`：OpenClawOnNode/OffNode/ExecuteNode + OpenClawSessionStore
- `backend/app/prompts/templates/openclaw_transcribe.txt`：双模式提示词（COMMAND:/TEXT:）

### 修改文件
- `backend/app/models/schemas.py`：ActionType 新增 openclaw 系列
- `backend/app/services/agent_pipeline.py`：IntentRouter 始终执行，按激活状态路由
- `backend/app/services/audio_pipeline.py`：PipelineContext 新增 `openclaw_status` 字段
- `backend/app/api/v1/audio.py`：从 multipart 读取 `openclaw_status` 字段

---

## 四、关键设计决策

1. **为什么不用 WebSocket**：openclaw gateway WS 需要设备签名握手，客户端不直接复刻握手。
2. **为什么不用 HTTP Chat Completions**：最新版 Gateway RPC 已提供 `sessions.send` 和 `sessions.abort`，可以发送并中断同一会话任务。
3. **stopGateway 为什么用 stop 不用 uninstall**：卸载由独立按钮负责，停止只执行 `openclaw gateway stop --json`。
4. **startGateway 智能判断**：先用 `gateway start --json`，失败再安装/前台运行，避免依赖旧的 launchctl grep 状态判断。
5. **IntentRouter 始终执行**：激活状态下 OFF → 关闭；ON + 已激活 → ALREADY_ACTIVE tip；其他意图 + 已激活 → ExecuteNode。

---

## 五、DIY vs 标准分支的界面差异约定

| 功能 | DIY 分支 | 标准分支 |
|------|----------|----------|
| OpenClaw 卡片 | ✅ 有 | ✅ 需实现（完全一致） |
| DIY 配置面板 | ✅ 有 | ❌ 无（标准版无此功能） |
| 主题定制 | ✅ 有 | ❌ 无 |
| 语言管理 | `LanguageManager`（可切换） | 同左 |
| OpenClaw 逻辑 | `OpenClawManager` | 完全相同 |

标准分支的 OpenClaw 实现与 DIY 分支**功能完全一致**，仅移除 DIY 专属功能（主题/配置面板），其余 UI 表现、文案、交互行为均相同。
