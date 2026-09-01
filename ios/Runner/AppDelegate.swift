import AVFoundation
import MetalKit
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
/// 檔案的畫面軌格式與色彩標籤，一行字（診斷用）
func mcFileInfo(_ path: String) -> String {
  guard !path.isEmpty else { return "無路徑" }
  let asset = AVURLAsset(url: URL(fileURLWithPath: path))
  guard let tr = asset.tracks(withMediaType: .video).first else {
    return "無畫面軌"
  }
  var s = "\(Int(tr.naturalSize.width))x\(Int(tr.naturalSize.height))"
  if let fdAny = tr.formatDescriptions.first {
    let fd = fdAny as! CMFormatDescription
    let sub = CMFormatDescriptionGetMediaSubType(fd)
    let cc = [24, 16, 8, 0].map { sh -> String in
      let c = UInt8((sub >> UInt32(sh)) & 255)
      return c >= 32 && c < 127 ? String(UnicodeScalar(c)) : "?"
    }.joined()
    let pr =
      CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
      as? String ?? "無"
    let tf =
      CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
      as? String ?? "無"
    s += " \(cc) 原色=\(pr.replacingOccurrences(of: "ITU_R_", with: ""))"
    s += " 曲線=\(tf.replacingOccurrences(of: "ITU_R_", with: ""))"
  }
  return s
}

/// 成品檔抽 3 格（10%/50%/90%），中央 50% 區平均 RGB（顯示轉換後）
func mcSampleFile(_ path: String) -> String {
  let asset = AVURLAsset(url: URL(fileURLWithPath: path))
  let d = CMTimeGetSeconds(asset.duration)
  guard d > 0.2 else { return "讀不到長度" }
  let gen = AVAssetImageGenerator(asset: asset)
  gen.appliesPreferredTrackTransform = true
  gen.maximumSize = CGSize(width: 160, height: 160)
  gen.requestedTimeToleranceBefore = .zero
  gen.requestedTimeToleranceAfter = CMTime(
    seconds: 0.5, preferredTimescale: 600)
  var out: [String] = []
  for t in [d * 0.1, d * 0.5, d * 0.9] {
    guard
      let cg = try? gen.copyCGImage(
        at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
    else {
      out.append(String(format: "%.1fs:抽不到", t))
      continue
    }
    let w = cg.width
    let h = cg.height
    guard w > 3, h > 3,
      let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { continue }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let dp = ctx.data else { continue }
    let buf = dp.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var r = 0.0
    var g = 0.0
    var b = 0.0
    var n = 0.0
    for y in (h / 4)..<(3 * h / 4) {
      for x in (w / 4)..<(3 * w / 4) {
        let i = (y * w + x) * 4
        r += Double(buf[i])
        g += Double(buf[i + 1])
        b += Double(buf[i + 2])
        n += 1
      }
    }
    if n > 0 {
      out.append(
        String(
          format: "%.1fs:%.3f,%.3f,%.3f", t, r / n / 255, g / n / 255,
          b / n / 255))
    }
  }
  return out.joined(separator: "；")
}

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

  /// 即時幾何（見 CompLiveOv）：id 對得上就套差量。
  /// bx/by/bs/br＝這張 PNG 烘的時候的位置/大小/旋轉基準。
  /// 匯出跟舊呼叫端不帶＝不參與
  let id: String?
  let bx: Double
  let by: Double
  let bs: Double
  let br: Double
  /// 烘圖畫布外擴比例（每邊）：快路用，拖出畫框再拉回不會缺一塊
  let pad: Double

  /// 解好的點陣（引擎上傳紋理、CI 合成共用同一份）
  let cgImg: CGImage

  init?(_ ov: [String: Any], canvas: CGSize) {
    id = ov["id"] as? String
    pad = ov["pad"] as? Double ?? 0
    bx = ov["bx"] as? Double ?? 0.5
    by = ov["by"] as? Double ?? 0.5
    bs = ov["bs"] as? Double ?? 1
    br = ov["br"] as? Double ?? 0
    // 兩種載體：png（匯出/停手全解析）或 raw RGBA（調樣式即時路——
    // PNG 編碼+解碼一來回 100~300ms，就是實機 157「樣式硬跟」的大頭）
    var decoded: CGImage?
    if let data = (ov["png"] as? FlutterStandardTypedData)?.data,
      let ui = UIImage(data: data)
    {
      decoded = ui.cgImage
    } else if let td = ov["raw"] as? FlutterStandardTypedData,
      let rw = ov["rw"] as? Int, let rh = ov["rh"] as? Int,
      rw > 1, rh > 1, td.data.count >= rw * rh * 4,
      let prov = CGDataProvider(data: td.data as CFData)
    {
      // Flutter rawRgba＝預乘 RGBA、sRGB
      decoded = CGImage(
        width: rw, height: rh, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: rw * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)
          ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
          rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: prov, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent)
    }
    guard let cg = decoded else { return nil }
    cgImg = cg
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

  /// 這一層烘進 transform 的「使用者變形」基準值（縮放/位置）。
  /// 即時變形（liveXform）要靠它算差量：新值 ∘ 舊值⁻¹ 疊上去。
  /// 只有預覽的影片層會帶；匯出/圖層用預設值（等於不參與）
  let uScale: Double
  let uPx: Double
  let uPy: Double

  init(
    trackID: CMPersistentTrackID, still: CIImage?,
    transform: CGAffineTransform, srcHeight: CGFloat,
    start: Double, end: Double, fadeIn: Double, fadeOut: Double,
    colorMatrix: [Double]?,
    crop: CGRect? = nil, rotation: Double = 0, opacity: Double = 1,
    z: Int = 0, gif: CIGifSpec? = nil,
    uScale: Double = 1, uPx: Double = 0.5, uPy: Double = 0.5
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
    self.uScale = uScale
    self.uPx = uPx
    self.uPy = uPy
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

  /// 即時內容的世代號：疊加物/變形每次更新 +1。Metal 引擎靜止
  /// 降頻用它判斷「畫面有沒有東西變了」——沒變就不重繪（省電）
  static var liveEpoch = 0

  static func setPreviewOverlays(_ o: [CIOverlaySpec]) {
    ovLock.lock()
    previewOvs = o
    liveEpoch &+= 1
    ovLock.unlock()
  }
  static func currentPreviewOverlays() -> [CIOverlaySpec] {
    ovLock.lock()
    defer { ovLock.unlock() }
    return previewOvs
  }

  /// 讀「即時疊加物」而不是指令裡那份（只有 HDR 預覽合成器開）
  var livePreview: Bool { false }

  /// 讀「即時變形」（兩個預覽合成器都開；匯出不讀）
  var liveComp: Bool { false }

  /// 捏合/拖曳中的即時變形（見 CompLiveXform）：每一格合成時直接
  /// 讀，零重建。只有預覽合成器（livePreview/liveCI）讀它
  static let xfLock = NSLock()
  private static var liveXf: CompLiveXform?
  static func setLiveXform(_ x: CompLiveXform?) {
    xfLock.lock()
    liveXf = x
    liveEpoch &+= 1
    xfLock.unlock()
  }
  static func currentLiveXform() -> CompLiveXform? {
    xfLock.lock()
    defer { xfLock.unlock() }
    return liveXf
  }

  // 一次可以有好幾個部件在動（位置九宮格＝文字＋圖片一起跳），
  // 用字典存、整包替換——單格存放會漏掉第二個部件（實測回報：
  // 點置中就是不過來）
  private static var liveOvs: [String: CompLiveOv] = [:]
  static func setLiveOvs(_ xs: [CompLiveOv]) {
    xfLock.lock()
    liveOvs = Dictionary(uniqueKeysWithValues: xs.map { ($0.id, $0) })
    liveEpoch &+= 1
    xfLock.unlock()
  }
  static func currentLiveOvs() -> [String: CompLiveOv] {
    xfLock.lock()
    defer { xfLock.unlock() }
    return liveOvs
  }

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

  /// Engine 3.0 快路統計：多少格走了 Metal 直拷、多少格走 CI
  static var stFastFrames = 0
  static var stCIFrames = 0
  /// 快路未命中原因計數（實機定罪用）
  static var stSkip: [String: Int] = [:]
  static func skip(_ why: String) {
    stSkip[why, default: 0] += 1
    if stSkip[why] == 1 { NSLog("[FastPath] skip=%@", why) }
  }

  /// 這一層的變形是否把來源滿版貼合畫布（誤差 1.5px 內）。
  /// 支援 0/90/180/270 旋轉（直式素材帶旋轉 flag 是實機常態）。
  /// 回傳旋轉角；nil＝非滿版或非直角旋轉，呼叫端走 CI
  /// 快路取樣參數：畫布四角 → 來源 UV（用 chain 反矩陣）。
  /// 回 nil＝這一層沒有滿版貼合畫布（或矩陣退化），呼叫端走 CI。
  /// 不再把幾何分類成 0/90/180/270——鏡像會被誤判成正立
  ///（實機 144：匯入後畫面顏倒）；仿射反矩陣一式通吃
  func fastUV(
    _ L: CILayerSpec, srcW: CGFloat, srcH: CGFloat, canvas: CGSize
  ) -> (SIMD4<Float>, SIMD2<Float>)? {
    guard srcW > 1, srcH > 1 else { return nil }
    let flipSrc = CGAffineTransform(
      a: 1, b: 0, c: 0, d: -1, tx: 0, ty: L.srcHeight)
    let flipCanvas = CGAffineTransform(
      a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height)
    let chain = flipSrc.concatenating(L.transform)
      .concatenating(flipCanvas)
    // 退化（行列式≈ 0）不可逆
    let det = chain.a * chain.d - chain.b * chain.c
    guard abs(det) > 0.000001 else { return nil }
    // 滿版檢查：來源四角映到畫布的包圍盒要蓋滿畫布
    let corners = [
      CGPoint(x: 0, y: 0), CGPoint(x: srcW, y: 0),
      CGPoint(x: 0, y: srcH), CGPoint(x: srcW, y: srcH),
    ].map { $0.applying(chain) }
    let xs = corners.map { $0.x }
    let ys = corners.map { $0.y }
    let r = CGRect(
      x: xs.min()!, y: ys.min()!,
      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    let c = CGRect(origin: .zero, size: canvas)
    guard abs(r.minX - c.minX) < 1.5, abs(r.minY - c.minY) < 1.5,
      abs(r.maxX - c.maxX) < 1.5, abs(r.maxY - c.maxY) < 1.5
    else {
      if Self.stFastFrames == 0, Self.stCIFrames < 30 {
        NSLog(
          "[FastPath] 非滿版 r=%@ canvas=%@",
          NSCoder.string(for: r), NSCoder.string(for: c))
      }
      return nil
    }
    let inv = chain.inverted()
    func uv(_ x: CGFloat, _ y: CGFloat) -> SIMD2<Float> {
      let p = CGPoint(x: x, y: y).applying(inv)
      return SIMD2<Float>(Float(p.x / srcW), Float(p.y / srcH))
    }
    let uv0 = uv(0, 0)
    let du = uv(canvas.width, 0) - uv0
    let dv = uv(0, canvas.height) - uv0
    return (SIMD4<Float>(uv0.x, uv0.y, du.x, du.y), dv)
  }

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
        : Int(kCVPixelFormatType_32BGRA),
      // IOSurface 支援：沒有它的話合成出來的緩衝「顯示不出來」——
      // 匯出（寫檔）不受影響，但 AVPlayerLayer 拿到就是一片黑。
      // 舊架構播放時畫面由 Metal 引擎蓋在上面，所以一直沒露出來；
      // 播放交還系統播放器後就變成「按播放全黑」（實機 143~146）
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      kCVPixelBufferMetalCompatibilityKey as String: true,
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
  /// 起播節奏：閒置 >300ms 後重新收集，前 40 格的到格間隔（ms）
  static var burstGaps: [Int] = []

  static func noteSupply(t: Double, wall: Double) {
    slowLock.lock()
    defer { slowLock.unlock() }
    if watchSupply, lastReqT >= 0 {
      let dt = t - lastReqT
      let dw = wall - lastReqWall
      if dw > 0.3 { burstGaps = [] }
      if burstGaps.count < 40 { burstGaps.append(Int(dw * 1000)) }
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

  /// 交出去那一格的中心亮度（0~1）取樣紀錄：每 30 格量一次。
  /// 全 0＝合成器真的交黑格；有值＝畫面在顯示端被吃掉
  static var lumaProbe: [String] = []
  private static var lumaN = 0

  /// 交格前補上色彩標記：CoreImage 渲染「不會」寫緩衝的色彩附件，
  /// 播放器圖層拿到沒有標記的 HLG/709 緩衝就顯示不出來（黑）。
  /// 匯出寫檔不受影響（走 videoComposition 的宣告），播放才需要
  func tagColors(_ buf: CVPixelBuffer) {
    let prim: CFString =
      hdrOut
      ? kCVImageBufferColorPrimaries_ITU_R_2020
      : kCVImageBufferColorPrimaries_ITU_R_709_2
    let trc: CFString =
      hdrOut
      ? kCVImageBufferTransferFunction_ITU_R_2100_HLG
      : kCVImageBufferTransferFunction_ITU_R_709_2
    let mat: CFString =
      hdrOut
      ? kCVImageBufferYCbCrMatrix_ITU_R_2020
      : kCVImageBufferYCbCrMatrix_ITU_R_709_2
    CVBufferSetAttachment(
      buf, kCVImageBufferColorPrimariesKey, prim, .shouldPropagate)
    CVBufferSetAttachment(
      buf, kCVImageBufferTransferFunctionKey, trc, .shouldPropagate)
    CVBufferSetAttachment(
      buf, kCVImageBufferYCbCrMatrixKey, mat, .shouldPropagate)
  }

  static func noteLuma(
    _ buf: CVPixelBuffer, t: Double, drawn: Int = -1, missing: Bool = false,
    srcH: CGFloat = -1, canvasH: CGFloat = -1
  ) {
    lumaN += 1
    guard lumaN % 30 == 1 else { return }
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    let fmt = CVPixelBufferGetPixelFormatType(buf)
    let planar = CVPixelBufferGetPlaneCount(buf) > 0
    let w = planar
      ? CVPixelBufferGetWidthOfPlane(buf, 0) : CVPixelBufferGetWidth(buf)
    let h = planar
      ? CVPixelBufferGetHeightOfPlane(buf, 0) : CVPixelBufferGetHeight(buf)
    let stride = planar
      ? CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
      : CVPixelBufferGetBytesPerRow(buf)
    guard
      let base = planar
        ? CVPixelBufferGetBaseAddressOfPlane(buf, 0)
        : CVPixelBufferGetBaseAddress(buf), w > 4, h > 4
    else { return }
    var v = 0.0
    if fmt == kCVPixelFormatType_32BGRA {
      let p = base.advanced(by: (h / 2) * stride + (w / 2) * 4)
        .assumingMemoryBound(to: UInt8.self)
      v = (Double(p[0]) + Double(p[1]) + Double(p[2])) / (3 * 255)
    } else {
      // 10-bit Y 平面（x420）：16-bit word 取高位
      let p = base.advanced(by: (h / 2) * stride + (w / 2) * 2)
        .assumingMemoryBound(to: UInt16.self)
      v = Double(p[0]) / 65535.0
    }
    lumaProbe.append(
      drawn < 0
        ? String(format: "%.1fs:%.3f", t, v)
        : String(
          format: "%.1fs:%.3f(畫%d層%@ 源高%.0f/布高%.0f)", t, v, drawn,
          missing ? "缺源" : "", Double(srcH), Double(canvasH)))
    if lumaProbe.count > 6 { lumaProbe.removeFirst() }
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
        let t0 = req.compositionTime.seconds
        if Self.stCIFrames + Self.stFastFrames < 3 {
          NSLog(
            "[FastPath] 格況 hdrOut=%@ layers=%d live=%@ ovs=%d 台上=%@",
            self.hdrOut ? "T" : "F", ins.layers.count,
            self.livePreview ? "T" : "F",
            CIExportCompositor.currentPreviewOverlays().count,
            MetalPreviewEngine.shared.isOnStage ? "T" : "F")
        }
        // ── Engine 3.0 快路：單層滿版無效果 → YUV 平面直拷 ──
        // 色彩零轉換（位元級一致）、<1ms。任何條件不合就走 CI 原路
        // 逐項判定並記錄未命中原因（實機診斷直接指認）
        func fastEligible() -> CVPixelBuffer? {
          // HDR 直拷暫停用：實機 144 命中 19 格且回報黑畫面，
          // x420 平面搬運的正確性未經數值驗證——先退 CI，
          // 等 SDR 快路穩定、且有逐格數值比對後再開
          guard !self.hdrOut else {
            Self.skip("HDR直拷暫停用")
            return nil
          }
          guard ins.mosaics.allSatisfy({ t0 < $0.start || t0 >= $0.end })
          else {
            Self.skip("馬賽克")
            return nil
          }
          guard ins.layers.count == 1, let L = ins.layers.first else {
            Self.skip("多層")
            return nil
          }
          guard L.trackID != kCMPersistentTrackID_Invalid, L.gif == nil,
            L.still == nil
          else {
            Self.skip("圖層")
            return nil
          }
          guard L.colorMatrix == nil, L.crop == nil, L.rotation == 0,
            L.opacity > 0.999
          else {
            Self.skip("效果")
            return nil
          }
          guard L.fadeIn < 0.01 || t0 >= L.start + L.fadeIn,
            L.fadeOut < 0.01 || t0 <= L.end - L.fadeOut
          else {
            Self.skip("淡化中")
            return nil
          }
          guard !self.liveComp
            || CIExportCompositor.currentLiveXform() == nil
          else {
            Self.skip("即時變形")
            return nil
          }
          // 浮水印：SDR 輸出在快路內直接疊整版 PNG；
          // HDR 輸出的提亮數學未搬入快路，有浮水印且引擎
          // 不在台上時退 CI
          if self.hdrOut {
            guard !self.livePreview
              || CIExportCompositor.currentPreviewOverlays().isEmpty
              || MetalPreviewEngine.shared.isOnStage
            else {
              Self.skip("HDR浮水印")
              return nil
            }
          }
          guard let sbuf = req.sourceFrame(byTrackID: L.trackID) else {
            Self.skip("缺來源格")
            return nil
          }
          guard
            let uvp = self.fastUV(
              L, srcW: CGFloat(CVPixelBufferGetWidth(sbuf)),
              srcH: CGFloat(CVPixelBufferGetHeight(sbuf)), canvas: size)
          else {
            Self.skip("非滿版")
            return nil
          }
          fastUVA = uvp.0
          fastUVB = uvp.1
          return sbuf
        }
        var fastUVA = SIMD4<Float>(0, 0, 1, 0)
        var fastUVB = SIMD2<Float>(0, 1)
        var fastOvs: [CGImage] = []
        if !self.hdrOut, self.liveComp {
          for ov in CIExportCompositor.currentPreviewOverlays()
          where ov.start <= t0 && t0 < ov.end {
            fastOvs.append(ov.cgImg)
          }
        }
        if let sbuf = fastEligible(),
          self.hdrOut
            ? MetalYUVBlit.shared.blit(
              from: sbuf, to: dst, uvA: fastUVA, uvB: fastUVB)
            : MetalYUVBlit.shared.sdrCompose(
              from: sbuf, to: dst, overlays: fastOvs,
              uvA: fastUVA, uvB: fastUVB)
        {
          Self.stFastFrames += 1
          if Self.stFastFrames == 1 || Self.stFastFrames % 300 == 0 {
            NSLog("[FastPath] 快路命中 %d 格", Self.stFastFrames)
          }
          Self.noteFrame(
            t: t0, ms: (CFAbsoluteTimeGetCurrent() - tick) * 1000,
            layers: 1, missing: false)
          self.tagColors(dst)
          Self.noteLuma(
            dst, t: t0, drawn: 1, missing: false,
            srcH: ins.layers.first?.srcHeight ?? -1, canvasH: size.height)
          req.finish(withComposedVideoFrame: dst)
          return
        }
        Self.stCIFrames += 1
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
        // 捏合/拖曳中的即時變形：每一格讀一次（只有預覽合成器讀）
        let lx = self.liveComp ? CIExportCompositor.currentLiveXform() : nil
        var mzIdx = 0
        var missing = false
        var drawnCount = 0
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
          // 捏合/拖曳中的即時變形：把「新值 ∘ 舊值⁻¹」的差量疊上去，
          // 數學跟 fitTransform 的使用者段同構——放手烘定不會跳位。
          // 只作用在被捏的那一段（軌道編號＋片段開頭一起對）
          var rot = layer.rotation
          if let lx = lx, lx.z == layer.z,
            abs(lx.start - layer.start) < 0.02,
            layer.trackID != kCMPersistentTrackID_Invalid
          {
            func userXf(
              _ u: Double, _ px: Double, _ py: Double
            ) -> CGAffineTransform {
              CGAffineTransform(
                translationX: -size.width / 2, y: -size.height / 2
              )
              .concatenating(
                CGAffineTransform(scaleX: CGFloat(u), y: CGFloat(u)))
              .concatenating(
                CGAffineTransform(
                  translationX: size.width / 2 + CGFloat(px - 0.5)
                    * size.width,
                  y: size.height / 2 + CGFloat(py - 0.5) * size.height))
            }
            // 差量在 AV 座標（y 往下）算，前後各翻一次進 CI 座標
            let extra = userXf(layer.uScale, layer.uPx, layer.uPy)
              .inverted()
              .concatenating(userXf(lx.scale, lx.px, lx.py))
            img = img.transformed(
              by: flipCanvas.concatenating(extra).concatenating(flipCanvas))
            rot = lx.rotation
          }
          // 裁切：transform 沒有旋轉成分，貼上畫布是軸對齊的方框，
          // 直接照 extent 的比例切窗。比例是左上原點，CI 是左下——
          // y 要反過來。旋轉繞「整個片段框」的中心（跟預覽一致），
          // 所以中心用裁切前的 extent 算
          if layer.crop != nil || abs(rot) > 0.05 {
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
              if abs(rot) > 0.05 {
                img = Self.spin(
                  img, degrees: rot,
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
          drawnCount += 1
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
          let lovs =
            self.liveComp ? CIExportCompositor.currentLiveOvs() : [:]
          // 夾白的底每格算一次就好（原本每個部件各夾一次）。
          // 部件彼此重疊的極端情況會少算前一個部件的亮度，肉眼
          // 看不出來；換來的是 N 個部件省 N-1 次全畫布濾鏡
          var cappedBase: CIImage?
          if self.hdrOut && !ovs.isEmpty {
            cappedBase = out.applyingFilter(
              "CIColorClamp",
              parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
              ])
          }
          for ov in ovs {
            if var o = ov.frame(at: t, canvas: size) {
              // 浮水印部件的即時幾何：拖/縮/轉只是差量，PNG 不重畫。
              // 差量繞「部件中心」算（跟預覽的拖曳手感同一個原點）
              if let oid = ov.id, let lov = lovs[oid] {
                let cx = CGFloat(ov.bx) * size.width
                let cy = (1 - CGFloat(ov.by)) * size.height
                let sc = CGFloat(lov.scale / max(0.0001, ov.bs))
                var d = CGAffineTransform(translationX: -cx, y: -cy)
                  .concatenating(CGAffineTransform(scaleX: sc, y: sc))
                let dr = lov.rot - ov.br
                if abs(dr) > 0.01 {
                  // CI 是 y 往上：畫面上的順時針＝數學上的負角
                  d = d.concatenating(
                    CGAffineTransform(
                      rotationAngle: CGFloat(-dr * Double.pi / 180)))
                }
                d = d.concatenating(
                  CGAffineTransform(
                    translationX: cx + CGFloat(lov.x - ov.bx) * size.width,
                    y: cy - CGFloat(lov.y - ov.by) * size.height))
                o = o.transformed(by: d)
              }
              if self.hdrOut, let capped = cappedBase {
                // 治本（半透明變灰的根）：疊加物蓋到的地方，先把
                // 「字底下」的畫面夾回 SDR 白以內再混色。半透明白字
                // 在 SDR 是 70% 白＋30% 背景（背景最亮 1.0）＝白；
                // HDR 背景可以亮到 SDR 白的好幾倍，30% 的背景就把
                // 70% 的字沖成灰——問題不在字不夠亮，在字縫裡透進來
                // 的超亮畫面。夾住之後混色數學跟 SDR 一字不差；
                // 字外的畫面完全不動、HDR 照樣亮
                out = capped.applyingFilter(
                  "CIBlendWithAlphaMask",
                  parameters: [
                    kCIInputBackgroundImageKey: out,
                    kCIInputMaskImageKey: o,
                  ])
                // HDR 輸出：疊加物（文字/浮水印/貼圖）在線性光提亮
                // 一檔（×2）。SDR 白疊在 HDR 畫面上只有基準白
                //（~203 尼特），旁邊高光動輒上千尼特，使用者挑的
                // 「白色」看起來就是灰的（實測回報：成品顏色跟挑的
                // 差很多）。提一檔後視覺上才是挑的那個顏色；
                // 預覽與匯出同一段程式碼，兩邊一起亮
                o = o.applyingFilter(
                  "CIColorMatrix",
                  parameters: [
                    // ×3（原本 ×2）：實測回報 ×2 在 HLG 高光旁邊
                    // 還是偏灰，再提半檔（約 600 尼特）
                    "inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 3, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 3, w: 0),
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
        self.tagColors(dst)
        Self.noteLuma(
          dst, t: t0, drawn: drawnCount, missing: missing,
          srcH: ins.layers.first?.srcHeight ?? -1, canvasH: size.height)
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
  override var liveComp: Bool { true }
}

/// SDR「預覽」合成器：跟匯出同一套疊圖，只是會讀即時變形
///（liveXform）。匯出用的基底類不讀——匯出中使用者捏預覽
/// 不能弄髒成品
final class CIPreviewCompositorSDR: CIExportCompositor {
  override var liveComp: Bool { true }
}

/// Engine 3.0 第一刀：Metal 快路合成核心。
///
/// 時間軸播放的大宗是「單一影片層滿版、無效果」的格——這種格
/// 不需要任何色彩處理，YUV 平面直接（縮放）搬運：色彩零轉換、
/// 跟來源位元級一致、GPU 耗時 <1ms。CI 慢格（實測 383ms）的主體
/// 就是這些格白白走了整條 CoreImage 管線。
/// 多層/濾鏡/貼圖/馬賽克/即時變形的格照走 CI（數值已驗證）。
final class MetalYUVBlit {
  static let shared = MetalYUVBlit()
  private var device: MTLDevice?
  private var queue: MTLCommandQueue?
  private var cache: CVMetalTextureCache?
  private var pipeY: MTLRenderPipelineState?
  private var pipeC: MTLRenderPipelineState?
  private var pipeY8: MTLRenderPipelineState?
  private var pipeC8: MTLRenderPipelineState?
  private var pipeYUVBGRA: MTLRenderPipelineState?
  private var pipeOv: MTLRenderPipelineState?
  /// 浮水印 PNG 紋理快取（以 Data 物件位址為鍵；預覽清單換了
  /// 就自然換新）
  private var ovTexCache: [ObjectIdentifier: MTLTexture] = [:]
  private var ovTexOrder: [ObjectIdentifier] = []
  private var sampler: MTLSamplerState?
  private var ready = false
  private var failed = false
  private var noteN = 0
  private let lock = NSLock()

  /// 每平面一條 passthrough（雙線性縮放由 sampler 做）。
  /// Y 平面 r16Unorm、CbCr 平面 rg16Unorm——值原樣搬，不解碼
  private let src = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    // 取樣坐標由呼叫端用「畫布→來源」反矩陣算好：
    // uv = uv0 + t.x*du + t.y*dv（仿射→三個向量就完全描述）。
    // 旋轉、鏡像、縮放全包、不需要分類——實機 144
    // 「畫面顏倒」就是分類法漏了垂直鏡像
    vertex VOut vtxBlit(uint vid [[vertex_id]],
                        constant float4 &uvA [[buffer(0)]],
                        constant float2 &uvB [[buffer(1)]]) {
      float2 p[6] = {
        float2(-1, 1), float2(1, 1), float2(-1, -1),
        float2(1, 1), float2(1, -1), float2(-1, -1)};
      float2 t[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)};
      VOut o;
      o.pos = float4(p[vid], 0, 1);
      float2 tt = t[vid];
      o.uv = uvA.xy + tt.x * uvA.zw + tt.y * uvB;
      return o;
    }
    fragment float4 fragY(VOut in [[stage_in]],
                          texture2d<float> tex [[texture(0)]],
                          sampler s [[sampler(0)]]) {
      return float4(tex.sample(s, in.uv).r, 0, 0, 1);
    }
    fragment float4 fragC(VOut in [[stage_in]],
                          texture2d<float> tex [[texture(0)]],
                          sampler s [[sampler(0)]]) {
      float2 c = tex.sample(s, in.uv).rg;
      return float4(c.r, c.g, 0, 1);
    }
    // SDR 快路：8-bit YUV（BT.709 limited）→ BGRA（gamma 域直出，
    // 跟來源同義——不做任何色彩轉換以外的處理）
    fragment float4 fragYUVBGRA(VOut in [[stage_in]],
                                texture2d<float> texY [[texture(0)]],
                                texture2d<float> texC [[texture(1)]],
                                constant float &fullRange [[buffer(0)]],
                                sampler s [[sampler(0)]]) {
      float y = texY.sample(s, in.uv).r;
      float2 cbcr = texC.sample(s, in.uv).rg;
      float Y = fullRange > 0.5
        ? y : (y - 16.0 / 255.0) * (255.0 / 219.0);
      float sc = fullRange > 0.5 ? 1.0 : (255.0 / 224.0);
      float Cb = (cbcr.x - 0.5) * sc;
      float Cr = (cbcr.y - 0.5) * sc;
      float3 rgb = float3(
        Y + 1.5748 * Cr,
        Y - 0.18732 * Cb - 0.46812 * Cr,
        Y + 1.8556 * Cb);
      return float4(clamp(rgb, 0.0, 1.0), 1.0);
    }
    // 浮水印整版 PNG 疊加（straight alpha，blend 在 pipeline 設）
    fragment float4 fragOv(VOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           sampler s [[sampler(0)]]) {
      return tex.sample(s, in.uv);
    }
    """

  private func setUp() -> Bool {
    if ready { return true }
    if failed { return false }
    guard let dev = MTLCreateSystemDefaultDevice(),
      let q = dev.makeCommandQueue()
    else {
      failed = true
      return false
    }
    var c: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, dev, nil, &c)
    guard let cc = c else {
      failed = true
      return false
    }
    do {
      let lib = try dev.makeLibrary(source: src, options: nil)
      let v = lib.makeFunction(name: "vtxBlit")
      func pipe(_ frag: String, _ fmt: MTLPixelFormat) throws
        -> MTLRenderPipelineState
      {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = v
        d.fragmentFunction = lib.makeFunction(name: frag)
        d.colorAttachments[0].pixelFormat = fmt
        return try dev.makeRenderPipelineState(descriptor: d)
      }
      pipeY = try pipe("fragY", .r16Unorm)
      pipeC = try pipe("fragC", .rg16Unorm)
      pipeY8 = try pipe("fragY", .r8Unorm)
      pipeC8 = try pipe("fragC", .rg8Unorm)
      pipeYUVBGRA = try pipe("fragYUVBGRA", .bgra8Unorm)
      let od = MTLRenderPipelineDescriptor()
      od.vertexFunction = v
      od.fragmentFunction = lib.makeFunction(name: "fragOv")
      od.colorAttachments[0].pixelFormat = .bgra8Unorm
      od.colorAttachments[0].isBlendingEnabled = true
      od.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
      od.colorAttachments[0].destinationRGBBlendFactor =
        .oneMinusSourceAlpha
      od.colorAttachments[0].sourceAlphaBlendFactor = .one
      od.colorAttachments[0].destinationAlphaBlendFactor =
        .oneMinusSourceAlpha
      pipeOv = try dev.makeRenderPipelineState(descriptor: od)
      let sd = MTLSamplerDescriptor()
      sd.minFilter = .linear
      sd.magFilter = .linear
      sd.sAddressMode = .clampToEdge
      sd.tAddressMode = .clampToEdge
      sampler = dev.makeSamplerState(descriptor: sd)
      device = dev
      queue = q
      cache = cc
      ready = true
      return true
    } catch {
      NSLog("[MetalYUVBlit] 建管線失敗 %@", String(describing: error))
      failed = true
      return false
    }
  }

  /// 預熱：建佈局時先把 Metal 管線編譯好。
  /// 不預熱的話第一次呼叫落在合成器的第一格上，
  /// makeLibrary(source:) 要幾百 ms——實機 144：首格 695ms，
  /// 使用者看到的就是「按播放後畫面遲遲不出來」
  func prewarm() {
    lock.lock()
    _ = setUp()
    lock.unlock()
  }

  private func planeTex(
    _ buf: CVPixelBuffer, _ plane: Int, _ fmt: MTLPixelFormat
  ) -> MTLTexture? {
    guard let cache = cache else { return nil }
    var cv: CVMetalTexture?
    let w = CVPixelBufferGetWidthOfPlane(buf, plane)
    let h = CVPixelBufferGetHeightOfPlane(buf, plane)
    guard
      CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, cache, buf, nil, fmt, w, h, plane, &cv)
        == kCVReturnSuccess, let cv = cv
    else { return nil }
    return CVMetalTextureGetTexture(cv)
  }

  /// 兩平面縮放搬運（10-bit bi-planar → 同格式）。同步等完成
  ///（合成器本來就在背景佇列，等 <1ms）。回 false＝呼叫端走 CI
  func blit(
    from srcBuf: CVPixelBuffer, to dstBuf: CVPixelBuffer,
    uvA: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 0),
    uvB: SIMD2<Float> = SIMD2<Float>(0, 1)
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard setUp(), let queue = queue, let sampler = sampler
    else { return false }
    let sf = CVPixelBufferGetPixelFormatType(srcBuf)
    let df = CVPixelBufferGetPixelFormatType(dstBuf)
    // 吃「同 bit 深的 bi-planar」組合（10-bit 或 8-bit）；其他退 CI
    let tenBit: Set<OSType> = [
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ]
    let eightBit: Set<OSType> = [
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]
    let is10 = tenBit.contains(sf) && tenBit.contains(df)
    let is8 = eightBit.contains(sf) && eightBit.contains(df)
    guard is10 || is8,
      CVPixelBufferGetPlaneCount(srcBuf) == 2,
      CVPixelBufferGetPlaneCount(dstBuf) == 2
    else {
      if noteN < 3 {
        noteN += 1
        NSLog("[FastPath] blit 格式不合 src=%08x dst=%08x", sf, df)
      }
      return false
    }
    let yFmt: MTLPixelFormat = is10 ? .r16Unorm : .r8Unorm
    let cFmt: MTLPixelFormat = is10 ? .rg16Unorm : .rg8Unorm
    let pY = is10 ? pipeY : pipeY8
    let pC = is10 ? pipeC : pipeC8
    guard let sy = planeTex(srcBuf, 0, yFmt),
      let sc = planeTex(srcBuf, 1, cFmt),
      let dy = planeTex(dstBuf, 0, yFmt),
      let dc = planeTex(dstBuf, 1, cFmt),
      let pipeYx = pY, let pipeCx = pC,
      let cmd = queue.makeCommandBuffer()
    else { return false }
    var va = uvA
    var vb = uvB
    func pass(
      _ dst: MTLTexture, _ srcTex: MTLTexture,
      _ pipe: MTLRenderPipelineState
    ) -> Bool {
      let rp = MTLRenderPassDescriptor()
      rp.colorAttachments[0].texture = dst
      rp.colorAttachments[0].loadAction = .dontCare
      rp.colorAttachments[0].storeAction = .store
      guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else {
        return false
      }
      e.setRenderPipelineState(pipe)
      e.setVertexBytes(&va, length: 16, index: 0)
      e.setVertexBytes(&vb, length: 8, index: 1)
      e.setFragmentTexture(srcTex, index: 0)
      e.setFragmentSamplerState(sampler, index: 0)
      e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      e.endEncoding()
      return true
    }
    guard pass(dy, sy, pipeYx), pass(dc, sc, pipeCx) else {
      cmd.commit()
      return false
    }
    cmd.commit()
    cmd.waitUntilCompleted()
    return cmd.status == .completed
  }

  private func ovTexture(_ cg: CGImage, dev: MTLDevice) -> MTLTexture? {
    let key = ObjectIdentifier(cg)
    if let t = ovTexCache[key] { return t }
    guard let t = try? MTKTextureLoader(device: dev).newTexture(
        cgImage: cg, options: [MTKTextureLoader.Option.SRGB: false as NSNumber])
    else { return nil }
    ovTexCache[key] = t
    ovTexOrder.append(key)
    if ovTexOrder.count > 12 {
      ovTexCache.removeValue(forKey: ovTexOrder.removeFirst())
    }
    return t
  }

  /// SDR 快路：8-bit YUV 單層滿版 → BGRA，再把浮水印整版 PNG
  /// 疊上。回 false＝呼叫端走 CI 原路
  func sdrCompose(
    from srcBuf: CVPixelBuffer, to dstBuf: CVPixelBuffer,
    overlays: [CGImage],
    uvA: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 0),
    uvB: SIMD2<Float> = SIMD2<Float>(0, 1)
  ) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard setUp(), let queue = queue, let sampler = sampler,
      let dev = device, let pYUV = pipeYUVBGRA, let pOv = pipeOv
    else { return false }
    let sf = CVPixelBufferGetPixelFormatType(srcBuf)
    let df = CVPixelBufferGetPixelFormatType(dstBuf)
    let full = sf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    guard df == kCVPixelFormatType_32BGRA,
      sf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || full,
      CVPixelBufferGetPlaneCount(srcBuf) == 2
    else {
      if noteN < 3 {
        noteN += 1
        NSLog("[FastPath] sdr 格式不合 src=%08x dst=%08x", sf, df)
      }
      return false
    }
    // 來源若標 HLG/PQ（HDR 原檔期）退 CI：快路不做色調映射
    if let tf = CVBufferGetAttachment(
      srcBuf, kCVImageBufferTransferFunctionKey, nil)?
      .takeUnretainedValue() as? String,
      tf == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        || tf == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    {
      return false
    }
    var dcv: CVMetalTexture?
    let dw = CVPixelBufferGetWidth(dstBuf)
    let dh = CVPixelBufferGetHeight(dstBuf)
    guard let cache = cache,
      CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, cache, dstBuf, nil, .bgra8Unorm, dw, dh, 0,
        &dcv) == kCVReturnSuccess, let dcv = dcv,
      let dtex = CVMetalTextureGetTexture(dcv),
      let sy = planeTex(srcBuf, 0, .r8Unorm),
      let sc = planeTex(srcBuf, 1, .rg8Unorm),
      let cmd = queue.makeCommandBuffer()
    else { return false }
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = dtex
    rp.colorAttachments[0].loadAction = .dontCare
    rp.colorAttachments[0].storeAction = .store
    guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else {
      return false
    }
    var fr: Float = full ? 1 : 0
    var va = uvA
    var vb = uvB
    var idA = SIMD4<Float>(0, 0, 1, 0)
    var idB = SIMD2<Float>(0, 1)
    e.setRenderPipelineState(pYUV)
    e.setVertexBytes(&va, length: 16, index: 0)
    e.setVertexBytes(&vb, length: 8, index: 1)
    e.setFragmentTexture(sy, index: 0)
    e.setFragmentTexture(sc, index: 1)
    e.setFragmentBytes(&fr, length: 4, index: 0)
    e.setFragmentSamplerState(sampler, index: 0)
    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    for cg in overlays {
      guard let t = ovTexture(cg, dev: dev) else { continue }
      e.setRenderPipelineState(pOv)
      e.setVertexBytes(&idA, length: 16, index: 0)
      e.setVertexBytes(&idB, length: 8, index: 1)
      e.setFragmentTexture(t, index: 0)
      e.setFragmentSamplerState(sampler, index: 0)
      e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    e.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    return cmd.status == .completed
  }
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
    registrar.register(MetalViewFactory(), withId: "markcut/metal_view")
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
        // 收早了前面那層還指著它，就是使用者看到的閃黑。
        // 順便告訴 Dart「新合成真的顯示了」——HDR 預覽的 Flutter 版
        // 浮水印要等這一刻才藏（早藏＝舊畫面還在、浮水印憑空消失）
        PlayerHosts.shared.use(p.player) {
          old?.dispose()
          DispatchQueue.main.async {
            channel.invokeMethod("compVisible", arguments: nil)
          }
        }
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
      case "mbuild":
        // Metal 預覽引擎（滑動/暫停接管）：換佈局。組不了回 false，
        // Dart 端照舊走現有路徑
        guard let a = call.arguments as? [String: Any],
          let ls = a["layers"] as? [[String: Any]]
        else {
          result(false)
          return
        }
        let specs: [MetalLayerSpec] = ls.compactMap { m in
          guard let path = m["path"] as? String else { return nil }
          return MetalLayerSpec(
            id: m["id"] as? Int ?? 0,
            path: path,
            offset: m["offset"] as? Double ?? 0,
            end: m["end"] as? Double ?? 0,
            trimStart: m["trimStart"] as? Double ?? 0,
            speed: m["speed"] as? Double ?? 1,
            z: m["z"] as? Int ?? 0,
            px: m["px"] as? Double ?? 0.5,
            py: m["py"] as? Double ?? 0.5,
            scale: m["scale"] as? Double ?? 1,
            mirror: m["mirror"] as? Bool ?? false,
            rotation: m["rotation"] as? Double ?? 0,
            opacity: m["opacity"] as? Double ?? 1,
            fadeIn: m["fadeIn"] as? Double ?? 0,
            fadeOut: m["fadeOut"] as? Double ?? 0,
            crop: m["crop"] as? [Double],
            srcW: m["srcW"] as? Double ?? 16,
            srcH: m["srcH"] as? Double ?? 9,
            color: m["color"] as? [Double],
            proxy: m["proxy"] as? Bool ?? false)
        }
        let stillSpecs: [MetalStillSpec] =
          ((a["stills"] as? [[String: Any]]) ?? []).compactMap { m in
            guard let path = m["path"] as? String else { return nil }
            return MetalStillSpec(
              path: path,
              start: m["start"] as? Double ?? 0,
              end: m["end"] as? Double ?? 0,
              z: m["track"] as? Int ?? 0,
              px: m["px"] as? Double ?? 0.5,
              py: m["py"] as? Double ?? 0.5,
              scale: m["scale"] as? Double ?? 1,
              mirror: m["mirror"] as? Bool ?? false,
              rotation: m["rotation"] as? Double ?? 0,
              opacity: m["opacity"] as? Double ?? 1,
              fadeIn: m["fadeIn"] as? Double ?? 0,
              fadeOut: m["fadeOut"] as? Double ?? 0,
              crop: m["crop"] as? [Double],
              gif: m["gif"] as? Bool ?? false,
              hasColor: (m["color"] as? [Double]) != nil,
              color: m["color"] as? [Double])
          }
        result(
          MetalPreviewEngine.shared.build(
            canvasW: a["w"] as? Double ?? 1080,
            canvasH: a["h"] as? Double ?? 1920,
            hdr: a["hdr"] as? Bool ?? false,
            specs: specs,
            stillSpecs: stillSpecs,
            mosaicMaps: (a["mosaics"] as? [[String: Any]]) ?? []))
      case "finfo":
        // 檔案格式/色彩標籤（取樣全零查因、成品驗證用）
        result(mcFileInfo((call.arguments as? String) ?? ""))
      case "sampleOut":
        // 成品檔抽格取樣：預覽=輸出的數字證據
        if let a = call.arguments as? [String: Any],
          let path = a["path"] as? String
        {
          DispatchQueue.global(qos: .utility).async {
            let r = mcSampleFile(path)
            DispatchQueue.main.async { result(r) }
          }
        } else {
          result("?")
        }
      case "mshow":
        MetalPreviewEngine.shared.show(call.arguments as? Bool ?? false)
        result(nil)
      case "mseek":
        MetalPreviewEngine.shared.seek(call.arguments as? Double ?? 0)
        result(nil)
      case "mplay":
        // 播放接管：引擎自己的時鐘＋每軌 pump 起播。
        // 佈局沒建成回 false，Dart 照舊讓合成播放器出畫面
        result(
          MetalPreviewEngine.shared.play(call.arguments as? Double ?? 0))
      case "reattach":
        PlayerHosts.shared.reassert()
        result(nil)
      case "mstop":
        result(MetalPreviewEngine.shared.stop())
      case "mpark":
        MetalPreviewEngine.shared.park()
        result(nil)
      case "mstats":
        result(MetalPreviewEngine.shared.statsReport())
      case "mready":
        result(
          MetalPreviewEngine.shared.readyAt(
            call.arguments as? Double ?? 0))
      case "mgrab":
        // 數值法庭：離屏渲染回讀線性值（驗色用，跟顯示器無關）
        result(
          MetalPreviewEngine.shared.grab(call.arguments as? Double ?? 0))
      case "mdispose":
        MetalPreviewEngine.shared.disposeAll()
        result(nil)
      case "setXform":
        // 捏合/拖曳中的即時變形。走「合成器每一格直接讀的靜態參數」
        // ——之前每次更新都重產 videoComposition 換上，AVFoundation
        // 吞不了 30 次/秒（實測回報：素材落後框框、縮放不即時）。
        // CI 沒掛的簡單合成：第一次先帶覆寫重產一次 vc 掛上 CI 路，
        // 之後同樣走靜態參數
        guard let a = call.arguments as? [String: Any], let p = self.comp
        else {
          result(false)
          return
        }
        if a["clear"] as? Bool ?? false {
          CIExportCompositor.setLiveXform(nil)
          result(true)
          return
        }
        let ov = CompLiveXform(
          z: a["z"] as? Int ?? 0,
          start: a["start"] as? Double ?? 0,
          scale: a["scale"] as? Double ?? 1,
          px: a["px"] as? Double ?? 0.5,
          py: a["py"] as? Double ?? 0.5,
          rotation: a["rotation"] as? Double ?? 0)
        CIExportCompositor.setLiveXform(ov)
        if p.liveCIOn {
          p.nudgeRedrawIfPaused()
          result(true)
        } else {
          result(p.applyXform(ov))
        }
      case "setOvXform":
        // 浮水印部件的即時幾何（拖曳/縮放/旋轉）：改靜態參數＋催一格
        // 重畫，PNG 不重畫、合成不重建——跟手的關鍵。
        // items＝「目前所有偏離基準的部件」整包（見 setLiveOvs）
        guard let a = call.arguments as? [String: Any], let p = self.comp,
          p.wmLive, let items = a["items"] as? [[String: Any]]
        else {
          result(false)
          return
        }
        CIExportCompositor.setLiveOvs(
          items.compactMap { m in
            guard let oid = m["id"] as? String else { return nil }
            return CompLiveOv(
              id: oid,
              x: m["x"] as? Double ?? 0.5,
              y: m["y"] as? Double ?? 0.5,
              scale: m["scale"] as? Double ?? 1,
              rot: m["rot"] as? Double ?? 0)
          })
        p.nudgeRedrawIfPaused()
        result(true)
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
        // 差量跟新基準同包到、同一輪主執行緒套用完——分兩發送的話
        // 引擎會在中間畫出「新圖×舊差量」的爆閃格（實機 161 抖動）
        if let lv = (call.arguments as? [String: Any])?["live"]
          as? [[String: Any]]
        {
          CIExportCompositor.setLiveOvs(
            lv.compactMap { m in
              guard let oid = m["id"] as? String else { return nil }
              return CompLiveOv(
                id: oid,
                x: m["x"] as? Double ?? 0.5,
                y: m["y"] as? Double ?? 0.5,
                scale: m["scale"] as? Double ?? 1,
                rot: m["rot"] as? Double ?? 0)
            })
        }
        // 暫停中換清單要逼播放器重畫這一格：光 seek 回同一個時間點
        // 會被當 no-op（實測回報：打字改浮水印、預覽完全不動）。
        // CI 掛著＝擺動半格催重畫就夠；沒掛才重產 vc
        if p.liveCIOn {
          p.nudgeRedrawIfPaused()
        } else if p.player.rate == 0 {
          _ = p.applyXform(nil)
        }
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
      case "vtracks":
        self.comp?.setVideoTracksEnabled(
          (call.arguments as? Bool) ?? true)
        result(nil)
      case "takeover":
        self.comp?.setTakeover((call.arguments as? Bool) ?? false)
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

  /// 前面那層是不是真的綁在現役播放器上（診斷用）
  var bound: Bool {
    let vs = views.allObjects
    if vs.isEmpty { return true }
    return vs.allSatisfy { $0.front.player === current }
  }

  /// 重新確認綁定：翻面過程被打斷、或視圖重掛時序沒對上，
  /// 前面那層會留在「已經被收掉的舊播放器」上＝畫面永久黑。
  /// 播放前呼叫一次，冪等、零成本（已經對的就不動）
  func reassert() {
    guard let p = current else { return }
    for v in views.allObjects where v.front.player !== p {
      v.front.player = p
      NSLog("[PlayerHosts] 圖層重新綁定（前層指著舊播放器）")
    }
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
/// 預覽合成裡的一段畫面（一個時間軸片段落在某條合成軌上）。
/// 檔案層級是因為即時變形的重產閉包（vcRegen）要存在屬性上
private struct CompSeg {
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

/// 浮水印部件的即時幾何覆寫（拖曳/縮放/旋轉），絕對值：
/// 原生端跟烘進 PNG 的基準（bx/by/bs/br）算差量，每一格直接套。
/// 內容（字/色）沒變就不用重畫 PNG——這才追得上手指
struct CompLiveOv {
  let id: String
  let x: Double
  let y: Double
  let scale: Double
  let rot: Double
}

/// 捏合/拖曳中的即時變形覆寫：z＝軌道編號、start＝片段在時間軸的開頭
/// （兩個一起才對得到「哪一段」——同一軌可以有很多片段）
struct CompLiveXform {
  let z: Int
  let start: Double
  let scale: Double
  let px: Double
  let py: Double
  let rotation: Double
}

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

  /// 即時變形：用組建時留下的材料重產一份 videoComposition。
  /// 重建合成最貴的是拆插軌道＋換播放器（要等新畫面上檔）；
  /// 片段的縮放/位移/旋轉只活在 vc 的變形指令裡——捏合中每次
  /// 只換 vc（同一個 item、不閃），放手才真正重組烘定。
  /// 數學跟烘定走同一段程式碼，放手不會跳位
  private var vcRegen: ((CompLiveXform?) -> AVMutableVideoComposition)?

  /// 現役的 videoComposition 是不是走「預覽 CI 合成器」——是的話
  /// 即時變形/疊加物只要改靜態參數＋催一格重畫，零重建
  private(set) var liveCIOn = false

  /// 這一版組建算出來的 needsCI（applyXform 重產 vc 時要知道
  /// 換回無覆寫版之後 CI 還在不在）
  var builtNeedsCI = false

  /// 暫停中催播放器重畫這一格：往同一個時間 seek 會被當 no-op，
  /// 改成在 ±1 個時間刻（1.7ms）之間來回擺——位置看不出差別、
  /// 不累積漂移，每次都真的重組。
  ///
  /// 兩條規矩（實測回報「滑動中畫面不動、放開才跳」的根）：
  /// 1. 使用者的拖曳 seek 進行中「不催」——那發 seek 完成時本來
  ///    就會用最新的靜態參數重組這一格；催下去反而把使用者的
  ///    seek 蓋回原地，預覽就凍住了
  /// 2. 自己也排隊：一發催在跑就記 pending，跑完再補一發，
  ///    不對播放器灌併發 seek
  private var nudgeFlip = false
  private var nudging = false
  private var nudgePending = false
  func nudgeRedrawIfPaused() {
    guard player.rate == 0 else { return }
    if seeking || seekTarget.isValid { return }
    if nudging {
      nudgePending = true
      return
    }
    nudging = true
    nudgeFlip.toggle()
    let eps = CMTime(value: nudgeFlip ? 1 : -1, timescale: 600)
    var t = player.currentTime() + eps
    if t < .zero { t = CMTime(value: 1, timescale: 600) }
    player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self] _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.nudging = false
        if self.nudgePending {
          self.nudgePending = false
          self.nudgeRedrawIfPaused()
        }
      }
    }
  }

  /// 重產 vc 換上（不重建合成）。即時變形第一次在「CI 沒掛」的
  /// 合成上發動時走這裡把 CI 路掛起來；之後的更新走靜態參數。
  /// 回 false＝這份合成產不出 vc（呼叫端當沒這回事，照舊等重組）
  func applyXform(_ ov: CompLiveXform?) -> Bool {
    guard let regen = vcRegen, let item = player.currentItem else {
      return false
    }
    item.videoComposition = regen(ov)
    liveCIOn = ov != nil || builtNeedsCI
    if player.rate == 0 {
      nudgeRedrawIfPaused()
    }
    return true
  }

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
    // 每一刻誰在上面、怎麼擺（CompSeg 移到檔案層級：即時變形的
    // 重產閉包要存在屬性上，區域型別存不了）
    var segments: [CompSeg] = []
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
        CompSeg(
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

    // 注意：這一段不再被 needsVC 擋——沒掛 vc 的簡單合成也要備好
    // 「重產 vc」的材料（vcRegen）：捏合那一刻才臨時掛上去做即時變形
    if size.width > 1, size.height > 1 {
      // 預覽用的合成不需要原始解析度：手機螢幕短邊不到 1200，
      // 用 4K 去重畫每一格只是把解碼省下來的錢又花掉。這也是別家
      // 「預覽解析度」設定在做的事。
      // 自適應再降一級：HDR 半浮點與多軌逐格重畫都是平方成本
      //（實測診斷：4 層 HDR 最慢一格 963ms、拖曳 seek 九成 227ms），
      // 疊越重降越多——手機預覽尺寸下肉眼幾乎無感，seek 直接快一倍
      let heavy = hdrOut && anyHDR
      let many = vTracks.count >= 3
      let cap: CGFloat = heavy ? (many ? 720 : 900) : (many ? 900 : 1080)
      let shrink = min(1, cap / min(size.width, size.height))
      if shrink < 1 {
        size = CGSize(
          width: (size.width * shrink / 2).rounded() * 2,
          height: (size.height * shrink / 2).rounded() * 2)
      }
      // 逃逸閉包（vcRegen 存在屬性上）不能隱式抓 self：
      // 畫布尺寸先落地成區域常數，下面一律用它
      let canvas = size

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
        let k = min(canvas.width / dw, canvas.height / dh)
        t = t.concatenating(CGAffineTransform(scaleX: k, y: k))
          .concatenating(
            CGAffineTransform(
              translationX: (canvas.width - dw * k) / 2,
              y: (canvas.height - dh * k) / 2))
        let u = CGFloat(st["scale"] as? Double ?? 1)
        let spx = st["px"] as? Double ?? 0.5
        let spy = st["py"] as? Double ?? 0.5
        if abs(Double(u) - 1) > 0.001 || abs(spx - 0.5) > 0.001
          || abs(spy - 0.5) > 0.001
        {
          t = t
            .concatenating(
              CGAffineTransform(
                translationX: -canvas.width / 2, y: -canvas.height / 2)
            )
            .concatenating(CGAffineTransform(scaleX: u, y: u))
            .concatenating(
              CGAffineTransform(
                translationX: canvas.width / 2 + CGFloat(spx - 0.5)
                  * canvas.width,
                y: canvas.height / 2 + CGFloat(spy - 0.5) * canvas.height))
        }
        let flipSrc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: dh)
        let flipCanvas = CGAffineTransform(
          a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height)
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
      func fitTransform(_ seg: CompSeg) -> CGAffineTransform? {
        let disp = seg.size.applying(seg.transform)
        let dw = abs(disp.width)
        let dh = abs(disp.height)
        guard dw > 1, dh > 1 else { return nil }
        let k = min(canvas.width / dw, canvas.height / dh)
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
        return t
      }

      /// 一段畫面在 [t] 這一刻該有多不透明（0~1）。淡入淡出是線性的
      func opacity(_ seg: CompSeg, at t: Double) -> Double {
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
      // CI 的材料一律先備好：就算這一版不走 CI（needsCI false），
      // 捏合中出現「旋轉」會臨時切到 CI 路（標準 layer instruction
      // 畫不了旋轉）。馬賽克逐格打碼、濃度柔邊顏色的數學跟成品
      // 一字不差（CIExportCompositor），HDR 來源 toneMapHDRtoSDR
      // 跟相簿同一條曲線
      let ciMosaics = mosaics.compactMap { CIMosaicSpec($0, canvas: canvas) }
      // 最後一個可見片段結束的時間：之後的區間就是「片尾」
      let lastShow = segments.map { $0.range.end.seconds }.max() ?? 0
      // 產一份 videoComposition（可帶捏合中的即時變形覆寫 ov）。
      // 組建與即時變形共用同一段數學：放手烘定不會跳位。
      // 閉包刻意不碰 self（buildInfo/wmLive 都在外面做）——
      // vcRegen 存在屬性上，碰了 self 就是保留循環
      let makeVC: (CompLiveXform?) -> AVMutableVideoComposition = { ov in
        var segs = segments
        if let ov = ov {
          for i in segs.indices
          where segs[i].layer == ov.z
            && abs(segs[i].range.start.seconds - ov.start) < 0.02
          {
            segs[i].userScale = ov.scale
            segs[i].px = ov.px
            segs[i].py = ov.py
            segs[i].rotation = ov.rotation
          }
        }
        let vc = AVMutableVideoComposition()
        vc.renderSize = canvas
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
        // 即時變形要 CI 才吃得到（標準 layer instruction 不會逐格
        // 問我們）：有覆寫一律走 CI 路（軌道沒為 CI 鋪滿，接縫可能
        // 用上一格頂一下；放手重組就正確）
        let useCI = needsCI || ov != nil
        if useCI {
        var proto: [(a: CMTime, b: CMTime, layers: [CILayerSpec], hold: Bool)] =
          []
        for i in 0..<(marks.count - 1) {
          let a = marks[i]
          let b = marks[i + 1]
          let mid = (a.seconds + b.seconds) / 2
          let here = segs.filter {
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
                opacity: seg.opacity, z: seg.layer,
                // 即時變形的差量基準（見 CILayerSpec.uScale）
                uScale: seg.userScale, uPx: seg.px, uPy: seg.py)
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
          proto.append((
            a: a, b: b, layers: layers,
            hold: layers.isEmpty && ((b - a).seconds < 0.12 || tail)
          ))
        }
        // 預捲窗：這一段「用到的軌」＋往後 1.5 秒內會進場的軌。
        // 原本每段都列全部軌道（解碼器全程熱機、接縫不冷啟動），
        // 代價是 5 軌專案在單軌區間 seek 也要等 5 顆解碼器供格——
        // 就是「多部影片後滑動就定位很久」（實測回報）。
        // 改成只看近未來：接縫照樣提前 1.5 秒熱機，seek 只等該等的
        var built: [CIExportInstruction] = []
        for (i, pi) in proto.enumerated() {
          var ids = Set(
            pi.layers.compactMap { l -> CMPersistentTrackID? in
              l.trackID == kCMPersistentTrackID_Invalid ? nil : l.trackID
            })
          let horizon = pi.b.seconds + 1.5
          for pj in proto.dropFirst(i + 1) {
            if pj.a.seconds >= horizon { break }
            for l in pj.layers
            where l.trackID != kCMPersistentTrackID_Invalid {
              ids.insert(l.trackID)
            }
          }
          built.append(
            CIExportInstruction(
              timeRange: CMTimeRange(start: pi.a, end: pi.b),
              layers: pi.layers, mosaics: ciMosaics, overlays: [],
              prerollTrackIDs: ids.sorted().map { NSNumber(value: $0) },
              holdIfEmpty: pi.hold))
        }
        // HDR 輸出模式掛「HDR 預覽」合成器：同一套疊圖、不做色調
        // 映射、輸出走 HLG 管線（跟 HDR 匯出同一顆），另外讀即時
        // 疊加物——浮水印/文字烘在 HDR 畫面上用 EDR 顯示，
        // 白色才是真的白（跟成品同一段提亮程式碼）
        vc.customVideoCompositorClass =
          hdrOut && anyHDR
          ? CIPreviewCompositorHDR.self : CIPreviewCompositorSDR.self
        vc.instructions = built
      } else {
      var instructions: [AVMutableVideoCompositionInstruction] = []
      for i in 0..<(marks.count - 1) {
        let a = marks[i]
        let b = marks[i + 1]
        let mid = (a.seconds + b.seconds) / 2
        let here = segs.filter {
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
      }
        return vc
      }
      vcRegen = makeVC
      // HDR 預覽的即時疊加物（浮水印/文字）：跟原本一樣只在
      // 「CI 有掛」時收清單（needsCI false＝沒有合成器在讀）
      if hdrOut && anyHDR && needsCI {
        CIExportCompositor.setPreviewOverlays(
          overlays.compactMap { CIOverlaySpec($0, canvas: canvas) })
        ciCanvas = canvas
        wmLive = true
      }
      builtNeedsCI = needsCI
      if needsVC {
        let vc = makeVC(nil)
        liveCIOn = needsCI
        buildInfo["CI"] = needsCI
        buildInfo["指令"] = vc.instructions.map { raw -> String in
          let head =
            "\(String(format: "%.2f", raw.timeRange.start.seconds))~"
            + "\(String(format: "%.2f", raw.timeRange.end.seconds))"
          if let ci = raw as? CIExportInstruction {
            return head + " 層z=\(ci.layers.map { $0.z })"
          }
          let n =
            (raw as? AVMutableVideoCompositionInstruction)?
            .layerInstructions.count ?? 0
          return head + " 層數\(n)"
        }.joined(separator: "；")
        // 交出去之前先讓 AVFoundation 自己驗一遍。壞掉的合成不會丟例外，
        // 只會安靜地變成一片黑——那正是「拉到新軌道預覽就消失」
        let v = VCValidator()
        if !vc.isValid(
          for: comp,
          timeRange: CMTimeRange(start: .zero, duration: comp.duration),
          validationDelegate: v)
        {
          buildError =
            "合成指令不合法：" + (v.problems.first ?? "沒有細節")
            + (v.problems.count > 1 ? "（共 \(v.problems.count) 處）" : "")
          return false
        }
        item.videoComposition = vc
      }
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
    // 播放接管的「音訊分身」：同一份合成拷貝後拆掉視訊軌，
    // 從建好那一刻就是純音訊。播放接管＝分身出聲＋主播放器
    // 原地凍結——管線永不拆裝（拆裝 videoComposition 在實機上
    // 會重建合成器：暫停黑畫面、時鐘亂跳針，build 131 實測）
    if let acomp = comp.mutableCopy() as? AVMutableComposition {
      for tr in acomp.tracks(withMediaType: .video) {
        acomp.removeTrack(tr)
      }
      let aItem = AVPlayerItem(asset: acomp)
      aItem.audioMix = mix
      audioPlayer.replaceCurrentItem(with: aItem)
      audioPlayer.automaticallyWaitsToMinimizeStalling = false
      audioPlayer.isMuted = player.isMuted
    }

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

  // ===== 播放接管（音訊分身）=====
  private let audioPlayer = AVPlayer()
  private(set) var takeover = false

  /// 時鐘偵探：接管/讓位後每 100ms 錄一點（音訊率/音訊時間/引擎
  /// 時鐘），共 15 點——「暫停再播跳動感」直接變成數字曲線
  private var clockTrace: [String] = []
  private var clockTimer: Timer?

  /// 引擎側塞時鐘事件（對表等）——static ring，dump 時合併
  static let clockEvLock = NSLock()
  static var clockEvents: [String] = []
  static func noteClockEvent(_ e: String) {
    clockEvLock.lock()
    clockEvents.append(e)
    if clockEvents.count > 12 { clockEvents.removeFirst(6) }
    clockEvLock.unlock()
  }

  private func traceClocks(_ tag: String) {
    clockTimer?.invalidate()
    var n = 0
    clockTrace.append("[\(tag)]")
    if clockTrace.count > 80 { clockTrace.removeFirst(40) }
    let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] tm in
      guard let self = self else {
        tm.invalidate()
        return
      }
      n += 1
      let line = String(
        format: "%d0:率%.2f 音%.2f 擎%.2f", n,
        self.audioPlayer.rate,
        self.audioPlayer.currentTime().seconds,
        MetalPreviewEngine.shared.clockT)
      self.clockTrace.append(line)
      if n >= 15 { tm.invalidate() }
    }
    RunLoop.main.add(t, forMode: .common)
    clockTimer = t
  }

  var clockTraceDump: String {
    Self.clockEvLock.lock()
    let ev = Self.clockEvents.joined(separator: " ")
    Self.clockEvLock.unlock()
    return (ev.isEmpty ? "" : ev + "\n") + clockTrace.joined(separator: "\n")
  }

  /// 分身有沒有真的聲音可播（無音軌素材＝空分身，時鐘改用引擎）
  private var audioValid = false

  /// 播放接管：畫面歸 Metal 引擎、聲音與時鐘歸音訊分身，
  /// 主播放器原地凍結（合成管線完整保留，暫停畫面隨叫隨到）
  func setTakeover(_ on: Bool) {
    takeover = on
    traceClocks(on ? "接管" : "讓位")
    if on {
      audioValid =
        (audioPlayer.currentItem?.duration.seconds ?? 0) > 0.05
      player.pause()
      let t = player.currentTime()
      audioPlayer.seek(
        to: t, toleranceBefore: .zero, toleranceAfter: .zero
      ) { [weak self] _ in
        guard let self = self, self.takeover else { return }
        self.audioPlayer.playImmediately(atRate: self.targetRate)
        // 聲音從這一刻起跑：引擎時鐘對到同一點，音畫同步起步
        DispatchQueue.main.async {
          guard self.takeover else { return }
          MetalPreviewEngine.shared.rebase(
            to: self.audioPlayer.currentTime().seconds)
        }
      }
    } else {
      audioPlayer.pause()
    }
  }

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
    if takeover {
      audioPlayer.playImmediately(atRate: targetRate)
      return
    }
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
    audioPlayer.pause()
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
    if takeover {
      if audioPlayer.rate != 0 {
        audioPlayer.playImmediately(atRate: targetRate)
      }
      return
    }
    if player.rate != 0 { player.playImmediately(atRate: targetRate) }
  }

  /// 預覽靜音。走 AVPlayer 自己的 isMuted，不動合成裡烘好的音量——
  /// 改音量參數要整份重組，按一下靜音就會卡一拍
  func setMuted(_ m: Bool) {
    player.isMuted = m
    audioPlayer.isMuted = m
  }

  /// 讓位期間收起來的 videoComposition（恢復時原樣掛回）
  private var parkedVC: AVVideoComposition?

  /// 專業 AV 分離：引擎接管播放時「整條視訊管線」停工——
  /// videoComposition 先撤（不撤的話 CI 合成器照樣每格開工，
  /// 軌又停用＝拿不到影格→缺格風暴＋保底重播狂燒 CPU，實測
  /// build 130「軌1 給不出影格×60」就是它），再停用視訊軌
  ///（解碼器 100% 讓給引擎）。恢復時原樣掛回、即時、不重建
  func setVideoTracksEnabled(_ on: Bool) {
    guard let item = player.currentItem else { return }
    if on {
      for tr in item.tracks
      where tr.assetTrack?.mediaType == .video {
        tr.isEnabled = true
      }
      if let vc = parkedVC {
        item.videoComposition = vc
        parkedVC = nil
      }
    } else {
      if item.videoComposition != nil {
        parkedVC = item.videoComposition
        item.videoComposition = nil
      }
      for tr in item.tracks
      where tr.assetTrack?.mediaType == .video {
        tr.isEnabled = false
      }
    }
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

  var positionMs: Int {
    // 播放接管中：有聲＝音訊分身當時鐘；無音軌素材＝分身是空的
    //（時間永遠 0），改用引擎的主機時鐘
    if takeover {
      // 分身還沒真的轉起來（seek+起播要 100~300ms）前用引擎時鐘：
      // 用停滯的音訊時間會讓位置「停→本地推進→被拉回→跳前」，
      // 就是實機「暫停再播放有跳動感」（140 回報）。轉起來再交棒
      // ——兩個時鐘此時已對齊（分身從引擎位置起播），無縫
      return audioValid && audioPlayer.rate > 0.01
        ? Int(audioPlayer.currentTime().seconds * 1000)
        : Int(MetalPreviewEngine.shared.clockT * 1000)
    }
    return Int(player.currentTime().seconds * 1000)
  }

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
    m["fastSkip"] = CIExportCompositor.stSkip
      .sorted { $0.value > $1.value }
      .map { "\($0.key)\($0.value)" }
      .joined(separator: "、")
    m["fastFrames"] =
      "快路\(CIExportCompositor.stFastFrames)/CI\(CIExportCompositor.stCIFrames)"
    m["ciWorstMs"] = CIExportCompositor.worstMs
    m["ciSlow"] = CIExportCompositor.slowFrames
    m["ciSupplyWorst"] = CIExportCompositor.worstSupplyMs
    m["ciSupplyGaps"] = CIExportCompositor.supplyGaps
    m["ciBurst"] = CIExportCompositor.burstGaps
      .map(String.init).joined(separator: ",")
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
    m["layerBound"] = PlayerHosts.shared.bound
    m["lumaProbe"] = CIExportCompositor.lumaProbe.joined(separator: "、")
    m["clockTrace"] = clockTraceDump
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
    // 重產閉包抓著整組合成軌，不放掉的話合成跟著這顆殭屍活著
    vcRegen = nil
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

// ============================================================
// Metal 預覽引擎（Phase 1：暫停與滑動）
//
// LAG 家族的終局解。AVFoundation 的合成播放器繼續負責「播放」
//（它播起來本來就穩），這顆引擎接管所有「互動」：滑動、暫停中
// 改參數——也就是延遲住的地方。
//
// 做法：每個可見片段一顆輕量 AVPlayer 當「供格幫浦」（各自
// tolerant seek、互不等待），影格以 64RGBAHalf（extended linear）
// 拉進 Metal 紋理，一個 render pass 疊合、CAMetalLayer EDR 顯示。
// 滑動＝先畫緩衝裡最近的格、解到更準的再補——零等待手感。
// 顏色數學（HDR 夾白＋疊加物提亮）從 CIExportCompositor 原封搬進
// shader，兩邊同一套。
//
// Phase 1 不畫馬賽克與墊底圖層（滑動的暫態省略）；
// 任何一步失敗都回報 unavailable，Dart 端自動退回現有路徑。
// ============================================================

/// 一個片段的供格幫浦：獨立 AVPlayer＋影格輸出，tolerant seek，
/// 拿得到就换新紋理、拿不到就沿用上一張（stale-while-refine）
final class MetalPump {
  let player = AVPlayer()
  private var output: AVPlayerItemVideoOutput?
  private(set) var ready = false
  private var lastSeek = -1.0
  var lastTexture: MTLTexture?

  /// 檔案的旋轉旗標（顯示要順時針轉幾度）與轉正後的顯示尺寸。
  /// iPhone 直式影片＝橫存＋90° 旗標；HDR 代理（HLG 直通）刻意
  /// 保留旗標不轉正——引擎不看旗標的話畫面就轉錯邊、比例爆炸
  ///（實測 build 127：「整個畫面爆炸 比例亂跑」的根因）
  private(set) var orient = 0
  private(set) var dispW = 0.0
  private(set) var dispH = 0.0

  /// 源的色彩標籤（輸出的 half 值保持源編碼，shader 按這個解）
  private(set) var isHLG = false
  private(set) var is2020 = false

  let path: String

  init(path: String) {
    self.path = path
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    if let tr = asset.tracks(withMediaType: .video).first {
      let t = tr.preferredTransform
      let d = tr.naturalSize.applying(t)
      dispW = abs(d.width)
      dispH = abs(d.height)
      if t.a == 0 && t.b == 1 && t.c == -1 {
        orient = 90
      } else if t.a == -1 && t.d == -1 {
        orient = 180
      } else if t.a == 0 && t.b == -1 && t.c == 1 {
        orient = 270
      }
      if let fdAny = tr.formatDescriptions.first {
        let fd = fdAny as! CMFormatDescription
        if let tf = CMFormatDescriptionGetExtension(
          fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
          as? String
        {
          isHLG =
            tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
              as String)
            || tf == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
              as String)
        }
        if let pr = CMFormatDescriptionGetExtension(
          fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
          as? String
        {
          is2020 =
            pr == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
        }
      }
    }
    let item = AVPlayerItem(asset: asset)
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(
        kCVPixelFormatType_64RGBAHalf),
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
    item.add(out)
    output = out
    player.isMuted = true
    // 本地密關鍵幀檔不需要「防斷流等待」——留著的話起播先緩衝
    // 幾秒才動（實測 build 130：「按播放先卡頓幾秒後面才順」）
    player.automaticallyWaitsToMinimizeStalling = false
    player.replaceCurrentItem(with: item)
  }

  /// item 還沒 ready 時被丟掉的 seek——ready 後第一次取樣補發。
  /// 沒有它，進場早期的 want 全部蒸發＝引擎亮起是黑畫布
  ///（build 129 實機「點浮水印畫面全黑」的根）
  private var pendingSeek: Double?

  /// 目標時間變超過半格才重新 seek（AVPlayer 自己會合併）。
  /// [coarse]＝快滑模式：容差無限大＝貼齊最近的關鍵幀，任何檔
  ///（4K 疏關鍵幀原檔也一樣）都是瞬間出圖——剪映「匯入完馬上
  /// 能滑」的做法就是這個；停手後呼叫端再補一發精確的
  func want(_ t: Double, coarse: Bool = false) {
    guard let item = player.currentItem else { return }
    if item.status == .readyToPlay { ready = true }
    guard ready else {
      pendingSeek = t
      return
    }
    // 只追最新目標，不把每一發都做完：手指每動一次就灌一發 seek，
    // AVPlayer 會排隊一發一發做，畫面永遠落在手指後面、停手才追上
    //（實機 155 回報）。中途那些位置使用者根本沒在看
    if abs(t - lastSeek) < (coarse ? 0.04 : 0.02) { return }
    lastSeek = t
    seekWanted = t
    seekCoarse = coarse
    if !seeking { chaseSeek() }
  }

  /// 進行中的 seek 與最新目標（見 want 的說明）
  private var seeking = false
  private var seekWanted: Double?
  private var seekCoarse = true

  private func chaseSeek() {
    guard let t = seekWanted, let _ = player.currentItem else {
      seeking = false
      return
    }
    seekWanted = nil
    seeking = true
    let tol = seekCoarse
      ? CMTime.positiveInfinity
      : CMTimeMakeWithSeconds(0.05, preferredTimescale: 600)
    player.seek(
      to: CMTime(seconds: t, preferredTimescale: 600),
      toleranceBefore: tol, toleranceAfter: tol
    ) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if self.seekWanted != nil {
          self.chaseSeek()  // 手指又動了，直接追最新的
        } else {
          self.seeking = false
        }
      }
    }
  }

  /// ready 之後把欠的 seek 補上（texture/playTexture 每次先問）
  private func flushPending() {
    if !ready, let item = player.currentItem,
      item.status == .readyToPlay
    {
      ready = true
    }
    guard ready, let p = pendingSeek else { return }
    pendingSeek = nil
    want(p)
  }

  /// 有新格就換上紋理；沒有就回傳上一張（可能是 nil＝還沒供過）
  func texture(at t: Double, cache: CVMetalTextureCache) -> MTLTexture? {
    flushPending()
    guard let out = output else { return lastTexture }
    let it = CMTime(seconds: t, preferredTimescale: 600)
    return sample(out, at: it, cache: cache)
  }

  // ===== 播放模式（播放接管）=====

  /// 目前的播放速率（0＝暫停）。engine 逐格管理，不重複下指令
  private(set) var playingRate = 0.0

  func play(rate: Double) {
    if abs(playingRate - rate) > 0.001 {
      playingRate = rate
      // playImmediately：現在有什麼就從什麼開始播，不等緩衝
      player.playImmediately(atRate: Float(rate))
    }
  }

  func pause() {
    if playingRate != 0 {
      playingRate = 0
      player.pause()
    }
  }

  /// 播放中的取樣：跟著主機時鐘拿「現在該顯示的那格」——
  /// AVPlayer 自己前進，60fps 逐格問有沒有新格
  func playTexture(cache: CVMetalTextureCache) -> MTLTexture? {
    flushPending()
    guard let out = output else { return lastTexture }
    let it = out.itemTime(forHostTime: CACurrentMediaTime())
    return sample(out, at: it, cache: cache)
  }

  /// 紋理與像素緩衝成對持有（防池回收覆寫，理由見 ClipReader.Held）
  private var heldBuf: CVPixelBuffer?
  private var heldCv: CVMetalTexture?

  private func sample(
    _ out: AVPlayerItemVideoOutput, at it: CMTime,
    cache: CVMetalTextureCache
  ) -> MTLTexture? {
    if out.hasNewPixelBuffer(forItemTime: it),
      let buf = out.copyPixelBuffer(forItemTime: it, itemTimeForDisplay: nil)
    {
      var cv: CVMetalTexture?
      let w = CVPixelBufferGetWidth(buf)
      let h = CVPixelBufferGetHeight(buf)
      if CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, cache, buf, nil, .rgba16Float, w, h, 0, &cv)
        == kCVReturnSuccess, let cv = cv, let tex = CVMetalTextureGetTexture(cv)
      {
        lastTexture = tex
        heldBuf = buf
        heldCv = cv
      }
    }
    return lastTexture
  }

  func dispose() {
    player.replaceCurrentItem(with: nil)
    lastTexture = nil
    heldBuf = nil
    heldCv = nil
  }
}

/// 確定性播放供格器：AVAssetReader 在背景執行緒順序硬解進
/// 幀佇列（帶來源時間戳、預解 4 格），渲染時鐘從佇列取「該顯示
/// 的那格」——晚了丟、早了等。沒有 AVPlayer 黑盒的緩衝／節奏／
/// seek 行為，播放供格完全確定（治本：pump 播放路的每一輪補丁
/// 都是在馴服黑盒的突發行為）
final class ClipReader {
  let path: String
  private var reader: AVAssetReader?
  private var out: AVAssetReaderTrackOutput?
  private let lock = NSLock()
  /// (來源秒, 影格)。佇列滿 4 就等，消費後解碼執行緒自動補
  private var queue: [(Double, CVPixelBuffer)] = []
  private var running = false
  private var finished = false
  /// 紋理與它的像素緩衝「成對持有」：AVAssetReader 的緩衝池只有
  /// 4 格、取出後立刻被下一格覆寫——只留 MTLTexture 不留 buffer，
  /// GPU 畫到的就是被覆寫的黑（實測 134：「一播放就黑掉」）。
  /// 留兩代：上一幀可能還在 GPU 手上
  private struct Held {
    let tex: MTLTexture
    let buf: CVPixelBuffer
    let cv: CVMetalTexture
  }
  /// 三代環形保留：CAMetalLayer 的 GPU 管線深度是 3 幀，
  /// 兩代在多軌高壓下第三幀還在 GPU 手上就被釋放回收＝黑/撕裂
  private var held: Held?
  private var heldRing: [Held] = []
  private var lastPts = -1.0
  /// 世代權杖：start() 每次 +1。舊解碼執行緒醒來對不上號就自行
  /// 收乾淨退出——沒有它，快速重啟時新 start 把 running 設回
  /// true，「舊執行緒以為自己還活著」→ 兩條執行緒同時對同一個
  /// AVAssetReaderTrackOutput 取樣（非執行緒安全）→ 閃退。
  /// 多軌 3 層 reader 頻繁開關時命中（實測 136：多軌會閃退）
  private var gen = 0
  /// 這一代 reader 起跑的主機時刻——重啟判定要先讓它暖身滿一秒
  private var startHost = 0.0
  /// SDR 來源（8-bit）解 32BGRA：記憶體砍半、色彩零損失。
  /// HDR 才用 64RGBAHalf（10-bit 要保留精度）。多 reader 全上
  /// half float 的話 3 層 ≈ +350MB，4GB 機種直接 jetsam（閃退）
  private var texFormat = MTLPixelFormat.rgba16Float
  /// 幾何與色彩標籤（解碼執行緒讀 track 填入）：播放路徑完全
  /// 不碰 pump——實機 137 播放全黑就是「reader 有格、但 render
  /// 先 guard pump 存在」，工作檔換路徑銷毀 pump 後整層被跳過
  private(set) var orient = 0
  private(set) var dispW = 0.0
  private(set) var dispH = 0.0
  private(set) var isHLG = false
  private(set) var is2020 = false
  private(set) var infoReady = false

  init(path: String) { self.path = path }

  /// 從 [srcT] 開始順序解碼（貼齊往前最近的可解點）。
  /// 開檔/建讀取器整套在解碼執行緒做——在主執行緒做的話，
  /// 起播與交界瞬間主執行緒卡 50~200ms（實測 134：引擎掉格 62）
  func start(at srcT: Double) {
    stop()
    lock.lock()
    gen += 1
    let g = gen
    running = true
    finished = false
    startHost = CACurrentMediaTime()
    lock.unlock()
    Thread.detachNewThread { [weak self] in
      self?.setupAndPump(at: srcT, gen: g)
    }
  }

  private func setupAndPump(at srcT: Double, gen g: Int) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let tr = asset.tracks(withMediaType: .video).first,
      let r = try? AVAssetReader(asset: asset)
    else {
      markDead(gen: g)
      return
    }
    // HDR/原色判定跟 pump 同一套（PQ 也算）；幾何一併讀齊——
    // 播放路徑要能不依賴 pump 獨立運作
    var hdr = false
    var p2020 = false
    if let fdAny = tr.formatDescriptions.first {
      let fd = fdAny as! CMFormatDescription
      if let tf = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
        as? String
      {
        hdr =
          tf == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
          || tf
            == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
      }
      if let pr = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
        as? String
      {
        p2020 = pr == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
      }
    }
    // 顯示尺寸＝naturalSize 過 preferredTransform 轉正（90°/270°
    // 寬高互換）——跟 pump 同一條算法。直接用 naturalSize 的話，
    // 帶旋轉 flag 的直式素材播放中被當橫的畫（實機 138 比例跑掉、
    // 暫停就正常＝暫停走 pump 幾何、播放走這裡）
    let xf = tr.preferredTransform
    let dsz = tr.naturalSize.applying(xf)
    var ori = 0
    if xf.a == 0 && xf.b == 1 && xf.c == -1 {
      ori = 90
    } else if xf.a == -1 && xf.d == -1 {
      ori = 180
    } else if xf.a == 0 && xf.b == -1 && xf.c == 1 {
      ori = 270
    }
    // 色彩語意與 shader 線性化管線共用，不另開 YUV 路
    let o = AVAssetReaderTrackOutput(
      track: tr,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(
          hdr ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA),
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ])
    o.alwaysCopiesSampleData = false
    guard r.canAdd(o) else {
      markDead(gen: g)
      return
    }
    r.add(o)
    // 從目標前 0.5s 起解、消費端丟到目標格：首幀正好是停格
    // 那一格（從目標起解的話首幀=目標後第一格，起播跳一格=抖）
    r.timeRange = CMTimeRange(
      start: CMTime(seconds: max(0, srcT - 0.5), preferredTimescale: 600),
      duration: .positiveInfinity)
    lock.lock()
    let go = running && gen == self.gen
    lock.unlock()
    guard go, r.startReading() else {
      markDead(gen: g)
      return
    }
    lock.lock()
    if gen == self.gen {
      reader = r
      out = o
      texFormat = hdr ? .rgba16Float : .bgra8Unorm
      isHLG = hdr
      is2020 = p2020
      orient = ori
      dispW = Double(abs(dsz.width))
      dispH = Double(abs(dsz.height))
      infoReady = true
      lock.unlock()
    } else {
      // 過期世代：別動共享狀態，自己收乾淨
      lock.unlock()
      r.cancelReading()
      return
    }
    pumpLoop(gen: g)
  }

  /// 只有「自己還是現任世代」才准把共享旗標標成死掉
  private func markDead(gen g: Int) {
    lock.lock()
    if gen == self.gen {
      running = false
      finished = true
    }
    lock.unlock()
  }

  private func pumpLoop(gen g: Int) {
    while true {
      lock.lock()
      let go = running && gen == g
      let full = queue.count >= 3
      lock.unlock()
      if !go { return }
      if full {
        usleep(4000)
        continue
      }
      lock.lock()
      let oo = gen == g ? out : nil
      lock.unlock()
      guard let o = oo, let sb = o.copyNextSampleBuffer(),
        let buf = CMSampleBufferGetImageBuffer(sb)
      else {
        lock.lock()
        let r = reader
        lock.unlock()
        NSLog(
          "[ClipReader] 斷 status=%d err=%@ path=…%@",
          r?.status.rawValue ?? -1,
          r?.error.map(String.init(describing:)) ?? "無",
          String(path.suffix(24)))
        markDead(gen: g)
        return
      }
      let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
      lock.lock()
      if gen == g { queue.append((pts, buf)) }
      lock.unlock()
    }
  }

  /// 渲染時鐘來取「來源時刻 [srcT] 該顯示的那格」：把已過期的
  /// 丟掉、留最新不超前的。佇列空＝解碼沒跟上（回上一張）
  func frame(at srcT: Double, cache: CVMetalTextureCache) -> MTLTexture? {
    lock.lock()
    var picked: CVPixelBuffer?
    while let first = queue.first, first.0 <= srcT + 0.017 {
      picked = first.1
      lastPts = first.0
      queue.removeFirst()
    }
    lock.unlock()
    if let buf = picked {
      var cv: CVMetalTexture?
      let w = CVPixelBufferGetWidth(buf)
      let h = CVPixelBufferGetHeight(buf)
      lock.lock()
      let fmt = texFormat
      lock.unlock()
      if CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, cache, buf, nil, fmt, w, h, 0, &cv)
        == kCVReturnSuccess, let cv = cv,
        let tex = CVMetalTextureGetTexture(cv)
      {
        lock.lock()
        if let h = held { heldRing.append(h) }
        if heldRing.count > 3 { heldRing.removeFirst() }
        held = Held(tex: tex, buf: buf, cv: cv)
        lock.unlock()
      }
    }
    lock.lock()
    defer { lock.unlock() }
    return held?.tex
  }

  /// 目前顯示到的來源時刻（滑動重啟判定用；-1=還沒出過圖）
  var lastShown: Double {
    lock.lock()
    defer { lock.unlock() }
    return lastPts
  }

  /// 滑動供格：跟 frame(at:) 一樣消費佇列，但顯示中的格離目標
  /// 超過 [tol] 就回 nil——讓呼叫端走 pump 保底，不讓舊格冒充
  /// 新畫面。容差要分兩檔：滑動中 0.3（解碼追手指，差一點沒關係）、
  /// 靜止 0.025（暫停上台時解碼器從目標前 0.5s 起解，容差放寬＝
  /// 螢幕肉眼可見地「快轉滾」到定點——實機 157 按暫停畫面晃動）
  func scrubFrame(at srcT: Double, tol: Double, cache: CVMetalTextureCache)
    -> MTLTexture?
  {
    let tex = frame(at: srcT, cache: cache)
    lock.lock()
    let shown = lastPts
    lock.unlock()
    guard tex != nil, shown >= 0, abs(shown - srcT) <= tol else { return nil }
    return tex
  }

  /// 佇列裡已備好的最遠時刻（交界預捲檢查用）
  var bufferedTo: Double {
    lock.lock()
    defer { lock.unlock() }
    return queue.last?.0 ?? lastPts
  }

  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running || !queue.isEmpty
  }

  /// 這一代跑了多久（秒）
  var age: Double {
    lock.lock()
    defer { lock.unlock() }
    return CACurrentMediaTime() - startHost
  }

  var lastTexture: MTLTexture? {
    lock.lock()
    defer { lock.unlock() }
    return held?.tex
  }

  func stop() {
    lock.lock()
    running = false
    queue.removeAll()
    held = nil
    heldRing.removeAll()
    let r = reader
    reader = nil
    out = nil
    lock.unlock()
    r?.cancelReading()
  }
}

/// 引擎收的一層（幾何跟合成器同一套欄位；時間都是時間軸秒）
struct MetalLayerSpec {
  let id: Int
  let path: String
  let offset: Double
  let end: Double
  let trimStart: Double
  let speed: Double
  let z: Int
  // px/py/scale/rotation 是 var：拖曳中被即時變形（liveXf）逐格蓋過
  var px: Double
  var py: Double
  var scale: Double
  let mirror: Bool
  var rotation: Double
  let opacity: Double
  let fadeIn: Double
  let fadeOut: Double
  let crop: [Double]?
  let srcW: Double
  let srcH: Double
  /// 色彩濾鏡（5x4 矩陣 20 元素，跟 CI applyColor 同格式）
  var color: [Double]? = nil
  /// 吃的是代理檔（工作檔/HDR 代理）。原檔（4K）只准滑動停格，
  /// 持續播放的浮點輸出頻寬撐不起——播放接管要求全代理
  var proxy = false
}

/// 引擎收的一張靜態圖層（圖片/貼圖/GIF 首幀；欄位跟 still 烘進
/// 合成那套一致，時間都是時間軸秒）
struct MetalStillSpec {
  let path: String
  let start: Double
  let end: Double
  let z: Int
  let px: Double
  let py: Double
  let scale: Double
  let mirror: Bool
  let rotation: Double
  let opacity: Double
  let fadeIn: Double
  let fadeOut: Double
  let crop: [Double]?
  var gif = false
  var hasColor = false
  /// 5x4 調色矩陣（跟影片層同格式；nil＝沒調色）
  var color: [Double]? = nil
}

/// GIF 動畫（引擎播放用）：幀紋理＋各幀「累計」時間表。
/// 建佈局時解一次（縮到長邊 ≤512、最多 96 幀），render 按時刻取幀
struct GifAnim {
  let frames: [MTLTexture]
  let cum: [Double]  // cum[i] = 第 i 幀結束時刻（秒）
  var total: Double { cum.last ?? 0.1 }

  func frame(at t: Double) -> MTLTexture? {
    guard !frames.isEmpty else { return nil }
    let m = t.truncatingRemainder(dividingBy: total)
    // 幀數 ≤96，線性掃就好
    for (i, c) in cum.enumerated() where m < c { return frames[i] }
    return frames.last
  }

  /// CGImageSource 解 GIF（含 APNG 也吃得下）：取各幀延遲、縮圖上傳
  static func load(path: String, device: MTLDevice) -> GifAnim? {
    guard
      let src = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, nil)
    else { return nil }
    let n = CGImageSourceGetCount(src)
    guard n > 1 else { return nil }
    let take = min(n, 96)
    let loader = MTKTextureLoader(device: device)
    var frames: [MTLTexture] = []
    var cum: [Double] = []
    var acc = 0.0
    for i in 0..<take {
      // 幀取樣：超過上限就等距抽
      let idx = n == take ? i : Int(Double(i) * Double(n) / Double(take))
      guard var cg = CGImageSourceCreateImageAtIndex(src, idx, nil) else {
        continue
      }
      // 長邊縮到 512：GIF 貼圖上屏就這麼大，全解析度只是燒記憶體
      let w = cg.width
      let h = cg.height
      let long = max(w, h)
      if long > 512 {
        let sc = 512.0 / Double(long)
        let nw = Int(Double(w) * sc)
        let nh = Int(Double(h) * sc)
        if let ctx = CGContext(
          data: nil, width: nw, height: nh, bitsPerComponent: 8,
          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
          ctx.interpolationQuality = .medium
          ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
          if let scaled = ctx.makeImage() { cg = scaled }
        }
      }
      // 幀延遲（沒標就 0.1s，跟瀏覽器同一套慣例）
      var delay = 0.1
      if let props = CGImageSourceCopyPropertiesAtIndex(src, idx, nil)
        as? [String: Any],
        let g = props[kCGImagePropertyGIFDictionary as String]
          as? [String: Any]
      {
        let d =
          (g[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
          ?? (g[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.1
        delay = d < 0.011 ? 0.1 : d
      }
      guard
        let tex = try? loader.newTexture(
          cgImage: cg, options: [MTKTextureLoader.Option.SRGB: true as NSNumber]
        )
      else { continue }
      frames.append(tex)
      acc += delay
      cum.append(acc)
    }
    guard frames.count > 1 else { return nil }
    return GifAnim(frames: frames, cum: cum)
  }
}

/// 引擎收的一塊馬賽克（幾何/遮罩直接重用 CIMosaicSpec 的解析，
/// 遮罩已烙成灰階紋理）
struct MetalMosaicSpec {
  let start: Double
  let end: Double
  /// 疊放層級：只糊 z 比它低的層（跟 CI 同語意）
  let z: Int
  let type: Int
  let strength: Double
  let colorR: Double
  let colorG: Double
  let colorB: Double
  let featherMarginPx: Double
  let rect: CGRect  // 畫布座標（左上原點）
  let maskTex: MTLTexture?
}

final class MetalPreviewEngine: NSObject {
  static let shared = MetalPreviewEngine()

  private var device: MTLDevice?
  private var queue: MTLCommandQueue?
  private var videoPipe: MTLRenderPipelineState?
  private var overlayPipe: MTLRenderPipelineState?
  private var mosaicPipe: MTLRenderPipelineState?
  private var sampler: MTLSamplerState?
  private var texCache: CVMetalTextureCache?
  /// 場景離屏紋理（two-pass：先畫圖層，再讓馬賽克取樣它）。
  /// 只在有馬賽克的佈局才建；drawable 尺寸變了重建
  private var sceneTex: MTLTexture?
  /// 乒乓第二張（馬賽克按 z 分段時「取樣上一段、畫進這一段」）
  private var sceneTex2: MTLTexture?
  /// 筆刷遮罩 CIImage → 灰階紋理用（一次性建）
  private lazy var ciCtx: CIContext? =
    device.map { CIContext(mtlDevice: $0) }

  private(set) var available = false
  private var buildFailed = false

  private var layers: [MetalLayerSpec] = []
  private var stills: [MetalStillSpec] = []
  private var mosaics: [MetalMosaicSpec] = []
  /// 靜態圖層紋理（鍵＝檔案路徑；GIF 只取首幀——滑動瞬間有畫面
  /// 比消失好，動起來交給合成播放器）
  private var stillTextures: [String: MTLTexture] = [:]
  /// GIF 動畫快取（路徑→幀序列）；value 為 nil＝解過但失敗，不重試
  private var gifAnims: [String: GifAnim?] = [:]
  private var pumps: [Int: MetalPump] = [:]
  private var canvasW: Double = 1080
  private var canvasH: Double = 1920
  private var hdr = false

  /// 疊加物 PNG → 紋理（鍵＝資料長度雜湊，同一張不重上傳）
  private var ovTextures: [ObjectIdentifier: MTLTexture] = [:]

  weak var layerHost: MetalPreviewView?
  private var link: CADisplayLink?
  private(set) var active = false

  /// 跨執行緒可讀的「引擎是否在台上」（合成器快路用；bool 原子性
  /// 在此讀取容忍度內——錯一格只是那格走 CI 全路）。
  /// 不讀 UIKit 屬性（背景執行緒），show() 時同步維護
  private(set) var isOnStage = false
  private var curT: Double = 0

  // ===== 播放接管：引擎自己的時鐘 =====
  private(set) var playing = false
  private var playT0 = 0.0
  private var host0 = 0.0
  /// 對時要慢慢吃掉的偏差（正＝往前追）。tick 每格吃 ≤6%×dt，
  /// 相當於 ±6% 速率微調——肉眼看不出來，也不用動 reader
  private var slideBias = 0.0
  private var lastSlideHost = 0.0

  /// 播放接管的安全閘：滑動暫態的近似（GIF 停首幀、馬賽克蓋全
  /// 層、貼圖不吃濾鏡）在「持續播放」中是持續的錯——這些佈局
  /// 播放不接管，畫面照舊給合成播放器（正確優先）
  private var playSafe = true

  /// 播放中引擎認定的時間軸時刻（主機時鐘推進；Dart 每半秒對時）
  private var engineT: Double {
    playing ? playT0 + (CACurrentMediaTime() - host0) : curT
  }

  /// 外部可讀的引擎時刻（無音軌素材的播放接管拿它當時鐘）
  var clockT: Double { engineT }

  /// 進入播放模式：pump 各自起播（靜音），畫面由 tick 逐格合成。
  /// 佈局沒建過（build 沒成）回 false，呼叫端照舊走合成播放器畫面
  func play(_ t: Double) -> Bool {
    if !available {
      lastReject = "引擎未就緒"
      NSLog("[MetalPreview] mplay 拒絕：引擎未就緒")
    }
    if layers.isEmpty {
      lastReject = "沒有佈局"
      NSLog("[MetalPreview] mplay 拒絕：沒有佈局")
    }
    guard available, !layers.isEmpty else {
      NSLog(
        "[MetalPreview] mplay 拒 available=%@ layers=%d",
        available ? "T" : "F", layers.count)
      return false
    }
    NSLog("[MetalPreview] mplay 接管 t=%.2f", t)
    playT0 = t
    host0 = CACurrentMediaTime()
    slideBias = 0
    lastSlideHost = 0
    playing = true
    playStartHost = host0
    stPlayStartMs = -1
    stMissAt.removeAll()
    stSupplyReader = 0
    stSupplyPump = 0
    stSupplyHold = 0
    stMaxGapMs = 0
    stMissWho.removeAll()
    lastReject = ""
    // 不 force：暫停時 primed 好的佇列直接消費（真 0ms 起播）；
    // 位置變過的 settle 機制已經重新 prime 過
    syncReaders(t)
    show(true)
    return true
  }

  /// 音訊分身真正轉起來那一刻的對表：playT0 直接跳到音訊時刻。
  /// 分身 seek+起步要 ~100ms，引擎先跑掉 0.1s，之後 ±6% 滑動要
  /// 吸兩秒——實測 141 時鐘軌跡「擎恆超前音 0.10~0.15」＝跳動感。
  /// 對表不動解碼佇列（時鐘回退 0.1s 只是同一格多顯示一下）
  func rebase(to t: Double) {
    guard playing else { return }
    let before = engineT
    playT0 = t
    host0 = CACurrentMediaTime()
    slideBias = 0
    CompPlayer.noteClockEvent(
      String(format: "[對表 擎%.2f→%.2f]", before, t))
  }

  /// 停播：畫面停在停點那格。解碼佇列「不殺」——沒人消費它就
  /// 自己填滿睡著（primed），再按播放＝直接消費，真 0ms 起播。
  /// 回傳精確停點：Dart 讓位的 exact seek 要用它——用音訊時鐘的
  /// 位置差幾十 ms，讓位瞬間畫面跳半格（實測 136「暫停抖一下」）
  @discardableResult
  func stop() -> Double {
    guard playing else { return curT }
    curT = engineT
    playing = false
    for (_, p) in pumps { p.pause() }
    return curT
  }

  /// 確定性播放供格：每個進窗片段一條 ClipReader（順序硬解＋
  /// 幀佇列），快進窗 1.5 秒前就開始填下一段的佇列——交界＝
  /// 換一條已填滿的佇列，零延遲零 seek。解碼器永遠順序全速跑，
  /// 時鐘只管消費（晚了丟、早了等）
  private var readers: [Int: ClipReader] = [:]

  /// 每個 reader 上次被重啟的時刻（重啟風暴防線，見下）
  private var restartAt: [Int: Double] = [:]
  /// 滑動路徑的重啟冷卻（與播放路徑的 restartAt 分開記）
  private var scrubRestartAt: [Int: Double] = [:]

  private func syncReaders(_ t: Double, force: Bool = false) {
    let now = CACurrentMediaTime()
    for sp in layers {
      let want = sp.trimStart + (t - sp.offset) * sp.speed
      if !sp.proxy {
        // 轉檔期過渡：原檔（4K）不開解碼佇列（記憶體/頻寬扛不住），
        // 播放交給系統播放器硬解供格——畫面仍由引擎渲染，不換手。
        // 代理轉好後（停播時佈局重建）自動升級成解碼佇列
        if sp.offset <= t && t < sp.end {
          let p = pumpFor(sp)
          if playing {
            p.play(rate: 1.0)
          } else {
            p.pause()
          }
        } else {
          pumps[sp.id]?.pause()
        }
        continue
      }
      if sp.offset <= t && t < sp.end {
        var r = readers[sp.id]
        if r == nil {
          r = ClipReader(path: sp.path)
          readers[sp.id] = r
          r!.start(at: want)
        } else if r!.path != sp.path {
          if playing {
            // 播放中不換檔：換檔＝新解碼器就緒前該層沒畫面＝
            // 閃黑（實測 135：代理完成觸發熱更新的瞬間閃黑）。
            // 沿用舊檔畫完這一輪，停播後 primed 重建自然升級
          } else {
            r!.stop()
            r = ClipReader(path: sp.path)
            readers[sp.id] = r
            r!.start(at: want)
          }
        } else if force {
          r!.start(at: want)
        } else if r!.age > 1.0, now - (restartAt[sp.id] ?? 0) > 1.0 {
          // 重啟只留給兩種確定壞掉的情況，而且一秒最多一次、
          // 新 reader 先給滿一秒暖身。之前每格（60次/秒）判定：
          // 新 reader 還沒出格時備量是 -1，被誤判成「落後」→
          // 每格「建 reader→立刻取消」→ CoreMedia 內部對「已失效
          // 物件」無限重試、錯誤每毫秒數十條洗版、執行緒絞死——
          // 實機 137「一進去黑畫面＋按播放馬上當機」的真兇
          //（模擬機日誌 err=-12790 洪流實證）。解碼慢＝顯示上一格
          // 等它追，不重啟：重啟會逼它從關鍵幀重解，只會更慢
          if !r!.isRunning && r!.bufferedTo < sp.trimStart
            + (sp.end - sp.offset) * sp.speed - 0.1
          {
            // 斷流（讀掛了）而且還沒到片尾：從當下重啟
            restartAt[sp.id] = now
            r!.start(at: want)
          } else if r!.bufferedTo >= 0, r!.bufferedTo < want - 2.0 {
            // 真的整段落後（已出過格才算數）：重啟一次
            restartAt[sp.id] = now
            r!.start(at: want)
          }
        }
      } else if sp.offset - 1.5 <= t && t < sp.offset {
        if readers[sp.id] == nil {
          let r = ClipReader(path: sp.path)
          readers[sp.id] = r
          r.start(at: sp.trimStart)
        }
      } else {
        // 剛出生的 reader 不當場取消（取消撞上 preroll 進行中
        // ＝CoreMedia 對失效物件無限重試，見上）：晾到下一輪再收
        if let r = readers[sp.id], r.age < 0.5 { continue }
        readers[sp.id]?.stop()
        readers.removeValue(forKey: sp.id)
      }
    }
  }

  private let shaderSrc = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vtx(uint vid [[vertex_id]],
                    constant float4 *verts [[buffer(0)]]) {
      VOut o;
      float4 v = verts[vid];
      o.pos = float4(v.xy, 0.0, 1.0);
      o.uv = v.zw;
      return o;
    }
    // 影片層：AVFoundation 的 64RGBAHalf 不做任何色彩轉換——值保持
    // 源的非線性編碼（實測：SDR=gamma 原樣、HLG=HLG 編碼原樣，
    // 附件標籤照抄）。這裡按源標籤自己線性化＋轉到 sRGB 原色，
    // 跟 CI 合成器（匯出）同一套語意。
    // vp = (透明度, 1=HLG, 1=BT.2020 原色, HLG 增益)
    fragment half4 fragVideo(VOut in [[stage_in]],
                             texture2d<half> tex [[texture(0)]],
                             constant float4 &vp [[buffer(0)]],
                             constant float4 *cm [[buffer(1)]],
                             sampler s [[sampler(0)]]) {
      half4 c = tex.sample(s, in.uv);
      float3 v = float3(c.rgb);
      if (vp.y < -0.5) {
        // 直通（two-pass 搬運：場景已是線性，不能再解一次）
      } else if (vp.y > 0.5) {
        // HLG OETF 反轉 → 場景線性，再乘增益對齊 SDR 白
        float3 lo = v * v / 3.0;
        float3 hi = (exp((v - 0.55991073) / 0.17883277) + 0.28466892)
          / 12.0;
        v = select(lo, hi, v > 0.5) * vp.w;
      } else {
        // sRGB/709 gamma → 線性
        float3 lo = v / 12.92;
        float3 hi = pow((abs(v) + 0.055) / 1.055, 2.4);
        v = select(lo, hi, v > 0.04045);
      }
      if (vp.z > 0.5) {
        // BT.2020 → 709 原色（線性域）
        v = float3(
          1.6605 * v.r - 0.5876 * v.g - 0.0728 * v.b,
          -0.1246 * v.r + 1.1329 * v.g - 0.0083 * v.b,
          -0.0182 * v.r - 0.1006 * v.g + 1.1187 * v.b);
      }
      // 色彩濾鏡：跟 CI applyColor 同語意——gamma 空間套 5x4 矩陣
      //（cm[0..2]=R/G/B 列、cm[3]=偏移；cm[3].w>0.5＝有濾鏡）
      if (cm[3].w > 0.5) {
        float3 g = select(
          v * 12.92, 1.055 * pow(abs(v), 1.0 / 2.4) - 0.055,
          v > 0.0031308);
        g = float3(
          dot(cm[0].xyz, g), dot(cm[1].xyz, g), dot(cm[2].xyz, g))
          + cm[3].xyz;
        g = clamp(g, 0.0, 1.0);
        float3 lo = g / 12.92;
        float3 hi = pow((abs(g) + 0.055) / 1.055, 2.4);
        v = select(lo, hi, g > 0.04045);
      }
      half a = half(vp.x);
      half3 rgb = half3(max(v, 0.0));
      return half4(rgb * a, a);
    }
    // 馬賽克：取樣「畫好的場景」紋理做像素化/模糊/純色，
    // uv 一律是畫布 uv。跟 CI 那套同一組換算（cells、down、羽化），
    // 模糊用 12 點 poisson 近似高斯——滑動瞬間的近似，放手就回
    // 合成器的精確幀
    struct MosaicU {
      float4 a; // type, strength, cellPx 或 radiusPx, 羽化 margin px
      float4 b; // rect uv: minU, minV, maxU, maxV
      float4 c; // canvasW, canvasH, 筆刷遮罩開關, 0
      float4 d; // 純色 r, g, b, 1
    };
    fragment half4 fragMosaic(VOut in [[stage_in]],
                              texture2d<half> scene [[texture(0)]],
                              texture2d<half> mask [[texture(1)]],
                              constant MosaicU &u [[buffer(0)]],
                              sampler s [[sampler(0)]]) {
      float2 uv = in.uv;
      float2 cv = u.c.xy;
      int type = int(u.a.x);
      half3 rgb;
      if (type == 2) {
        rgb = half3(u.d.xyz);
      } else if (type == 1) {
        float2 r = u.a.z / cv;
        half3 acc = half3(0.0h);
        const float2 taps[12] = {
          float2(-0.326, -0.406), float2(-0.840, -0.074),
          float2(-0.696, 0.457),  float2(-0.203, 0.621),
          float2(0.962, -0.195),  float2(0.473, -0.480),
          float2(0.519, 0.767),   float2(0.185, -0.893),
          float2(0.507, 0.064),   float2(0.896, 0.412),
          float2(-0.322, -0.933), float2(-0.792, -0.598)
        };
        for (int i = 0; i < 12; i++) {
          acc += scene.sample(s, uv + taps[i] * r).rgb;
        }
        rgb = acc / 12.0h;
      } else {
        float2 cell = u.a.z / cv;
        float2 q = u.b.xy
          + (floor((uv - u.b.xy) / cell) + 0.5) * cell;
        q = clamp(q, u.b.xy, u.b.zw);
        rgb = scene.sample(s, q).rgb;
      }
      // 羽化：離方框邊緣的距離（畫布 px）在 margin 內線性收掉
      half fA = 1.0h;
      if (u.a.w > 0.5) {
        float2 dpx = min(uv - u.b.xy, u.b.zw - uv) * cv;
        float d = min(dpx.x, dpx.y);
        fA = half(clamp(d / u.a.w, 0.0, 1.0));
      }
      if (u.c.z > 0.5) {
        fA *= mask.sample(s, uv).r;
      }
      return half4(rgb * fA, fA);
    }
    """

  // 疊加物 shader 分真機/模擬器兩版：
  // 真機——programmable blending 讀底色（dst [[color(0)]]），跟
  // CIExportCompositor 同一套數學：字底下的畫面夾回 SDR 白再混
  //（半透明不被 HDR 高光沖淡），白位再乘 boost。
  // 模擬器——不支援讀 rendertarget（CompilerError: reading from a
  // rendertarget is not supported），退回固定混色、跳過夾白：
  // 顏色驗證本來就以真機為準，模擬器管幾何與順暢度
  // 參數 p：x=白位 boost（只乘色）、y=夾白開關、z=淡入淡出
  //（同乘色與 alpha——只乘色會變暗、只乘 alpha 會漏底）
  #if targetEnvironment(simulator)
    private let overlaySrc = """
      fragment half4 fragOverlay(VOut in [[stage_in]],
                                 texture2d<half> tex [[texture(0)]],
                                 constant float4 &p [[buffer(0)]],
                                 constant float4 *cm [[buffer(1)]],
                                 sampler s [[sampler(0)]]) {
        half4 o = tex.sample(s, in.uv);
        if (cm[3].w > 0.5 && o.a > 0.001h) {
        float3 v = float3(o.rgb) / float(o.a);
        float3 g = select(
          v * 12.92, 1.055 * pow(abs(v), 1.0 / 2.4) - 0.055,
          v > 0.0031308);
        g = float3(
          dot(cm[0].xyz, g), dot(cm[1].xyz, g), dot(cm[2].xyz, g))
          + cm[3].xyz;
        g = clamp(g, 0.0, 1.0);
        float3 lo = g / 12.92;
        float3 hi = pow((abs(g) + 0.055) / 1.055, 2.4);
        o.rgb = half3(select(lo, hi, g > 0.04045)) * o.a;
      }
      half f = half(p.z);
        return half4(o.rgb * half(p.x) * f, o.a * f);
      }
      """
  #else
    private let overlaySrc = """
      fragment half4 fragOverlay(VOut in [[stage_in]],
                                 half4 dst [[color(0)]],
                                 texture2d<half> tex [[texture(0)]],
                                 constant float4 &p [[buffer(0)]],
                                 constant float4 *cm [[buffer(1)]],
                                 sampler s [[sampler(0)]]) {
        half4 o = tex.sample(s, in.uv);
        if (cm[3].w > 0.5 && o.a > 0.001h) {
        float3 v = float3(o.rgb) / float(o.a);
        float3 g = select(
          v * 12.92, 1.055 * pow(abs(v), 1.0 / 2.4) - 0.055,
          v > 0.0031308);
        g = float3(
          dot(cm[0].xyz, g), dot(cm[1].xyz, g), dot(cm[2].xyz, g))
          + cm[3].xyz;
        g = clamp(g, 0.0, 1.0);
        float3 lo = g / 12.92;
        float3 hi = pow((abs(g) + 0.055) / 1.055, 2.4);
        o.rgb = half3(select(lo, hi, g > 0.04045)) * o.a;
      }
      half f = half(p.z);
        half a = o.a * f;
        half boost = half(p.x);
        half3 bg = dst.rgb;
        if (p.y > 0.5) {
          half3 capped = min(dst.rgb, half3(1.0h));
          bg = capped * a + dst.rgb * (1.0h - a);
        }
        half3 rgb = o.rgb * boost * f + bg * (1.0h - a);
        return half4(rgb, 1.0h);
      }
      """
  #endif

  private func setUp() -> Bool {
    if available { return true }
    if buildFailed { return false }
    guard let dev = MTLCreateSystemDefaultDevice(),
      let q = dev.makeCommandQueue()
    else {
      buildFailed = true
      NSLog("[MetalPreview] 拿不到 Metal 裝置/命令佇列")
      return false
    }
    do {
      let lib = try dev.makeLibrary(
        source: shaderSrc + "\n" + overlaySrc, options: nil)
      let vfn = lib.makeFunction(name: "vtx")
      let d1 = MTLRenderPipelineDescriptor()
      d1.vertexFunction = vfn
      d1.fragmentFunction = lib.makeFunction(name: "fragVideo")
      d1.colorAttachments[0].pixelFormat = .rgba16Float
      d1.colorAttachments[0].isBlendingEnabled = true
      d1.colorAttachments[0].sourceRGBBlendFactor = .one
      d1.colorAttachments[0].sourceAlphaBlendFactor = .one
      d1.colorAttachments[0].destinationRGBBlendFactor =
        .oneMinusSourceAlpha
      d1.colorAttachments[0].destinationAlphaBlendFactor =
        .oneMinusSourceAlpha
      let d2 = MTLRenderPipelineDescriptor()
      d2.vertexFunction = vfn
      d2.fragmentFunction = lib.makeFunction(name: "fragOverlay")
      d2.colorAttachments[0].pixelFormat = .rgba16Float
      #if targetEnvironment(simulator)
        // 模擬器版 shader 不讀底色，混色交給固定管線（預乘 over）
        d2.colorAttachments[0].isBlendingEnabled = true
        d2.colorAttachments[0].sourceRGBBlendFactor = .one
        d2.colorAttachments[0].sourceAlphaBlendFactor = .one
        d2.colorAttachments[0].destinationRGBBlendFactor =
          .oneMinusSourceAlpha
        d2.colorAttachments[0].destinationAlphaBlendFactor =
          .oneMinusSourceAlpha
      #else
        // 真機版 shader 自己讀底色算最終色，關掉固定混色
        d2.colorAttachments[0].isBlendingEnabled = false
      #endif
      let d3 = MTLRenderPipelineDescriptor()
      d3.vertexFunction = vfn
      d3.fragmentFunction = lib.makeFunction(name: "fragMosaic")
      d3.colorAttachments[0].pixelFormat = .rgba16Float
      d3.colorAttachments[0].isBlendingEnabled = true
      d3.colorAttachments[0].sourceRGBBlendFactor = .one
      d3.colorAttachments[0].sourceAlphaBlendFactor = .one
      d3.colorAttachments[0].destinationRGBBlendFactor =
        .oneMinusSourceAlpha
      d3.colorAttachments[0].destinationAlphaBlendFactor =
        .oneMinusSourceAlpha
      videoPipe = try dev.makeRenderPipelineState(descriptor: d1)
      overlayPipe = try dev.makeRenderPipelineState(descriptor: d2)
      mosaicPipe = try dev.makeRenderPipelineState(descriptor: d3)
    } catch {
      buildFailed = true
      NSLog("[MetalPreview] shader/管線建置失敗：%@", "\(error)")
      return false
    }
    let sd = MTLSamplerDescriptor()
    sd.minFilter = .linear
    sd.magFilter = .linear
    sd.sAddressMode = .clampToEdge
    sd.tAddressMode = .clampToEdge
    sampler = dev.makeSamplerState(descriptor: sd)
    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
    guard sampler != nil, cache != nil else {
      buildFailed = true
      NSLog("[MetalPreview] 取樣器/紋理快取建不起來")
      return false
    }
    texCache = cache
    device = dev
    queue = q
    available = true
    return true
  }

  /// 換一份時間軸佈局（滑動起手時呼叫；佈局沒變成本≈0）
  func build(canvasW: Double, canvasH: Double, hdr: Bool,
             specs: [MetalLayerSpec],
             stillSpecs: [MetalStillSpec] = [],
             mosaicMaps: [[String: Any]] = []) -> Bool {
    guard setUp() else { return false }
    self.canvasW = max(2, canvasW)
    self.canvasH = max(2, canvasH)
    self.hdr = hdr
    // 馬賽克：幾何/筆刷遮罩解析直接重用 CI 那顆（同一套數學），
    // 遮罩趁建佈局烙成灰階紋理（滑動中零轉換）
    let cvSize = CGSize(width: self.canvasW, height: self.canvasH)
    mosaics = mosaicMaps.compactMap { m in
      guard let spec = CIMosaicSpec(m, canvas: cvSize) else { return nil }
      var maskTex: MTLTexture? = nil
      if let ci = spec.strokeMask, let dev = device, let ctx = ciCtx {
        let w = Int(cvSize.width.rounded())
        let h = Int(cvSize.height.rounded())
        let td = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite]
        if let t = dev.makeTexture(descriptor: td) {
          ctx.render(
            ci, to: t, commandBuffer: nil,
            bounds: CGRect(x: 0, y: 0, width: w, height: h),
            colorSpace: CGColorSpaceCreateDeviceGray())
          maskTex = t
        }
      }
      // 羽化圈寬：跟 CI 的 margin 同一條換算（純色/筆刷不吃羽化圈——
      // 筆刷的柔邊已烘進遮罩）
      let margin = (spec.type == 2 || spec.strokeMask != nil)
        ? 0.0
        : spec.feather * 0.35
          * Double(min(spec.rect.width, spec.rect.height))
      return MetalMosaicSpec(
        start: spec.start, end: spec.end, z: spec.z, type: spec.type,
        strength: spec.strength,
        colorR: Double(spec.color.red),
        colorG: Double(spec.color.green),
        colorB: Double(spec.color.blue),
        featherMarginPx: margin, rect: spec.rect, maskTex: maskTex)
    }
    layers = specs.sorted { $0.z < $1.z }
    stills = stillSpecs
    // 2.0：引擎全時段當家，播放不再有任何佈局閘門。
    // 還在吃原檔的層走「系統播放器過渡供格」（play/syncReaders），
    // 代理轉好、下次停播重建佈局後自動升級成解碼佇列
    playSafe = true
    layoutEpoch &+= 1  // 佈局變了＝畫面該重繪（靜止降頻歸零）
    // pump 走「靠近才建、遠離回收」（見 pumpFor/trimPumps）：
    // 二十支片的時間軸也只養播放頭附近那幾顆解碼器
    // 靜態圖層紋理趁建佈局先載好（滑動中零載入）；不在佈局裡的放掉
    let wantStills = Set(stillSpecs.map { $0.path })
    for k in stillTextures.keys where !wantStills.contains(k) {
      stillTextures.removeValue(forKey: k)
    }
    if let dev = device {
      let loader = MTKTextureLoader(device: dev)
      for sp in stillSpecs where stillTextures[sp.path] == nil {
        guard let ui = UIImage(contentsOfFile: sp.path),
          let cg = ui.cgImage
        else { continue }
        stillTextures[sp.path] = try? loader.newTexture(
          cgImage: cg,
          options: [MTKTextureLoader.Option.SRGB: true as NSNumber])
      }
      // GIF 動畫幀（首幀已在 stillTextures 當保底）
      for k in gifAnims.keys where !wantStills.contains(k) {
        gifAnims.removeValue(forKey: k)
      }
      for sp in stillSpecs where sp.gif && gifAnims[sp.path] == nil {
        gifAnims[sp.path] = GifAnim.load(path: sp.path, device: dev)
      }
    }
    // 幫浦照片段開；不在新佈局裡的收掉
    let want = Set(specs.map { $0.id })
    for (id, p) in pumps where !want.contains(id) {
      p.dispose()
      pumps.removeValue(forKey: id)
    }
    for sp in specs {
      if let old = pumps[sp.id], old.path != sp.path {
        old.dispose()
        pumps.removeValue(forKey: sp.id)
        // 換檔（工作檔轉好）當場重建＋預熱到現在位置：不重建的話
        // 沒有下一次 seek 就沒人建 pump——閒置節流又停了 render，
        // 畫面就凍在舊檔最後一張（實機 137「預覽跑不出」）
        if sp.offset <= curT && curT < sp.end {
          pumpFor(sp).want(sp.trimStart + (curT - sp.offset) * sp.speed)
        }
      }
    }
    // 佈局換過＝重畫一輪（closure 內的 epoch 已 +1，這裡把
    // 閒置計數歸零，確保換檔幀真的上屏）
    idleTicks = 0
    // 合成器快路的 Metal 管線預熱（見 MetalYUVBlit.prewarm）
    DispatchQueue.global(qos: .userInitiated).async {
      MetalYUVBlit.shared.prewarm()
    }
    return true
  }

  /// 靠近才建：這一層的 pump（AVPlayer＋供格器）在用到的那一刻
  /// 才生。配合 trimPumps，長時間軸只養播放頭附近那幾顆解碼器
  private func pumpFor(_ sp: MetalLayerSpec) -> MetalPump {
    if let p = pumps[sp.id] { return p }
    let p = MetalPump(path: sp.path)
    pumps[sp.id] = p
    return p
  }

  /// 遠離回收：離播放頭前後 8 秒以外的 pump 放掉（超過 6 顆才
  /// 開始收——小專案全養著，切來切去零成本）
  private func trimPumps(_ t: Double) {
    guard pumps.count > 6 else { return }
    for sp in layers {
      guard let p = pumps[sp.id] else { continue }
      if t < sp.offset - 8 || t > sp.end + 8 {
        p.dispose()
        pumps.removeValue(forKey: sp.id)
      }
    }
  }

  /// 色彩濾鏡 → shader 的 4×float4（R/G/B 列＋偏移；bias.w＝
  /// 有沒有濾鏡的旗標）。格式跟 CI applyColor 同一份 5x4 矩陣
  private static func colorU(_ m: [Double]?) -> [Float] {
    guard let m = m, m.count >= 20 else {
      return [
        1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0,
      ]
    }
    return [
      Float(m[0]), Float(m[1]), Float(m[2]), 0,
      Float(m[5]), Float(m[6]), Float(m[7]), 0,
      Float(m[10]), Float(m[11]), Float(m[12]), 0,
      Float(m[4] / 255), Float(m[9] / 255), Float(m[14] / 255), 1,
    ]
  }

  /// 數值法庭：把 [t] 的影片層渲進離屏 rgba16Float、回讀中線
  /// 5 個取樣點的線性值——跟顯示器無關，直接驗線性化/色域數學。
  /// 回傳 [r,g,b]×5（左 10% 到右 90%）
  func grab(_ t: Double) -> [Double]? {
    guard setUp(), let queue = queue, let dev = device,
      let videoPipe = videoPipe, let sampler = sampler,
      let cache = texCache
    else { return nil }
    curT = t
    let w = 512
    let h = max(2, Int(512.0 * canvasH / canvasW))
    let td = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    td.usage = [.renderTarget]
    td.storageMode = .shared
    guard let target = dev.makeTexture(descriptor: td) else { return nil }
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = target
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].storeAction = .store
    rp.colorAttachments[0].clearColor = MTLClearColor(
      red: 0, green: 0, blue: 0, alpha: 1)
    guard let cmd = queue.makeCommandBuffer(),
      let enc = cmd.makeRenderCommandEncoder(descriptor: rp)
    else { return nil }
    enc.setFragmentSamplerState(sampler, index: 0)
    for sp in layers where sp.offset <= t && t < sp.end {
      guard let pump = pumps[sp.id] else { continue }
      let srcT = sp.trimStart + (t - sp.offset) * sp.speed
      pump.want(srcT)
      guard let tex = pump.texture(at: srcT, cache: cache),
        let verts = quad(
          for: sp, texOrient: pump.orient,
          texW: pump.dispW, texH: pump.dispH)
      else { continue }
      var vp = SIMD4<Float>(
        1, pump.isHLG ? 1 : 0, pump.is2020 ? 1 : 0, 3.77)
      enc.setRenderPipelineState(videoPipe)
      enc.setVertexBytes(verts, length: verts.count * 4, index: 0)
      enc.setFragmentBytes(&vp, length: 16, index: 0)
      enc.setFragmentBytes(Self.colorU(sp.color), length: 64, index: 1)
      enc.setFragmentTexture(tex, index: 0)
      enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    var out: [Double] = []
    let row = UnsafeMutableRawPointer.allocate(
      byteCount: w * 8, alignment: 8)
    defer { row.deallocate() }
    target.getBytes(
      row, bytesPerRow: w * 8,
      from: MTLRegionMake2D(0, h / 2, w, 1), mipmapLevel: 0)
    let p = row.assumingMemoryBound(to: UInt16.self)
    for fx in [0.1, 0.3, 0.5, 0.7, 0.9] {
      let x = Int(Double(w) * fx)
      for c in 0..<3 {
        out.append(Double(Float(Float16(bitPattern: p[x * 4 + c]))))
      }
    }
    // 尾巴掛層診斷：這一刻畫了哪些層、各自的標籤（id, HLG, 2020,
    // 旋轉, 顯示寬）——「HLG 分支有沒有跑」一看便知
    for sp in layers where sp.offset <= t && t < sp.end {
      guard let pump = pumps[sp.id] else { continue }
      out.append(contentsOf: [
        Double(sp.id), pump.isHLG ? 1 : 0, pump.is2020 ? 1 : 0,
        Double(pump.orient), pump.dispW,
      ])
    }
    return out
  }

  /// 泊車：播放（引擎不接管時）起跑前把 pump 全放掉——每顆都是
  /// 一台 AVPlayer＋供格器＋解碼器，播放中留著就是跟合成播放器
  /// 搶硬體解碼器和記憶體（實機回報：127 起「播放卡到不行」，
  /// 正是引擎預建開始存在的版本）。暫停後懶建機制自動重建
  func park() {
    for (_, r) in readers { r.stop() }
    readers.removeAll()
    for (_, p) in pumps { p.dispose() }
    pumps.removeAll()
  }

  /// 上/下台歷程（診斷用）：播放中若還出現「上」就是引擎又爬上來
  static var stageLog: [String] = []

  func show(_ on: Bool) {
    Self.stageLog.append(String(format: "%@%.1f", on ? "上" : "下", curT))
    if Self.stageLog.count > 10 { Self.stageLog.removeFirst() }
    if !on { stop() }
    active = on && available
    if active, !isOnStage {
      stageAt = CACurrentMediaTime()
      lastShownPts = -1
      pendingReveal = true
    }
    isOnStage = active
    layerHost?.setHDR(hdr)
    if active {
      // 上台不立刻亮：先渲染出正確的這一格（render 的 reveal 才亮）
      if !pendingReveal { layerHost?.setVisible(true) }
    } else {
      layerHost?.setVisible(false)
    }
    if active {
      if link == nil {
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
      }
    } else {
      link?.invalidate()
      link = nil
    }
  }

  /// [t] 這一刻的畫面「畫得出來了嗎」——所有覆蓋這一刻的影片層
  /// 都有紋理才算。接管前先問這個，沒好就下一個事件再試，
  /// 不讓黑畫布上台（build 129 實機教訓）
  func readyAt(_ t: Double) -> Bool {
    guard available, !layers.isEmpty, let cache = texCache else {
      return false
    }
    // 查詢本身就取樣一次：引擎還沒上台不會有人呼叫 texture()，
    // 只看 lastTexture 會死鎖在「永遠沒紋理→永不上台」
    var ok = true
    for sp in layers where sp.offset <= t && t < sp.end {
      guard let p = pumps[sp.id] else {
        ok = false
        continue
      }
      let srcT = sp.trimStart + (t - sp.offset) * sp.speed
      if p.texture(at: srcT, cache: cache) == nil { ok = false }
    }
    return ok
  }

  func seek(_ t: Double) {
    if playing {
      // 播放中的 seek 是「對時」（音訊時鐘是主）。硬跳＋強制重啟
      // 只留給真失聯（>1s）——音訊分身起步慢 ~300ms，開播後第一次
      // 對時若硬跳（舊值 0.25s 門檻）＝畫面跳一格＋解碼斷一拍，
      // 就是實機「暫停再播放頓一下、抖一下」。小偏差改用 ±6% 速率
      // 滑著吃，肉眼看不見，reader 完全不用動
      let diff = t - engineT
      if abs(diff) > 1.0 {
        playT0 = t
        host0 = CACurrentMediaTime()
        slideBias = 0
        syncReaders(t, force: true)
      } else if abs(diff) > 0.04 {
        slideBias = diff
      }
    } else {
      curT = t
      // 滑動供格＝連續解碼，不是逐格 seek：AVPlayer.seek 一發
      // 100~200ms，一秒只供得出 5 張新畫面（實機 156：渲染1237/
      // 新格96）。順向滑動解碼佇列順著解就是滿速；倒退/跳遠才
      // 重啟，而且要過暖身（age>0.3）＋冷卻（0.2s）兩道門——
      // v1 沒有這兩道門，倒退滑動＝每秒 60 次重建解碼器（風暴）
      for sp in layers where sp.offset <= t && t < sp.end {
        let want = sp.trimStart + (t - sp.offset) * sp.speed
        if sp.proxy {
          // 原檔（轉檔期過渡）不開解碼佇列，理由同 syncReaders
          var r = readers[sp.id]
          if r == nil || r!.path != sp.path {
            r?.stop()
            r = ClipReader(path: sp.path)
            readers[sp.id] = r
            r!.start(at: want)
            scrubRestartAt[sp.id] = CACurrentMediaTime()
          } else {
            let now = CACurrentMediaTime()
            let shown = r!.lastShown
            let buffered = r!.bufferedTo
            let behind = shown >= 0 && want < shown - 0.05
            let ahead = buffered >= 0 && want > buffered + 1.0
            let dead =
              !r!.isRunning && (shown < 0 || abs(want - shown) > 0.05)
            if behind || ahead || dead, r!.age > 0.3,
              now - (scrubRestartAt[sp.id] ?? 0) > 0.2
            {
              r!.start(at: want)
              scrubRestartAt[sp.id] = now
              stScrubRestart += 1
            }
          }
        }
        // 關鍵幀貼齊照舊：解碼佇列就緒前的保底
        pumpFor(sp).want(want, coarse: true)
      }
      prevSeekGap = CACurrentMediaTime() - lastSeekHost
      lastSeekHost = CACurrentMediaTime()
      seekSettled = false
      trimPumps(t)
    }
  }

  /// 停手精修：seek 停 150ms 沒新目標＝手停了，補精確幀
  private var lastSeekHost = 0.0
  private var seekSettled = true

  /// 靜止降頻：畫面內容（時刻/即時幾何/佈局）沒變的話——
  /// 200ms 後降到 10fps（pump 晚到的紋理還補得上）、10 秒後
  /// 完全停畫。任何變化立刻回 60fps。常駐引擎暫停時不燒 GPU
  private var idleTicks = 0
  private var drawnT = -1.0
  private var drawnEpoch = -1
  private var layoutEpoch = 0

  // ===== 引擎實測統計（真機頓在哪，看數字不用猜）=====
  private var stTicks = 0
  private var stDropped = 0
  /// 播放中畫面來源計數：解碼佇列／過渡供格／保底停格
  private var stSupplyReader = 0
  private var stSupplyPump = 0
  private var stSupplyHold = 0
  /// 播放中 tick 間隔最大值（ms）——「跳動感」的數字證據
  private var stMaxGapMs = 0
  /// 非播放（滑動/編輯）中：渲染幾格、其中幾格是真的新畫面。
  /// 兩者差很大＝渲染沒問題，是解碼器供不出新格（滑動落後的證據）
  private var stIdleRenders = 0
  private var stIdleFresh = 0
  private weak var idleLastTex: MTLTexture?
  /// 浮水印貼圖：畫了幾張／新上傳幾次／單次上傳最久（ms）
  private var stOvDraws = 0
  private var stOvUploads = 0
  private var stOvUpMaxMs = 0
  /// 滑動供格來源：解碼佇列命中／pump 保底／解碼器重啟次數
  private var stScrubReader = 0
  private var stScrubPump = 0
  private var stScrubRestart = 0
  /// 暫停上台滾動偵測：上台 300ms 內畫面倒跳或跳 >0.1s 的次數
  ///（=「按暫停畫面晃動」的數字證據；0 才算修好）
  private var stageAt = 0.0
  private var lastShownPts = -1.0
  private var stStageRoll = 0
  /// 上台亮燈延遲：圖層裡還是上一輪的舊畫面，先渲染出正確的
  /// 這一格再亮（按暫停閃一下＝舊畫面先露出來）
  private var pendingReveal = false
  /// 護持中跳過的上屏數（上台後等精確幀）
  private var stHoldPres = 0
  /// 手指正在滑：最後一次 seek 在 150ms 內「而且」它跟上一發
  /// 的間隔也短（連續事件才算）。少了第二個條件，暫停上台那
  /// 單獨一發 seek 也算滑動＝寬容差漏進來＝上台畫面快轉滾
  ///（實機 158：暫停上台滾動 3 次）
  private var prevSeekGap = 999.0
  private var scrubbingNow: Bool {
    CACurrentMediaTime() - lastSeekHost < 0.15 && prevSeekGap < 0.3
  }
  /// miss 發生時的層脈絡（層z/佇列備量/解碼器狀態）
  private var stMissWho: [String] = []
  private var stRenderMsMax = 0.0
  private var stRenderMsSum = 0.0
  private var stRenders = 0
  private var stPumpMiss = 0
  private var lastTickAt = 0.0
  /// 起播→首個新格的毫秒（真 0ms 起播的驗收數字）
  private var playStartHost = 0.0
  private var stPlayStartMs = -1.0
  /// miss 爆發（連續 4 tick 沒格）發生的時間軸秒——直接看是不是
  /// 交界（前 8 筆）
  private var stMissAt: [Double] = []
  /// 最近一次 mplay 被拒的原因（報告要看得到，不只 NSLog）
  private(set) var lastReject = ""

  func statsReport() -> [String: Any] {
    var layerInfo: [String] = []
    for sp in layers {
      let tail = String(sp.path.suffix(18))
      layerInfo.append(
        "z\(sp.z)@\(String(format: "%.1f", sp.offset))"
          + "~\(String(format: "%.1f", sp.end))"
          + (sp.proxy ? "代理" : "⚠原檔")
          + "(…\(tail))")
    }
    var queueInfo: [String] = []
    for (id, r) in readers {
      queueInfo.append(
        "id\(id) 備到 \(String(format: "%.2f", r.bufferedTo))s")
    }
    return [
      "ticks": stTicks,
      "dropped": stDropped,
      "renders": stRenders,
      "renderAvgMs": stRenders > 0
        ? (stRenderMsSum / Double(stRenders) * 1000).rounded() : 0,
      "renderMaxMs": (stRenderMsMax * 1000).rounded(),
      "pumpMiss": stPumpMiss,
      "playStartMs": stPlayStartMs.rounded(),
      "missAt": stMissAt.map { ($0 * 10).rounded() / 10 },
      "layers": layerInfo.joined(separator: "、"),
      "queues": queueInfo.joined(separator: "、"),
      "playSafe": playSafe,
      "supply": "佇列\(stSupplyReader)/過渡\(stSupplyPump)/保底\(stSupplyHold)",
      "maxGapMs": stMaxGapMs,
      "idleFresh": "渲染\(stIdleRenders)/新格\(stIdleFresh)",
      "ovTex": "貼\(stOvDraws)張/上傳\(stOvUploads)次/最久\(stOvUpMaxMs)ms",
      "scrubSrc": "佇列\(stScrubReader)/保底\(stScrubPump)/重啟\(stScrubRestart)",
      "stageRoll": stStageRoll,
      "holdPres": stHoldPres,
      "stage": Self.stageLog.joined(separator: " "),
      "onStage": isOnStage,
      "missWho": stMissWho.joined(separator: "、"),
      "resident": active,
      "playing": playing,
      "lastReject": lastReject,
    ]
  }

  /// 連續無新格的長度：30fps 內容在 60fps tick 下每兩 tick 沒
  /// 新格是「正常節奏」，連續 4 tick（>65ms）沒格才是真缺
  private var missStreak = 0
  func noteMiss(_ miss: Bool, layer: MetalLayerSpec? = nil) {
    if miss {
      missStreak += 1
      if missStreak == 4 {
        stPumpMiss += 1
        if stMissAt.count < 8 { stMissAt.append(curT) }
        // 交界卡頓的指名道姓：哪一層、佇列剩多少、解碼器活著沒
        if stMissWho.count < 8, let sp = layer {
          let rd = readers[sp.id]
          stMissWho.append(String(
            format: "%.1fs層%d佇%.2f%@", curT, sp.z,
            rd?.bufferedTo ?? -1,
            rd?.isRunning == true ? "跑" : "死"))
        }
      }
    } else {
      if missStreak >= 1, playing, stPlayStartMs < 0 {
        stPlayStartMs = (CACurrentMediaTime() - playStartHost) * 1000
      }
      if playing, stPlayStartMs < 0 {
        stPlayStartMs = (CACurrentMediaTime() - playStartHost) * 1000
      }
      missStreak = 0
    }
  }

  @objc private func tick() {
    guard active else { return }
    let now = CACurrentMediaTime()
    if lastTickAt > 0, playing {
      let gapMs = Int((now - lastTickAt) * 1000)
      if gapMs > stMaxGapMs { stMaxGapMs = gapMs }
      if gapMs > 26 { stDropped += 1 }
    }
    lastTickAt = now
    stTicks += 1
    if playing {
      // 對時偏差滑著吃（±6% 速率）：見 seek() 播放分支的說明
      if abs(slideBias) > 0.0005, lastSlideHost > 0 {
        let dt = min(now - lastSlideHost, 0.1)
        let eat = max(-dt * 0.06, min(dt * 0.06, slideBias))
        playT0 += eat
        slideBias -= eat
      }
      lastSlideHost = now
      curT = engineT
      syncReaders(curT)
    } else if !seekSettled,
      CACurrentMediaTime() - lastSeekHost > 0.15
    {
      // 手停了：補精確幀（滑動中全是關鍵幀貼齊的粗略幀），
      // 播放佇列同步 prime 到新位置——之後按播放即刻起
      seekSettled = true
      for sp in layers where sp.offset <= curT && curT < sp.end {
        pumpFor(sp).want(sp.trimStart + (curT - sp.offset) * sp.speed)
      }
      syncReaders(curT, force: true)
    }
    let ep = CIExportCompositor.liveEpoch &+ layoutEpoch
    // GIF 動畫是時變內容：有它在台上就不能靜止降頻（會凍住）
    let liveGif = stills.contains {
      $0.gif && $0.start <= curT && curT < $0.end
        && (gifAnims[$0.path] ?? nil) != nil
    }
    if !playing && !liveGif && curT == drawnT && ep == drawnEpoch {
      idleTicks += 1
      if idleTicks > 600 { return }
      if idleTicks > 12 && idleTicks % 6 != 0 { return }
    } else {
      idleTicks = 0
      drawnT = curT
      drawnEpoch = ep
    }
    let t0 = CACurrentMediaTime()
    render()
    let dt = CACurrentMediaTime() - t0
    stRenders += 1
    stRenderMsSum += dt
    if dt > stRenderMsMax { stRenderMsMax = dt }
  }

  /// 疊加物紋理（premultiplied sRGB PNG → 線性取樣）
  private func ovTexture(_ cg: CGImage) -> MTLTexture? {
    let key = ObjectIdentifier(cg)
    if let t = ovTextures[key] { return t }
    guard let dev = device else { return nil }
    let loader = MTKTextureLoader(device: dev)
    let up0 = CACurrentMediaTime()
    let tex = try? loader.newTexture(
      cgImage: cg,
      options: [MTKTextureLoader.Option.SRGB: true as NSNumber])
    if let tex = tex {
      stOvUploads += 1
      stOvUpMaxMs = max(
        stOvUpMaxMs, Int((CACurrentMediaTime() - up0) * 1000))
      if ovTextures.count > 24 { ovTextures.removeAll() }
      ovTextures[key] = tex
    }
    return tex
  }

  /// 一層的四個角（NDC）＋UV，含 contain-fit／使用者縮放位移／
  /// 鏡像／旋轉／裁切——跟 fitTransform 同一套數學。
  /// [texOrient]＝紋理的旋轉旗標（顯示要順時針轉幾度）：UV 最後
  /// 映射回未旋轉的紋理座標；[texW]/[texH]＝轉正後的顯示尺寸
  ///（有值就蓋過 Dart 給的 srcW/srcH——紋理本人比較準）
  private func quad(
    for sp: MetalLayerSpec, texOrient: Int = 0,
    texW: Double = 0, texH: Double = 0
  ) -> [Float]? {
    let W = canvasW
    let H = canvasH
    let sw = texW > 1 ? texW : sp.srcW
    let sh = texH > 1 ? texH : sp.srcH
    guard sw > 1, sh > 1 else { return nil }
    let k = min(W / sw, H / sh)
    var w = sw * k * sp.scale
    var h = sh * k * sp.scale
    var cx = sp.px * W
    var cy = sp.py * H
    // 裁切（顯示座標比例、左上原點；鏡像時水平窗翻過來）
    var u0 = 0.0, v0 = 0.0, u1 = 1.0, v1 = 1.0
    if let ca = sp.crop, ca.count >= 4, ca[2] > 0.001, ca[3] > 0.001 {
      let l = sp.mirror ? 1 - ca[0] - ca[2] : ca[0]
      // 方框縮到裁切窗；中心照裁切窗的中心移（繞原框中心）
      let fullCx = cx
      let fullCy = cy
      cx = fullCx + (l + ca[2] / 2 - 0.5) * w
      cy = fullCy + (ca[1] + ca[3] / 2 - 0.5) * h
      u0 = l
      u1 = l + ca[2]
      v0 = ca[1]
      v1 = ca[1] + ca[3]
      w *= ca[2]
      h *= ca[3]
    }
    if sp.mirror {
      swap(&u0, &u1)
    }
    // 旋轉繞整個片段框的中心（跟 CI 一致）
    let rad = sp.rotation * Double.pi / 180
    let cr = cos(rad)
    let sr = sin(rad)
    func corner(_ dx: Double, _ dy: Double, _ u0: Double, _ v0: Double)
      -> [Float]
    {
      let x0 = dx * w / 2
      let y0 = dy * h / 2
      let x = cx + x0 * cr - y0 * sr
      let y = cy + x0 * sr + y0 * cr
      // 顯示 UV → 未旋轉的紋理 UV（旋轉旗標）
      var u = u0
      var v = v0
      switch texOrient {
      case 90:
        u = v0
        v = 1 - u0
      case 180:
        u = 1 - u0
        v = 1 - v0
      case 270:
        u = 1 - v0
        v = u0
      default:
        break
      }
      return [
        Float(2 * x / W - 1), Float(1 - 2 * y / H), Float(u), Float(v),
      ]
    }
    let a = corner(-1, -1, u0, v0)
    let b = corner(1, -1, u1, v0)
    let c = corner(-1, 1, u0, v1)
    let d = corner(1, 1, u1, v1)
    return a + b + c + b + d + c
  }

  private func render() {
    guard let host = layerHost, let queue = queue,
      let videoPipe = videoPipe, let overlayPipe = overlayPipe,
      let sampler = sampler, let cache = texCache
    else { return }
    host.layoutNow()
    let mlayer = host.metalLayer
    guard mlayer.drawableSize.width > 1,
      let drawable = mlayer.nextDrawable(),
      let cmd = queue.makeCommandBuffer()
    else { return }
    // 播畢（時鐘超過所有層）停在最後一幀，不變黑
    var t = curT
    let maxEnd = layers.map { $0.end }.max() ?? 0
    if maxEnd > 0, t >= maxEnd { t = maxEnd - 0.001 }
    // 有馬賽克的佈局走 two-pass：圖層先畫進離屏場景紋理，
    // 馬賽克 shader 取樣它（模擬器也行——不讀 framebuffer），
    // 最後整張搬上 drawable 再蓋疊加物。近似：馬賽克蓋「所有」
    // 圖層（CI 是只糊 z 較低的層；馬賽克上面還有影片的排法極少，
    // 放手後合成器的精確幀就回來）
    let activeMz = mosaics.filter { $0.start <= t && t < $0.end }
    let twoPass = !activeMz.isEmpty && mosaicPipe != nil
    var target = drawable.texture
    if twoPass {
      let dw = Int(mlayer.drawableSize.width)
      let dh = Int(mlayer.drawableSize.height)
      if sceneTex == nil || sceneTex!.width != dw
        || sceneTex!.height != dh
      {
        let td = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .rgba16Float, width: dw, height: dh,
          mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        sceneTex = device?.makeTexture(descriptor: td)
        sceneTex2 = device?.makeTexture(descriptor: td)
      }
      if let st = sceneTex { target = st }
    }
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = target
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].storeAction = .store
    rp.colorAttachments[0].clearColor = MTLClearColor(
      red: 0, green: 0, blue: 0, alpha: 1)
    guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else {
      cmd.commit()
      return
    }
    enc.setFragmentSamplerState(sampler, index: 0)
    // 分段狀態：目前畫到哪個 encoder／哪張場景（乒乓）
    var curEnc = enc
    var curScene = sceneTex
    var altScene = sceneTex2
    let fullQuad: [Float] = [
      -1, 1, 0, 0, 1, 1, 1, 0, -1, -1, 0, 1,
      1, 1, 1, 0, 1, -1, 1, 1, -1, -1, 0, 1,
    ]
    // 整張搬運（場景已線性，vp.y=-1 直通）
    func blit(_ e: MTLRenderCommandEncoder, _ src: MTLTexture) {
      var passthru = SIMD4<Float>(1, -1, 0, 0)
      e.setRenderPipelineState(videoPipe)
      e.setVertexBytes(fullQuad, length: fullQuad.count * 4, index: 0)
      e.setFragmentBytes(&passthru, length: 16, index: 0)
      e.setFragmentBytes(Self.colorU(nil), length: 64, index: 1)
      e.setFragmentTexture(src, index: 0)
      e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    // 馬賽克方塊：取樣 [src] 畫到目前 encoder
    func applyMz(
      _ e: MTLRenderCommandEncoder, _ group: [MetalMosaicSpec],
      src: MTLTexture, mzPipe: MTLRenderPipelineState
    ) {
      let W = canvasW
      let H = canvasH
      for mz in group {
        let r = mz.rect.intersection(
          CGRect(x: 0, y: 0, width: W, height: H))
        guard r.width > 2, r.height > 2 else { continue }
        let u0 = Double(r.minX) / W
        let v0 = Double(r.minY) / H
        let u1 = Double(r.maxX) / W
        let v1 = Double(r.maxY) / H
        func vtx(_ u: Double, _ v: Double) -> [Float] {
          [Float(2 * u - 1), Float(1 - 2 * v), Float(u), Float(v)]
        }
        let verts =
          vtx(u0, v0) + vtx(u1, v0) + vtx(u0, v1)
          + vtx(u1, v0) + vtx(u1, v1) + vtx(u0, v1)
        // 濃度換算跟 CI 同一條：模糊＝縮小倍數當半徑（隨畫布縮放）、
        // 像素化＝橫向格數
        var third = 0.0
        if mz.type == 1 {
          third = (2.0 + mz.strength * 12.0) * min(W, H) / 1080.0
        } else if mz.type != 2 {
          let cells = min(40.0, max(4.0, 26.0 - 20.0 * mz.strength))
          third = max(2.0, Double(r.width) / cells)
        }
        let U: [Float] = [
          Float(mz.type), Float(mz.strength), Float(third),
          Float(mz.featherMarginPx),
          Float(u0), Float(v0), Float(u1), Float(v1),
          Float(W), Float(H), mz.maskTex != nil ? 1 : 0, 0,
          Float(mz.colorR), Float(mz.colorG), Float(mz.colorB), 1,
        ]
        e.setRenderPipelineState(mzPipe)
        e.setVertexBytes(verts, length: verts.count * 4, index: 0)
        e.setFragmentBytes(U, length: 64, index: 0)
        e.setFragmentTexture(src, index: 0)
        e.setFragmentTexture(mz.maskTex ?? src, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
      }
    }
    // 乒乓一輪：目前場景收工 → 換到另一張（先整張搬過去、再把
    // 這群馬賽克取樣舊場景蓋上）→ 後續圖層繼續畫在新場景上
    func pingPong(_ group: [MetalMosaicSpec]) {
      guard let src = curScene, let dst = altScene,
        let mzPipe = mosaicPipe
      else { return }
      curEnc.endEncoding()
      let rp = MTLRenderPassDescriptor()
      rp.colorAttachments[0].texture = dst
      rp.colorAttachments[0].loadAction = .clear
      rp.colorAttachments[0].storeAction = .store
      rp.colorAttachments[0].clearColor = MTLClearColor(
        red: 0, green: 0, blue: 0, alpha: 1)
      guard let e = cmd.makeRenderCommandEncoder(descriptor: rp) else {
        return
      }
      e.setFragmentSamplerState(sampler, index: 0)
      blit(e, src)
      applyMz(e, group, src: src, mzPipe: mzPipe)
      curEnc = e
      curScene = dst
      altScene = src
    }
    // 影片層與靜態圖層混排（照 z 由下往上，跟合成器同一個順序）
    enum Draw {
      case video(MetalLayerSpec)
      case still(MetalStillSpec)
    }
    var draws: [(Int, Draw)] = []
    for sp in layers where sp.offset <= t && t < sp.end {
      draws.append((sp.z, .video(sp)))
    }
    for st in stills where st.start <= t && t < st.end {
      draws.append((st.z, .still(st)))
    }
    draws.sort { $0.0 < $1.0 }
    func fade(
      _ base: Double, _ s: Double, _ e: Double, _ fi: Double, _ fo: Double
    ) -> Double {
      var a = base
      if fi > 0.01 { a = min(a, max(0, min(1, (t - s) / fi))) }
      if fo > 0.01 { a = min(a, max(0, min(1, (e - t) / fo))) }
      return a
    }
    func drawItem(_ enc: MTLRenderCommandEncoder, _ d: Draw) {
      switch d {
      case .video(let sp):
        // 播放路徑完全不依賴 pump：幾何/色彩標籤 reader 自己有。
        // 舊寫法先 guard pump 存在——工作檔轉好換路徑會銷毀 pump，
        // 播放中沒人重建 → 整層被跳過 → 全黑（實機 137 播放黑）
        let pump = pumps[sp.id]
        let tex: MTLTexture?
        var orient = pump?.orient ?? 0
        var dispW = pump?.dispW ?? sp.srcW
        var dispH = pump?.dispH ?? sp.srcH
        var hlg = pump?.isHLG ?? false
        var p2020 = pump?.is2020 ?? false
        if playing, readers[sp.id] == nil, !sp.proxy, let pump = pump {
          // 轉檔期過渡：系統播放器自走時鐘、逐格取樣（見 syncReaders）
          if let pt = pump.playTexture(cache: cache) {
            tex = pt
            stSupplyPump += 1
          } else {
            tex = pump.lastTexture
            stSupplyHold += 1
          }
        } else if playing, let rd = readers[sp.id] {
          // 確定性播放：從解碼佇列取「時鐘這一刻該顯示的那格」
          let srcT = sp.trimStart + (t - sp.offset) * sp.speed
          let before = rd.lastTexture
          // reader 剛開（開檔 50~200ms）或短暫斷供＝拿不出格。
          // 直接 continue 的話該層整層不畫——滿版底層缺格＝整個
          // 畫面黑。退回上一張或 pump 暫停幀，寧可舊一格也不透黑
          if let rt = rd.frame(at: srcT, cache: cache) {
            tex = rt
            stSupplyReader += 1
          } else {
            tex = pump?.lastTexture
            stSupplyHold += 1
          }
          noteMiss(tex === before, layer: sp)
          if rd.infoReady {
            orient = rd.orient
            dispW = rd.dispW
            dispH = rd.dispH
            hlg = rd.isHLG
            p2020 = rd.is2020
          }
        } else if !playing, let rd = readers[sp.id],
          let rt = rd.scrubFrame(
            at: sp.trimStart + (t - sp.offset) * sp.speed,
            tol: scrubbingNow ? 0.3 : 0.025, cache: cache)
        {
          // 滑動供格：解碼佇列（連續解碼，跟得上手指）。
          // 幾何從 reader 帶——proxy 與 pump 同檔同幾何，但
          // 播放分支就是這樣做的，兩路必須同一套（准）
          tex = rt
          if scrubbingNow {
            stIdleRenders += 1
            if rt !== idleLastTex { stIdleFresh += 1 }
            stScrubReader += 1
          }
          idleLastTex = rt
          let sPts = rd.lastShown
          if CACurrentMediaTime() - stageAt < 0.3, lastShownPts >= 0,
            sPts < lastShownPts - 0.001 || sPts > lastShownPts + 0.1
          {
            stStageRoll += 1
          }
          lastShownPts = sPts
          if rd.infoReady {
            orient = rd.orient
            dispW = rd.dispW
            dispH = rd.dispH
            hlg = rd.isHLG
            p2020 = rd.is2020
          }
        } else if let pump = pump {
          let srcT = sp.trimStart + (t - sp.offset) * sp.speed
          let beforeTex = pump.lastTexture
          pump.want(srcT)
          // pump 剛重建（換工作檔）或 seek 未完＝暫時沒圖：用播放
          // 停格那張頂住——那本來就是正確的暫停幀，不透黑
          tex =
            pump.texture(at: srcT, cache: cache)
            ?? readers[sp.id]?.lastTexture
          if !playing, scrubbingNow {
            stIdleRenders += 1
            if tex !== beforeTex { stIdleFresh += 1 }
            stScrubPump += 1
          }
          if !playing, readers[sp.id] != nil { usedCoarse = true }
        } else {
          tex = readers[sp.id]?.lastTexture
        }
        // 拖曳/捏合中的即時變形：跟合成器讀同一份靜態，逐格蓋過
        var spEff = sp
        if let lx = CIExportCompositor.currentLiveXform(),
          lx.z == sp.z, abs(lx.start - sp.offset) < 0.02
        {
          spEff.px = lx.px
          spEff.py = lx.py
          spEff.scale = lx.scale
          spEff.rotation = lx.rotation
        }
        guard let tex = tex,
          let verts = quad(
            for: spEff, texOrient: orient,
            texW: dispW, texH: dispH)
        else { return }
        let af = Float(
          fade(sp.opacity, sp.offset, sp.end, sp.fadeIn, sp.fadeOut))
        // HLG 增益 3.77＝參考白（75% 訊號）對齊 SDR 白 1.0
        var vp = SIMD4<Float>(
          af, hlg ? 1 : 0, p2020 ? 1 : 0, 3.77)
        let cmU = Self.colorU(sp.color)
        enc.setRenderPipelineState(videoPipe)
        enc.setVertexBytes(verts, length: verts.count * 4, index: 0)
        enc.setFragmentBytes(&vp, length: 16, index: 0)
        enc.setFragmentBytes(cmU, length: 64, index: 1)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        drewAny = true
      case .still(let st):
        // GIF：取這一刻該顯示的動畫幀；解不出＝停首幀（原行為）
        let animTex = st.gif
          ? gifAnims[st.path]?.flatMap { $0.frame(at: t - st.start) } : nil
        guard let tex = animTex ?? stillTextures[st.path] else { return }
        // 幾何跟影片層同一套（contain-fit／縮放位移／鏡像旋轉裁切），
        // 原始尺寸取紋理本人
        let asLayer = MetalLayerSpec(
          id: 0, path: st.path, offset: st.start, end: st.end,
          trimStart: 0, speed: 1, z: st.z, px: st.px, py: st.py,
          scale: st.scale, mirror: st.mirror, rotation: st.rotation,
          opacity: st.opacity, fadeIn: st.fadeIn, fadeOut: st.fadeOut,
          crop: st.crop, srcW: Double(tex.width), srcH: Double(tex.height))
        guard let verts = quad(for: asLayer) else { return }
        let a = fade(st.opacity, st.start, st.end, st.fadeIn, st.fadeOut)
        // 匯出對 still 是一般 sourceOver：不加亮（boost=1）、不夾白，
        // 淡入淡出走 z（同乘色與 alpha）
        var p = SIMD4<Float>(1.0, 0.0, Float(a), 0.0)
        enc.setRenderPipelineState(overlayPipe)
        enc.setVertexBytes(verts, length: verts.count * 4, index: 0)
        enc.setFragmentBytes(&p, length: 16, index: 0)
        // 貼圖調色（跟 CI applyColor 同語意；沒調色＝旗標 0 直通）
        enc.setFragmentBytes(Self.colorU(st.color), length: 64, index: 1)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        drewAny = true
      }
    }
    // 馬賽克按 z 分組（只糊 z 比它低的層——跟 CI 同語意）。
    // 沒有馬賽克＝整串畫在同一個 encoder（原路徑，零開銷）
    // 一層都沒畫成才不上屏（見結尾的 drewAny）：不能在這裡用
    // 「有沒有紋理」提早跳過——紋理正是靠渲染時去取樣才生出來的，
    // 提早跳過＝永遠不取樣＝畫面凍住（實機 151：滑動停在暫停那格）
    var drewAny = false
    var usedCoarse = false
    let mzGroups = Dictionary(grouping: activeMz) { $0.z }
      .sorted { $0.key < $1.key }
    var gi = 0
    for (z, d) in draws {
      // 這個 z 之前該套的馬賽克群先套（乒乓一輪）：
      // 馬賽克(z=m) 蓋住 z<m 的層——同 z 的層畫在馬賽克之上
      while twoPass, gi < mzGroups.count, mzGroups[gi].key <= z {
        pingPong(mzGroups[gi].value)
        gi += 1
      }
      drawItem(curEnc, d)
    }
    while twoPass, gi < mzGroups.count {
      pingPong(mzGroups[gi].value)
      gi += 1
    }
    // 收尾：two-pass 把最終場景整張搬上 drawable（馬賽克已在
    // 各自的 z 邊界內聯套完），疊加物再畫在它上面
    var out = curEnc
    if twoPass, let st = curScene {
      curEnc.endEncoding()
      let rp2 = MTLRenderPassDescriptor()
      rp2.colorAttachments[0].texture = drawable.texture
      rp2.colorAttachments[0].loadAction = .clear
      rp2.colorAttachments[0].storeAction = .store
      rp2.colorAttachments[0].clearColor = MTLClearColor(
        red: 0, green: 0, blue: 0, alpha: 1)
      guard let e2 = cmd.makeRenderCommandEncoder(descriptor: rp2) else {
        cmd.commit()
        return
      }
      e2.setFragmentSamplerState(sampler, index: 0)
      blit(e2, st)
      out = e2
    }
    // 疊加物（浮水印/文字）：讀合成器同一份即時清單與即時幾何
    let ovs = CIExportCompositor.currentPreviewOverlays()
    let lovs = CIExportCompositor.currentLiveOvs()
    for ov in ovs {
      guard ov.start <= t, t < ov.end, let tex = ovTexture(ov.cgImg)
      else { continue }
      stOvDraws += 1
      var x = ov.bx
      var y = ov.by
      var sc = 1.0
      var rot = 0.0
      if let oid = ov.id, let lov = lovs[oid] {
        x = lov.x
        y = lov.y
        sc = lov.scale / max(0.0001, ov.bs)
        rot = lov.rot - ov.br
      }
      // 整版 PNG：以部件中心為原點套差量（跟合成器同一套）
      let W = canvasW
      let H = canvasH
      let cx0 = ov.bx * W
      let cy0 = ov.by * H
      let cx = x * W
      let cy = y * H
      let rad = rot * Double.pi / 180
      let cr = cos(rad)
      let sr = sin(rad)
      func c2(_ px0: Double, _ py0: Double, _ u: Double, _ v: Double)
        -> [Float]
      {
        let dx = (px0 - cx0) * sc
        let dy = (py0 - cy0) * sc
        let xx = cx + dx * cr - dy * sr
        let yy = cy + dx * sr + dy * cr
        return [
          Float(2 * xx / W - 1), Float(1 - 2 * yy / H), Float(u),
          Float(v),
        ]
      }
      let pw = ov.pad * W
      let ph = ov.pad * H
      let a0 = c2(-pw, -ph, 0, 0)
      let b0 = c2(W + pw, -ph, 1, 0)
      let c0 = c2(-pw, H + ph, 0, 1)
      let d0 = c2(W + pw, H + ph, 1, 1)
      let verts = a0 + b0 + c0 + b0 + d0 + c0
      var p = SIMD4<Float>(hdr ? 3.0 : 1.0, hdr ? 1.0 : 0.0, 1.0, 0.0)
      out.setRenderPipelineState(overlayPipe)
      out.setVertexBytes(verts, length: verts.count * 4, index: 0)
      out.setFragmentBytes(&p, length: 16, index: 0)
      out.setFragmentBytes(Self.colorU(nil), length: 64, index: 1)
      out.setFragmentTexture(tex, index: 0)
      out.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    out.endEncoding()
    // 一層都沒畫成（解碼器還沒出第一格）就不上屏：保留上一幀，
    // 既不會蓋黑、也不會擋住取樣（取樣已經在上面做過了）
    // 上台護持：頭 0.4s 內若影片層還只有 pump 粗略幀（關鍵幀貼齊，
    // 差半格～幾格），先不上屏——底下播放器停著的就是精確幀，等
    // 解碼佇列補上精確幀再亮，換手零閃動。滑動中不護持（要跟手）
    let holdOff =
      CACurrentMediaTime() - stageAt < 0.4 && usedCoarse && !scrubbingNow
      && !playing
    if drewAny, !holdOff {
      cmd.present(drawable)
      if pendingReveal {
        pendingReveal = false
        layerHost?.setVisible(true)
      }
    } else if drewAny {
      stHoldPres += 1
    }
    cmd.commit()
  }

  func disposeAll() {
    show(false)
    for (_, r) in readers { r.stop() }
    readers.removeAll()
    for (_, p) in pumps { p.dispose() }
    pumps.removeAll()
    layers = []
    stills = []
    mosaics = []
    stillTextures.removeAll()
    ovTextures.removeAll()
    sceneTex = nil
  }
}

/// Metal 圖層的 PlatformView（跟 PlayerHostView 同一種掛法）
final class MetalPreviewView: NSObject, FlutterPlatformView {
  private let holder = UIView()
  let metalLayer = CAMetalLayer()

  override init() {
    super.init()
    metalLayer.pixelFormat = .rgba16Float
    metalLayer.isOpaque = true
    // EDR：iOS 16 才有這個開關；更舊的系統照畫，只是白位被夾在
    // SDR（滑動暫態可接受）
    if #available(iOS 16.0, *) {
      metalLayer.wantsExtendedDynamicRangeContent = true
    }
    setHDR(false)
    holder.layer.addSublayer(metalLayer)
    holder.backgroundColor = .clear
    metalLayer.isHidden = true
    MetalPreviewEngine.shared.layerHost = self
  }

  /// 圖層色彩空間：一律 extended linear sRGB。
  /// AVPlayerItemVideoOutput 的 64RGBAHalf 輸出值就是這個空間
  ///（EDR 慣例：>1＝高光），HDR/SDR 都一樣——之前 HDR 掛
  /// linear BT.2020 等於整個錯譯（實測 build 128：「滑動顏色
  /// 整個爆掉」的根因）
  func setHDR(_ hdr: Bool) {
    metalLayer.colorspace = CGColorSpace(
      name: CGColorSpace.extendedLinearSRGB)
  }

  func view() -> UIView {
    holder
  }

  func setVisible(_ v: Bool) {
    // 關掉隱式動畫：isHidden 切換預設帶 0.25s fade，上台/讓位
    // 交錯期會透出底下的黑＋「淡入淡出感」（實測 build 130：
    // 「停下來再滑有 FADE 感，然後螢幕一片黑」）。切換必須是瞬時的
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    metalLayer.isHidden = !v
    CATransaction.commit()
  }

  func layoutNow() {
    // 關掉隱式動畫：圖層第一次上台時 frame 從零長到滿版，系統會
    // 幫它做 0.25s 的動畫——看起來就是「畫面從旁邊飄進來」
    //（實機 151 回報）。尺寸變更必須是瞬時的
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    metalLayer.frame = holder.bounds
    let s = UIScreen.main.scale
    metalLayer.drawableSize = CGSize(
      width: max(2, holder.bounds.width * s),
      height: max(2, holder.bounds.height * s))
    CATransaction.commit()
  }
}

final class MetalViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    let v = MetalPreviewView()
    DispatchQueue.main.async { v.layoutNow() }
    // 版面變了要跟著調 drawableSize（簡單起見用觀察輪詢一次）
    return v
  }
}

