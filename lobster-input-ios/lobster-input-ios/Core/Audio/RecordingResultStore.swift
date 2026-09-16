import Foundation
import Combine

@MainActor
final class RecordingResultStore: ObservableObject {

    static let shared = RecordingResultStore()
    private init() {}

    @Published var transcript: String = ""
    @Published var result: String = ""
    @Published var errorMessage: String?

    func update(transcript: String, result: String, error: String?) {
        self.transcript = transcript
        self.result = result
        self.errorMessage = error
    }

    func clear() {
        transcript = ""
        result = ""
        errorMessage = nil
    }
}
