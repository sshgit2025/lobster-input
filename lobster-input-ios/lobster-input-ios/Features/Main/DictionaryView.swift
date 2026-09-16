import SwiftUI

struct DictionaryView: View {

    @StateObject private var store = DictionaryStore.shared
    @State private var newWord = ""
    @State private var editingId: String?
    @State private var editingWord = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(L10n.dictPlaceholder, text: $newWord)
                    Button {
                        Task { await addWord() }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(LobsterWaterPalette.accentColor)
                    }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(LobsterWaterPalette.surfaceColor)
            }

            if store.words.isEmpty && !store.isLoading {
                Section {
                    Text(L10n.dictEmpty)
                        .foregroundStyle(LobsterWaterPalette.mutedColor)
                }
                .listRowBackground(LobsterWaterPalette.surfaceColor)
            } else {
                Section {
                    ForEach(store.words) { item in
                        if editingId == item.id {
                            HStack {
                                TextField("", text: $editingWord)
                                Button(L10n.btnSave) {
                                    Task { await updateWord(id: item.id) }
                                }
                                .buttonStyle(.bordered)
                                .tint(LobsterWaterPalette.accentColor)
                                Button(L10n.btnCancel) {
                                    editingId = nil
                                }
                                .buttonStyle(.bordered)
                                .tint(LobsterWaterPalette.mutedColor)
                            }
                        } else {
                            Text(item.word)
                                .foregroundStyle(LobsterWaterPalette.textColor)
                                .contextMenu {
                                    Button(L10n.btnEdit) {
                                        editingId = item.id
                                        editingWord = item.word
                                    }
                                    Button(L10n.btnDelete, role: .destructive) {
                                        Task { try? await store.delete(id: item.id) }
                                    }
                                }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.words[$0].id }
                        Task { for id in ids { try? await store.delete(id: id) } }
                    }
                }
                .listRowBackground(LobsterWaterPalette.surfaceColor)
            }
        }
        .scrollContentBackground(.hidden)
        .background(LobsterWaterPalette.panelColor.ignoresSafeArea())
        .navigationTitle(L10n.dictTitle)
        .tint(LobsterWaterPalette.accentColor)
        .task { await store.loadWords() }
    }

    private func addWord() async {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        try? await store.add(word: word)
        newWord = ""
    }

    private func updateWord(id: String) async {
        let word = editingWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        try? await store.update(id: id, word: word)
        editingId = nil
    }
}
