package com.lobster.input.core.device

import android.content.Context
import android.os.Build
import android.provider.Settings
import java.security.MessageDigest

/**
 * 设备唯一标识与硬件指纹工具。
 * 所有方法均为纯函数，结果可缓存，不持有 Context 引用。
 *
 * 字段格式与 MAC/Windows 端保持一致：SHA-256 输出的 64 位小写十六进制字符串。
 */
object DeviceIdentity {

    /**
     * 设备 ID：对 ANDROID_ID 做 SHA-256 哈希。
     * ANDROID_ID 在同一设备同一应用签名下稳定，重置出厂设置后会变化。
     * 哈希后格式与 MAC/Win 端（64 位 hex）统一，避免明文上报系统标识符。
     */
    fun deviceId(context: Context): String {
        val androidId = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ANDROID_ID
        ) ?: "unknown_android_id"
        return sha256(androidId)
    }

    /**
     * 硬件指纹：组合多个相对稳定的系统级属性后 SHA-256 哈希。
     * 组合项：ANDROID_ID | Build.FINGERPRINT | Build.BOARD | Build.HARDWARE | CPU_ABI
     *
     * - Build.FINGERPRINT：包含设备型号、系统版本等，刷机后变化
     * - Build.BOARD：主板型号，硬件更换时变化
     * - Build.HARDWARE：硬件标识符
     * - SUPPORTED_ABIS[0]：CPU 架构
     *
     * 注意：不使用 IMEI/序列号（需额外权限，且 Android 10+ 不可用）。
     */
    fun hardwareFingerprint(context: Context): String {
        val androidId = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ANDROID_ID
        ) ?: "unknown"

        val components = listOf(
            androidId,
            Build.FINGERPRINT,
            Build.BOARD,
            Build.HARDWARE,
            Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown_abi"
        )
        val raw = components.joinToString(separator = "|")
        return sha256(raw)
    }

    private fun sha256(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val bytes = digest.digest(input.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
