package com.idoluidoluidolu.watermark

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

private class FrameSource(val retriever: MediaMetadataRetriever, val width: Int, val height: Int) {
    companion object {
        fun open(key: FrameSourceKey): FrameSource {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(key.path)
                val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
                val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
                val rot = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
                return if (rot == 90 || rot == 270) FrameSource(r, h, w) else FrameSource(r, w, h)
            } catch (e: Exception) {
                try { r.release() } catch (_: Exception) {}
                throw e
            }
        }
    }
}

/// 工作檔轉檔退路階梯的一段（見 MainActivity.rungsFor）
private data class PrepRung(
    val label: String,
    val shortSide: Int,
    /// 關鍵幀間隔（秒）；null＝media3 預設（1 秒）
    val gopSec: Float?,
    val hdrMode: Int,
)

/// 一次 toWorkFile 呼叫的狀態（一支素材一個）
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private class PrepJob(
    val id: Int,
    val src: String,
    val dest: String,
    val shortSide: Int,
    /// Dart 端說上一次轉出來的不能用：跳過第一段、直接走保守參數
    val safe: Boolean,
    val interactiveYield: Boolean,
    val result: MethodChannel.Result,
) {
    var transformer: Transformer? = null
    var rung = 0
    var replied = false
    var cancelled = false
    /// 來源「顯示方向」的寬高（已照旋轉旗標換算）；0＝讀不到
    var srcW = 0
    var srcH = 0
    var srcHdr = false
    val startedAt = SystemClock.elapsedRealtime()
    var tick: Runnable? = null
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class MainActivity : FlutterActivity() {
    // 系統抽幀 API 的解碼成本與 codec 選擇依來源及裝置而異。
    // Retriever 與 LRU 全部只在單一工作緒使用，兩支素材交替時保留已開的來源。
    private val frameExec = Executors.newSingleThreadExecutor()
    private val framePool = FrameResourcePool(2, FrameSource::open) { it.retriever.release() }
    private val frameGeneration = AtomicLong()
    private var frameForeground = true

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val main = mainHandler
        registerPrepChannel(flutterEngine)
        registerDiagChannel(flutterEngine)
        registerPickChannel(flutterEngine)
        // cacheDir/picked 每挑一次就多一份複本（同名不覆蓋、從沒人清）：
        // 啟動時在背景掃掉七天以前的。草稿要留的素材 Dart 端會複製進
        // 自己的目錄，這裡的只是匯入時的中繼複本
        copyExec.execute { sweepPicked() }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markcut/frames")
            .setMethodCallHandler { call, result ->
                if (call.method == "release") {
                    releaseFrames { result.success(null) }
                    return@setMethodCallHandler
                }
                if (call.method == "stats") {
                    if (frameExec.isShutdown) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    frameExec.execute {
                        val stats = mapOf("active" to framePool.active, "created" to framePool.created,
                            "reused" to framePool.reused, "capacity" to framePool.capacity)
                        main.post { result.success(stats) }
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "frameAt") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val ms = (call.argument<Number>("ms") ?: 0).toLong().coerceIn(0, Long.MAX_VALUE / 1000)
                val maxH = (call.argument<Number>("maxH") ?: 540).toInt().coerceIn(2, 4096)
                val detailed = call.argument<Boolean>("detailed") ?: false
                // JPEG 僅供粗覽；不拿它的畫質／顏色代替最終播放器與匯出。
                val q = ((call.argument<Number>("q") ?: 0.8).toDouble() * 100)
                    .toInt().coerceIn(30, 100)
                if (path == null || !frameForeground || frameExec.isShutdown) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                val generation = frameGeneration.get()
                frameExec.execute {
                    val bytes = try {
                        if (generation == frameGeneration.get()) grabFrame(path, ms, maxH, q) else null
                    } catch (_: Exception) {
                        null
                    }
                    main.post {
                        // MMR 不回傳實際 PTS；絕不把要求時間冒充成落地時間。
                        result.success(if (generation != frameGeneration.get()) null
                            else if (detailed && bytes != null) mapOf("bytes" to bytes) else bytes)
                    }
                }
            }
    }

    // ===== 挑素材：系統相片選取器 =====
    //
    // file_picker 的 FileType.video 在安卓走 SAF 文件選取器——開出來是
    // 檔案管理器的「最近」，不是相簿。Android 13 起有系統相片選取器
    // （ACTION_PICK_IMAGES），可以限定只列影片、直接開在相簿的長相。
    // 更舊的機型回 null，Dart 端退回原本的 SAF 那條路。
    //
    // 三個方法共用這一支：videos＝多選影片、photos＝挑照片（單多選看
    // max）、gifs＝單選 GIF（同一個選取器換 type 而已，見 registerPickChannel）

    /// 等使用者選完的那次呼叫（一次只會有一個選取器在畫面上）
    private var pickReply: MethodChannel.Result? = null

    /// 這一次挑的是 GIF、照片還是影片。補副檔名要用——問 contentResolver
    /// 的 MIME 不可靠（可能回 null、image/*、或大小寫不同），而這裡本來
    /// 就知道答案：選取器是我們自己按方法名開的
    private var pickWantsGif = false
    private var pickWantsPhoto = false

    /// 刻意超過 16 位元。file_picker 的 REQUEST_CODE 是
    /// `(FilePickerPlugin::class.java.hashCode() + 43) and 0xffff`——執行期
    /// 雜湊，0~65535 任何值都可能；跟舊的 9137 撞上時 onActivityResult 會
    /// 把它的結果吃掉、它的 Future 永遠不回。`and 0xffff` 永遠算不出
    /// 0x10000 以上的號碼。FlutterActivity 直接繼承 android.app.Activity，
    /// 沒有 FragmentActivity「只能用低 16 位元」的那道檢查
    private val pickReq = 0x1ACE7

    /// 把 content:// 複製進快取的工作緒（大檔要幾秒，不能佔主緒）
    private val copyExec = Executors.newSingleThreadExecutor()

    /// 掃掉 cacheDir/picked 底下七天以前的複本。七天內的先留著：可能還在
    /// 被這一次的匯入用，也可能被某份草稿記著原路徑（見下面 cutoff）。
    /// 讀不到日期（0）的也留著——判不出新舊時寧可留下垃圾也不要刪掉
    /// 還在用的（iOS 的 sweepPickedTemp 同一條規矩）
    private fun sweepPicked() {
        val files = File(cacheDir, "picked").listFiles() ?: return
        // 七天不是一天：草稿引用的素材有一部分是「太大所以沒留複本、
        // 記的是這裡的原路徑」（見 Dart 端 DraftAssets 的額度上限）。
        // 一天就掃掉的話，那種草稿隔天就續作不了；七天仍然擋得住無限
        // 長大（每挑一次就多一份原檔），又給草稿一週的餘裕
        val cutoff = System.currentTimeMillis() - 7L * 24 * 60 * 60 * 1000
        for (f in files) {
            try {
                val at = f.lastModified()
                if (at > 0 && at < cutoff) f.delete()
            } catch (_: Exception) {}
        }
    }

    private fun registerPickChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markcut/pick")
            .setMethodCallHandler { call, result ->
                val gifs = call.method == "gifs"
                val photos = call.method == "photos"
                if (call.method != "videos" && !gifs && !photos) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < 33) {
                    // 沒有系統相片選取器：讓 Dart 端走 file_picker
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (pickReply != null) {
                    // 已經有一個選取器開著（連點兩下）：這一次當沒選
                    result.success(ArrayList<String>())
                    return@setMethodCallHandler
                }
                // 組 intent 也可能丟（coerceIn 在上限 < 2 時就會），所以
                // 鎖要等到真的要開選取器前一刻才拿——先拿了卻在這裡丟出去，
                // 那把鎖就再也放不掉，之後每一次挑都被當成「已經有一個開著」
                val intent = try {
                    Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                        if (gifs) {
                            // 只列會動的那種；不放 EXTRA_PICK_IMAGES_MAX
                            // ＝單選（匯入一次收一個 GIF）
                            type = "image/gif"
                        } else {
                            // 點照片只列照片、點影片只列影片（使用者指定）。
                            // 照片以前走 image_picker 的 ACTION_GET_CONTENT：
                            // 系統先問「用哪個 App 開」，OEM 相簿又不一定理會
                            // image/* 這個過濾，照片影片混著列
                            type = if (photos) "image/*" else "video/*"
                            // max ≤ 1＝單選：不放 EXTRA_PICK_IMAGES_MAX 就是單選
                            //（照片編輯器、裁切這種一次一張的）；2 以上才多選
                            val max = (call.argument<Number>("max") ?: 30).toInt()
                            if (max >= 2) {
                                putExtra(
                                    MediaStore.EXTRA_PICK_IMAGES_MAX,
                                    max.coerceIn(2, MediaStore.getPickImagesMaxLimit()),
                                )
                            }
                        }
                    }
                } catch (_: Exception) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                pickReply = result
                pickWantsGif = gifs
                pickWantsPhoto = photos
                try {
                    startActivityForResult(intent, pickReq)
                } catch (_: Exception) {
                    // 叫不出選取器：鎖要放掉再回 null（Dart 端退回
                    // file_picker）
                    pickReply = null
                    result.success(null)
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // 沒有在等的挑選（pickReply 空）也交給 super：就算號碼真的撞上，
        // 別人（外掛）的結果也不會被這裡吃掉
        val reply = pickReply
        if (requestCode != pickReq || reply == null) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        pickReply = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            reply.success(ArrayList<String>()) // 使用者按了返回
            return
        }
        val uris = ArrayList<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        // 選取器給的是 content://，整條管線（FFmpeg、mpv、抽幀）都吃
        // 檔案路徑——複製進快取再回。file_picker 本來也是這樣做的，
        // 成本一樣，只是選取的長相變成相簿
        val main = mainHandler
        copyExec.execute {
            val out = ArrayList<String>()
            for (u in uris) copyToCache(u)?.let { out.add(it) }
            main.post {
                // 明明選了東西卻一個都複製不出來（I/O 壞了、沒權限）：
                // 回 null 讓 Dart 端退回 file_picker。回空清單的話會被當成
                // 「使用者按了取消」，他就只看到點了完全沒反應
                if (uris.isNotEmpty() && out.isEmpty()) {
                    reply.success(null)
                } else {
                    reply.success(out)
                }
            }
        }
    }

    /// content:// → 快取檔。保留原檔名（介面上顯示素材名稱用）。
    ///
    /// 這裡是 block body 而不是 `= try {…}`：下面那句 `?: return null`
    /// 在 expression body 裡是編譯錯誤（returns are prohibited for
    /// functions with an expression body）
    private fun copyToCache(u: Uri): String? {
        return try {
            var name: String? = null
            contentResolver.query(u, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (i >= 0 && c.moveToFirst()) name = c.getString(i)
            }
            // 選取器照理都給得出 DISPLAY_NAME；真的沒有才自己編一個。
            // 下游整條管線是照副檔名認素材的，所以副檔名一定要有：GIF
            // 那條尤其重要——在只列 GIF 的清單裡挑到的東西，要是名字沒
            // 帶 .gif，會被 App 自己的檢查擋下來說「這不是 GIF」
            // （iOS 同樣有這一手）
            val gif = pickWantsGif
            var safe = (name ?: "picked_${System.currentTimeMillis()}")
                .replace('/', '_')
            if (gif && !safe.lowercase().endsWith(".gif")) safe += ".gif"
            // 沒副檔名才補：照片補 .jpg、影片補 .mp4（實際格式看檔頭，
            // 下游只是拿副檔名分「照片還是影片」）
            if (!gif && !safe.contains('.')) {
                safe += if (pickWantsPhoto) ".jpg" else ".mp4"
            }

            val dir = File(cacheDir, "picked").apply { mkdirs() }
            var f = File(dir, safe)
            var n = 1
            while (f.exists()) f = File(dir, "${n++}_$safe") // 同名不覆蓋
            contentResolver.openInputStream(u)?.use { input ->
                FileOutputStream(f).use { output ->
                    input.copyTo(output, 1 shl 16)
                }
            } ?: return null
            f.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun grabFrame(
        path: String,
        ms: Long,
        maxH: Int,
        quality: Int = 80,
    ): ByteArray? {
        val source = framePool.acquire(FrameSourceKey.fromFile(path))
        val r = source.retriever
        val us = ms * 1000
        // OPTION_CLOSEST_SYNC 只取附近關鍵幀，稀疏 GOP 可能離指標很遠。
        // 這是拖曳中的粗覽，放手後由播放器精準 seek；MMR 沒有實際 PTS。
        val bmp: Bitmap? = if (Build.VERSION.SDK_INT >= 27) {
            // getScaledFrameAtTime 要的是「顯示方向」的寬高
            val dw = source.width
            val dh = source.height
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
        return try {
            val out = ByteArrayOutputStream()
            if (bmp.compress(Bitmap.CompressFormat.JPEG, quality, out)) out.toByteArray() else null
        } finally {
            bmp.recycle()
        }
    }

    // ===== 診斷（markcut/diag）=====
    //
    // 匯出被系統收掉時不會留下當機報告，只能靠「死掉前吃多少記憶體」
    // 回推。totalPss 是這個行程實際佔的實體記憶體（含 codec 那些原生
    // 配置，Runtime 的 heap 數字看不到那一塊）；availMem 是系統還剩多少
    private fun registerDiagChannel(flutterEngine: FlutterEngine) {
        val main = mainHandler
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markcut/diag")
            .setMethodCallHandler { call, result ->
                if (call.method == "videoProbe") {
                    // 播放偵測：這支檔在「系統眼中」長什麼樣、會挑哪顆解碼器。
                    // MediaFormat.toString() 直接倒出來——csd、色彩、profile
                    // 全在裡面，挑著印反而漏掉關鍵欄位
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    frameExec.execute {
                        val out = LinkedHashMap<String, String>()
                        out["機型"] = "${Build.MANUFACTURER} ${Build.MODEL} (API ${Build.VERSION.SDK_INT})"
                        try {
                            val r = MediaMetadataRetriever()
                            r.setDataSource(path)
                            fun md(k: Int, name: String) {
                                try {
                                    r.extractMetadata(k)?.let { out[name] = it }
                                } catch (_: Exception) {}
                            }
                            md(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH, "寬")
                            md(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT, "高")
                            md(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION, "旋轉")
                            md(MediaMetadataRetriever.METADATA_KEY_DURATION, "時長ms")
                            md(MediaMetadataRetriever.METADATA_KEY_MIMETYPE, "容器")
                            if (Build.VERSION.SDK_INT >= 28) {
                                md(MediaMetadataRetriever.METADATA_KEY_VIDEO_FRAME_COUNT, "影格數")
                            }
                            if (Build.VERSION.SDK_INT >= 30) {
                                md(MediaMetadataRetriever.METADATA_KEY_COLOR_STANDARD, "色彩標準")
                                md(MediaMetadataRetriever.METADATA_KEY_COLOR_TRANSFER, "色彩轉換")
                                md(MediaMetadataRetriever.METADATA_KEY_COLOR_RANGE, "色彩範圍")
                            }
                            r.release()
                        } catch (e: Exception) {
                            out["retriever"] = "失敗 $e"
                        }
                        try {
                            val ex = MediaExtractor()
                            ex.setDataSource(path)
                            for (i in 0 until ex.trackCount) {
                                val f = ex.getTrackFormat(i)
                                val mime = f.getString(MediaFormat.KEY_MIME) ?: ""
                                out["軌道$i"] = f.toString()
                                if (mime.startsWith("video/")) {
                                    try {
                                        // findDecoderForFormat 不接受帶 frame-rate
                                        // 的格式（官方文件明講的雷），先清掉
                                        f.setString(MediaFormat.KEY_FRAME_RATE, null)
                                        val dec =
                                            android.media.MediaCodecList(
                                                android.media.MediaCodecList.ALL_CODECS
                                            ).findDecoderForFormat(f)
                                        out["系統挑的解碼器"] = dec ?: "找不到！"
                                    } catch (e: Exception) {
                                        out["系統挑的解碼器"] = "查失敗 $e"
                                    }
                                }
                            }
                            ex.release()
                        } catch (e: Exception) {
                            out["extractor"] = "失敗 $e"
                        }
                        main.post { result.success(out) }
                    }
                    return@setMethodCallHandler
                }
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
                    result.success(
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
                result.success(
                    mapOf(
                        "usedMb" to mi.totalPss / 1024.0,
                        "freeMb" to sys.availMem / (1024.0 * 1024.0),
                    )
                )
            }
    }

    // ===== 素材工作檔（markcut/prep）=====
    //
    // 產生 SDR H.264 工作檔；HDR 原始色彩與最終匯出仍由呼叫端選正確來源。
    // Transformer 使用 MediaCodec＋OpenGL，硬體能力與映射結果需依裝置驗證。
    //
    // 為什麼不用 FFmpeg 轉：它的色調映射是 32 位元浮點的軟體運算，
    // 一格 4K 就要 100MB，實測一支 4K HDR 的峰值 1.7GB——那正是匯出
    // 閃退的原因，拿它做工作檔只是把同一個問題搬到匯入
    //
    // 通道方法：
    // - toWorkFile：轉檔。三段退路階梯（rungsFor），每一段轉完都先驗過
    //   輸出檔（有視訊軌、有格、第一格是關鍵幀）才回報成功；失敗原因
    //   （ExportException 錯誤碼、哪顆 codec、CodecException 的暫時性
    //   旗標）用 note 送回 Dart 進診斷報告——以前只回 null，Dart 端只能
    //   寫「工作檔失敗」
    // - probeLite／probe：容器中繼資料（probe 另外數關鍵幀），跟 iOS 的
    //   probeFile 同一套鍵。Dart 端的出廠檢驗、匯入秒進（不開播放器就
    //   知道長度）、HDR 分類全靠它。以前 Android 沒實作：Dart 端拿到
    //   null 就把每一支轉好的工作檔當「沒有畫面的壞檔」作廢重轉——
    //   實機 2018 兩支素材各轉兩次全被丟掉，編輯器只好拿 4K60 原檔
    //   逐片段播，那就是「安卓放影片會卡」
    // - cancel：取消進行中的轉檔。Transformer.cancel() 不會叫 listener，
    //   要自己回 null——不然 Dart 那邊的 Future 永遠不完成，之後每一支
    //   都排在它後面等

    /// 探測與出廠檢驗的工作緒：別佔主緒（4K 檔開 MediaExtractor 要
    /// 幾十到幾百毫秒），也別跟拖曳抽幀（frameExec）排同一條——拖曳
    /// 要跟手
    private val prepExec = Executors.newSingleThreadExecutor()
    private val prepJobs = HashMap<Int, PrepJob>()
    private val previewWorkGate = PreviewWorkGate<PrepJob> { deferPreviewPrep(it) }
    private var prepChannel: MethodChannel? = null

    /// 把一行診斷送回 Dart（進 Diag.note）。一定在主緒送
    private fun prepNote(msg: String) {
        mainHandler.post { prepChannel?.invokeMethod("note", msg) }
    }

    private fun registerPrepChannel(flutterEngine: FlutterEngine) {
        val channel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markcut/prep")
        prepChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(true)
                "setInteractive" -> {
                    previewWorkGate.setInteractive(call.argument<Boolean>("interactive") ?: false)
                    result.success(null)
                }
                "cancel" -> {
                    mainHandler.post { cancelAllPrep() }
                    result.success(null)
                }
                "probeLite", "probe" -> {
                    val path = call.arguments as? String
                    if (path == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val keys = call.method == "probe"
                    prepExec.execute {
                        // Dart 端的 probe 只拿關鍵幀密度做判斷：掃前 2000 格
                        // 就夠代表整支（advance 會真的把取樣讀進來，整支
                        // 掃等於把幾 GB 檔從頭讀到尾）
                        val m = probeFile(path, keyframes = keys, maxSamples = 2000)
                        mainHandler.post { result.success(m) }
                    }
                }
                "toWorkFile" -> {
                    val src = call.argument<String>("src")
                    val dest = call.argument<String>("dest")
                    val shortSide = (call.argument<Number>("maxShortSide") ?: 1080).toInt()
                    val jobId = (call.argument<Number>("job") ?: 0).toInt()
                    val hdr = call.argument<Boolean>("hdr") ?: false
                    val safe = call.argument<Boolean>("safe") ?: false
                    val interactiveYield = call.argument<Boolean>("interactiveYield") ?: false
                    if (src == null || dest == null) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    if (hdr) {
                        // HDR 直通代理要 HEVC 10-bit 直出；這裡只做 SDR
                        // 工作檔。轉一份 SDR 冒充代理會讓 HDR 預覽播錯顏色，
                        // 老實回 null（呼叫端照播原檔）
                        prepNote("HDR 代理：Android 沒做（只有 SDR 工作檔）")
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val job = PrepJob(jobId, src, dest, shortSide, safe, interactiveYield, result)
                    prepJobs[jobId] = job
                    if (!previewWorkGate.register(job, interactiveYield)) return@setMethodCallHandler
                    // Main-thread ownership: an old cancelled probe must not delete a retry's file.
                    File(dest).delete()
                    prepExec.execute {
                        val info = probeFile(src, keyframes = false)
                        job.srcW = (info["w"] as? Int) ?: 0
                        job.srcH = (info["h"] as? Int) ?: 0
                        job.srcHdr = info["sdr709"] == false
                        mainHandler.post { startRung(job) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 退路階梯。第一段是我們要的規格：短邊精確縮到 shortSide、關鍵幀
    /// 0.10 秒（60fps 約每 6 格，減少拖曳時從上一個關鍵幀解碼的距離）。
    /// 第二段退回 media3 的預設編碼參數，HDR 來源改由
    /// MediaCodec 做色調映射（GL 那條壞了時的另一條路；SDR 來源沒差）。
    /// 第三段 720p 保底。[safe]＝Dart 端說上一次轉出來的不能用（轉好
    /// 卻全黑那種），直接從第二段起
    private fun rungsFor(shortSide: Int, safe: Boolean): List<PrepRung> {
        val gl = Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
        val mc =
            if (Build.VERSION.SDK_INT >= 31) {
                Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC
            } else {
                gl
            }
        val all =
            listOf(
                PrepRung("短邊 $shortSide、關鍵幀 0.10 秒", shortSide, 0.10f, gl),
                PrepRung("系統預設編碼參數", shortSide, null, mc),
                PrepRung("720p 保底", minOf(720, shortSide), null, gl),
            )
        return if (safe) all.drop(1) else all
    }

    /// 起這一段的 Transformer（主緒）。起不來就直接跳下一段
    private fun startRung(j: PrepJob) {
        if (j.replied) return // 已經回過（成功或取消）：什麼都別再動
        if (j.interactiveYield && previewWorkGate.interactive) {
            deferPreviewPrep(j)
            return
        }
        if (j.cancelled) {
            finishPrep(j, null)
            return
        }
        val rungs = rungsFor(j.shortSide, j.safe)
        if (j.rung >= rungs.size) {
            prepNote("工作檔：${rungs.size} 段退路全部失敗，改播原檔：${File(j.src).name}")
            finishPrep(j, null)
            return
        }
        val rung = rungs[j.rung]
        File(j.dest).delete()
        try {
            // 短邊縮到 shortSide：直式拿到 1080x1920、橫式 1920x1080，
            // 兩種方向的解碼成本一樣（縮長邊的話直式會糊掉）。
            // media3 只給 createForHeight／createForWidthAndHeight，
            // 沒有「照短邊縮」的工廠，所以自己用探測到的尺寸算一次；
            // 讀不到就退回 createForHeight（橫式的常見情況剛好正確）。
            //
            // 直式輸出 media3 會轉成橫式編碼＋容器旋轉旗標（encoder 對
            // 寬 > 高的支援最穩）；MediaMetadataRetriever、ExoPlayer、
            // FFmpeg 都認這個旗標，不用自己轉正
            val presentation =
                fitShortSide(j.srcW, j.srcH, rung.shortSide)?.let { (w, h) ->
                    Presentation.createForWidthAndHeight(
                        w,
                        h,
                        Presentation.LAYOUT_SCALE_TO_FIT,
                    )
                } ?: Presentation.createForHeight(rung.shortSide)
            val encoderSettings =
                VideoEncoderSettings.Builder()
                    .apply { rung.gopSec?.let { setiFrameIntervalSeconds(it) } }
                    .build()
            // enableFallback：編碼器不支援要求的尺寸／位元率／profile 時
            // 由 media3 自己退到它支援的最近值，而不是直接失敗
            val encoderFactory =
                DefaultEncoderFactory.Builder(this)
                    .setRequestedVideoEncoderSettings(encoderSettings)
                    .setEnableFallback(true)
                    .build()
            val transformer =
                Transformer.Builder(this)
                    // 一律輸出 H.264：後面的 FFmpeg 合成與各家播放器都吃得下
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setEncoderFactory(encoderFactory)
                    .addListener(
                        object : Transformer.Listener {
                            override fun onCompleted(
                                composition: Composition,
                                exportResult: ExportResult,
                            ) {
                                onRungCompleted(j, rung, exportResult)
                            }

                            override fun onError(
                                composition: Composition,
                                exportResult: ExportResult,
                                exception: ExportException,
                            ) {
                                onRungFailed(j, rung, exception)
                            }
                        }
                    )
                    .build()
            val item = MediaItem.fromUri(Uri.fromFile(File(j.src)))
            val edited =
                EditedMediaItem.Builder(item)
                    .setEffects(Effects(emptyList(), listOf(presentation)))
                    .build()
            val composition =
                Composition.Builder(EditedMediaItemSequence.Builder(edited).build())
                    .setHdrMode(rung.hdrMode)
                    .build()
            j.transformer = transformer
            transformer.start(composition, j.dest)
            scheduleTick(j)
        } catch (t: Throwable) {
            prepNote(
                "工作檔第 ${j.rung + 1} 段（${rung.label}）起不來：" +
                    "${t.javaClass.simpleName}: ${t.message}"
            )
            j.transformer = null
            j.rung++
            startRung(j)
        }
    }

    /// 進度：Transformer 只提供查詢式的進度，自己每 250ms 問一次。
    /// 送 {job, value}（Dart 端 MediaPrep._wire 只認這個形狀；以前這裡
    /// 送裸的 Double，Dart 端一格進度都沒收到，匯入遮罩永遠「估算中」）
    private fun scheduleTick(j: PrepJob) {
        val holder = ProgressHolder()
        val tick =
            object : Runnable {
                override fun run() {
                    if (j.replied || j.tick !== this) return
                    val t = j.transformer
                    if (t != null) {
                        val state =
                            try {
                                t.getProgress(holder)
                            } catch (_: Throwable) {
                                Transformer.PROGRESS_STATE_UNAVAILABLE
                            }
                        if (state == Transformer.PROGRESS_STATE_AVAILABLE) {
                            prepChannel?.invokeMethod(
                                "progress",
                                mapOf("job" to j.id, "value" to holder.progress / 100.0),
                            )
                        }
                    }
                    mainHandler.postDelayed(this, 250)
                }
            }
        j.tick = tick
        mainHandler.postDelayed(tick, 250)
    }

    /// Transformer 回報成功（主緒）：先到工作緒驗輸出檔，過了才回 dest
    private fun onRungCompleted(j: PrepJob, rung: PrepRung, res: ExportResult) {
        j.transformer = null
        if (j.cancelled || j.replied) return
        val stage = j.rung + 1
        prepExec.execute {
            val m = probeFile(j.dest, keyframes = true)
            val why = verifyOutput(j.dest, m)
            mainHandler.post {
                if (j.cancelled || j.replied) return@post
                if (why == null) {
                    val sec = (SystemClock.elapsedRealtime() - j.startedAt) / 1000.0
                    val fps = (m["fps"] as? Double) ?: 0.0
                    prepNote(
                        "工作檔轉好（第 $stage 段：${rung.label}）：" +
                            "${m["w"]}x${m["h"]}" +
                            (if (m["rotated"] == true) "（旋轉旗標）" else "") +
                            " ${"%.0f".format(fps)}fps ${m["kbps"]}kbps／" +
                            "${m["frames"]} 格，關鍵幀 ${m["keyframes"]}" +
                            "（最疏 ${m["maxGopFrames"]} 格）／" +
                            "編碼器 ${res.videoEncoderName ?: "?"}，" +
                            "${"%.1f".format(sec)} 秒" +
                            (if (j.srcHdr) "，來源 HDR 已映射成 SDR" else "")
                    )
                    finishPrep(j, j.dest)
                } else {
                    // 這一行就是以前寫成「編碼器被重置吐出壞檔」的那種情況
                    // 的真相：檔案到底缺了什麼
                    prepNote(
                        "工作檔第 $stage 段（${rung.label}）回報成功但出廠檢驗不過：" +
                            "$why（編碼器 ${res.videoEncoderName ?: "?"} 送出 " +
                            "${res.videoFrameCount} 格）"
                    )
                    j.rung++
                    startRung(j)
                }
            }
        }
    }

    /// Transformer 回報失敗（主緒）：記下原因、退下一段。像是硬體暫時
    /// 被佔用（codec 開不起來、被系統回收）的先等 1.5 秒——同時在跑的
    /// 播放器／抽幀讓一下路再試，馬上重試多半撞同一堵牆
    private fun onRungFailed(j: PrepJob, rung: PrepRung, e: ExportException) {
        j.transformer = null
        if (j.cancelled || j.replied) return
        val transient = looksTransient(e)
        prepNote(
            "工作檔第 ${j.rung + 1} 段（${rung.label}）失敗：${describe(e)}" +
                (if (transient) "；像是硬體暫時被佔用，等 1.5 秒再退一段" else "")
        )
        j.rung++
        if (transient) {
            mainHandler.postDelayed({ startRung(j) }, 1500)
        } else {
            startRung(j)
        }
    }

    /// 收尾（主緒）：只回覆一次；失敗的把殘檔刪掉。
    /// 「回過了」要最先判——回成功之後誰再叫一次（遲到的退路排程），
    /// 都不准碰那份已經交出去的檔
    private fun finishPrep(j: PrepJob, path: String?) {
        if (j.replied) return
        j.tick?.let { mainHandler.removeCallbacks(it) }
        j.tick = null
        j.transformer = null
        previewWorkGate.finish(j)
        prepJobs.remove(j.id)
        if (path == null) File(j.dest).delete()
        j.replied = true
        if (path != null) {
            prepChannel?.invokeMethod("progress", mapOf("job" to j.id, "value" to 1.0))
        }
        j.result.success(path)
    }

    private fun deferPreviewPrep(j: PrepJob) {
        if (j.replied || !j.interactiveYield) return
        try {
            // cancel() releases Transformer resources synchronously. It does not notify its listener.
            j.transformer?.cancel()
        } catch (e: Exception) {
            // Do not claim the encoder has stopped if the platform could not release it.
            prepNote("工作檔讓路失敗：${e.javaClass.simpleName}: ${e.message}")
            return
        }
        j.cancelled = true
        j.tick?.let { mainHandler.removeCallbacks(it) }
        j.tick = null
        j.transformer = null
        previewWorkGate.finish(j)
        prepJobs.remove(j.id)
        File(j.dest).delete()
        j.replied = true
        prepNote("預覽工作檔已讓路，閒置後重排：${File(j.src).name}")
        j.result.success(mapOf("status" to "deferred", "reason" to "interaction"))
    }

    private fun cancelAllPrep() {
        for (j in prepJobs.values.toList()) {
            j.cancelled = true
            try {
                j.transformer?.cancel()
            } catch (_: Throwable) {}
            finishPrep(j, null)
        }
    }

    /// 出廠檢驗：Transformer 回報成功不等於檔案能用（媒體服務重置的
    /// 窗口裡硬體編碼器會吐出只有聲音、或視訊軌 0 格的殘檔卻回報成功）。
    /// 回 null＝能用；否則回一句人看得懂的原因，會進診斷報告
    private fun verifyOutput(dest: String, m: Map<String, Any?>): String? {
        val f = File(dest)
        if (!f.exists()) return "輸出檔不存在"
        if (f.length() < 4096) return "輸出檔只有 ${f.length()} bytes"
        (m["error"] as? String)?.let { return "探不到視訊軌（$it）" }
        val frames = (m["frames"] as? Int) ?: 0
        val keys = (m["keyframes"] as? Int) ?: 0
        if (frames == 0) return "視訊軌 0 格（只有聲音的殘檔）"
        if (keys == 0) return "視訊軌 $frames 格但沒有任何關鍵幀"
        if (m["firstSync"] != true) return "第一格不是關鍵幀（播放器解不開開頭）"
        if (((m["w"] as? Int) ?: 0) <= 0 || ((m["h"] as? Int) ?: 0) <= 0) {
            return "視訊軌寬高是 0"
        }
        return null
    }

    private fun errorName(code: Int): String {
        val name =
            when (code) {
                ExportException.ERROR_CODE_FAILED_RUNTIME_CHECK -> "內部檢查失敗"
                ExportException.ERROR_CODE_IO_UNSPECIFIED,
                ExportException.ERROR_CODE_IO_FILE_NOT_FOUND,
                ExportException.ERROR_CODE_IO_NO_PERMISSION,
                ExportException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE -> "讀檔失敗"
                ExportException.ERROR_CODE_DECODER_INIT_FAILED -> "解碼器開不起來"
                ExportException.ERROR_CODE_DECODING_FAILED -> "解碼中途失敗"
                ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED -> "解碼器不支援這種格式"
                ExportException.ERROR_CODE_ENCODER_INIT_FAILED -> "編碼器開不起來"
                ExportException.ERROR_CODE_ENCODING_FAILED -> "編碼中途失敗"
                ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED -> "編碼器不支援要求的格式"
                ExportException.ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED -> "GL 畫面處理失敗"
                ExportException.ERROR_CODE_AUDIO_PROCESSING_FAILED -> "音訊處理失敗"
                ExportException.ERROR_CODE_MUXING_FAILED -> "封裝（muxer）失敗"
                ExportException.ERROR_CODE_MUXING_TIMEOUT -> "封裝逾時（編碼器沒再吐格）"
                else -> "未分類錯誤"
            }
        return "$name($code)"
    }

    /// ExportException 攤平成一行：錯誤碼、哪顆 codec、底下的例外
    ///（MediaCodec.CodecException 連暫時性／可恢復旗標與診斷字串一起帶）
    private fun describe(e: ExportException): String {
        val b = StringBuilder(errorName(e.errorCode))
        e.codecInfo?.let { ci ->
            b.append("／").append(if (ci.isDecoder) "解碼器 " else "編碼器 ").append(ci.name)
        }
        b.append("：").append(e.message ?: "")
        val c = e.cause
        if (c is MediaCodec.CodecException) {
            b.append("（CodecException code=").append(c.errorCode)
            if (c.isTransient) b.append(" 暫時性")
            if (c.isRecoverable) b.append(" 可恢復")
            b.append(" ").append(c.diagnosticInfo).append("）")
        } else if (c != null && c !== e) {
            b.append("（").append(c.javaClass.simpleName).append(": ")
                .append(c.message ?: "").append("）")
        }
        return b.toString()
    }

    /// 像是「硬體暫時被別人佔著」的失敗：codec 開不起來、資源不足、
    /// 被系統回收（另一個 App 或播放器搶走了解碼器名額）
    private fun looksTransient(e: ExportException): Boolean {
        val c = e.cause
        if (c is MediaCodec.CodecException) {
            if (c.isTransient || c.isRecoverable) return true
            if (c.errorCode == MediaCodec.CodecException.ERROR_INSUFFICIENT_RESOURCE ||
                c.errorCode == MediaCodec.CodecException.ERROR_RECLAIMED
            ) {
                return true
            }
        }
        return e.errorCode == ExportException.ERROR_CODE_DECODER_INIT_FAILED ||
            e.errorCode == ExportException.ERROR_CODE_ENCODER_INIT_FAILED
    }

    /// 讀一支檔的容器中繼資料，跟 iOS 的 probeFile 同一套鍵：w/h 是
    /// 「顯示方向」（已照旋轉旗標換算）、rotated、codec（avc1/hvc1…）、
    /// sdr709、fps、kbps、durSec、sizeMb、path。
    /// [keyframes]＝再把視訊軌的取樣旗標掃一遍，數 frames／keyframes／
    /// maxGopFrames／firstSync。掃關鍵幀要把檔案讀過一遍（advance 會
    /// 真的把取樣讀進來），所以 [maxSamples] 可以設上限（超過就停、標
    /// partial）；出廠檢驗不設上限（工作檔本來就不大）。永遠不丟例外，
    /// 失敗放進 error
    private fun probeFile(
        path: String,
        keyframes: Boolean,
        maxSamples: Int = Int.MAX_VALUE,
    ): HashMap<String, Any?> {
        val m = HashMap<String, Any?>()
        val f = File(path)
        m["path"] = f.name
        if (!f.exists()) {
            m["error"] = "檔案不存在"
            return m
        }
        m["sizeMb"] = f.length() / 1048576.0
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
            var vt = -1
            var vf: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val fmt = ex.getTrackFormat(i)
                if ((fmt.getString(MediaFormat.KEY_MIME) ?: "").startsWith("video/")) {
                    vt = i
                    vf = fmt
                    break
                }
            }
            if (vf == null) {
                m["error"] = "沒有視訊軌"
                return m
            }
            val mime = vf.getString(MediaFormat.KEY_MIME) ?: ""
            val w = vf.getInteger(MediaFormat.KEY_WIDTH)
            val h = vf.getInteger(MediaFormat.KEY_HEIGHT)
            val rot =
                if (vf.containsKey(MediaFormat.KEY_ROTATION)) {
                    vf.getInteger(MediaFormat.KEY_ROTATION)
                } else {
                    0
                }
            val swap = rot == 90 || rot == 270
            m["w"] = if (swap) h else w
            m["h"] = if (swap) w else h
            m["rotated"] = rot != 0
            m["codec"] =
                when (mime) {
                    "video/avc" -> "avc1"
                    "video/hevc" -> "hvc1"
                    "video/av01" -> "av01"
                    "video/x-vnd.on2.vp9" -> "vp09"
                    "video/mp4v-es" -> "mp4v"
                    "video/dolby-vision" -> "dvh1"
                    else -> mime
                }
            val durUs =
                if (vf.containsKey(MediaFormat.KEY_DURATION)) {
                    vf.getLong(MediaFormat.KEY_DURATION)
                } else {
                    0L
                }
            m["durSec"] = durUs / 1e6
            m["fps"] = numberKey(vf, MediaFormat.KEY_FRAME_RATE)
            m["kbps"] =
                if (vf.containsKey(MediaFormat.KEY_BIT_RATE)) {
                    vf.getInteger(MediaFormat.KEY_BIT_RATE) / 1000
                } else if (durUs > 0) {
                    (f.length() * 8000 / durUs).toInt()
                } else {
                    0
                }
            // SDR(709) 判定跟 iOS 同一套：沒標記當 SDR；標了 HLG/PQ
            //（或帶 HDR 靜態資訊、Dolby Vision）才算 HDR
            val transfer =
                if (vf.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
                    vf.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
                } else {
                    -1
                }
            val hdr =
                transfer == MediaFormat.COLOR_TRANSFER_HLG ||
                    transfer == MediaFormat.COLOR_TRANSFER_ST2084 ||
                    vf.containsKey(MediaFormat.KEY_HDR_STATIC_INFO) ||
                    mime == "video/dolby-vision"
            m["sdr709"] = !hdr
            if (!keyframes) return m
            ex.selectTrack(vt)
            var frames = 0
            var keys = 0
            var gap = 0
            var maxGap = 0
            var firstSync: Boolean? = null
            while (ex.sampleTrackIndex >= 0) {
                val sync = (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0
                if (firstSync == null) firstSync = sync
                frames++
                if (sync) {
                    keys++
                    if (gap > maxGap) maxGap = gap
                    gap = 1
                } else {
                    gap++
                }
                if (frames >= maxSamples) {
                    m["partial"] = true
                    break
                }
                if (!ex.advance()) break
            }
            if (gap > maxGap) maxGap = gap
            m["frames"] = frames
            m["keyframes"] = keys
            m["maxGopFrames"] = maxGap
            m["firstSync"] = firstSync == true
        } catch (t: Throwable) {
            m["error"] = "${t.javaClass.simpleName}: ${t.message}"
        } finally {
            try {
                ex.release()
            } catch (_: Throwable) {}
        }
        return m
    }

    /// MediaFormat 的數字欄位可能是 Integer 也可能是 Float
    ///（frame-rate 兩種都有人寫），兩種都接
    private fun numberKey(f: MediaFormat, key: String): Double {
        if (!f.containsKey(key)) return 0.0
        return try {
            f.getInteger(key).toDouble()
        } catch (_: Throwable) {
            try {
                f.getFloat(key).toDouble()
            } catch (_: Throwable) {
                0.0
            }
        }
    }

    /// 把「顯示方向寬高」縮成短邊 = [shortSide]。本來就比短邊小的素材
    /// 不放大——放大不會更清楚，只是白編碼。尺寸讀不到回 null
    private fun fitShortSide(dw: Int, dh: Int, shortSide: Int): Pair<Int, Int>? {
        if (dw < 2 || dh < 2) return null
        val short = minOf(dw, dh)
        if (short <= shortSide) return Pair(even(dw), even(dh))
        val k = shortSide.toDouble() / short
        return Pair(even((dw * k).toInt()), even((dh * k).toInt()))
    }

    /// 編碼器只吃偶數邊長
    private fun even(v: Int): Int = maxOf(2, v / 2 * 2)

    private fun releaseFrames(completed: (() -> Unit)? = null) {
        frameGeneration.incrementAndGet()
        if (frameExec.isShutdown) {
            completed?.invoke()
            return
        }
        frameExec.execute {
            framePool.clear()
            completed?.let { mainHandler.post(it) }
        }
    }

    override fun onStop() {
        frameForeground = false
        releaseFrames()
        super.onStop()
    }

    override fun onStart() {
        super.onStart()
        frameForeground = true
    }

    override fun onTrimMemory(level: Int) {
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) releaseFrames()
        super.onTrimMemory(level)
    }

    override fun onDestroy() {
        // retriever 只能在 frameExec 上碰（MediaMetadataRetriever 不是執行緒
        // 安全的）：以前主緒直接 release，跟正在抽幀的 grabFrame 撞上就是
        // 原生 crash。排進同一條工作緒、排在所有已排的抽幀之後。三條工作
        // 緒也一併收掉：shutdown 讓已排的跑完、不再接新的（以前從沒收過）
        releaseFrames()
        frameExec.shutdown()
        copyExec.shutdown()
        cancelAllPrep()
        prepExec.shutdown()
        super.onDestroy()
    }
}
