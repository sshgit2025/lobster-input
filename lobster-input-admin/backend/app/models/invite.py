from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime


class InviteCodeItem(BaseModel):
    code: str
    owner_email: str
    is_used: bool
    used_by: Optional[str] = None
    used_at: Optional[datetime] = None
    created_at: Optional[datetime] = None


class CreateInviteCodeRequest(BaseModel):
    owner_email: str
    count: int = 1


class PaginatedInviteCodes(BaseModel):
    total: int
    page: int
    page_size: int
    items: List[InviteCodeItem]
