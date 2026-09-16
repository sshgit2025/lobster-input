import SwiftUI

struct HistoryView: View {

    @StateObject private var store = HistoryStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    ContentUnavailableView(
                        L10n.historyEmpty,
                        systemImage: "clock.arrow.circlepath",
                        description: Text(L10n.historyEmptyDesc)
                    )
                } else {
                    List {
                        ForEach(store.records) { record in
                            HistoryRow(record: record) {
                                store.deleteRecord(id: record.id)
                            }
                            .listRowBackground(LobsterWaterPalette.surfaceColor)
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { store.records[$0].id }
                            ids.forEach { store.deleteRecord(id: $0) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(LobsterWaterPalette.panelColor.ignoresSafeArea())
            .navigationTitle(L10n.historyTitle)
            .toolbar {
                if !store.records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.historyClearAll, role: .destructive) {
                            store.clearAll()
                        }
                        .tint(LobsterWaterPalette.dangerColor)
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    let record: RecordingHistory
    let onDelete: () -> Void

    private var output: String {
        record.result?.nonEmpty ?? record.transcript?.nonEmpty ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                statusIcon
                Text(operationText(record.operation))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(LobsterWaterPalette.accentDeepColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(LobsterWaterPalette.surfaceMutedColor, in: Capsule())
                Spacer()
                Text(record.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(LobsterWaterPalette.tertiaryColor)
            }

            if let selectedText = record.selectedText?.nonEmpty {
                Text("\(L10n.homeTranscript): \(selectedText)")
                    .font(.caption)
                    .foregroundStyle(LobsterWaterPalette.mutedColor)
            }

            if !output.isEmpty {
                Text(output)
                    .font(.subheadline)
                    .foregroundStyle(LobsterWaterPalette.textColor)
                    .lineLimit(3)
            }

            if let error = record.errorMessage?.nonEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(LobsterWaterPalette.dangerColor)
            }

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = output
                } label: {
                    Label(L10n.btnCopy, systemImage: "doc.on.doc")
                }
                .disabled(output.isEmpty)
                .tint(LobsterWaterPalette.accentColor)

                Button(role: .destructive, action: onDelete) {
                    Label(L10n.btnDelete, systemImage: "trash")
                }
                .tint(LobsterWaterPalette.dangerColor)
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
        }
        .padding(.vertical, 4)
        .contextMenu {
            if !output.isEmpty {
                Button {
                    UIPasteboard.general.string = output
                } label: {
                    Label(L10n.btnCopy, systemImage: "doc.on.doc")
                }
            }
            Button(role: .destructive, action: onDelete) {
                Label(L10n.btnDelete, systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch record.status {
        case .processing:
            ProgressView().scaleEffect(0.7)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LobsterWaterPalette.successColor)
                .font(.caption)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(LobsterWaterPalette.dangerColor)
                .font(.caption)
        }
    }

    private func operationText(_ operation: String) -> String {
        if operation == "rewrite" {
            return L10n.historyOperationCommand
        }
        if operation.hasPrefix("android_quick_") || operation.hasPrefix("ios_quick_") || operation.hasPrefix("quick_") {
            return L10n.historyOperationQuickAction
        }
        return L10n.historyOperationVoiceInput
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
