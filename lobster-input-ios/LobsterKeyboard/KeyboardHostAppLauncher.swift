import UIKit
import os.log

private let launcherLog = Logger(subsystem: "ssh2026.lobster-input-ios", category: "KeyboardHostAppLauncher")

/// 键盘扩展拉起主 App（iOS 18 下 extensionContext.open 常失效，需多路径尝试）
enum KeyboardHostAppLauncher {

    static let activateVoiceSessionURL = URL(string: "lobster-input://activate-voice-session")!

    /// 尽可能拉起主 App；completion 在主线程回调是否至少一条路径已触发
    static func openActivateVoiceSession(
        extensionContext: NSExtensionContext?,
        responder: UIResponder?,
        completion: ((Bool) -> Void)? = nil
    ) {
        let url = activateVoiceSessionURL
        var anyTriggered = false

        if openViaSharedApplication(url) {
            launcherLog.info("opened via UIApplication.shared hack")
            anyTriggered = true
        }

        if openViaResponderChain(url: url, from: responder) {
            launcherLog.info("opened via responder chain")
            anyTriggered = true
        }

        if let view = responder as? UIView {
            if openViaResponderChain(url: url, from: view) {
                anyTriggered = true
            }
        }

        if let context = extensionContext {
            context.open(url) { success in
                launcherLog.info("extensionContext.open success=\(success, privacy: .public)")
                DispatchQueue.main.async {
                    completion?(anyTriggered || success)
                }
            }
            if anyTriggered {
                DispatchQueue.main.async { completion?(true) }
            }
            return
        }

        DispatchQueue.main.async { completion?(anyTriggered) }
    }

    @discardableResult
    private static func openViaSharedApplication(_ url: URL) -> Bool {
        guard let appClass = NSClassFromString("UIApplication") as? NSObject.Type else { return false }
        let sharedSel = NSSelectorFromString("sharedApplication")
        guard appClass.responds(to: sharedSel),
              let app = appClass.perform(sharedSel)?.takeUnretainedValue() as? UIApplication
        else { return false }

        if app.responds(to: #selector(UIApplication.open(_:options:completionHandler:))) {
            app.open(url, options: [:]) { success in
                launcherLog.info("UIApplication.open completion=\(success, privacy: .public)")
            }
            return true
        }

        let legacySel = NSSelectorFromString("openURL:")
        if app.responds(to: legacySel) {
            _ = app.perform(legacySel, with: url)
            return true
        }
        return false
    }

    @discardableResult
    private static func openViaResponderChain(url: URL, from start: UIResponder?) -> Bool {
        var current: UIResponder? = start
        let legacySel = NSSelectorFromString("openURL:")
        while let responder = current {
            if let application = responder as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            if responder.responds(to: legacySel) {
                _ = responder.perform(legacySel, with: url)
                return true
            }
            current = responder.next
        }
        return false
    }
}
