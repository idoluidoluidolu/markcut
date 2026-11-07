package com.idoluidoluidolu.watermark

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/// 修邊、防閃跟參考實作（scratchpad 的 refcore.py 產的向量）比對；iOS 的
/// MCCutoutRefine 用同一份向量
class CutoutRefineTest {
    private class Vectors(
        val w: Int,
        val h: Int,
        val r: Int,
        val eps: Float,
        val guide: ByteArray,
        val coarse: FloatArray,
        val refined: FloatArray,
        val ofd: List<ByteArray>,
    )

    private fun load(): Vectors {
        val text = javaClass.classLoader!!.getResourceAsStream("cutout_refine_vectors.txt")!!
            .bufferedReader().readText()
        val lines = text.trim().split("\n")
        val head = lines[0].trim().split(" ")
        fun ints(l: String) = l.trim().split(" ").map { it.toInt() }
        fun floats(l: String) = l.trim().split(" ").map { it.toFloat() }.toFloatArray()
        return Vectors(
            w = head[0].toInt(),
            h = head[1].toInt(),
            r = head[2].toInt(),
            eps = head[3].toFloat(),
            guide = ints(lines[1]).map { it.toByte() }.toByteArray(),
            coarse = floats(lines[2]),
            refined = floats(lines[3]),
            ofd = (4..7).map { i -> ints(lines[i]).map { it.toByte() }.toByteArray() },
        )
    }

    @Test
    fun bandRefineMatchesReference() {
        val v = load()
        val out = CutoutRefine.bandRefine(v.guide, v.coarse, v.w, v.h, v.r, v.eps)
        var worst = 0f
        for (i in out.indices) worst = maxOf(worst, abs(out[i] - v.refined[i]))
        assertTrue("最大誤差 $worst", worst < 2e-3f)
    }

    @Test
    fun ofdMatchesReference() {
        val v = load()
        val out = CutoutRefine.ofd(v.ofd[0], v.ofd[1], v.ofd[2])
        assertArrayEquals(v.ofd[3], out)
    }

    @Test
    fun boxMeanAveragesOnlyExistingPixels() {
        // 3×1：半徑 1 → 兩端只有兩格
        val src = floatArrayOf(0f, 3f, 6f)
        val out = FloatArray(3)
        CutoutRefine.boxMean(src, 3, 1, 1, FloatArray(3), out)
        assertEquals(1.5f, out[0], 1e-6f)
        assertEquals(3f, out[1], 1e-6f)
        assertEquals(4.5f, out[2], 1e-6f)
    }

    @Test
    fun refineLeavesConfidentPixelsAlone() {
        // 整張都是確定的（0 或 1）：一格都不該動
        val w = 8
        val h = 6
        val coarse = FloatArray(w * h) { if (it % w < 4) 1f else 0f }
        val guide = ByteArray(w * h * 3) { (it * 37).toByte() }
        val out = CutoutRefine.bandRefine(guide, coarse, w, h)
        assertArrayEquals(coarse, out, 0f)
    }

    @Test
    fun downsampleAreaAverages() {
        val src = floatArrayOf(0f, 1f, 1f, 1f)
        val out = CutoutRefine.downsampleArea(src, 2, 2, 1, 1)
        assertEquals(191, out[0].toInt() and 0xFF)
        // 不整除：3→2，每格蓋 1.5 個來源像素
        val row = CutoutRefine.downsampleArea(floatArrayOf(0f, 1f, 0f), 3, 1, 2, 1)
        assertEquals(85, row[0].toInt() and 0xFF)
        assertEquals(85, row[1].toInt() and 0xFF)
    }

    @Test
    fun trackerCropsAroundSmallPerson() {
        val gw = 540
        val gh = 960
        val t = CropTracker(gw, gh)
        assertArrayEquals(intArrayOf(0, 0, gw, gh), t.next())
        // 整張裡右下角一個小人（100×200）
        val full = FloatArray(gw * gh)
        for (y in 600 until 800) for (x in 350 until 450) full[y * gw + x] = 1f
        t.update(full, intArrayOf(0, 0, gw, gh))
        val c = t.next()
        assertTrue("裁切框要包住人：${c.toList()}", c[0] <= 350 && c[1] <= 600 && c[0] + c[2] >= 450 && c[1] + c[3] >= 800)
        assertTrue("要比整張小：${c.toList()}", c[2] < gw || c[3] < gh)
        // 人碰到裁切框的邊 → 下一格整張重找
        val inCrop = FloatArray(c[2] * c[3])
        for (y in 0 until c[3]) inCrop[y * c[2]] = 1f
        for (x in 0 until 40) for (y in 0 until 40) inCrop[y * c[2] + x] = 1f
        t.update(inCrop, c)
        assertArrayEquals(intArrayOf(0, 0, gw, gh), t.next())
        // 找不到人 → 整張
        t.update(FloatArray(gw * gh), intArrayOf(0, 0, gw, gh))
        assertArrayEquals(intArrayOf(0, 0, gw, gh), t.next())
    }

    @Test
    fun trackerDoesNotFlipWhenPersonIsCutByFrameEdge() {
        // 小小的人站在畫面下緣（腳被畫面切掉）：裁切框貼著畫面底，不能每格
        // 「碰邊 → 整張 → 裁切」交替
        val gw = 540
        val gh = 960
        val t = CropTracker(gw, gh)
        fun person(box: IntArray): FloatArray {
            val (ox, oy, w, h) = box
            val a = FloatArray(w * h)
            for (y in 780 until 960) for (x in 230 until 310) {
                val cx = x - ox
                val cy = y - oy
                if (cx in 0 until w && cy in 0 until h) a[cy * w + cx] = 1f
            }
            return a
        }
        val seq = mutableListOf<Boolean>()
        repeat(6) {
            val box = t.next()
            seq.add(box[2] == gw && box[3] == gh)
            t.update(person(box), box)
        }
        assertEquals("第一格整張、之後一直裁切：$seq", listOf(true, false, false, false, false, false), seq)
    }

    @Test
    fun probeFindsSomeoneOutsideTheCrop() {
        val gw = 540
        val gh = 960
        val t = CropTracker(gw, gh)
        val full = FloatArray(gw * gh)
        for (y in 600 until 800) for (x in 350 until 450) full[y * gw + x] = 1f
        t.update(full, intArrayOf(0, 0, gw, gh))
        assertTrue(t.cropping)
        // 整張看一眼（54×96 的小圖）：只有框裡那個人 → 照舊裁切
        val pw = 54
        val ph = 96
        val p = FloatArray(pw * ph)
        for (y in 60 until 80) for (x in 35 until 45) p[y * pw + x] = 1f
        t.probe(p, pw, ph)
        assertTrue(t.cropping)
        // 左上角走進來一個人 → 下一格整張
        for (y in 5 until 25) for (x in 3 until 10) p[y * pw + x] = 1f
        t.probe(p, pw, ph)
        assertArrayEquals(intArrayOf(0, 0, gw, gh), t.next())
    }
}
