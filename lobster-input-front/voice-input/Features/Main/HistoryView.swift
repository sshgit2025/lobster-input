/// HistoryView.swift
/// 录音历史记录列表 — 油绿科技风格
import SwiftUI

struct HistoryView: View {

    @ObservedObject private var store = HistoryStore.shared
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        ZStack {
            Cyber.bgTop.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.pageHistory)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Cyber.textBright)
                    Spacer()
                    if store.totalCount > 0 {
                        CountBadge(text: L10n.recCount(store.totalCount))
                    }
                }
                .padding(.horizontal, CyberLayout.padH).padding(.vertical, CyberLayout.padV)
                CyberDivider()
                ScrollView {
                    VStack(spacing: 0) {
                        historySaveSection
                        CyberDivider()
                        historyPrivacySection
                    }
                    .frame(maxWidth: CyberLayout.contentMaxW)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, CyberLayout.padH)
                    .padding(.top, 6)
                    if store.isLoading {
                        loadingState
                    } else if store.records.isEmpty {
                        emptyState
                    } else {
                        recordCards
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordCards: some View {
        LazyVStack(spacing: 12) {
            ForEach(store.records) { record in HistoryCard(record: record) }
            if store.hasMore {
                Button { store.loadMore() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.down").font(.system(size: 12))
                        Text(L10n.moreCount(store.totalCount - store.records.count)).font(.system(size: 13, weight: .medium))
                    }.foregroundStyle(Cyber.textDim)
                }.buttonStyle(.plain).padding(.vertical, 12)
            }
        }
        .frame(maxWidth: CyberLayout.contentMaxW)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CyberLayout.padH)
        .padding(.vertical, 12)
    }

    private var historySaveSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Cyber.textGhost)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.historySaveTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.historySaveSubtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Cyber.textDim)
            }
            Spacer()
            retentionMenu
        }
        .padding(.vertical, 12)
    }

    private var retentionMenu: some View {
        Menu {
            ForEach(HistoryStore.RetentionPolicy.allCases) { policy in
                Button(policy.localizedName) {
                    store.retentionPolicy = policy
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(store.retentionPolicy.localizedName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Cyber.textGhost)
            }
            .padding(.horizontal, 10)
            .frame(width: 108, height: 30)
            .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
            .overlay(RoundedRectangle(cornerRadius: CyberLayout.cornerSm).stroke(Cyber.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .id(lang.current.rawValue)
    }

    private var historyPrivacySection: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Cyber.textGhost)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.historyPrivacyTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.historyPrivacySubtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Cyber.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark").font(.system(size: 40)).foregroundStyle(Cyber.faint)
            Text(L10n.noRecords).font(.system(size: 15, weight: .medium)).foregroundStyle(Cyber.textGhost)
        }.frame(maxWidth: .infinity, minHeight: 200)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small).tint(Cyber.accent)
            Text(L10n.processing).font(.system(size: 15, weight: .medium)).foregroundStyle(Cyber.textGhost)
        }.frame(maxWidth: .infinity, minHeight: 200)
    }
}

private struct HistoryCard: View {
    let record: RecordingHistory
    @ObservedObject private var store = HistoryStore.shared
    @ObservedObject private var lang = LanguageManager.shared
    @State private var isExpanded = false; @State private var showDeleteConfirm = false
    @State private var resultCopied = false; @State private var transcriptCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            CyberDivider().padding(.vertical, 8)
            contentArea
            if record.status != .processing && record.status != .pending {
                CyberDivider()
                actionBar.padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .neonCard()
        .overlay(
            RoundedRectangle(cornerRadius: CyberLayout.corner)
                .stroke(record.status == .failed ? Cyber.danger.opacity(0.3) : Cyber.borderDim, lineWidth: 1)
        )
        .confirmationDialog(L10n.deleteConfirm, isPresented: $showDeleteConfirm) {
            Button(L10n.deleteRecordAndAudio, role: .destructive) { let id = record.id; DispatchQueue.main.async { store.delete(id: id, deleteAudio: true) } }
            Button(L10n.deleteRecordOnly, role: .destructive) { let id = record.id; DispatchQueue.main.async { store.delete(id: id, deleteAudio: false) } }
            Button(L10n.cancel, role: .cancel) {}
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: operationIcon).font(.system(size: 12))
                Text(localizedOperation).font(.system(size: 12, weight: .medium))
            }.foregroundStyle(Cyber.textGhost)
            Spacer()
            if let d = record.processingDuration { Text(String(format: "%.1fs", d)).font(.system(size: 12)).foregroundStyle(Cyber.textGhost) }
            Text(record.createdAt, formatter: Self.timeFormatter).font(.system(size: 12)).foregroundStyle(Cyber.textGhost)
            statusBadge
        }.padding(.horizontal, 20).padding(.top, 16)
    }

    @ViewBuilder
    private var contentArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch record.status {
            case .pending, .processing:
                HStack(spacing: 10) { ProgressView().controlSize(.small).tint(Cyber.accent); Text(L10n.processing).font(.system(size: 15)).foregroundStyle(Cyber.textDim) }
                    .padding(.horizontal, 20).padding(.bottom, 16)
            case .failed:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Cyber.danger).font(.system(size: 13))
                    Text(L10n.recognizeFailed).font(.system(size: 14)).foregroundStyle(Cyber.danger)
                    Spacer()
                }.padding(.horizontal, 20).padding(.bottom, 16)
            case .success:
                successContent
            }
        }
    }

    private var successContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if let result = record.result, !result.isEmpty {
                    if record.resultIsMarkdown {
                        // Markdown 内容（搜索结果等）：折叠状态只显示摘要提示，不渲染原始符号
                        HStack(spacing: 6) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 12))
                                .foregroundStyle(Cyber.accent.opacity(0.7))
                            Text(L10n.historySearchResultHint)
                                .font(.system(size: 14))
                                .foregroundStyle(Cyber.textDim)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(result)
                            .font(.system(size: 15))
                            .foregroundStyle(Cyber.textBright)
                            .textSelection(.enabled)
                            .lineLimit(isExpanded ? nil : 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(L10n.noResult).font(.system(size: 15)).foregroundStyle(Cyber.textGhost).frame(maxWidth: .infinity, alignment: .leading)
                }
                collapsedCopyActions
                Button { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Cyber.textDim).frame(width: 26, height: 26)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 20).padding(.bottom, isExpanded ? 10 : 16)
            if isExpanded {
                CyberDivider().padding(.horizontal, 20)
                expandedDetail.padding(.horizontal, 20).padding(.vertical, 16)
            }
        }
    }

    @ViewBuilder
    private var collapsedCopyActions: some View {
        HStack(spacing: 8) {
            if let t = record.transcript, !t.isEmpty {
                compactCopyButton(label: L10n.labelTranscript, isCopied: transcriptCopied, color: Cyber.accent) {
                    copy(t)
                    transcriptCopied = true
                    resetTranscriptCopied()
                }
            }
            if let r = record.result, !r.isEmpty {
                compactCopyButton(label: L10n.labelResult, isCopied: resultCopied, color: Cyber.accent) {
                    copy(r)
                    resultCopied = true
                    resetResultCopied()
                }
            }
        }
        .fixedSize()
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let t = record.transcript, !t.isEmpty { detailBlock(label: L10n.labelTranscript, text: t, color: Cyber.accent, isCopied: transcriptCopied) {
                copy(t); transcriptCopied = true
                resetTranscriptCopied()
            }}
            if let r = record.result, !r.isEmpty {
                if record.resultIsMarkdown {
                    markdownDetailBlock(text: r, isCopied: resultCopied) {
                        copy(r); resultCopied = true
                        resetResultCopied()
                    }
                } else {
                    detailBlock(label: L10n.labelResult, text: r, color: Cyber.accent, isCopied: resultCopied) {
                        copy(r); resultCopied = true
                        resetResultCopied()
                    }
                }
            }
        }
    }

    private func detailBlock(label: String, text: String, color: Color, isCopied: Bool, onCopy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Cyber.textDim)
                Spacer()
                Button(action: onCopy) {
                    HStack(spacing: 5) { Image(systemName: isCopied ? "checkmark" : "doc.on.doc").font(.system(size: 11)); Text(isCopied ? L10n.btnCopied : L10n.btnCopy).font(.system(size: 11, weight: .medium)) }
                        .foregroundStyle(isCopied ? Cyber.success : Cyber.textDim)
                }.buttonStyle(.plain)
            }
            Text(text).font(.system(size: 14)).foregroundStyle(Cyber.textBright.opacity(0.85)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
                .overlay(RoundedRectangle(cornerRadius: CyberLayout.cornerSm).stroke(Cyber.borderDim, lineWidth: 1))
        }
    }

    private func markdownDetailBlock(text: String, isCopied: Bool, onCopy: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.labelResult)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Cyber.textDim)
                Image(systemName: "doc.richtext")
                    .font(.system(size: 10))
                    .foregroundStyle(Cyber.accent.opacity(0.6))
                Spacer()
                Button(action: onCopy) {
                    HStack(spacing: 5) { Image(systemName: isCopied ? "checkmark" : "doc.on.doc").font(.system(size: 11)); Text(isCopied ? L10n.btnCopied : L10n.btnCopy).font(.system(size: 11, weight: .medium)) }
                        .foregroundStyle(isCopied ? Cyber.success : Cyber.textDim)
                }.buttonStyle(.plain)
            }
            MarkdownScrollView(text: text, maxHeight: 280)
                .frame(height: 280)
                .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
                .overlay(RoundedRectangle(cornerRadius: CyberLayout.cornerSm).stroke(Cyber.borderDim, lineWidth: 1))
            Button {
                Task { @MainActor in
                    ResultOverlayWindowController.shared.showMarkdown(text: text, pinned: true)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.and.arrow.up.right.and.arrow.down.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L10n.btnViewInOverlay)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Cyber.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: CyberLayout.cornerSm)
                        .fill(Cyber.accentSoft)
                        .overlay(RoundedRectangle(cornerRadius: CyberLayout.cornerSm).stroke(Cyber.accentRing, lineWidth: 1))
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            Spacer()
            if record.audioFileExists && record.retryable {
                Button {
                    Task { @MainActor in await AppHotKeyHandler.shared.processRecord(id: record.id, operation: record.operation, audioPath: record.audioFilePath, selectedText: record.selectedText) }
                } label: { HStack(spacing: 5) { Image(systemName: "arrow.clockwise").font(.system(size: 11)); Text(L10n.retry).font(.system(size: 12, weight: .medium)) } }
                .buttonStyle(.plain).foregroundStyle(Cyber.textDim)
            }
            if record.audioFileExists {
                Button { let id = record.id; DispatchQueue.main.async { store.deleteAudioFile(id: id) } } label: {
                    HStack(spacing: 5) { Image(systemName: "waveform.slash").font(.system(size: 11)); Text(L10n.btnDelAudio).font(.system(size: 12, weight: .medium)) }
                }.buttonStyle(.plain).foregroundStyle(Cyber.textDim)
            }
            Button { showDeleteConfirm = true } label: { Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Cyber.textDim) }.buttonStyle(.plain)
        }
    }

    private static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    private func compactCopyButton(label: String, isCopied: Bool, color: Color, onCopy: @escaping () -> Void) -> some View {
        Button(action: onCopy) {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(isCopied ? L10n.btnCopied : "\(L10n.btnCopy) \(label)")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isCopied ? Cyber.success : Cyber.textDim)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
            .overlay(RoundedRectangle(cornerRadius: CyberLayout.cornerSm).stroke(Cyber.borderDim, lineWidth: 1))
        }
        .buttonStyle(.plain)
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

    private var statusBadge: some View {
        Group {
            switch record.status {
            case .pending: HStack(spacing: 4) { Image(systemName: "clock"); Text(L10n.statusWait) }.foregroundStyle(Cyber.warning)
            case .processing: HStack(spacing: 4) { Image(systemName: "waveform"); Text(L10n.statusProc) }.foregroundStyle(Cyber.accent)
            case .success: HStack(spacing: 4) { Image(systemName: "checkmark.circle.fill"); Text(L10n.statusOk) }.foregroundStyle(Cyber.success)
            case .failed: HStack(spacing: 4) { Image(systemName: "xmark.circle.fill"); Text(L10n.statusFail) }.foregroundStyle(Cyber.danger)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var localizedOperation: String {
        switch record.operation {
        case "transcribe": return L10n.opTranscribe
        case "rewrite": return L10n.opRewrite
        case "agent": return L10n.opAgent
        default: return record.operation
        }
    }

    private var operationIcon: String {
        switch record.operation { case "transcribe": return "mic"; case "rewrite": return "pencil"; case "agent": return "sparkles"; default: return "waveform" }
    }
}
