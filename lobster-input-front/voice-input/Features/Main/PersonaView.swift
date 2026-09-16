/// PersonaView.swift
/// 人设管理页面：列表 + 新建 + 编辑详情（含三模块配置 + 独立开关）
import SwiftUI

// MARK: - ModuleDraft（编辑状态草稿）

private struct ModuleDraft {
    var prompt: String
    var enabled: Bool

    init(prompt: String?, enabled: Bool) {
        self.prompt  = prompt ?? ""
        self.enabled = enabled
    }

    var isCustomized: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var trimmed: String?   { let s = prompt.trimmingCharacters(in: .whitespacesAndNewlines); return s.isEmpty ? nil : s }
    var effectiveEnabled: Bool { enabled && isCustomized }
}

// MARK: - PersonaView（列表页）

struct PersonaView: View {
    @ObservedObject private var store = PersonaStore.shared
    @ObservedObject private var lang  = LanguageManager.shared

    @State private var editingItem: PersonaItem? = nil
    @State private var showCreate = false
    @State private var isActivating = false
    @State private var isDeactivating = false

    var body: some View {
        ZStack {
            Cyber.bgTop.ignoresSafeArea()
            VStack(spacing: 0) {
                topBanner
                CyberDivider()
                contentArea
            }
            .frame(maxWidth: CyberLayout.contentMaxW)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await store.load() }
        .sheet(item: $editingItem) { item in
            PersonaEditSheet(item: item)
        }
        .sheet(isPresented: $showCreate) {
            PersonaEditSheet(item: nil)
        }
    }

    // MARK: - Top Banner

    private var topBanner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.pagePersona)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Cyber.textBright)
                Text(L10n.personaPageDesc)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cyber.textGhost)
                    .lineLimit(2)
            }
            Spacer()
            if store.canCreate {
                Button {
                    showCreate = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text(L10n.personaNewPersona).font(.system(size: 13, weight: .medium))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, CyberLayout.padH).padding(.vertical, CyberLayout.padV)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if store.isLoading {
            VStack(spacing: 12) {
                ProgressView().tint(Cyber.accent)
                Text(L10n.loading).font(.system(size: 14)).foregroundStyle(Cyber.textDim)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.personas.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    countBar
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)],
                        spacing: 14
                    ) {
                        ForEach(store.personas) { persona in
                            PersonaListCard(
                                persona: persona,
                                isActionInFlight: isActivating || isDeactivating,
                                onEdit: { if !persona.isBuiltin { editingItem = persona } },
                                onToggleActive: { togglePersona(persona) },
                                onDelete: {
                                    Task { _ = await store.delete(id: persona.id) }
                                }
                            )
                        }
                    }
                }
                .frame(maxWidth: 796)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, CyberLayout.padH)
                .padding(.vertical, CyberLayout.padV)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 40))
                .foregroundStyle(Cyber.faint)
            Text(L10n.personaPageDesc)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Cyber.textGhost)
                .multilineTextAlignment(.center)
            Button {
                showCreate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text(L10n.personaNewPersona)
                }
                .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var countBar: some View {
        HStack {
            Text(L10n.personaCountHint(store.userPersonas.count, personaMaxCount))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Cyber.textGhost)
            Spacer()
            if !store.canCreate {
                Text(L10n.personaLimitReached(personaMaxCount))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Cyber.warning)
            }
        }
    }

    private func togglePersona(_ persona: PersonaItem) {
        guard !isActivating && !isDeactivating else { return }
        if persona.isActive {
            isDeactivating = true
            Task {
                _ = await store.deactivateAll()
                isDeactivating = false
            }
        } else {
            isActivating = true
            Task {
                _ = await store.activate(id: persona.id)
                isActivating = false
            }
        }
    }
}

// MARK: - PersonaEditSheet（新建 / 编辑 Sheet）

private struct PersonaListCard: View {
    let persona: PersonaItem
    let isActionInFlight: Bool
    let onEdit: () -> Void
    let onToggleActive: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false
    @State private var isHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            Spacer(minLength: 10)
            if let desc = persona.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(Cyber.textDim)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
            }
            promptSummary
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: CyberLayout.corner))
        .overlay(
            RoundedRectangle(cornerRadius: CyberLayout.corner)
                .stroke(cardBorder, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: CyberLayout.corner))
        .onTapGesture {
            if !isActionInFlight { onToggleActive() }
        }
        .onHover { isHover = $0 }
        .animation(.easeInOut(duration: 0.16), value: persona.isActive)
        .confirmationDialog(L10n.deleteConfirm, isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L10n.delete, role: .destructive) { onDelete() }
            Button(L10n.cancel, role: .cancel) {}
        }
    }

    private var hasAnyPrompt: Bool {
        !persona.isBuiltin && (
        persona.prompts.transcribePrompt != nil ||
        persona.prompts.rewritePrompt != nil ||
        persona.prompts.intentHint != nil)
    }

    private var cardHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(persona.name.first ?? " "))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Cyber.textBright)
                .frame(width: 28, height: 28)
                .background(Cyber.sidebarBg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Cyber.borderDim, lineWidth: 1))
            Text(persona.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Cyber.textBright)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if persona.isActive {
                Circle()
                    .fill(Cyber.accent)
                    .frame(width: 8, height: 8)
                    .padding(.top, 10)
            }
            actionButtons
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if !persona.isBuiltin {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(Cyber.textGhost)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("编辑")

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(Cyber.textGhost)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var promptSummary: some View {
        HStack(spacing: 10) {
            if hasAnyPrompt {
                promptDot(icon: "waveform", color: Cyber.accent, enabled: persona.prompts.transcribeEnabled, hasContent: persona.prompts.transcribePrompt != nil)
                promptDot(icon: "pencil", color: Cyber.accent, enabled: persona.prompts.rewriteEnabled, hasContent: persona.prompts.rewritePrompt != nil)
                promptDot(icon: "sparkles", color: Cyber.warning, enabled: persona.prompts.intentEnabled, hasContent: persona.prompts.intentHint != nil)
                Spacer()
            }
        }
    }

    private func promptDot(icon: String, color: Color, enabled: Bool, hasContent: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(enabled ? color : Cyber.textGhost)
            Circle()
                .fill(enabled ? color : (hasContent ? Cyber.textGhost.opacity(0.35) : Color.clear))
                .frame(width: 5, height: 5)
        }
    }

    private var cardBackground: Color {
        if persona.isActive { return Cyber.accentSoft }
        if isHover { return Cyber.hoverBg }
        return Cyber.panelBg
    }

    private var cardBorder: Color {
        if persona.isActive { return Cyber.accentRing }
        if isHover { return Cyber.lineStrong }
        return Cyber.borderDim
    }
}

// MARK: - PersonaEditSheet（新建 / 编辑 Sheet）

private struct PersonaEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PersonaStore.shared

    let item: PersonaItem?

    @State private var name: String
    @State private var desc: String
    @State private var transcribe: ModuleDraft
    @State private var rewrite:    ModuleDraft
    @State private var intent:     ModuleDraft
    @State private var isSaving = false

    init(item: PersonaItem?) {
        self.item = item
        _name       = State(initialValue: item?.name ?? "")
        _desc       = State(initialValue: item?.description ?? "")
        _transcribe = State(initialValue: ModuleDraft(
            prompt: item?.prompts.transcribePrompt, enabled: item?.prompts.transcribeEnabled ?? false))
        _rewrite    = State(initialValue: ModuleDraft(
            prompt: item?.prompts.rewritePrompt,    enabled: item?.prompts.rewriteEnabled    ?? false))
        _intent     = State(initialValue: ModuleDraft(
            prompt: item?.prompts.intentHint,       enabled: item?.prompts.intentEnabled     ?? false))
    }

    private var isCreate: Bool { item == nil }
    private var nameOk: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ZStack {
            Cyber.panelBg.ignoresSafeArea()
            VStack(spacing: 0) {
                sheetHeader
                CyberDivider()
                ScrollView {
                    VStack(spacing: 20) {
                        metaSection
                        PersonaModuleCard(
                            icon: "waveform", title: L10n.personaTranscribeTitle,
                            description: L10n.personaTranscribeDesc,
                            accentColor: Cyber.accent,
                            placeholder: L10n.personaTranscribePlaceholder,
                            maxLength: personaPromptMaxLength, draft: $transcribe
                        )
                        PersonaModuleCard(
                            icon: "pencil.and.sparkles", title: L10n.personaRewriteTitle,
                            description: L10n.personaRewriteDesc,
                            accentColor: Cyber.accent,
                            placeholder: L10n.personaRewritePlaceholder,
                            maxLength: personaPromptMaxLength, draft: $rewrite
                        )
                        PersonaModuleCard(
                            icon: "brain.head.profile", title: L10n.personaIntentTitle,
                            description: L10n.personaIntentDesc,
                            accentColor: Cyber.warning,
                            placeholder: L10n.personaIntentPlaceholder,
                            maxLength: personaPromptMaxLength, draft: $intent
                        )
                    }
                    .padding(.horizontal, CyberLayout.padH)
                    .padding(.vertical, CyberLayout.padV)
                }
            }
        }
        .frame(minWidth: 540, minHeight: 600)
    }

    private var sheetHeader: some View {
        HStack {
            Button(L10n.cancel) { dismiss() }
                .buttonStyle(NeonButtonStyle(color: Cyber.textDim))
            Spacer()
            Text(isCreate ? L10n.personaNewPersona : name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Cyber.textBright)
            Spacer()
            Button {
                isSaving = true
                Task {
                    let prompts = PersonaPrompts(
                        transcribePrompt: transcribe.trimmed, transcribeEnabled: transcribe.effectiveEnabled,
                        rewritePrompt:    rewrite.trimmed,    rewriteEnabled:    rewrite.effectiveEnabled,
                        intentHint:       intent.trimmed,     intentEnabled:     intent.effectiveEnabled
                    )
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedDesc = desc.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isCreate {
                        _ = await store.create(
                            name: trimmedName,
                            description: trimmedDesc.isEmpty ? nil : trimmedDesc,
                            prompts: prompts
                        )
                    } else if let id = item?.id {
                        _ = await store.update(
                            id: id, name: trimmedName,
                            description: trimmedDesc.isEmpty ? nil : trimmedDesc,
                            prompts: prompts
                        )
                    }
                    isSaving = false
                    dismiss()
                }
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().scaleEffect(0.7).tint(Cyber.accent) }
                    Text(L10n.save).font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!nameOk || isSaving)
        }
        .padding(.horizontal, CyberLayout.padH).padding(.vertical, CyberLayout.padV)
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.personaNameLabel)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Cyber.textGhost)
                TextField(L10n.personaNamePlaceholder, text: $name)
                    .font(.system(size: 14)).foregroundStyle(Cyber.textBright)
                    .textFieldStyle(.plain).padding(10)
                    .background(Cyber.panelBg)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(name.isEmpty ? Cyber.borderDim : Cyber.accent.opacity(0.5), lineWidth: 1))
                    .onChange(of: name) { v in
                        if v.count > personaNameMaxLength { name = String(v.prefix(personaNameMaxLength)) }
                    }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.personaDescLabel)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Cyber.textGhost)
                TextField(L10n.personaDescPlaceholder, text: $desc)
                    .font(.system(size: 13)).foregroundStyle(Cyber.textBright)
                    .textFieldStyle(.plain).padding(10)
                    .background(Cyber.panelBg)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Cyber.borderDim, lineWidth: 1))
                    .onChange(of: desc) { v in
                        if v.count > personaDescMaxLength { desc = String(v.prefix(personaDescMaxLength)) }
                    }
            }
        }
        .padding(14)
        .background(Cyber.panelBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Cyber.borderDim, lineWidth: 1))
    }
}

// MARK: - PersonaModuleCard（提示词编辑卡片，供 PersonaEditSheet 使用）

private struct PersonaModuleCard: View {
    let icon: String
    let title: String
    let description: String
    let accentColor: Color
    let placeholder: String
    let maxLength: Int
    @Binding var draft: ModuleDraft

    private var charCount: Int { draft.prompt.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            CyberDivider()
            cardBody
        }
        .neonCard()
        .overlay(
            RoundedRectangle(cornerRadius: CyberLayout.corner)
                .stroke(
                    draft.effectiveEnabled ? accentColor.opacity(0.4)
                    : draft.isCustomized   ? accentColor.opacity(0.2)
                    : Cyber.borderDim,
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.15), value: draft.effectiveEnabled)
    }

    private var cardHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Cyber.textBright)
                    statusBadge
                }
                Text(description)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Cyber.textGhost)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if draft.isCustomized {
                Toggle("", isOn: Binding(
                    get: { draft.enabled },
                    set: { draft.enabled = $0 }
                ))
                .toggleStyle(NeonToggleStyle(color: accentColor))
                .help(draft.enabled ? L10n.personaDisableHint : L10n.personaEnableHint)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if draft.effectiveEnabled {
            Text(L10n.personaActive)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(accentColor)
        } else if draft.isCustomized {
            Text(L10n.personaCustomized)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Cyber.textGhost.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(Cyber.textGhost)
        } else {
            Text(L10n.personaUsingBuiltin)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Cyber.textGhost.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(Cyber.textGhost.opacity(0.6))
        }
    }

    private var cardBody: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.prompt)
                    .font(.system(size: 14))
                    .foregroundStyle(Cyber.textBright)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 220)
                    .padding(12)
                    .onChange(of: draft.prompt) { newVal in
                        if newVal.count > maxLength { draft.prompt = String(newVal.prefix(maxLength)) }
                        if newVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            draft.enabled = false
                        }
                    }
                if draft.prompt.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(Cyber.textGhost.opacity(0.4))
                        .padding(.horizontal, 16).padding(.vertical, 20)
                        .allowsHitTesting(false)
                }
            }
            .background(Cyber.panelBg)

            HStack {
                Text(L10n.charCount(charCount, maxLength))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(charCount > maxLength - 100 ? Cyber.warning : Cyber.textGhost)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
}

// MARK: - NeonToggleStyle

private struct NeonToggleStyle: ToggleStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(configuration.isOn ? color.opacity(0.2) : Cyber.panelBg)
                    .frame(width: 44, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(configuration.isOn ? color.opacity(0.6) : Cyber.borderDim, lineWidth: 1))
                Circle()
                    .fill(configuration.isOn ? color : Cyber.textGhost.opacity(0.4))
                    .frame(width: 18, height: 18)
                    .offset(x: configuration.isOn ? 10 : -10)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
    }
}
