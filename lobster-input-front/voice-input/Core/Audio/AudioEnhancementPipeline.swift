import AVFoundation
import Foundation

struct AudioEnhancementMetrics {
    var originalRMS: Float
    var originalPeak: Float
    var enhancedRMS: Float
    var enhancedPeak: Float
    var appliedGain: Float

    var displayLevel: Float {
        Self.displayLevel(forRMS: max(originalRMS, enhancedRMS))
    }

    static let empty = AudioEnhancementMetrics(
        originalRMS: 0,
        originalPeak: 0,
        enhancedRMS: 0,
        enhancedPeak: 0,
        appliedGain: 1
    )

    static func displayLevel(forRMS rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 50) / 50))
        return rms >= 0.0012 ? max(0.03, normalized) : normalized
    }
}

protocol AudioEnhancementStrategy: AnyObject {
    var identifier: String { get }

    func process(_ buffer: AVAudioPCMBuffer, metrics: inout AudioEnhancementMetrics)
}

final class AudioEnhancementPipeline {
    private let strategies: [AudioEnhancementStrategy]
    private var processedBuffers = 0
    private var maxOriginalRMS: Float = 0
    private var maxEnhancedRMS: Float = 0
    private var maxAppliedGain: Float = 1

    init(strategies: [AudioEnhancementStrategy]) {
        self.strategies = strategies
    }

    static func voiceInputDefault() -> AudioEnhancementPipeline {
        AudioEnhancementPipeline(strategies: [
            DCOffsetRemovalStrategy(),
            SpeechClarityStrategy(),
            AdaptiveGainStrategy(),
            PeakLimiterStrategy(),
        ])
    }

    func process(_ buffer: AVAudioPCMBuffer) -> AudioEnhancementMetrics {
        guard let channel = buffer.floatChannelData?[0] else { return .empty }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return .empty }

        let initial = Self.measure(channel: channel, frameCount: frameCount)
        var metrics = AudioEnhancementMetrics(
            originalRMS: initial.rms,
            originalPeak: initial.peak,
            enhancedRMS: initial.rms,
            enhancedPeak: initial.peak,
            appliedGain: 1
        )

        for strategy in strategies {
            strategy.process(buffer, metrics: &metrics)
        }

        let final = Self.measure(channel: channel, frameCount: frameCount)
        metrics.enhancedRMS = final.rms
        metrics.enhancedPeak = final.peak
        updateSummary(metrics)
        return metrics
    }

    func signalSummary() -> String {
        "buffers=\(processedBuffers), rawRMS=\(maxOriginalRMS), enhancedRMS=\(maxEnhancedRMS), gain=\(maxAppliedGain)"
    }

    private func updateSummary(_ metrics: AudioEnhancementMetrics) {
        processedBuffers += 1
        maxOriginalRMS = max(maxOriginalRMS, metrics.originalRMS)
        maxEnhancedRMS = max(maxEnhancedRMS, metrics.enhancedRMS)
        maxAppliedGain = max(maxAppliedGain, metrics.appliedGain)
    }

    fileprivate static func measure(channel: UnsafeMutablePointer<Float>, frameCount: Int) -> (rms: Float, peak: Float) {
        var sum: Float = 0
        var peak: Float = 0

        for index in 0..<frameCount {
            let sample = channel[index]
            sum += sample * sample
            peak = max(peak, abs(sample))
        }

        return (sqrt(sum / Float(frameCount)), peak)
    }
}

final class DCOffsetRemovalStrategy: AudioEnhancementStrategy {
    let identifier = "dc-offset-removal"

    private var estimate: Float = 0
    private let smoothing: Float = 0.995

    func process(_ buffer: AVAudioPCMBuffer, metrics: inout AudioEnhancementMetrics) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        for index in 0..<frameCount {
            estimate = smoothing * estimate + (1 - smoothing) * channel[index]
            channel[index] -= estimate
        }
    }
}

final class SpeechClarityStrategy: AudioEnhancementStrategy {
    let identifier = "speech-clarity"

    private let preEmphasis: Float = 0.12
    private var previousSample: Float = 0

    func process(_ buffer: AVAudioPCMBuffer, metrics: inout AudioEnhancementMetrics) {
        guard metrics.originalRMS >= 0.0012 else { return }
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        for index in 0..<frameCount {
            let sample = channel[index]
            channel[index] = sample - preEmphasis * previousSample
            previousSample = sample
        }
    }
}

final class AdaptiveGainStrategy: AudioEnhancementStrategy {
    let identifier = "adaptive-gain"

    private let targetRMS: Float = 0.08
    private let noiseFloorRMS: Float = 0.0012
    private let maxGain: Float = 8
    private let attack: Float = 0.35
    private let release: Float = 0.08
    private var smoothedGain: Float = 1

    func process(_ buffer: AVAudioPCMBuffer, metrics: inout AudioEnhancementMetrics) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let desiredGain = gain(forRMS: metrics.originalRMS)
        let smoothing = desiredGain > smoothedGain ? attack : release
        smoothedGain += (desiredGain - smoothedGain) * smoothing
        smoothedGain = max(1, min(maxGain, smoothedGain))
        metrics.appliedGain = smoothedGain

        guard smoothedGain > 1.01 else { return }
        for index in 0..<frameCount {
            channel[index] *= smoothedGain
        }
    }

    private func gain(forRMS rms: Float) -> Float {
        guard rms >= noiseFloorRMS else { return 1 }
        guard rms < targetRMS else { return 1 }
        return max(1, min(maxGain, targetRMS / max(rms, noiseFloorRMS)))
    }
}

final class PeakLimiterStrategy: AudioEnhancementStrategy {
    let identifier = "peak-limiter"

    private let ceiling: Float = 0.96

    func process(_ buffer: AVAudioPCMBuffer, metrics: inout AudioEnhancementMetrics) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let measured = AudioEnhancementPipeline.measure(channel: channel, frameCount: frameCount)
        guard measured.peak > ceiling else { return }

        let scale = ceiling / measured.peak
        for index in 0..<frameCount {
            channel[index] *= scale
        }
        metrics.appliedGain *= scale
    }
}
