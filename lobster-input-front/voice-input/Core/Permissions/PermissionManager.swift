/// PermissionManager.swift
/// 系统权限统一管理器（单例）。
/// 管理两项权限: 麦克风（录音）、辅助功能（全局快捷键 + 选中文本读取 + Cmd+V 填充）。
/// 启动时静默检查状态，使用时按需申请，App 重新获得焦点时自动刷新。
import Foundation
import Combine
import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// 权限状态枚举
enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

@MainActor
final class PermissionManager: ObservableObject {

    static let shared = PermissionManager()
    private let screenCaptureRequestedKey = "screen_capture_permission_requested"
    private init() {
        // 监听 App 重新获得焦点，自动刷新权限状态
        // 用户在系统设置授权后切回 App 时触发
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatuses()
            }
        }
    }

    @Published var microphoneStatus: PermissionStatus     = .notDetermined
    @Published var accessibilityStatus: PermissionStatus  = .notDetermined
    @Published var screenCaptureStatus: PermissionStatus  = .notDetermined

    var allGranted: Bool {
        microphoneStatus == .granted &&
        accessibilityStatus == .granted
    }

    var corePermissionsGranted: Bool { allGranted }

    func refreshStatuses() {
        microphoneStatus = currentMicrophoneStatus()
        screenCaptureStatus = currentScreenCaptureStatus()
        if microphoneStatus == .granted {
            Task { await AudioRecorder.shared.prewarmIfNeeded() }
        }
        refreshAccessibilityStatus(reason: "refreshStatuses")
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = granted ? .granted : .denied
        if granted {
            await AudioRecorder.shared.prewarmIfNeeded()
        }
    }

    /// 请求辅助功能权限（弹出系统提示）
    /// 非沙盒环境下，AXIsProcessTrustedWithOptions(prompt:true) 会在系统设置中注册 App
    /// 并在首次调用时弹出授权提示；已授权时静默返回 true
    func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityStatus = trusted ? .granted : .denied
    }

    @discardableResult
    func requestScreenCaptureIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            screenCaptureStatus = .granted
            return true
        }
        UserDefaults.standard.set(true, forKey: screenCaptureRequestedKey)
        let granted = CGRequestScreenCaptureAccess()
        screenCaptureStatus = granted ? .granted : .denied
        return granted
    }

    /// 静默检查辅助功能权限（不弹窗），用于启动时初始化状态
    /// 非沙盒 App 必须调用此方法让系统将 App 注册到 TCC 数据库
    func checkAccessibilitySilently() {
        refreshAccessibilityStatus(reason: "checkAccessibilitySilently")
    }

    /// 轻量同步辅助功能权限状态。
    /// 热键和回填链路只需要知道 AX 当前是否可信，不能复用 refreshStatuses()
    /// 那类会检查麦克风、屏幕录制并触发音频预热的重型刷新。
    @discardableResult
    func refreshAccessibilityStatus(reason: String) -> Bool {
        let rawTrusted = AXIsProcessTrusted()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let optionsTrusted = AXIsProcessTrustedWithOptions(options)
        let trusted = rawTrusted || optionsTrusted
        let nextStatus: PermissionStatus = trusted ? .granted : .denied
        let previousStatus = accessibilityStatus
        accessibilityStatus = nextStatus

        if previousStatus != nextStatus {
            DebugTrace.log(
                "PermissionManager.accessibility sync reason=\(reason), previous=\(debugName(previousStatus)), next=\(debugName(nextStatus)), rawTrusted=\(rawTrusted), optionsTrusted=\(optionsTrusted)"
            )
        } else if !trusted {
            DebugTrace.log(
                "PermissionManager.accessibility sync denied reason=\(reason), rawTrusted=\(rawTrusted), optionsTrusted=\(optionsTrusted)"
            )
        }

        return trusted
    }

    func openMicrophoneSettings() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenCaptureSettings() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    // MARK: - Private

    private func openURL(_ string: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [string]
        try? process.run()
    }

    private func currentMicrophoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:           return .granted
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .notDetermined
        @unknown default:           return .notDetermined
        }
    }

    private func currentScreenCaptureStatus() -> PermissionStatus {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: screenCaptureRequestedKey) ? .denied : .notDetermined
    }

    private func debugName(_ status: PermissionStatus) -> String {
        switch status {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .notDetermined:
            return "notDetermined"
        }
    }

}
