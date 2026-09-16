import logging
from datetime import datetime, timezone
from app.core.config import settings
from app.core.security import generate_random_password, hash_password
from app.core.database import get_db

logger = logging.getLogger(__name__)

BANNER = """
╔═══════════════════════════════════════════════════════════╗
║        🔑 API Pool Manager - 管理员账号初始化              ║
╠═══════════════════════════════════════════════════════════╣
║  账号: {username:<49}║
║  密码: {password:<49}║
║  ⚠️  请立即登录后修改密码！                                ║
╚═══════════════════════════════════════════════════════════╝
"""


async def init_admin_account():
    db = get_db()
    collection = db["admin_users"]

    existing = await collection.find_one(
        {"username": settings.ADMIN_USERNAME}
    )
    if existing:
        logger.info("管理员账号已存在，跳过初始化")
        return

    password = generate_random_password(16)
    hashed = hash_password(password)

    await collection.insert_one({
        "username": settings.ADMIN_USERNAME,
        "hashed_password": hashed,
        "created_at": datetime.now(timezone.utc),
        "updated_at": datetime.now(timezone.utc),
    })

    print(BANNER.format(
        username=settings.ADMIN_USERNAME,
        password=password,
    ))
    logger.warning("=" * 60)
    logger.warning(
        "管理员账号创建成功！用户名: %s  密码: %s",
        settings.ADMIN_USERNAME, password,
    )
    logger.warning("=" * 60)
