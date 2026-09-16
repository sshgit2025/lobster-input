/// DictionaryStore.swift
/// 热词词典数据管理（单例 ObservableObject），驱动 DictionaryView 的列表展示与 CRUD 操作。
/// 支持点击式翻页和关键词模糊搜索，无数量上限。
import Foundation
import Combine

@MainActor
final class DictionaryStore: ObservableObject {

    static let shared = DictionaryStore()
    private init() {}

    static let pageSize      = 50
    static let maxWordLength = 20

    // MARK: - 列表状态

    @Published private(set) var hotwords: [HotWordItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    /// 当前页码（1-indexed）
    @Published private(set) var currentPage = 1
    /// 当前搜索词对应的总条数
    @Published private(set) var total = 0
    /// 总页数
    var totalPages: Int { max(1, Int(ceil(Double(total) / Double(Self.pageSize)))) }
    var hasPrev: Bool { currentPage > 1 }
    var hasNext: Bool { currentPage < totalPages }

    // MARK: - 搜索状态

    /// 当前生效的搜索关键词（由 View 写入，Store 监听后自动触发重新加载）
    @Published var searchText: String = ""

    private var searchTask: Task<Void, Never>?
    private var loadedSearchText: String = ""

    private let api = APIClient.shared

    // MARK: - 加载

    /// 初次进入页面或手动刷新时调用，重置到第1页
    func load() async {
        currentPage = 1
        loadedSearchText = searchText
        await fetchPage(page: 1, search: searchText)
    }

    /// 点击式翻页：跳转到指定页（保持当前搜索词不变）
    func goToPage(_ page: Int) async {
        guard page >= 1, page <= totalPages else { return }
        currentPage = page
        await fetchPage(page: page, search: loadedSearchText)
    }

    func prevPage() async { await goToPage(currentPage - 1) }
    func nextPage() async { await goToPage(currentPage + 1) }

    /// 搜索词变化时调用（防抖 300ms）
    func onSearchChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            currentPage = 1
            loadedSearchText = searchText
            await fetchPage(page: 1, search: searchText)
        }
    }

    // MARK: - 私有加载

    private func fetchPage(page: Int, search: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let resp = try await api.listHotWords(page: page, pageSize: Self.pageSize, search: search)
            hotwords    = resp.hotwords
            total       = resp.total
            currentPage = page
        } catch {
            errorMessage = apiErrorMessage(error)
        }
        isLoading = false
    }

    // MARK: - CRUD

    func create(word: String) async -> Bool {
        do {
            let item = try await api.createHotWord(word: word)
            // 新词插入当前页头部；若当前是搜索状态且新词不匹配搜索词则不插入
            let keyword = loadedSearchText.lowercased()
            if keyword.isEmpty || item.word.lowercased().contains(keyword) {
                hotwords.insert(item, at: 0)
            }
            total += 1
            return true
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
    }

    func update(id: String, word: String) async -> Bool {
        do {
            let updated = try await api.updateHotWord(id: id, word: word)
            if let idx = hotwords.firstIndex(where: { $0.id == id }) {
                hotwords[idx] = updated
            }
            return true
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
    }

    func delete(id: String) async -> Bool {
        do {
            try await api.deleteHotWord(id: id)
            hotwords.removeAll { $0.id == id }
            total = max(0, total - 1)
            // 删完当前页最后一条时自动退到上一页
            if hotwords.isEmpty && currentPage > 1 {
                await goToPage(currentPage - 1)
            }
            return true
        } catch {
            errorMessage = apiErrorMessage(error)
            return false
        }
    }
}
