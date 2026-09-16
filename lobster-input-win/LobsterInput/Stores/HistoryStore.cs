using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using CommunityToolkit.Mvvm.ComponentModel;
using LobsterInput.Helpers;
using LobsterInput.Models;

namespace LobsterInput.Stores;

public enum RetentionPolicy
{
    Forever,
    ThirtyDays,
    SevenDays,
    OneDay,
    Never
}

/// <summary>
/// 录音历史记录本地持久化管理器（单例）。
///
/// 存储架构（增量化 + 分页）：
/// 历史记录采用「每条一文件」存储，每条记录写到
///   %APPDATA%\LobsterInput\history\&lt;email_hash&gt;\records\&lt;时间戳&gt;_&lt;id&gt;.json
/// 音频文件仍保存在同目录下的 AudioFiles\ 子目录（不变）。
///   - 新增 / 更新 / 删除 都只读写「单条记录文件」，绝不重写整库，写放大与历史总量无关。
///   - 文件名前缀内嵌 CreatedAt 毫秒时间戳（16 位零填充），目录列表按文件名倒序即得「最新在前」，
///     分页时只读「当前页」的少量文件，避免整库常驻内存与整列表 diff。
///   - CreatedAt 创建后不可变，因此任何一条记录的文件名都可由 (CreatedAt, Id) 直接推导，
///     更新/删除无需额外索引即可定位文件。
///
/// 一次性迁移：旧 recording_history.json（整库 JSON）存在且新 records 目录为空时，
/// 拆分为每条一文件写入新目录，校验通过后删除旧整库文件。
///
/// 每个账号完全独立隔离（email SHA256 前 16 位做目录名）。
/// </summary>
public sealed partial class HistoryStore : ObservableObject
{
    private static readonly string AppDataDir = AppPaths.AppDataDir;

    private static readonly string RetentionSettingPath =
        Path.Combine(AppDataDir, "retention_policy.txt");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    /// <summary>每页加载条数。</summary>
    public const int PageSize = 20;

    public static HistoryStore Instance { get; } = new();

    /// <summary>
    /// 当前已加载到内存的记录（按 CreatedAt 倒序，最新在前）。
    /// 注意：这是「已加载的分页」而非全量；<see cref="TotalCount"/> 才是磁盘上的记录总数。
    /// </summary>
    [ObservableProperty]
    private List<RecordingHistory> _records = new();

    [ObservableProperty]
    private RetentionPolicy _retentionPolicy = RetentionPolicy.Forever;

    /// <summary>磁盘上的记录总数（用于 UI 显示与「加载更多」判定）。</summary>
    [ObservableProperty]
    private int _totalCount;

    /// <summary>是否还有未加载到内存的更早记录。</summary>
    public bool HasMore => Records.Count < TotalCount;

    // 同步分页读取（LoadPage/迁移）用此锁；后台写/删除任务链的追加也用此锁保护尾指针。
    private readonly object _ioGate = new();

    // 后台磁盘写/删除任务链尾：每个新任务延续到上一个之后，保证「按提交顺序」串行执行（FIFO）。
    private Task _ioTail = Task.CompletedTask;

    // 每次 ReloadForCurrentUser 自增，用于丢弃过期的后台加载/清理结果。
    private int _loadGeneration;
    private bool _isLoadingMore;

    private HistoryStore()
    {
        LoadRetentionPolicy();
    }

    partial void OnRetentionPolicyChanged(RetentionPolicy value)
    {
        SaveRetentionPolicy();
        ApplyRetentionPolicy();
    }

    public TimeSpan? GetMaxAge(RetentionPolicy policy)
    {
        return policy switch
        {
            RetentionPolicy.Forever => null,
            RetentionPolicy.ThirtyDays => TimeSpan.FromDays(30),
            RetentionPolicy.SevenDays => TimeSpan.FromDays(7),
            RetentionPolicy.OneDay => TimeSpan.FromDays(1),
            RetentionPolicy.Never => TimeSpan.Zero,
            _ => null
        };
    }

    // MARK: - Paths

    private static string UserDirName(string email)
    {
        var hashBytes = SHA256.HashData(Encoding.UTF8.GetBytes(email));
        var hex = Convert.ToHexString(hashBytes).ToLowerInvariant();
        return hex[..16];
    }

    private static string UserBaseDir(string email)
    {
        var dir = Path.Combine(AppDataDir, "history", UserDirName(email));
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static string RecordsDir(string email)
    {
        var dir = Path.Combine(UserBaseDir(email), "records");
        Directory.CreateDirectory(dir);
        return dir;
    }

    private static string AudioDir(string email)
    {
        var dir = Path.Combine(UserBaseDir(email), "AudioFiles");
        Directory.CreateDirectory(dir);
        return dir;
    }

    /// <summary>旧版整库文件路径，仅用于一次性迁移。</summary>
    private static string LegacyStoreFilePath(string email)
    {
        return Path.Combine(UserBaseDir(email), "recording_history.json");
    }

    /// <summary>
    /// 单条记录文件名：&lt;16 位零填充毫秒时间戳&gt;_&lt;id&gt;.json。
    /// 零填充保证「文件名字典序 == CreatedAt 时序」，倒序即最新在前。
    /// </summary>
    private static string FileName(RecordingHistory record)
    {
        var millis = (long)Math.Round(
            (record.CreatedAt.ToUniversalTime() - DateTime.UnixEpoch).TotalMilliseconds);
        var stamp = millis.ToString("D16", CultureInfo.InvariantCulture);
        return $"{stamp}_{record.Id}.json";
    }

    /// <summary>从文件名解析内嵌的毫秒时间戳；无法解析返回 null。</summary>
    private static long? TimestampMillis(string fileName)
    {
        var underscore = fileName.IndexOf('_');
        if (underscore <= 0) return null;
        return long.TryParse(
            fileName.AsSpan(0, underscore),
            NumberStyles.Integer,
            CultureInfo.InvariantCulture,
            out var millis)
            ? millis
            : null;
    }

    public string? AudioDirectory
    {
        get
        {
            var email = AuthStore.Instance.Email;
            if (string.IsNullOrEmpty(email)) return null;
            return AudioDir(email);
        }
    }

    // MARK: - CRUD（内存改在调用线程同步进行，磁盘 IO 后台串行，UI 线程不阻塞）

    /// <summary>新增一条记录（录音完成后立即调用）。只写单条记录文件。</summary>
    public void Add(RecordingHistory record)
    {
        if (RetentionPolicy == RetentionPolicy.Never) return;
        var email = AuthStore.Instance.Email;
        if (string.IsNullOrEmpty(email)) return;

        Records.Insert(0, record);
        TotalCount += 1;
        OnPropertyChanged(nameof(Records));
        SaveRecordAsync(record, email);
        ReconcileOrphanAudioIfNeeded(email);
    }

    private static string LastReconcilePath(string email) =>
        Path.Combine(UserBaseDir(email), "last_reconcile.txt");

    /// <summary>跨天异步孤儿音频对账:每次对话(新增记录)触发,与上次不同一天才后台扫描,一天最多一次。</summary>
    private void ReconcileOrphanAudioIfNeeded(string email)
    {
        var today = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var lastReconcilePath = LastReconcilePath(email);
        try
        {
            if (File.Exists(lastReconcilePath) &&
                string.Equals(File.ReadAllText(lastReconcilePath).Trim(), today, StringComparison.Ordinal))
                return;
            File.WriteAllText(lastReconcilePath, today);
        }
        catch { return; }
        RunOnIo(() => ReconcileOrphanAudio(email));
    }

    /// <summary>扫描 AudioFiles,删除没有任何记录 JSON 引用的孤儿音频(记录引用了但音频缺失的不处理)。
    /// 健壮:只删修改时间早于 5 分钟前的文件,避免误删正在持久化中的音频。</summary>
    private static void ReconcileOrphanAudio(string email)
    {
        try
        {
            var recordsDir = RecordsDir(email);
            var referenced = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var name in SortedRecordFileNamesDesc(recordsDir))
            {
                var audioPath = ReadRecord(Path.Combine(recordsDir, name))?.AudioFilePath;
                if (!string.IsNullOrEmpty(audioPath))
                    referenced.Add(Path.GetFileName(audioPath));
            }

            var audioDir = AudioDir(email);
            if (!Directory.Exists(audioDir)) return;
            var cutoff = DateTime.Now.AddMinutes(-5);
            foreach (var file in Directory.EnumerateFiles(audioDir))
            {
                if (referenced.Contains(Path.GetFileName(file))) continue;
                if (File.GetLastWriteTime(file) > cutoff) continue;
                DeleteQuietly(file);
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HistoryStore] ReconcileOrphanAudio failed: {ex.Message}");
        }
    }

    /// <summary>标记开始处理（记录开始时间）。只重写该条记录文件。</summary>
    public void MarkProcessingStarted(string id)
    {
        var record = Records.FirstOrDefault(r => r.Id == id);
        if (record == null)
        {
            // 记录已被分页移出内存：走磁盘读改写兜底。
            ApplyUpdateOnDisk(id, r =>
            {
                r.Status = RecordingStatus.Processing;
                r.ProcessStartedAt = DateTime.UtcNow;
            });
            return;
        }

        record.Status = RecordingStatus.Processing;
        record.ProcessStartedAt = DateTime.UtcNow;
        OnPropertyChanged(nameof(Records));
        PersistAsync(record);
    }

    /// <summary>更新记录状态（识别结果回来后调用，自动计算耗时）。只重写该条记录文件。</summary>
    public void Update(
        string id,
        RecordingStatus status,
        string? transcript = null,
        string? result = null,
        string? error = null,
        bool retryable = true,
        string? actionType = null)
    {
        var record = Records.FirstOrDefault(r => r.Id == id);
        if (record == null)
        {
            // 记录已被分页移出内存：走磁盘读改写兜底，保证状态不丢失。
            ApplyUpdateOnDisk(id, r =>
            {
                if (r.ProcessStartedAt.HasValue)
                    r.ProcessingDuration = (DateTime.UtcNow - r.ProcessStartedAt.Value).TotalSeconds;
                r.Status = status;
                if (transcript != null) r.Transcript = transcript;
                if (result != null) r.Result = result;
                if (actionType != null) r.ActionType = actionType;
                r.ErrorMessage = error;
                r.Retryable = retryable;
            });
            return;
        }

        if (record.ProcessStartedAt.HasValue)
        {
            record.ProcessingDuration =
                (DateTime.UtcNow - record.ProcessStartedAt.Value).TotalSeconds;
        }

        record.Status = status;
        if (transcript != null) record.Transcript = transcript;
        if (result != null) record.Result = result;
        if (actionType != null) record.ActionType = actionType;
        record.ErrorMessage = error;
        record.Retryable = retryable;
        OnPropertyChanged(nameof(Records));
        PersistAsync(record);
    }

    /// <summary>删除一条记录（同时可选删除音频文件）。只删除该条记录文件。</summary>
    public void Delete(string id, bool deleteAudio = false)
    {
        var record = Records.FirstOrDefault(r => r.Id == id);
        if (record == null) return;
        var email = AuthStore.Instance.Email;
        if (string.IsNullOrEmpty(email)) return;

        var audioToDelete = deleteAudio ? record.AudioFilePath : null;

        Records.Remove(record);
        TotalCount = Math.Max(0, TotalCount - 1);
        OnPropertyChanged(nameof(Records));

        var fileName = FileName(record);
        RunOnIo(() =>
        {
            DeleteQuietly(Path.Combine(RecordsDir(email), fileName));
            if (audioToDelete != null)
                DeleteQuietly(audioToDelete);
        });
    }

    /// <summary>仅删除某条记录的音频文件（保留文字记录）。只重写该条记录文件。</summary>
    public void DeleteAudioFile(string id)
    {
        var record = Records.FirstOrDefault(r => r.Id == id);
        if (record == null) return;

        var audioToDelete = record.AudioFilePath;
        record.AudioFilePath = null;
        OnPropertyChanged(nameof(Records));
        PersistAsync(record);

        if (audioToDelete != null)
            RunOnIo(() => DeleteQuietly(audioToDelete));
    }

    /// <summary>将临时音频文件移动到持久化目录，返回新路径。</summary>
    public string? PersistAudio(string tempFilePath)
    {
        var dir = AudioDirectory;
        if (dir == null) return null;

        var fileName = Path.GetFileName(tempFilePath);
        var dest = Path.Combine(dir, fileName);

        try
        {
            if (File.Exists(dest))
                File.Delete(dest);

            try
            {
                File.Move(tempFilePath, dest);
            }
            catch
            {
                File.Copy(tempFilePath, dest);
            }

            return dest;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HistoryStore] Failed to persist audio: {ex.Message}");
            return null;
        }
    }

    // MARK: - 分页加载

    /// <summary>
    /// 历史记录加载入口（加载第一页），由登录成功后调用。
    /// 触发一次旧整库 → 每条一文件迁移，随后读取首页。
    /// </summary>
    public void ReloadForCurrentUser()
    {
        var email = AuthStore.Instance.Email;
        if (string.IsNullOrEmpty(email))
        {
            Records = new List<RecordingHistory>();
            TotalCount = 0;
            return;
        }

        var generation = Interlocked.Increment(ref _loadGeneration);
        Records = new List<RecordingHistory>();
        TotalCount = 0;

        var (page, total) = LoadPage(email, 0, PageSize);
        if (generation != _loadGeneration ||
            !string.Equals(AuthStore.Instance.Email, email, StringComparison.Ordinal))
            return;

        Records = page;
        TotalCount = total;
        CleanupStaleProcessing(email);
        ApplyRetentionPolicy();
    }

    /// <summary>加载下一页（追加到 Records 尾部）。供 UI 在已加载页全部展示后调用。</summary>
    public void LoadMore()
    {
        if (_isLoadingMore || !HasMore) return;
        var email = AuthStore.Instance.Email;
        if (string.IsNullOrEmpty(email)) return;

        _isLoadingMore = true;
        try
        {
            var generation = _loadGeneration;
            var offset = Records.Count;
            var (page, total) = LoadPage(email, offset, PageSize);

            if (generation != _loadGeneration ||
                !string.Equals(AuthStore.Instance.Email, email, StringComparison.Ordinal))
                return;

            // 去重后追加（防止加载期间有新记录插入导致 offset 漂移而重复）。
            var existingIds = new HashSet<string>(Records.Select(r => r.Id));
            Records.AddRange(page.Where(r => !existingIds.Contains(r.Id)));
            TotalCount = Math.Max(TotalCount, total);
            OnPropertyChanged(nameof(Records));
        }
        finally
        {
            _isLoadingMore = false;
        }
    }

    /// <summary>退出登录时调用：清空内存，磁盘文件保留（下次登录可恢复）。</summary>
    public void ClearMemory()
    {
        Interlocked.Increment(ref _loadGeneration);
        Records = new List<RecordingHistory>();
        TotalCount = 0;
    }

    // MARK: - 磁盘读写（单文件，原子）

    private void PersistAsync(RecordingHistory record)
    {
        var email = AuthStore.Instance.Email;
        if (string.IsNullOrEmpty(email)) return;
        SaveRecordAsync(record, email);
    }

    private void SaveRecordAsync(RecordingHistory record, string email)
    {
        // 复制需要的字段引用即可：record 在调用线程被同步改完后才入队，写入的是当时快照值。
        var fileName = FileName(record);
        var json = JsonSerializer.Serialize(record, JsonOptions);
        RunOnIo(() => WriteFileAtomic(Path.Combine(RecordsDir(email), fileName), json));
    }

    /// <summary>从磁盘按 id 读出记录、应用变更后原子写回。用于记录已被分页移出内存的兜底路径。</summary>
    private void ApplyUpdateOnDisk(string id, Action<RecordingHistory> mutate)
    {
        var email = AuthStore.Instance.Email;
        if (string.IsNullOrEmpty(email)) return;

        RunOnIo(() =>
        {
            var dir = RecordsDir(email);
            var match = FindRecordFile(dir, id);
            if (match == null) return;

            var record = ReadRecord(match);
            if (record == null) return;

            mutate(record);
            var json = JsonSerializer.Serialize(record, JsonOptions);
            WriteFileAtomic(Path.Combine(dir, FileName(record)), json);
        });
    }

    /// <summary>读取某账号指定分页（按文件名倒序）的完整记录，并返回记录总数。首次访问触发旧库迁移。</summary>
    private (List<RecordingHistory> Page, int Total) LoadPage(string email, int offset, int limit)
    {
        lock (_ioGate)
        {
            MigrateLegacyIfNeeded(email);
            var dir = RecordsDir(email);
            var names = SortedRecordFileNamesDesc(dir);
            var total = names.Count;
            if (offset >= total || limit <= 0)
                return (new List<RecordingHistory>(), total);

            var end = Math.Min(offset + limit, total);
            var page = new List<RecordingHistory>(end - offset);
            for (var i = offset; i < end; i++)
            {
                var record = ReadRecord(Path.Combine(dir, names[i]));
                if (record != null)
                    page.Add(record);
            }

            return (page, total);
        }
    }

    private void CleanupStaleProcessing(string email)
    {
        bool changed = false;
        foreach (var record in Records)
        {
            if (record.Status is RecordingStatus.Processing or RecordingStatus.Pending)
            {
                record.Status = RecordingStatus.Failed;
                record.ErrorMessage = null;
                changed = true;
                PersistAsync(record);
            }
        }

        if (changed)
            OnPropertyChanged(nameof(Records));
    }

    private void ApplyRetentionPolicy()
    {
        var email = AuthStore.Instance.Email;
        if (string.IsNullOrEmpty(email)) return;

        switch (RetentionPolicy)
        {
            case RetentionPolicy.Forever:
                return;

            case RetentionPolicy.Never:
                Records = new List<RecordingHistory>();
                TotalCount = 0;
                RunOnIo(() => PurgeAll(email));
                return;

            default:
                var maxAge = GetMaxAge(RetentionPolicy);
                if (maxAge == null) return;
                var cutoff = DateTime.UtcNow - maxAge.Value;

                // 内存中（已加载页）先即时移除过期项，磁盘清理交给后台按文件名时间戳批量删除。
                var before = Records.Count;
                Records.RemoveAll(r => r.CreatedAt.ToUniversalTime() < cutoff);
                if (Records.Count != before)
                    OnPropertyChanged(nameof(Records));

                var generation = _loadGeneration;
                RunOnIo(() =>
                {
                    var remaining = PurgeOlderThan(cutoff, email);
                    if (generation == _loadGeneration &&
                        string.Equals(AuthStore.Instance.Email, email, StringComparison.Ordinal))
                    {
                        TotalCount = remaining;
                    }
                });
                return;
        }
    }

    // MARK: - 文件层基础操作（均在 _ioGate 保护下调用）

    private static List<string> SortedRecordFileNamesDesc(string dir)
    {
        if (!Directory.Exists(dir)) return new List<string>();
        var names = Directory.EnumerateFiles(dir)
            .Select(Path.GetFileName)
            .Where(n => n != null && n.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
            .Select(n => n!)
            .ToList();
        // 文件名字典序 == CreatedAt 时序（毫秒零填充），倒序即最新在前。
        names.Sort(StringComparer.Ordinal);
        names.Reverse();
        return names;
    }

    private static RecordingHistory? ReadRecord(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<RecordingHistory>(json, JsonOptions);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HistoryStore] ReadRecord failed: {ex.Message}");
            return null;
        }
    }

    /// <summary>按 id 在目录中查找对应记录文件（文件名以 _&lt;id&gt;.json 结尾）。</summary>
    private static string? FindRecordFile(string dir, string id)
    {
        if (!Directory.Exists(dir)) return null;
        var suffix = $"_{id}.json";
        return Directory.EnumerateFiles(dir, $"*{suffix}").FirstOrDefault();
    }

    private static void WriteFileAtomic(string path, string json)
    {
        try
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir))
                Directory.CreateDirectory(dir);

            var tmp = path + ".tmp";
            File.WriteAllText(tmp, json);
            // 原子替换：目标存在用 Replace，不存在用 Move。
            if (File.Exists(path))
                File.Replace(tmp, path, null);
            else
                File.Move(tmp, path);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HistoryStore] WriteFileAtomic failed: {ex.Message}");
            try { File.Delete(path + ".tmp"); }
            catch { }
        }
    }

    private static void DeleteQuietly(string path)
    {
        try
        {
            if (File.Exists(path))
                File.Delete(path);
        }
        catch
        {
            // Best-effort cleanup only.
        }
    }

    /// <summary>按保留策略清理：删除 CreatedAt 早于 cutoff 的记录文件及其音频，返回剩余记录总数。</summary>
    private static int PurgeOlderThan(DateTime cutoffUtc, string email)
    {
        var dir = RecordsDir(email);
        var names = SortedRecordFileNamesDesc(dir);
        var cutoffMillis = (long)Math.Round((cutoffUtc.ToUniversalTime() - DateTime.UnixEpoch).TotalMilliseconds);
        var remaining = 0;
        foreach (var name in names)
        {
            var ts = TimestampMillis(name) ?? long.MaxValue;
            if (ts < cutoffMillis)
            {
                var record = ReadRecord(Path.Combine(dir, name));
                if (record?.AudioFilePath != null)
                    DeleteQuietly(record.AudioFilePath);
                DeleteQuietly(Path.Combine(dir, name));
            }
            else
            {
                remaining++;
            }
        }

        return remaining;
    }

    /// <summary>清空某账号全部记录与音频（用于 RetentionPolicy.Never）。</summary>
    private static void PurgeAll(string email)
    {
        try
        {
            var recordsDir = Path.Combine(UserBaseDir(email), "records");
            if (Directory.Exists(recordsDir))
                Directory.Delete(recordsDir, recursive: true);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HistoryStore] PurgeAll records failed: {ex.Message}");
        }

        try
        {
            var audioDir = Path.Combine(UserBaseDir(email), "AudioFiles");
            if (Directory.Exists(audioDir))
                Directory.Delete(audioDir, recursive: true);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HistoryStore] PurgeAll audio failed: {ex.Message}");
        }
    }

    /// <summary>
    /// 从未上线、均为测试数据，不迁移老历史：直接删除旧整库文件 recording_history.json，
    /// 新存储从空开始。避免老数据混入，也省掉迁移兼容代码。
    /// </summary>
    private static void MigrateLegacyIfNeeded(string email)
    {
        var legacyPath = LegacyStoreFilePath(email);
        if (File.Exists(legacyPath))
            DeleteQuietly(legacyPath);
    }

    // MARK: - 后台 IO 调度

    /// <summary>
    /// 在后台「按提交顺序」串行执行一次磁盘操作（FIFO），不阻塞调用线程。
    /// 通过把每个任务链接到上一个任务的延续上，保证执行顺序与提交顺序一致——
    /// 这点至关重要：同一条记录可能被 Add→MarkProcessingStarted→Update 连续写多次，
    /// 乱序会让磁盘上残留旧状态。Task.Run + 普通锁只能串行不能保序，故不用。
    /// 录音流程已在后台线程调用 CRUD，UI 线程调用（重试/删除）也借此避免被磁盘 IO 阻塞。
    /// </summary>
    private void RunOnIo(Action work)
    {
        lock (_ioGate)
        {
            _ioTail = _ioTail.ContinueWith(
                _ =>
                {
                    try
                    {
                        work();
                    }
                    catch (Exception ex)
                    {
                        Debug.WriteLine($"[HistoryStore] IO task failed: {ex.Message}");
                    }
                },
                CancellationToken.None,
                TaskContinuationOptions.None,
                TaskScheduler.Default);
        }
    }

    // MARK: - Retention 持久化

    private void SaveRetentionPolicy()
    {
        try
        {
            Directory.CreateDirectory(AppDataDir);
            File.WriteAllText(RetentionSettingPath, RetentionPolicy.ToString());
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HistoryStore] SaveRetentionPolicy failed: {ex.Message}");
        }
    }

    private void LoadRetentionPolicy()
    {
        try
        {
            if (!File.Exists(RetentionSettingPath)) return;
            var raw = File.ReadAllText(RetentionSettingPath).Trim();
            if (Enum.TryParse<RetentionPolicy>(raw, out var policy))
                RetentionPolicy = policy;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HistoryStore] LoadRetentionPolicy failed: {ex.Message}");
        }
    }
}
