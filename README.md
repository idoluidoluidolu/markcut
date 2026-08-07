# MarkCut

浮水印與簡易剪輯 App（Flutter / Android）。所有影片與照片都在裝置本機處理，不上傳、不蒐集個資。

## 功能

- **浮水印**：文字（13 款內建字型、顏色、大小、間距、旋轉、陰影／描邊／底色、滿版平鋪）與圖片浮水印，可存成範本一鍵套用
- **剪輯**：多軌時間軸、切割、修剪、排序、變速、音量與淡入淡出
- **批次**：一次選多個檔案，統一套用同一組浮水印後整批輸出
- **輸出**：原始／4K／1080P，畫面比例可選，畫質三檔（CRF 17／12／0）

## 建置

```
flutter pub get
flutter build apk --release --split-per-abi
```

需要 Flutter 3.44+ 與 JDK 17。

## 授權

本程式為自由軟體，依 **Mozilla Public License 2.0** 散布，
授權全文見 [LICENSE](LICENSE)。

MPL 是檔案層級的 copyleft：你改到的原始檔必須以相同授權公開，
但可以跟其他授權（含閉源）的程式碼整合在同一個專案裡。
本程式不提供任何擔保。

影音處理使用 FFmpeg 的 **LGPL v2.1+** 建置版（不含 x264），
H.264 編碼改用裝置的硬體編碼器（Android MediaCodec／iOS VideoToolbox）。

內建字型皆為 SIL Open Font License 1.1：思源黑體／思源宋體、jf open 粉圓、
LXGW 文楷 TC、朱古力黑體、Montserrat、Playfair Display、Pacifico、
Bebas Neue、Oswald、Lobster、Anton、Courier Prime。
