"""
管理/运营接口 — 注册封禁排查与解封。
所有接口均受内部 API Key + HMAC 时间戳签名保护，不对外用户开放。

接口设计参考业界标准（Stripe/Twilio 等 PaaS 的运营后台设计）：
  GET  /admin/reg/query              — 按设备码/IP/指纹/邮箱查询关联账号明文信息
  GET  /admin/reg/device-groups      — 聚合查所有多账号设备（巡检用）
  POST /admin/reg/unban              — 解封：硬删除（释放名额）或软禁用账号
  GET  /admin/reg/limit              — 查看当前注册上限配置
  POST /admin/reg/limit              — 修改注册上限（替代手改 MongoDB）

典型解封流程：
  1. 用户反馈误封 → 提供邮箱
  2. GET /admin/reg/query?email=xxx → 查看该账号的设备码/IP/指纹及所有关联账号
  3. 确认是误封后 POST /admin/reg/unban {email, mode: "delete"} → 硬删除，释放名额
  4. 用户重新注册即可
"""
import logging
from datetime import datetime, timezone
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from app.models.schemas import (
    AdminQueryResponse,
    RegAccountInfo,
    RegDeviceGroup,
    RegDeviceGroupListResponse,
    SetRegLimitRequest,
    UnbanRequest,
    UnbanResponse,
)
from app.repositories.agreement_repository import AgreementRepository
from app.repositories.user_repository import UserRepository
from app.middleware.auth import verify_internal_api_key
from app.core.database import get_db

logger = logging.getLogger("voice_input.admin")

router = APIRouter(prefix="/admin/reg", tags=["Admin - RegBlock"])
user_repo = UserRepository()


def _to_account_info(doc: dict) -> RegAccountInfo:
    """将 MongoDB 文档转换为 RegAccountInfo（过滤敏感字段）。"""
    created_raw = doc.get("created_at")
    created_at: datetime | None = None
    if isinstance(created_raw, datetime):
        created_at = created_raw
    elif isinstance(created_raw, str):
        try:
            created_at = datetime.fromisoformat(created_raw)
        except ValueError:
            pass

    return RegAccountInfo(
        email=doc.get("email", ""),
        tier=doc.get("tier", ""),
        is_active=doc.get("is_active", True),
        reg_device_id=doc.get("reg_device_id", ""),
        reg_ip=doc.get("reg_ip", ""),
        reg_hw_fingerprint=doc.get("reg_hw_fingerprint", ""),
        invited_by=doc.get("invited_by", ""),
        created_at=created_at,
    )


# ── 查询接口 ─────────────────────────────────────────────────

@router.get(
    "/query",
    response_model=AdminQueryResponse,
    summary="关联账号查询（按邮箱/设备码/IP/硬件指纹）",
)
async def query_reg_accounts(
    email: str | None = Query(None, description="邮箱（精确或前缀模糊匹配）"),
    device_id: str | None = Query(None, description="设备 UUID（精确）"),
    ip: str | None = Query(None, description="注册 IP（精确）"),
    hw_fingerprint: str | None = Query(None, description="硬件指纹 SHA-256（精确）"),
    _payload: dict = Depends(verify_internal_api_key),
):
    """
    四维查询，优先级：email > device_id > ip > hw_fingerprint。
    返回命中账号列表及封禁状态，供运营人员判断是否误封。
    """
    max_accounts = await user_repo.get_max_accounts_per_device()

    if email:
        docs = await user_repo.find_by_email_prefix(email)
        query_key = f"email={email}"
    elif device_id:
        docs = await user_repo.find_by_device_id(device_id)
        query_key = f"device_id={device_id}"
    elif ip:
        docs = await user_repo.find_by_ip(ip)
        query_key = f"ip={ip}"
    elif hw_fingerprint:
        docs = await user_repo.find_by_hw_fingerprint(hw_fingerprint)
        query_key = f"hw_fingerprint={hw_fingerprint[:16]}..."
    else:
        return AdminQueryResponse(
            query_key="(no query)",
            account_count=0,
            max_accounts_per_device=max_accounts,
            is_over_limit=False,
            accounts=[],
        )

    accounts = [_to_account_info(d) for d in docs]
    count = len(accounts)
    logger.info("[admin] query %s → %d accounts", query_key, count)

    return AdminQueryResponse(
        query_key=query_key,
        account_count=count,
        max_accounts_per_device=max_accounts,
        is_over_limit=count >= max_accounts,
        accounts=accounts,
    )


@router.get(
    "/device-groups",
    response_model=RegDeviceGroupListResponse,
    summary="聚合查询多账号设备列表（巡检用）",
)
async def list_device_groups(
    min_count: int = Query(2, ge=2, description="最少注册账号数（默认 2，即查所有多账号设备）"),
    limit: int = Query(50, ge=1, le=200, description="返回条数上限"),
    _payload: dict = Depends(verify_internal_api_key),
):
    """
    聚合所有同设备码注册账号数 >= min_count 的分组，用于定期巡检。
    建议运营每周查一次 min_count=3 的分组，核实是否存在滥用行为。
    """
    max_accounts = await user_repo.get_max_accounts_per_device()
    raw_groups = await user_repo.get_all_device_groups(min_count=min_count, limit=limit)

    groups = []
    for g in raw_groups:
        account_infos = [_to_account_info(a) for a in g["accounts"]]
        groups.append(RegDeviceGroup(
            device_id=g["device_id"],
            account_count=g["account_count"],
            accounts=account_infos,
        ))

    logger.info("[admin] device-groups min_count=%d → %d groups", min_count, len(groups))
    return RegDeviceGroupListResponse(
        total_groups=len(groups),
        max_accounts_per_device=max_accounts,
        groups=groups,
    )


# ── 解封接口 ─────────────────────────────────────────────────

@router.post(
    "/unban",
    response_model=UnbanResponse,
    summary="解封操作（硬删除释放名额 / 软禁用保留记录）",
)
async def unban_account(
    body: UnbanRequest,
    _payload: dict = Depends(verify_internal_api_key),
):
    """
    两种解封模式：
    - delete（推荐误封场景）：硬删除账号记录，设备/IP/指纹计数自动降低，
      用户可用同设备重新注册。
    - disable（推荐违规封号）：软禁用账号（is_active=False），保留注册记录，
      设备计数不变，用户无法再用该账号登录，但也不释放设备名额。
    """
    email = body.email.strip().lower()
    mode = body.mode.strip().lower()
    reason = body.reason or "（无备注）"

    if mode not in ("delete", "disable"):
        return UnbanResponse(
            email=email,
            mode=mode,
            success=False,
            message="mode 参数无效，必须为 delete 或 disable",
        )

    # 先查是否存在
    user = await user_repo.find_by_email(email)
    if not user:
        logger.warning("[admin] unban target not found: %s", email)
        return UnbanResponse(
            email=email,
            mode=mode,
            success=False,
            message=f"账号 {email} 不存在",
        )

    operator = _payload.get("sub", "unknown_operator")

    if mode == "delete":
        success = await user_repo.delete_by_email(email)
        msg = f"账号已硬删除，设备/IP/指纹注册计数已释放。原因：{reason}"
        logger.info("[admin] HARD DELETE email=%s by=%s reason=%s", email, operator, reason)
    else:
        success = await user_repo.deactivate_by_email(email)
        msg = f"账号已软禁用（is_active=False），注册计数保留。原因：{reason}"
        logger.info("[admin] SOFT DISABLE email=%s by=%s reason=%s", email, operator, reason)

    return UnbanResponse(email=email, mode=mode, success=success, message=msg)


# ── 注册上限配置接口 ─────────────────────────────────────────

@router.get(
    "/limit",
    summary="查看当前注册上限配置",
)
async def get_reg_limit(_payload: dict = Depends(verify_internal_api_key)):
    """查看每设备/IP/指纹的注册账号上限，避免每次都要登录 MongoDB 查看。"""
    max_accounts = await user_repo.get_max_accounts_per_device()
    return {
        "max_accounts_per_device": max_accounts,
        "description": "设备码/IP/硬件指纹任意一维注册数达到此上限则触发联动封禁",
    }


@router.post(
    "/limit",
    summary="修改注册上限配置",
)
async def set_reg_limit(
    body: SetRegLimitRequest,
    _payload: dict = Depends(verify_internal_api_key),
):
    """
    动态修改注册上限（替代手动修改 MongoDB 的繁琐操作）。
    修改立即生效，不需要重启服务。
    """
    config_col = get_db()["system_config"]
    await config_col.update_one(
        {"key": "max_accounts_per_device"},
        {"$set": {"value": body.max_accounts, "updated_at": datetime.now(timezone.utc)}},
        upsert=True,
    )
    operator = _payload.get("sub", "unknown_operator")
    logger.info("[admin] reg limit changed to %d by %s", body.max_accounts, operator)
    return {
        "max_accounts_per_device": body.max_accounts,
        "message": "已更新，立即生效",
        "updated_by": operator,
    }


# ── 协议管理 ──────────────────────────────────────────────

class UpsertAgreementRequest(BaseModel):
    type: str
    lang: str
    content: str


@router.get(
    "/agreements",
    summary="获取所有协议列表（管理员专用）",
)
async def list_agreements(_payload: dict = Depends(verify_internal_api_key)):
    repo = AgreementRepository()
    items = await repo.list_all()
    return items


@router.post(
    "/agreements",
    summary="新增或更新协议内容（管理员专用）",
)
async def upsert_agreement(
    body: UpsertAgreementRequest,
    _payload: dict = Depends(verify_internal_api_key),
):
    repo = AgreementRepository()
    await repo.upsert(body.type, body.lang, body.content)
    return {"message": f"协议 {body.type}/{body.lang} 已更新"}


@router.delete(
    "/agreements/{agreement_type}/{lang}",
    summary="删除协议内容（管理员专用）",
)
async def delete_agreement(
    agreement_type: str,
    lang: str,
    _payload: dict = Depends(verify_internal_api_key),
):
    repo = AgreementRepository()
    ok = await repo.delete(agreement_type, lang)
    if not ok:
        raise HTTPException(status_code=404, detail="协议不存在")
    return {"message": f"协议 {agreement_type}/{lang} 已删除"}
