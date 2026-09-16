/// RecordingHistory.swift
/// 单条录音历史记录的数据模型，支持 Codable 序列化以实现本地 JSON 持久化。
/// 包含操作类型、音频路径、识别结果、处理耗时等完整生命周期数据。
import Foundation

/// 单条历史记录的识别状态
enum RecognitionStatus: String, Codable {
    case pending    = "pending"    // 等待识别
    case processing = "processing" // 识别中
    case success    = "success"    // 识别成功
    case failed     = "failed"     // 识别失败
}

/// 单条录音历史记录（本地持久化）
struct RecordingHistory: Codable, Identifiable {
    var id: String
    var createdAt: Date
    var operation: String          // transcribe / rewrite / agent
    var audioFilePath: String?     // 本地音频文件路径（可被用户删除）
    var selectedText: String?      // 录音时选中的文本
    var transcript: String?        // Whisper 识别结果
    var result: String?            // LLM 处理结果
    var actionType: String?        // 后端返回的操作类型（paste/clarify/show_markdown/tip），nil 兼容旧数据
    var status: RecognitionStatus
    var errorMessage: String?
    var retryable: Bool = true            // 是否允许重试（前置校验错误设为 false）
    var processingDuration: TimeInterval? // 识别耗时（秒），完成后填入
    var processStartedAt: Date?           // 开始识别的时间戳

    /// result 是否应以 Markdown 格式渲染（由 actionType 决定）
    var resultIsMarkdown: Bool { actionType == "show_markdown" }

    init(
        operation: String,
        audioFilePath: String?,
        selectedText: String?
    ) {
        self.id = UUID().uuidString
        self.createdAt = Date()
        self.operation = operation
        self.audioFilePath = audioFilePath
        self.selectedText = selectedText
        self.status = .pending
    }

    /// 音频文件是否仍然存在
    var audioFileExists: Bool {
        guard let path = audioFilePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 操作类型的中文名称
    var operationDisplayName: String {
        switch operation {
        case "transcribe": return "语音转文字"
        case "rewrite":    return "改写文本"
        case "agent":      return "Agent 操作"
        default:           return operation
        }
    }
}
