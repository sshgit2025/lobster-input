// 对齐 Android: keyboard/typing/editor/EditorInfoResolver.kt
// Android EditorInfo(imeOptions/inputType) → 鸿蒙 inputMethodEngine.EditorAttribute(enterKeyType/inputPattern)。
import { inputMethod, inputMethodEngine } from '@kit.IMEKit';
import { common } from '@kit.AbilityKit';
import { MobileStrings } from '../../../core/locale/MobileStrings';
import { EditorActionModel, EditorInfoAction } from './EditorActionModel';

/** 从 EditorAttribute 解析 Enter 键标签与动作(策略模式入口)。 */
export class EditorInfoResolver {

  static resolve(context: common.Context, info?: inputMethodEngine.EditorAttribute): EditorActionModel {
    if (info === undefined) return EditorActionModel.DEFAULT;
    const enterKeyType = info.enterKeyType;
    const inputPattern = info.inputPattern;
    // Android TYPE_TEXT_FLAG_MULTI_LINE → 鸿蒙 TextInputType.MULTILINE
    const multiline = inputPattern === inputMethod.TextInputType.MULTILINE;
    // Android:文本类密码 / 数字类密码 → isPassword
    // 鸿蒙:VISIBLE_PASSWORD(标准密码框)/ NEW_PASSWORD / SCREEN_LOCK_PASSWORD / NUMBER_PASSWORD
    const isPassword = inputPattern === inputMethod.TextInputType.VISIBLE_PASSWORD ||
      inputPattern === inputMethod.TextInputType.NEW_PASSWORD ||
      inputPattern === inputMethod.TextInputType.SCREEN_LOCK_PASSWORD ||
      inputPattern === inputMethod.TextInputType.NUMBER_PASSWORD;
    // 数字/电话/日期时间输入框 → 自动数字键盘(对齐 Gboard/搜狗)
    // Android NUMBER 类含数字密码 → NUMBER_PASSWORD/NUMBER_DECIMAL 同样归入数字框
    const isNumeric = inputPattern === inputMethod.TextInputType.NUMBER ||
      inputPattern === inputMethod.TextInputType.PHONE ||
      inputPattern === inputMethod.TextInputType.DATETIME ||
      inputPattern === inputMethod.TextInputType.NUMBER_DECIMAL ||
      inputPattern === inputMethod.TextInputType.NUMBER_PASSWORD;
    // 邮箱/URI/密码/账号类文本框 → 自动英文模式(对齐 Gboard/搜狗;仅本次会话,不覆盖用户偏好)
    // USER_NAME 为鸿蒙特有的账号输入类型,语义等价 Android 账号类 ASCII 框,一并纳入
    const isEnglish = inputPattern === inputMethod.TextInputType.EMAIL_ADDRESS ||
      inputPattern === inputMethod.TextInputType.URL ||
      inputPattern === inputMethod.TextInputType.VISIBLE_PASSWORD ||
      inputPattern === inputMethod.TextInputType.NEW_PASSWORD ||
      inputPattern === inputMethod.TextInputType.USER_NAME;

    let action: EditorInfoAction;
    if (enterKeyType === inputMethod.EnterKeyType.SEARCH) {
      action = EditorInfoAction.SEARCH;
    } else if (enterKeyType === inputMethod.EnterKeyType.SEND) {
      action = EditorInfoAction.SEND;
    } else if (enterKeyType === inputMethod.EnterKeyType.GO) {
      action = EditorInfoAction.GO;
    } else if (enterKeyType === inputMethod.EnterKeyType.DONE) {
      action = EditorInfoAction.DONE;
    } else if (enterKeyType === inputMethod.EnterKeyType.NEXT) {
      action = EditorInfoAction.NEXT;
    } else if (enterKeyType === inputMethod.EnterKeyType.PREVIOUS) {
      action = EditorInfoAction.PREVIOUS;
    } else {
      // UNSPECIFIED/NONE/NEWLINE(与 Android 一致:多行与否最终都落 NEWLINE)
      action = EditorInfoAction.NEWLINE;
    }

    let label: string;
    switch (action) {
      case EditorInfoAction.SEARCH:
        label = MobileStrings.enterSearch();
        break;
      case EditorInfoAction.SEND:
        label = MobileStrings.enterSend();
        break;
      case EditorInfoAction.GO:
        label = MobileStrings.enterGo();
        break;
      case EditorInfoAction.DONE:
        label = MobileStrings.enterDone();
        break;
      case EditorInfoAction.NEXT:
        label = MobileStrings.enterNext();
        break;
      case EditorInfoAction.PREVIOUS:
        label = MobileStrings.enterPrevious();
        break;
      default:
        label = MobileStrings.enterNewline();
        break;
    }
    return new EditorActionModel(label, action, multiline, isPassword, isNumeric, isEnglish);
  }
}
