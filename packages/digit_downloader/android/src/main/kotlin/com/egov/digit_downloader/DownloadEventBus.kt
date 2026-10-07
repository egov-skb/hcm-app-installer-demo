package com.egov.digit_downloader

import java.util.concurrent.CopyOnWriteArraySet

/**
 * Decouples [BackgroundDownloadService] (which may run with no Flutter
 * engine attached at all) from [DigitDownloaderPlugin] (which only exists
 * while one is). The service always emits; the plugin only forwards to Dart
 * while something is actually listening on the EventChannel.
 */
object DownloadEventBus {
    private val listeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()

    fun addListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.remove(listener)
    }

    fun emit(event: Map<String, Any?>) {
        listeners.forEach { it(event) }
    }
}
