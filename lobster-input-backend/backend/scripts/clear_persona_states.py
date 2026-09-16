"""清空人设激活状态（user_persona_states），用于激活态「逐端隔离」改造上线。

改造前激活指针仅按 user_email 存储，全端共享；改造后按 (user_email, platform) 隔离。
旧数据缺少 platform 字段，且旧的 user_email 唯一索引会阻止同一用户多端各自激活。
按产品决策：不迁移、不兼容旧激活态，直接清空即可——用户重新在各端激活即可。

脚本是幂等的：
  1. 删除旧的仅按 user_email 唯一的遗留索引（若存在）。
  2. 清空 user_persona_states 全部文档。
  3. 重建 (user_email, platform) 复合唯一索引（与 PersonaRepository.ensure_indexes 一致）。

运行：
  cd /opt/lobster-backend
  PYTHONPATH=/opt/lobster-backend venv/bin/python3.12 scripts/clear_persona_states.py
"""
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.core.database import close_db, connect_db, get_db
from app.repositories.persona_repository import (
    PERSONA_STATES_COL,
    _LEGACY_STATE_INDEX,
    PersonaRepository,
)


async def main() -> None:
    await connect_db()
    try:
        col = get_db()[PERSONA_STATES_COL]

        index_info = await col.index_information()
        legacy_dropped = False
        if _LEGACY_STATE_INDEX in index_info:
            await col.drop_index(_LEGACY_STATE_INDEX)
            legacy_dropped = True

        result = await col.delete_many({})

        # 复用仓库的索引定义，确保与运行时一致
        await PersonaRepository().ensure_indexes()

        print({
            "ok": True,
            "legacy_index_dropped": legacy_dropped,
            "states_deleted": result.deleted_count,
            "indexes": sorted((await col.index_information()).keys()),
        })
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
