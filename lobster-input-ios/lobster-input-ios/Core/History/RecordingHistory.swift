import Foundation

enum RecordingStatus: String, Codable {
    case processing
    case success
    case failed
}

struct RecordingHistory: Codable, Identifiable {
    let id: String
    let operation: String
    var audioFilePath: String?
    var selectedText: String?
    var transcript: String?
    var result: String?
    var status: RecordingStatus
    var errorMessage: String?
    var actionType: String?
    var retryable: Bool
    let createdAt: Date

    init(
        operation: String,
        audioFilePath: String? = nil,
        selectedText: String? = nil
    ) {
        self.id = UUID().uuidString
        self.operation = operation
        self.audioFilePath = audioFilePath
        self.selectedText = selectedText
        self.status = .processing
        self.retryable = true
        self.createdAt = Date()
    }
}
