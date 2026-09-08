package com.idoluidoluidolu.watermark

/** Main-thread ownership of cancellable preview work. Export jobs never enter this gate. */
internal class PreviewWorkGate<T>(private val yieldWork: (T) -> Unit) {
    private val jobs = linkedSetOf<T>()
    var interactive = false
        private set

    /** Returns false when a new preview job must wait; it has not started yet. */
    fun register(job: T, canYield: Boolean): Boolean {
        if (!canYield) return true
        if (interactive) {
            yieldWork(job)
            return false
        }
        jobs.add(job)
        return true
    }

    fun finish(job: T) { jobs.remove(job) }

    fun setInteractive(value: Boolean) {
        if (value == interactive) return
        interactive = value
        if (!value) return
        // A successful yield calls finish(). Keep a job whose cancellation failed
        // owned until completion, so a later busy edge may try to yield it again.
        val pending = jobs.toList()
        pending.forEach(yieldWork)
    }
}
