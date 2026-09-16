# 龙虾用户中心

龙虾用户中心是用户、认证和账号能力的后端服务，当前为 FastAPI 空项目骨架。

## 项目结构

```text
lobster-ucenter/
├── app/
│   ├── __init__.py
│   └── main.py
├── requirements.txt
└── README.md
```

## 本地启动

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

默认接口：

- `GET /`：服务基础信息
- `GET /health`：健康检查
