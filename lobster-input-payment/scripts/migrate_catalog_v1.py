"""计费目录域 v1 迁移脚本(幂等)—— 计费域重构阶段 1。

从现有 system_config.plan_configs + system_config.payment_billing_config 生成
billing_plans / billing_prices v1:

- 每个 plan_code×period×currency 一条 price,price_id=f"{plan}_{period}_{currency}_v1";
- lookup_key=f"{plan}_{period}",channel_bindings 从 channel_prices 按商品×币种归并;
- 已存在的 plan/price 直接跳过,可反复执行;
- 迁移完成后立刻执行 dry-run publish 校验往返一致性(应显示零 diff)。

用法(在 lobster-input-payment 目录下):
    PYTHONPATH=. python scripts/migrate_catalog_v1.py
"""

import asyncio
import json

from app.core.database import close_db, connect_db, get_main_db
from app.services.billing_catalog import migrate_catalog_v1, publish_catalog


async def main() -> None:
    await connect_db()
    try:
        db = get_main_db()
        stats = await migrate_catalog_v1(db)
        print("迁移完成:", json.dumps(stats, ensure_ascii=False))

        result = await publish_catalog(db, operator="migrate_catalog_v1", dry_run=True)
        if result["has_changes"]:
            print("[警告] dry-run publish 存在 diff,catalog 与现有配置往返不一致,请人工核对后再正式发布:")
            print(json.dumps(result["diff"], ensure_ascii=False, indent=2, default=str))
        else:
            print(f"dry-run publish 零 diff,往返一致(plans={result['plan_count']}, prices={result['price_count']})")
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
