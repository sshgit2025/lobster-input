package com.lobster.input.keyboard.typing

/** 键类型。 */
enum class KeyType {
    LETTER, T9, DELETE, SPACE, ENTER, SHIFT,
    LANG, LAYOUT,
    NUM, SYMBOL, ALPHA, SYM_CHAR, SYM_PAGE,
    SYLLABLE, UNDO, EMOJI, CLIP,
    /** 模式轮换键(中文九宫格→中文26键→英文→俄语→韩语循环,全布局常驻,自绘循环箭头图标)。 */
    MODE_CYCLE,
    /** 分类符号板入口(最近/中文/英文/括号/数学/序号/货币/箭头)。 */
    SYM_BOARD,
    /** 9 宫格 1 键(@#):候选栏展示固定高频符号候选(对齐豆包)。 */
    SYM_CANDS,
    GAP
}

/**
 * 键盘输入语种。中英文为核心语种(LANG 键互切);俄/韩为扩展语种(独立布局,
 * 齿轮工具页直达 + App 界面语言为俄/韩时进入 LANG 轮换序列)。
 */
enum class InputLang(val code: String, val keyLabel: String, val nativeName: String) {
    ZH("zh", "中", "中文"),
    EN("en", "EN", "English"),
    RU("ru", "РУ", "Русский"),
    KO("ko", "한", "한국어");

    companion object {
        fun fromCode(code: String?): InputLang = entries.firstOrNull { it.code == code } ?: ZH
    }
}

/**
 * 一个键的描述(数据驱动布局)。longValue:长按时输出的字符(9宫格键长按出数字、26键字母行长按出数字、
 * 俄语 е 长按出 ё)。shiftValue:shift 按下时的输入/显示字符(韩语双辅音 ㅂ→ㅃ 等;拉丁/西里尔大小写不走此字段)。
 */
data class KeySpec(
    val type: KeyType,
    val main: String = "",
    val sub: String? = null,
    val weight: Float = 1f,
    val value: String? = null,
    val longValue: String? = null,
    val shiftValue: String? = null
)

/** 需要本地化的键盘文案。 */
enum class KbStr {
    RETURN_VOICE, SPACE, CH, EN, NINEGRID, QWERTY,
    SYMBOL, SWITCH_QWERTY, PINYIN, ABC, SYLLABLE, UNDO
}

/**
 * 键盘与宿主 IME 的对接接口。
 */
interface TypingKeyboardHost {
    fun onCommit(text: String)
    /** 智能标点配对上屏:插入 opening+closing 后把光标置于二者之间。 */
    fun onCommitPair(opening: String, closing: String) { onCommit(opening + closing) }
    /** 组合预览写入目标框(韩语组字音节,setComposingText 通道;拼音不走此通道)。 */
    fun onComposingText(text: String) {}
    /** 定稿目标框中的组合预览(finishComposingText)。 */
    fun onFinishComposing() {}
    /** 移动光标(dx<0 左移,dx>0 右移)。 */
    fun onMoveCursor(dx: Int) {}
    /** 光标后是否还有文字(1 键符号候选的成套插入判定:光标后无文字才成套插入括号/书名号)。 */
    fun hasTextAfterCursor(): Boolean = false
    /** 光标前 ≤maxChars 字符(标点联想 v2 的句内上下文;取不到返回空串,调用方走降级路径)。 */
    fun textBeforeCursor(maxChars: Int): String = ""
    fun onDeleteBeforeCursor()
    fun onEnter()
    fun onReturnToVoice()
    fun onKeyboardMicStart()
    fun onKeyboardMicStop()
    fun isChineseModeDefault(): Boolean
    fun persistChineseMode(chinese: Boolean)
    fun isNineGridDefault(): Boolean
    fun persistNineGrid(nine: Boolean)
    /** 当前默认输入语种(持久化的用户选择;跨语言组切换后为组默认语种)。 */
    fun inputLangDefault(): InputLang = if (isChineseModeDefault()) InputLang.ZH else InputLang.EN
    fun persistInputLang(lang: InputLang) { persistChineseMode(lang == InputLang.ZH) }
    /** 当前 App 界面语言组的默认输入语种(中英组按界面语言:zh/繁/粤→中文,en→英文;ru→俄语;ko→韩语)。 */
    fun groupDefaultLang(): InputLang = InputLang.ZH
    /**
     * App 界面语言组变化检测(消费式):跨组切换(中英组↔俄↔韩)返回 true 并把持久化输入语种
     * 重置为新组默认;组内互切(中英文互切)返回 false 不动任何暂存状态。
     */
    fun consumeLangGroupChange(): Boolean = false
    fun onKeyFeedback()
    fun localize(key: KbStr): String
    fun enterKeyLabel(): String = "↵"
    fun isPasswordField(): Boolean = false
    /** 数字/电话/日期时间输入框:进入时自动切换到数字键盘页。 */
    fun isNumericField(): Boolean = false
    /** 邮箱/URI/密码类 ASCII 输入框:进入时自动切换英文模式(会话内,不覆盖用户偏好)。 */
    fun isEnglishField(): Boolean = false
    /** 键盘麦克风是否可用(未登录时置灰禁用,键盘仍可打字)。 */
    fun isMicAvailable(): Boolean = true
    fun canUndo(): Boolean = false
    fun undoLastCommit() {}
    fun recordRecentEmoji(emoji: String) {}
    fun recentEmojis(): List<String> = emptyList()
    /** 分类符号板「最近使用」(键盘/语音两处共用同一存储)。 */
    fun recordRecentSymbol(symbol: String) {}
    fun recentSymbols(): List<String> = emptyList()
    fun clipboardHistory(): List<String> = emptyList()
    fun quickPhrases(): List<String> = emptyList()
    fun removeClipboardItem(item: String) {}
    fun clearClipboard() {}
}
