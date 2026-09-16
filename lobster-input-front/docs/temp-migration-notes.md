# 临时迁移参考文档（用后删除）

## 一、feature/standard 分支与 feature/diy-customization 分支差异

两个分支从 commit `9c3ffd2` 分叉。standard 无 DIY 功能，无 DIYConfigStore、LanguageManager 等。

---

## 二、需要移植到 standard 的内容

### 2.1 后端（backend）— 直接合并，无差异

以下文件在 diy 分支上新增/修改，standard 分支完全没有，直接复制：

| 文件 | 说明 |
|---|---|
| `backend/app/models/schemas.py` | AuthResponse 新增 is_new_user/require_invite；VerifyInviteRequest；InviteCodeItem 等 |
| `backend/app/repositories/invite_repository.py` | 邀请码 CRUD，NEW |
| `backend/app/repositories/user_repository.py` | 注册设备/IP/指纹字段、管理查询方法 |
| `backend/app/services/auth_service.py` | verify_invite、联动封禁、邮件频率限制、弃用域名黑名单 |
| `backend/app/api/v1/auth.py` | /verify-invite、/invite-codes 端点 |
| `backend/app/api/v1/admin.py` | 管理运营端点，NEW |
| `backend/app/api/v1/__init__.py` | 注册 admin_router |
| `backend/app/main.py` | lifespan 中 await InviteRepository().ensure_indexes() |
| `scripts/generate_invite_codes.py` | 数据清洗脚本，NEW |

### 2.2 客户端（非DIY版本）— 需要移植 + 适配

#### A. 数据隔离修复（standard 无此实现，必须补）

**HistoryStore.swift 修复要点：**
- 原路径：`~/Documents/recording_history.json`（共享）
- 目标路径：`~/Documents/VoiceInputHistory/<email_sha256_16位>/recording_history.json`
- audioDirectory 同样改为用户子目录
- `init()` 不做任何加载；加载入口改为 `reloadForCurrentUser()`
- 增加 `clearMemory()` 方法（清空内存，不删磁盘）
- 参考：diy 分支的 `HistoryStore.swift` 完整实现

**HotKeyManager.swift 修复要点：**
- 原 key：`"hotkey_configs"`（共享）
- 目标 key：`"hotkey_configs_<email FNV-1a hash 16位>"`
- 增加 `reloadForCurrentUser()` 方法
- 参考：diy 分支的 HotKeyManager 实现（仅改 userDefaultsKey 部分）

**AuthStore.swift 修复要点（关键时序）：**
- `save()` 加 `@MainActor`，先设 email，同步调各 store reload，**最后设 token**（触发 isLoggedIn=true → UI 切换）
- `logout()` 加 `@MainActor`，先同步 clearMemory/reload，**最后清 token/email**
- 这样确保 MainView 第一帧渲染时就是正确的账号状态

```swift
@MainActor
func save(_ response: AuthResponse) {
    email = response.email.isEmpty ? nil : response.email
    tier = response.tier.isEmpty ? "trial" : response.tier
    HistoryStore.shared.reloadForCurrentUser()
    HotKeyManager.shared.reloadForCurrentUser()
    token = response.token.isEmpty ? nil : response.token  // 最后触发UI切换
}

@MainActor
func logout() {
    HistoryStore.shared.clearMemory()
    HotKeyManager.shared.reloadForCurrentUser()
    RecordingResultStore.shared.clear()
    token = nil
    email = nil
    tier = "trial"
    pendingInviteEmail = nil
}
```

**voice_inputApp.swift 修复要点：**
- `onMainViewAppear()` 中已登录时补调：
```swift
Task { @MainActor in
    HistoryStore.shared.reloadForCurrentUser()
    HotKeyManager.shared.reloadForCurrentUser()
}
```

#### B. 邀请码功能（非DIY版本，无 L10n/DIY 依赖）

**需要新增的文件：**
- `Features/Auth/InviteCodeView.swift` — 去掉 CyberTheme，用标准 SwiftUI 样式
- `Features/Main/MyInviteCodesView.swift` — 同上

**需要修改的文件：**
- `Models/APIModels.swift` — 新增 AuthResponse.isNewUser/requireInvite、VerifyInviteRequest、InviteCodeItem 等
- `Core/Network/APIClient.swift` — 新增 verifyInvite()、fetchMyInviteCodes()
- `Core/Network/AuthStore.swift` — 新增 pendingInviteEmail
- `Features/Auth/AuthViewModel.swift` — 新增 showInviteStep、deviceID()、hardwareFingerprint()、submitInvite()
- `Features/Auth/AuthView.swift` — 切换显示 InviteCodeView

**需要参考的字符串（直接硬编码英文/中文，无 L10n）：**
- 邀请码页面标题："受邀才能使用" / "Invitation Required"
- 占位符："请输入8位邀请码" / "Enter 8-character invite code"
- 错误码映射：INVALID_INVITE_CODE、INVITE_SESSION_EXPIRED、REG_LIMIT_REACHED
- 邀请码面板：在 MainView 合适位置（如底部信息区或菜单）入口

---

## 三、数据隔离方案速查

### email hash 算法（FNV-1a，与 diy 分支保持一致）

```swift
private static func emailHash(_ email: String) -> String {
    let data = Data(email.lowercased().utf8)
    var hash: UInt64 = 14695981039346656037
    for byte in data { hash ^= UInt64(byte); hash = hash &* 1099511628211 }
    return String(format: "%016llx", hash)
}
```

### HistoryStore 用户目录

```
~/Documents/VoiceInputHistory/<emailHash前16位>/recording_history.json
~/Documents/VoiceInputHistory/<emailHash前16位>/AudioFiles/
```

### HotKeyManager UserDefaults key

```
hotkey_configs_<emailHash16位>
```

---

## 四、邀请码核心逻辑速查

### 登录流程（AuthViewModel）

```
发送验证码 → 输入验证码 → 调 /auth/verify
  → resp.requireInvite == true → 显示 InviteCodeView（pendingInviteEmail）
  → resp.requireInvite == false → authStore.save(resp) → 进主界面
```

### 提交邀请码（AuthViewModel.submitInvite）

```swift
let req = VerifyInviteRequest(
    email: pendingInviteEmail,
    inviteCode: code,
    deviceId: AuthViewModel.deviceID(),
    hardwareFingerprint: AuthViewModel.hardwareFingerprint()
)
let resp = try await APIClient.shared.verifyInvite(req)
authStore.save(resp)
```

### 设备 ID（IOKit，已验证可用）

```swift
static func deviceID() -> String {
    let service = IOServiceGetMatchingService(kIOMasterPortDefault,
        IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(service) }
    return (IORegistryEntryCreateCFProperty(service,
        "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        .takeRetainedValue() as? String) ?? UUID().uuidString
}
```

### 硬件指纹（SHA256，已验证可用）

```swift
static func hardwareFingerprint() -> String {
    // 组合: IOPlatformUUID | CPU核心数 | 物理内存 | 主硬盘序列号
    // SHA256 hex string
}
```

完整实现参考 diy 分支 `AuthViewModel.swift` 的 `hardwareFingerprint()` 和 `diskSerialNumber()`。

### 我的邀请码入口

- `GET /auth/invite-codes` — 返回该用户的3个邀请码及使用状态
- 在 MainView 底部或次要位置放一个低调入口（如"关于/账号信息"附近）

---

## 五、standard 分支不需要实现的内容

- DIYConfigStore 相关的一切
- LanguageManager 的账号隔离（standard 无 LanguageManager）
- L10n 多语言文件中的邀请码字符串（直接硬编码两种语言即可）
- 管理端 UI（admin.py 后端移植，客户端无需实现管理界面）
