/// PersonaStore.swift
/// 人设列表数据管理（单例 ObservableObject），支持多人设 CRUD + 激活。
import Foundation
import Combine

@MainActor
final class PersonaStore: ObservableObject {

    static let shared = PersonaStore()

    private var languageCancellable: AnyCancellable?

    private init() {
        languageCancellable = LanguageManager.shared.$current
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isLoading, !self.personas.isEmpty else { return }
                    await self.load()
                }
            }
    }

    @Published private(set) var personas: [PersonaItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let api = APIClient.shared

    var activePersona: PersonaItem? { personas.first(where: { $0.isActive }) }
    var userPersonas: [PersonaItem] { personas.filter { !$0.isBuiltin } }
    var canCreate: Bool { userPersonas.count < personaMaxCount }

    // MARK: - Load

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            personas = try await api.listPersonas()
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
    }

    // MARK: - Create

    func create(name: String, description: String?, prompts: PersonaPrompts) async -> PersonaItem? {
        do {
            let item = try await api.createPersona(
                name: name, description: description, prompts: prompts
            )
            personas.append(item)
            return item
        } catch {
            errorMessage = apiErrorMessage(error)
            return nil
        }
    }

    // MARK: - Update

    func update(id: String, name: String?, description: String?, prompts: PersonaPrompts?) async -> Bool {
        do {
            let updated = try await api.updatePersona(
                id: id, name: name, description: description, prompts: prompts
            )
            if let idx = personas.firstIndex(where: { $0.id == id }) {
                personas[idx] = updated
            }
            return true
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
    }

    // MARK: - Delete

    func delete(id: String) async -> Bool {
        do {
            try await api.deletePersona(id: id)
            personas.removeAll { $0.id == id }
            return true
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
    }

    // MARK: - Activate

    func activate(id: String) async -> Bool {
        do {
            let activated = try await api.activatePersona(id: id)
            for idx in personas.indices {
                if personas[idx].id == activated.id {
                    personas[idx] = activated
                } else {
                    personas[idx].isActive = false
                }
            }
            return true
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
    }

    func deactivateAll() async -> Bool {
        do {
            let activeId = activePersona?.id
            try await api.deactivateAllPersonas()
            for idx in personas.indices {
                personas[idx].isActive = false
                if personas[idx].id == activeId, !personas[idx].isBuiltin {
                    personas[idx].prompts.transcribeEnabled = false
                    personas[idx].prompts.rewriteEnabled = false
                    personas[idx].prompts.intentEnabled = false
                }
            }
            return true
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
    }
}
