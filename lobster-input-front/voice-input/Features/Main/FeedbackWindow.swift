import SwiftUI
import AppKit

@MainActor
final class FeedbackWindowController: NSObject, NSWindowDelegate {
    static let shared = FeedbackWindowController()

    /// 稳定的窗口标识，独立于本地化标题，供主窗口识别逻辑排除本窗口。
    static let windowIdentifier = "feedback-window"

    private var window: NSWindow?

    private override init() { super.init() }

    func show() {
        if window == nil { createWindow() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let view = FeedbackView { [weak self] in self?.window?.orderOut(nil) }
        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.feedbackTitle
        win.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        win.contentView = NSHostingView(rootView: view)
        win.isReleasedWhenClosed = false
        win.delegate = self
        window = win
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private struct FeedbackView: View {
    let onClose: () -> Void
    @ObservedObject private var lang = LanguageManager.shared

    @State private var content = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var isSubmitting = false
    @State private var message: String?
    @State private var isSuccess = false

    var body: some View {
        ZStack {
            Cyber.bgTop.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                header
                feedbackEditor
                contactFields
                if let message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(isSuccess ? Cyber.success : Cyber.danger)
                }
                Spacer()
                actions
            }
            .padding(24)
        }
        .frame(width: 520, height: 430)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.feedbackTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Cyber.textBright)
            Text(L10n.feedbackWindowDesc)
                .font(.system(size: 12))
                .foregroundStyle(Cyber.textGhost)
        }
    }

    private var feedbackEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $content)
                .font(.system(size: 14))
                .foregroundStyle(Cyber.textBright)
                .scrollContentBackground(.hidden)
                .padding(8)
            if content.isEmpty {
                Text(L10n.feedbackPlaceholder)
                    .font(.system(size: 14))
                    .foregroundStyle(Cyber.textGhost)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 150)
        .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
        .overlay(RoundedRectangle(cornerRadius: CyberLayout.cornerSm).stroke(Cyber.lineStrong, lineWidth: 1))
    }

    private var contactFields: some View {
        VStack(spacing: 10) {
            TextField(L10n.feedbackPhonePlaceholder, text: $phone)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
            TextField(L10n.feedbackEmailPlaceholder, text: $email)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button(L10n.cancel, action: onClose)
                .buttonStyle(NeonButtonStyle(color: Cyber.textDim))
                .disabled(isSubmitting)
            Button(isSubmitting ? L10n.feedbackSubmitting : L10n.feedbackSubmit) {
                Task { await submit() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSubmitting || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit() async {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return }
        isSubmitting = true
        message = nil
        do {
            try await APIClient.shared.submitFeedback(
                content: trimmedContent,
                phone: phone.trimmedNilIfEmpty,
                email: email.trimmedNilIfEmpty
            )
            isSuccess = true
            message = L10n.feedbackSuccess
            content = ""
            phone = ""
            email = ""
        } catch {
            isSuccess = false
            message = L10n.feedbackFailure
        }
        isSubmitting = false
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
