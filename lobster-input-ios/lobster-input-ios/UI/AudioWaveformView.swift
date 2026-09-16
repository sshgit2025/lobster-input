import Combine
import SwiftUI

/// 首页录音区音浪（对齐 Mac 浮层 10 柱风格，扩展为更宽展示）
struct LobsterWaveformView: View {

    let level: Float
    let isProcessing: Bool
    var barCount: Int = 20
    var accent: Color = LobsterWaterPalette.accentBrightColor

    @State private var engine = AudioWaveformEngine(barCount: 10)
    @State private var processingPhase = 0
    @State private var timer: Timer?

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: barSpacing(totalWidth: geo.size.width)) {
                ForEach(Array(displayLevels.enumerated()), id: \.offset) { index, barLevel in
                    barView(
                        level: barLevel,
                        index: index,
                        maxHeight: geo.size.height
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear {
            engine = AudioWaveformEngine(barCount: barCount)
            startTimer()
        }
        .onDisappear { stopTimer() }
        .onChange(of: barCount) { _, count in
            engine = AudioWaveformEngine(barCount: count)
        }
        .onChange(of: isProcessing) { _, processing in
            if !processing { engine.reset() }
        }
    }

    private var displayLevels: [Float] {
        engine.levels
    }

    @ViewBuilder
    private func barView(level: Float, index: Int, maxHeight: CGFloat) -> some View {
        if isProcessing {
            let global = index
            let active = global == processingPhase
            let near = global == (processingPhase + barCount - 1) % barCount
            RoundedRectangle(cornerRadius: 3)
                .fill(accent)
                .frame(width: active ? 8 : 6, height: active ? 8 : 6)
                .opacity(active ? 1 : near ? 0.55 : 0.28)
                .animation(.easeInOut(duration: 0.14), value: processingPhase)
        } else {
            let h = max(4, min(maxHeight, 4 + maxHeight * 0.75 * CGFloat(level)))
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 2, height: h)
                .opacity(0.45 + min(0.5, Double(level) * 0.75))
                .animation(.easeOut(duration: 0.08), value: level)
        }
    }

    private func barSpacing(totalWidth: CGFloat) -> CGFloat {
        let bars = CGFloat(barCount)
        let barW: CGFloat = isProcessing ? 8 : 2
        let gaps = max(0, bars - 1)
        guard gaps > 0, totalWidth > bars * barW else { return 2 }
        return max(2, (totalWidth - bars * barW) / gaps)
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            Task { @MainActor in
                if isProcessing {
                    processingPhase = engine.nextProcessingPhase(processingPhase)
                } else {
                    engine.push(inputLevel: level)
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// 键盘会话条（左右各 5 柱，与 Mac 浮层一致）
struct LobsterWaveformSideBars: View {
    let levels: [Float]
    let isProcessing: Bool
    let processingPhase: Int
    let phaseOffset: Int
    var mirrored: Bool = false
    var accent: Color = LobsterWaterPalette.accentBrightColor

    var body: some View {
        ZStack(alignment: .center) {
            ForEach(Array(displayLevels.enumerated()), id: \.offset) { localIndex, barLevel in
                let globalIndex = phaseOffset + localIndex
                let active = isProcessing && globalIndex == processingPhase
                let near = isProcessing && globalIndex == (processingPhase + 9) % 10
                RoundedRectangle(cornerRadius: isProcessing ? 3 : 1)
                    .fill(accent)
                    .frame(
                        width: isProcessing ? (active ? 8 : 6) : 2,
                        height: isProcessing
                            ? (active ? 8 : 6)
                            : max(4, min(16, 4 + 16 * CGFloat(barLevel)))
                    )
                    .opacity(isProcessing ? (active ? 1 : near ? 0.55 : 0.28) : 0.45 + min(0.5, Double(barLevel) * 0.75))
                    .position(x: barX(localIndex, active: active), y: 8)
                    .animation(.easeOut(duration: 0.08), value: barLevel)
            }
        }
        .frame(width: 42, height: 16)
    }

    private var displayLevels: [Float] {
        mirrored ? Array(levels.reversed()) : levels
    }

    private func barX(_ localIndex: Int, active: Bool) -> CGFloat {
        let left: [CGFloat] = [4, 10, 16, 22, 28]
        let right: [CGFloat] = [10, 16, 22, 28, 34]
        let positions = phaseOffset == 0 ? left : right
        let width: CGFloat = isProcessing ? (active ? 8 : 6) : 2
        return positions[localIndex] + width / 2
    }
}
