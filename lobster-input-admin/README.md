# 🦞 Lobster Input Admin

Lobster Input 配套管理后台，基于 FastAPI + Jinja2 构建。

## 功能模块

- **仪表盘** - 用户、请求、Token 等核心指标概览
- **用户管理** - 查询、禁用/解封、套餐与积分查看、赠送积分
- **邀请码管理** - 创建、查询、删除邀请码
- **用量统计** - 多维度用量分析（平台、操作、用户）
- **系统配置** - 系统参数、全局快捷键管理
- **账号安全** - 管理员密码修改

## 快速启动

```bash
# 复制配置文件
cp .env.example .env
# 按需修改 .env 中的 MongoDB 连接信息

# 使用一键启动脚本
bash scripts/dev-restart.sh
```

首次启动会自动创建管理员账号，**密码将在日志中醒目显示**，请及时登录修改。

## 手动启动

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python run.py
```

访问 http://localhost:8888

## 配置说明

| 配置项 | 默认值 | 说明 |
|---|---|---|
| MONGODB_URI | mongodb://localhost:27017 | MongoDB 连接地址 |
| MONGODB_DB_NAME | voice_input | 业务数据库名（与 backend 一致） |
| ADMIN_DB_NAME | lobster_admin | 管理端专用数据库 |
| ADMIN_USERNAME | admin | 管理员账号（固定） |
| SECRET_KEY | - | JWT 签名密钥，生产环境必须修改 |
| PORT | 8888 | 服务端口 |
