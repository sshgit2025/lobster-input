/// RecordingResultStore.swift
/// 当前识别结果的临时状态存储（单例）。
/// 供首页 UI 展示最近一次的识别原文、处理结果和错误信息。
/// 登录/退出时调用 clear() 重置，避免旧状态残留。
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

    /// 清除所有状态（登录/退出时调用）
    func clear() {
        transcript = ""
        result = ""
        errorMessage = nil
    }
}
