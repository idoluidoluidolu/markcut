package com.idoluidoluidolu.watermark

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Handler
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.SegmentationMask
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import com.google.mlkit.vision.segmentation.subject.SubjectSegmentation
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenterOptions
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.zip.Deflater

/// 去背（markcut/cutout，Dart 端見 lib/services/cutout_detect.dart）。
/// 全部在手機上算，照片、影片不離開手機：
/// - 照片：ML Kit 主體分割（人、寵物、物品都行；模型走 Google Play 服務，
///   第一次用要下載）。拿不到（沒有 Play 服務、模型還在下載）就退回內建的
///   人像分割，回 kind = "person"
/// - 影片：ML Kit 人像分割，串流模式（會參考前幾格，邊緣比較不閃），
///   每一格的遮罩寫成 .mcmk（格式見 lib/services/cutout_mask.dart）
///
/// analyzePhoto({path, maxSide, previewSide}) -> {w, h, fullW, fullH, kind, mask,
///   labels?, lw, lh, subjects, note?}?：mask＝全部主體（w×h 位元組）、labels＝
///   每個像素是第幾個主體（lw×lh）。檔案讀不到回 null
/// photoMask({path, ids, maxSide}) -> {w, h, mask}：只留 ids 這幾個主體
/// videoMask({path, out, token}) -> {frames, w, h}；過程中送 cutoutProgress({token, p})
/// cancel({token})
internal class CutoutChannel(
    private val main: Handler,
    /// 使用者正在滑動、播放（影片遮罩放慢讓路）
    private val interactive: () -> Boolean,
) {
    private lateinit var channel: MethodChannel
    private val photoExec = Executors.newSingleThreadExecutor()
    private val videoExec = Executors.newSingleThreadExecutor()
    private val cancelled = ConcurrentHashMap<Int, AtomicBoolean>()

    // 最近一次分析的照片（點主體切換、匯出要原尺寸遮罩都接著用）。只在 photoExec 上碰
    private var cachePath: String? = null
    private var cacheW = 0
    private var cacheH = 0
    /// 每個主體：外框＋框內的信心值（0~255）
    private var cacheSubjects: List<CutSubject> = emptyList()
    /// 只認人的那條路：整張的遮罩
    private var cachePerson: ByteArray? = null

    private class CutSubject(val id: Int, val x: Int, val y: Int, val w: Int, val h: Int, val mask: ByteArray)

    fun register(flutterEngine: FlutterEngine) {
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markcut/cutout")
        channel.setMethodCallHandler { call, result ->
            // 只回一次：回兩次 Flutter 會丟例外
            val replied = AtomicBoolean(false)
            fun ok(v: Any?) {
                if (replied.compareAndSet(false, true)) main.post { result.success(v) }
            }
            fun fail(step: String, e: Throwable) {
                val cause = e.cause ?: e
                val at = cause.stackTrace.take(2).joinToString(" ← ") {
                    "${it.className.substringAfterLast('.')}.${it.methodName}"
                }
                val msg = "${step}｜${cause.javaClass.simpleName} @ ${at}｜${cause.message ?: ""}"
                if (replied.compareAndSet(false, true)) {
                    main.post { result.error("cutout_failed", msg, null) }
                }
            }
            when (call.method) {
                "analyzePhoto" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val maxSide = (call.argument<Number>("maxSide") ?: 2048).toInt().coerceIn(256, 4096)
                    val previewSide = (call.argument<Number>("previewSide") ?: 1600).toInt().coerceIn(16, 4096)
                    photoExec.execute {
                        try {
                            ok(analyzePhoto(path, maxSide, previewSide))
                        } catch (e: Throwable) {
                            fail("照片去背", e)
                        }
                    }
                }
                "photoMask" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val ids = (call.argument<List<Any?>>("ids") ?: emptyList()).mapNotNull { (it as? Number)?.toInt() }
                    val maxSide = (call.argument<Number>("maxSide") ?: 2048).toInt().coerceIn(16, 4096)
                    photoExec.execute {
                        try {
                            ok(photoMask(path, ids, maxSide))
                        } catch (e: Throwable) {
                            fail("主體遮罩", e)
                        }
                    }
                }
                "videoMask" -> {
                    val path = call.argument<String>("path")
                    val out = call.argument<String>("out")
                    val token = call.argument<Number>("token")?.toInt()
                    if (path.isNullOrEmpty() || out.isNullOrEmpty() || token == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val flag = cancelled.getOrPut(token) { AtomicBoolean(false) }
                    videoExec.execute {
                        val stats = arrayOf("開檔")
                        try {
                            var last = -1.0
                            val r = videoMask(path, out, flag, stats) { p ->
                                // 每 1% 送一次就夠
                                if (p - last >= 0.01 || p >= 1.0) {
                                    last = p
                                    main.post {
                                        channel.invokeMethod("cutoutProgress", mapOf("token" to token, "p" to p))
                                    }
                                }
                            }
                            ok(r)
                        } catch (e: Throwable) {
                            fail(stats[0], e)
                        } finally {
                            cancelled.remove(token)
                        }
                    }
                }
                "cancel" -> {
                    call.argument<Number>("token")?.toInt()?.let {
                        cancelled.getOrPut(it) { AtomicBoolean(false) }.set(true)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ===== 照片 =====

    private fun fit(w: Int, h: Int, maxSide: Int): Pair<Int, Int> {
        val long = maxOf(w, h)
        if (long <= maxSide) return Pair(w, h)
        val k = maxSide.toDouble() / long
        return Pair(maxOf(1, Math.round(w * k).toInt()), maxOf(1, Math.round(h * k).toInt()))
    }

    private fun analyzePhoto(path: String, maxSide: Int, previewSide: Int): Map<String, Any?>? {
        val bmp = decodeUpright(path, maxSide) ?: return null
        val w = bmp.width
        val h = bmp.height
        val (pw, ph) = fit(w, h, previewSide)
        cachePath = null
        cacheSubjects = emptyList()
        cachePerson = null
        var note: String? = null
        try {
            val subjects = subjectSegment(bmp)
            // 一個主體都沒有：可能真的沒有，也可能是模型還沒下載完（官方說
            // 下載完之前的請求「拿不到結果」）——交給人像分割再看一次
            if (subjects.isEmpty()) throw IllegalStateException("主體分割沒有結果")
            cachePath = path
            cacheW = w
            cacheH = h
            cacheSubjects = subjects
            val all = composeSubjects(subjects, subjects.map { it.id }, w, h)
            // 點畫面切換主體用的標籤圖：不用全尺寸，長邊 512 就夠點
            val (lw, lh) = fit(w, h, 512)
            val labels = ByteArray(lw * lh)
            for (ly in 0 until lh) {
                val y = minOf(h - 1, (ly + 0.5) * h / lh).toInt()
                for (lx in 0 until lw) {
                    val x = minOf(w - 1, (lx + 0.5) * w / lw).toInt()
                    var best = 127
                    var label = 0
                    for (s in subjects) {
                        if (x < s.x || y < s.y || x >= s.x + s.w || y >= s.y + s.h) continue
                        val v = s.mask[(y - s.y) * s.w + (x - s.x)].toInt() and 0xFF
                        if (v > best) {
                            best = v
                            label = s.id
                        }
                    }
                    labels[ly * lw + lx] = label.toByte()
                }
            }
            return mapOf(
                "w" to pw, "h" to ph, "fullW" to w, "fullH" to h,
                "kind" to "subject",
                "mask" to resize(all, w, h, pw, ph),
                "labels" to labels, "lw" to lw, "lh" to lh,
                "subjects" to subjects.map {
                    mapOf(
                        "id" to it.id,
                        "x" to it.x.toDouble() / w, "y" to it.y.toDouble() / h,
                        "w" to it.w.toDouble() / w, "h" to it.h.toDouble() / h,
                    )
                },
            )
        } catch (e: Throwable) {
            // 主體分割走 Google Play 服務：沒有 Play 服務、模型還在下載都會
            // 走到這裡。退回內建的人像分割（照樣能去人），原因帶回去提示
            val cause = e.cause ?: e
            note = "${cause.javaClass.simpleName}: ${cause.message ?: ""}"
        }
        val person = selfieSegment(bmp)
        cachePath = path
        cacheW = w
        cacheH = h
        cachePerson = person
        val preview = resize(person, w, h, pw, ph)
        val box = boxOf(person, w, h)
        return mapOf(
            "w" to pw, "h" to ph, "fullW" to w, "fullH" to h,
            "kind" to "person",
            "mask" to preview,
            "lw" to 0, "lh" to 0,
            "subjects" to if (box == null) emptyList() else listOf(
                mapOf(
                    "id" to 1,
                    "x" to box[0].toDouble() / w, "y" to box[1].toDouble() / h,
                    "w" to (box[2] - box[0] + 1).toDouble() / w,
                    "h" to (box[3] - box[1] + 1).toDouble() / h,
                ),
            ),
            "note" to note,
        )
    }

    private fun photoMask(path: String, ids: List<Int>, maxSide: Int): Map<String, Any?>? {
        if (cachePath != path) {
            analyzePhoto(path, maxOf(maxSide, 1024), 64) ?: return null
        }
        val w = cacheW
        val h = cacheH
        val (ow, oh) = fit(w, h, maxSide)
        val person = cachePerson
        val full = when {
            person != null -> if (ids.isEmpty()) ByteArray(w * h) else person
            else -> composeSubjects(cacheSubjects, ids, w, h)
        }
        return mapOf("w" to ow, "h" to oh, "mask" to resize(full, w, h, ow, oh))
    }

    /// 主體分割：每個主體的外框與框內信心值。拿不到（模型沒下載、沒有
    /// Play 服務）會丟例外
    private fun subjectSegment(bmp: Bitmap): List<CutSubject> {
        val options = SubjectSegmenterOptions.Builder()
            .enableMultipleSubjects(
                SubjectSegmenterOptions.SubjectResultOptions.Builder()
                    .enableConfidenceMask()
                    .build(),
            )
            .build()
        val segmenter = SubjectSegmentation.getClient(options)
        try {
            val r = Tasks.await(segmenter.process(InputImage.fromBitmap(bmp, 0)), 60, TimeUnit.SECONDS)
            val out = ArrayList<CutSubject>()
            var id = 1
            for (s in r.subjects) {
                val m = s.confidenceMask ?: continue
                val sw = s.width
                val sh = s.height
                if (sw <= 0 || sh <= 0 || id > 250) continue
                val bytes = ByteArray(sw * sh)
                (m as java.nio.Buffer).rewind()
                for (i in 0 until sw * sh) {
                    if (!m.hasRemaining()) break
                    bytes[i] = toByte(m.get())
                }
                out.add(CutSubject(id, s.startX, s.startY, sw, sh, bytes))
                id++
            }
            return out
        } finally {
            try {
                segmenter.close()
            } catch (_: Throwable) {}
        }
    }

    /// 只留 [ids] 這幾個主體：整張的遮罩（w×h，取最大值）
    private fun composeSubjects(subjects: List<CutSubject>, ids: List<Int>, w: Int, h: Int): ByteArray {
        val out = ByteArray(w * h)
        for (s in subjects) {
            if (!ids.contains(s.id)) continue
            for (y in 0 until s.h) {
                val oy = s.y + y
                if (oy < 0 || oy >= h) continue
                for (x in 0 until s.w) {
                    val ox = s.x + x
                    if (ox < 0 || ox >= w) continue
                    val v = s.mask[y * s.w + x].toInt() and 0xFF
                    val o = oy * w + ox
                    if (v > (out[o].toInt() and 0xFF)) out[o] = v.toByte()
                }
            }
        }
        return out
    }

    /// 人像分割（內建模型，不靠 Play 服務）：整張照片的遮罩（w×h）
    private fun selfieSegment(bmp: Bitmap): ByteArray {
        val segmenter = Segmentation.getClient(
            SelfieSegmenterOptions.Builder()
                .setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE)
                .build(),
        )
        try {
            val mask = Tasks.await(segmenter.process(InputImage.fromBitmap(bmp, 0)), 60, TimeUnit.SECONDS)
            val raw = maskBytes(mask)
            return resize(raw, mask.width, mask.height, bmp.width, bmp.height)
        } finally {
            try {
                segmenter.close()
            } catch (_: Throwable) {}
        }
    }

    // ===== 影片 =====

    /// 整支影片每一格的人像遮罩 → .mcmk。MediaCodec 順著硬體解碼（不 seek）；
    /// 每一格自己轉正、縮小成點陣再給 ML Kit（遮罩就是畫面上看到的方向，
    /// 跟播放器一樣）。30fps 以上的片子隔格算，跟 iOS 同一套。
    /// [step] 的第一格記做到哪一步（失敗時跟原因一起回）
    private fun videoMask(
        path: String,
        out: String,
        cancel: AtomicBoolean,
        step: Array<String>,
        progress: (Double) -> Unit,
    ): Map<String, Any> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var writer: CutoutMaskWriter? = null
        val segmenter = Segmentation.getClient(
            SelfieSegmenterOptions.Builder()
                .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE)
                .enableRawSizeMask()
                .build(),
        )
        var ok = false
        try {
            step[0] = "開檔"
            extractor.setDataSource(path)
            var track = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/")) {
                    track = i
                    break
                }
            }
            if (track < 0) throw IllegalStateException("沒有影片軌")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: throw IllegalStateException("讀不到編碼")
            val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) {
                format.getLong(MediaFormat.KEY_DURATION)
            } else {
                0L
            }
            val rawRotation = if (format.containsKey(MediaFormat.KEY_ROTATION)) {
                format.getInteger(MediaFormat.KEY_ROTATION)
            } else {
                videoRotation(path)
            }
            val rotation = (rawRotation % 360 + 360) % 360
            format.setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
            )
            step[0] = "解碼"
            val dec = MediaCodec.createDecoderByType(mime)
            codec = dec
            dec.configure(format, null, null, 0)
            dec.start()

            var next = Double.NEGATIVE_INFINITY
            var frames = 0
            var failed = 0
            var firstError: String? = null
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var idle = 0
            while (!outputDone) {
                if (cancel.get()) throw InterruptedException("已取消")
                step[0] = "解碼"
                if (!inputDone) {
                    val inIdx = dec.dequeueInputBuffer(10_000)
                    if (inIdx >= 0) {
                        val buf = dec.getInputBuffer(inIdx)
                        val size = if (buf == null) -1 else extractor.readSampleData(buf, 0)
                        if (size < 0) {
                            dec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            dec.queueInputBuffer(inIdx, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = dec.dequeueOutputBuffer(info, 10_000)
                if (outIdx < 0) {
                    if (inputDone && ++idle > 200) break
                    continue
                }
                idle = 0
                val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                if (eos) outputDone = true
                val t = info.presentationTimeUs / 1_000_000.0
                val isFrame = info.size > 0 || !eos
                if (isFrame && t >= next) {
                    step[0] = "拿影像"
                    val image = try {
                        dec.getOutputImage(outIdx)
                    } catch (e: Exception) {
                        if (firstError == null) firstError = "${e.javaClass.simpleName}: ${e.message ?: ""}"
                        null
                    }
                    if (image != null) {
                        next = t + 1.0 / 30 - 0.5 / 60
                        try {
                            step[0] = "轉正"
                            val bmp = yuvToUpright(image, rotation, 512)
                            step[0] = "算遮罩"
                            val mask = Tasks.await(
                                segmenter.process(InputImage.fromBitmap(bmp, 0)),
                                10,
                                TimeUnit.SECONDS,
                            )
                            bmp.recycle()
                            val bytes = maskBytes(mask)
                            step[0] = "寫檔"
                            val wr = writer ?: CutoutMaskWriter(out, mask.width, mask.height).also { writer = it }
                            if (mask.width == wr.width && mask.height == wr.height) {
                                wr.add(t, bytes)
                                frames++
                            } else {
                                wr.add(t, resize(bytes, mask.width, mask.height, wr.width, wr.height))
                                frames++
                            }
                        } catch (e: InterruptedException) {
                            throw e
                        } catch (e: Throwable) {
                            failed++
                            if (firstError == null) {
                                val c = e.cause ?: e
                                firstError = "${c.javaClass.simpleName}: ${c.message ?: ""}"
                            }
                        } finally {
                            image.close()
                        }
                        if (durationUs > 0) progress((t * 1_000_000.0 / durationUs).coerceIn(0.0, 1.0))
                        // 使用者在滑動、播放：放慢讓路（跟工作檔轉檔一樣，滑動優先）
                        if (interactive()) Thread.sleep(40)
                    }
                }
                dec.releaseOutputBuffer(outIdx, false)
            }
            val wr = writer
            if (wr == null || frames == 0) {
                throw IllegalStateException("一格遮罩都沒算出來（失敗 ${failed} 格：${firstError ?: "?"}）")
            }
            step[0] = "收尾"
            wr.finish()
            ok = true
            progress(1.0)
            return mapOf("frames" to frames, "w" to wr.width, "h" to wr.height)
        } finally {
            if (!ok) writer?.abort()
            try {
                codec?.stop()
            } catch (_: Exception) {}
            try {
                codec?.release()
            } catch (_: Exception) {}
            extractor.release()
            try {
                segmenter.close()
            } catch (_: Throwable) {}
        }
    }

    /// 解碼器的一格（YUV_420_888）→ 轉正、長邊不超過 [maxSide] 的 ARGB 點陣。
    /// 直接照目的地每一點回頭取樣（最近點）：轉正跟縮小一步做完，不必先
    /// 轉出整張全尺寸的 RGB。10 位元的 P010 每個樣本兩個位元組、值在高位，
    /// 取後面那個位元組（同找臉那條）
    private fun yuvToUpright(image: android.media.Image, rotation: Int, maxSide: Int): Bitmap {
        val crop = image.cropRect
        val sw = crop.width()
        val sh = crop.height()
        val swap = rotation == 90 || rotation == 270
        val uw = if (swap) sh else sw
        val uh = if (swap) sw else sh
        val (ow, oh) = fit(uw, uh, maxSide)
        val hi = if (image.format == 0x36) 1 else 0
        val yPlane = image.planes[0]
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        val yBuf = yPlane.buffer
        val uBuf = uPlane.buffer
        val vBuf = vPlane.buffer
        val yRow = yPlane.rowStride
        val yPix = yPlane.pixelStride
        val uRow = uPlane.rowStride
        val uPix = uPlane.pixelStride
        val vRow = vPlane.rowStride
        val vPix = vPlane.pixelStride
        val yLast = yBuf.limit() - 1
        val uLast = uBuf.limit() - 1
        val vLast = vBuf.limit() - 1
        val px = IntArray(ow * oh)
        for (oy in 0 until oh) {
            val uy = ((oy + 0.5) * uh / oh).toInt().coerceIn(0, uh - 1)
            for (ox in 0 until ow) {
                val ux = ((ox + 0.5) * uw / ow).toInt().coerceIn(0, uw - 1)
                // 轉正後的 (ux, uy) 回到解碼器格子裡的 (x, y)。旋轉旗標是
                // 「顯示時要順時針轉幾度」
                val x: Int
                val y: Int
                when (rotation) {
                    90 -> {
                        x = uy
                        y = sh - 1 - ux
                    }
                    180 -> {
                        x = sw - 1 - ux
                        y = sh - 1 - uy
                    }
                    270 -> {
                        x = sw - 1 - uy
                        y = ux
                    }
                    else -> {
                        x = ux
                        y = uy
                    }
                }
                val sx = crop.left + x
                val sy = crop.top + y
                val yy = (yBuf.get(minOf(sy * yRow + sx * yPix + hi, yLast)).toInt() and 0xFF)
                val cx = sx / 2
                val cy = sy / 2
                val u = (uBuf.get(minOf(cy * uRow + cx * uPix + hi, uLast)).toInt() and 0xFF) - 128
                val v = (vBuf.get(minOf(cy * vRow + cx * vPix + hi, vLast)).toInt() and 0xFF) - 128
                // BT.601（找人用的，色準不重要）
                val c = (yy - 16).coerceAtLeast(0) * 1192
                val r = ((c + 1634 * v) shr 10).coerceIn(0, 255)
                val g = ((c - 833 * v - 400 * u) shr 10).coerceIn(0, 255)
                val b = ((c + 2066 * u) shr 10).coerceIn(0, 255)
                px[oy * ow + ox] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
            }
        }
        return Bitmap.createBitmap(px, ow, oh, Bitmap.Config.ARGB_8888)
    }

    private fun videoRotation(path: String): Int {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(path)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        } catch (_: Exception) {
            0
        } finally {
            try {
                r.release()
            } catch (_: Exception) {}
        }
    }

    // ===== 共用 =====

    /// ML Kit 人像遮罩（每個像素一個 float 信心值）→ 位元組
    private fun maskBytes(mask: SegmentationMask): ByteArray {
        val n = mask.width * mask.height
        val out = ByteArray(n)
        val buf: ByteBuffer = mask.buffer
        (buf as java.nio.Buffer).rewind()
        for (i in 0 until n) {
            if (buf.remaining() < 4) break
            out[i] = toByte(buf.float)
        }
        return out
    }

    private fun toByte(v: Float): Byte = (v * 255f + 0.5f).toInt().coerceIn(0, 255).toByte()

    /// 遮罩縮放（雙線性）；尺寸一樣直接回原本那份
    private fun resize(src: ByteArray, sw: Int, sh: Int, dw: Int, dh: Int): ByteArray {
        if (sw == dw && sh == dh) return src
        val out = ByteArray(dw * dh)
        val kx = sw.toDouble() / dw
        val ky = sh.toDouble() / dh
        for (y in 0 until dh) {
            val fy = ((y + 0.5) * ky - 0.5).coerceIn(0.0, (sh - 1).toDouble())
            val y0 = fy.toInt()
            val y1 = minOf(sh - 1, y0 + 1)
            val wy = fy - y0
            for (x in 0 until dw) {
                val fx = ((x + 0.5) * kx - 0.5).coerceIn(0.0, (sw - 1).toDouble())
                val x0 = fx.toInt()
                val x1 = minOf(sw - 1, x0 + 1)
                val wx = fx - x0
                val a = (src[y0 * sw + x0].toInt() and 0xFF) * (1 - wx) + (src[y0 * sw + x1].toInt() and 0xFF) * wx
                val b = (src[y1 * sw + x0].toInt() and 0xFF) * (1 - wx) + (src[y1 * sw + x1].toInt() and 0xFF) * wx
                out[y * dw + x] = (a * (1 - wy) + b * wy + 0.5).toInt().coerceIn(0, 255).toByte()
            }
        }
        return out
    }

    /// 遮罩（≥128 算主體）的外框 [x0, y0, x1, y1]；整張都是背景回 null
    private fun boxOf(mask: ByteArray, w: Int, h: Int): IntArray? {
        var x0 = Int.MAX_VALUE
        var y0 = Int.MAX_VALUE
        var x1 = -1
        var y1 = -1
        for (y in 0 until h) {
            for (x in 0 until w) {
                if ((mask[y * w + x].toInt() and 0xFF) < 128) continue
                if (x < x0) x0 = x
                if (x > x1) x1 = x
                if (y < y0) y0 = y
                if (y > y1) y1 = y
            }
        }
        return if (x1 < 0) null else intArrayOf(x0, y0, x1, y1)
    }

    /// 照片解成點陣（長邊不超過 [maxSide]）並照 EXIF 方向轉正——Dart 端
    /// 解碼也會轉正，0~1 座標才對得上（同找臉那條）
    private fun decodeUpright(path: String, maxSide: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val longSide = maxOf(bounds.outWidth, bounds.outHeight)
        if (longSide <= 0) return null
        var sample = 1
        while (longSide / (sample * 2) >= maxSide) sample *= 2
        val raw = BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            },
        ) ?: return null
        val orientation = try {
            ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val m = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> m.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> m.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> m.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                m.setRotate(90f)
                m.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> m.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                m.setRotate(-90f)
                m.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> m.setRotate(-90f)
            else -> {}
        }
        val s = maxSide.toFloat() / maxOf(raw.width, raw.height)
        if (s < 1f) m.postScale(s, s)
        if (m.isIdentity) return raw
        val upright = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, m, true)
        if (upright !== raw) raw.recycle()
        return upright
    }
}

/// .mcmk 遮罩檔的寫入端（格式見 lib/services/cutout_mask.dart；iOS 那份在
/// AppDelegate.swift 的 MCCutoutMaskWriter）。全部小端序、每格 raw deflate
internal class CutoutMaskWriter(private val path: String, val width: Int, val height: Int) {
    private val raf: RandomAccessFile
    private val deflater = Deflater(6, true)
    private val scratch = ByteArray(width * height + 4096)
    private val pts = ArrayList<Double>()
    private val offs = ArrayList<Long>()
    private val lens = ArrayList<Int>()

    init {
        require(width in 1..65535 && height in 1..65535) { "遮罩尺寸不對 ${width}×${height}" }
        File(path).delete()
        raf = RandomAccessFile(path, "rw")
        raf.write(ByteArray(24))
    }

    fun add(t: Double, mask: ByteArray) {
        require(mask.size == width * height) { "遮罩大小不對" }
        deflater.reset()
        deflater.setInput(mask)
        deflater.finish()
        var n = 0
        while (!deflater.finished()) {
            if (n >= scratch.size) throw IllegalStateException("遮罩壓縮暫存不夠")
            n += deflater.deflate(scratch, n, scratch.size - n)
        }
        offs.add(raf.filePointer)
        raf.write(scratch, 0, n)
        pts.add(t)
        lens.add(n)
    }

    fun finish() {
        val indexAt = raf.filePointer
        val index = ByteBuffer.allocate(pts.size * 24).order(ByteOrder.LITTLE_ENDIAN)
        for (i in pts.indices) {
            index.putDouble(pts[i])
            index.putLong(offs[i])
            index.putInt(lens[i])
            index.putInt(0)
        }
        raf.write(index.array())
        val header = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
        header.put('M'.code.toByte())
        header.put('C'.code.toByte())
        header.put('M'.code.toByte())
        header.put('K'.code.toByte())
        header.putShort(1.toShort())
        header.putShort(0.toShort())
        header.putShort(width.toShort())
        header.putShort(height.toShort())
        header.putInt(pts.size)
        header.putLong(indexAt)
        raf.seek(0)
        raf.write(header.array())
        raf.fd.sync()
        raf.close()
        deflater.end()
    }

    /// 沒做完（失敗／取消）：殘檔刪掉
    fun abort() {
        try {
            raf.close()
        } catch (_: Exception) {}
        deflater.end()
        File(path).delete()
    }
}
