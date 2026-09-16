/**
 * 拼音词库加载生命周期状态。
 * 移植自 Android: keyboard/pinyin/PinyinLoadState.kt(逐行对齐)。
 */
export enum PinyinLoadState {
  IDLE,
  LOADING,
  READY,
  FAILED
}

/**
 * 词库加载状态观察者(UI 层订阅,主线程回调)。
 * 对齐 Kotlin `fun interface PinyinLoadListener`,ArkTS 侧用函数类型表达。
 */
export type PinyinLoadListener = (state: PinyinLoadState, detail: string | null) => void;
