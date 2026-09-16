"""支付计费域路由包(payments)。

由单文件 payments.py(2392 行 God File)按路由域拆分而来:
  _common       共享内核(工具/常量/鉴权/依赖)
  catalog       /catalog
  admin         /admin/*(配置/折扣/订单/交易/退款)
  checkout      /checkout/*、/quote/*
  subscription  /portal/*、/subscription/*
  callback      /callback/*
  webhook       /webhook/{provider}

本包在此原样重导出「拆分前单文件对外暴露的全部符号」——共享内核经 `from ._common import *`
统一带出(供 apple_iap / webhook_admin / catalog_admin / return_page 及测试直接
`from app.api.v1.payments import _xxx`),各域端点显式重导出。故所有既有导入零改动。
路由注册顺序与拆分前一致,保证路径匹配零漂移。
"""
from fastapi import APIRouter

# 先导入各域子模块(构建 router;子模块内部只依赖 ._common 与单向 webhook->callback,无环)
from app.api.v1.payments import (
    catalog,
    admin,
    checkout,
    subscription,
    callback,
    webhook,
)

# 共享内核:重导出全部工具/常量/鉴权(verify_callback_key、_normalize_provider、
# _event_exists、_downgrade_user_to_free、_can_replace_immediately … 均在此带出)。
from app.api.v1.payments._common import *  # noqa: F401,F403

# 各域端点:显式重导出,保持与拆分前单文件完全一致的可导入符号面。
from app.api.v1.payments.catalog import payment_provider_catalog  # noqa: F401
from app.api.v1.payments.admin import (  # noqa: F401
    admin_billing_config,
    save_admin_billing_config,
    admin_discount_status,
    admin_orders,
    admin_order_detail,
    admin_transactions,
    admin_refunds,
    admin_refund_detail,
    admin_order_refund,
)
from app.api.v1.payments.checkout import (  # noqa: F401
    create_subscription_checkout,
    quote_subscription_options,
    create_credits_topup_checkout,
)
from app.api.v1.payments.subscription import (  # noqa: F401
    subscription_manage_portal,
    cancel_subscription_renewal,
)
from app.api.v1.payments.callback import subscription_callback, credits_topup_callback  # noqa: F401
from app.api.v1.payments.webhook import (  # noqa: F401
    apply_subscription_status,
    dispatch_webhook_event,
    payment_provider_webhook,
    _webhook_provider_accounts,
)

router = APIRouter(prefix="/payments", tags=["payments"])
router.include_router(catalog.router)
router.include_router(admin.router)
router.include_router(checkout.router)
router.include_router(subscription.router)
router.include_router(callback.router)
router.include_router(webhook.router)
