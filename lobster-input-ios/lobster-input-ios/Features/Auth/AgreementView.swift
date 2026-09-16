import SwiftUI

struct AgreementView: View {

    @State private var agreements: [AgreementItem] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if agreements.isEmpty {
                Text(L10n.agreementEmpty)
                    .foregroundStyle(LobsterWaterPalette.mutedColor)
            } else {
                List(agreements) { item in
                    NavigationLink {
                        ScrollView {
                            Text(item.content)
                                .font(.body)
                                .foregroundStyle(LobsterWaterPalette.textColor)
                                .padding()
                        }
                        .navigationTitle(item.title)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.headline)
                                .foregroundStyle(LobsterWaterPalette.textColor)
                            Text("v\(item.version)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(LobsterWaterPalette.mutedColor)
                        }
                    }
                }
                .tint(LobsterWaterPalette.accentColor)
            }
        }
        .navigationTitle(L10n.agreementTitle)
        .task {
            do {
                agreements = try await APIClient.shared.fetchAgreements()
            } catch {}
            isLoading = false
        }
    }
}
