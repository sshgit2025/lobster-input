"""Idempotently initialize system billing and flow-node configuration."""
import asyncio

from app.core.database import close_db, connect_db
from app.repositories.plan_repository import PlanRepository


async def main() -> None:
    await connect_db()
    try:
        await PlanRepository().ensure_default_system_configs()
        plans = await PlanRepository().get_plan_configs()
        print({"ok": True, "plan_configs": sorted(plans.keys())})
    finally:
        await close_db()


if __name__ == "__main__":
    asyncio.run(main())
