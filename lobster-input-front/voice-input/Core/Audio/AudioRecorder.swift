/// AudioRecorder.swift
/// 麦克风录音管理器（单例）。
///
/// ## 架构设计：引擎持久化
///
/// AVAudioEngine 的延迟完全来自首次创建时 macOS HAL 音频子系统的初始化（1-4秒）。
/// 一旦 HAL 完成初始化，engine.start() 几乎是瞬时的（< 50ms）。
///
/// 因此采用「引擎持久化」方案：
///   - App 启动或权限确认后预热并启动引擎（触发 HAL 初始化），之后短时间保温
///   - 录音时只做：打开写文件开关，tap 继续向 AVAudioFile 写入
///   - 结束时只做：关闭写文件开关 → 返回已写好的文件 URL
///   - 空闲一段时间后移除 tap 并停机，避免长期占用 HAL/tap 导致设备切换和浮窗状态不稳定
///
/// ## 音频格式
/// 录制 16kHz 单声道 PCM16 WAV，后端 DashScope SDK 原生支持，无需服务端格式转换。
///
import Foundation
import Combine
import AVFoundation
import AudioToolbox
import CoreAudio
import os.log

private let recLog = Logger(subsystem: "ssh2026.voice-input", category: "AudioRecorder")

/// 录音状态枚举
enum RecordingState: Equatable {
    case idle
    case starting
    case recording
    case processing
}

private final class AudioCaptureSession {
    private let lock = NSLock()
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var enhancementPipeline: AudioEnhancementPipeline?
    private var isWriting = false

    var writingActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isWriting
    }

    init?(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.converter = converter
    }

    func startWriting(to url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isWriting else { return false }
        do {
            converter?.reset()
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: Self.outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            enhancementPipeline = AudioEnhancementPipeline.voiceInputDefault()
            isWriting = true
            return true
        } catch {
            audioFile = nil
            enhancementPipeline = nil
            isWriting = false
            return false
        }
    }

    func stopWriting() -> String? {
        lock.lock()
        defer { lock.unlock() }
        isWriting = false
        audioFile = nil
        converter?.reset()
        let summary = enhancementPipeline?.signalSummary()
        enhancementPipeline = nil
        return summary
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard isWriting,
              let audioFile,
              let converter,
              let enhancementPipeline else {
            return Self.rmsLevel(buffer: buffer)
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return Self.rmsLevel(buffer: buffer)
        }

        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData, converted.frameLength > 0 else {
            return Self.rmsLevel(buffer: buffer)
        }
        let metrics = enhancementPipeline.process(converted)
        try? audioFile.write(from: converted)
        return metrics.displayLevel
    }

    private static let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

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

private final class AudioEngineWorker {
    private let queue = DispatchQueue(label: "ssh2026.voice-input.audio-engine", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var captureSession: AudioCaptureSession?
    private var configChangeObserver: NSObjectProtocol?
    private var engineReady = false
    private var engineReadyTime: Date?
    private var currentPreferredDeviceID: AudioDeviceID?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var lastStopTime = Date.distantPast
    private let tapActivityLock = NSLock()
    private var tapActivitySequence: UInt64 = 0
    private let maxPrepareAttempts = 3
    private let targetFormat: AVAudioFormat

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func prewarm(
        preferredDeviceID: AudioDeviceID?,
        inputDeviceDebugSummary: String,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        queue.async {
            guard self.captureSession?.writingActive != true else { return }
            self.levelHandler = onLevel
            _ = self.prepareEngineIfNeededSync(
                preferredDeviceID: preferredDeviceID,
                inputDeviceDebugSummary: inputDeviceDebugSummary,
                onLevel: onLevel
            )
        }
    }

    func startWriting(
        to url: URL,
        preferredDeviceID: AudioDeviceID?,
        inputDeviceDebugSummary: String,
        onLevel: @escaping @Sendable (Float) -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.levelHandler = onLevel
                let ok = self.startWritingSync(
                    to: url,
                    preferredDeviceID: preferredDeviceID,
                    inputDeviceDebugSummary: inputDeviceDebugSummary,
                    onLevel: onLevel
                )
                continuation.resume(returning: ok)
            }
        }
    }

    func stopWriting() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let summary = self.captureSession?.stopWriting()
                self.lastStopTime = Date()
                continuation.resume(returning: summary)
            }
        }
    }

    func cancelWriting() {
        queue.async {
            _ = self.captureSession?.stopWriting()
            self.lastStopTime = Date()
        }
    }

    func teardown(keepEngineAllocated: Bool = true) {
        queue.async {
            self.teardownSync(keepEngineAllocated: keepEngineAllocated)
        }
    }

    func teardownForRealtimeStart() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.teardownSync(keepEngineAllocated: false)
                continuation.resume()
            }
        }
    }

    func rebuildForDeviceChange() {
        queue.async {
            self.teardownSync(keepEngineAllocated: false)
        }
    }

    private func startWritingSync(
        to url: URL,
        preferredDeviceID: AudioDeviceID?,
        inputDeviceDebugSummary: String,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> Bool {
        if Date().timeIntervalSince(lastStopTime) < 0.12 {
            Thread.sleep(forTimeInterval: 0.12)
        }

        guard prepareEngineIfNeededSync(
            preferredDeviceID: preferredDeviceID,
            inputDeviceDebugSummary: inputDeviceDebugSummary,
            onLevel: onLevel
        ),
              let captureSession,
              let engine,
              engine.isRunning else {
            DebugTrace.log("AudioEngineWorker.startWriting: engine unavailable")
            return false
        }

        guard captureSession.startWriting(to: url) else {
            DebugTrace.log("AudioEngineWorker.startWriting: writer failed, rebuilding once")
            teardownSync(keepEngineAllocated: false)
            guard prepareEngineIfNeededSync(
                    preferredDeviceID: preferredDeviceID,
                    inputDeviceDebugSummary: inputDeviceDebugSummary,
                    onLevel: onLevel
                  ),
                  let retrySession = self.captureSession,
                  self.engine?.isRunning == true,
                  retrySession.startWriting(to: url) else {
                return false
            }
            return verifyActiveTapOrRebuildSync(
                preferredDeviceID: preferredDeviceID,
                inputDeviceDebugSummary: inputDeviceDebugSummary,
                onLevel: onLevel,
                url: url
            )
        }
        return verifyActiveTapOrRebuildSync(
            preferredDeviceID: preferredDeviceID,
            inputDeviceDebugSummary: inputDeviceDebugSummary,
            onLevel: onLevel,
            url: url
        )
    }

    private func prepareEngineIfNeededSync(
        preferredDeviceID: AudioDeviceID?,
        inputDeviceDebugSummary: String,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> Bool {
        var requestedDeviceID = preferredDeviceID
        var preferredDeviceApplyFailures = 0
        var invalidFormatFailures = 0

        if engineReady,
           currentPreferredDeviceID != requestedDeviceID,
           captureSession?.writingActive != true {
            DebugTrace.log("AudioEngineWorker.prepare: preferred device changed, rebuilding")
            teardownSync(keepEngineAllocated: false)
        }

        if engineReady, engine?.isRunning == true, captureSession != nil {
            return true
        }

        for attempt in 1...maxPrepareAttempts {
            DebugTrace.log("AudioEngineWorker.prepare: attempt=\(attempt), \(inputDeviceDebugSummary)")
            removeConfigObserver()
            let eng = engine ?? AVAudioEngine()
            engine = eng

            if let deviceID = requestedDeviceID,
               !applyInputDevice(deviceID, to: eng) {
                teardownSync(keepEngineAllocated: false)
                preferredDeviceApplyFailures += 1
                if preferredDeviceApplyFailures >= 2 {
                    requestedDeviceID = nil
                    DebugTrace.log("AudioEngineWorker.prepare: preferred device rejected twice, falling back to system default for this start")
                } else {
                    DebugTrace.log("AudioEngineWorker.prepare: preferred device rejected, retrying after route settle")
                }
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }

            let initialFormat = eng.inputNode.inputFormat(forBus: 0)
            DebugTrace.log("AudioEngineWorker.prepare: input format sr=\(initialFormat.sampleRate), ch=\(initialFormat.channelCount)")

            if waitForConfigChangeSync(engine: eng, timeout: 0.45) {
                DebugTrace.log("AudioEngineWorker.prepare: config changed, settling")
                Thread.sleep(forTimeInterval: 0.5)
            }

            let readyFormat = eng.inputNode.inputFormat(forBus: 0)
            guard readyFormat.sampleRate > 0, readyFormat.channelCount > 0 else {
                invalidFormatFailures += 1
                DebugTrace.log("AudioEngineWorker.prepare: invalid format, attempt=\(attempt), ready sr=\(readyFormat.sampleRate), ch=\(readyFormat.channelCount)")
                teardownSync(keepEngineAllocated: false)
                if requestedDeviceID == nil, invalidFormatFailures == 1 {
                    requestedDeviceID = AudioInputDeviceService.shared
                        .currentSnapshot(requestRefreshIfStale: "audio worker recovery")
                        .defaultInputDeviceID
                    if let requestedDeviceID {
                        DebugTrace.log("AudioEngineWorker.prepare: system default produced invalid format, retrying with explicit default deviceID=\(requestedDeviceID)")
                    }
                } else if requestedDeviceID != nil, invalidFormatFailures >= 2 {
                    requestedDeviceID = nil
                    DebugTrace.log("AudioEngineWorker.prepare: preferred device produced invalid format twice, falling back to system default for this start")
                }
                Thread.sleep(forTimeInterval: invalidFormatFailures == 1 ? 0.35 : 0.6)
                continue
            }

            guard installTapAndStartSync(engine: eng, format: readyFormat, onLevel: onLevel) else {
                DebugTrace.log("AudioEngineWorker.prepare: start failed, attempt=\(attempt)")
                teardownSync(keepEngineAllocated: false)
                Thread.sleep(forTimeInterval: 0.35)
                continue
            }

            Thread.sleep(forTimeInterval: 0.08)
            guard engine === eng, eng.isRunning, captureSession != nil else {
                DebugTrace.log("AudioEngineWorker.prepare: post-start verify failed, attempt=\(attempt)")
                teardownSync(keepEngineAllocated: false)
                Thread.sleep(forTimeInterval: 0.35)
                continue
            }

            engineReady = true
            engineReadyTime = Date()
            currentPreferredDeviceID = requestedDeviceID
            observeIdleConfigChange(engine: eng)
            DebugTrace.log("AudioEngineWorker.prepare: ready sr=\(readyFormat.sampleRate)")
            return true
        }

        engineReady = false
        return false
    }

    private func installTapAndStartSync(
        engine eng: AVAudioEngine,
        format hwFormat: AVAudioFormat,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> Bool {
        do {
            guard let session = AudioCaptureSession(sourceFormat: hwFormat, targetFormat: targetFormat) else {
                return false
            }
            let inputNode = eng.inputNode
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self, weak session] buffer, _ in
                guard let session else { return }
                // 引擎保温期间（未在录音写入）跳过逐缓冲的 RMS 计算与电平回调派发，
                // 消除空闲时每秒约 12 个 MainActor Task 的主线程唤醒与无意义 CPU 占用；
                // 引擎本体仍常驻运行，按下快捷键后 session.startWriting 置位即恢复处理，瞬时开始录音。
                guard session.writingActive else { return }
                self?.markTapActivity()
                onLevel(session.process(buffer))
            }
            captureSession = session
            eng.prepare()
            try eng.start()
            return eng.isRunning
        } catch {
            DebugTrace.log("AudioEngineWorker.installTapAndStart: \(error.localizedDescription)")
            captureSession = nil
            return false
        }
    }

    private func observeIdleConfigChange(engine eng: AVAudioEngine) {
        removeConfigObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: eng,
            queue: nil
        ) { [weak self, weak eng] _ in
            guard let self, let eng else { return }
            self.queue.async {
                guard self.engine === eng else { return }
                if let readyTime = self.engineReadyTime,
                   Date().timeIntervalSince(readyTime) < 2.0 {
                    DebugTrace.log("AudioEngineWorker.config: ignored near startup")
                    return
                }
                guard self.captureSession?.writingActive != true else {
                    DebugTrace.log("AudioEngineWorker.config: active recording, mark not ready after stop")
                    self.engineReady = false
                    return
                }
                DebugTrace.log("AudioEngineWorker.config: idle rebuild after device/config change")
                self.teardownSync(keepEngineAllocated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    Task { @MainActor in
                        guard AudioRecorder.shared.state == .idle else { return }
                        await AudioRecorder.shared.prewarmIfNeeded()
                    }
                }
            }
        }
    }

    private func waitForConfigChangeSync(engine eng: AVAudioEngine, timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var fired = false
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: eng,
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

    private func applyInputDevice(_ deviceID: AudioDeviceID, to engine: AVAudioEngine) -> Bool {
        // HAL 异常（coreaudiod 重启 / AUHAL 实例化失败）时 audioUnit 可能为 nil；
        // 直接访问 nil 值会在最需要容错的设备异常路径上崩溃，改为返回 false 进入既有重试/回退逻辑。
        guard let audioUnit = engine.inputNode.audioUnit else {
            DebugTrace.log("AudioEngineWorker.applyInputDevice: inputNode.audioUnit is nil, deviceID=\(deviceID)")
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
        DebugTrace.log("AudioEngineWorker.applyInputDevice: deviceID=\(deviceID), status=\(status) \(Self.osStatusDescription(status))")
        return status == noErr
    }

    private static func osStatusDescription(_ status: OSStatus) -> String {
        guard status != noErr else { return "ok" }
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        let fourCC = String(bytes: bytes, encoding: .macOSRoman) ?? "????"
        return "fourCC=\(fourCC)"
    }

    private func teardownSync(keepEngineAllocated: Bool) {
        removeConfigObserver()
        _ = captureSession?.stopWriting()
        captureSession = nil
        engineReady = false
        engineReadyTime = nil
        currentPreferredDeviceID = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        if !keepEngineAllocated {
            engine = nil
        }
    }

    private func verifyActiveTapOrRebuildSync(
        preferredDeviceID: AudioDeviceID?,
        inputDeviceDebugSummary: String,
        onLevel: @escaping @Sendable (Float) -> Void,
        url: URL
    ) -> Bool {
        let baseline = currentTapActivitySequence()
        if waitForTapActivitySync(after: baseline, timeout: 0.55) {
            return true
        }

        DebugTrace.log("AudioEngineWorker.startWriting: tap inactive after start, rebuilding once")
        _ = captureSession?.stopWriting()
        teardownSync(keepEngineAllocated: false)
        guard prepareEngineIfNeededSync(
                preferredDeviceID: preferredDeviceID,
                inputDeviceDebugSummary: inputDeviceDebugSummary,
                onLevel: onLevel
              ),
              let retrySession = self.captureSession,
              self.engine?.isRunning == true,
              retrySession.startWriting(to: url) else {
            return false
        }

        let retryBaseline = currentTapActivitySequence()
        let ok = waitForTapActivitySync(after: retryBaseline, timeout: 0.55)
        if !ok {
            DebugTrace.log("AudioEngineWorker.startWriting: tap still inactive after rebuild")
        }
        return ok
    }

    private func markTapActivity() {
        tapActivityLock.lock()
        tapActivitySequence &+= 1
        tapActivityLock.unlock()
    }

    private func currentTapActivitySequence() -> UInt64 {
        tapActivityLock.lock()
        defer { tapActivityLock.unlock() }
        return tapActivitySequence
    }

    private func waitForTapActivitySync(after baseline: UInt64, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentTapActivitySequence() > baseline {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return currentTapActivitySequence() > baseline
    }

    private func removeConfigObserver() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
    }
}

@MainActor
final class AudioRecorder: ObservableObject {

    static let shared = AudioRecorder()

    private init() {}

    // MARK: - Public State

    var maxDuration: TimeInterval = 60
    static let countdownWarningSeconds: Int = 10

    @Published private(set) var state: RecordingState = .idle {
        didSet {
            let isRecording = state == .recording
            NotificationCenter.default.post(
                name: .audioRecorderStateChanged,
                object: nil,
                userInfo: ["recording": isRecording]
            )
        }
    }
    @Published private(set) var audioLevel: Float = 0.0
    @Published private(set) var countdown: Int?
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var inputDeviceTransitionInProgress = false

    // MARK: - Private Engine State

    private var recordingURL: URL?
    private var durationTickerTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var maxDurationSignalSent = false
    private var warmHealthCheckTask: Task<Void, Never>?
    private let warmHealthCheckInterval: TimeInterval = 300
    private var engineWorker = AudioEngineWorker(targetFormat: AudioRecorder.targetFormat)
    private var inputDeviceTransitionGeneration: UInt64 = 0

    /// 16kHz 单声道 Float32（tap 内暂存格式，写 WAV 时 AVAudioFile 自动转 PCM16）
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Public API

    func markInputDeviceTransitionStarted(reason: String) {
        inputDeviceTransitionGeneration &+= 1
        inputDeviceTransitionInProgress = true
        DebugTrace.log("AudioRecorder.inputDeviceTransition: begin gen=\(inputDeviceTransitionGeneration) reason=\(reason)")
    }

    func prewarmIfNeeded() async {
        guard !RealtimeRecognitionStore.isEnabled else {
            DebugTrace.log("AudioRecorder.prewarmIfNeeded: skipped; realtime ASR enabled")
            await RealtimeAudioStreamer.shared.prewarmIfNeeded()
            return
        }
        guard !inputDeviceTransitionInProgress else {
            DebugTrace.log("AudioRecorder.prewarmIfNeeded: skipped; input device transition in progress")
            return
        }
        guard PermissionManager.shared.microphoneStatus == .granted else {
            DebugTrace.log("AudioRecorder.prewarmIfNeeded: skipped; mic not granted")
            return
        }
        guard RealtimeAudioStreamer.shared.state == .idle else {
            DebugTrace.log("AudioRecorder.prewarmIfNeeded: skipped; realtime streamer=\(RealtimeAudioStreamer.shared.state)")
            return
        }
        guard state == .idle else {
            DebugTrace.log("AudioRecorder.prewarmIfNeeded: skipped; state=\(state)")
            return
        }
        cancelWarmHealthCheck()
        let resolution = MicrophoneDeviceManager.shared.recordingInputDeviceResolution(reason: "audio recorder prewarm")
        let preferredDeviceID = resolution.preferredDeviceID
        let inputDeviceDebugSummary = resolution.debugSummary
        DebugTrace.log("AudioRecorder.prewarmIfNeeded: enqueue service warmup, \(inputDeviceDebugSummary)")
        engineWorker.prewarm(preferredDeviceID: preferredDeviceID, inputDeviceDebugSummary: inputDeviceDebugSummary) { level in
            Task { @MainActor in
                guard AudioRecorder.shared.state == .starting || AudioRecorder.shared.state == .recording else { return }
                AudioRecorder.shared.audioLevel = level
            }
        }
        scheduleWarmHealthCheck()
    }

    func prepareStartingVisualState() -> Bool {
        guard !inputDeviceTransitionInProgress else {
            DebugTrace.log("AudioRecorder.prepareStartingVisualState: ignored; input device transition in progress")
            return false
        }
        guard state == .idle else {
            DebugTrace.log("AudioRecorder.prepareStartingVisualState: ignored, state=\(state)")
            return false
        }
        cancelWarmHealthCheck()
        cancelTimers()
        recordingURL = nil
        audioLevel = 0
        elapsedSeconds = 0
        countdown = nil
        state = .starting
        return true
    }

    func startRecording() async -> Bool {
        recLog.info("startRecording called, state=\(String(describing: self.state))")
        DebugTrace.log("AudioRecorder.startRecording: state=\(state)")
        cancelWarmHealthCheck()
        guard PermissionManager.shared.microphoneStatus == .granted else {
            recLog.error("microphone NOT granted")
            DebugTrace.log("AudioRecorder.startRecording: mic NOT granted")
            return false
        }
        guard state == .idle || state == .starting else {
            recLog.warning("not idle/starting, aborting")
            DebugTrace.log("AudioRecorder.startRecording: not idle/starting (\(state)), aborting")
            return false
        }

        let url = tempAudioURL()
        recordingURL = url
        if state != .starting {
            state = .starting
        }

        let resolution = MicrophoneDeviceManager.shared.recordingInputDeviceResolution(reason: "audio recorder start")
        let preferredDeviceID = resolution.preferredDeviceID
        let inputDeviceDebugSummary = resolution.debugSummary
        DebugTrace.log("AudioRecorder.startRecording: \(inputDeviceDebugSummary)")
        let success = await engineWorker.startWriting(
            to: url,
            preferredDeviceID: preferredDeviceID,
            inputDeviceDebugSummary: inputDeviceDebugSummary
        ) { level in
            Task { @MainActor in
                AudioRecorder.shared.audioLevel = level
            }
        }

        guard !Task.isCancelled, state == .starting else {
            DebugTrace.log("AudioRecorder.startRecording: cancelled while engine was starting")
            _ = await engineWorker.stopWriting()
            if let currentURL = recordingURL {
                try? FileManager.default.removeItem(at: currentURL)
            }
            recordingURL = nil
            if state == .starting {
                state = .idle
            }
            return false
        }

        guard success else {
            recLog.error("engine worker start failed")
            DebugTrace.log("AudioRecorder.startRecording: engine worker start failed")
            // 停掉可能已激活的写入会话并删除已创建的临时 WAV，避免启动失败路径残留孤儿文件。
            engineWorker.cancelWriting()
            if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
            recordingURL = nil
            state = .idle
            return false
        }

        state = .recording
        startDurationTicker()
        recLog.info("Recording started, maxDuration=\(self.maxDuration)")
        DebugTrace.log("AudioRecorder.startRecording: SUCCESS, state=recording")
        return true
    }

    func stopRecording() async -> URL? {
        guard state == .recording else { return nil }
        recLog.info("stopRecording called")
        DebugTrace.log("stopRecording: begin")

        cancelTimers()
        state = .processing
        audioLevel = 0

        if let summary = await engineWorker.stopWriting() {
            recLog.info("Audio enhancement summary: \(summary)")
            DebugTrace.log("Audio enhancement summary: \(summary)")
        }

        let url = recordingURL
        recordingURL = nil

        if let url {
            recLog.info("stopRecording done, audioURL=\(url.lastPathComponent)")
            DebugTrace.log("stopRecording: done → \(url.lastPathComponent)")
        } else {
            DebugTrace.log("stopRecording: no URL")
        }
        return url
    }

    func resetToIdle() {
        recLog.info("resetToIdle")
        state = .idle
        elapsedSeconds = 0
        if RealtimeRecognitionStore.isEnabled {
            Task { await RealtimeAudioStreamer.shared.prewarmIfNeeded() }
        } else {
            scheduleWarmHealthCheck()
        }
    }

    func cancelRecording() {
        recLog.info("cancelRecording")
        cancelTimers()
        engineWorker.cancelWriting()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        audioLevel = 0
        state = .idle
        elapsedSeconds = 0
        scheduleWarmHealthCheck()
    }

    func recoverAfterEngineStartTimeout() {
        recLog.warning("recoverAfterEngineStartTimeout")
        DebugTrace.log("AudioRecorder.recoverAfterEngineStartTimeout: replacing audio worker")
        cancelTimers()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        audioLevel = 0
        elapsedSeconds = 0
        countdown = nil
        state = .idle
        engineWorker = AudioEngineWorker(targetFormat: Self.targetFormat)
        scheduleWarmHealthCheck()
    }

    func releaseWarmEngineForRealtimeStart() async {
        guard state == .idle else { return }
        cancelWarmHealthCheck()
        DebugTrace.log("AudioRecorder.releaseWarmEngineForRealtimeStart: teardown warm engine before realtime")
        await engineWorker.teardownForRealtimeStart()
    }

    func rebuildForInputDeviceChange() async {
        guard state == .idle else {
            DebugTrace.log("AudioRecorder.rebuildForInputDeviceChange: skipped; state=\(state)")
            inputDeviceTransitionInProgress = false
            return
        }
        if RealtimeRecognitionStore.isEnabled {
            DebugTrace.log("AudioRecorder.rebuildForInputDeviceChange: route to realtime streamer")
            await engineWorker.teardownForRealtimeStart()
            await RealtimeAudioStreamer.shared.rebuildForInputDeviceChange()
            return
        }
        if !inputDeviceTransitionInProgress {
            markInputDeviceTransitionStarted(reason: "rebuild requested")
        }
        let generation = inputDeviceTransitionGeneration
        engineWorker.rebuildForDeviceChange()
        try? await Task.sleep(nanoseconds: 800_000_000)
        if generation == inputDeviceTransitionGeneration {
            inputDeviceTransitionInProgress = false
            DebugTrace.log("AudioRecorder.inputDeviceTransition: end gen=\(generation)")
        } else {
            DebugTrace.log("AudioRecorder.inputDeviceTransition: stale end gen=\(generation) current=\(inputDeviceTransitionGeneration)")
        }
        guard state == .idle else {
            DebugTrace.log("AudioRecorder.rebuildForInputDeviceChange: skip prewarm; state=\(state)")
            return
        }
        await prewarmIfNeeded()
    }

    // MARK: - Engine Lifecycle

    private func scheduleWarmHealthCheck() {
        cancelWarmHealthCheck()
        let interval = warmHealthCheckInterval
        warmHealthCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.state == .idle else { return }
            recLog.info("warm health check: refreshing audio capture service")
            DebugTrace.log("AudioRecorder warm health check: refreshing audio capture service")
            await self.prewarmIfNeeded()
        }
    }

    private func cancelWarmHealthCheck() {
        warmHealthCheckTask?.cancel()
        warmHealthCheckTask = nil
    }

    // MARK: - Timers

    private func startDurationTicker() {
        cancelTimers()
        let duration = maxDuration
        let warnSec = Self.countdownWarningSeconds
        recordingStartedAt = Date()
        elapsedSeconds = 0
        countdown = nil
        maxDurationSignalSent = false

        durationTickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .recording, let startedAt = self.recordingStartedAt else { return }

                let elapsed = Date().timeIntervalSince(startedAt)
                let nextElapsedSeconds = max(0, Int(floor(elapsed)))
                if self.elapsedSeconds != nextElapsedSeconds {
                    self.elapsedSeconds = nextElapsedSeconds
                }

                let remaining = duration - elapsed
                if remaining <= 0 {
                    if self.countdown != 0 {
                        self.countdown = 0
                    }
                    if !self.maxDurationSignalSent {
                        self.maxDurationSignalSent = true
                        NotificationCenter.default.post(name: .recordingMaxDurationReached, object: nil)
                    }
                    return
                }

                let nextCountdown: Int? = remaining <= TimeInterval(warnSec)
                    ? max(1, Int(ceil(remaining)))
                    : nil
                if self.countdown != nextCountdown {
                    self.countdown = nextCountdown
                }

                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func cancelTimers() {
        durationTickerTask?.cancel(); durationTickerTask = nil
        recordingStartedAt = nil
        maxDurationSignalSent = false
        countdown = nil
    }

    // MARK: - Utilities

    private func tempAudioURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
    }

    private static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var sum: Float = 0
        let channel = data[0]
        for i in 0..<frameCount { sum += channel[i] * channel[i] }
        let rms = sqrt(sum / Float(frameCount))
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 60) / 60))
    }
}
