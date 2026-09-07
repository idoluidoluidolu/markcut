# MarkCut

浮水印與簡易剪輯 App（Flutter；iOS 為主要平台，Android 亦支援）。所有影片與照片都在裝置本機處理，不上傳、不蒐集個資。

## 功能

- **浮水印**：文字（20 款內建字型、顏色、大小、間距、旋轉、陰影／描邊／底色、滿版平鋪）與圖片浮水印，可存成範本一鍵套用
- **剪輯**：多軌時間軸、切割、修剪、排序、變速、音量與淡入淡出
- **批次**：一次選多個檔案，統一套用同一組浮水印後整批輸出
- **輸出**：原始／4K／1080P，畫面比例可選，畫質四檔（省空間／標準／高畫質／最高畫質；H.264 由裝置硬體編碼器輸出，位元率依檔位、解析度與影格率換算，程式內部以 CRF 26／17／12／0 作為檔位鍵）

## 建置

```
flutter pub get
flutter build ios --release                    # iOS（雲端由 codemagic.yaml 打包上 TestFlight）
flutter build apk --release --split-per-abi    # Android
```

需要 Flutter 3.44.8（CI 釘同一版）；iOS 另需 Xcode 與 CocoaPods，Android 另需 JDK 17。

## 授權

本程式為自由軟體，依 **Mozilla Public License 2.0** 散布，
授權全文見 [LICENSE](LICENSE)。

MPL 是檔案層級的 copyleft：你改到的原始檔必須以相同授權公開，
但可以跟其他授權（含閉源）的程式碼整合在同一個專案裡。
本程式不提供任何擔保。

影音處理使用 FFmpeg 的 **LGPL v2.1+** 建置版（`ffmpeg_kit_flutter_new_full`：
不含 x264／x265／xvid／vid.stab 等 GPL 元件），
H.264 編碼改用裝置的硬體編碼器（Android MediaCodec／iOS VideoToolbox）。
Android 的預覽播放另使用 media_kit（libmpv）；iOS 用系統的 AVPlayer。

內建字型皆為 SIL Open Font License 1.1：思源黑體／思源宋體、jf open 粉圓、
LXGW 文楷 TC、悠哉字體、縫合像素字體、Montserrat、Playfair Display、Pacifico、
Bebas Neue、Oswald、Lobster、Anton、Courier Prime、Quicksand、Space Grotesk、
Abril Fatface、Dancing Script、Caveat、Press Start 2P。
