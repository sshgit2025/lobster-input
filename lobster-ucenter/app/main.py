from fastapi import FastAPI

app = FastAPI(
    title="龙虾用户中心 API",
    description="龙虾用户中心 FastAPI 后端服务",
    version="0.1.0",
)


@app.get("/")
def read_root() -> dict[str, str]:
    return {"name": "龙虾用户中心", "service": "lobster-ucenter"}


@app.get("/health")
def health_check() -> dict[str, str]:
    return {"status": "ok"}
