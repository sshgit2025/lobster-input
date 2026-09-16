import Combine
import SwiftUI

struct HomeView: View {

    @StateObject private var recorder = AudioRecorder.shared
    @StateObject private var resultStore = RecordingResultStore.shared
    @StateObject private var authStore = AuthStore.shared
    @StateObject private var historyStore = HistoryStore.shared

    @State private var isRewriteMode = false
    @State private var showCopiedToast = false
    @State private var processingRecordId: String?
    @State private var activeKeyboardRequest: KeyboardRecordingRequest?
    @State private var keyboardRequestCompleted = false

    private var isIdle: Bool { recorder.state == .idle }
    private var isRecording: Bool { recorder.state == .recording }
    private var isProcessing: Bool { recorder.state == .processing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if activeKeyboardRequest != nil {
                        keyboardSessionSection
                    } else {
                        resultSection
                        quickGuideSection
                        recordingSection
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .background(LobsterWaterPalette.panelColor.ignoresSafeArea())
            .navigationTitle(L10n.homeTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { activateKeyboardRequestIfNeeded() }
        .onOpenURL { url in
            if url.scheme == "lobster-input", url.host == "record" {
                activateKeyboardRequestIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingMaxDurationReached)) { _ in
            Task { await stopAndProcess() }
        }
    }

    // MARK: - Result Section

    @ViewBuilder
    private var resultSection: some View {
        VStack(spacing: 12) {
            if activeKeyboardRequest != nil {
                keyboardRequestBanner
            }

            if let error = resultStore.errorMessage {
                errorBanner(error)
            }

            if !resultStore.result.isEmpty {
                resultCard
            } else {
                emptyResultPlaceholder
            }
        }
        .padding(.top, 16)
    }

    private var keyboardRequestBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: keyboardRequestCompleted ? "checkmark.circle.fill" : "keyboard.badge.ellipsis")
                .foregroundStyle(keyboardRequestCompleted ? LobsterWaterPalette.successColor : LobsterWaterPalette.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(MobileStrings.appKeyboardRequestTitle())
                    .font(.subheadline.weight(.semibold))
                Text(MobileStrings.appKeyboardRequestHint())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(LobsterWaterPalette.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !resultStore.transcript.isEmpty && resultStore.transcript != resultStore.result {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.homeTranscript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(resultStore.transcript)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(resultStore.result)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = resultStore.result
                    showCopiedToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopiedToast = false
                    }
                } label: {
                    Label(showCopiedToast ? L10n.btnCopied : L10n.btnCopy,
                          systemImage: showCopiedToast ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                }
                .tint(showCopiedToast ? LobsterWaterPalette.successColor : LobsterWaterPalette.accentColor)

                Button {
                    isRewriteMode = true
                } label: {
                    Label(L10n.homeRewrite, systemImage: "mic.badge.plus")
                        .font(.subheadline)
                }
                .tint(LobsterWaterPalette.accentColor)

                Spacer()

                Button {
                    resultStore.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LobsterWaterPalette.tertiaryColor)
                }
            }
        }
        .lobsterCard()
    }

    private var emptyResultPlaceholder: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LobsterWaterPalette.accentColor.opacity(0.10))
                    .frame(width: 72, height: 72)
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(LobsterWaterPalette.accentGradient)
            }
            Text(L10n.homeResultPlaceholder)
                .font(.headline.weight(.semibold))
                .foregroundStyle(LobsterWaterPalette.textColor)
            Text(MobileStrings.text(zh: "在键盘里切换到龙虾输入法，或在这里测试语音转写。", en: "Switch to Lobster in the keyboard, or test voice transcription here.", ru: "Выберите Lobster на клавиатуре или проверьте диктовку здесь.", ko: "키보드에서 랍스터로 전환하거나 여기에서 음성 전사를 테스트하세요."))
                .font(.subheadline)
                .foregroundStyle(LobsterWaterPalette.mutedColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .lobsterCard(padding: 0)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LobsterWaterPalette.dangerColor)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(LobsterWaterPalette.dangerColor)
            Spacer()
        }
        .padding(12)
        .background(LobsterWaterPalette.dangerColor.opacity(0.10), in: RoundedRectangle(cornerRadius: LobsterMetrics.radiusButton, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LobsterMetrics.radiusButton, style: .continuous)
                .strokeBorder(LobsterWaterPalette.dangerColor.opacity(0.22), lineWidth: 1)
        )
    }

    private var keyboardSessionSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: keyboardRequestCompleted ? "checkmark.circle.fill" : "keyboard")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(keyboardRequestCompleted ? LobsterWaterPalette.successColor : keyboardAccent)

                VStack(alignment: .leading, spacing: 3) {
                    Text(MobileStrings.appKeyboardRequestTitle())
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(keyboardText)
                    Text(keyboardOperationTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(keyboardMuted)
                }

                Spacer()
            }

            KeyboardSessionRecordButton(
                isRecording: isRecording,
                isProcessing: isProcessing,
                isCompleted: keyboardRequestCompleted && resultStore.errorMessage == nil && !resultStore.result.isEmpty,
                level: recorder.audioLevel,
                countdown: recorder.countdown
            ) {
                Task { await toggleRecording() }
            }

            Text(keyboardSessionStatus)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(keyboardSessionStatusColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let error = resultStore.errorMessage {
                keyboardInlineMessage(error, systemImage: "exclamationmark.triangle.fill", color: LobsterWaterPalette.dangerColor)
            }

            if !resultStore.result.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if !resultStore.transcript.isEmpty && resultStore.transcript != resultStore.result {
                        Text(resultStore.transcript)
                            .font(.caption)
                            .foregroundStyle(keyboardMuted)
                            .lineLimit(3)
                    }

                    Text(resultStore.result)
                        .font(.body.weight(.medium))
                        .foregroundStyle(keyboardText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                        Text(MobileStrings.appKeyboardRequestHint())
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(keyboardMuted)
                }
                .padding(14)
                .background(keyboardSurface, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(keyboardPanel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(keyboardAccent.opacity(0.16), lineWidth: 1)
        )
        .padding(.top, 16)
    }

    private func keyboardInlineMessage(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var keyboardOperationTitle: String {
        guard let operation = activeKeyboardRequest?.operation else {
            return MobileStrings.text(zh: "语音输入", en: "Voice input", ru: "Голосовой ввод", ko: "음성 입력")
        }
        switch operation {
        case .transcribe:
            return MobileStrings.text(zh: "语音输入", en: "Voice input", ru: "Голосовой ввод", ko: "음성 입력")
        case .rewrite:
            return MobileStrings.text(zh: "语音改写", en: "Voice rewrite", ru: "Голосовая правка", ko: "음성 수정")
        }
    }

    private var keyboardSessionStatus: String {
        if isProcessing {
            return MobileStrings.text(zh: "正在识别", en: "Recognizing", ru: "Распознаем", ko: "인식 중")
        }
        if isRecording {
            return MobileStrings.text(zh: "点击麦克风停止", en: "Tap the microphone to stop", ru: "Нажмите микрофон, чтобы остановить", ko: "마이크를 눌러 중지")
        }
        if keyboardRequestCompleted && resultStore.errorMessage != nil {
            return MobileStrings.text(zh: "点击麦克风重试", en: "Tap the microphone to retry", ru: "Нажмите микрофон, чтобы повторить", ko: "마이크를 눌러 재시도")
        }
        if keyboardRequestCompleted {
            return MobileStrings.text(zh: "已完成，返回刚才的输入框会自动插入", en: "Done. Return to the previous field to insert.", ru: "Готово. Вернитесь в поле ввода.", ko: "완료. 이전 입력창으로 돌아가면 입력됩니다.")
        }
        return MobileStrings.text(zh: "点击麦克风开始", en: "Tap the microphone to start", ru: "Нажмите микрофон, чтобы начать", ko: "마이크를 눌러 시작")
    }

    private var keyboardSessionStatusColor: Color {
        if isRecording { return keyboardAccent }
        if isProcessing { return LobsterWaterPalette.accentBrightColor }
        if keyboardRequestCompleted { return LobsterWaterPalette.successColor }
        return keyboardMuted
    }

    private var keyboardPanel: Color { LobsterWaterPalette.panelColor }
    private var keyboardSurface: Color { LobsterWaterPalette.surfaceColor }
    private var keyboardAccent: Color { LobsterWaterPalette.accentColor }
    private var keyboardText: Color { LobsterWaterPalette.textColor }
    private var keyboardMuted: Color { LobsterWaterPalette.mutedColor }

    private var quickGuideSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(MobileStrings.text(zh: "手机端使用方式", en: "How to use on mobile", ru: "Как использовать на телефоне", ko: "모바일 사용 방법"), systemImage: "keyboard")
                .font(.headline.weight(.semibold))
                .foregroundStyle(LobsterWaterPalette.textColor)
            guideRow("1", MobileStrings.text(zh: "在设置页添加并启用龙虾输入法", en: "Add and enable Lobster from Settings", ru: "Добавьте и включите Lobster в настройках", ko: "설정에서 랍스터 입력기를 추가하고 켜세요"))
            guideRow("2", MobileStrings.text(zh: "在输入框中通过地球键切换到龙虾输入法", en: "Use the globe key in a text field to switch", ru: "В поле ввода выберите Lobster через глобус", ko: "입력창에서 지구본 키로 전환하세요"))
            guideRow("3", MobileStrings.text(zh: "使用语音转写，或对已输入内容进行语音改写", en: "Transcribe by voice or rewrite existing text", ru: "Диктуйте или правьте текст голосом", ko: "음성 전사 또는 기존 텍스트 수정을 사용하세요"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lobsterCard()
    }

    private func guideRow(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(index)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(LobsterWaterPalette.accentGradient, in: Circle())
            Text(text)
                .font(.subheadline)
                .foregroundStyle(LobsterWaterPalette.mutedColor)
            Spacer()
        }
    }

    // MARK: - Recording Section

    private var recordingSection: some View {
        VStack(spacing: 16) {
            if isRewriteMode && isIdle {
                HStack {
                    Text(L10n.homeRewriteHint)
                        .font(.caption)
                        .foregroundStyle(LobsterWaterPalette.accentBrightColor)
                    Spacer()
                    Button(L10n.btnCancel) { isRewriteMode = false }
                        .font(.caption)
                        .tint(.secondary)
                }
            }

            statusLabel

            if isRecording || isProcessing {
                LobsterWaveformView(
                    level: recorder.audioLevel,
                    isProcessing: isProcessing,
                    barCount: 20,
                    accent: LobsterWaterPalette.accentBrightColor
                )
                .frame(height: 36)
            }

            recordButton

            if let sec = recorder.countdown, isRecording {
                Text("\(sec)s")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(LobsterWaterPalette.dangerColor)
                    .contentTransition(.numericText())
                    .animation(.easeInOut, value: sec)
            }
        }
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.subheadline)
            .foregroundStyle(statusColor)
            .animation(.easeInOut, value: recorder.state)
    }

    private var statusText: String {
        if isProcessing { return L10n.homeRecognizing }
        if isRecording { return L10n.homeRecording }
        if activeKeyboardRequest != nil && keyboardRequestCompleted { return MobileStrings.appKeyboardRequestHint() }
        if isRewriteMode { return L10n.homeRewrite }
        return L10n.homeReady
    }

    private var statusColor: Color {
        if isProcessing { return LobsterWaterPalette.accentBrightColor }
        if isRecording { return LobsterWaterPalette.dangerColor }
        if isRewriteMode { return LobsterWaterPalette.accentColor }
        return LobsterWaterPalette.mutedColor
    }

    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            ZStack {
                Circle()
                    .fill(recordButtonColor)
                    .frame(width: 80, height: 80)
                    .shadow(color: recordButtonColor.opacity(0.4), radius: isRecording ? 12 : 6)

                if isProcessing {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .disabled(isProcessing)
        .scaleEffect(isRecording ? 1.1 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }

    private var recordButtonColor: Color {
        if isProcessing { return LobsterWaterPalette.mutedColor }
        if isRecording { return LobsterWaterPalette.dangerColor }
        if isRewriteMode { return LobsterWaterPalette.accentColor }
        return LobsterWaterPalette.orbBottomColor
    }

    // MARK: - Logic

    private func toggleRecording() async {
        switch recorder.state {
        case .idle:
            if authStore.creditsTotal > 0 && authStore.creditsRemaining <= 0 {
                resultStore.update(transcript: "", result: "", error: L10n.errorCreditsExhausted)
                return
            }
            if activeKeyboardRequest != nil {
                keyboardRequestCompleted = false
                resultStore.clear()
            }
            let success = await recorder.startRecording()
            if !success {
                let error = L10n.errorMicPermission
                resultStore.update(transcript: "", result: "", error: error)
                if let activeKeyboardRequest {
                    KeyboardRecordingBridge.complete(
                        request: activeKeyboardRequest,
                        transcript: "",
                        result: "",
                        actionType: nil,
                        error: error
                    )
                    keyboardRequestCompleted = true
                }
            }
        case .recording:
            await stopAndProcess()
        case .processing:
            break
        }
    }

    private func activateKeyboardRequestIfNeeded() {
        guard let request = KeyboardRecordingBridge.currentRequest() else { return }
        guard activeKeyboardRequest?.id != request.id else { return }
        activeKeyboardRequest = request
        keyboardRequestCompleted = false
        isRewriteMode = request.operation == .rewrite
        resultStore.clear()

        guard recorder.state == .idle else { return }
        Task { await startKeyboardRequestRecording(request) }
    }

    private func startKeyboardRequestRecording(_ request: KeyboardRecordingRequest) async {
        if authStore.creditsTotal > 0 && authStore.creditsRemaining <= 0 {
            let error = L10n.errorCreditsExhausted
            resultStore.update(transcript: "", result: "", error: error)
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: "",
                result: "",
                actionType: nil,
                error: error
            )
            keyboardRequestCompleted = true
            return
        }

        let success = await recorder.startRecording()
        if !success {
            let error = L10n.errorMicPermission
            resultStore.update(transcript: "", result: "", error: error)
            KeyboardRecordingBridge.complete(
                request: request,
                transcript: "",
                result: "",
                actionType: nil,
                error: error
            )
            keyboardRequestCompleted = true
        }
    }

    private func stopAndProcess() async {
        guard let audioURL = await recorder.stopRecording() else {
            recorder.resetToIdle()
            return
        }

        let keyboardRequest = activeKeyboardRequest
        let operation = keyboardRequest?.operation.rawValue ?? (isRewriteMode ? "rewrite" : "transcribe")
        let selectedText = keyboardRequest?.selectedText ?? (isRewriteMode ? resultStore.result : nil)

        let persistedPath = historyStore.persistAudio(from: audioURL)
        var record = RecordingHistory(operation: operation, audioFilePath: persistedPath, selectedText: selectedText)
        record.status = .processing
        historyStore.add(record)
        processingRecordId = record.id

        try? FileManager.default.removeItem(at: audioURL)

        do {
            let fileURL: URL
            if let path = persistedPath {
                fileURL = URL(fileURLWithPath: path)
            } else {
                throw APIError.networkError(URLError(.fileDoesNotExist))
            }

            let response = try await APIClient.shared.processAudio(
                fileURL: fileURL,
                operation: operation,
                selectedText: selectedText,
                clipboardHistory: keyboardRequest?.context,
                fastMode: keyboardRequest?.fastMode ?? false
            )

            historyStore.update(
                id: record.id, status: .success,
                transcript: response.transcript,
                result: response.result,
                actionType: response.actionType.rawValue
            )

            resultStore.update(
                transcript: response.transcript,
                result: response.result,
                error: nil
            )

            if let keyboardRequest {
                KeyboardRecordingBridge.complete(
                    request: keyboardRequest,
                    transcript: response.transcript,
                    result: response.result,
                    actionType: response.actionType.rawValue,
                    error: nil
                )
                keyboardRequestCompleted = true
            }

            if let remaining = response.creditsRemaining {
                authStore.creditsRemaining = remaining
            }

            if let update = response.configUpdate, let newMax = update.maxDurationSec {
                recorder.maxDuration = TimeInterval(newMax)
            }

            isRewriteMode = false

        } catch {
            let apiError = error as? APIError
            if case .unauthorized = apiError {
                authStore.logout()
            }
            let msg = apiError?.errorDescription ?? error.localizedDescription
            historyStore.update(id: record.id, status: .failed, error: msg)
            resultStore.update(transcript: "", result: "", error: msg)
            if let keyboardRequest {
                KeyboardRecordingBridge.complete(
                    request: keyboardRequest,
                    transcript: "",
                    result: "",
                    actionType: nil,
                    error: msg
                )
                keyboardRequestCompleted = true
            }
        }

        processingRecordId = nil
        recorder.resetToIdle()
    }
}

private struct KeyboardSessionRecordButton: View {
    let isRecording: Bool
    let isProcessing: Bool
    let isCompleted: Bool
    let level: Float
    let countdown: Int?
    let action: () -> Void

    private let accent = LobsterWaterPalette.accentColor
    private let text = LobsterWaterPalette.textColor

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                KeyboardSessionBars(level: level, active: isRecording, processing: isProcessing, mirrored: false, phaseOffset: 0)
                    .frame(width: 48, height: 24)

                ZStack {
                    if isProcessing {
                        ProgressView()
                            .tint(accent)
                            .scaleEffect(1.05)
                    } else {
                        Image(systemName: iconName)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(isCompleted ? LobsterWaterPalette.successColor : .white)
                    }
                }
                .frame(width: 34, height: 34)

                KeyboardSessionBars(level: level, active: isRecording, processing: isProcessing, mirrored: true, phaseOffset: 5)
                    .frame(width: 48, height: 24)
            }
            .padding(.horizontal, 18)
            .frame(height: 68)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [LobsterWaterPalette.orbTopColor, LobsterWaterPalette.orbBottomColor],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: LobsterWaterPalette.accentColor.opacity(isRecording ? 0.35 : 0.18), radius: isRecording ? 18 : 10, y: 5)
            )
            .overlay(
                Capsule()
                    .stroke((isRecording ? accent : accent.opacity(0.25)), lineWidth: isRecording ? 1.4 : 1)
            )
            .overlay(alignment: .bottom) {
                if let countdown, isRecording {
                    Text("\(countdown)s")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                        .padding(.bottom, 5)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isProcessing || isCompleted)
        .opacity(isProcessing ? 0.82 : 1)
        .scaleEffect(isRecording ? 1.03 : 1)
        .animation(.easeInOut(duration: 0.18), value: isRecording)
        .animation(.easeInOut(duration: 0.18), value: isProcessing)
        .animation(.easeInOut(duration: 0.18), value: isCompleted)
        .accessibilityLabel(accessibilityTitle)
    }

    private var iconName: String {
        if isCompleted { return "checkmark" }
        if isRecording { return "stop.fill" }
        return "mic.fill"
    }

    private var accessibilityTitle: String {
        if isProcessing { return L10n.homeRecognizing }
        if isRecording { return L10n.homeRecordStop }
        return L10n.homeRecordStart
    }
}

private struct KeyboardSessionBars: View {
    let level: Float
    let active: Bool
    let processing: Bool
    let mirrored: Bool
    var phaseOffset: Int = 0

    @State private var engine = AudioWaveformEngine(barCount: 5)
    @State private var processingPhase = 0
    @State private var timer: Timer?

    var body: some View {
        LobsterWaveformSideBars(
            levels: engine.levels,
            isProcessing: processing,
            processingPhase: processingPhase,
            phaseOffset: phaseOffset,
            mirrored: mirrored
        )
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: processing) { _, isProc in
            if !isProc { engine.reset() }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            Task { @MainActor in
                if processing {
                    processingPhase = engine.nextProcessingPhase(processingPhase)
                } else if active {
                    engine.push(inputLevel: level)
                } else {
                    engine.push(inputLevel: 0)
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
