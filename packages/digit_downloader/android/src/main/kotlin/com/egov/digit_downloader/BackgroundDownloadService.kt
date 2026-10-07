package com.egov.digit_downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Native engine behind `BackgroundDownloadMode.systemManaged`. Runs as a
 * foreground service (not WorkManager) so the chunked-download loop has
 * direct control over the destination file and a live progress
 * notification, independent of whether Flutter is running at all — this is
 * what lets a download survive the app process being killed outright,
 * unlike the pure-Dart engine in `DigitDownloader`.
 *
 * A Kotlin port of `DigitDownloader._run` — same HEAD-then-Range-chunk-then-
 * verify shape, same [SnapshotStore]-backed resumability, same
 * already-complete fast path — so the two engines behave identically from
 * the caller's point of view, just with different survival guarantees.
 */
class BackgroundDownloadService : Service() {
    private lateinit var snapshotStore: SnapshotStore
    private lateinit var notificationManager: NotificationManager
    private val ensuredChannelIds = mutableSetOf<String>()

    override fun onCreate() {
        super.onCreate()
        snapshotStore = SnapshotStore(applicationContext)
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }

    /** Idempotent — channels are cheap to (re)create and this may be called once per unique [NotificationConfig.channelId] seen. */
    private fun ensureChannel(config: NotificationConfig) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (!ensuredChannelIds.add(config.channelId)) return
        // IMPORTANCE_DEFAULT rather than _LOW: a silent, no-heads-up channel
        // is easy to never notice while the app is in the foreground — it's
        // genuinely posted the whole time, just unobtrusively, which reads
        // exactly like "the notification only shows after I close the app."
        val channel = NotificationChannel(config.channelId, config.channelName, config.channelImportance)
        channel.description = config.channelDescription
        notificationManager.createNotificationChannel(channel)
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        val taskId = intent?.getStringExtra(EXTRA_TASK_ID)
        if (taskId == null) {
            stopIfIdle()
            return START_NOT_STICKY
        }

        when (intent.getStringExtra(EXTRA_ACTION)) {
            ACTION_START -> handleStart(intent, taskId)
            ACTION_PAUSE -> activeJobs[taskId]?.requestPause()
            ACTION_CANCEL -> activeJobs[taskId]?.requestCancel()
        }

        // START_REDELIVER_INTENT: if the OS kills this process while a job
        // is running, redeliver the same start Intent so the download picks
        // back up via the same resumable-snapshot path a manual restart
        // would use — the point of `systemManaged` in the first place.
        return START_REDELIVER_INTENT
    }

    private fun handleStart(
        intent: Intent,
        taskId: String,
    ) {
        if (activeJobs.containsKey(taskId)) return // already running — ignore duplicate start

        val spec = DownloadSpec.fromIntent(intent) ?: return
        ensureChannel(spec.notificationConfig)
        val notification = buildProgressNotification(spec.notificationConfig, 0, indeterminate = true)
        ServiceCompat.startForeground(
            this,
            notificationIdFor(taskId),
            notification,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            } else {
                0
            },
        )
        primaryTaskId = taskId

        val job = DownloadJob(applicationContext, spec, snapshotStore, ::onJobProgress, ::onJobTerminal)
        activeJobs[taskId] = job
        jobExecutor.execute(job::run)
    }

    private fun onJobProgress(
        taskId: String,
        bytesReceived: Long,
        totalBytes: Long,
        chunksTotal: Int,
        chunksCompleted: Int,
    ) {
        val config = activeJobs[taskId]?.spec?.notificationConfig
        if (config != null && config.showProgress) {
            val fraction = if (totalBytes > 0) (bytesReceived.toDouble() / totalBytes * 100).toInt() else 0
            notificationManager.notify(notificationIdFor(taskId), buildProgressNotification(config, fraction, indeterminate = totalBytes <= 0))
        }
        DownloadEventBus.emit(
            mapOf(
                "taskId" to taskId,
                "kind" to "progress",
                "bytesReceived" to bytesReceived,
                "totalBytes" to totalBytes,
                "bytesPerSecond" to 0.0,
                "chunksTotal" to chunksTotal,
                "chunksCompleted" to chunksCompleted,
            ),
        )
    }

    private fun onJobTerminal(
        taskId: String,
        event: Map<String, Any?>,
    ) {
        val config = activeJobs[taskId]?.spec?.notificationConfig ?: NotificationConfig.DEFAULT
        activeJobs.remove(taskId)
        DownloadEventBus.emit(event)

        when (event["kind"]) {
            "completed" -> {
                if (config.showCompleted) {
                    notificationManager.notify(notificationIdFor(taskId), buildTerminalNotification(config, success = true, errorText = null))
                } else {
                    notificationManager.cancel(notificationIdFor(taskId))
                }
            }
            "failed" -> {
                if (event["failureKind"] != "cancelled" && config.showFailed) {
                    val errorText = describeFailure(event)
                    notificationManager.notify(notificationIdFor(taskId), buildTerminalNotification(config, success = false, errorText = errorText))
                } else {
                    notificationManager.cancel(notificationIdFor(taskId))
                }
            }
            "paused" -> notificationManager.cancel(notificationIdFor(taskId))
        }

        stopIfIdle()
    }

    private fun describeFailure(event: Map<String, Any?>): String =
        when (event["failureKind"]) {
            "checksumMismatch" -> "Checksum did not match"
            "certificatePinningFailure" -> "Certificate did not match the pinned certificate"
            "incomplete" -> "Download stopped early"
            else -> event["message"] as? String ?: "Network error"
        }

    private fun stopIfIdle() {
        if (activeJobs.isNotEmpty()) return
        // DETACH, not REMOVE: onJobTerminal just posted the completed/failed
        // notification under this same notification id (the one tied to
        // startForeground). REMOVE deletes whatever notification is
        // currently associated with the foreground service — which, right
        // after that notify() call, is the terminal notification itself —
        // so it would be shown and instantly deleted back-to-back. DETACH
        // ends the foreground-service association but leaves the
        // already-posted notification as a normal, dismissible one.
        // (paused / cancelled already explicitly call cancel() beforehand,
        // so DETACH is a no-op for those — nothing left to detach.)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_DETACH)
        stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildProgressNotification(
        config: NotificationConfig,
        progressPercent: Int,
        indeterminate: Boolean,
    ): Notification {
        val silent = !config.showProgress
        return NotificationCompat.Builder(this, config.channelId)
            .setSmallIcon(resolveIcon(config))
            .setContentTitle(if (silent) "" else config.progressTitle)
            .setContentText(if (silent) "" else if (indeterminate) "Starting…" else config.progressText.replace("{percent}", "$progressPercent"))
            .setProgress(100, progressPercent, indeterminate)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(if (silent) NotificationCompat.PRIORITY_MIN else NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun buildTerminalNotification(
        config: NotificationConfig,
        success: Boolean,
        errorText: String?,
    ): Notification {
        val title = if (success) config.completedTitle else config.failedTitle
        val text =
            if (success) {
                config.completedText
            } else {
                config.failedText?.replace("{error}", errorText ?: "") ?: errorText
            }
        return NotificationCompat.Builder(this, config.channelId)
            .setSmallIcon(resolveIcon(config))
            .setContentTitle(title)
            .also { if (text != null) it.setContentText(text) }
            // Explicitly zeroed, not just omitted: this replaces the
            // progress notification under the same id, and simply not
            // calling setProgress() isn't reliably enough to clear the bar
            // — some Android versions/OEM renderers keep showing the last
            // progress state from the prior update unless it's zeroed out.
            .setProgress(0, 0, false)
            .setOngoing(false)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
    }

    /** Resolves [NotificationConfig.smallIconResourceName] via the host app's own resources; falls back to the launcher icon. */
    private fun resolveIcon(config: NotificationConfig): Int {
        val name = config.smallIconResourceName ?: return applicationInfo.icon
        val drawableId = resources.getIdentifier(name, "drawable", packageName)
        if (drawableId != 0) return drawableId
        val mipmapId = resources.getIdentifier(name, "mipmap", packageName)
        if (mipmapId != 0) return mipmapId
        return applicationInfo.icon
    }

    private fun notificationIdFor(taskId: String) = NOTIFICATION_ID_BASE + taskId.hashCode()

    companion object {
        private const val NOTIFICATION_ID_BASE = 20260

        const val EXTRA_TASK_ID = "taskId"
        const val EXTRA_ACTION = "action"
        const val ACTION_START = "start"
        const val ACTION_PAUSE = "pause"
        const val ACTION_CANCEL = "cancel"

        private var primaryTaskId: String? = null
        private val activeJobs = ConcurrentHashMap<String, DownloadJob>()
        private val jobExecutor = Executors.newCachedThreadPool()

        fun enqueueStart(
            context: Context,
            spec: DownloadSpec,
        ) {
            val intent =
                Intent(context, BackgroundDownloadService::class.java)
                    .putExtra(EXTRA_ACTION, ACTION_START)
                    .also { spec.applyTo(it) }
            context.startForegroundService(intent)
        }

        fun enqueuePause(
            context: Context,
            taskId: String,
        ) {
            context.startService(
                Intent(context, BackgroundDownloadService::class.java)
                    .putExtra(EXTRA_TASK_ID, taskId)
                    .putExtra(EXTRA_ACTION, ACTION_PAUSE),
            )
        }

        fun enqueueCancel(
            context: Context,
            taskId: String,
        ) {
            context.startService(
                Intent(context, BackgroundDownloadService::class.java)
                    .putExtra(EXTRA_TASK_ID, taskId)
                    .putExtra(EXTRA_ACTION, ACTION_CANCEL),
            )
        }
    }
}

/** Everything [DownloadJob] needs, parsed once from the starting [Intent]. */
data class DownloadSpec(
    val taskId: String,
    val url: String,
    val destinationPath: String?,
    val chunkCount: Int,
    val minChunkSize: Long,
    val maxRetriesPerChunk: Int,
    val expectedSha256: String?,
    val headers: Map<String, String>,
    val pinsByHost: Map<String, Set<String>>,
    val notificationConfig: NotificationConfig,
) {
    fun applyTo(intent: Intent) {
        intent.putExtra(BackgroundDownloadService.EXTRA_TASK_ID, taskId)
        intent.putExtra("url", url)
        intent.putExtra("destinationPath", destinationPath)
        intent.putExtra("chunkCount", chunkCount)
        intent.putExtra("minChunkSize", minChunkSize)
        intent.putExtra("maxRetriesPerChunk", maxRetriesPerChunk)
        intent.putExtra("expectedSha256", expectedSha256)
        intent.putExtra("headers", JSONObject(headers as Map<*, *>).toString())
        intent.putExtra(
            "certificatePins",
            JSONObject(pinsByHost.mapValues { org.json.JSONArray(it.value.toList()) } as Map<*, *>).toString(),
        )
        intent.putExtra("notification", notificationConfigToJson(notificationConfig).toString())
    }

    companion object {
        fun fromIntent(intent: Intent): DownloadSpec? {
            val taskId = intent.getStringExtra(BackgroundDownloadService.EXTRA_TASK_ID) ?: return null
            val url = intent.getStringExtra("url") ?: return null
            val headersJson = intent.getStringExtra("headers")?.let { JSONObject(it) }
            val headers =
                headersJson?.keys()?.asSequence()?.associateWith { headersJson.getString(it) } ?: emptyMap()
            val pinsJson = intent.getStringExtra("certificatePins")?.let { JSONObject(it) }
            val pins =
                pinsJson?.keys()?.asSequence()?.associateWith { host ->
                    val arr = pinsJson.getJSONArray(host)
                    (0 until arr.length()).map { arr.getString(it) }.toSet()
                } ?: emptyMap()
            val notificationConfig =
                intent.getStringExtra("notification")?.let { NotificationConfig.fromJson(JSONObject(it)) } ?: NotificationConfig.DEFAULT
            return DownloadSpec(
                taskId = taskId,
                url = url,
                destinationPath = intent.getStringExtra("destinationPath"),
                chunkCount = intent.getIntExtra("chunkCount", 4),
                minChunkSize = intent.getLongExtra("minChunkSize", 1024 * 1024),
                maxRetriesPerChunk = intent.getIntExtra("maxRetriesPerChunk", 3),
                expectedSha256 = intent.getStringExtra("expectedSha256"),
                headers = headers,
                pinsByHost = pins,
                notificationConfig = notificationConfig,
            )
        }

        private fun notificationConfigToJson(config: NotificationConfig): JSONObject =
            JSONObject().apply {
                put("channelId", config.channelId)
                put("channelName", config.channelName)
                put("channelDescription", config.channelDescription)
                put("channelImportance", config.channelImportance)
                put("smallIconResourceName", config.smallIconResourceName)
                put("showProgress", config.showProgress)
                put("progressTitle", config.progressTitle)
                put("progressText", config.progressText)
                put("showCompleted", config.showCompleted)
                put("completedTitle", config.completedTitle)
                put("completedText", config.completedText)
                put("showFailed", config.showFailed)
                put("failedTitle", config.failedTitle)
                put("failedText", config.failedText)
            }
    }
}

/**
 * Runs one download to completion — a Kotlin port of `DigitDownloader._run`.
 * Created fresh per [BackgroundDownloadService.handleStart] call; not
 * reused across downloads.
 */
class DownloadJob(
    private val context: Context,
    val spec: DownloadSpec,
    private val snapshotStore: SnapshotStore,
    private val onProgress: (taskId: String, bytesReceived: Long, totalBytes: Long, chunksTotal: Int, chunksCompleted: Int) -> Unit,
    private val onTerminal: (taskId: String, event: Map<String, Any?>) -> Unit,
) {
    private val pauseRequested = AtomicBoolean(false)
    private val cancelRequested = AtomicBoolean(false)

    fun requestPause() = pauseRequested.set(true)

    fun requestCancel() = cancelRequested.set(true)

    fun run() {
        try {
            val url = URL(spec.url)
            val destinationPath = spec.destinationPath ?: defaultDestinationPath(context, spec.taskId)
            val file = File(destinationPath)
            file.parentFile?.mkdirs()

            val head = openConnection(url, "HEAD")
            val totalBytes = head.getHeaderFieldLong("Content-Length", -1L)
            val etag = head.getHeaderField("ETag")
            val acceptsRanges = head.getHeaderField("Accept-Ranges") == "bytes"
            head.disconnect()

            // Already downloaded and verified by a previous run that was
            // never consumed (mirrors the same fast path in
            // DigitDownloader._run).
            if (spec.expectedSha256 != null && file.exists() && file.length() == totalBytes) {
                if (ChecksumUtil.sha256OfFile(file) == spec.expectedSha256) {
                    snapshotStore.delete(spec.taskId)
                    onTerminal(spec.taskId, mapOf("taskId" to spec.taskId, "kind" to "completed", "filePath" to file.path))
                    return
                }
            }

            val existingSnapshot = snapshotStore.read(spec.taskId)
            val canResume =
                existingSnapshot != null &&
                    existingSnapshot.totalBytes == totalBytes &&
                    existingSnapshot.etag == etag &&
                    file.exists() &&
                    file.length() == totalBytes

            val ranges: List<ByteRange>
            val received: LongArray
            if (canResume) {
                ranges = existingSnapshot!!.ranges
                received = existingSnapshot.chunkReceivedBytes.copyOf()
            } else {
                val effectiveChunkCount = if (acceptsRanges) spec.chunkCount else 1
                ranges = ChunkPlanner.plan(totalBytes, effectiveChunkCount, spec.minChunkSize)
                received = LongArray(ranges.size)
                RandomAccessFile(file, "rw").use { it.setLength(if (totalBytes > 0) totalBytes else 0) }
                snapshotStore.write(DownloadSnapshot(spec.taskId, totalBytes, etag, ranges, received))
            }

            val receivedAtomics = Array(ranges.size) { AtomicLong(received[it]) }
            var lastPersist = System.currentTimeMillis()
            val progressLock = Any()

            fun reportProgress() {
                synchronized(progressLock) {
                    val totalReceived = receivedAtomics.sumOf { it.get() }
                    val completedChunks = ranges.indices.count { receivedAtomics[it].get() >= ranges[it].length }
                    onProgress(spec.taskId, totalReceived, totalBytes, ranges.size, completedChunks)

                    val now = System.currentTimeMillis()
                    if (now - lastPersist > 250) {
                        lastPersist = now
                        snapshotStore.write(
                            DownloadSnapshot(spec.taskId, totalBytes, etag, ranges, LongArray(ranges.size) { receivedAtomics[it].get() }),
                        )
                    }
                }
            }

            val chunkExecutor = Executors.newFixedThreadPool(ranges.size.coerceAtLeast(1))
            val failures = java.util.Collections.synchronizedList(mutableListOf<Exception>())
            try {
                val futures =
                    ranges.mapIndexed { index, range ->
                        chunkExecutor.submit {
                            try {
                                downloadChunk(url, range, file, received[index], index, receivedAtomics, ::reportProgress)
                            } catch (e: Exception) {
                                failures.add(e)
                            }
                        }
                    }
                futures.forEach { it.get() }
            } finally {
                chunkExecutor.shutdown()
            }

            snapshotStore.write(
                DownloadSnapshot(spec.taskId, totalBytes, etag, ranges, LongArray(ranges.size) { receivedAtomics[it].get() }),
            )

            if (cancelRequested.get()) {
                if (file.exists()) file.delete()
                snapshotStore.delete(spec.taskId)
                onTerminal(spec.taskId, mapOf("taskId" to spec.taskId, "kind" to "failed", "failureKind" to "cancelled"))
                return
            }

            if (failures.isNotEmpty()) {
                onTerminal(
                    spec.taskId,
                    mapOf(
                        "taskId" to spec.taskId,
                        "kind" to "failed",
                        "failureKind" to "network",
                        "message" to (failures.first().message ?: failures.first().toString()),
                    ),
                )
                return
            }

            if (pauseRequested.get()) {
                val totalReceived = receivedAtomics.sumOf { it.get() }
                onTerminal(
                    spec.taskId,
                    mapOf(
                        "taskId" to spec.taskId,
                        "kind" to "paused",
                        "bytesReceived" to totalReceived,
                        "totalBytes" to totalBytes,
                        "chunksTotal" to ranges.size,
                        "chunksCompleted" to 0,
                    ),
                )
                return
            }

            if (spec.expectedSha256 != null) {
                val actual = ChecksumUtil.sha256OfFile(file)
                if (actual != spec.expectedSha256) {
                    snapshotStore.delete(spec.taskId)
                    onTerminal(
                        spec.taskId,
                        mapOf(
                            "taskId" to spec.taskId,
                            "kind" to "failed",
                            "failureKind" to "checksumMismatch",
                            "expectedSha256" to spec.expectedSha256,
                            "actualSha256" to actual,
                        ),
                    )
                    return
                }
            }

            snapshotStore.delete(spec.taskId)
            onTerminal(spec.taskId, mapOf("taskId" to spec.taskId, "kind" to "completed", "filePath" to file.path))
        } catch (e: Exception) {
            onTerminal(
                spec.taskId,
                mapOf("taskId" to spec.taskId, "kind" to "failed", "failureKind" to "network", "message" to (e.message ?: e.toString())),
            )
        }
    }

    private fun downloadChunk(
        url: URL,
        range: ByteRange,
        file: File,
        alreadyReceivedForChunk: Long,
        chunkIndex: Int,
        receivedAtomics: Array<AtomicLong>,
        reportProgress: () -> Unit,
    ) {
        var position = range.start + alreadyReceivedForChunk
        var attempt = 0
        RandomAccessFile(file, "rw").use { raf ->
            while (position <= range.endInclusive || range.endInclusive < 0) {
                if (pauseRequested.get() || cancelRequested.get()) return
                try {
                    position = fetchFrom(url, range, position, raf, chunkIndex, receivedAtomics, reportProgress)
                    return
                } catch (e: Exception) {
                    attempt++
                    if (attempt > spec.maxRetriesPerChunk) throw e
                    Thread.sleep(300L * attempt)
                }
            }
        }
    }

    /** Returns the position reached — used only to detect completion; retries restart from the last confirmed byte. */
    private fun fetchFrom(
        url: URL,
        range: ByteRange,
        startPosition: Long,
        raf: RandomAccessFile,
        chunkIndex: Int,
        receivedAtomics: Array<AtomicLong>,
        reportProgress: () -> Unit,
    ): Long {
        val connection = openConnection(url, "GET")
        val rangeHeader = if (range.endInclusive < 0) "bytes=$startPosition-" else "bytes=$startPosition-${range.endInclusive}"
        connection.setRequestProperty("Range", rangeHeader)
        spec.headers.forEach { (key, value) -> connection.setRequestProperty(key, value) }
        if (connection is javax.net.ssl.HttpsURLConnection) {
            PinningTrustManager.applyIfConfigured(connection, spec.pinsByHost)
        }

        val responseCode = connection.responseCode
        if (responseCode != HttpURLConnection.HTTP_PARTIAL && responseCode != HttpURLConnection.HTTP_OK) {
            connection.disconnect()
            throw java.io.IOException("Unexpected status $responseCode for ranged request")
        }

        var position = startPosition
        connection.inputStream.use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                if (pauseRequested.get() || cancelRequested.get()) return position
                val read = input.read(buffer)
                if (read == -1) break
                raf.seek(position)
                raf.write(buffer, 0, read)
                position += read
                receivedAtomics[chunkIndex].addAndGet(read.toLong())
                reportProgress()
            }
        }
        connection.disconnect()
        return position
    }

    private fun openConnection(
        url: URL,
        method: String,
    ): HttpURLConnection {
        val connection = url.openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        if (method == "HEAD") {
            spec.headers.forEach { (key, value) -> connection.setRequestProperty(key, value) }
            if (connection is javax.net.ssl.HttpsURLConnection) {
                PinningTrustManager.applyIfConfigured(connection, spec.pinsByHost)
            }
        }
        return connection
    }

    companion object {
        /**
         * Must match `path_provider`'s Android `getApplicationSupportDirectory()`
         * exactly (`<filesDir>/app_flutter`) — the Dart engine's default
         * destination path is built from that same call, and both engines
         * need to agree on where a given taskId's file lives.
         */
        fun defaultDestinationPath(
            context: Context,
            taskId: String,
        ): String {
            val appSupportDir = File(context.filesDir, "app_flutter")
            return File(File(appSupportDir, "digit_downloader"), taskId).path
        }
    }
}
