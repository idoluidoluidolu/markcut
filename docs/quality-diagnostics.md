# 下一版品質驗收

## 2026-09-20：iPhone 17／約五支非 4K HDR 素材

使用者補充裝置為 iPhone 17、約五支影片，非 4K、HDR。目標是匯入後立即
拖曳、多素材往返、素材與樣式更新跟手，並保持 HDR 顏色。209 報告的上一輪
中斷時 footprint 為 2111MB；目前空專案的 1.3GB 取樣屬於另一輪，不能據此
定位是哪個池持有，也不能判定這次必然是 jetsam。

本輪 `preview-resource-release-1` 在既有未提交的代理記憶體退讓修正上追加：

- `ClipReader` 的三處 `gen == self.gen` 實際比較同一個成員，沒有檢查參數
  `g`。改由鎖內 `MCReaderLifetime` 管理世代；stop 同樣使舊世代失效。舊 setup
  不得發布 reader/output，舊失敗不得把新 reader 標死，舊 sample 不得入列。
- Metal 拖曳原本只新增當前素材的 reader，離屏回收僅在播放同步路徑做。
  現在拖曳、佈局更新與閒置 tick 都回收離屏／移除的 reader，保留 0.5 秒
  setup 緩衝及播放前方 1.5 秒預捲；多軌目前所需的 reader 仍保留。
- reader 長駐執行緒補上入口與逐 sample autorelease pool，避免框架暫存物件
  必須等整條解碼執行緒退出才釋放。依據
  [Apple autorelease pool 指引](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html)。
- Flutter 收到記憶體警告時清掉離屏拖曳幀、最近幀與解碼器，取消排隊與
  晚到抽幀結果；本次編輯器的歷史快取預算由 96MB 降到 24MB。當前可見
  素材保留，故這是歷史淘汰門檻，不是程序或全部影格的硬上限。
- SDR／HDR 的 `onStart` 改為等黑盒子紀錄落地後才叫原生轉檔。之前
  `unawaited(Diag.mark(...))` 讓原生已開工、檔上仍是排隊中；等待期間若
  開始手勢，會再次檢查互動狀態並讓路，不配置新解碼器。
- 診斷新增 Metal `readerCount`／`pumpCount` 與 `scrubEncodedLimitBytes`。
  計數不等於 OS 實際 decoder 數或記憶體，不能當作完整占用。

本輪不更動 HDR 轉換、色彩標記、預覽或匯出解析度。Metal 的世代錯誤是
程式可確認的缺陷，但 209 附件沒有崩潰時的 Metal 活動或系統 crash report，
不能宣稱這就是本次五支 HDR 閃退的唯一原因。單靠程式／單元測試也不能
證明代理尚未就緒的第一次 seek 已流暢。

本機驗證：`flutter test --no-pub --exclude-tags golden --reporter expanded`
最終 **980 通過／8 跳過**。新增記憶體警告晚到結果、跨素材回收、保留目前
畫面及等待開始紀錄時手勢優先的回歸測試。匯入測試補齊原生記憶體通道
mock，沒有放寬原有斷言。修改的服務與測試 `dart analyze` 無問題；編輯器
保留既有 `_sceneSnapshot` 的 `prefer_function_declarations_over_variables`
提示（該閉包為維持 dispose 時 identity，與本輪無關）。Swift 新增取消／
重啟世代與多素材 reader 窗口測試，Windows 尚不能編譯或執行。

待 iOS 驗證：Xcode 編譯及 RunnerTests；iPhone 17 冷啟動匯入同五支 HDR，
立即來回拖曳並重複跨素材，播放／暫停、更新素材及樣式，再離開回空專案。
追蹤記憶體是否隨重複輪次持續上升、reader 是否在離屏後下降，以及真正
上屏的延遲／閃動；同幀比較原片、預覽與匯出高光和膚色。系統終止原因需
對應 [JetsamEvent／crash report](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports)。

## 2026-09-15 多影片匯入後滑動閃退回報

上次中斷記號為 HDR 代理轉檔中，程序 footprint 2111MB、App 可用額度
1265MB（`os_proc_available_memory`，不是全系統空閒 RAM）。貼出的 71 格與
UI 154ms 是重新進場後的樣本，不能当作上次閃退時的執行緒量測；未提供
對應 crash／JetsamEvent，不能判定必然是 OOM、watchdog 或 Swift 例外。

`proxy-memory-admission-1` 包含上一輪尚未推送的解碼需求／換件修正，另補：

- iOS 預覽代理在接單、配置後開工前及執行中檢查記憶體。工程高水位為
  實體記憶體 20%，限制在 768–1536MB；App 可用額度小於 512MB 也退讓。
  收到 OS 記憶體警告同樣停止預覽代理。恢復需至少 5 秒、footprint 低於
  高水位 256MB 且可用額度至少 768MB。這不是 jetsam 的安全保證或系統門檻。
- 原本手勢暫停只停 sample 讀取，仍持有 reader／writer／緩衝；現在記憶體
  不足時會取消該代理。影片／聲音 append 佇列各自結束一次，取消 writer
  後才回覆，避免提早釋放 Dart 單工作名額讓新舊 codec 重疊。
- HDR 及 SDR 的 deferred 回傳一致，不當成 codec 失敗，也不進保守轉檔
  fallback。Dart 尊重 5 秒 retryAfter，未恢复時不忙迴圈重試；原片不刪除、
  半成品不寫入代理索引，不降低 HDR 或匯出解析度。

預算只限制可退讓的編輯器代理，不取消使用者匯出。原生 250ms 取樣不能捕捉
所有瞬間尖峰；如果預覽本身一直超過恢復門檻，代理會繼續延後，原片預覽仍
可能卡頓。這是避免資源繼續疊加的防護，不是所有記憶體來源已釋放或閃退已
修復的證明；需 Xcode 編譯和同專案實機匯入／拖曳驗證。

## BUILD 208 加圖片閃退回報（尚待實機驗證）

208 附件的上次未正常結束記號停在 HDR 代理轉檔，當時 2542 MB；本輪則為空白編輯器，不能用其零樣本否定使用者的閃退或推定確切 crash 類型。附件尾端截斷；需要對應的 iOS crash／JetsamEvent 才能確認系統終止原因。208 的操作快照不含上一節修改新增的欄位，本機修正當時尚未推送。

此次確認並修改兩處風險：裁切頁原本無條件解碼全尺寸照片，現在先讀 metadata，再請求最長邊 2048 的預覽；完成時依原圖尺寸及裁切範圍決定解碼／輸出尺寸，不以小預覽犧牲成品解析度。完整 8000×6000 圖輸出 4096×3072 時只需請求長邊 4096；挖取小區域且需要原始細節時仍可能需要全尺寸來源，不能宣稱消除所有大圖解碼峰值。Picture、Codec、ImageDescriptor、ImmutableBuffer 及輸出 Image 的錯誤／離頁清理已補齊。

影片浮水印面板新增選圖工作生命週期：在系統選圖器開啟前等待原生收到暫停背景 sample 解碼的旗標，持續到取消、失敗或裁切完成；同時暫停播放，背景縮圖與可讓步的合成重建也讓路。新增 `watermarkImageImporting` 操作欄位。這是降低已確認的競爭，不是 BUILD 208 閃退原因已被證實，也不代表 2.5 GB 程序記憶體問題已全面解決。

報告環境新增 `previewRevision: image-import-guard-1`，即使空白專案也能辨認是否包含這次程式路徑；這是修正識別，不是通過實機驗收的標記。

本輪驗證：靜態檢查通過；Codemagic 同條件功能測試 970 通過／8 跳過；裁切頁 golden 通過。新增測試涵蓋大圖預覽尺寸、裁切成品解析度、選圖前等待暫停確認、取消／失敗解除暫停及重複點擊防護。尚無對應 iOS crash log，也未在 iPhone 上驗證閃退已排除。

## BUILD 207 回報後的修正（2026-09-14）

- 記憶體警告不再清空所有正在用的浮水印：歷史部件淘汰，目前位元組清單在 8 MiB 內保留身分，繼續供原生差量重用；解碼熱池縮到 8 MiB，保留最近圖片、不 dispose 畫家仍借用的圖片。這兩個池不是整個程序的記憶體上限。
- 編輯器部件繪製／回讀單工，互動版優先於排隊中的全解析細化；同鍵仍共用工作。已開始的工作安全完成，離頁丟棄未開始工作。匯出不經這個佇列。
- 快速拖曳合併為約 16.7 ms 一次的最新目標；首發即送，放手精準 seek 立即送並清掉舊尾發。這是請求頻率限制，不是顯示 FPS 保證。
- 背景代理在直接操作及 600 ms 冷卻期暫停影音 sample 讀取，取消最多隔 50 ms 再檢查；只播放時維持慢速前進，閒置恢復正常。代理不重頭轉，但持續操作會延後代理完成，不能把它宣稱成全面縮短匯入時間。
- 原生代理的影音迴圈逐 sample 回收 autorelease 暫存；不改 HDR 格式、色域、匯出解析度，也不啟用另一條 HDR 顯示平面。

新增操作現場欄位：`preparationGesturePause`、`previewSeekCoalesced`、`overlayPartCacheLimitBytes`、`overlayRasterQueued`。後者是排隊工作數，不是同時 GPU 繪圖數。

207 的 2581 MB 取樣峰值不能歸因於僅數 MB 的疊圖池。上述修改減少可確認的重工、競爭與暫存，但尚未實機證明消除原生解碼／GPU 記憶體峰值及 seek 重畫長尾。需在同一專案比較新舊版本的冷匯入、連續縮放、快速往返拖曳與停手定位，並確認不閃動及同幀 HDR 色彩。Windows 測試不能代替 iOS 原生編譯或這項驗收。

本機驗證：`flutter analyze --no-pub` 通過；依 Codemagic 原有條件 `flutter test --no-pub --exclude-tags golden`，962 通過／8 跳過。包含 golden 的全套為 969 通過／8 跳過／4 失敗；在獨立的修改前 `d797bf2` 工作目錄重現同樣四個快照失敗，四張測試輸出 PNG 的 SHA-256 與本次完全相同（匯出頁、畫質選單、GIF 加素材、排序面板），未修改快照或 CI 排除規則。新增的 iOS 代理暫停／取消測試尚未於 Xcode 執行。

## v2：這一版新增的定位能力

206 回報補強：記錄時間軸拖曳起手、縮圖工作／排隊數，以及原生 seek 的最近 30 次回呼等待（含目標、精準／寬容、後續目標與主佇列耗時）。冷啟動縮圖帶改為單條工作，封面與每張補圖都等待互動結束及冷卻窗，避免在往返拖曳的短暫停頓搶解碼；已送出的單張抽圖不強制中斷。這是降低可確認的競爭，不代表已實測消除所有 iPhone 拖曳卡頓。

- 慢操作記下「開始時」的時間軸位置、選取片段、播放／拖曳／樣式手勢、背景準備及快取狀態；完成時已換片段也不會張冠李戴。
- 編輯器在前景每 3 秒低頻取樣，一次只允許一組讀取、每通道最長等待 2 秒。保存最近 90 筆資源趨勢與本輪記憶體最高取樣的現場；不是連續的瞬時峰值。
- 分列 Dart 部件快取、Logo 解碼熱快取、縮圖／拖曳圖的編碼資料、原生目前疊圖，以及背景準備數。這些池可能重疊，不能加總後當成完整的程序記憶體歸因。
- 部件快取命中／未命中／共用進行中工作／淘汰數於每輪歸零。記憶體警告記下釋放快取前的操作狀態。
- 原生重畫拆成 seek 回呼等待與主佇列等待，並記錄取消、使用者 seek 中略過、等待中的合併。每個播放器有獨立 instance ID，以免重建後計數被誤認為改善。
- 原生 CI 記錄開始排隊、合成耗時、缺來源格、取消／配置失敗，以及樣式版本是否在製作期間變動；保存最近 30 個慢事件。此資料為預覽程序累計，附 compositor instance 和原生 uptime，匯出不納入。
- 報告附素材尺寸／類型、代理可用狀態、片段布局（最多 100 個來源／200 個片段，超過會標示），不含來源名稱、路徑、文字及圖片內容。
- 「複製驗收報告／JSON」會先更新資料；舊播放診斷的「出報告」也附上完整 v2，包含記憶體趨勢，不用另外貼兩次。

最有效的回報：開新一輪 → 用原本會卡的專案操作 2～3 分鐘（圖片／文字樣式、影片缩放、開關軌道、播放／暫停）→ 若有問題記下大約操作與時間軸秒數 → 回診斷器標記並複製。
若問題是顏色或閃動，另附同一幀的原片／預覽／成品比對；錄屏可協助定位閃動，但不能作為 HDR 色準證明。

影片編輯器右上角「品質診斷器」。進入編輯器自動開一輪本機記錄；
可按「開始新一輪」清空本輪資料（不動專案），關閉面板後操作。
要測首次匯入，先在空白專案開一輪，再選素材。

## 最小實機矩陣

- 分別用 SDR、HLG／Dolby Vision 原片，記下機型、iOS、是否低耗電／發熱。
- 單影片、三影片多軌；再各加圖片、文字、GIF、手繪、馬賽克。
- 首次匯入與暖快取各一次；播放 30 秒並跨接縫，播放／暫停 5 次。
- 首尾與跨接縫拖曳；文字／圖片移動、縮放、旋轉、透明度各 10 次。
- 影片／圖片／浮水印軌隱藏與恢復各 5 次。
- 暫停、播放、加圖片前後用**相同時間點**比較；匯出 SDR／HDR 後比對原片及相簿。
- 回診斷器標記「可接受／有問題」，更新資料並複製報告或 JSON。
  問題時間是回報時的時間軸位置，並非自動偵測閃屏發生時間。

## BUILD 209 回報後：解碼需求與換件競爭

209 的 `image-import-guard-1` 已確認包含前次修正。本輪圖片解碼 24.8ms、
樣式重製最大 31.1ms、幾何 ACK 最大 21.9ms；原生重畫行程歷史仍有
537ms 長尾，程序記憶體取樣峰值 2633MB。不能把 ACK 快解讀成畫面跟手，
也不能把 31 筆記憶體警告事件（部分同時重複）當成 31 次獨立 OS 警告。

`hidden-decoder-idle-swap-1` 修正兩個可從程式確認的競爭來源：

- 隱藏軌道在產生 CI 指令的來源需求之前剔除，未隱藏的層仍做保守遮蔽判定。
  以前隱藏會永久停用遮蔽剔除，且被隱藏影片仍在 requiredSourceTrackIDs 中。
  顯示／隱藏集合改變時只更新同一播放器的 videoComposition，不換 player/item；
  幾何變更仍保留既有即時參數與 seek 重畫路徑。全部隱藏時不保留舊合成影像；
  沒有可見影片的指令仍可能要求一條有媒體的載體軌，不能宣稱零解碼。
- 背景換檔、合成重建與原生準備共用直接互動判定，涵蓋選圖／裁切、滑桿、
  時間軸手指和預覽手指。已有播放器時，非編輯入口也不能繞過互動檢查；
  非同步烘圖完成後再檢查，停手後保留 600ms 閒置窗。明確起播可完成必要的
  待辦結構重建，不會被起播自己設下的準備暫停旗標擋住。

`requiredDecoderTracksMin/Max` 是目前 CI 指令要求的軌數範圍，不是解碼器實例
或實際記憶體。`hiddenTimelineTracks` 和 `occlusionEnabled` 顯示同份計畫的狀態。
這些修改不改匯出、HLG／BT.2020、顯示平面或預覽解析度；不能保證 AVFoundation
立即歸還既有緩衝。已進入原生建置的工作也不能由 Dart 檢查倒追回取消。
必須用 iOS 實機驗證隱藏／全部隱藏／恢復、連續縮放及快速往返拖曳；
Windows 無法執行新增的 Swift 測試或驗證實際上屏、色準與記憶體降幅。

本機驗證：`flutter analyze --no-pub` 通過；依既有 Codemagic 條件
`flutter test --no-pub --exclude-tags golden`，971 通過／8 跳過。
新增的選圖／裁切延後重建測試驗證持有期間不換件、閒置後待辦不遺失；
Swift 測試補上隱藏來源先於遮蔽判定、解碼需求縮減、全部隱藏及恢復的案例，
尚未在 Xcode 執行。未更新 golden 基準或更動 CI 排除規則。

## 判讀界線

「取樣內達標」只表示該階段達到初步 60Hz 工程門檻。
樣本不足或平台不支援一律待量測；失敗不混入成功延遲平均。
P95 使用最近 300 筆，最大值保留本輪所有成功樣本；保留最多 100 個問題事件／未完成操作。
關閉記錄不代表未完成操作失敗；重開一輪丟棄舊非同步操作的收據。

通道確認不是上屏；Flutter 幀時間與播放時鐘不能當作 AVPlayerLayer 的顯示 FPS。
匯入計時不包含系統選檔、選圖前的 iCloud 下載與人工裁切時間。
原生快照只讀現有狀態，不抽取畫面、轉檔、匯出或啟動像素測試。
`watermarkImageParts` 另計浮水印內啟用的圖片；`imageSources` 只計時間軸圖片來源。
`overlayPartCacheBytes` 為 Dart 部件快取，不等於解碼器或 GPU 總記憶體。
`previewSourcesWithoutProxyAtBuild` 可區分代理開關開啟與建置當下實際仍用原檔。
`pausedRedraw*ProcessLifetime`、`itemSwapsProcessLifetime`、`vcRedrawSwapsProcessLifetime`
為 App 行程累積的重畫／換件量測，重開診斷不歸零；比較操作前後差值，不能當本輪顯示 FPS。
HDR 像素鏈與快路自檢是**行程累積**資料，可能來自舊專案；不能代替本輪同幀驗色。
HDR 色彩標記正確不證明色準、EDR 顯示或 Dolby Vision 中繼資料正確。
目前不提供自動色差儀、實際顯示 FPS、閃屏或系統強制終止（jetsam）的自動通過判定。
未重現問題不等於通過；色準仍需相同內容與顯示條件下的實機／原片／成品比對。

## 低干擾與隱私

本機記憶體內記錄，無網路上傳、無素材影像或文字內容，無素材路徑。
診斷面板打開期間不把自身 Flutter 繪製計入 UI 指標；其他操作仍可完成計時。
關閉 App 不保留本輪資料，離開編輯器停止記錄；請先複製。
原本的長按播放診斷仍保留，可補充較完整的底層事件與當機線索。
v2 的慢事件／資源歷史都有容量上限，無逐幀圖像回讀；仍須實機確認取樣開銷。
自動診斷能縮小問題範圍，不能保證所有未重現問題都被測出，也不能保證下一版全部修完。
使用 release/profile BUILD 量性能，debug 的耗時不可當作正式版驗收。

在 Windows 可以測試量測器與 Flutter 接線；新增 iOS 快照需於 Xcode 編譯、實機驗證。


## BUILD 210 回報後：圖片重用、樣式回讀及插入提示

回報 `preview-resource-release-1` 的四個來源尺寸皆為 2160×3840，當下沒有
可用代理。程序記憶體取樣約 2405MB、峰值 2857MB；浮水印與部件快取遠小於
此數值，不能把高記憶體全歸因於圖片。77 筆 pressure trim 不代表 77 次獨立
系統警告，也不能單憑程序峰值確診 jetsam。

- Flutter UI／raster P95 約 0.83／1.94ms，未包含原生影片呈現。
- 圖片檔案讀取 3.6ms、Logo 預覽解碼 238ms；當輪只有浮水印圖片，沒有時間軸
  圖片來源。既有計時沒有涵蓋裁切出檔，無法據此推定整個匯入只花 242ms。
- 樣式重製最大 446ms；PNG 回讀最大 205ms，而 RGBA 回讀最大 8.24ms。
  不同工作尺寸不一定相同，不能視為嚴格的格式效能 A/B 測試。
- 暫停重畫的 seek 回呼最久約 749ms，主佇列等待最久 1.59ms。這是另一段
  原生播放器延遲，不能用 Flutter 畫面幀時間或通道 ACK 取代。

本輪修正標記 `crop-reuse-raw-preview-1`：

1. 浮水印圖片匯入／重新裁切，在 PNG 出檔時從已存在的 sRGB 裁切影像建立
   最長邊 1080 的獨立預覽快取，避免回到編輯器再解碼整份 PNG。裁切原圖仍
   依原先上限出檔；快取不接管原始 raster 的生命週期，也不取代匯出尺寸。
   廣色域 raster 保留原本的 PNG 解碼路徑，避免快取與編碼成品的色域不同。
   快取失敗不會丟棄成功的裁切结果。新增 `logoPreviewSeeded` 計數。
2. 編輯器部件的像素數與 raw 傳輸上限使用同一規則：互動中最多 512K 像素／
   2MiB，停手後最多 2M 像素／8MiB。像素上限維持原值，較大部件不再因超過
   舊 1MiB raw 門檻而改走 PNG。這會增加部分傳輸的位元組數；既有單一 raster
   佇列、部件差量傳輸、LRU 與壓力快取上限繼續限制持有量，實機仍須量測。
3. 拖曳素材時顯示左右插入提示與垂直落點線。提示和放下共用
   `placementOnTrack`；空隙、自由疊加樣式、新增圖層不顯示錯誤的左右提示。
   原本「前半插左／後半插右／後段讓位」規則保留，懸停不修改素材。
4. 診斷補上「裁切預覽解碼」和「裁切確認出圖」。確認出圖從按完成起計，
   包含解碼、點陣化、PNG 編碼與快取準備，不把人工選圖／裁切時間算進去。

尚需實機確認：同一批 HDR 原片、停手後高畫質補圖、連續樣式調整、圖片裁切
確認耗時、記憶體峰值以及 HDR 原片／預覽／成品同幀比較。原生精準 seek 的
長尾與代理未就緒問題未由本輪修正證明消失；Windows 無法完成 iOS 編譯或
實際上屏測量。

本機驗證：Codemagic 同等 `dart analyze lib test` 為 0 error／0 warning（保留
原有一則 info）；`flutter test --no-pub --exclude-tags golden --reporter expanded`
為 993 通過／8 跳過，輸出沒有 `[E]` 且正常結束。最後補上 sRGB 保守限制與
手機窄螢幕測試後，圖片快取／裁切／插入互動的 22 項針對性測試再次全過，
靜態分析與 `git diff --check` 通過。本輪沒有改動 Swift、套件版本或 CI 規則。


## BUILD 210 回報後：原生暫停重畫與解碼資源

修正標記 `bounded-native-redraw-1` 延續圖片重用與左右插入提示，處理報告中
749ms seek 回呼、代理未就緒與高記憶體的原生路徑。這是程式行為修正，尚無
同批素材的新 iPhone 效能數據，不能宣稱 2857MB 峰值已降至特定數值。

- 暫停樣式更新改為複製目前 `AVVideoComposition`，保留指令、HDR 色彩設定及
  `AVPlayerLayer`；最多一張等待中的重画，只保留最新操作。收到相符時間與
  樣式世代的 CI 完成回報後才能排下一張，頻率上限 30 次／秒。這與舊版每
  40ms 重產整份合成計畫不同。樣式已再次更新也必須釋放已完成的舊工作，
  但舊樣式影格不得存進目前快取。使用者 seek 中收到的樣式改動留到定位後。
- 某個播放器若 250ms 內沒有相符合成回報，取消等待，該播放器退回既有單一
  seek 路徑；診斷會留下 timeout。播放、定位、換件與釋放會取消舊的等待。
- 移除暫停及精準定位完成後的自動 preroll。設定短的 forward buffer 偏好；
  這是 AVFoundation 提示，並非硬性記憶體或解碼影格上限。
- 縮圖的兩個 `AVAssetImageGenerator` 閒置一秒後釋放；新的取格會使舊的
  閒置計時失效。所有建立、取格與回收共用同一串行佇列，避免在取格中拆除。
- 合成抽幀輸出口以使用數量管理；成功、逾時、轉換失敗都會釋放，且從最初
  的 player item 拆除。播放器 dispose 同時清理輸出口、保留合成與音訊材料。
- 預覽代理的 admission 改看 OS 回報的剩餘行程記憶體額度。原先已超過固定
  footprint 門檻的原片播放器，可能永遠無法開始建立較省資源的替代代理。
  新工作保留至少 1GiB、最多 1.5GiB（依實體記憶體比例），執行中保留至少
  768MiB；不足或收到壓力會取消工作並冷卻五秒，未能取得量測也延後。
  這些是工程預留值，並非對 jetsam 限制或轉檔峰值的保證。
- 系統記憶體警告另外釋放預覽合成器的上一格 CI graph 與 CI 暫存；此工作
  與合成共用序列，並限制清理頻率，避免警告風暴造成反覆重編譯。

新增診斷：`availableProcessMemoryMB`、`pausedRedrawRenderCompleted`、
`pausedRedrawRenderedEpoch`、`pausedRedrawRenderMaxMs`、
`pausedRedrawCopyTimeouts`、`pausedRedrawCopyInFlight/Pending`、
`preferredForwardBufferSeconds`、`prerollArmed`、縮圖池 `idleReleases`。
新重畫耗時量到 CI 合成完成；舊 `redrawSeekMaxMs` 仍只計後備 seek。
兩者皆不冒充 AVPlayerLayer 實際上屏時間。

重畫方式依據 Apple [QA1966](https://developer.apple.com/library/archive/qa/qa1966/_index.html)；
相同 custom compositor class 的實例沿用行為見
[customVideoCompositor](https://developer.apple.com/documentation/avfoundation/avplayeritem/customvideocompositor)。

本機檢查：`dart analyze lib test` 為 0 error／0 warning，保留原有一則 info；
Codemagic 同等完整 Flutter 測試 994 通過／8 跳過，日誌無 `[E]` 且正常完成。
新增 XCTest 涵蓋連續樣式合併、取消、舊 timeout、HDR 合成設定保留、
代理記憶體預留、縮圖閒置回收、真正播放器的無 seek 重畫，以及並行抽幀
失敗後拆除原 item 輸出口。iOS 編譯及 XCTest 以原生 CI 結果為準。

原生測試使用固定 64×64／30fps／30 格 H.264 素材，只打包於 XCTest。
素材建立不再依賴模擬器即時 AVAssetWriter 編碼，避免建立測試檔逾時後
以未完成影片繼續測試；來源、生成方式與用途列於 RunnerTests/Fixtures。


## 最新版批次匯入閃退：serial-media-import-1

這輪針對「影片編輯模式一次匯入多支，在讀取時閃退」。尚無該次 crash／
jetsam 報告，因此以下是已確認的程式缺陷與防護，不能冒充實機根因驗證。

- PHPicker 舊實作用 serial queue 呼叫非同步 `loadFileRepresentation`，實際
  仍同時啟動整批 provider；各回呼也同時修改 errors／進度。改為
  `FPFileImportBatch`：前一支檔案複製完成才啟動下一支，所有集合及計數由
  同一佇列管理。保持點選順序、部分成功、原檔 HDR 位元資料及 tmp 儲存。
- 暫存來源仍在 provider 回呼內複製，沒有把 URL 延後使用：Apple 明確說明
  [來源檔案於回呼返回時刪除](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation%28fortypeidentifier%3Acompletionhandler%3A%29)。
- 新選取取代未完成的批次時取消舊 NSProgress、丟棄排隊素材、清理尚未交付
  的複本。進度與最終結果在 main 檢查請求身分；事件取消訂閱後不呼叫 nil
  sink，舊批次也不會把新批次的載入狀態關掉。
- 首合成完成初始定位後才開始進場縮圖；中繼資料匯入／合成重建期間不加開
  拖曳幀 decoder，背景縮圖也等待重建完成。原有五秒 UI 閘門獨立運作；
  已逾時或離頁時不補開另一輪阻塞縮圖。
- 200px 時間軸縮圖只保留當前一個 generator，同支連續取樣仍重用；不同素材
  不留下前一支的 decoder。互動大圖原有容量二與一秒閒置回收維持。
- HDR AVPlayerLayer 及 native scrub 接手後，統一禁止額外的 SDR JPEG 拖曳
  抽幀，包含換件前已排隊的工作。時間軸縮圖仍照常；顯示與輸出色彩路徑不變。

回歸覆蓋：五個延遲 provider 逐支開工、來源 URL 回呼後消失、單支失敗與
順序、取消後無後續載入與暫存殘留、全不支援類型正常回錯、縮圖池容量、
HDR 拖曳仍 seek 但不抽 JPEG、首合成延遲與離頁的完整生命週期。
請以同批 iPhone 17 HDR 素材驗證冷匯入、立即往返拖曳及播放／暫停。
