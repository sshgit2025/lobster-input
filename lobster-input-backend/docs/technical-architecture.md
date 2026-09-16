# 技术架构文档

## 1. 系统架构

```
┌──────────────────────────────────────────────────────────┐
│                  macOS 客户端「龙虾输入法」(Swift)          │
│                                                            │
│  ┌──────────┐  ┌───────────────┐  ┌───────────────┐      │
│  │ HotKey   │→ │ AudioRecorder │→ │ API Client    │──┼──→ POST /audio/process
│  │ Manager  │  │ (16kHz AAC    │  │ (multipart)   │  │    POST /hotwords
│  └──────────┘  │  60s limit)   │  └───────────────┘  │    POST /personas
│       ↑        └───────────────┘         ↓            │
│  ┌──────────┐                    ┌───────────────┐    │
│  │ Settings │                    │ FocusedInput  │    │
│  │ View     │                    │ Filler        │    │
│  └──────────┘                    │ (actionType)  │    │
│  ┌──────────┐  ┌──────────┐     └───────────────┘    │
│  │Dictionary│  │ Persona  │                           │
│  │ Store    │  │ Store    │                           │
│  └──────────┘  └──────────┘                           │
└──────────────────────────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────┐
│                Python 后端 (FastAPI)                       │
│                                                            │
│  Request → Auth Middleware → Router                        │
│                                │                           │
│     ┌──────────────────────────┼────────────────┐         │
│     ▼                          ▼                ▼         │
│  Audio API              HotWords API      Personas API    │
│     │                                                      │
│     ▼                                                      │
│  AudioProcessPipeline（模板方法）                            │
│     ├─ save_upload()                                       │
│     ├─ validate_duration() (mutagen)                       │
│     ├─ transcribe() (Whisper: OpenAI / Groq)               │
│     ├─ should_invoke_llm()                                 │
│     ├─ invoke_llm() (PromptManager + 人设 prompt)          │
│     └─ decide_action_type()                                │
│                                                            │
│  MongoDB ← UserRepo / HotWordRepo / PersonaRepo /         │
│            ShortcutRepo / VerifyCodeRepo                   │
└──────────────────────────────────────────────────────────┘
```

## 2. 客户端架构

### 2.1 模块划分

| 模块 | 路径 | 职责 |
|------|------|------|
| **App 入口** | `voice_inputApp.swift` | App 生命周期、AppDelegate、菜单栏图标、窗口管理 |
| **Audio** | `Core/Audio/` | 麦克风录音（AVAudioEngine + AVAudioConverter，16kHz mono AAC，60s 上限） |
| **Dictionary** | `Core/Dictionary/` | 热词词典数据管理（ObservableObject 单例，CRUD + 容量限制） |
| **HotKey** | `Core/HotKey/` | 全局快捷键监听（CGEventTap / NSEvent 双轨）、快捷键配置持久化 |
| **Network** | `Core/Network/` | REST API 调用（含词典/人设 CRUD）、JWT Token 管理 |
| **Permissions** | `Core/Permissions/` | 麦克风/输入监控/辅助功能权限检测与引导 |
| **Persona** | `Core/Persona/` | 人设数据管理（ObservableObject 单例，CRUD + 激活管理 + 复制内置） |
| **History** | `Core/History/` | 录音历史本地 JSON 持久化、音频文件管理 |
| **Clipboard** | `Core/Clipboard/` | 剪贴板内容读取（录音前上下文） |
| **SelectedText** | `Core/SelectedText/` | 选中文本读取（AX API）、输入框填充（actionType 分发 + 剪贴板 + Cmd+V） |
| **Auth UI** | `Features/Auth/` | 邮箱验证码登录/注册界面 |
| **Main UI** | `Features/Main/` | 侧边栏布局（首页/词典/人设/历史/设置）、录音浮窗 |

### 2.2 核心流程：录音 → 识别 → 填充

```
用户按下快捷键
    │
    ▼
AppHotKeyHandler.handle()
    │
    ├─ 校验麦克风权限（缺则申请，拒绝中断）
    ├─ 校验辅助功能权限（缺则申请，拒绝中断）
    ├─ 记录目标 App PID（FocusedInputFiller.captureTargetApp）
    ├─ 抓取剪贴板历史（ClipboardHistoryReader.read）
    └─ 启动录音（AudioRecorder.startRecording）
         │
         ▼
    显示录音浮窗（RecordingOverlayWindow）
         │
    ┌────┴────┐
    │         │
用户再次   达到 60 秒上限
按下快捷键  （recordingMaxDurationReached 通知）
    │         │
    └────┬────┘
         │
         ▼
AppHotKeyHandler.stopAndProcess()
    │
    ├─ 停止录音，获取音频文件（16kHz mono AAC）
    ├─ 读取选中文本（SelectedTextReader.read）
    ├─ 持久化音频到本地（HistoryStore.persistAudio）
    ├─ 创建历史记录（状态：processing）
    └─ 调用后端 API（APIClient.processAudio）
         │
         ▼
    后端返回结果（含 action_type）
    │
    ├─ 更新历史记录（状态：success / failed）
    └─ handleAction(actionType)
        ├─ paste        → 写入剪贴板 + Cmd+V 填充
        ├─ clarify      → 显示询问悬浮窗（不写入）
        ├─ show_markdown → 拉起 ResultOverlay 悬浮窗展示 Markdown 内容
        └─ tip          → 底部居中 TipOverlay，4 秒后淡出消失
    │
    └─ 隐藏浮窗
```

### 2.3 快捷键监听策略

采用双轨方案，启动时自动选择可用方案：

| 方案 | API | 所需权限 | 优先级 |
|------|-----|----------|--------|
| CGEventTap | `CGEvent.tapCreate(.listenOnly)` | 输入监控 | 高 |
| NSEvent | `addGlobalMonitorForEvents` | 辅助功能 | 低（降级） |

支持的快捷键类型：
- 单独 Fn 键
- Fn + 普通键（如 Fn+Space）
- Fn + 修饰键（如 Fn+Shift）
- 修饰键组合 + 普通键（如 Cmd+Shift+A）
- 单独修饰键（如 Control、Option）

### 2.4 窗口生命周期

- 点击窗口 X 按钮 → 隐藏窗口（`orderOut`），不退出进程
- 点击 Dock 图标 → 恢复主窗口（`applicationShouldHandleReopen`）
- 菜单栏右键 → 显示主界面 / 权限管理 / 退出
- `ProcessInfo.beginActivity` 防止 App Nap

## 3. 后端架构

### 3.1 分层结构

```
API Layer (api/v1/)
    │
    ▼
Service Layer (services/)
    │
    ▼
Repository Layer (repositories/)
    │
    ▼
Database (MongoDB via Motor)
```

### 3.2 API 接口

| 路径 | 方法 | 鉴权 | 说明 |
|------|------|------|------|
| `/api/v1/auth/send-code` | POST | 无 | 发送验证码 |
| `/api/v1/auth/verify` | POST | 无 | 验证码确认（自动注册或登录） |
| `/api/v1/audio/mac/process` | POST | JWT | Mac 端音频处理（transcribe/rewrite/agent） |
| `/api/v1/audio/ios/process` | POST | JWT | iOS 端音频处理（transcribe/rewrite） |
| `/api/v1/audio/windows/process` | POST | JWT | Windows 端音频处理（transcribe/rewrite/agent） |
| `/api/v1/audio/android/process` | POST | JWT | Android 端音频处理（transcribe/rewrite） |
| `/api/v1/hotwords` | GET/POST | JWT | 查询/新增热词 |
| `/api/v1/hotwords/{id}` | PUT/DELETE | JWT | 更新/删除热词 |
| `/api/v1/personas` | GET/POST | JWT | 查询/新增人设 |
| `/api/v1/personas/{id}` | PUT/DELETE | JWT | 更新/删除人设 |
| `/api/v1/personas/active` | GET | JWT | 获取当前激活人设 |
| `/api/v1/personas/active/{id}` | POST | JWT | 设置激活人设 |
| `/api/v1/shortcuts` | GET | JWT | 查询所有快捷键映射 |
| `/api/v1/shortcuts/{key}` | GET/PUT/DELETE | JWT | 单个快捷键 CRUD |
| `/health` | GET | 无 | 健康检查 |

**请求头规范**：

| Header | 必填 | 说明 |
|--------|------|------|
| `X-Accept-Language` | 是 | 客户端 UI 语言（如 `zh`/`en`），用于流程选择（PipelineSelector） |
| `X-Client-Platform` | 是 | 客户端平台标识（macos/ios/windows/android） |

### 3.3 流程管理架构（PipelineManager）

后端使用分层流程管理架构，所有平台的音频处理请求统一经过此架构路由：

```
接口层（audio_mac/ios/windows/android.py）
    │  提取 X-Accept-Language（客户端 UI 语言）
    │
    ▼
PipelineManager（统一入口）
    │
    ▼
PipelineSelector（流程选择器）
    │  根据 client_ui_lang 选择处理流程
    │  当前注册表为空，始终返回 StandardFlow
    │
    ▼
StandardFlow（唯一标准流程，flow_name="standard"）
    │  按平台返回对应 PlatformPipelineSet
    │
    ▼
AudioProcessPipeline（平台专属实例）
    │  execute() 模板方法
```

**两种语言类型的区别（绝不混用）**：

| 字段 | 来源 | 含义 | 参与逻辑 |
|------|------|------|----------|
| `client_ui_lang` | 请求头 `X-Accept-Language` | 客户端 UI 语言（用户主动选择） | PipelineSelector 流程路由 |
| `transcript_language` | ASR 接口返回 | ASR 识别出的音频语言 | PromptManager 提示词目录路由 |

### 3.3.1 音频处理流水线（AudioProcessPipeline 模板方法）

```
上传音频文件（16kHz mono AAC m4a）
    │
    ▼
save_upload() → 保存到 uploads/audio/
    │
    ▼
validate_duration() → mutagen 读取时长，校验 ≤ 65 秒
    │
    ▼
transcribe() → 号池获取 ASR Key（required_tag=flow_name）→ Whisper 语音识别
               返回 (text, transcript_language, key_info)
    │
    ▼
should_invoke_llm() → 判断是否需要调用 LLM
    │
    ├─ True:
    │   ├─ PromptManager.get_system_prompt(flow_name, transcript_language) → 提示词目录路由
    │   ├─ 拼接用户人设 prompt（PersonaRepository.get_active_persona）
    │   └─ LLMService.run() → 号池获取 LLM Key（required_tag=flow_name）→ LLM 调用
    │
    ├─ False:
    │   └─ result = transcript（直接输出识别文本）
    │
    ▼
decide_action_type() → 决定 action_type（当前默认 paste）
    │
    ▼
返回 { operation, action_type, transcript, result, model_provider, model_name }
```

### 3.3.1 AgentPipeline — 第3种快捷键意图路由流水线

```
Whisper 语音识别 → transcript
    │
    ▼
IntentRouter（LLM 意图分类）→ IntentType 枚举
    │  输出不合规时兜底为 TRANSCRIBE
    │
    ├─ TRANSCRIBE   → TranscribeNode  （转文字 + paste）
    ├─ REWRITE      → RewriteNode     （改写选中文本 + paste 或 clarify）
    ├─ SEARCH       → SearchNode      （Tavily 查询 + show_markdown）
    ├─ OPENCLAW_ON  → OpenClawOnNode  （开启标记 + tip 提示）
    └─ OPENCLAW_OFF → OpenClawOffNode （关闭标记 + tip 提示）
         │
         ▼
返回 { operation, action_type, transcript, result, ... }
```

**ActionType 说明**：

| action_type | 说明 | 客户端行为 |
|---|---|---|
| `paste` | 结果写入剪贴板并粘贴 | 自动 Cmd+V 填充输入框 |
| `clarify` | LLM 意图不明 | 显示询问悬浮窗 |
| `show_markdown` | Markdown 内容展示（搜索结果） | 拉起 ResultOverlay 悬浮窗 |
| `tip` | 系统操作反馈 tip | 底部居中 TipOverlay，4 秒自动消失 |

### 3.3.3 提示词模板目录结构

提示词按流程 / ASR语言 / 平台三层隔离管理：

```
templates/
└── standard/              # 流程名（flow_name）
    ├── zh/                # ASR 识别语言目录
    │   ├── mac/           # 平台专属提示词
    │   │   ├── transcribe.txt
    │   │   ├── rewrite.txt
    │   │   └── agent_intent.txt
    │   ├── ios/
    │   ├── windows/
    │   └── android/
    └── default/           # 默认语言包（ASR 语言无匹配时降级）
        ├── mac/
        ├── ios/
        ├── windows/
        └── android/
```

**加载优先级**（`PromptManager.get_template()`）：
1. `{flow}/zh/{platform}` — 流程 + ASR语言 + 平台专属
2. `{flow}/zh/mac` — 流程 + ASR语言 + mac 兜底（非 mac 平台无专属时）
3. `{flow}/default/{platform}` — 流程 + 默认语言 + 平台专属
4. `{flow}/default/mac` — 流程 + 默认语言 + mac 兜底

**注意**：`transcript_language` 是 ASR 识别语言，用于此目录路由；`client_ui_lang` 是客户端 UI 语言，用于流程选择，两者含义不同。

**Whisper 提供商配置**：

| 配置项 | 值 | 说明 |
|--------|------|------|
| `WHISPER_PROVIDER` | `openai` / `groq` | 语音识别提供商 |
| `WHISPER_MODEL` | `whisper-1` / `whisper-large-v3-turbo` | 模型名称 |
| `WHISPER_LANGUAGE` | 留空 | 自动检测语言（支持国际化多语言识别） |
| `GROQ_API_KEY` | - | Groq 专用 API Key |

### 3.4 LLM 消息构建

```
[System] {operation 对应的 prompt 模板}

[Human]
[Selected Text]         ← 可选，用户录音时选中的文本
{selected_text}

[Clipboard History]     ← 可选，录音前剪贴板最近 5 条
  1. {clip_1}
  2. {clip_2}

[Voice Input]
{transcript}            ← Whisper 识别的语音文本
```

### 3.5 API Key 号池（lobster-input-api-manage）

所有 API Key（ASR/LLM/搜索/Embed）通过号池统一管理，后端不硬编码任何 Key：

```
后端 pick_key(service_type, required_tag)
    │
    ▼
号池 /api/v1/pool/pick?service_type=llm&required_tag=standard
    │
    ├─ 优先匹配 tags 包含 "standard" 的 Key
    └─ 无匹配则回退到 tags 为空的通用 Key
```

**Key 标签策略**：
- `tags=["standard"]`：专属标准流程的 Key，优先命中
- `tags=[]`（空列表）：通用 Key，无标签约束时作为兜底
- `required_tag` 使用流程名（`flow_name`）作为固定字符串，迁移后无需修改

**支持的 service_type**：

| service_type | 用途 |
|------|------|
| `asr` | ASR 语音识别（Whisper） |
| `llm` | LLM 文本生成 |
| `search` | 搜索（Tavily 等） |
| `embed` | 向量 Embedding |

**多模型提供商支持**（通过 `model_provider.py` 工厂）：

| Provider | 实现 | 说明 |
|----------|------|------|
| OpenAI | `ChatOpenAI` | 兼容标准 OpenAI 接口 |
| Anthropic | `ChatAnthropic` | Claude 系列 |
| DeepSeek | `ChatOpenAI`（兼容接口） | DeepSeek API |
| Ollama | `ChatOllama` | 本地模型 |
| Azure OpenAI | `AzureChatOpenAI` | Azure 托管 |

### 3.6 认证机制

- **JWT Bearer Token**：客户端登录后获取，7 天有效期
- **API Key + HMAC**：通过 `X-API-Key`、`X-Internal-Timestamp`、`X-Internal-Signature` Header，用于内部服务间调用
- 用户接口使用 `verify_user` 仅接受 JWT；内部管理接口使用 `verify_internal_api_key` 校验 API Key 与 HMAC 签名

### 3.7 数据库集合

| 集合 | 用途 | 索引 |
|------|------|------|
| `users` | 用户信息 | `email` (unique) |
| `verify_codes` | 验证码 | `email + purpose` (unique), TTL |
| `shortcuts` | 快捷键映射 | `shortcut_key` (unique) |
| `hotwords` | 热词词典 | `(user_email, word)` (unique) |
| `personas` | 人设 | `(user_email, id)` |
| `user_settings` | 用户设置（如激活人设 ID） | `user_email` (unique) |

**词典容量限制**：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `hotword_max_count` | 30 | 每用户最多热词条数 |
| `hotword_max_length` | 20 | 单个热词最大字符数 |

限制依据：Whisper prompt 上限 224 tokens，30 条 × 20 字符安全可控。

### 3.8 时区策略

**数据存储**：所有时间戳统一使用 `datetime.now(timezone.utc)`，MongoDB 存 UTC，与时区无关。

**本地时间（日志）**：三个服务（后端、管理端、号池管理端）启动入口均设置：

```python
os.environ.setdefault("TZ", "Asia/Shanghai")
```

进程本地时间即北京时间，日志可读性友好，存储层不受影响。

**页面展示**：前端 JS 渲染时间时强制指定时区：

```javascript
d.toLocaleString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' })
```

不依赖用户浏览器系统时区，任何地区打开管理页面时间都显示北京时间。

## 4. 权限模型

| 权限 | 用途 | API |
|------|------|-----|
| 麦克风 | 录音 | `AVCaptureDevice.requestAccess` |
| 输入监控 | 全局快捷键（CGEventTap） | `CGRequestListenEventAccess` |
| 辅助功能 | 读取选中文本 + Cmd+V 填充 | `AXIsProcessTrustedWithOptions` |

权限检查时机：
- **启动时**：静默检查状态，不弹窗
- **录音前**：校验麦克风 + 辅助功能，缺则申请，拒绝中断
- **填充前**：校验辅助功能，缺则申请一次，拒绝后本次会话不再弹窗

## 5. 数据持久化

### 客户端

| 数据 | 存储方式 | 位置 |
|------|----------|------|
| 快捷键配置 | UserDefaults | `hotkey_configs` |
| JWT Token | UserDefaults | `auth_token` |
| 用户信息 | UserDefaults | `auth_email`, `auth_tier` |
| 历史记录 | JSON 文件 | `~/Documents/VoiceInput/history.json` |
| 音频文件 | m4a 文件（16kHz mono AAC） | `~/Documents/VoiceInput/AudioFiles/` |
| 词典/人设 | 远程 API（不本地缓存） | 每次打开页面从后端加载 |

### 后端

| 数据 | 存储方式 |
|------|----------|
| 用户、验证码、快捷键映射 | MongoDB |
| 热词词典、人设、用户设置 | MongoDB（按 user_email 隔离） |
| 上传音频（临时） | 本地文件系统 `uploads/audio/`，处理后清理 |
