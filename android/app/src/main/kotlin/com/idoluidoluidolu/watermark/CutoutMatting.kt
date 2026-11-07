package com.idoluidoluidolu.watermark

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/// MODNet 人像 matting（ZHKKKe/MODNet，Apache-2.0；Xenova/modnet 的 fp16 權重
/// ONNX，輸入輸出 fp32，assets/models/modnet_fp16.onnx）。
///
/// 專做半身人像，髮絲（連被風吹起來的）都抓得到——ML Kit 的人像分割整撮切掉。
/// 但全身、人很小時會整塊漏掉（實測跳舞的片子人不見、裁切後頭頂被挖掉），
/// 所以只拿來「補」粗遮罩的邊：一致度夠才用（[iou]），用的時候粗遮罩的核心
/// 一定保留、離人太遠的一律不要（[fuse]）
internal class CutoutMatting(model: ByteArray) : AutoCloseable {
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val session: OrtSession

    init {
        val threads = max(1, min(4, Runtime.getRuntime().availableProcessors()))
        session = OrtSession.SessionOptions().use { opts ->
            opts.setIntraOpNumThreads(threads)
            env.createSession(model, opts)
        }
    }

    /// [rgb]＝RGB 交錯（[w]×[h]）→ 0~1 的 alpha（同大小）。模型輸入：短邊
    /// [short]、長寬都取 32 的倍數（面積平均縮），值換成 (x-0.5)/0.5
    fun matte(rgb: ByteArray, w: Int, h: Int, short: Int = 256): FloatArray {
        val k = short.toDouble() / min(w, h)
        val iw = max(32, (w * k / 32).roundToInt() * 32)
        val ih = max(32, (h * k / 32).roundToInt() * 32)
        val input = FloatArray(3 * iw * ih)
        val plane = iw * ih
        val sx = w.toDouble() / iw
        val sy = h.toDouble() / ih
        for (oy in 0 until ih) {
            val y0 = (oy * sy).toInt()
            val y1 = max(y0 + 1, min(h, kotlin.math.ceil((oy + 1) * sy).toInt()))
            for (ox in 0 until iw) {
                val x0 = (ox * sx).toInt()
                val x1 = max(x0 + 1, min(w, kotlin.math.ceil((ox + 1) * sx).toInt()))
                var r = 0
                var g = 0
                var b = 0
                for (y in y0 until y1) {
                    for (x in x0 until x1) {
                        val i = (y * w + x) * 3
                        r += rgb[i].toInt() and 0xFF
                        g += rgb[i + 1].toInt() and 0xFF
                        b += rgb[i + 2].toInt() and 0xFF
                    }
                }
                val n = ((y1 - y0) * (x1 - x0)).toFloat()
                val o = oy * iw + ox
                input[o] = (r / n / 255f - 0.5f) / 0.5f
                input[plane + o] = (g / n / 255f - 0.5f) / 0.5f
                input[2 * plane + o] = (b / n / 255f - 0.5f) / 0.5f
            }
        }
        val shape = longArrayOf(1, 3, ih.toLong(), iw.toLong())
        OnnxTensor.createTensor(env, FloatBuffer.wrap(input), shape).use { t ->
            session.run(mapOf(session.inputNames.first() to t)).use { res ->
                val buf = (res[0] as OnnxTensor).floatBuffer
                val out = FloatArray(plane)
                buf.get(out, 0, min(plane, buf.remaining()))
                for (i in out.indices) out[i] = out[i].coerceIn(0f, 1f)
                return CutoutRefine.upscaleBilinear(out, iw, ih, w, h)
            }
        }
    }

    override fun close() {
        session.close()
    }

    companion object {
        /// BiRefNet-lite（照片精修，MIT；模型用到才下載）：[rgb]（RGB 交錯
        /// [w]×[h]）面積平均縮成 1024×1024、ImageNet 正規化 → logits 過 sigmoid →
        /// 放大回 [w]×[h] 的 0~1 matte
        fun birefnet(
            env: OrtEnvironment,
            session: OrtSession,
            rgb: ByteArray,
            w: Int,
            h: Int,
        ): FloatArray {
            val s = 1024
            val plane = s * s
            val input = FloatArray(3 * plane)
            val mean = floatArrayOf(0.485f, 0.456f, 0.406f)
            val std = floatArrayOf(0.229f, 0.224f, 0.225f)
            val sx = w.toDouble() / s
            val sy = h.toDouble() / s
            for (oy in 0 until s) {
                val y0 = (oy * sy).toInt()
                val y1 = max(y0 + 1, min(h, kotlin.math.ceil((oy + 1) * sy).toInt()))
                for (ox in 0 until s) {
                    val x0 = (ox * sx).toInt()
                    val x1 = max(x0 + 1, min(w, kotlin.math.ceil((ox + 1) * sx).toInt()))
                    var r = 0
                    var g = 0
                    var b = 0
                    for (y in y0 until y1) {
                        for (x in x0 until x1) {
                            val i = (y * w + x) * 3
                            r += rgb[i].toInt() and 0xFF
                            g += rgb[i + 1].toInt() and 0xFF
                            b += rgb[i + 2].toInt() and 0xFF
                        }
                    }
                    val n = ((y1 - y0) * (x1 - x0)) * 255f
                    val o = oy * s + ox
                    input[o] = (r / n - mean[0]) / std[0]
                    input[plane + o] = (g / n - mean[1]) / std[1]
                    input[2 * plane + o] = (b / n - mean[2]) / std[2]
                }
            }
            val shape = longArrayOf(1, 3, s.toLong(), s.toLong())
            val out = FloatArray(plane)
            OnnxTensor.createTensor(env, FloatBuffer.wrap(input), shape).use { t ->
                session.run(mapOf(session.inputNames.first() to t)).use { res ->
                    val buf = (res[0] as OnnxTensor).floatBuffer
                    buf.get(out, 0, min(plane, buf.remaining()))
                }
            }
            // 輸出是 logits
            for (i in out.indices) out[i] = (1.0 / (1.0 + kotlin.math.exp(-out[i].toDouble()))).toFloat()
            return CutoutRefine.upscaleBilinear(out, s, s, w, h)
        }

        /// 兩張遮罩「是人」（≥0.5）的 IoU；兩張都沒有人回 0
        fun iou(a: FloatArray, b: FloatArray): Double {
            var inter = 0
            var union = 0
            for (i in a.indices) {
                val pa = a[i] >= 0.5f
                val pb = b[i] >= 0.5f
                if (pa && pb) inter++
                if (pa || pb) union++
            }
            return if (union == 0) 0.0 else inter.toDouble() / union
        }

        /// 粗遮罩＋MODNet 的 matte：粗遮罩「是人」的區域往內縮 [core] 像素＝核心，
        /// 一定是 1；往外擴 [reach] 像素以外一定是 0（MODNet 在離人很遠的地方說
        /// 有東西也不要）；中間這一圈照 MODNet（髮絲、邊緣的半透明）
        fun fuse(
            coarse: FloatArray,
            matte: FloatArray,
            w: Int,
            h: Int,
            core: Int,
            reach: Int,
        ): FloatArray {
            val inside = BooleanArray(w * h) { coarse[it] >= 0.5f }
            val dIn = chamfer(inside, w, h)
            val outside = BooleanArray(w * h) { !inside[it] }
            val dOut = chamfer(outside, w, h)
            val coreD = core * 3
            val reachD = reach * 3
            return FloatArray(w * h) { i ->
                when {
                    inside[i] && dIn[i] > coreD -> 1f
                    inside[i] -> matte[i]
                    dOut[i] <= reachD -> matte[i]
                    else -> 0f
                }
            }
        }

        /// chamfer 3-4 距離轉換：[on] 的每一點到最近一個「不是 on」的點的距離
        ///（×3，約等於像素數×3）；不是 on 的點是 0。整張都是 on 回很大的值
        fun chamfer(on: BooleanArray, w: Int, h: Int): IntArray {
            val inf = Int.MAX_VALUE / 4
            val d = IntArray(w * h) { if (on[it]) inf else 0 }
            for (y in 0 until h) {
                for (x in 0 until w) {
                    val i = y * w + x
                    if (d[i] == 0) continue
                    var v = d[i]
                    if (x > 0) v = min(v, d[i - 1] + 3)
                    if (y > 0) {
                        v = min(v, d[i - w] + 3)
                        if (x > 0) v = min(v, d[i - w - 1] + 4)
                        if (x < w - 1) v = min(v, d[i - w + 1] + 4)
                    }
                    d[i] = v
                }
            }
            for (y in h - 1 downTo 0) {
                for (x in w - 1 downTo 0) {
                    val i = y * w + x
                    if (d[i] == 0) continue
                    var v = d[i]
                    if (x < w - 1) v = min(v, d[i + 1] + 3)
                    if (y < h - 1) {
                        v = min(v, d[i + w] + 3)
                        if (x < w - 1) v = min(v, d[i + w + 1] + 4)
                        if (x > 0) v = min(v, d[i + w - 1] + 4)
                    }
                    d[i] = v
                }
            }
            return d
        }
    }
}
