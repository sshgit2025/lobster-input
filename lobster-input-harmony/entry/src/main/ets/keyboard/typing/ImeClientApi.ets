// 鸿蒙侧新增抽象:Android InputConnection 语义 → inputMethodEngine.InputClient 的桥接契约。
// 本模块(打字逻辑层)只面向此接口编程;由 IME 服务层(ets/ime/**)基于 InputClient 实现。
import { EditorInfoAction } from './editor/EditorActionModel';

/** getTextBeforeCursor/getTextAfterCursor 的"取全部"长度(Android Int.MAX_VALUE 等价)。 */
export const IME_TEXT_MAX: number = 0x7fffffff;

/**
 * 打字模块使用的输入连接抽象(方法名与语义对齐 Android InputConnection)。
 *
 * 实现要求(IME 服务层):
 * - commitText:提交文本到光标处;若存在选区则**替换选区**(Android commitText 语义,
 *   onDeleteBeforeCursor 依赖 commitText('') 删除选区);若存在组合串预览则先替换预览再定稿。
 *   返回是否成功(TypingSessionHost 用返回值决定回车换行的降级路径)。
 * - setComposing/finishComposing:鸿蒙 InputClient 没有 setComposingText,
 *   组合串预览需由实现方用「已提交文本 + 内部状态」模拟:setComposing(text) 把 text 显示在
 *   光标处并记录预览区间(重复调用为替换);finishComposing() 把当前预览定稿(文本保留,
 *   预览状态清除)。调用时序与 Android 完全一致(韩语组字逐 jamo 更新预览,flush 时定稿)。
 * - getTextBeforeCursor/getTextAfterCursor:建议用 InputClient.getBackwardSync/getForwardSync
 *   实现;失败时返回空串(Android 返回 null 的等价降级)。
 * - deleteSurroundingText(before, after):光标前删 before 个、光标后删 after 个字符
 *   (deleteBackward/deleteForward)。
 * - setSelection(start, end):移动光标/设置选区(InputClient.selectByRange)。
 * - getSelectedText:无选区返回空串。
 * - performEditorAction:按解析出的编辑器动作发送(InputClient.sendKeyFunction 映射)。
 * - sendEnterKeyEvent:commitText('\n') 失败时的回车键事件降级(Android sendKeyEvent(KEYCODE_ENTER))。
 * - beginBatchEdit/endBatchEdit:批量编辑边界(鸿蒙无对应能力时可实现为空,但必须保留调用时序)。
 */
export interface ImeClientApi {
  commitText(text: string): boolean;

  setComposing(text: string): void;

  finishComposing(): void;

  deleteSurroundingText(beforeLength: number, afterLength: number): void;

  getTextBeforeCursor(length: number): string;

  getTextAfterCursor(length: number): string;

  getSelectedText(): string;

  setSelection(start: number, end: number): void;

  performEditorAction(action: EditorInfoAction): void;

  sendEnterKeyEvent(): void;

  beginBatchEdit(): void;

  endBatchEdit(): void;
}
