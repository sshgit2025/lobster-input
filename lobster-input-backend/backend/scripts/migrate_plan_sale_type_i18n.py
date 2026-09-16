"""幂等迁移存量 plan_configs:回填 sale_type(三态)+ localized_*(多语言文案)。(套餐重构 P5)

迁移逻辑已内置于 PlanRepository._clean_plan_config(sale_type 默认三态、localized_names 从旧单语言
name 迁移到 zh)。本脚本 read→set_plan_configs 即触发清洗回填,幂等(重复执行结果一致)。
部署时也可由 init_system_config.py(ensure_default_system_configs 内部同样 get→set)自动完成,
本脚本用于显式迁移 + 结果核对。
"""
import asyncio

from app.core.database import close_db, connect_db
from app.repositories.plan_repository import PlanRepository


async def main() -> None:
    await connect_db()
    try:
        repo = PlanRepository()
        before = await repo.get_plan_configs()
        await repo.set_plan_configs(before)
        after = await repo.get_plan_configs()
        report = {
            code: {
                "sale_type": v.get("sale_type"),
                "localized_names": v.get("localized_names"),
                "name": v.get("name"),
            }
            for code, v in sorted(after.items())
        }
        print({"ok": True, "count": len(after), "plans": report})
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
