from fastapi import FastAPI

app = FastAPI(
    title="龙虾笔记 API",
    description="龙虾笔记 FastAPI 后端服务",
    version="0.1.0",
)


@app.get("/")
def read_root() -> dict[str, str]:
    return {"name": "龙虾笔记", "service": "lobster-note-backend"}


@app.get("/health")
def health_check() -> dict[str, str]:
    return {"status": "ok"}
