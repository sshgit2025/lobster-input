import Foundation

/// 打字模式撤销栈:记录最近上屏文本,支持一键撤销(与语音模式 undo 独立)。
final class TypingUndoManager {

    private let maxDepth: Int
    private var stack: [String] = []

    init(maxDepth: Int = 32) {
        self.maxDepth = maxDepth
    }

    func record(_ text: String) {
        guard !text.isEmpty else { return }
        stack.append(text)
        while stack.count > maxDepth { stack.removeFirst() }
    }

    func canUndo() -> Bool { !stack.isEmpty }

    func peek() -> String? { stack.last }

    func pop() -> String? {
        guard !stack.isEmpty else { return nil }
        return stack.removeLast()
    }
}
