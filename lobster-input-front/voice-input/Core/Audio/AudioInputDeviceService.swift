import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

struct AudioInputDeviceSnapshot: Equatable {
    let devices: [MicrophoneDevice]
    let selectedDeviceUID: String?
    let defaultInputDeviceID: AudioDeviceID?
    let defaultInputDeviceName: String
    let defaultInputChannelCount: Int
    let resolvedPreferredDeviceID: AudioDeviceID?
    let generatedAt: Date
    let generation: UInt64
    let isRefreshing: Bool
    let refreshFailureReason: String?

    static let empty = AudioInputDeviceSnapshot(
        devices: [],
        selectedDeviceUID: nil,
        defaultInputDeviceID: nil,
        defaultInputDeviceName: "系统默认麦克风",
        defaultInputChannelCount: 0,
        resolvedPreferredDeviceID: nil,
        generatedAt: .distantPast,
        generation: 0,
        isRefreshing: false,
        refreshFailureReason: nil
    )

    var selectedDeviceName: String? {
        guard let selectedDeviceUID else { return nil }
        return devices.first { $0.id == selectedDeviceUID }?.name
    }

    func debugSummary(preferredDeviceID: AudioDeviceID?, candidateDeviceIDs: [AudioDeviceID]) -> String {
        let preferredName = preferredDeviceID.flatMap { deviceID in
            devices.first { $0.deviceID == deviceID }?.name
        } ?? "system-default"
        let preferredChannels = preferredDeviceID.flatMap { deviceID in
            devices.first { $0.deviceID == deviceID }?.inputChannelCount
        } ?? defaultInputChannelCount
        let candidateSummary = candidateDeviceIDs
            .map { deviceID in
                let name = devices.first { $0.deviceID == deviceID }?.name ?? "unknown"
                return "\(name)#\(deviceID)"
            }
            .joined(separator: ">")
        let available = devices
            .map { "\($0.name)#\($0.deviceID)\($0.isDefault ? ":default" : "")" }
            .joined(separator: "|")
        let selectionMode = selectedDeviceUID == nil ? "auto" : "explicit"
        return "selectionMode=\(selectionMode), selectedUID=\(selectedDeviceUID ?? "nil"), preferredID=\(preferredDeviceID.map(String.init) ?? "nil"), preferredName=\(preferredName), preferredChannels=\(preferredChannels), candidates=[\(candidateSummary)], defaultID=\(defaultInputDeviceID.map(String.init) ?? "nil"), defaultName=\(defaultInputDeviceName), defaultChannels=\(defaultInputChannelCount), devices=[\(available)], snapshotGen=\(generation), refreshing=\(isRefreshing), failure=\(refreshFailureReason ?? "nil")"
    }

    func candidateInputDeviceIDs() -> [AudioDeviceID] {
        if let selectedDeviceUID {
            return devices.first { $0.id == selectedDeviceUID }.map { [$0.deviceID] } ?? []
        }

        var ordered = [AudioDeviceID]()
        func appendUnique(_ deviceID: AudioDeviceID?) {
            guard let deviceID, !ordered.contains(deviceID) else { return }
            ordered.append(deviceID)
        }

        let externalDevices = devices.filter { !Self.isBuiltInDevice($0) }
        let builtInDevices = devices.filter { Self.isBuiltInDevice($0) }

        appendUnique(externalDevices.first { $0.isDefault }?.deviceID)
        externalDevices.forEach { appendUnique($0.deviceID) }
        appendUnique(builtInDevices.first { $0.isDefault }?.deviceID)
        builtInDevices.forEach { appendUnique($0.deviceID) }

        if ordered.isEmpty {
            appendUnique(defaultInputDeviceID)
        }
        return ordered
    }

    private static func isBuiltInDevice(_ device: MicrophoneDevice) -> Bool {
        device.id == "BuiltInMicrophoneDevice"
            || device.name.localizedCaseInsensitiveContains("MacBook")
            || device.name.localizedCaseInsensitiveContains("Built-in")
            || device.name.localizedCaseInsensitiveContains("内建")
            || device.name.localizedCaseInsensitiveContains("内置")
    }
}

struct AudioInputDeviceResolution {
    let preferredDeviceID: AudioDeviceID?
    let candidateDeviceIDs: [AudioDeviceID]
    let usesAutomaticDeviceSelection: Bool
    let explicitDefaultDeviceID: AudioDeviceID?
    let debugSummary: String
    let snapshot: AudioInputDeviceSnapshot
}

private enum AudioDeviceRefreshPhase {
    case idle
    case refreshing(generation: UInt64, startedAt: Date)
    case failed(generation: UInt64, failedAt: Date, reason: String)
}

final class AudioInputDeviceService {
    static let shared = AudioInputDeviceService()

    var onSnapshotChanged: (@MainActor (AudioInputDeviceSnapshot) -> Void)?

    private let stateLock = NSLock()
    private let listenerQueue = DispatchQueue(label: "ssh2026.voice-input.audio-device-listener", qos: .utility)
    private let timeoutQueue = DispatchQueue(label: "ssh2026.voice-input.audio-device-timeout", qos: .utility)
    private let selectedDeviceKey = "selected_microphone_device_uid"
    private let staleInterval: TimeInterval = 10
    private let refreshTimeout: TimeInterval = 3

    private var snapshot = AudioInputDeviceSnapshot.empty
    private var lastGoodSnapshot: AudioInputDeviceSnapshot?
    private var selectedDeviceUID: String?
    private var phase: AudioDeviceRefreshPhase = .idle
    private var nextGeneration: UInt64 = 0
    private var listenersInstalled = false

    private init() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: selectedDeviceKey)
        snapshot = AudioInputDeviceSnapshot(
            devices: [],
            selectedDeviceUID: selectedDeviceUID,
            defaultInputDeviceID: nil,
            defaultInputDeviceName: "系统默认麦克风",
            defaultInputChannelCount: 0,
            resolvedPreferredDeviceID: nil,
            generatedAt: .distantPast,
            generation: 0,
            isRefreshing: false,
            refreshFailureReason: nil
        )
        installSystemListenersIfNeeded()
        requestRefresh(reason: "initial")
    }

    func currentSnapshot(requestRefreshIfStale reason: String? = nil) -> AudioInputDeviceSnapshot {
        let current = lockedSnapshot()
        if let reason, Date().timeIntervalSince(current.generatedAt) > staleInterval {
            requestRefresh(reason: "\(reason): stale")
        }
        return current
    }

    func currentResolution(requestRefreshIfStale reason: String) -> AudioInputDeviceResolution {
        let current = currentSnapshot(requestRefreshIfStale: reason)
        let preferred = current.resolvedPreferredDeviceID
        let candidates = current.candidateInputDeviceIDs()
        return AudioInputDeviceResolution(
            preferredDeviceID: preferred,
            candidateDeviceIDs: candidates,
            usesAutomaticDeviceSelection: current.selectedDeviceUID == nil,
            explicitDefaultDeviceID: current.defaultInputDeviceID,
            debugSummary: current.debugSummary(preferredDeviceID: preferred, candidateDeviceIDs: candidates),
            snapshot: current
        )
    }

    func updateSelectedDeviceUID(_ uid: String?, reason: String) {
        stateLock.lock()
        selectedDeviceUID = uid
        snapshot = snapshotWithRuntimeState(snapshot, selectedUID: uid, isRefreshing: isRefreshingLocked(), failure: failureReasonLocked())
        stateLock.unlock()
        notify(snapshot)
        requestRefresh(reason: reason)
    }

    func requestRefresh(reason: String) {
        let generation: UInt64
        stateLock.lock()
        if case .refreshing = phase {
            stateLock.unlock()
            DebugTrace.log("AudioInputDeviceService.refresh: coalesced reason=\(reason)")
            return
        }
        nextGeneration &+= 1
        generation = nextGeneration
        phase = .refreshing(generation: generation, startedAt: Date())
        snapshot = snapshotWithRuntimeState(snapshot, selectedUID: selectedDeviceUID, isRefreshing: true, failure: nil)
        let selectedUID = selectedDeviceUID
        stateLock.unlock()

        notify(snapshot)
        DebugTrace.log("AudioInputDeviceService.refresh: begin gen=\(generation), reason=\(reason)")
        scheduleRefreshTimeout(generation: generation)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let startedAt = Date()
            let result = Self.loadSnapshot(selectedUID: selectedUID, generation: generation)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            self?.completeRefresh(result, generation: generation, elapsedMs: elapsedMs)
        }
    }

    private func completeRefresh(_ result: AudioInputDeviceSnapshot, generation: UInt64, elapsedMs: Int) {
        var shouldNotify = false
        var applied = result
        stateLock.lock()
        let isBlockedByNewerRefresh: Bool
        switch phase {
        case .refreshing(let activeGeneration, _) where activeGeneration > generation:
            isBlockedByNewerRefresh = true
        case .failed(let failedGeneration, _, _) where failedGeneration > generation:
            isBlockedByNewerRefresh = true
        default:
            isBlockedByNewerRefresh = false
        }
        if !isBlockedByNewerRefresh, generation >= snapshot.generation {
            phase = .idle
            applied = snapshotWithRuntimeState(result, selectedUID: selectedDeviceUID, isRefreshing: false, failure: nil)
            snapshot = applied
            lastGoodSnapshot = applied
            shouldNotify = true
        }
        stateLock.unlock()

        if shouldNotify {
            DebugTrace.log("AudioInputDeviceService.refresh: success gen=\(generation), elapsed=\(elapsedMs)ms, defaultID=\(applied.defaultInputDeviceID.map(String.init) ?? "nil"), devices=\(applied.devices.count)")
            notify(applied)
        } else {
            DebugTrace.log("AudioInputDeviceService.refresh: stale result discarded gen=\(generation), elapsed=\(elapsedMs)ms")
        }
    }

    private func scheduleRefreshTimeout(generation: UInt64) {
        timeoutQueue.asyncAfter(deadline: .now() + refreshTimeout) { [weak self] in
            guard let self else { return }
            var shouldNotify = false
            var current = AudioInputDeviceSnapshot.empty
            self.stateLock.lock()
            if case .refreshing(let activeGeneration, let startedAt) = self.phase,
               activeGeneration == generation {
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                let reason = "refresh timeout after \(elapsed)ms"
                self.phase = .failed(generation: generation, failedAt: Date(), reason: reason)
                let base = self.lastGoodSnapshot ?? self.snapshot
                current = self.snapshotWithRuntimeState(base, selectedUID: self.selectedDeviceUID, isRefreshing: false, failure: reason)
                self.snapshot = current
                shouldNotify = true
            }
            self.stateLock.unlock()

            if shouldNotify {
                DebugTrace.log("AudioInputDeviceService.refresh: timeout gen=\(generation)")
                self.notify(current)
            }
        }
    }

    private func lockedSnapshot() -> AudioInputDeviceSnapshot {
        stateLock.lock()
        let current = snapshot
        stateLock.unlock()
        return current
    }

    private func isRefreshingLocked() -> Bool {
        if case .refreshing = phase { return true }
        return false
    }

    private func failureReasonLocked() -> String? {
        if case .failed(_, _, let reason) = phase { return reason }
        return nil
    }

    private func snapshotWithRuntimeState(
        _ base: AudioInputDeviceSnapshot,
        selectedUID: String?,
        isRefreshing: Bool,
        failure: String?
    ) -> AudioInputDeviceSnapshot {
        let resolved = selectedUID.flatMap { uid in
            base.devices.first { $0.id == uid }?.deviceID
        } ?? base.defaultInputDeviceID
        return AudioInputDeviceSnapshot(
            devices: base.devices,
            selectedDeviceUID: selectedUID,
            defaultInputDeviceID: base.defaultInputDeviceID,
            defaultInputDeviceName: base.defaultInputDeviceName,
            defaultInputChannelCount: base.defaultInputChannelCount,
            resolvedPreferredDeviceID: resolved,
            generatedAt: base.generatedAt,
            generation: base.generation,
            isRefreshing: isRefreshing,
            refreshFailureReason: failure
        )
    }

    private func notify(_ snapshot: AudioInputDeviceSnapshot) {
        guard let onSnapshotChanged else { return }
        Task { @MainActor in
            onSnapshotChanged(snapshot)
        }
    }

    private func installSystemListenersIfNeeded() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        addSystemListener(selector: kAudioHardwarePropertyDevices)
        addSystemListener(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func addSystemListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue
        ) { [weak self] _, _ in
            self?.requestRefresh(reason: "coreaudio property changed selector=\(selector)")
        }
        if status != noErr {
            DebugTrace.log("AudioInputDeviceService.listener: install failed selector=\(selector), status=\(status)")
        }
    }

    private static func loadSnapshot(selectedUID: String?, generation: UInt64) -> AudioInputDeviceSnapshot {
        let defaultID = defaultInputDeviceID()
        let devices = allAudioDeviceIDs().compactMap { id -> MicrophoneDevice? in
            let transport = transportType(deviceID: id)
            let channels = inputChannelCount(deviceID: id)
            guard channels > 0,
                  let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName),
                  isUserSelectableDevice(uid: uid, name: name, transportType: transport) else {
                return nil
            }
            return MicrophoneDevice(
                id: uid,
                name: name,
                deviceID: id,
                inputChannelCount: channels,
                isDefault: id == defaultID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        let defaultName = defaultID.flatMap { id in
            devices.first { $0.deviceID == id }?.name
                ?? stringProperty(deviceID: id, selector: kAudioObjectPropertyName)
        } ?? "系统默认麦克风"
        let defaultChannels = defaultID.flatMap { id in
            devices.first { $0.deviceID == id }?.inputChannelCount ?? inputChannelCount(deviceID: id)
        } ?? 0
        let resolved = selectedUID.flatMap { uid in
            devices.first { $0.id == uid }?.deviceID
        } ?? defaultID
        return AudioInputDeviceSnapshot(
            devices: devices,
            selectedDeviceUID: selectedUID,
            defaultInputDeviceID: defaultID,
            defaultInputDeviceName: defaultName,
            defaultInputChannelCount: defaultChannels,
            resolvedPreferredDeviceID: resolved,
            generatedAt: Date(),
            generation: generation,
            isRefreshing: false,
            refreshFailureReason: nil
        )
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }
        return deviceIDs
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        return status == noErr ? deviceID : nil
    }

    private static func inputChannelCount(deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return 0
        }
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawList) == noErr else {
            return 0
        }
        let bufferList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private static func transportType(deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        return status == noErr ? (value as String) : nil
    }

    private static func isUserSelectableDevice(uid: String, name: String, transportType: UInt32?) -> Bool {
        if transportType == fourCC("virt") || transportType == fourCC("grup") {
            return false
        }
        let hiddenTokens = ["CADefaultDeviceAggregate", "Aggregate", "Virtual", "Loopback"]
        return !hiddenTokens.contains { uid.localizedCaseInsensitiveContains($0) || name.localizedCaseInsensitiveContains($0) }
    }

    private static func fourCC(_ value: String) -> UInt32 {
        value.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
    }
}
