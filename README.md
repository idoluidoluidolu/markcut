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

本程式為自由軟體，依 **GNU General Public License v3**（或後續版本）散布，
授權全文見 [LICENSE](LICENSE)。

之所以採用 GPL，是因為影音處理使用了包含 GPL 元件（x264）的 FFmpeg。
你可以自由使用、修改、再散布本程式，但衍生作品必須以相同授權釋出並公開原始碼。
本程式不提供任何擔保。

內建字型皆為 SIL Open Font License 1.1：思源黑體／思源宋體、jf open 粉圓、
LXGW 文楷 TC、朱古力黑體、Montserrat、Playfair Display、Pacifico、
Bebas Neue、Oswald、Lobster、Anton、Courier Prime。
