// 对齐 Android: keyboard/typing/editor/EditorActionModel.kt

/** Enter 键动作类型(Kotlin 嵌套 enum EditorActionModel.EditorInfoAction → ArkTS 顶层 enum)。 */
export enum EditorInfoAction {
  NEWLINE,
  SEARCH,
  SEND,
  GO,
  DONE,
  NEXT,
  PREVIOUS
}

/** Enter 键展示与行为模型(由 EditorInfoResolver 解析)。 */
export class EditorActionModel {
  readonly label: string;
  readonly action: EditorInfoAction;
  readonly multiline: boolean;
  readonly isPassword: boolean;
  /** 数字/电话/日期时间类输入框:键盘应自动进入数字键盘页(业界标准)。 */
  readonly isNumeric: boolean;
  /** 邮箱/URI/密码类 ASCII 输入框:键盘应自动进入英文模式(对齐 Gboard/搜狗,不覆盖用户偏好)。 */
  readonly isEnglish: boolean;

  constructor(label: string, action: EditorInfoAction, multiline: boolean, isPassword: boolean,
    isNumeric: boolean = false, isEnglish: boolean = false) {
    this.label = label;
    this.action = action;
    this.multiline = multiline;
    this.isPassword = isPassword;
    this.isNumeric = isNumeric;
    this.isEnglish = isEnglish;
  }

  static readonly DEFAULT: EditorActionModel = new EditorActionModel('↵', EditorInfoAction.NEWLINE, false, false);
}
