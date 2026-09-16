// 对齐 Android: keyboard/typing/composing/TypingUndoManager.kt

/**
 * 打字模式撤销栈:记录最近上屏文本,支持一键撤销(与语音模式 undo 独立)。
 */
export class TypingUndoManager {
  private readonly maxDepth: number;
  private readonly stack: string[] = [];

  constructor(maxDepth: number = 32) {
    this.maxDepth = maxDepth;
  }

  record(text: string): void {
    if (text.length === 0) return;
    this.stack.push(text);
    while (this.stack.length > this.maxDepth) this.stack.shift();
  }

  canUndo(): boolean {
    return this.stack.length > 0;
  }

  peek(): string | undefined {
    return this.stack.length === 0 ? undefined : this.stack[this.stack.length - 1];
  }

  pop(): string | undefined {
    return this.stack.pop();
  }
}
