/**
 * InputClientAdapter.ets — 安卓 InputConnection 语义在 HarmonyOS inputMethodEngine.InputClient 上的适配层。
 * 完整实现打字逻辑层契约 ImeClientApi(ets/keyboard/typing/ImeClientApi.ets)。
 *
 * ── 组合文本(setComposing)模拟策略 ──
 * 鸿蒙 InputClient 没有 setComposingText/finishComposingText。本适配器维护"内部组合缓冲":
 *  - setComposing(text):若已有组合串,先删除上一次组合串(deleteForward N),再 insertText(text);
 *    对外表现与安卓"整段替换组合区"一致(实时 ASR 预览逐字揭示正是靠它)。
 *  - commitText(text) 处于组合中时:先删除组合串再插入 text,等价于安卓"提交替换组合区"。
 *  - finishComposing():组合串本来就是编辑器中的真实文本,只需清空内部缓冲(原地固化),
 *    与安卓 finishComposingText 的可见结果一致。
 *  - 所有编辑操作经内部 Promise 队列串行执行,确保与安卓 InputConnection 的调用时序等价
 *    (打字机 30ms tick 的连续 setComposing 绝不允许交错)。
 *
 * ── 同步/异步双通道 ──
 * ImeClientApi 契约的方法是同步签名(boolean/string/void):
 *  - 写操作(commitText/setComposing/...)同步入队即返回(true = 已受理入队;失败在队内吞掉并记日志),
 *    与安卓 InputConnection "返回是否已接受请求"的语义等价;
 *  - 读操作 getTextBeforeCursor/getTextAfterCursor 走 InputClient.getForwardSync/getBackwardSync
 *    (契约推荐实现),失败返回空串(安卓返回 null 的等价降级)。
 *  服务层(本目录)需要真实完成时机/结果时使用 *Async 扩展方法(经串行队列)。
 *
 * ── 选区文本(getSelectedText)模拟 ──
 * InputClient 没有读取选中文本的 API。由服务层把 KeyboardDelegate 的
 * selectionChange / textChange 事件喂给本适配器(onSelectionChange/onTextChange),
 * 用"全文缓存 + 选区区间"还原选中文本;删除/替换选区通过
 * selectByRange 折叠光标到选区末尾 + deleteForward(选区长度) 实现。
 *
 * ── 删除长度单位 ──
 * 安卓 deleteSurroundingText 以 UTF-16 code unit 计;鸿蒙 deleteForward/deleteBackward
 * 以"字符"计。对已知字符串(组合串/选区/整段撤回)统一用码点数换算(codePointCount),
 * 避免 emoji 等代理对导致多删/少删;纯数字长度请求(如退格 1)原样透传。
 */
import { inputMethodEngine, inputMethod } from '@kit.IMEKit';
import { ImeClientApi } from '../keyboard/typing/ImeClientApi';
import { EditorInfoAction } from '../keyboard/typing/editor/EditorActionModel';
import { Logger } from '../core/log/Logger';

const TAG = 'InputClientAdapter';

/** 计算字符串的 Unicode 码点数(跨过 UTF-16 代理对),用于鸿蒙删除接口的长度换算。 */
function codePointCount(text: string): number {
  let count = 0;
  let i = 0;
  while (i < text.length) {
    const cp = text.codePointAt(i);
    if (cp === undefined) {
      break;
    }
    i += cp > 0xFFFF ? 2 : 1;
    count++;
  }
  return count;
}

export class InputClientAdapter implements ImeClientApi {
  private client: inputMethodEngine.InputClient;
  /** 编辑操作串行队列:保证 commit/delete/setComposing 的执行顺序与调用顺序一致。 */
  private queue: Promise<void> = Promise.resolve();
  /** 内部组合缓冲(模拟安卓 composing region)。 */
  private composingText: string = '';
  private composingActive: boolean = false;
  /** 选区区间镜像(由服务层转发 KeyboardDelegate.selectionChange 事件维护)。 */
  private selBegin: number = 0;
  private selEnd: number = 0;
  /** 编辑器全文缓存(由服务层转发 KeyboardDelegate.textChange 事件维护)。 */
  private fullTextCache: string = '';
  /** 编辑框回车动作类型(EditorAttribute.enterKeyType),sendEnterKeyEvent 时使用。 */
  private enterKeyType: number = 0;

  constructor(client: inputMethodEngine.InputClient) {
    this.client = client;
  }

  // ==================== 服务层事件喂入 ====================

  onSelectionChange(newBegin: number, newEnd: number): void {
    this.selBegin = newBegin;
    this.selEnd = newEnd;
  }

  onTextChange(text: string): void {
    this.fullTextCache = text;
  }

  setEnterKeyType(type: number): void {
    this.enterKeyType = type;
  }

  // ==================== 选区(同步,来自缓存镜像) ====================

  hasSelection(): boolean {
    return this.selBegin !== this.selEnd;
  }

  /** 对齐安卓 InputConnection.getSelectedText(0):无选区返回空串(ImeClientApi 契约)。 */
  getSelectedText(): string {
    const start = Math.min(this.selBegin, this.selEnd);
    const end = Math.max(this.selBegin, this.selEnd);
    if (start >= end) {
      return '';
    }
    if (end <= this.fullTextCache.length) {
      return this.fullTextCache.substring(start, end);
    }
    return '';
  }

  // ==================== 内部队列 ====================

  /** 把操作追加到串行队列;失败吞异常返回 false(对齐安卓 InputConnection 返回布尔的惯例)。 */
  private enqueueBool(op: () => Promise<void>): Promise<boolean> {
    const run: Promise<boolean> = this.queue.then((): Promise<boolean> => {
      return op()
        .then((): boolean => true)
        .catch((e: Error): boolean => {
          Logger.w(TAG, 'edit op failed: ' + e.message);
          return false;
        });
    });
    this.queue = run.then((): void => {});
    return run;
  }

  /** 读取类操作也入队:保证读取发生在此前所有写操作之后(时序与安卓一致)。 */
  private enqueueText(op: () => Promise<string>): Promise<string> {
    const run: Promise<string> = this.queue.then((): Promise<string> => {
      return op().catch((e: Error): string => {
        Logger.w(TAG, 'read op failed: ' + e.message);
        return '';
      });
    });
    this.queue = run.then((): void => {});
    return run;
  }

  /** 删除当前选区(折叠光标到选区末尾后向前删除选区长度)。必须在队列内调用。 */
  private async deleteSelectionInternal(): Promise<void> {
    const start = Math.min(this.selBegin, this.selEnd);
    const end = Math.max(this.selBegin, this.selEnd);
    if (start >= end) {
      return;
    }
    const selected = this.getSelectedText();
    const range: inputMethodEngine.Range = { start: end, end: end };
    await this.client.selectByRange(range);
    const len = selected.length > 0 ? codePointCount(selected) : end - start;
    if (len > 0) {
      await this.client.deleteForward(len);
    }
    // 本地镜像立即折叠,等待 selectionChange 事件最终校准
    this.selBegin = start;
    this.selEnd = start;
  }

  // ==================== ImeClientApi(安卓 InputConnection 语义,契约签名) ====================

  /**
   * 对齐安卓 commitText(text, 1):
   *  - 有选区时替换选区;
   *  - 处于组合中时替换组合区;
   *  - 否则在光标处插入。
   * 同步返回"是否已受理"(入队即受理;真实执行结果见 commitTextAsync)。
   */
  commitText(text: string): boolean {
    this.commitTextAsync(text);
    return true;
  }

  /** commitText 的可等待版本(服务层撤回/换行降级路径使用)。 */
  commitTextAsync(text: string): Promise<boolean> {
    return this.enqueueBool(async (): Promise<void> => {
      if (this.hasSelection()) {
        await this.deleteSelectionInternal();
      }
      if (this.composingActive && this.composingText.length > 0) {
        await this.client.deleteForward(codePointCount(this.composingText));
      }
      this.composingText = '';
      this.composingActive = false;
      if (text.length > 0) {
        await this.client.insertText(text);
      }
    });
  }

  /**
   * 对齐安卓 setComposingText(text, 1):内部组合缓冲模拟(详见文件头说明)。
   * 有选区时先替换选区(与安卓行为一致)。
   */
  setComposing(text: string): void {
    this.setComposingAsync(text);
  }

  /** setComposing 的可等待版本(内部/服务层使用)。 */
  setComposingAsync(text: string): Promise<boolean> {
    return this.enqueueBool(async (): Promise<void> => {
      if (this.hasSelection()) {
        await this.deleteSelectionInternal();
      }
      if (this.composingActive && this.composingText.length > 0) {
        await this.client.deleteForward(codePointCount(this.composingText));
      }
      if (text.length > 0) {
        await this.client.insertText(text);
      }
      this.composingText = text;
      this.composingActive = text.length > 0;
    });
  }

  /** 对齐安卓 finishComposingText():组合串原地固化为普通文本(只清内部缓冲)。 */
  finishComposing(): void {
    this.finishComposingAsync();
  }

  /** finishComposing 的可等待版本(服务层清空输入框前置步骤使用)。 */
  finishComposingAsync(): Promise<boolean> {
    return this.enqueueBool(async (): Promise<void> => {
      this.composingText = '';
      this.composingActive = false;
    });
  }

  /** 对齐安卓 deleteSurroundingText(before, after)。数值长度原样透传(入队串行)。 */
  deleteSurroundingText(beforeLength: number, afterLength: number): void {
    this.enqueueBool(async (): Promise<void> => {
      if (beforeLength > 0) {
        await this.client.deleteForward(beforeLength);
      }
      if (afterLength > 0) {
        await this.client.deleteBackward(afterLength);
      }
    });
  }

  /**
   * 对齐安卓 getTextBeforeCursor(length, 0):契约同步签名,走 getForwardSync
   * (鸿蒙 getForward = 光标前文本);失败返回空串(安卓返回 null 的等价降级)。
   */
  getTextBeforeCursor(length: number): string {
    try {
      return this.client.getForwardSync(length);
    } catch (e) {
      Logger.w(TAG, 'getForwardSync failed: ' + (e as Error).message);
      return '';
    }
  }

  /** 对齐安卓 getTextAfterCursor(length, 0):契约同步签名,走 getBackwardSync。 */
  getTextAfterCursor(length: number): string {
    try {
      return this.client.getBackwardSync(length);
    } catch (e) {
      Logger.w(TAG, 'getBackwardSync failed: ' + (e as Error).message);
      return '';
    }
  }

  /** 对齐安卓 setSelection(start, end):InputClient.selectByRange(经队列,保证先于其前写操作生效)。 */
  setSelection(start: number, end: number): void {
    this.enqueueBool(async (): Promise<void> => {
      const range: inputMethodEngine.Range = { start: start, end: end };
      await this.client.selectByRange(range);
      // 本地镜像先行更新,等待 selectionChange 事件最终校准
      this.selBegin = start;
      this.selEnd = end;
    });
  }

  /** 对齐安卓 performEditorAction:EditorInfoAction → InputClient.sendKeyFunction 映射。 */
  performEditorAction(action: EditorInfoAction): void {
    const key = this.editorActionKeyFunction(action);
    this.enqueueBool(async (): Promise<void> => {
      await this.client.sendKeyFunction(key);
    });
  }

  /** EditorInfoAction → 鸿蒙 EnterKeyType 数值(sendKeyFunction 入参)。 */
  private editorActionKeyFunction(action: EditorInfoAction): number {
    switch (action) {
      case EditorInfoAction.SEARCH:
        return inputMethod.EnterKeyType.SEARCH;
      case EditorInfoAction.SEND:
        return inputMethod.EnterKeyType.SEND;
      case EditorInfoAction.GO:
        return inputMethod.EnterKeyType.GO;
      case EditorInfoAction.DONE:
        return inputMethod.EnterKeyType.DONE;
      case EditorInfoAction.NEXT:
        return inputMethod.EnterKeyType.NEXT;
      case EditorInfoAction.PREVIOUS:
        return inputMethod.EnterKeyType.PREVIOUS;
      default:
        // NEWLINE 等:回退到编辑框自己声明的回车动作类型
        return this.enterKeyType;
    }
  }

  /** 发送编辑器回车动作(安卓 sendKeyEvent(KEYCODE_ENTER) 的鸿蒙等价:sendKeyFunction)。 */
  sendEnterKeyEvent(): void {
    this.sendEnterKeyAsync();
  }

  /** sendEnterKeyEvent 的可等待版本(服务层换行降级路径使用)。 */
  sendEnterKeyAsync(): Promise<boolean> {
    return this.enqueueBool(async (): Promise<void> => {
      await this.client.sendKeyFunction(this.enterKeyType);
    });
  }

  /** 批量编辑边界:鸿蒙 InputClient 无对应能力,按契约实现为空(保留调用时序)。 */
  beginBatchEdit(): void {
    // no-op(契约允许:鸿蒙无对应能力)
  }

  /** 批量编辑边界:同 beginBatchEdit,空实现。 */
  endBatchEdit(): void {
    // no-op(契约允许:鸿蒙无对应能力)
  }

  // ==================== 服务层专用扩展(非契约) ====================

  /** 删除光标前的指定字符串(按码点数换算长度,对齐安卓"逐字删除 text.length 次")。 */
  deleteTextBeforeCursor(text: string): Promise<boolean> {
    return this.enqueueBool(async (): Promise<void> => {
      const len = codePointCount(text);
      if (len > 0) {
        await this.client.deleteForward(len);
      }
    });
  }

  /** getTextBeforeCursor 的入队版本:保证读取发生在此前所有写操作之后(服务层上下文采集用)。 */
  getTextBeforeCursorAsync(length: number): Promise<string> {
    return this.enqueueText(async (): Promise<string> => {
      return await this.client.getForward(length);
    });
  }

  /** getTextAfterCursor 的入队版本。 */
  getTextAfterCursorAsync(length: number): Promise<string> {
    return this.enqueueText(async (): Promise<string> => {
      return await this.client.getBackward(length);
    });
  }

  /** 光标移动(方向键等场景;direction 取 inputMethodEngine.CURSOR_*)。 */
  moveCursor(direction: number): Promise<boolean> {
    return this.enqueueBool(async (): Promise<void> => {
      await this.client.moveCursor(direction);
    });
  }

  /**
   * 清空整个输入框(对齐安卓 handleClearInputText 的兜底路径):
   * 先固化组合串、折叠选区,再读出光标前后全文并成对删除。
   */
  clearAllText(maxChars: number): Promise<boolean> {
    return this.enqueueBool(async (): Promise<void> => {
      this.composingText = '';
      this.composingActive = false;
      if (this.hasSelection()) {
        await this.deleteSelectionInternal();
      }
      const before = await this.client.getForward(maxChars);
      const after = await this.client.getBackward(maxChars);
      if (before.length > 0) {
        await this.client.deleteForward(codePointCount(before));
      }
      if (after.length > 0) {
        await this.client.deleteBackward(codePointCount(after));
      }
    });
  }

  /** 当前是否处于(模拟的)组合状态。 */
  isComposing(): boolean {
    return this.composingActive;
  }
}
