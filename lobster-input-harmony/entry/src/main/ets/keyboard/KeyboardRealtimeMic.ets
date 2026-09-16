import { inputMethodEngine } from '@kit.IMEKit';
import { RealtimeAudioStreamer } from '../core/audio/RealtimeAudioStreamer';
import { RealtimeAsrErrorKind, RealtimeAsrWebSocketClient } from '../core/network/RealtimeAsrWebSocketClient';
import { TypewriterReveal } from './TypewriterReveal';
import { Logger } from '../core/log/Logger';

const TAG: string = 'KeyboardRealtimeMic';

/** 等价 Kotlin 的 delay(ms) */
function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: (value: void) => void) => {
    setTimeout(() => resolve(undefined), ms);
  });
}

/**
 * 回调契约(移植自 Kotlin KeyboardRealtimeMic.Callbacks 嵌套接口;
 * ArkTS 不支持类内嵌套接口,提为顶层导出接口)。
 */
export interface KeyboardRealtimeMicCallbacks {
  language(): string;
  /** 等价安卓 inputConnection():返回当前输入法客户端,不可用时返回 null */
  inputConnection(): inputMethodEngine.InputClient | null;
  onActiveChanged(active: boolean): void;
  onError(kind: RealtimeAsrErrorKind, message: string): void;
}

/**
 * 键盘模式内的流式实时麦克风会话(独立模块,与语音模式数据隔离)。
 * (移植自 keyboard/KeyboardRealtimeMic.kt)
 *
 * 强制实时流式(不受设置页 SYNC/REALTIME 开关影响):识别文本直接以预览方式上屏,
 * 不写语音历史、不参与指令二次加工。复用 RealtimeAudioStreamer 与 RealtimeAsrWebSocketClient,
 * 但维护独立的会话状态与音频缓冲,绝不触碰语音模式字段。
 *
 * 与安卓差异说明:
 *  - 安卓用 setComposingText/finishComposingText 做 composing 预览;鸿蒙 API 12 的
 *    InputClient 无 composing 能力,这里用「删除旧预览 + 插入新预览」模拟整段替换,
 *    且当新预览是旧预览的扩展时只插增量(TypewriterReveal 逐字揭示下几乎总是增量,
 *    避免每 tick 闪烁)。收尾"定格"即文本已真实提交,无需 finishComposingText 等价调用。
 *  - 安卓的 uiHandler.post 用于把 WS/采集线程回调切回主线程;ArkTS 所有回调本就在
 *    同一事件循环上,直接调用即可,时序语义不变。
 *  - CoroutineScope 构造参数无对应物,协程体改为 async 方法。
 */
export class KeyboardRealtimeMic {
  private static readonly FINISH_TIMEOUT_MS: number = 1500;
  private static readonly FINISH_POLL_MS: number = 40;
  private static readonly KEYBOARD_MAX_SEC: number = 60;
  // 待发音频缓冲上限 2.5MB(与语音模式 REALTIME_AUDIO_BUFFER_LIMIT_BYTES 对齐):
  // WS 长时间未就绪等异常场景下超限则丢最旧,防止内存无限膨胀。
  private static readonly MAX_BUFFER_BYTES: number = 2500000;

  private readonly streamer: RealtimeAudioStreamer;
  private readonly callbacks: KeyboardRealtimeMicCallbacks;

  /** WS 未就绪时的待发音频队列(等价安卓 ArrayDeque<ByteArray>) */
  private buffer: ArrayBuffer[] = [];
  /** WS 未就绪时的待发音频累计字节数,配合 MAX_BUFFER_BYTES 上限防止异常场景无限膨胀 */
  private bufferedBytes: number = 0;
  private client: RealtimeAsrWebSocketClient | null = null;
  private ready: boolean = false;
  private finishing: boolean = false;
  private previewLen: number = 0;
  /** 当前已上屏的预览文本(鸿蒙无 composing 区域,需自行记录以便替换) */
  private previewText: string = '';
  private finalReceived: boolean = false;
  // 实时识别打字机平滑层:把突发 partial 平滑成逐字揭示,只影响预览。
  private readonly typewriter: TypewriterReveal;

  private _isActive: boolean = false;

  constructor(streamer: RealtimeAudioStreamer, callbacks: KeyboardRealtimeMicCallbacks) {
    this.streamer = streamer;
    this.callbacks = callbacks;
    this.typewriter = new TypewriterReveal((shown: string) => this.renderComposing(shown));
  }

  get isActive(): boolean {
    return this._isActive;
  }

  /** 开始(authHeader 由调用方在校验登录/权限后传入)。 */
  start(authHeader: string): void {
    if (this._isActive) {
      return;
    }
    this._isActive = true;
    this.finishing = false;
    this.ready = false;
    this.previewLen = 0;
    this.previewText = '';
    this.finalReceived = false;
    this.typewriter.reset();
    this.buffer = [];
    this.bufferedBytes = 0;
    this.callbacks.onActiveChanged(true);

    const c = new RealtimeAsrWebSocketClient(
      authHeader,
      this.callbacks.language(),
      (text: string, _language: string) => {
        if (this._isActive && !this.finishing) {
          this.preview(text);
        }
      },
      // onCompleted 是 ASR 权威最终结果:即便已进入 finishing 也要采纳,作为收尾定格的目标。
      (text: string, _language: string) => {
        if (this._isActive || this.finishing) {
          this.typewriter.setTarget(text.trim());
          this.finalReceived = true;
        }
      },
      (kind: RealtimeAsrErrorKind, msg: string) => {
        if (this._isActive) {
          this.callbacks.onError(kind, msg);
          this.stop();
        }
      }
    );
    this.client = c;

    // 键盘麦克风固定 60s 上限(后端最长处理 60s 音频;倒计时环随之从 60s 递减)
    this.streamer.maxDurationSec = KeyboardRealtimeMic.KEYBOARD_MAX_SEC;
    this.streamer.start(
      (bytes: ArrayBuffer) => this.onChunk(bytes),
      () => this.stop()
    ).then((started: boolean) => {
      if (!started) {
        // 异步启动期间可能已被外部 stop(),此时收尾已由 stop() 完成,不再重复回调
        if (!this._isActive) {
          return;
        }
        this._isActive = false;
        this.callbacks.onActiveChanged(false);
        c.close();
        this.client = null;
        this.callbacks.onError(RealtimeAsrErrorKind.SERVER, '');
        return;
      }
      // 等价安卓 scope.launch { c.connect(); ready = true; flush() }
      c.connect().then(() => {
        this.ready = true;
        this.flush();
      }).catch((e: Error) => {
        if (this._isActive) {
          // 连接阶段失败(超时/断链)按链路层错误处理,不透传底层原文
          this.callbacks.onError(RealtimeAsrErrorKind.NETWORK,
            e !== undefined && e.message !== undefined ? e.message : '');
          this.stop();
        }
      });
    });
  }

  stop(): void {
    if (!this._isActive || this.finishing) {
      return;
    }
    this.finishing = true;
    // 立即把预览补齐到最新完整目标:停止后 onPartial/onCompleted 已被 finishing 门控屏蔽,
    // 必须保证随后定格锁定的是完整文本,而不是揭示到一半的残缺串。
    this.typewriter.flush();
    this.streamer.stop();
    this._isActive = false;
    this.callbacks.onActiveChanged(false);

    const c = this.client;
    if (c === null) {
      this.finishing = false;
      return;
    }
    this.finishSession(c);
  }

  /** 收尾协程(等价安卓 stop() 内的 scope.launch 块) */
  private async finishSession(c: RealtimeAsrWebSocketClient): Promise<void> {
    try {
      if (!this.ready) {
        // 等价安卓 runCatching { c.connect(); ready = true }
        try {
          await c.connect();
          this.ready = true;
        } catch (e) {
          Logger.w(TAG, `late connect failed: ${e}`);
        }
      }
      this.flush();
      c.requestFinish();
      // 完成/超时竞速:onCompleted(权威最终结果)先到则立即定格,否则最多等 1.5s 兜底,
      // 避免固定盲等导致尾部更正丢失或无谓延迟。
      let waited = 0;
      while (!this.finalReceived && waited < KeyboardRealtimeMic.FINISH_TIMEOUT_MS) {
        await sleep(KeyboardRealtimeMic.FINISH_POLL_MS);
        waited += KeyboardRealtimeMic.FINISH_POLL_MS;
      }
      this.typewriter.flush();
      // 等价安卓 finishComposingText:鸿蒙预览采用「删旧插新」直接上屏,
      // 最新完整文本已真实提交在编辑器中,这里只需把预览状态清零表示定格。
      this.previewLen = 0;
      this.previewText = '';
    } finally {
      c.close();
      this.client = null;
      this.ready = false;
      this.previewLen = 0;
      this.previewText = '';
      this.finalReceived = false;
      this.typewriter.reset();
      this.buffer = [];
      this.bufferedBytes = 0;
      this.finishing = false;
    }
  }

  private onChunk(bytes: ArrayBuffer): void {
    const c = this.client;
    if (c === null) {
      return;
    }
    if (this.ready) {
      this.flush();
      if (!c.sendAudio(bytes)) {
        this.enqueue(bytes);
      }
    } else {
      this.enqueue(bytes);
    }
  }

  /** 入队待发音频并施加 2.5MB 上限:超限先丢最旧,单块超限直接丢弃。 */
  private enqueue(bytes: ArrayBuffer): void {
    while (this.bufferedBytes + bytes.byteLength > KeyboardRealtimeMic.MAX_BUFFER_BYTES &&
      this.buffer.length > 0) {
      const removed = this.buffer.shift();
      if (removed !== undefined) {
        this.bufferedBytes -= removed.byteLength;
      }
    }
    if (bytes.byteLength <= KeyboardRealtimeMic.MAX_BUFFER_BYTES) {
      this.buffer.push(bytes);
      this.bufferedBytes += bytes.byteLength;
    }
  }

  private flush(): void {
    const c = this.client;
    if (c === null) {
      return;
    }
    if (!this.ready) {
      return;
    }
    while (this.buffer.length > 0) {
      if (!c.sendAudio(this.buffer[0])) {
        break;
      }
      const removed = this.buffer.shift();
      if (removed !== undefined) {
        this.bufferedBytes -= removed.byteLength;
      }
    }
  }

  private preview(text: string): void {
    // 喂给打字机平滑层;实际逐字渲染走 renderComposing。
    this.typewriter.setTarget(text.trim());
  }

  /**
   * 计算字符串的 Unicode 码点数(跨过 UTF-16 代理对)。
   * 鸿蒙 deleteBackward 以"字符(码点)"计,直接传 UTF-16 .length 会在预览含
   * emoji 等代理对时多删(切断代理对);安卓 setComposingText 整段替换无此问题,
   * 换算后语义对齐(等价 ime/InputClientAdapter 的 codePointCount)。
   */
  private static codePointCount(text: string): number {
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

  /**
   * 渲染预览(等价安卓 renderComposing 的 setComposingText(shown, 1))。
   * 鸿蒙无 composing 区域:用「删除旧预览 + 插入新预览」模拟整段替换;
   * TypewriterReveal 保证 shown 始终是最新 target 的前缀,正常揭示时新预览
   * 是旧预览的扩展,只需插入增量,不会闪烁;发生纠正/整句替换时才整段删换,
   * 删除长度按码点数换算,保证 emoji 代理对不被切断(对齐安卓整段替换语义)。
   * 注意:预览期间若用户手动移动光标/编辑文本,删换可能作用于错误位置
   * (安卓 composing 由系统兜底,鸿蒙此为已知限制)。
   */
  private renderComposing(shown: string): void {
    const ic = this.callbacks.inputConnection();
    if (ic === null) {
      return;
    }
    try {
      if (shown === this.previewText) {
        return;
      }
      if (shown.startsWith(this.previewText)) {
        // 增量追加(逐字揭示的常规路径)
        const delta = shown.substring(this.previewText.length);
        if (delta.length > 0) {
          ic.insertTextSync(delta);
        }
      } else {
        // 纠正/整句替换:删旧插新(按码点计数,防切断代理对)
        if (this.previewText.length > 0) {
          ic.deleteBackwardSync(KeyboardRealtimeMic.codePointCount(this.previewText));
        }
        if (shown.length > 0) {
          ic.insertTextSync(shown);
        }
      }
      this.previewText = shown;
      this.previewLen = shown.length;
    } catch (e) {
      Logger.w(TAG, `renderComposing failed: ${e}`);
    }
  }
}
