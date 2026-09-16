import Foundation
import Combine
import AppKit
import Carbon
import CoreGraphics
import os.log

private let hotkeyLog = Logger(subsystem: "ssh2026.voice-input", category: "HotKey")
private let kHotKeyDefaultsVersion = 5
private let hotKeyEventSignature: OSType = 0x4C425348 // "LBSH"

/// 快速单击 Fn 后,系统 HID 栈上游会合成 keyCode 179 的 keyDown/keyUp 注入事件流,
/// 它才是「表情面板/切换输入法/听写」的实际触发物;吞掉它即可拦截系统 Globe 行为,
/// 而吞 Fn(63) 本身的 flagsChanged 已被真机隔离实验证明无效(179 照样合成、系统行为照样触发)。
private let kFnSyntheticGlobeKeyCode = 179
/// 179 吞取关联窗口:只吞紧跟物理 Fn 松开之后(实测约 1ms 内到达)的 179,来路不明的一律放行
private let kFnGlobeSwallowWindow: CFTimeInterval = 0.5

nonisolated private func relevantModifierFlags() -> NSEvent.ModifierFlags {
    [.shift, .control, .option, .command]
}

nonisolated private func isFnKeyCode(_ keyCode: Int) -> Bool {
    keyCode == 63
}

nonisolated private func isModifierKeyCode(_ keyCode: Int) -> Bool {
    switch keyCode {
    case 54, 55, 56, 58, 59, 60, 61, 62:
        return true
    default:
        return false
    }
}

nonisolated private func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
    var result = NSEvent.ModifierFlags()
    if flags.contains(.maskControl) { result.insert(.control) }
    if flags.contains(.maskAlternate) { result.insert(.option) }
    if flags.contains(.maskShift) { result.insert(.shift) }
    if flags.contains(.maskCommand) { result.insert(.command) }
    return result
}

nonisolated private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var result: UInt32 = 0
    if flags.contains(.command) { result |= UInt32(cmdKey) }
    if flags.contains(.option) { result |= UInt32(optionKey) }
    if flags.contains(.control) { result |= UInt32(controlKey) }
    if flags.contains(.shift) { result |= UInt32(shiftKey) }
    return result
}

nonisolated private func isCarbonSupported(_ config: HotKeyConfig) -> Bool {
    config.keyCode >= 0 && !config.requiresFn
}

struct HotKeyConfig: Codable, Equatable {
    var modifiers: Int
    var keyCode: Int
    var requiresFn: Bool

    // 语音类默认快捷键 v5:
    // 转写=Fn 单键，改写=Fn+⇧，
    // 智能体=Fn+Space(Ask Anything)。截屏保持 ⌥A 走 Carbon 通道。
    static let defaultTranscribe = HotKeyConfig(
        modifiers: 0, keyCode: -1, requiresFn: true)
    static let defaultRewrite = HotKeyConfig(
        modifiers: Int(NSEvent.ModifierFlags.shift.rawValue), keyCode: -1, requiresFn: true)
    static let defaultAgent = HotKeyConfig(
        modifiers: 0, keyCode: Int(kVK_Space), requiresFn: true)
    static let defaultScreenshot = HotKeyConfig(
        modifiers: Int(NSEvent.ModifierFlags.option.rawValue), keyCode: Int(kVK_ANSI_A), requiresFn: false)

    var displayString: String {
        var parts: [String] = []
        if requiresFn { parts.append("Fn") }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        if keyCode >= 0 { parts.append(HotKeyConfig.keyCodeName(keyCode)) }
        return parts.joined(separator: "+")
    }

    static func keyCodeName(_ code: Int) -> String {
        let map: [Int: String] = [
            Int(kVK_ANSI_A): "A", Int(kVK_ANSI_B): "B", Int(kVK_ANSI_C): "C",
            Int(kVK_ANSI_D): "D", Int(kVK_ANSI_E): "E", Int(kVK_ANSI_F): "F",
            Int(kVK_ANSI_G): "G", Int(kVK_ANSI_H): "H", Int(kVK_ANSI_I): "I",
            Int(kVK_ANSI_J): "J", Int(kVK_ANSI_K): "K", Int(kVK_ANSI_L): "L",
            Int(kVK_ANSI_M): "M", Int(kVK_ANSI_N): "N", Int(kVK_ANSI_O): "O",
            Int(kVK_ANSI_P): "P", Int(kVK_ANSI_Q): "Q", Int(kVK_ANSI_R): "R",
            Int(kVK_ANSI_S): "S", Int(kVK_ANSI_T): "T", Int(kVK_ANSI_U): "U",
            Int(kVK_ANSI_V): "V", Int(kVK_ANSI_W): "W", Int(kVK_ANSI_X): "X",
            Int(kVK_ANSI_Y): "Y", Int(kVK_ANSI_Z): "Z",
            Int(kVK_ANSI_0): "0", Int(kVK_ANSI_1): "1", Int(kVK_ANSI_2): "2",
            Int(kVK_ANSI_3): "3", Int(kVK_ANSI_4): "4", Int(kVK_ANSI_5): "5",
            Int(kVK_ANSI_6): "6", Int(kVK_ANSI_7): "7", Int(kVK_ANSI_8): "8",
            Int(kVK_ANSI_9): "9",
            Int(kVK_Space): "Space", Int(kVK_Return): "Return", Int(kVK_Tab): "Tab",
            Int(kVK_Escape): "Esc", Int(kVK_Delete): "Delete"
        ]
        return map[code] ?? "Key(\(code))"
    }
}

typealias HotKeyHandler = (HotKeyCombo) -> Void

enum HotKeyCombo: String, CaseIterable {
    case transcribe = "transcribe"
    case rewrite = "rewrite"
    case agent = "agent"
    case screenshot = "screenshot"
}

private extension HotKeyCombo {
    var carbonID: UInt32 {
        UInt32((HotKeyCombo.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    static func fromCarbonID(_ id: UInt32) -> HotKeyCombo? {
        guard id > 0 else { return nil }
        let index = Int(id - 1)
        guard allCases.indices.contains(index) else { return nil }
        return allCases[index]
    }
}

nonisolated private final class ConfigStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: [HotKeyCombo: HotKeyConfig] = [:]

    nonisolated func update(_ configs: [HotKeyCombo: HotKeyConfig]) {
        lock.lock()
        snapshot = configs
        lock.unlock()
    }

    nonisolated func read() -> [HotKeyCombo: HotKeyConfig] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

/// tap 端口/独立线程 runloop 的线程安全持有器:
/// tap 回调与看门狗跑在专用线程,主线程(startListening/stopListening)也要读写,统一走锁。
nonisolated private final class TapRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    nonisolated func store(port: CFMachPort, runLoop: CFRunLoop) {
        lock.lock()
        self.port = port
        self.runLoop = runLoop
        lock.unlock()
    }

    nonisolated func currentPort() -> CFMachPort? {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    nonisolated func clear() -> (CFMachPort?, CFRunLoop?) {
        lock.lock()
        defer { lock.unlock() }
        let result = (port, runLoop)
        port = nil
        runLoop = nil
        return result
    }

    /// 看门狗/回调共用的自愈入口:tap 存在且被禁用时重新启用。
    /// 实测回调卡顿导致的系统禁用是「静默」的(不派发 tapDisabledByTimeout 事件),必须靠轮询兜底。
    nonisolated func reenableIfDisabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let port, !CGEvent.tapIsEnabled(tap: port) else { return false }
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }
}

private struct HotKeyPressedState {
    var primaryKeyCodes: Set<Int>
    var modifiers: NSEvent.ModifierFlags
    var requiresFn: Bool
    var keylessSequenceHadPrimary: Bool
    var keylessSequenceConsumed: Bool
}

nonisolated private final class HotKeyRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var primaryKeyCodes: Set<Int> = []
    private var modifiers = NSEvent.ModifierFlags()
    private var fnDown = false
    private var fnReleasedAt: CFTimeInterval = 0
    private var activeCombos: Set<HotKeyCombo> = []
    private var swallowedKeyCodes: Set<Int> = []
    private var keylessSequenceHadPrimary = false
    // 一轮修饰键按压序列内已触发过 keyless 组合:
    // 防止 Fn+⇧ 松开 ⇧ 触发改写后,再松开 Fn 又触发 Fn 单键(逐级松开的连环误触发)
    private var keylessSequenceConsumed = false

    nonisolated func reset() {
        lock.lock()
        primaryKeyCodes.removeAll()
        modifiers = []
        fnDown = false
        fnReleasedAt = 0
        activeCombos.removeAll()
        swallowedKeyCodes.removeAll()
        keylessSequenceHadPrimary = false
        keylessSequenceConsumed = false
        lock.unlock()
    }

    nonisolated func markKeylessConsumed() {
        lock.lock()
        keylessSequenceConsumed = true
        lock.unlock()
    }

    /// 179 关联窗口判定:物理 Fn 正按住,或刚在 window 秒内松开
    nonisolated func hasRecentFnActivity(window: CFTimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fnDown || (CFAbsoluteTimeGetCurrent() - fnReleasedAt) < window
    }

    nonisolated func snapshot() -> HotKeyPressedState {
        lock.lock()
        defer { lock.unlock() }
        return HotKeyPressedState(
            primaryKeyCodes: primaryKeyCodes,
            modifiers: modifiers,
            requiresFn: fnDown,
            keylessSequenceHadPrimary: keylessSequenceHadPrimary,
            keylessSequenceConsumed: keylessSequenceConsumed
        )
    }

    nonisolated func hasActiveCombos() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !activeCombos.isEmpty
    }

    nonisolated func updatePressedState(type: CGEventType, keyCode: Int, flags: CGEventFlags) -> HotKeyPressedState {
        lock.lock()
        defer { lock.unlock() }

        let oldKeylessActive = fnDown || !modifiers.isEmpty
        modifiers = modifierFlags(from: flags).intersection(relevantModifierFlags())

        switch type {
        case .keyDown:
            if !isFnKeyCode(keyCode) && !isModifierKeyCode(keyCode) {
                primaryKeyCodes.insert(keyCode)
                if fnDown || !modifiers.isEmpty {
                    keylessSequenceHadPrimary = true
                }
            }
        case .keyUp:
            primaryKeyCodes.remove(keyCode)
        case .flagsChanged:
            if isFnKeyCode(keyCode) || flags.contains(.maskSecondaryFn) || fnDown {
                let isDown = flags.contains(.maskSecondaryFn) || (isFnKeyCode(keyCode) && !fnDown)
                if fnDown && !isDown {
                    fnReleasedAt = CFAbsoluteTimeGetCurrent()
                }
                fnDown = isDown
            }
        default:
            break
        }

        if type == .flagsChanged && !oldKeylessActive && (fnDown || !modifiers.isEmpty) {
            keylessSequenceHadPrimary = false
            keylessSequenceConsumed = false
        }

        return HotKeyPressedState(
            primaryKeyCodes: primaryKeyCodes,
            modifiers: modifiers,
            requiresFn: fnDown || flags.contains(.maskSecondaryFn),
            keylessSequenceHadPrimary: keylessSequenceHadPrimary,
            keylessSequenceConsumed: keylessSequenceConsumed
        )
    }

    nonisolated func replaceActiveCombos(_ combos: Set<HotKeyCombo>) -> Set<HotKeyCombo> {
        lock.lock()
        defer { lock.unlock() }
        let newlyMatched = combos.subtracting(activeCombos)
        activeCombos = combos
        return newlyMatched
    }

    nonisolated func markSwallowedKey(_ keyCode: Int) {
        lock.lock()
        swallowedKeyCodes.insert(keyCode)
        lock.unlock()
    }

    nonisolated func consumeSwallowedKey(_ keyCode: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return swallowedKeyCodes.remove(keyCode) != nil
    }

}

@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()
    private init() { loadConfigs() }

    @Published var configs: [HotKeyCombo: HotKeyConfig] = [:]
    @Published private(set) var isListening = false

    var onHotKeyPressed: HotKeyHandler?

    private var carbonHotKeys: [HotKeyCombo: EventHotKeyRef] = [:]
    private var carbonEventHandler: EventHandlerRef?
    private var retainedCarbonSelf: Unmanaged<HotKeyManager>?
    private var retainedSelf: Unmanaged<HotKeyManager>?

    private let configStore = ConfigStore()
    private let runtimeState = HotKeyRuntimeState()
    private let tapRuntime = TapRuntime()

    private func syncConfigSnapshot() {
        configStore.update(configs)
    }

    private var userDefaultsKey: String {
        let email = AuthStore.shared.email ?? "anonymous"
        let data = Data(email.lowercased().utf8)
        var hash: UInt64 = 14695981039346656037
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "hotkey_configs_%016llx", hash)
    }

    private var customizedKey: String { "hotkey_customized_\(userDefaultsKey)" }
    private var disabledKey: String { "hotkey_disabled_\(userDefaultsKey)" }

    private func loadConfigs() {
        // 版本号必须跟配置一样按用户 profile 分 key:历史上用全局键,
        // 会被先加载的 profile 消费掉,导致其它 profile 永远不迁移。
        let versionKey = "hotkey_defaults_version_\(userDefaultsKey)"
        let savedVersion = UserDefaults.standard.integer(forKey: versionKey)
        let disabledCombos = loadDisabledCombos()

        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let saved = try? JSONDecoder().decode([String: HotKeyConfig].self, from: data) {
            configs = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                HotKeyCombo(rawValue: key).map { ($0, value) }
            })
        } else {
            configs = [:]
        }

        if savedVersion < kHotKeyDefaultsVersion {
            // 历代默认值清单:值仍等于任一历史默认值的组合视为"未真正自定义"
            // (历史代码曾把默认值误标为 customized,用户也可能手动录制出与默认相同的值),
            // 一并参与迁移刷新;值与所有历史默认值都不同的真自定义配置永不触碰。
            let optionFlag = Int(NSEvent.ModifierFlags.option.rawValue)
            let legacyDefaults: [HotKeyCombo: [HotKeyConfig]] = [
                .transcribe: [
                    HotKeyConfig(modifiers: optionFlag, keyCode: Int(kVK_ANSI_Q), requiresFn: false), // v3
                    HotKeyConfig(modifiers: 0, keyCode: -1, requiresFn: true),                        // v4
                ],
                .rewrite: [
                    HotKeyConfig(modifiers: optionFlag, keyCode: Int(kVK_ANSI_E), requiresFn: false), // v3
                    HotKeyConfig(modifiers: 0, keyCode: Int(kVK_ANSI_S), requiresFn: true),           // v4
                ],
                .agent: [
                    HotKeyConfig(modifiers: optionFlag, keyCode: Int(kVK_ANSI_W), requiresFn: false), // v3
                    HotKeyConfig(modifiers: 0, keyCode: Int(kVK_ANSI_W), requiresFn: true),           // v4
                ],
            ]
            let customized = loadCustomizedCombos()
            var migrated: [String] = []
            for combo in HotKeyCombo.allCases {
                let isLegacyDefaultValue = configs[combo].map { config in
                    legacyDefaults[combo]?.contains(config) ?? false
                } ?? false
                if !customized.contains(combo) || isLegacyDefaultValue {
                    configs[combo] = nil
                    if isLegacyDefaultValue { unmarkComboCustomized(combo) }
                    migrated.append(combo.rawValue)
                }
            }
            UserDefaults.standard.set(kHotKeyDefaultsVersion, forKey: versionKey)
            DebugTrace.log("HotKey CONFIG: defaults migrated v\(savedVersion) -> v\(kHotKeyDefaultsVersion), refreshed=\(migrated.joined(separator: ","))")
        }

        if configs[.transcribe] == nil && !disabledCombos.contains(.transcribe) { configs[.transcribe] = .defaultTranscribe }
        if configs[.rewrite] == nil && !disabledCombos.contains(.rewrite) { configs[.rewrite] = .defaultRewrite }
        if configs[.agent] == nil && !disabledCombos.contains(.agent) { configs[.agent] = .defaultAgent }
        if configs[.screenshot] == nil && !disabledCombos.contains(.screenshot) { configs[.screenshot] = .defaultScreenshot }
        syncConfigSnapshot()
        let summary = HotKeyCombo.allCases
            .map { "\($0.rawValue)=\(configs[$0]?.displayString ?? "off")" }
            .joined(separator: " ")
        DebugTrace.log("HotKey CONFIG: loaded \(summary)")
    }

    func saveConfigs() {
        let dict = Dictionary(uniqueKeysWithValues: configs.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
        syncConfigSnapshot()
    }

    func markComboCustomized(_ combo: HotKeyCombo) {
        var set = loadCustomizedCombos()
        set.insert(combo)
        UserDefaults.standard.set(set.map { $0.rawValue }, forKey: customizedKey)
    }

    private func unmarkComboCustomized(_ combo: HotKeyCombo) {
        var set = loadCustomizedCombos()
        set.remove(combo)
        UserDefaults.standard.set(set.map { $0.rawValue }, forKey: customizedKey)
    }

    func markComboDisabled(_ combo: HotKeyCombo) {
        var set = loadDisabledCombos()
        set.insert(combo)
        UserDefaults.standard.set(set.map { $0.rawValue }, forKey: disabledKey)
    }

    func markComboEnabled(_ combo: HotKeyCombo) {
        var set = loadDisabledCombos()
        set.remove(combo)
        UserDefaults.standard.set(set.map { $0.rawValue }, forKey: disabledKey)
    }

    private func loadCustomizedCombos() -> Set<HotKeyCombo> {
        let arr = UserDefaults.standard.stringArray(forKey: customizedKey) ?? []
        return Set(arr.compactMap { HotKeyCombo(rawValue: $0) })
    }

    private func loadDisabledCombos() -> Set<HotKeyCombo> {
        let arr = UserDefaults.standard.stringArray(forKey: disabledKey) ?? []
        return Set(arr.compactMap { HotKeyCombo(rawValue: $0) })
    }

    func reloadForCurrentUser() {
        let shouldRestart = isListening
        let handler = onHotKeyPressed
        let oldConfigs = configs
        loadConfigs()
        if shouldRestart, let handler, oldConfigs != configs {
            startListening(handler: handler)
        }
    }

    func startListening(handler: @escaping HotKeyHandler) {
        stopListening()
        onHotKeyPressed = handler
        syncConfigSnapshot()

        let carbonCount = installCarbonHotKeys()
        let needsFallbackTap = configs.values.contains { !isCarbonSupported($0) }
        var fallbackInstalled = false

        if needsFallbackTap {
            if !AXIsProcessTrusted() {
                hotkeyLog.warning("Accessibility not trusted; fallback event tap may fail")
                DebugTrace.log("HotKey: AX not trusted for fallback event tap")
            }
            fallbackInstalled = installCGEventTap()
            if !fallbackInstalled {
                hotkeyLog.error("fallback CGEventTap installation failed")
                DebugTrace.log("HotKey: fallback event tap install failed")
            }
        }

        guard carbonCount > 0 || fallbackInstalled else {
            uninstallCarbonHotKeys()
            isListening = false
            hotkeyLog.error("no hotkeys installed")
            DebugTrace.log("HotKey: no hotkeys installed")
            return
        }

        isListening = true
        hotkeyLog.info("hotkeys installed: carbon=\(carbonCount), fallbackTap=\(fallbackInstalled)")
        DebugTrace.log("HotKey: installed carbon=\(carbonCount), fallbackTap=\(fallbackInstalled)")
    }

    func stopListening() {
        uninstallCarbonHotKeys()
        let (port, runLoop) = tapRuntime.clear()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        if port != nil {
            DebugTrace.log("HotKey TAP: stopped and invalidated")
        }
        retainedSelf?.release()
        retainedSelf = nil
        runtimeState.reset()
        isListening = false
    }

    private func installCarbonHotKeys() -> Int {
        let carbonConfigs = configs.filter { isCarbonSupported($0.value) }
        guard !carbonConfigs.isEmpty else { return 0 }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let retained = Unmanaged.passRetained(self)
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == hotKeyEventSignature,
                      let combo = HotKeyCombo.fromCarbonID(hotKeyID.id) else {
                    return status
                }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { [weak manager] in
                    DebugTrace.log("HotKey CARBON: combo=\(combo.rawValue)")
                    manager?.onHotKeyPressed?(combo)
                }
                return noErr
            },
            1,
            &eventSpec,
            retained.toOpaque(),
            &carbonEventHandler
        )

        guard handlerStatus == noErr else {
            retained.release()
            hotkeyLog.error("Carbon event handler install failed: \(handlerStatus)")
            DebugTrace.log("HotKey: carbon event handler install failed status=\(handlerStatus)")
            return 0
        }

        retainedCarbonSelf = retained

        var installed = 0
        for combo in HotKeyCombo.allCases {
            guard let config = carbonConfigs[combo] else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(config.modifiers)).intersection(relevantModifierFlags())
            let hotKeyID = EventHotKeyID(signature: hotKeyEventSignature, id: combo.carbonID)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(config.keyCode),
                carbonModifiers(from: flags),
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &ref
            )

            if status == noErr, let ref {
                carbonHotKeys[combo] = ref
                installed += 1
            } else {
                hotkeyLog.error("Carbon hotkey register failed combo=\(combo.rawValue), status=\(status)")
                DebugTrace.log("HotKey: carbon register failed combo=\(combo.rawValue), status=\(status)")
            }
        }

        if installed == 0 {
            uninstallCarbonHotKeys()
        }

        return installed
    }

    private func uninstallCarbonHotKeys() {
        for ref in carbonHotKeys.values {
            UnregisterEventHotKey(ref)
        }
        carbonHotKeys.removeAll()

        if let handler = carbonEventHandler {
            RemoveEventHandler(handler)
        }
        carbonEventHandler = nil

        retainedCarbonSelf?.release()
        retainedCarbonSelf = nil
    }

    /// tap 跑在专用线程 + 自建 CFRunLoop:
    /// 主线程被 SwiftUI/AX 卡住时快捷键仍瞬时响应,也避免回调阻塞主线程反向拖累系统事件链。
    /// 线程内挂 2s 看门狗轮询 tapIsEnabled,兜底「系统静默禁用 tap 且不派发禁用事件」的场景。
    @discardableResult
    private func installCGEventTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let retained = Unmanaged.passRetained(self)
        let runtime = tapRuntime
        let ready = DispatchSemaphore(value: 0)
        var created = false

        let thread = Thread {
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                    return manager.handleCGEventSync(type: type, event: event)
                },
                userInfo: retained.toOpaque()
            ) else {
                ready.signal()
                return
            }

            let runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            runtime.store(port: port, runLoop: runLoop!)

            let watchdog = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 2.0, 2.0, 0, 0
            ) { _ in
                if runtime.reenableIfDisabled() {
                    hotkeyLog.warning("watchdog: tap was silently disabled, re-enabled")
                    DebugTrace.log("HotKey WATCHDOG: tap was silently disabled, re-enabled")
                }
            }
            CFRunLoopAddTimer(runLoop, watchdog, .commonModes)

            created = true
            ready.signal()
            DebugTrace.log("HotKey TAP: dedicated thread started, tap installed")
            CFRunLoopRun()
            DebugTrace.log("HotKey TAP: dedicated thread exited")
        }
        thread.name = "hotkey.tap"
        thread.qualityOfService = .userInteractive
        thread.start()

        let waitResult = ready.wait(timeout: .now() + 3)
        guard waitResult == .success, created else {
            retained.release()
            hotkeyLog.error("tap thread setup failed (timeout=\(waitResult == .timedOut))")
            DebugTrace.log("HotKey TAP: setup failed timeout=\(waitResult == .timedOut)")
            return false
        }

        retainedSelf = retained
        return true
    }

    private nonisolated func handleCGEventSync(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "userInput"
            hotkeyLog.warning("tap disabled by \(reason), re-enabling in place")
            DebugTrace.log("HotKey TAP-DISABLED: reason=\(reason), re-enabling in place")
            if let port = tapRuntime.currentPort() {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return passthrough
        }

        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return passthrough
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // 系统合成的 Globe 触发事件(179):在进状态机之前拦截,既防止它污染按键序列
        // (快速连击 Fn 时 179 会落在下一次按压窗口内),也按门禁决定吞/放。
        // 门禁(缺一不吞,防无脑吞键):
        //   ① tap 在监听中(App 存活、快捷键功能开启——tap 本身只在监听期存在)
        //   ② 当前配置里存在启用的「Fn 单键」快捷键(只配 Fn+组合时,单击 Fn 不属于本 App,放行保留系统行为)
        //   ③ 179 紧跟我们观测到的物理 Fn 按压(500ms 关联窗口),来路不明的 179 一律放行
        if keyCode == kFnSyntheticGlobeKeyCode && (type == .keyDown || type == .keyUp) {
            let hasFnOnlyConfig = configStore.read().values.contains { $0.requiresFn && $0.keyCode < 0 }
            let recentFn = runtimeState.hasRecentFnActivity(window: kFnGlobeSwallowWindow)
            let swallow = hasFnOnlyConfig && recentFn
            DebugTrace.log("HotKey FN-GLOBE(179): type=\(type == .keyDown ? "down" : "up"), fnOnlyConfig=\(hasFnOnlyConfig), recentFn=\(recentFn) -> \(swallow ? "swallow" : "pass")")
            return swallow ? nil : passthrough
        }

        if type == .flagsChanged && isFnKeyCode(keyCode) {
            let down = event.flags.contains(.maskSecondaryFn)
            DebugTrace.log("HotKey FN(63): \(down ? "down" : "up"), flags=0x\(String(event.flags.rawValue, radix: 16))")
        }

        let previousState = runtimeState.snapshot()
        let wasActive = runtimeState.hasActiveCombos()
        let state = runtimeState.updatePressedState(type: type, keyCode: keyCode, flags: event.flags)
        let matches = matchingCombos(for: state, includeKeylessCombos: false)
        let releaseMatches = releasedKeylessCombos(previousState: previousState, currentState: state, type: type)
        let newlyMatched = runtimeState.replaceActiveCombos(matches)
        let combosToTrigger = newlyMatched.union(releaseMatches)

        if type == .keyDown && !matches.isEmpty {
            runtimeState.markSwallowedKey(keyCode)
        }

        if !releaseMatches.isEmpty {
            runtimeState.markKeylessConsumed()
        }

        for combo in combosToTrigger {
            DebugTrace.log("HotKey INTERCEPT: combo=\(combo.rawValue), keyCode=\(keyCode), type=\(type.rawValue)")
            DispatchQueue.main.async { [weak self] in
                self?.onHotKeyPressed?(combo)
            }
        }

        let swallow = shouldSwallow(type: type, keyCode: keyCode, state: state, matches: matches, releaseMatches: releaseMatches, wasActive: wasActive)
        if swallow || !combosToTrigger.isEmpty {
            DebugTrace.log("HotKey DECISION: keyCode=\(keyCode), type=\(type.rawValue), swallow=\(swallow), triggered=\(combosToTrigger.map(\.rawValue).joined(separator: ","))")
        }
        return swallow ? nil : passthrough
    }

    private nonisolated func matchingCombos(for state: HotKeyPressedState, includeKeylessCombos: Bool) -> Set<HotKeyCombo> {
        var result: Set<HotKeyCombo> = []
        let snapshot = configStore.read()

        for (combo, config) in snapshot {
            guard !isCarbonSupported(config) else { continue }
            let configModifiers = NSEvent.ModifierFlags(rawValue: UInt(config.modifiers)).intersection(relevantModifierFlags())
            guard config.requiresFn == state.requiresFn else { continue }
            guard configModifiers == state.modifiers.intersection(relevantModifierFlags()) else { continue }

            if config.keyCode >= 0 {
                if state.primaryKeyCodes == [config.keyCode] {
                    result.insert(combo)
                }
            } else if includeKeylessCombos && state.primaryKeyCodes.isEmpty && (config.requiresFn || !configModifiers.isEmpty) {
                result.insert(combo)
            }
        }

        return result
    }

    private nonisolated func releasedKeylessCombos(
        previousState: HotKeyPressedState,
        currentState: HotKeyPressedState,
        type: CGEventType
    ) -> Set<HotKeyCombo> {
        guard type == .flagsChanged else { return [] }
        guard stateWeight(currentState) < stateWeight(previousState) else { return [] }
        guard !previousState.keylessSequenceHadPrimary else { return [] }
        guard !previousState.keylessSequenceConsumed else { return [] }
        return matchingCombos(for: previousState, includeKeylessCombos: true)
    }

    private nonisolated func shouldSwallow(
        type: CGEventType,
        keyCode: Int,
        state: HotKeyPressedState,
        matches: Set<HotKeyCombo>,
        releaseMatches: Set<HotKeyCombo>,
        wasActive: Bool
    ) -> Bool {
        // Fn(63) 的 flagsChanged 永远放行:真机实验证明吞它拦不住系统 Globe 行为(179 才是关键),
        // 吞它反而会破坏其它 App 对 fn 修饰位的感知,还有 fn 状态错乱导致的锁键风险。
        if type == .flagsChanged && isFnKeyCode(keyCode) {
            return false
        }

        if !matches.isEmpty { return true }
        if !releaseMatches.isEmpty { return true }

        if type == .keyUp && runtimeState.consumeSwallowedKey(keyCode) {
            return true
        }

        if type == .flagsChanged && wasActive {
            return true
        }

        return false
    }

    private nonisolated func stateWeight(_ state: HotKeyPressedState) -> Int {
        var result = state.primaryKeyCodes.count
        if state.requiresFn { result += 1 }
        if state.modifiers.contains(.control) { result += 1 }
        if state.modifiers.contains(.option) { result += 1 }
        if state.modifiers.contains(.shift) { result += 1 }
        if state.modifiers.contains(.command) { result += 1 }
        return result
    }

}
