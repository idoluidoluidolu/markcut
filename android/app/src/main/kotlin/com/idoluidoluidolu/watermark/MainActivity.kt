package com.idoluidoluidolu.watermark

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Build
import android.os.Handler
import android.os.Looper
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val main = Handler(Looper.getMainLooper())
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

    override fun onDestroy() {
        retriever?.release()
        retriever = null
        super.onDestroy()
    }
}
