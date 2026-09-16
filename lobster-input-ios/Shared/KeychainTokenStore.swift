import Foundation
import Security

/// 共享 Keychain 封装，用于在主 App 与键盘扩展之间安全地共享登录 JWT token。
///
/// 共享原理：
/// - 两个 target 的 entitlements 都声明了相同的 `keychain-access-groups`
///   （`$(AppIdentifierPrefix)group.ssh2026.lobster-input`）。
/// - 代码里使用同一个不带前缀的 access group（`accessGroup`），由系统在运行时
///   匹配 entitlements 中声明的同名组（前缀 `$(AppIdentifierPrefix)` 由系统注入）。
/// - 使用 `kSecAttrAccessibleAfterFirstUnlock`，保证键盘扩展在锁屏后被唤醒时仍可读取。
enum KeychainTokenStore {

    /// 固定的 service 标识，作为这条凭据的命名空间。
    private static let service = "ssh2026.lobster-input.credentials"

    /// 单条 token 凭据的 account。
    private static let account = "auth_token"

    /// 共享 access group。代码中传不带 `$(AppIdentifierPrefix)` 前缀的组名，
    /// 与两个 target entitlements 里 `keychain-access-groups` 声明的字符串保持一致；
    /// 系统会自动补上团队前缀完成跨 target 共享。
    private static let accessGroup = "group.ssh2026.lobster-input"

    /// 公共查询基底，所有操作共用同一组定位属性。
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    /// 读取当前存储的 token，不存在时返回 nil。
    /// 不做旧明文迁移（从未上线，均为测试版）：Keychain 中没有即视为登出状态。
    static func get() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    /// 写入 token；传入 nil 等价于删除。
    static func set(_ token: String?) {
        guard let token, !token.isEmpty else {
            delete()
            return
        }

        let data = Data(token.utf8)

        // 先尝试更新已有条目。
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ] as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }

        // 条目不存在则新增。
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// 删除存储的 token。
    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
