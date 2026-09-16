import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { ApiConfig } from './ApiConfig';
import { Logger } from '../log/Logger';

const TAG: string = 'RealtimeAsrWebSocketClient';

/**
 * 实时识别错误分类(对齐安卓 RealtimeAsrErrorKind):NETWORK 为链路层错误(弱网断链等,
 * 原始文案是底层英文,不可直接展示给用户);SERVER 为服务端业务错误(message 来自后端下发)。
 */
export enum RealtimeAsrErrorKind {
  NETWORK = 0,
  SERVER = 1
}

/** 实时识别最终结果(移植自 Kotlin data class RealtimeAsrFinal) */
export interface RealtimeAsrFinal {
  text: string;
  language: string;
  creditsRemaining: number | null;
}

/** 服务端下行消息(部分字段可缺省;缺省/null 一律按空串/空值处理) */
interface RealtimeAsrServerMessage {
  type?: string;
  text?: string;
  transcript?: string;
  language?: string;
  message?: string;
  credits_remaining?: number;
}

/** CompletableDeferred 的 Promise 等价物 */
class Deferred<T> {
  readonly promise: Promise<T>;
  private resolveFn: ((value: T) => void) | null = null;
  private rejectFn: ((reason: Error) => void) | null = null;
  private _completed: boolean = false;

  constructor() {
    this.promise = new Promise<T>((resolve: (value: T) => void, reject: (reason?: Object) => void) => {
      this.resolveFn = resolve;
      this.rejectFn = (reason: Error): void => reject(reason);
    });
    // 预挂空 catch:调用方可能从不 await(如键盘麦克风不调用 finish()),
    // 避免 completeExceptionally 造成 unhandled promise rejection。
    this.promise.catch((e: Error): void => {});
  }

  get isCompleted(): boolean {
    return this._completed;
  }

  complete(value: T): void {
    if (this._completed) {
      return;
    }
    this._completed = true;
    const f = this.resolveFn;
    if (f !== null) {
      f(value);
    }
  }

  completeExceptionally(e: Error): void {
    if (this._completed) {
      return;
    }
    this._completed = true;
    const f = this.rejectFn;
    if (f !== null) {
      f(e);
    }
  }
}

/** withTimeout 等价物:超时以 Error 拒绝 */
function withTimeout<T>(p: Promise<T>, ms: number, timeoutMsg: string): Promise<T> {
  return new Promise<T>((resolve: (value: T) => void, reject: (reason?: Object) => void) => {
    const timer = setTimeout(() => {
      reject(new Error(timeoutMsg));
    }, ms);
    p.then((v: T) => {
      clearTimeout(timer);
      resolve(v);
    }).catch((e: Error) => {
      clearTimeout(timer);
      reject(e);
    });
  });
}

/**
 * 实时语音识别 WebSocket 客户端(移植自 core/network/RealtimeAsrWebSocketClient.kt)。
 *
 * 协议(与安卓/后端完全一致):
 *  - 连接:BASE_URL 的 https→wss(http→ws)替换 + AudioV2.REALTIME_ASR 路径 +
 *    query(language/sample_rate=16000/audio_format=pcm/vad=true/max_duration_sec=60/asr_session_id);
 *    请求头 Authorization / X-Client-Platform / Accept-Language / X-Accept-Language。
 *  - 上行:二进制 PCM 帧;结束发文本 {"type":"finish"}。
 *  - 下行:{"type":"ready"|"partial"|"completed"|"finished"|"error", ...}。
 *
 * 与安卓差异说明:
 *  - OkHttp 的 send() 能同步返回入队结果;NetworkKit send 为异步,sendAudio/requestFinish
 *    的布尔返回值仅代表「通过状态门控并已提交发送」,发送失败经 error 事件走 onError 兜底。
 *  - ArkTS 单线程,无需 @Volatile / sendLock(保留同名门控检查,语义不变)。
 *  - OkHttp dispatcher/connectionPool 的显式回收无对应物:NetworkKit 每个 ws 实例独立,close 即释放。
 */
export class RealtimeAsrWebSocketClient {
  readonly asrSessionId: string;

  private readonly authHeader: string;
  private readonly language: string;
  private readonly onPartial: (text: string, language: string) => void;
  private readonly onCompleted: (text: string, language: string) => void;
  private readonly onError: (kind: RealtimeAsrErrorKind, message: string) => void;

  private readyState: boolean = false;
  private closing: boolean = false;
  private finishRequested: boolean = false;
  private finalReceived: boolean = false;

  private ws: webSocket.WebSocket | null = null;
  private ready: Deferred<boolean> = new Deferred<boolean>();
  private finalResult: Deferred<RealtimeAsrFinal> = new Deferred<RealtimeAsrFinal>();

  constructor(
    authHeader: string,
    language: string,
    onPartial: (text: string, language: string) => void,
    onCompleted: (text: string, language: string) => void,
    onError: (kind: RealtimeAsrErrorKind, message: string) => void
  ) {
    this.authHeader = authHeader;
    this.language = language;
    this.onPartial = onPartial;
    this.onCompleted = onCompleted;
    this.onError = onError;
    // 平台前缀标识会话来源(安卓为 android_,鸿蒙用 harmony_)
    this.asrSessionId = `harmony_${util.generateRandomUUID(true).toLowerCase()}`;
  }

  get isReady(): boolean {
    return this.readyState;
  }

  /** 建立连接并等待服务端 {"type":"ready"}(30s 超时,对齐安卓 withTimeout(30_000)) */
  async connect(): Promise<void> {
    this.readyState = false;
    this.closing = false;
    this.finishRequested = false;
    this.finalReceived = false;
    this.ready = new Deferred<boolean>();
    this.finalResult = new Deferred<RealtimeAsrFinal>();

    const ws = webSocket.createWebSocket();
    this.ws = ws;

    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (typeof value === 'string') {
        this.handleMessage(value);
      }
    });
    ws.on('error', (err: BusinessError) => {
      this.handleFailure(err !== undefined && err.message !== undefined && err.message !== ''
        ? err.message : 'Realtime ASR failed');
    });
    ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      this.handleClosed(value !== undefined ? value.reason : '');
    });

    const header: Record<string, string> = {
      'Authorization': this.authHeader,
      'X-Client-Platform': ApiConfig.CLIENT_PLATFORM,
      'Accept-Language': this.language,
      'X-Accept-Language': this.language
    };
    const options: webSocket.WebSocketRequestOptions = { header: header };

    ws.connect(this.buildUrl(), options).catch((e: BusinessError) => {
      this.handleFailure(e !== undefined && e.message !== undefined && e.message !== ''
        ? e.message : 'Realtime ASR failed');
    });

    await withTimeout(this.ready.promise, 30000, 'Realtime ASR connect timeout');
    this.readyState = true;
  }

  /**
   * 发送二进制 PCM 帧。仅在「已就绪且未在收尾/关闭/已收到最终结果」时发送,
   * 返回是否通过门控并提交发送(门控条件逐项对齐安卓 sendAudio)。
   */
  sendAudio(bytes: ArrayBuffer): boolean {
    const socket = this.ws;
    if (socket === null) {
      return false;
    }
    if (!this.readyState || this.finishRequested || this.closing || this.finalReceived) {
      return false;
    }
    socket.send(bytes).catch((e: BusinessError) => {
      Logger.w(TAG, `send audio failed: ${e.message}`);
    });
    return true;
  }

  /** 请求收尾并等待最终结果(90s 超时,对齐安卓 finish) */
  async finish(): Promise<RealtimeAsrFinal> {
    if (!this.requestFinish()) {
      throw new Error('Realtime ASR is not connected');
    }
    return withTimeout(this.finalResult.promise, 90000, 'Realtime ASR finish timeout');
  }

  /** 发送 {"type":"finish"} 请求服务端出最终结果(门控条件逐项对齐安卓 requestFinish) */
  requestFinish(): boolean {
    const socket = this.ws;
    if (socket === null) {
      return false;
    }
    if (!this.readyState || this.closing || this.finalReceived) {
      return false;
    }
    this.finishRequested = true;
    socket.send('{"type":"finish"}').catch((e: BusinessError) => {
      Logger.w(TAG, `send finish failed: ${e.message}`);
    });
    return true;
  }

  /** 主动关闭连接;未完成的等待方以「closed」异常结束(对齐安卓 close) */
  close(): void {
    this.closing = true;
    this.readyState = false;
    const socket = this.ws;
    this.ws = null;
    if (socket !== null) {
      const opts: webSocket.WebSocketCloseOptions = { code: 1000, reason: 'client closed' };
      socket.close(opts).catch((e: BusinessError) => {
        Logger.w(TAG, `close failed: ${e.message}`);
      });
    }
    if (!this.ready.isCompleted) {
      this.ready.completeExceptionally(new Error('closed'));
    }
    if (!this.finalResult.isCompleted) {
      this.finalResult.completeExceptionally(new Error('closed'));
    }
    // 安卓此处显式回收 OkHttp dispatcher 线程池与连接池;
    // NetworkKit 的 ws 实例随 close 释放,无滞留资源,无需对应操作。
  }

  /** 等价安卓 WebSocketListener.onFailure */
  private handleFailure(message: string): void {
    if (this.closing || this.finalReceived) {
      this.readyState = false;
      return;
    }
    this.readyState = false;
    const err = new Error(message);
    if (!this.ready.isCompleted) {
      this.ready.completeExceptionally(err);
    }
    if (!this.finalResult.isCompleted) {
      this.finalResult.completeExceptionally(err);
    }
    // ws error 事件/connect 失败均为链路层错误,原始文案交由 UI 层换成本地化提示
    this.onError(RealtimeAsrErrorKind.NETWORK, message);
  }

  /** 等价安卓 WebSocketListener.onClosed */
  private handleClosed(reason: string): void {
    this.readyState = false;
    if (!this.closing && !this.finalReceived) {
      const message = reason.trim().length > 0 ? reason : 'Realtime ASR websocket closed';
      const err = new Error(message);
      if (!this.ready.isCompleted) {
        this.ready.completeExceptionally(err);
      }
      if (!this.finalResult.isCompleted) {
        this.finalResult.completeExceptionally(err);
      }
      // 未收到 finished 前连接被对端关闭,同样按链路层异常处理
      this.onError(RealtimeAsrErrorKind.NETWORK, message);
    }
  }

  /** 下行文本消息协议解析,分支逐项对齐安卓 handleMessage */
  private handleMessage(text: string): void {
    let json: RealtimeAsrServerMessage | null = null;
    try {
      json = JSON.parse(text) as RealtimeAsrServerMessage;
    } catch (e) {
      return;
    }
    if (json === null) {
      return;
    }
    const type = RealtimeAsrWebSocketClient.str(json.type);
    if (type === 'ready') {
      if (!this.ready.isCompleted) {
        this.ready.complete(true);
      }
    } else if (type === 'partial') {
      this.onPartial(RealtimeAsrWebSocketClient.str(json.text), RealtimeAsrWebSocketClient.str(json.language));
    } else if (type === 'completed') {
      this.onCompleted(
        RealtimeAsrWebSocketClient.firstNonBlank(
          RealtimeAsrWebSocketClient.str(json.text), RealtimeAsrWebSocketClient.str(json.transcript)),
        RealtimeAsrWebSocketClient.str(json.language));
    } else if (type === 'finished') {
      this.finalReceived = true;
      this.readyState = false;
      const finalValue: RealtimeAsrFinal = {
        text: RealtimeAsrWebSocketClient.firstNonBlank(
          RealtimeAsrWebSocketClient.str(json.text), RealtimeAsrWebSocketClient.str(json.transcript)),
        language: RealtimeAsrWebSocketClient.str(json.language),
        creditsRemaining: RealtimeAsrWebSocketClient.intOrNull(json.credits_remaining)
      };
      if (!this.finalResult.isCompleted) {
        this.finalResult.complete(finalValue);
      }
    } else if (type === 'error') {
      const message = RealtimeAsrWebSocketClient.firstNonBlank(
        RealtimeAsrWebSocketClient.str(json.message), 'Realtime ASR error');
      const err = new Error(message);
      if (!this.ready.isCompleted) {
        this.ready.completeExceptionally(err);
      }
      if (!this.finalResult.isCompleted) {
        this.finalResult.completeExceptionally(err);
      }
      this.onError(RealtimeAsrErrorKind.SERVER, message);
    }
  }

  /** 构造 wss 连接 URL(逐行对齐安卓 buildUrl:trimEnd('/') + https→wss 首次替换) */
  private buildUrl(): string {
    let base = ApiConfig.BASE_URL;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    // JS 的 String.replace(字符串) 只替换首个匹配,等价 Kotlin replaceFirst
    base = base.replace('https://', 'wss://').replace('http://', 'ws://');
    const encodedLang = encodeURIComponent(this.language);
    const encodedSessionId = encodeURIComponent(this.asrSessionId);
    return `${base}/${ApiConfig.AudioV2.REALTIME_ASR}?language=${encodedLang}&sample_rate=16000&audio_format=pcm&vad=true&max_duration_sec=60&asr_session_id=${encodedSessionId}`;
  }

  /** 等价 Kotlin JsonObject.string(name):缺省/null → 空串 */
  private static str(v: string | undefined): string {
    return v !== undefined && v !== null ? v : '';
  }

  /** 等价 Kotlin ifBlank:a 为空白时取 b */
  private static firstNonBlank(a: string, b: string): string {
    return a.trim().length > 0 ? a : b;
  }

  /** 等价 Kotlin JsonObject.intOrNull(name) */
  private static intOrNull(v: number | undefined): number | null {
    if (v === undefined || v === null) {
      return null;
    }
    const n = Math.trunc(v);
    return Number.isFinite(n) ? n : null;
  }
}
