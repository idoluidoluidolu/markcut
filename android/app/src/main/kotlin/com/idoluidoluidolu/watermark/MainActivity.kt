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
    // 拖曳預覽的「按需抽幀」：滑到哪、跟硬體解碼器要那一格。
    // MediaMetadataRetriever 不是執行緒安全的，全部排進同一條工作緒
    private val frameExec = Executors.newSingleThreadExecutor()
    private var cachedPath: String? = null
    private var retriever: MediaMetadataRetriever? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val main = mainHandler
        registerPrepChannel(flutterEngine)
        registerDiagChannel(flutterEngine)
        registerPickChannel(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markcut/frames")
            .setMethodCallHandler { call, result ->
                if (call.method != "frameAt") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val ms = (call.argument<Number>("ms") ?: 0).toLong()
                val maxH = (call.argument<Number>("maxH") ?: 540).toInt()
                // 拖曳預覽壓得兇一點沒人看得出來；當裁切底圖時會被放大
                // 到滿版，壓縮痕跡就很明顯，呼叫端自己決定
                val q = ((call.argument<Number>("q") ?: 0.8).toDouble() * 100)
                    .toInt().coerceIn(30, 100)
                if (path == null) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                frameExec.execute {
                    val bytes = try {
                        grabFrame(path, ms, maxH, q)
                    } catch (_: Exception) {
                        null
                    }
                    main.post { result.success(bytes) }
                }
            }
    }

    // ===== 挑影片：系統相片選取器 =====
    //
    // file_picker 的 FileType.video 在安卓走 SAF 文件選取器——開出來是
    // 檔案管理器的「最近」，不是相簿。Android 13 起有系統相片選取器
    // （ACTION_PICK_IMAGES），可以限定只列影片、直接開在相簿的長相。
    // 更舊的機型回 null，Dart 端退回原本的 SAF 那條路

    /// 等使用者選完的那次呼叫（一次只會有一個選取器在畫面上）
    private var pickReply: MethodChannel.Result? = null
    private val pickReq = 9137

    /// 把 content:// 複製進快取的工作緒（大檔要幾秒，不能佔主緒）
    private val copyExec = Executors.newSingleThreadExecutor()

    private fun registerPickChannel(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "markcut/pick")
            .setMethodCallHandler { call, result ->
                if (call.method != "videos") {
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
                val max = (call.argument<Number>("max") ?: 30).toInt()
                    .coerceIn(2, MediaStore.getPickImagesMaxLimit())
                pickReply = result
                val intent = Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                    type = "video/*"
                    putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, max)
                }
                startActivityForResult(intent, pickReq)
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickReq) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val reply = pickReply ?: return
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
            main.post { reply.success(out) }
        }
    }

    /// content:// → 快取檔。保留原檔名（介面上顯示素材名稱用）
    private fun copyToCache(u: Uri): String? = try {
        var name: String? = null
        contentResolver.query(u, null, null, null, null)?.use { c ->
            val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (i >= 0 && c.moveToFirst()) name = c.getString(i)
        }
        val safe = (name ?: "video_${System.currentTimeMillis()}.mp4")
            .replace('/', '_')
        val dir = File(cacheDir, "picked").apply { mkdirs() }
        var f = File(dir, safe)
        var n = 1
        while (f.exists()) f = File(dir, "${n++}_$safe") // 同名不覆蓋
        contentResolver.openInputStream(u)?.use { input ->
            FileOutputStream(f).use { output -> input.copyTo(output, 1 shl 16) }
        } ?: return null
        f.absolutePath
    } catch (_: Exception) {
        null
    }

    private fun grabFrame(
        path: String,
        ms: Long,
        maxH: Int,
        quality: Int = 80,
    ): ByteArray? {
        if (cachedPath != path) {
            retriever?.release()
            retriever = MediaMetadataRetriever().also { it.setDataSource(path) }
            cachedPath = path
        }
        val r = retriever ?: return null
        val us = ms * 1000
        // OPTION_CLOSEST_SYNC＝取最近的關鍵幀，不用從頭解到指定格。
        // 拖曳預覽要的是「跟手」，差半秒的畫面人眼分不出來。
        // 注意：MediaMetadataRetriever 抽幀是系統偏好「軟體解碼器」的
        // 路（AOSP FrameDecoder 用 kPreferSoftwareCodecs 挑），4K 一格
        // 要幾百毫秒，但不佔硬體解碼器的名額——跟轉檔／播放不搶 codec，
        // 搶的是 CPU
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
        bmp.compress(Bitmap.CompressFormat.JPEG, quality, out)
        bmp.recycle()
        return out.toByteArray()
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
    // 把 4K（HDR）原檔轉成 1080p SDR 的 H.264 工作檔，之後預覽、拖曳、
    // 匯出都用它。Transformer 走 MediaCodec＋OpenGL 的硬體管線，
    // HDR→SDR 的色調映射也是系統做的，跟播放器的顏色一致。
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
                    val job = PrepJob(jobId, src, dest, shortSide, safe, result)
                    prepJobs[jobId] = job
                    prepExec.execute {
                        File(dest).delete()
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
        prepJobs.remove(j.id)
        if (path == null) File(j.dest).delete()
        j.replied = true
        if (path != null) {
            prepChannel?.invokeMethod("progress", mapOf("job" to j.id, "value" to 1.0))
        }
        j.result.success(path)
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

    override fun onDestroy() {
        retriever?.release()
        retriever = null
        cancelAllPrep()
        super.onDestroy()
    }
}
