package com.lobster.input.core.history

import android.content.Context
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.lobster.input.core.network.ApiConfig
import java.util.UUID

enum class MobileHistoryStatus {
    SUCCESS,
    FAILED
}

data class MobileHistoryRecord(
    val id: String = UUID.randomUUID().toString(),
    val operation: String,
    val transcript: String? = null,
    val result: String? = null,
    val actionType: String? = null,
    val selectedText: String? = null,
    val errorMessage: String? = null,
    val status: MobileHistoryStatus,
    val createdAt: Long = System.currentTimeMillis()
)

class MobileHistoryStore(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
    private val gson = Gson()
    private val recordType = object : TypeToken<List<MobileHistoryRecord>>() {}.type

    fun records(): List<MobileHistoryRecord> {
        val raw = prefs.getString(KEY_RECORDS, null) ?: return emptyList()
        return runCatching {
            gson.fromJson<List<MobileHistoryRecord>>(raw, recordType)
        }.getOrDefault(emptyList())
    }

    fun addSuccess(
        operation: String,
        transcript: String,
        result: String,
        actionType: String?,
        selectedText: String?
    ) {
        add(
            MobileHistoryRecord(
                operation = operation,
                transcript = transcript,
                result = result,
                actionType = actionType,
                selectedText = selectedText,
                status = MobileHistoryStatus.SUCCESS
            )
        )
    }

    fun addFailed(operation: String, errorMessage: String, selectedText: String?) {
        add(
            MobileHistoryRecord(
                operation = operation,
                selectedText = selectedText,
                errorMessage = errorMessage,
                status = MobileHistoryStatus.FAILED
            )
        )
    }

    fun delete(id: String) {
        save(records().filterNot { it.id == id })
    }

    fun clearAll() {
        save(emptyList())
    }

    private fun add(record: MobileHistoryRecord) {
        save((listOf(record) + records()).take(MAX_RECORDS))
    }

    private fun save(items: List<MobileHistoryRecord>) {
        prefs.edit().putString(KEY_RECORDS, gson.toJson(items)).apply()
    }

    companion object {
        private const val KEY_RECORDS = "mobile_history_records"
        private const val MAX_RECORDS = 100
    }
}
