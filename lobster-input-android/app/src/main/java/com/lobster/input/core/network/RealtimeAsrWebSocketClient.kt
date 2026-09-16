package com.lobster.input.core.network

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import java.io.IOException
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.TimeUnit

data class RealtimeAsrFinal(
    val text: String,
    val language: String,
    val creditsRemaining: Int?
)

/**
 * 实时识别错误分类:NETWORK 为链路层错误(弱网断链等,原始文案是 OS 级英文
 * 如 "Software caused connection abort",不可直接展示给用户);SERVER 为服务端
 * 业务错误(message 来自后端下发)。
 */
enum class RealtimeAsrErrorKind { NETWORK, SERVER }

class RealtimeAsrWebSocketClient(
    private val authHeader: String,
    private val language: String,
    private val onPartial: (String, String) -> Unit,
    private val onCompleted: (String, String) -> Unit,
    private val onError: (RealtimeAsrErrorKind, String) -> Unit
) {
    companion object {
        /** 判断异常链上是否为网络链路层错误(IOException 家族,含 Socket/SSL/DNS)。 */
        fun isNetworkError(t: Throwable?): Boolean {
            var cur = t
            while (cur != null) {
                if (cur is IOException) return true
                cur = cur.cause
            }
            return false
        }
    }

    val asrSessionId: String = "android_${UUID.randomUUID().toString().lowercase()}"
    @Volatile
    private var readyState = false
    @Volatile
    private var closing = false
    @Volatile
    private var finishRequested = false
    @Volatile
    private var finalReceived = false

    val isReady: Boolean
        get() = readyState

    private val sendLock = Any()

    private val client = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.SECONDS)
        .build()

    private var webSocket: WebSocket? = null
    private var ready = CompletableDeferred<Unit>()
    private var finalResult = CompletableDeferred<RealtimeAsrFinal>()

    suspend fun connect() {
        readyState = false
        closing = false
        finishRequested = false
        finalReceived = false
        ready = CompletableDeferred()
        finalResult = CompletableDeferred()
        val request = Request.Builder()
            .url(buildUrl())
            .header("Authorization", authHeader)
            .header("X-Client-Platform", ApiConfig.CLIENT_PLATFORM)
            .header("Accept-Language", language)
            .header("X-Accept-Language", language)
            .build()
        webSocket = client.newWebSocket(request, listener())
        withTimeout(30_000) { ready.await() }
        readyState = true
    }

    fun sendAudio(bytes: ByteArray): Boolean {
        val socket = webSocket ?: return false
        if (!readyState || finishRequested || closing || finalReceived) return false
        return synchronized(sendLock) {
            if (!readyState || finishRequested || closing || finalReceived) {
                false
            } else {
                socket.send(bytes.toByteString())
            }
        }
    }

    suspend fun finish(): RealtimeAsrFinal {
        if (!requestFinish()) {
            throw IllegalStateException("Realtime ASR is not connected")
        }
        return withTimeout(90_000) { finalResult.await() }
    }

    fun requestFinish(): Boolean {
        val socket = webSocket ?: return false
        if (!readyState || closing || finalReceived) return false
        return synchronized(sendLock) {
            if (!readyState || closing || finalReceived) {
                false
            } else {
                finishRequested = true
                socket.send("""{"type":"finish"}""")
            }
        }
    }

    fun close() {
        closing = true
        readyState = false
        webSocket?.close(1000, "client closed")
        webSocket = null
        if (!ready.isCompleted) ready.completeExceptionally(IllegalStateException("closed"))
        if (!finalResult.isCompleted) finalResult.completeExceptionally(IllegalStateException("closed"))
        // 会话结束显式释放本 client 独有的连接池与线程池:高频实时会话下避免空闲线程/连接
        // 滞留累积(dispatcher 线程默认空闲 60s 才回收)。仅在会话已结束时执行,close(1000)
        // 已排队的关闭帧由 shutdown(非 shutdownNow)保证发送完,绝不影响进行中的低延迟识别。
        runCatching {
            client.dispatcher.executorService.shutdown()
            client.connectionPool.evictAll()
        }
    }

    private fun listener(): WebSocketListener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            handleMessage(text)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            if (closing || finalReceived) {
                readyState = false
                return
            }
            val message = t.message ?: "Realtime ASR failed"
            readyState = false
            if (!ready.isCompleted) ready.completeExceptionally(t)
            if (!finalResult.isCompleted) finalResult.completeExceptionally(t)
            // 弱网断链等 IOException 的 t.message 是 OS 级英文文案,交由 UI 层换成本地化提示
            val kind = if (isNetworkError(t)) RealtimeAsrErrorKind.NETWORK else RealtimeAsrErrorKind.SERVER
            onError(kind, message)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            readyState = false
            if (!closing && !finalReceived) {
                val message = reason.ifBlank { "Realtime ASR websocket closed" }
                if (!ready.isCompleted) ready.completeExceptionally(IllegalStateException(message))
                if (!finalResult.isCompleted) finalResult.completeExceptionally(IllegalStateException(message))
                // 未收到 finished 前连接被对端关闭,同样按链路层异常处理
                onError(RealtimeAsrErrorKind.NETWORK, message)
            }
        }
    }

    private fun handleMessage(text: String) {
        val json = runCatching { JsonParser().parse(text).asJsonObject }.getOrNull() ?: return
        when (json.string("type")) {
            "ready" -> if (!ready.isCompleted) ready.complete(Unit)
            "partial" -> onPartial(json.string("text"), json.string("language"))
            "completed" -> onCompleted(json.string("text").ifBlank { json.string("transcript") }, json.string("language"))
            "finished" -> {
                finalReceived = true
                readyState = false
                val final = RealtimeAsrFinal(
                    text = json.string("text").ifBlank { json.string("transcript") },
                    language = json.string("language"),
                    creditsRemaining = json.intOrNull("credits_remaining")
                )
                if (!finalResult.isCompleted) finalResult.complete(final)
            }
            "error" -> {
                val message = json.string("message").ifBlank { "Realtime ASR error" }
                if (!ready.isCompleted) ready.completeExceptionally(IllegalStateException(message))
                if (!finalResult.isCompleted) finalResult.completeExceptionally(IllegalStateException(message))
                onError(RealtimeAsrErrorKind.SERVER, message)
            }
        }
    }

    private fun buildUrl(): String {
        val base = ApiConfig.BASE_URL.trimEnd('/')
            .replaceFirst("https://", "wss://")
            .replaceFirst("http://", "ws://")
        val encodedLang = URLEncoder.encode(language, "UTF-8")
        val encodedSessionId = URLEncoder.encode(asrSessionId, "UTF-8")
        return "$base/${ApiConfig.AudioV2.REALTIME_ASR}?language=$encodedLang&sample_rate=16000&audio_format=pcm&vad=true&max_duration_sec=60&asr_session_id=$encodedSessionId"
    }

    private fun JsonObject.string(name: String): String =
        if (has(name) && !get(name).isJsonNull) get(name).asString.orEmpty() else ""

    private fun JsonObject.intOrNull(name: String): Int? =
        if (has(name) && !get(name).isJsonNull) runCatching { get(name).asInt }.getOrNull() else null
}
