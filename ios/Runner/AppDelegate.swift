import AVFoundation
import CoreImage
import VideoToolbox
import Flutter
import ImageIO
import UIKit

extension Double {
  /// 夾在 0~1（淡入淡出的係數算出來可能超出範圍）
  func clamped01() -> Double { self < 0 ? 0 : (self > 1 ? 1 : self) }
}

/// 影片合成的驗證回報。AVFoundation 自己會逐段檢查指令，出問題時
/// 直接說是哪一種——時間範圍沒接起來、軌道編號不對、指令是空的。
/// 靠人眼看程式碼猜「為什麼合成壞了」是查不出來的
final class VCValidator: NSObject, AVVideoCompositionValidationHandling {
  var problems: [String] = []

  func videoComposition(
    _ videoComposition: AVVideoComposition,
    shouldContinueValidatingAfterFindingInvalidValueForKey key: String
  ) -> Bool {
    problems.append("欄位不合法：\(key)")
    return true
  }

  func videoComposition(
    _ videoComposition: AVVideoComposition,
    shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange
  ) -> Bool {
    // 連長度一起印：這種縫常常短到兩位小數看起來頭尾一樣（4.45~4.45），
    // 沒有長度就分不出「差一格的接縫」跟「真的少了一整段」
    problems.append(
      "有一段沒人管：\(String(format: "%.3f", timeRange.start.seconds))~"
        + "\(String(format: "%.3f", timeRange.end.seconds))s"
        + "（長 \(Int((timeRange.duration.seconds * 1000).rounded()))ms）")
    return true
  }

  func videoComposition(
    _ videoComposition: AVVideoComposition,
    shouldContinueValidatingAfterFindingInvalidTimeRangeIn instruction:
      AVVideoCompositionInstructionProtocol
  ) -> Bool {
    problems.append(
      "指令的時間範圍不合法：\(String(format: "%.2f", instruction.timeRange.start.seconds))~"
        + "\(String(format: "%.2f", instruction.timeRange.end.seconds))s")
    return true
  }

  func videoComposition(
    _ videoComposition: AVVideoComposition,
    shouldContinueValidatingAfterFindingInvalidTrackIDIn instruction:
      AVVideoCompositionInstructionProtocol,
    layerInstruction: AVVideoCompositionLayerInstruction,
    asset: AVAsset
  ) -> Bool {
    problems.append("指令指到不存在的軌道（trackID \(layerInstruction.trackID)）")
    return true
  }
}

// ── GPU 匯出合成器 ─────────────────────────────────────────
//
// 疊浮水印本來走 AVVideoCompositionCoreAnimationTool——那條路會把整個
// 渲染拉到 Core Animation 的離線繪製，是匯出最大的單一瓶頸。這裡改成
// 自訂合成器：每一格在 GPU 上用 Core Image 疊，管線全程硬體。
//
// 疊加物的模型本來就簡單：整張畫布大小的 PNG＋純時間函數的動畫
//（閃爍＝週期開關、飄移＝sin/cos、跑馬燈＝線性位移），逐格算正好

/// 一張疊加物（浮水印／文字 PNG）＋它的顯示窗與動畫參數
final class CIOverlaySpec {
  let image: CIImage  // 已縮放/定位到畫布座標
  let start: Double
  let end: Double
  let anim: String
  let cycle: Double
  let on: Double
  let animSpeed: Double
  let range: Double
  /// 動畫幅度的基準尺寸＝疊加物自己的畫布（套過 rect 之後）。
  /// 匯出不帶 rect 時就是輸出畫布，行為跟原本一模一樣
  let effW: Double
  let effH: Double

  init?(_ ov: [String: Any], canvas: CGSize) {
    guard let data = (ov["png"] as? FlutterStandardTypedData)?.data,
      let ui = UIImage(data: data), let cg = ui.cgImage
    else { return nil }
    var img = CIImage(cgImage: cg)
    let ext = img.extent
    guard ext.width > 1, ext.height > 1 else { return nil }
    // 預覽合成的畫布是「影片畫框」，使用者的畫布（固定比例）可能更寬
    // 或更高：PNG 是照使用者畫布畫的，rect 描述使用者畫布落在這個
    // 畫框座標系的哪裡（左上原點、normalized，允許超出邊界——超出的
    // 部分合成時自然被裁掉）。匯出不帶 rect＝整版，跟原本相同
    var r: [Double] = ov["rect"] as? [Double] ?? [0, 0, 1, 1]
    if r.count < 4 || r[2] <= 0 || r[3] <= 0 { r = [0, 0, 1, 1] }
    let w = canvas.width * CGFloat(r[2])
    let h = canvas.height * CGFloat(r[3])
    img = img.transformed(
      by: CGAffineTransform(scaleX: w / ext.width, y: h / ext.height))
    // CI 是左下原點、y 往上，rect 是左上原點：垂直要反過來
    img = img.transformed(
      by: CGAffineTransform(
        translationX: canvas.width * CGFloat(r[0]),
        y: canvas.height * CGFloat(1 - r[1] - r[3])))
    image = img
    effW = Double(w)
    effH = Double(h)
    start = max(0, ov["start"] as? Double ?? 0)
    end = ov["end"] as? Double ?? .greatestFiniteMagnitude
    anim = ov["anim"] as? String ?? "none"
    cycle = max(0.05, ov["cycle"] as? Double ?? 1.2)
    on = max(0.01, ov["on"] as? Double ?? 0.7)
    animSpeed = max(0.05, ov["animSpeed"] as? Double ?? 1)
    range = max(0.01, ov["range"] as? Double ?? 1)
    if end <= start { return nil }
  }

  /// t 時刻要不要畫、畫在哪個位移。座標注意：Core Animation 的 y 往下、
  /// Core Image 的 y 往上，垂直位移要反過來。係數跟 CALayer 版與 FFmpeg
  /// 版完全同一組，三條路的動畫才長一樣
  func frame(at t: Double, canvas: CGSize) -> CIImage? {
    if t < start || t >= end { return nil }
    switch anim {
    case "blink":
      if (t - start).truncatingRemainder(dividingBy: cycle) >= on {
        return nil
      }
      return image
    case "drift":
      // 幅度照「疊加物自己的畫布」算：預覽合成的畫框比使用者畫布
      // 小的時候，用畫框算會讓擺動比成品小一截
      let amp = 0.02 * range
      let dx = sin(t * 1.3 * animSpeed) * effW * amp
      let dy = cos(t * 0.9 * animSpeed) * effH * amp
      return image.transformed(
        by: CGAffineTransform(translationX: dx, y: -dy))
    case "marquee":
      let ph = t.truncatingRemainder(dividingBy: cycle) / cycle
      let dx = effW * (1 - 2 * ph)
      return image.transformed(by: CGAffineTransform(translationX: dx, y: 0))
    default:
      return image
    }
  }
}

/// 一層畫面：一段影片軌（或一張已定位好的靜態圖）＋變形＋淡入淡出＋調色。
///
/// start/end 是這一層自己的完整顯示窗（輸出秒）。淡入淡出照它算，
/// 不照指令的範圍——指令會被圖層邊界切成好幾段，照指令算的話
/// 每一段都會重新淡一次
/// 會動的 GIF 圖層：影格用 ImageIO 隨取隨解。
///
/// 不整包解開——一支 15 秒 640px 的 GIF 全解是幾百 MB，匯出中
/// 扛不起。匯出是照時間順序走的，連續請求幾乎都命中同一格，
/// 快取「上一格」就夠了。定位變形（縮放/位移/翻轉）跟靜態圖層
/// 同一套烘法，建構時算一次、每一格套用
final class CIGifSpec {
  private let src: CGImageSource
  private let endsMs: [Int]  // 每一格的累計結束時間（毫秒）
  private let loopMs: Int
  private let placement: CGAffineTransform
  private let clipStart: Double  // 圖層進場的輸出秒（迴圈從這裡起算）
  private var lastIdx = -1
  private var lastImg: CIImage?
  private let lock = NSLock()

  init?(path: String, placement: CGAffineTransform, clipStart: Double) {
    guard
      let s = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, nil),
      CGImageSourceGetCount(s) > 1
    else { return nil }
    var ends: [Int] = []
    var acc = 0
    for i in 0..<CGImageSourceGetCount(s) {
      var d = 0.1
      if let props = CGImageSourceCopyPropertiesAtIndex(s, i, nil)
        as? [CFString: Any],
        let g = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
      {
        let un = g[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let cl = g[kCGImagePropertyGIFDelayTime] as? Double
        d = (un ?? cl ?? 0.1)
      }
      // 太短的間隔照瀏覽器慣例當 100ms（跟預覽端 _decodeGifFrames 一致）
      if d < 0.011 { d = 0.1 }
      acc += Int(d * 1000)
      ends.append(acc)
    }
    guard acc > 0 else { return nil }
    self.src = s
    self.endsMs = ends
    self.loopMs = acc
    self.placement = placement
    self.clipStart = clipStart
  }

  /// 輸出時間 t（秒）該畫哪一格（照 GIF 自己的節奏循環）
  func image(at t: Double) -> CIImage? {
    let ms = Int(
      max(0, t - clipStart)
        .truncatingRemainder(dividingBy: Double(loopMs) / 1000) * 1000)
    var lo = 0
    var hi = endsMs.count - 1
    while lo < hi {
      let mid = (lo + hi) / 2
      if endsMs[mid] > ms { hi = mid } else { lo = mid + 1 }
    }
    lock.lock()
    defer { lock.unlock() }
    if lo == lastIdx, let img = lastImg { return img }
    guard let cg = CGImageSourceCreateImageAtIndex(src, lo, nil) else {
      return lastImg
    }
    let img = CIImage(cgImage: cg).transformed(by: placement)
    lastIdx = lo
    lastImg = img
    return img
  }
}

final class CILayerSpec {
  let trackID: CMPersistentTrackID  // Invalid ＝ 靜態圖層（still 有值）
  let still: CIImage?

  /// 會動的 GIF（still 為 nil、trackID 為 Invalid 時可有）。
  /// 影格照輸出時間循環，其餘（裁切/旋轉/透明/調色/淡化）跟
  /// 靜態圖層走同一條處理
  let gif: CIGifSpec?
  let transform: CGAffineTransform
  let srcHeight: CGFloat
  let start: Double
  let end: Double
  let fadeIn: Double
  let fadeOut: Double
  /// 調色：跟預覽同一顆 4x5 矩陣（列主序 20 個數，位移是 0~255 階）。
  /// nil＝沒調
  let colorMatrix: [Double]?

  /// 裁切窗（顯示座標的比例 0~1、左上原點；鏡像在打包時已換算）。
  /// nil＝不裁。只留窗內的畫面，位置不重新貼合——跟預覽一致
  let crop: CGRect?

  /// 自由旋轉（度；順時針＝正，跟預覽的 Transform.rotate 同方向）
  let rotation: Double

  /// 固定透明度（0~1），跟淡入淡出相乘
  let opacity: Double

  /// 疊放層級（時間軸軌道編號）。馬賽克只糊 z 比它低的層
  let z: Int

  init(
    trackID: CMPersistentTrackID, still: CIImage?,
    transform: CGAffineTransform, srcHeight: CGFloat,
    start: Double, end: Double, fadeIn: Double, fadeOut: Double,
    colorMatrix: [Double]?,
    crop: CGRect? = nil, rotation: Double = 0, opacity: Double = 1,
    z: Int = 0, gif: CIGifSpec? = nil
  ) {
    self.trackID = trackID
    self.still = still
    self.gif = gif
    self.transform = transform
    self.srcHeight = srcHeight
    self.start = start
    self.end = end
    self.fadeIn = fadeIn
    self.fadeOut = fadeOut
    self.colorMatrix = colorMatrix
    self.crop = crop
    self.rotation = rotation
    self.opacity = opacity
    self.z = z
  }

  /// 這一格的不透明度（線性淡入淡出）
  func alpha(at t: Double) -> Double {
    var a = 1.0
    if fadeIn > 0.01 { a = min(a, ((t - start) / fadeIn).clamped01()) }
    if fadeOut > 0.01 { a = min(a, ((end - t) / fadeOut).clamped01()) }
    return a
  }
}

/// 一塊馬賽克：畫布座標（左上原點）的方框＋樣式＋顯示窗。
/// 區域數學跟 FFmpeg 的 layerBox(srcAspect=1) 同一個答案：
/// 貼合後是「畫布短邊 × scale」的正方形，中心在 (px, py)
final class CIMosaicSpec {
  let rect: CGRect
  let type: Int  // 0=像素化 1=模糊 2=純色遮蓋
  let strength: Double
  let color: CIColor
  let feather: Double
  let start: Double
  let end: Double

  /// 疊放層級（時間軸軌道編號）：只糊 z 比它低的層
  let z: Int

  /// 筆刷筆畫的遮罩（CI 座標、跟畫布同尺寸；nil＝一般方形）。
  /// 建構時就畫好（CGContext 一次），逐格只做 CIBlendWithMask
  let strokeMask: CIImage?

  init?(_ m: [String: Any], canvas: CGSize) {
    type = m["type"] as? Int ?? 0
    strength = min(1, max(0, m["strength"] as? Double ?? 0.5))
    let argb = m["color"] as? Int ?? 0xFF00_0000
    color = CIColor(
      red: CGFloat((argb >> 16) & 0xFF) / 255.0,
      green: CGFloat((argb >> 8) & 0xFF) / 255.0,
      blue: CGFloat(argb & 0xFF) / 255.0)
    feather = min(1, max(0, m["feather"] as? Double ?? 0))
    z = m["track"] as? Int ?? 0
    start = m["start"] as? Double ?? 0
    end = m["end"] as? Double ?? 0
    if end <= start { return nil }

    // 筆刷筆畫：範圍＝包圍盒；遮罩＝圓頭圓角粗線畫在跟畫布同尺寸的
    // 灰階圖上（CI 是左下原點，畫的時候 y 翻過去），柔邊＝先收線寬
    // 再整張高斯暈開——跟照片編輯器的共用畫家同一套規則
    if let raw = m["stroke"] as? [Double], raw.count >= 2 {
      let brushPx =
        CGFloat(m["brush"] as? Double ?? 0.16)
        * min(canvas.width, canvas.height)
      let featherPx = CGFloat(feather) * 0.5 * brushPx
      // 遮罩用 CI 座標（y 往上）畫；包圍盒 rect 存「左上原點」座標
      // ——applyMosaic 進場會統一把 rect 翻成 CI 座標，這裡先翻的話
      // 會被翻兩次，效果區域跑到鏡像位置、跟遮罩對不上（實測：
      // 只看得到白遮罩、永遠沒有馬賽克）
      var pts: [CGPoint] = []
      var topMinX = CGFloat.greatestFiniteMagnitude
      var topMinY = CGFloat.greatestFiniteMagnitude
      var topMaxX = -CGFloat.greatestFiniteMagnitude
      var topMaxY = -CGFloat.greatestFiniteMagnitude
      var i = 0
      while i + 1 < raw.count {
        let tx = CGFloat(raw[i]) * canvas.width
        let ty = CGFloat(raw[i + 1]) * canvas.height
        topMinX = min(topMinX, tx)
        topMinY = min(topMinY, ty)
        topMaxX = max(topMaxX, tx)
        topMaxY = max(topMaxY, ty)
        pts.append(CGPoint(x: tx, y: canvas.height - ty))
        i += 2
      }
      let margin = brushPx / 2 + featherPx + 2
      rect = CGRect(
        x: topMinX - margin, y: topMinY - margin,
        width: topMaxX - topMinX + margin * 2,
        height: topMaxY - topMinY + margin * 2)
      var maskImg: CIImage? = nil
      let w = Int(canvas.width.rounded())
      let h = Int(canvas.height.rounded())
      if w > 1, h > 1,
        let cg = CGContext(
          data: nil, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue)
      {
        cg.setFillColor(gray: 0, alpha: 1)
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        cg.setStrokeColor(gray: 1, alpha: 1)
        cg.setLineWidth(max(1, brushPx - (featherPx >= 1 ? featherPx : 0)))
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        if pts.count == 1 {
          let r0 = max(0.5, (brushPx - featherPx) / 2)
          cg.setFillColor(gray: 1, alpha: 1)
          cg.fillEllipse(
            in: CGRect(
              x: pts[0].x - r0, y: pts[0].y - r0,
              width: r0 * 2, height: r0 * 2))
        } else {
          cg.beginPath()
          cg.move(to: pts[0])
          for p in pts.dropFirst() { cg.addLine(to: p) }
          cg.strokePath()
        }
        if let img = cg.makeImage() {
          var ci = CIImage(cgImage: img)
          if featherPx >= 1 {
            ci = ci.clampedToExtent()
              .applyingFilter(
                "CIGaussianBlur",
                parameters: ["inputRadius": featherPx * 0.5])
              .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
          }
          maskImg = ci
        }
      }
      strokeMask = maskImg
      guard rect.width > 2, rect.height > 2 else { return nil }
      return
    }
    strokeMask = nil

    let px = m["px"] as? Double ?? 0.5
    let py = m["py"] as? Double ?? 0.5
    let scale = m["scale"] as? Double ?? 1
    let aspect = canvas.width / canvas.height
    let side = (aspect <= 1 ? canvas.width : canvas.height) * CGFloat(scale)
    guard side > 2 else { return nil }
    rect = CGRect(
      x: CGFloat(px) * canvas.width - side / 2,
      y: CGFloat(py) * canvas.height - side / 2,
      width: side, height: side)
  }
}

/// 一段指令：這段時間裡「有哪些圖層、哪些馬賽克」固定不變。
/// 圖層照 z 序（時間軸軌道由下而上）排好，馬賽克疊在圖層之上、
/// 文字／浮水印 PNG 疊在最上——跟 FFmpeg 那條路同一個疊法
final class CIExportInstruction: NSObject, AVVideoCompositionInstructionProtocol {
  let timeRange: CMTimeRange
  let enablePostProcessing = false
  let containsTweening = true
  let passthroughTrackID = kCMPersistentTrackID_Invalid
  var requiredSourceTrackIDs: [NSValue]? {
    // 治本：全部影像軌每一段都列進去。AVFoundation 只替「這段指令
    // 要求的軌」預捲解碼器——只列當下用到的話，上層片段進場那一刻
    // 它的解碼器才冷啟動，來源格晚一兩格到位，就是接縫閃黑／停頓
    // 的根。列了但這一段沒有媒體的軌是空範圍，沒有解碼成本
    if !prerollTrackIDs.isEmpty { return prerollTrackIDs }
    let ids = layers.compactMap { l -> NSNumber? in
      l.trackID == kCMPersistentTrackID_Invalid
        ? nil : NSNumber(value: l.trackID)
    }
    return ids.isEmpty ? nil : ids
  }

  let layers: [CILayerSpec]
  let mosaics: [CIMosaicSpec]
  let overlays: [CIOverlaySpec]

  /// 整條時間軸用到的所有影像軌（預捲用，見 requiredSourceTrackIDs）
  let prerollTrackIDs: [NSNumber]

  /// 這一段沒有任何圖層時，用上一格頂住而不是畫黑。
  /// 只給「極短的空窗」開：片段之間手滑留下的一條小縫（幾格），
  /// 忠實畫黑就是使用者看到的「接縫閃一下」；刻意留的長空窗照樣黑
  let holdIfEmpty: Bool

  init(
    timeRange: CMTimeRange, layers: [CILayerSpec],
    mosaics: [CIMosaicSpec], overlays: [CIOverlaySpec],
    prerollTrackIDs: [NSNumber] = [], holdIfEmpty: Bool = false
  ) {
    self.timeRange = timeRange
    self.layers = layers
    self.mosaics = mosaics
    self.overlays = overlays
    self.prerollTrackIDs = prerollTrackIDs
    self.holdIfEmpty = holdIfEmpty
    super.init()
  }
}

class CIExportCompositor: NSObject, AVVideoCompositing {
  /// HDR 輸出模式（見 CIExportCompositorHDR）：來源不做色調映射、
  /// 輸出 10-bit HLG。SDR（預設）＝原本的 8-bit 709
  var hdrOut: Bool { false }

  /// 預覽合成的「即時疊加物」（浮水印/文字/貼圖）。
  ///
  /// HDR 預覽把疊加物烘進合成，白色才能跟成品一樣亮（EDR）；
  /// 但拖曳、調樣式如果每次都整組重建合成，手感就毀了——Dart 端
  /// 重畫 PNG 後直接換這份清單，下一格就生效。只有預覽合成器
  ///（livePreview）讀它，匯出照走指令裡的 overlays，互不相干
  static let ovLock = NSLock()
  private static var previewOvs: [CIOverlaySpec] = []
  static func setPreviewOverlays(_ o: [CIOverlaySpec]) {
    ovLock.lock()
    previewOvs = o
    ovLock.unlock()
  }
  static func currentPreviewOverlays() -> [CIOverlaySpec] {
    ovLock.lock()
    defer { ovLock.unlock() }
    return previewOvs
  }

  /// 讀「即時疊加物」而不是指令裡那份（只有 HDR 預覽合成器開）
  var livePreview: Bool { false }

  // context 用靜態共用：CI 的濾鏡管線編譯快取掛在 context 上，
  // 每個合成器實例各開一顆的話，抽格器、播放器、匯出各自都要
  // 重新編一次管線——首編譯那幾十 ms 正好落在畫面上變成一頓
  // 抽格器（frameAt）也共用這顆做 HDR 影格的色調映射，不另開
  static let ctxSDR = CIContext(options: [
    .cacheIntermediates: false, .workingFormat: CIFormat.RGBA8,
    // 半透明疊加要在 gamma 空間混色：Flutter 預覽跟 FFmpeg 的
    // overlay 都是 gamma 混，CI 預設的「線性光」混出來，同一個
    // 55% 白字會更實、陰影的柔度被吃掉——實測回報「預覽字較淺
    // 有厚度、匯出變濃變扁」就是這個。HDR 管線維持線性（色調
    // 映射要在線性光上算）
    .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
  ])
  // HDR 要在半浮點工作格式上算，8 位元會把高光截掉
  private static let ctxHDR = CIContext(options: [
    .cacheIntermediates: false, .workingFormat: CIFormat.RGBAh,
  ])
  private var ctx: CIContext { hdrOut ? Self.ctxHDR : Self.ctxSDR }

  /// 先把馬賽克那組濾鏡的 GPU 管線編譯起來。
  /// CI 第一次遇到新形狀的濾鏡圖要現場編 Metal 管線（幾十 ms）——
  /// 「上層片段進場」的第一格正好會換圖形，那一下就是接縫的頓。
  /// 開合成時先空跑一次，管線進快取，正式播放全程熱路徑
  static func warmUp() {
    DispatchQueue.global(qos: .utility).async {
      let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
      var img = base.clampedToExtent()
        .applyingFilter("CIPixellate", parameters: ["inputScale": 8.0])
        .cropped(to: base.extent)
      img = base.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 4.0])
        .cropped(to: base.extent)
        .composited(over: img)
      img = img.applyingFilter("CILinearToSRGBToneCurve")
        .applyingFilter("CISRGBToneCurveToLinear")
        .composited(over: base)
      _ = ctxSDR.createCGImage(img, from: base.extent)
    }
  }
  private let queue = DispatchQueue(label: "markcut.ciexport")

  /// 上一格合成完的畫面（指向我們自己輸出池的緩衝）。
  /// 指令邊界的瞬間，某一軌的來源格常常還沒到位——那一格畫黑底
  /// 就是使用者看到的「接縫閃黑」。缺格就重播上一格頂住，
  /// 解碼器下一格就追上了
  private var lastComposed: CIImage?
  private lazy var outCS: CGColorSpace = {
    if hdrOut, #available(iOS 14.0, *),
      let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
    {
      return hlg
    }
    return CGColorSpace(name: CGColorSpace.itur_709)
      ?? CGColorSpaceCreateDeviceRGB()
  }()

  // 收原生格式（含 10-bit HDR）。只收 BGRA 的話，HDR 來源會在進到
  // 我們手上之前先被轉成 8-bit BGRA——那一步沒有色調映射，顏色就是
  // 在這裡被沖淡的。收原生 YUV，映射交給下面的 toneMapHDRtoSDR
  var sourcePixelBufferAttributes: [String: Any]? = [
    kCVPixelBufferPixelFormatTypeKey as String: [
      Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
      Int(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
      Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
      Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
      Int(kCVPixelFormatType_32BGRA),
    ]
  ]
  var requiredPixelBufferAttributesForRenderContext: [String: Any] {
    [
      kCVPixelBufferPixelFormatTypeKey as String: hdrOut
        ? Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        : Int(kCVPixelFormatType_32BGRA)
    ]
  }

  // 沒有這兩個旗標的話，AVFoundation 會在把畫格交給我們「之前」
  // 自己先把 HDR 轉成 SDR——那一步是純色度轉換、沒有色調映射，
  // HLG 的像素被當成 709 解，成品就是整片沖淡、過曝。
  // 而我們自己的 toneMapHDRtoSDR 這時拿到的已經是標成 SDR 的畫格，
  // 等於空轉。宣告支援之後，HDR 畫格原封進來，色調映射才輪得到我們
  var supportsWideColorSourceFrames = true
  var supportsHDRSourceFrames = true

  func renderContextChanged(_ newContext: AVVideoCompositionRenderContext) {
    // 渲染環境換了（理論上一個 item 一生只有一次）：上一格的緩衝
    // 尺寸可能對不上了，別再重播它
    queue.async { self.lastComposed = nil }
  }
  func cancelAllPendingVideoCompositionRequests() {}

  /// 調色：預覽的 4x5 矩陣是在「已編碼（gamma）」的像素值上做的，
  /// Core Image 的工作空間是線性——直接套會跟預覽對不上。先轉去
  /// sRGB 編碼域、套矩陣、再轉回來，數學才跟預覽／FFmpeg 一字不差
  private func applyColor(_ img: CIImage, _ m: [Double]) -> CIImage {
    guard m.count >= 20 else { return img }
    var i = img.applyingFilter("CILinearToSRGBToneCurve")
    i = i.applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": CIVector(
          x: CGFloat(m[0]), y: CGFloat(m[1]), z: CGFloat(m[2]), w: 0),
        "inputGVector": CIVector(
          x: CGFloat(m[5]), y: CGFloat(m[6]), z: CGFloat(m[7]), w: 0),
        "inputBVector": CIVector(
          x: CGFloat(m[10]), y: CGFloat(m[11]), z: CGFloat(m[12]), w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(
          x: CGFloat(m[4] / 255.0), y: CGFloat(m[9] / 255.0),
          z: CGFloat(m[14] / 255.0), w: 0),
      ])
    return i.applyingFilter("CISRGBToneCurveToLinear")
  }

  /// 馬賽克。柔邊跟 FFmpeg 同一套同心圈：由外到內 6 圈漸強，
  /// 外圈幾乎是原畫面，邊界就沒有一條硬線
  private func applyMosaic(
    _ mz: CIMosaicSpec, to base: CIImage, canvas: CGSize
  ) -> CIImage {
    // rect 是左上原點座標，翻成 Core Image 的左下
    var r = CGRect(
      x: mz.rect.minX, y: canvas.height - mz.rect.maxY,
      width: mz.rect.width, height: mz.rect.height)
    r = r.intersection(CGRect(origin: .zero, size: canvas))
    guard r.width > 2, r.height > 2 else { return base }

    func patch(_ region: CGRect, _ k: Double) -> CIImage {
      switch mz.type {
      case 2:
        return CIImage(color: mz.color).cropped(to: region)
      case 1:
        // 濃度 → FFmpeg 的縮小倍數（2~14），拿它當高斯半徑的基準。
        // 半徑要隨畫布縮放（以短邊 1080 為基準）：絕對像素的話
        // 預覽（上限 1080）跟 4K 匯出的相對模糊強度差一倍，
        // FFmpeg 的「縮小倍數」語意本來就是尺度不變的
        let down =
          (2.0 + mz.strength * 12.0)
          * Double(min(canvas.width, canvas.height)) / 1080.0
        return base.clampedToExtent()
          .applyingFilter(
            "CIGaussianBlur", parameters: ["inputRadius": down * k])
          .cropped(to: region)
      default:
        // 濃度 → 橫向格數（26~6，跟 FFmpeg 同一條換算）
        let cells = min(40.0, max(4.0, 26.0 - 20.0 * mz.strength))
        let cell = max(2.0, Double(r.width) / cells * k)
        return base.clampedToExtent()
          .applyingFilter(
            "CIPixellate",
            parameters: [
              "inputScale": cell,
              "inputCenter": CIVector(x: region.minX, y: region.minY),
            ])
          .cropped(to: region)
      }
    }

    // 筆刷筆畫：效果鋪滿包圍盒、筆畫遮罩決定哪裡吃效果
    //（柔邊已烘進遮罩本身）。跟照片編輯器的 paintMosaicStroke
    // 同一套語意，塗到哪碼到哪
    if let mask = mz.strokeMask {
      let fx = patch(r, 1).composited(over: base)
      return fx.applyingFilter(
        "CIBlendWithMask",
        parameters: [
          kCIInputBackgroundImageKey: base,
          kCIInputMaskImageKey: mask,
        ])
    }

    let margin = mz.feather * 0.35 * Double(min(r.width, r.height))
    var out = base
    if margin >= 8, mz.type != 2 {
      for i in 1...6 {
        let inset = CGFloat(margin * Double(i - 1) / 5.0)
        let region = r.insetBy(dx: inset, dy: inset)
        guard region.width > 2, region.height > 2 else { break }
        out = patch(region, Double(i) / 6.0).composited(over: out)
      }
    } else {
      out = patch(r, 1).composited(over: out)
    }
    return out
  }

  /// 繞著 [c] 轉 [degrees] 度（順時針，跟預覽同方向）。
  /// CI 座標 y 往上，視覺上的順時針要用負角度
  private static func spin(
    _ img: CIImage, degrees: Double, around c: CGPoint
  ) -> CIImage {
    let t = CGAffineTransform(translationX: -c.x, y: -c.y)
      .concatenating(
        CGAffineTransform(rotationAngle: CGFloat(-degrees * .pi / 180)))
      .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
    return img.transformed(by: t)
  }

  /// 慢格紀錄（>20ms 的合成格）：時間點、耗時、層數、有沒有缺格。
  /// 靜態＋鎖：合成器實例是 AVFoundation 生的，診斷只能從這裡撈
  static let slowLock = NSLock()
  static var slowFrames: [String] = []
  static var frameCount = 0
  static var worstMs = 0.0

  /// 供格節奏：播放中相鄰兩格「牆鐘等了多久 vs 畫面差多少」。
  /// 合成再快，系統若在接縫供不出下一格，卡頓就在這裡現形——
  /// 直接寫出「幾秒處等了幾 ms」。只在合成播放器播放中量
  //（watchSupply），匯出的離線節奏不會混進來
  static var watchSupply = false
  static var lastReqT = -1.0
  static var lastReqWall = 0.0
  static var supplyGaps: [String] = []
  static var worstSupplyMs = 0.0
  /// 缺格（sourceFrame 給不出來）：哪一軌、什麼時候、總共幾次
  static var missNotes: [String] = []
  static var missTotal = 0
  /// 保底出動次數：缺格重播上一格／短縫頂住
  static var holdMissCount = 0
  static var holdGapCount = 0

  static func noteSupply(t: Double, wall: Double) {
    slowLock.lock()
    defer { slowLock.unlock() }
    if watchSupply, lastReqT >= 0 {
      let dt = t - lastReqT
      let dw = wall - lastReqWall
      // 只看連續播放的相鄰格（畫面差半秒內）；seek、暫停造成的大跳
      // 不算。牆鐘比畫面多等 80ms 以上＝系統在這一格卡住了
      if dt > 0, dt <= 0.5 {
        let extra = (dw - dt) * 1000
        if extra > worstSupplyMs { worstSupplyMs = extra }
        if extra > 80 {
          if supplyGaps.count > 12 { supplyGaps.removeFirst() }
          supplyGaps.append(
            String(
              format: "%.2fs 等了 %.0fms（畫面才差 %.0fms）",
              t, dw * 1000, dt * 1000))
        }
      }
    }
    lastReqT = t
    lastReqWall = wall
  }

  static func noteMiss(t: Double, track: Int) {
    slowLock.lock()
    missTotal += 1
    if missNotes.count < 10 {
      missNotes.append(String(format: "%.2fs 軌%d 給不出影格", t, track))
    }
    slowLock.unlock()
  }

  static func noteFrame(t: Double, ms: Double, layers: Int, missing: Bool) {
    slowLock.lock()
    frameCount += 1
    if ms > worstMs { worstMs = ms }
    if ms > 20 {
      if slowFrames.count > 40 { slowFrames.removeFirst() }
      slowFrames.append(
        String(
          format: "%.2fs 花了 %.0fms（%d 層%@）", t, ms, layers,
          missing ? "、缺格" : ""))
    }
    slowLock.unlock()
  }

  func startRequest(_ req: AVAsynchronousVideoCompositionRequest) {
    queue.async {
      autoreleasepool {
        let tick = CFAbsoluteTimeGetCurrent()
        Self.noteSupply(t: req.compositionTime.seconds, wall: tick)
        guard
          let ins = req.videoCompositionInstruction as? CIExportInstruction,
          let dst = req.renderContext.newPixelBuffer()
        else {
          req.finish(
            with: NSError(domain: "markcut.ciexport", code: -1, userInfo: nil))
          return
        }
        let size = req.renderContext.size
        let canvasRect = CGRect(origin: .zero, size: size)
        var out = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
          .cropped(to: canvasRect)
        let t = req.compositionTime.seconds
        let flipCanvas = CGAffineTransform(
          a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)

        // 馬賽克照 z 交錯：只糊排在它下面的層。疊完 z 比它低的層就
        // 先打碼，再把更高的層（例如子母畫面）疊上去——跟預覽一致
        let activeMz = ins.mosaics
          .filter { t >= $0.start && t < $0.end }
          .sorted { $0.z < $1.z }
        var mzIdx = 0
        var missing = false
        for layer in ins.layers {
          while mzIdx < activeMz.count, activeMz[mzIdx].z <= layer.z {
            out = self.applyMosaic(activeMz[mzIdx], to: out, canvas: size)
            mzIdx += 1
          }
          var img: CIImage
          if layer.trackID != kCMPersistentTrackID_Invalid {
            guard let buf = req.sourceFrame(byTrackID: layer.trackID) else {
              missing = true
              Self.noteMiss(t: t, track: Int(layer.trackID))
              continue
            }
            // HDR（HLG/PQ）來源：開系統的色調映射轉成 SDR，跟相簿、
            // 跟內建合成器同一套曲線。SDR 來源開著沒有影響
            let base: CIImage
            if #available(iOS 14.1, *) {
              // SDR 輸出＝系統色調映射（跟相簿同一條曲線）；
              // HDR 輸出＝不映射，HDR 像素原封進 HLG 管線
              base = CIImage(
                cvPixelBuffer: buf,
                options: [.toneMapHDRtoSDR: !self.hdrOut])
            } else {
              base = CIImage(cvPixelBuffer: buf)
            }
            // 變形是「左上原點、y 往下」的 AVFoundation 座標，Core Image
            // 是「左下原點、y 往上」：先把來源翻成 y 往下、套變形、再翻回
            let flipSrc = CGAffineTransform(
              a: 1, b: 0, c: 0, d: -1, tx: 0, ty: layer.srcHeight)
            img = base.transformed(
              by: flipSrc.concatenating(layer.transform)
                .concatenating(flipCanvas))
          } else if let gif = layer.gif {
            // 會動的 GIF：照輸出時間挑格（定位變形已烘在 spec 裡）
            guard let g = gif.image(at: t) else { continue }
            img = g
          } else if let still = layer.still {
            img = still  // 靜態圖層在建圖時就定位好了
          } else {
            continue
          }
          // 裁切：transform 沒有旋轉成分，貼上畫布是軸對齊的方框，
          // 直接照 extent 的比例切窗。比例是左上原點，CI 是左下——
          // y 要反過來。旋轉繞「整個片段框」的中心（跟預覽一致），
          // 所以中心用裁切前的 extent 算
          if layer.crop != nil || abs(layer.rotation) > 0.05 {
            let full = img.extent
            if full.width > 1, full.height > 1 {
              if let cr = layer.crop {
                img = img.cropped(
                  to: CGRect(
                    x: full.minX + cr.minX * full.width,
                    y: full.minY + (1 - cr.minY - cr.height) * full.height,
                    width: cr.width * full.width,
                    height: cr.height * full.height))
              }
              if abs(layer.rotation) > 0.05 {
                img = Self.spin(
                  img, degrees: layer.rotation,
                  around: CGPoint(x: full.midX, y: full.midY))
              }
            }
          }
          if let m = layer.colorMatrix {
            img = self.applyColor(img, m)
          }
          let a = layer.alpha(at: t) * layer.opacity
          if a < 0.999 {
            // 淡入淡出＝RGBA 一起乘（premultiplied 直接壓係數）：
            // 疊在下層畫面上就是正確的交叉淡化，疊在黑底上等同變暗
            img = img.applyingFilter(
              "CIColorMatrix",
              parameters: [
                "inputRVector": CIVector(x: CGFloat(a), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(a), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(a), w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(a)),
              ])
          }
          out = img.cropped(to: canvasRect).composited(over: out)
        }
        let tinyGap =
          ins.layers.isEmpty && ins.holdIfEmpty && self.lastComposed != nil
        if missing || tinyGap, let held = self.lastComposed {
          // 邊界缺格或極短空窗：上一格原封重播（已含馬賽克與疊加物）
          out = held
          Self.slowLock.lock()
          if missing {
            Self.holdMissCount += 1
          } else {
            Self.holdGapCount += 1
          }
          Self.slowLock.unlock()
        } else {
          while mzIdx < activeMz.count {
            out = self.applyMosaic(activeMz[mzIdx], to: out, canvas: size)
            mzIdx += 1
          }
          let ovs =
            self.livePreview
            ? CIExportCompositor.currentPreviewOverlays() : ins.overlays
          for ov in ovs {
            if var o = ov.frame(at: t, canvas: size) {
              if self.hdrOut {
                // HDR 輸出：疊加物（文字/浮水印/貼圖）在線性光提亮
                // 一檔（×2）。SDR 白疊在 HDR 畫面上只有基準白
                //（~203 尼特），旁邊高光動輒上千尼特，使用者挑的
                // 「白色」看起來就是灰的（實測回報：成品顏色跟挑的
                // 差很多）。提一檔後視覺上才是挑的那個顏色；
                // 預覽與匯出同一段程式碼，兩邊一起亮
                o = o.applyingFilter(
                  "CIColorMatrix",
                  parameters: [
                    "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0),
                  ])
              }
              out = o.composited(over: out)
            }
          }
        }
        self.ctx.render(out, to: dst, bounds: canvasRect, colorSpace: self.outCS)
        if !missing && !tinyGap {
          // 引用的是我們自己的輸出緩衝（不是解碼器的），
          // 只多佔用池子裡的一顆
          self.lastComposed = CIImage(cvPixelBuffer: dst)
        }
        req.finish(withComposedVideoFrame: dst)
        Self.noteFrame(
          t: t, ms: (CFAbsoluteTimeGetCurrent() - tick) * 1000,
          layers: ins.layers.count, missing: missing)
      }
    }
  }
}

/// HDR 匯出用的合成器：同一套疊圖邏輯，只是不做色調映射、
/// 輸出 10-bit HLG（見 CIExportCompositor.hdrOut）
class CIExportCompositorHDR: CIExportCompositor {
  override var hdrOut: Bool { true }
}

/// HDR「預覽」合成器：跟 HDR 匯出同一套疊圖，另外改讀即時疊加物
///（浮水印/文字直接烘在 HDR 畫面上、走 EDR 顯示——白色才是白色，
/// 而且提亮數學跟匯出同一段程式碼，預覽即所得）
final class CIPreviewCompositorHDR: CIExportCompositorHDR {
  override var livePreview: Bool { true }
}

/// 跨執行緒的一次性旗標。轉檔那條路上有兩個地方需要它：
/// 「中途失敗過」（不記的話截斷檔會被當成功換上去）與「已經回覆過」
///（逾時跟正常完成會撞在一起，回兩次就會有兩份結果）
final class AtomicFlag {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  /// 還沒設過才設起來並回 true；已經設過回 false
  func setIfClear() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if value { return false }
    value = true
    return true
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 抽幀用的 asset 快取：同一支影片反覆要幀，不用每次重新解析容器
  private var frameAssets = [String: AVURLAsset]()
  private let frameQueue = DispatchQueue(label: "markcut.frames")

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 正在跑的轉檔工作（取消用）。同時可能有兩支在轉，用 job 編號分開
  private var prepSessions: [Int: AVAssetExportSession] = [:]

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerPrepChannel(engineBridge)
    registerDiagChannel(engineBridge)
    registerCompChannel(engineBridge)
    registerExportChannel(engineBridge)

    // 拖曳預覽的「按需抽幀」通道：滑到哪、跟硬體解碼器要那一格。
    // HDR 的色調映射由系統做，顏色跟 AVPlayer 播放畫面天生一致
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "markcut.frames")
    else { return }
    let channel = FlutterMethodChannel(
      name: "markcut/frames", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self,
        call.method == "frameAt",
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        let ms = args["ms"] as? Int
      else {
        result(nil)
        return
      }
      let maxH = args["maxH"] as? Int ?? 540
      // 拖曳預覽壓得兇一點沒人看得出來；當裁切底圖時會被放大到滿版，
      // 壓縮痕跡就很明顯，呼叫端自己決定
      let jpegQ = CGFloat(args["q"] as? Double ?? 0.7)
      self.frameQueue.async {
        let asset: AVURLAsset
        if let cached = self.frameAssets[path] {
          asset = cached
        } else {
          if self.frameAssets.count > 4 { self.frameAssets.removeAll() }
          asset = AVURLAsset(url: URL(fileURLWithPath: path))
          self.frameAssets[path] = asset
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true  // 直式影片轉正
        gen.maximumSize = CGSize(width: maxH, height: maxH)
        // HDR（HLG）素材一定要壓回 SDR：copyCGImage 不會自己轉，
        // HLG 像素直接進 JPEG 就是「拖曳預覽顏色超飽和」（實測回報）。
        // 之前用 .forceSDR：它的轉換又平又淡，草稿封面「偏淡比起
        // 原圖」就是它（實測回報）。改成 .matchSource 拿回 HDR 影格，
        // 下面用跟合成播放器/工作檔同一條系統 toneMap 曲線壓 SDR
        // ——全 App 的顏色只有一套。
        // dynamicRangePolicy 是 iOS 18 的 API（16 會編譯失敗，CI 踩過）；
        // 17 以下維持舊行為（拖曳幀偏飽和，放開就正常）
        if #available(iOS 18.0, *) {
          gen.dynamicRangePolicy = .matchSource
        }
        // 容忍 0.15 秒：允許解碼器就近取材，不必逐格精準解到底，
        // 這是「快」的關鍵；拖曳預覽差半格人眼看不出來
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        var payload: FlutterStandardTypedData?
        if let cg = try? gen.copyCGImage(
          at: CMTime(value: Int64(ms), timescale: 1000), actualTime: nil)
        {
          var flat = UIImage(cgImage: cg)
          // HDR 影格（HLG/PQ 色彩空間）：用跟合成播放器/工作檔同一條
          // 系統 toneMap 曲線壓回 SDR。壓不成再退回原樣（頂多偏色，
          // 不能沒圖）
          if let cs = cg.colorSpace, CGColorSpaceUsesITUR_2100TF(cs) {
            let ci = CIImage(cgImage: cg, options: [.toneMapHDRtoSDR: true])
            if let sdr = CIExportCompositor.ctxSDR.createCGImage(
              ci, from: ci.extent, format: .RGBA8,
              colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            {
              flat = UIImage(cgImage: sdr)
            }
          }
          if let data = flat.jpegData(compressionQuality: jpegQ) {
            payload = FlutterStandardTypedData(bytes: data)
          }
        }
        DispatchQueue.main.async { result(payload) }
      }
    }
  }

  // MARK: - 合成播放器（markcut/comp）
  //
  // 整條時間軸組成一份 AVComposition、一顆 AVPlayer 播。
  // 為什麼要換掉「一片段一顆播放器」見 CompPlayer.swift 的說明
  private var comp: CompPlayer?

  private func registerCompChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "markcut.comp")
    else { return }
    let channel = FlutterMethodChannel(
      name: "markcut/comp", binaryMessenger: registrar.messenger())
    let textures = registrar.textures()
    // AVPlayerLayer 版的預覽：跟相簿播放同一條路，零複製
    registrar.register(PlayerViewFactory(), withId: "markcut/player_view")
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "available":
        result(true)
      case "build":
        guard let args = call.arguments as? [String: Any],
          let clips = args["clips"] as? [[String: Any]]
        else {
          result(nil)
          return
        }
        // 先組好新的，確定成功才換過去，最後才收掉舊的。
        //
        // 本來是「先 dispose 舊的再組新的」：組的過程中畫面上那層指著
        // 一顆已經被收掉的播放器（黑一下），而萬一組不起來就永遠黑著——
        // 使用者說的「按了切割整個畫面都消失」就是這條路
        let p = CompPlayer(registry: textures)
        let mosaics = args["mosaics"] as? [[String: Any]] ?? []
        let stills = args["stills"] as? [[String: Any]] ?? []
        let hdrOut = args["hdrOut"] as? Bool ?? false
        let overlays = args["overlays"] as? [[String: Any]] ?? []
        // 馬賽克/圖片/疊加層要走 CI 合成器：先把濾鏡管線暖起來，
        // 接縫不吃首編譯
        if !mosaics.isEmpty || !stills.isEmpty || !overlays.isEmpty {
          CIExportCompositor.warmUp()
        }
        guard
          p.build(
            clips: clips, texture: (args["texture"] as? Bool) ?? true,
            mosaics: mosaics, stills: stills, hdrOut: hdrOut,
            overlays: overlays)
        else {
          let why = p.buildError ?? "未知原因"
          p.dispose()
          result(["error": why])  // 舊的還活著，畫面照舊
          return
        }
        let old = self.comp
        self.comp = p
        // 舊的等新畫面真的上檔（第一格就緒翻面）才收：
        // 收早了前面那層還指著它，就是使用者看到的閃黑
        PlayerHosts.shared.use(p.player) { old?.dispose() }
        result([
          "textureId": p.textureId,
          "duration": p.duration,
          "width": Double(p.size.width),
          "height": Double(p.size.height),
          // 這一次組建有沒有掛 CI／HDR 判定（Dart 端寫進「就緒」的
          // 診斷歷史——組建內視鏡只留最後一次，進場那次會被蓋掉）
          "ci": (p.buildInfo["CI"] as? Bool) ?? false,
          "hdr": (p.buildInfo["HDR"] as? Bool) ?? false,
          // 疊加物有沒有走「即時清單」（HDR 預覽）：有的話 Dart 端
          // 把 Flutter 版藏起來、之後用 setOverlays 更新
          "wmLive": p.wmLive,
        ])
      case "setOverlays":
        // HDR 預覽的即時疊加物：換清單不重建合成（拖曳/改樣式用）。
        // 換完 Dart 端會補一個精準 seek 逼它重畫當下這一格
        let list =
          (call.arguments as? [String: Any])?["overlays"]
          as? [[String: Any]] ?? []
        guard let p = self.comp, p.wmLive, p.ciCanvas.width > 1 else {
          result(false)
          return
        }
        CIExportCompositor.setPreviewOverlays(
          list.compactMap { CIOverlaySpec($0, canvas: p.ciCanvas) })
        result(true)
      case "play":
        let st = self.comp?.playStatus()
        self.comp?.play()
        result(st)
      case "pause":
        self.comp?.pause()
        result(nil)
      case "rate":
        self.comp?.setRate((call.arguments as? Double) ?? 1)
        result(nil)
      case "muted":
        self.comp?.setMuted((call.arguments as? Bool) ?? false)
        result(nil)
      case "seek":
        if let a = call.arguments as? [String: Any] {
          self.comp?.seek(
            (a["sec"] as? Double) ?? 0, exact: (a["exact"] as? Bool) ?? false)
        } else {
          self.comp?.seek((call.arguments as? Double) ?? 0, exact: false)
        }
        result(nil)
      case "position":
        result(self.comp?.positionMs ?? 0)
      case "grab":
        let maxH = (call.arguments as? [String: Any])?["maxH"] as? Int ?? 1080
        if let c = self.comp {
          c.grabFrame(maxH: maxH) { data in
            DispatchQueue.main.async {
              result(data == nil ? nil : FlutterStandardTypedData(bytes: data!))
            }
          }
        } else {
          result(nil)
        }
      case "gaps":
        result(self.comp?.gapStats() ?? ["count": 0])
      case "health":
        result(self.comp?.healthStats() ?? [:])
      case "dispose":
        PlayerHosts.shared.use(nil)
        self.comp?.dispose()
        self.comp = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }


  // MARK: - 原生匯出（markcut/export）
  //
  // 匯出本來走 FFmpeg。它的 HDR 色調映射是 32 位元浮點的軟體運算，一格
  // 4K 就要 100MB，實測峰值 1.7GB——那正是「匯出閃退」的來源，也是
  // 「素材一定要先轉工作檔」這整套東西存在的唯一硬理由。
  //
  // 這裡改用系統自己的路：預覽已經在用的那份 AVComposition，浮水印與
  // 文字用 Core Animation 圖層疊上去，交給 AVAssetExportSession 硬體
  // 編碼。記憶體由系統管、顏色跟預覽天生一致（同一份合成）、速度是
  // 硬體對軟體的差距。
  //
  // 做不到的（子母畫面、馬賽克、照片素材）由呼叫端判斷後退回 FFmpeg
  private var exportSession: AVAssetExportSession?
  private var exportTimer: Timer?

  private func registerExportChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "markcut.export")
    else { return }
    let channel = FlutterMethodChannel(
      name: "markcut/export", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "available":
        result(true)
      case "hasHDR":
        // 這批檔案裡有沒有 HDR（HLG/PQ）影像軌。匯出頁用它決定
        // 要不要顯示「保留 HDR」的開關
        guard let paths = call.arguments as? [String] else {
          result(false)
          return
        }
        var found = false
        for p in paths where !found {
          let asset = AVURLAsset(url: URL(fileURLWithPath: p))
          for tr in asset.tracks(withMediaType: .video) {
            for d in tr.formatDescriptions {
              let desc = d as! CMFormatDescription
              guard
                let tf = CMFormatDescriptionGetExtension(
                  desc,
                  extensionKey: kCMFormatDescriptionExtension_TransferFunction)
                  as? String
              else { continue }
              if tf
                == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                  as String)
                || tf
                  == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
                    as String)
              {
                found = true
              }
            }
          }
        }
        result(found)
      case "cancel":
        self.exportSession?.cancelExport()
        result(nil)
      case "reverse":
        guard let a = call.arguments as? [String: Any] else {
          result("參數錯誤")
          return
        }
        self.runReverse(a, channel: channel) { err in result(err) }
      case "reverseCancel":
        self.reverseCancelled = true
        result(nil)
      case "run":
        guard let a = call.arguments as? [String: Any] else {
          result("參數錯誤")
          return
        }
        self.runExport(a, channel: channel) { err in result(err) }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // ===== 倒轉檔（原生）=====
  //
  // 「倒轉」在 App 裡是一次性前置處理：把選定區間渲染成一支「已倒好」
  // 的檔，之後整條管線（預覽、合成播放器、匯出）都當普通素材用。
  // 原本這一步交給 FFmpeg 的 reverse 濾鏡（軟體解編碼，整段吃記憶體
  // 得分段跑）。這裡改系統硬體管線：從片尾往片頭一窗一窗處理——
  // 窗內影格倒序寫出、窗與窗又倒序銜接，整支就是連續倒轉，
  // 全程只佔一窗的記憶體；聲音同一招（窗內 PCM 樣本反轉）
  private var reverseCancelled = false

  private func runReverse(
    _ a: [String: Any], channel: FlutterMethodChannel,
    done: @escaping (String?) -> Void
  ) {
    guard let path = a["path"] as? String, let out = a["out"] as? String
    else {
      done("參數錯誤")
      return
    }
    let start = a["start"] as? Double ?? 0
    let end = a["end"] as? Double ?? 0
    let maxLong = a["maxLong"] as? Int ?? 1920
    reverseCancelled = false
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var err: String? = "內部錯誤"
      if let self = self {
        err = self.reverseWork(
          path: path, start: start, end: end, out: out, maxLong: maxLong
        ) { v in
          DispatchQueue.main.async {
            channel.invokeMethod("progress", arguments: v)
          }
        }
      }
      DispatchQueue.main.async { done(err) }
    }
  }

  private func reverseWork(
    path: String, start: Double, end: Double, out: String, maxLong: Int,
    progress: @escaping (Double) -> Void
  ) -> String? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let vTrack = asset.tracks(withMediaType: .video).first else {
      return "沒有影像軌"
    }
    let dur = asset.duration.seconds
    let a = max(0, min(start, dur))
    let b = max(a + 0.05, min(end <= 0 ? dur : end, dur))

    // 輸出尺寸：轉正後的顯示尺寸，長邊夾在 maxLong
    let d0 = vTrack.naturalSize.applying(vTrack.preferredTransform)
    let dispW = max(1, abs(d0.width))
    let dispH = max(1, abs(d0.height))
    var k: CGFloat = 1
    if max(dispW, dispH) > CGFloat(maxLong) {
      k = CGFloat(maxLong) / max(dispW, dispH)
    }
    let outW = max(2, Int((dispW * k).rounded()) & ~1)
    let outH = max(2, Int((dispH * k).rounded()) & ~1)

    try? FileManager.default.removeItem(atPath: out)
    let writer: AVAssetWriter
    do {
      writer = try AVAssetWriter(
        outputURL: URL(fileURLWithPath: out), fileType: .mp4)
    } catch {
      return "開不了輸出檔：\(error.localizedDescription)"
    }
    let fps = vTrack.nominalFrameRate > 1 ? Double(vTrack.nominalFrameRate) : 30
    let vIn = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: outW,
        AVVideoHeightKey: outH,
        AVVideoCompressionPropertiesKey: [
          // 位元率跟工作檔同級，畫質不因倒轉降階
          AVVideoAverageBitRateKey: max(4_000_000, outW * outH * 6),
          AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
        ],
      ])
    vIn.expectsMediaDataInRealTime = false
    guard writer.canAdd(vIn) else { return "加不進影像軌" }
    writer.add(vIn)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: vIn,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ])

    // 聲音：讀成 PCM、窗內樣本反轉，寫回 AAC
    let aTrack = asset.tracks(withMediaType: .audio).first
    var aIn: AVAssetWriterInput? = nil
    var pcmDesc: CMAudioFormatDescription? = nil
    let sampleRate = 44_100.0
    let channels: UInt32 = 2
    if aTrack != nil {
      let input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: channels,
          AVEncoderBitRateKey: 128_000,
        ])
      input.expectsMediaDataInRealTime = false
      if writer.canAdd(input) {
        writer.add(input)
        aIn = input
      }
      var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger
          | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2 * channels, mFramesPerPacket: 1,
        mBytesPerFrame: 2 * channels, mChannelsPerFrame: channels,
        mBitsPerChannel: 16, mReserved: 0)
      CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &pcmDesc)
    }

    guard writer.startWriting() else {
      return "寫入器啟動失敗：\(writer.error?.localizedDescription ?? "?")"
    }
    writer.startSession(atSourceTime: .zero)

    // 轉正＋縮放交給解碼端的 videoComposition：讀出來就是輸出尺寸，
    // 一窗的記憶體占用固定（0.5 秒約 15 格 NV12，1080p 一格 3MB）
    let comp = AVMutableVideoComposition()
    comp.renderSize = CGSize(width: outW, height: outH)
    comp.frameDuration = CMTime(
      value: 1, timescale: CMTimeScale(max(1, Int(fps.rounded()))))
    let ins = AVMutableVideoCompositionInstruction()
    ins.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
    li.setTransform(
      vTrack.preferredTransform.concatenating(
        CGAffineTransform(scaleX: k, y: k)), at: .zero)
    ins.layerInstructions = [li]
    comp.instructions = [ins]

    let win = 0.5
    let steps = max(1, Int(ceil((b - a) / win)))
    var outAudioFrames: Int64 = 0
    for i in 0..<steps {
      if reverseCancelled {
        writer.cancelWriting()
        try? FileManager.default.removeItem(atPath: out)
        return "已取消"
      }
      let wEnd = b - Double(i) * win
      let wStart = max(a, wEnd - win)
      var frames: [(CVPixelBuffer, CMTime)] = []
      var pcm = Data()
      var readErr: String? = nil
      autoreleasepool {
        guard let reader = try? AVAssetReader(asset: asset) else {
          readErr = "讀取器開不起來"
          return
        }
        reader.timeRange = CMTimeRange(
          start: CMTime(seconds: wStart, preferredTimescale: 600),
          end: CMTime(seconds: wEnd, preferredTimescale: 600))
        let vOut = AVAssetReaderVideoCompositionOutput(
          videoTracks: [vTrack],
          videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String:
              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
          ])
        vOut.videoComposition = comp
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else {
          readErr = "讀不了影像"
          return
        }
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput? = nil
        if let at = aTrack, aIn != nil {
          let o = AVAssetReaderTrackOutput(
            track: at,
            outputSettings: [
              AVFormatIDKey: kAudioFormatLinearPCM,
              AVSampleRateKey: sampleRate,
              AVLinearPCMBitDepthKey: 16,
              AVLinearPCMIsFloatKey: false,
              AVLinearPCMIsBigEndianKey: false,
              AVLinearPCMIsNonInterleaved: false,
              AVNumberOfChannelsKey: channels,
            ])
          if reader.canAdd(o) {
            reader.add(o)
            aOut = o
          }
        }
        reader.startReading()
        while let sb = vOut.copyNextSampleBuffer() {
          if let pb = CMSampleBufferGetImageBuffer(sb) {
            frames.append((pb, CMSampleBufferGetPresentationTimeStamp(sb)))
          }
        }
        if let ao = aOut {
          while let sb = ao.copyNextSampleBuffer() {
            if let blk = CMSampleBufferGetDataBuffer(sb) {
              let len = CMBlockBufferGetDataLength(blk)
              var tmp = Data(count: len)
              tmp.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress {
                  _ = CMBlockBufferCopyDataBytes(
                    blk, atOffset: 0, dataLength: len, destination: base)
                }
              }
              pcm.append(tmp)
            }
          }
        }
        if reader.status == .failed {
          readErr = "讀取失敗：\(reader.error?.localizedDescription ?? "?")"
        }
      }
      if let e = readErr {
        writer.cancelWriting()
        return e
      }

      // 影格倒序寫出：這一窗在成品裡的起點＝(b - wEnd)。
      // 窗內用等距時間戳（窗長 ÷ 張數），來源變動幀率也不會亂
      let outBase = b - wEnd
      let step = (wEnd - wStart) / Double(max(1, frames.count))
      for (j, f) in frames.reversed().enumerated() {
        while !vIn.isReadyForMoreMediaData {
          // writer 中途失敗（磁碟滿等）時 isReadyForMoreMediaData
          // 可能永遠不變 true——沒有這個出口就是背景執行緒無限
          // 自旋、channel 永遠等不到回覆
          if reverseCancelled || writer.status != .writing { break }
          usleep(5000)
        }
        if reverseCancelled || writer.status != .writing { continue }
        if !adaptor.append(
          f.0,
          withPresentationTime: CMTime(
            seconds: outBase + Double(j) * step, preferredTimescale: 600))
        {
          break  // append 失敗＝writer 已壞，剩下的丟了也一樣
        }
      }
      frames.removeAll()

      if let input = aIn, let desc = pcmDesc, !pcm.isEmpty {
        let bpf = Int(2 * channels)
        let nFrames = pcm.count / bpf
        var rev = Data(capacity: nFrames * bpf)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
          guard let base = raw.baseAddress else { return }
          for f in stride(from: nFrames - 1, through: 0, by: -1) {
            rev.append(Data(bytes: base + f * bpf, count: bpf))
          }
        }
        var blk: CMBlockBuffer? = nil
        CMBlockBufferCreateWithMemoryBlock(
          allocator: kCFAllocatorDefault, memoryBlock: nil,
          blockLength: rev.count, blockAllocator: nil,
          customBlockSource: nil, offsetToData: 0,
          dataLength: rev.count, flags: 0, blockBufferOut: &blk)
        if let bb = blk {
          CMBlockBufferAssureBlockMemory(bb)
          rev.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
              _ = CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: bb,
                offsetIntoDestination: 0, dataLength: rev.count)
            }
          }
          var sb: CMSampleBuffer? = nil
          CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: bb,
            formatDescription: desc, sampleCount: nFrames,
            presentationTimeStamp: CMTime(
              value: outAudioFrames, timescale: Int32(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sb)
          if let s2 = sb {
            while !input.isReadyForMoreMediaData {
              if reverseCancelled || writer.status != .writing { break }
              usleep(5000)
            }
            if !reverseCancelled && writer.status == .writing {
              input.append(s2)
            }
            outAudioFrames += Int64(nFrames)
          }
        }
      }
      progress(Double(i + 1) / Double(steps))
    }
    if reverseCancelled {
      writer.cancelWriting()
      try? FileManager.default.removeItem(atPath: out)
      return "已取消"
    }
    vIn.markAsFinished()
    aIn?.markAsFinished()
    var err: String? = nil
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting {
      if writer.status != .completed {
        err = "寫檔失敗：\(writer.error?.localizedDescription ?? "?")"
      }
      sem.signal()
    }
    sem.wait()
    return err
  }

  /// 成功回 nil，失敗回原因字串（取消回「已取消」）
  private func runExport(
    _ a: [String: Any], channel: FlutterMethodChannel,
    done: @escaping (String?) -> Void
  ) {
    guard let clips = a["clips"] as? [[String: Any]],
      let dest = a["dest"] as? String,
      let outW = a["outW"] as? Int, let outH = a["outH"] as? Int,
      outW > 1, outH > 1
    else {
      done("參數錯誤")
      return
    }
    let audios = a["audios"] as? [[String: Any]] ?? []
    let overlays = a["overlays"] as? [[String: Any]] ?? []
    let globalSpeed = max(0.05, a["speed"] as? Double ?? 1)
    // 圖層模式：子母畫面／照片素材／馬賽克／調色。這些要每格在 GPU 上
    // 疊，一律走 CI 合成器；沒有這些的簡單匯出照舊走驗證過的舊路
    let layered = a["layered"] as? Bool ?? false
    let stillsIn = a["stills"] as? [[String: Any]] ?? []
    let mosaicsIn = a["mosaics"] as? [[String: Any]] ?? []
    // 時間軸總長（秒）：圖片素材可能比最後一段影片還晚結束，
    // 合成要補空白撐到這裡，不然片尾的圖會被切掉
    let timelineDur = a["timelineDuration"] as? Double ?? 0
    // GPU 合成（見 CIExportCompositor）。關掉＝退回 CoreAnimationTool
    // 舊路徑（實驗開關，成品有異狀時的備援）。
    // 沒有疊加物時不走：那種匯出本來就沒有 CoreAnimationTool 的瓶頸，
    // 標準路徑（layer instruction）是純硬體，CI 反而多一次像素格式轉換
    var useCI = layered || ((a["ci"] as? Bool ?? true) && !overlays.isEmpty)
    // HDR 來源一律不交給自訂合成器（見下面的 hasHDR）
    var hasHDR = false
    let canvas = CGSize(width: CGFloat(outW), height: CGFloat(outH))
    let scale: CMTimeScale = 600

    let comp = AVMutableComposition()
    guard
      let vTrack = comp.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      done("建不出視訊軌")
      return
    }
    // 圖層模式的多條視訊軌：跟聲音同一套「找一條排得下的，沒有就開新的」
    var vTracks: [(track: AVMutableCompositionTrack, end: CMTime)] = [
      (vTrack, .zero)
    ]
    func videoTrack(from t: CMTime) -> AVMutableCompositionTrack? {
      for i in vTracks.indices where vTracks[i].end <= t {
        return vTracks[i].track
      }
      guard
        let nt = comp.addMutableTrack(
          withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { return nil }
      vTracks.append((nt, .zero))
      return nt
    }
    func noteVideoEnd(_ track: AVMutableCompositionTrack, _ end: CMTime) {
      for i in vTracks.indices where vTracks[i].track === track {
        vTracks[i].end = end
      }
    }

    // 聲音可能同時有好幾層（影片自己的聲音＋配樂），一條軌塞不下重疊的
    // 時間範圍——需要幾條就開幾條，每條記自己排到哪
    var aTracks: [(track: AVMutableCompositionTrack, end: CMTime)] = []
    var aParams: [AVMutableAudioMixInputParameters] = []
    func audioTrack(from t: CMTime) -> AVMutableCompositionTrack? {
      for i in aTracks.indices where aTracks[i].end <= t {
        return aTracks[i].track
      }
      guard
        let nt = comp.addMutableTrack(
          withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
      else { return nil }
      aTracks.append((nt, .zero))
      aParams.append(AVMutableAudioMixInputParameters(track: nt))
      return nt
    }
    func noteAudioEnd(_ track: AVMutableCompositionTrack, _ end: CMTime) {
      for i in aTracks.indices where aTracks[i].track === track {
        aTracks[i].end = end
      }
    }
    func params(for track: AVMutableCompositionTrack)
      -> AVMutableAudioMixInputParameters?
    {
      for (i, t) in aTracks.enumerated() where t.track === track {
        return aParams[i]
      }
      return nil
    }

    /// 一段聲音：插進某條空著的軌，套音量與淡入淡出
    func addAudio(
      asset: AVAsset, range: CMTimeRange, at: CMTime, outDur: CMTime,
      volume: Float, fadeIn: Double, fadeOut: Double
    ) {
      guard let src = asset.tracks(withMediaType: .audio).first,
        let track = audioTrack(from: at)
      else { return }
      do {
        // 先補空白再插（跟 CompPlayer 的同名邏輯一致）：插在超過
        // 軌道長度的時間點時，「會不會自動補空白」文件講得含糊，
        // 不補的話配樂可能整段往前擠、聲音跟畫面對不上——預覽那條
        // 路是被實測逼出來的，匯出不能少這一道
        for i in aTracks.indices
        where aTracks[i].track === track && aTracks[i].end < at {
          track.insertEmptyTimeRange(
            CMTimeRange(start: aTracks[i].end, duration: at - aTracks[i].end))
        }
        try track.insertTimeRange(range, of: src, at: at)
        if outDur != range.duration {
          track.scaleTimeRange(
            CMTimeRange(start: at, duration: range.duration), toDuration: outDur)
        }
      } catch {
        return
      }
      let end = at + outDur
      noteAudioEnd(track, end)
      guard let pr = params(for: track) else { return }
      if fadeIn > 0.01 {
        pr.setVolumeRamp(
          fromStartVolume: 0, toEndVolume: volume,
          timeRange: CMTimeRange(
            start: at,
            duration: CMTime(seconds: fadeIn, preferredTimescale: scale)))
      } else {
        pr.setVolume(volume, at: at)
      }
      if fadeOut > 0.01 {
        let fo = CMTime(seconds: fadeOut, preferredTimescale: scale)
        pr.setVolumeRamp(
          fromStartVolume: volume, toEndVolume: 0,
          timeRange: CMTimeRange(start: end - fo, duration: fo))
      }
    }

    // ── 影片：照時間順序接成一條軌 ──────────────────────────────
    var cursor = CMTime.zero
    var segments:
      [(
        range: CMTimeRange, transform: CGAffineTransform, size: CGSize,
        fadeIn: Double, fadeOut: Double, userScale: Double, px: Double,
        py: Double, mirror: Bool, trackID: CMPersistentTrackID, z: Int,
        color: [Double]?, crop: [Double]?, rotation: Double, opacity: Double
      )] = []

    for clip in clips {
      guard let path = clip["path"] as? String else { continue }
      let start = clip["start"] as? Double ?? 0
      let end = clip["end"] as? Double ?? 0
      let gap = clip["gap"] as? Double ?? 0
      let volume = Float(clip["volume"] as? Double ?? 1)
      let speed = max(0.05, clip["speed"] as? Double ?? 1)
      let fadeIn = clip["fadeIn"] as? Double ?? 0
      let fadeOut = clip["fadeOut"] as? Double ?? 0
      let userScale = clip["scale"] as? Double ?? 1
      let px = clip["px"] as? Double ?? 0.5
      let py = clip["py"] as? Double ?? 0.5
      let mirror = clip["mirror"] as? Bool ?? false
      let clipOffset = clip["offset"] as? Double ?? 0
      let zTrack = clip["track"] as? Int ?? 0
      let colorM = clip["color"] as? [Double]
      let cropArr = clip["crop"] as? [Double]
      let rotation = clip["rotation"] as? Double ?? 0
      let opacity = clip["opacity"] as? Double ?? 1
      if end - start <= 0.01 { continue }

      if layered {
        // 圖層模式：照時間軸的絕對位置放，重疊就開新的一條軌
        cursor = CMTime(seconds: clipOffset, preferredTimescale: scale)
      } else if gap > 0.01 {
        let g = CMTime(seconds: gap, preferredTimescale: scale)
        vTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: g))
        cursor = cursor + g
      }
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      guard let src = asset.tracks(withMediaType: .video).first else { continue }
      // HLG／PQ 的來源：色調映射是 AVFoundation 內建合成器在做的，
      // 自訂合成器拿到的是「還沒映射」的原始畫格，直接當 709 render
      // 出來就是顏色變淡、發灰。這種來源退回內建那條路（慢一點但正確）
      // formatDescriptions 是 [Any]，而 CF 型別只能用強制轉型：
      // as? 會被編譯器擋（「一定會成功」是錯誤）、直接用又轉不過去，
      // as! 是官方文件的標準寫法
      for fd in src.formatDescriptions {
        let d = fd as! CMFormatDescription
        guard
          let tf = CMFormatDescriptionGetExtension(
            d, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
            as? String
        else { continue }
        if tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
          || tf
            == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        {
          hasHDR = true
        }
      }
      let range = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: scale),
        duration: CMTime(seconds: end - start, preferredTimescale: scale))
      let outDur =
        abs(speed - 1) > 0.001
        ? CMTime(seconds: (end - start) / speed, preferredTimescale: scale)
        : range.duration
      let destTrack = layered ? (videoTrack(from: cursor) ?? vTrack) : vTrack
      do {
        if layered {
          // 軌道上一段的結尾跟這段的開頭之間要補空白（合成不接受洞）
          let prevEnd = vTracks.first(where: { $0.track === destTrack })?.end
            ?? .zero
          if cursor > prevEnd {
            destTrack.insertEmptyTimeRange(
              CMTimeRange(start: prevEnd, end: cursor))
          }
        }
        try destTrack.insertTimeRange(range, of: src, at: cursor)
        if outDur != range.duration {
          destTrack.scaleTimeRange(
            CMTimeRange(start: cursor, duration: range.duration),
            toDuration: outDur)
        }
      } catch {
        done("素材接不進時間軸")
        return
      }
      if layered { noteVideoEnd(destTrack, cursor + outDur) }
      if volume > 0.001 {
        addAudio(
          asset: asset, range: range, at: cursor, outDur: outDur,
          volume: volume, fadeIn: fadeIn, fadeOut: fadeOut)
      }
      segments.append((
        range: CMTimeRange(start: cursor, duration: outDur),
        transform: src.preferredTransform, size: src.naturalSize,
        fadeIn: fadeIn, fadeOut: fadeOut, userScale: userScale, px: px,
        py: py, mirror: mirror, trackID: destTrack.trackID, z: zTrack,
        color: colorM, crop: cropArr, rotation: rotation, opacity: opacity
      ))
      cursor = cursor + outDur
    }
    if layered {
      // 時間軸的尾巴可能是圖片素材：主軌補空白撐到總長，
      // 不然合成在最後一段影片結束就收工了
      var maxEnd = vTracks.map { $0.end }.max() ?? .zero
      let want = CMTime(seconds: timelineDur, preferredTimescale: scale)
      if want > maxEnd {
        // 補在主軌自己的結尾之後（不是 maxEnd）：主軌可能比別的軌短，
        // 從 maxEnd 開始補會在中間留一個洞，合成不接受
        let ownEnd = vTracks[0].end
        vTrack.insertEmptyTimeRange(CMTimeRange(start: ownEnd, end: want))
        noteVideoEnd(vTrack, want)
        maxEnd = want
      }
      cursor = maxEnd
    }
    if cursor.seconds <= 0.01 {
      done("時間軸沒有內容")
      return
    }

    // ── 純聲音素材（配樂）：可以跟影片重疊 ─────────────────────
    for m in audios {
      guard let path = m["path"] as? String else { continue }
      let start = m["start"] as? Double ?? 0
      let end = m["end"] as? Double ?? 0
      if end - start <= 0.01 { continue }
      let at = CMTime(
        seconds: m["offset"] as? Double ?? 0, preferredTimescale: scale)
      let speed = max(0.05, m["speed"] as? Double ?? 1)
      let range = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: scale),
        duration: CMTime(seconds: end - start, preferredTimescale: scale))
      let outDur =
        abs(speed - 1) > 0.001
        ? CMTime(seconds: (end - start) / speed, preferredTimescale: scale)
        : range.duration
      addAudio(
        asset: AVURLAsset(url: URL(fileURLWithPath: path)), range: range,
        at: at, outDur: outDur, volume: Float(m["volume"] as? Double ?? 1),
        fadeIn: m["fadeIn"] as? Double ?? 0, fadeOut: m["fadeOut"] as? Double ?? 0
      )
    }

    // ── 整條時間軸的速度 ───────────────────────────────────────
    if abs(globalSpeed - 1) > 0.001 {
      let whole = CMTimeRange(start: .zero, duration: cursor)
      let target = CMTime(
        seconds: cursor.seconds / globalSpeed, preferredTimescale: scale)
      if layered {
        for vt in vTracks where vt.end > .zero {
          vt.track.scaleTimeRange(
            CMTimeRange(start: .zero, duration: vt.end),
            toDuration: CMTime(
              seconds: vt.end.seconds / globalSpeed,
              preferredTimescale: scale))
        }
      } else {
        vTrack.scaleTimeRange(whole, toDuration: target)
      }
      for t in aTracks {
        t.track.scaleTimeRange(
          CMTimeRange(start: .zero, duration: t.end), toDuration: target)
      }
      // 片段的時間範圍也跟著換算，圖層指令才對得上
      for i in segments.indices {
        segments[i].range = CMTimeRange(
          start: CMTime(
            seconds: segments[i].range.start.seconds / globalSpeed,
            preferredTimescale: scale),
          duration: CMTime(
            seconds: segments[i].range.duration.seconds / globalSpeed,
            preferredTimescale: scale))
        segments[i].fadeIn /= globalSpeed
        segments[i].fadeOut /= globalSpeed
      }
    }
    let total = comp.duration.seconds

    // ── 畫面：每段貼齊畫布（轉正 → 等比縮放 → 置中 → 使用者變形）──
    let vc = AVMutableVideoComposition()
    vc.renderSize = canvas
    // 順暢度：指定張數就照指定的走，沒指定維持 30
    let fpsOut = a["fps"] as? Int ?? 0
    vc.frameDuration = CMTime(
      value: 1, timescale: fpsOut > 0 ? CMTimeScale(fpsOut) : 30)
    // HDR 輸出：使用者要「跟原片一樣」而且來源真的是 HDR 才開。
    // SDR 轉出來在 HDR 螢幕上永遠跟原片有落差（亮度被壓縮了），
    // 唯一的真解是輸出檔本身就是 HDR（HEVC 10-bit HLG）
    var wantHDR = (a["hdr"] as? Bool ?? false) && hasHDR
    if wantHDR, #unavailable(iOS 15.0) { wantHDR = false }
    if wantHDR {
      // 疊加物要在 HLG 管線裡合成，一律走 CI
      useCI = true
      vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
      vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
      vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
    } else {
      // 明確標成 709。素材是 iPhone 預設的 4K HLG（HDR），不標的話 HDR
      // 的色彩標記會原封帶進輸出檔，播放器再自己套一次曲線——輕則顏色
      // 歪掉，重則整片黑。轉工作檔那段早就踩過同一個坑，這裡漏了
      vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
      vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
      vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    }
    var instructions: [AVMutableVideoCompositionInstruction] = []
    // HDR 在 GPU 路裡用 toneMapHDRtoSDR 處理（見 startRequest）；
    // 只有拿不到那個選項的舊系統才退回內建合成器
    if hasHDR {
      if #available(iOS 14.1, *) {
        // GPU 路自己會做色調映射，照走
      } else if layered {
        // 圖層模式沒有備援路（多軌合成只有 CI 做得到），
        // 這種老系統直接退回 FFmpeg
        done("HDR 圖層匯出需要 iOS 14.1")
        return
      } else {
        useCI = false
      }
    }
    // 走哪條合成路寫進診斷：浮水印「預覽有浮雕、匯出扁平」查了
    // 兩輪都在猜這格——CI（gamma 混色，跟預覽一致）還是 CA 圖層
    channel.invokeMethod(
      "note",
      arguments:
        "原生匯出路徑：\(useCI ? "CI 合成器（gamma 混色）" : "CA 圖層")"
        + (wantHDR ? "／HDR 輸出" : "")
        + "／疊加 \(overlays.count) 張")
    // GPU 路：疊加物先整批解好（PNG → 畫布大小的 CIImage），
    // 每段指令都帶同一份
    let ciOverlays: [CIOverlaySpec] =
      useCI ? overlays.compactMap { CIOverlaySpec($0, canvas: canvas) } : []
    var ciInstructions: [CIExportInstruction] = []
    // 圖層模式：先把每一層收起來（z 序＝時間軸軌道，由下而上），
    // 迴圈跑完再按邊界切段
    var layerBasket: [(z: Int, order: Int, layer: CILayerSpec)] = []
    // 指令必須首尾相接把整條蓋滿：段落之間的空白（gap）也要有一段
    // 「黑底＋疊加物」的指令，缺一段合成就不合法
    var ciCursor = CMTime.zero
    for seg in segments {
      let disp = seg.size.applying(seg.transform)
      let dw = abs(disp.width)
      let dh = abs(disp.height)
      guard dw > 1, dh > 1 else { continue }
      let k = min(canvas.width / dw, canvas.height / dh)
      // 鏡像在「轉正之後的顯示座標」上做：先左右翻，再推回原位，
      // 後面的縮放置中就完全不用改
      var t = seg.transform
      if seg.mirror {
        t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1))
          .concatenating(CGAffineTransform(translationX: dw, y: 0))
      }
      t = t
        .concatenating(CGAffineTransform(scaleX: k, y: k))
        .concatenating(
          CGAffineTransform(
            translationX: (canvas.width - dw * k) / 2,
            y: (canvas.height - dh * k) / 2))
      let u = CGFloat(seg.userScale)
      if abs(seg.userScale - 1) > 0.001 || abs(seg.px - 0.5) > 0.001
        || abs(seg.py - 0.5) > 0.001
      {
        t = t
          .concatenating(
            CGAffineTransform(
              translationX: -canvas.width / 2, y: -canvas.height / 2)
          )
          .concatenating(CGAffineTransform(scaleX: u, y: u))
          .concatenating(
            CGAffineTransform(
              translationX: canvas.width / 2 + CGFloat(seg.px - 0.5)
                * canvas.width,
              y: canvas.height / 2 + CGFloat(seg.py - 0.5) * canvas.height))
      }
      if layered {
        // 裁切窗：預覽是「先裁再鏡像」，這裡的 transform 已含鏡像，
        // 所以鏡像時窗的水平位置要翻過來
        var cropRect: CGRect? = nil
        if let ca = seg.crop, ca.count >= 4, ca[2] > 0.001, ca[3] > 0.001 {
          let l = seg.mirror ? 1 - ca[0] - ca[2] : ca[0]
          cropRect = CGRect(x: l, y: ca[1], width: ca[2], height: ca[3])
        }
        layerBasket.append((
          z: seg.z, order: layerBasket.count,
          layer: CILayerSpec(
            trackID: seg.trackID, still: nil, transform: t,
            srcHeight: seg.size.height, start: seg.range.start.seconds,
            end: seg.range.end.seconds, fadeIn: seg.fadeIn,
            fadeOut: seg.fadeOut, colorMatrix: seg.color,
            crop: cropRect, rotation: seg.rotation, opacity: seg.opacity,
            z: seg.z)
        ))
        continue
      }
      if useCI {
        if seg.range.start > ciCursor {
          let gap = CMTimeRange(start: ciCursor, end: seg.range.start)
          ciInstructions.append(
            CIExportInstruction(
              timeRange: gap,
              layers: [], mosaics: [], overlays: ciOverlays,
              holdIfEmpty: gap.duration.seconds < 0.12))
        }
        ciInstructions.append(
          CIExportInstruction(
            timeRange: seg.range,
            layers: [
              CILayerSpec(
                trackID: seg.trackID, still: nil, transform: t,
                srcHeight: seg.size.height,
                start: seg.range.start.seconds, end: seg.range.end.seconds,
                fadeIn: seg.fadeIn, fadeOut: seg.fadeOut, colorMatrix: nil)
            ],
            mosaics: [], overlays: ciOverlays))
        ciCursor = seg.range.end
        continue
      }
      let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
      li.setTransform(t, at: seg.range.start)
      if seg.fadeIn > 0.01 {
        li.setOpacityRamp(
          fromStartOpacity: 0, toEndOpacity: 1,
          timeRange: CMTimeRange(
            start: seg.range.start,
            duration: CMTime(seconds: seg.fadeIn, preferredTimescale: scale)))
      }
      if seg.fadeOut > 0.01 {
        let fo = CMTime(seconds: seg.fadeOut, preferredTimescale: scale)
        li.setOpacityRamp(
          fromStartOpacity: 1, toEndOpacity: 0,
          timeRange: CMTimeRange(start: seg.range.end - fo, duration: fo))
      }
      let ins = AVMutableVideoCompositionInstruction()
      ins.timeRange = seg.range
      ins.layerInstructions = [li]
      instructions.append(ins)
    }
    if layered {
      // 照片素材：讀進來、照「貼合畫布 → 使用者變形」定位好，
      // 座標翻轉也在這裡一次做完（見 CIExportCompositor 的說明）
      for st in stillsIn {
        guard let path = st["path"] as? String,
          let ui = UIImage(contentsOfFile: path), let cg = ui.cgImage
        else { continue }
        var img = CIImage(cgImage: cg)
        let dw = img.extent.width
        let dh = img.extent.height
        guard dw > 1, dh > 1 else { continue }
        var t = CGAffineTransform.identity
        if st["mirror"] as? Bool ?? false {
          t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1))
            .concatenating(CGAffineTransform(translationX: dw, y: 0))
        }
        let k = min(canvas.width / dw, canvas.height / dh)
        t = t.concatenating(CGAffineTransform(scaleX: k, y: k))
          .concatenating(
            CGAffineTransform(
              translationX: (canvas.width - dw * k) / 2,
              y: (canvas.height - dh * k) / 2))
        let u = CGFloat(st["scale"] as? Double ?? 1)
        let px = st["px"] as? Double ?? 0.5
        let py = st["py"] as? Double ?? 0.5
        if abs(Double(u) - 1) > 0.001 || abs(px - 0.5) > 0.001
          || abs(py - 0.5) > 0.001
        {
          t = t
            .concatenating(
              CGAffineTransform(
                translationX: -canvas.width / 2, y: -canvas.height / 2)
            )
            .concatenating(CGAffineTransform(scaleX: u, y: u))
            .concatenating(
              CGAffineTransform(
                translationX: canvas.width / 2 + CGFloat(px - 0.5)
                  * canvas.width,
                y: canvas.height / 2 + CGFloat(py - 0.5) * canvas.height))
        }
        let flipSrc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: dh)
        let flipCanvas = CGAffineTransform(
          a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height)
        let placement = flipSrc.concatenating(t).concatenating(flipCanvas)
        // GIF：不烘成單張，把定位矩陣連同 ImageIO 來源包成
        // CIGifSpec，合成器照輸出時間逐幀取（見 CIGifSpec）。
        // 只有一格的「GIF」照舊當靜態圖
        var gifSpec: CIGifSpec? = nil
        if st["gif"] as? Bool ?? false {
          gifSpec = CIGifSpec(
            path: path, placement: placement,
            clipStart: st["start"] as? Double ?? 0)
        }
        if gifSpec == nil {
          img = img.transformed(by: placement)
        }
        var stCrop: CGRect? = nil
        if let ca = st["crop"] as? [Double], ca.count >= 4, ca[2] > 0.001,
          ca[3] > 0.001
        {
          let mir = st["mirror"] as? Bool ?? false
          let l = mir ? 1 - ca[0] - ca[2] : ca[0]
          stCrop = CGRect(x: l, y: ca[1], width: ca[2], height: ca[3])
        }
        layerBasket.append((
          z: st["track"] as? Int ?? 0, order: layerBasket.count,
          layer: CILayerSpec(
            trackID: kCMPersistentTrackID_Invalid,
            still: gifSpec == nil ? img : nil,
            transform: .identity, srcHeight: dh,
            // 時間全是「時間軸秒」；整體變速時合成的時間基準已被
            // scaleTimeRange 除過 globalSpeed，影片段的時間有跟著
            // 除（見上面 segments 的換算），這裡不除的話圖片/GIF
            // 會出現在未換算的時間點、跟畫面錯位
            start: (st["start"] as? Double ?? 0) / globalSpeed,
            end: (st["end"] as? Double ?? 0) / globalSpeed,
            fadeIn: (st["fadeIn"] as? Double ?? 0) / globalSpeed,
            fadeOut: (st["fadeOut"] as? Double ?? 0) / globalSpeed,
            colorMatrix: st["color"] as? [Double],
            crop: stCrop,
            rotation: st["rotation"] as? Double ?? 0,
            opacity: st["opacity"] as? Double ?? 1,
            z: st["track"] as? Int ?? 0, gif: gifSpec)
        ))
      }
      // z 序排定（同 z 保持進籃順序）
      layerBasket.sort { $0.z != $1.z ? $0.z < $1.z : $0.order < $1.order }
      // 馬賽克時間同理要除整體變速（切點是從這些值長出來的，
      // 一併對齊）
      let ciMosaics = mosaicsIn.compactMap { m -> CIMosaicSpec? in
        var mm = m
        if abs(globalSpeed - 1) > 0.001 {
          mm["start"] = (m["start"] as? Double ?? 0) / globalSpeed
          mm["end"] = (m["end"] as? Double ?? 0) / globalSpeed
        }
        return CIMosaicSpec(mm, canvas: canvas)
      }
      // 全部影像軌都預捲（跟合成播放器同一個治本，見
      // CIExportInstruction.requiredSourceTrackIDs）
      let prerollIDs = Array(
        Set(
          layerBasket.compactMap {
            $0.layer.trackID == kCMPersistentTrackID_Invalid
              ? nil : $0.layer.trackID
          })
      ).sorted().map { NSNumber(value: $0) }

      // 邊界切段：每一層／每塊馬賽克的頭尾都是切點，
      // 切出來的每一段「有哪些層」固定，一段一條指令
      let total = comp.duration
      var qs = Set<Int64>()
      func q(_ sec: Double) -> Int64 { Int64((sec * 600).rounded()) }
      for e in layerBasket {
        qs.insert(q(e.layer.start))
        qs.insert(q(e.layer.end))
      }
      for m in ciMosaics {
        qs.insert(q(m.start))
        qs.insert(q(m.end))
      }
      let totalQ = q(total.seconds)
      var cuts: [CMTime] = [.zero]
      for v in qs.sorted() where v > 0 && v < totalQ {
        cuts.append(CMTime(value: v, timescale: 600))
      }
      cuts.append(total)
      var built: [CIExportInstruction] = []
      for j in 0..<(cuts.count - 1) {
        let a0 = cuts[j]
        let b0 = cuts[j + 1]
        if b0 <= a0 { continue }
        let mid = (a0.seconds + b0.seconds) / 2
        let act = layerBasket.filter {
          mid >= $0.layer.start && mid < $0.layer.end
        }
        built.append(
          CIExportInstruction(
            timeRange: CMTimeRange(start: a0, end: b0),
            layers: act.map { $0.layer }, mosaics: ciMosaics,
            overlays: ciOverlays, prerollTrackIDs: prerollIDs,
            holdIfEmpty: act.isEmpty && (b0 - a0).seconds < 0.12))
      }
      vc.customVideoCompositorClass =
        wantHDR ? CIExportCompositorHDR.self : CIExportCompositor.self
      vc.instructions = built
    } else if useCI {
      if comp.duration > ciCursor {
        ciInstructions.append(
          CIExportInstruction(
            timeRange: CMTimeRange(start: ciCursor, end: comp.duration),
            layers: [], mosaics: [], overlays: ciOverlays))
      }
      vc.customVideoCompositorClass =
        wantHDR ? CIExportCompositorHDR.self : CIExportCompositor.self
      vc.instructions = ciInstructions
    } else {
      vc.instructions = instructions
    }

    // ── 浮水印與文字：Core Animation 圖層（舊路徑備援）────────
    if !useCI && !overlays.isEmpty {
      let parent = CALayer()
      parent.frame = CGRect(origin: .zero, size: canvas)
      // 影片合成的座標原點在左下，而 PNG 是照左上角畫的——不翻的話
      // 浮水印會上下顛倒
      parent.isGeometryFlipped = true
      let videoLayer = CALayer()
      videoLayer.frame = parent.frame
      parent.addSublayer(videoLayer)
      for ov in overlays {
        if let l = overlayLayer(ov, canvas: canvas, total: total) {
          parent.addSublayer(l)
        }
      }
      vc.animationTool = AVVideoCompositionCoreAnimationTool(
        postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    let mix = AVMutableAudioMix()
    mix.inputParameters = aParams

    // 預設輸出尺寸由 renderSize 決定，preset 只決定編碼品質上限：
    // 挑一個裝得下畫布的，不然系統會把畫面縮下去
    let long = max(canvas.width, canvas.height)
    let preset: String
    if wantHDR {
      // HDR 一定要 HEVC（H.264 沒有 10-bit HLG 這回事）
      if long > 1920,
        AVAssetExportSession.allExportPresets().contains(
          AVAssetExportPresetHEVC3840x2160)
      {
        preset = AVAssetExportPresetHEVC3840x2160
      } else {
        preset = AVAssetExportPresetHEVC1920x1080
      }
    } else if long > 1920,
      AVAssetExportSession.allExportPresets().contains(
        AVAssetExportPreset3840x2160)
    {
      preset = AVAssetExportPreset3840x2160
    } else if long > 1280 {
      preset = AVAssetExportPreset1920x1080
    } else {
      preset = AVAssetExportPreset1280x720
    }
    guard let session = AVAssetExportSession(asset: comp, presetName: preset)
    else {
      done("這台機器建不出匯出工作")
      return
    }
    try? FileManager.default.removeItem(atPath: dest)
    session.outputURL = URL(fileURLWithPath: dest)
    session.outputFileType = .mp4
    session.videoComposition = vc
    if !aParams.isEmpty { session.audioMix = mix }
    // 這個開關會在編碼完之後「再把整個檔案重寫一遍」，只為了把
    // moov atom 搬到檔頭讓網路串流可以邊下載邊播。成品是存進相簿的，
    // 沒有人在串流它——多的那一趟純粹是白等，長片尤其明顯
    session.shouldOptimizeForNetworkUse = false

    exportSession = session
    exportTimer?.invalidate()
    exportTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
      [weak session] _ in
      guard let session = session else { return }
      channel.invokeMethod("progress", arguments: Double(session.progress))
    }
    session.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        self?.exportTimer?.invalidate()
        self?.exportTimer = nil
        self?.exportSession = nil
        switch session.status {
        case .completed:
          // 驗收：抽兩格看是不是整片黑。
          //
          // 匯出「成功但畫面是黑的」不會有任何錯誤——檔案照樣生出來、
          // 存進相簿，使用者要等整支匯完才發現。這種錯不能靠使用者回報，
          // 這裡自己看一眼；黑的就當作失敗，呼叫端會退回 FFmpeg 重跑
          if self?.looksBlank(dest) == true {
            try? FileManager.default.removeItem(atPath: dest)
            done("畫面是黑的（已丟掉，改用 FFmpeg）")
            return
          }
          channel.invokeMethod("progress", arguments: 1.0)
          done(nil)
        case .cancelled:
          try? FileManager.default.removeItem(atPath: dest)
          done("已取消")
        default:
          try? FileManager.default.removeItem(atPath: dest)
          if let e = session.error as NSError? {
            done("\(e.localizedDescription)[\(e.domain) \(e.code)]")
          } else {
            done("status=\(session.status.rawValue)")
          }
        }
      }
    }
  }

  /// 抽兩格看畫面是不是整片黑（匯出的驗收）。
  ///
  /// 只看亮度：把影格縮成 32x32 拿出來，只要有任何一格不是幾乎全黑就算
  /// 過。真的全黑的影片本來就很少，誤判的代價也只是多跑一次 FFmpeg
  private func looksBlank(_ path: String) -> Bool {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let dur = asset.duration.seconds
    guard dur > 0.05 else { return true }
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 32, height: 32)
    gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
    for frac in [0.1, 0.5] {
      let t = CMTime(seconds: dur * frac, preferredTimescale: 600)
      guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { continue }
      let w = cg.width
      let h = cg.height
      guard w > 0, h > 0 else { continue }
      var buf = [UInt8](repeating: 0, count: w * h * 4)
      guard
        let ctx = CGContext(
          data: &buf, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { continue }
      ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
      for i in stride(from: 0, to: buf.count, by: 4) {
        if Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2]) > 24 { return false }
      }
    }
    return true
  }

  /// 一張整版 PNG 疊在畫面上，只在它的時間範圍內出現。
  ///
  /// 動畫跟 FFmpeg 那條路一致：閃爍＝週期性開關、飄移＝原地小幅擺動、
  /// 跑馬燈＝整版由右向左掃過
  private func overlayLayer(
    _ ov: [String: Any], canvas: CGSize, total: Double
  ) -> CALayer? {
    guard let data = (ov["png"] as? FlutterStandardTypedData)?.data,
      let img = UIImage(data: data)?.cgImage
    else { return nil }
    let layer = CALayer()
    layer.frame = CGRect(origin: .zero, size: canvas)
    layer.contents = img
    layer.contentsGravity = .resize
    layer.isOpaque = false

    let start = max(0, ov["start"] as? Double ?? 0)
    let end = min(total, ov["end"] as? Double ?? total)
    let anim = ov["anim"] as? String ?? "none"
    let cycle = max(0.05, ov["cycle"] as? Double ?? 1.2)
    let on = max(0.01, ov["on"] as? Double ?? 0.7)
    let animSpeed = max(0.05, ov["animSpeed"] as? Double ?? 1)
    let range = max(0.01, ov["range"] as? Double ?? 1)
    if end <= start { return nil }

    // 顯示區間（閃爍就在區間內再切開關）。用離散關鍵幀＝硬開硬關
    var times: [Double] = [0]
    var values: [Double] = [0]
    func mark(_ t: Double, _ v: Double) {
      let c = min(max(t, 0), total)
      if let last = times.last, c < last { return }
      times.append(c)
      values.append(v)
    }
    if anim == "blink" {
      var t = start
      while t < end {
        mark(t, 1)
        mark(min(t + on, end), 0)
        t += cycle
      }
    } else {
      mark(start, 1)
      mark(end, 0)
    }
    let op = CAKeyframeAnimation(keyPath: "opacity")
    op.calculationMode = .discrete
    op.duration = max(0.05, total)
    op.values = values
    op.keyTimes = times.map { NSNumber(value: $0 / max(0.05, total)) }
    op.beginTime = AVCoreAnimationBeginTimeAtZero
    op.isRemovedOnCompletion = false
    op.fillMode = .both
    layer.opacity = 0
    layer.add(op, forKey: "markcut.window")

    let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
    layer.position = center
    if anim == "drift" {
      // 跟 FFmpeg 同一組係數：x=sin(t*1.3v)*W*0.02r、y=cos(t*0.9v)*H*0.02r
      let amp = 0.02 * range
      let steps = min(1200, max(30, Int(total * 12)))
      var pts: [NSValue] = []
      for i in 0...steps {
        let t = total * Double(i) / Double(steps)
        pts.append(
          NSValue(cgPoint: CGPoint(
            x: center.x + sin(t * 1.3 * animSpeed) * canvas.width * amp,
            y: center.y + cos(t * 0.9 * animSpeed) * canvas.height * amp)))
      }
      let mv = CAKeyframeAnimation(keyPath: "position")
      mv.values = pts
      mv.duration = max(0.05, total)
      mv.beginTime = AVCoreAnimationBeginTimeAtZero
      mv.isRemovedOnCompletion = false
      mv.fillMode = .both
      layer.add(mv, forKey: "markcut.drift")
    } else if anim == "marquee" {
      let mv = CABasicAnimation(keyPath: "position.x")
      mv.fromValue = center.x + canvas.width
      mv.toValue = center.x - canvas.width
      mv.duration = cycle
      mv.repeatCount = .greatestFiniteMagnitude
      mv.beginTime = AVCoreAnimationBeginTimeAtZero
      mv.isRemovedOnCompletion = false
      mv.fillMode = .both
      layer.add(mv, forKey: "markcut.marquee")
    }
    return layer
  }

  // MARK: - 診斷（markcut/diag）
  //
  // 匯出被系統收掉時不會留下任何當機報告，只能靠「死掉前吃多少記憶體」
  // 回推。phys_footprint 就是 jetsam 判定用的那個數字（不是 residentSize，
  // 那個會把共用的頁面也算進來，看起來永遠偏大）；
  // os_proc_available_memory 是「這個 App 還能再要多少」，
  // 比總量更能預測會不會被收掉
  private func registerDiagChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "markcut.diag")
    else { return }
    let channel = FlutterMethodChannel(
      name: "markcut/diag", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      // 音訊 session 的啟用成本。
      //
      // 插件只設 category、從來沒有主動 setActive；iOS 是在播放真的開始
      // 時才隱式啟用，而啟用要跟音訊伺服器協商，典型 100~300ms——
      // 那正是「按下播放要等一下畫面才動」的量級，而且完全不在影片
      // 解碼那條路上（所以改 preroll、改 playImmediately 都沒用）。
      // 進編輯器時先啟用起來並保持著，播放鍵就不用付這筆錢
      if call.method == "activateAudio" {
        let t0 = CACurrentMediaTime()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        result(Int((CACurrentMediaTime() - t0) * 1000))
        return
      }
      if call.method == "deactivateAudio" {
        try? AVAudioSession.sharedInstance().setActive(
          false, options: [.notifyOthersOnDeactivation])
        result(nil)
        return
      }
      // 裝置狀態：連續匯出幾支 4K 之後手機會燙，系統一降頻什麼都會頓。
      // 這種「全部一起變慢」的卡頓，查程式碼永遠查不到
      if call.method == "deviceState" {
        let t: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: t = "正常"
        case .fair: t = "微溫"
        case .serious: t = "過熱（系統已降頻）"
        case .critical: t = "嚴重過熱（大幅降頻）"
        @unknown default: t = "?"
        }
        result([
          "thermal": t,
          "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
        ])
        return
      }
      guard call.method == "memory" else {
        result(FlutterMethodNotImplemented)
        return
      }
      var info = task_vm_info_data_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
      let kerr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
      }
      let mb = 1024.0 * 1024.0
      let used = kerr == KERN_SUCCESS ? Double(info.phys_footprint) / mb : 0
      var free = 0.0
      if #available(iOS 13.0, *) {
        free = Double(os_proc_available_memory()) / mb
      }
      result(["usedMb": used, "freeMb": free])
    }
  }

  // MARK: - 素材工作檔（markcut/prep）
  //
  // 把 4K HDR 原檔轉成 1080p SDR 的 H.264 工作檔，之後預覽、拖曳、匯出
  // 都用它。轉檔本身走 AVAssetExportSession：硬體加速，而且 HDR→SDR 的
  // 色調映射是系統做的，跟 AVPlayer 播出來的顏色天生一致。
  //
  // 為什麼不用 FFmpeg 轉：它的色調映射是 32 位元浮點的軟體運算，一格 4K
  // 就要 100MB，實測一支 4K HDR 的峰值 1.7GB——那正是匯出閃退的原因，
  // 拿它來做工作檔只是把同一個問題搬到匯入
  private func registerPrepChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "markcut.prep")
    else { return }
    let channel = FlutterMethodChannel(
      name: "markcut/prep", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "available":
        result(true)
      case "cancel":
        for s in self.prepSessions.values { s.cancelExport() }
        result(nil)
      case "toWorkFile":
        guard let args = call.arguments as? [String: Any],
          let src = args["src"] as? String,
          let dest = args["dest"] as? String
        else {
          result(nil)
          return
        }
        let maxShortSide = args["maxShortSide"] as? Int ?? 1080
        let job = args["job"] as? Int ?? 0
        // HDR 直通代理：HLG 10-bit、不映射、密關鍵幀。
        // 失敗就回 nil（呼叫端照播原檔），不走兩段式退路——
        // 退路轉出來是 SDR，對 HDR 預覽是錯的畫面
        if args["hdr"] as? Bool ?? false {
          self.transcodeWorkFile(
            src: src, dest: dest, maxShortSide: maxShortSide,
            channel: channel, label: "HDR 代理一趟轉好", job: job,
            hdrPass: true
          ) { err in result(err == nil ? dest : nil) }
          return
        }
        // 已經符合規格的素材直接用原檔，一格都不用重編。
        // 自己匯出過的影片、下載回來的 1080p H.264 都會命中。
        // 判定搬到背景：它會同步載軌道、命中前還要掃整支檔的
        // 關鍵幀——在主執行緒跑，多支排隊時 UI 凍住，卡超過
        // 系統容忍就是整個 App 被 watchdog 處決
        DispatchQueue.global(qos: .userInitiated).async {
          if let why = self.alreadyGoodEnough(src, maxShortSide: maxShortSide) {
            DispatchQueue.main.async {
              channel.invokeMethod("note", arguments: "素材本來就合用（\(why)）")
              result(src)
            }
            return
          }
          DispatchQueue.main.async {
            self.makeWorkFile(
              src: src, dest: dest, maxShortSide: maxShortSide,
              channel: channel, job: job
            ) { path in result(path) }
          }
        }
      case "probe":
        guard let path = call.arguments as? String else {
          result(nil)
          return
        }
        // 讀完整條軌，別擋主執行緒
        DispatchQueue.global(qos: .userInitiated).async {
          let m = self.probeFile(path)
          DispatchQueue.main.async { result(m) }
        }
      case "probeLite":
        // 輕量版：只讀容器層的中繼資料（尺寸/編碼/旋轉/色彩），
        // 不掃關鍵幀——完整 probe 要把整支檔的取樣讀過一遍，
        // 幾 GB 的素材光探測就要好幾秒。給「要不要蓋讀取遮罩」
        // 這種只看規格的判斷用
        guard let path = call.arguments as? String else {
          result(nil)
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let m = self.probeFile(path, keyframes: false)
          DispatchQueue.main.async { result(m) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 這支素材本來就合用嗎？合用就直接拿原檔當工作檔，一格都不用重編。
  ///
  /// 條件跟工作檔的輸出規格一致：短邊沒超過上限、H.264、SDR(709)、
  /// 關鍵幀夠密、而且沒有旋轉旗標。回 nil 代表要轉，回字串是「為什麼
  /// 可以省下來」（寫進診斷用）
  private func alreadyGoodEnough(_ path: String, maxShortSide: Int) -> String? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let t = asset.tracks(withMediaType: .video).first else { return nil }
    guard t.preferredTransform.isIdentity else { return nil }
    let n = t.naturalSize.applying(t.preferredTransform)
    let short = min(abs(n.width), abs(n.height))
    guard short > 1, Int(short) <= maxShortSide else { return nil }
    guard let fdAny = t.formatDescriptions.first else { return nil }
    let fd = fdAny as! CMFormatDescription
    guard CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_H264
    else { return nil }
    // HDR 一定要轉：色調映射交給系統做，不然預覽跟匯出的顏色會不一樣
    let trc = CMFormatDescriptionGetExtension(
      fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
    if let trc = trc,
      !CFEqual(trc, kCMFormatDescriptionTransferFunction_ITU_R_709_2)
    {
      return nil
    }
    // 關鍵幀太疏的話拖曳會鈍，那正是工作檔要解決的事
    let m = probeFile(path)
    guard let frames = m["frames"] as? Int, let keys = m["keyframes"] as? Int,
      let maxGop = m["maxGopFrames"] as? Int,
      keys > 0, Double(frames) / Double(keys) <= 8, maxGop <= 12
    else { return nil }
    return "\(Int(short))p H.264 SDR、關鍵幀每 \(frames / keys) 格"
  }

  private func makeWorkFile(
    src: String, dest: String, maxShortSide: Int,
    channel: FlutterMethodChannel, job: Int,
    done: @escaping (String?) -> Void
  ) {
    // 一趟做完：解碼 → 轉正、縮到 1080、映射回 709 → 密關鍵幀編碼。
    // 兩段式（ExportSession 再重編一次）是舊路徑，留著當保底：慢動作、
    // 時間重映射過的軌有可能讓合成器讀不動，那種素材更需要工作檔
    transcodeWorkFile(
      src: src, dest: dest, maxShortSide: maxShortSide, channel: channel,
      label: "工作檔一趟轉好", job: job
    ) { [weak self] err in
      if err == nil {
        done(dest)
        return
      }
      channel.invokeMethod(
        "note", arguments: "一趟轉檔沒成功（\(err!)），改用兩段式")
      self?.exportOnce(
        src: src, dest: dest, maxShortSide: maxShortSide,
        useComposition: true, channel: channel, job: job
      ) { e1 in
        if e1 == nil {
          self?.denseKeyframes(dest, channel: channel) { _ in done(dest) }
          return
        }
        channel.invokeMethod(
          "note", arguments: "工作檔第一次失敗（\(e1!)），改用系統預設尺寸重試")
        self?.exportOnce(
          src: src, dest: dest, maxShortSide: maxShortSide,
          useComposition: false, channel: channel, job: job
        ) { e2 in
          if e2 == nil {
            self?.denseKeyframes(dest, channel: channel) { _ in done(dest) }
          } else {
            channel.invokeMethod("note", arguments: "工作檔還是失敗：\(e2!)")
            done(nil)
          }
        }
      }
    }
  }

  /// 一趟把素材做成工作檔：解碼 → 轉正、縮到短邊上限、映射回 709 →
  /// 密關鍵幀 H.264 編碼。
  ///
  /// 本來是兩趟：AVAssetExportSession 先轉成 1080p SDR，再用
  /// reader/writer 重編一次排密關鍵幀。兩趟各自做了一次完整的解碼與
  /// 編碼，而它們做的其實是同一件事的不同部分——合成一趟就好，時間
  /// 大約省一半。
  ///
  /// 顏色不會因此改變：舊的第一趟本來就是掛 videoComposition 交給
  /// 系統的合成器算，這裡是同一個合成器、同一組色彩屬性，只是換成
  /// 由 writer 收影格。
  ///
  /// [maxShortSide] 給 0 代表不縮，維持原尺寸（只重排關鍵幀時用）
  private func transcodeWorkFile(
    src: String, dest: String, maxShortSide: Int,
    channel: FlutterMethodChannel, label: String, job: Int = 0,
    hdrPass: Bool = false,
    done: @escaping (String?) -> Void
  ) {
    try? FileManager.default.removeItem(atPath: dest)
    if hdrPass {
      DispatchQueue.main.async {
        channel.invokeMethod(
          "note", arguments: "HDR 代理：零處理（解碼→縮放→重編碼，不動色彩）")
      }
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: src))
    guard let vTrack = asset.tracks(withMediaType: .video).first,
      let reader = try? AVAssetReader(asset: asset),
      let writer = try? AVAssetWriter(
        outputURL: URL(fileURLWithPath: dest), fileType: .mp4)
    else {
      done("開不了這個檔")
      return
    }
    let dur = asset.duration.seconds
    let fps = vTrack.nominalFrameRate > 1 ? vTrack.nominalFrameRate : 30
    // HDR 來源：掛跟匯出/合成播放器同一顆 CI 合成器做色調映射。
    // 內建合成器的 HDR→SDR 是另一條曲線——「預覽（播工作檔）跟
    // 成品（CI toneMap）顏色不一樣」的根因就是工作檔在這裡分家。
    // HDR 直通模式（hdrPass）＝零處理：純解碼→縮放→重編碼，
    // 不掛任何合成器（內建的、CI 的都不掛）、色彩標記照抄來源、
    // 方向保留旗標。像素不經過任何色彩管線，物理上不可能變色
    let isHDR = hdrPass ? false : CompPlayer.isHDRSource(src)
    let pixels: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(
        hdrPass
          ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
          : (isHDR
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
    ]

    // 輸出尺寸縮的是短邊：直式拿到 1080x1920、橫式拿到 1920x1080，
    // 兩種方向的清晰度與解碼成本都一樣。系統預設的「塞進 1920x1080」
    // 會把直式 4K 縮成 607x1080，長邊只剩六成，預覽就糊了
    // 零處理（hdrPass）不轉正：畫框尺寸用未旋轉的原始尺寸，
    // 方向靠旗標帶著走（跟原檔一樣）
    let disp = hdrPass
      ? vTrack.naturalSize
      : vTrack.naturalSize.applying(vTrack.preferredTransform)
    let dw = abs(disp.width)
    let dh = abs(disp.height)
    guard dw > 1, dh > 1 else {
      done("讀不到畫面尺寸")
      return
    }
    let shrink =
      maxShortSide > 0 ? min(1, CGFloat(maxShortSide) / min(dw, dh)) : 1
    var outW = (dw * shrink).rounded()
    var outH = (dh * shrink).rounded()
    outW -= outW.truncatingRemainder(dividingBy: 2)  // H.264 要偶數
    outH -= outH.truncatingRemainder(dividingBy: 2)
    let size = CGSize(width: max(2, outW), height: max(2, outH))

    // 一律走合成器：方向燒進畫面（不留旋轉旗標，不然合成播放器會為了
    // 方向不一致而掛上逐格重畫）、尺寸精確、而且明確標成 709——不標的
    // 話 HDR 的色彩標記會原封帶進 H.264 檔，播放器再套一次曲線，顏色
    // 就整個歪掉
    let vc = AVMutableVideoComposition()
    vc.renderSize = size
    vc.frameDuration = CMTime(
      value: 1, timescale: CMTimeScale(max(1, min(60, fps.rounded()))))
    if hdrPass {
      // HLG 直通：跟 HDR 匯出同一組標記
      vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
      vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
      vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
    } else {
      vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
      vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
      vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    }
    if isHDR {
      // 跟合成播放器的 fitTransform 同一套數學：轉正 → 等比縮放 →
      // 置中（滿版貼齊，這裡沒有使用者縮放位移）。座標翻轉由
      // CIExportCompositor 用 srcHeight 自己處理
      let fit = vTrack.preferredTransform
        .concatenating(CGAffineTransform(scaleX: shrink, y: shrink))
        .concatenating(
          CGAffineTransform(
            translationX: (size.width - dw * shrink) / 2,
            y: (size.height - dh * shrink) / 2))
      // 直通用 HDR 版（不映射、HLG 輸出）；SDR 工作檔用一般版
      //（toneMap，跟成品同一條曲線）——都是匯出驗證過的那兩顆
      vc.customVideoCompositorClass =
        hdrPass ? CIExportCompositorHDR.self : CIExportCompositor.self
      vc.instructions = [
        CIExportInstruction(
          timeRange: CMTimeRange(start: .zero, duration: asset.duration),
          layers: [
            CILayerSpec(
              trackID: vTrack.trackID, still: nil,
              transform: fit, srcHeight: vTrack.naturalSize.height,
              start: 0, end: dur,
              fadeIn: 0, fadeOut: 0, colorMatrix: nil,
              crop: nil, rotation: 0, opacity: 1, z: 0)
          ],
          mosaics: [], overlays: [],
          prerollTrackIDs: [NSNumber(value: vTrack.trackID)],
          holdIfEmpty: true)
      ]
      DispatchQueue.main.async {
        channel.invokeMethod(
          "note",
          arguments: "工作檔（HDR）：CI 色調映射，跟成品同一條曲線")
      }
    } else {
      let ins = AVMutableVideoCompositionInstruction()
      ins.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
      let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
      li.setTransform(
        vTrack.preferredTransform.concatenating(
          CGAffineTransform(scaleX: shrink, y: shrink)),
        at: .zero)
      ins.layerInstructions = [li]
      vc.instructions = [ins]
    }
    let vOut: AVAssetReaderOutput
    if hdrPass {
      // 零處理：純解碼，不經過任何合成器
      let o = AVAssetReaderTrackOutput(track: vTrack, outputSettings: pixels)
      o.alwaysCopiesSampleData = false
      vOut = o
    } else {
      let o = AVAssetReaderVideoCompositionOutput(
        videoTracks: [vTrack], videoSettings: pixels)
      o.videoComposition = vc
      o.alwaysCopiesSampleData = false
      vOut = o
    }
    guard reader.canAdd(vOut) else {
      done("讀取端建不起來")
      return
    }
    reader.add(vOut)

    var vCompression: [String: Any] = [
      // 每 5 格一個關鍵幀、不用 B 幀：拖曳的每一次 seek 最多只要
      // 解 5 格。系統轉出來的檔關鍵幀間隔一兩秒，那是滑動跟不上
      // 手指的根本原因
      AVVideoMaxKeyFrameIntervalKey: 5,
      AVVideoAllowFrameReorderingKey: false,
      AVVideoAverageBitRateKey: Int(
        size.width * size.height * CGFloat(min(fps, 60)) * 0.2),
      AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
    ]
    if hdrPass {
      vCompression[AVVideoProfileLevelKey] =
        kVTProfileLevel_HEVC_Main10_AutoLevel as String
    }
    // 零處理的色彩標記照抄來源（讀不到才退回 HLG 常見組合）——
    // 像素沒動，標記也原封，播放端的解讀跟原檔一字不差
    var hdrColor: [String: Any] = [
      AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
      AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
      AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ]
    if hdrPass, let fdAny = vTrack.formatDescriptions.first {
      let fd = fdAny as! CMFormatDescription
      if let v = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
        as? String
      {
        hdrColor[AVVideoColorPrimariesKey] = v
      }
      if let v = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        as? String
      {
        hdrColor[AVVideoTransferFunctionKey] = v
      }
      if let v = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
        as? String
      {
        hdrColor[AVVideoYCbCrMatrixKey] = v
      }
    }
    var vSettings: [String: Any] = [
      AVVideoCodecKey: hdrPass ? AVVideoCodecType.hevc : .h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: vCompression,
      // 明確標色彩：不標的話編碼器會自己猜
      AVVideoColorPropertiesKey: hdrPass
        ? hdrColor
        : [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ] as [String: Any],
    ]
    if hdrPass {
      // 4K 進 1080 出：縮放交給編碼器（YUV 域等比縮，無色彩轉換）
      vSettings[AVVideoScalingModeKey] = AVVideoScalingModeResize
    }
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
    if hdrPass {
      // 方向照原檔留旗標（零處理不轉正）
      vIn.transform = vTrack.preferredTransform
    }
    vIn.expectsMediaDataInRealTime = false
    guard writer.canAdd(vIn) else {
      done("寫入端建不起來")
      return
    }
    writer.add(vIn)

    // 聲音照抄成 AAC（取樣率與聲道數跟著來源，寫死會編不動單聲道）
    var aOut: AVAssetReaderTrackOutput?
    var aIn: AVAssetWriterInput?
    if let aTrack = asset.tracks(withMediaType: .audio).first {
      var ch = 2
      var sr = 44100.0
      if let fdAny = aTrack.formatDescriptions.first {
        let fd = fdAny as! CMFormatDescription
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
          ch = max(1, Int(asbd.pointee.mChannelsPerFrame))
          if asbd.pointee.mSampleRate > 0 { sr = asbd.pointee.mSampleRate }
        }
      }
      let out = AVAssetReaderTrackOutput(
        track: aTrack,
        outputSettings: [AVFormatIDKey: Int(kAudioFormatLinearPCM)])
      let input = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
          AVNumberOfChannelsKey: ch,
          AVSampleRateKey: sr,
          AVEncoderBitRateKey: 128_000,
        ])
      input.expectsMediaDataInRealTime = false
      // 兩邊都要收得下才動手：只把 reader output 加進去而 writer input
      // 沒加的話，那條軌永遠不會被讀完，reader 就到不了 completed，
      // 整份轉檔會被判成失敗
      if reader.canAdd(out), writer.canAdd(input) {
        reader.add(out)
        writer.add(input)
        aOut = out
        aIn = input
      }
    }

    guard reader.startReading(), writer.startWriting() else {
      done("開不了工")
      return
    }
    writer.startSession(atSourceTime: .zero)

    let group = DispatchGroup()
    // 一條軌一條佇列：兩個 input 共用一條序列佇列的話，影像那個 block
    // 在 while 裡跑的時候聲音那個永遠排不進去，兩邊互相餓死
    let vq = DispatchQueue(label: "markcut.work.v")
    let aq = DispatchQueue(label: "markcut.work.a")
    // append 失敗要記下來：不記的話 writer 仍可能收在 completed，
    // 於是一份「只有前半段」的檔會被當成功交出去，素材默默變短
    let failed = AtomicFlag()
    let t0 = CACurrentMediaTime()
    var lastReport: CFTimeInterval = 0

    group.enter()
    vIn.requestMediaDataWhenReady(on: vq) {
      while vIn.isReadyForMoreMediaData {
        if let sb = vOut.copyNextSampleBuffer() {
          if !vIn.append(sb) {
            failed.set()
            vIn.markAsFinished()
            group.leave()
            return
          }
          // 進度：讀到第幾秒。reader/writer 沒有內建進度，但影格自己
          // 帶著時間戳，除以總長就是進度
          let now = CACurrentMediaTime()
          if dur > 0.05, now - lastReport > 0.2 {
            lastReport = now
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if t.isFinite {
              DispatchQueue.main.async {
                channel.invokeMethod(
                  "progress",
                  arguments: ["job": job, "value": min(1, max(0, t / dur))])
              }
            }
          }
        } else {
          vIn.markAsFinished()
          group.leave()
          return
        }
      }
    }
    if let aOut = aOut, let aIn = aIn {
      group.enter()
      aIn.requestMediaDataWhenReady(on: aq) {
        while aIn.isReadyForMoreMediaData {
          if let sb = aOut.copyNextSampleBuffer() {
            if !aIn.append(sb) {
              failed.set()
              aIn.markAsFinished()
              group.leave()
              return
            }
          } else {
            aIn.markAsFinished()
            group.leave()
            return
          }
        }
      }
    }

    // 只回一次（逾時與正常完成可能撞在一起）
    let replied = AtomicFlag()
    let finish: (String?) -> Void = { err in
      guard replied.setIfClear() else { return }
      DispatchQueue.main.async {
        if err != nil { try? FileManager.default.removeItem(atPath: dest) }
        done(err)
      }
    }
    // 逾時保險：硬體編碼器被別的工作佔住時 requestMediaDataWhenReady
    // 可能一直不回來，沒有這道就卡在「工作檔轉不完」，畫面永遠是原檔。
    // 額度隨片長：寫死 120 秒的話長片一趟正常轉檔就會超過、被誤判
    // 逾時砍掉，最後整段編輯拿 4K HDR 原檔播——正是要避免的卡頓。
    // 給「片長的 3 倍」（硬體轉檔實測遠快於實時），下限 120 秒
    let timeoutSec = max(120.0, asset.duration.seconds * 3.0)
    DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSec) {
      guard !replied.isSet else { return }
      reader.cancelReading()
      writer.cancelWriting()
      finish("逾時")
    }

    group.notify(queue: vq) {
      if failed.isSet {
        reader.cancelReading()
        writer.cancelWriting()
        finish("中途失敗")
        return
      }
      writer.finishWriting {
        let ok =
          writer.status == .completed && reader.status == .completed
          && !failed.isSet
        guard ok else {
          if let e = writer.error as NSError? {
            finish("\(e.localizedDescription)[\(e.domain) \(e.code)]")
          } else if let e = reader.error as NSError? {
            finish("讀取端 \(e.localizedDescription)[\(e.code)]")
          } else {
            finish("writer=\(writer.status.rawValue) reader=\(reader.status.rawValue)")
          }
          return
        }
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        channel.invokeMethod("note", arguments: "\(label) \(ms)ms")
        finish(nil)
      }
    }
  }

  /// 已經是工作檔了，只重排關鍵幀（原地換掉）。兩段式那條路才會用到
  private func denseKeyframes(
    _ path: String, channel: FlutterMethodChannel,
    done: @escaping (Bool) -> Void
  ) {
    let tmp = path + ".dense.mp4"
    transcodeWorkFile(
      src: path, dest: tmp, maxShortSide: 0, channel: channel,
      label: "密關鍵幀重編完成", job: -1
    ) { err in
      guard err == nil else {
        channel.invokeMethod(
          "note", arguments: "密關鍵幀重編沒成功（\(err!)，滑動會比較鈍）")
        done(false)
        return
      }
      do {
        _ = try FileManager.default.replaceItemAt(
          URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        done(true)
      } catch {
        try? FileManager.default.removeItem(atPath: tmp)
        channel.invokeMethod("note", arguments: "密關鍵幀重編換檔失敗")
        done(false)
      }
    }
  }

  /// 檢查一份影片檔的實際規格——尺寸、編碼、位元率，以及**關鍵幀間隔**。
  ///
  /// 關鍵幀間隔是「左右滑動順不順」的決定性數字：seek 一定要從前一個
  /// 關鍵幀解過來，間隔 60 格就是每滑一下解 60 格。這裡用 passthrough
  /// 讀（不解碼）數每一格的 sync 旗標，一支十秒的檔幾十毫秒就數完
  private func probeFile(_ path: String, keyframes: Bool = true) -> [String: Any] {
    var m: [String: Any] = ["path": (path as NSString).lastPathComponent]
    if let attr = try? FileManager.default.attributesOfItem(atPath: path),
      let bytes = attr[.size] as? NSNumber
    {
      m["sizeMb"] = bytes.doubleValue / 1_048_576
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let t = asset.tracks(withMediaType: .video).first else {
      m["error"] = "沒有視訊軌"
      return m
    }
    let n = t.naturalSize.applying(t.preferredTransform)
    m["w"] = Int(abs(n.width))
    m["h"] = Int(abs(n.height))
    m["fps"] = Double(t.nominalFrameRate)
    m["kbps"] = Int(t.estimatedDataRate / 1000)
    m["durSec"] = asset.duration.seconds
    if let fdAny = t.formatDescriptions.first {
      let fd = fdAny as! CMFormatDescription
      let c = CMFormatDescriptionGetMediaSubType(fd)
      m["codec"] = String(
        format: "%c%c%c%c", (c >> 24) & 255, (c >> 16) & 255, (c >> 8) & 255,
        c & 255)
      // SDR(709) 判定跟 alreadyGoodEnough 同一套：沒有標記當 SDR，
      // 有標記但不是 709 才算 HDR
      let trc = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
      if let trc = trc {
        m["sdr709"] = CFEqual(trc, kCMFormatDescriptionTransferFunction_ITU_R_709_2)
      } else {
        m["sdr709"] = true
      }
    }
    // 有沒有旋轉旗標：有的話合成播放器要靠 layer instruction 轉正，
    // 沒有的話是已經燒進畫面的（工作檔第一次轉成功就會是這種）
    m["rotated"] = !t.preferredTransform.isIdentity
    if !keyframes { return m }
    if let reader = try? AVAssetReader(asset: asset) {
      let out = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
      out.alwaysCopiesSampleData = false
      if reader.canAdd(out) {
        reader.add(out)
        if reader.startReading() {
          var frames = 0
          var keys = 0
          var gap = 0
          var maxGap = 0
          while let sb = out.copyNextSampleBuffer() {
            frames += 1
            var sync = true
            if let arr = CMSampleBufferGetSampleAttachmentsArray(
              sb, createIfNecessary: false) as? [[CFString: Any]],
              let first = arr.first,
              let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool
            {
              sync = !notSync
            }
            if sync {
              keys += 1
              maxGap = max(maxGap, gap)
              gap = 1
            } else {
              gap += 1
            }
          }
          maxGap = max(maxGap, gap)
          reader.cancelReading()
          m["frames"] = frames
          m["keyframes"] = keys
          m["maxGopFrames"] = maxGap
        }
      }
    }
    return m
  }

  /// 轉一次。成功回 nil，失敗回原因字串
  private func exportOnce(
    src: String, dest: String, maxShortSide: Int, useComposition: Bool,
    channel: FlutterMethodChannel, job: Int,
    done: @escaping (String?) -> Void
  ) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: src))
    guard let track = asset.tracks(withMediaType: .video).first else {
      done("沒有視訊軌")  // 純音訊不需要工作檔
      return
    }
    // 1920x1080 這個預設輸出的是 H.264 SDR——素材是 HLG/PQ 時系統會
    // 自己映射回 SDR。實際尺寸由下面的 videoComposition 決定
    guard
      let session = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPreset1920x1080)
    else {
      done("這台機器建不出 1920x1080 的轉檔工作")
      return
    }
    // 同一個目的檔案殘留會讓 export 直接失敗
    try? FileManager.default.removeItem(atPath: dest)
    session.outputURL = URL(fileURLWithPath: dest)
    session.outputFileType = .mp4

    // 輸出尺寸自己算，不靠預設：預設是「塞進 1920x1080 的框」，
    // 直式 4K 會被縮成 607x1080（長邊只剩六成），預覽就糊了。
    // 這裡縮的是短邊——直式拿到 1080x1920、橫式拿到 1920x1080，
    // 兩種方向的清晰度與解碼成本都一樣
    let natural = track.naturalSize.applying(track.preferredTransform)
    let dispW = abs(natural.width)
    let dispH = abs(natural.height)
    if useComposition, dispW > 1, dispH > 1 {
      let scale = min(1.0, CGFloat(maxShortSide) / min(dispW, dispH))
      var outW = (dispW * scale).rounded()
      var outH = (dispH * scale).rounded()
      outW -= outW.truncatingRemainder(dividingBy: 2)  // H.264 要偶數
      outH -= outH.truncatingRemainder(dividingBy: 2)
      let comp = AVMutableVideoComposition()
      comp.renderSize = CGSize(width: max(2, outW), height: max(2, outH))
      let fps = track.nominalFrameRate > 1 ? track.nominalFrameRate : 30
      comp.frameDuration = CMTime(
        value: 1, timescale: CMTimeScale(min(60, fps.rounded())))
      // 明確標成 709：不指定的話有些素材會把 HDR 的色彩標記原封帶進
      // H.264 檔，播放器再自己套一次曲線，顏色就整個歪掉
      comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
      comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
      comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
      // HDR：跟一趟轉檔同一顆 CI 合成器（同一條 toneMap 曲線）。
      // 這條是一趟轉失敗的退路，退路走系統舊曲線的話，
      // 「預覽比較淡」又會從這個縫鑽回來
      if CompPlayer.isHDRSource(src) {
        let fit = track.preferredTransform
          .concatenating(CGAffineTransform(scaleX: scale, y: scale))
          .concatenating(
            CGAffineTransform(
              translationX: (comp.renderSize.width - dispW * scale) / 2,
              y: (comp.renderSize.height - dispH * scale) / 2))
        comp.customVideoCompositorClass = CIExportCompositor.self
        comp.instructions = [
          CIExportInstruction(
            timeRange: CMTimeRange(start: .zero, duration: asset.duration),
            layers: [
              CILayerSpec(
                trackID: track.trackID, still: nil,
                transform: fit, srcHeight: track.naturalSize.height,
                start: 0, end: asset.duration.seconds,
                fadeIn: 0, fadeOut: 0, colorMatrix: nil,
                crop: nil, rotation: 0, opacity: 1, z: 0)
            ],
            mosaics: [], overlays: [],
            prerollTrackIDs: [NSNumber(value: track.trackID)],
            holdIfEmpty: true)
        ]
      } else {
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
          start: .zero, duration: asset.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(
          assetTrack: track)
        // 先轉正（直式影片是「橫著存＋旋轉旗標」）再縮
        layer.setTransform(
          track.preferredTransform.concatenating(
            CGAffineTransform(scaleX: scale, y: scale)),
          at: .zero)
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]
      }
      session.videoComposition = comp
    }

    prepSessions[job] = session
    // 進度用輪詢的：AVAssetExportSession 沒有回呼式的進度。
    // 計時器是這一趟自己的，不是共用的——同時轉兩支時共用那個會互相蓋掉
    let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) {
      [weak session] _ in
      guard let session = session else { return }
      channel.invokeMethod(
        "progress", arguments: ["job": job, "value": Double(session.progress)])
    }

    session.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        timer.invalidate()
        self?.prepSessions.removeValue(forKey: job)
        if session.status == .completed,
          FileManager.default.fileExists(atPath: dest)
        {
          channel.invokeMethod("progress", arguments: ["job": job, "value": 1.0])
          done(nil)
        } else {
          try? FileManager.default.removeItem(atPath: dest)
          // 把系統給的原因帶回去：沒有它就只知道「失敗」，
          // 而失敗的素材會一路用 4K HDR 原檔播，那正是卡頓的來源
          // 「未知原因」查不動。把系統給的東西全帶回來：error 的
          // domain/code、底層 error，還有 status 本身
          var reason: String
          if let e = session.error as NSError? {
            reason = "\(e.localizedDescription)[\(e.domain) \(e.code)]"
            if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError {
              reason += "←\(u.domain) \(u.code)"
            }
          } else {
            reason = "status=\(session.status.rawValue)"
          }
          done(reason)
        }
      }
    }
  }
}

/// 用 AVPlayerLayer 直接顯示的原生視圖。
///
/// 材質那條路（影格 → CVPixelBuffer → 複製進 Flutter 材質 → Flutter 合成）
/// 就算一格都沒掉，節奏也可能不均：16ms、50ms、16ms、50ms——每一格都
/// 準時畫，但畫的是同一張。所有 Flutter 端的指標都看不到它，眼睛卻很
/// 敏感，這正是「成品在相簿裡很順、App 裡就是卡」的最後一個結構差異。
///
/// AVPlayerLayer 是系統自己的影片圖層，跟相簿播放走同一條路：零複製、
/// 影格節奏由系統排程
final class PlayerHostView: UIView {
  // 疊兩層：換播放器時新的先掛背面，第一格解出來（isReadyForDisplay）
  // 才翻到前面——舊畫面全程在前面撐著，換手過程沒有黑幕
  private let layerA = AVPlayerLayer()
  private let layerB = AVPlayerLayer()
  private(set) lazy var front: AVPlayerLayer = layerA
  var back: AVPlayerLayer { front === layerA ? layerB : layerA }

  override init(frame: CGRect) {
    super.init(frame: frame)
    for l in [layerB, layerA] {
      l.videoGravity = .resizeAspect
      layer.addSublayer(l)
    }
    layerA.zPosition = 1
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) 不支援") }

  override func layoutSubviews() {
    super.layoutSubviews()
    // 圖層 frame 有隱式動畫，轉向/縮放時會拖影——關掉
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layerA.frame = bounds
    layerB.frame = bounds
    CATransaction.commit()
  }

  /// 背面翻到前面；翻完舊的那層退到背面並卸下播放器
  func flip() {
    let old = front
    let new = back
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    new.zPosition = 1
    old.zPosition = 0
    CATransaction.commit()
    front = new
    old.player = nil
  }
}

/// 目前該顯示哪一顆播放器，以及畫面上還活著的影片圖層。
///
/// 平台視圖是「建立時抓一次播放器」就再也不換的。合成會重組（工作檔
/// 轉好了要換成工作檔版、時間軸改了要重烘），一重組舊播放器就被收掉，
/// 而畫面上那層還指著它——結果就是預覽整片黑。這裡把「現在是哪一顆」
/// 集中管理，換的時候一起換過去
final class PlayerHosts: NSObject {
  static let shared = PlayerHosts()
  private let views = NSHashTable<PlayerHostView>.weakObjects()
  private(set) var current: AVPlayer?

  /// 進行中的換手：世代編號＋觀察者。新一輪換手直接作廢上一輪
  ///（連按兩下重烘時，只有最後一顆播放器算數）
  private var gen = 0
  private var pendingObs: [NSKeyValueObservation] = []

  /// 還沒執行的收尾（舊播放器 dispose）。上一輪換手被新一輪作廢
  /// 時不能直接丟：那輪的舊播放器可能還掛在前面圖層顯示中，
  /// 立刻收會黑；不收則 CADisplayLink 抓著它永不釋放，快速重烘
  /// 一次就漏一顆。做法＝接力：作廢輪的收尾轉交給新一輪，
  /// 等新畫面真的上檔一起執行
  private var pendingVisible: (() -> Void)?

  func register(_ v: PlayerHostView) {
    views.add(v)
    v.front.player = current
  }

  /// 換成新的播放器——但畫面不立刻換：新播放器先掛每個視圖的
  /// 背面圖層，等它第一格真的解出來（isReadyForDisplay）才翻面。
  /// 舊畫面全程在前面撐著，重烘換手不再閃黑。
  /// [whenVisible] 新畫面上檔（或保底逾時）後呼叫——舊播放器
  /// 留到這一刻才收，收早了圖層還指著它就黑了
  func use(_ p: AVPlayer?, whenVisible: (() -> Void)? = nil) {
    gen += 1
    let g = gen
    pendingObs.removeAll()
    current = p
    // 上一輪沒跑完的收尾接力進來，跟這一輪的一起等新畫面上檔
    let carried = pendingVisible
    let done: () -> Void = {
      carried?()
      whenVisible?()
    }
    pendingVisible = done
    let finishNow: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.pendingVisible = nil
      done()
    }
    guard let p = p else {
      for v in views.allObjects {
        v.front.player = nil
        v.back.player = nil
      }
      finishNow()
      return
    }
    let vs = views.allObjects
    if vs.isEmpty {
      finishNow()
      return
    }
    var remaining = vs.count
    var finished = false
    let oneDone: () -> Void = { [weak self] in
      remaining -= 1
      guard remaining == 0, !finished, let self = self, self.gen == g
      else { return }
      finished = true
      self.pendingObs.removeAll()
      finishNow()
    }
    for v in vs {
      let incoming = v.back
      incoming.player = p
      if incoming.isReadyForDisplay {
        v.flip()
        oneDone()
        continue
      }
      let obs = incoming.observe(\.isReadyForDisplay, options: [.new]) {
        [weak self] layer, _ in
        guard layer.isReadyForDisplay else { return }
        DispatchQueue.main.async {
          guard let self = self, self.gen == g else { return }
          // 已經翻過面的視圖再收到 KVO（true→false→true 抖動）
          // 直接忽略——不擋的話 remaining 會被多扣，多視圖時
          // 另一個視圖的觀察者被提早作廢、永遠翻不了面
          guard v.front.player !== p else { return }
          v.flip()
          oneDone()
        }
      }
      pendingObs.append(obs)
    }
    // 保底：素材壞掉 readyForDisplay 永遠不來——1.5 秒硬翻，
    // 寧可閃一下也不能卡在舊畫面（聲音已經是新的了）
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self, self.gen == g, !finished else { return }
      finished = true
      self.pendingObs.removeAll()
      for v in vs where v.front.player !== p {
        if v.back.player !== p { v.back.player = p }
        v.flip()
      }
      finishNow()
    }
  }
}

final class PlayerPlatformView: NSObject, FlutterPlatformView {
  private let host: PlayerHostView

  /// 原生圖層被「建立」的次數與時間：播放中數字增加＝Flutter 把圖層
  /// 拆掉重掛（重掛那一瞬間就是黑閃）。接縫卡頓的最終 tripwire——
  /// 修好之後整段編輯過程應該只建立一次
  static let statLock = NSLock()
  static var createCount = 0
  static var createNotes: [String] = []

  init(frame: CGRect) {
    host = PlayerHostView(frame: frame)
    host.backgroundColor = .black
    super.init()
    PlayerHosts.shared.register(host)
    Self.statLock.lock()
    Self.createCount += 1
    if Self.createNotes.count > 9 { Self.createNotes.removeFirst() }
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    Self.createNotes.append(f.string(from: Date()))
    Self.statLock.unlock()
  }

  func view() -> UIView { host }
}

final class PlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    PlayerPlatformView(frame: frame)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

// ===== 合成播放器 =====
//
// 這個類別本來是獨立的 CompPlayer.swift，但 Xcode 專案是「逐檔列在
// project.pbxproj 裡」的——新檔案丟進資料夾不會被編譯，要嘛用 Xcode 加、
// 要嘛手改專案檔（改壞了連專案都開不起來）。放在這裡最不會出事；
// 之後有人用 Xcode 開專案時，隨時可以把它拉出去變成獨立檔案

/// 合成播放器：把整條時間軸組成「一份 AVComposition」，交給一顆 AVPlayer 播。
///
/// 為什麼要有它：原本的做法是「一個片段一顆播放器」，由 App 自己的時鐘
/// 驅動，交界時預先開播下一顆再換手。實機量出來的結果是——Flutter 這條線
/// 完全乾淨（5190 格只超時 2 格）、散熱正常、對時成本 0.01ms，但影格就是
/// 會不定時落後。剩下唯一沒排除的變因就是「同時養三顆 AVPlayer」：
/// 每顆都佔一組解碼與影格輸出資源，系統會在它們之間排隊。
///
/// AVComposition 是 AVFoundation 為這件事準備的東西：一條時間軸、一顆
/// 播放器、一組解碼資源，片段交界由系統自己處理（不會黑閃也不用預熱）。
/// 這也是 iOS 上剪輯 App 的標準做法。
///
/// 影格用 AVPlayerItemVideoOutput 取出來交給 Flutter 材質，
/// 由 CADisplayLink 驅動——跟 video_player 內部同一套機制
final class CompPlayer: NSObject, FlutterTexture {
  /// 這個檔的視訊軌是不是 HDR（有色彩轉換標記且不是 709）。
  /// 判定跟 probeFile/alreadyGoodEnough 同一套；只讀容器中繼資料
  static func isHDRSource(_ path: String) -> Bool {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let t = asset.tracks(withMediaType: .video).first,
      let fdAny = t.formatDescriptions.first
    else { return false }
    let fd = fdAny as! CMFormatDescription
    guard
      let trc = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
    else { return false }
    return !CFEqual(trc, kCMFormatDescriptionTransferFunction_ITU_R_709_2)
  }

  /// 讓 AVPlayerLayer 的 PlatformView 拿得到（見 PlayerHostView）
  let player = AVPlayer()

  /// HDR 預覽的即時疊加物（浮水印/文字）：這一版合成有沒有掛
  /// 讀即時清單的合成器（CIPreviewCompositorHDR），以及它的畫布
  /// 尺寸——之後 setOverlays 換清單要用同一個座標系
  private(set) var wmLive = false
  private(set) var ciCanvas = CGSize.zero

  private var output: AVPlayerItemVideoOutput?
  private var link: CADisplayLink?
  private var latest: CVPixelBuffer?
  private let lock = NSLock()

  private weak var registry: FlutterTextureRegistry?
  private(set) var textureId: Int64 = 0

  /// 這次有沒有掛合成器。掛了＝每一格都進合成管線重畫一張，
  /// 沒掛＝硬體解碼直送螢幕（跟相簿播放同一條路）
  private(set) var usesVC = false

  /// 組不起來時的原因。沒有這個的話只知道「失敗」，而失敗的後果是
  /// 預覽退回舊路徑，查不出為什麼
  private(set) var buildError: String?

  /// 這份合成本身（診斷用：軌數、抽格）
  private var composition: AVMutableComposition?

  /// 抽「目前渲染輸出」用（見 grabFrame）。產生器不支援自訂合成器，
  /// video output 拿的是實際送畫面的那一格，CI 路線也抽得到
  private var videoOut: AVPlayerItemVideoOutput?

  /// 組建內視鏡：Swift 實際收到什麼、組出什麼（診斷用）。
  /// 「程式碼看起來對、裝置行為不對」的僵局只有它拆得開
  private(set) var buildInfo: [String: Any] = [:]

  /// 系統的「播放卡住」通知：次數與發生的時間點
  var stallCount = 0
  var stallNotes: [String] = []
  private var stallObs: NSObjectProtocol? = nil

  /// 這份合成的總長度（秒）與畫面尺寸
  private(set) var duration: Double = 0
  private(set) var size: CGSize = .zero

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
    player.actionAtItemEnd = .pause
    // 一顆播放器負責整條時間軸，不需要任何緩衝以外的等待
    player.automaticallyWaitsToMinimizeStalling = false
  }

  /// 用片段清單組出合成。clips 依時間順序，每一筆是
  /// path / start / end（素材內秒數）/ gap（跟前一段之間的空白秒數）/ volume
  /// [texture] 畫面要不要另外送一份到 Flutter 材質。
  /// 用系統影片圖層顯示時就不用——那條路是播放器自己畫到圖層上，
  /// 材質這份沒有人看，卻是每一格都在複製一張 4K 的畫面
  /// [mosaics] 跟原生匯出同一套欄位（px/py/scale/type/strength/
  /// color/feather/start/end）。非空時掛 CI 合成器把碼烘進畫面
  func build(
    clips: [[String: Any]], texture: Bool, mosaics: [[String: Any]] = [],
    stills: [[String: Any]] = [], hdrOut: Bool = false,
    overlays: [[String: Any]] = []
  ) -> Bool {
    let comp = AVMutableComposition()
    let scale: CMTimeScale = 600

    // 一條時間軸軌道 → 一條合成軌。
    //
    // 本來只開一條，所以「同一時刻有兩層畫面」（子母畫面）就整組退回
    // 舊的一片段一顆播放器——那正是使用者說的「多軌之後變超 LAG」。
    // AVFoundation 本來就支援多軌疊合，逐段的 layer instruction 決定
    // 每一刻誰在上面、怎麼擺
    struct Seg {
      var range: CMTimeRange
      var transform: CGAffineTransform
      var size: CGSize
      var fadeIn: Double
      var fadeOut: Double
      var userScale: Double
      var px: Double
      var py: Double
      var mirror: Bool
      var track: AVMutableCompositionTrack
      var layer: Int
      var crop: [Double]?
      var rotation: Double
      var opacity: Double
    }
    var segments: [Seg] = []
    var vTracks: [Int: (track: AVMutableCompositionTrack, end: CMTime)] = [:]
    // 每層最後插入的媒體（來源軌＋來源區間），片尾鋪滿（見 needsCI）用
    var lastMedia: [Int: (src: AVAssetTrack, rng: CMTimeRange)] = [:]
    stallCount = 0
    stallNotes = []

    // 聲音也可能同時好幾層（影片自己的聲音＋配樂），一條軌塞不下重疊的
    // 時間範圍——需要幾條就開幾條
    var aTracks: [(track: AVMutableCompositionTrack, end: CMTime)] = []
    var aParams: [AVMutableAudioMixInputParameters] = []

    // 依時間排好再放：同一條合成軌只能往後接，中間的空白要自己補
    let ordered = clips.sorted {
      (($0["offset"] as? Double) ?? 0) < (($1["offset"] as? Double) ?? 0)
    }
    buildInfo["收到"] = ordered.map { c -> String in
      let tk = c["track"] as? Int ?? -9
      let of = c["offset"] as? Double ?? -1
      return "軌\(tk)@\(String(format: "%.2f", of))"
    }.joined(separator: " ")
    buildInfo["馬賽克"] = mosaics.map { m -> String in
      let tk = m["track"] as? Int ?? -9
      let a = m["start"] as? Double ?? -1
      let b = m["end"] as? Double ?? -1
      return "z\(tk) \(String(format: "%.2f", a))~\(String(format: "%.2f", b))"
    }.joined(separator: " ")

    // 這些效果標準的 layer instruction 畫不出來，得掛 CI 合成器。
    // 這件事在插軌之前就得知道：CI 路線（自訂合成器）的軌道必須
    // 從頭到尾鋪滿媒體、一個空範圍都不能留——AVFoundation 的自訂
    // 合成器遇到「這一刻這條軌沒有媒體」會供格失敗：抽格器直接
    // 報錯（診斷的「抽格檢查失敗」）、播放進出空範圍的邊界打嗝
    //（接縫閃黑卡頓）。內建合成器沒這個問題，所以標準路線照舊留空
    // 秒進之後合成可能直接吃 4K HLG 原檔。不掛合成器的話系統照 HDR
    // 顯示（跟相簿一樣被 EDR 拉亮），旁邊 SDR 的浮水印/文字相對就
    // 變灰——工作檔（SDR）換上才恢復，看起來就是「文字先變色、
    // 讀取好才正常」（實測回報）。掛 CI 合成器強制 toneMapHDRtoSDR，
    // 預覽全程 SDR、跟成品同一條曲線；工作檔全好後重組，來源都是
    // SDR，這裡自然回到輕的路
    // HDR 判定以 Dart 端傳來的 'hdr' 旗標為準（probeLite 算的，
    // 實機驗證可靠）；自家同步讀軌道的 isHDRSource 當備援——
    // 實測它在進場當下有拿不到資料回 false 的情況，合成沒掛 CI、
    // HDR 原檔整段白白的
    let anyHDR = ordered.contains { c in
      if (c["hdr"] as? Bool) == true { return true }
      guard let p = c["path"] as? String else { return false }
      return CompPlayer.isHDRSource(p)
    }
    let needsCI =
      !mosaics.isEmpty
      // 墊在影片下層的圖片/GIF：烘進合成（標準 layer instruction
      // 畫不了外來影像，得走 CI 合成器）
      || !stills.isEmpty
      // HDR 輸出模式不做 toneMap：沒有別的效果時整個不掛合成器，
      // 系統照 HDR 顯示（EDR，跟相簿/成品同一條）
      || (anyHDR && !hdrOut)
      // HDR 預覽的疊加物（浮水印/文字）：要烘進合成用 EDR 顯示，
      // Flutter 畫的白色最多只有基準白，旁邊 HDR 高光一比就是灰的
      || (hdrOut && anyHDR && !overlays.isEmpty)
      || ordered.contains { c in
        (c["crop"] as? [Double]) != nil
          || abs(c["rotation"] as? Double ?? 0) > 0.05
          || (c["opacity"] as? Double ?? 1) < 0.999
      }
    // 寫進組建內視鏡：下次「進場顏色白白的」的回報，一眼就能看出
    // HDR 判定有沒有中、CI 有沒有掛（上一輪就是缺這格查了半天）
    buildInfo["HDR"] = anyHDR

    for clip in ordered {
      guard let path = clip["path"] as? String else { continue }
      let start = clip["start"] as? Double ?? 0
      let end = clip["end"] as? Double ?? 0
      let at = CMTime(
        seconds: max(0, clip["offset"] as? Double ?? 0), preferredTimescale: scale)
      let layer = clip["track"] as? Int ?? 0
      let volume = Float(clip["volume"] as? Double ?? 1)
      let speed = max(0.05, clip["speed"] as? Double ?? 1)
      let fadeIn = clip["fadeIn"] as? Double ?? 0
      let fadeOut = clip["fadeOut"] as? Double ?? 0
      let userScale = clip["scale"] as? Double ?? 1
      let px = clip["px"] as? Double ?? 0.5
      let py = clip["py"] as? Double ?? 0.5
      let mirror = clip["mirror"] as? Bool ?? false
      let cropArr = clip["crop"] as? [Double]
      let rotation = clip["rotation"] as? Double ?? 0
      let opacity = clip["opacity"] as? Double ?? 1
      if end - start <= 0.01 { continue }

      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      guard let src = asset.tracks(withMediaType: .video).first else { continue }
      let range = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: scale),
        duration: CMTime(seconds: end - start, preferredTimescale: scale))
      // 變速直接烘進合成的時間軸（scaleTimeRange），播放器照常播；
      // outDur 是這一段在時間軸上實際佔的長度
      let outDur =
        abs(speed - 1) > 0.001
        ? CMTime(seconds: (end - start) / speed, preferredTimescale: scale)
        : range.duration

      // 這一層的合成軌（沒有就開一條）
      if vTracks[layer] == nil {
        guard
          let t = comp.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
          buildError = "開不出第 \(layer) 層的合成軌"
          return false
        }
        vTracks[layer] = (t, .zero)
      }
      guard var slot = vTracks[layer] else {
        buildError = "第 \(layer) 層的合成軌不見了"
        return false
      }
      // 補到位：同一條軌上一段結束到這一段開始之間的縫。
      // CI 路線不能留空範圍（見 needsCI），改用「本片開頭的一小段」
      // 拉長鋪滿：指令不會列它、畫面看不見，但解碼器全程有東西吃，
      // 而且到本片進場那一刻剛好就停在它的開頭附近——零冷啟動
      if slot.end < at {
        var filled = false
        if needsCI {
          let gap = at - slot.end
          // 儘量拿「本片入點前 0.2 秒」當填充：解碼器一路順流進
          // 本片第一格，完全不跳針；素材開頭沒餘裕才退而用本片
          // 開頭一小段（會小倒帶 0.2 秒，關鍵幀密，代價很小）
          let leadIn = min(0.2, start)
          let snip =
            leadIn > 0.05
            ? CMTimeRange(
              start: CMTime(seconds: start - leadIn, preferredTimescale: scale),
              duration: CMTime(seconds: leadIn, preferredTimescale: scale))
            : CMTimeRange(
              start: range.start,
              duration: CMTime(
                seconds: min(0.2, end - start), preferredTimescale: scale))
          if (try? slot.track.insertTimeRange(snip, of: src, at: slot.end))
            != nil
          {
            slot.track.scaleTimeRange(
              CMTimeRange(start: slot.end, duration: snip.duration),
              toDuration: gap)
            filled = true
          }
        }
        if !filled {
          slot.track.insertEmptyTimeRange(
            CMTimeRange(start: slot.end, duration: at - slot.end))
        }
        slot.end = at
      }
      // 同一層若真的重疊（理論上不會，時間軸不允許），往後推一格避免蓋掉
      let putAt = max(at, slot.end)
      do {
        try slot.track.insertTimeRange(range, of: src, at: putAt)
        if outDur != range.duration {
          slot.track.scaleTimeRange(
            CMTimeRange(start: putAt, duration: range.duration),
            toDuration: outDur)
        }
      } catch {
        // 最常見的是「要的區間超出素材長度」——修剪或切割之後
        // trim 值算過頭就會走到這裡
        buildError =
          "素材接不進去（\((path as NSString).lastPathComponent)："
          + "要 \(String(format: "%.2f", start))~\(String(format: "%.2f", end))s，"
          + "素材長 \(String(format: "%.2f", asset.duration.seconds))s）"
        return false
      }
      slot.end = putAt + outDur
      vTracks[layer] = slot
      lastMedia[layer] = (src, range)

      // 聲音：找一條這個時間點空著的軌，沒有就開新的
      if let sa = asset.tracks(withMediaType: .audio).first {
        var chosen: Int? = nil
        for i in aTracks.indices where aTracks[i].end <= putAt {
          chosen = i
          break
        }
        if chosen == nil,
          let t = comp.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        {
          aTracks.append((t, .zero))
          aParams.append(AVMutableAudioMixInputParameters(track: t))
          chosen = aTracks.count - 1
        }
        if let i = chosen {
          do {
            // 先補空白再插：插在超過軌道長度的時間點時，「會不會自動
            // 補空白」文件講得含糊，不補的話配樂可能整段往前擠、
            // 聲音跟畫面對不上
            if aTracks[i].end < putAt {
              aTracks[i].track.insertEmptyTimeRange(
                CMTimeRange(
                  start: aTracks[i].end, duration: putAt - aTracks[i].end))
            }
            try aTracks[i].track.insertTimeRange(range, of: sa, at: putAt)
            if outDur != range.duration {
              aTracks[i].track.scaleTimeRange(
                CMTimeRange(start: putAt, duration: range.duration),
                toDuration: outDur)
            }
            aTracks[i].end = putAt + outDur
            // 每一段的音量；淡入淡出是斜坡，不是階梯
            let pr = aParams[i]
            if fadeIn > 0.01 {
              pr.setVolumeRamp(
                fromStartVolume: 0, toEndVolume: volume,
                timeRange: CMTimeRange(
                  start: putAt,
                  duration: CMTime(seconds: fadeIn, preferredTimescale: scale)))
            } else {
              pr.setVolume(volume, at: putAt)
            }
            if fadeOut > 0.01 {
              let fo = CMTime(seconds: fadeOut, preferredTimescale: scale)
              pr.setVolumeRamp(
                fromStartVolume: volume, toEndVolume: 0,
                timeRange: CMTimeRange(
                  start: putAt + outDur - fo, duration: fo))
            }
          } catch {}
        }
      }

      segments.append(
        Seg(
          range: CMTimeRange(start: putAt, duration: outDur),
          transform: src.preferredTransform, size: src.naturalSize,
          fadeIn: fadeIn, fadeOut: fadeOut, userScale: userScale, px: px,
          py: py, mirror: mirror, track: slot.track, layer: layer,
          crop: cropArr, rotation: rotation, opacity: opacity))
    }
    if segments.isEmpty {
      buildError = "沒有一段畫面接得進去"
      return false
    }

    // CI 路線：每條畫面軌「最後一段結束到合成結尾」也要鋪滿——
    // 對自訂合成器來說，軌道提早結束跟空範圍是同一回事（+79 的
    // 軌 0 只到 0.48s、合成長 1.76s，抽格就是這樣壞的）。
    // 用該軌最後一段的結尾一小格拉長蓋過去，畫面照樣由指令決定
    if needsCI {
      for (layer, slot) in vTracks where slot.end < comp.duration {
        guard let m = lastMedia[layer] else { continue }
        let gap = comp.duration - slot.end
        let snipDur = CMTime(
          seconds: min(0.2, m.rng.duration.seconds), preferredTimescale: scale)
        let snip = CMTimeRange(start: m.rng.end - snipDur, duration: snipDur)
        if (try? slot.track.insertTimeRange(snip, of: m.src, at: slot.end))
          != nil
        {
          slot.track.scaleTimeRange(
            CMTimeRange(start: slot.end, duration: snip.duration),
            toDuration: gap)
          vTracks[layer]?.end = comp.duration
        }
      }
    }

    // 畫面大小以「最底層、最早出現」的那一段轉正之後的尺寸為準。
    //
    // 本來是取迴圈裡第一個遇到的，但那份排序只看時間不看層——子母畫面
    // 的小畫面如果比底下那層早開始，整個畫布就會照小畫面的比例走
    if let base = segments.min(by: {
      $0.layer != $1.layer
        ? $0.layer < $1.layer
        : $0.range.start.seconds < $1.range.start.seconds
    }) {
      let d = base.size.applying(base.transform)
      size = CGSize(width: abs(d.width), height: abs(d.height))
    }
    if size.width < 2 || size.height < 2 {
      buildError = "讀不到畫面尺寸"
      return false
    }
    duration = comp.duration.seconds
    if duration <= 0 {
      buildError = "總長度是 0"
      return false
    }

    // 軌道實況：每條畫面軌實際鋪了什麼（媒＝正常媒體、填＝拉長的
    // 填充或變速、空＝空範圍）。CI 路線出現「空」＝鋪滿失敗，直接定罪
    buildInfo["軌道段"] = vTracks.keys.sorted().map { k -> String in
      guard let tr = vTracks[k]?.track else { return "軌\(k)：？" }
      let parts = tr.segments.map { sg -> String in
        let r = sg.timeMapping.target
        let tag =
          sg.isEmpty
          ? "空" : (sg.timeMapping.source.duration == r.duration ? "媒" : "填")
        return String(
          format: "%@%.2f~%.2f", tag, r.start.seconds, r.end.seconds)
      }.joined(separator: "｜")
      return "軌\(k)：\(parts)"
    }.joined(separator: "；")

    let mix = AVMutableAudioMix()
    mix.inputParameters = aParams
    let item = AVPlayerItem(asset: comp)
    item.audioMix = mix
    // 抽幀口改「用到才掛」（見 grabFrame）：常駐掛一個 BGRA 輸出
    // 會讓顯示管線退化——HDR 原檔在圖層上過飽和爆掉（+109 實驗：
    // 同一個檔相簿正常、我們爆，唯一差異就是這個 tap）
    videoOut = nil
    // 變速時聲音保持音高（跟主流剪輯 App 一致）
    item.audioTimePitchAlgorithm = .timeDomain
    // 系統自己喊的「播放卡住了」：時間點記下來，跟供格節奏對照
    if let o = stallObs { NotificationCenter.default.removeObserver(o) }
    // queue: .main——nil 是「發通知的那條執行緒」，stallNotes 同時
    // 被主執行緒的 healthStats 讀，無鎖交錯理論上可 crash
    stallObs = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.AVPlayerItemPlaybackStalled,
      object: item, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      self.stallCount += 1
      if self.stallNotes.count < 10 {
        self.stallNotes.append(
          String(format: "%.2fs", self.player.currentTime().seconds))
      }
    }

    // 需不需要合成器，先問清楚再掛。
    //
    // 掛了 AVVideoComposition，播放就從「硬體解碼直送螢幕」變成
    // 「每一格都進合成管線重畫一張」——4K 素材那是每格重畫 830 萬像素。
    // 相簿播同一支影片不會這樣，別家剪輯 App 也不會：他們只在真的要
    // 疊圖層、轉正、淡入淡出的時候才掛。
    //
    // 只有一層、方向一致、尺寸一致、沒有淡入淡出也沒有縮放位移時，
    // 一條軌照順序播就是正確結果，合成器純粹是多餘的成本——
    // 而且不掛的話 HDR 素材由系統自己映射，顏色跟相簿完全一致
    let uniformTransform = segments.first?.transform ?? .identity
    let sameTransform = segments.allSatisfy { $0.transform == uniformTransform }
    let needsVC =
      vTracks.count > 1
      || segments.contains { seg in
        seg.fadeIn > 0.01 || seg.fadeOut > 0.01 || seg.mirror
          || abs(seg.userScale - 1) > 0.001 || abs(seg.px - 0.5) > 0.001
          || abs(seg.py - 0.5) > 0.001
      }
      || segments.contains { seg in
        let d = seg.size.applying(seg.transform)
        return abs(abs(d.width) - size.width) > 1
          || abs(abs(d.height) - size.height) > 1
      }
      || !sameTransform
      // Flutter 材質那條路拿到的是「儲存方向」的原始影格，不會自動套
      // 軌道方向——走材質又有旋轉旗標時，方向只能靠合成器烘進畫面。
      // 系統影片圖層則會自己套，不受影響
      || (texture && !uniformTransform.isIdentity)
      // 馬賽克要烘進畫面，一定得走合成器；裁切/旋轉/透明度同理
      || !mosaics.isEmpty
      || !stills.isEmpty
      // HDR 原檔要靠合成器做 toneMapHDRtoSDR（見 needsCI 的說明）；
      // HDR 輸出模式不映射，沒別的效果就不掛
      || (anyHDR && !hdrOut)
      // HDR 預覽的疊加物：跟 needsCI 同一條（掛 CI 的前提是有 VC）
      || (hdrOut && anyHDR && !overlays.isEmpty)
      || segments.contains { seg in
        seg.crop != nil || abs(seg.rotation) > 0.05 || seg.opacity < 0.999
      }
    if !needsVC, let only = vTracks.values.first {
      only.track.preferredTransform = uniformTransform
    }
    usesVC = needsVC

    if needsVC, size.width > 1, size.height > 1 {
      // 預覽用的合成不需要原始解析度：手機螢幕短邊不到 1200，
      // 用 4K 去重畫每一格只是把解碼省下來的錢又花掉。這也是別家
      // 「預覽解析度」設定在做的事
      let cap: CGFloat = 1080
      let shrink = min(1, cap / min(size.width, size.height))
      if shrink < 1 {
        size = CGSize(
          width: (size.width * shrink / 2).rounded() * 2,
          height: (size.height * shrink / 2).rounded() * 2)
      }
      let vc = AVMutableVideoComposition()
      vc.renderSize = size
      vc.frameDuration = CMTime(value: 1, timescale: 30)
      // 輸出色彩明確標 709。HDR 原檔進 CI 合成器時像素已經被
      // toneMap 成 SDR，但不標的話 HDR 的色彩標記會原封傳下去，
      // 播放器對「已經是 SDR 的像素」再套一次 HLG 顯示曲線——
      // 就是「進場 CI 有掛、顏色照樣洗白」（+93 診斷定罪）。
      // 匯出路早就標了（同一個教訓），播放路漏掉
      if hdrOut && anyHDR {
        // HDR 預覽：跟 HDR 匯出同一組標記（HLG），像素不做映射
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
      } else {
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
      }

      // 墊在影片下層的圖片/GIF：組成 CI 層（跟匯出同一套定位數學，
      // 畫布用預覽的 renderSize）。GIF 包成 CIGifSpec 逐幀取
      var stillSpecs: [(z: Int, order: Int, layer: CILayerSpec)] = []
      for (idx, st) in stills.enumerated() {
        guard let path = st["path"] as? String,
          let ui = UIImage(contentsOfFile: path), let cg = ui.cgImage
        else { continue }
        var img = CIImage(cgImage: cg)
        let dw = img.extent.width
        let dh = img.extent.height
        guard dw > 1, dh > 1 else { continue }
        var t = CGAffineTransform.identity
        if st["mirror"] as? Bool ?? false {
          t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1))
            .concatenating(CGAffineTransform(translationX: dw, y: 0))
        }
        let k = min(size.width / dw, size.height / dh)
        t = t.concatenating(CGAffineTransform(scaleX: k, y: k))
          .concatenating(
            CGAffineTransform(
              translationX: (size.width - dw * k) / 2,
              y: (size.height - dh * k) / 2))
        let u = CGFloat(st["scale"] as? Double ?? 1)
        let spx = st["px"] as? Double ?? 0.5
        let spy = st["py"] as? Double ?? 0.5
        if abs(Double(u) - 1) > 0.001 || abs(spx - 0.5) > 0.001
          || abs(spy - 0.5) > 0.001
        {
          t = t
            .concatenating(
              CGAffineTransform(
                translationX: -size.width / 2, y: -size.height / 2)
            )
            .concatenating(CGAffineTransform(scaleX: u, y: u))
            .concatenating(
              CGAffineTransform(
                translationX: size.width / 2 + CGFloat(spx - 0.5)
                  * size.width,
                y: size.height / 2 + CGFloat(spy - 0.5) * size.height))
        }
        let flipSrc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: dh)
        let flipCanvas = CGAffineTransform(
          a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        let placement = flipSrc.concatenating(t).concatenating(flipCanvas)
        var gifSpec: CIGifSpec? = nil
        if st["gif"] as? Bool ?? false {
          gifSpec = CIGifSpec(
            path: path, placement: placement,
            clipStart: st["start"] as? Double ?? 0)
        }
        if gifSpec == nil {
          img = img.transformed(by: placement)
        }
        var stCrop: CGRect? = nil
        if let ca = st["crop"] as? [Double], ca.count >= 4, ca[2] > 0.001,
          ca[3] > 0.001
        {
          let mir = st["mirror"] as? Bool ?? false
          let l = mir ? 1 - ca[0] - ca[2] : ca[0]
          stCrop = CGRect(x: l, y: ca[1], width: ca[2], height: ca[3])
        }
        stillSpecs.append((
          z: st["track"] as? Int ?? 0, order: idx,
          layer: CILayerSpec(
            trackID: kCMPersistentTrackID_Invalid,
            still: gifSpec == nil ? img : nil,
            transform: .identity, srcHeight: dh,
            start: st["start"] as? Double ?? 0,
            end: st["end"] as? Double ?? 0,
            fadeIn: st["fadeIn"] as? Double ?? 0,
            fadeOut: st["fadeOut"] as? Double ?? 0,
            colorMatrix: st["color"] as? [Double],
            crop: stCrop,
            rotation: st["rotation"] as? Double ?? 0,
            opacity: st["opacity"] as? Double ?? 1,
            z: st["track"] as? Int ?? 0, gif: gifSpec)
        ))
      }
      buildInfo["圖片層"] = stillSpecs.count

      /// 一段畫面貼進畫布：轉正 → 等比縮放貼齊 → 置中 → 使用者的縮放位移
      func fitTransform(_ seg: Seg) -> CGAffineTransform? {
        let disp = seg.size.applying(seg.transform)
        let dw = abs(disp.width)
        let dh = abs(disp.height)
        guard dw > 1, dh > 1 else { return nil }
        let k = min(size.width / dw, size.height / dh)
        // 鏡像在「轉正之後的顯示座標」上做：先左右翻，再推回原位
        var t = seg.transform
        if seg.mirror {
          t = t.concatenating(CGAffineTransform(scaleX: -1, y: 1))
            .concatenating(CGAffineTransform(translationX: dw, y: 0))
        }
        t = t
          .concatenating(CGAffineTransform(scaleX: k, y: k))
          .concatenating(
            CGAffineTransform(
              translationX: (size.width - dw * k) / 2,
              y: (size.height - dh * k) / 2))
        let u = CGFloat(seg.userScale)
        if abs(seg.userScale - 1) > 0.001 || abs(seg.px - 0.5) > 0.001
          || abs(seg.py - 0.5) > 0.001
        {
          t = t
            .concatenating(
              CGAffineTransform(
                translationX: -size.width / 2, y: -size.height / 2)
            )
            .concatenating(CGAffineTransform(scaleX: u, y: u))
            .concatenating(
              CGAffineTransform(
                translationX: size.width / 2 + CGFloat(seg.px - 0.5)
                  * size.width,
                y: size.height / 2 + CGFloat(seg.py - 0.5) * size.height))
        }
        return t
      }

      /// 一段畫面在 [t] 這一刻該有多不透明（0~1）。淡入淡出是線性的
      func opacity(_ seg: Seg, at t: Double) -> Double {
        let s = seg.range.start.seconds
        let e = seg.range.end.seconds
        var o = 1.0
        if seg.fadeIn > 0.01 {
          o = min(o, ((t - s) / seg.fadeIn).clamped01())
        }
        if seg.fadeOut > 0.01 {
          o = min(o, ((e - t) / seg.fadeOut).clamped01())
        }
        return o
      }

      // 指令必須把整條時間軸切成不重疊、而且接得起來的區間。
      // 每個片段的頭尾都是一個切點；區間內把「當下看得到的層」由下往上
      // 疊起來，這就是子母畫面
      //
      // 切點一律用 CMTime 本人，不要繞道 Double 再轉回來。
      //
      // 轉回來會各自被 timescale 四捨五入：前一段的「開頭＋長度」跟下一段
      // 的「開頭」就差那麼一兩格，中間留下一條比一格還短的縫。系統驗出來
      // 就是「有一段沒人管：4.45~4.45s」（頭尾印出來一樣，因為根本不到
      // 0.01 秒），整份合成直接作廢，播放退回舊的多播放器路徑——那正是
      // 「不黑畫面了，但延遲又回來了」
      var rawT: [CMTime] = [CMTime.zero, comp.duration]
      for seg in segments {
        rawT.append(seg.range.start)
        rawT.append(seg.range.end)
      }
      for sp in stillSpecs {
        rawT.append(CMTime(seconds: sp.layer.start, preferredTimescale: 600))
        rawT.append(CMTime(seconds: sp.layer.end, preferredTimescale: 600))
      }
      // 去重要帶容差，而且是在這裡去掉，不是排完之後跳過太短的區間——
      // 跳過會在時間軸上留一條沒有指令的縫，而指令必須首尾相接把整條
      // 蓋滿，缺一段系統就當這份合成有問題
      var marks: [CMTime] = []
      for t in rawT.filter({
        $0.isValid && $0 >= CMTime.zero && $0 <= comp.duration
      }).sorted() {
        if let last = marks.last, (t - last).seconds < 0.005 { continue }
        marks.append(t)
      }
      // 結尾一定要正好等於 comp.duration，差一格系統就當最後那一格沒人管。
      // 距離夠遠才補一個切點；很近的話是把原本的切點對齊過去，不是蓋掉
      // 它——蓋掉的話那一段就消失了，取中點時會挑到別段，畫面直接不見
      if let last = marks.last, last != comp.duration {
        if (comp.duration - last).seconds < 0.005 {
          marks[marks.count - 1] = comp.duration
        } else {
          marks.append(comp.duration)
        }
      }
      if marks.count < 2 { marks = [CMTime.zero, comp.duration] }
      // needsCI 在插軌之前就算好了（CI 路線的軌道有沒有鋪滿全看它，
      // 這裡沿用同一個值才不會兩邊打架）
      if needsCI {
        // 馬賽克要逐格打在畫面上，標準的 layer instruction 做不到——
        // 掛跟匯出同一顆 CI 合成器（CIExportCompositor）：濃度、柔邊、
        // 顏色的數學跟成品一字不差，預覽即所得。
        // HDR 來源它會做 toneMapHDRtoSDR，顏色跟相簿同一條曲線
        let ciMosaics = mosaics.compactMap { CIMosaicSpec($0, canvas: size) }
        // 全部影像軌：每段指令都列，解碼器全程保持熱的（見
        // CIExportInstruction.requiredSourceTrackIDs 的說明）
        let prerollIDs = Array(Set(segments.map { $0.track.trackID }))
          .sorted().map { NSNumber(value: $0) }
        // 最後一個可見片段結束的時間：之後的區間就是「片尾」
        let lastShow = segments.map { $0.range.end.seconds }.max() ?? 0
        var built: [CIExportInstruction] = []
        for i in 0..<(marks.count - 1) {
          let a = marks[i]
          let b = marks[i + 1]
          let mid = (a.seconds + b.seconds) / 2
          let here = segments.filter {
            $0.range.start.seconds <= mid + 0.0005
              && $0.range.end.seconds >= mid - 0.0005
          }.sorted { $0.layer < $1.layer }
          // CI 合成器照陣列順序由下往上疊。影片段跟圖片層
          // 併在一起照 z（軌道編號）排——圖片墊在影片下層時
          // 會先畫、被影片正確蓋住（就是它進合成的意義）
          var entries: [(z: Int, order: Int, spec: CILayerSpec)] = []
          for (oi, seg) in here.enumerated() {
            guard let t = fitTransform(seg) else { continue }
            // 裁切窗：預覽是「先裁再鏡像」，transform 已含鏡像，
            // 鏡像時窗的水平位置要翻過來（跟匯出同一套換算）
            var cropRect: CGRect? = nil
            if let ca = seg.crop, ca.count >= 4, ca[2] > 0.001,
              ca[3] > 0.001
            {
              let l = seg.mirror ? 1 - ca[0] - ca[2] : ca[0]
              cropRect = CGRect(x: l, y: ca[1], width: ca[2], height: ca[3])
            }
            entries.append((
              z: seg.layer, order: oi,
              spec: CILayerSpec(
                trackID: seg.track.trackID, still: nil,
                transform: t, srcHeight: seg.size.height,
                start: seg.range.start.seconds,
                end: seg.range.end.seconds,
                fadeIn: seg.fadeIn, fadeOut: seg.fadeOut,
                colorMatrix: nil,
                crop: cropRect, rotation: seg.rotation,
                opacity: seg.opacity, z: seg.layer)
            ))
          }
          for sp in stillSpecs
          where sp.layer.start <= mid + 0.0005
            && sp.layer.end >= mid - 0.0005
          {
            entries.append((z: sp.z, order: 1000 + sp.order, spec: sp.layer))
          }
          entries.sort { $0.z != $1.z ? $0.z < $1.z : $0.order < $1.order }
          let layers = entries.map { $0.spec }
          // 片尾（最後一個可見片段之後，例如音樂比畫面長）不留黑：
          // 無條件重播最後一格，畫面停在最後一幀直到播完
          let tail = a.seconds >= lastShow - 0.001
          built.append(
            CIExportInstruction(
              timeRange: CMTimeRange(start: a, end: b),
              layers: layers, mosaics: ciMosaics, overlays: [],
              prerollTrackIDs: prerollIDs,
              holdIfEmpty: layers.isEmpty
                && ((b - a).seconds < 0.12 || tail)))
        }
        // HDR 輸出模式掛「HDR 預覽」合成器：同一套疊圖、不做色調
        // 映射、輸出走 HLG 管線（跟 HDR 匯出同一顆），另外讀即時
        // 疊加物——浮水印/文字烘在 HDR 畫面上用 EDR 顯示，
        // 白色才是真的白（跟成品同一段提亮程式碼）
        vc.customVideoCompositorClass =
          hdrOut && anyHDR
          ? CIPreviewCompositorHDR.self : CIExportCompositor.self
        if hdrOut && anyHDR {
          CIExportCompositor.setPreviewOverlays(
            overlays.compactMap { CIOverlaySpec($0, canvas: size) })
          ciCanvas = size
          wmLive = true
        }
        vc.instructions = built
        buildInfo["CI"] = true
        buildInfo["指令"] = built.map { ins -> String in
          "\(String(format: "%.2f", ins.timeRange.start.seconds))~"
            + "\(String(format: "%.2f", ins.timeRange.end.seconds))"
            + " 層z=\(ins.layers.map { $0.z })"
        }.joined(separator: "；")
      } else {
      var instructions: [AVMutableVideoCompositionInstruction] = []
      for i in 0..<(marks.count - 1) {
        let a = marks[i]
        let b = marks[i + 1]
        let mid = (a.seconds + b.seconds) / 2
        let here = segments.filter {
          $0.range.start.seconds <= mid + 0.0005
            && $0.range.end.seconds >= mid - 0.0005
        }.sorted { $0.layer < $1.layer }  // 軌道編號小的在下面
        let ins = AVMutableVideoCompositionInstruction()
        // 上一段的結尾就是下一段的開頭本人，接縫是零
        ins.timeRange = CMTimeRange(start: a, end: b)
        var lis: [AVMutableVideoCompositionLayerInstruction] = []
        // 疊圖層時後面的畫在上面，所以由上往下加
        for seg in here.reversed() {
          guard let t = fitTransform(seg) else { continue }
          let li = AVMutableVideoCompositionLayerInstruction(
            assetTrack: seg.track)
          li.setTransform(t, at: ins.timeRange.start)
          // 淡入淡出要裁進「這一段指令」的範圍裡。
          //
          // 指令的區間是被所有片段的頭尾切出來的，一個片段常常橫跨好幾
          // 段指令；把整條淡入的時間範圍原封設在每一段指令上，範圍會落
          // 在指令之外，那是不合法的用法。改成算出這段指令的頭尾各自
          // 該有多不透明，中間拉一條斜坡——跨幾段都接得起來
          let o0 = opacity(seg, at: a.seconds)
          let o1 = opacity(seg, at: b.seconds)
          if abs(o0 - 1) > 0.001 || abs(o1 - 1) > 0.001 {
            if abs(o0 - o1) < 0.001 {
              li.setOpacity(Float(o0), at: ins.timeRange.start)
            } else {
              li.setOpacityRamp(
                fromStartOpacity: Float(o0), toEndOpacity: Float(o1),
                timeRange: ins.timeRange)
            }
          }
          lis.append(li)
        }
        ins.layerInstructions = lis
        instructions.append(ins)
      }
      vc.instructions = instructions
      buildInfo["CI"] = false
      buildInfo["指令"] = instructions.map { ins -> String in
        "\(String(format: "%.2f", ins.timeRange.start.seconds))~"
          + "\(String(format: "%.2f", ins.timeRange.end.seconds))"
          + " 層數\(ins.layerInstructions.count)"
      }.joined(separator: "；")
      }
      // 交出去之前先讓 AVFoundation 自己驗一遍。壞掉的合成不會丟例外，
      // 只會安靜地變成一片黑——那正是「拉到新軌道預覽就消失」
      let v = VCValidator()
      if !vc.isValid(
        for: comp, timeRange: CMTimeRange(start: .zero, duration: comp.duration),
        validationDelegate: v)
      {
        buildError =
          "合成指令不合法：" + (v.problems.first ?? "沒有細節")
          + (v.problems.count > 1 ? "（共 \(v.problems.count) 處）" : "")
        return false
      }
      item.videoComposition = vc
    }
    // 影格輸出：BGRA 直接給 Flutter 材質用
    // 屬性字典的型別要寫死：空字典字面值 Swift 推不出型別會直接編不過
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    if texture {
      let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
      item.add(out)
      output = out
    }
    buildInfo["合成軌"] = vTracks.count
    buildInfo["usesVC"] = usesVC
    // 長度 0＝合成是空的（多半是「沒有視訊軌」的壞工作檔混進來）。
    // 照樣回報就緒的話，播放器抱著空合成跳針卡死、畫面全黑，
    // 連看門狗重建都只會重建出同一份空的——直接判失敗，
    // 讓呼叫端退回逐片段播放器
    guard comp.duration.seconds > 0.05 else {
      buildError = "合成長度為 0（可能有壞掉的工作檔，重進編輯器會自動重轉）"
      return false
    }
    composition = comp
    player.replaceCurrentItem(with: item)

    if texture {
      if textureId == 0, let registry = registry {
        textureId = registry.register(self)
      }
      startLink()
    }
    return true
  }

  private func startLink() {
    link?.invalidate()
    let l = CADisplayLink(target: self, selector: #selector(onFrame))
    l.add(to: .main, forMode: .common)
    link = l
  }

  /// 材質實際更新的間隔統計（judder 的唯一證據）
  private var lastFrameAt: CFTimeInterval = 0
  private(set) var frameGaps: [Int] = []

  @objc private func onFrame() {
    guard let out = output else { return }
    let t = player.currentTime()
    guard out.hasNewPixelBuffer(forItemTime: t),
      let buf = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    else { return }
    let now = CACurrentMediaTime()
    if lastFrameAt > 0, frameGaps.count < 600 {
      frameGaps.append(Int((now - lastFrameAt) * 1000))
    }
    lastFrameAt = now
    lock.lock()
    latest = buf
    lock.unlock()
    registry?.textureFrameAvailable(textureId)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let b = latest else { return nil }
    return Unmanaged.passRetained(b)
  }

  private var targetRate: Float = 1

  /// 按下播放那一刻播放器在忙什麼——量出來，不用猜。
  /// 「seek進行中」＝畫面要等那發 seek 跑完才會動；
  /// 「緩衝是空的」＝暫停期間 buffer 被回收了，要先重新解
  func playStatus() -> String {
    var bits: [String] = []
    if seeking { bits.append("seek進行中") }
    if let it = player.currentItem {
      if it.status != .readyToPlay { bits.append("item還沒ready") }
      if it.isPlaybackBufferEmpty { bits.append("緩衝是空的") }
      if !it.isPlaybackLikelyToKeepUp { bits.append("緩衝可能跟不上") }
    } else {
      bits.append("沒有item")
    }
    return bits.isEmpty ? "乾淨" : bits.joined(separator: "、")
  }

  /// playImmediately 而不是 play：後者會先跑一輪緩衝條件才讓畫面真的動
  func play() {
    // 還沒跑完的 preroll 會把播放壓住，先取消
    player.cancelPendingPrerolls()
    startPlayWatch()
    CIExportCompositor.slowLock.lock()
    CIExportCompositor.watchSupply = true
    CIExportCompositor.lastReqT = -1
    CIExportCompositor.slowLock.unlock()
    player.playImmediately(atRate: targetRate)
  }

  // ── 按下播放到畫面真的動：在原生端量，而且量的是「過程」 ─────────
  //
  // Dart 端只能每 33ms 問一次位置，而且問到的是「時鐘動了沒」。
  // 播放器自己說「乾淨」卻要 200ms 才動——那 200ms 裡它到底在做什麼，
  // 只有在原生端用 display link 逐格記錄才看得到：
  // - timeControlStatus 什麼時候變成 playing
  // - 這期間 reasonForWaitingToPlay 說了什麼
  // - currentTime 什麼時候真的開始前進
  // 三個時間點分開之後，是「播放器沒開始」還是「開始了但畫面沒更新」
  // 一眼就分得出來
  private var watchLink: CADisplayLink?
  private var watchT0: CFTimeInterval = 0
  private var watchStartTime: CMTime = .zero
  private(set) var lastPlayBreakdown: [String: Any] = [:]

  private func startPlayWatch() {
    watchLink?.invalidate()
    watchT0 = CACurrentMediaTime()
    watchStartTime = player.currentTime()
    lastPlayBreakdown = [:]
    let l = CADisplayLink(target: self, selector: #selector(onWatch))
    l.add(to: .main, forMode: .common)
    watchLink = l
  }

  @objc private func onWatch() {
    let ms = Int((CACurrentMediaTime() - watchT0) * 1000)
    if lastPlayBreakdown["rateMs"] == nil, player.rate != 0 {
      lastPlayBreakdown["rateMs"] = ms
    }
    if lastPlayBreakdown["playingMs"] == nil,
      player.timeControlStatus == .playing
    {
      lastPlayBreakdown["playingMs"] = ms
    }
    if lastPlayBreakdown["waiting"] == nil,
      player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
      let r = player.reasonForWaitingToPlay
    {
      lastPlayBreakdown["waiting"] = "\(r.rawValue)＠\(ms)ms"
    }
    if lastPlayBreakdown["movedMs"] == nil,
      CMTimeGetSeconds(player.currentTime()) - CMTimeGetSeconds(watchStartTime)
        > 0.001
    {
      lastPlayBreakdown["movedMs"] = ms
    }
    // 畫面真的動了、或量超過 2 秒都沒動，就收工
    if lastPlayBreakdown["movedMs"] != nil || ms > 2000 {
      lastPlayBreakdown["totalMs"] = ms
      watchLink?.invalidate()
      watchLink = nil
    }
  }

  func pause() {
    CIExportCompositor.slowLock.lock()
    CIExportCompositor.watchSupply = false
    CIExportCompositor.slowLock.unlock()
    player.pause()
    // 暫停時把管線熱著，下次按播放就不用等
    if player.currentItem?.status == .readyToPlay {
      player.preroll(atRate: targetRate, completionHandler: nil)
    }
  }

  func setRate(_ r: Double) {
    targetRate = Float(r)
    if player.rate != 0 { player.playImmediately(atRate: targetRate) }
  }

  /// 預覽靜音。走 AVPlayer 自己的 isMuted，不動合成裡烘好的音量——
  /// 改音量參數要整份重組，按一下靜音就會卡一拍
  func setMuted(_ m: Bool) {
    player.isMuted = m
  }

  private var seekTarget: CMTime = .invalid
  private var seekTargetExact = false
  private var seeking = false

  /// 每一發真正做掉的 seek 花多久（毫秒），以及被合併掉幾發。
  /// 這是「左右滑動順不順」的直接證據：平均 30ms 以下＝跟得上手指，
  /// 200ms 以上＝每滑一下都要等，關鍵幀太疏
  private(set) var seekMs: [Int] = []
  private(set) var seekCoalesced = 0
  private var seekStart: CFTimeInterval = 0

  /// [exact] 只有「使用者停手了、要對準那一格」時才給 true。
  ///
  /// 精準 seek 要從前一個關鍵幀一路解到目標格，而且跑完之前 rate 會被
  /// 壓在 0——按下播放剛好撞上它，畫面就是不動。拖曳中一律寬容，
  /// 停手之後才補一次精準的
  func seek(_ seconds: Double, exact: Bool) {
    var t = seconds
    // 精準 seek（停手/點時間軸）偏移半格：指針吸在片段邊界（例如
    // 馬賽克起點 4.5s）時，來源取樣格的 PTS 常常是 4.4711 之類
    //（29.97fps 對不齊），畫面顯示的是「邊界前一格」——那格還不在
    // 效果的時間段裡，看起來就是「指針指到素材開頭卻沒有馬賽克」
    //（實測回報）。往前偏半格保證顯示的是邊界上或之後的取樣格
    if exact { t += 0.02 }
    // 目標夾在「最後一格之前」：seek 到正好等於總長的位置，指令已經
    // 出界，畫面可能刷成黑的——拖到底或播完停在結尾都要停在最後一幀
    if duration > 0.1, t > duration - 0.034 { t = duration - 0.034 }
    seekTarget = CMTime(seconds: t, preferredTimescale: 600)
    seekTargetExact = exact
    // 已經有一發在跑：只要記住最新目標就好，跑完會自己追上去
    if seeking {
      seekCoalesced += 1
    } else {
      chase()
    }
  }

  /// 追最新的目標，不是把每一發都做完。
  ///
  /// 手指每動一次就灌一發 seek 的話，AVPlayer 會排成隊列一發一發做，
  /// 畫面於是永遠落在手指後面好幾發——看起來就是「一格一格跳、沒辦法
  /// 快速預覽」。中途那些目標使用者根本沒在看，直接丟掉
  /// 還沒 ready 就先等一下再試，最多等 2 秒（40 次）
  private var chaseWaits = 0

  private func chase() {
    guard seekTarget.isValid else {
      seeking = false
      chaseWaits = 0
      return
    }
    // 剛重組完的 item 還沒 ready，這時候 seek 會被系統丟掉——本來就在
    // 這裡直接放棄，結果是「切割之後預覽跳回前段」：時間軸停在 2.8 秒，
    // 畫面卻是第 0 秒。改成等它 ready 再送
    guard player.currentItem?.status == .readyToPlay else {
      if chaseWaits >= 40 {
        seeking = false
        chaseWaits = 0
        return
      }
      chaseWaits += 1
      seeking = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self = self else { return }
        self.seeking = false
        self.chase()
      }
      return
    }
    chaseWaits = 0
    let t = seekTarget
    let exact = seekTargetExact
    seekTarget = .invalid
    seeking = true
    let tol =
      exact ? CMTime.zero : CMTimeMakeWithSeconds(0.1, preferredTimescale: 600)
    seekStart = CACurrentMediaTime()
    player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol) {
      [weak self] _ in
      // 完成回呼在 AVFoundation 的背景佇列跑，seeking/seekTarget
      // 卻是主執行緒（method channel）在寫——無鎖交錯下最後那發
      // 「停手精準 seek」可能被安靜吞掉、seeking 卡在 true 之後
      // 全部 seek 都被合併。整段跳回主執行緒，狀態單線化
      DispatchQueue.main.async {
        guard let self = self else { return }
        if self.seekMs.count < 400 {
          self.seekMs.append(
            Int((CACurrentMediaTime() - self.seekStart) * 1000))
        }
        self.seeking = false
        if self.seekTarget.isValid {
          self.chase()  // 手指又動了，追過去
        } else if self.player.rate == 0,
          self.player.currentItem?.status == .readyToPlay
        {
          // 停下來了：把管線熱著，下次按播放就不用等
          self.player.preroll(atRate: self.targetRate, completionHandler: nil)
        }
      }
    }
  }

  /// 抽「現在畫面上這一格」（合成後的輸出）。給編輯器的
  /// 「重烘空窗即時鋪面」用：剛加的馬賽克先用這格＋Flutter 畫出來，
  /// 重烘好再換真的
  func grabFrame(maxH: Int, done: @escaping (Data?) -> Void) {
    // 用到才掛：常駐的 BGRA 輸出會讓顯示管線退化（HDR 爆色）。
    // 掛上去的當下畫面上那格還沒送進 tap，原地精準 seek 一發
    // 逼它重繪，再輪詢把那格抄出來
    if videoOut == nil, let item = player.currentItem {
      let vo = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(
          kCVPixelFormatType_32BGRA)
      ])
      item.add(vo)
      videoOut = vo
      // 原地 seek 會被系統當 no-op 略過（目標＝現在位置就不重繪），
      // tap 永遠等不到畫面——往前挪一格（34ms）逼它真的重繪。
      // 暫停中差一格肉眼無感；重烘完成後會再精準 seek 回正
      let t0 = player.currentTime()
      let nudge = CMTime(
        seconds: max(0, t0.seconds - 0.034), preferredTimescale: 600)
      player.seek(to: nudge, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    guard let vo = videoOut else {
      done(nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      // 抄「現在顯示中的那格」：時間用 tap 的 host 時間對映——
      // 上面可能剛做過挪格 seek，抓固定時間點會抓不到
      func tryCopy() -> CVPixelBuffer? {
        let t = vo.itemTime(forHostTime: CACurrentMediaTime())
        return vo.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
      }
      var pb: CVPixelBuffer? = tryCopy()
      // 剛掛上的 tap 要等重繪那格到位（最多等 0.6 秒）
      var waited = 0
      while pb == nil, waited < 30 {
        Thread.sleep(forTimeInterval: 0.02)
        waited += 1
        pb = tryCopy()
      }
      guard let pb = pb else {
        done(nil)
        return
      }
      var img = CIImage(cvPixelBuffer: pb)
      let h = img.extent.height
      if maxH > 0, h > CGFloat(maxH) {
        let k = CGFloat(maxH) / h
        img = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
      }
      let ctx = CIContext(options: [.workingColorSpace: NSNull()])
      guard let cg = ctx.createCGImage(img, from: img.extent) else {
        done(nil)
        return
      }
      let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
      // 抄完就拆：tap 留著顯示管線就一直退化
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        if let vo2 = self.videoOut, let item = self.player.currentItem {
          item.remove(vo2)
        }
        self.videoOut = nil
      }
      done(data)
    }
  }

  var positionMs: Int { Int(player.currentTime().seconds * 1000) }

  /// 系統自己記的播放品質。這幾個數字是 AVPlayer 內部統計，
  /// Flutter 端的任何指標都看不到：
  /// - 掉格：解碼器沒把影格及時交出來（畫面頓的直接證據）
  /// - 卡頓：播放中途被迫停下來等資料
  /// - 在等什麼：rate 想跑但跑不動時，系統說的理由
  /// 「畫面是黑的」有兩種完全不同的原因，修法也完全不同：
  /// 合成本身是空的／壞的，還是合成好好的但圖層沒把它畫出來。
  /// 直接從這份合成抽一格出來看，就分得開——抽得到就是圖層的問題
  private func frameProbe() -> String {
    guard let comp = composition else { return "沒有合成" }
    let gen = AVAssetImageGenerator(asset: comp)
    // 掛了 videoComposition 就不能再要求它套軌道方向：兩個一起給，
    // 產生器會直接失敗——那樣這個檢查本身就在說謊
    if let vc = player.currentItem?.videoComposition {
      // Apple 的限制：產生器不支援自訂合成器，掛了必定抽不到。
      // 這條檢查對 CI 路線天生無效——+77~+80 每一份報告的
      // 「抽不到畫面（合成本身有問題）」全是這裡的假警報
      if vc.customVideoCompositorClass != nil {
        return "不適用（CI 合成器，產生器天生抽不了；不是故障）"
      }
      gen.videoComposition = vc
    } else {
      gen.appliesPreferredTrackTransform = true
    }
    gen.maximumSize = CGSize(width: 64, height: 64)
    gen.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(0.2, preferredTimescale: 600)
    gen.requestedTimeToleranceAfter = CMTimeMakeWithSeconds(0.2, preferredTimescale: 600)
    let t = player.currentTime()
    guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else {
      return "這一刻抽不到畫面（合成本身有問題）"
    }
    let w = cg.width
    let h = cg.height
    var buf = [UInt8](repeating: 0, count: max(1, w * h * 4))
    guard
      let ctx = CGContext(
        data: &buf, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return "抽得到但檢查不了" }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var lit = 0
    for i in stride(from: 0, to: buf.count, by: 4) {
      if Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2]) > 24 { lit += 1 }
    }
    return lit == 0
      ? "抽得到但整格是黑的（合成內容是空的）"
      : "抽得到，有畫面（合成沒問題，是圖層沒畫出來）"
  }

  func healthStats() -> [String: Any] {
    var m: [String: Any] = ["usesVC": usesVC, "renderW": Int(size.width),
                            "renderH": Int(size.height)]
    if let comp = composition {
      m["vTracks"] = comp.tracks(withMediaType: .video).count
      m["aTracks"] = comp.tracks(withMediaType: .audio).count
      m["compDur"] = comp.duration.seconds
    }
    m["instructions"] =
      player.currentItem?.videoComposition?.instructions.count ?? 0
    m["buildInfo"] = buildInfo
    CIExportCompositor.slowLock.lock()
    m["ciFrames"] = CIExportCompositor.frameCount
    m["ciWorstMs"] = CIExportCompositor.worstMs
    m["ciSlow"] = CIExportCompositor.slowFrames
    m["ciSupplyWorst"] = CIExportCompositor.worstSupplyMs
    m["ciSupplyGaps"] = CIExportCompositor.supplyGaps
    m["ciMiss"] = CIExportCompositor.missTotal
    m["ciMissNotes"] = CIExportCompositor.missNotes
    m["ciHoldMiss"] = CIExportCompositor.holdMissCount
    m["ciHoldGap"] = CIExportCompositor.holdGapCount
    CIExportCompositor.slowLock.unlock()
    m["stallNotify"] = stallCount
    m["stallNotifyAt"] = stallNotes
    PlayerPlatformView.statLock.lock()
    m["viewCreates"] = PlayerPlatformView.createCount
    m["viewCreateAt"] = PlayerPlatformView.createNotes
    PlayerPlatformView.statLock.unlock()
    m["frameProbe"] = frameProbe()
    switch player.timeControlStatus {
    case .paused: m["timeControl"] = "暫停"
    case .waitingToPlayAtSpecifiedRate: m["timeControl"] = "想播但在等"
    case .playing: m["timeControl"] = "播放中"
    @unknown default: m["timeControl"] = "未知"
    }
    if let r = player.reasonForWaitingToPlay {
      switch r {
      case .toMinimizeStalls: m["waiting"] = "怕卡頓先囤資料"
      case .evaluatingBufferingRate: m["waiting"] = "在評估載入速度"
      case .noItemToPlay: m["waiting"] = "沒有東西可播"
      default: m["waiting"] = r.rawValue
      }
    }
    if let it = player.currentItem {
      m["bufferEmpty"] = it.isPlaybackBufferEmpty
      m["likelyToKeepUp"] = it.isPlaybackLikelyToKeepUp
      if let e = it.accessLog()?.events.last {
        m["dropped"] = e.numberOfDroppedVideoFrames
        m["stalls"] = e.numberOfStalls
      }
    }
    if !lastPlayBreakdown.isEmpty {
      m["playBreakdown"] = lastPlayBreakdown
    }
    if !seekMs.isEmpty {
      let sorted = seekMs.sorted()
      m["seekCount"] = seekMs.count
      m["seekAvgMs"] = seekMs.reduce(0, +) / seekMs.count
      m["seekP50Ms"] = sorted[sorted.count / 2]
      m["seekP90Ms"] = sorted[min(sorted.count - 1, sorted.count * 9 / 10)]
      m["seekMaxMs"] = sorted.last!
      m["seekCoalesced"] = seekCoalesced
    }
    return m
  }

  /// 換圖間隔的統計：幾次、平均、最久、超過兩格的次數。
  /// 30fps 的素材理想值是每 33ms 一次；出現 60、80、100 就是 judder
  func gapStats() -> [String: Any] {
    let g = frameGaps
    guard !g.isEmpty else { return ["count": 0] }
    let sum = g.reduce(0, +)
    return [
      "count": g.count,
      "avgMs": Double(sum) / Double(g.count),
      "maxMs": g.max() ?? 0,
      "over2x": g.filter { $0 > 66 }.count,
    ]
  }

  func disposeWatch() {
    watchLink?.invalidate()
    watchLink = nil
  }

  func dispose() {
    disposeWatch()
    if let o = stallObs {
      NotificationCenter.default.removeObserver(o)
      stallObs = nil
    }
    link?.invalidate()
    link = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    if textureId != 0 {
      registry?.unregisterTexture(textureId)
      textureId = 0
    }
    lock.lock()
    latest = nil
    lock.unlock()
  }
}
