package com.lobster.input.core.log

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/// 落盘运行日志:写入内部存储 files/logs/lobster-yyyy-MM-dd.log。
/// - 按天切割:每天一个文件,跨天写入时自动滚动;
/// - 保留 14 天:创建新日文件时清理更早的文件,避免撑爆磁盘;
/// - 覆盖安装(在线升级)不清空:internal files 目录只在卸载/清数据时被系统删除;
/// - 单线程串行写入,不阻塞调用方;写文件失败静默降级(仍打 Logcat)。
object FileLog {

    private const val RETENTION_DAYS = 14
    private const val PREFIX = "lobster-"
    private const val SUFFIX = ".log"

    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "FileLog") }
    private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    private val timeFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    @Volatile
    private var logDir: File? = null
    private var currentDay: String = ""
    private var currentFile: File? = null

    fun init(context: Context) {
        if (logDir != null) return
        logDir = File(context.applicationContext.filesDir, "logs").apply { mkdirs() }
    }

    fun i(tag: String, msg: String) = write("I", tag, msg).also { Log.i(tag, msg) }
    fun w(tag: String, msg: String) = write("W", tag, msg).also { Log.w(tag, msg) }
    fun e(tag: String, msg: String) = write("E", tag, msg).also { Log.e(tag, msg) }

    private fun write(level: String, tag: String, msg: String) {
        val dir = logDir ?: return
        val now = Date()
        executor.execute {
            runCatching {
                val day = dayFormat.format(now)
                if (day != currentDay || currentFile == null) {
                    currentDay = day
                    currentFile = File(dir, "$PREFIX$day$SUFFIX")
                    pruneOldLogs(dir, day)
                }
                currentFile?.appendText("${timeFormat.format(now)} $level/$tag: $msg\n")
            }
        }
    }

    /// 只保留最近 RETENTION_DAYS 个日文件(按文件名中的日期字典序即时间序)。
    private fun pruneOldLogs(dir: File, today: String) {
        val files = dir.listFiles { f -> f.name.startsWith(PREFIX) && f.name.endsWith(SUFFIX) } ?: return
        val sorted = files.sortedByDescending { it.name }
        sorted.drop(RETENTION_DAYS).forEach { it.delete() }
    }
}
