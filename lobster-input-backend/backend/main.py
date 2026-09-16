"""
后端启动入口。
直接运行: python main.py 即可启动 uvicorn 开发服务器。
"""
import os
import uvicorn

os.environ.setdefault("TZ", "Asia/Shanghai")

if __name__ == "__main__":
    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)
