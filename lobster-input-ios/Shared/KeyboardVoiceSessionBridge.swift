import Foundation

enum KeyboardVoiceSessionAction: String, Codable {
    case start
    case stop
    case cancel
}

struct KeyboardVoiceSessionCommand: Codable, Equatable {
    let id: String
    let requestID: String
    let action: KeyboardVoiceSessionAction
    let createdAt: TimeInterval
}

struct KeyboardVoiceSessionSnapshot: Equatable {
    let enabled: Bool
    let active: Bool
    let heartbeatAt: TimeInterval
    let recording: Bool
    let recordingStartedAt: TimeInterval?
    let audioLevel: Float
    let liveText: String
    let transcriptLanguage: String?

    /// 主 App 进程是否在保活窗口内（依赖心跳，避免 App 被杀后 active 残留）
    var isAlive: Bool {
        guard enabled, active else { return false }
        guard heartbeatAt > 0 else { return false }
        return Date().timeIntervalSince1970 - heartbeatAt <= Self.heartbeatMaxAgeSec
    }

    /// 可接受键盘录音指令：必须有心跳，不能只看 active 标记
    var isReady: Bool {
        isAlive
    }

    private static let heartbeatMaxAgeSec: TimeInterval = 8
}

final class KeyboardDarwinNotificationObserver {
    private let name: String
    private let callback: () -> Void
    private var isObserving = false

    init(name: String, callback: @escaping () -> Void) {
        self.name = name
        self.callback = callback
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let value = Unmanaged<KeyboardDarwinNotificationObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                value.callback()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
        isObserving = true
    }

    deinit {
        stop()
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }
}

enum KeyboardVoiceSessionBridge {
    enum NotificationName {
        static let commandPosted = "ssh2026.lobster.keyboardVoice.commandPosted"
        static let statusChanged = "ssh2026.lobster.keyboardVoice.statusChanged"
        static let resultReady = "ssh2026.lobster.keyboardVoice.resultReady"
    }

    private enum Key {
        static let enabled = "ios_keyboard_voice_session_enabled"
        static let active = "ios_keyboard_voice_session_active"
        static let heartbeatAt = "ios_keyboard_voice_session_heartbeat_at"
        static let recording = "ios_keyboard_voice_session_recording"
        static let recordingStartedAt = "ios_keyboard_voice_session_recording_started_at"
        static let audioLevel = "ios_keyboard_voice_session_audio_level"
        static let liveText = "ios_keyboard_voice_session_live_text"
        static let transcriptLanguage = "ios_keyboard_voice_session_transcript_language"
        static let command = "ios_keyboard_voice_session_command"
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard
    }

    static var isEnabled: Bool {
        guard defaults.object(forKey: Key.enabled) != nil else { return true }
        return defaults.bool(forKey: Key.enabled)
    }

    static func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.enabled)
        if !enabled {
            markSessionActive(false)
        }
        post(NotificationName.statusChanged)
    }

    /// 主 App 已退出但 App Group 仍残留 active=true 时，由键盘侧清理
    static func invalidateStaleSessionIfNeeded() {
        let snap = snapshot()
        guard snap.enabled, snap.active, !snap.isAlive else { return }
        markSessionActive(false)
    }

    static func snapshot() -> KeyboardVoiceSessionSnapshot {
        KeyboardVoiceSessionSnapshot(
            enabled: isEnabled,
            active: defaults.bool(forKey: Key.active),
            heartbeatAt: defaults.double(forKey: Key.heartbeatAt),
            recording: defaults.bool(forKey: Key.recording),
            recordingStartedAt: defaults.object(forKey: Key.recordingStartedAt) as? TimeInterval,
            audioLevel: Float(defaults.double(forKey: Key.audioLevel)),
            liveText: defaults.string(forKey: Key.liveText) ?? "",
            transcriptLanguage: defaults.string(forKey: Key.transcriptLanguage)
        )
    }

    static func markSessionActive(_ active: Bool) {
        defaults.set(active, forKey: Key.active)
        if active {
            writeHeartbeat()
        } else {
            defaults.set(false, forKey: Key.recording)
            defaults.removeObject(forKey: Key.recordingStartedAt)
            defaults.set(0.0, forKey: Key.audioLevel)
            defaults.removeObject(forKey: Key.liveText)
            defaults.removeObject(forKey: Key.transcriptLanguage)
        }
        post(NotificationName.statusChanged)
    }

    static func writeHeartbeat(_ now: TimeInterval = Date().timeIntervalSince1970) {
        defaults.set(now, forKey: Key.heartbeatAt)
        defaults.synchronize()
    }

    static func updateRecording(_ recording: Bool, startedAt: TimeInterval? = nil) {
        defaults.set(recording, forKey: Key.recording)
        if recording {
            defaults.set(startedAt ?? Date().timeIntervalSince1970, forKey: Key.recordingStartedAt)
        } else {
            defaults.removeObject(forKey: Key.recordingStartedAt)
            defaults.set(0.0, forKey: Key.audioLevel)
        }
        post(NotificationName.statusChanged)
    }

    static func updateLiveText(_ text: String, language: String? = nil) {
        defaults.set(text, forKey: Key.liveText)
        if let language, !language.isEmpty {
            defaults.set(language, forKey: Key.transcriptLanguage)
        }
        defaults.synchronize()
        if defaults.bool(forKey: Key.recording) {
            post(NotificationName.statusChanged)
        }
    }

    static func writeAudioLevel(_ level: Float) {
        defaults.set(Double(max(0, min(1, level))), forKey: Key.audioLevel)
        if defaults.bool(forKey: Key.recording) {
            post(NotificationName.statusChanged)
        }
    }

    @discardableResult
    static func postCommand(action: KeyboardVoiceSessionAction, requestID: String) -> KeyboardVoiceSessionCommand {
        let command = KeyboardVoiceSessionCommand(
            id: UUID().uuidString,
            requestID: requestID,
            action: action,
            createdAt: Date().timeIntervalSince1970
        )
        save(command, key: Key.command)
        defaults.synchronize()
        post(NotificationName.commandPosted)
        return command
    }

    static func latestCommand(maxAge: TimeInterval = 30) -> KeyboardVoiceSessionCommand? {
        guard let command: KeyboardVoiceSessionCommand = load(Key.command) else { return nil }
        guard Date().timeIntervalSince1970 - command.createdAt <= maxAge else { return nil }
        return command
    }

    static func postResultReady() {
        post(NotificationName.resultReady)
    }

    static func observe(_ name: String, callback: @escaping () -> Void) -> KeyboardDarwinNotificationObserver {
        KeyboardDarwinNotificationObserver(name: name, callback: callback)
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
