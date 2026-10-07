package com.egov.digit_downloader

import android.app.NotificationManager
import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** An inclusive byte range `[start, endInclusive]` for a single HTTP `Range` request. */
data class ByteRange(val start: Long, val endInclusive: Long) {
    val length: Long get() = endInclusive - start + 1

    fun toJson(): JSONArray = JSONArray().put(start).put(endInclusive)

    companion object {
        fun fromJson(json: JSONArray): ByteRange = ByteRange(json.getLong(0), json.getLong(1))
    }
}

/**
 * Splits [totalBytes] into disjoint, contiguous [ByteRange]s for concurrent
 * chunk workers — a Kotlin port of `ChunkPlanner` in the Dart engine, kept
 * byte-for-byte equivalent so a download planned by one side resumes
 * correctly if picked up by the other.
 */
object ChunkPlanner {
    fun plan(
        totalBytes: Long,
        chunkCount: Int,
        minChunkSize: Long,
    ): List<ByteRange> {
        if (totalBytes <= 0) return listOf(ByteRange(0, -1))

        val maxPossibleChunks = totalBytes / minChunkSize
        val effectiveCount =
            when {
                maxPossibleChunks < 1 -> 1
                chunkCount < maxPossibleChunks -> chunkCount
                else -> maxPossibleChunks.toInt()
            }

        val baseSize = totalBytes / effectiveCount
        val remainder = totalBytes % effectiveCount

        val ranges = mutableListOf<ByteRange>()
        var start = 0L
        for (i in 0 until effectiveCount) {
            val size = baseSize + (if (i < remainder) 1 else 0)
            val end = start + size - 1
            ranges.add(ByteRange(start, end))
            start = end + 1
        }
        return ranges
    }
}

/**
 * Resume state for one taskId — enough to decide whether a restarted
 * service can continue an interrupted download (matching [totalBytes]/
 * [etag] and an on-disk file of the right length) or must start clean.
 */
data class DownloadSnapshot(
    val taskId: String,
    val totalBytes: Long,
    val etag: String?,
    val ranges: List<ByteRange>,
    val chunkReceivedBytes: LongArray,
) {
    fun toJson(): JSONObject =
        JSONObject().apply {
            put("taskId", taskId)
            put("totalBytes", totalBytes)
            put("etag", etag)
            put("ranges", JSONArray(ranges.map { it.toJson() }))
            put("chunkReceivedBytes", JSONArray(chunkReceivedBytes.toList()))
        }

    companion object {
        fun fromJson(json: JSONObject): DownloadSnapshot {
            val rangesJson = json.getJSONArray("ranges")
            val ranges = (0 until rangesJson.length()).map { ByteRange.fromJson(rangesJson.getJSONArray(it)) }
            val receivedJson = json.getJSONArray("chunkReceivedBytes")
            val received = LongArray(receivedJson.length()) { receivedJson.getLong(it) }
            return DownloadSnapshot(
                taskId = json.getString("taskId"),
                totalBytes = json.getLong("totalBytes"),
                etag = if (json.isNull("etag")) null else json.getString("etag"),
                ranges = ranges,
                chunkReceivedBytes = received,
            )
        }
    }
}

/**
 * Customizes the notification(s) shown for one download — a Kotlin mirror
 * of `DownloadNotificationConfig` in the Dart engine. [progressText] and
 * [failedText] support `{percent}` / `{error}` placeholders, substituted
 * here rather than via a Dart callback, since that would mean a
 * platform-channel round trip on every single progress tick.
 */
data class NotificationConfig(
    val channelId: String,
    val channelName: String,
    val channelDescription: String?,
    /** An `android.app.NotificationManager.IMPORTANCE_*` value. */
    val channelImportance: Int,
    val smallIconResourceName: String?,
    val showProgress: Boolean,
    val progressTitle: String,
    val progressText: String,
    val showCompleted: Boolean,
    val completedTitle: String,
    val completedText: String?,
    val showFailed: Boolean,
    val failedTitle: String,
    val failedText: String?,
) {
    companion object {
        fun fromJson(json: JSONObject): NotificationConfig =
            NotificationConfig(
                channelId = json.optString("channelId", "digit_downloader_progress"),
                channelName = json.optString("channelName", "Downloads"),
                channelDescription = json.optStringOrNull("channelDescription"),
                channelImportance = json.optInt("channelImportance", NotificationManager.IMPORTANCE_DEFAULT),
                smallIconResourceName = json.optStringOrNull("smallIconResourceName"),
                showProgress = json.optBoolean("showProgress", true),
                progressTitle = json.optString("progressTitle", "Downloading update"),
                progressText = json.optString("progressText", "{percent}%"),
                showCompleted = json.optBoolean("showCompleted", true),
                completedTitle = json.optString("completedTitle", "Download complete"),
                completedText = json.optStringOrNull("completedText"),
                showFailed = json.optBoolean("showFailed", true),
                failedTitle = json.optString("failedTitle", "Download failed"),
                failedText = json.optStringOrNull("failedText"),
            )

        val DEFAULT = NotificationConfig(
            channelId = "digit_downloader_progress",
            channelName = "Downloads",
            channelDescription = null,
            channelImportance = NotificationManager.IMPORTANCE_DEFAULT,
            smallIconResourceName = null,
            showProgress = true,
            progressTitle = "Downloading update",
            progressText = "{percent}%",
            showCompleted = true,
            completedTitle = "Download complete",
            completedText = null,
            showFailed = true,
            failedTitle = "Download failed",
            failedText = null,
        )

        private fun JSONObject.optStringOrNull(key: String): String? = if (isNull(key) || !has(key)) null else getString(key)
    }
}

/**
 * Persists [DownloadSnapshot]s in SharedPreferences — deliberately separate
 * from the Dart engine's `just_storage`-backed store, since this needs to
 * be readable/writable by native code with no Dart isolate (or even Flutter
 * engine) attached, which is the whole point of
 * `BackgroundDownloadMode.systemManaged`.
 */
class SnapshotStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun read(taskId: String): DownloadSnapshot? {
        val raw = prefs.getString(keyFor(taskId), null) ?: return null
        return runCatching { DownloadSnapshot.fromJson(JSONObject(raw)) }.getOrNull()
    }

    fun write(snapshot: DownloadSnapshot) {
        prefs.edit().putString(keyFor(snapshot.taskId), snapshot.toJson().toString()).apply()
    }

    fun delete(taskId: String) {
        prefs.edit().remove(keyFor(taskId)).apply()
    }

    private fun keyFor(taskId: String) = "snapshot.$taskId"

    private companion object {
        const val PREFS_NAME = "digit_downloader_prefs"
    }
}
