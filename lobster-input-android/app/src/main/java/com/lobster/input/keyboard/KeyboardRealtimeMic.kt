package com.lobster.input.keyboard

import android.os.Handler
import android.os.Looper
import android.view.inputmethod.InputConnection
import com.lobster.input.core.audio.RealtimeAudioStreamer
import com.lobster.input.core.network.RealtimeAsrErrorKind
import com.lobster.input.core.network.RealtimeAsrWebSocketClient
import com.lobster.input.core.network.RealtimeResume
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.ArrayDeque

/**
 * 键盘模式内的流式实时麦克风会话(独立模块,与语音模式数据隔离)。
 *
 * 强制实时流式(不受设置页 SYNC/REALTIME 开关影响):识别文本直接以 composing 预览并上屏,
 * 不写语音历史、不参与指令二次加工。复用 [RealtimeAudioStreamer] 与 [RealtimeAsrWebSocketClient],
 * 但维护独立的会话状态与音频缓冲,绝不触碰语音模式字段。
 */
class KeyboardRealtimeMic(
    private val streamer: RealtimeAudioStreamer,
    private val scope: CoroutineScope,
    private val callbacks: Callbacks
) {
    interface Callbacks {
        fun language(): String
        fun inputConnection(): InputConnection?
        fun onActiveChanged(active: Boolean)
        fun onError(kind: RealtimeAsrErrorKind, message: String)
    }

    private val uiHandler = Handler(Looper.getMainLooper())
    private val buffer = ArrayDeque<ByteArray>()
    // WS 未就绪时的待发音频累计字节数,配合 MAX_BUFFER_BYTES 上限防止异常场景无限膨胀
    private var bufferedBytes = 0
    private var client: RealtimeAsrWebSocketClient? = null
    private var ready = false
    private var finishing = false
    private var previewLen = 0
    @Volatile private var finalReceived = false
    // 断连续传:登录凭证(重连新会话用)/已并入前缀/当前完整目标文本/已发送音频尾巴/重连次数
    private var sessionAuthHeader: String? = null
    private var transcriptPrefix = ""
    private var lastTargetText = ""
    private val sentTail = ArrayDeque<ByteArray>()
    private var sentTailBytes = 0
    private var reconnectAttempts = 0
    private var connectJobActive = false
    // 实时识别打字机平滑层:把突发 partial 平滑成逐字揭示,只影响 composing 预览。
    private val typewriter = TypewriterReveal(uiHandler) { shown -> renderComposing(shown) }

    var isActive = false
        private set

    /** 开始(authHeader 由调用方在校验登录/权限后传入)。 */
    fun start(authHeader: String) {
        if (isActive) return
        isActive = true; finishing = false; ready = false; previewLen = 0; finalReceived = false
        typewriter.reset()
        buffer.clear(); bufferedBytes = 0
        sessionAuthHeader = authHeader
        transcriptPrefix = ""; lastTargetText = ""
        sentTail.clear(); sentTailBytes = 0
        reconnectAttempts = 0
        callbacks.onActiveChanged(true)

        val c = createClient(authHeader)
        client = c

        // 键盘麦克风固定 60s 上限(后端最长处理 60s 音频;倒计时环随之从 60s 递减)
        streamer.maxDurationSec = KEYBOARD_MAX_SEC
        val started = streamer.start(
            onChunk = { bytes -> onChunk(bytes) },
            onMaxDuration = { uiHandler.post { stop() } }
        )
        if (!started) {
            isActive = false; callbacks.onActiveChanged(false)
            c.close(); client = null
            callbacks.onError(RealtimeAsrErrorKind.SERVER, "")
            return
        }
        launchConnect(c)
    }

    private fun createClient(authHeader: String): RealtimeAsrWebSocketClient = RealtimeAsrWebSocketClient(
        authHeader = authHeader,
        language = callbacks.language(),
        // 断连续传后新会话文本与前缀做重叠裁剪拼接
        onPartial = { text, _ -> uiHandler.post { if (isActive && !finishing) preview(text) } },
        // onCompleted 是 ASR 权威最终结果:即便已进入 finishing 也要采纳,作为收尾定格的目标。
        onCompleted = { text, _ ->
            uiHandler.post {
                if (isActive || finishing) {
                    typewriter.setTarget(mergeTarget(text))
                    finalReceived = true
                }
            }
        },
        onError = { kind, msg ->
            uiHandler.post {
                if (!isActive) return@post
                // 链路层断连优先静默重连续传;不可重连才报错收尾
                if (kind == RealtimeAsrErrorKind.NETWORK && !finishing &&
                    reconnectAttempts < RealtimeResume.MAX_RECONNECT_ATTEMPTS
                ) {
                    beginReconnect()
                } else {
                    callbacks.onError(kind, msg)
                    stop()
                }
            }
        }
    )

    private fun launchConnect(c: RealtimeAsrWebSocketClient) {
        connectJobActive = true
        scope.launch {
            try {
                c.connect()
                if (client === c && isActive) {
                    ready = true
                    flush()
                }
            } catch (e: Exception) {
                if (client === c && isActive && !finishing) {
                    if (RealtimeAsrWebSocketClient.isNetworkError(e) &&
                        reconnectAttempts < RealtimeResume.MAX_RECONNECT_ATTEMPTS
                    ) {
                        beginReconnect()
                    } else {
                        val kind = if (RealtimeAsrWebSocketClient.isNetworkError(e)) {
                            RealtimeAsrErrorKind.NETWORK
                        } else {
                            RealtimeAsrErrorKind.SERVER
                        }
                        callbacks.onError(kind, e.message ?: "")
                        stop()
                    }
                }
            } finally {
                if (client === c) connectJobActive = false
            }
        }
    }

    /**
     * 弱网断连的静默重连续传:冻结当前目标文本为前缀,已发送音频尾巴回灌到待发队列头部,
     * 新建会话续流;RECONNECT_WINDOW_MS 内未就绪则按错误收尾(已上屏文本仍会被 stop 定格提交)。
     */
    private fun beginReconnect() {
        val auth = sessionAuthHeader
        val old = client
        if (auth == null || old == null || !isActive || finishing) {
            callbacks.onError(RealtimeAsrErrorKind.NETWORK, "")
            stop()
            return
        }
        reconnectAttempts++
        transcriptPrefix = lastTargetText
        ready = false
        old.close()
        while (sentTail.isNotEmpty()) {
            val chunk = sentTail.removeLast()
            buffer.addFirst(chunk)
            bufferedBytes += chunk.size
        }
        sentTailBytes = 0
        val c = createClient(auth)
        client = c
        launchConnect(c)
        uiHandler.postDelayed({
            if (client === c && !ready && isActive && !finishing) {
                callbacks.onError(RealtimeAsrErrorKind.NETWORK, "")
                stop()
            }
        }, RealtimeResume.RECONNECT_WINDOW_MS)
    }

    /** 前缀 + 当前会话文本的重叠合并,并记录为当前完整目标。 */
    private fun mergeTarget(text: String): String {
        val merged = RealtimeResume.mergeWithOverlap(transcriptPrefix, text.trim())
        lastTargetText = merged
        return merged
    }

    fun stop() {
        if (!isActive || finishing) return
        finishing = true
        // 立即把预览补齐到最新完整目标:停止后 onPartial/onCompleted 已被 finishing 门控屏蔽,
        // 必须保证随后 finishComposingText 锁定的是完整文本,而不是揭示到一半的残缺串。
        typewriter.flush()
        streamer.stop()
        isActive = false
        callbacks.onActiveChanged(false)

        val c = client
        if (c == null) { finishing = false; return }
        scope.launch {
            try {
                // 重连协程在途时不重复 connect(同一 client 双重 connect 会泄漏旧 ws)
                if (!ready && !connectJobActive) { runCatching { c.connect(); ready = true } }
                flush()
                c.requestFinish()
                // 完成/超时竞速:onCompleted(权威最终结果)先到则立即定格,否则最多等 1.5s 兜底,
                // 避免固定盲等导致尾部更正丢失或无谓延迟。
                var waited = 0
                while (!finalReceived && waited < FINISH_TIMEOUT_MS) { delay(FINISH_POLL_MS); waited += FINISH_POLL_MS.toInt() }
                typewriter.flush()
                callbacks.inputConnection()?.finishComposingText()
            } finally {
                c.close(); client = null; ready = false; previewLen = 0; finalReceived = false
                typewriter.reset()
                buffer.clear(); bufferedBytes = 0; finishing = false
                transcriptPrefix = ""; lastTargetText = ""
                sentTail.clear(); sentTailBytes = 0
                reconnectAttempts = 0; sessionAuthHeader = null
            }
        }
    }

    private companion object {
        const val FINISH_TIMEOUT_MS = 1500L
        const val FINISH_POLL_MS = 40L
        const val KEYBOARD_MAX_SEC = 60
        // 待发音频缓冲上限 2.5MB(与语音模式 REALTIME_AUDIO_BUFFER_LIMIT_BYTES 对齐):
        // WS 长时间未就绪等异常场景下超限则丢最旧,防止内存无限膨胀。
        const val MAX_BUFFER_BYTES = 2_500_000
    }

    private fun onChunk(bytes: ByteArray) {
        val c = client ?: return
        if (ready) {
            flush()
            if (c.sendAudio(bytes)) recordSentTail(bytes) else enqueue(bytes)
        } else {
            enqueue(bytes)
        }
    }

    /** 记录最近已发送音频尾巴(环形,上限 1.5s),供断连重连时回灌补齐接缝。 */
    private fun recordSentTail(bytes: ByteArray) {
        sentTail.addLast(bytes)
        sentTailBytes += bytes.size
        while (sentTailBytes > RealtimeResume.SENT_TAIL_LIMIT_BYTES && sentTail.isNotEmpty()) {
            sentTailBytes -= sentTail.removeFirst().size
        }
    }

    /** 入队待发音频并施加 2.5MB 上限:超限先丢最旧,单块超限直接丢弃。 */
    private fun enqueue(bytes: ByteArray) {
        while (bufferedBytes + bytes.size > MAX_BUFFER_BYTES && buffer.isNotEmpty()) {
            bufferedBytes -= buffer.removeFirst().size
        }
        if (bytes.size <= MAX_BUFFER_BYTES) {
            buffer.addLast(bytes); bufferedBytes += bytes.size
        }
    }

    private fun flush() {
        val c = client ?: return
        if (!ready) return
        while (buffer.isNotEmpty()) {
            if (!c.sendAudio(buffer.first())) break
            val chunk = buffer.removeFirst()
            bufferedBytes -= chunk.size
            recordSentTail(chunk)
        }
    }

    private fun preview(text: String) {
        // 喂给打字机平滑层(与前缀重叠合并);实际逐字渲染走 renderComposing。
        typewriter.setTarget(mergeTarget(text))
    }

    private fun renderComposing(shown: String) {
        val ic = callbacks.inputConnection() ?: return
        ic.setComposingText(shown, 1)
        previewLen = shown.length
    }
}
