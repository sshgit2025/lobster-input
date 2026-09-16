# 邀请码系统技术文档

> 版本：v1.0 | 创建时间：2026-03-16 | 适用模块：Auth / Registration

## 1. 背景与目标

邀请码系统是用于**临时限制注册膨胀**的轻量策略，非永久功能。核心目标：

- 控制新用户注册速度，避免早期 Beta 阶段用户量爆发导致服务过载
- 结合多维设备指纹，防止批量脚本注册滥用
- 保持低侵入性：后续迭代可随时下掉，不影响已注册用户

**设计原则**：

1. 邀请码校验由后端全权控制，客户端无法绕过
2. 是否展示邀请码界面完全由后端响应决定（`require_invite` 字段），前端不写死任何逻辑判断
3. 注册成功前不签发任何 JWT，防止空壳登录

---

## 2. 系统整体流程

### 2.1 老用户登录流程（无变化）

```
客户端                          后端
  │                              │
  ├── POST /auth/send-code ──────►  ① 临时邮箱黑名单检查
  │                              │  ② 同邮箱 60s 冷却检查
  │                              │  ③ 同 IP 每小时发码上限
  │                              │  ④ 生成验证码并发送邮件
  │◄── 200 OK ──────────────────┤
  │                              │
  ├── POST /auth/verify ─────────►  ① 验证码校验
  │   {email, code}              │  ② 查询用户是否存在
  │                              │  ③ 已存在 → 签发 JWT
  │◄── {token, is_new_user:false}┤
  │                              │
  └── 进入主界面 ✓               │
```

### 2.2 新用户注册流程（含邀请码）

```
客户端                          后端
  │                              │
  ├── POST /auth/send-code ──────►  ① 临时邮箱黑名单 + 频率限制
  │◄── 200 OK ──────────────────┤
  │                              │
  ├── POST /auth/verify ─────────►  ① 验证码校验
  │   {email, code}              │  ② 查询用户是否存在
  │                              │  ③ 不存在 → 保存 pending_invite 状态
  │◄── {token:"", require_invite:true}
  │                              │
  │   [跳转 InviteCodeView]      │
  │                              │
  ├── POST /auth/verify-invite ──►  ① pending_invite 会话校验
  │   {email, invite_code,       │  ② 邀请码有效性校验
  │    device_id,                │  ③ 三维联动封禁检查（设备码/IP/指纹）
  │    hardware_fingerprint}     │  ④ 消耗邀请码（mark_used）
  │                              │  ⑤ 创建用户（明文存储注册信息）
  │                              │  ⑥ 为新用户生成 3 个邀请码
  │                              │  ⑦ 签发 JWT
  │◄── {token, is_new_user:true} ┤
  │                              │
  └── 进入主界面 ✓               │
```

---

## 3. 防滥注册策略（三维联动封禁）

### 3.1 三维度说明

| 维度 | 字段 | 采集方式 | 说明 |
|------|------|---------|------|
| 设备 UUID | `reg_device_id` | 客户端 `IOPlatformUUID`（IOKit） | 主板级唯一标识，虚拟机可伪造 |
| 硬件指纹 | `reg_hw_fingerprint` | SHA-256(UUID + CPU核数 + 内存大小 + 硬盘序列号) | 多项组合哈希，提高伪造成本 |
| 注册 IP | `reg_ip` | 后端从 `X-Forwarded-For` / `request.client` 提取 | 防同 IP 批量注册 |

### 3.2 联动封禁逻辑

**任意一维**达到 `max_accounts_per_device`（默认 3，运营可动态配置），三维全部封禁：

```python
device_blocked  = device_count  >= max_accounts
ip_blocked      = ip_count      >= max_accounts
fp_blocked      = fp_count      >= max_accounts

if device_blocked or ip_blocked or fp_blocked:
    raise AppException(403, "REG_LIMIT_REACHED", "该设备或网络注册账号已达上限")
```

> **设计意图**：防止攻击者换 IP 绕过设备限制，或换设备绕过 IP 限制。只要一维满额，即视为整体封禁。

### 3.3 发码频率限制

| 限制类型 | 规则 | 实现 |
|---------|------|------|
| 同邮箱冷却 | 60 秒内不可重发 | 内存字典 `_last_send_by_email` |
| 同 IP 每小时上限 | 每 IP 每小时最多 20 次 | 滑动窗口 `_send_history_by_ip` |

> ⚠️ **注意**：频率限制为进程内内存实现，服务重启后重置。多进程/多实例部署时需迁移至 Redis。

### 3.4 临时邮箱域名黑名单

内置 74 个常见一次性邮箱服务域名（mailinator / guerrillamail / yopmail / 10minutemail 等），在发码接口前置拦截。黑名单定义在 `auth_service.py` 的 `DISPOSABLE_EMAIL_DOMAINS` 常量，可随时增删无需重启。

---

## 4. 邀请码规格

| 属性 | 值 | 说明 |
|------|-----|------|
| 长度 | 8 位 | |
| 字符集 | `ABCDEFGHJKMNPQRSTUVWXYZ23456789` | 去掉易混淆字符 `0/O/1/I/L` |
| 每用户生成数量 | 3 个 | 注册成功后立即生成 |
| 有效期 | 无限期 | 仅限一次性使用 |
| 唯一性保证 | 生成时碰撞重试，`code` 字段唯一索引 | |

邀请码生成算法（`invite_repository.py`）：

```python
INVITE_CHARSET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
INVITE_CODE_LENGTH = 8

def _generate_code() -> str:
    return "".join(random.choices(INVITE_CHARSET, k=INVITE_CODE_LENGTH))
```

---

## 5. 数据模型

### 5.1 用户文档（`users` 集合）

注册相关字段（明文存储，用于运营排查）：

```json
{
  "email": "user@example.com",
  "tier": "trial",
  "is_active": true,
  "reg_device_id": "12345678-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
  "reg_ip": "1.2.3.4",
  "reg_hw_fingerprint": "a3f1c2...（64位 SHA-256 hex）",
  "invited_by": "inviter@example.com",
  "created_at": "2026-03-16T05:00:00Z"
}
```

### 5.2 邀请码文档（`invite_codes` 集合）

```json
{
  "code": "AB3X7KN2",
  "owner_email": "owner@example.com",
  "is_used": false,
  "used_by": null,
  "used_at": null,
  "created_at": "2026-03-16T05:00:00Z"
}
```

索引：`code`（唯一）、`owner_email`、`used_by`

### 5.3 系统配置（`system_config` 集合）

```json
{ "key": "max_accounts_per_device", "value": 3 }
```

---

## 6. API 接口

### 6.1 发送验证码

```
POST /api/v1/auth/send-code
Body: { "email": "user@example.com" }
```

前置校验顺序：临时邮箱域名 → 同邮箱 60s 冷却 → 同 IP 每小时限额

### 6.2 验证码确认（区分新老用户）

```
POST /api/v1/auth/verify
Body: { "email": "user@example.com", "code": "123456" }

响应（老用户）：
{ "token": "eyJ...", "email": "...", "tier": "trial", "is_new_user": false, "require_invite": false }

响应（新用户）：
{ "token": "", "email": "...", "tier": "", "is_new_user": true, "require_invite": true }
```

### 6.3 新用户邀请码校验完成注册

```
POST /api/v1/auth/verify-invite
Body:
{
  "email": "user@example.com",
  "invite_code": "AB3X7KN2",
  "device_id": "12345678-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
  "hardware_fingerprint": "a3f1c2..."
}
```

注意：`client_ip` 由后端从请求头自动提取，不依赖客户端上报。

### 6.4 获取我的邀请码

```
GET /api/v1/auth/invite-codes
Header: Authorization: Bearer <token>

响应：
{
  "invite_codes": [
    { "code": "AB3X7KN2", "is_used": false, "used_by": null, "used_at": null },
    { "code": "PQ9M3FVZ", "is_used": true,  "used_by": "abc***@gmail.com", "used_at": "..." },
    { "code": "KN8W2TXR", "is_used": false, "used_by": null, "used_at": null }
  ]
}
```

> `used_by` 字段经过邮箱脱敏（前3位保留，其余替换为 `*`）。

---

## 7. 客户端实现

### 7.1 文件清单

| 文件 | 职责 |
|------|------|
| `Features/Auth/AuthViewModel.swift` | 验证码发送/校验逻辑，`hardwareFingerprint()` 采集硬件指纹 |
| `Features/Auth/InviteCodeView.swift` | 邀请码输入界面（新用户跳转） |
| `Features/Main/MyInviteCodesView.swift` | 查看我的邀请码弹窗 |
| `Core/Network/AuthStore.swift` | 登录状态管理，`pendingInviteEmail` 临时存储 |
| `Core/Network/APIClient.swift` | `verifyInvite` / `fetchMyInviteCodes` 接口封装 |
| `Models/APIModels.swift` | `VerifyInviteRequest` / `AuthResponse` / `InviteCodeItem` 数据模型 |

### 7.2 硬件指纹采集

```swift
static func hardwareFingerprint() -> String {
    let components = [
        deviceID(),                                          // IOPlatformUUID
        "\(ProcessInfo.processInfo.processorCount)",         // CPU 核心数
        "\(ProcessInfo.processInfo.physicalMemory)",         // 物理内存（字节）
        diskSerialNumber(),                                  // 主硬盘序列号（IOKit）
    ]
    let raw = components.joined(separator: "|")
    let digest = SHA256.hash(data: Data(raw.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}
```

### 7.3 UI 状态流转

```
AuthView（输入邮箱 + 验证码）
    │
    ├── require_invite = false → 直接进入主界面
    │
    └── require_invite = true  → InviteCodeView（输入邀请码）
                                      │
                                      ├── 成功 → 主界面
                                      └── 失败 → 错误提示，停留在 InviteCodeView
```

### 7.4 国际化（i18n）

邀请码功能相关的新增字符串通过 `AppStrings` 协议统一管理，支持 DIY 覆盖：

| 字段 | 用途 |
|------|------|
| `invitePageTitle` | 邀请码页面标题 |
| `invitePageSubtitle` | 副标题说明文案 |
| `inviteCodePlaceholder` | 输入框占位符 |
| `inviteSubmitButton` | 提交按钮文案 |
| `errorInvalidInviteCode` | 无效邀请码错误 |
| `errorInviteSessionExpired` | 填写会话过期错误 |
| `errorRegLimitReached` | 注册名额已满（三维联动封禁统一文案） |
| `errorDisposableEmail` | 临时邮箱拦截错误 |
| `errorSendCodeTooFrequent` | 发码频率超限错误 |

支持语言：简体中文、繁体中文、英语、韩语、俄语。

---

## 8. 运营管理接口

所有管理接口均受内部 `X-API-Key` + HMAC 时间戳签名保护，不对外用户开放。

### 8.1 接口清单

| 接口 | 方法 | 说明 |
|------|------|------|
| `/api/v1/admin/reg/query` | GET | 按邮箱/设备码/IP/硬件指纹查询关联账号明文信息 |
| `/api/v1/admin/reg/device-groups` | GET | 聚合查多账号设备列表（定期巡检） |
| `/api/v1/admin/reg/unban` | POST | 解封：硬删除（释放名额）或软禁用账号 |
| `/api/v1/admin/reg/limit` | GET | 查看当前注册上限 |
| `/api/v1/admin/reg/limit` | POST | 动态修改注册上限（无需重启服务） |

### 8.2 典型误封排查流程

```
1. 用户反馈误封 → 提供注册邮箱

2. 查询关联账号：
   GET /api/v1/admin/reg/query?email=user@example.com

   响应示例：
   {
     "query_key": "email=user@example.com",
     "account_count": 1,
     "max_accounts_per_device": 3,
     "is_over_limit": false,
     "accounts": [{
       "email": "user@example.com",
       "reg_device_id": "12345678-...",
       "reg_ip": "1.2.3.4",
       "reg_hw_fingerprint": "a3f1c2...",
       "created_at": "2026-03-16T05:00:00Z"
     }]
   }

3. 用同设备码再查，确认关联账号数量：
   GET /api/v1/admin/reg/query?device_id=12345678-...

4. 确认误封后执行解封（硬删除，释放设备名额）：
   POST /api/v1/admin/reg/unban
   { "email": "user@example.com", "mode": "delete", "reason": "误封确认，正常用户" }

5. 通知用户重新注册
```

### 8.3 解封模式对比

| 模式 | 操作 | 设备名额 | 适用场景 |
|------|------|---------|---------|
| `delete` | 硬删除账号记录 | **释放**（计数 -1） | 误封：正常用户被误判 |
| `disable` | 软禁用（is_active=false） | **保留**（计数不变） | 违规封号：封号但不释放名额 |

---

## 9. 后端文件清单

| 文件 | 职责 |
|------|------|
| `app/services/auth_service.py` | 核心逻辑：验证码校验、邀请码校验、三维封禁、发码频率限制 |
| `app/repositories/invite_repository.py` | 邀请码 CRUD（生成、查询有效码、标记使用） |
| `app/repositories/user_repository.py` | 用户 CRUD + 三维注册计数 + 关联查询 + 解封操作 |
| `app/repositories/verify_code_repository.py` | 验证码存取（含 pending_invite 状态暂存） |
| `app/api/v1/auth.py` | Auth 路由：send-code / verify / verify-invite / invite-codes |
| `app/api/v1/admin.py` | 管理路由：query / device-groups / unban / limit |
| `app/models/schemas.py` | Pydantic 数据模型定义 |
| `scripts/generate_invite_codes.py` | 离线脚本：为已注册但未生成邀请码的用户补全邀请码 |

---

## 10. 注意事项与后续迭代建议

### 10.1 下线邀请码功能的步骤

当运营决定开放注册时，只需：

1. 后端 `auth_service.verify_unified` 中将 `require_invite` 固定返回 `false`
2. 客户端 `AuthViewModel.verify()` 已通过后端响应判断，无需改代码
3. 保留 `invite_codes` 集合和相关接口，已生成的邀请码继续有效（或直接弃用集合）

### 10.2 频率限制升级（多实例部署时）

当服务扩展为多进程/多实例时，需将内存频率限制迁移至 Redis：

```python
# 当前（内存）
_last_send_by_email: dict[str, float] = {}

# 升级后（Redis）
await redis.set(f"send_code:email:{email}", "1", ex=RESEND_COOLDOWN_SEC, nx=True)
```

### 10.3 安全建议

- 生产环境建议将 `/api/v1/admin` 路径通过 Nginx 限制为**仅内网访问**
- `max_accounts_per_device` 配置建议根据注册速率动态调整，初始值 3
- 临时邮箱黑名单 `DISPOSABLE_EMAIL_DOMAINS` 应定期更新（推荐每月同步一次 [disposable-email-domains](https://github.com/disposable-email-domains/disposable-email-domains) 仓库）
