/// AgreementView.swift
/// 协议展示视图：从后端拉取 Markdown 格式协议并渲染展示。
import SwiftUI
import Observation

enum AgreementType: String, Identifiable {
    case terms = "terms"
    case privacy = "privacy"
    var id: String { rawValue }
}

@Observable
final class AgreementViewModel {
    var content: String = ""
    var isLoading = false
    var error: String? = nil

    func load(type: AgreementType, lang: String) async {
        isLoading = true
        error = nil
        content = ""

        guard var comps = URLComponents(string: APIConfig.Agreements.get) else {
            isLoading = false
            return
        }
        comps.queryItems = [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "lang", value: lang),
        ]
        guard let url = comps.url else {
            isLoading = false
            return
        }

        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(APIConfig.appVariant, forHTTPHeaderField: "X-App-Variant")
            request.setValue("macos_\(APIConfig.appVariant)", forHTTPHeaderField: "X-Client-Platform")
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONDecoder().decode(AgreementResponse.self, from: data) {
                content = json.content
            } else {
                error = L10n.agreementLoadFailed
            }
        } catch {
            self.error = L10n.agreementLoadFailed
        }

        isLoading = false
    }
}

private struct AgreementResponse: Decodable {
    let content: String
}

struct AgreementView: View {
    let type: AgreementType
    @ObservedObject private var lang = LanguageManager.shared
    @State private var vm = AgreementViewModel()
    @Environment(\.dismiss) private var dismiss

    var title: String {
        switch type {
        case .terms: return L10n.agreementTerms
        case .privacy: return L10n.agreementPrivacy
        }
    }

    var body: some View {
        ZStack {
            Cyber.panelBg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                CyberDivider()
                contentArea
                CyberDivider()
                footer
            }
        }
        .frame(width: 680, height: 600)
        .task { await vm.load(type: type, lang: lang.current.rawValue) }
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Cyber.textBright)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var contentArea: some View {
        Group {
            if vm.isLoading {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular).tint(Cyber.accent)
                    Text(L10n.agreementLoading)
                        .font(.system(size: 13))
                        .foregroundStyle(Cyber.textDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = vm.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Cyber.danger)
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(Cyber.textDim)
                        .multilineTextAlignment(.center)
                    Button(L10n.retry) {
                        Task { await vm.load(type: type, lang: lang.current.rawValue) }
                    }
                    .buttonStyle(NeonButtonStyle(color: Cyber.accent))
                    .frame(width: 120)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarkdownScrollView(text: vm.content, maxHeight: 440)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.agreementClose) { dismiss() }
                .buttonStyle(NeonButtonStyle(color: Cyber.accent))
                .frame(width: 120)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
