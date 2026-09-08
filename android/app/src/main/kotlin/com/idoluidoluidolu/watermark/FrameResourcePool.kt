package com.idoluidoluidolu.watermark

import java.io.File

/** A file replacement at the same path must not reuse a decoder for the old file. */
internal data class FrameSourceKey(val path: String, val length: Long, val modified: Long) {
    companion object {
        fun fromFile(path: String): FrameSourceKey = File(path).absoluteFile.let {
            FrameSourceKey(it.path, it.length(), it.lastModified())
        }
    }
}

/** Thread-confined LRU. Callers serialize acquisition, use and release on one executor. */
internal class FrameResourcePool<T>(
    val capacity: Int,
    private val create: (FrameSourceKey) -> T,
    private val dispose: (T) -> Unit,
) {
    init { require(capacity > 0) }

    private val entries = LinkedHashMap<FrameSourceKey, T>(capacity, 0.75f, true)
    var created = 0L
        private set
    var reused = 0L
        private set
    val active: Int get() = entries.size

    fun acquire(key: FrameSourceKey): T {
        entries[key]?.let { reused++; return it }
        // Evict before opening: even briefly exceeding capacity costs a decoder.
        entries.keys.filter { it.path == key.path }.forEach { release(it) }
        if (entries.size >= capacity) release(entries.keys.first())
        val value = create(key) // A failed open never enters the cache.
        entries[key] = value
        created++
        return value
    }

    private fun release(key: FrameSourceKey) {
        val value = entries.remove(key) ?: return
        try { dispose(value) } catch (_: Exception) { /* Release the remaining entries too. */ }
    }

    fun clear() = entries.keys.toList().forEach { release(it) }
}
