import Foundation

/// 键类型。
enum TypingKeyType {
    case letter     // 26 键字母
    case t9         // 9 宫格字母组(value=数字)
    case delete, space, enter, shift
    case lang       // 中/英 切换
    case layout     // 26 ↔ 9 宫格 切换
    case mic        // 保留类型,麦克风已移至候选栏
    case num, symbol // 进入数字/符号页
    case alpha      // 符号页返回字母
    case symChar    // 符号/数字字符直接上屏
    case symPage    // 符号页翻页
    case syllable   // 拼音音节分隔符 '
    case undo       // 打字撤销
    case modeCycle  // 模式轮换键(中9→中26→EN→РУ→한 循环,全布局常驻)
    case symBoard   // 分类符号板入口(最近/中文/英文/括号/数学/序号/货币/箭头)
    case symCands   // 9 宫格 1 键(@#):候选栏展示固定高频符号候选(对齐豆包)
    case gap        // 占位空白
}

/// 键盘输入语种。中英文为核心语种(LANG 键互切);俄/韩为扩展语种(独立布局,
/// 长按 LANG 键轮换 + App 界面语言为俄/韩时进入 LANG 轮换序列)。
enum InputLang: String, CaseIterable {
    case zh, en, ru, ko

    var keyLabel: String {
        switch self {
        case .zh: return "中"
        case .en: return "EN"
        case .ru: return "РУ"
        case .ko: return "한"
        }
    }
}

/// 一个键的描述(数据驱动布局)。longValue:长按输出的字符(9宫格键长按出数字、26键字母行长按出数字、
/// 俄语 е 长按出 ё)。shiftValue:shift 按下时的输入/显示字符(韩语双辅音 ㅂ→ㅃ 等)。
struct TypingKeySpec {
    let type: TypingKeyType
    var main: String = ""
    var sub: String? = nil
    var weight: CGFloat = 1
    var value: String? = nil
    var longValue: String? = nil
    var shiftValue: String? = nil
}

/// 需要本地化的键盘文案。
enum KbStrKey {
    case returnVoice, space, ch, en, ninegrid, qwerty
    case symbol, switchQwerty, pinyin, abc, syllable, undo
}

/// 键盘与宿主的对接接口。键盘只通过此接口操作输入框与流式麦克风。
protocol TypingKeyboardHost: AnyObject {
    func onCommit(_ text: String)
    /// 智能标点配对上屏:插入 opening+closing 后把光标置于二者之间。
    func onCommitPair(_ opening: String, _ closing: String)
    func onDeleteBeforeCursor()
    func onEnter()
    func onReturnToVoice()
    func onKeyboardMicStart()
    func onKeyboardMicStop()
    func isChineseModeDefault() -> Bool
    func persistChineseMode(_ chinese: Bool)
    func isNineGridDefault() -> Bool
    func persistNineGrid(_ nine: Bool)
    func onKeyFeedback()
    func localize(_ key: KbStrKey) -> String
    /// 当前默认输入语种(持久化的用户选择;跨语言组切换后为组默认语种)。
    func inputLangDefault() -> InputLang
    func persistInputLang(_ lang: InputLang)
    /// 当前 App 界面语言组的默认输入语种(zh/繁/粤→中文,en→英文;ru→俄语;ko→韩语)。
    func groupDefaultLang() -> InputLang
    /// App 界面语言组变化检测(消费式):跨组切换返回 true 并把持久化输入语种重置为新组默认。
    func consumeLangGroupChange() -> Bool
    /// 组合预览写入目标框(韩语组字音节,setMarkedText 通道;拼音不走此通道)。
    func onComposingText(_ text: String)
    /// 定稿目标框中的组合预览(unmarkText)。
    func onFinishComposing()
    /// 分类符号板「最近使用」(键盘/语音两处共用同一存储)。
    func recordRecentSymbol(_ symbol: String)
    func recentSymbols() -> [String]
    /// 光标后是否还有文字(1 键符号候选的成套插入判定:光标后无文字才成套插入括号/书名号)。
    func hasTextAfterCursor() -> Bool
    /// 光标前 ≤maxChars 字符(标点联想 v2 的句内上下文;取不到返回空串,调用方走降级路径)。
    func textBeforeCursor(_ maxChars: Int) -> String
}

/// 默认实现:无配对能力的宿主退化为普通上屏;语种扩展能力可选。
extension TypingKeyboardHost {
    func onCommitPair(_ opening: String, _ closing: String) { onCommit(opening + closing) }
    func inputLangDefault() -> InputLang { isChineseModeDefault() ? .zh : .en }
    func persistInputLang(_ lang: InputLang) { persistChineseMode(lang == .zh) }
    func groupDefaultLang() -> InputLang { .zh }
    func consumeLangGroupChange() -> Bool { false }
    func onComposingText(_ text: String) {}
    func onFinishComposing() {}
    func recordRecentSymbol(_ symbol: String) {}
    func recentSymbols() -> [String] { [] }
    func hasTextAfterCursor() -> Bool { false }
    func textBeforeCursor(_ maxChars: Int) -> String { "" }
}

/// 扩展宿主能力(组合预览、撤销、Enter 标签、密码框判定),由 [TypingSessionHost] 实现。
protocol TypingSessionHosting: TypingKeyboardHost {
    func updateComposingPreview(_ text: String)
    func clearComposingPreview()
    func enterKeyLabel() -> String
    func canUndo() -> Bool
    func undoLastCommit()
    func showStatus(_ message: String?)
    func setInputBlocked(_ blocked: Bool)
    func notifyEngineState(_ state: PinyinLoadState, detail: String?)
    func isPasswordField() -> Bool
    /// 数字/电话/小数输入框:进入时自动切换到数字键盘页。
    func isNumericField() -> Bool
    /// 邮箱/URI/ASCII 类英文输入框:进入时自动切换到英文模式(仅会话内,不写偏好)。
    func isEnglishField() -> Bool
}

extension TypingSessionHost: TypingSessionHosting {}
