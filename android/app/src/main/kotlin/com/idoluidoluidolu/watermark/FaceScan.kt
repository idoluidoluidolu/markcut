package com.idoluidoluidolu.watermark

import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt
import kotlin.math.sqrt

// 11-07 使用者：安卓馬賽克「偵測不靈敏」。以前影片整張丟快速模式、臉寬要有
// 畫面寬的 5% 才找；ML Kit 官方也說每張臉最好有 100×100 像素——直拍 1080p
// 裡稍微遠一點的臉只有幾十像素，就漏了。現在三招一起上：
//   整張：精準模式、臉寬 3% 就找
//   補找：認得的臉這一格沒找到，在它附近裁一塊、放大到臉約 128 像素再找
//   切塊：畫面切 2×2（每塊六成、互相疊一點）放大 1.5 倍找遠處的小臉
// 影片的排程見 [VideoFaceFollower]；照片整張＋切塊見 [FaceScanner.scanBitmap]

/// 找到的一張臉：轉正後的畫面座標（0~1、左上原點）＋哪一招找到的
internal class FaceHit(
    val x: Double,
    val y: Double,
    val w: Double,
    val h: Double,
    val src: Int,
) {
    val cx: Double get() = x + w / 2
    val cy: Double get() = y + h / 2
    val area: Double get() = w * h

    companion object {
        /// 整張找到的
        const val FULL = 0

        /// 補找：前面看過、這一格整張沒找到，在附近裁一塊放大才找到的
        const val FOLLOW = 1

        /// 切塊放大找到的（合照、遠處的小臉）
        const val TILE = 2
    }
}

/// 找臉用的幾何：跟 ML Kit 無關、可以單獨驗算的部分
internal object FaceGeom {
    /// 交集÷聯集
    fun iou(a: FaceHit, b: FaceHit): Double {
        val l = maxOf(a.x, b.x)
        val t = maxOf(a.y, b.y)
        val r = minOf(a.x + a.w, b.x + b.w)
        val btm = minOf(a.y + a.h, b.y + b.h)
        if (r <= l || btm <= t) return 0.0
        val inter = (r - l) * (btm - t)
        val union = a.area + b.area - inter
        return if (union <= 0.0) 0.0 else inter / union
    }

    private fun contains(f: FaceHit, px: Double, py: Double): Boolean =
        px >= f.x && px <= f.x + f.w && py >= f.y && py <= f.y + f.h

    /// 同一張臉（兩招都找到、或相鄰兩塊都切到）：重疊夠多，或一個的中心
    /// 落在另一個框裡
    fun sameFace(a: FaceHit, b: FaceHit): Boolean =
        iou(a, b) >= 0.3 || contains(b, a.cx, a.cy) || contains(a, b.cx, b.cy)

    /// 前後兩格是不是同一個人（跟 Dart buildFaceTracks 的 _matchScore 同一套）：
    /// 0＝不是；越大越像
    fun matchScore(a: FaceHit, b: FaceHit): Double {
        val o = iou(a, b)
        if (o >= 0.15) return 1 + o
        if (a.area <= 0.0 || b.area <= 0.0) return 0.0
        val ratio = a.area / b.area
        if (ratio > 4 || ratio < 0.25) return 0.0
        val dx = a.cx - b.cx
        val dy = a.cy - b.cy
        val dist = sqrt(dx * dx + dy * dy)
        val size = maxOf(maxOf(a.w, a.h), maxOf(b.w, b.h))
        return if (dist < size) 1 - dist / size else 0.0
    }

    /// 放進 [list]：已經有同一張臉就不放——除非兩個都是切塊找到的、新的比較大
    ///（卡在接縫被切掉一截的框比較小，換成完整的那個）。回 true＝多了一張
    fun addOrMerge(list: MutableList<FaceHit>, f: FaceHit): Boolean {
        for (i in list.indices) {
            val e = list[i]
            if (!sameFace(e, f)) continue
            if (e.src == FaceHit.TILE && f.src == FaceHit.TILE && f.area > e.area) list[i] = f
            return false
        }
        list.add(f)
        return true
    }

    /// 切塊：每邊 [n] 塊、每塊佔 [frac]，相鄰兩塊疊（frac − 間距）那麼寬——
    /// 卡在接縫上、寬度不超過重疊的臉，至少整張落在其中一塊裡。
    /// 回轉正後的 0~1 範圍 [x0, y0, x1, y1]
    fun tiles(n: Int, frac: Double): List<DoubleArray> {
        val step = if (n <= 1) 0.0 else (1.0 - frac) / (n - 1)
        val out = ArrayList<DoubleArray>()
        for (j in 0 until n) {
            for (i in 0 until n) {
                val x0 = i * step
                val y0 = j * step
                out.add(doubleArrayOf(x0, y0, x0 + frac, y0 + frac))
            }
        }
        return out
    }

    /// 解碼器的一格（NV21，[w]×[h]，顯示時要順時針轉 [rot] 度）裡，轉正後的
    /// 這一塊（轉正後的像素座標 [ux0, ux1)×[uy0, uy1)）取樣成 [ow]×[oh] 的
    /// ARGB 點陣：裁切、轉正、縮放一步做完
    fun sampleUpright(
        nv21: ByteArray,
        w: Int,
        h: Int,
        rot: Int,
        ux0: Double,
        uy0: Double,
        ux1: Double,
        uy1: Double,
        ow: Int,
        oh: Int,
    ): Bitmap = Bitmap.createBitmap(
        sampleUprightPixels(nv21, w, h, rot, ux0, uy0, ux1, uy1, ow, oh),
        ow,
        oh,
        Bitmap.Config.ARGB_8888,
    )

    /// [sampleUpright] 的像素（ARGB，一列接一列）。亮度雙線性（放大才不會
    /// 一格一格的，ML Kit 認不出方塊臉）、顏色取最近的那一組。
    /// 轉正後的點 (ux, uy) 回到格子裡的 (sx, sy)（連續座標，像素中心在 +0.5；
    /// 跟去背的 yuvToUpright 同一套方向）：
    ///   90°：sx = uy、sy = h − ux；180°：sx = w − ux、sy = h − uy；
    ///   270°：sx = w − uy、sy = ux
    fun sampleUprightPixels(
        nv21: ByteArray,
        w: Int,
        h: Int,
        rot: Int,
        ux0: Double,
        uy0: Double,
        ux1: Double,
        uy1: Double,
        ow: Int,
        oh: Int,
    ): IntArray {
        // sx = m0·ux + m1·uy + m2、sy = m3·ux + m4·uy + m5
        val m = when (rot) {
            90 -> doubleArrayOf(0.0, 1.0, 0.0, -1.0, 0.0, h.toDouble())
            180 -> doubleArrayOf(-1.0, 0.0, w.toDouble(), 0.0, -1.0, h.toDouble())
            270 -> doubleArrayOf(0.0, -1.0, w.toDouble(), 1.0, 0.0, 0.0)
            else -> doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0)
        }
        val px = IntArray(ow * oh)
        val kx = (ux1 - ux0) / ow
        val ky = (uy1 - uy0) / oh
        val maxX = (w - 1).toDouble()
        val maxY = (h - 1).toDouble()
        val cBase = w * h
        for (oy in 0 until oh) {
            val uy = uy0 + (oy + 0.5) * ky
            for (ox in 0 until ow) {
                val ux = ux0 + (ox + 0.5) * kx
                val sx = m[0] * ux + m[1] * uy + m[2]
                val sy = m[3] * ux + m[4] * uy + m[5]
                val fx = (sx - 0.5).coerceIn(0.0, maxX)
                val fy = (sy - 0.5).coerceIn(0.0, maxY)
                val x0 = fx.toInt()
                val y0 = fy.toInt()
                val x1 = if (x0 + 1 < w) x0 + 1 else x0
                val y1 = if (y0 + 1 < h) y0 + 1 else y0
                val ax = fx - x0
                val ay = fy - y0
                val r0 = y0 * w
                val r1 = y1 * w
                val p00 = nv21[r0 + x0].toInt() and 0xFF
                val p10 = nv21[r0 + x1].toInt() and 0xFF
                val p01 = nv21[r1 + x0].toInt() and 0xFF
                val p11 = nv21[r1 + x1].toInt() and 0xFF
                val top = p00 + (p10 - p00) * ax
                val bot = p01 + (p11 - p01) * ax
                val yy = (top + (bot - top) * ay + 0.5).toInt()
                // NV21：亮度整片之後 V、U 交錯，2×2 個像素共用一組
                val nx = minOf((fx + 0.5).toInt(), w - 1)
                val ny = minOf((fy + 0.5).toInt(), h - 1)
                val ci = cBase + (ny shr 1) * w + (nx shr 1) * 2
                val v = (nv21[ci].toInt() and 0xFF) - 128
                val u = (nv21[ci + 1].toInt() and 0xFF) - 128
                // BT.601（找人用的，色準不重要；同去背那條）
                val c = (yy - 16).coerceAtLeast(0) * 1192
                val r = ((c + 1634 * v) shr 10).coerceIn(0, 255)
                val g = ((c - 833 * v - 400 * u) shr 10).coerceIn(0, 255)
                val b = ((c + 2066 * u) shr 10).coerceIn(0, 255)
                px[oy * ow + ox] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        return px
    }
}

/// 兩個偵測器＋照片、影片共用的找法。只在找臉的工作緒上用；用完要 [close]
internal class FaceScanner : AutoCloseable {
    /// 整張、切塊：精準模式，臉寬只要畫面寬的 3%
    private val wide: FaceDetector = FaceDetection.getClient(
        FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
            .setMinFaceSize(0.03f)
            .build(),
    )

    /// 補找（裁出來的那塊，臉約佔三分之一）：精準模式、最小臉照預設 0.1。
    /// 只有影片用得到，用到才建
    private val nearLazy = lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                .build(),
        )
    }

    /// 花在 ML Kit 的毫秒、叫了幾次（流水帳：精準模式比較慢，實機看值不值得）
    var detectMs = 0L
        private set
    var detectCalls = 0
        private set

    /// 照片切塊丟例外的次數、第一個例外（整張的結果照樣回）
    var extraFailed = 0
        private set
    var firstExtraError: String? = null
        private set

    private fun run(d: FaceDetector, img: InputImage, timeoutSec: Long): List<Face> {
        val t0 = SystemClock.elapsedRealtime()
        try {
            return Tasks.await(d.process(img), timeoutSec, TimeUnit.SECONDS)
        } finally {
            detectMs += SystemClock.elapsedRealtime() - t0
            detectCalls++
        }
    }

    /// [run] 一張自己建的點陣，正常回來才收掉。逾時、出事就留給 GC：
    /// ML Kit 那邊可能還在讀它，先收掉會讓它讀到收掉的點陣
    private fun runOwned(d: FaceDetector, bmp: Bitmap, timeoutSec: Long): List<Face> {
        val faces = run(d, InputImage.fromBitmap(bmp, 0), timeoutSec)
        bmp.recycle()
        return faces
    }

    /// ML Kit 的框（送進去那張圖的像素）→ 轉正後畫面的 0~1。那張圖是從轉正後
    /// 的 ([x0], [y0]) 裁起、每個像素等於轉正後的 [kx]×[ky] 個像素
    private fun hit(
        f: Face,
        x0: Double,
        y0: Double,
        kx: Double,
        ky: Double,
        uw: Double,
        uh: Double,
        src: Int,
    ): FaceHit {
        val b = f.boundingBox
        return FaceHit(
            (x0 + b.left * kx) / uw,
            (y0 + b.top * ky) / uh,
            b.width() * kx / uw,
            b.height() * ky / uh,
            src,
        )
    }

    private fun tileScale(tw: Double, th: Double): Double =
        minOf(TILE_UPSCALE, TILE_MAX_SIDE / maxOf(tw, th))

    /// 一張已轉正的照片：整張找一次，再切 2×2 放大找小臉（合照）。
    /// 整張那次出事照樣丟出去（呼叫端報原因）；切塊出事只記下來
    fun scanBitmap(bmp: Bitmap): List<FaceHit> {
        val uw = bmp.width.toDouble()
        val uh = bmp.height.toDouble()
        val out = ArrayList<FaceHit>()
        // 整張那次 ML Kit 自己去過重，全收（兩個人靠很近也不能被併成一個）
        for (f in run(wide, InputImage.fromBitmap(bmp, 0), 30)) {
            out.add(hit(f, 0.0, 0.0, 1.0, 1.0, uw, uh, FaceHit.FULL))
        }
        try {
            for (t in FaceGeom.tiles(TILE_N, TILE_FRAC)) {
                val x0 = (t[0] * uw).toInt()
                val y0 = (t[1] * uh).toInt()
                val tw = minOf((t[2] * uw).toInt(), bmp.width) - x0
                val th = minOf((t[3] * uh).toInt(), bmp.height) - y0
                if (tw < 32 || th < 32) continue
                val s = tileScale(tw.toDouble(), th.toDouble()).toFloat()
                val m = Matrix()
                m.setScale(s, s)
                val tile = Bitmap.createBitmap(bmp, x0, y0, tw, th, m, true)
                val kx = tw.toDouble() / tile.width
                val ky = th.toDouble() / tile.height
                // createBitmap 可能直接回原圖（理論上，六成的塊不會）：原圖不能收
                val faces = if (tile === bmp) {
                    run(wide, InputImage.fromBitmap(tile, 0), 30)
                } else {
                    runOwned(wide, tile, 30)
                }
                for (f in faces) {
                    FaceGeom.addOrMerge(
                        out,
                        hit(f, x0.toDouble(), y0.toDouble(), kx, ky, uw, uh, FaceHit.TILE),
                    )
                }
            }
        } catch (e: Throwable) {
            extraFailed++
            if (firstExtraError == null) firstExtraError = "${e.javaClass.simpleName}: ${e.message ?: ""}"
        }
        return out
    }

    /// 影片一格（NV21、顯示時順時針轉 [rot] 度）整張找
    fun frameFull(nv21: ByteArray, w: Int, h: Int, rot: Int): List<FaceHit> {
        val uw = (if (rot % 180 == 0) w else h).toDouble()
        val uh = (if (rot % 180 == 0) h else w).toDouble()
        val faces = run(
            wide,
            InputImage.fromByteArray(nv21, w, h, rot, InputImage.IMAGE_FORMAT_NV21),
            10,
        )
        // ML Kit 的框在「轉正後」的座標：90°／270° 寬高對調（uw、uh 已經換過）
        return faces.map { hit(it, 0.0, 0.0, 1.0, 1.0, uw, uh, FaceHit.FULL) }
    }

    /// 影片一格切 2×2、每塊放大找小臉，放進 [into]（同一張臉不重複）。回多了幾張
    fun frameTiles(nv21: ByteArray, w: Int, h: Int, rot: Int, into: MutableList<FaceHit>): Int {
        val uw = (if (rot % 180 == 0) w else h).toDouble()
        val uh = (if (rot % 180 == 0) h else w).toDouble()
        var added = 0
        for (t in FaceGeom.tiles(TILE_N, TILE_FRAC)) {
            val x0 = t[0] * uw
            val y0 = t[1] * uh
            val tw = (t[2] - t[0]) * uw
            val th = (t[3] - t[1]) * uh
            val s = tileScale(tw, th)
            val ow = (tw * s).roundToInt().coerceAtLeast(32)
            val oh = (th * s).roundToInt().coerceAtLeast(32)
            val bmp = FaceGeom.sampleUpright(nv21, w, h, rot, x0, y0, x0 + tw, y0 + th, ow, oh)
            val faces = runOwned(wide, bmp, 10)
            for (f in faces) {
                val c = hit(f, x0, y0, tw / ow, th / oh, uw, uh, FaceHit.TILE)
                if (FaceGeom.addOrMerge(into, c)) added++
            }
        }
        return added
    }

    /// 補找：[prev] 是 [dt] 秒前最後一次看到這張臉的位置。在它附近裁一塊
    /// 正方形（臉寬的 3 倍，隔越久裁越大），放大到臉約 128 像素，用補找的
    /// 偵測器找；裡面最靠近上次位置、大小差不到 4 倍的那張就是它。沒有回 null
    fun frameFollow(nv21: ByteArray, w: Int, h: Int, rot: Int, prev: FaceHit, dt: Double): FaceHit? {
        if (prev.area <= 0.0) return null
        val uw = (if (rot % 180 == 0) w else h).toDouble()
        val uh = (if (rot % 180 == 0) h else w).toDouble()
        val face = maxOf(prev.w * uw, prev.h * uh)
        val side = minOf(face * (3.0 + 2.0 * dt.coerceIn(0.0, 1.0)), minOf(uw, uh))
        if (side < 16.0) return null
        val x0 = (prev.cx * uw - side / 2).coerceIn(0.0, uw - side)
        val y0 = (prev.cy * uh - side / 2).coerceIn(0.0, uh - side)
        val out = (side * (FOLLOW_SIDE / side).coerceIn(0.5, 4.0)).roundToInt().coerceAtLeast(32)
        val bmp = FaceGeom.sampleUpright(nv21, w, h, rot, x0, y0, x0 + side, y0 + side, out, out)
        val faces = runOwned(nearLazy.value, bmp, 10)
        val k = side / out
        var best: FaceHit? = null
        var bestD = Double.MAX_VALUE
        for (f in faces) {
            val c = hit(f, x0, y0, k, k, uw, uh, FaceHit.FOLLOW)
            val ratio = c.area / prev.area
            if (ratio > 4 || ratio < 0.25) continue
            val dx = c.cx - prev.cx
            val dy = c.cy - prev.cy
            val d = dx * dx + dy * dy
            if (d < bestD) {
                bestD = d
                best = c
            }
        }
        return best
    }

    override fun close() {
        try {
            wide.close()
        } catch (_: Throwable) {}
        if (nearLazy.isInitialized()) {
            try {
                nearLazy.value.close()
            } catch (_: Throwable) {}
        }
    }

    companion object {
        /// 切塊：每邊 2 塊、每塊佔六成（中間疊兩成）
        const val TILE_N = 2
        const val TILE_FRAC = 0.6

        /// 切出來的那塊放大幾倍、放大後長邊最多幾像素（ML Kit 每張臉最好有
        /// 100 像素；再大只是慢）
        const val TILE_UPSCALE = 1.5
        const val TILE_MAX_SIDE = 1920.0

        /// 補找裁的那塊放大到幾像素（臉約佔三分之一＝128 像素）
        const val FOLLOW_SIDE = 384.0
    }
}

/// 影片逐格找臉的排程與記憶（每一格 [scan] 一次，時間要由小到大）：
///   - 整張每兩格一次（Dart 每秒要 10 格＝整張每秒 5 次）：精準模式比快速
///     模式慢，隔一格省一半；中間那格靠補找跟住認得的臉
///   - 切塊每 0.8 秒一次（第一格也做）：遠處的小臉。間隔要小於 Dart 那邊
///     buildFaceTracks 的 maxGap（1 秒）：只有切塊找得到的臉才不會被拆成
///     一格一段、又被當成誤判丟掉
///   - 補找每一格：最近 1.2 秒內看過、這一格沒配到的臉（見 [canFollow]）
/// 切塊、補找出事只記下來，不影響整張的結果（新招不能讓舊的變差）
internal class VideoFaceFollower(private val scanner: FaceScanner) {
    /// 認得的一張臉：最後看到的位置與時間。[confirms]／[confirmedT]＝被整張或
    /// 切塊找到的次數、最後一次（補找找到的不算）。只會從整張／切塊新找到
    /// 的臉建出來，所以一建好就算一次
    private class Seen(var face: FaceHit, var t: Double) {
        var confirms = 1
        var confirmedT = t
    }

    private val seen = ArrayList<Seen>()
    private var lastTileT = Double.NEGATIVE_INFINITY
    private var n = 0

    /// 上一次整張丟例外：下一格補跑整張。一直出事就每一格都出事，呼叫端
    /// 「每一格都找不了＝整支走不通」才判得出來（不然奇數格只跑補找、
    /// 永遠算成功，整支只會說找不到臉）
    private var fullFailed = false

    /// 切塊或補找丟例外的次數、第一個例外（流水帳）
    var extraFailed = 0
        private set
    var firstExtraError: String? = null
        private set

    private fun note(e: Throwable) {
        extraFailed++
        if (firstExtraError == null) firstExtraError = "${e.javaClass.simpleName}: ${e.message ?: ""}"
    }

    /// 還要不要補找：最近 [FOLLOW_FOR] 秒內看過；而且被整張／切塊找到過兩次
    /// 以上，或最後一次被它們找到在 [FOLLOW_FOR] 秒內。只被找到一次的（可能是
    /// 誤判）最多撐 [FOLLOW_FOR] 秒，不能靠補找一路自己延續下去；認定是臉
    /// 的，側過去、整張找不到也一直跟著
    private fun canFollow(s: Seen, t: Double): Boolean =
        t - s.t <= FOLLOW_FOR && (s.confirms >= 2 || t - s.confirmedT <= FOLLOW_FOR)

    private class Cand(val score: Double, val hit: FaceHit, val s: Seen)

    /// 這一格的框（整張、切塊）配給認得的臉：所有「框×臉」照像的程度排，
    /// 像的先配、一個配一個（同 Dart buildFaceTracks）。合照臉挨著臉時，
    /// 旁邊那張不會把漏掉的這張頂掉，漏掉的才補找得到
    private fun pairUp(hits: List<FaceHit>): HashMap<FaceHit, Seen> {
        val cands = ArrayList<Cand>()
        for (f in hits) {
            for (s in seen) {
                val sc = FaceGeom.matchScore(f, s.face)
                if (sc > 0.0) cands.add(Cand(sc, f, s))
            }
        }
        cands.sortByDescending { it.score }
        val out = HashMap<FaceHit, Seen>()
        val used = HashSet<Seen>()
        for (c in cands) {
            if (out.containsKey(c.hit) || c.s in used) continue
            out[c.hit] = c.s
            used.add(c.s)
        }
        return out
    }

    /// 這一格（素材秒 [t]）的臉。整張那次丟的例外照樣丟出去（呼叫端算這格失敗）
    fun scan(nv21: ByteArray, w: Int, h: Int, rot: Int, t: Double): List<FaceHit> {
        val hits = ArrayList<FaceHit>()
        if (n++ % 2 == 0 || fullFailed) {
            // 整張那次 ML Kit 自己去過重，全收；之後的切塊、補找才跟它比
            fullFailed = true
            hits.addAll(scanner.frameFull(nv21, w, h, rot))
            fullFailed = false
        }
        if (t - lastTileT >= TILE_EVERY) {
            lastTileT = t
            try {
                scanner.frameTiles(nv21, w, h, rot, hits)
            } catch (e: Throwable) {
                note(e)
            }
        }
        val pair = pairUp(hits)
        val taken = HashSet<Seen>(pair.values)
        // 補找：最近看過、這一格沒配到的。找到的直接算那一張的（動得多也
        // 不會多出一張重複的）
        for (s in seen) {
            if (s in taken || !canFollow(s, t)) continue
            try {
                val f = scanner.frameFollow(nv21, w, h, rot, s.face, t - s.t) ?: continue
                val dup = hits.firstOrNull { FaceGeom.sameFace(it, f) }
                if (dup == null) {
                    hits.add(f)
                    pair[f] = s
                    taken.add(s)
                } else if (!pair.containsKey(dup)) {
                    // 整張／切塊其實找到了，只是動得多、沒配上：就是它
                    pair[dup] = s
                    taken.add(s)
                }
            } catch (e: Throwable) {
                note(e)
            }
        }
        // 記住這一格的臉：配到的更新位置，沒配到的（整張／切塊新找到的）當新的一張
        for (f in hits) {
            val s = pair[f]
            if (s == null) {
                seen.add(Seen(f, t))
            } else {
                s.face = f
                s.t = t
                if (f.src != FaceHit.FOLLOW) {
                    s.confirms++
                    s.confirmedT = t
                }
            }
        }
        seen.removeAll { t - it.t > FOLLOW_FOR }
        return hits
    }

    companion object {
        const val TILE_EVERY = 0.8
        const val FOLLOW_FOR = 1.2
    }
}
