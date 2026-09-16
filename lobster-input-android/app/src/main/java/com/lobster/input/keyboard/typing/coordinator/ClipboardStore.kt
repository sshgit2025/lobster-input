package com.lobster.input.keyboard.typing.coordinator

import android.content.ClipboardManager
import android.content.Context

/**
 * 剪贴板历史 + 快捷短语(prefs 持久化)。
 * 系统 ClipboardManager 只暴露当前剪贴内容,故每次打开剪贴板面板时快照当前内容入历史(去重)。
 * 密码框由调用方禁用,不在此记录。
 */
class ClipboardStore(private val context: Context) {

    private val prefs = context.getSharedPreferences(
        com.lobster.input.core.network.ApiConfig.PREFS_NAME, Context.MODE_PRIVATE
    )

    /** 快照当前系统剪贴板到历史(最多 20,最新在前)。返回历史列表。 */
    fun snapshotAndGet(): List<String> {
        runCatching {
            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            val text = cm?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()?.trim()
            if (!text.isNullOrEmpty()) {
                val list = ArrayList(history())
                list.remove(text); list.add(0, text)
                while (list.size > MAX) list.removeAt(list.size - 1)
                prefs.edit().putString(KEY_HISTORY, list.joinToString(SEP)).apply()
            }
        }
        return history()
    }

    fun history(): List<String> =
        prefs.getString(KEY_HISTORY, null)?.split(SEP)?.filter { it.isNotEmpty() } ?: emptyList()

    fun clearHistory() { prefs.edit().remove(KEY_HISTORY).apply() }

    fun removeHistory(item: String) {
        val list = ArrayList(history()); list.remove(item)
        prefs.edit().putString(KEY_HISTORY, list.joinToString(SEP)).apply()
    }

    /** 快捷短语:用户自定义 + 内置默认。 */
    fun quickPhrases(): List<String> {
        val custom = prefs.getString(KEY_PHRASES, null)?.split(SEP)?.filter { it.isNotEmpty() }
        return custom ?: DEFAULT_PHRASES
    }

    companion object {
        private const val KEY_HISTORY = "ime_clipboard_history"
        private const val KEY_PHRASES = "ime_quick_phrases"
        private const val SEP = ""
        private const val MAX = 20
        private val DEFAULT_PHRASES = listOf(
            "好的,收到", "稍等一下", "在的", "谢谢", "辛苦了", "马上处理", "已收到,谢谢"
        )
    }
}
