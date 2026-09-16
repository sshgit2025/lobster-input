/// DictionaryView.swift
/// 热词词典管理页面 — 油绿科技风格，支持模糊搜索和点击式翻页。
import SwiftUI

struct DictionaryView: View {

    @ObservedObject private var store = DictionaryStore.shared
    @State private var showSheet = false
    @State private var editingItem: HotWordItem?
    @State private var deleteTarget: HotWordItem?
    @State private var showDeleteAlert = false
    @ObservedObject private var lang = LanguageManager.shared

    var body: some View {
        ZStack {
            Cyber.bgTop.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                CyberDivider()
                searchBar
                CyberDivider()
                content
                if store.totalPages > 1 {
                    CyberDivider()
                    pagination
                }
            }
            .frame(maxWidth: CyberLayout.contentMaxW)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await store.load() }
        .sheet(isPresented: $showSheet) {
            HotWordEditSheet(item: editingItem, onSave: { word in await saveHotWord(word: word) })
        }
        .alert(L10n.deleteConfirm, isPresented: $showDeleteAlert) {
            Button(L10n.cancel, role: .cancel) {}
            Button(L10n.delete, role: .destructive) {
                if let item = deleteTarget { Task { await store.delete(id: item.id) } }
            }
        } message: {
            if let item = deleteTarget { Text(L10n.confirmDeleteHotword(item.word)) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(L10n.pageDict)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Cyber.textBright)
                    if store.total > 0 {
                        CountBadge(text: "\(store.total)")
                    }
                }
                Text(L10n.dictDesc)
                    .font(.system(size: 13)).foregroundStyle(Cyber.textGhost)
            }
            Spacer()
            Button {
                editingItem = nil; showSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 13))
                    Text(L10n.add).font(.system(size: 13, weight: .medium))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, CyberLayout.padH).padding(.vertical, CyberLayout.padV)
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Cyber.textDim)
            TextField(L10n.dictSearchPlaceholder, text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Cyber.textBright)
                .onChange(of: store.searchText) { _ in store.onSearchChanged() }
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                    store.onSearchChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Cyber.textDim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CyberLayout.padH)
        .padding(.vertical, 10)
    }

    // MARK: - 列表内容

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            VStack(spacing: 12) {
                ProgressView().tint(Cyber.accent)
                Text(L10n.loading).font(.system(size: 14)).foregroundStyle(Cyber.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.hotwords.isEmpty && store.searchText.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "text.book.closed").font(.system(size: 40)).foregroundStyle(Cyber.faint)
                Text(L10n.dictEmpty).font(.system(size: 15, weight: .medium)).foregroundStyle(Cyber.textGhost)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.hotwords.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 36)).foregroundStyle(Cyber.faint)
                Text(L10n.dictNoResult).font(.system(size: 14)).foregroundStyle(Cyber.textGhost)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)],
                    spacing: 12
                ) {
                    ForEach(store.hotwords) { item in
                        HotWordRow(item: item,
                                   onEdit: { editingItem = item; showSheet = true },
                                   onDelete: { deleteTarget = item; showDeleteAlert = true })
                    }
                }
                .frame(maxWidth: 796)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, CyberLayout.padH)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - 点击式翻页栏

    private var pagination: some View {
        HStack(spacing: 16) {
            Button {
                Task { await store.prevPage() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.hasPrev ? Cyber.accent : Cyber.textGhost)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(store.hasPrev ? Cyber.accent.opacity(0.5) : Cyber.borderDim.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!store.hasPrev || store.isLoading)

            Text(L10n.dictPageInfo(store.currentPage, store.totalPages))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Cyber.textDim)
                .monospacedDigit()

            Button {
                Task { await store.nextPage() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.hasNext ? Cyber.accent : Cyber.textGhost)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(store.hasNext ? Cyber.accent.opacity(0.5) : Cyber.borderDim.opacity(0.3), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!store.hasNext || store.isLoading)
        }
        .padding(.horizontal, CyberLayout.padH)
        .padding(.vertical, 10)
    }

    // MARK: - 保存

    private func saveHotWord(word: String) async {
        if let editing = editingItem { _ = await store.update(id: editing.id, word: word) }
        else { _ = await store.create(word: word) }
        showSheet = false
    }
}

// MARK: - 热词行

private struct HotWordRow: View {
    let item: HotWordItem; let onEdit: () -> Void; let onDelete: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text(item.word)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Cyber.textBright)
                .lineLimit(1)
            Spacer()
            Button(action: onEdit) { Image(systemName: "pencil").font(.system(size: 13)) }
                .buttonStyle(.plain)
                .foregroundStyle(Cyber.textGhost)
                .frame(width: 26, height: 26)
            Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 13)) }
                .buttonStyle(.plain)
                .foregroundStyle(Cyber.textGhost)
                .frame(width: 26, height: 26)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(minHeight: 46)
        .background(Cyber.panelBg, in: RoundedRectangle(cornerRadius: CyberLayout.cornerSm))
        .overlay(RoundedRectangle(cornerRadius: CyberLayout.cornerSm).stroke(Cyber.borderDim, lineWidth: 1))
    }
}

// MARK: - 编辑/新建 Sheet

private struct HotWordEditSheet: View {
    let item: HotWordItem?; let onSave: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var word = ""; @State private var isSaving = false
    private let maxLen = DictionaryStore.maxWordLength
    private var isEditing: Bool { item != nil }
    private var trimmed: String { word.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { !trimmed.isEmpty && trimmed.count <= maxLen }

    var body: some View {
        ZStack {
            Cyber.panelBg.ignoresSafeArea()
            VStack(spacing: 24) {
                Text(isEditing ? L10n.editHotword : L10n.newHotword)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Cyber.textBright)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.dictStandardWord)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Cyber.textDim)
                        Spacer()
                        Text(L10n.charCount(trimmed.count, maxLen)).font(.system(size: 12))
                            .foregroundColor(trimmed.count > maxLen ? Cyber.danger : Cyber.textGhost)
                    }
                    TextField(L10n.dictPlaceholder, text: $word).textFieldStyle(CyberTextFieldStyle())
                }
                HStack {
                    Button(L10n.cancel) { dismiss() }
                        .buttonStyle(NeonButtonStyle(color: Cyber.textDim))
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(isEditing ? L10n.save : L10n.add) {
                        isSaving = true
                        Task { await onSave(trimmed); isSaving = false }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || isSaving)
                }
            }.padding(28)
        }
        .frame(width: CyberLayout.sheetW)
        .onAppear { if let item { word = item.word } }
    }
}
