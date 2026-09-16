"""Plan catalog policy helpers.

Keep subscription business rules data-driven: code decides the state transition
shape, while plan rank/capabilities come from system_config.plan_configs.
"""
from dataclasses import dataclass

FREE_PLAN_CODE = "free"
TRIAL_PLAN_CODE = "trial"


@dataclass(frozen=True)
class PlanPolicy:
    code: str
    paid: bool
    enabled: bool
    rank: int
    plan_family: str
    stackable: bool
    self_checkout_enabled: bool
    manual_assign_enabled: bool
    auto_renew_supported: bool
    paid_topup_enabled: bool
    lifecycle_status: str

    @classmethod
    def from_config(cls, config: dict | None, fallback_code: str = "") -> "PlanPolicy":
        cfg = config or {}
        code = cfg.get("code") or fallback_code
        paid = bool(cfg.get("paid", bool(code) and code not in {FREE_PLAN_CODE, TRIAL_PLAN_CODE}))
        enabled = bool(cfg.get("enabled", True))
        return cls(
            code=code,
            paid=paid,
            enabled=enabled,
            rank=int(cfg.get("rank", 0 if not paid else 10) or 0),
            plan_family=cfg.get("plan_family") if cfg.get("plan_family") in {"base", "addon"} else "base",
            stackable=bool(cfg.get("stackable", False)),
            self_checkout_enabled=bool(cfg.get("self_checkout_enabled", paid)),
            manual_assign_enabled=bool(cfg.get("manual_assign_enabled", True)),
            auto_renew_supported=bool(cfg.get("auto_renew_supported", paid)),
            paid_topup_enabled=bool(cfg.get("paid_topup_enabled", paid)),
            lifecycle_status=(cfg.get("lifecycle_status") or ("active" if enabled else "archived")).strip().lower(),
        )

    @property
    def is_active_catalog_item(self) -> bool:
        return self.enabled and self.lifecycle_status == "active"

    @property
    def is_base_subscription(self) -> bool:
        return self.plan_family == "base" and not self.stackable

    @property
    def can_self_checkout_subscription(self) -> bool:
        return self.paid and self.is_active_catalog_item and self.is_base_subscription and self.self_checkout_enabled

    @property
    def can_auto_renew(self) -> bool:
        return self.paid and self.auto_renew_supported and self.is_base_subscription

    def can_replace_immediately(self, current: "PlanPolicy") -> bool:
        return self.rank >= current.rank
