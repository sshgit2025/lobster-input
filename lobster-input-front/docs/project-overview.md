# 龙虾输入法 项目概览

## 基本信息

- **平台**：macOS 14.0+
- **客户端**：Swift 5.0 / SwiftUI / AppKit / CoreGraphics / AVAudioEngine
- **后端**：Python 3.11+ / FastAPI / LangChain
- **数据库**：MongoDB（Motor 异步驱动）
- **语音识别**：Whisper API（支持 OpenAI / Groq 双提供商，通过 .env 切换）
- **LLM**：OpenAI GPT-4o（可切换 Anthropic / DeepSeek / Ollama / Azure）
- **认证**：JWT + 邮箱验证码
- **分发方式**：独立分发（Developer ID 签名 + Notarization 公证），不上 Mac App Store
- **不上架原因**：App 依赖辅助功能权限（Accessibility）实现自动粘贴和选中文本读取，Apple 不批准新 App 在沙盒中使用该权限
- **支付方案**：独立支付（Stripe / Paddle / Lemon Squeezy / 支付宝），无 Apple 30% 抽成

---

## 客户端代码结构

```
voice-input/
├── voice_inputApp.swift           # App 入口 + AppDelegate（窗口管理、菜单栏、App Nap 防护）
├── Info.plist                     # 权限说明（麦克风、输入监控）
├── voice-input.entitlements       # 权限声明（非沙盒，空 dict）
├── Assets.xcassets/               # 图标资源（龙虾 Logo）
├── Core/
│   ├── Audio/
│   │   ├── AudioRecorder.swift          # 麦克风录音（16kHz mono AAC，60秒上限，AVAudioConverter 重采样）
│   │   └── RecordingResultStore.swift   # 录音结果状态
│   ├── Clipboard/
│   │   └── ClipboardHistoryReader.swift # 剪贴板历史读取
│   ├── Dictionary/
│   │   └── DictionaryStore.swift        # 热词词典数据管理（ObservableObject 单例）
│   ├── History/
│   │   ├── HistoryStore.swift           # 历史记录 JSON 持久化
│   │   └── RecordingHistory.swift       # 历史记录数据模型
│   ├── HotKey/
│   │   ├── AppHotKeyHandler.swift       # 快捷键事件处理（录音→识别→actionType 分发→填充）
│   │   └── HotKeyManager.swift          # 全局快捷键监听（CGEventTap）
│   ├── Network/
│   │   ├── APIClient.swift              # REST API 调用（含词典/人设 CRUD）
│   │   └── AuthStore.swift              # JWT Token 管理
│   ├── Permissions/
│   │   ├── PermissionGateView.swift     # 权限状态面板
│   │   ├── PermissionManager.swift      # 权限检测与申请
│   │   └── PermissionWindowManager.swift # 权限窗口管理
│   ├── Persona/
│   │   └── PersonaStore.swift           # 人设数据管理（ObservableObject 单例）
│   └── SelectedText/
│       ├── FocusedInputFiller.swift     # 输入框填充（剪贴板 + Cmd+V）
│       └── SelectedTextReader.swift     # 选中文本读取（AX API）
├── Features/
│   ├── Auth/
│   │   ├── AuthView.swift               # 登录/注册界面
│   │   └── AuthViewModel.swift          # 登录逻辑
│   └── Main/
│       ├── MainView.swift               # 侧边栏主布局（首页/词典/人设/历史/设置）
│       ├── HomeView.swift               # 首页（欢迎 + 快捷键指南）
│       ├── DictionaryView.swift         # 词典管理（热词 CRUD + 容量限制）
│       ├── PersonaView.swift            # 人设管理（内置只读+复制、自定义编辑、激活切换）
│       ├── HistoryView.swift            # 历史记录（分页 + 展开/收起）
│       ├── SettingsView.swift           # 设置（快捷键配置）
│       └── RecordingOverlayWindow.swift # 录音/识别浮窗
└── Models/
    └── APIModels.swift                  # API 请求/响应模型（含词典/人设/ActionType）
```

---

## 后端代码结构

```
backend/
├── main.py                          # 启动入口
├── requirements.txt
├── .env / .env.example
└── app/
    ├── main.py                      # FastAPI app + lifespan（DB 初始化）
    ├── core/
    │   ├── config.py                # 统一配置（Pydantic Settings，含词典限制参数）
    │   ├── database.py              # MongoDB 连接管理
    │   └── exceptions.py            # 统一异常定义
    ├── middleware/
    │   ├── auth.py                  # JWT + API Key 统一鉴权（verify_any）
    │   └── logging.py              # 请求日志中间件
    ├── providers/
    │   └── model_provider.py        # LLM 工厂（5 家提供商）
    ├── repositories/
    │   ├── hotword_repository.py    # 热词词典 CRUD（唯一索引 + 数量上限）
    │   ├── persona_repository.py    # 人设 CRUD + 内置默认人设 seed + 激活管理
    │   ├── shortcut_repository.py   # 快捷键映射 CRUD + 默认数据
    │   ├── user_repository.py       # 用户数据访问
    │   └── verify_code_repository.py # 验证码数据访问
    ├── prompts/
    │   ├── prompt_manager.py        # 按 operation 读取系统提示词
    │   └── templates/               # 提示词模板文件
    │       ├── transcribe.txt       # 语音转文字
    │       ├── rewrite.txt          # 改写
    │       ├── agent.txt            # Agent 模式
    │       ├── qa.txt               # 问答
    │       ├── summarize.txt        # 总结
    │       └── action_extract.txt   # 动作提取
    ├── services/
    │   ├── audio_pipeline.py        # 音频处理流水线（模板方法模式）
    │   ├── audio_service.py         # 音频保存 + 时长校验 + Whisper 识别（OpenAI/Groq）
    │   ├── agent_pipeline.py        # Agent 意图路由流水线（第3种快捷键专用）
    │   ├── rewrite_pipeline.py      # Rewrite 流水线（第2种快捷键专用）
    │   ├── auth_service.py          # 统一登录/注册（验证码）
    │   ├── email_service.py         # SMTP 邮件发送
    │   └── llm_service.py           # LLM 调用（普通链 + Agent）
    ├── agent/                       # Agent 意图路由系统
    │   ├── __init__.py
    │   ├── intent_router.py         # LLM 意图分类器（IntentType 枚举 + 兜底策略）
    │   └── nodes/                   # 各意图处理节点
    │       ├── base.py              # BaseNode 抽象基类
    │       ├── transcribe_node.py   # TRANSCRIBE 意图（复用第1种流程）
    │       ├── rewrite_node.py      # REWRITE 意图（复用第2种流程）
    │       ├── search_node.py       # SEARCH 意图（Tavily 搜索 + Markdown 格式化）
    │       └── openclaw_node.py     # OPENCLAW_ON/OFF 意图（会话标记 + 多语言 tip）
    ├── models/
    │   └── schemas.py               # Pydantic Schema（含词典/人设/ActionType）
    ├── api/v1/
    │   ├── auth.py                  # POST /send-code, /verify
    │   ├── audio.py                 # POST /audio/process（使用 AudioProcessPipeline）
    │   ├── hotwords.py              # 词典 CRUD（GET/POST/PUT/DELETE）
    │   ├── personas.py              # 人设 CRUD + 激活管理
    │   └── shortcuts.py             # CRUD /shortcuts
    └── tools/                       # Agent 工具目录（待扩展）
```

---

## API 接口

### 认证

| 接口 | 方法 | 鉴权 | 说明 |
|------|------|------|------|
| `/api/v1/auth/send-code` | POST | 无 | 发送验证码 |
| `/api/v1/auth/verify` | POST | 无 | 验证码确认（自动注册/登录） |

### 音频处理

| 接口 | 方法 | 鉴权 | 说明 |
|------|------|------|------|
| `/api/v1/audio/process` | POST | JWT / API Key | 上传音频 → Pipeline 处理 → 返回结果 |

### 词典（热词）

| 接口 | 方法 | 鉴权 | 说明 |
|------|------|------|------|
| `/api/v1/hotwords` | GET | JWT / API Key | 查询当前用户所有热词 |
| `/api/v1/hotwords` | POST | JWT / API Key | 新增热词（上限 30 条，单词最长 20 字符） |
| `/api/v1/hotwords/{id}` | PUT | JWT / API Key | 更新热词 |
| `/api/v1/hotwords/{id}` | DELETE | JWT / API Key | 删除热词 |

### 人设

| 接口 | 方法 | 鉴权 | 说明 |
|------|------|------|------|
| `/api/v1/personas` | GET | JWT / API Key | 查询所有人设（含内置）+ 当前激活 ID |
| `/api/v1/personas` | POST | JWT / API Key | 新增自定义人设 |
| `/api/v1/personas/{id}` | PUT | JWT / API Key | 更新人设（内置不可改） |
| `/api/v1/personas/{id}` | DELETE | JWT / API Key | 删除人设（内置不可删） |
| `/api/v1/personas/active/{id}` | POST | JWT / API Key | 设置激活人设 |
| `/api/v1/personas/active` | GET | JWT / API Key | 获取当前激活人设详情 |

### 快捷键映射

| 接口 | 方法 | 鉴权 | 说明 |
|------|------|------|------|
| `/api/v1/shortcuts` | GET | JWT / API Key | 查询所有快捷键映射 |
| `/api/v1/shortcuts/{key}` | GET | JWT / API Key | 查询单个快捷键 |
| `/api/v1/shortcuts/{key}` | PUT | JWT / API Key | 新增/更新快捷键映射 |
| `/api/v1/shortcuts/{key}` | DELETE | JWT / API Key | 删除快捷键映射 |

### 其他

| 接口 | 方法 | 鉴权 | 说明 |
|------|------|------|------|
| `/health` | GET | 无 | 健康检查 |

### 音频接口参数

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `file` | File | 是 | 音频文件（16kHz mono AAC m4a，最大 25MB，最长 65 秒） |
| `operation` | string | 是 | 操作类型（transcribe / rewrite / agent 等） |
| `selected_text` | string | 否 | 客户端当前选中的文本 |
| `clipboard_history` | string | 否 | 剪贴板历史（JSON 数组字符串） |
| `provider` | string | 否 | 模型提供商，留空用默认 |
| `model` | string | 否 | 模型名称，留空用默认 |

### 音频接口响应

```json
{
  "operation": "agent",
  "action_type": "show_markdown",
  "transcript": "语音识别原文",
  "result": "## 搜索结果\n\n...",
  "model_provider": "openai",
  "model_name": "gpt-4o"
}
```

`action_type` 由后端 Pipeline 决定，客户端据此分支执行对应操作：
- `paste` — 写入剪贴板 + 自动粘贴
- `clarify` — 显示询问悬浮窗
- `show_markdown` — 拉起悬浮窗展示 Markdown 内容（搜索结果），不写入输入框
- `tip` — 底部居中 tip 提示，4 秒后自动消失（openclaw 开启/关闭通知）

---

## 默认快捷键映射

| 快捷键 | Operation | 说明 |
|--------|-----------|------|
| Fn | transcribe | 语音转文字 |
| Fn + Space | rewrite | 改写选中文本 |
| Fn + Shift | agent | Agent 智能操作 |

---

## 开发指南

### 开发脚本

```bash
# 编译 + 重启客户端和后端（Apple 开发者证书签名，权限稳定无需重复授权）
bash scripts/dev-restart.sh --build

# 仅重启（已编译过）
bash scripts/dev-restart.sh
```

### 手动启动后端

```bash
cd backend
source .venv/bin/activate
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

### 验证

```bash
curl http://localhost:8000/health
# {"status":"ok"}
```

---

## 相关文档

- [需求文档](requirements.md) — 基于真实业务反向整理的完整需求
- [技术架构](technical-architecture.md) — 系统架构、核心流程、数据模型
- [AVAudioEngine 排查手册](troubleshooting-avaudioengine-non-sandbox.md) — 非沙盒环境录音问题排查、权限管理、环境一致性
