package com.idoluidoluidolu.watermark

import org.junit.Assert.*
import org.junit.Test

class FrameResourcePoolTest {
    private fun key(name: String, revision: Long = 1) = FrameSourceKey(name, revision, revision)

    @Test fun alternatingSourcesReuseAndThirdSourceEvictsLeastRecentlyUsed() {
        val released = mutableListOf<String>()
        val pool = FrameResourcePool(2, { it.path }, { released += it })
        pool.acquire(key("a")); pool.acquire(key("b")); pool.acquire(key("a"))
        assertEquals(2L, pool.created)
        assertEquals(1L, pool.reused)
        pool.acquire(key("c"))
        assertEquals(listOf("b"), released)
        assertEquals(2, pool.active)
    }

    @Test fun samePathReplacementReleasesOldResourceBeforeOpeningReplacement() {
        val events = mutableListOf<String>()
        val pool = FrameResourcePool(2, { events += "open ${it.length}"; it.length },
            { events += "close $it" })
        pool.acquire(key("a")); pool.acquire(key("a", 2))
        assertEquals(listOf("open 1", "close 1", "open 2"), events)
        assertEquals(1, pool.active)
    }

    @Test fun failedOpenDoesNotPoisonPreviousSourceOrBecomeACacheHit() {
        var attempts = 0
        val pool = FrameResourcePool(2, { attempts++; check(it.path != "bad"); it.path }, {})
        pool.acquire(key("good"))
        repeat(2) { try { pool.acquire(key("bad")); fail() } catch (_: IllegalStateException) {} }
        assertEquals("good", pool.acquire(key("good")))
        assertEquals(3, attempts)
        assertEquals(1L, pool.created)
        assertEquals(1L, pool.reused)
    }

    @Test fun clearIsIdempotentAndContinuesAfterOneReleaseFails() {
        val released = mutableListOf<String>()
        val pool = FrameResourcePool(2, { it.path }, { released += it; error("release failed") })
        pool.acquire(key("a")); pool.acquire(key("b"))
        pool.clear(); pool.clear()
        assertEquals(listOf("a", "b"), released)
        assertEquals(0, pool.active)
    }
}
