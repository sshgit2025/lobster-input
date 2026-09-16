package com.lobster.input.core.security

import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import com.lobster.input.core.network.ApiConfig
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 集中封装登录 token 的加密读写。
 *
 * 设计要点（保证「输入法 LobsterIME 与主 App 共享同一份 token」不被破坏）：
 * - 密钥由 Android Keystore 持有（应用级别名 [KEY_ALIAS]），AES-256/GCM。
 * - 密文（Base64，含 12 字节 IV 前缀）仍写入同一个 SharedPreferences 文件
 *   [ApiConfig.PREFS_NAME] 的新 key [ApiConfig.KEY_AUTH_TOKEN_ENC] 下。
 * - 因为 IME 与主 App 同进程、共享同一 prefs 文件与同一应用级 Keystore 别名，
 *   双方读写都经过本对象，共享天然保留。
 *
 * 所有 Keystore / 解密异常都被吞掉并降级为 null（等价于需要重新登录），绝不崩溃。
 */
object SecureTokenStore {

    private const val TAG = "SecureTokenStore"

    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    private const val KEY_ALIAS = "lobster_token_key"
    private const val TRANSFORMATION =
        "${KeyProperties.KEY_ALGORITHM_AES}/${KeyProperties.BLOCK_MODE_GCM}/${KeyProperties.ENCRYPTION_PADDING_NONE}"
    private const val GCM_IV_LENGTH = 12
    private const val GCM_TAG_LENGTH_BITS = 128

    /**
     * 解密结果的内存缓存(密文键控)。
     *
     * 关键性能修复:isLoggedIn()/authHeader() 会被 refreshKeyboardUi 在录音时每帧高频调用,
     * 若每次都走 Android Keystore 解密(IPC + AES/GCM,单次数毫秒),会把主线程打爆并触发 ANR
     * (输入法面板卡死后被系统杀掉)。这里缓存「密文 -> 明文」:密文未变直接返回缓存,
     * 不再触碰 Keystore;登录态变化(密文变化)会自然 miss 并重新解密。
     */
    @Volatile
    private var cachedCipher: String? = null
    @Volatile
    private var cachedPlain: String? = null

    /**
     * 读取 token（解密后的明文）。
     *
     * 从未上线、一直是测试版，不迁移老数据：若只有旧明文 key [ApiConfig.KEY_AUTH_TOKEN]，
     * 直接清除该明文并返回 null（老用户处于登出态，重新登录即可）。
     *
     * 任何异常都降级返回 null。
     */
    @Synchronized
    fun readToken(prefs: SharedPreferences): String? {
        val encrypted = prefs.getString(ApiConfig.KEY_AUTH_TOKEN_ENC, null)
        if (encrypted != null) {
            // 命中缓存:密文未变,直接返回上次解密结果,绝不重复走 Keystore。
            if (encrypted == cachedCipher) {
                return cachedPlain
            }
            return try {
                val plain = decrypt(encrypted)
                cachedCipher = encrypted
                cachedPlain = plain
                plain
            } catch (e: Exception) {
                Log.w(TAG, "解密 token 失败，降级为未登录", e)
                cachedCipher = null
                cachedPlain = null
                null
            }
        }

        // 没有密文:清空缓存,并清除旧版残留的明文 token(不迁移,老用户重新登录即可)。
        cachedCipher = null
        cachedPlain = null
        if (prefs.contains(ApiConfig.KEY_AUTH_TOKEN)) {
            prefs.edit().remove(ApiConfig.KEY_AUTH_TOKEN).apply()
        }
        return null
    }

    /**
     * 写入 token：value 为 null/空时等价于清除；否则加密写入新 key。
     * 同时清除旧明文 key，确保迁移后不再残留明文。
     */
    @Synchronized
    fun writeToken(prefs: SharedPreferences, value: String?) {
        if (value.isNullOrEmpty()) {
            clearToken(prefs)
            return
        }
        try {
            val cipherText = encrypt(value)
            prefs.edit()
                .putString(ApiConfig.KEY_AUTH_TOKEN_ENC, cipherText)
                .remove(ApiConfig.KEY_AUTH_TOKEN)
                .apply()
            // 同步刷新缓存,使后续读取直接命中,无需解密。
            cachedCipher = cipherText
            cachedPlain = value
        } catch (e: Exception) {
            Log.e(TAG, "加密写入 token 失败", e)
            // 加密失败时不落明文，清除以保持一致状态（用户需重新登录）
            clearToken(prefs)
        }
    }

    /** 清除 token：同时移除加密 key 与旧明文 key。 */
    @Synchronized
    fun clearToken(prefs: SharedPreferences) {
        cachedCipher = null
        cachedPlain = null
        prefs.edit()
            .remove(ApiConfig.KEY_AUTH_TOKEN_ENC)
            .remove(ApiConfig.KEY_AUTH_TOKEN)
            .apply()
    }

    private fun encrypt(plain: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
        val iv = cipher.iv
        val cipherBytes = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        val combined = ByteArray(iv.size + cipherBytes.size)
        System.arraycopy(iv, 0, combined, 0, iv.size)
        System.arraycopy(cipherBytes, 0, combined, iv.size, cipherBytes.size)
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String): String {
        val combined = Base64.decode(encoded, Base64.NO_WRAP)
        if (combined.size <= GCM_IV_LENGTH) {
            throw IllegalArgumentException("密文长度异常")
        }
        val iv = combined.copyOfRange(0, GCM_IV_LENGTH)
        val cipherBytes = combined.copyOfRange(GCM_IV_LENGTH, combined.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            getOrCreateSecretKey(),
            GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv)
        )
        return String(cipher.doFinal(cipherBytes), Charsets.UTF_8)
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let {
            return it.secretKey
        }

        val keyGenerator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            ANDROID_KEYSTORE
        )
        val spec = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(false)
            .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }
}
