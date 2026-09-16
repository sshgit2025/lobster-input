package com.lobster.input.core.update

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.pm.PackageInfoCompat
import androidx.core.content.FileProvider
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import com.lobster.input.BuildConfig
import com.lobster.input.core.locale.MobileLanguage
import com.lobster.input.core.locale.MobileStrings
import com.lobster.input.core.network.ApiConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

class AndroidUpdateManager(
    private val context: Context,
    private val httpClient: OkHttpClient = updateHttpClient(),
    private val gson: Gson = Gson()
) {
    suspend fun checkForUpdate(): AndroidUpdateCheckResult = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(ApiConfig.Update.FEED_URL)
            .get()
            .build()
        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) {
            response.close()
            error(updateText("检查更新失败：HTTP ${response.code}", "Update check failed: HTTP ${response.code}", "Проверка обновлений не удалась: HTTP ${response.code}", "업데이트 확인 실패: HTTP ${response.code}"))
        }
        val body = response.body?.string().orEmpty()
        response.close()
        val manifest = gson.fromJson(body, AndroidUpdateManifest::class.java)
            ?: error(updateText("更新清单格式无效", "Invalid update feed", "Некорректный файл обновления", "업데이트 정보 형식이 올바르지 않습니다"))
        if (manifest.versionCode > currentInstalledVersion().versionCode) {
            AndroidUpdateCheckResult.UpdateAvailable(manifest)
        } else {
            // 已是最新版本:说明此前下载的 APK 已安装成功(或已过期),清理更新缓存目录,避免堆积
            runCatching { File(context.cacheDir, "updates").deleteRecursively() }
            AndroidUpdateCheckResult.NoUpdate
        }
    }

    suspend fun downloadApk(
        manifest: AndroidUpdateManifest,
        onProgress: (Int?) -> Unit = {}
    ): File = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(manifest.apkUrl)
            .get()
            .build()
        val response = httpClient.newCall(request).execute()
        if (!response.isSuccessful) {
            response.close()
            error(updateText("下载更新失败：HTTP ${response.code}", "Download failed: HTTP ${response.code}", "Скачивание не удалось: HTTP ${response.code}", "다운로드 실패: HTTP ${response.code}"))
        }
        val body = response.body ?: run {
            response.close()
            error(updateText("下载更新失败：响应为空", "Download failed: empty response", "Скачивание не удалось: пустой ответ", "다운로드 실패: 빈 응답"))
        }
        val updateDir = File(context.cacheDir, "updates").apply { mkdirs() }
        // 下载前清理旧安装包(只保留本次下载),避免历史版本 APK 无限堆积撑爆缓存
        updateDir.listFiles()?.forEach { runCatching { it.delete() } }
        val apkFile = File(updateDir, "lobster-input-${manifest.versionName}-${manifest.versionCode}.apk")
        val contentLength = body.contentLength()
        var downloaded = 0L
        var lastProgress = -1
        apkFile.outputStream().use { output ->
            body.byteStream().use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val read = input.read(buffer)
                    if (read <= 0) break
                    output.write(buffer, 0, read)
                    downloaded += read
                    if (contentLength > 0) {
                        val progress = ((downloaded * 100) / contentLength).toInt().coerceIn(0, 100)
                        if (progress != lastProgress) {
                            lastProgress = progress
                            onProgress(progress)
                        }
                    } else {
                        onProgress(null)
                    }
                }
            }
        }
        response.close()
        manifest.apkSha256?.takeIf { it.isNotBlank() }?.let { expected ->
            val actual = apkFile.sha256()
            check(actual.equals(expected, ignoreCase = true)) {
                updateText("安装包校验失败", "APK checksum failed", "Проверка APK не прошла", "APK 검증 실패")
            }
        }
        validateDownloadedApk(apkFile, manifest)
        apkFile
    }

    companion object {
        private fun updateHttpClient(): OkHttpClient {
            return OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(90, TimeUnit.SECONDS)
                .writeTimeout(30, TimeUnit.SECONDS)
                .callTimeout(0, TimeUnit.SECONDS)
                .build()
        }
    }

    fun canRequestPackageInstalls(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()
    }

    fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val uri = Uri.parse("package:${context.packageName}")
        val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, uri)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    fun installApk(apkFile: File) {
        val uri = FileProvider.getUriForFile(
            context,
            "${BuildConfig.APPLICATION_ID}.fileprovider",
            apkFile
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(intent)
    }

    fun currentInstalledVersion(): AndroidInstalledVersion {
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        return AndroidInstalledVersion(
            versionCode = PackageInfoCompat.getLongVersionCode(packageInfo),
            versionName = packageInfo.versionName ?: BuildConfig.VERSION_NAME
        )
    }

    private fun validateDownloadedApk(apkFile: File, manifest: AndroidUpdateManifest) {
        val archiveInfo = context.packageManager.getPackageArchiveInfo(apkFile.absolutePath, 0)
            ?: error(updateText("安装包格式无效", "Invalid APK package", "Некорректный APK", "APK 형식이 올바르지 않습니다"))
        check(archiveInfo.packageName == context.packageName) {
            updateText("安装包包名不匹配", "APK package name mismatch", "Имя пакета APK не совпадает", "APK 패키지명이 일치하지 않습니다")
        }
        val archiveVersionCode = PackageInfoCompat.getLongVersionCode(archiveInfo)
        check(archiveVersionCode == manifest.versionCode) {
            updateText("更新清单版本与安装包版本不一致", "Feed version does not match APK", "Версия в файле не совпадает с APK", "업데이트 정보와 APK 버전이 일치하지 않습니다")
        }
        check(archiveVersionCode > currentInstalledVersion().versionCode) {
            updateText("当前已安装版本不低于更新包版本", "Installed version is not older than the APK", "Установленная версия не ниже APK", "설치된 버전이 업데이트 APK보다 낮지 않습니다")
        }
    }

    private fun updateText(zh: String, en: String, ru: String, ko: String): String {
        return when (MobileStrings.currentLanguage(context)) {
            MobileLanguage.EN -> en
            MobileLanguage.RU -> ru
            MobileLanguage.KO -> ko
            else -> zh
        }
    }
}

data class AndroidInstalledVersion(
    val versionCode: Long,
    val versionName: String
)

data class AndroidUpdateManifest(
    @SerializedName("version_code")
    val versionCode: Long,
    @SerializedName("version_name")
    val versionName: String,
    @SerializedName("apk_url")
    val apkUrl: String,
    @SerializedName("apk_sha256")
    val apkSha256: String? = null,
    @SerializedName("release_notes")
    val releaseNotes: String? = null,
    @SerializedName("force")
    val force: Boolean = false,
    @SerializedName("published_at")
    val publishedAt: String? = null
)

sealed interface AndroidUpdateCheckResult {
    data object NoUpdate : AndroidUpdateCheckResult
    data class UpdateAvailable(val manifest: AndroidUpdateManifest) : AndroidUpdateCheckResult
}

private fun File.sha256(): String {
    val digest = MessageDigest.getInstance("SHA-256")
    inputStream().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            digest.update(buffer, 0, read)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}
