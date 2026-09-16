package com.lobster.input.keyboard.pinyin

/** 拼音词库加载生命周期状态。 */
enum class PinyinLoadState {
    IDLE,
    LOADING,
    READY,
    FAILED
}

/** 词库加载状态观察者(UI 层订阅,主线程回调)。 */
fun interface PinyinLoadListener {
    fun onLoadStateChanged(state: PinyinLoadState, detail: String?)
}
