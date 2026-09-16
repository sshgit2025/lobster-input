/// HomeView.swift
/// 首页视图，展示欢迎区、快捷键说明和最近一条识别结果。
import SwiftUI

struct HomeView: View {

    @ObservedObject private var permissionManager = PermissionManager.shared
    @ObservedObject private var historyStore = HistoryStore.shared
    @ObservedObject private var lang = LanguageManager.shared
    @ObservedObject private var openClawManager = OpenClawManager.shared
    @State private var transcriptCopied = false
    @State private var resultCopied = false

    var body: some View {
        ZStack {
            Cyber.bgTop

            VStack(spacing: 0) {
                // 页头
                HStack {
                    Text(L10n.pageHome)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Cyber.textBright)
                    Spacer()
                    if !permissionManager.allGranted {
                        Button { openPermissionWindow() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .font(.system(size: 13))
                                Text(L10n.btnWarn)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(Cyber.warning)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, CyberLayout.padH)
                .padding(.vertical, CyberLayout.padV)

                CyberDivider()

                ScrollView {
                    VStack(spacing: 28) {
                        openClawSection
                        shortcutGuide
                        latestHistorySection
                    }
                    .frame(maxWidth: CyberLayout.readingMaxW)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, CyberLayout.padH)
                    .padding(.vertical, 32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { permissionManager.refreshStatuses() }
    }

    // MARK: - OpenClaw Section

    @ViewBuilder
    private var openClawSection: some View {
        switch openClawManager.status {
        case .unknown:
            EmptyView()
        case .notInstalled:
            openClawPromoCard
        case .installedServiceDown:
            openClawServiceDownCard
        case .ready:
            openClawReadyCard
        }
    }

    private var openClawPromoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Cyber.accentSoft)
                        .frame(width: 40, height: 40)
                    Text("🦞").font(.system(size: 20))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.openclawPromoTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Cyber.textBright)
                    Text(L10n.openclawPromoDesc)
                        .font(.system(size: 12))
                        .foregroundStyle(Cyber.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 12) {
                Button {
                    openClawManager.launchInstaller()
                } label: {
                    Text(L10n.openclawInstallBtn)
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(PrimaryButtonStyle())
                Text(L10n.openclawMinVersion)
                    .font(.system(size: 11))
                    .foregroundStyle(Cyber.textGhost)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Cyber.accentSoft, Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .neonCard(Cyber.accentRing, glow: 0)
        .overlay(
            RoundedRectangle(cornerRadius: CyberLayout.corner)
                .stroke(Cyber.accentRing, lineWidth: 1)
        )
    }

    private var openClawServiceDownCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Cyber.warning.opacity(0.08))
                        .frame(width: 40, height: 40)
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Cyber.warning.opacity(0.3), lineWidth: 1)
                        .frame(width: 40, height: 40)
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Cyber.warning)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.openclawServiceDownTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Cyber.textBright)
                    Text(L10n.openclawServiceDownDesc)
                        .font(.system(size: 12))
                        .foregroundStyle(Cyber.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    openClawManager.launchUninstaller()
                } label: {
                    Text(L10n.openclawUninstallBtn)
                        .font(.system(size: 11))
                        .foregroundStyle(Cyber.textGhost)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().stroke(Cyber.borderDim, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Button {
                openClawManager.startGateway()
            } label: {
                HStack(spacing: 8) {
                    if openClawManager.isStartingGateway {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Cyber.accentForeground)
                    }
                    Text(openClawManager.isStartingGateway
                         ? L10n.openclawStartingGateway
                         : L10n.openclawStartBtn)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(openClawManager.isStartingGateway)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCard()
    }

    private var openClawReadyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Cyber.success.opacity(0.08))
                        .frame(width: 40, height: 40)
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Cyber.success.opacity(0.3), lineWidth: 1)
                        .frame(width: 40, height: 40)
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Cyber.success)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.openclawInstalledTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Cyber.textBright)
                    Text(L10n.openclawInstalledDesc)
                        .font(.system(size: 12))
                        .foregroundStyle(Cyber.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    openClawManager.launchUninstaller()
                } label: {
                    Text(L10n.openclawUninstallBtn)
                        .font(.system(size: 11))
                        .foregroundStyle(Cyber.textGhost)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().stroke(Cyber.borderDim, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Button {
                openClawManager.stopGateway()
            } label: {
                Text(L10n.openclawStopBtn)
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(NeonButtonStyle(color: Cyber.accent))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCard()
    }

    // MARK: - Shortcut Guide

    @ObservedObject private var hotKeyManager = HotKeyManager.shared

    private var shortcutGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.sectionHotkeys.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Cyber.textGhost)
                .tracking(0.8)

            VStack(spacing: 0) {
                ShortcutRow(
                    key: hotKeyManager.configs[.transcribe]?.displayString ?? L10n.hotkeyNotSet,
                    desc: L10n.hotkeyTranscribe
                )
                CyberDivider().padding(.leading, 16)
                ShortcutRow(
                    key: hotKeyManager.configs[.rewrite]?.displayString ?? L10n.hotkeyNotSet,
                    desc: L10n.hotkeyRewrite
                )
                CyberDivider().padding(.leading, 16)
                ShortcutRow(
                    key: hotKeyManager.configs[.agent]?.displayString ?? L10n.hotkeyNotSet,
                    desc: L10n.hotkeyAgent
                )
                CyberDivider().padding(.leading, 16)
                ShortcutRow(
                    key: hotKeyManager.configs[.screenshot]?.displayString ?? L10n.hotkeyNotSet,
                    desc: L10n.hotkeyScreenshotTitle
                )
            }
            .neonCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Latest History

    @ViewBuilder
    private var latestHistorySection: some View {
        if let latest = historyStore.records.first {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.sectionLatest.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Cyber.textGhost)
                        .tracking(0.8)
                    Spacer()
                    Text(latest.createdAt, formatter: Self.timeFormatter)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Cyber.textGhost)
                }
                latestRecordCard(latest)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func latestRecordCard(_ record: RecordingHistory) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch record.status {
            case .pending, .processing:
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Cyber.accent)
                    Text(L10n.recognizing)
                        .font(.system(size: 14))
                        .foregroundStyle(Cyber.textDim)
                }
            case .failed:
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                    Text(L10n.recognizeFailed)
                        .font(.system(size: 14))
                }
                .foregroundStyle(Cyber.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                if record.audioFileExists {
                    Button {
                        Task { @MainActor in
                            await AppHotKeyHandler.shared.processRecord(
                                id: record.id, operation: record.operation,
                                audioPath: record.audioFilePath, selectedText: record.selectedText
                            )
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11))
                            Text(L10n.retry).font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(NeonButtonStyle(color: Cyber.warning))
                }
            case .success:
                if let transcript = record.transcript, !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        copyHeader(label: L10n.labelTranscript, isCopied: transcriptCopied) {
                            copy(transcript)
                            transcriptCopied = true
                            resetTranscriptCopied()
                        }
                        Text(transcript)
                            .font(.system(size: 12))
                            .foregroundStyle(Cyber.textGhost)
                            .lineLimit(2)
                    }
                }
                if let result = record.result, !result.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        if record.transcript != nil && !record.transcript!.isEmpty {
                            Divider().background(Cyber.borderDim)
                        }
                        copyHeader(label: L10n.labelResult, isCopied: resultCopied) {
                            copy(result)
                            resultCopied = true
                            resetResultCopied()
                        }
                        if record.resultIsMarkdown {
                            MarkdownScrollView(text: result, maxHeight: 200)
                                .frame(height: 200)
                        } else {
                            Text(result)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Cyber.textBright)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .neonCard()
    }

    private func copyHeader(label: String, isCopied: Bool, onCopy: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Cyber.textGhost)
                .tracking(0.6)
            Spacer()
            Button(action: onCopy) {
                HStack(spacing: 5) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                    Text(isCopied ? L10n.btnCopied : L10n.btnCopy)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(isCopied ? Cyber.success : Cyber.textDim)
            }
            .buttonStyle(.plain)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func resetTranscriptCopied() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { transcriptCopied = false }
    }

    private func resetResultCopied() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { resultCopied = false }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func openPermissionWindow() { PermissionWindowManager.shared.show() }
}

// MARK: - ShortcutRow

private struct ShortcutRow: View {
    let key: String, desc: String

    var body: some View {
        HStack(spacing: 14) {
            KbdTag(text: key)
                .fixedSize()
            Text(desc)
                .font(.system(size: 13))
                .foregroundStyle(Cyber.textDim)
            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
    }
}

#Preview { HomeView() }
