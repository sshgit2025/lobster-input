package com.lobster.input.keyboard.typing.coordinator

import android.content.Context
import com.lobster.input.core.network.ApiConfig
import com.lobster.input.keyboard.pinyin.PinyinFuzzy

/** 打字键盘用户偏好(中/英、布局、是否记住键盘模式、模糊音/纠错、最近 emoji)。 */
class TypingPreferences(context: Context) {

    private val prefs = context.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)

    var chineseMode: Boolean
        get() = prefs.getBoolean(KEY_CHINESE, true)
        set(value) { prefs.edit().putBoolean(KEY_CHINESE, value).apply() }

    /** 输入语种 code(zh/en/ru/ko)。缺省从旧 chineseMode 偏好推导(平滑升级)。 */
    var inputLang: String
        get() = prefs.getString(KEY_INPUT_LANG, null) ?: if (chineseMode) "zh" else "en"
        set(value) { prefs.edit().putString(KEY_INPUT_LANG, value).apply() }

    /** 上次已知的 App 界面语言组(zhen/ru/ko),用于跨组切换检测。 */
    var langGroup: String?
        get() = prefs.getString(KEY_LANG_GROUP, null)
        set(value) { prefs.edit().putString(KEY_LANG_GROUP, value).apply() }

    var nineGrid: Boolean
        get() = prefs.getBoolean(KEY_NINEGRID, false)
        set(value) { prefs.edit().putBoolean(KEY_NINEGRID, value).apply() }

    /** 跨输入框是否保持键盘模式(默认 false:每次聚焦回语音)。 */
    var rememberTypingMode: Boolean
        get() = prefs.getBoolean(KEY_REMEMBER_MODE, false)
        set(value) { prefs.edit().putBoolean(KEY_REMEMBER_MODE, value).apply() }

    /** 记住上次是语音还是键盘模式(默认 false=语音;用户手动切换后持久化,下次拉起恢复)。 */
    var lastModeKeyboard: Boolean
        get() = prefs.getBoolean(KEY_LAST_MODE_KB, false)
        set(value) { prefs.edit().putBoolean(KEY_LAST_MODE_KB, value).apply() }

    private fun flag(key: String) = prefs.getBoolean(key, false)
    fun setFlag(key: String, value: Boolean) { prefs.edit().putBoolean(key, value).apply() }
    fun getFlag(key: String) = flag(key)

    /** 最近使用 emoji(最多 24,最新在前)。 */
    fun recentEmojis(): List<String> =
        prefs.getString(KEY_RECENT_EMOJI, null)?.split(EMOJI_SEP)?.filter { it.isNotEmpty() } ?: emptyList()

    fun recordRecentEmoji(emoji: String) {
        if (emoji.isEmpty()) return
        val list = ArrayList(recentEmojis())
        list.remove(emoji); list.add(0, emoji)
        while (list.size > 24) list.removeAt(list.size - 1)
        prefs.edit().putString(KEY_RECENT_EMOJI, list.joinToString(EMOJI_SEP)).apply()
    }

    /** 最近使用符号(最多 16,最新在前;键盘/语音符号板共用)。 */
    fun recentSymbols(): List<String> =
        prefs.getString(KEY_RECENT_SYMBOL, null)?.split(EMOJI_SEP)?.filter { it.isNotEmpty() } ?: emptyList()

    fun recordRecentSymbol(symbol: String) {
        if (symbol.isEmpty()) return
        val list = ArrayList(recentSymbols())
        list.remove(symbol); list.add(0, symbol)
        while (list.size > 16) list.removeAt(list.size - 1)
        prefs.edit().putString(KEY_RECENT_SYMBOL, list.joinToString(EMOJI_SEP)).apply()
    }

    /** 由各模糊音/纠错开关组装出引擎所需配置。 */
    fun fuzzySettings(): PinyinFuzzy.Settings = PinyinFuzzy.Settings(
        zZh = flag(KEY_FUZZY_ZZH),
        cCh = flag(KEY_FUZZY_CCH),
        sSh = flag(KEY_FUZZY_SSH),
        lN = flag(KEY_FUZZY_LN),
        fH = flag(KEY_FUZZY_FH),
        rL = flag(KEY_FUZZY_RL),
        anAng = flag(KEY_FUZZY_ANANG),
        enEng = flag(KEY_FUZZY_ENENG),
        inIng = flag(KEY_FUZZY_INING),
        // 纠错默认开启:它只在候选不足时兜底纠正错拼,不污染正常输入,无需用户配置
        correction = prefs.getBoolean(KEY_CORRECTION, true)
    )

    companion object {
        const val KEY_CHINESE = "ime_typing_chinese_mode"
        const val KEY_INPUT_LANG = "ime_typing_input_lang"
        const val KEY_LANG_GROUP = "ime_typing_lang_group"
        const val KEY_NINEGRID = "ime_typing_ninegrid"
        const val KEY_REMEMBER_MODE = "ime_typing_remember_mode"
        const val KEY_LAST_MODE_KB = "ime_typing_last_mode_keyboard"
        const val KEY_FUZZY_ZZH = "ime_fuzzy_zzh"
        const val KEY_FUZZY_CCH = "ime_fuzzy_cch"
        const val KEY_FUZZY_SSH = "ime_fuzzy_ssh"
        const val KEY_FUZZY_LN = "ime_fuzzy_ln"
        const val KEY_FUZZY_FH = "ime_fuzzy_fh"
        const val KEY_FUZZY_RL = "ime_fuzzy_rl"
        const val KEY_FUZZY_ANANG = "ime_fuzzy_anang"
        const val KEY_FUZZY_ENENG = "ime_fuzzy_eneng"
        const val KEY_FUZZY_INING = "ime_fuzzy_ining"
        const val KEY_CORRECTION = "ime_fuzzy_correction"
        const val KEY_RECENT_EMOJI = "ime_recent_emoji"
        const val KEY_RECENT_SYMBOL = "ime_recent_symbol"
        private const val EMOJI_SEP = ""
    }
}
