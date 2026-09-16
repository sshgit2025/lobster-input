package com.lobster.input.core.audio

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.core.content.ContextCompat
import com.lobster.input.core.network.ApiConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlin.math.log10
import kotlin.math.sqrt

class RealtimeAudioStreamer(private val context: Context) {
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var audioRecord: AudioRecord? = null
    private var streamingJob: Job? = null
    private var startedAtMs: Long = 0L

    private val _isStreaming = MutableStateFlow(false)
    val isStreaming: StateFlow<Boolean> = _isStreaming

    private val _audioLevel = MutableStateFlow(0f)
    val audioLevel: StateFlow<Float> = _audioLevel

    private val _remainingSeconds = MutableStateFlow(ApiConfig.DEFAULT_MAX_DURATION_SEC)
    val remainingSeconds: StateFlow<Int> = _remainingSeconds

    var maxDurationSec: Int = ApiConfig.DEFAULT_MAX_DURATION_SEC
        set(value) {
            field = value.coerceAtLeast(1)
            if (!_isStreaming.value) {
                _remainingSeconds.value = field
            }
        }

    private val sampleRate = ApiConfig.AUDIO_SAMPLE_RATE
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    private val minBufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
    private val bufferSize = maxOf(minBufferSize, 2048)

    fun start(onChunk: (ByteArray) -> Unit, onMaxDuration: () -> Unit): Boolean {
        if (_isStreaming.value) return false
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return false
        }
        return try {
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                channelConfig,
                audioFormat,
                bufferSize
            )
            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                cleanup()
                return false
            }
            audioRecord?.startRecording()
            startedAtMs = System.currentTimeMillis()
            _isStreaming.value = true
            _remainingSeconds.value = maxDurationSec
            streamingJob = scope.launch {
                streamAudio(onChunk, onMaxDuration)
            }
            true
        } catch (_: Exception) {
            cleanup()
            false
        }
    }

    fun stop() {
        // 隐患1 修复:避免在采集协程的 read() 阻塞过程中,从另一个线程 release AudioRecord
        // (native 未定义行为,可能导致麦克风损坏/崩溃)。
        // 做法:有采集协程在跑时,只翻转标志并取消协程,真正的释放交给 streamAudio 的 finally
        //(它一定在 read() 返回之后、同一线程上执行);没有协程时(如启动失败)才直接释放。
        val hadJob = streamingJob != null
        _isStreaming.value = false
        streamingJob?.cancel()
        streamingJob = null
        if (!hadJob) {
            releaseAudioRecord()
        }
        _audioLevel.value = 0f
        _remainingSeconds.value = maxDurationSec
    }

    fun release() {
        stop()
        scope.cancel()
    }

    private suspend fun streamAudio(onChunk: (ByteArray) -> Unit, onMaxDuration: () -> Unit) {
        val buffer = ByteArray(bufferSize)
        var maxSent = false
        try {
            while (_isStreaming.value) {
                val elapsed = ((System.currentTimeMillis() - startedAtMs) / 1000).toInt()
                _remainingSeconds.value = (maxDurationSec - elapsed).coerceAtLeast(0)
                if (elapsed >= maxDurationSec) {
                    if (!maxSent) {
                        maxSent = true
                        onMaxDuration()
                    }
                    break
                }
                val readSize = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                if (readSize > 0) {
                    _audioLevel.value = calculateAudioLevel(buffer, readSize)
                    onChunk(buffer.copyOf(readSize))
                } else {
                    delay(10)
                }
            }
        } finally {
            _isStreaming.value = false
            releaseAudioRecord()
            _audioLevel.value = 0f
            _remainingSeconds.value = maxDurationSec
        }
    }

    @Synchronized
    private fun releaseAudioRecord() {
        // 先置空,保证从多处(stop / cleanup / streamAudio 的 finally)调用时幂等,只真正释放一次。
        val record = audioRecord ?: return
        audioRecord = null
        try {
            record.stop()
        } catch (_: Exception) {
        }
        try {
            record.release()
        } catch (_: Exception) {
        }
    }

    private fun cleanup() {
        _isStreaming.value = false
        streamingJob?.cancel()
        streamingJob = null
        releaseAudioRecord()
        _audioLevel.value = 0f
        _remainingSeconds.value = maxDurationSec
    }

    private fun calculateAudioLevel(buffer: ByteArray, size: Int): Float {
        var sum = 0L
        var i = 0
        while (i + 1 < size) {
            val sample = (buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xFF)
            sum += sample * sample
            i += 2
        }
        val samples = (size / 2).coerceAtLeast(1)
        val rms = sqrt(sum.toDouble() / samples)
        val db = 20.0 * log10((rms / 32768.0).coerceAtLeast(1e-7))
        val normalized = ((db + 55.0) / 55.0).coerceIn(0.0, 1.0)
        return (sqrt(normalized) * 100.0).toFloat()
    }
}
