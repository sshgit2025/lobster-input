from fastapi import APIRouter

from app.api.v1 import apple_iap, catalog_admin, payments, return_page, webhook_admin

router = APIRouter(prefix="/api/v1")
router.include_router(payments.router)
# 支付中转页:含 /payments/{provider}/return 路径参数路由,紧跟 payments.router 之后注册,
# 保持其相对原单文件时的末位顺序,避免与其它 /payments/* 路由发生匹配遮蔽。
router.include_router(return_page.router)
router.include_router(apple_iap.router)
router.include_router(webhook_admin.router)
router.include_router(catalog_admin.router)
