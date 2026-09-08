# iOS 195：冷拖曳與時間軸同步

## 實機回報

1.1.0+195 的最後一份合成有 56 次原生快取命中，但實際呈現為 0、失敗 29 次；整次編輯記錄到 12 次精準定位未完成。原生 seek 回覆平均 1ms，並不代表影格已經完成解碼與顯示。第一次起播 400ms 未確認位置前進，Dart 時間軸仍開始自行推進。

這些計數的生命週期不同：原生呈現與 seek 統計屬於當前合成播放器，CI 與編輯事件則可能包含先前重建前的工作，不能相除當成螢幕 FPS。

## 修正

- 原生拖曳保留一個處理中的目標與一個最新待處理目標。新的手指事件不再連續取消正在產生的 CI／GPU 影格；真正呈現或有界失敗後，才處理最新目標。放手的精準定位仍等待顯示收據，播放、暫停、重建與離頁可取消舊工作。
- 移除非線性 HLG 顯示層上不相容的 `CAEDRMetadata.hlg` 設定。原生 GPU 測試另確認 Core Image 拒絕原本的 `bgr10a2Unorm` 目的貼圖，改用 CI 與顯示層均支援的 `rgba16Float`。保留來源十位元 HLG、HLG 色彩空間與既有 CI 色彩轉換，不另外調亮或降低原始素材品質；以半精度浮點讀回驗證 0.5／0.75／1.0，容許誤差仍為 0.015。
- 合成播放的時間碼與刻度使用原生位置樣本。讀取失敗視為未知，起播或中途停滯時不自行前進；只有確認影片合成已結束，才讓較長的文字／貼圖尾段繼續走。
- 點刻度與全螢幕進度條立即同步同一條時間軸；停手後用實際呈現影格的時間對齊刻度，過期的成功回覆不能改動新手勢。
- 診斷分列正常合併、seek 成功／未完成，以及無可見視圖、drawable、GPU、合成等待或呈現等待等失敗階段。

## 驗證方式

回歸涵蓋拖曳中持續改目標、停手精準定位、成功回覆晚到、快速播放／暫停、原生位置停滯、讀取失敗與尾段播放。iOS 測試另外建立真正的 `UIWindow` 與 `CAMetalLayer`，檢查 SDR／HLG 連續呈現相同時間點，而不只驗證離屏像素或模擬回覆。

模擬器 SDK 不提供 `addPresentedHandler`／`presentedTime`。因此模擬器關閉原生拖曳呈現能力，略過需要這兩個 API 的三項顯示整合測試；純 GPU、色彩數值、快取與排程測試仍可執行。真機保留真正的呈現回呼，沒有把 GPU 執行完成當成已上屏。

完整 Flutter 回歸 **876 項通過、7 項需額外啟用的效能測試跳過**，包含 FFmpeg 實際圖像輸出。`dart analyze --format machine lib test integration_test` 無問題。完整回歸也找出既有草稿測試以固定時間等待真實 I/O 的不穩定性，已改為等待保存完成，另驗證未完成保存時不會離頁或清掉素材；產品保存流程未更動。

iOS 原生驗證於 2026-09-08 完成：[GitHub CI 34234768003](https://github.com/idoluidoluidolu/markcut/actions/runs/34234768003)，程式提交 `89fe0462183f26d93797b9963a6756f20463a186`。iOS Release 與模擬器編譯通過；原生測試共 39 項，**36 項通過、3 項因模擬器不支援實際呈現回呼而跳過、0 失敗**。HLG 半精度貼圖的亮度數值測試實際執行並通過。模擬器測試無法取代同一部 iPhone 使用原始 4K HDR 素材的冷拖曳與 HDR 螢幕實測。

## 上機比對

使用 +195 回報的同一組五段素材，重新進入編輯後立即左右拖曳，再於背景準備完成後重做一次。兩次各保存診斷，分開比較冷啟動與快取完成的狀態，不能用第二次已經轉好工作檔的結果代表第一次。

- 停手後，預覽畫面、時間碼與刻度應對齊同一個實際影格；快速換方向、播放／暫停或切換片段後，晚到的回覆不得拉回舊位置。
- 第一次播放等待解碼時，時間碼與指標不得先行；播放到素材末端或較長的文字尾段仍應正確停止。
- 同一個合成播放器生命週期內，檢查「原生拖曳／實際呈現」是否增加，並記錄請求到實際呈現延遲。不能只看 seek 回覆速度，也不能把正常合併的舊目標當成顯示失敗。
- 若仍有呈現失敗，保留「失敗階段」與「最後失敗」；若仍會鈍，保留冷拖曳的事件時長、影格數與讀取中的素材數。這些資料可區分解碼負載與顯示層失敗。
- HLG 亮度數值測試涵蓋顯示轉換，無法驗證實體面板的 EDR／系統 tone mapping；需在同一部手機、相同顯示條件下觀察原始 HDR 影片與預覽，截圖本身不足以證明面板顯色一致。

## API 依據

- [Apple：平順執行 AVPlayer seek](https://developer.apple.com/library/archive/qa/qa1820/_index.html)
- [Apple：以 Core Animation transaction 呈現 Metal drawable](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction)
- [Apple：以色彩空間顯示 HDR 內容](https://developer.apple.com/documentation/metal/using-color-spaces-to-display-hdr-content)
- [Apple：EDR metadata 的格式與線性色彩空間要求](https://developer.apple.com/documentation/quartzcore/cametallayer/edrmetadata)
