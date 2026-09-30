# MarkCut 稽核修正紀錄 — 2026-09-27

本文件對應 `APP_REVIEW_2026_09_26.md` 的 R01–R11。修正位於工作目錄，尚未提交、推送或發版。程式與可在 Windows 執行的驗證已逐項處理；iOS 原生編譯、真機壓測、商店交易與系統還原，不能用 Dart 測試結果代替。

## 修正結果

| 編號 | 已落實的變更 | 驗證與剩餘條件 |
|---|---|---|
| R01 | Android release 移除 debug 簽章回退；正式建置驗證金鑰設定、私鑰別名與憑證，拒絕 Android Debug 憑證。提供 `android/key.properties.example`。 | 缺少簽章、debug 憑證拒絕及有效測試憑證接受，3 個檢查通過。測試憑證只用於驗證，沒有簽署產品。實際正式金鑰未提供。 |
| R02 | 工作檔清理與草稿存刪共用序列鎖；保護草稿引用、開啟中的編輯器、原檔消失後的唯一備份。路徑先解析符號連結。舊草稿無引用清單、清單損壞或目錄不可讀時停止清理。 | 回歸覆蓋超額、孤兒檔、唯一複本、舊草稿、開啟中的編輯器、目錄失敗。寧可暫時超額，不刪唯一素材。 |
| R03 | 保存前預檢全部素材；超額、遺失或複製失敗時明確回報失敗並留在編輯頁。不再把暫存路徑當成保存完成。素材經暫存檔、大小核對及 rename 後提交。 | 單檔及整份草稿素材上限均為 300 MiB；超過時需減少素材或先匯出。照片、拼圖、批次均接入錯誤回報。 |
| R04 | Android file_picker 將 provider 顯示名稱與儲存名稱分開，使用 UUID、受限副檔名與 canonical parent 驗證。保留原本 iOS fork 修正。 | Kotlin 編譯及 2 個 JVM 測試通過，涵蓋 `../`、絕對路徑、反斜線、引號、Unicode 及碰撞隔離。 |
| R05 | FFmpeg 匯出、音訊合併、倒轉、縮圖、GIF、HDR 探測與波形一律使用 argument list。外部路徑不再經命令字串 parser；硬體／軟體回退也依 argument 操作。 | 注入檔名保持單一 argument；真實桌面 FFmpeg GIF 像素測試涵蓋修剪、速度、倒轉、循環與分段。這不等於原生 codec 漏洞均已修復。 |
| R06 | 配額依最終引用的唯一素材集合計算，包含已存在複本。重複引用不重複計費，重複保存不能重設總額。 | 配額繞過、重複素材、複本恢復測試通過。 |
| R07 | Metal 圖片／GIF 僅保留播放位置附近素材；ImageIO 先縮圖再建紋理。共享 128 MiB 靜態／GIF 紋理預算，記憶體警告降為 64 MiB；單 GIF 最多 96 幀、24 MiB。取樣保留原動畫總時長。dispose 釋放 GIF 與第二張場景紋理。幾何修改不反覆重解相同素材。 | Swift 程式審查完成；本機無 Xcode，未完成 iOS 編譯與真機記憶體驗證。預算限於這組快取，並非整個 App／GPU 記憶體上限。 |
| R08 | 波形由單一佇列解碼；移除素材或離開時間軸會取消該工作。PCM 最多 128 MiB、解碼等待 2 分鐘；峰值在 worker isolate 用 64 KiB 區塊計算，結果最多 6,000 格、快取 12 份。 | 排隊、取消、跨區塊峰值測試通過。超限／失敗回示意波形。原生取消後仍等寫入結束才釋放佇列，避免重疊解碼；取消回呼失效可能使波形佇列停住，但不繼續堆疊工作。 |
| R09 | 明訂 Android 備份與移轉規則；草稿與持久素材一起保留，排除可丟棄 cache。新版雲端備份要求系統具加密能力。隱私文字說明使用者啟用的 iCloud／Android 系統備份可能包含草稿素材。 | 設定與說明一致；尚未做跨裝置完整還原測試。系統備份受平台配額與使用者設定限制，不能當作完整媒體備份承諾。 |
| R10 | 交易監聽移到 App 層 `PurchaseService`，開 App 即啟動；付款頁只訂閱 UI 事件。離頁後仍完成 pending 交易，失敗保留重試、回前景重試、去除重複完成。 | 離頁後完成、去重、失敗重試測試通過；尚未在 Apple／Google 商店沙盒驗證真實交易。 |
| R11 | FFmpegKit 2.5.2 以可追蹤本地 fork 固定 iOS 8.1.2-full ZIP SHA-256；先驗證再解壓，重用快取前核對檔案雜湊。Podfile 額外執行驗證，避免 local pod 跳過 prepare。 | 已下載 49,275,024 bytes 真實 ZIP 核對雜湊，並實跑錯誤檔案拒絕測試。Android libmpv 的 codec 修補盤點仍未結案，見下方。 |

草稿內容與引用清單之間另增加失敗保護：內容變動前先作廢舊清單；引用寫入失敗會回報保存失敗。意外中斷留下的「缺清單」會阻擋自動清理，不會拿過期清單刪新素材。

## 架構與測試維護

- 將商店交易生命週期抽離畫面，將波形工作所有權、取消與併發集中到服務。
- 草稿清理使用小型引用清單，避免為清理而在 UI 執行緒解析全部大型草稿。
- Codemagic 的 Android 與 iOS 都執行靜態檢查及測試；保留真實退出碼，Android 再跑原生檔案邊界測試及簽章驗證。
- 修正依賴固定睡眠時間的匯入／保存測試；改等實際完成狀態。
- Golden 測試載入真正 Material Icons 字型，更新並逐張檢查 6 張基準圖。CI 仍排除跨 OS 不穩定的 golden，本機全套包含它們。
- 大型 `video_editor_screen.dart`、`AppDelegate.swift` 尚未全面拆分；這次優先修正資料安全、外部輸入邊界及資源生命週期，未宣稱架構技術債全部清除。

## 驗證紀錄

執行環境：Windows、Flutter 3.44.8／Dart 3.12.2、JDK 17。

| 驗證 | 結果 |
|---|---|
| Dart 靜態分析 | 0 error、0 warning；1 個既有函式宣告風格 info。 |
| Flutter 全套測試（含 golden、桌面 FFmpeg） | **1,078 passed、7 skipped、0 failed**，6 分 14 秒，exit 0；使用 `--no-pub --concurrency=4 --reporter expanded` 與 `MARKCUT_FFMPEG`。 |
| 定向回歸 | 先 39 passed；最後 5 個受影響檔案 51 passed，涵蓋目錄讀取失敗、損壞引用、批次超額及 GIF 刪除完成。 |
| file_picker Kotlin + JVM | 2 tests，0 failure、0 error。 |
| Android 完整 debug APK | `:app:assembleDebug` 成功；最後更新後重建再次成功（422 tasks，37 秒）。APK 346,948,265 bytes，僅為 debug 驗證產物。 |
| Release 簽章檢查 | 缺少金鑰與 debug 憑證明確失敗；非 debug 測試憑證成功。 |
| 原生下載完整性 | 真實 ZIP SHA-256 一致；錯誤 ZIP 在解壓前被拒絕。 |
| 編輯器獨立 benchmark | 1 passed；單指拖曳 median 2.36 ms／p90 3.66 ms，雙指縮放 median 3.92 ms／p90 6.57 ms。 |
| iOS／商店／系統備份 | 此環境無法執行，未標示為通過。 |

效能量測為 Windows debug、部分原生 mock，不是手機 release FPS。整頁 `setState + pump` 仍重建 671 elements，median 30.06 ms／p90 55.60 ms；修正前紀錄為 27.91／43.42 ms。這次沒有證據顯示整頁重建變快，仍需後續縮小重建範圍；單次桌面數值波動也不能直接歸因於某一筆修正。此次效能修正重點是記憶體預算、波形併發及資源釋放，iOS 載入尖峰與 GPU 效果仍待真機驗證。

本機原路徑含中文字，Flutter impellerc 在 Android shader 編譯崩潰；改從指向同一工作目錄的 ASCII junction 建置。Kotlin 增量快取對跨磁碟路徑也報錯，僅在本次驗證命令停用 incremental，未將這些環境 workaround 寫進產品設定。

原始與修正後 log 位於忽略版控的 `build/audit_2026_09_26/`。主要檔案：`fix-full-tests-final.log`、`fix-analyze-final.log`、`fix-picker-kotlin.log`、`fix-android-final.log`、`fix-signing-missing.log`、`fix-native-hash-negative.log`、`fix-native-verified-hash.json`、`fix-editor-benchmark.log`。

## 發版前仍需完成的外部驗證

1. **Android 正式簽章**：使用既有 production/upload key；在安全 CI 變數設定 `CM_KEYSTORE_PATH`、`CM_KEYSTORE_PASSWORD`、`CM_KEY_ALIAS`、`CM_KEY_PASSWORD`，或本機忽略版控的 `android/key.properties`。Codemagic 若使用變數群組，還需在 Android workflow 的 `environment.groups` 引用實際群組名稱，金鑰檔須先配置到指定路徑。不要重新產一把 key 冒充既有正式身分。
2. **iOS 原生驗證**：在 macOS 執行既有 `ios-compile` workflow，接著真機測試大量圖片／GIF、記憶體警告與離開編輯器後的資源回收。此工作目錄尚未推送，CI 未被觸發。
3. **商店與備份**：沙盒驗證付款後立刻離頁、斷網重試與重啟補單；測試草稿與素材一起備份／還原。
4. **Android libmpv 供應鏈**：本案使用的預編譯媒體引擎含舊 FFmpeg。查核較新的上游 v1.1.11 建置清單仍列 FFmpeg 6.0、libxml2 2.10.3，不能只升封裝版本就視為 codec 已修補。需要上游提供可核對的安全 backport 清單，或建立並測試更新 codec 的自有 native build。版本舊本身不等於已證明 App 存在可利用漏洞，但這項尚不能標為已排除。[上游版本清單](https://raw.githubusercontent.com/media-kit/libmpv-android-video-build/v1.1.11/buildscripts/include/depinfo.sh)、[FFmpeg 安全公告](https://ffmpeg.org/security.html)。
5. **回饋 API 後端**：此 repository 不含後端，未能修正或驗證服務端權限、限流、儲存與日誌處理；需要後端原始碼與部署設定才可結案。
6. **iOS 建置可重現性**：目前 CI 的 Xcode／CocoaPods 仍使用 `latest`／`default`。需以實際成功的 macOS 建置環境固定版本並產生 Podfile.lock，不能在本機沒有 CocoaPods 的情況下杜撰鎖定檔。

本次沒有連線壓測正式服務、沒有上傳使用者媒體，也沒有更動正式商店或部署設定。

## 後續編輯器效能重構

本報告的數字保留為第一輪修正紀錄。後續已實作區域更新、時間軸與片段內容虛擬化、波形分檔訂閱、Metal 背景差異載入及先保存內容再更新封面；最新驗證與限制見 [大型編輯器效能調整](EDITOR_PERFORMANCE_2026_09_27.md)。
