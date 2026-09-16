package com.lobster.input.core.audio

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import com.lobster.input.core.network.ApiConfig
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class AudioRecorder(private val context: Context) {
    
    private var audioRecord: AudioRecord? = null
    private var recordingJob: Job? = null
    private var outputFile: File? = null
    
    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording
    
    private val _audioLevel = MutableStateFlow(0f)
    val audioLevel: StateFlow<Float> = _audioLevel

    private val _remainingSeconds = MutableStateFlow(ApiConfig.DEFAULT_MAX_DURATION_SEC)
    val remainingSeconds: StateFlow<Int> = _remainingSeconds
    
    var maxDurationSec: Int = ApiConfig.DEFAULT_MAX_DURATION_SEC
        set(value) {
            field = value.coerceAtLeast(1)
            if (!_isRecording.value) {
                _remainingSeconds.value = field
            }
        }

    var onMaxDurationReached: ((File) -> Unit)? = null
    
    private val sampleRate = ApiConfig.AUDIO_SAMPLE_RATE
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    
    private val bufferSize = AudioRecord.getMinBufferSize(
        sampleRate,
        channelConfig,
        audioFormat
    )
    
    fun startRecording(): File? {
        if (_isRecording.value) return null

        try {
            // 创建临时文件
            val file = File.createTempFile("audio_", ".wav", context.cacheDir)
            outputFile = file

            // 初始化AudioRecord
            val record = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                channelConfig,
                audioFormat,
                bufferSize
            )

            if (record.state != AudioRecord.STATE_INITIALIZED) {
                try { record.release() } catch (_: Exception) {}
                throw IllegalStateException("AudioRecord initialization failed")
            }

            audioRecord = record
            record.startRecording()
            _isRecording.value = true
            _remainingSeconds.value = maxDurationSec

            // 开始录音协程:把 record/file 作为参数交给协程独占,生命周期由协程负责,
            // 避免从其它线程访问/释放正在被 read() 使用的 AudioRecord。
            recordingJob = CoroutineScope(Dispatchers.IO).launch {
                recordAudio(record, file)
            }

            return file
        } catch (e: Exception) {
            e.printStackTrace()
            cleanup()
            return null
        }
    }

    fun stopRecording(): File? {
        if (!_isRecording.value) return null

        // 翻转标志通知采集协程退出循环。AudioRecord.stop() 跨线程调用是安全的(标准用法,
        // 用于立刻解除 read() 阻塞);但 release() 绝不能与进行中的 read() 重叠,
        // 因此真正的 release 仍只由 recordAudio 的 finally 在 read() 返回后、同一线程完成。
        _isRecording.value = false
        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }

        val file = outputFile
        outputFile = null
        return file
    }

    private suspend fun recordAudio(record: AudioRecord, file: File) {
        val buffer = ByteArray(bufferSize)
        val audioData = mutableListOf<ByteArray>()
        val startTime = System.currentTimeMillis()
        var reachedMaxDuration = false

        try {
            while (_isRecording.value) {
                // 检查是否超过最大时长
                val elapsed = (System.currentTimeMillis() - startTime) / 1000
                _remainingSeconds.value = (maxDurationSec - elapsed.toInt()).coerceAtLeast(0)
                if (elapsed >= maxDurationSec) {
                    reachedMaxDuration = true
                    _isRecording.value = false
                    break
                }

                val readSize = try {
                    record.read(buffer, 0, buffer.size)
                } catch (_: Exception) {
                    -1
                }
                if (readSize > 0) {
                    // 保存音频数据
                    audioData.add(buffer.copyOf(readSize))

                    // 计算音量级别
                    _audioLevel.value = calculateAudioLevel(buffer, readSize)
                }
            }

            // 写入WAV文件(在释放前完成)
            runCatching { writeWavFile(file, audioData) }
        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            // 单一释放点:read() 必然已返回,此处释放与读取在同一线程顺序执行,绝不重叠。
            releaseRecord(record)
            _audioLevel.value = 0f
            _remainingSeconds.value = maxDurationSec
            if (reachedMaxDuration) {
                withContext(Dispatchers.Main) {
                    onMaxDurationReached?.invoke(file)
                }
            }
        }
    }

    @Synchronized
    private fun releaseRecord(record: AudioRecord) {
        // 幂等释放指定的 AudioRecord;若它仍是当前实例则同时清空引用。
        if (audioRecord === record) {
            audioRecord = null
        }
        try {
            record.stop()
        } catch (_: Exception) {
        }
        try {
            record.release()
        } catch (_: Exception) {
        }
    }
    
    private fun calculateAudioLevel(buffer: ByteArray, size: Int): Float {
        var sum = 0L
        for (i in 0 until size step 2) {
            val sample = (buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xFF)
            sum += sample * sample
        }
        val rms = kotlin.math.sqrt(sum.toDouble() / (size / 2))
        val db = 20.0 * kotlin.math.log10((rms / 32768.0).coerceAtLeast(1e-7))
        val normalized = ((db + 55.0) / 55.0).coerceIn(0.0, 1.0)
        val sensitive = kotlin.math.sqrt(normalized).coerceIn(0.0, 1.0)
        return (sensitive * 100.0).toFloat()
    }
    
    private fun writeWavFile(file: File, audioData: List<ByteArray>) {
        val totalAudioLen = audioData.sumOf { it.size }
        val totalDataLen = totalAudioLen + 36
        val channels = 1
        val byteRate = sampleRate * channels * 2
        
        FileOutputStream(file).use { out ->
            // WAV文件头
            out.write(
                getWavHeader(
                    totalAudioLen.toLong(),
                    totalDataLen.toLong(),
                    sampleRate.toLong(),
                    channels,
                    byteRate.toLong()
                )
            )
            
            // 音频数据
            audioData.forEach { data ->
                out.write(data)
            }
        }
    }
    
    private fun getWavHeader(
        totalAudioLen: Long,
        totalDataLen: Long,
        sampleRate: Long,
        channels: Int,
        byteRate: Long
    ): ByteArray {
        val header = ByteArray(44)
        
        // RIFF chunk
        header[0] = 'R'.code.toByte()
        header[1] = 'I'.code.toByte()
        header[2] = 'F'.code.toByte()
        header[3] = 'F'.code.toByte()
        
        // File size
        writeInt(header, 4, totalDataLen.toInt())
        
        // WAVE
        header[8] = 'W'.code.toByte()
        header[9] = 'A'.code.toByte()
        header[10] = 'V'.code.toByte()
        header[11] = 'E'.code.toByte()
        
        // fmt chunk
        header[12] = 'f'.code.toByte()
        header[13] = 'm'.code.toByte()
        header[14] = 't'.code.toByte()
        header[15] = ' '.code.toByte()
        
        // fmt chunk size (16 for PCM)
        writeInt(header, 16, 16)
        
        // Audio format (1 = PCM)
        writeShort(header, 20, 1)
        
        // Number of channels
        writeShort(header, 22, channels)
        
        // Sample rate
        writeInt(header, 24, sampleRate.toInt())
        
        // Byte rate
        writeInt(header, 28, byteRate.toInt())
        
        // Block align
        writeShort(header, 32, (channels * 2))
        
        // Bits per sample
        writeShort(header, 34, 16)
        
        // data chunk
        header[36] = 'd'.code.toByte()
        header[37] = 'a'.code.toByte()
        header[38] = 't'.code.toByte()
        header[39] = 'a'.code.toByte()
        
        // Data size
        writeInt(header, 40, totalAudioLen.toInt())
        
        return header
    }
    
    private fun writeInt(header: ByteArray, offset: Int, value: Int) {
        header[offset] = (value and 0xff).toByte()
        header[offset + 1] = ((value shr 8) and 0xff).toByte()
        header[offset + 2] = ((value shr 16) and 0xff).toByte()
        header[offset + 3] = ((value shr 24) and 0xff).toByte()
    }
    
    private fun writeShort(header: ByteArray, offset: Int, value: Int) {
        header[offset] = (value and 0xff).toByte()
        header[offset + 1] = ((value shr 8) and 0xff).toByte()
    }
    
    private fun cleanup() {
        _isRecording.value = false
        recordingJob?.cancel()
        recordingJob = null
        // 仅在启动失败(协程尚未接管)时直接释放残留实例。
        audioRecord?.let { releaseRecord(it) }
        outputFile?.delete()
        outputFile = null
        _audioLevel.value = 0f
        _remainingSeconds.value = maxDurationSec
    }
}
