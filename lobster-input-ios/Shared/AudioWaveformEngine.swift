import Foundation

/// 与 Mac `RecordingOverlayView` / Windows `RecordingOverlay` 一致的滚动音浪采样算法。
final class AudioWaveformEngine {

    private(set) var levels: [Float]
    private let barCount: Int
    private let initialLevel: Float

    init(barCount: Int = 10, initialLevel: Float = 0.08) {
        self.barCount = max(1, barCount)
        self.initialLevel = initialLevel
        self.levels = Array(repeating: initialLevel, count: self.barCount)
    }

    func reset() {
        levels = Array(repeating: initialLevel, count: barCount)
    }

    /// 推入一帧电平（录音态），带轻微随机呼吸感，避免静音时完全静止。
    func push(inputLevel: Float) {
        let input = max(0, min(1, inputLevel))
        let idle = Float.random(in: 0.08...0.20)
        let reactive = input * Float.random(in: 0.72...0.95)
        shift(max(0.05, min(1, max(idle, reactive))))
    }

    func shift(_ value: Float) {
        guard !levels.isEmpty else { return }
        levels.removeFirst()
        levels.append(value)
    }

    /// 处理态点阵相位（0 ..< barCount）
    func nextProcessingPhase(_ phase: Int) -> Int {
        (phase + 1) % barCount
    }
}

enum AudioLevelNormalizer {

    /// AVAudioRecorder 分贝转 0...1
    static func fromMeter(average: Float, peak: Float) -> Float {
        let power = max(average, peak)
        guard power.isFinite, power > -120 else { return 0 }
        let clamped = max(-50, min(0, power))
        let normalized = (clamped + 50) / 50
        return min(1, sqrt(normalized) * 1.12)
    }

    /// 主 App 后台 tap RMS 转 0...1
    static func fromRMS(_ rms: Float) -> Float {
        min(1, max(0, rms * 14))
    }
}
