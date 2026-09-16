/// OnboardingManager.swift
/// 引导教程状态管理器（单例）。
/// 使用 "账号邮箱 + 设备硬件UUID" 组合键存储引导完成状态，
/// 确保同一设备同一账号仅展示一次引导教程。
import Foundation
import Combine
import IOKit

@MainActor
final class OnboardingManager: ObservableObject {

    static let shared = OnboardingManager()

    private init() {
        // 启动时同步计算：若已登录且未完成引导 → 直接标记需要展示
        if let email = AuthStore.shared.email {
            let key = Self.storageKey(for: email)
            self._shouldShowOnboarding = Published(initialValue: !UserDefaults.standard.bool(forKey: key))
        } else {
            self._shouldShowOnboarding = Published(initialValue: false)
        }
    }

    @Published var shouldShowOnboarding: Bool

    private static let keyPrefix = "onboarding_completed_"

    /// 登录态变化后重新检查（新登录 / 切换账号）
    func checkOnboardingNeeded() {
        guard let email = AuthStore.shared.email else {
            shouldShowOnboarding = false
            return
        }
        let key = Self.storageKey(for: email)
        shouldShowOnboarding = !UserDefaults.standard.bool(forKey: key)
    }

    /// 标记当前账号在当前设备上的引导已完成
    func markCompleted() {
        guard let email = AuthStore.shared.email else { return }
        let key = Self.storageKey(for: email)
        UserDefaults.standard.set(true, forKey: key)
        shouldShowOnboarding = false
    }

    /// 从设置页重新进入引导教程。
    /// 不清除持久化的完成标记：中途退出或重启后不会再次自动弹出教程。
    func replay() {
        shouldShowOnboarding = true
    }

    /// 组合键：prefix + SHA256(email + deviceUUID)
    private static func storageKey(for email: String) -> String {
        let raw = email.lowercased() + "_" + deviceUUID()
        let hash = raw.djb2Hash
        return "\(keyPrefix)\(hash)"
    }

    /// 获取设备硬件 UUID（IOKit）
    private static func deviceUUID() -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != IO_OBJECT_NULL else { return "unknown" }
        defer { IOObjectRelease(service) }

        if let uuidRef = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String {
            return uuidRef
        }
        return "unknown"
    }
}

private extension String {
    /// DJB2 哈希，轻量且足够用于 UserDefaults key 去重
    var djb2Hash: String {
        var hash: UInt64 = 5381
        for byte in self.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
