import Foundation
import Combine
import AVFoundation
import os.log

private let recLog = Logger(subsystem: "ssh2026.lobster-input-ios", category: "AudioRecorder")

enum RecordingState {
    case idle
    case recording
    case processing
}

@MainActor
final class AudioRecorder: ObservableObject {

    static let shared = AudioRecorder()
    private init() {}

    var maxDuration: TimeInterval = 60

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var audioLevel: Float = 0.0
    @Published private(set) var countdown: Int?

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var maxDurationTimer: Task<Void, Never>?
    private var countdownTimer: Task<Void, Never>?
    private var levelTimer: Task<Void, Never>?

    private static let wavSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            recLog.error("AVAudioSession setup failed: \(error)")
        }
    }

    func requestPermission() async -> Bool {
        return await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func startRecording() async -> Bool {
        guard state == .idle else { return false }

        let granted = await requestPermission()
        guard granted else {
            recLog.error("microphone permission not granted")
            return false
        }

        prepareSession()

        let url = tempAudioURL()
        recordingURL = url

        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.wavSettings)
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                recLog.error("AVAudioRecorder refused to start")
                recordingURL = nil
                try? FileManager.default.removeItem(at: url)
                return false
            }
            audioRecorder = recorder
        } catch {
            recLog.error("AVAudioRecorder start failed: \(error)")
            recordingURL = nil
            try? FileManager.default.removeItem(at: url)
            return false
        }

        state = .recording
        startMaxDurationTimer()
        startLevelTimer()
        recLog.info("Recording started, maxDuration=\(self.maxDuration)")
        return true
    }

    func stopRecording() async -> URL? {
        guard state == .recording else { return nil }
        cancelTimers()
        state = .processing
        audioLevel = 0
        stopRecorder()
        let url = recordingURL
        recordingURL = nil
        return url
    }

    func resetToIdle() {
        state = .idle
    }

    func cancelRecording() {
        cancelTimers()
        stopRecorder()
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
        audioLevel = 0
        state = .idle
    }

    // MARK: - Recorder

    private func stopRecorder() {
        audioRecorder?.stop()
        audioRecorder = nil
        if KeyboardVoiceSessionBridge.snapshot().isReady {
            return
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Timers

    private func startMaxDurationTimer() {
        let duration = maxDuration
        let warnSec = 10

        maxDurationTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.state == .recording else { return }
            NotificationCenter.default.post(name: .recordingMaxDurationReached, object: nil)
        }

        let delayBeforeCountdown = max(0, duration - TimeInterval(warnSec))
        countdownTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayBeforeCountdown * 1_000_000_000))
            guard !Task.isCancelled else { return }
            for remaining in stride(from: warnSec, through: 1, by: -1) {
                guard !Task.isCancelled, let self, self.state == .recording else { return }
                self.countdown = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func cancelTimers() {
        maxDurationTimer?.cancel(); maxDurationTimer = nil
        countdownTimer?.cancel(); countdownTimer = nil
        levelTimer?.cancel(); levelTimer = nil
        countdown = nil
    }

    private func startLevelTimer() {
        levelTimer?.cancel()
        levelTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, let self, self.state == .recording, let recorder = self.audioRecorder else {
                    continue
                }
                recorder.updateMeters()
                let average = recorder.averagePower(forChannel: 0)
                let peak = recorder.peakPower(forChannel: 0)
                let next = AudioLevelNormalizer.fromMeter(average: average, peak: peak)
                self.audioLevel = next * 0.82 + self.audioLevel * 0.18
            }
        }
    }

    // MARK: - Utilities

    private func tempAudioURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    }

}

extension Notification.Name {
    static let recordingMaxDurationReached = Notification.Name("recordingMaxDurationReached")
}
