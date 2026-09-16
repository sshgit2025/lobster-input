import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import Combine

enum RealtimeStreamingState: Equatable {
    case idle
    case starting
    case streaming
    case processing
}

private enum EngineStartVerificationResult {
    case verified
    case postStartConfigurationChanged(tapActive: Bool)
    case noAudio(tapActive: Bool)
    case notRunning
}

private final class RealtimeAudioEngineWorker {
    private let queue = DispatchQueue(label: "ssh2026.voice-input.realtime-audio", qos: .userInitiated)
    private let chunkLock = NSLock()
    private let targetChunkBytes = 3_200
    private var engine: AVAudioEngine?
    private var pendingPCM = Data()
    private var chunkHandler: (@Sendable (Data) -> Void)?
    private var verifyingAudio = false
    private let targetSampleRate = 16_000.0
    private let maxStartAttempts = 3
    private var resampleCursor = 0.0
    private var conversionDropCount = 0
    private let activityLock = NSLock()
    private var tapActivitySequence: UInt64 = 0
    private var chunkActivitySequence: UInt64 = 0
    private var engineReady = false
    private var currentPreferredDeviceID: AudioDeviceID?
    private var currentInputSampleRate: Double = 0
    private var levelHandler: (@Sendable (Float) -> Void)?

    func prewarm(
        preferredDeviceID: AudioDeviceID?,
        candidateDeviceIDs: [AudioDeviceID],
        usesAutomaticDeviceSelection: Bool,
        inputDeviceDebugSummary: String,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        queue.async {
            self.levelHandler = onLevel
            DebugTrace.log("RealtimeAudioEngineWorker.prewarm: enqueue, \(inputDeviceDebugSummary)")
            _ = self.prepareEngineSync(
                preferredDeviceID: preferredDeviceID,
                candidateDeviceIDs: candidateDeviceIDs,
                usesAutomaticDeviceSelection: usesAutomaticDeviceSelection,
                inputDeviceDebugSummary: inputDeviceDebugSummary,
                onLevel: onLevel
            )
        }
    }

    func rebuildForDeviceChange(
        preferredDeviceID: AudioDeviceID?,
        candidateDeviceIDs: [AudioDeviceID],
        usesAutomaticDeviceSelection: Bool,
        inputDeviceDebugSummary: String,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                DebugTrace.log("RealtimeAudioEngineWorker.rebuildForDeviceChange: \(inputDeviceDebugSummary)")
                self.stopEngineSync(flushTail: false)
                self.levelHandler = onLevel
                let ok = self.prepareEngineSync(
                    preferredDeviceID: preferredDeviceID,
                    candidateDeviceIDs: candidateDeviceIDs,
                    usesAutomaticDeviceSelection: usesAutomaticDeviceSelection,
                    inputDeviceDebugSummary: inputDeviceDebugSummary,
                    onLevel: onLevel
                )
                continuation.resume(returning: ok)
            }
        }
    }

    func start(
        preferredDeviceID: AudioDeviceID?,
        candidateDeviceIDs: [AudioDeviceID],
        usesAutomaticDeviceSelection: Bool,
        inputDeviceDebugSummary: String,
        onChunk: @escaping @Sendable (Data) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.startSync(
                    preferredDeviceID: preferredDeviceID,
                    candidateDeviceIDs: candidateDeviceIDs,
                    usesAutomaticDeviceSelection: usesAutomaticDeviceSelection,
                    inputDeviceDebugSummary: inputDeviceDebugSummary,
                    onChunk: onChunk,
                    onLevel: onLevel
                ))
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopCaptureSync(flushTail: true)
                continuation.resume()
            }
        }
    }

    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopEngineSync(flushTail: false)
                continuation.resume()
            }
        }
    }

    private func startSync(
        preferredDeviceID: AudioDeviceID?,
        candidateDeviceIDs: [AudioDeviceID],
        usesAutomaticDeviceSelection: Bool,
        inputDeviceDebugSummary: String,
        onChunk: @escaping @Sendable (Data) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> Bool {
        DebugTrace.log("RealtimeAudioEngineWorker.start: begin capture, \(inputDeviceDebugSummary)")
        levelHandler = onLevel
        guard prepareEngineSync(
            preferredDeviceID: preferredDeviceID,
            candidateDeviceIDs: candidateDeviceIDs,
            usesAutomaticDeviceSelection: usesAutomaticDeviceSelection,
            inputDeviceDebugSummary: inputDeviceDebugSummary,
            onLevel: onLevel
        ) else {
            DebugTrace.log("RealtimeAudioEngineWorker.start: prepare failed")
            return false
        }

        resetChunking(onChunk: onChunk)
        let chunkBaseline = currentChunkActivitySequence()
        if waitForChunkActivitySync(after: chunkBaseline, timeout: 0.65) {
            DebugTrace.log("RealtimeAudioEngineWorker.start: capture ready from warm engine sr=\(currentInputSampleRate)")
            return true
        }

        DebugTrace.log("RealtimeAudioEngineWorker.start: warm engine produced no chunks, rebuilding once")
        stopEngineSync(flushTail: false)
        guard prepareEngineSync(
            preferredDeviceID: preferredDeviceID,
            candidateDeviceIDs: candidateDeviceIDs,
            usesAutomaticDeviceSelection: usesAutomaticDeviceSelection,
            inputDeviceDebugSummary: inputDeviceDebugSummary,
            onLevel: onLevel
        ) else {
            return false
        }
        resetChunking(onChunk: onChunk)
        let retryBaseline = currentChunkActivitySequence()
        let ok = waitForChunkActivitySync(after: retryBaseline, timeout: 0.85)
        if ok {
            DebugTrace.log("RealtimeAudioEngineWorker.start: capture ready after rebuild sr=\(currentInputSampleRate)")
        } else {
            DebugTrace.log("RealtimeAudioEngineWorker.start: no audio chunks after rebuild")
            stopCaptureSync(flushTail: false)
        }
        return ok
    }

    private func prepareEngineSync(
        preferredDeviceID: AudioDeviceID?,
        candidateDeviceIDs: [AudioDeviceID],
        usesAutomaticDeviceSelection: Bool,
        inputDeviceDebugSummary: String,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> Bool {
        let requestedDeviceIDs = effectiveCandidateDeviceIDs(
            preferredDeviceID: preferredDeviceID,
            candidateDeviceIDs: candidateDeviceIDs,
            usesAutomaticDeviceSelection: usesAutomaticDeviceSelection
        )
        guard !requestedDeviceIDs.isEmpty else {
            DebugTrace.log("RealtimeAudioEngineWorker.prepare: no candidate input device, \(inputDeviceDebugSummary)")
            return false
        }
        let primaryRequestedDeviceID: AudioDeviceID? = requestedDeviceIDs.first ?? nil
        if engineReady,
           currentPreferredDeviceID != primaryRequestedDeviceID {
            DebugTrace.log("RealtimeAudioEngineWorker.prepare: preferred device changed old=\(currentPreferredDeviceID.map(String.init) ?? "nil") new=\(primaryRequestedDeviceID.map(String.init) ?? "nil"), rebuilding")
            stopEngineSync(flushTail: false)
        }

        if engineReady, engine?.isRunning == true {
            DebugTrace.log("RealtimeAudioEngineWorker.prepare: reuse warm engine sr=\(currentInputSampleRate), \(inputDeviceDebugSummary)")
            return true
        }

        for requestedDeviceID in requestedDeviceIDs {
            let candidateLabel = requestedDeviceID.map(String.init) ?? "system-default"
            for attempt in 1...maxStartAttempts {
                DebugTrace.log("RealtimeAudioEngineWorker.prepare: candidate=\(candidateLabel), attempt=\(attempt), \(inputDeviceDebugSummary)")
                let engine = AVAudioEngine()
                if let deviceID = requestedDeviceID,
                   !applyInputDevice(deviceID, to: engine) {
                    DebugTrace.log("RealtimeAudioEngineWorker.prepare: candidate device rejected deviceID=\(deviceID)")
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }

                let input = engine.inputNode
                let initialFormat = input.inputFormat(forBus: 0)
                DebugTrace.log("RealtimeAudioEngineWorker.prepare: input format sr=\(initialFormat.sampleRate), ch=\(initialFormat.channelCount)")

                if waitForConfigChangeSync(engine: engine, timeout: 0.45) {
                    DebugTrace.log("RealtimeAudioEngineWorker.prepare: config changed, settling")
                    Thread.sleep(forTimeInterval: 0.5)
                }

                let inputFormat = input.inputFormat(forBus: 0)
                guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                    DebugTrace.log("RealtimeAudioEngineWorker.prepare: invalid format, candidate=\(candidateLabel), attempt=\(attempt), ready sr=\(inputFormat.sampleRate), ch=\(inputFormat.channelCount)")
                    teardown(engine)
                    Thread.sleep(forTimeInterval: 0.35)
                    continue
                }

                self.engine = engine
                resetChunking(onChunk: nil)
                input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
                    guard let self else { return }
                    self.markTapActivity()
                    // 引擎保温期间（未在录音/识别写入）跳过逐缓冲的 RMS 计算与电平回调派发，
                    // 消除空闲时每个音频缓冲都生成一个 MainActor Task 派发到主线程的问题；
                    // 与 AudioRecorder 保温路径保持一致，引擎本体仍常驻运行，开始识别后立即恢复电平。
                    guard self.shouldConvertAudio() else { return }
                    self.levelHandler?(Self.rmsLevel(buffer: buffer))
                    guard let data = self.convertToPCM16(buffer) else { return }
                    let chunks = self.appendPCMAndTakeChunks(data)
                    if !chunks.isEmpty {
                        self.markChunkActivity()
                    }
                    if let handler = self.currentChunkHandler() {
                        for chunk in chunks {
                            handler(chunk)
                        }
                    }
                }
                do {
                    engine.prepare()
                    let tapBaseline = currentTapActivitySequence()
                    let chunkBaseline = currentChunkActivitySequence()
                    setAudioVerificationActive(true)
                    defer { setAudioVerificationActive(false) }
                    let verification = try startEngineAndVerifyAudioSync(
                        engine: engine,
                        tapBaseline: tapBaseline,
                        chunkBaseline: chunkBaseline,
                        timeout: 0.95
                    )
                    switch verification {
                    case .verified:
                        engineReady = true
                        currentPreferredDeviceID = requestedDeviceID
                        currentInputSampleRate = inputFormat.sampleRate
                        discardPendingPCM()
                        DebugTrace.log("RealtimeAudioEngineWorker.prepare: ready deviceID=\(candidateLabel), sr=\(inputFormat.sampleRate), audio verified")
                        return true
                    case .postStartConfigurationChanged(let tapActive):
                        DebugTrace.log("RealtimeAudioEngineWorker.prepare: post-start config changed, candidate=\(candidateLabel), tapActive=\(tapActive), settling")
                        stopEngineSync(flushTail: false)
                        Thread.sleep(forTimeInterval: min(1.4, 0.55 + Double(attempt) * 0.25))
                        continue
                    case .noAudio(let tapActive):
                        DebugTrace.log("RealtimeAudioEngineWorker.prepare: no audio chunks after start, candidate=\(candidateLabel), tapActive=\(tapActive), rebuilding")
                    case .notRunning:
                        DebugTrace.log("RealtimeAudioEngineWorker.prepare: engine not running after start")
                    }
                } catch {
                    DebugTrace.log("RealtimeAudioEngineWorker.prepare: \(error.localizedDescription)")
                }
                stopEngineSync(flushTail: false)
                Thread.sleep(forTimeInterval: 0.35)
            }
        }
        return false
    }

    private func effectiveCandidateDeviceIDs(
        preferredDeviceID: AudioDeviceID?,
        candidateDeviceIDs: [AudioDeviceID],
        usesAutomaticDeviceSelection: Bool
    ) -> [AudioDeviceID?] {
        var ordered = [AudioDeviceID]()
        func appendUnique(_ deviceID: AudioDeviceID?) {
            guard let deviceID, !ordered.contains(deviceID) else { return }
            ordered.append(deviceID)
        }
        candidateDeviceIDs.forEach { appendUnique($0) }
        if usesAutomaticDeviceSelection {
            appendUnique(preferredDeviceID)
        }
        if ordered.isEmpty {
            return usesAutomaticDeviceSelection ? [nil] : []
        }
        return ordered.map { Optional($0) }
    }

    private func stopCaptureSync(flushTail: Bool) {
        if flushTail, let tail = flushPendingPCM(), let chunkHandler {
            chunkHandler(tail)
        } else {
            discardPendingPCM()
        }
        chunkLock.lock()
        chunkHandler = nil
        resampleCursor = 0
        chunkLock.unlock()
        DebugTrace.log("RealtimeAudioEngineWorker.stopCapture: engineReady=\(engineReady), running=\(engine?.isRunning == true)")
    }

    private func stopEngineSync(flushTail: Bool) {
        stopCaptureSync(flushTail: flushTail)
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        engine = nil
        engineReady = false
        currentPreferredDeviceID = nil
        currentInputSampleRate = 0
        resampleCursor = 0
        DebugTrace.log("RealtimeAudioEngineWorker.stopEngine: complete")
    }

    private func teardown(_ engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }

    private func convertToPCM16(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard buffer.format.sampleRate > 0,
              buffer.frameLength > 1,
              let mono = Self.monoFloatSamples(from: buffer),
              mono.count > 1 else {
            logConversionDrop(buffer: buffer, reason: "unsupported input buffer")
            return nil
        }

        let step = buffer.format.sampleRate / targetSampleRate
        guard step > 0 else {
            logConversionDrop(buffer: buffer, reason: "invalid resample step")
            return nil
        }

        var cursor = resampleCursor
        var output = Data()
        output.reserveCapacity(max(0, Int(Double(mono.count) / step)) * 2)

        while cursor < Double(mono.count - 1) {
            let index = Int(cursor)
            let fraction = Float(cursor - Double(index))
            let sample = mono[index] + (mono[index + 1] - mono[index]) * fraction
            let clamped = max(-1, min(1, sample))
            let intSample = Int16(clamped * Float(Int16.max))
            output.append(UInt8(truncatingIfNeeded: intSample))
            output.append(UInt8(truncatingIfNeeded: intSample >> 8))
            cursor += step
        }

        resampleCursor = cursor - Double(mono.count)
        if resampleCursor < 0 { resampleCursor = 0 }

        if output.isEmpty {
            logConversionDrop(buffer: buffer, reason: "empty resampled output")
            return nil
        }
        conversionDropCount = 0
        return output
    }

    private static func monoFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        let channelCount = max(1, Int(buffer.format.channelCount))

        if let channels = buffer.floatChannelData {
            var mono = Array(repeating: Float(0), count: frameCount)
            let readableChannels = min(channelCount, Int(buffer.format.channelCount))
            for channelIndex in 0..<readableChannels {
                let channel = channels[channelIndex]
                for frame in 0..<frameCount {
                    mono[frame] += channel[frame]
                }
            }
            let divisor = Float(max(1, readableChannels))
            for frame in 0..<frameCount {
                mono[frame] /= divisor
            }
            return mono
        }

        if let channels = buffer.int16ChannelData {
            var mono = Array(repeating: Float(0), count: frameCount)
            let readableChannels = min(channelCount, Int(buffer.format.channelCount))
            for channelIndex in 0..<readableChannels {
                let channel = channels[channelIndex]
                for frame in 0..<frameCount {
                    mono[frame] += Float(channel[frame]) / Float(Int16.max)
                }
            }
            let divisor = Float(max(1, readableChannels))
            for frame in 0..<frameCount {
                mono[frame] /= divisor
            }
            return mono
        }

        return nil
    }

    private func logConversionDrop(buffer: AVAudioPCMBuffer, reason: String) {
        conversionDropCount += 1
        guard conversionDropCount <= 3 || conversionDropCount % 50 == 0 else { return }
        DebugTrace.log(
            "RealtimeAudioEngineWorker.convert: dropped buffer count=\(conversionDropCount) reason=\(reason) sr=\(buffer.format.sampleRate), ch=\(buffer.format.channelCount), frames=\(buffer.frameLength), format=\(buffer.format.commonFormat.rawValue)"
        )
    }

    private func resetChunking(onChunk: (@Sendable (Data) -> Void)?) {
        chunkLock.lock()
        pendingPCM.removeAll(keepingCapacity: false)
        pendingPCM.reserveCapacity(targetChunkBytes * 2)
        chunkHandler = onChunk
        resampleCursor = 0
        conversionDropCount = 0
        chunkLock.unlock()
    }

    private func setAudioVerificationActive(_ active: Bool) {
        chunkLock.lock()
        verifyingAudio = active
        if !active, chunkHandler == nil {
            pendingPCM.removeAll(keepingCapacity: false)
        }
        chunkLock.unlock()
    }

    private func shouldConvertAudio() -> Bool {
        chunkLock.lock()
        let shouldConvert = verifyingAudio || chunkHandler != nil
        chunkLock.unlock()
        return shouldConvert
    }

    private func currentChunkHandler() -> (@Sendable (Data) -> Void)? {
        chunkLock.lock()
        defer { chunkLock.unlock() }
        return chunkHandler
    }

    private func appendPCMAndTakeChunks(_ data: Data) -> [Data] {
        chunkLock.lock()
        defer { chunkLock.unlock() }

        guard verifyingAudio || chunkHandler != nil else {
            pendingPCM.removeAll(keepingCapacity: false)
            return []
        }

        pendingPCM.append(data)
        var chunks: [Data] = []
        let chunkCount = pendingPCM.count / targetChunkBytes
        guard chunkCount > 0 else {
            return chunks
        }

        chunks.reserveCapacity(chunkCount)
        let consumedBytes = chunkCount * targetChunkBytes
        for offset in stride(from: 0, to: consumedBytes, by: targetChunkBytes) {
            let start = pendingPCM.index(pendingPCM.startIndex, offsetBy: offset)
            let end = pendingPCM.index(start, offsetBy: targetChunkBytes)
            chunks.append(Data(pendingPCM[start..<end]))
        }
        pendingPCM.removeSubrange(pendingPCM.startIndex..<pendingPCM.index(pendingPCM.startIndex, offsetBy: consumedBytes))
        if consumedBytes > targetChunkBytes * 8 {
            let tail = pendingPCM
            pendingPCM.removeAll(keepingCapacity: false)
            pendingPCM.append(tail)
        }
        return chunks
    }

    private func flushPendingPCM() -> Data? {
        chunkLock.lock()
        defer { chunkLock.unlock() }
        guard !pendingPCM.isEmpty else { return nil }
        let tail = pendingPCM
        pendingPCM.removeAll(keepingCapacity: true)
        return tail
    }

    private func discardPendingPCM() {
        chunkLock.lock()
        pendingPCM.removeAll(keepingCapacity: false)
        chunkLock.unlock()
    }

    private func applyInputDevice(_ deviceID: AudioDeviceID, to engine: AVAudioEngine) -> Bool {
        // HAL 异常时 audioUnit 可能为 nil；直接访问 nil 值会在设备异常的容错路径上崩溃，改为返回 false 走重试/回退。
        guard let audioUnit = engine.inputNode.audioUnit else {
            DebugTrace.log("RealtimeAudioEngineWorker.applyInputDevice: inputNode.audioUnit is nil, deviceID=\(deviceID)")
            return false
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        DebugTrace.log("RealtimeAudioEngineWorker.applyInputDevice: deviceID=\(deviceID), status=\(status)")
        return status == noErr
    }

    private func waitForConfigChangeSync(engine: AVAudioEngine, timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var fired = false
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            lock.lock()
            if !fired {
                fired = true
                semaphore.signal()
            }
            lock.unlock()
        }
        let result = semaphore.wait(timeout: .now() + timeout) == .success
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        return result
    }

    private func startEngineAndVerifyAudioSync(
        engine: AVAudioEngine,
        tapBaseline: UInt64,
        chunkBaseline: UInt64,
        timeout: TimeInterval
    ) throws -> EngineStartVerificationResult {
        let lock = NSLock()
        var configurationChanged = false
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            lock.lock()
            configurationChanged = true
            lock.unlock()
        }
        defer {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        try engine.start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentChunkActivitySequence() > chunkBaseline {
                return .verified
            }
            lock.lock()
            let didChange = configurationChanged
            lock.unlock()
            if didChange && !engine.isRunning {
                return .postStartConfigurationChanged(tapActive: currentTapActivitySequence() > tapBaseline)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if currentChunkActivitySequence() > chunkBaseline {
            return .verified
        }
        let tapActive = currentTapActivitySequence() > tapBaseline
        lock.lock()
        let didChange = configurationChanged
        lock.unlock()
        if didChange {
            return .postStartConfigurationChanged(tapActive: tapActive)
        }
        if !engine.isRunning {
            return .notRunning
        }
        return .noAudio(tapActive: tapActive)
    }

    private func markTapActivity() {
        activityLock.lock()
        tapActivitySequence &+= 1
        activityLock.unlock()
    }

    private func markChunkActivity() {
        activityLock.lock()
        chunkActivitySequence &+= 1
        activityLock.unlock()
    }

    private func currentTapActivitySequence() -> UInt64 {
        activityLock.lock()
        defer { activityLock.unlock() }
        return tapActivitySequence
    }

    private func currentChunkActivitySequence() -> UInt64 {
        activityLock.lock()
        defer { activityLock.unlock() }
        return chunkActivitySequence
    }

    private func waitForChunkActivitySync(after baseline: UInt64, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentChunkActivitySequence() > baseline {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return currentChunkActivitySequence() > baseline
    }

    private static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var sum: Float = 0
        let channel = data[0]
        for index in 0..<frameCount { sum += channel[index] * channel[index] }
        let rms = sqrt(sum / Float(frameCount))
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 60) / 60))
    }
}

@MainActor
final class RealtimeAudioStreamer: ObservableObject {
    static let shared = RealtimeAudioStreamer()

    static let maxDuration: TimeInterval = 60
    static let countdownWarningSeconds = 10

    @Published private(set) var state: RealtimeStreamingState = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var countdown: Int?
    @Published private(set) var liveText: String = ""
    // 显示用的平滑文本:仅供悬浮窗逐字揭示展示,业务始终读取上面的完整 liveText,互不影响。
    @Published private(set) var displayLiveText: String = ""
    @Published private(set) var inputDeviceTransitionInProgress = false

    private lazy var typewriter = TypewriterReveal { [weak self] shown in
        self?.displayLiveText = shown
    }

    private var worker = RealtimeAudioEngineWorker()
    private var tickerTask: Task<Void, Never>?
    private var startedAt: Date?
    private var maxDurationHandler: (() -> Void)?
    private var inputDeviceTransitionGeneration: UInt64 = 0

    private init() {}

    func markInputDeviceTransitionStarted(reason: String) {
        inputDeviceTransitionGeneration &+= 1
        inputDeviceTransitionInProgress = true
        DebugTrace.log("RealtimeAudioStreamer.inputDeviceTransition: begin gen=\(inputDeviceTransitionGeneration) reason=\(reason)")
    }

    func prewarmIfNeeded() async {
        guard PermissionManager.shared.microphoneStatus == .granted else {
            DebugTrace.log("RealtimeAudioStreamer.prewarmIfNeeded: skipped; mic not granted")
            return
        }
        guard !inputDeviceTransitionInProgress else {
            DebugTrace.log("RealtimeAudioStreamer.prewarmIfNeeded: skipped; input device transition in progress")
            return
        }
        guard state == .idle else {
            DebugTrace.log("RealtimeAudioStreamer.prewarmIfNeeded: skipped; state=\(state)")
            return
        }
        let resolution = MicrophoneDeviceManager.shared.recordingInputDeviceResolution(reason: "realtime prewarm")
        let preferredDeviceID = resolution.preferredDeviceID
        let candidateDeviceIDs = resolution.candidateDeviceIDs
        let usesAutomaticDeviceSelection = resolution.usesAutomaticDeviceSelection
        let inputDeviceDebugSummary = resolution.debugSummary
        DebugTrace.log("RealtimeAudioStreamer.prewarmIfNeeded: \(inputDeviceDebugSummary)")
        worker.prewarm(
            preferredDeviceID: preferredDeviceID,
            candidateDeviceIDs: candidateDeviceIDs,
            usesAutomaticDeviceSelection: usesAutomaticDeviceSelection,
            inputDeviceDebugSummary: inputDeviceDebugSummary
        ) { level in
            Task { @MainActor in
                guard RealtimeAudioStreamer.shared.state == .starting || RealtimeAudioStreamer.shared.state == .streaming else { return }
                RealtimeAudioStreamer.shared.audioLevel = level
            }
        }
    }

    func rebuildForInputDeviceChange() async {
        guard state == .idle else {
            DebugTrace.log("RealtimeAudioStreamer.rebuildForInputDeviceChange: skipped; state=\(state)")
            inputDeviceTransitionInProgress = false
            return
        }
        if !inputDeviceTransitionInProgress {
            markInputDeviceTransitionStarted(reason: "rebuild requested")
        }
        let generation = inputDeviceTransitionGeneration
        let resolution = MicrophoneDeviceManager.shared.recordingInputDeviceResolution(reason: "realtime rebuild")
        let preferredDeviceID = resolution.preferredDeviceID
        let candidateDeviceIDs = resolution.candidateDeviceIDs
        let usesAutomaticDeviceSelection = resolution.usesAutomaticDeviceSelection
        let inputDeviceDebugSummary = resolution.debugSummary
        DebugTrace.log("RealtimeAudioStreamer.rebuildForInputDeviceChange: gen=\(generation), \(inputDeviceDebugSummary)")
        let ok = await worker.rebuildForDeviceChange(
            preferredDeviceID: preferredDeviceID,
            candidateDeviceIDs: candidateDeviceIDs,
            usesAutomaticDeviceSelection: usesAutomaticDeviceSelection,
            inputDeviceDebugSummary: inputDeviceDebugSummary
        ) { level in
            Task { @MainActor in
                guard RealtimeAudioStreamer.shared.state == .starting || RealtimeAudioStreamer.shared.state == .streaming else { return }
                RealtimeAudioStreamer.shared.audioLevel = level
            }
        }
        if generation == inputDeviceTransitionGeneration {
            inputDeviceTransitionInProgress = false
            DebugTrace.log("RealtimeAudioStreamer.inputDeviceTransition: end gen=\(generation) ok=\(ok)")
        } else {
            DebugTrace.log("RealtimeAudioStreamer.inputDeviceTransition: stale end gen=\(generation) current=\(inputDeviceTransitionGeneration) ok=\(ok)")
        }
    }

    func shutdownWarmEngine() async {
        DebugTrace.log("RealtimeAudioStreamer.shutdownWarmEngine")
        await worker.shutdown()
    }

    func prepareStartingVisualState() -> Bool {
        guard !inputDeviceTransitionInProgress else {
            DebugTrace.log("RealtimeAudioStreamer.prepareStartingVisualState: ignored; input device transition in progress")
            return false
        }
        guard state == .idle else { return false }
        audioLevel = 0
        elapsedSeconds = 0
        countdown = nil
        liveText = ""
        displayLiveText = ""
        typewriter.reset()
        state = .starting
        return true
    }

    func startStreaming(
        onChunk: @escaping @Sendable (Data) -> Void,
        onMaxDuration: @escaping () -> Void
    ) async -> Bool {
        guard !inputDeviceTransitionInProgress else {
            DebugTrace.log("RealtimeAudioStreamer.startStreaming: blocked; input device transition in progress")
            return false
        }
        guard state == .starting || state == .idle else { return false }
        maxDurationHandler = onMaxDuration
        if state == .idle { state = .starting }
        let resolution = MicrophoneDeviceManager.shared.recordingInputDeviceResolution(reason: "realtime start")
        let preferredDeviceID = resolution.preferredDeviceID
        let candidateDeviceIDs = resolution.candidateDeviceIDs
        let usesAutomaticDeviceSelection = resolution.usesAutomaticDeviceSelection
        let inputDeviceDebugSummary = resolution.debugSummary
        DebugTrace.log("RealtimeAudioStreamer.startStreaming: \(inputDeviceDebugSummary)")
        let success = await worker.start(
            preferredDeviceID: preferredDeviceID,
            candidateDeviceIDs: candidateDeviceIDs,
            usesAutomaticDeviceSelection: usesAutomaticDeviceSelection,
            inputDeviceDebugSummary: inputDeviceDebugSummary,
            onChunk: onChunk
        ) { level in
            Task { @MainActor in
                guard RealtimeAudioStreamer.shared.state == .starting || RealtimeAudioStreamer.shared.state == .streaming else { return }
                RealtimeAudioStreamer.shared.audioLevel = level
            }
        }
        guard success else {
            state = .idle
            return false
        }
        state = .streaming
        startTicker()
        return true
    }

    func stopForProcessing() async {
        guard state == .streaming || state == .starting else { return }
        cancelTicker()
        // 停止时把预览补齐到完整目标(避免停在揭示一半);最终提交仍走权威文本,不受影响。
        typewriter.flush()
        state = .processing
        await worker.stop()
        await Task.yield()
        audioLevel = 0
    }

    func cancel() {
        cancelTicker()
        Task { await worker.stop() }
        resetToIdle()
    }

    func resetToIdle() {
        cancelTicker()
        audioLevel = 0
        elapsedSeconds = 0
        countdown = nil
        liveText = ""
        displayLiveText = ""
        typewriter.reset()
        state = .idle
        maxDurationHandler = nil
    }

    func updateLiveText(_ text: String) {
        // liveText 立即设为完整目标(业务读取/兜底依赖它);显示走打字机平滑。
        liveText = text
        typewriter.setTarget(text)
    }

    private func startTicker() {
        cancelTicker()
        startedAt = Date()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .streaming, let startedAt = self.startedAt else { return }
                let elapsed = Date().timeIntervalSince(startedAt)
                self.elapsedSeconds = max(0, Int(floor(elapsed)))
                let remaining = Self.maxDuration - elapsed
                if remaining <= 0 {
                    self.countdown = 0
                    self.maxDurationHandler?()
                    return
                }
                self.countdown = remaining <= TimeInterval(Self.countdownWarningSeconds)
                    ? max(1, Int(ceil(remaining)))
                    : nil
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func cancelTicker() {
        tickerTask?.cancel()
        tickerTask = nil
        startedAt = nil
        countdown = nil
    }
}
