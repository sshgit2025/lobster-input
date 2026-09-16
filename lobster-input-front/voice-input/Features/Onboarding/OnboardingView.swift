/// OnboardingView.swift
/// 首次登录引导教程视图。
/// 每个功能步骤页内嵌交互区域，用户在教程页内直接完成体验操作。
/// 通过监听 HistoryStore 最新记录的状态来判断操作是否完成。
import SwiftUI
import Combine

// MARK: - Steps

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case permissions
    case transcribeFill      // 语音转文字 → 填入页内输入框
    case rewriteGenerate     // 改写·生成式 → 填入页内输入框
    case rewriteReadonly     // 改写·翻译只读文本 → 弹窗（页内只读示例）
    case rewriteEditable     // 改写·替换输入框内容 → 页内可编辑框
    case screenshotOcr       // 截图提取文字 → 截图上下文 + 改写输入框
    case agentSearch         // Agent·搜索 → Markdown 弹窗
    case complete

    var stepLabel: String {
        switch self {
        case .welcome:          return "1"
        case .permissions:      return "2"
        case .transcribeFill:   return "3"
        case .rewriteGenerate:  return "4"
        case .rewriteReadonly:  return "5"
        case .rewriteEditable:  return "6"
        case .screenshotOcr:    return "7"
        case .agentSearch:      return "8"
        case .complete:         return "✓"
        }
    }
}

// MARK: - Main View

struct OnboardingView: View {

    @ObservedObject var pm = PermissionManager.shared
    @ObservedObject var lang = LanguageManager.shared
    @ObservedObject var historyStore = HistoryStore.shared
    @State var currentStep: OnboardingStep = .welcome
    @State var stepCompleted: Set<Int> = []
    let onFinish: () -> Void

    private var canProceed: Bool {
        switch currentStep {
        case .welcome, .complete:
            return true
        case .permissions:
            return pm.allGranted
        default:
            return stepCompleted.contains(currentStep.rawValue)
        }
    }

    private var isLastStep: Bool { currentStep == .complete }

    /// 是否展示"跳过此步"：试用步骤未完成时可跳过，避免体验失败卡死流程。
    /// 权限页不允许跳过（核心权限缺失会导致后续功能全部不可用）。
    private var canSkip: Bool {
        switch currentStep {
        case .welcome, .permissions, .complete:
            return false
        default:
            return !canProceed
        }
    }

    var body: some View {
        ZStack {
            Cyber.bgTop

            VStack(spacing: 0) {
                stepIndicator
                CyberDivider()
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                CyberDivider()
                navigationBar
            }
        }
        .frame(minWidth: CyberLayout.windowW, minHeight: CyberLayout.windowH)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            pm.refreshStatuses()
            syncSystemPasteSkip()
        }
        .onChange(of: currentStep) { _, _ in
            syncSystemPasteSkip()
        }
        .onDisappear {
            AppHotKeyHandler.shared.skipSystemPaste = false
        }
        .onReceive(historyStore.$records) { records in
            checkLatestRecord(records)
        }
    }

    /// 按当前步骤同步「跳过系统写入」开关。
    /// 只有「页内视图自己订阅 RecordingResultStore 写入输入框」的步骤才跳过，
    /// 避免 TextEditor 被「store 写入 + 系统粘贴」写两次；
    /// 其余步骤必须放行 TextFillEngine：
    /// - rewriteReadonly 依赖「判定为浮窗」的出口，短路则结果永远无处展示；
    /// - rewriteEditable 页内无订阅，依赖真实的 Cmd+V 粘贴覆盖选区完成替换。
    private func syncSystemPasteSkip() {
        let storeDrivenSteps: Set<OnboardingStep> = [
            .transcribeFill, .rewriteGenerate, .screenshotOcr,
        ]
        AppHotKeyHandler.shared.skipSystemPaste = storeDrivenSteps.contains(currentStep)
    }

    /// 监听历史记录变化，判断当前步骤是否完成
    private func checkLatestRecord(_ records: [RecordingHistory]) {
        guard let latest = records.first, latest.status == .success else { return }
        let alreadyDone = stepCompleted.contains(currentStep.rawValue)
        if alreadyDone { return }

        switch currentStep {
        case .transcribeFill:
            if latest.operation == "transcribe" {
                markCurrentDone()
            }
        case .rewriteGenerate:
            if latest.operation == "rewrite" && (latest.selectedText ?? "").isEmpty {
                markCurrentDone()
            }
        case .rewriteReadonly:
            if latest.operation == "rewrite" && !(latest.selectedText ?? "").isEmpty {
                markCurrentDone()
            }
        case .rewriteEditable:
            if latest.operation == "rewrite" && !(latest.selectedText ?? "").isEmpty
                && latest.actionType == "paste" {
                markCurrentDone()
            }
        case .screenshotOcr:
            if latest.operation == "rewrite" {
                markCurrentDone()
            }
        case .agentSearch:
            // 双检测：旧机制按操作类型识别（用户用 Agent 快捷键发起搜索）；
            // 新机制按后端返回的 actionType 识别（联网搜索结果以 Markdown 弹窗展示）。
            // 任一命中即认为本步骤完成，避免旧机制单一判断不全面导致漏判。
            if latest.operation == "agent" || latest.actionType == "show_markdown" {
                markCurrentDone()
            }
        default:
            break
        }
    }

    private func markCurrentDone() {
        _ = withAnimation(.easeOut(duration: 0.3)) {
            stepCompleted.insert(currentStep.rawValue)
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 4) {
                    if step.rawValue > 0 {
                        Rectangle()
                            .fill(step.rawValue <= currentStep.rawValue
                                  ? Cyber.accent.opacity(0.35)
                                  : Cyber.borderDim)
                            .frame(height: 1)
                    }
                    stepDot(for: step)
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 16)
    }

    private func stepDot(for step: OnboardingStep) -> some View {
        let isDone = step.rawValue < currentStep.rawValue
        let isCurrent = step == currentStep
        return ZStack {
            Circle()
                .fill(isDone || isCurrent ? Cyber.accentSoft : Cyber.panelBg)
                .frame(width: 26, height: 26)
            Circle()
                .stroke(isDone ? Cyber.success.opacity(0.5) :
                            isCurrent ? Cyber.accent.opacity(0.6) : Cyber.borderDim,
                        lineWidth: 1)
                .frame(width: 26, height: 26)
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Cyber.success)
            } else {
                Text(step.stepLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isCurrent ? Cyber.accent : Cyber.textGhost)
            }
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        ScrollView {
            Group {
                switch currentStep {
                case .welcome:          welcomeStep
                case .permissions:      permissionsStep
                case .transcribeFill:   transcribeFillStep
                case .rewriteGenerate:  rewriteGenerateStep
                case .rewriteReadonly:  rewriteReadonlyStep
                case .rewriteEditable:  rewriteEditableStep
                case .screenshotOcr:    screenshotOcrStep
                case .agentSearch:      agentSearchStep
                case .complete:         completeStep
                }
            }
            .frame(maxWidth: CyberLayout.readingMaxW)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 50)
            .padding(.vertical, 28)
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack {
            if currentStep != .welcome {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { goBack() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text(L10n.onboardingBack)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Cyber.textDim)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if canSkip {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { skipCurrent() }
                } label: {
                    Text(L10n.onboardingSkip)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Cyber.textDim)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
            }

            if isLastStep {
                Button {
                    OnboardingManager.shared.markCompleted()
                    onFinish()
                } label: {
                    HStack(spacing: 8) {
                        Text(L10n.onboardingStart)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                navNextButton
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 14)
    }

    private var navNextButton: some View {
        let isPermStep = currentStep == .permissions && !canProceed
        let isTrialStep = !canProceed && currentStep.rawValue >= OnboardingStep.transcribeFill.rawValue
        let label = isPermStep ? L10n.onboardingGrantFirst
            : isTrialStep ? L10n.onboardingTryFirst
            : L10n.onboardingNext

        let btn = Button {
            withAnimation(.easeInOut(duration: 0.3)) { goNext() }
        } label: {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 13, weight: .medium))
                if canProceed {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
            }
        }
        .disabled(!canProceed)

        return Group {
            if canProceed {
                btn.buttonStyle(PrimaryButtonStyle())
            } else {
                btn.buttonStyle(NeonButtonStyle(color: Cyber.textGhost))
            }
        }
    }

    private func goNext() {
        guard canProceed, let next = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    /// 跳过当前步骤：不要求完成条件，直接前进。
    private func skipCurrent() {
        guard let next = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    private func goBack() {
        guard let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    // MARK: - Shared: Completion Badge

    func completionBadge(_ done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 14))
            Text(done ? L10n.onboardingStepDone : L10n.onboardingStepWaiting)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(done ? Cyber.success : Cyber.warning)
        .padding(.vertical, 6)
    }

    var isDone: Bool { stepCompleted.contains(currentStep.rawValue) }
}
