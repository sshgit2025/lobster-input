package com.lobster.input.keyboard.pinyin

import android.content.Context
import com.lobster.input.core.network.ApiConfig

/**
 * 将 App 主进程同步的热词写入键盘用户词典。
 * MainViewModel 在热词增删改后调用 [persistHotwords];引擎启动时 [importInto] 导入调频。
 */
object HotwordDictionaryBridge {

    const val PREFS_KEY = "ime_hotwords_cache"

    fun persistHotwords(context: Context, words: List<String>) {
        val cleaned = words.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        context.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(PREFS_KEY, cleaned.joinToString("\n"))
            .apply()
    }

    fun readHotwords(context: Context): List<String> {
        val raw = context.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
            .getString(PREFS_KEY, null) ?: return emptyList()
        return raw.split('\n').map { it.trim() }.filter { it.isNotEmpty() }
    }

    fun importInto(userDict: UserDictionary, context: Context, baseBoost: Int = 8) {
        for (word in readHotwords(context)) {
            repeat(baseBoost) { userDict.learn(word) }
        }
    }
}
