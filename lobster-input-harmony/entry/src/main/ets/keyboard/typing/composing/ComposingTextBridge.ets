// 对齐 Android: keyboard/typing/composing/ComposingTextBridge.kt
import { ImeClientApi } from '../ImeClientApi';

/**
 * 拼音组合串的目标框同步(桥)。
 *
 * 搜狗式设计:**拼音只在键盘候选区显示,绝不写入目标输入框**——
 * 否则打字时拼音字母会插进用户输入框,选词又追加(如「237449测试」)。
 * 键盘麦克风的实时 ASR 预览走独立的 setComposing 路径(不经过本桥)。
 */
export class ComposingTextBridge {

  bind(connectionProvider: () => ImeClientApi | undefined, micActiveProvider: () => boolean): void {
    /* 不再需要:拼音不进目标框 */
  }

  update(composingDisplay: string): void {
    /* no-op:拼音只在候选区显示 */
  }

  clear(): void {
    /* no-op */
  }
}
