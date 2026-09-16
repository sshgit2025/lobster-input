import os
import uvicorn
from app.core.config import settings

os.environ.setdefault("TZ", "Asia/Shanghai")

if __name__ == "__main__":
    uvicorn.run(
        "app.main:app",
        host=settings.HOST,
        port=settings.PORT,
        reload=False,
        log_level="info",
    )
