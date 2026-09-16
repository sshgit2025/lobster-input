/// HistoryStore.swift
/// 录音历史记录本地持久化管理器（单例）。
///
/// ## 存储架构（增量化 + 分页）
/// 历史记录采用「每条一文件」存储，每条记录写到
///   ~/Library/Application Support/<bundleId>/VoiceInputHistory/<email_hash>/records/<时间戳>_<id>.json
/// 音频文件保存在同目录下的 AudioFiles/ 子目录。
///   - 新增 / 更新 / 删除 都只读写「单条记录文件」，绝不重写整库，写放大与延迟与历史总量无关。
///   - 文件名前缀内嵌 createdAt 毫秒时间戳，目录列表按文件名倒序即得「最新在前」的顺序，
///     分页时只需读取「当前页」的少量文件，避免整库常驻内存与整列表 diff。
///   - createdAt 创建后不可变，因此任何一条记录的文件名都可由 (createdAt, id) 直接推导，
///     更新/删除无需额外索引即可定位文件。
///
/// ## 安全
/// 存储目录从旧版的 ~/Documents 迁移到 ~/Library/Application Support，
/// 不再受 iCloud「桌面与文稿」同步影响；首次加载会把旧 Documents 数据安全迁移过来并清理。
///
/// 每个账号完全独立隔离（email SHA256 前 16 位做目录名），无任何跨账号读取路径。
import Foundation
import Combine
import CryptoKit

private actor HistoryStorageIO {

    /// 读取某账号指定分页（按 createdAt 倒序）的完整记录，并返回记录总数。
    /// 首次访问时会触发一次「旧 Documents → Application Support」的迁移。
    func loadPage(email: String, offset: Int, limit: Int) -> (records: [RecordingHistory], total: Int) {
        deleteLegacyIfNeeded(email: email)
        let dir = HistoryStoragePaths.recordsDir(for: email)
        let names = sortedRecordFileNamesDesc(in: dir)
        let total = names.count
        guard offset < total, limit > 0 else { return ([], total) }
        let pageNames = names[offset..<min(offset + limit, total)]
        let records = pageNames.compactMap { readRecord(dir: dir, fileName: $0) }
        return (records, total)
    }

    /// 写入/更新单条记录文件（O(1)，不触碰其它记录）。
    func save(_ record: RecordingHistory, email: String) {
        let dir = HistoryStoragePaths.recordsDir(for: email)
        let url = dir.appendingPathComponent(HistoryStoragePaths.fileName(for: record))
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 按 id 从磁盘读出记录、应用状态更新后写回（用于该记录已被分页移出内存的兜底路径，
    /// 例如 OpenClaw 长任务完成时记录可能已不在已加载页内）。返回是否命中。
    @discardableResult
    func applyUpdate(id: String, email: String, status: RecognitionStatus,
                     transcript: String?, result: String?, error: String?,
                     retryable: Bool, actionType: String?) -> Bool {
        let dir = HistoryStoragePaths.recordsDir(for: email)
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .first(where: { $0.hasSuffix("_\(id).json") }),
              var record = readRecord(dir: dir, fileName: name) else {
            return false
        }
        if let startedAt = record.processStartedAt {
            record.processingDuration = Date().timeIntervalSince(startedAt)
        }
        record.status = status
        if let transcript { record.transcript = transcript }
        if let result { record.result = result }
        if let actionType { record.actionType = actionType }
        record.errorMessage = error
        record.retryable = retryable
        save(record, email: email)
        return true
    }

    /// 删除单条记录文件。
    func deleteRecordFile(_ record: RecordingHistory, email: String) {
        let dir = HistoryStoragePaths.recordsDir(for: email)
        let url = dir.appendingPathComponent(HistoryStoragePaths.fileName(for: record))
        try? FileManager.default.removeItem(at: url)
    }

    func deleteFiles(paths: [String]) {
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    func persistAudio(from tempURL: URL, email: String) -> String? {
        let dest = audioDirectory(for: email).appendingPathComponent(tempURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: tempURL, to: dest)
            return dest.path
        } catch {
            print("[HistoryStorageIO] Failed to persist audio: \(error)")
            return nil
        }
    }

    func audioDirectory(for email: String) -> URL {
        let dir = HistoryStoragePaths.userBaseDir(for: email).appendingPathComponent("AudioFiles")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 按保留策略清理：删除 createdAt 早于 cutoff 的记录文件及其音频，返回清理后剩余记录总数。
    /// 时间过滤只依赖文件名内嵌的时间戳，无需读取记录体；仅对将被删除的少量记录读体以取音频路径。
    func purgeOlderThan(_ cutoff: Date, email: String) -> Int {
        let dir = HistoryStoragePaths.recordsDir(for: email)
        let names = sortedRecordFileNamesDesc(in: dir)
        let cutoffMillis = cutoff.timeIntervalSince1970 * 1000
        var remaining = 0
        for name in names {
            if (Self.timestampMillis(fromFileName: name) ?? .greatestFiniteMagnitude) < cutoffMillis {
                if let record = readRecord(dir: dir, fileName: name), let audioPath = record.audioFilePath {
                    try? FileManager.default.removeItem(atPath: audioPath)
                }
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            } else {
                remaining += 1
            }
        }
        return remaining
    }

    /// 清空某账号全部记录与音频（用于 retention = never）。
    func purgeAll(email: String) {
        let recordsDir = HistoryStoragePaths.recordsDir(for: email)
        try? FileManager.default.removeItem(at: recordsDir)
        let audioDir = HistoryStoragePaths.userBaseDir(for: email).appendingPathComponent("AudioFiles")
        try? FileManager.default.removeItem(at: audioDir)
    }

    /// 孤儿音频对账：遍历全部记录 JSON 收集被引用的音频文件名，扫描 AudioFiles 目录，
    /// 删除没有任何记录引用的孤儿音频（记录引用了但音频不存在的情况无需处理）。
    /// 健壮性：只删修改时间早于 5 分钟前的文件，避免误删正在持久化中的音频。
    func reconcileOrphanAudio(email: String) {
        let recordsDir = HistoryStoragePaths.recordsDir(for: email)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: recordsDir.path) else { return }
        var referenced = Set<String>()
        for name in names where name.hasSuffix(".json") {
            if let record = readRecord(dir: recordsDir, fileName: name), let path = record.audioFilePath {
                referenced.insert(URL(fileURLWithPath: path).lastPathComponent)
            }
        }
        let audioDir = audioDirectory(for: email)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-300)
        for f in files where !referenced.contains(f.lastPathComponent) {
            let mdate = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mdate, mdate > cutoff { continue }
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: - 内部

    private func sortedRecordFileNamesDesc(in dir: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted(by: >)
    }

    private func readRecord(dir: URL, fileName: String) -> RecordingHistory? {
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(RecordingHistory.self, from: data) else {
            return nil
        }
        return record
    }

    private static func timestampMillis(fromFileName name: String) -> Double? {
        guard let underscore = name.firstIndex(of: "_") else { return nil }
        return Double(name[name.startIndex..<underscore])
    }

    /// 从未上线、均为测试数据，不迁移老历史：直接删除旧 ~/Documents 历史目录
    /// （含明文转写/音频），既清掉敏感残留，又避免老数据混入。新存储从空开始。
    private func deleteLegacyIfNeeded(email: String) {
        let legacyBase = HistoryStoragePaths.legacyUserBaseDir(for: email)
        if FileManager.default.fileExists(atPath: legacyBase.path) {
            try? FileManager.default.removeItem(at: legacyBase)
        }
    }
}

private enum HistoryStoragePaths {
    static func userDirName(for email: String) -> String {
        let digest = SHA256.hash(data: Data(email.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// 新存储根：~/Library/Application Support/<bundleId>/VoiceInputHistory/<hash>/
    static func userBaseDir(for email: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleId = Bundle.main.bundleIdentifier ?? "ssh2026.voice-input"
        let dir = appSupport
            .appendingPathComponent(bundleId, isDirectory: true)
            .appendingPathComponent("VoiceInputHistory", isDirectory: true)
            .appendingPathComponent(userDirName(for: email), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func recordsDir(for email: String) -> URL {
        let dir = userBaseDir(for: email).appendingPathComponent("records", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 单条记录文件名：<16 位零填充毫秒时间戳>_<id>.json。
    /// 零填充保证「文件名字典序 == createdAt 时序」，倒序即最新在前。
    static func fileName(for record: RecordingHistory) -> String {
        let millis = (record.createdAt.timeIntervalSince1970 * 1000).rounded()
        let stamp = String(format: "%016.0f", millis)
        return "\(stamp)_\(record.id).json"
    }

    // MARK: 旧版（~/Documents）路径，仅用于清除旧测试数据
    static func legacyUserBaseDir(for email: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("VoiceInputHistory")
            .appendingPathComponent(userDirName(for: email))
    }
}

@MainActor
final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()
    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.retentionKey) ?? RetentionPolicy.forever.rawValue
        self.retentionPolicy = RetentionPolicy(rawValue: raw) ?? .forever
    }

    /// 当前已加载到内存的记录（按 createdAt 倒序，最新在前）。
    /// 注意：这是「已加载的分页」而非全量；`totalCount` 才是磁盘上的记录总数。
    @Published private(set) var records: [RecordingHistory] = []
    @Published private(set) var isLoading = false
    /// 磁盘上的记录总数（用于 UI 显示与「加载更多」判定）。
    @Published private(set) var totalCount = 0

    /// 是否还有未加载到内存的更早记录。
    var hasMore: Bool { records.count < totalCount }

    /// 每页加载条数。
    static let pageSize = 20

    private let storage = HistoryStorageIO()
    private var loadGeneration = 0
    private var isLoadingMore = false

    // MARK: - Retention Policy

    enum RetentionPolicy: String, CaseIterable, Identifiable {
        case forever = "forever"
        case thirtyDays = "30days"
        case sevenDays = "7days"
        case oneDay = "1day"
        case never = "never"

        var id: String { rawValue }

        var maxAge: TimeInterval? {
            switch self {
            case .forever: return nil
            case .thirtyDays: return 30 * 24 * 3600
            case .sevenDays: return 7 * 24 * 3600
            case .oneDay: return 24 * 3600
            case .never: return 0
            }
        }

        var localizedName: String {
            switch self {
            case .forever: return L10n.historyRetentionForever
            case .thirtyDays: return L10n.historyRetention30Days
            case .sevenDays: return L10n.historyRetention7Days
            case .oneDay: return L10n.historyRetention1Day
            case .never: return L10n.historyRetentionNever
            }
        }
    }

    private static let retentionKey = "historyRetentionPolicy"

    @Published var retentionPolicy: RetentionPolicy {
        didSet {
            UserDefaults.standard.set(retentionPolicy.rawValue, forKey: Self.retentionKey)
            applyRetentionPolicy()
        }
    }

    // MARK: - Paths（全部 email 强依赖，无 fallback）

    /// 当前登录账号的音频目录。未登录时返回 nil，调用方负责判断。
    var audioDirectory: URL? {
        guard let email = AuthStore.shared.email else { return nil }
        return HistoryStoragePaths.userBaseDir(for: email).appendingPathComponent("AudioFiles")
    }

    // MARK: - CRUD

    /// 新增一条记录（录音完成后立即调用）。只写单条记录文件。
    func add(_ record: RecordingHistory) {
        if retentionPolicy == .never { return }
        guard let email = AuthStore.shared.email else { return }
        records.insert(record, at: 0)
        totalCount += 1
        Task { [storage] in await storage.save(record, email: email) }
        reconcileOrphanAudioIfNeeded()
    }

    private static let lastReconcileKey = "historyAudioLastReconcile"

    /// 跨天异步孤儿音频对账：每次对话(新增记录)时检测与上次是否同一天;跨天才触发,
    /// 交给后台 actor 扫描 AudioFiles 删除无记录引用的孤儿音频。一天最多一次,不阻塞主线程。
    func reconcileOrphanAudioIfNeeded() {
        guard let email = AuthStore.shared.email else { return }
        let today = Self.dayKey(Date())
        if UserDefaults.standard.string(forKey: Self.lastReconcileKey) == today { return }
        UserDefaults.standard.set(today, forKey: Self.lastReconcileKey)
        Task { [storage] in await storage.reconcileOrphanAudio(email: email) }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// 标记开始处理（记录开始时间）。只重写该条记录文件。
    func markProcessingStarted(id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].status = .processing
        records[idx].processStartedAt = Date()
        persist(records[idx])
    }

    /// 更新记录状态（识别结果回来后调用，自动计算耗时）。只重写该条记录文件。
    func update(id: String, status: RecognitionStatus, transcript: String? = nil,
                result: String? = nil, error: String? = nil, retryable: Bool = true,
                actionType: String? = nil) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            // 记录已被分页移出内存：走磁盘读改写兜底，保证状态不丢失。
            guard let email = AuthStore.shared.email else { return }
            Task { [storage] in
                await storage.applyUpdate(id: id, email: email, status: status,
                                          transcript: transcript, result: result, error: error,
                                          retryable: retryable, actionType: actionType)
            }
            return
        }
        if let startedAt = records[idx].processStartedAt {
            records[idx].processingDuration = Date().timeIntervalSince(startedAt)
        }
        records[idx].status = status
        if let t = transcript { records[idx].transcript = t }
        if let r = result     { records[idx].result = r }
        if let a = actionType { records[idx].actionType = a }
        records[idx].errorMessage = error
        records[idx].retryable = retryable
        persist(records[idx])
    }

    /// 删除一条记录（同时可选删除音频文件）。只删除该条记录文件。
    func delete(id: String, deleteAudio: Bool = false) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let record = records[idx]
        let deletedAudioPath = deleteAudio ? record.audioFilePath : nil
        records.remove(at: idx)
        totalCount = max(0, totalCount - 1)
        guard let email = AuthStore.shared.email else { return }
        Task { [storage] in
            await storage.deleteRecordFile(record, email: email)
            if let deletedAudioPath {
                await storage.deleteFiles(paths: [deletedAudioPath])
            }
        }
    }

    /// 仅删除某条记录的音频文件（保留文字记录）。只重写该条记录文件。
    func deleteAudioFile(id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let deletedAudioPath = records[idx].audioFilePath
        records[idx].audioFilePath = nil
        persist(records[idx])
        if let deletedAudioPath {
            Task { [storage] in await storage.deleteFiles(paths: [deletedAudioPath]) }
        }
    }

    /// 将临时音频文件移动到持久化目录，返回新路径
    func persistAudio(from tempURL: URL) async -> String? {
        guard let email = AuthStore.shared.email else { return nil }
        return await storage.persistAudio(from: tempURL, email: email)
    }

    // MARK: - 分页加载

    /// 唯一的历史记录加载入口（加载第一页），由 AuthStore.save() 在登录成功后调用。
    /// 无迁移逻辑暴露给调用方，无 fallback，严格按当前登录账号目录读取。
    func reloadForCurrentUser() {
        guard let email = AuthStore.shared.email else {
            records = []
            totalCount = 0
            isLoading = false
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        records = []
        totalCount = 0
        isLoading = true
        let pageSize = Self.pageSize
        Task { [storage] in
            let page = await storage.loadPage(email: email, offset: 0, limit: pageSize)
            await MainActor.run { [weak self] in
                guard let self,
                      self.loadGeneration == generation,
                      AuthStore.shared.email == email else { return }
                self.records = page.records
                self.totalCount = page.total
                self.isLoading = false
                self.cleanupStaleProcessing()
                self.applyRetentionPolicy()
            }
        }
    }

    /// 加载下一页（追加到 records 尾部）。
    func loadMore() {
        guard !isLoadingMore, hasMore, let email = AuthStore.shared.email else { return }
        isLoadingMore = true
        let generation = loadGeneration
        let offset = records.count
        let pageSize = Self.pageSize
        Task { [storage] in
            let page = await storage.loadPage(email: email, offset: offset, limit: pageSize)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoadingMore = false
                guard self.loadGeneration == generation,
                      AuthStore.shared.email == email else { return }
                // 去重后追加（防止加载期间有新记录插入导致 offset 漂移而重复）
                let existingIDs = Set(self.records.map(\.id))
                self.records.append(contentsOf: page.records.filter { !existingIDs.contains($0.id) })
                self.totalCount = max(self.totalCount, page.total)
            }
        }
    }

    /// 退出登录时调用：清空内存，磁盘文件保留（下次登录可恢复）
    func clearMemory() {
        loadGeneration += 1
        records = []
        totalCount = 0
        isLoading = false
    }

    // MARK: - Persistence

    /// 写入单条记录文件（增量，不触碰整库）。
    private func persist(_ record: RecordingHistory) {
        guard let email = AuthStore.shared.email else { return }
        Task { [storage] in await storage.save(record, email: email) }
    }

    private func cleanupStaleProcessing() {
        for i in records.indices {
            if records[i].status == .processing || records[i].status == .pending {
                records[i].status = .failed
                records[i].errorMessage = nil
                persist(records[i])
            }
        }
    }

    private func applyRetentionPolicy() {
        guard let email = AuthStore.shared.email else { return }
        switch retentionPolicy {
        case .forever:
            return
        case .never:
            records.removeAll()
            totalCount = 0
            Task { [storage] in await storage.purgeAll(email: email) }
        default:
            guard let maxAge = retentionPolicy.maxAge else { return }
            let cutoff = Date().addingTimeInterval(-maxAge)
            // 内存中（已加载页）先即时移除过期项，磁盘清理交给后台 actor 按文件名时间戳批量删除。
            records.removeAll { $0.createdAt < cutoff }
            let generation = loadGeneration
            Task { [storage] in
                let remaining = await storage.purgeOlderThan(cutoff, email: email)
                await MainActor.run { [weak self] in
                    guard let self, self.loadGeneration == generation,
                          AuthStore.shared.email == email else { return }
                    self.totalCount = remaining
                }
            }
        }
    }
}
