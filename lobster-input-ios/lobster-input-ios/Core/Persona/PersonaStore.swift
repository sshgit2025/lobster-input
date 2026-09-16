import Foundation
import Combine

@MainActor
final class PersonaStore: ObservableObject {

    static let shared = PersonaStore()
    private init() {}

    @Published private(set) var personas: [PersonaItem] = []
    @Published private(set) var isLoading = false

    var activePersona: PersonaItem? { personas.first(where: { $0.isActive }) }

    func loadPersonas() async {
        isLoading = true
        defer { isLoading = false }
        do {
            personas = try await APIClient.shared.fetchPersonas()
        } catch {
            personas = []
        }
    }

    func create(name: String, description: String?, prompts: PersonaPrompts) async throws {
        _ = try await APIClient.shared.createPersona(name: name, description: description, prompts: prompts)
        await loadPersonas()
    }

    func update(id: String, name: String?, description: String?, prompts: PersonaPrompts?) async throws {
        _ = try await APIClient.shared.updatePersona(id: id, name: name, description: description, prompts: prompts)
        await loadPersonas()
    }

    func delete(id: String) async throws {
        try await APIClient.shared.deletePersona(id: id)
        await loadPersonas()
    }

    func activate(id: String) async throws {
        try await APIClient.shared.activatePersona(id: id)
        await loadPersonas()
    }

    func deactivateAll() async throws {
        try await APIClient.shared.deactivateAllPersonas()
        await loadPersonas()
    }
}
