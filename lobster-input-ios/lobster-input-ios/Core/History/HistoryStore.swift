import Foundation
import Combine

@MainActor
final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()

    @Published private(set) var records: [RecordingHistory] = []

    private let storageKey = "recording_history"
    private let lastReconcileKey = "history_audio_last_reconcile"
    private let maxRecords = 100
    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard
        load()
    }

    func add(_ record: RecordingHistory) {
        records.insert(record, at: 0)
        if records.count > maxRecords {
            // 超上限被裁掉的记录,其音频也要删,避免孤儿
            for dropped in records.dropFirst(maxRecords) { deleteAudioFile(dropped.audioFilePath) }
            records = Array(records.prefix(maxRecords))
        }
        save()
        reconcileOrphanAudioIfNeeded()
    }

    /// 跨天异步对账:每次对话(新增记录)时检测与上次是否同一天;跨天才异步扫描 history_audio
    /// 目录,删除没有被任何历史记录引用的孤儿音频(JSON 无对应音频不处理)。
    /// 健壮性:只删 5 分钟前的文件,避免误删正在持久化中的音频。
    func reconcileOrphanAudioIfNeeded() {
        let today = Self.dayKey(Date())
        if defaults.string(forKey: lastReconcileKey) == today { return }
        defaults.set(today, forKey: lastReconcileKey)
        let referenced = Set(records.compactMap { $0.audioFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } })
        let dir = historyAudioDir()
        DispatchQueue.global(qos: .utility).async {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-300)
            for f in files where !referenced.contains(f.lastPathComponent) {
                let mdate = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mdate, mdate > cutoff { continue } // 近期文件可能正在写入,跳过
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    func update(
        id: String, status: RecordingStatus,
        transcript: String? = nil, result: String? = nil,
        error: String? = nil, actionType: String? = nil,
        retryable: Bool? = nil
    ) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        if let t = transcript { records[idx].transcript = t }
        if let r = result { records[idx].result = r }
        if let e = error { records[idx].errorMessage = e }
        if let a = actionType { records[idx].actionType = a }
        if let rt = retryable { records[idx].retryable = rt }
        records[idx].status = status
        save()
    }

    func markProcessingStarted(id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].status = .processing
        save()
    }

    func deleteRecord(id: String) {
        // 删记录同步删对应音频文件,避免磁盘残留孤儿音频
        if let rec = records.first(where: { $0.id == id }) {
            deleteAudioFile(rec.audioFilePath)
        }
        records.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        for rec in records { deleteAudioFile(rec.audioFilePath) }
        records.removeAll()
        save()
    }

    /// 删除单个音频文件(健壮:空路径/不存在均安全)。
    private func deleteAudioFile(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    func persistAudio(from tempURL: URL) -> String? {
        let dir = historyAudioDir()
        let dest = dir.appendingPathComponent(UUID().uuidString + ".wav")
        do {
            try FileManager.default.copyItem(at: tempURL, to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let items = try? JSONDecoder().decode([RecordingHistory].self, from: data) {
            records = items
            return
        }
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([RecordingHistory].self, from: data) else { return }
        records = items
        save()
    }

    private func historyAudioDir() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("history_audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
