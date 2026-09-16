// 对齐 Android: keyboard/typing/KeyboardRenderer.kt
import { Candidate } from '../pinyin/PinyinEngine';
import { PinyinLoadState } from '../pinyin/PinyinLoadState';

/** 键盘视图渲染回调(由打字键盘 UI 组件实现;ArkTS 接口无默认实现,UI 侧需全量实现)。 */
export interface KeyboardRenderer {
  rebuildKeyboard(): void;

  renderCandidates(composingDisplay: string, candidates: Candidate[], layoutLabel: string): void;

  /** 左侧竖排拼音选择器:options=当前编辑段可选读音,active=应高亮项(跟随首候选)。空则隐藏。 */
  renderPinyinSelector(options: string[], active: string): void;

  invalidateKeys(): void;

  /** 进入分类符号板时回调:重置分类选中为「最近」,不记忆上次入口的选择。 */
  onEnterSymBoard(): void;

  setInputBlocked(blocked: boolean): void;

  renderEngineState(state: PinyinLoadState, detail?: string): void;
}
