package com.idoluidoluidolu.watermark

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    // 拖曳預覽的「按需抽幀」：滑到哪、跟硬體解碼器要那一格。
    // MediaMetadataRetriever 不是執行緒安全的，全部排進同一條工作緒
    private val frameExec = Executors.newSingleThreadExecutor()
    private var cachedPath: String? = null
    private var retriever: MediaMetadataRetriever? = null

    // 素材工作檔的轉檔工作（取消與進度回報用）
    private var prep: Transformer? = null
    private var prepTick: Runnable? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val main = Handler(Looper.getMainLooper())
        registerPrepChannel(flutterEngine, main)
        registerDiagChannel(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markcut/frames")
            .setMethodCallHandler { call, result ->
                if (call.method != "frameAt") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val ms = (call.argument<Number>("ms") ?: 0).toLong()
                val maxH = (call.argument<Number>("maxH") ?: 540).toInt()
                if (path == null) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                frameExec.execute {
                    val bytes = try {
                        grabFrame(path, ms, maxH)
                    } catch (_: Exception) {
                        null
                    }
                    main.post { result.success(bytes) }
                }
            }
    }

    private fun grabFrame(path: String, ms: Long, maxH: Int): ByteArray? {
        if (cachedPath != path) {
            retriever?.release()
            retriever = MediaMetadataRetriever().also { it.setDataSource(path) }
            cachedPath = path
        }
        val r = retriever ?: return null
        val us = ms * 1000
        // OPTION_CLOSEST_SYNC＝取最近的關鍵幀，不用從頭解到指定格。
        // 拖曳預覽要的是「跟手」，差半秒的畫面人眼分不出來
        val bmp: Bitmap? = if (Build.VERSION.SDK_INT >= 27) {
            val w = r.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH
            )?.toIntOrNull() ?: 0
            val h = r.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT
            )?.toIntOrNull() ?: 0
            val rot = r.extractMetadata(
                MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION
            )?.toIntOrNull() ?: 0
            // getScaledFrameAtTime 要的是「顯示方向」的寬高
            val dw = if (rot == 90 || rot == 270) h else w
            val dh = if (rot == 90 || rot == 270) w else h
            if (dw > 0 && dh > 0) {
                // 只縮不放：來源比 maxH 小就照原尺寸
                val s = minOf(1f, maxH.toFloat() / maxOf(dw, dh))
                r.getScaledFrameAtTime(
                    us,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    maxOf(2, (dw * s).toInt()),
                    maxOf(2, (dh * s).toInt()),
                )
            } else {
                r.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
        } else {
            r.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        }
        if (bmp == null) return null
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 80, out)
        bmp.recycle()
        return out.toByteArray()
    }

    // ===== 診斷（markcut/diag）=====
    //
    // 匯出被系統收掉時不會留下當機報告，只能靠「死掉前吃多少記憶體」
    // 回推。totalPss 是這個行程實際佔的實體記憶體（含 codec 那些原生
    // 配置，Runtime 的 heap 數字看不到那一塊）；availMem 是系統還剩多少
    private fun registerDiagChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markcut/diag")
            .setMethodCallHandler { call, result ->
                if (call.method == "deviceState") {
                    // 過熱降頻時什麼都會頓，查程式碼永遠查不到
                    val pm = getSystemService(android.content.Context.POWER_SERVICE)
                        as android.os.PowerManager
                    val t = if (android.os.Build.VERSION.SDK_INT >= 29) {
                        when (pm.currentThermalStatus) {
                            android.os.PowerManager.THERMAL_STATUS_NONE -> "正常"
                            android.os.PowerManager.THERMAL_STATUS_LIGHT -> "微溫"
                            android.os.PowerManager.THERMAL_STATUS_MODERATE -> "溫熱"
                            else -> "過熱（系統已降頻）"
                        }
                    } else {
                        "?"
                    }
                    result(
                        mapOf(
                            "thermal" to t,
                            "lowPower" to pm.isPowerSaveMode,
                        )
                    )
                    return@setMethodCallHandler
                }
                if (call.method != "memory") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val mi = android.os.Debug.MemoryInfo()
                android.os.Debug.getMemoryInfo(mi)
                val am =
                    getSystemService(android.content.Context.ACTIVITY_SERVICE)
                        as android.app.ActivityManager
                val sys = android.app.ActivityManager.MemoryInfo()
                am.getMemoryInfo(sys)
                result(
                    mapOf(
                        "usedMb" to mi.totalPss / 1024.0,
                        "freeMb" to sys.availMem / (1024.0 * 1024.0),
                    )
                )
            }
    }

    // ===== 素材工作檔（markcut/prep）=====
    //
    // 把 4K HDR 原檔轉成 1080p SDR 的 H.264 工作檔，之後預覽、拖曳、
    // 匯出都用它。Transformer 走 MediaCodec＋OpenGL 的硬體管線，
    // HDR→SDR 的色調映射也是系統做的，跟播放器的顏色一致。
    //
    // 為什麼不用 FFmpeg 轉：它的色調映射是 32 位元浮點的軟體運算，
    // 一格 4K 就要 100MB，實測一支 4K HDR 的峰值 1.7GB——那正是匯出
    // 閃退的原因，拿它做工作檔只是把同一個問題搬到匯入
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun registerPrepChannel(flutterEngine: FlutterEngine, main: Handler) {
        val channel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markcut/prep")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(true)
                "cancel" -> {
                    main.post { prep?.cancel() }
                    result.success(null)
                }
                "toWorkFile" -> {
                    val src = call.argument<String>("src")
                    val dest = call.argument<String>("dest")
                    val shortSide = (call.argument<Number>("maxShortSide") ?: 1080).toInt()
                    if (src == null || dest == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    main.post { startPrep(src, dest, shortSide, channel, main, result) }
                }
                else -> result.notImplemented()
            }
        }
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun startPrep(
        src: String,
        dest: String,
        shortSide: Int,
        channel: MethodChannel,
        main: Handler,
        result: MethodChannel.Result,
    ) {
        try {
            java.io.File(dest).delete()
            var replied = false
            fun reply(path: String?) {
                if (replied) return
                replied = true
                prepTick?.let { main.removeCallbacks(it) }
                prepTick = null
                prep = null
                if (path == null) java.io.File(dest).delete()
                result.success(path)
            }

            val transformer =
                Transformer.Builder(this)
                    // 一律輸出 H.264：後面的 FFmpeg 合成與各家播放器都吃得下
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .addListener(
                        object : Transformer.Listener {
                            override fun onCompleted(
                                composition: Composition,
                                exportResult: ExportResult,
                            ) {
                                channel.invokeMethod("progress", 1.0)
                                reply(if (java.io.File(dest).exists()) dest else null)
                            }

                            override fun onError(
                                composition: Composition,
                                exportResult: ExportResult,
                                exception: ExportException,
                            ) {
                                reply(null)
                            }
                        }
                    )
                    .build()

            val item = MediaItem.fromUri(android.net.Uri.fromFile(java.io.File(src)))
            // 短邊縮到 1080：直式拿到 1080x1920、橫式 1920x1080，
            // 兩種方向的解碼成本一樣（縮長邊的話直式會糊掉）
            val edited =
                EditedMediaItem.Builder(item)
                    .setEffects(
                        Effects(
                            emptyList(),
                            listOf(Presentation.createForShortSide(shortSide)),
                        )
                    )
                    .build()
            val composition =
                Composition.Builder(EditedMediaItemSequence.Builder(edited).build())
                    // HDR → SDR 用 OpenGL 的色調映射（裝置不支援時
                    // Transformer 自己會退到別的做法）
                    .setHdrMode(
                        Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL_TONE_MAPPER
                    )
                    .build()

            prep = transformer
            transformer.start(composition, dest)

            // 進度：Transformer 只提供查詢式的進度，自己每 250ms 問一次
            val holder = ProgressHolder()
            val tick =
                object : Runnable {
                    override fun run() {
                        val t = prep ?: return
                        val state = t.getProgress(holder)
                        if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                            channel.invokeMethod("progress", holder.progress / 100.0)
                        }
                        main.postDelayed(this, 250)
                    }
                }
            prepTick = tick
            main.postDelayed(tick, 250)
        } catch (_: Throwable) {
            prep = null
            result.success(null)
        }
    }

    override fun onDestroy() {
        retriever?.release()
        retriever = null
        prepTick?.let { Handler(Looper.getMainLooper()).removeCallbacks(it) }
        try {
            prep?.cancel()
        } catch (_: Throwable) {}
        prep = null
        super.onDestroy()
    }
}
