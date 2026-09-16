// 对齐 Android: keyboard/typing/accessibility/TypingAccessibilityLabels.kt
// Android 版直接写 View.contentDescription;鸿蒙侧为纯文案表:
// 返回无障碍描述字符串,由 UI agent 设置到 ArkUI accessibilityText/accessibilityDescription。
import { common } from '@kit.AbilityKit';
import { MobileStrings } from '../../../core/locale/MobileStrings';
import { Candidate } from '../../pinyin/PinyinEngine';
import { KeySpec, KeyType } from '../KeyModels';

/** 键盘无障碍标签与状态播报文案(集中管理,避免散落)。 */
export class TypingAccessibilityLabels {

  /** 按键无障碍描述(Android applyKeyLabel 的文案部分)。 */
  static keyLabel(spec: KeySpec, context: common.Context, shiftActive: boolean, capsLock: boolean): string {
    switch (spec.type) {
      case KeyType.LETTER: {
        const ch = shiftActive || capsLock ? spec.main.toUpperCase() : spec.main;
        return MobileStrings.a11yKeyLetter(ch);
      }
      case KeyType.T9:
        return MobileStrings.a11yKeyT9(spec.main, spec.sub ?? '');
      case KeyType.DELETE:
        return MobileStrings.a11yKeyDelete();
      case KeyType.SPACE:
        return MobileStrings.a11yKeySpace();
      case KeyType.ENTER:
        return MobileStrings.a11yKeyEnter();
      case KeyType.SHIFT: {
        if (capsLock) return MobileStrings.a11yKeyCapsLock();
        return shiftActive ? MobileStrings.a11yKeyShiftOn() : MobileStrings.a11yKeyShift();
      }
      case KeyType.LANG:
        return MobileStrings.a11yKeyLang();
      case KeyType.LAYOUT:
        return MobileStrings.a11yKeyLayout();
      case KeyType.SYMBOL:
        return MobileStrings.a11yKeySymbols();
      case KeyType.NUM:
        return MobileStrings.a11yKeySymbols();
      case KeyType.ALPHA:
        return MobileStrings.a11yKeyAlpha();
      case KeyType.SYM_PAGE:
        return MobileStrings.a11yKeySymPage();
      case KeyType.SYM_CHAR:
        return MobileStrings.a11yKeyChar(spec.main);
      // 模式轮换键:读出下一模式(spec.sub);符号板入口读布局键通用描述
      case KeyType.MODE_CYCLE:
        return MobileStrings.a11yKeyLayout() + (spec.sub !== undefined ? ` ${spec.sub}` : '');
      case KeyType.SYM_BOARD:
        return MobileStrings.a11yKeySymbols();
      // 9 宫格 1 键(@#):高频符号候选入口,读作符号键
      case KeyType.SYM_CANDS:
        return MobileStrings.a11yKeySymbols();
      default:
        return spec.main;
    }
  }

  /** 候选项无障碍描述(Android announceCandidate 的文案部分)。 */
  static candidateLabel(candidate: Candidate, index: number): string {
    return `${index + 1}. ${candidate.word}`;
  }

  // Android announceStatus(View.announceForAccessibility)为视图行为,鸿蒙侧由 UI 层
  // 用 ArkUI 无障碍播报能力实现;状态文案本身即 message 原文,无需转换,故不在本表提供方法。
}
