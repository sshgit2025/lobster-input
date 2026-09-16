# 龙虾笔记

龙虾笔记是一个前后端分离的桌面笔记项目。

## 项目结构

```text
lobster-note/
├── lobster-note-front/     # Electron 前端
└── lobster-note-backend/   # Python FastAPI 后端
```

## 前端

```bash
cd lobster-note-front
npm install
npm run dev
```

## 后端

```bash
cd lobster-note-backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

后端默认接口：

- `GET /`：项目基础信息
- `GET /health`：健康检查
