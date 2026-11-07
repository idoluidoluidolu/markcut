package com.idoluidoluidolu.watermark

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/// MODNet 融合規則、距離轉換；再拿桌機版 ONNX Runtime 真的跑一次包進 App 的模型
class CutoutMattingTest {
    @Test
    fun chamferMeasuresDistanceToOutside() {
        // 9×1：中間 5 格是 on
        val on = BooleanArray(9) { it in 2..6 }
        val d = CutoutMatting.chamfer(on, 9, 1)
        assertEquals(listOf(0, 0, 3, 6, 9, 6, 3, 0, 0), d.toList())
    }

    @Test
    fun fuseKeepsCoreDropsFarAndUsesMatteInBetween() {
        val w = 40
        val h = 1
        // 粗遮罩：10..29 是人
        val coarse = FloatArray(w) { if (it in 10..29) 1f else 0f }
        // MODNet：核心挖了個洞（全身時頭被挖掉那種）、邊緣多一點髮絲、遠處亂說
        val matte = FloatArray(w) { x ->
            when (x) {
                in 15..24 -> 0f // 洞
                in 6..9 -> 0.4f // 髮絲（離人 1~4 格）
                0 -> 0.9f // 遠處亂說
                else -> if (x in 10..29) 1f else 0f
            }
        }
        val out = CutoutMatting.fuse(coarse, matte, w, h, core = 2, reach = 5)
        assertEquals("核心的洞補回來", 1f, out[20], 0f)
        assertEquals("髮絲照 MODNet", 0.4f, out[7], 0f)
        assertEquals("遠處不要", 0f, out[0], 0f)
        assertEquals("人邊緣照 MODNet", 1f, out[10], 0f)
    }

    @Test
    fun iouCountsPersonPixels() {
        val a = floatArrayOf(1f, 1f, 0f, 0f)
        val b = floatArrayOf(1f, 0f, 1f, 0f)
        assertEquals(1.0 / 3, CutoutMatting.iou(a, b), 1e-9)
        assertEquals(0.0, CutoutMatting.iou(FloatArray(4), FloatArray(4)), 0.0)
    }

    @Test
    fun bundledModelRunsOnDesktopRuntime() {
        val f = listOf(
            File("src/main/assets/models/modnet_fp16.onnx"),
            File("app/src/main/assets/models/modnet_fp16.onnx"),
        ).firstOrNull { it.exists() } ?: error("找不到模型檔")
        CutoutMatting(f.readBytes()).use { m ->
            // 120×200：中間一個膚色的橢圓（不求準，只驗大小、範圍、跑得起來）
            val w = 120
            val h = 200
            val rgb = ByteArray(w * h * 3)
            for (y in 0 until h) for (x in 0 until w) {
                val i = (y * w + x) * 3
                val dx = (x - 60) / 35.0
                val dy = (y - 90) / 60.0
                val person = dx * dx + dy * dy < 1
                rgb[i] = (if (person) 210 else 40).toByte()
                rgb[i + 1] = (if (person) 160 else 90).toByte()
                rgb[i + 2] = (if (person) 140 else 50).toByte()
            }
            val t0 = System.nanoTime()
            val a = m.matte(rgb, w, h)
            println("BENCH modnet 120x200 → %.1f ms".format((System.nanoTime() - t0) / 1e6))
            assertEquals(w * h, a.size)
            assertTrue(a.all { it in 0f..1f })
        }
    }
}
