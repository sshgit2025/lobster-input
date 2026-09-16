import { audio } from '@kit.AudioKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { ApiConfig } from '../network/ApiConfig';
import { Logger } from '../log/Logger';

const TAG: string = 'AudioRecorder';

/**
 * 一次性录音器(移植自 core/audio/AudioRecorder.kt)。
 *
 * Android 版基于 AudioRecord 阻塞 read() 循环;HarmonyOS 版基于 AudioCapturer 的
 * 'readData' 帧回调(系统按固定帧长回推 PCM 数据,无需自建采集线程)。
 * 采集参数与安卓一致:16kHz / 单声道 / 16bit PCM(SAMPLE_S16LE)/ SOURCE_TYPE_MIC。
 *
 * StateFlow 替代方案:isRecording / audioLevel / remainingSeconds 暴露为只读属性,
 * 并提供对应的可空回调字段(仅在值变化时触发,语义对齐 StateFlow 的去重派发)。
 *
 * 帧回调必须保持轻量(历史教训:安卓曾因每帧做重量级同步操作导致 ANR):
 * 这里每帧只做「拷贝缓冲 + RMS 电平计算」,WAV 写盘集中在停止时一次完成。
 */
export class AudioRecorder {
  private context: common.Context;
  private capturer: audio.AudioCapturer | null = null;
  /** 输出 WAV 文件的沙箱路径(等价安卓 outputFile: File) */
  private outputFile: string | null = null;
  /** 采集到的 PCM 帧(等价安卓 recordAudio 内的 audioData) */
  private audioData: ArrayBuffer[] = [];
  private startTimeMs: number = 0;
  /**
   * 会话代号:每次 停止/清理 递增,使「异步创建/启动 capturer 期间被叫停」以及
   * 晚到的 readData 回调全部失效。等价于安卓「协程独占 record 生命周期」的防重叠语义
   * (ArkTS 单线程事件循环,不存在跨线程 release 与 read 重叠的问题,但异步启动窗口仍需防护)。
   */
  private session: number = 0;

  private _isRecording: boolean = false;
  private _audioLevel: number = 0;
  private _remainingSeconds: number = ApiConfig.DEFAULT_MAX_DURATION_SEC;
  private _maxDurationSec: number = ApiConfig.DEFAULT_MAX_DURATION_SEC;

  /** StateFlow 替代:值变化时回调(可空) */
  onRecordingChanged: ((recording: boolean) => void) | null = null;
  onAudioLevelChanged: ((level: number) => void) | null = null;
  onRemainingSecondsChanged: ((seconds: number) => void) | null = null;
  /** 达到最大录音时长时回调(参数为已写好的 WAV 文件路径),等价安卓 onMaxDurationReached */
  onMaxDurationReached: ((filePath: string) => void) | null = null;

  /** WAV 头使用的采样率,与 AudioCapturer 的 SAMPLE_RATE_16000 严格一致 */
  private readonly sampleRate: number = ApiConfig.AUDIO_SAMPLE_RATE;

  constructor(context: common.Context) {
    this.context = context;
  }

  get isRecording(): boolean {
    return this._isRecording;
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
    // 对齐 Kotlin setter:coerceAtLeast(1);未在录音时同步刷新剩余秒数
    this._maxDurationSec = Math.max(1, value);
    if (!this._isRecording) {
      this.setRemaining(this._maxDurationSec);
    }
  }

  /**
   * 开始录音。成功返回输出 WAV 文件路径,失败或已在录音中返回 null。
   * (安卓为同步方法;鸿蒙 createAudioCapturer/start 均为异步,故返回 Promise,
   *  调用方 await 后拿到路径的语义与安卓拿到 File 一致。)
   */
  async startRecording(): Promise<string | null> {
    if (this._isRecording) {
      return null;
    }

    const mySession = ++this.session;
    try {
      // 创建临时文件(应用沙箱 cache 目录,对齐安卓 context.cacheDir)
      const filePath = this.createTempWavFile();
      this.outputFile = filePath;

      // 初始化 AudioCapturer(等价安卓初始化 AudioRecord)
      const capturer = await audio.createAudioCapturer(AudioRecorder.capturerOptions());
      if (mySession !== this.session) {
        // 异步创建期间已被叫停/清理:直接释放,不进入录音状态
        AudioRecorder.releaseAsync(capturer);
        return null;
      }
      this.capturer = capturer;
      this.audioData = [];

      // 帧回调:仅做「时长检查 + 缓冲拷贝 + 电平计算」,严禁重量级同步操作
      capturer.on('readData', (buf: ArrayBuffer) => this.onFrame(mySession, buf));

      await capturer.start();
      if (mySession !== this.session) {
        this.releaseCapturer();
        return null;
      }

      this.startTimeMs = Date.now();
      this.setRecording(true);
      this.setRemaining(this._maxDurationSec);
      return filePath;
    } catch (e) {
      Logger.e(TAG, `startRecording failed: ${e}`);
      this.cleanup();
      return null;
    }
  }

  /**
   * 停止录音,返回 WAV 文件路径;未在录音中返回 null。
   * 与安卓差异:安卓在采集协程 finally 中异步写 WAV;鸿蒙无独立采集线程,
   * PCM 帧全程驻留内存,这里在停止时同步写盘后再返回,调用方拿到路径即文件完整可用
   * (消除了安卓「返回 File 与写盘完成之间」的竞态,行为只强不弱)。
   */
  stopRecording(): string | null {
    if (!this._isRecording) {
      return null;
    }
    return this.finishInternal();
  }

  /** 帧回调(等价安卓 recordAudio 循环体) */
  private onFrame(session: number, buf: ArrayBuffer): void {
    if (session !== this.session || !this._isRecording) {
      return;
    }

    // 检查是否超过最大时长
    const elapsed = Math.floor((Date.now() - this.startTimeMs) / 1000);
    this.setRemaining(Math.max(0, this._maxDurationSec - elapsed));
    if (elapsed >= this._maxDurationSec) {
      // 达到上限:收尾(写 WAV → 释放)后在此帧内通知调用方,对齐安卓 reachedMaxDuration 分支
      const file = this.finishInternal();
      if (file !== null) {
        const cb = this.onMaxDurationReached;
        if (cb !== null) {
          cb(file);
        }
      }
      return;
    }

    if (buf.byteLength > 0) {
      // 保存音频数据(系统可能复用回调缓冲区,必须拷贝)
      this.audioData.push(buf.slice(0));
      // 计算音量级别
      this.setAudioLevel(this.calculateAudioLevel(buf, buf.byteLength));
    }
  }

  /** 统一收尾:停止状态 → 释放采集器 → 写 WAV → 复位(等价安卓 stopRecording + 协程 finally) */
  private finishInternal(): string | null {
    this.session++;
    this.setRecording(false);
    this.releaseCapturer();

    const file = this.outputFile;
    this.outputFile = null;

    if (file !== null) {
      // 写入 WAV 文件(等价安卓 runCatching { writeWavFile(...) })
      try {
        this.writeWavFile(file, this.audioData);
      } catch (e) {
        Logger.e(TAG, `writeWavFile failed: ${e}`);
      }
    }

    this.audioData = [];
    this.setAudioLevel(0);
    this.setRemaining(this._maxDurationSec);
    return file;
  }

  /** 幂等释放当前 AudioCapturer(stop/release 异常全部吞掉,对齐安卓 releaseRecord) */
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
    AudioRecorder.releaseAsync(c);
  }

  /** 异步 stop + release,异常吞掉(fire-and-forget) */
  private static async releaseAsync(c: audio.AudioCapturer): Promise<void> {
    try {
      await c.stop();
    } catch (e) {
      // 未处于运行态时 stop 会报错,忽略
    }
    try {
      await c.release();
    } catch (e) {
      // 重复释放等错误,忽略
    }
  }

  /** 计算音量级别(0~100),逐行对齐 Kotlin calculateAudioLevel */
  private calculateAudioLevel(buf: ArrayBuffer, size: number): number {
    const view = new DataView(buf);
    let sum = 0;
    for (let i = 0; i + 1 < size; i += 2) {
      // 小端 16bit 有符号样本,等价 (buffer[i+1].toInt() shl 8) or (buffer[i] and 0xFF)
      const sample = view.getInt16(i, true);
      sum += sample * sample;
    }
    const rms = Math.sqrt(sum / Math.max(1, Math.floor(size / 2)));
    const db = 20.0 * Math.log10(Math.max(rms / 32768.0, 1e-7));
    const normalized = Math.min(1.0, Math.max(0.0, (db + 55.0) / 55.0));
    const sensitive = Math.min(1.0, Math.max(0.0, Math.sqrt(normalized)));
    return sensitive * 100.0;
  }

  /** 在沙箱 cache 目录创建临时 WAV 文件(等价 File.createTempFile("audio_", ".wav", cacheDir)) */
  private createTempWavFile(): string {
    const rand = Math.floor(Math.random() * 0xFFFFFF).toString(16);
    const path = `${this.context.cacheDir}/audio_${Date.now()}_${rand}.wav`;
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
    fs.closeSync(file);
    return path;
  }

  /** 写出完整 WAV 文件(44 字节头 + PCM 数据),逐行对齐 Kotlin writeWavFile */
  private writeWavFile(filePath: string, audioData: ArrayBuffer[]): void {
    let totalAudioLen = 0;
    for (let i = 0; i < audioData.length; i++) {
      totalAudioLen += audioData[i].byteLength;
    }
    const totalDataLen = totalAudioLen + 36;
    const channels = 1;
    const byteRate = this.sampleRate * channels * 2;

    const file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      // WAV 文件头
      fs.writeSync(file.fd, this.getWavHeader(totalAudioLen, totalDataLen, this.sampleRate, channels, byteRate));
      // 音频数据
      for (let i = 0; i < audioData.length; i++) {
        fs.writeSync(file.fd, audioData[i]);
      }
    } finally {
      fs.closeSync(file);
    }
  }

  /** 手写 44 字节 WAV 头,字段与 Kotlin getWavHeader 完全一致 */
  private getWavHeader(totalAudioLen: number, totalDataLen: number, sampleRate: number,
    channels: number, byteRate: number): ArrayBuffer {
    const buf = new ArrayBuffer(44);
    const header = new Uint8Array(buf);

    // RIFF chunk
    header[0] = 'R'.charCodeAt(0);
    header[1] = 'I'.charCodeAt(0);
    header[2] = 'F'.charCodeAt(0);
    header[3] = 'F'.charCodeAt(0);

    // File size
    this.writeInt(header, 4, totalDataLen);

    // WAVE
    header[8] = 'W'.charCodeAt(0);
    header[9] = 'A'.charCodeAt(0);
    header[10] = 'V'.charCodeAt(0);
    header[11] = 'E'.charCodeAt(0);

    // fmt chunk
    header[12] = 'f'.charCodeAt(0);
    header[13] = 'm'.charCodeAt(0);
    header[14] = 't'.charCodeAt(0);
    header[15] = ' '.charCodeAt(0);

    // fmt chunk size (16 for PCM)
    this.writeInt(header, 16, 16);

    // Audio format (1 = PCM)
    this.writeShort(header, 20, 1);

    // Number of channels
    this.writeShort(header, 22, channels);

    // Sample rate
    this.writeInt(header, 24, sampleRate);

    // Byte rate
    this.writeInt(header, 28, byteRate);

    // Block align
    this.writeShort(header, 32, channels * 2);

    // Bits per sample
    this.writeShort(header, 34, 16);

    // data chunk
    header[36] = 'd'.charCodeAt(0);
    header[37] = 'a'.charCodeAt(0);
    header[38] = 't'.charCodeAt(0);
    header[39] = 'a'.charCodeAt(0);

    // Data size
    this.writeInt(header, 40, totalAudioLen);

    return buf;
  }

  /** 小端写 32 位整数(对齐 Kotlin writeInt) */
  private writeInt(header: Uint8Array, offset: number, value: number): void {
    header[offset] = value & 0xff;
    header[offset + 1] = (value >> 8) & 0xff;
    header[offset + 2] = (value >> 16) & 0xff;
    header[offset + 3] = (value >> 24) & 0xff;
  }

  /** 小端写 16 位整数(对齐 Kotlin writeShort) */
  private writeShort(header: Uint8Array, offset: number, value: number): void {
    header[offset] = value & 0xff;
    header[offset + 1] = (value >> 8) & 0xff;
  }

  /** 启动失败时的清理(等价 Kotlin cleanup:释放残留实例并删除临时文件) */
  private cleanup(): void {
    this.session++;
    this.setRecording(false);
    this.releaseCapturer();
    if (this.outputFile !== null) {
      try {
        fs.unlinkSync(this.outputFile);
      } catch (e) {
        Logger.w(TAG, `delete temp file failed: ${e}`);
      }
      this.outputFile = null;
    }
    this.audioData = [];
    this.setAudioLevel(0);
    this.setRemaining(this._maxDurationSec);
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

  private setRecording(v: boolean): void {
    if (this._isRecording === v) {
      return;
    }
    this._isRecording = v;
    const cb = this.onRecordingChanged;
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
