/// OnboardingSteps.swift
/// 引导教程各步骤的具体内容视图。
/// 功能体验步骤均内嵌交互区（输入框/只读示例文本），用户无需离开教程页即可完成体验。
import SwiftUI
import Combine

// MARK: - Step 0: Welcome

extension OnboardingView {

    var welcomeStep: some View {
        VStack(spacing: 28) {
            Spacer().frame(height: 12)
            ZStack {
                Image("LobsterClaw")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 92, height: 92)
                    .shadow(color: Color.black.opacity(0.12), radius: 14)
            }
            VStack(spacing: 10) {
                Text(L10n.onboardingWelcomeTitle)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.onboardingWelcomeDesc)
                    .font(.system(size: 15)).foregroundStyle(Cyber.textDim)
                    .multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 480)
            }
            VStack(spacing: 12) {
                welcomeFeature(icon: "mic.fill", color: Cyber.accent,
                               title: L10n.onboardingFeature1Title, desc: L10n.onboardingFeature1Desc)
                welcomeFeature(icon: "pencil.and.outline", color: Cyber.accent,
                               title: L10n.onboardingFeature2Title, desc: L10n.onboardingFeature2Desc)
                welcomeFeature(icon: "brain.head.profile", color: Cyber.warning,
                               title: L10n.onboardingFeature3Title, desc: L10n.onboardingFeature3Desc)
            }
            .padding(20).neonCard(Cyber.borderDim, glow: 6).frame(maxWidth: 500)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func welcomeFeature(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.3), lineWidth: 0.8))
                .shadow(color: color.opacity(0.3), radius: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Cyber.textBright)
                Text(desc).font(.system(size: 12)).foregroundStyle(Cyber.textDim)
            }
            Spacer()
        }
    }
}

// MARK: - Step 1: Permissions

extension OnboardingView {

    var permissionsStep: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 6)
            Image(systemName: "lock.shield").font(.system(size: 40, weight: .medium))
                .foregroundStyle(pm.allGranted ? Cyber.accent : Cyber.warning)
                .frame(width: 72, height: 72)
                .background((pm.allGranted ? Cyber.accent : Cyber.warning).opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke((pm.allGranted ? Cyber.accent : Cyber.warning).opacity(0.22), lineWidth: 1))
            VStack(spacing: 8) {
                Text(L10n.onboardingPermTitle).font(.system(size: 20, weight: .semibold)).foregroundStyle(Cyber.textBright)
                Text(L10n.onboardingPermDesc).font(.system(size: 14)).foregroundStyle(Cyber.textDim)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            VStack(spacing: 0) {
                permRow(icon: "mic", iconColor: Cyber.warning,
                        title: L10n.permMicrophone, desc: L10n.onboardingPermMicDesc,
                        status: pm.microphoneStatus) {
                    if pm.microphoneStatus == .notDetermined { Task { await pm.requestMicrophone() } }
                    else { pm.openMicrophoneSettings() }
                }
                CyberDivider(color: Cyber.dividerCol).padding(.leading, 54)
                permRow(icon: "figure.wave", iconColor: Cyber.accent,
                        title: L10n.permAccessibility, desc: L10n.onboardingPermAXDesc,
                        status: pm.accessibilityStatus) {
                    pm.requestAccessibilityIfNeeded()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pm.openAccessibilitySettings() }
                }
                CyberDivider(color: Cyber.dividerCol).padding(.leading, 54)
                permRow(icon: "camera.viewfinder", iconColor: Cyber.accent,
                        title: "\(L10n.permScreenCapture) · \(L10n.permissionOptional)",
                        desc: L10n.permScreenCaptureDesc,
                        status: pm.screenCaptureStatus) {
                    if !pm.requestScreenCaptureIfNeeded() {
                        pm.openScreenCaptureSettings()
                    }
                }
            }
            .neonCard(Cyber.borderDim, glow: 6).frame(maxWidth: 500)

            if pm.allGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 15))
                    Text(L10n.onboardingPermAllDone).font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Cyber.accent).shadow(color: Cyber.accent.opacity(0.4), radius: 4)
            } else {
                Button { pm.refreshStatuses() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        Text(L10n.onboardingPermRefresh).font(.system(size: 12, weight: .medium))
                    }.foregroundStyle(Cyber.textDim)
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func permRow(icon: String, iconColor: Color, title: String, desc: String,
                         status: PermissionStatus, onAuth: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(iconColor)
                    .frame(width: 34, height: 34)
                    .background(iconColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(iconColor.opacity(0.3), lineWidth: 0.8))
                Group {
                    if status == .granted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Cyber.accent)
                    } else {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, Cyber.warning)
                    }
                }.font(.system(size: 10)).offset(x: 3, y: 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Cyber.textBright)
                Text(desc).font(.system(size: 11)).foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            if status == .granted {
                Text(L10n.statusOk).font(.system(size: 11, weight: .medium)).foregroundStyle(Cyber.accent)
            } else {
                Button(L10n.permGoAuth) { onAuth() }.buttonStyle(NeonButtonStyle(color: iconColor))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

// MARK: - Step 2: Transcribe Fill
// 内嵌输入框：用户将光标点入输入框后触发快捷键，识别结果自动填入

extension OnboardingView {
    var transcribeFillStep: some View {
        TrialTranscribeView(isDone: isDone, completionBadge: completionBadge)
    }
}

struct TrialTranscribeView: View {
    let isDone: Bool
    let completionBadge: (Bool) -> AnyView
    @State private var fieldText: String = ""
    @FocusState private var isFocused: Bool
    @ObservedObject private var lang = LanguageManager.shared

    init(isDone: Bool, completionBadge: @escaping (Bool) -> some View) {
        self.isDone = isDone
        self.completionBadge = { done in AnyView(completionBadge(done)) }
    }

    var body: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "mic.fill", color: Cyber.accent,
                       title: L10n.obTriFillTitle, subtitle: L10n.obTriFillSub,
                       hotkey: HotKeyManager.shared.configs[.transcribe]?.displayString ?? L10n.hotkeyNotSet,
                       hotkeyColor: Cyber.accent)

            // 内嵌输入框体验区
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "text.cursor").font(.system(size: 11))
                        .foregroundStyle(Cyber.accent.opacity(0.7))
                    Text(L10n.obTriFillFieldLabel).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cyber.textDim)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $fieldText)
                        .font(.system(size: 14))
                        .foregroundStyle(Cyber.textBright)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 80)
                        .focused($isFocused)
                    if fieldText.isEmpty {
                        Text(L10n.obTriFillPlaceholder)
                            .font(.system(size: 14))
                            .foregroundStyle(Cyber.textGhost.opacity(0.5))
                            .padding(.top, 8).padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
                .padding(12)
                .background(Cyber.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? Cyber.accent.opacity(0.5) : Cyber.borderDim, lineWidth: 1)
                )
                .onTapGesture { isFocused = true }

                if !fieldText.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                            .foregroundStyle(Cyber.accent)
                        Text(fieldText).font(.system(size: 12)).foregroundStyle(Cyber.accent)
                            .lineLimit(2)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 580, alignment: .leading)
            .neonCard(Cyber.accent.opacity(0.2), glow: 6)

            instructionRow(icon: "1.circle.fill", color: Cyber.accent, text: L10n.obTriFillI1)
            instructionRow(icon: "2.circle.fill", color: Cyber.accent, text: L10n.obTriFillI2)
            instructionRow(icon: "3.circle.fill", color: Cyber.accent, text: L10n.obTriFillI3)

            completionBadge(isDone)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onReceive(RecordingResultStore.shared.$result.dropFirst()) { newResult in
            if !newResult.isEmpty {
                fieldText = newResult
            }
        }
    }
}

// MARK: - Step 3: Rewrite Generate
// 内嵌输入框：无选中文本，直接说生成指令，结果填入输入框

extension OnboardingView {
    var rewriteGenerateStep: some View {
        TrialRewriteGenerateView(isDone: isDone, completionBadge: completionBadge)
    }
}

struct TrialRewriteGenerateView: View {
    let isDone: Bool
    let completionBadge: (Bool) -> AnyView
    @State private var fieldText: String = ""
    @FocusState private var isFocused: Bool
    @ObservedObject private var lang = LanguageManager.shared

    init(isDone: Bool, completionBadge: @escaping (Bool) -> some View) {
        self.isDone = isDone
        self.completionBadge = { done in AnyView(completionBadge(done)) }
    }

    var body: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "text.badge.plus", color: Cyber.accent,
                       title: L10n.obRwGenTitle, subtitle: L10n.obRwGenSub,
                       hotkey: HotKeyManager.shared.configs[.rewrite]?.displayString ?? L10n.hotkeyNotSet,
                       hotkeyColor: Cyber.accent)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "text.cursor").font(.system(size: 11))
                        .foregroundStyle(Cyber.accent.opacity(0.7))
                    Text(L10n.obRwGenFieldLabel).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cyber.textDim)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $fieldText)
                        .font(.system(size: 14))
                        .foregroundStyle(Cyber.textBright)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 80)
                        .focused($isFocused)
                    if fieldText.isEmpty {
                        Text(L10n.obRwGenPlaceholder)
                            .font(.system(size: 14))
                            .foregroundStyle(Cyber.textGhost.opacity(0.5))
                            .padding(.top, 8).padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
                .padding(12)
                .background(Cyber.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? Cyber.accent.opacity(0.5) : Cyber.borderDim, lineWidth: 1)
                )
                .onTapGesture { isFocused = true }
            }
            .padding(18)
            .frame(maxWidth: 580, alignment: .leading)
            .neonCard(Cyber.accent.opacity(0.2), glow: 6)

            instructionRow(icon: "1.circle.fill", color: Cyber.accent, text: L10n.obRwGenI1)
            instructionRow(icon: "2.circle.fill", color: Cyber.accent, text: L10n.obRwGenI2)
            instructionRow(icon: "3.circle.fill", color: Cyber.accent, text: L10n.obRwGenI3)

            completionBadge(isDone)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onReceive(RecordingResultStore.shared.$result.dropFirst()) { newResult in
            if !newResult.isEmpty {
                fieldText = newResult
            }
        }
    }
}

// MARK: - Step 4: Rewrite Readonly
// 内嵌只读示例文本：用户选中后说改写指令，结果以弹窗展示

extension OnboardingView {
    var rewriteReadonlyStep: some View {
        TrialRewriteReadonlyView(isDone: isDone, completionBadge: completionBadge)
    }
}

struct TrialRewriteReadonlyView: View {
    let isDone: Bool
    let completionBadge: (Bool) -> AnyView
    @ObservedObject private var lang = LanguageManager.shared

    init(isDone: Bool, completionBadge: @escaping (Bool) -> some View) {
        self.isDone = isDone
        self.completionBadge = { done in AnyView(completionBadge(done)) }
    }

    var body: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "doc.text.magnifyingglass", color: Cyber.accent,
                       title: L10n.obRwRoTitle, subtitle: L10n.obRwRoSub,
                       hotkey: HotKeyManager.shared.configs[.rewrite]?.displayString ?? L10n.hotkeyNotSet,
                       hotkeyColor: Cyber.accent)

            // 只读示例文本区
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw.fill").font(.system(size: 11))
                        .foregroundStyle(Cyber.accent.opacity(0.7))
                    Text(L10n.obRwRoSelectHint).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cyber.textDim)
                }
                Text(L10n.obRwRoSampleText)
                    .font(.system(size: 14))
                    .foregroundStyle(Cyber.textBright)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Cyber.accent.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Cyber.accent.opacity(0.3), lineWidth: 1)
                    )
            }
            .padding(18)
            .frame(maxWidth: 580, alignment: .leading)
            .neonCard(Cyber.accent.opacity(0.2), glow: 6)

            instructionRow(icon: "1.circle.fill", color: Cyber.accent, text: L10n.obRwRoI1)
            instructionRow(icon: "2.circle.fill", color: Cyber.accent, text: L10n.obRwRoI2)
            instructionRow(icon: "3.circle.fill", color: Cyber.accent, text: L10n.obRwRoI3)

            completionBadge(isDone)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Step 5: Rewrite Editable
// 内嵌可编辑输入框 + 预填默认文案：用户选中文字后说改写指令，结果替换选中内容

extension OnboardingView {
    var rewriteEditableStep: some View {
        TrialRewriteEditableView(isDone: isDone, completionBadge: completionBadge)
    }
}

struct TrialRewriteEditableView: View {
    let isDone: Bool
    let completionBadge: (Bool) -> AnyView
    @State private var fieldText: String = ""
    @FocusState private var isFocused: Bool
    @ObservedObject private var lang = LanguageManager.shared

    init(isDone: Bool, completionBadge: @escaping (Bool) -> some View) {
        self.isDone = isDone
        self.completionBadge = { done in AnyView(completionBadge(done)) }
    }

    var body: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "pencil.line", color: Cyber.accent,
                       title: L10n.obRwEdTitle, subtitle: L10n.obRwEdSub,
                       hotkey: HotKeyManager.shared.configs[.rewrite]?.displayString ?? L10n.hotkeyNotSet,
                       hotkeyColor: Cyber.accent)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw.fill").font(.system(size: 11))
                        .foregroundStyle(Cyber.accent.opacity(0.7))
                    Text(L10n.obRwEdFieldLabel).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cyber.textDim)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $fieldText)
                        .font(.system(size: 14))
                        .foregroundStyle(Cyber.textBright)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 80)
                        .focused($isFocused)
                }
                .padding(12)
                .background(Cyber.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? Cyber.accent.opacity(0.5) : Cyber.borderDim, lineWidth: 1)
                )
                .onTapGesture { isFocused = true }
            }
            .padding(18)
            .frame(maxWidth: 580, alignment: .leading)
            .neonCard(Cyber.accent.opacity(0.2), glow: 6)

            instructionRow(icon: "1.circle.fill", color: Cyber.accent, text: L10n.obRwEdI1)
            instructionRow(icon: "2.circle.fill", color: Cyber.accent, text: L10n.obRwEdI2)
            instructionRow(icon: "3.circle.fill", color: Cyber.accent, text: L10n.obRwEdI3)

            completionBadge(isDone)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if fieldText.isEmpty { fieldText = L10n.obRwEdDefaultText }
        }
    }
}

// MARK: - Step 6: Screenshot OCR

extension OnboardingView {
    var screenshotOcrStep: some View {
        TrialScreenshotOcrView(isDone: isDone, completionBadge: completionBadge)
    }
}

struct TrialScreenshotOcrView: View {
    let isDone: Bool
    let completionBadge: (Bool) -> AnyView
    @State private var fieldText: String = ""
    @FocusState private var isFocused: Bool
    @ObservedObject private var lang = LanguageManager.shared

    private var screenshotHotkey: String {
        HotKeyManager.shared.configs[.screenshot]?.displayString ?? L10n.hotkeyNotSet
    }

    private var rewriteHotkey: String {
        HotKeyManager.shared.configs[.rewrite]?.displayString ?? L10n.hotkeyNotSet
    }

    init(isDone: Bool, completionBadge: @escaping (Bool) -> some View) {
        self.isDone = isDone
        self.completionBadge = { done in AnyView(completionBadge(done)) }
    }

    var body: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "camera.viewfinder", color: Cyber.accent,
                       title: L10n.obScrTitle, subtitle: L10n.obScrSub,
                       hotkey: "\(screenshotHotkey) / \(rewriteHotkey)",
                       hotkeyColor: Cyber.accent)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "viewfinder").font(.system(size: 11))
                        .foregroundStyle(Cyber.accent.opacity(0.7))
                    Text(L10n.obScrSelectHint)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cyber.textDim)
                }

                Text(L10n.obScrSampleText)
                    .font(.system(size: 14))
                    .foregroundStyle(Cyber.textBright)
                    .lineSpacing(5)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Cyber.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Cyber.accent.opacity(0.3), lineWidth: 1)
                    )

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $fieldText)
                        .font(.system(size: 14))
                        .foregroundStyle(Cyber.textBright)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .frame(minHeight: 80)
                        .focused($isFocused)
                    if fieldText.isEmpty {
                        Text(L10n.obScrPlaceholder)
                            .font(.system(size: 14))
                            .foregroundStyle(Cyber.textGhost.opacity(0.5))
                            .padding(.top, 8).padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
                .padding(12)
                .background(Cyber.accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isFocused ? Cyber.accent.opacity(0.5) : Cyber.borderDim, lineWidth: 1)
                )
                .onTapGesture { isFocused = true }
            }
            .padding(18)
            .frame(maxWidth: 580, alignment: .leading)
            .neonCard(Cyber.accent.opacity(0.2), glow: 6)

            instructionRow(icon: "1.circle.fill", color: Cyber.accent, text: L10n.obScrI1(screenshotHotkey))
            instructionRow(icon: "2.circle.fill", color: Cyber.accent, text: L10n.obScrI2(rewriteHotkey))
            instructionRow(icon: "3.circle.fill", color: Cyber.accent, text: L10n.obScrI3)
            instructionRow(icon: "4.circle.fill", color: Cyber.accent, text: L10n.obScrI4(rewriteHotkey))

            completionBadge(isDone)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onReceive(RecordingResultStore.shared.$result.dropFirst()) { newResult in
            if !newResult.isEmpty {
                fieldText = newResult
            }
        }
    }
}

// MARK: - Step 7: Agent Search

extension OnboardingView {
    var agentSearchStep: some View {
        TrialAgentSearchView(isDone: isDone, completionBadge: completionBadge)
    }
}

struct TrialAgentSearchView: View {
    let isDone: Bool
    let completionBadge: (Bool) -> AnyView
    @ObservedObject private var lang = LanguageManager.shared

    init(isDone: Bool, completionBadge: @escaping (Bool) -> some View) {
        self.isDone = isDone
        self.completionBadge = { done in AnyView(completionBadge(done)) }
    }

    var body: some View {
        VStack(spacing: 20) {
            stepHeader(icon: "brain.head.profile", color: Cyber.warning,
                       title: L10n.obAgSearchTitle, subtitle: L10n.obAgSearchSub,
                       hotkey: HotKeyManager.shared.configs[.agent]?.displayString ?? L10n.hotkeyNotSet,
                       hotkeyColor: Cyber.warning)

            // 示例指令卡片
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "quote.bubble").font(.system(size: 11))
                        .foregroundStyle(Cyber.warning.opacity(0.7))
                    Text(L10n.obAgSearchExampleLabel).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Cyber.textDim)
                }
                VStack(spacing: 6) {
                    examplePhrase(L10n.obAgSearchEx1)
                    examplePhrase(L10n.obAgSearchEx2)
                    examplePhrase(L10n.obAgSearchEx3)
                }
            }
            .padding(18)
            .frame(maxWidth: 580, alignment: .leading)
            .neonCard(Cyber.warning.opacity(0.2), glow: 6)

            instructionRow(icon: "1.circle.fill", color: Cyber.warning, text: L10n.obAgSearchI1)
            instructionRow(icon: "2.circle.fill", color: Cyber.warning, text: L10n.obAgSearchI2)
            instructionRow(icon: "3.circle.fill", color: Cyber.warning, text: L10n.obAgSearchI3)

            completionBadge(isDone)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func examplePhrase(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 10)).foregroundStyle(Cyber.warning.opacity(0.6))
            Text(L10n.examplePhraseFormat(text))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Cyber.warning)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Cyber.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Cyber.warning.opacity(0.2), lineWidth: 0.8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Step 8: Complete

extension OnboardingView {

    var completeStep: some View {
        VStack(spacing: 26) {
            Spacer().frame(height: 20)
            ZStack {
                Circle().fill(Cyber.accent.opacity(0.08)).frame(width: 110, height: 110)
                Circle().stroke(Cyber.accent.opacity(0.4), lineWidth: 1.5).frame(width: 110, height: 110)
                    .shadow(color: Cyber.accent.opacity(0.4), radius: 10)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48))
                    .foregroundStyle(Cyber.accent)
            }
            VStack(spacing: 10) {
                Text(L10n.onboardingCompleteTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.onboardingCompleteDesc)
                    .font(.system(size: 15)).foregroundStyle(Cyber.textDim)
                    .multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            VStack(spacing: 8) {
                shortcutRow(key: HotKeyManager.shared.configs[.transcribe]?.displayString ?? L10n.hotkeyNotSet,
                            desc: L10n.hotkeyTranscribe, color: Cyber.accent)
                shortcutRow(key: HotKeyManager.shared.configs[.rewrite]?.displayString ?? L10n.hotkeyNotSet,
                            desc: L10n.hotkeyRewrite, color: Cyber.accent)
                shortcutRow(key: HotKeyManager.shared.configs[.agent]?.displayString ?? L10n.hotkeyNotSet,
                            desc: L10n.hotkeyAgent, color: Cyber.warning)
                shortcutRow(key: HotKeyManager.shared.configs[.screenshot]?.displayString ?? L10n.hotkeyNotSet,
                            desc: L10n.hotkeyScreenshotTitle, color: Cyber.accent)
            }
            .padding(18).neonCard(Cyber.borderDim, glow: 6).frame(maxWidth: 400)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func shortcutRow(key: String, desc: String, color: Color) -> some View {
        HStack(spacing: 14) {
            Text(key).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.4), lineWidth: 0.8))
                .fixedSize()
            Text(desc).font(.system(size: 13)).foregroundStyle(Cyber.textDim)
            Spacer()
        }
    }
}

// MARK: - Shared Layout Helpers

private func stepHeader(icon: String, color: Color,
                        title: String, subtitle: String,
                        hotkey: String, hotkeyColor: Color) -> some View {
    HStack(spacing: 16) {
        Image(systemName: icon).font(.system(size: 28)).foregroundStyle(color)
            .shadow(color: color.opacity(0.5), radius: 8)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Cyber.textBright)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Cyber.textDim)
        }
        Spacer()
        Text(hotkey).font(.system(size: 14, weight: .medium)).foregroundStyle(hotkeyColor)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(hotkeyColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(hotkeyColor.opacity(0.4), lineWidth: 1))
            .shadow(color: hotkeyColor.opacity(0.3), radius: 3)
    }
    .frame(maxWidth: 580)
}

private func instructionRow(icon: String, color: Color, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color)
            .frame(width: 24, height: 24)
        Text(text).font(.system(size: 13)).foregroundStyle(Cyber.textBright)
            .fixedSize(horizontal: false, vertical: true)
        Spacer()
    }
    .frame(maxWidth: 580)
}
