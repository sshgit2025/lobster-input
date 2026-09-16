# Voice Input

macOS 语音输入工具 — 按下快捷键录音，自动识别并填充到当前输入框。

## 功能特性

- **全局快捷键录音**：支持 Fn、组合键、单独修饰键，可自定义
- **语音识别**：OpenAI Whisper 转写，支持中文
- **LLM 处理**：识别结果经 LLM 二次加工（改写、Agent 等）
- **自动填充**：识别结果写入剪贴板并自动粘贴到焦点输入框
- **剪贴板上下文**：录音前自动抓取剪贴板最近内容，作为 LLM 上下文
- **历史记录**：本地持久化全部录音历史，支持重试、删除
- **菜单栏常驻**：后台运行，App Nap 防护，状态栏图标实时反馈
- **权限管理**：麦克风、输入监控、辅助功能权限的检测与引导

## 技术栈

| 层 | 技术 |
|----|------|
| 客户端 | Swift / SwiftUI / AppKit / CoreGraphics |
| 后端 | Python / FastAPI / LangChain |
| 语音识别 | OpenAI Whisper API |
| LLM | OpenAI GPT-4o（可切换 Anthropic / DeepSeek / Ollama / Azure） |
| 数据库 | MongoDB（Motor 异步驱动） |
| 认证 | JWT + 邮箱验证码 |

## 快速开始

### 前置要求

- macOS 14.0+
- Xcode 15.0+
- Python 3.11+
- MongoDB（本地或远程）
- Apple Developer 账号（用于代码签名和权限授权）

### 后端启动

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env  # 编辑 .env 填入实际配置
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

### 客户端编译

使用 Xcode 打开 `voice-input.xcodeproj`，选择你的 Apple Developer Team 签名后编译运行。

或使用开发脚本一键编译+启动：

```bash
bash scripts/dev-restart.sh --build
```

### 验证

```bash
curl http://localhost:8000/health
# {"status":"ok"}
```

## 项目结构

```
voice-input/
├── backend/                 # Python 后端
│   ├── app/
│   │   ├── api/v1/          # REST API 路由
│   │   ├── core/            # 配置、数据库、异常
│   │   ├── middleware/       # 鉴权中间件
│   │   ├── models/          # Pydantic Schema
│   │   ├── prompts/         # LLM 提示词模板
│   │   ├── providers/       # 多模型提供商工厂
│   │   ├── repositories/    # MongoDB 数据访问
│   │   └── services/        # 业务逻辑
│   └── requirements.txt
├── voice-input/             # Swift 客户端
│   ├── Core/                # 核心模块
│   │   ├── Audio/           # 录音管理
│   │   ├── Clipboard/       # 剪贴板读取
│   │   ├── History/         # 历史记录持久化
│   │   ├── HotKey/          # 全局快捷键监听
│   │   ├── Network/         # API 客户端 + 认证
│   │   ├── Permissions/     # 系统权限管理
│   │   └── SelectedText/    # 选中文本读取 + 输入框填充
│   ├── Features/            # UI 功能模块
│   │   ├── Auth/            # 登录/注册
│   │   └── Main/            # 主界面（首页/历史/设置）
│   └── Models/              # API 数据模型
├── scripts/                 # 开发脚本
│   ├── dev-restart.sh       # 一键编译+重启
│   └── create-dev-cert.sh   # 开发证书创建
└── docs/                    # 项目文档
```

## 默认快捷键

| 快捷键 | 功能 |
|--------|------|
| Fn | 语音转文字 |
| Fn + Space | 改写选中文本 |
| Fn + Shift | Agent 智能操作 |

快捷键可在客户端「设置」页面自定义修改。

## 文档

- [需求文档](docs/requirements.md)
- [技术架构](docs/technical-architecture.md)
- [项目概览](docs/project-overview.md)

## License

项目原创代码遵循根目录 [MIT License](../LICENSE)。第三方资源遵循其各自许可证，详见 [第三方声明](../THIRD_PARTY_NOTICES.md)。
