import Foundation
import AVFoundation

protocol KeyboardAudioRecorderDelegate: AnyObject {
    func recorderDidFinish(url: URL)
    func recorderDidUpdateLevel(_ level: Float)
    func recorderDidUpdateRemainingSeconds(_ seconds: Int)
    func recorderDidFail(error: String)
}

final class KeyboardAudioRecorder {

    weak var delegate: KeyboardAudioRecorderDelegate?

    private(set) var isRecording = false
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var maxDurationTimer: Timer?
    private var countdownTimer: Timer?
    private var recordingStartedAt: Date?
    private var isFinishing = false

    var maxDurationSec: Int = 60

    private static let wavSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    func startRecording() {
        guard !isRecording && !isFinishing else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            guard session.isInputAvailable else {
                delegate?.recorderDidFail(error: "Audio session has no available input")
                cleanup()
                return
            }
        } catch {
            delegate?.recorderDidFail(error: "Audio session initialization failed: \(error.localizedDescription)")
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        recordingURL = url

        do {
            let recorder = try AVAudioRecorder(url: url, settings: Self.wavSettings)
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                delegate?.recorderDidFail(error: "AVAudioRecorder refused to start")
                cleanup()
                return
            }
            audioRecorder = recorder
            isRecording = true
            recordingStartedAt = Date()
            scheduleMaxDurationTimer()
            scheduleCountdownTimer()
        } catch {
            delegate?.recorderDidFail(error: "AVAudioRecorder start failed: \(error.localizedDescription)")
            cleanup()
        }
    }

    func stopRecording() {
        guard isRecording && !isFinishing else { return }
        isFinishing = true
        isRecording = false
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        recordingStartedAt = nil
        audioRecorder?.stop()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        if let url = recordingURL {
            recordingURL = nil
            DispatchQueue.main.async { [weak self] in
                self?.isFinishing = false
                self?.delegate?.recorderDidFinish(url: url)
            }
        } else {
            isFinishing = false
        }
    }

    func cancelRecording() {
        isRecording = false
        isFinishing = false
        cleanup()
    }

    private func cleanup() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        recordingStartedAt = nil
        audioRecorder?.stop()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let url = recordingURL { try? FileManager.default.removeItem(at: url) }
        recordingURL = nil
    }

    private static func normalizedLevel(fromPower power: Float) -> Float {
        let clamped = max(-60, min(0, power))
        let normalized = (clamped + 60) / 60
        return sqrt(normalized)
    }

    private func scheduleMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(maxDurationSec), repeats: false) { [weak self] _ in
            self?.stopRecording()
        }
    }

    private func scheduleCountdownTimer() {
        countdownTimer?.invalidate()
        delegate?.recorderDidUpdateRemainingSeconds(maxDurationSec)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartedAt, self.isRecording else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            let remaining = max(0, self.maxDurationSec - elapsed)
            self.audioRecorder?.updateMeters()
            if let power = self.audioRecorder?.averagePower(forChannel: 0) {
                self.delegate?.recorderDidUpdateLevel(Self.normalizedLevel(fromPower: power))
            }
            self.delegate?.recorderDidUpdateRemainingSeconds(remaining)
        }
    }

    private var invalidAudioMessage: String {
        MobileStrings.text(
            zh: "音频文件无效",
            en: "Invalid audio file",
            ru: "Некорректный аудиофайл",
            ko: "유효하지 않은 오디오 파일",
            zhHant: "音訊檔無效",
            yue: "音訊檔無效"
        )
    }
}
