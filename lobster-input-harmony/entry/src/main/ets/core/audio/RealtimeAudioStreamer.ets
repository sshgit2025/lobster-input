import { audio } from '@kit.AudioKit';
import { common, abilityAccessCtrl, bundleManager } from '@kit.AbilityKit';
import { ApiConfig } from '../network/ApiConfig';
import { Logger } from '../log/Logger';

const TAG: string = 'RealtimeAudioStreamer';

/**
 * 实时 PCM 帧流送器(移植自 core/audio/RealtimeAudioStreamer.kt)。
 *
 * Android 版基于 AudioRecord 阻塞 read() 循环把 PCM 分块回调给上层;
 * HarmonyOS 版基于 AudioCapturer 'readData' 帧回调,系统按固定帧长(约 20ms)主动回推,
 * 无需自建采集线程,也无需 minBufferSize/2048 缓冲策略(帧长由系统决定)。
 *
 * 单线程事件循环下不存在安卓「跨线程 release 与 read() 重叠」的 native 隐患;
 * 但 createAudioCapturer/start 是异步的,用会话代号(session)防护
 * 「启动尚未完成即被 stop」以及晚到的帧回调,达成与安卓协程独占释放等价的安全语义。
 *
 * 帧回调必须轻量(历史教训:每帧重量级同步操作会卡死输入面板):
 * 每帧只做「电平计算 + 缓冲拷贝 + onChunk 派发」。
 *
 * 说明:安卓版没有 warm/预热逻辑(实例常驻、AudioRecord 每次 start 新建),
 * 此处保持相同结构 —— 实例可长期持有复用,AudioCapturer 每次 start 新建、stop 即释放。
 */
export class RealtimeAudioStreamer {
  /** 仅为与 Kotlin 构造签名一致而保留(鸿蒙权限检查基于 tokenId,无需 context) */
  private context: common.Context;
  private capturer: audio.AudioCapturer | null = null;
  private startedAtMs: number = 0;
  /** 会话代号:stop/cleanup 递增,使异步启动窗口与晚到帧回调失效 */
  private session: number = 0;

  private _isStreaming: boolean = false;
  private _audioLevel: number = 0;
  private _remainingSeconds: number = ApiConfig.DEFAULT_MAX_DURATION_SEC;
  private _maxDurationSec: number = ApiConfig.DEFAULT_MAX_DURATION_SEC;

  /** StateFlow 替代:值变化时回调(可空) */
  onStreamingChanged: ((streaming: boolean) => void) | null = null;
  onAudioLevelChanged: ((level: number) => void) | null = null;
  onRemainingSecondsChanged: ((seconds: number) => void) | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  get isStreaming(): boolean {
    return this._isStreaming;
  }

  get audioLevel(): number {
    return this._audioLevel;
  }

  get remainingSeconds(): number {
    return this._remainingSeconds;
  }

  get maxDurationSec(): number {
    return this._maxDurationSec;
  }

  set maxDurationSec(value: number) {
    // 对齐 Kotlin setter:coerceAtLeast(1);未在流送时同步刷新剩余秒数
    this._maxDurationSec = Math.max(1, value);
    if (!this._isStreaming) {
      this.setRemaining(this._maxDurationSec);
    }
  }

  /**
   * 开始流送。onChunk 收到逐帧 PCM(16kHz/单声道/S16LE);
   * 到达最大时长时触发一次 onMaxDuration 并自动停止采集。
   * 无麦克风权限 / 已在流送 / 初始化失败均返回 false(语义对齐安卓)。
   */
  async start(onChunk: (chunk: ArrayBuffer) => void, onMaxDuration: () => void): Promise<boolean> {
    if (this._isStreaming) {
      return false;
    }
    if (!this.hasMicPermission()) {
      return false;
    }

    const mySession = ++this.session;
    try {
      const capturer = await audio.createAudioCapturer(RealtimeAudioStreamer.capturerOptions());
      if (mySession !== this.session) {
        // 异步创建期间已被 stop:直接释放,保持未启动语义
        RealtimeAudioStreamer.releaseAsync(capturer);
        return false;
      }
      this.capturer = capturer;

      // 每会话独立的 maxSent 标志(等价安卓 streamAudio 局部变量)
      let maxSent = false;
      capturer.on('readData', (buf: ArrayBuffer) => {
        if (mySession !== this.session || !this._isStreaming) {
          return;
        }
        const elapsed = Math.floor((Date.now() - this.startedAtMs) / 1000);
        this.setRemaining(Math.max(0, this._maxDurationSec - elapsed));
        if (elapsed >= this._maxDurationSec) {
          if (!maxSent) {
            maxSent = true;
            onMaxDuration();
          }
          // 等价安卓 break → finally:停止并释放本会话采集
          this.stopInternal(mySession);
          return;
        }
        if (buf.byteLength > 0) {
          this.setAudioLevel(this.calculateAudioLevel(buf, buf.byteLength));
          // 系统可能复用回调缓冲区,必须拷贝后派发
          onChunk(buf.slice(0));
        }
      });

      await capturer.start();
      if (mySession !== this.session) {
        this.releaseCapturer();
        return false;
      }

      this.startedAtMs = Date.now();
      this.setStreaming(true);
      this.setRemaining(this._maxDurationSec);
      return true;
    } catch (e) {
      Logger.e(TAG, `start failed: ${e}`);
      this.cleanup();
      return false;
    }
  }

  /** 停止流送并释放采集器(幂等,可随时调用,等价安卓 stop) */
  stop(): void {
    this.session++;
    this.setStreaming(false);
    this.releaseCapturer();
    this.setAudioLevel(0);
    this.setRemaining(this._maxDurationSec);
  }

  /** 彻底释放(安卓版额外 cancel 协程 scope;ArkTS 无对应资源,等价于 stop) */
  release(): void {
    this.stop();
  }

  /** 达到最大时长后的内部收尾(等价安卓 streamAudio 的 finally 块) */
  private stopInternal(session: number): void {
    if (session !== this.session) {
      return;
    }
    this.session++;
    this.setStreaming(false);
    this.releaseCapturer();
    this.setAudioLevel(0);
    this.setRemaining(this._maxDurationSec);
  }

  /** 幂等释放:先置空引用再异步 stop/release,吞掉全部异常(对齐安卓 releaseAudioRecord) */
  private releaseCapturer(): void {
    const c = this.capturer;
    if (c === null) {
      return;
    }
    this.capturer = null;
    try {
      c.off('readData');
    } catch (e) {
      Logger.w(TAG, `off readData failed: ${e}`);
    }
    RealtimeAudioStreamer.releaseAsync(c);
  }

  private static async releaseAsync(c: audio.AudioCapturer): Promise<void> {
    try {
      await c.stop();
    } catch (e) {
      // 未处于运行态时 stop 报错,忽略
    }
    try {
      await c.release();
    } catch (e) {
      // 重复释放等错误,忽略
    }
  }

  private cleanup(): void {
    this.session++;
    this.setStreaming(false);
    this.releaseCapturer();
    this.setAudioLevel(0);
    this.setRemaining(this._maxDurationSec);
  }

  /** 同步检查麦克风权限(等价安卓 checkSelfPermission(RECORD_AUDIO)) */
  private hasMicPermission(): boolean {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const status = atManager.checkAccessTokenSync(
        bundleInfo.appInfo.accessTokenId, 'ohos.permission.MICROPHONE');
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
      Logger.w(TAG, `check mic permission failed: ${e}`);
      return false;
    }
  }

  /** 计算音量级别(0~100),逐行对齐 Kotlin calculateAudioLevel */
  private calculateAudioLevel(buf: ArrayBuffer, size: number): number {
    const view = new DataView(buf);
    let sum = 0;
    let i = 0;
    while (i + 1 < size) {
      // 小端 16bit 有符号样本,等价 (buffer[i+1].toInt() shl 8) or (buffer[i] and 0xFF)
      const sample = view.getInt16(i, true);
      sum += sample * sample;
      i += 2;
    }
    const samples = Math.max(1, Math.floor(size / 2));
    const rms = Math.sqrt(sum / samples);
    const db = 20.0 * Math.log10(Math.max(rms / 32768.0, 1e-7));
    const normalized = Math.min(1.0, Math.max(0.0, (db + 55.0) / 55.0));
    return Math.sqrt(normalized) * 100.0;
  }

  /** 采集参数:16kHz / 单声道 / S16LE / MIC(与安卓 AudioRecord 参数一致) */
  private static capturerOptions(): audio.AudioCapturerOptions {
    const streamInfo: audio.AudioStreamInfo = {
      samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
      channels: audio.AudioChannel.CHANNEL_1,
      sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
      encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
    };
    const capturerInfo: audio.AudioCapturerInfo = {
      source: audio.SourceType.SOURCE_TYPE_MIC,
      capturerFlags: 0
    };
    const options: audio.AudioCapturerOptions = {
      streamInfo: streamInfo,
      capturerInfo: capturerInfo
    };
    return options;
  }

  // ===== StateFlow 语义的去重派发 =====

  private setStreaming(v: boolean): void {
    if (this._isStreaming === v) {
      return;
    }
    this._isStreaming = v;
    const cb = this.onStreamingChanged;
    if (cb !== null) {
      cb(v);
    }
  }

  private setAudioLevel(v: number): void {
    if (this._audioLevel === v) {
      return;
    }
    this._audioLevel = v;
    const cb = this.onAudioLevelChanged;
    if (cb !== null) {
      cb(v);
    }
  }

  private setRemaining(v: number): void {
    if (this._remainingSeconds === v) {
      return;
    }
    this._remainingSeconds = v;
    const cb = this.onRemainingSecondsChanged;
    if (cb !== null) {
      cb(v);
    }
  }
}
