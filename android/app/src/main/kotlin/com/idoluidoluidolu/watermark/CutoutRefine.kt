package com.idoluidoluidolu.watermark

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/// 去背遮罩的後製（影片逐格用；iOS 那份在 AppDelegate.swift 的 MCCutoutRefine，
/// 兩邊照同一份參考實作寫、同一組測試向量驗）：
///
/// - [bandRefine]：模型給的粗遮罩只在「模糊的那一圈」（0.05~0.95）裡，拿原畫面
///   當導引做彩色導引濾波（He et al.），邊緣貼齊真正的輪廓；確定是人／背景的
///   地方不動（導引濾波在紋理區會把背景花紋抄進遮罩，所以只修那一圈）
/// - [CropTracker]：人在畫面裡很小時，裁一塊正方形給模型（256 格全部花在人身上）
/// - [ofd]：一格延遲防閃——前後兩格一致、中間那格跳掉，換成前後平均
/// - [downsampleArea]：導引解析度 → 存檔解析度（面積平均）
internal object CutoutRefine {
    /// 粗遮罩「確定」的門檻：0.05 以下算背景、0.95 以上算人，中間才修
    const val LO = 0.05f

    /// 導引濾波的 box 平均：視窗 (2r+1)²，邊界只平均「實際存在」的像素
    /// （不補值）。先橫再直，[tmp] 是同大小的暫存。直向用「一整列的欄和」往下
    /// 滑（記憶體循序讀，比一欄一欄往下快很多）
    fun boxMean(
        src: FloatArray,
        w: Int,
        h: Int,
        r: Int,
        tmp: FloatArray,
        dst: FloatArray,
        colSum: DoubleArray = DoubleArray(w),
        invCx: FloatArray = invCounts(w, r),
    ) {
        // 橫向：每列滑動視窗的和
        for (y in 0 until h) {
            val row = y * w
            var s = 0.0
            for (x in 0..min(r, w - 1)) s += src[row + x]
            for (x in 0 until w) {
                tmp[row + x] = s.toFloat()
                val add = x + r + 1
                if (add < w) s += src[row + add]
                val sub = x - r
                if (sub >= 0) s -= src[row + sub]
            }
        }
        // 直向：欄和陣列往下滑，順便除以實際格數
        java.util.Arrays.fill(colSum, 0, w, 0.0)
        for (y in 0..min(r, h - 1)) {
            val row = y * w
            for (x in 0 until w) colSum[x] += tmp[row + x]
        }
        for (y in 0 until h) {
            val cy = (min(h - 1, y + r) - max(0, y - r) + 1).toFloat()
            val inv = 1f / cy
            val row = y * w
            for (x in 0 until w) dst[row + x] = colSum[x].toFloat() * invCx[x] * inv
            val add = y + r + 1
            if (add < h) {
                val ar = add * w
                for (x in 0 until w) colSum[x] += tmp[ar + x]
            }
            val sub = y - r
            if (sub >= 0) {
                val sr = sub * w
                for (x in 0 until w) colSum[x] -= tmp[sr + x]
            }
        }
    }

    /// 橫向每個位置實際涵蓋幾格的倒數
    fun invCounts(w: Int, r: Int): FloatArray =
        FloatArray(w) { x -> 1f / (min(w - 1, x + r) - max(0, x - r) + 1) }

    /// [bandRefine] 的暫存（一支影片逐格重複用，不要每格配幾十 MB）
    class Workspace {
        var cap = 0
        var bufs: Array<FloatArray> = emptyArray()
        var col = DoubleArray(0)

        fun ensure(n: Int, w: Int) {
            if (n > cap) {
                cap = n
                bufs = Array(21) { FloatArray(n) }
            }
            if (col.size < w) col = DoubleArray(w)
        }
    }

    /// 邊帶權重：帶（LO < a < 1-LO）做 [1,2,1]/4 的 3×3 平滑，邊界取最近的像素
    fun bandWeight(p: FloatArray, w: Int, h: Int): FloatArray {
        val t = FloatArray(w * h)
        for (i in 0 until w * h) {
            val v = p[i]
            t[i] = if (v > LO && v < 1f - LO) 1f else 0f
        }
        val hz = FloatArray(w * h)
        for (y in 0 until h) {
            val row = y * w
            for (x in 0 until w) {
                val l = t[row + max(0, x - 1)]
                val c = t[row + x]
                val r = t[row + min(w - 1, x + 1)]
                hz[row + x] = (l + 2f * c + r) * 0.25f
            }
        }
        val out = FloatArray(w * h)
        for (y in 0 until h) {
            val up = max(0, y - 1) * w
            val c = y * w
            val dn = min(h - 1, y + 1) * w
            for (x in 0 until w) {
                out[c + x] = (hz[up + x] + 2f * hz[c + x] + hz[dn + x]) * 0.25f
            }
        }
        return out
    }

    /// 邊帶導引濾波。[guide]＝RGB 交錯（w×h×3）、[coarse]＝0~1。回傳新的遮罩
    /// （0~1，同大小）
    fun bandRefine(
        guide: ByteArray,
        coarse: FloatArray,
        w: Int,
        h: Int,
        r: Int = 2,
        eps: Float = 1e-3f,
        ws: Workspace = Workspace(),
    ): FloatArray {
        require(guide.size >= w * h * 3 && coarse.size >= w * h) { "大小不對" }
        val out = coarse.copyOf(w * h)
        val wgt = bandWeight(coarse, w, h)
        var x0 = Int.MAX_VALUE
        var y0 = Int.MAX_VALUE
        var x1 = -1
        var y1 = -1
        for (y in 0 until h) {
            for (x in 0 until w) {
                if (wgt[y * w + x] <= 0f) continue
                if (x < x0) x0 = x
                if (x > x1) x1 = x
                if (y < y0) y0 = y
                if (y > y1) y1 = y
            }
        }
        if (x1 < 0) return out
        val m = 2 * r + 1
        x0 = max(0, x0 - m)
        y0 = max(0, y0 - m)
        x1 = min(w, x1 + 1 + m)
        y1 = min(h, y1 + 1 + m)
        // 邊帶只是人周圍細細一圈：外框切成一條條橫帶，每條只算有邊帶的那幾段
        // （往外多算 2r：裡面每一點用到的鄰居都算得到，結果跟整塊一起算一模
        // 一樣；外框邊界跟參考實作一樣是「影像邊界」）
        val strip = 24
        val pad = 2 * r
        var ys = y0
        while (ys < y1) {
            val ye = min(y1, ys + strip)
            var x = x0
            while (x < x1) {
                // 找下一段有邊帶的欄
                var xs = -1
                while (x < x1) {
                    var any = false
                    for (y in ys until ye) if (wgt[y * w + x] > 0f) { any = true; break }
                    if (any) { xs = x; break }
                    x++
                }
                if (xs < 0) break
                var xe = xs + 1
                var gap = 0
                x = xs + 1
                while (x < x1) {
                    var any = false
                    for (y in ys until ye) if (wgt[y * w + x] > 0f) { any = true; break }
                    if (any) {
                        xe = x + 1
                        gap = 0
                    } else if (++gap > 2 * pad + 2) {
                        break
                    }
                    x++
                }
                refineRect(
                    guide, coarse, w, wgt, out, r, eps, ws,
                    max(x0, xs - pad), max(y0, ys - pad), min(x1, xe + pad), min(y1, ye + pad),
                    xs, ys, xe, ye,
                )
                x = xe
            }
            ys = ye
        }
        return out
    }

    /// 在子矩形 [rx0,ry0)-(rx1,ry1) 上算導引濾波，只寫回內框 [ix0,iy0)-(ix1,iy1)
    /// 裡有邊帶的點。子矩形切在外框裡、比內框大 2r：box 濾波的邊界只有落在外框
    /// 邊上時才會被內框用到，跟整塊一起算一致
    private fun refineRect(
        guide: ByteArray,
        coarse: FloatArray,
        w: Int,
        wgt: FloatArray,
        out: FloatArray,
        r: Int,
        eps: Float,
        ws: Workspace,
        rx0: Int, ry0: Int, rx1: Int, ry1: Int,
        ix0: Int, iy0: Int, ix1: Int, iy1: Int,
    ) {
        val x0 = rx0
        val y0 = ry0
        val bw = rx1 - rx0
        val bh = ry1 - ry0
        val n = bw * bh
        ws.ensure(n, bw)
        val b = ws.bufs
        val ir = b[0]
        val ig = b[1]
        val ib = b[2]
        val pp = b[3]
        val tmp = b[4]
        val prod = b[5]
        val col = ws.col
        val invCx = invCounts(bw, r)
        for (y in 0 until bh) {
            for (x in 0 until bw) {
                val s = (y + y0) * w + (x + x0)
                val d = y * bw + x
                ir[d] = (guide[s * 3].toInt() and 0xFF) / 255f
                ig[d] = (guide[s * 3 + 1].toInt() and 0xFF) / 255f
                ib[d] = (guide[s * 3 + 2].toInt() and 0xFF) / 255f
                pp[d] = coarse[s]
            }
        }
        fun mean(src: FloatArray, o: FloatArray): FloatArray {
            boxMean(src, bw, bh, r, tmp, o, col, invCx)
            return o
        }
        fun meanOf(o: FloatArray, f: (Int) -> Float): FloatArray {
            for (i in 0 until n) prod[i] = f(i)
            return mean(prod, o)
        }
        val mr = mean(ir, b[6])
        val mg = mean(ig, b[7])
        val mb = mean(ib, b[8])
        val mp = mean(pp, b[9])
        val mrp = meanOf(b[10]) { ir[it] * pp[it] }
        val mgp = meanOf(b[11]) { ig[it] * pp[it] }
        val mbp = meanOf(b[12]) { ib[it] * pp[it] }
        val vrr = meanOf(b[13]) { ir[it] * ir[it] }
        val vrg = meanOf(b[14]) { ir[it] * ig[it] }
        val vrb = meanOf(b[15]) { ir[it] * ib[it] }
        val vgg = meanOf(b[16]) { ig[it] * ig[it] }
        val vgb = meanOf(b[17]) { ig[it] * ib[it] }
        val vbb = meanOf(b[18]) { ib[it] * ib[it] }
        // 係數寫回用完的陣列：a 三個通道、b
        val ar = b[19]
        val ag = b[20]
        val ab = mrp
        val bb = mgp
        for (i in 0 until n) {
            val cr = mrp[i] - mr[i] * mp[i]
            val cg = mgp[i] - mg[i] * mp[i]
            val cb = mbp[i] - mb[i] * mp[i]
            // 3×3 共變異＋eps·I，對稱矩陣直接用餘因子求逆
            val a11 = (vrr[i] - mr[i] * mr[i] + eps).toDouble()
            val a12 = (vrg[i] - mr[i] * mg[i]).toDouble()
            val a13 = (vrb[i] - mr[i] * mb[i]).toDouble()
            val a22 = (vgg[i] - mg[i] * mg[i] + eps).toDouble()
            val a23 = (vgb[i] - mg[i] * mb[i]).toDouble()
            val a33 = (vbb[i] - mb[i] * mb[i] + eps).toDouble()
            val c11 = a22 * a33 - a23 * a23
            val c12 = a13 * a23 - a12 * a33
            val c13 = a12 * a23 - a13 * a22
            val c22 = a11 * a33 - a13 * a13
            val c23 = a12 * a13 - a11 * a23
            val c33 = a11 * a22 - a12 * a12
            val det = a11 * c11 + a12 * c12 + a13 * c13
            val inv = if (abs(det) < 1e-18) 0.0 else 1.0 / det
            val xr = (c11 * cr + c12 * cg + c13 * cb) * inv
            val xg = (c12 * cr + c22 * cg + c23 * cb) * inv
            val xb = (c13 * cr + c23 * cg + c33 * cb) * inv
            ar[i] = xr.toFloat()
            ag[i] = xg.toFloat()
            ab[i] = xb.toFloat()
            bb[i] = (mp[i] - xr * mr[i] - xg * mg[i] - xb * mb[i]).toFloat()
        }
        // 共變異那幾張用完了，拿來放係數的平均
        val mar = mean(ar, vrr)
        val mag = mean(ag, vrg)
        val mab = mean(ab, vrb)
        val mbb = mean(bb, vgg)
        for (yy in iy0 until iy1) {
            val y = yy - y0
            for (xx in ix0 until ix1) {
                val s = yy * w + xx
                val k = wgt[s]
                if (k <= 0f) continue
                val i = y * bw + (xx - x0)
                var q = mar[i] * ir[i] + mag[i] * ig[i] + mab[i] * ib[i] + mbb[i]
                if (q < 0f) q = 0f else if (q > 1f) q = 1f
                out[s] = pp[i] * (1f - k) + q * k
            }
        }
    }

    /// 一格延遲防閃（存檔用的位元組遮罩）：前後兩格差 ≤25、中間那格跟兩邊
    /// 都差 ≥26（約 0.1）→ 換成前後平均。回傳修過的中間那格（新陣列）
    fun ofd(prev: ByteArray, cur: ByteArray, next: ByteArray): ByteArray {
        val out = cur.copyOf()
        for (i in out.indices) {
            val p = prev[i].toInt() and 0xFF
            val c = cur[i].toInt() and 0xFF
            val n = next[i].toInt() and 0xFF
            if (abs(p - n) <= 25 && abs(c - p) >= 26 && abs(c - n) >= 26) {
                out[i] = ((p + n + 1) / 2).toByte()
            }
        }
        return out
    }

    /// 0~1 浮點遮罩（sw×sh）面積平均縮到 dw×dh 位元組（不放大）
    fun downsampleArea(src: FloatArray, sw: Int, sh: Int, dw: Int, dh: Int): ByteArray {
        val out = ByteArray(dw * dh)
        val kx = sw.toDouble() / dw
        val ky = sh.toDouble() / dh
        for (y in 0 until dh) {
            val fy0 = y * ky
            val fy1 = (y + 1) * ky
            val iy0 = fy0.toInt()
            val iy1 = min(sh - 1, kotlin.math.ceil(fy1).toInt() - 1)
            for (x in 0 until dw) {
                val fx0 = x * kx
                val fx1 = (x + 1) * kx
                val ix0 = fx0.toInt()
                val ix1 = min(sw - 1, kotlin.math.ceil(fx1).toInt() - 1)
                var s = 0.0
                var a = 0.0
                for (sy in iy0..iy1) {
                    val wy = min(fy1, (sy + 1).toDouble()) - max(fy0, sy.toDouble())
                    if (wy <= 0) continue
                    for (sx in ix0..ix1) {
                        val wx = min(fx1, (sx + 1).toDouble()) - max(fx0, sx.toDouble())
                        if (wx <= 0) continue
                        s += src[sy * sw + sx] * wx * wy
                        a += wx * wy
                    }
                }
                val v = if (a > 0) s / a else 0.0
                out[y * dw + x] = (v * 255.0 + 0.5).toInt().coerceIn(0, 255).toByte()
            }
        }
        return out
    }

    /// 遮罩放大（雙線性，像素中心對齊），0~1 浮點
    fun upscaleBilinear(src: FloatArray, sw: Int, sh: Int, dw: Int, dh: Int): FloatArray {
        val out = FloatArray(dw * dh)
        val kx = sw.toDouble() / dw
        val ky = sh.toDouble() / dh
        for (y in 0 until dh) {
            val fy = ((y + 0.5) * ky - 0.5).coerceIn(0.0, (sh - 1).toDouble())
            val y0 = fy.toInt()
            val y1 = min(sh - 1, y0 + 1)
            val wy = (fy - y0).toFloat()
            for (x in 0 until dw) {
                val fx = ((x + 0.5) * kx - 0.5).coerceIn(0.0, (sw - 1).toDouble())
                val x0 = fx.toInt()
                val x1 = min(sw - 1, x0 + 1)
                val wx = (fx - x0).toFloat()
                val a = src[y0 * sw + x0] * (1 - wx) + src[y0 * sw + x1] * wx
                val b = src[y1 * sw + x0] * (1 - wx) + src[y1 * sw + x1] * wx
                out[y * dw + x] = a * (1 - wy) + b * wy
            }
        }
        return out
    }
}

/// 人在哪就裁哪：上一格遮罩的外框放大 1.5 倍、做成正方形，平滑移動；
/// 找不到人、人碰到裁切框的邊（快跑出去了）就回整張。座標都是導引圖的像素
internal class CropTracker(private val gw: Int, private val gh: Int) {
    private var cx = 0.0
    private var cy = 0.0
    private var side = 0.0
    private var has = false

    /// 這一格要裁哪：[x, y, w, h]
    fun next(): IntArray {
        if (!has) return intArrayOf(0, 0, gw, gh)
        val s = min(side, max(gw, gh).toDouble())
        val w = min(s, gw.toDouble()).roundToInt().coerceIn(1, gw)
        val h = min(s, gh.toDouble()).roundToInt().coerceIn(1, gh)
        val x = (cx - w / 2.0).roundToInt().coerceIn(0, gw - w)
        val y = (cy - h / 2.0).roundToInt().coerceIn(0, gh - h)
        return intArrayOf(x, y, w, h)
    }

    /// 這一格算完：[alpha]＝裁切框（[crop]）裡的遮罩
    fun update(alpha: FloatArray, crop: IntArray) {
        val (ox, oy, w, h) = crop
        var x0 = Int.MAX_VALUE
        var y0 = Int.MAX_VALUE
        var x1 = -1
        var y1 = -1
        var count = 0
        for (y in 0 until h) {
            for (x in 0 until w) {
                if (alpha[y * w + x] < 0.5f) continue
                count++
                if (x < x0) x0 = x
                if (x > x1) x1 = x
                if (y < y0) y0 = y
                if (y > y1) y1 = y
            }
        }
        if (count < max(16, w * h / 2000)) {
            has = false
            return
        }
        val full = w == gw && h == gh
        val touch = !full && (x0 <= 1 || y0 <= 1 || x1 >= w - 2 || y1 >= h - 2)
        if (touch) {
            // 快跑出框：下一格整張重找
            has = false
            return
        }
        val bx0 = ox + x0
        val by0 = oy + y0
        val bx1 = ox + x1
        val by1 = oy + y1
        val wantSide = max(
            max(bx1 - bx0, by1 - by0) * 1.5,
            min(gw, gh) * 0.35,
        )
        val wantCx = (bx0 + bx1) / 2.0
        val wantCy = (by0 + by1) / 2.0
        if (!has) {
            cx = wantCx
            cy = wantCy
            side = wantSide
            has = true
            return
        }
        val ncx = cx * 0.6 + wantCx * 0.4
        val ncy = cy * 0.6 + wantCy * 0.4
        val nside = side * 0.6 + wantSide * 0.4
        // 平滑後還要包得住這一格的人（留一點邊），包不住就直接跳過去
        val half = nside / 2
        val ok = ncx - half <= bx0 - 2 && ncx + half >= bx1 + 2 &&
            ncy - half <= by0 - 2 && ncy + half >= by1 + 2
        if (ok) {
            cx = ncx
            cy = ncy
            side = nside
        } else {
            cx = wantCx
            cy = wantCy
            side = wantSide
        }
    }
}
