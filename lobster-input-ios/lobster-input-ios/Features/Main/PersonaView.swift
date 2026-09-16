import SwiftUI

struct PersonaView: View {

    @StateObject private var store = PersonaStore.shared
    @State private var showAddSheet = false
    @State private var path = NavigationPath()

    private var customPersonaCount: Int {
        store.personas.count { !$0.isBuiltin }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.personas.isEmpty && !store.isLoading {
                    ContentUnavailableView(
                        L10n.personaEmpty,
                        systemImage: "person.text.rectangle",
                        description: Text(L10n.personaEmptyDesc)
                    )
                } else {
                    List {
                        ForEach(store.personas) { persona in
                            PersonaRow(
                                persona: persona,
                                onOpen: { if !persona.isBuiltin { path.append(persona.id) } },
                                onToggleActive: { toggleActive(persona) },
                                onDelete: { Task { try? await store.delete(id: persona.id) } }
                            )
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(LobsterWaterPalette.panelColor.ignoresSafeArea())
            .navigationTitle(L10n.personaTitle)
            .navigationDestination(for: String.self) { id in
                PersonaEditScreen(personaID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(customPersonaCount >= personaMaxCount)
                }
            }
            .sheet(isPresented: $showAddSheet) {
                PersonaEditSheet(mode: .create)
            }
            .task { await store.loadPersonas() }
        }
    }

    private func toggleActive(_ persona: PersonaItem) {
        Task {
            if persona.isActive {
                try? await store.deactivateAll()
            } else {
                try? await store.activate(id: persona.id)
            }
        }
    }
}

struct PersonaRow: View {
    let persona: PersonaItem
    let onOpen: () -> Void
    let onToggleActive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(persona.name)
                            .font(.headline)
                            .foregroundStyle(LobsterWaterPalette.textColor)
                            .lineLimit(1)
                        Text(persona.isBuiltin ? L10n.personaBuiltin : L10n.personaCustom)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LobsterWaterPalette.accentDeepColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(LobsterWaterPalette.surfaceMutedColor, in: Capsule())
                    }
                    if let desc = persona.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(LobsterWaterPalette.mutedColor)
                            .lineLimit(2)
                    } else if !persona.isBuiltin {
                        Text(moduleSummary)
                            .font(.caption)
                            .foregroundStyle(LobsterWaterPalette.mutedColor)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if persona.isActive {
                    Label(L10n.personaActive, systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(LobsterWaterPalette.successColor)
                        .font(.title3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            HStack(spacing: 8) {
                Button(persona.isActive ? L10n.personaDeactivate : L10n.personaActivate) {
                    onToggleActive()
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.borderedProminent)
                .tint(persona.isActive ? LobsterWaterPalette.dangerColor : LobsterWaterPalette.accentColor)

                if !persona.isBuiltin {
                    Button(L10n.btnEdit) { onOpen() }
                        .buttonStyle(.bordered)
                        .tint(LobsterWaterPalette.accentColor)

                    Button(L10n.btnDelete, role: .destructive) {
                        onDelete()
                    }
                    .buttonStyle(.bordered)
                    .tint(LobsterWaterPalette.dangerColor)
                }
            }
        }
        .lobsterCard()
    }

    private var moduleSummary: String {
        [
            "\(MobileStrings.personaTranscribe()): \(persona.prompts.transcribeEnabled ? MobileStrings.active() : MobileStrings.inactive())",
            "\(MobileStrings.personaRewrite()): \(persona.prompts.rewriteEnabled ? MobileStrings.active() : MobileStrings.inactive())"
        ].joined(separator: "  ")
    }
}

struct PersonaEditScreen: View {
    let personaID: String
    @StateObject private var store = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var desc = ""
    @State private var transcribePrompt = ""
    @State private var transcribeEnabled = false
    @State private var rewritePrompt = ""
    @State private var rewriteEnabled = false
    @State private var isSaving = false

    private var persona: PersonaItem? {
        store.personas.first { $0.id == personaID }
    }

    var body: some View {
        Group {
            if let persona, !persona.isBuiltin {
                Form {
                    Section {
                        TextField(L10n.personaName, text: $name)
                            .onChange(of: name) { _, newValue in
                                name = String(newValue.prefix(personaNameMaxLength))
                            }
                        TextField(L10n.personaDesc, text: $desc, axis: .vertical)
                            .lineLimit(2...4)
                            .onChange(of: desc) { _, newValue in
                                desc = String(newValue.prefix(personaDescMaxLength))
                            }
                    } footer: {
                        Text(L10n.personaMobileHint)
                    }

                    promptEditor(
                        title: L10n.personaTranscribe,
                        text: $transcribePrompt,
                        enabled: $transcribeEnabled
                    )

                    promptEditor(
                        title: L10n.personaRewrite,
                        text: $rewritePrompt,
                        enabled: $rewriteEnabled
                    )

                    Section {
                        Button(persona.isActive ? L10n.personaDeactivate : L10n.personaActivate) {
                            Task {
                                if persona.isActive {
                                    try? await store.deactivateAll()
                                } else {
                                    try? await store.activate(id: persona.id)
                                }
                            }
                        }
                        .tint(persona.isActive ? LobsterWaterPalette.dangerColor : LobsterWaterPalette.accentColor)

                        Button(L10n.btnDelete, role: .destructive) {
                            Task {
                                try? await store.delete(id: persona.id)
                                dismiss()
                            }
                        }
                        .tint(LobsterWaterPalette.dangerColor)
                    }

                    Section {
                        HStack(spacing: 10) {
                            Button(L10n.btnCancel) {
                                dismiss()
                            }
                            .buttonStyle(.bordered)
                            .tint(LobsterWaterPalette.mutedColor)
                            .frame(maxWidth: .infinity)

                            Button(L10n.btnSave) {
                                Task { await save(persona: persona) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(LobsterWaterPalette.accentColor)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationTitle(L10n.personaEditTitle)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear { populateFields(persona) }
                .onChange(of: persona.id) { _, _ in populateFields(persona) }
            } else {
                ContentUnavailableView(
                    L10n.personaEmpty,
                    systemImage: "person.text.rectangle",
                    description: Text(L10n.personaEmptyDesc)
                )
            }
        }
        .background(LobsterWaterPalette.panelColor.ignoresSafeArea())
    }

    private func promptEditor(title: String, text: Binding<String>, enabled: Binding<Bool>) -> some View {
        Section(title) {
            Toggle(L10n.personaActivate, isOn: enabled)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            TextEditor(text: text)
                .frame(minHeight: 110)
                .onChange(of: text.wrappedValue) { _, newValue in
                    if newValue.count > personaPromptMaxLength {
                        text.wrappedValue = String(newValue.prefix(personaPromptMaxLength))
                    }
                    if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        enabled.wrappedValue = false
                    }
                }
            Text("\(text.wrappedValue.count) / \(personaPromptMaxLength)")
                .font(.caption2)
                .foregroundStyle(LobsterWaterPalette.tertiaryColor)
        }
    }

    private func populateFields(_ persona: PersonaItem) {
        name = persona.name
        desc = persona.description ?? ""
        transcribePrompt = persona.prompts.transcribePrompt ?? ""
        transcribeEnabled = persona.prompts.transcribeEnabled && !transcribePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        rewritePrompt = persona.prompts.rewritePrompt ?? ""
        rewriteEnabled = persona.prompts.rewriteEnabled && !rewritePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save(persona: PersonaItem) async {
        isSaving = true
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscribe = transcribePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRewrite = rewritePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompts = PersonaPrompts(
            transcribePrompt: trimmedTranscribe.isEmpty ? nil : trimmedTranscribe,
            transcribeEnabled: transcribeEnabled && !trimmedTranscribe.isEmpty,
            rewritePrompt: trimmedRewrite.isEmpty ? nil : trimmedRewrite,
            rewriteEnabled: rewriteEnabled && !trimmedRewrite.isEmpty,
            intentHint: nil,
            intentEnabled: false
        )
        do {
            try await store.update(
                id: persona.id,
                name: trimmedName,
                description: trimmedDesc.isEmpty ? nil : trimmedDesc,
                prompts: prompts
            )
            dismiss()
        } catch {
            // Keep the editor open so the user can retry.
        }
    }
}

enum PersonaEditMode {
    case create
    case edit(PersonaItem)
}

struct PersonaEditSheet: View {
    let mode: PersonaEditMode
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = PersonaStore.shared

    @State private var name = ""
    @State private var desc = ""
    @State private var transcribePrompt = ""
    @State private var transcribeEnabled = false
    @State private var rewritePrompt = ""
    @State private var rewriteEnabled = false
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.personaName, text: $name)
                        .onChange(of: name) { _, newValue in
                            name = String(newValue.prefix(personaNameMaxLength))
                        }
                    TextField(L10n.personaDesc, text: $desc)
                        .onChange(of: desc) { _, newValue in
                            desc = String(newValue.prefix(personaDescMaxLength))
                        }
                } footer: {
                    Text(L10n.personaMobileHint)
                }

                promptEditor(
                    title: L10n.personaTranscribe,
                    text: $transcribePrompt,
                    enabled: $transcribeEnabled
                )

                promptEditor(
                    title: L10n.personaRewrite,
                    text: $rewritePrompt,
                    enabled: $rewriteEnabled
                )
            }
            .scrollContentBackground(.hidden)
            .background(LobsterWaterPalette.panelColor.ignoresSafeArea())
            .navigationTitle(isCreate ? L10n.personaCreateTitle : L10n.personaEditTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.btnCancel) { dismiss() }
                        .tint(LobsterWaterPalette.mutedColor)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.btnSave) { Task { await save() } }
                        .font(.body.weight(.semibold))
                        .tint(LobsterWaterPalette.accentColor)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .onAppear { populateFields() }
        }
    }

    private var isCreate: Bool {
        if case .create = mode { return true }
        return false
    }

    private func promptEditor(title: String, text: Binding<String>, enabled: Binding<Bool>) -> some View {
        Section(title) {
            Toggle(L10n.personaActivate, isOn: enabled)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            TextEditor(text: text)
                .frame(minHeight: 92)
                .onChange(of: text.wrappedValue) { _, newValue in
                    if newValue.count > personaPromptMaxLength {
                        text.wrappedValue = String(newValue.prefix(personaPromptMaxLength))
                    }
                    let hasPrompt = !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if !hasPrompt {
                        enabled.wrappedValue = false
                    } else if isCreate {
                        enabled.wrappedValue = true
                    }
                }
            Text("\(text.wrappedValue.count) / \(personaPromptMaxLength)")
                .font(.caption2)
                .foregroundStyle(LobsterWaterPalette.tertiaryColor)
        }
    }

    private func populateFields() {
        guard case .edit(let p) = mode else { return }
        guard !p.isBuiltin else { return }
        name = p.name
        desc = p.description ?? ""
        transcribePrompt = p.prompts.transcribePrompt ?? ""
        transcribeEnabled = p.prompts.transcribeEnabled && !transcribePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        rewritePrompt = p.prompts.rewritePrompt ?? ""
        rewriteEnabled = p.prompts.rewriteEnabled && !rewritePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscribe = transcribePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRewrite = rewritePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompts = PersonaPrompts(
            transcribePrompt: trimmedTranscribe.isEmpty ? nil : trimmedTranscribe,
            transcribeEnabled: transcribeEnabled && !trimmedTranscribe.isEmpty,
            rewritePrompt: trimmedRewrite.isEmpty ? nil : trimmedRewrite,
            rewriteEnabled: rewriteEnabled && !trimmedRewrite.isEmpty,
            intentHint: nil,
            intentEnabled: false
        )
        do {
            switch mode {
            case .create:
                try await store.create(
                    name: trimmedName,
                    description: trimmedDesc.isEmpty ? nil : trimmedDesc,
                    prompts: prompts
                )
            case .edit(let p):
                guard !p.isBuiltin else { return }
                try await store.update(
                    id: p.id,
                    name: trimmedName,
                    description: trimmedDesc.isEmpty ? nil : trimmedDesc,
                    prompts: prompts
                )
            }
            dismiss()
        } catch {}
    }
}
