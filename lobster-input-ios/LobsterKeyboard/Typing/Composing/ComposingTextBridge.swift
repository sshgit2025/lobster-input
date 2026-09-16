import UIKit

/// 将中文拼音组合串同步到目标输入框的下划线 composing 区域(setMarkedText)。
/// 与键盘麦克风 ASR 预览互斥:录音中暂停拼音 composing。
final class ComposingTextBridge {

    private var proxyProvider: (() -> UITextDocumentProxy?)?
    private var micActiveProvider: (() -> Bool)?
    private var lastPreview = ""

    func bind(
        proxyProvider: @escaping () -> UITextDocumentProxy?,
        micActiveProvider: @escaping () -> Bool
    ) {
        self.proxyProvider = proxyProvider
        self.micActiveProvider = micActiveProvider
    }

    // 搜狗式:拼音只在键盘候选区显示,不写入目标输入框(否则拼音字母会插进用户输入框)。
    func update(composingDisplay: String) { /* no-op */ }

    func clear() { /* no-op */ }
}
