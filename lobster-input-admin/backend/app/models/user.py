from pydantic import BaseModel
from typing import Optional, List
from datetime import datetime


class UserListItem(BaseModel):
    email: str
    plan_code: str
    is_active: bool
    reg_device_id: Optional[str] = None
    reg_ip: Optional[str] = None
    invited_by: Optional[str] = None
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None


class UserDetail(UserListItem):
    reg_hw_fingerprint: Optional[str] = None
    hashed_password: Optional[str] = None


class BanUserRequest(BaseModel):
    email: str


class UnbanUserRequest(BaseModel):
    email: str


class UserQueryParams(BaseModel):
    email: Optional[str] = None
    device_id: Optional[str] = None
    ip: Optional[str] = None
    plan_code: Optional[str] = None
    is_active: Optional[bool] = None
    page: int = 1
    page_size: int = 20


class PaginatedUsers(BaseModel):
    total: int
    page: int
    page_size: int
    items: List[UserListItem]


class EmailRequest(BaseModel):
    email: str


class GrantCreditsRequest(BaseModel):
    email: str
    amount: int
    expires_at: Optional[datetime] = None
    expires_at_mode: str = "manual"
    reason: str = ""
