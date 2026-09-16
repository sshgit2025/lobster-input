import Foundation
import Combine

@MainActor
final class DictionaryStore: ObservableObject {

    static let shared = DictionaryStore()
    private init() {}

    @Published private(set) var words: [HotWordItem] = []
    @Published private(set) var isLoading = false

    private func syncHotwordsToKeyboard() {
        let cleaned = words
            .map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = Array(Set(cleaned))
        let defaults = UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard
        defaults.set(unique.joined(separator: "\n"), forKey: "ime_hotwords_cache")
    }

    func loadWords() async {
        isLoading = true
        defer { isLoading = false }
        do {
            words = try await APIClient.shared.fetchHotWords()
            syncHotwordsToKeyboard()
        } catch {
            words = []
        }
    }

    func add(word: String) async throws {
        let item = try await APIClient.shared.createHotWord(word: word)
        words.insert(item, at: 0)
        syncHotwordsToKeyboard()
    }

    func update(id: String, word: String) async throws {
        let updated = try await APIClient.shared.updateHotWord(id: id, word: word)
        if let idx = words.firstIndex(where: { $0.id == id }) {
            words[idx] = updated
        }
        syncHotwordsToKeyboard()
    }

    func delete(id: String) async throws {
        try await APIClient.shared.deleteHotWord(id: id)
        words.removeAll { $0.id == id }
        syncHotwordsToKeyboard()
    }
}
