# Android 播放 LAG：播放不再砍掉工作檔轉檔（2026-10-05）

## 報告（1.1.0+2232，Android、120Hz、release）

單支 2160x3840、9 秒的影片，剛匯入：

- 進場閘等滿 5 秒（縮圖帶），轉檔排著還沒開始（`preparationQueuedSources: 1`）。
- 6 秒時工作檔開始轉（`backgroundPreparations: 1`）。
- 7～9 秒按播放：轉檔被收掉，佇列回到 1（`backgroundPreparations: 0`、
  `preparationInteractionCooldown: true`），之後整輪播的都是 4K 原檔
  （`fallbackLeadUsesWorkFile: false`）。
- 播放期間沒有任何背景工作在跑（轉檔、縮圖、拖曳快取都是 0），Flutter
  建構 P95 3.3ms、繪製 P95 5.1ms，照樣卡——卡的是原檔播放本身。

## 根因

Android 的原檔用 ExoPlayer（video_player）經 Flutter 貼圖播。ExoPlayer 會把
影格提早最多約 50ms 送出、靠 SurfaceFlinger 照時間戳上屏；Flutter 的
ImageReader 貼圖不看時間戳，拿到就畫，影格間隔跟著抖（120Hz 上更明顯），
加上 4K 解碼。8 月在 Pixel 10 Pro 上量過：裸 ExoPlayer 連 1080p 都頓、mpv
順，所以架構一直是「原檔 ExoPlayer、1080p 工作檔 mpv」——Android 要順，
只能靠工作檔。

但 Android 的背景轉檔器（media3 Transformer）停不下也放不慢，原生端的讓路
（`PreviewWorkGate`）＝取消、刪掉半成品、閒置後從頭重轉。Dart 端把「播放」
也算成要讓路的忙碌：按播放就砍轉檔、播放中也不開工。結果是使用者越常播，
越拿不到工作檔，整輪都停在會頓的原檔上。iOS 沒有這個問題：那邊播放中只是
放慢（每格等 30ms），手勢才暫停，進度都留著。

## 改法（只動 Android 的排程，iOS 送給原生的值不變）

- `previewPrepYieldsToPlayback(android:)`（`lib/services/preview_preparation.dart`）：
  Android 回 false。
- 編輯器送給原生的「忙」：Android＝匯出 ||（播放沒在跑時的）手勢；iOS 照舊
  ＝播放 || 手勢。播放中點一下選片段不讓路（轉檔本來就在跑，點一下不多用
  解碼器）；真的拖時間軸會先停播放（`_onTimelineScroll`），停了就讓路。
  值沒變就不重送；每次同步都重算（播放、匯出旗標不一定跟活動狀態一起變）。
  離開編輯頁一律送「不忙」（匯出中離開也是）。
- 起播：Android 不再強制「暫停解碼」（`_syncPrepInteraction(pauseDecoding:)`）。
- `_drainPrep` 開工前的等待改走 `_waitForPrepTurn()`：Android 播放中照樣開工，
  只等匯出、播放沒在跑時的手勢，以及起播那一段（`_play` 可能正在開工作檔
  的 mpv，首格只等 2.5 秒，等不到會永久退回 ExoPlayer）。Android 播放中也
  不為了（不存在的）合成重組擋住下一支（`_settleCompBeforeNextPrep`）。
- 播放中轉好的工作檔照舊不中途抽換播放器：暫停 400ms 後換，或下一次按播放
  前換（`_ensureCtrlFor(refreshSource:)`）。

## 已知界線

- 剛匯入就馬上播的那「第一輪」，工作檔多半還沒好，仍是原檔。工作檔落地後
  （2018 那份報告：6.6 秒 4K60 約 5～7 秒），暫停或下一次播放就換成順的。
- 播放中轉檔跟 ExoPlayer 同時解 4K，那幾秒原檔可能更頓；換來的是工作檔
  一定轉得完，不會被反覆砍掉。
- 手指拖曳仍會讓 Android 的轉檔從頭來（滑動優先，使用者定的規矩）。

## 下一份報告看哪裡

- `previewRevision` 應為 `android-prep-play-1`；`previewPrepYieldsToPlayback: false`。
- 每筆取樣的 `fallbackLeadEngine`（exo＝原檔走 ExoPlayer、mpv＝工作檔）、
  `fallbackLeadWorkFileProgress`（播放中轉檔的進度）、`fallbackLeadFrameStats`
  （mpv 自己數的累計 voDropped／decoderDropped／voDelayed／hwdec；ExoPlayer
  是 null）。只讀初始化完成、還沒收掉的 mpv（handle 為 null 時呼叫 libmpv
  會原生閃退）。
- `counters`：`playbackSampleOriginalFile`／`playbackSampleWorkFile`（播放取樣
  落在原檔或工作檔的次數）、`previewPrepDeferred`（轉檔讓路幾次）；卡在原檔
  時「優先處理」會點名。
- `sourceSpecs` 多了 `codec`／`fps`／`hdr`（匯入時探過的快取）。

驗證：`test/android_prep_playback_test.dart`（真編輯頁、Android 排程：播放不送
「忙」、轉檔照跑、落地後暫停才換工作檔；被讓掉的那支在播放中重新開工；播放中
點一下不讓路；停著時手勢照舊讓路；iOS 預設照舊送「忙」）。三種改回舊規則的
寫法（播放也讓路／開工等播放停／播放中的手勢也讓路）各自都會讓對應的測試變紅
（已實測）。另有一位沒看過我推理的審查者讀過整份改動。沒有 Android 實機，
實際順暢度要看下一份報告。

## 第二步：第一次播放也要順——相機規格的原檔直接走 mpv（同日稍晚）

build 2234 的報告證實上面那步生效（播放中轉檔 1%→19%→35%、沒被砍），但第一
輪還是 ExoPlayer 播 4K60 原檔（`fallbackLeadEngine: exo`）。使用者要第一次播放
就順：

- 還沒有工作檔的原檔，尺寸是相機規格（`isCameraVideoSize`：短邊 480～4320、
  長邊 640～7680 的常見組合，直式橫式都算）就交給 mpv（`_FallbackPlayerX`：
  mpv 開不起來或首格 2.5 秒沒畫出來，自動換 ExoPlayer）。螢幕錄影那類怪尺寸
  （1080x2410…）照舊系統解碼器——mpv 硬解會破圖然後全黑，而且驗不到（23602ff）
- mpv 預覽改用省 GPU 的畫法（雙線性縮放、不做線性光縮小／抖色／去色帶、HDR
  不逐格量峰值）：預覽只有手機螢幕大，4K 原檔每格縮小用預設畫質反而掉格
- `Diag.androidOriginalMpv`（預設開）是退路：實機若更糟，改成 false 出一版
- 工作檔落地後照舊在暫停時換成工作檔（mpv 播 1080p，解碼更省）
- 報告：`previewRevision: android-original-mpv-1`；原檔播放時 `fallbackLeadEngine`
  應為 `mpv`，`fallbackLeadFrameStats.hwdec` 看 mpv 用的是零複製的 `mediacodec`
  還是 `mediacodec-copy`（4K 用 copy 可能吃力）；「優先處理」只在原檔真的落在
  ExoPlayer 時點名（計數 `playbackSampleOriginalExo`）

驗證：同一支測試檔新增尺寸規則、相機規格走 mpv、怪尺寸留系統解碼器、iOS 不變
四項；拿掉 mpv 分流或讓所有尺寸都過，對應測試會紅。
