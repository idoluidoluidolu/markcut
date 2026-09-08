package com.idoluidoluidolu.watermark

import org.junit.Assert.*
import org.junit.Test

class PreviewWorkGateTest {
    @Test fun busyEdgeYieldsOnlyOptedInJobsOnceAndNeverRestartsOnItsOwn() {
        val yielded = mutableListOf<String>()
        lateinit var gate: PreviewWorkGate<String>
        gate = PreviewWorkGate { yielded += it; gate.finish(it) }
        assertTrue(gate.register("preview", true))
        assertTrue(gate.register("export", false))
        gate.setInteractive(true)
        repeat(10) { gate.setInteractive(true) }
        gate.setInteractive(false)
        assertEquals(listOf("preview"), yielded)
        assertTrue(gate.register("retry", true))
        gate.setInteractive(true)
        assertEquals(listOf("preview", "retry"), yielded)
    }

    @Test fun busyNewPreviewIsDeferredBeforeStartingButExportsRemainAllowed() {
        val yielded = mutableListOf<String>()
        val gate = PreviewWorkGate<String> { yielded += it }
        gate.setInteractive(true)
        assertFalse(gate.register("preview", true))
        assertTrue(gate.register("export", false))
        assertEquals(listOf("preview"), yielded)
    }

    @Test fun completedJobsAreNeverCancelledAndCallbackCanFinishReentrantly() {
        val yielded = mutableListOf<String>()
        lateinit var gate: PreviewWorkGate<String>
        gate = PreviewWorkGate { yielded += it; gate.finish(it) }
        gate.register("done", true); gate.finish("done")
        gate.register("running", true)
        gate.setInteractive(true)
        assertEquals(listOf("running"), yielded)
    }

    @Test fun unsuccessfulYieldStaysOwnedUntilCompletionOrNextBusyEdge() {
        var attempts = 0
        val gate = PreviewWorkGate<String> { attempts++ }
        gate.register("running", true)
        gate.setInteractive(true)
        gate.setInteractive(true)
        assertEquals(1, attempts)
        gate.setInteractive(false)
        gate.setInteractive(true)
        assertEquals(2, attempts)
        gate.finish("running")
        gate.setInteractive(false)
        gate.setInteractive(true)
        assertEquals(2, attempts)
    }
}
