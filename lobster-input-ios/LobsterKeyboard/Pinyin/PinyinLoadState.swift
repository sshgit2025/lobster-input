import Foundation

/// 拼音词库加载生命周期状态。
enum PinyinLoadState {
    case idle
    case loading
    case ready
    case failed
}

/// 词库加载状态观察者(UI 层订阅,主线程回调)。
typealias PinyinLoadListener = (_ state: PinyinLoadState, _ detail: String?) -> Void
