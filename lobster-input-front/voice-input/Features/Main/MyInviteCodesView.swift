/// MyInviteCodesView.swift
/// 展示当前用户的 3 个邀请码及其使用状态（低调的 popover）。
/// 业务逻辑与 DIY 分支完全一致，去掉 DIY 专属装饰。
import SwiftUI
import AppKit
import Combine

struct MyInviteCodesView: View {

    @StateObject private var vm = MyInviteCodesViewModel()
    let onDismiss: () -> Void
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            CyberDivider()

            Group {
                if vm.isLoading {
                    loadingView
                } else if let err = vm.errorMessage {
                    errorView(err)
                } else {
                    codesList
                }
            }
            .padding(20)
        }
        .frame(width: 320)
        .background(Cyber.panelBg)
        .onAppear { Task { await vm.load() } }
    }

    private var titleBar: some View {
        HStack {
            Image(systemName: "key.fill")
                .font(.system(size: 13))
                .foregroundStyle(Cyber.accent.opacity(0.7))
            Text(L10n.myInviteCodesTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Cyber.textBright)
            Spacer()
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Cyber.textGhost)
                    .frame(width: 22, height: 22)
                    .background(Cyber.textGhost.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Cyber.accent)
            Text(L10n.loading).font(.system(size: 13)).foregroundStyle(Cyber.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(Cyber.danger.opacity(0.7))
            Text(msg).font(.system(size: 13)).foregroundStyle(Cyber.textDim)
                .multilineTextAlignment(.center)
            Button(L10n.retry) { Task { await vm.load() } }
                .buttonStyle(NeonButtonStyle(color: Cyber.accent))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var codesList: some View {
        VStack(spacing: 0) {
            Text(L10n.myInviteCodesDesc)
                .font(.system(size: 12))
                .foregroundStyle(Cyber.textGhost)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)

            ScrollView(.vertical, showsIndicators: vm.codes.count > 3) {
                VStack(spacing: 0) {
                    ForEach(Array(vm.codes.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            CyberDivider().padding(.vertical, 8)
                        }
                        InviteCodeRow(item: item)
                    }
                }
            }
            .frame(height: 220)
        }
    }
}

// MARK: - InviteCodeRow

private struct InviteCodeRow: View {
    let item: InviteCodeItem
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(formattedCode)
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(item.isUsed ? Cyber.textGhost : Cyber.textBright)
                        .tracking(2)

                    statusBadge
                }

                if item.isUsed, let usedBy = item.usedBy {
                    HStack(spacing: 4) {
                        Text(L10n.myInviteCodeUsedBy + ":")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Cyber.textGhost)
                        Text(usedBy)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Cyber.textDim)
                    }
                }
            }

            Spacer()

            if !item.isUsed {
                Button {
                    copyCode()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundStyle(copied ? Cyber.accent : Cyber.accent.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(Cyber.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Cyber.accent.opacity(0.2), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
                .help(copied ? L10n.myInviteCodeCopied : L10n.btnCopy)
            }
        }
    }

    private var formattedCode: String {
        let c = item.code
        guard c.count == 8 else { return c }
        return "\(c.prefix(4))-\(c.suffix(4))"
    }

    private var statusBadge: some View {
        let isUsed = item.isUsed
        let label = isUsed ? L10n.myInviteCodeUsed : L10n.myInviteCodeUnused
        let color: Color = isUsed ? Cyber.textGhost : Cyber.accent
        return Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color.opacity(0.3), lineWidth: 0.6))
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.code, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class MyInviteCodesViewModel: ObservableObject {
    @Published var codes: [InviteCodeItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            codes = try await APIClient.shared.fetchMyInviteCodes()
        } catch {
            errorMessage = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
