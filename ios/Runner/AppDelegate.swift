import AVFoundation
import MetalKit
import CoreImage
import VideoToolbox
import Flutter
import ImageIO
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

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

  /// 流水號：Metal 引擎的紋理快取用它當鍵。以前拿 cgImg 的位址
  ///（ObjectIdentifier）當鍵、又不持有那張圖——舊清單釋放後，新解
  /// 出來的同尺寸 PNG 常常落在同一個位址（ABA），命中的是舊樣式的
  /// 紋理（反覆改字/改色偶發停在上一版）。流水號永不重用，也不用
  /// 為了防位址重用而把整張圖抓在快取裡
  let uid: Int
  private static let uidLock = NSLock()
  private static var nextUid = 0

  init?(_ ov: [String: Any], canvas: CGSize) {
    CIOverlaySpec.uidLock.lock()
    CIOverlaySpec.nextUid += 1
    uid = CIOverlaySpec.nextUid
    CIOverlaySpec.uidLock.unlock()
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
  private let sourceStart: Double
  private let sourceRate: Double
  private var lastIdx = -1
  private var lastImg: CIImage?
  private let lock = NSLock()

  init?(path: String, placement: CGAffineTransform, clipStart: Double,
    sourceStart: Double = 0, sourceRate: Double = 1) {
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
    self.sourceStart = sourceStart
    self.sourceRate = sourceRate
  }

  /// 輸出時間 t（秒）該畫哪一格（照 GIF 自己的節奏循環）
  func image(at t: Double) -> CIImage? {
    let ms = Int(
      max(0, sourceStart + max(0, t - clipStart) * sourceRate)
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

/// 靜態圖層（圖片素材）的載入：預覽的 CompPlayer.build 跟匯出的
/// runExport（layered）共用這一個入口，兩邊的色彩／方向才是同一套。
///
/// 色彩：CIImage(contentsOf:) 保留檔案的 ICC（iPhone 照片是 Display P3），
/// 進工作空間（延伸線性 sRGB）時由 CI 轉換——跟原本
/// UIImage(contentsOfFile:).cgImage → CIImage(cgImage:) 一樣有標記，
/// 這一步本來就沒有掉色（沒有標記的 PNG，例如 Flutter 裁切存的那份，
/// ImageIO 兩條路都當 sRGB）。
///
/// 方向：applyOrientationProperty 把 EXIF 方向烘進像素。原本 .cgImage
/// 拿的是未轉正的點陣（UIImage 只把方向記在 imageOrientation），
/// 而 Flutter 那份（dart:ui）是轉正過的——多選匯入的 JPEG 帶 EXIF 方向
/// 時，烘進合成的那份會躺著。轉正後 extent 原點可能不在 0,0，歸零，
/// 後面的貼合／定位數學才是絕對座標（跟 HDRPhotoExport.export 同一手）。
///
/// HDR：[hdr]（這份合成走 HLG 輸出）而且這張有增益圖／10-bit
///（HDRPhotoExport.probe 同一套判定；[hint] 是 Dart 端探過的結果，
/// 有就不再讀檔頭）時用 expandToHDR 展開（iOS 17+）：像素可以超過 1.0
///（線性、1.0＝SDR 白），高光才跟相簿裡看到的一樣亮。SDR 輸出一律
/// 不展開——SDR 合成器的工作格式是 RGBA8，超過 1.0 的值只會被截掉。
/// 展開失敗（CI 打不開）退回舊路：未轉正、不展開，至少有圖
enum MCStillLoader {
  /// [inverseOotf]：HLG 合成（[hdr]）時要不要對載入的圖片套 [inverseHlgOotf]。
  /// nil＝自動——照 [hlgProbe]（一個行程量一次的中灰探針）判定：CI 把
  /// 線性寫成 HLG 碼那一步是場景參考才套、顯示參考不套、三條反 OOTF 路
  /// 自檢都不動就停用。true/false＝診斷用的強制覆寫（Dart 端
  /// Diag.hlgStillInverseOotf，預設 null；沒有使用者開關，決定是自動的，
  /// 健康報告只寫決定了什麼、為什麼）。SDR 合成連判斷都不進，像素一個
  /// 位元都不變
  static func load(
    path: String, hdr: Bool, hint: Bool? = nil, inverseOotf: Bool? = nil
  ) -> CIImage? {
    var opts: [CIImageOption: Any] = [.applyOrientationProperty: true]
    var expanded = false
    if hdr, #available(iOS 17.0, *) {
      let isHDR = hint ?? ((HDRPhotoExport.probe(path)["hdr"] as? Bool) ?? false)
      if isHDR {
        opts[.expandToHDR] = true
        expanded = true
      }
    }
    var loaded = CIImage(contentsOf: URL(fileURLWithPath: path), options: opts)
    if loaded == nil, let ui = UIImage(contentsOfFile: path), let cg = ui.cgImage {
      loaded = CIImage(cgImage: cg)
      expanded = false
    }
    guard let raw = loaded, raw.extent.width > 1, raw.extent.height > 1 else {
      return nil
    }
    if expanded {
      NSLog("[HDRStill] 展開 HDR：%@", (path as NSString).lastPathComponent)
    }
    // HLG 合成分別校正白基準與 OOTF；探針同時驗證白色及中灰。
    // 展開過的 HDR 照片也套：它的線性值一樣是「顯示光」（1.0＝SDR 白、
    // 增益圖往上乘），要修的是 CI 寫 HLG 碼那一步，跟 SDR 圖同一個病
    let img = hdr ? prepareForHLG(raw, inverseOotf: inverseOotf) : raw
    let o = img.extent.origin
    if abs(o.x) > 0.001 || abs(o.y) > 0.001 {
      return img.transformed(by: CGAffineTransform(translationX: -o.x, y: -o.y))
    }
    return img
  }

  /// BT.2100 HLG 的系統 γ（標稱 1000 nit 顯示器）。BT.2408 的 203 nit
  /// 基準白正是 1000 × 0.265^1.2，所以以「基準白＝1.0」正規化之後，
  /// 反 OOTF 就是 Y^(1/γ)，沒有額外的比例常數
  static let hlgSystemGamma: Double = 1.2

  /// 黑階下限：Y 的負指數在 0 會爆成無限大（0×∞＝NaN），Y 先夾到這裡
  static let blackFloor: Double = 1.0 / 4096.0

  /// 線性 0.18 的中灰乘 Y^(1/γ−1) 之後應得的線性值：0.18^(1/1.2)＝0.239
  static let correctedMidGrey: Double = pow(0.18, 1.0 / hlgSystemGamma)

  /// Measure the output transfer separately from its white level. A single
  /// grey sample cannot distinguish a gamma error from a reference-white error.
  struct HlgTransfer {
    let sceneReferred: Bool
    let whiteGain: Double
  }

  static func hlgScene(_ code: Double) -> Double {
    let a = 0.17883277
    let b = 1 - 4 * a
    let c = 0.5 - a * log(4 * a)
    return code <= 0.5 ? code * code / 3 : (exp((code - c) / a) + b) / 12
  }

  static func transfer(greyCode: Double, whiteCode: Double) -> HlgTransfer? {
    guard greyCode.isFinite, whiteCode.isFinite,
      greyCode > 0, greyCode < whiteCode, whiteCode <= 1 else { return nil }
    let white = hlgScene(whiteCode)
    let power = log(hlgScene(greyCode) / white) / log(0.18)
    let scene = abs(power - 1) < 0.04
    guard scene || abs(power - 1 / hlgSystemGamma) < 0.04 else { return nil }
    // SDR reference white -> 75% HLG (BT.2408). Use the measured transfer
    // exponent so display-referred output is not given inverse OOTF twice.
    let gain = pow(hlgScene(0.75) / white, 1 / power)
    guard gain.isFinite, gain >= 0.05, gain <= 16 else { return nil }
    return HlgTransfer(sceneReferred: scene, whiteGain: gain)
  }

  static func scaleLinear(_ image: CIImage, gain: Double) -> CIImage {
    // 增益是 1 就別多掛一個恆等濾鏡（每張 HLG 靜態圖都會經過這裡）
    if abs(gain - 1) < 1e-6 { return image }
    return image.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: CGFloat(gain), y: 0, z: 0, w: 0),
      "inputGVector": CIVector(x: 0, y: CGFloat(gain), z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gain), w: 0)
    ])
  }

  static func prepareForHLG(_ image: CIImage, inverseOotf: Bool? = nil) -> CIImage {
    let probe = hlgProbe()
    let corrected = (inverseOotf ?? probe.apply)
      ? applyOotf(image, method: probe.method) : image
    return scaleLinear(corrected, gain: probe.whiteGain)
  }

  /// 反 OOTF 的三條做法（自檢挑第一條真的動的；見 [runProbe]）
  enum OotfMethod: String {
    /// 三條都不動＝校正已停用
    case disabled = "無"
    /// 自寫 color kernel（CIKL）：RGB × max(Y, 下限)^(1/γ−1)，alpha 直通。
    /// 精確、保色度，不靠 CIGammaAdjust 吃不吃負指數
    case kernel = "kernel"
    /// 內建濾鏡鏈：CIColorMatrix 算 Y → CIColorClamp 夾黑 →
    /// CIGammaAdjust(負指數) → CIMultiplyCompositing。保色度，但
    /// CIGammaAdjust 的屬性表寫 min 0，負指數會不會被夾查不到
    case lumaChain = "亮度係數"
    /// 逐通道 CIGammaAdjust(1/γ)（正指數，一定吃）：灰階精確，
    /// 飽和色的色度會偏一點（每通道各自壓，不是整體乘一個係數）
    case perChannel = "逐通道γ"
  }

  /// 反 OOTF：RGB_s = RGB_d × Y_d^(1/γ − 1)。
  ///
  /// 圖片素材是「顯示光」（sRGB/P3 解碼出來的線性值，1.0＝基準白）直接
  /// 插進線性工作空間；影片則是 HLG→線性→HLG 來回抵銷。Core Image 把
  /// 線性值寫成 HLG 碼那一步若是純反 OETF（場景參考），顯示端再套一次
  /// BT.2100 的 OOTF，圖片中間調就暗半檔（0.18→0.128）、白還是白。
  /// 這個函數先把顯示光換成場景光，讓顯示端的 OOTF 剛好把它變回原來
  /// 的顯示光。只乘亮度算出來的係數、RGB 一起乘：色度不變，跟 BT.2100
  /// 定義的 OOTF（作用在 Y 上）同構。Y 用 709 權重在線性 sRGB 工作空間
  /// 算——CIE Y 跟原色無關，在 sRGB 原色算的 Y 跟轉去 2020 再算是同一
  /// 個數。走 [hlgProbe] 自檢挑出來的那條路（kernel → 內建亮度係數鏈 →
  /// 逐通道），三條都不動時原圖照回
  static func inverseHlgOotf(_ img: CIImage) -> CIImage {
    applyOotf(img, method: hlgProbe().method)
  }

  /// 指定做法的反 OOTF（自檢逐條試用；正常路走 [inverseHlgOotf]）。
  /// 這裡不能碰 [hlgProbe]——[runProbe] 在探針鎖裡呼叫這條
  static func applyOotf(_ img: CIImage, method: OotfMethod) -> CIImage {
    switch method {
    case .disabled:
      return img
    case .kernel:
      guard let k = ootfKernel,
        let out = k.apply(
          extent: img.extent,
          arguments: [img, 1.0 / hlgSystemGamma - 1.0, blackFloor])
      else { return img }
      return out
    case .lumaChain:
      return lumaChainOotf(img)
    case .perChannel:
      return img.applyingFilter(
        "CIGammaAdjust", parameters: ["inputPower": 1.0 / hlgSystemGamma])
    }
  }

  /// 反 OOTF 的 color kernel（CIKL）。init(source:) 從 iOS 12 SDK 起就標
  /// deprecated（編譯只會給一個警告，專案沒開警告當錯誤），但 iOS 15～17
  /// 執行期照樣編得過；哪天編不過（回 nil）就自動退到內建濾鏡鏈，自檢再驗一次。
  /// __sample 進來是預乘 alpha 的：先除回 alpha 算 Y（半透明邊緣的係數
  /// 才對），係數乘回預乘的 RGB，alpha 原樣直通——α=0 的像素 Y 被下限
  /// 夾住，永遠不會算 pow(0, 負數)
  static let ootfKernel: CIColorKernel? = CIColorKernel(
    source: """
      kernel vec4 mcInverseHlgOotf(__sample s, float e, float floorY) {
        vec3 c = s.rgb / max(s.a, floorY);
        float y = max(dot(c, vec3(0.2126, 0.7152, 0.0722)), floorY);
        return vec4(s.rgb * pow(y, e), s.a);
      }
      """)

  /// 內建濾鏡版：係數圖＝Y^(1/γ−1)（CIColorMatrix → CIColorClamp →
  /// CIGammaAdjust），CIMultiplyCompositing 乘回原圖。
  /// 係數圖的 alpha 固定 1（inputAVector 全零＋bias w=1）：乘出來的
  /// alpha 才正好是原圖的 α（以前係數圖帶著原圖的 α，乘完變 α²，半透明
  /// 邊緣變薄）；bias 會把畫外也填成不透明、extent 變無限，裁回原圖範圍。
  /// α=0 的像素：Y 是 0，先被 CIColorClamp 夾到下限才進 CIGammaAdjust，
  /// 不會算 pow(0, 負數)，乘回 (0,0,0,0) 還是 (0,0,0,0)
  static func lumaChainOotf(_ img: CIImage) -> CIImage {
    let w = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
    // Y 要從「未預乘」的 RGB 算：CIColorMatrix 不會自己除回 alpha，
    // 半透明邊緣的 Y 會被 α 打折，係數 (αY)^(-1/6) 就比該有的大——
    // α=0.5 多亮 12%、α=0.1 多亮 47%，透明 PNG 的鋸齒邊會浮一圈亮邊。
    // 乘回去的仍是預乘的 img，輸出照樣正確
    let luma = img.unpremultiplyingAlpha().applyingFilter(
      "CIColorMatrix",
      parameters: [
        "inputRVector": w, "inputGVector": w, "inputBVector": w,
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
      ]
    ).cropped(to: img.extent)
    let f = CGFloat(blackFloor)
    let clamped = luma.applyingFilter(
      "CIColorClamp",
      parameters: [
        "inputMinComponents": CIVector(x: f, y: f, z: f, w: 1),
        "inputMaxComponents": CIVector(x: 65504, y: 65504, z: 65504, w: 1),
      ])
    let factor = clamped.applyingFilter(
      "CIGammaAdjust", parameters: ["inputPower": 1.0 / hlgSystemGamma - 1.0])
    return img.applyingFilter(
      "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: factor])
  }

  /// 中灰探針的結果（一個行程量一次；見 [hlgProbe]）
  struct HlgProbe {
    /// Linear RGB gain, independent of alpha and the inverse-OOTF decision.
    var whiteGain: Double = 1
    /// 探針本身可信：色彩空間建得出來、線性讀回 ≈0.180
    let ok: Bool
    /// 線性工作空間讀回的中灰（應 0.180）
    let linear: Double
    /// Core Image 把線性 0.180 寫成的 HLG 碼
    let code: Double
    /// 中灰／白色還原成場景線性後的比值，辨識是否需要反 OOTF
    let sceneReferred: Bool
    /// 自檢後真的動的那條反 OOTF 路（.disabled＝三條都不動）
    let method: OotfMethod
    /// 自檢：中灰走 [method] 之後的線性值（應 ≈0.239）
    let corrected: Double
    /// 自動模式的最後決定：場景參考、而且有一條路能動，才套
    let apply: Bool
    /// 讀值的判讀（報告那行括號裡的字）；探不到時是原因
    let reading: String
    /// 自檢每條路的讀值（停用時寫進報告定罪）
    let tried: String
  }

  private static let probeLock = NSLock()
  private static var probeCache: HlgProbe?

  /// 中灰探針：一個行程只量一次，結果放靜態快取（鎖住量，同時來的
  /// 等第一個量完）。探不到／讀回不對的結果不快取，下一張圖再試一次
  static func hlgProbe() -> HlgProbe {
    probeLock.lock()
    defer { probeLock.unlock() }
    if let p = probeCache { return p }
    let p = runProbe()
    if p.ok { probeCache = p }
    return p
  }

  /// 健康報告「中灰探針」那行：讀值＋判讀＋這次組建的決定。
  /// [override]＝Dart 端的診斷強制值（nil＝自動）。長相：
  ///   中灰線性0.180→HLG碼0.378（場景參考）→反OOTF 套用（kernel），校正後線性0.239
  ///   中灰線性0.180→HLG碼0.436（顯示參考）→不套
  ///   中灰線性0.180→HLG碼0.378（場景參考）→反OOTF 無效，已停用（kernel 0.180／…）
  ///   探針異常：線性讀回0.250（應0.180），不判定→反OOTF 不套
  static func hlgReport(override: Bool?) -> String {
    hlgLine(hlgProbe(), override: override)
  }

  private static func hlgLine(_ p: HlgProbe, override: Bool?) -> String {
    guard p.ok else { return "\(p.reading)→反OOTF 不套" }
    func f3(_ v: Double) -> String { String(format: "%.3f", v) }
    var s = "中灰線性\(f3(p.linear))→HLG碼\(f3(p.code))（\(p.reading)；白基準增益\(f3(p.whiteGain))）"
    if let o = override {
      s += o ? "→反OOTF 強制開（" : "→反OOTF 強制關（"
      s += p.apply ? "自動會套" : "自動不套"
      if !o {
        return s + "）"
      }
      if p.method == .disabled {
        return s + "；三條路都無效，實際沒動）"
      }
      return s + "；\(p.method.rawValue)），校正後線性\(f3(p.corrected))"
    }
    if !p.sceneReferred { return s + "→不套" }
    if p.method == .disabled {
      return s + "→反OOTF 無效，已停用（\(p.tried)）"
    }
    return s + "→反OOTF 套用（\(p.method.rawValue)），校正後線性\(f3(p.corrected))"
  }

  /// 1×1 中灰（sRGB 0.4614＝線性 0.180 的 18% 中灰）經 [transform] 之後，
  /// 走跟圖片素材同一條路（同一顆 HDR 工作空間 context、同一個 HLG 輸出
  /// 色彩空間——CIExportCompositor 的 outCS 就是它）讀回：(1) 線性工作
  /// 空間的值、(2) CI 寫成的 HLG 碼。色彩空間或 CIColor 建不出來回 nil
  private static func renderGrey(
    _ transform: (CIImage) -> CIImage, srgbValue: CGFloat = 0.4614
  ) -> (linear: Double, code: Double)? {
    let g = srgbValue
    guard let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
      let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG),
      let srgb = CGColorSpace(name: CGColorSpace.sRGB),
      let grey = CIColor(red: g, green: g, blue: g, alpha: 1, colorSpace: srgb)
    else { return nil }
    let px = CGRect(x: 0, y: 0, width: 1, height: 1)
    let img = transform(CIImage(color: grey).cropped(to: px))
    let ctx = CIExportCompositor.ctxHDR
    var linear: [Float] = [0, 0, 0, 0]
    ctx.render(
      img, toBitmap: &linear, rowBytes: 16, bounds: px, format: .RGBAf,
      colorSpace: lin)
    var code: [UInt16] = [0, 0, 0, 0]
    ctx.render(
      img, toBitmap: &code, rowBytes: 8, bounds: px, format: .RGBA16,
      colorSpace: hlg)
    return (Double(linear[0]), Double(code[0]) / 65535.0)
  }

  /// 中灰探針（健康報告「中灰探針」那行的資料）。
  ///
  /// 同時量中灰與白色：先以兩者比值辨識轉換曲線，再將白色對齊
  /// HLG 0.75。舊版只看中灰 <0.407，會把「白基準偏暗」誤當 gamma
  /// 問題；即使透明度 100%，白底仍灰，而且多套了一次反 OOTF。
  ///
  /// 自檢：同一顆中灰再走一次反 OOTF 路，線性應從 0.180 變成 ≈0.239
  ///（±0.01）。沒動＝那條路在這個 OS 上是死的（CIKL kernel 編不過、
  /// CIGammaAdjust 把負指數夾掉……），依序試 kernel → 內建亮度係數鏈 →
  /// 逐通道正指數；三條都不動就停用校正、報告那行明說。
  /// 探針本身先要可信：線性讀回不是 0.180（±0.01）就不判定、不快取。
  /// 校正後再讀回白色及中灰驗證；通過才快取，一個行程一次。
  private static func runProbe() -> HlgProbe {
    func failed(_ why: String) -> HlgProbe {
      HlgProbe(
        ok: false, linear: 0, code: 0, sceneReferred: false,
        method: .disabled, corrected: 0, apply: false, reading: why, tried: "")
    }
    guard let plain = renderGrey({ $0 }) else {
      return failed("探不到（色彩空間或 CIColor 建不出來）")
    }
    guard abs(plain.linear - 0.18) <= 0.01 else {
      return failed(
        "探針異常：線性讀回" + String(format: "%.3f", plain.linear)
          + "（應0.180），不判定")
    }
    // HLG 碼也要落在物理上可能的區間，避免把未寫入或 NaN 當成樣本。
    // 文件上合理的讀值 0.325／0.378／0.436／0.672 全在區間內；NaN 兩邊
    // 比較都不成立，一樣落到 failed
    guard plain.code > 0.2, plain.code < 0.9 else {
      return failed(
        "探針異常：HLG碼讀回" + String(format: "%.3f", plain.code)
          + "（應0.378或0.436），不判定")
    }
    guard let white = renderGrey({ $0 }, srgbValue: 1),
      abs(white.linear - 1) <= 0.01,
      let mapping = transfer(greyCode: plain.code, whiteCode: white.code)
    else { return failed("白色／中灰轉換不符合可校正曲線，不判定") }
    let scene = mapping.sceneReferred
    let reading = (scene ? "場景參考" : "顯示參考")
      + String(format: "；白HLG碼%.3f→0.750", white.code)
    var method = OotfMethod.disabled
    var corrected = plain.linear
    var tried: [String] = []
    for m in [OotfMethod.kernel, .lumaChain, .perChannel] {
      if m == .kernel && ootfKernel == nil {
        tried.append("kernel 編譯失敗")
        continue
      }
      guard let r = renderGrey({ applyOotf($0, method: m) }) else { continue }
      tried.append(m.rawValue + String(format: " %.3f", r.linear))
      if abs(r.linear - correctedMidGrey) <= 0.01 {
        method = m
        corrected = r.linear
        break
      }
    }
    // Check the complete conversion, including reference-white gain. Never
    // cache an adjustment which only fixes grey while leaving white incorrect.
    // 場景參考但三種反 OOTF 寫法都不能用（method == .disabled）：這台就是
    // 沒辦法校正中灰，只做白基準；自檢只驗白，不然這種裝置永遠 failed、
    // 不進快取，每載一張圖就重跑十幾張 1×1 的渲染，報告也看不到 tried
    let ootfUsable = !scene || method != .disabled
    func correctedImage(_ image: CIImage) -> CIImage {
      scaleLinear(
        ootfUsable && scene ? applyOotf(image, method: method) : image,
        gain: mapping.whiteGain)
    }
    guard let finalWhite = renderGrey(correctedImage, srgbValue: 1),
      let finalGrey = renderGrey(correctedImage),
      abs(finalWhite.code - 0.75) < 0.01,
      !ootfUsable
        || abs(hlgScene(finalGrey.code) / hlgScene(0.75) - correctedMidGrey) < 0.01
    else { return failed("白色／中灰校正後自檢未通過，不套用") }
    var result = HlgProbe(
      ok: true, linear: plain.linear, code: plain.code, sceneReferred: scene,
      method: method, corrected: corrected,
      apply: scene && method != .disabled, reading: reading,
      tried: tried.joined(separator: "／"))
    result.whiteGain = mapping.whiteGain
    return result
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
  /// 原始寬度與已查證的不透明來源，只供預覽剔除全遮蔽層。
  /// 其他建構路徑預設未知，不能拿來遮蔽下層。
  let srcWidth: CGFloat
  let sourceOpaque: Bool
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

  /// 這一層烘進 transform／placement 的「使用者變形」基準值
  ///（縮放/位置）。即時變形（liveXform）要靠它算差量：
  /// 新值 ∘ 舊值⁻¹ 疊上去。預覽的影片層跟烘進合成的圖片/GIF 層
  /// 都會帶（見 build() 的 stillSpecs 那段）；匯出用預設值
  ///（等於不參與，反正匯出的合成器 liveComp 恆 false，不會讀 lx）
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
    uScale: Double = 1, uPx: Double = 0.5, uPy: Double = 0.5,
    srcWidth: CGFloat = 0, sourceOpaque: Bool = false
  ) {
    self.trackID = trackID
    self.still = still
    self.gif = gif
    self.transform = transform
    self.srcHeight = srcHeight
    self.srcWidth = srcWidth
    self.sourceOpaque = sourceOpaque
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

/// 預覽指令的保守可見性規劃。只減少完全不可能露出的來源；不改音軌。
/// 圖片／GIF／馬賽克不當遮蔽物，fade、裁切與自由旋轉也保留所有下層。
enum MCPreviewVisibility {
  static let prerollSeconds = 1.5

  static func sourceIsOpaque(_ track: AVAssetTrack) -> Bool {
    // Apple 明定此 characteristic 表示來源含 alpha；不可只看 hvc1，
    // HEVC 也可以帶 alpha。格式資訊不完整時保守保留所有層。
    // https://developer.apple.com/documentation/avfoundation/avmediacharacteristic/containsalphachannel
    guard !track.hasMediaCharacteristic(.containsAlphaChannel),
      !track.formatDescriptions.isEmpty else { return false }
    return track.formatDescriptions.allSatisfy { raw in
      let fd = raw as! CMFormatDescription
      let alpha = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel)
      let mode = CMFormatDescriptionGetExtension(
        fd, extensionKey: kCMFormatDescriptionExtension_AlphaChannelMode)
      return (alpha as? NSNumber)?.boolValue != true && mode == nil
    }
  }

  static func coversCanvas(_ layer: CILayerSpec, canvas: CGSize) -> Bool {
    guard layer.trackID != kCMPersistentTrackID_Invalid,
      layer.still == nil, layer.gif == nil, layer.sourceOpaque,
      layer.opacity == 1, layer.fadeIn == 0, layer.fadeOut == 0,
      layer.crop == nil, layer.rotation == 0, layer.colorMatrix == nil,
      layer.srcWidth > 1, layer.srcHeight > 1,
      canvas.width > 1, canvas.height > 1 else { return false }
    let xf = layer.transform
    let values = [xf.a, xf.b, xf.c, xf.d, xf.tx, xf.ty,
                  layer.srcWidth, layer.srcHeight, canvas.width, canvas.height]
    guard values.allSatisfy({ $0.isFinite }),
      abs(xf.a * xf.d - xf.b * xf.c) > 0.000001 else { return false }
    // 旋轉方框的包圍盒蓋滿，不代表畫布四角被蓋住。
    // 反算每個畫布角到來源；凸四邊形包含四角才真的全覆蓋。
    let inverse = xf.inverted()
    let epsilon: CGFloat = 0.000001 // 只容許浮點誤差，不吞掉邊緣像素。
    return [CGPoint.zero, CGPoint(x: canvas.width, y: 0),
            CGPoint(x: 0, y: canvas.height),
            CGPoint(x: canvas.width, y: canvas.height)].allSatisfy { point in
      let p = point.applying(inverse)
      return p.x >= -epsilon && p.y >= -epsilon
        && p.x <= layer.srcWidth + epsilon && p.y <= layer.srcHeight + epsilon
    }
  }

  static func visibleLayers(
    _ layers: [CILayerSpec], canvas: CGSize, enabled: Bool
  ) -> [CILayerSpec] {
    guard enabled,
      let index = layers.lastIndex(where: { coversCanvas($0, canvas: canvas) })
    else { return layers }
    return Array(layers[index...])
  }

  /// 必須在可見性邊界之前切一段預熱窗，不能把末尾預熱攤到整條長指令。
  static func prerollStarts(before boundaries: [CMTime]) -> [CMTime] {
    let lead = CMTime(seconds: prerollSeconds, preferredTimescale: 600)
    return boundaries.compactMap { boundary in
      let start = boundary - lead
      guard start.isNumeric, start > .zero else { return nil }
      // 後面的標記合併容差是 5ms；預熱標記不能搶先留下而把真正的
      // 片段頭尾擠掉，否則只是加預熱就會提早顯示下一段。
      // CMTime(seconds:) can quantize neighboring 3.842/5.338 boundaries to
      // exactly three 1/600 ticks apart. Compare rational times, inclusively:
      // converting back to Double can put that 5ms distance on either side.
      let boundaryGuard = CMTime(value: 3, timescale: 600)
      guard !boundaries.contains(where: {
        $0.isNumeric && CMTimeCompare(CMTimeAbsoluteValue($0 - start), boundaryGuard) <= 0
      })
      else { return nil }
      return start
    }
  }

  static func requiredTracks<S: Sequence>(
    at start: CMTime, own: Set<CMPersistentTrackID>,
    upcoming: S
  ) -> Set<CMPersistentTrackID>
  where S.Element == (start: CMTime, tracks: Set<CMPersistentTrackID>) {
    var ids = own
    let horizon = start.seconds + prerollSeconds
    for next in upcoming {
      if next.start.seconds > horizon + 0.000001 { break }
      ids.formUnion(next.tracks)
    }
    return ids
  }
}

/// 每次正式 build 各自一份。第一次編輯片段後維持完整圖層，直到下次 build；
/// 不能 clear 手勢就重新剔除，因為正式烘定可能仍在等待背景重建。
final class MCPreviewVisibilityState {
  private(set) var enabled = true
  private(set) var hasCulledLayers = false
  func noteCulling() { hasCulledLayers = true }
  func beginEditing() -> Bool {
    guard enabled else { return false }
    enabled = false
    return true
  }
}

/// Method-channel 的精準定位收據。新請求取代舊請求時，舊等待一定結束；
/// 舊 AVPlayer 回呼不得把新的收據誤判成功。僅在主執行緒存取。
final class MCSeekCompletionState {
  private(set) var generation: UInt64 = 0
  private var completion: ((Bool) -> Void)?

  @discardableResult
  func replace(with next: ((Bool) -> Void)?) -> UInt64 {
    let previous = completion
    generation &+= 1
    completion = next
    previous?(false)
    return generation
  }

  func finish(_ request: UInt64, succeeded: Bool) {
    guard request == generation else { return }
    let done = completion
    completion = nil
    done?(succeeded)
  }

  /// 拖動時 seek 容忍值的上限（毫秒）。seek 窗跟原生拖曳的呈現窗
  /// （performNativeScrub）都用這一個數——兩邊不一致的話，seek 落到的關鍵
  /// 幀會被呈現窗（快取的 accepts()）拒收，逾時、畫面不動
  static let scrubToleranceCapMs = 500

  static func tolerance(exact: Bool, milliseconds: Int?) -> CMTime {
    // 舊呼叫預設 0；原始長 GOP 影片才由 Dart 明確要求寬容拖曳。
    // 放手的精準發無條件為 0，即使呼叫方誤傳了寬容值。
    let ms = exact ? 0 : min(scrubToleranceCapMs, max(0, milliseconds ?? 0))
    return CMTime(value: Int64(ms), timescale: 1000)
  }

  /// 拖動的容忍窗不跨指令段。
  ///
  /// 窗一跨到隔壁片段，AVPlayer 會落在那一段的起點（段落起點必是同步點，
  /// 離得近就被吸過去），而合成出來的那格不在 target 的 range 裡，快取的
  /// accepts() 永遠不收——逾時、畫面不動。所以把窗夾成「離最近接縫多遠
  /// 就多寬」（對稱）：接縫附近自然退回近乎精準的 seek，段落中間才吃滿
  /// 上限。找不到 target 所在的段（沒有 videoComposition）就只套上限
  static func clampedScrubToleranceMs(
    _ milliseconds: Int, target: Double,
    instructions: [AVVideoCompositionInstructionProtocol]?
  ) -> Int {
    let capped = min(scrubToleranceCapMs, max(0, milliseconds))
    guard capped > 0, target.isFinite, let instructions = instructions else {
      return capped
    }
    let at = CMTime(seconds: target, preferredTimescale: 60_000)
    guard let instruction = instructions.first(where: {
      CMTimeRangeContainsTime($0.timeRange, time: at)
    }) else { return capped }
    let start = instruction.timeRange.start.seconds
    let end = instruction.timeRange.end.seconds
    guard start.isFinite, end.isFinite else { return capped }
    // 尾端留一個合成刻度（1/600 秒）：AVPlayer 的容忍窗是閉區間
    // [t-before, t+after]，窗的邊剛好壓在 end（＝隔壁段的起點，同步點）
    // 就會被吸過去，那格不在 target 的段裡、accepts() 不收。起點側不用
    // 留：落在 start 就是這一段的第一格，收得進來
    let room = max(0, min(target - start, end - target - 1.0 / 600))
    // 十進位的 0.3 在二進位是 0.29999…，直接 floor 會掉成 299：先加一點點
    return min(capped, Int(floor(room * 1000 + 1e-6)))
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
  // Only preview instructions capture frames. Export/proxy compositors never
  // enter the interactive cache, even when they run concurrently.
  var scrubCapture: MCNativeScrubCache?
  var scrubLayout: UInt64 = 0
  let timeRange: CMTimeRange
  let enablePostProcessing = false
  let containsTweening = true
  let passthroughTrackID = kCMPersistentTrackID_Invalid
  var requiredSourceTrackIDs: [NSValue]? {
    // AVFoundation 只替「這段指令要求的軌」預捲解碼器——只列當下
    // 用到的話，上層片段進場那一刻它的解碼器才冷啟動，來源格晚一
    // 兩格到位，就是接縫閃黑／停頓的根。所以組建端會把「這一段用到
    // 的軌＋往後一段時間內會進場的軌」一起算好塞進 prerollTrackIDs
    //（見 CompPlayer.build 的預捲窗）；有算過就照它
    if !prerollTrackIDs.isEmpty { return prerollTrackIDs }
    let ids = layers.compactMap { l -> NSNumber? in
      l.trackID == kCMPersistentTrackID_Invalid
        ? nil : NSNumber(value: l.trackID)
    }
    // 一條來源軌都不用（只有圖片層的段、補長出來的黑尾巴、或短縫
    // 頂住的段）：一定要回「空陣列」，不能回 nil。
    // AVVideoComposition.h 明講 nil＝「所有來源軌都是必要的」，
    // 空陣列才是「這一段不需要任何來源」。回 nil 的話，畫面明明只有
    // 一張圖片，AVFoundation 還是會把每一條合成軌的解碼器全部叫醒
    // ——影片結束、圖片尾巴接上的那一刻同時冷啟三顆 4K 解碼器，
    // 而那幾格的畫面根本沒有人去讀（startRequest 只畫 still 層）
    return ids
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
  /// 已省略下層來源的預覽指令不可吃到新手勢：換 VC 時可能還有舊格在飛，
  /// 它維持舊幾何直到完整來源指令接手，避免移走上層時短暫露出黑底。
  let previewCulled: Bool

  init(
    timeRange: CMTimeRange, layers: [CILayerSpec],
    mosaics: [CIMosaicSpec], overlays: [CIOverlaySpec],
    prerollTrackIDs: [NSNumber] = [], holdIfEmpty: Bool = false,
    previewCulled: Bool = false
  ) {
    self.timeRange = timeRange
    self.layers = layers
    self.mosaics = mosaics
    self.overlays = overlays
    self.prerollTrackIDs = prerollTrackIDs
    self.holdIfEmpty = holdIfEmpty
    self.previewCulled = previewCulled
    super.init()
  }
}

class CIExportCompositor: NSObject, AVVideoCompositing {
  /// 不透明度 a：正確結果是預乘的 (r,g,b,α) 全部乘 a。
  ///
  /// 不用 CIColorMatrix 做這件事——它到底是在預乘值還是非預乘值上運算，
  /// Apple 文件（「色彩濾鏡用非預乘值」）跟本檔既有的量測說法互相矛盾，
  /// 兩位審查員各執一詞，沒有真機沒人能判：一種模型下「RGBA 一起乘」
  /// 會變成 a² 雙重壓暗，另一種模型下「只乘 alpha」會變成加法疊底。
  /// 改成乘上一張常數色圖（純白、alpha=a）：合成類濾鏡不管哪種模型，
  /// 結果都是 (r·a, g·a, b·a, α·a)——預乘模型是直接相乘；非預乘模型是
  /// 白色不改色、alpha 乘 a、再預乘回去，殊途同歸。
  /// RunnerTests 的像素測試（白疊白不變灰、彩色按比例混）在 Mac 上跑得出
  /// 最終答案，這個寫法兩種答案都會過
  static func applyingOpacity(_ image: CIImage, opacity: Double) -> CIImage {
    let a = CGFloat(min(1, max(0, opacity)))
    if a >= 0.999 { return image }
    let tint = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: a))
      .cropped(to: image.extent)
    return image.applyingFilter(
      "CIMultiplyCompositing",
      parameters: [kCIInputBackgroundImageKey: tint])
  }

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
  private static let epochLock = NSLock()
  private static var _liveEpoch = 0
  static var liveEpoch: Int {
    epochLock.lock(); defer { epochLock.unlock() }
    return _liveEpoch
  }
  private static func changeLiveEpoch() {
    epochLock.lock()
    _liveEpoch &+= 1
    epochLock.unlock()
    // Setter calls originate on the main channel. Do not retain a frame with
    // yesterday's style above the freshly redrawn AVPlayer layer.
    DispatchQueue.main.async {
      PlayerHosts.shared.nativeScrubStyleChanged()
    }
  }
  private static var liveMosaics: [CIMosaicSpec]?
  static func setLiveMosaics(_ specs: [CIMosaicSpec]?) {
    ovLock.lock()
    liveMosaics = specs
    changeLiveEpoch()
    ovLock.unlock()
  }
  static func currentLiveMosaics() -> [CIMosaicSpec]? {
    ovLock.lock()
    defer { ovLock.unlock() }
    return liveMosaics
  }

  /// 換清單。[live] 給了就連部件的即時幾何一起換（同一把鎖、同一
  /// 瞬間）——分兩發送的話合成器可能在中間畫出「新圖×舊差量」的
  /// 錯位格；nil＝差量不動
  static func setPreviewOverlays(_ o: [CIOverlaySpec], live: [CompLiveOv]? = nil) {
    ovLock.lock()
    previewOvs = o
    if let xs = live {
      liveOvs = Dictionary(
        xs.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    }
    changeLiveEpoch()
    ovLock.unlock()
  }
  static func currentPreviewOverlays() -> [CIOverlaySpec] {
    ovLock.lock()
    defer { ovLock.unlock() }
    return previewOvs
  }
  /// 清單＋部件差量一次讀（同一把鎖，兩者必定同一版）
  static func previewSnapshot() -> ([CIOverlaySpec], [String: CompLiveOv]) {
    ovLock.lock()
    defer { ovLock.unlock() }
    return (previewOvs, liveOvs)
  }

  /// 讀「即時疊加物」而不是指令裡那份（只有 HDR 預覽合成器開）
  var livePreview: Bool { false }

  /// 讀「即時變形」（兩個預覽合成器都開；匯出不讀）
  var liveComp: Bool { false }

  /// 捏合/拖曳中的即時變形（見 CompLiveXform）：每一格合成時直接
  /// 讀，零重建。只有預覽合成器（livePreview/liveCI）讀它
  static let xfLock = NSLock()
  private static var hiddenImageTracks: Set<Int> = []
  static func setHiddenImageTracks(_ tracks: Set<Int>) {
    xfLock.lock()
    hiddenImageTracks = tracks
    changeLiveEpoch()
    xfLock.unlock()
  }
  static func currentHiddenImageTracks() -> Set<Int> {
    xfLock.lock()
    defer { xfLock.unlock() }
    return hiddenImageTracks
  }
  private static var liveXf: CompLiveXform?
  static func setLiveXform(_ x: CompLiveXform?) {
    xfLock.lock()
    liveXf = x
    changeLiveEpoch()
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
  // 跟 previewOvs 同一把鎖（ovLock）：清單與差量永遠同一版
  private static var liveOvs: [String: CompLiveOv] = [:]
  static func setLiveOvs(_ xs: [CompLiveOv]) {
    ovLock.lock()
    liveOvs = Dictionary(
      xs.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    changeLiveEpoch()
    ovLock.unlock()
  }
  static func currentLiveOvs() -> [String: CompLiveOv] {
    ovLock.lock()
    defer { ovLock.unlock() }
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
  // HDR 要在半浮點工作格式上算，8 位元會把高光截掉。
  //
  // 工作色彩空間一定要「明講是延伸範圍的線性空間」：只給
  // workingFormat 而不給 workingColorSpace 的話，用的是 CI 的預設
  // 工作空間，HLG 來源在轉進去的那一步就沒有「1.0 以上還算數」的
  // 保證——高光（HLG 的 0.75 以上）會被收在 SDR 白以內，輸出雖然
  // 照樣標 2020/HLG，但畫面已經沒有 HDR 的量，看起來就是「HDR 沒了、
  // 整片暗一階」。1.0＝SDR 基準白這個慣例跟預設一樣，所以疊加物那套
  // 夾白（CIColorClamp 到 1）與 ×3 提亮的數學完全不受影響
  // 不是 private：MCStillLoader.hlgProbe 借同一顆 context 量圖片素材
  // 走的那條色彩鏈（CIContext 是執行緒安全的，合成佇列照跑）
  static let ctxHDR: CIContext = {
    var opts: [CIContextOption: Any] = [
      .cacheIntermediates: false,
      .workingFormat: CIFormat.RGBAh,
    ]
    if let ws = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
      opts[.workingColorSpace] = ws
    }
    return CIContext(options: opts)
  }()
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
    // 好幾顆合成器（預覽、匯出、HDR 代理轉檔）各自的佇列同時寫：
    // 字典無鎖併寫會 crash
    slowLock.lock()
    stSkip[why, default: 0] += 1
    let first = stSkip[why] == 1
    slowLock.unlock()
    if first { NSLog("[FastPath] skip=%@", why) }
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

  /// 缺格重播用的底（含馬賽克、不含疊加物）。指令邊界的瞬間，某一軌
  /// 的來源格常常還沒到位——那一格畫黑底就是「接縫閃黑」，改重播
  /// 這份底、疊加物照當下清單重畫（重播整格會把舊樣式的浮水印帶
  /// 回螢幕＝拖滑桿時新→舊→新閃爍）
  private var lastComposedBase: CIImage?
  private lazy var outCS: CGColorSpace = {
    if hdrOut, let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG) {
      return hlg
    }
    return CGColorSpace(name: CGColorSpace.itur_709)
      ?? CGColorSpaceCreateDeviceRGB()
  }()

  // 收原生格式（含 10-bit HDR）。只收 BGRA 的話，HDR 來源會在進到
  // 我們手上之前先被轉成 8-bit BGRA——那一步沒有色調映射，顏色就是
  // 在這裡被沖淡的。收原生 YUV，映射交給下面的 toneMapHDRtoSDR
  //
  // HDR 輸出模式只列 10-bit：這份清單是「我收得下哪些格式」，
  // AVFoundation 從裡面挑一個給我們——8-bit 也在清單上，它就有權
  // 把 HLG 來源先壓成 8-bit 再交過來，高光在進到合成器之前就沒了
  //（上面那段註解講的正是這件事，但清單本身沒有把 8-bit 排除）。
  // Apple 的 HDR 自訂合成器範例只列 420YpCbCr10BiPlanarVideoRange。
  // SDR 路的清單一個字都不動（8-bit 來源照舊直收，不多做轉換）
  var sourcePixelBufferAttributes: [String: Any]? {
    let tenBit: [Int] = [
      Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
      Int(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
    ]
    let anyDepth: [Int] =
      tenBit + [
        Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        Int(kCVPixelFormatType_32BGRA),
      ]
    return [
      kCVPixelBufferPixelFormatTypeKey as String: hdrOut ? tenBit : anyDepth
    ]
  }
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
    queue.async {
      self.lastComposedBase = nil
    }
  }
  func cancelAllPendingVideoCompositionRequests() {
    // 佇列裡還沒開工的請求，開工時看到世代對不上就回報取消
    //（見 startRequest 開頭）；正在合成的那格照常做完
    Self.slowLock.lock()
    reqGen &+= 1
    Self.slowLock.unlock()
  }

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

  /// 拖曳模式（CompPlayer 依 seek 節奏切：暫停中的寬容發＝手指在動；
  /// 精準發／播放／暫停＝結束）。合成器只省「看不見」的工作：診斷
  /// 亮度取樣不做、合成 block 用互動優先權排程。畫布尺寸、層數、
  /// 疊加物、馬賽克一律照常——任何一樣動了就是放手那一刻閃一下
  private static var scrubbing = false
  static func setScrubbing(_ on: Bool) {
    slowLock.lock()
    scrubbing = on
    slowLock.unlock()
  }

  /// 待處理請求的世代：AVFoundation 喊取消（新 seek 打斷、換件）時 +1，
  /// 佇列裡還沒開工的舊格直接回報取消，不白算一張沒人看的畫面——
  /// 拖曳中每發 seek 的那一格不必排在前一發多要的預備格後面
  private var reqGen = 0

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

  /// 片段接縫：合成軌真正切段的時間點（秒，時間軸座標）與它屬於哪一軌。
  ///
  /// 使用者回報的「把影片切成段落放到不同軌道，播到新段落會先卡頓
  /// 一下」就發生在這些點上。組建時從 AVCompositionTrack.segments 直接
  /// 抄下來（不是猜的），播放中每跨過一個就記一次「牆鐘等了多久 vs
  /// 畫面才差多少」——有數字就是真的頓，全部貼著一格的時間就是乾淨。
  /// 供格節奏那條只列「超過 80ms」的點，接縫是不是其中之一還要人去對；
  /// 這條直接把接縫本身列出來，對不對得上不用再猜
  static var seamTimes: [Double] = []
  static var seamNames: [String] = []
  static var seamHits: [String] = []
  static var worstSeamMs = 0.0

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
        // 這一格跨過了哪些片段接縫（見 seamTimes）。門檻刻意是「跨過
        // 就記」而不是「慢了才記」：接縫乾淨也要留下證據，不然報告
        // 上「沒有東西」分不出是沒卡還是根本沒播到那裡
        for (i, s) in seamTimes.enumerated() where s > lastReqT && s <= t {
          if extra > worstSeamMs { worstSeamMs = extra }
          if seamHits.count > 12 { seamHits.removeFirst() }
          seamHits.append(
            String(
              format: "%.2fs%@ 等了 %.0fms（畫面才差 %.0fms）", s,
              i < seamNames.count ? seamNames[i] : "",
              dw * 1000, dt * 1000))
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

  /// HDR 管線探針（每次 App 生命週期記第一格）：合成器「真正收到」
  /// 與「真正交出」的那一格是什麼像素格式、什麼傳遞函數。
  ///
  /// 「加了圖片素材 HDR 就不見」這種回報，兩個嫌疑的畫面長得一模一樣：
  /// (a) 來源在進到合成器之前就被壓成 8-bit／SDR（源那格不是 x420
  /// 加 HLG）、(b) 我們交出去的那格標記不對（出那格不是 HLG）。
  /// 這一行直接分辨，不用再猜
  static var hdrProbe = ""
  private static var hdrProbeDone = false

  /// 一格緩衝的「格式/傳遞函數」摘要（探針用）
  static func describeBuf(_ b: CVPixelBuffer) -> String {
    let f = CVPixelBufferGetPixelFormatType(b)
    let bytes: [UInt8] = [
      UInt8((f >> 24) & 0xFF), UInt8((f >> 16) & 0xFF),
      UInt8((f >> 8) & 0xFF), UInt8(f & 0xFF),
    ]
    let fourCC = String(bytes: bytes, encoding: .ascii) ?? "\(f)"
    let trc =
      (CVBufferGetAttachment(b, kCVImageBufferTransferFunctionKey, nil)?
        .takeUnretainedValue() as? String) ?? "無標記"
    return "\(fourCC)/\(trc)"
  }

  // ── HDR 直拷的逐格數值驗證（每個行程一次）──
  //
  // 實機 144 命中 19 格卻回報黑畫面，之後整條 HDR 快路就被一句 guard 停用。
  // 停用的代價是每一格 HDR 預覽都得走 CI：實機 199 在 900x1600 的畫布上
  // 量到最慢 73ms 一格，而直拷是搬兩個平面、不到 1ms，色彩還是位元級一致。
  //
  // 這裡不直接把 guard 拿掉——沒有真機的情況下重開一條曾經吐黑畫面的路，
  // 就是重演 144。改成「先證明再開」：驗證通過之前每一格照走 CI，螢幕上
  // 永遠是 CI 那份；CI 畫完之後另外把同一格用直拷寫進一顆暫存緩衝，跟 CI
  // 的結果逐點比。兩者是同一張畫面的兩種算法（CI 多繞一趟 YUV→RGB→YUV），
  // 差幾個碼值正常；黑畫面、錯位、range 搞錯都會讓平均差爆掉，當場判不過、
  // 記下數字，之後整個行程不再嘗試。
  enum HDRFastVerdict {
    case pending
    case pass
    case fail(String)
  }

  private static var hdrFastPassed = false
  private static var hdrFastFailure: String?
  private static var hdrFastTries = 0
  private static var hdrFastDetail = ""

  /// 畫面太平（純色、全黑、淡入淡出的頭尾）那幾格驗不出東西：直拷跟 CI
  /// 都會給出同一片平坦，差值當然是 0——那種「通過」證明不了任何事。
  /// 換下一格再驗，但不能無限驗下去（整支都是純色的素材）
  private static let hdrFastMaxTries = 24

  static func hdrFastVerdict() -> HDRFastVerdict {
    slowLock.lock()
    defer { slowLock.unlock() }
    if hdrFastPassed { return .pass }
    if let why = hdrFastFailure { return .fail(why) }
    return .pending
  }

  /// 診斷那一行：驗證到哪一步了。空字串＝這次沒驗過（純 SDR 場次）。
  ///
  /// **呼叫端必須已經持有 slowLock**。healthStats 整段都在鎖裡，而 slowLock
  /// 是 NSLock、不可重入：在那裡呼叫一個自己再鎖一次的 getter，主執行緒會
  /// 鎖死在自己手上，而且是握著 slowLock 死的——每一格合成都會跟著卡在
  /// skip／noteFrame 上，整個 App 只剩強制結束（獨立複查擋下來的）
  static var hdrFastNoteHoldingLock: String {
    if hdrFastPassed { return "通過（\(hdrFastDetail)）" }
    if let why = hdrFastFailure { return "未過（\(why)）" }
    if hdrFastTries == 0 { return "" }
    return "驗證中（已試 \(hdrFastTries) 格）"
  }

  /// 來源這一格是不是標成 2020/HLG（＝跟 tagColors 要蓋上去的一致）。
  ///
  /// 直拷是原樣搬碼值、然後把輸出標成 2020/HLG。來源要是 PQ（HDR10）或是
  /// 被放進 HDR 專案的 709 素材，搬完再貼上 HLG 的標籤就是整片顏色錯——
  /// 那正是 144 的形狀。SDR 那條有對稱的檢查（sdrCompose 看到 HLG/PQ 來源
  /// 就退 CI），HDR 這條以前沒有，是因為整條被擋著沒人走得到
  static func taggedHLG2020(_ b: CVPixelBuffer) -> Bool {
    func tag(_ key: CFString) -> String? {
      CVBufferGetAttachment(b, key, nil)?.takeUnretainedValue() as? String
    }
    return tag(kCVImageBufferTransferFunctionKey)
      == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
      && tag(kCVImageBufferColorPrimariesKey)
        == (kCVImageBufferColorPrimaries_ITU_R_2020 as String)
      // 矩陣也要對。tagColors 蓋的是三個標記，這裡只驗兩個的話，一支標成
      // 2020/HLG 卻帶 709 矩陣的來源會原樣搬過去再被貼上 2020 矩陣＝色度
      // 用錯係數解，又是一次「整片顏色錯」。BT.2100 規定 HLG 配 2020 NCL、
      // VideoToolbox 也是三個一起寫，實務上碰不到——但這裡是防線，不是統計
      && tag(kCVImageBufferYCbCrMatrixKey)
        == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
  }

  /// 兩顆同格式 bi-planar 10-bit 緩衝的逐點差；每 4 列 4 行取一點。
  ///
  /// 回傳的單位是「容器碼值」：10-bit 樣本裝在 16-bit 字裡，靠左靠右各家
  /// 不同，所以門檻一律拿 [spread]（這張畫面自己的動態範圍）當比例尺，
  /// 不寫死絕對值。逐位元組讀再自己併成 16-bit：平面的起始位址與列距
  /// 不保證 2 位元組對齊，直接 assumingMemoryBound(to: UInt16.self) 是
  /// 未定義行為
  static func comparePlanes10(_ a: CVPixelBuffer, _ b: CVPixelBuffer)
    -> (meanY: Double, meanC: Double, spread: Int, peak: Int)?
  {
    guard CVPixelBufferGetPixelFormatType(a)
      == CVPixelBufferGetPixelFormatType(b),
      CVPixelBufferGetPlaneCount(a) == 2, CVPixelBufferGetPlaneCount(b) == 2
    else { return nil }
    guard CVPixelBufferLockBaseAddress(a, .readOnly) == kCVReturnSuccess
    else { return nil }
    guard CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess
    else {
      CVPixelBufferUnlockBaseAddress(a, .readOnly)
      return nil
    }
    defer {
      CVPixelBufferUnlockBaseAddress(a, .readOnly)
      CVPixelBufferUnlockBaseAddress(b, .readOnly)
    }
    var mean = [0.0, 0.0]
    var lo = Int.max
    var hi = Int.min
    for plane in 0..<2 {
      guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, plane),
        let pb = CVPixelBufferGetBaseAddressOfPlane(b, plane)
      else { return nil }
      let w = min(
        CVPixelBufferGetWidthOfPlane(a, plane),
        CVPixelBufferGetWidthOfPlane(b, plane))
      let h = min(
        CVPixelBufferGetHeightOfPlane(a, plane),
        CVPixelBufferGetHeightOfPlane(b, plane))
      let ra = CVPixelBufferGetBytesPerRowOfPlane(a, plane)
      let rb = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
      // Y 一個分量、CbCr 兩個（交錯）
      let comps = plane == 0 ? 1 : 2
      guard w > 0, h > 0, ra >= w * comps * 2, rb >= w * comps * 2
      else { return nil }
      var sum = 0.0
      var n = 0
      var y = 0
      while y < h {
        let rowA = pa.advanced(by: y * ra).assumingMemoryBound(to: UInt8.self)
        let rowB = pb.advanced(by: y * rb).assumingMemoryBound(to: UInt8.self)
        var x = 0
        while x < w {
          for c in 0..<comps {
            let i = (x * comps + c) * 2
            let va = Int(rowA[i]) | (Int(rowA[i + 1]) << 8)
            let vb = Int(rowB[i]) | (Int(rowB[i + 1]) << 8)
            sum += Double(abs(va - vb))
            n += 1
            if plane == 0 {
              lo = min(lo, vb)
              hi = max(hi, vb)
            }
          }
          x += 4
        }
        y += 4
      }
      guard n > 0 else { return nil }
      mean[plane] = sum / Double(n)
    }
    guard hi >= lo else { return nil }
    return (mean[0], mean[1], hi - lo, hi)
  }

  /// 拿 CI 剛畫好的 [reference] 當基準，把同一格改用直拷寫進暫存緩衝比對。
  /// 只在 [hdrFastVerdict] 還是 pending 時呼叫；[reference] 一個位元組都不動
  static func probeHDRFast(
    source: CVPixelBuffer, reference: CVPixelBuffer,
    uvA: SIMD4<Float>, uvB: SIMD2<Float>
  ) {
    slowLock.lock()
    let settled = hdrFastPassed || hdrFastFailure != nil
    if !settled { hdrFastTries += 1 }
    let tries = hdrFastTries
    slowLock.unlock()
    if settled { return }

    /// 第一個寫進去的算數。三顆 HDR 合成器（預覽、匯出、代理轉檔）各有自己
    /// 的佇列，可能同時在驗：兩邊都先看到「還沒定案」再各寫各的，就會出現
    /// 「通過」與「未過」同時成立，而 hdrFastVerdict 先看通過＝失敗被吃掉
    func settle(_ pass: Bool, _ detail: String) {
      slowLock.lock()
      let already = hdrFastPassed || hdrFastFailure != nil
      if !already {
        if pass {
          hdrFastPassed = true
          hdrFastDetail = detail
        } else {
          hdrFastFailure = detail
        }
      }
      slowLock.unlock()
      if !already {
        NSLog("[FastPath] HDR 直拷驗證 %@：%@", pass ? "通過" : "未過", detail)
      }
    }

    /// 這一格驗不出結果（畫面太平、讀不回像素、直拷這一格不吃）：不判死刑，
    /// 換下一格再驗。單一一格的失敗不能代表整條路——現場那條遇到同樣的情形
    /// 也只是退 CI。連 [hdrFastMaxTries] 格都這樣才收工
    func postpone(_ why: String) {
      guard tries >= hdrFastMaxTries else { return }
      settle(false, "連 \(tries) 格都驗不成（\(why)）")
    }

    let fmt = CVPixelBufferGetPixelFormatType(reference)
    guard fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    else {
      settle(false, "輸出不是 10-bit bi-planar")
      return
    }
    var scratch: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, CVPixelBufferGetWidth(reference),
        CVPixelBufferGetHeight(reference), fmt, attrs as CFDictionary,
        &scratch) == kCVReturnSuccess, let probe = scratch
    else {
      postpone("配不出暫存緩衝")
      return
    }
    guard MetalYUVBlit.shared.blit(
      from: source, to: probe, uvA: uvA, uvB: uvB)
    else {
      // 例如來源是 full range、輸出是 video range：直拷本來就該讓開，
      // 那是這一格的事，不是整條路的死刑（現場那條也只是退 CI）
      postpone("直拷回報這一格不吃")
      return
    }
    guard let m = comparePlanes10(probe, reference) else {
      postpone("讀不回像素")
      return
    }
    // 10-bit 樣本裝在 16-bit 字裡，靠左（0~65472）靠右（0~1023）各家不同：
    // 用觀察到的最大值推容器刻度，門檻換一種裝法也還是同一個意思
    let scale = m.peak > 1023 ? 65535 : 1023
    // 平坦的格證明不了任何事（黑畫面也會「通過」），而且門檻是動態範圍的
    // 1/16——動態太小，門檻會縮到比 CI 的來回誤差還小，好格子反而被判死。
    // 要求動態至少有滿刻度的 1/8，換算下來門檻是 8 個碼值
    if m.spread < scale / 8 {
      postpone("畫面太平（動態 \(m.spread)／刻度 \(scale)）")
      return
    }
    // 門檻＝這張畫面自己動態範圍的 1/16。CI 那趟 YUV→RGB→YUV 的來回誤差
    // 遠在這之下；黑畫面或錯位會是好幾成
    let limit = Double(m.spread) / 16
    let detail =
      "亮度差 \(String(format: "%.1f", m.meanY))"
      + "／色差 \(String(format: "%.1f", m.meanC))"
      + "／動態 \(m.spread)／門檻 \(String(format: "%.1f", limit))"
    settle(m.meanY <= limit && m.meanC <= limit, detail)
  }

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

  /// 中央一點亮度（0~1）；黑階＝0.063（video range）
  static func centerLuma(_ buf: CVPixelBuffer) -> Double {
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
    else { return -1 }
    if fmt == kCVPixelFormatType_32BGRA {
      let p = base.advanced(by: (h / 2) * stride + (w / 2) * 4)
        .assumingMemoryBound(to: UInt8.self)
      return (Double(p[0]) + Double(p[1]) + Double(p[2])) / (3 * 255)
    }
    if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    {
      let p = base.advanced(by: (h / 2) * stride + (w / 2))
        .assumingMemoryBound(to: UInt8.self)
      return Double(p[0]) / 255.0
    }
    // 10-bit Y 平面（x420）：16-bit word 取高位
    let p = base.advanced(by: (h / 2) * stride + (w / 2) * 2)
      .assumingMemoryBound(to: UInt16.self)
    return Double(p[0]) / 65535.0
  }

  static func noteLuma(
    _ buf: CVPixelBuffer, t: Double, drawn: Int = -1, missing: Bool = false,
    srcH: CGFloat = -1, canvasH: CGFloat = -1, src: CVPixelBuffer? = nil
  ) {
    // 多顆合成器各自的佇列同時進來（預覽＋HDR 代理轉檔）：陣列無鎖
    // 併寫會 crash，整段鎖住
    slowLock.lock()
    defer { slowLock.unlock() }
    lumaN += 1
    guard lumaN % 30 == 1 else { return }
    let v = centerLuma(buf)
    // 輸出黑而來源亮＝CI 染黑；來源也黑＝解碼器交黑（165 定罪用）
    let sv = src.map(centerLuma)
    lumaProbe.append(
      drawn < 0
        ? String(format: "%.1fs:%.3f", t, v)
        : String(
          format: "%.1fs:%.3f(畫%d層%@ 源高%.0f/布高%.0f%@)", t, v, drawn,
          missing ? "缺源" : "", Double(srcH), Double(canvasH),
          sv.map { String(format: " 源亮%.3f", $0) } ?? ""))
    if lumaProbe.count > 6 { lumaProbe.removeFirst() }
  }

  /// 合成格的累計耗時（ms）：匯出前後各抄一次，差值÷格數＝匯出期間
  /// 每格平均（跟 frameCount 同一把鎖）
  static var totalMs = 0.0

  /// [fast]＝這格走了 Metal 快路：計數在這把鎖底下加（以前在合成
  /// 佇列上無鎖 +=、主執行緒讀，兩邊撞的話數字錯）
  static func noteFrame(
    t: Double, ms: Double, layers: Int, missing: Bool, fast: Bool = false
  ) {
    slowLock.lock()
    frameCount += 1
    totalMs += ms
    if fast { stFastFrames += 1 }
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
    // 世代號在呼叫端（AVFoundation 的執行緒）就取：之後被取消的話，
    // block 開工時對不上就直接回報取消（見 cancelAllPending…）
    Self.slowLock.lock()
    let gen = reqGen
    let scrub = Self.scrubbing
    Self.slowLock.unlock()
    // 拖曳中的格是使用者正在等的畫面：用跟主執行緒同一級的優先權排程
    //（合成佇列沒指定 QoS，會排在 UI 之後；播放／匯出照舊）
    queue.async(qos: scrub ? .userInteractive : .unspecified) {
      autoreleasepool {
        Self.slowLock.lock()
        let stale = self.reqGen != gen
        Self.slowLock.unlock()
        if stale {
          req.finishCancelledRequest()
          return
        }
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
        let captureEpoch = Self.liveEpoch
        func capturePreview(_ missing: Bool) {
          guard self.liveComp, !missing, captureEpoch == Self.liveEpoch else { return }
          ins.scrubCapture?.insert(dst, time: t0, epoch: captureEpoch,
            layout: ins.scrubLayout, range: ins.timeRange, hdr: self.hdrOut)
        }
        let frameMosaics = self.liveComp
          ? (Self.currentLiveMosaics() ?? ins.mosaics) : ins.mosaics
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
        // 這裡只判「這一格夠不夠格走快路」。HDR 還要再過一關數值驗證
        //（見 probeHDRFast）：那是下面 fastSource 的事，不在這裡擋
        func fastEligible() -> CVPixelBuffer? {
          guard frameMosaics.allSatisfy({ t0 < $0.start || t0 >= $0.end })
          else {
            Self.skip("馬賽克")
            return nil
          }
          // 指令裡帶疊加物（匯出把浮水印/文字 PNG 綁在指令裡、由下面
          // 的 CI 路畫）就不能直拷：快路只搬 YUV，命中＝成品整段沒有
          // 浮水印（單一滿版 SDR 片段匯出實測就是這樣掉的）
          guard ins.overlays.isEmpty else {
            Self.skip("疊加物")
            return nil
          }
          // HDR 預覽的浮水印不在指令裡，在「即時清單」（見 previewSnapshot）：
          // SDR 預覽由 Flutter 畫在上面，所以指令那份是空的就夠；HDR 一定要
          // 由合成器烘進去。以前這裡只看 ins.overlays 沒事，是因為 HDR 整條
          // 在最前面就被擋掉了——現在 HDR 進得來，漏掉這道就是「一走快路
          // 浮水印整個不見」
          guard !self.livePreview
            || CIExportCompositor.currentPreviewOverlays().isEmpty
          else {
            Self.skip("即時疊加物")
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
          guard let sbuf = req.sourceFrame(byTrackID: L.trackID) else {
            Self.skip("缺來源格")
            return nil
          }
          // 來源的色彩標記要跟我們待會蓋上去的一致（見 taggedHLG2020）：
          // PQ 來源或被放進 HDR 專案的 709 素材，原樣搬完再貼 HLG 標籤
          // 就是整片顏色錯
          guard !self.hdrOut || Self.taggedHLG2020(sbuf) else {
            Self.skip("來源不是2020/HLG")
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
        // 這一格真的要走快路的來源；nil＝走 CI
        var fastSource: CVPixelBuffer?
        // HDR 還在驗證中：這一格照走 CI，但把來源留著，CI 畫完拿去比對
        var hdrProbeSource: CVPixelBuffer?
        if let sbuf = fastEligible() {
          if !self.hdrOut {
            fastSource = sbuf
          } else {
            switch Self.hdrFastVerdict() {
            case .pass:
              fastSource = sbuf
            case .pending:
              hdrProbeSource = sbuf
              Self.skip("HDR直拷驗證中")
            case .fail(let why):
              Self.skip("HDR直拷未過:\(why)")
            }
          }
        }
        // SDR 預覽的疊加物由 Flutter 畫（wmLive 只在 HDR 開），
        // 即時清單只有 livePreview（HDR）合成器讀——快路不疊任何
        // PNG，跟同一顆合成器的 CI 路一致（否則兩條路交替＝閃）
        if let sbuf = fastSource,
          self.hdrOut
            ? MetalYUVBlit.shared.blit(
              from: sbuf, to: dst, uvA: fastUVA, uvB: fastUVB)
            : MetalYUVBlit.shared.sdrCompose(
              from: sbuf, to: dst, overlays: [],
              uvA: fastUVA, uvB: fastUVB)
        {
          Self.noteFrame(
            t: t0, ms: (CFAbsoluteTimeGetCurrent() - tick) * 1000,
            layers: 1, missing: false, fast: true)
          Self.slowLock.lock()
          let nFast = Self.stFastFrames
          Self.slowLock.unlock()
          if nFast == 1 || nFast % 300 == 0 {
            NSLog("[FastPath] 快路命中 %d 格", nFast)
          }
          self.tagColors(dst)
          capturePreview(false)
          if !scrub {
            Self.noteLuma(
              dst, t: t0, drawn: 1, missing: false,
              srcH: ins.layers.first?.srcHeight ?? -1, canvasH: size.height)
          }
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
        let activeMz = frameMosaics
          .filter { t >= $0.start && t < $0.end }
          .sorted { $0.z < $1.z }
        // 捏合/拖曳中的即時變形：每一格讀一次（只有預覽合成器讀）
        let lx = self.liveComp && !ins.previewCulled
          ? CIExportCompositor.currentLiveXform() : nil
        let hiddenImages: Set<Int> = self.liveComp
          ? CIExportCompositor.currentHiddenImageTracks() : []
        var mzIdx = 0
        var missing = false
        var drawnCount = 0
        var probeSrc: CVPixelBuffer?
        for layer in ins.layers {
          while mzIdx < activeMz.count, activeMz[mzIdx].z <= layer.z {
            out = self.applyMosaic(activeMz[mzIdx], to: out, canvas: size)
            mzIdx += 1
          }
          var img: CIImage
          if layer.trackID == kCMPersistentTrackID_Invalid,
            hiddenImages.contains(layer.z) { continue }
          if layer.trackID != kCMPersistentTrackID_Invalid {
            guard let buf = req.sourceFrame(byTrackID: layer.trackID) else {
              missing = true
              Self.noteMiss(t: t, track: Int(layer.trackID))
              continue
            }
            if probeSrc == nil { probeSrc = buf }
            // HDR（HLG/PQ）來源：開系統的色調映射轉成 SDR，跟相簿、
            // 跟內建合成器同一套曲線。SDR 來源開著沒有影響
            // SDR 輸出＝系統色調映射（跟相簿同一條曲線）；
            // HDR 輸出＝不映射，HDR 像素原封進 HLG 管線
            let base = CIImage(
              cvPixelBuffer: buf,
              options: [.toneMapHDRtoSDR: !self.hdrOut])
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
          // 數學跟 fitTransform／圖片烘的使用者段同構——放手烘定不會
          // 跳位。只作用在被捏的那一段（軌道編號＋片段開頭一起對）。
          // 圖片/GIF 層（trackID＝Invalid）一樣吃這條路：baseline
          // 由建圖時的 uScale/uPx/uPy 帶（見 stillSpecs 那段的
          // CILayerSpec 建構），數學跟影片段完全同構——先前這裡排除
          // trackID＝Invalid，等於烘進合成的圖片素材永遠沒有即時變形，
          // 捏合時只能等 350ms 後的重組（使用者回報「圖片素材放大縮小
          // 不夠跟手」的根）
          var rot = layer.rotation
          var opacity = layer.opacity
          if let lx = lx, lx.z == layer.z,
            abs(lx.start - layer.start) < 0.02
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
            opacity = min(1, max(0, lx.opacity))
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
          let a = layer.alpha(at: t) * opacity
          if a < 0.999 {
            img = Self.applyingOpacity(img, opacity: a)
          }
          out = img.cropped(to: canvasRect).composited(over: out)
          drawnCount += 1
        }
        let tinyGap =
          ins.layers.isEmpty && ins.holdIfEmpty
          && self.lastComposedBase != nil
        if missing || tinyGap, let heldB = self.lastComposedBase {
          // 邊界缺格或極短空窗：重播「不含疊加物」的底，疊加物
          // 照當下清單往下重畫——重播整格＝舊樣式浮水印回魂
          out = heldB
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
          // 底（馬賽克後、疊加物前）留給缺格重播
          self.lastComposedBase = out
        }
        do {
          // 清單與部件差量一次讀（同一把鎖）：不會拿到新圖配舊差量
          let snap: ([CIOverlaySpec], [String: CompLiveOv]) =
            self.livePreview
            ? CIExportCompositor.previewSnapshot()
            : (ins.overlays, [String: CompLiveOv]())
          let ovs = snap.0
          let lovs = snap.1
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
                // 只算部件蓋到的範圍：遮罩外的混色結果本來就等於背景，
                // 裁到部件的 extent 再疊回去，像素一個位元都不變；省的是
                // 原本每個部件各跑一次的整張畫布濾鏡（夾白＋遮罩混色）
                let roi = o.extent.intersection(canvasRect)
                if !roi.isEmpty {
                  out = capped.applyingFilter(
                    "CIBlendWithAlphaMask",
                    parameters: [
                      kCIInputBackgroundImageKey: out,
                      kCIInputMaskImageKey: o,
                    ]
                  ).cropped(to: roi).composited(over: out)
                }
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
        // （上：疊加物區塊——缺格重播也會走到，樣式永遠是當下版）
        self.ctx.render(out, to: dst, bounds: canvasRect, colorSpace: self.outCS)
        self.tagColors(dst)
        capturePreview(missing)
        // HDR 直拷驗證：拿剛畫好的這一格 CI 結果當基準比對（見 probeHDRFast）。
        // 只有「這一格本來就夠格走快路、而且還沒驗出結果」時 hdrProbeSource
        // 才不是 nil；dst 一個位元組都不會被動到
        // captureEpoch 要還是當下那一版：fastEligible 判「沒有即時疊加物、
        // 沒有即時變形」是在 CI 開畫之前讀的，而 CI 這一格要畫幾十毫秒。
        // 期間使用者加了浮水印或起手捏合，CI 就把它們烘進 dst 了——拿那份
        // 去比一份純搬運的直拷，平均差當然爆掉，於是把整條路永久判死，
        // 而診斷上看起來像是直拷真的壞掉。這是在冤枉自己要驗的東西
        //（capturePreview 用的是同一道閘）
        if let ps = hdrProbeSource, !missing, captureEpoch == Self.liveEpoch {
          Self.probeHDRFast(
            source: ps, reference: dst, uvA: fastUVA, uvB: fastUVB)
        }
        // HDR 管線探針：整個 App 生命週期只記第一格（見 hdrProbe）
        if self.hdrOut, let ps = probeSrc {
          Self.slowLock.lock()
          var line: String? = nil
          if !Self.hdrProbeDone {
            Self.hdrProbeDone = true
            Self.hdrProbe =
              "源\(Self.describeBuf(ps))→出\(Self.describeBuf(dst))"
            line = Self.hdrProbe
          }
          Self.slowLock.unlock()
          if let line = line { NSLog("[HDR] %@", line) }
        }
        // 拖曳中不做亮度取樣（要把剛渲染好的緩衝鎖回 CPU 讀一點）：
        // 純診斷，放手那發照樣量
        if !scrub {
          Self.noteLuma(
            dst, t: t0, drawn: drawnCount, missing: missing,
            srcH: ins.layers.first?.srcHeight ?? -1, canvasH: size.height,
            src: probeSrc)
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
  /// 浮水印 PNG 紋理快取。鍵＝CIOverlaySpec.uid（流水號）：以前用
  /// CGImage 位址當鍵，位址會重用（ABA）→ 拿到舊樣式的紋理
  private var ovTexCache: [Int: MTLTexture] = [:]
  private var ovTexOrder: [Int] = []
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
    // 來源與目的要是「同一個」格式，不只是同 bit 深：video range 與 full
    // range 的碼值範圍不同（10-bit video 的亮度是 64~940、full 是 0~1023），
    // 原樣搬過去等於黑階被抬高、高光被壓掉。以前只比 bit 深，HLG full
    // range 的相機檔就會被錯搬進 video range 的輸出緩衝
    let is10 = sf == df && tenBit.contains(sf)
    let is8 = sf == df && eightBit.contains(sf)
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

  private func ovTexture(_ ov: CIOverlaySpec, dev: MTLDevice) -> MTLTexture? {
    let key = ov.uid
    if let t = ovTexCache[key] { return t }
    guard let t = try? MTKTextureLoader(device: dev).newTexture(
        cgImage: ov.cgImg, options: [MTKTextureLoader.Option.SRGB: false as NSNumber])
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
    overlays: [CIOverlaySpec],
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
    for ov in overlays {
      guard let t = ovTexture(ov, dev: dev) else { continue }
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

/// 背景保護：匯出／轉檔／倒轉期間向系統登記「有工作在跑」。
///
/// 沒有這道的話切到背景（來電、通知下拉、按 Home）process 立刻被
/// suspend：進度停在原地、回前景才續，偶發 AVAssetExportSession 直接
/// 回 -11800/-11847。登記後系統至少多給幾十秒把手上的編碼跑完。
/// end() 任何執行緒都能呼叫、呼叫幾次都只結束一次；到期回呼與 deinit
/// 也會結束，不會留下沒關的登記。只在主執行緒建（UIApplication.shared
/// 在背景緒會被 Main Thread Checker 記一筆）
final class BgTask {
  private let lock = NSLock()
  private var id: UIBackgroundTaskIdentifier = .invalid

  init(_ name: String) {
    id = UIApplication.shared.beginBackgroundTask(withName: name) {
      [weak self] in self?.end()
    }
  }

  func end() {
    lock.lock()
    let i = id
    id = .invalid
    lock.unlock()
    guard i != .invalid else { return }
    if Thread.isMainThread {
      UIApplication.shared.endBackgroundTask(i)
    } else {
      DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(i) }
    }
  }

  deinit { end() }
}

/// 半精度（IEEE 754 binary16）→ Float。arm64 有 Float16 型別；x86_64
/// 模擬器（Intel Mac）沒有，Float16(bitPattern:) 直接編不過——只有
/// 診斷抽樣在用，手動展開就夠
func mcHalfToFloat(_ bits: UInt16) -> Float {
  #if arch(arm64)
    return Float(Float16(bitPattern: bits))
  #else
    let sign: Float = (bits & 0x8000) != 0 ? -1 : 1
    let e = Int((bits >> 10) & 0x1F)
    let m = Int(bits & 0x3FF)
    if e == 0 { return sign * Float(m) * Float(pow(2.0, -24.0)) }
    if e == 31 { return m == 0 ? sign * Float.infinity : Float.nan }
    return sign * (1 + Float(m) / 1024) * Float(pow(2.0, Double(e - 15)))
  #endif
}

/// 最多兩顆互動抽幀器，所有存取都由 AppDelegate.frameQueue 串行化。
/// 重用 generator 可保留 AVFoundation 自己的狀態，但不保證硬體 decoder 常駐。
final class MCFrameGeneratorPool {
  private struct Key: Equatable {
    let path: String
    let fileBytes: Int64
    let modified: TimeInterval
    let maxH: Int

    func sameFileVersion(as other: Key) -> Bool {
      path == other.path && fileBytes == other.fileBytes && modified == other.modified
    }
  }
  private struct Entry {
    let key: Key
    let generator: AVAssetImageGenerator
  }
  private var entries: [Entry] = [] // oldest first
  private(set) var createdCount = 0
  private(set) var hitCount = 0
  var count: Int { entries.count }

  func generator(path: String, maxH: Int) -> AVAssetImageGenerator? {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      let bytes = attrs[.size] as? NSNumber,
      let modified = attrs[.modificationDate] as? Date else {
      remove { $0.path == url.path }
      return nil
    }
    let key = Key(path: url.path, fileBytes: bytes.int64Value,
      modified: modified.timeIntervalSince1970, maxH: maxH)
    // 同一路徑可能被工作檔原地替換；舊 generator 仍握著舊資產，立即淘汰。
    remove { $0.path == key.path && !$0.sameFileVersion(as: key) }
    if let index = entries.firstIndex(where: { $0.key == key }) {
      let entry = entries.remove(at: index)
      entries.append(entry)
      hitCount += 1
      return entry.generator
    }
    while entries.count >= 2 {
      entries.removeFirst().generator.cancelAllCGImageGeneration()
    }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxH, height: maxH)
    if #available(iOS 18.0, *) { generator.dynamicRangePolicy = .matchSource }
    entries.append(Entry(key: key, generator: generator))
    createdCount += 1
    return generator
  }

  private func remove(where predicate: (Key) -> Bool) {
    for entry in entries where predicate(entry.key) {
      entry.generator.cancelAllCGImageGeneration()
    }
    entries.removeAll { predicate($0.key) }
  }

  func removeAll() {
    for entry in entries { entry.generator.cancelAllCGImageGeneration() }
    entries.removeAll()
  }
}

/// Cooperative pause for editor background proxies only. Waiting releases this
/// lock; AV reader/writer state and already encoded samples remain intact.
final class MCInteractivePrepGate {
  private let condition = NSCondition()
  private var interactive = false
  private var pausedAt: CFTimeInterval?
  private var accumulatedPause: CFTimeInterval = 0
  var isInteractive: Bool {
    condition.lock(); defer { condition.unlock() }; return interactive
  }
  func setInteractive(_ value: Bool) {
    condition.lock(); defer { condition.unlock() }
    guard interactive != value else { return }
    let now = CACurrentMediaTime()
    if value { pausedAt = now }
    else if let start = pausedAt { accumulatedPause += now - start; pausedAt = nil }
    interactive = value
    condition.broadcast()
  }
  var pausedDuration: CFTimeInterval {
    condition.lock(); defer { condition.unlock() }
    return accumulatedPause + (pausedAt.map { CACurrentMediaTime() - $0 } ?? 0)
  }
  /// 互動中畫面那條每一格讓多久（30ms ≈ 30fps 素材的 1 倍速）。
  ///
  /// 以前互動中整個停住，直到手指離開。實機 199：使用者進去就一直滑，3.1 秒的
  /// 代理轉了 11.4 秒（0.3 倍速），48 秒那支在滑了十幾秒後還是原檔——而原檔
  /// 拖曳現在九成九走快取呈現（218/221、30ms），轉檔跟它搶的只剩快取沒命中
  /// 那一成的關鍵幀解碼。放慢比停住划算：一直滑也會在一倍速內轉完
  static let interactiveThrottle: TimeInterval = 0.03
  /// 這一格可不可以做：互動中讓 [throttle] 秒再放行（[throttle] 0＝不讓，只看
  /// 取消；聲音那條用它，聲音解碼跟畫面搶不到什麼）。互動結束會提早叫醒。
  /// 回 false＝被取消
  func wait(cancelled: AtomicFlag, throttle: TimeInterval = interactiveThrottle) -> Bool {
    condition.lock(); defer { condition.unlock() }
    if interactive && !cancelled.isSet && throttle > 0 {
      _ = condition.wait(until: Date(timeIntervalSinceNow: throttle))
    }
    return !cancelled.isSet
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let frameGenerators = MCFrameGeneratorPool()
  private let frameQueue = DispatchQueue(label: "markcut.frames")
  private let prepInteractiveGate = MCInteractivePrepGate()

  private func releaseFrameGenerators() {
    // copyCGImage 是同步工作，不能在別條執行緒同時拆 generator。
    // 警告／退背景只排清理，不阻塞主執行緒，當前那格完成後就釋放。
    frameQueue.async { [weak self] in self?.frameGenerators.removeAll() }
  }
  @objc private func frameResourcesNeedRelease(_ notification: Notification) {
    releaseFrameGenerators()
    PlayerHosts.shared.invalidateNativeScrub()
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    NotificationCenter.default.addObserver(self,
      selector: #selector(frameResourcesNeedRelease(_:)),
      name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
    NotificationCenter.default.addObserver(self,
      selector: #selector(frameResourcesNeedRelease(_:)),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self,
      selector: #selector(frameResourcesNeedRelease(_:)),
      name: UIApplication.willEnterForegroundNotification, object: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 正在跑的轉檔工作（取消用）。同時可能有兩支在轉，用 job 編號分開
  private var prepSessions: [Int: AVAssetExportSession] = [:]
  private var prepYieldSessions: Set<Int> = []
  private var prepDeferredSessions: Set<Int> = []

  /// 一趟轉檔（reader/writer：工作檔、HDR 代理、密關鍵幀都走它）的
  /// 取消把手。prepSessions 只管兩段式退路的 ExportSession，主路徑
  /// 以前根本不在名單上：按「先不要等」之後硬體編碼照跑到完，Dart 那
  /// 把「一次一支」的鎖也跟著等到底。鍵是流水號不是 job——同一個 job
  /// 會依序走一趟轉檔→兩段式→密關鍵幀，job 當鍵會互相覆蓋。
  /// 只在主執行緒讀寫（登記在主執行緒、finish 也回主執行緒才註銷）
  private var prepCancels: [Int: () -> Void] = [:]
  private var prepCancelSeq = 0

  /// 音訊 session 的啟用／停用共用這一條序列佇列，順序才不會倒過來
  /// （見 activateAudio）
  fileprivate static let audioQueue = DispatchQueue(label: "markcut.audio")

  /// 相簿挑 GIF：等使用者選完的那次呼叫（一次只會有一個選取器在畫面上）。
  /// 這個要放在 class 本體——Swift 的 extension 放不了儲存屬性
  fileprivate var gifPickReply: FlutterResult?

  /// 正在等的那個選取器。看門狗靠它確認「這一個從來沒被推上去」——
  /// delegate 一被叫到就清掉，看門狗就不會再插手（見 presentGifPicker）
  fileprivate weak var gifPicker: PHPickerViewController?

  /// 第幾次挑。看門狗是延後執行的，這一次結束之後它還會醒來一次；
  /// 沒有這個編號的話，它會去回覆「下一次」那個還開著的呼叫
  fileprivate var gifPickSeq = 0

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerPrepChannel(engineBridge)
    registerDiagChannel(engineBridge)
    registerCompChannel(engineBridge)
    registerExportChannel(engineBridge)
    registerPhotoChannel(engineBridge)
    registerPhotoSaveChannel(engineBridge)
    registerPickChannel(engineBridge)

    // 拖曳預覽的按需抽幀通道。重用 AVAssetImageGenerator，實際取樣時間
    // 由 actualTime 回報；JPEG 粗覽是 tone-map 後的 SDR，不是完整 HDR 顯示。
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "markcut.frames")
    else { return }
    let channel = FlutterMethodChannel(
      name: "markcut/frames", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      if call.method == "release" {
        self.frameQueue.async {
          self.frameGenerators.removeAll()
          DispatchQueue.main.async { result(nil) }
        }
        return
      }
      if call.method == "stats" {
        self.frameQueue.async {
          let stats = ["active": self.frameGenerators.count,
                       "created": self.frameGenerators.createdCount,
                       "reused": self.frameGenerators.hitCount, "capacity": 2]
          DispatchQueue.main.async { result(stats) }
        }
        return
      }
      guard call.method == "frameAt",
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        let ms = args["ms"] as? Int
      else {
        result(nil)
        return
      }
      let maxH = min(8192, max(1, args["maxH"] as? Int ?? 540))
      let detailed = args["detailed"] as? Bool ?? false
      // 拖曳預覽壓得兇一點沒人看得出來；當裁切底圖時會被放大到滿版，
      // 壓縮痕跡就很明顯，呼叫端自己決定
      let jpegQ = CGFloat(args["q"] as? Double ?? 0.7)
      self.frameQueue.async {
        autoreleasepool {
        guard let gen = self.frameGenerators.generator(path: path, maxH: maxH) else {
          DispatchQueue.main.async { result(nil) }
          return
        }
        // HDR（HLG）素材一定要壓回 SDR：copyCGImage 不會自己轉，
        // HLG 像素直接進 JPEG 就是「拖曳預覽顏色超飽和」（實測回報）。
        // 之前用 .forceSDR：它的轉換又平又淡，草稿封面「偏淡比起
        // 原圖」就是它（實測回報）。改成 .matchSource 拿回 HDR 影格，
        // 下面用跟合成播放器/工作檔同一條系統 toneMap 曲線壓 SDR
        // JPEG 僅用於 SDR 粗覽，停手後回到播放器的完整 HDR 顯示。
        // dynamicRangePolicy 是 iOS 18 的 API（16 會編譯失敗，CI 踩過）；
        // 17 以下維持舊行為（拖曳幀偏飽和，放開就正常）
        // .matchSource 已在 pool 建立 generator 時設定。
        // tolMs 只指定可接受的取樣時間窗，不保證回最近關鍵幀或只解一格。
        // 0.15 秒在 30fps 也有數格差距；detailed 回傳真正的 actualTime，
        // 讓快取與 UI 區分「附近的粗覽」和精準定位，不能冒充指針那一格。
        let tolMs = max(0, args["tolMs"] as? Int ?? 150)
        let tol = CMTime(value: Int64(tolMs), timescale: 1000)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        var payload: FlutterStandardTypedData?
        var actualTime = CMTime.invalid
        if let cg = try? gen.copyCGImage(
          at: CMTime(value: Int64(ms), timescale: 1000), actualTime: &actualTime)
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
        var reply: Any? = payload
        if detailed, let payload = payload {
          var map: [String: Any] = ["bytes": payload]
          if actualTime.isValid, actualTime.seconds.isFinite {
            map["actualSeconds"] = actualTime.seconds
          }
          reply = map
        }
        DispatchQueue.main.async { result(reply) }
        }
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
        CIExportCompositor.setHiddenImageTracks(Set(args["hiddenImageTracks"] as? [Int] ?? []))
        let overlays = args["overlays"] as? [[String: Any]] ?? []
        // 純聲音素材（配樂／旁白／從影片提取的聲音）：跟匯出 run 的
        // audios 同一份 schema（見 CompPlayer.build）。舊 Dart 沒送＝空
        let audios = args["audios"] as? [[String: Any]] ?? []
        // 馬賽克/圖片/疊加層要走 CI 合成器：先把濾鏡管線暖起來，
        // 接縫不吃首編譯
        if !mosaics.isEmpty || !stills.isEmpty || !overlays.isEmpty {
          CIExportCompositor.warmUp()
        }
        guard
          p.build(
            clips: clips, texture: (args["texture"] as? Bool) ?? true,
            mosaics: mosaics, stills: stills, hdrOut: hdrOut,
            audios: audios,
            overlays: overlays,
            // 收即時清單的合成器要掛著，就算 overlays 現在是空的
            //（全域浮水印隱藏中；見 CompPlayer.build 的 liveOverlays）
            ovLive: args["ovLive"] as? Bool ?? false,
            // 合成要補到多長（0＝不用補；見 CompPlayer.build）
            timelineDuration: args["timelineDuration"] as? Double ?? 0,
            canvasAspect: args["canvasAspect"] as? Double,
            // HLG 合成裡的圖片素材反 OOTF：沒送＝自動（中灰探針判定），
            // 送了 true/false＝診斷強制值（見 MCStillLoader.load）
            stillInverseOotf: args["stillInverseOotf"] as? Bool)
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
        PlayerHosts.shared.onNativeScrubInvalidated = { [weak p] in
          p?.invalidateNativeScrub()
        }
        PlayerHosts.shared.onNativeScrubStyleChanged = { [weak p] in
          p?.nativeStyleChanged()
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
          "opaqueSourcePaths": p.opaqueSourcePaths.sorted(),
          "nativeScrub": p.nativeScrubSupported,
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
      case "setMosaics":
        guard let a = call.arguments as? [String: Any], let p = self.comp,
          p.liveCIOn, let maps = a["mosaics"] as? [[String: Any]] else {
          result(false)
          return
        }
        CIExportCompositor.setLiveMosaics(
          maps.compactMap { CIMosaicSpec($0, canvas: p.size) })
        p.nudgeRedrawIfPaused()
        result(true)
      case "setHiddenImageTracks":
        guard let a = call.arguments as? [String: Any], let p = self.comp else {
          result(false)
          return
        }
        CIExportCompositor.setHiddenImageTracks(Set(a["tracks"] as? [Int] ?? []))
        p.nudgeRedrawIfPaused()
        result(true)
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
        _ = p.beginLiveLayerEditing()
        let ov = CompLiveXform(
          z: a["z"] as? Int ?? 0,
          start: a["start"] as? Double ?? 0,
          scale: a["scale"] as? Double ?? 1,
          px: a["px"] as? Double ?? 0.5,
          py: a["py"] as? Double ?? 0.5,
          rotation: a["rotation"] as? Double ?? 0,
          opacity: a["opacity"] as? Double ?? 1)
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
        // 暫停中的重畫走「換 vc」不 seek（見 rerenderPaused）
        if a["noNudge"] as? Bool != true {
          p.rerenderPaused()
        }
        result(true)
      case "setOverlays":
        // HDR 預覽的即時疊加物：換清單不重建合成（拖曳/改樣式用）。
        // 暫停中換完由原生換 vc 重畫當下這一格（不 seek，見下）
        let list =
          (call.arguments as? [String: Any])?["overlays"]
          as? [[String: Any]] ?? []
        guard let p = self.comp, p.wmLive, p.ciCanvas.width > 1 else {
          result(false)
          return
        }
        // 差量跟新基準同一把鎖、同一瞬間換上——分兩發的話合成器
        // 可能在中間畫出「新圖×舊差量」的錯位格（實機 161 抖動）。
        // live 沒帶＝差量不動
        let lv = (call.arguments as? [String: Any])?["live"]
          as? [[String: Any]]
        CIExportCompositor.setPreviewOverlays(
          list.compactMap { CIOverlaySpec($0, canvas: p.ciCanvas) },
          live: lv?.compactMap { (m: [String: Any]) -> CompLiveOv? in
            guard let oid = m["id"] as? String else { return nil }
            return CompLiveOv(
              id: oid,
              x: m["x"] as? Double ?? 0.5,
              y: m["y"] as? Double ?? 0.5,
              scale: m["scale"] as? Double ?? 1,
              rot: m["rot"] as? Double ?? 0)
          })
        // 暫停中換清單要逼合成器重畫這一格。改樣式不准碰解碼器：
        // 不 seek（擺動一刻＝對暫停中的解碼器做精準 seek、還可能跨格），
        // 改成把同一份 videoComposition 重產新物件換上——AVFoundation
        // 認物件換了就為現在這個時間重跑合成器，時間軸一動不動
        //（見 rerenderPaused）。wmLive 成立＝CI 一定掛著。
        // noNudge＝呼叫端自己安排重畫（例如緊接一發精準 seek）
        if (call.arguments as? [String: Any])?["noNudge"] as? Bool != true {
          p.rerenderPaused()
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
      case "scrub":
        guard let a = call.arguments as? [String: Any], let p = self.comp else {
          result(["displayed": false, "cacheHit": false]); return
        }
        p.scrub((a["sec"] as? Double) ?? 0,
          exact: (a["exact"] as? Bool) ?? false,
          toleranceMs: a["toleranceMs"] as? Int ?? 150, reply: result)
      case "endScrub":
        guard let p = self.comp else { result(false); return }
        let seconds = (call.arguments as? [String: Any])?["sec"] as? Double
        p.endScrub(at: seconds) { result($0) }
      case "seek":
        if let a = call.arguments as? [String: Any] {
          let wait = a["awaitCompletion"] as? Bool ?? false
          guard let p = self.comp else {
            if wait { result(false) } else { result(nil) }
            return
          }
          let completion: ((Bool) -> Void)? = wait ? { landed in result(landed) } : nil
          p.seek(
            (a["sec"] as? Double) ?? 0, exact: (a["exact"] as? Bool) ?? false,
            toleranceMs: a["toleranceMs"] as? Int,
            completion: completion)
          if wait { return }
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
        self.releaseFrameGenerators()
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

  /// 進行中的匯出（取消用）。可能不只一場：播放偵測報告會另起一場
  /// 2 秒的原生匯出，撞上真匯出時以前共用單一 session/timer 欄位，
  /// 先完成的把後者的計時器跟 session 清掉——真匯出進度停、取消失效。
  /// 每場自己抓自己的計時器，這裡只留清單；完成時只移掉自己
  private var activeExports: [AVAssetExportSession] = []

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
        for s in self.activeExports { s.cancelExport() }
        result(nil)
      case "reverse":
        guard let a = call.arguments as? [String: Any] else {
          result("參數錯誤")
          return
        }
        self.runReverse(a, channel: channel) { err in result(err) }
      case "reverseCancel":
        self.reverseCancel?.set()
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

  /// 進行中那場倒轉的取消旗標：一場一個（reverseWork 抓住自己那個）。
  /// 以前是一個普通 Bool 給所有場次共用：主執行緒寫、背景緒讀沒有
  /// 任何保證，第二場進來還會把第一場的取消洗掉
  private var reverseCancel: AtomicFlag?

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
    let cancel = AtomicFlag()
    reverseCancel = cancel
    // 結束時只清掉「還是自己那一份」的情況：中間又開了新的一場，
    // 屬性已經換成它的，清掉會讓那一場取消不了
    let releaseCancel: () -> Void = { [weak self] in
      guard let self = self, self.reverseCancel === cancel else { return }
      self.reverseCancel = nil
    }
    let bg = BgTask("倒轉")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var err: String? = "內部錯誤"
      if let self = self {
        err = self.reverseWork(
          path: path, start: start, end: end, out: out, maxLong: maxLong,
          cancel: cancel
        ) { v in
          DispatchQueue.main.async {
            channel.invokeMethod("progress", arguments: v)
          }
        }
      }
      DispatchQueue.main.async {
        bg.end()
        releaseCancel()
        done(err)
      }
    }
  }

  private func reverseWork(
    path: String, start: Double, end: Double, out: String, maxLong: Int,
    cancel: AtomicFlag,
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
      if cancel.isSet {
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
          if cancel.isSet || writer.status != .writing { break }
          usleep(5000)
        }
        if cancel.isSet || writer.status != .writing { continue }
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
              if cancel.isSet || writer.status != .writing { break }
              usleep(5000)
            }
            if !cancel.isSet && writer.status == .writing {
              input.append(s2)
            }
            outAudioFrames += Int64(nFrames)
          }
        }
      }
      progress(Double(i + 1) / Double(steps))
    }
    if cancel.isSet {
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
    // 匯出分段：組合成（開每支素材、插軌、建指令）跟編碼分開計
    let tBuild = CACurrentMediaTime()
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
    // HLG 成品裡的圖片素材反 OOTF：沒送＝自動（MCStillLoader.hlgProbe 的
    // 中灰探針判定，跟預覽同一份快取），送了 true/false＝診斷強制值
    let stillInverseOotf = a["stillInverseOotf"] as? Bool
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
    // 主軌最後插進去的媒體（來源軌＋來源區間）：片尾補長要拿它的
    // 尾巴一小格來鋪（見下面「時間軸尾巴」）。
    // asset 一起抓著：AVAssetTrack.asset 是 weak，迴圈裡的 asset 是
    // 區域變數，迴圈跑完就放掉——只留軌道的話補尾巴那一刻軌道已經
    // 沒有主人，insertTimeRange 會拒收（尾段又被切掉）
    var lastMain: (asset: AVURLAsset, src: AVAssetTrack, rng: CMTimeRange)? =
      nil
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
      if destTrack === vTrack {
        lastMain = (asset: asset, src: src, rng: range)
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
    // ── 時間軸尾巴：合成補長到總長 ─────────────────────────────
    //
    // 圖片/文字/貼圖/配樂可能比最後一段影片還晚結束。以前這裡（只有
    // 圖層模式）用 insertEmptyTimeRange 補在主軌尾端——
    // AVMutableCompositionTrack 的標頭明講「you cannot add empty time
    // ranges to the end of a composition track」：加了等於沒加，合成
    // 長度停在最後一格影片，尾段的圖片就默默被切掉；一般模式（尾段
    // 只有文字/浮水印素材）則連補都沒補。改成跟預覽 build 的 fillTail
    // 同一套（本週實機驗過）：拿主軌最後一段的尾巴一小格拉長蓋到總長。
    // 畫面由指令決定——補出來那段的指令不列主軌，所以仍是黑底＋圖層
    var mainEnd = layered ? vTracks[0].end : cursor
    let naturalEnd = layered ? (vTracks.map { $0.end }.max() ?? .zero) : cursor
    let want = CMTime(seconds: timelineDur, preferredTimescale: scale)
    var padded = false
    if timelineDur > naturalEnd.seconds + 0.05, want > mainEnd,
      let m = lastMain
    {
      // 尾巴夾在來源視訊軌的範圍內：Dart 端的 end 多半是整個檔的長度，
      // 聲音軌比視訊軌長的檔，rng.end 會超出視訊軌幾毫秒，
      // 超出的子範圍 AVFoundation 會不會夾、還是直接拒收，查不到保證
      let srcEnd = min(m.rng.end, m.src.timeRange.end)
      let snipDur = CMTime(
        seconds: min(0.2, (srcEnd - m.rng.start).seconds),
        preferredTimescale: scale)
      let snip = CMTimeRange(start: srcEnd - snipDur, duration: snipDur)
      if (try? vTrack.insertTimeRange(snip, of: m.src, at: mainEnd)) != nil {
        vTrack.scaleTimeRange(
          CMTimeRange(start: mainEnd, duration: snip.duration),
          toDuration: want - mainEnd)
        mainEnd = want
        if layered { noteVideoEnd(vTrack, want) }
        padded = true
      } else {
        channel.invokeMethod(
          "note", arguments: "匯出尾段補長失敗：尾巴的圖片/文字可能被切掉")
      }
    }
    if layered {
      cursor = max(vTracks.map { $0.end }.max() ?? .zero, mainEnd)
    } else if padded {
      cursor = mainEnd
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
      // 聲音軌各自照自己的長度縮：以前一律縮到 target（＝主軌總長÷
      // 倍速）。主軌現在可能補了尾巴（cursor＝時間軸總長），影片自己的
      // 聲音 [0,V] 就被拉到 want/倍速——變慢又對不上畫面；圖層模式裡
      // 聲音軌比最長視訊軌短時本來就已經是這樣錯的
      for t in aTracks where t.end > .zero {
        t.track.scaleTimeRange(
          CMTimeRange(start: .zero, duration: t.end),
          toDuration: CMTime(
            seconds: t.end.seconds / globalSpeed, preferredTimescale: scale))
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
    // 守門：補了尾巴，合成就該有時間軸那麼長（整體變速已除）。
    // 短了＝鋪媒體沒生效，尾段會被切——寫進診斷，別再默默發生
    if padded, total + 0.05 < timelineDur / globalSpeed {
      channel.invokeMethod(
        "note",
        arguments: String(
          format: "匯出尾段補長沒生效：合成 %.2fs、時間軸 %.2fs", total,
          timelineDur / globalSpeed))
    }

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
    let wantHDR = (a["hdr"] as? Bool ?? false) && hasHDR
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
    // HDR 來源在 GPU 路裡用 toneMapHDRtoSDR 處理（見 startRequest）；
    // 部署目標 15 起一定拿得到那個選項，不必再為舊系統分流
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
        // 載入（色彩／方向／HDR 展開）跟預覽同一個入口：wantHDR＝這份
        // 成品走 HLG，HDR 照片才展開；SDR 成品照舊 8-bit 基底
        guard let path = st["path"] as? String,
          let loaded = MCStillLoader.load(
            path: path, hdr: wantHDR, hint: st["hdr"] as? Bool,
            inverseOotf: stillInverseOotf)
        else { continue }
        var img = loaded
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
            clipStart: st["start"] as? Double ?? 0,
            sourceStart: st["sourceStart"] as? Double ?? 0,
            sourceRate: st["sourceRate"] as? Double ?? 1)
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
      // HLG 成品有圖片素材：把中灰探針的判定＋這次的決定印進 log
      //（探針一個行程一次、早就快取了，這裡只是組字串）
      if wantHDR && !stillsIn.isEmpty {
        NSLog(
          "[HDRStill] 匯出 中灰探針 %@",
          MCStillLoader.hlgReport(override: stillInverseOotf))
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
        // 補長出來的尾巴：主軌在這段有媒體（上面 padded 鋪的），列成
        // 必要來源——跟預覽 makeVC 的 baseTrack 同一個理由（標頭只寫明
        // 「有必要來源的段合成器一定跑」，空陣列沒寫）。沒補長的尾巴
        //（配樂比畫面長、主軌沒媒體）不能列，列了會等不到來源格。
        // 再對著主軌的分段表驗一次：尾段裡若有空段（isEmpty 的 segment
        // 跟尾巴有交集），那格同樣等不到來源，照舊列空
        let tail = CMTimeRange(start: ciCursor, end: comp.duration)
        let tailHasGap = vTrack.segments.contains { sg in
          sg.isEmpty
            && sg.timeMapping.target.intersection(tail).duration.seconds
              > 0.001
        }
        let tailIDs: [NSNumber] =
          padded && comp.duration <= mainEnd && !tailHasGap
          ? [NSNumber(value: vTrack.trackID)] : []
        ciInstructions.append(
          CIExportInstruction(
            timeRange: tail,
            layers: [], mosaics: [], overlays: ciOverlays,
            prerollTrackIDs: tailIDs))
      }
      vc.customVideoCompositorClass =
        wantHDR ? CIExportCompositorHDR.self : CIExportCompositor.self
      vc.instructions = ciInstructions
    } else {
      // 補出來的尾巴也要有指令蓋住（沒有圖層＝黑底），不然合成的
      // 指令沒鋪滿整條，內建合成器那段沒有定義
      if padded, let last = segments.last, comp.duration > last.range.end {
        let tail = AVMutableVideoCompositionInstruction()
        tail.timeRange = CMTimeRange(start: last.range.end, end: comp.duration)
        instructions.append(tail)
      }
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

    // 匯出分段：編碼從這一刻起算；合成器的格數/耗時抄快照，完成時
    // 差值就是這場匯出的每格成本（預覽在匯出期間是暫停的，不會混進來）
    let tEnc = CACurrentMediaTime()
    CIExportCompositor.slowLock.lock()
    let frames0 = CIExportCompositor.frameCount
    let ciMs0 = CIExportCompositor.totalMs
    let fast0 = CIExportCompositor.stFastFrames
    CIExportCompositor.slowLock.unlock()
    let presetName = preset

    activeExports.append(session)
    // 背景保護（見 BgTask）：切到背景硬體編碼才不會被 suspend 卡住
    let bg = BgTask("匯出")
    // 計時器是這一場自己的（不是共用欄位）：兩場併發時才不會互相清掉
    let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
      [weak session] _ in
      guard let session = session else { return }
      channel.invokeMethod("progress", arguments: Double(session.progress))
    }
    session.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        timer.invalidate()
        self?.activeExports.removeAll { $0 === session }
        bg.end()
        if session.status == .completed || session.status == .failed {
          let encS = CACurrentMediaTime() - tEnc
          CIExportCompositor.slowLock.lock()
          let frames = CIExportCompositor.frameCount - frames0
          let ciMs = CIExportCompositor.totalMs - ciMs0
          let fast = CIExportCompositor.stFastFrames - fast0
          CIExportCompositor.slowLock.unlock()
          channel.invokeMethod(
            "note",
            arguments: String(
              format:
                "原生匯出分段：組合成 %dms｜編碼 %.1fs（成品 %.1fs → %.1f 倍速、%@）"
                + "｜合成器 %d 格、平均 %.1fms/格、快路 %d 格",
              Int((tEnc - tBuild) * 1000), encS, total,
              encS > 0 ? total / encS : 0, presetName, frames,
              frames > 0 ? ciMs / Double(frames) : 0, fast))
        }
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
        // 那 100~300ms 以前是在主執行緒同步付的：進編輯器那一下 UI 就
        // 凍這麼久。AVAudioSession 允許從任何執行緒呼叫，搬到背景。
        //
        // 一定要跟 deactivateAudio 共用同一條「序列」佇列：Dart 兩邊都是
        // unawaited，進編輯器隨即離開時，啟用還在背景跑、停用卻已經在
        // 別的執行緒做完了，session 最後停在 active
        AppDelegate.audioQueue.async {
          let t0 = CACurrentMediaTime()
          let session = AVAudioSession.sharedInstance()
          try? session.setCategory(.playback, options: [.mixWithOthers])
          try? session.setActive(true)
          let ms = Int((CACurrentMediaTime() - t0) * 1000)
          DispatchQueue.main.async { result(ms) }
        }
        return
      }
      if call.method == "deactivateAudio" {
        AppDelegate.audioQueue.async {
          try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
          DispatchQueue.main.async { result(nil) }
        }
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
      let free = Double(os_proc_available_memory()) / mb
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
      case "setInteractive":
        let args = call.arguments as? [String: Any]
        let busy = args?["interactive"] as? Bool ?? false
        self.prepInteractiveGate.setInteractive(busy)
        if busy {
          // AVAssetExportSession has no sample-boundary pause API. Only its
          // editor-proxy fallback is deferred; real exports are not in this set.
          for job in self.prepYieldSessions {
            self.prepDeferredSessions.insert(job)
            self.prepSessions[job]?.cancelExport()
          }
        }
        result(nil)
      case "cancel":
        for s in self.prepSessions.values { s.cancelExport() }
        // 一趟轉檔／HDR 代理／密關鍵幀（reader/writer）：見 prepCancels。
        // 每個把手會自己（回主執行緒）從名單註銷，這裡照名單走完就好
        for c in self.prepCancels.values { c() }
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
        // safe＝Dart 端說上一次轉出來的不能用（轉好卻全黑那種），這一次
        // 要跳過第一段、直接走保守參數（Android 的 rungsFor 同一個意思）。
        // 以前 iOS 完全不讀它：重試就是同參數再轉一次。
        // 注意 HDR 代理那條沒有「更保守的參數」可退（下面 hdr 分支直接
        // return），safe 對它沒有意義——那條的重試就是原封不動再跑一次
        let safe = args["safe"] as? Bool ?? false
        let interactiveYield = args["interactiveYield"] as? Bool ?? false
        // HDR 直通代理：HLG 10-bit、不映射、密關鍵幀。
        // 失敗就回 nil（呼叫端照播原檔），不走兩段式退路——
        // 退路轉出來是 SDR，對 HDR 預覽是錯的畫面
        if args["hdr"] as? Bool ?? false {
          self.transcodeWorkFile(
            src: src, dest: dest, maxShortSide: maxShortSide,
            channel: channel, label: "HDR 代理一趟轉好", job: job,
            hdrPass: true, interactiveYield: interactiveYield
          ) { err in result(err == nil ? dest : nil) }
          return
        }
        // 已經符合規格的素材直接用原檔，一格都不用重編。
        // 自己匯出過的影片、下載回來的 1080p H.264 都會命中。
        // 判定搬到背景：它會同步載軌道、命中前還要掃整支檔的
        // 關鍵幀——在主執行緒跑，多支排隊時 UI 凍住，卡超過
        // 系統容忍就是整個 App 被 watchdog 處決。
        // prechecked＝Dart 端已經掃過整支檔判定不合（它的條件比這裡鬆，
        // 它說不合這裡一定也不合）：別再把關鍵幀數第二遍
        let prechecked = args["prechecked"] as? Bool ?? false
        DispatchQueue.global(qos: .userInitiated).async {
          // safe 時也不能再判「原檔本來就合用」：上一次交出去的可能正是原檔
          if !prechecked, !safe,
            let why = self.alreadyGoodEnough(src, maxShortSide: maxShortSide)
          {
            DispatchQueue.main.async {
              channel.invokeMethod("note", arguments: "素材本來就合用（\(why)）")
              result(src)
            }
            return
          }
          DispatchQueue.main.async {
            self.makeWorkFile(
              src: src, dest: dest, maxShortSide: maxShortSide,
              channel: channel, job: job, safe: safe,
              interactiveYield: interactiveYield
            ) { path in
              if path == AppDelegate.prepDeferredErr { result(["status": "deferred"]) }
              else { result(path) }
            }
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

  /// 取消（prepCancels／prepSessions）時各段回的錯誤字串：makeWorkFile
  /// 看到它就直接收工（回 nil，呼叫端照播原檔），不再往下一段退路走——
  /// 退路照跑的話「先不要等」等於沒按
  private static let prepCancelledErr = "已取消"
  private static let prepDeferredErr = "__markcut_preview_deferred__"

  private func makeWorkFile(
    src: String, dest: String, maxShortSide: Int,
    channel: FlutterMethodChannel, job: Int, safe: Bool = false,
    interactiveYield: Bool = false, done: @escaping (String?) -> Void
  ) {
    let cancelled = AppDelegate.prepCancelledErr
    /// 最後一段退路：系統預設尺寸轉一次，再重排關鍵幀
    let lastResort: () -> Void = { [weak self] in
      // self 沒了就要自己回覆：漏掉的話 Dart 那邊的 Future 永遠掛著，
      // 「一次只轉一支」的鎖也跟著卡死（finish 那條就是這樣寫的）
      guard let self = self else {
        done(nil)
        return
      }
      self.exportOnce(
        src: src, dest: dest, maxShortSide: maxShortSide,
        useComposition: false, channel: channel, job: job, interactiveYield: interactiveYield
      ) { e2 in
        if e2 == AppDelegate.prepDeferredErr { done(AppDelegate.prepDeferredErr); return }
        if e2 == nil {
          self.denseKeyframes(dest, channel: channel, job: job,
                              interactiveYield: interactiveYield) { _ in
            done(dest)
          }
        } else {
          if e2 != cancelled {
            channel.invokeMethod("note", arguments: "工作檔還是失敗：\(e2!)")
          }
          done(nil)
        }
      }
    }
    // safe＝上一次轉出來的不能用：一趟轉檔跟兩段式第一段都跳過，
    // 直接從保守參數起（見 toWorkFile 的 safe）
    if safe {
      channel.invokeMethod(
        "note", arguments: "工作檔保守重試：跳過第一段，直接走系統預設尺寸")
      lastResort()
      return
    }
    // 一趟做完：解碼 → 轉正、縮到 1080、映射回 709 → 密關鍵幀編碼。
    // 兩段式（ExportSession 再重編一次）是舊路徑，留著當保底：慢動作、
    // 時間重映射過的軌有可能讓合成器讀不動，那種素材更需要工作檔
    transcodeWorkFile(
      src: src, dest: dest, maxShortSide: maxShortSide, channel: channel,
      label: "工作檔一趟轉好", job: job, interactiveYield: interactiveYield
    ) { [weak self] err in
      if err == nil {
        done(dest)
        return
      }
      if err == cancelled {
        done(nil)
        return
      }
      channel.invokeMethod(
        "note", arguments: "一趟轉檔沒成功（\(err!)），改用兩段式")
      self?.exportOnce(
        src: src, dest: dest, maxShortSide: maxShortSide,
        useComposition: true, channel: channel, job: job, interactiveYield: interactiveYield
      ) { e1 in
        if e1 == AppDelegate.prepDeferredErr { done(AppDelegate.prepDeferredErr); return }
        if e1 == nil {
          self?.denseKeyframes(dest, channel: channel, job: job,
                               interactiveYield: interactiveYield) { _ in done(dest) }
          return
        }
        if e1 == cancelled {
          done(nil)
          return
        }
        channel.invokeMethod(
          "note", arguments: "工作檔第一次失敗（\(e1!)），改用系統預設尺寸重試")
        lastResort()
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
    interactiveYield: Bool = false,
    done: @escaping (String?) -> Void
  ) {
    // 這一趟寫自己的暫存檔，成功才換到 dest。
    //
    // 取消／逾時是「立刻回覆、writer 稍後才在 group.notify 收掉」——
    // 呼叫端拿到回覆的當下就可能用同一個 dest 開下一次轉檔（兩段式退路
    // 的 exportOnce 就是這樣），而舊的 writer 還活著、還指著那個路徑，
    // cancelWriting 收尾時會不會順手刪掉那個檔沒有保證。各寫各的就沒有
    // 這個問題，順便讓「轉到一半的檔」永遠不會被誤認成成品
    let stage = "\(dest).\(UUID().uuidString).mp4"
    try? FileManager.default.removeItem(atPath: stage)
    if hdrPass {
      DispatchQueue.main.async {
        channel.invokeMethod(
          "note", arguments: "HDR 代理：HLG 直通（HDR 合成器轉正，不動色調）")
      }
    }
    // 匯入分段：開檔（同步解析 moov、載軌道、建 reader/writer）跟
    // 真正的解碼→合成→編碼分開計，完成那行一起印
    let tOpen = CACurrentMediaTime()
    let asset = AVURLAsset(url: URL(fileURLWithPath: src))
    guard let vTrack = asset.tracks(withMediaType: .video).first,
      let reader = try? AVAssetReader(asset: asset),
      let writer = try? AVAssetWriter(
        outputURL: URL(fileURLWithPath: stage), fileType: .mp4)
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
    // hdrPass＝HLG 直通「但走 HDR 合成器」：方向烘死、HLG 標記寫進
    // 檔（跟 HDR 匯出同一顆合成器、同一組標記；像素不做色調映射）。
    // 舊的「零處理不掛合成器」把旋轉旗標與未轉正畫框帶進代理，
    // 預覽合成器吃它時轉正數學對不上＝來源亮、輸出黑
    //（實機 166 探針：交格亮度 0.063、源亮 0.449）
    let isHDR = hdrPass ? true : CompPlayer.isHDRSource(src)
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
    let disp = vTrack.naturalSize.applying(vTrack.preferredTransform)
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
    // 獨立審查定罪（fresh-eyes）：hdrPass 原本走純軌道輸出，
    // 上面蓋好的旋轉合成器整段是死碼——原始橫向畫格被 Resize
    // 硬壓進直式尺寸＝中繼資料完美、像素橫躺變形（「方向反了」
    // 的真根）。兩條路統一走合成器輸出
    let vOut: AVAssetReaderOutput
    do {
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
    // HDR 代理的色彩標記固定 2020/HLG：像素是 CI HDR 合成器渲染進
    // HLG 色彩空間的（outCS＋tagColors 都是 HLG），不能照抄來源——
    // PQ（HDR10）來源抄成 PQ 標記＝像素 HLG、檔頭 PQ，整片顏色錯
    let hdrColor: [String: Any] = [
      AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
      AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
      AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
    ]
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

    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
    // 不再抄旋轉旗標：畫面已由合成器烘正（167 起），再留旗標＝
    // 雙重旋轉——直式素材被當橫式、畫布翻成 1600x900
    //（實機 168：暫停幾次影片比例整個跑掉）
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
      // startWriting 可能已經把檔案建出來了：這條早退不經過 finish，
      // 自己收掉，不然要等 WorkFiles.sweep 有跑到才清得掉
      try? FileManager.default.removeItem(atPath: stage)
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
    let cancelled = AtomicFlag()
    let gate = prepInteractiveGate
    let pauseBaseline = gate.pausedDuration
    let t0 = CACurrentMediaTime()
    var lastReport: CFTimeInterval = 0

    group.enter()
    vIn.requestMediaDataWhenReady(on: vq) {
      while vIn.isReadyForMoreMediaData {
        if interactiveYield, !gate.wait(cancelled: cancelled) {
          vIn.markAsFinished(); group.leave(); return
        }
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
          // 聲音不讓路（throttle 0）：只看取消。畫面那條讓，聲音跟著讓的話
          // 每個 21ms 的音訊格都要等 30ms，反而變成整趟的瓶頸
          if interactiveYield, !gate.wait(cancelled: cancelled, throttle: 0) {
            aIn.markAsFinished(); group.leave(); return
          }
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

    // 只回一次（逾時、取消與正常完成可能撞在一起）
    let replied = AtomicFlag()
    // 取消／逾時只設這個旗標並停掉 reader，writer 一律留給 group.notify
    // 收——cancelWriting 不能跟 appendSampleBuffer 併行（AVAssetWriter
    // 明文規定），而 append 正在 vq／aq 上跑；notify 是兩個迴圈都結束
    // 之後才到的那一點，是唯一安全的地方。
    // reader.cancelReading() 任何執行緒都能叫，叫完 copyNextSampleBuffer
    // 就回 nil，兩個迴圈自己 markAsFinished + leave，notify 隨即到
    // 背景保護（見 BgTask）：切到背景硬體編碼才不會被 suspend 卡住
    let bg = BgTask("工作檔轉檔")
    // 取消把手（見 prepCancels）：這裡（主執行緒）登記，finish 回主
    // 執行緒註銷。watchdog 也在 finish 裡收掉
    prepCancelSeq += 1
    let cancelKey = prepCancelSeq
    var timeoutTimer: DispatchSourceTimer?
    let finish: (String?) -> Void = { [weak self] err in
      guard replied.setIfClear() else { return }
      DispatchQueue.main.async {
        timeoutTimer?.setEventHandler {}
        timeoutTimer?.cancel()
        timeoutTimer = nil
        self?.prepCancels.removeValue(forKey: cancelKey)
        bg.end()
        // 失敗／取消：只清自己的暫存檔，不要碰 dest——那裡可能已經是
        // 下一次嘗試的成品了
        if err != nil { try? FileManager.default.removeItem(atPath: stage) }
        done(err)
      }
    }
    prepCancels[cancelKey] = {
      cancelled.set()
      reader.cancelReading()
      finish(AppDelegate.prepCancelledErr)
    }
    // 逾時保險：硬體編碼器被別的工作佔住時 requestMediaDataWhenReady
    // 可能一直不回來，沒有這道就卡在「工作檔轉不完」，畫面永遠是原檔。
    // 額度隨片長：寫死 120 秒的話長片一趟正常轉檔就會超過、被誤判
    // 逾時砍掉，最後整段編輯拿 4K HDR 原檔播——正是要避免的卡頓。
    // 給「片長的 3 倍」（硬體轉檔實測遠快於實時），下限 120 秒
    // 用 DispatchWorkItem、而且只弱抓 reader/writer：以前的 closure 強抓
    // 著它們排在主佇列上，轉完之後還要等到期（30 分鐘片＝90 分鐘）才放
    let timeoutSec = max(120.0, asset.duration.seconds * 3.0)
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak reader] in
      guard !replied.isSet else { return }
      let paused = interactiveYield ? max(0, gate.pausedDuration - pauseBaseline) : 0
      guard CACurrentMediaTime() - t0 - paused >= timeoutSec else { return }
      cancelled.set()
      reader?.cancelReading()
      finish("逾時")
    }
    timeoutTimer = timer
    timer.resume()

    group.notify(queue: vq) {
      // 兩個 append 迴圈都收工了：writer 的去留在這裡一次決定，
      // 不會跟 append 併行（見上面 cancelled 的說明）
      if cancelled.isSet || failed.isSet {
        reader.cancelReading()
        if writer.status == .writing { writer.cancelWriting() }
        // 取消那條 finish 早就回覆過了（replied 擋著），這一句是給
        // 「中途失敗」用的
        finish(failed.isSet ? "中途失敗" : AppDelegate.prepCancelledErr)
        return
      }
      // writer 自己壞掉（磁碟滿、編碼器出錯）時 status 已經是 .failed：
      // 這種 writer 不能再 finishWriting，但一定要回覆——不回的話要等到
      // 逾時（最長片長×3，30 分鐘的片＝90 分鐘）鎖才放開
      guard writer.status == .writing else {
        finish(writer.error?.localizedDescription ?? "寫入端中止")
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
        // 成功了才換到 dest（同一顆磁碟上的 move，不是複製）
        do {
          try? FileManager.default.removeItem(atPath: dest)
          try FileManager.default.moveItem(atPath: stage, toPath: dest)
        } catch {
          finish("換檔失敗：\(error.localizedDescription)")
          return
        }
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        // 「幾倍速」＝素材秒數 ÷ 轉檔牆鐘：硬體管線（4K HEVC 解→
        // 1080p 合成→HEVC/H.264 編）實測遠快於實時，這個數字掉到
        // 1~2 倍就是有東西在排隊（散熱降頻、別的解碼器在搶）
        let openMs = Int((t0 - tOpen) * 1000)
        let ratio = ms > 0 ? dur * 1000 / Double(ms) : 0
        // finishWriting 的 completion 在 AVFoundation 的背景佇列：platform
        // channel 只能在主執行緒送（跟上面的進度回報同一條規矩）。
        // finish(nil) 自己也回主執行緒，排在這句後面，順序不變
        DispatchQueue.main.async {
          channel.invokeMethod(
            "note",
            arguments: String(
              format: "%@ %dms（開檔 %dms、素材 %.1fs %dx%d@%.0f → %.1f 倍速）",
              label, ms, openMs, dur, Int(size.width), Int(size.height),
              Double(fps), ratio))
        }
        finish(nil)
      }
    }
  }

  /// 已經是工作檔了，只重排關鍵幀（原地換掉）。兩段式那條路才會用到
  private func denseKeyframes(
    _ path: String, channel: FlutterMethodChannel, job: Int,
    interactiveYield: Bool = false,
    done: @escaping (Bool) -> Void
  ) {
    let tmp = path + ".dense.mp4"
    // 進度帶真的 job：以前送 -1，Dart 沒有對應的 callback，兩段式退路
    // 的進度條就卡在上一段的 100% 直到重編完
    transcodeWorkFile(
      src: path, dest: tmp, maxShortSide: 0, channel: channel,
      label: "密關鍵幀重編完成", job: job, interactiveYield: interactiveYield
    ) { err in
      guard err == nil else {
        // 取消不是「重編失敗」：把 prepCancelledErr 塞進提示會變成
        // 「密關鍵幀重編沒成功（已取消，滑動會比較鈍）」，使用者自己
        // 按的取消被講成錯誤。
        // 注意呼叫端照樣拿得到工作檔：這一步是「已經轉好的工作檔再
        // 重排關鍵幀」，取消它只是少了密關鍵幀（滑動鈍一點），檔案
        // 本身是好的，所以 done(dest) 仍然正確
        if err == AppDelegate.prepCancelledErr {
          done(false)
          return
        }
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
    interactiveYield: Bool = false,
    done: @escaping (String?) -> Void
  ) {
    if interactiveYield && prepInteractiveGate.isInteractive {
      done(AppDelegate.prepDeferredErr); return
    }
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
    if interactiveYield { prepYieldSessions.insert(job) }
    // 背景保護（見 BgTask）：切到背景硬體編碼才不會被 suspend 卡住
    let bg = BgTask("工作檔轉檔（兩段式）")
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
        bg.end()
        self?.prepSessions.removeValue(forKey: job)
        self?.prepYieldSessions.remove(job)
        let deferred = self?.prepDeferredSessions.remove(job) != nil
        if deferred {
          try? FileManager.default.removeItem(atPath: dest)
          done(AppDelegate.prepDeferredErr); return
        }
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
          if session.status == .cancelled {
            // 取消（prepSessions）：呼叫端看到它就不再往下一段退路走
            reason = AppDelegate.prepCancelledErr
          } else if let e = session.error as NSError? {
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
/// One composition's final, color-tagged frames. Retaining CVPixelBuffers keeps
/// their IOSurface and color attachments; no JPEG, CPU readback or extra decoder.
/// The lock protects capture on AVFoundation's queue versus main-thread seeks.
final class MCNativeScrubCache {
  struct Frame {
    let buffer: CVPixelBuffer
    let time: Double
    let epoch: Int
    let layout: UInt64
    let range: CMTimeRange
    let hdr: Bool
    let bytes: Int
  }
  private let lock = NSLock()
  private var frames: [Frame] = []
  private var active = true
  private var capturing = true
  private var layout: UInt64 = 0
  private var presentation: UInt64 = 0
  private var center: Double?
  private var lastEpoch = -1
  private var storedBytes = 0
  private var wantsFrames = false
  private var noticeTolerance = 0.15
  private var pendingNotice: Frame?
  private var noticeScheduled = false
  let budget: Int
  let capacity: Int
  var onFrame: ((Frame) -> Void)? // set once, on the main thread, before build
  private var hits = 0
  private var misses = 0
  private var evictions = 0

  init(budget: Int = 48 * 1024 * 1024, capacity: Int = 32) {
    self.budget = max(1, budget)
    self.capacity = max(1, capacity)
  }
  @discardableResult func nextLayout() -> UInt64 {
    lock.lock(); defer { lock.unlock() }
    layout &+= 1
    presentation &+= 1
    frames.removeAll(); storedBytes = 0
    return layout
  }
  func removeAll(dispose: Bool = false, suspend: Bool = false) {
    lock.lock(); defer { lock.unlock() }
    frames.removeAll(); storedBytes = 0; center = nil
    presentation &+= 1
    wantsFrames = false; pendingNotice = nil
    if suspend { capturing = false }
    if dispose { active = false; onFrame = nil }
  }
  func resumeCapturing() {
    lock.lock(); defer { lock.unlock() }; if active { capturing = true }
  }
  @discardableResult func beginPresentation(wantsFrames: Bool = true,
    target: Double? = nil, tolerance: Double = 0.15) -> UInt64 {
    lock.lock(); defer { lock.unlock() }
    self.wantsFrames = wantsFrames; pendingNotice = nil
    if let target = target { center = target }
    noticeTolerance = tolerance
    if !wantsFrames { center = nil }
    presentation &+= 1; return presentation
  }
  func finishPresentation() {
    lock.lock(); defer { lock.unlock() }
    wantsFrames = false; pendingNotice = nil
  }
  func allowNoticeTolerance(_ tolerance: Double) {
    lock.lock(); defer { lock.unlock() }
    if wantsFrames { noticeTolerance = max(noticeTolerance, tolerance) }
  }
  private func deliverLatestNotice() {
    lock.lock()
    let frame = wantsFrames ? pendingNotice : nil
    pendingNotice = nil; noticeScheduled = false
    let notify = onFrame
    lock.unlock()
    if let frame = frame { notify?(frame) }
  }
  func isCurrent(_ frame: Frame, presentation expected: UInt64? = nil) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return active && (expected == nil || expected == presentation)
      && frame.layout == layout && frame.epoch == CIExportCompositor.liveEpoch
  }
  static func accepts(time: Double, target: Double, tolerance: Double,
                      range: CMTimeRange) -> Bool {
    guard time.isFinite, target.isFinite, tolerance.isFinite else { return false }
    // A nearby cached frame must not cross a structural clip boundary.
    return abs(time - target) <= max(0.001, tolerance)
      && target >= range.start.seconds - 0.0001
      && target < range.end.seconds - 0.0001
  }
  func nearest(_ target: Double, tolerance: Double) -> Frame? {
    lock.lock(); defer { lock.unlock() }
    guard active, target.isFinite else { return nil }
    center = target
    let epoch = CIExportCompositor.liveEpoch
    if lastEpoch != epoch { frames.removeAll(); storedBytes = 0; lastEpoch = epoch }
    guard let index = frames.indices.filter({
      Self.accepts(time: frames[$0].time, target: target, tolerance: tolerance,
                   range: frames[$0].range)
    }).min(by: { abs(frames[$0].time - target) < abs(frames[$1].time - target) })
    else { misses += 1; return nil }
    let frame = frames.remove(at: index)
    frames.append(frame) // recently displayed frames survive eviction
    hits += 1
    return frame
  }
  func insert(_ buffer: CVPixelBuffer, time: Double, epoch: Int, layout: UInt64,
              range: CMTimeRange, hdr: Bool) {
    guard time.isFinite else { return }
    // GetDataSize is not reliable for every IOSurface-backed buffer. Sum the
    // actual plane strides, including padding, rather than width*height guesses.
    let planes = CVPixelBufferGetPlaneCount(buffer)
    let bytes = planes == 0
      ? CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
      : (0..<planes).reduce(0) { $0 + CVPixelBufferGetBytesPerRowOfPlane(buffer, $1)
          * CVPixelBufferGetHeightOfPlane(buffer, $1) }
    lock.lock()
    guard active, capturing, layout == self.layout, epoch == CIExportCompositor.liveEpoch,
      bytes > 0, bytes <= budget else { lock.unlock(); return }
    if lastEpoch != epoch { frames.removeAll(); storedBytes = 0; lastEpoch = epoch }
    let frame = Frame(buffer: buffer, time: time, epoch: epoch, layout: layout,
                      range: range, hdr: hdr, bytes: bytes)
    if let index = frames.firstIndex(where: { abs($0.time - time) < 0.001 }) {
      storedBytes -= frames.remove(at: index).bytes
    }
    // Natural playback/preroll warms the neighborhood; never issue speculative
    // seeks. Keep a four-second window and a separate hard byte/count ceiling.
    let around = center ?? time
    frames.removeAll { old in
      if abs(old.time - around) > 2 { storedBytes -= old.bytes; evictions += 1; return true }
      return false
    }
    frames.append(frame); storedBytes += bytes
    while storedBytes > budget || frames.count > capacity {
      storedBytes -= frames.removeFirst().bytes; evictions += 1
    }
    // One pending notice, never one main-queue closure retaining each video
    // frame. A busy UI cannot bypass the cache budget by queuing CVPixelBuffers.
    var schedule = false
    if wantsFrames, let target = center,
      Self.accepts(time: time, target: target, tolerance: noticeTolerance, range: range) {
      if pendingNotice == nil || abs(time - target) < abs(pendingNotice!.time - target) {
        pendingNotice = frame
      }
      if !noticeScheduled { noticeScheduled = true; schedule = true }
    }
    lock.unlock()
    if schedule { DispatchQueue.main.async { [weak self] in self?.deliverLatestNotice() } }
  }
  func stats() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return ["frames": frames.count, "bytes": storedBytes, "budgetBytes": budget,
            "capacity": capacity, "hits": hits, "misses": misses,
            "evictions": evictions, "warming": "natural-playback-and-preroll"]
  }
}

/// Main-thread receipt: exact settling needs both an AVPlayer seek completion
/// and a genuinely presented drawable. New requests complete old waiters false.
final class MCNativeScrubReceipt {
  private(set) var generation: UInt64 = 0
  private var reply: (([String: Any]) -> Void)?
  private var exact = false
  private var seekOK = false
  private var presented: (time: Double, hit: Bool)?
  var isPending: Bool { reply != nil }
  func invalidatePresentation() { presented = nil }
  func acceptsPresentation(_ id: UInt64, presentation: UInt64,
                           currentPresentation: UInt64?) -> Bool {
    id == generation && currentPresentation == presentation
  }
  @discardableResult func begin(exact: Bool, reply: @escaping ([String: Any]) -> Void) -> UInt64 {
    cancel()
    self.exact = exact; self.reply = reply
    return generation
  }
  func cancel() {
    generation &+= 1
    let old = reply; reply = nil; seekOK = false; presented = nil
    old?(["displayed": false, "cacheHit": false])
  }
  func didSeek(_ id: UInt64, ok: Bool) {
    guard id == generation else { return }
    if !ok { cancel(); return }
    seekOK = true; finishIfReady()
  }
  func didPresent(_ id: UInt64, time: Double, cacheHit: Bool) {
    guard id == generation, time.isFinite else { return }
    presented = (time, cacheHit); finishIfReady()
  }
  private func finishIfReady() {
    guard let frame = presented, !exact || seekOK, let done = reply else { return }
    reply = nil
    done(["displayed": true, "actualSeconds": frame.time, "cacheHit": frame.hit])
  }
}

/// A pause/new gesture cancels an asynchronous play-after-alignment intent
/// without destroying an unrelated in-flight scrub receipt.
final class MCNativePlaybackIntent {
  private var generation: UInt64 = 0
  @discardableResult func replace() -> UInt64 { generation &+= 1; return generation }
  func isCurrent(_ token: UInt64) -> Bool { token == generation }
}

/// One physical seek/presentation at a time, plus the latest requested target.
/// Superseding a reply does not cancel the frame already being decoded: a seek
/// completion can arrive before CI has produced that frame. Draining here only
/// after presentation prevents a stream of 1 ms seek callbacks starving CI.
final class MCNativeScrubRequests {
  final class Request {
    let id: UInt64
    let seconds: Double
    let exact: Bool
    let toleranceMs: Int
    private var reply: (([String: Any]) -> Void)?
    init(id: UInt64, seconds: Double, exact: Bool, toleranceMs: Int,
         reply: @escaping ([String: Any]) -> Void) {
      self.id = id; self.seconds = seconds; self.exact = exact
      self.toleranceMs = toleranceMs; self.reply = reply
    }
    func finish(_ result: [String: Any]) {
      let done = reply; reply = nil; done?(result)
    }
    func supersede() { finish(["displayed": false, "cacheHit": false, "reason": "superseded"]) }
  }
  var onStart: ((Request) -> Void)?
  private(set) var active: Request?
  private(set) var pending: Request?
  private var nextID: UInt64 = 0
  private(set) var coalesced = 0
  func submit(seconds: Double, exact: Bool, toleranceMs: Int,
              reply: @escaping ([String: Any]) -> Void) {
    nextID &+= 1
    let request = Request(id: nextID, seconds: seconds, exact: exact,
                          toleranceMs: toleranceMs, reply: reply)
    if active != nil {
      active?.supersede(); pending?.supersede()
      pending = request; coalesced += 1
    } else {
      active = request; onStart?(request)
    }
  }
  func complete(_ id: UInt64, result: [String: Any]) {
    guard let finished = active, finished.id == id else { return }
    active = nil
    let next = pending; pending = nil
    // Install ownership before invoking user callbacks, which may re-enter.
    active = next
    finished.finish(result)
    if let next = next, active === next { onStart?(next) }
  }
  func cancel() {
    let old = active; let next = pending
    active = nil; pending = nil
    old?.supersede(); next?.supersede()
  }
}

/// Display only: effects already ran through CIExportCompositor. A tagged HLG
/// output remains encoded HLG into a half-float layer, avoiding an undocumented
/// linear-HLG normalization/SDR-white multiplier. Apple's color-space display
/// path handles transfer/OOTF/tone mapping; this class has no effect shaders.
final class MCNativeScrubPlane {
  // CAMetalLayer can display BGR10A2, but Core Image cannot render into that
  // destination on all MTLDevices (CIContextRenderDestination error 5). Half
  // float is supported by both; colorspace still describes ENCODED HLG values.
  static let hdrPixelFormat: MTLPixelFormat = .rgba16Float
  let layer = CAMetalLayer()
  private let device: MTLDevice?
  private let commands: MTLCommandQueue?
  private let context: CIContext?
  private let queue = DispatchQueue(label: "markcut.scrub.present", qos: .userInteractive)
  private let lock = NSLock()
  private var generation: UInt64 = 0
  private var hdr: Bool?
  private var displayedFrame: MCNativeScrubCache.Frame?
  private var displayedValidity: (() -> Bool)?
  private(set) var visible = false
  static var presentationUnavailableReason: String? {
    #if targetEnvironment(simulator)
    // The Simulator Metal SDK omits MTLDrawable.addPresentedHandler. It cannot
    // supply this feature's onscreen receipt, even when offscreen Metal works.
    return "Drawable presentation callbacks are unavailable in the iOS Simulator SDK; run this display test on an iOS device."
    #else
    if #available(iOS 16.0, *), MTLCreateSystemDefaultDevice() != nil { return nil }
    return "Native drawable presentation requires iOS 16 and a Metal device."
    #endif
  }
  static var supported: Bool { presentationUnavailableReason == nil }
  static func canPresent(in view: UIView) -> Bool {
    guard let window = view.window, !view.bounds.isEmpty,
      view.convert(view.bounds, to: window).intersects(window.bounds) else { return false }
    var ancestor: UIView? = view
    while let current = ancestor {
      if current.isHidden || current.alpha <= 0.01 { return false }
      ancestor = current.superview
    }
    return true
  }
  init() {
    let gpu = MTLCreateSystemDefaultDevice()
    device = gpu; commands = gpu?.makeCommandQueue()
    context = gpu.map { CIContext(mtlDevice: $0, options: [
      .cacheIntermediates: false, .workingFormat: CIFormat.RGBAh,
      .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    ]) }
    layer.device = gpu; layer.framebufferOnly = false
    layer.isOpaque = true; layer.isHidden = true; layer.zPosition = 2
    layer.presentsWithTransaction = true
    layer.maximumDrawableCount = 2
  }
  func resize(_ bounds: CGRect, scale: CGFloat) {
    guard layer.frame != bounds || layer.contentsScale != scale else { return }
    let frame = displayedFrame
    let validity = displayedValidity
    invalidate()
    layer.frame = bounds; layer.contentsScale = scale
    layer.drawableSize = CGSize(width: max(1, (bounds.width * scale).rounded()),
                                height: max(1, (bounds.height * scale).rounded()))
    if let frame = frame, let validity = validity, validity() {
      present(frame, valid: validity) { _, _ in }
    }
  }
  func invalidate() {
    lock.lock(); generation &+= 1; lock.unlock()
    visible = false; layer.isHidden = true
    displayedFrame = nil; displayedValidity = nil
  }
  /// 圖層從隱藏露出：先以 1% 不透明度上台（肉眼看不到）並 flush，讓 render
  /// server 先把「這一層可見」收下，drawable 之後才交；呈現成功才拉到 100%
  ///（呈現回呼裡）。回傳 true＝這一次真的是從隱藏露出。
  ///
  /// 以前 isHidden=false 跟 drawable.present() 放同一個巢狀交易：實機 196～198
  /// 三個版本都是九成的 drawable 被系統丟掉（presentedTime 0）。巢狀交易的屬性
  /// 變更要等 run loop 收尾才到 render server，drawable 卻在 present 那一刻就
  /// 交出去、交到一個 render server 眼裡還是隱藏的圖層上；同時圖層已經露出
  ///（露的是黑或上一張），下一格 failNativeScrub 又把它藏回去＝每次失敗閃一下
  ///（實測回報「播放螢幕一直閃動」）。1% 露出＋成功才拉滿：就算還是被丟，
  /// 使用者也看不到閃
  @discardableResult private func reveal() -> Bool {
    guard layer.isHidden else { return false }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer.opacity = 0.01; layer.isHidden = false
    CATransaction.commit()
    CATransaction.flush()
    return true
  }
  private func current(_ id: UInt64) -> Bool {
    lock.lock(); defer { lock.unlock() }; return id == generation
  }
  static func encode(_ frame: MCNativeScrubCache.Frame, to texture: MTLTexture,
                     command: MTLCommandBuffer, context: CIContext) throws {
    let rect = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
    var image = CIImage(cvPixelBuffer: frame.buffer, options: [.toneMapHDRtoSDR: false])
    let factor = min(rect.width / image.extent.width, rect.height / image.extent.height)
    image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    image = image.transformed(by: CGAffineTransform(
      translationX: (rect.width - image.extent.width) / 2,
      y: (rect.height - image.extent.height) / 2))
      .composited(over: CIImage(color: .black).cropped(to: rect))
    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: command)
    destination.colorSpace = CGColorSpace(name: frame.hdr ? CGColorSpace.itur_2100_HLG
                                                         : CGColorSpace.itur_709)
    destination.isFlipped = true // Metal drawable origin is top-left
    _ = try context.startTask(toRender: image, from: rect, to: destination, at: .zero)
  }
  func present(_ frame: MCNativeScrubCache.Frame,
               valid: @escaping () -> Bool, done: @escaping (Bool, String?) -> Void) {
    let replied = AtomicFlag()
    let finish: (Bool, String?) -> Void = { ok, reason in
      if replied.setIfClear() { done(ok, reason) }
    }
    guard Self.supported, layer.bounds.width > 0, layer.bounds.height > 0,
      let commands = commands, let context = context else { finish(false, "surface-unavailable"); return }
    if hdr != frame.hdr {
      invalidate(); hdr = frame.hdr
      layer.pixelFormat = frame.hdr ? Self.hdrPixelFormat : .bgra8Unorm
      layer.colorspace = CGColorSpace(name: frame.hdr ? CGColorSpace.itur_2100_HLG
                                                        : CGColorSpace.itur_709)
      if #available(iOS 16.0, *) {
        layer.wantsExtendedDynamicRangeContent = frame.hdr
        // Encoded HDR uses the layer's transfer-function color space. A
        // non-nil edrMetadata requires a LINEAR color space as well as a float
        // format. These half-float pixels still contain encoded HLG, so metadata
        // stays nil. Keep the CVPixelBuffer's HLG/2020 tags and CI conversion;
        // do not apply an additional HLG normalization or SDR-white multiplier.
        // https://developer.apple.com/documentation/quartzcore/cametallayer/edrmetadata
        // https://developer.apple.com/documentation/metal/using-color-spaces-to-display-hdr-content
        layer.edrMetadata = nil
      }
    }
    lock.lock(); generation &+= 1; let id = generation; lock.unlock()
    queue.async { [weak self] in
      autoreleasepool {
      guard let self = self, self.current(id), valid()
      else { DispatchQueue.main.async { finish(false, "render-superseded") }; return }
      guard let drawable = self.layer.nextDrawable() else {
        DispatchQueue.main.async { finish(false, "drawable-unavailable") }; return
      }
      guard let command = commands.makeCommandBuffer() else {
        DispatchQueue.main.async { finish(false, "command-unavailable") }; return
      }
      do {
        try Self.encode(frame, to: drawable.texture, command: command, context: context)
      } catch {
        DispatchQueue.main.async { finish(false, "encode: \(error.localizedDescription)") }; return
      }
      guard self.current(id), valid() else {
        DispatchQueue.main.async { finish(false, "encoded-superseded") }; return
      }
      // 這一張交上去時圖層是不是「剛從隱藏露出」（診斷用：丟格分成兩類）。
      // 主執行緒寫、主執行緒讀：下面 present 的區塊先跑，呈現回呼在它之後
      var revealed = false
      #if !targetEnvironment(simulator)
      drawable.addPresentedHandler { [weak self] drawable in
        DispatchQueue.main.async {
          guard let self = self, self.current(id), valid()
          else { finish(false, "presented-superseded"); return }
          guard drawable.presentedTime > 0 else {
            finish(false, revealed ? "drawable-dropped-fresh" : "drawable-dropped-shown")
            return
          }
          // 真的上了螢幕才把不透明度拉滿（露出那一格是 1% 交上去的，見 reveal）
          if self.layer.opacity < 1 {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.layer.opacity = 1
            CATransaction.commit()
          }
          self.displayedFrame = frame; self.displayedValidity = valid
          finish(true, nil)
        }
      }
      #endif
      command.addCompletedHandler { buffer in
        if buffer.status == .error {
          DispatchQueue.main.async { finish(false, "gpu: \(buffer.error?.localizedDescription ?? "unknown")") }
        }
      }
      // Commit GPU work first, then present on the main thread. A hidden layer
      // is revealed (at 1% opacity, flushed to the render server) BEFORE the
      // drawable is presented, so the presentation always targets a layer the
      // render server already treats as visible; see reveal().
      command.commit()
      command.waitUntilScheduled()
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.current(id), valid(), command.status != .error
        else { finish(false, "scheduled-superseded"); return }
        revealed = self.reveal()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.visible = true
        drawable.present()
        CATransaction.commit()
      }
      }
    }
  }
}

final class PlayerHostView: UIView {
  let scrubPlane = MCNativeScrubPlane()
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
    layer.addSublayer(scrubPlane.layer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) 不支援") }

  override func layoutSubviews() {
    super.layoutSubviews()
    // 圖層 frame 有隱式動畫，轉向/縮放時會拖影——關掉
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layerA.frame = bounds
    layerB.frame = bounds
    scrubPlane.resize(bounds, scale: window?.screen.scale ?? UIScreen.main.scale)
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
  var onNativeScrubInvalidated: (() -> Void)?
  var onNativeScrubStyleChanged: (() -> Void)?

  func nativeScrubStyleChanged() { onNativeScrubStyleChanged?() }

  func invalidateNativeScrub() {
    hideNativeScrub()
    onNativeScrubInvalidated?()
  }
  func hideNativeScrub() {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    for v in views.allObjects { v.scrubPlane.invalidate() }
    CATransaction.commit()
  }
  func presentNativeScrub(_ frame: MCNativeScrubCache.Frame, player: AVPlayer,
                          cache: MCNativeScrubCache, presentation: UInt64,
                          done: @escaping (Bool, String?) -> Void) {
    guard current === player else { done(false, "player-replaced"); return }
    let hosts = views.allObjects.filter { MCNativeScrubPlane.canPresent(in: $0) }
    guard !hosts.isEmpty else { done(false, "no-visible-host"); return }
    var remaining = hosts.count
    var replied = false
    for host in hosts {
      host.scrubPlane.present(frame,
        valid: { cache.isCurrent(frame, presentation: presentation) }) { ok, reason in
        remaining -= 1
        // A covered secondary host may never present. The first actually
        // presented, visible surface is sufficient; it cannot be vetoed later.
        if !replied && (ok || remaining == 0) { replied = true; done(ok, reason) }
      }
    }
  }

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

  /// 換手中的新播放器「還沒對到位」：剛組好的 item 停在 0 秒，
  /// 第一格就緒就翻面會先露一下開頭的畫面，等 Dart 的定位 seek 落地
  /// 才回到停點（實機：進場十秒內按播放/暫停閃一下）。
  /// CompPlayer.build 先 hold，第一發 seek 完成或起播才 release；
  /// 1.5 秒保底照舊硬翻
  private weak var heldPlayer: AVPlayer?
  private var flipWhenReleased: [() -> Void] = []

  func hold(_ p: AVPlayer) {
    heldPlayer = p
    flipWhenReleased.removeAll()
  }

  func release(_ p: AVPlayer) {
    guard heldPlayer === p else { return }
    heldPlayer = nil
    let fs = flipWhenReleased
    flipWhenReleased.removeAll()
    for f in fs { f() }
  }

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
    invalidateNativeScrub()
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
    flipWhenReleased.removeAll()
    guard let p = p else {
      heldPlayer = nil
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
      // 翻面本體。已經翻過的視圖（前層就是 p）直接略過——KVO
      // true→false→true 抖動、或 hold 期間重複排進來，都不會把
      // remaining 多扣（多視圖時另一個視圖的觀察者會被提早作廢）
      let flipNow: () -> Void = { [weak self] in
        guard let self = self, self.gen == g, v.front.player !== p else {
          return
        }
        v.flip()
        oneDone()
      }
      // 第一格就緒但還在 hold（定位 seek 沒落地）：排到 release 再翻
      let flipOrDefer: () -> Void = { [weak self] in
        guard let self = self else { return }
        if self.heldPlayer === p {
          self.flipWhenReleased.append(flipNow)
        } else {
          flipNow()
        }
      }
      if incoming.isReadyForDisplay {
        flipOrDefer()
        continue
      }
      let obs = incoming.observe(\.isReadyForDisplay, options: [.new]) {
        [weak self] layer, _ in
        guard layer.isReadyForDisplay else { return }
        DispatchQueue.main.async {
          guard let self = self, self.gen == g else { return }
          guard v.front.player !== p else { return }
          flipOrDefer()
        }
      }
      pendingObs.append(obs)
    }
    // 保底：素材壞掉 readyForDisplay 永遠不來（或定位 seek 一直沒
    // 落地）——1.5 秒硬翻，寧可閃一下也不能卡在舊畫面（聲音已經是
    // 新的了）
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self, self.gen == g, !finished else { return }
      finished = true
      self.pendingObs.removeAll()
      if self.heldPlayer === p {
        self.heldPlayer = nil
        self.flipWhenReleased.removeAll()
      }
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
  var sourceOpaque: Bool
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
  let opacity: Double
}

final class CompPlayer: NSObject, FlutterTexture {
  /// 只來自這次成功組建真正讀過的來源軌。Dart 冷拖曳只能憑這份證據
  /// 剔除全遮蔽下層，不可把「影片副檔名」當作沒有 alpha 的證明。
  private(set) var opaqueSourcePaths: Set<String> = []
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
  private let nativeScrubCache = MCNativeScrubCache()
  private let nativeScrubReceipt = MCNativeScrubReceipt()
  private let nativeScrubRequests = MCNativeScrubRequests()
  private let nativePlayIntent = MCNativePlaybackIntent()
  private struct NativeGoal {
    let id: UInt64
    let presentation: UInt64
    let target: Double
    var tolerance: Double
    let started: CFTimeInterval
    var rendering = false
  }
  private var nativeGoal: NativeGoal?
  private var nativePresentedTime: Double?
  private var nativeRequestedTarget: Double?
  private(set) var nativeScrubSupported = false
  private var nativePresentedCount = 0
  private var nativeFailedCount = 0
  private var nativeFailureReasons: [String: Int] = [:]
  private var nativeLastFailure: String?
  private var nativePresentMs: [Int] = []
  private var nativeLastPresentedTime: Double?
  private var nativeStyleRedrawArmed = false
  private var nativeStylePresentation: UInt64?

  /// The native path samples the composition's 30 fps time grid. Ceil keeps a
  /// target on an effect/clip boundary from returning the preceding frame.
  static func nativeFrameTarget(_ seconds: Double, duration: Double) -> Double {
    guard seconds.isFinite else { return 0 }
    let last = duration > 0 ? max(0, floor((duration - 0.0001) * 30) / 30) : 0
    return min(last, max(0, ceil(seconds * 30 - 0.000001) / 30))
  }
  /// Tiny redraw inside this frame AND its instruction. In particular, never
  /// apply the legacy nudge's duration-40ms cap to an exact final-frame target.
  static func nativeRedrawTarget(_ target: Double, duration: Double,
                                 instruction: CMTimeRange, avoiding current: Double? = nil) -> Double? {
    let start = instruction.start.seconds
    let end = instruction.end.seconds
    guard target.isFinite, duration.isFinite, start.isFinite, end.isFinite,
      target >= max(0, start), target < min(duration, end) else { return nil }
    let frameEnd = (floor(target * 30 + 0.000001) + 1) / 30
    let upper = min(duration, min(end, frameEnd))
    // Alternate two valid positions when a later style edit is already sitting
    // on the first nudge, so that edit does not become another no-op seek.
    for delta in [min(1.0 / 600.0, (upper - target) / 2),
                  min(2.0 / 600.0, (upper - target) * 0.75)] {
      let actual = CMTime(seconds: target + delta, preferredTimescale: 60_000).seconds
      guard actual > target, actual < upper, actual - target < 0.004 else { continue }
      if let current = current, abs(actual - current) < 1.0 / 120_000 { continue }
      return actual
    }
    return nil
  }
  func invalidateNativeScrub() {
    nativePlayIntent.replace()
    nativeScrubRequests.cancel()
    nativeGoal = nil; nativePresentedTime = nil; nativeRequestedTarget = nil
    nativeStylePresentation = nil
    nativeScrubReceipt.cancel()
    nativeScrubCache.removeAll(suspend: true)
  }
  func nativeStyleChanged() {
    guard nativeScrubSupported, PlayerHosts.shared.current === player else { return }
    nativeScrubCache.removeAll()
    nativeScrubCache.resumeCapturing()
    let previousGoal = nativeGoal
    guard let time = previousGoal?.target ?? nativeRequestedTarget ?? nativePresentedTime,
      player.rate == 0, previousGoal != nil || nativePresentedTime != nil else {
      nativeGoal = nil; nativeScrubReceipt.cancel(); return
    }
    // Hold the last visible frame while existing setter nudge/chase produces a
    // replacement. Revealing the underlying player here can show an older seek.
    // Keep the latest user target and its pending exact-seek receipt. A style
    // update while seeking 1s -> 4s must not replace that request with 1s.
    let id = nativeScrubReceipt.isPending ? nativeScrubReceipt.generation
      : nativeScrubReceipt.begin(exact: false) { _ in }
    nativeScrubReceipt.invalidatePresentation()
    let tolerance = max(0.004, previousGoal?.tolerance ?? 1.0 / 30.0)
    let presentation = nativeScrubCache.beginPresentation(target: time, tolerance: tolerance)
    nativeStylePresentation = presentation
    nativeGoal = NativeGoal(id: id, presentation: presentation, target: time,
      tolerance: tolerance, started: previousGoal?.started ?? CACurrentMediaTime())
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self, self.nativeGoal?.presentation == presentation else { return }
      self.failNativeScrub("style-frame-timeout")
    }
    scheduleNativeStyleRedraw()
  }
  private func scheduleNativeStyleRedraw(retries: Int = 0) {
    guard !nativeStyleRedrawArmed, retries < 30 else { return }
    nativeStyleRedrawArmed = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
      guard let self = self else { return }
      self.nativeStyleRedrawArmed = false
      guard let goal = self.nativeGoal, self.nativeStylePresentation == goal.presentation,
        self.player.rate == 0 else { return }
      if self.seeking || self.nudging || self.player.currentItem?.status != .readyToPlay {
        self.scheduleNativeStyleRedraw(retries: retries + 1); return
      }
      if abs(self.player.currentTime().seconds - goal.target) > 0.004 {
        self.seek(goal.target, exact: true, nativeRequest: true) { [weak self] ok in
          guard let self = self, self.nativeGoal?.presentation == goal.presentation else { return }
          self.nativeScrubReceipt.didSeek(goal.id, ok: ok)
          if ok { self.scheduleNativeStyleRedraw(retries: retries + 1) }
        }
        return
      }
      self.nudgeNativeGoal(goal)
    }
  }
  private func nudgeNativeGoal(_ original: NativeGoal) {
    guard var goal = nativeGoal, goal.presentation == original.presentation,
      !seeking, !nudging, player.rate == 0,
      let instructions = player.currentItem?.videoComposition?.instructions,
      let instruction = instructions.first(where: {
        CMTimeRangeContainsTime($0.timeRange,
          time: CMTime(seconds: goal.target, preferredTimescale: 60_000))
      }),
      let target = Self.nativeRedrawTarget(goal.target, duration: duration,
        instruction: instruction.timeRange, avoiding: player.currentTime().seconds) else { return }
    goal.tolerance = max(goal.tolerance, target - goal.target + 0.0001)
    nativeGoal = goal
    nativeScrubCache.allowNoticeTolerance(goal.tolerance)
    let lifecycle = seekLifecycle
    let presentation = goal.presentation
    nudging = true
    if prerollArmed {
      prerollArmed = false; player.cancelPendingPrerolls()
    }
    player.seek(to: CMTime(seconds: target, preferredTimescale: 60_000),
      toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] ok in
      DispatchQueue.main.async {
        guard let self = self, lifecycle == self.seekLifecycle else { return }
        self.nudging = false
        if !ok, self.nativeGoal?.presentation == presentation {
          self.failNativeScrub("redraw-seek-failed"); return
        }
        // A style update during the in-flight nudge still owns a final redraw.
        if let latest = self.nativeStylePresentation, latest != presentation {
          self.scheduleNativeStyleRedraw()
        }
      }
    }
  }
  private func hideNativeScrub(cancelRequests: Bool = true) {
    if cancelRequests { nativeScrubRequests.cancel() }
    nativeScrubCache.beginPresentation(wantsFrames: false)
    nativeGoal = nil; nativePresentedTime = nil; nativeRequestedTarget = nil
    nativeStylePresentation = nil
    if PlayerHosts.shared.current === player { PlayerHosts.shared.hideNativeScrub() }
    nativeScrubReceipt.cancel()
  }
  private func failNativeScrub(_ reason: String) {
    nativeFailedCount += 1
    let stage = String(reason.prefix(80)).components(separatedBy: ":").first ?? reason
    nativeFailureReasons[stage, default: 0] += 1
    nativeLastFailure = String(reason.prefix(200))
    hideNativeScrub(cancelRequests: false)
  }
  func scrub(_ seconds: Double, exact: Bool, toleranceMs: Int,
             reply: @escaping ([String: Any]) -> Void) {
    nativePlayIntent.replace()
    guard nativeScrubSupported, seconds.isFinite,
      PlayerHosts.shared.current === player else {
      reply(["displayed": false, "cacheHit": false]); return
    }
    nativeScrubRequests.submit(seconds: seconds, exact: exact,
                               toleranceMs: toleranceMs, reply: reply)
  }
  private func performNativeScrub(_ request: MCNativeScrubRequests.Request) {
    nativeStylePresentation = nil
    let exact = request.exact
    let target = Self.nativeFrameTarget(request.seconds, duration: duration)
    // 容忍窗夾在 target 所在的指令段內（見 clampedScrubToleranceMs）。
    // 呈現窗跟 seek 窗用同一個數：以前呈現窗另外 cap 在 150ms，Dart 把原檔
    // 拖動放寬到 500（關鍵幀貼齊、往回滑不重解）之後，seek 落到 400ms 外
    // 的關鍵幀會被快取的 accepts() 拒收、逾時、畫面不動——比不放寬還糟
    let toleranceMs = MCSeekCompletionState.clampedScrubToleranceMs(
      request.toleranceMs, target: target,
      instructions: player.currentItem?.videoComposition?.instructions)
    nativeRequestedTarget = target
    nativeScrubCache.resumeCapturing()
    // 呈現窗比 seek 窗多 1ms：關鍵幀剛好落在窗的邊上時，accepts() 的浮點
    // 比較差一個 ulp 就會拒收。多的這 1ms 跨不到隔壁段——accepts() 另外
    // 要求 target 在那格自己的指令段裡
    let tolerance = exact ? 0.001 : Double(toleranceMs) / 1000 + 0.001
    let id = nativeScrubReceipt.begin(exact: exact) { [weak self] result in
      self?.nativeScrubRequests.complete(request.id, result: result)
    }
    nativeGoal = NativeGoal(id: id, presentation: nativeScrubCache.beginPresentation(
      target: target, tolerance: tolerance),
      target: target, tolerance: tolerance, started: CACurrentMediaTime())
    if let frame = nativeScrubCache.nearest(target, tolerance: tolerance) {
      presentNativeScrub(frame, cacheHit: true)
    }
    let mayBeNoOp = exact && abs(player.currentTime().seconds - target) < 0.001
    // The same chase aligns the AVPlayer under the cached plane. Hits do not
    // create a second decoder or a parallel seek stream.
    seek(target, exact: exact, toleranceMs: toleranceMs, nativeRequest: true) { [weak self] ok in
      guard let self = self, id == self.nativeScrubReceipt.generation else { return }
      guard ok else { self.failNativeScrub("seek-failed"); return }
      self.nativeScrubReceipt.didSeek(id, ok: true)
      if mayBeNoOp {
        // Repeating a seek to the current item time can complete without a new
        // compositor request (e.g. the current frame was evicted after a style
        // or memory reset). Give its existing request/preroll time to finish;
        // only if no frame arrives, ask once for a tiny in-frame redraw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
          guard let self = self, let goal = self.nativeGoal, goal.id == id,
            !goal.rendering, !self.seeking, !self.nudging, self.player.rate == 0,
            abs(self.player.currentTime().seconds - target) < 0.004 else { return }
          if let frame = self.nativeScrubCache.nearest(target, tolerance: goal.tolerance) {
            self.presentNativeScrub(frame, cacheHit: true); return
          }
          self.nudgeNativeGoal(goal)
        }
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + (exact ? 3 : 0.75)) { [weak self] in
      guard let self = self, self.nativeScrubReceipt.generation == id,
        self.nativeScrubReceipt.isPending else { return }
      self.failNativeScrub(self.nativeGoal?.rendering == true
        ? "presentation-timeout" : "composition-frame-timeout")
    }
  }
  private func presentNativeScrub(_ frame: MCNativeScrubCache.Frame, cacheHit: Bool) {
    guard var goal = nativeGoal, !goal.rendering, nativeScrubCache.isCurrent(frame),
      MCNativeScrubCache.accepts(time: frame.time, target: goal.target,
        tolerance: goal.tolerance, range: frame.range) else { return }
    goal.rendering = true; nativeGoal = goal
    PlayerHosts.shared.presentNativeScrub(frame, player: player, cache: nativeScrubCache,
                                          presentation: goal.presentation) {
      [weak self] ok, reason in
      guard let self = self, self.nativeGoal?.id == goal.id,
        self.nativeScrubReceipt.acceptsPresentation(goal.id,
          presentation: goal.presentation,
          currentPresentation: self.nativeGoal?.presentation) else { return }
      if ok {
        self.nativePresentedTime = frame.time
        self.nativeLastPresentedTime = frame.time
        self.nativePresentMs.append(Int((CACurrentMediaTime() - goal.started) * 1000))
        if self.nativePresentMs.count > 200 { self.nativePresentMs.removeFirst() }
        self.nativeGoal = nil
        self.nativeScrubCache.finishPresentation()
        self.nativePresentedCount += 1
        self.nativeScrubReceipt.didPresent(goal.id, time: frame.time, cacheHit: cacheHit)
      } else {
        self.nativeGoal?.rendering = false
        self.failNativeScrub(reason ?? "presentation-failed")
      }
    }
  }
  func endScrub(at seconds: Double?, reply: @escaping (Bool) -> Void) {
    nativePlayIntent.replace()
    nativeScrubRequests.cancel()
    nativeScrubCache.beginPresentation(wantsFrames: false)
    guard let seconds = seconds, seconds.isFinite else {
      hideNativeScrub(); reply(true); return
    }
    nativeScrubReceipt.cancel(); nativeGoal = nil
    let id = nativeScrubReceipt.generation
    seek(seconds, exact: true, nativeRequest: true) { [weak self] ok in
      guard let self = self, id == self.nativeScrubReceipt.generation else {
        reply(false); return
      }
      if ok { self.hideNativeScrub() }
      reply(ok)
    }
  }

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
  private var visibilityState: MCPreviewVisibilityState?

  /// 第一次變形前先恢復所有來源需求。往後縮小／移走／降低透明度時，
  /// 下層解碼器已回到指令裡，不能只更新 CI 靜態參數卻沒有來源可畫。
  func beginLiveLayerEditing() -> Bool {
    guard vcRegen != nil, player.currentItem != nil,
      let state = visibilityState, state.beginEditing() else { return false }
    // 單層或原本就沒有完全遮蔽，不必為了「恢復」重產同一份完整 VC。
    guard state.hasCulledLayers else { return false }
    guard applyXform(lastXformOv, nudge: false) else { return false }
    buildInfo["遮蔽剔除"] = "編輯中停用，保留完整來源"
    return true
  }

  /// 現役的 videoComposition 是不是走「預覽 CI 合成器」——是的話
  /// 即時變形/疊加物只要改靜態參數＋催一格重畫（暫停中：疊加物
  /// 走換 vc 的 rerenderPaused，不 seek），零重建
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
  /// 疊加物（setOverlays/setOvXform）暫停中的重畫已改走 rerenderPaused
  ///（換 vc、不 seek、不碰時間軸）；這裡留給真的要動時間的路
  ///（片段捏合 applyXform 預設仍催、grabFrame 自己挪格）
  private var nudgeFlip = false
  private var nudging = false
  private var nudgePending = false
  private var nudgeTimerArmed = false
  private var lastNudgeAt = 0.0
  /// 催重畫的錨點＝使用者最後停下的位置。每發都以它為基準擺
  /// +1/600、+2/600，不以「現在位置」為基準——那樣每發都往前推
  /// 一刻，拖滑桿一秒就漂過一格（畫面跳、位置回報也跟著漂）。
  /// 使用者 seek／播放／暫停後失效，下一發重新取
  private var nudgeAnchor: CMTime = .invalid
  static var stNudgeFired = 0
  static var stNudgeDropped = 0
  static var stItemSwaps = 0
  /// 催重畫「落地」花多久（毫秒）：冷起手（上一發在 1 秒以前＝暫停很久
  /// 之後的第一版）跟熱發分開記。Dart 端只量得到送出、量不到落地——
  /// 「第一下改樣式先頓一下」是不是暫停中的解碼器冷起手，看這兩組
  static var stNudgeColdMs: [Int] = []
  static var stNudgeWarmMs: [Int] = []
  static func noteNudgeLanded(ms: Int, cold: Bool) {
    if cold {
      stNudgeColdMs.append(ms)
      if stNudgeColdMs.count > 40 { stNudgeColdMs.removeFirst() }
    } else {
      stNudgeWarmMs.append(ms)
      if stNudgeWarmMs.count > 200 { stNudgeWarmMs.removeFirst() }
    }
  }
  static func nudgeLandInfo() -> String {
    func stat(_ a: [Int]) -> String {
      if a.isEmpty { return "—" }
      return "\(a.count)發 平均\(a.reduce(0, +) / a.count)ms 最久\(a.max() ?? 0)ms"
    }
    return "/落地 冷起手 \(stat(stNudgeColdMs))；熱 \(stat(stNudgeWarmMs))"
  }

  /// 暫停中「只換 vc、不 seek」的重畫（見 rerenderPaused）：
  /// 真的換了幾次／被延到窗尾合併掉幾發
  static var stVcSwaps = 0
  static var stVcDeferred = 0
  private var vcSwapTimerArmed = false
  private var vcSwapRetries = 0
  private var lastVcSwapAt = 0.0
  /// 上一次 applyXform 帶上的覆寫：暫停重畫用同一份重產 vc，
  /// 幾何一個位元都不變，只有物件換新（組建時 nil，跟 makeVC(nil) 對齊）
  private var lastXformOv: CompLiveXform?
  /// 暫停重畫的路：true＝換 vc（不碰時間軸）；false＝退回催 seek。
  /// 實機若發現換 vc 不觸發重繪，改這一個字就退回舊路
  /// 實機 174 定案：換 vc 重畫在拖動中每 40ms 重建一次渲染上下文
  /// ＝「第一次拉要讀取、拉一半硬停」；173 的節流催重畫手感較好，
  /// 預設退回。留開關供日後驗證
  static var pausedRedrawViaVC = false

  func nudgeRedrawIfPaused() {
    guard player.rate == 0 else { return }
    if seeking || seekTarget.isValid { return }
    if nudging {
      nudgePending = true
      return
    }
    // 節流 20fps：連續催＝對暫停中的 10-bit 代理做精準 seek 風暴，
    // 解碼器被打到交黑格（實機 165）。窗內來的不丟、排到窗尾補一發
    // ——丟掉的話「最後一次改樣式」可能永遠沒畫到
    let nowN = CACurrentMediaTime()
    let wait = 0.05 - (nowN - lastNudgeAt)
    if wait > 0.001 {
      if !nudgeTimerArmed {
        nudgeTimerArmed = true
        Self.stNudgeDropped += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
          [weak self] in
          guard let self = self else { return }
          self.nudgeTimerArmed = false
          self.nudgeRedrawIfPaused()
        }
      }
      return
    }
    // 落地計時：上一發在 1 秒以前＝冷起手（見 stNudgeColdMs）
    let cold = nowN - lastNudgeAt > 1.0
    lastNudgeAt = nowN
    Self.stNudgeFired += 1
    nudging = true
    nudgeFlip.toggle()
    if !nudgeAnchor.isValid {
      nudgeAnchor = player.currentTime()
      // 播完停在「剛好等於總長」的停點：往前擺就出界——指令只鋪到
      // 總長之前，seek 到總長畫面可能刷成黑的（seek 也是這樣夾的）。
      // 錨點退到最後一格之前，兩個擺幅都留在指令裡
      if duration > 0.1 {
        let cap = CMTime(seconds: duration - 0.04, preferredTimescale: 600)
        if nudgeAnchor > cap { nudgeAnchor = cap }
      }
    }
    // 只往前擺（+1/600 與 +2/600 交替）：± 擺在不巧的停點會跨到
    // 上一格，整片影像每版前後跳一格（獨立審查 #3）
    let eps = CMTime(value: nudgeFlip ? 1 : 2, timescale: 600)
    var t = nudgeAnchor + eps
    if t < .zero { t = CMTime(value: 1, timescale: 600) }
    player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self] _ in
      DispatchQueue.main.async {
        guard let self = self else { return }
        CompPlayer.noteNudgeLanded(
          ms: Int((CACurrentMediaTime() - nowN) * 1000), cold: cold)
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
  /// [nudge] false＝只換 vc、不催 seek（rerenderPaused 用）
  /// 回 false＝這份合成產不出 vc（呼叫端當沒這回事，照舊等重組）
  func applyXform(_ ov: CompLiveXform?, nudge: Bool = true) -> Bool {
    guard let regen = vcRegen, let item = player.currentItem else {
      return false
    }
    item.videoComposition = regen(ov)
    lastXformOv = ov
    liveCIOn = ov != nil || builtNeedsCI
    if nudge && player.rate == 0 {
      nudgeRedrawIfPaused()
    }
    return true
  }

  /// 暫停中催合成器重畫「現在這一格」而不碰時間軸（疊加物換清單／
  /// 改樣式／部件差量用）：把同一份 vc 重產一個新物件換上。
  /// AVFoundation 對 videoComposition 只認「物件換了」——內容相同也會
  /// 為現在這個時間重跑一次合成器；同一個 item、同一個 currentTime、
  /// 沒有 seek、不跨格、不回第 0 格、不換件。合成器每格直讀
  /// previewOvs／liveOvs 快照，所以清單本身不用進指令。
  /// 規矩：
  /// 1. 播放中不催（下一格自然用新快照）
  /// 2. 使用者 seek／催 seek 在飛時不換：排到窗尾再看（最多 1 秒）
  ///    ——那發落地本來就用最新快照重組；換 vc 也不去干擾在飛的 seek
  /// 3. 沒掛 vc 的 item（讓位中 parkedVC／接管中）絕不「掛上」：只換不裝
  /// 4. 40ms 一發、窗內合併成尾發：滑桿風暴不排隊，最後一發一定畫到
  func rerenderPaused() {
    guard Self.pausedRedrawViaVC else {
      nudgeRedrawIfPaused()
      return
    }
    guard player.rate == 0, !takeover, let item = player.currentItem,
      item.videoComposition != nil, item.status == .readyToPlay
    else { return }
    let busy = seeking || seekTarget.isValid || nudging
    let nowN = CACurrentMediaTime()
    let wait = busy ? 0.04 : 0.04 - (nowN - lastVcSwapAt)
    if wait > 0.001 {
      if busy && vcSwapRetries >= 25 {
        vcSwapRetries = 0
        return
      }
      if !vcSwapTimerArmed {
        vcSwapTimerArmed = true
        Self.stVcDeferred += 1
        if busy { vcSwapRetries += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
          [weak self] in
          guard let self = self else { return }
          self.vcSwapTimerArmed = false
          self.rerenderPaused()
        }
      }
      return
    }
    vcSwapRetries = 0
    lastVcSwapAt = nowN
    if applyXform(lastXformOv, nudge: false) {
      Self.stVcSwaps += 1
    }
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

  /// grabFrame 的 CIContext：以前每抓一格就建一顆（管線重編譯、GPU
  /// 資源），加馬賽克／重烘連續觸發時又慢又吃記憶體。共用一顆；
  /// CIContext 本身執行緒安全，grabFrame 在背景緒用它沒問題
  private static let grabCtx = CIContext(options: [.workingColorSpace: NSNull()])

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
    nativeScrubCache.onFrame = { [weak self] frame in
      self?.presentNativeScrub(frame, cacheHit: false)
    }
    nativeScrubRequests.onStart = { [weak self] request in
      self?.performNativeScrub(request)
    }
    // 新合成從一般模式起算（拖曳模式只在拖曳 seek 之間活著）
    CIExportCompositor.setScrubbing(false)
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
  /// [timelineDuration] 合成要補到多長（秒；0＝不用補）。圖片/文字/
  /// 貼圖/配樂拖得比最後一段影片長時，合成的長度只到影片結尾、時鐘
  /// 走到那裡就停住——照這個值把畫面軌鋪到時間軸終點（跟匯出的
  /// timelineDuration 同一個量；鋪法見下面的 fillTail）
  /// [stillInverseOotf] HLG 合成裡的圖片素材反 OOTF 的診斷強制值：
  /// nil＝自動（MCStillLoader.hlgProbe 的中灰探針判定）；SDR 合成不讀
  /// [ovLive] HDR 預覽要收即時疊加物清單（setOverlays）：就算 overlays
  /// 現在是空的（全域浮水印隱藏中）也要掛 CI 合成器、wmLive 打開——
  /// 不然隱藏中重建出來的合成不收清單，打開只能由 Flutter 畫（HDR 上是灰的）
  func build(
    clips: [[String: Any]], texture: Bool, mosaics: [[String: Any]] = [],
    stills: [[String: Any]] = [], hdrOut: Bool = false,
    audios: [[String: Any]] = [],
    overlays: [[String: Any]] = [], ovLive: Bool = false,
    timelineDuration: Double = 0,
    canvasAspect: Double? = nil,
    stillInverseOotf: Bool? = nil
  ) -> Bool {
    cancelSeekRequests()
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
    var opaqueByPath: [String: Bool] = [:]
    var vTracks: [Int: (track: AVMutableCompositionTrack, end: CMTime)] = [:]
    // 每層最後插入的媒體（來源軌＋來源區間），片尾鋪滿（見 needsCI）用
    var lastMedia: [Int: (src: AVAssetTrack, rng: CMTimeRange)] = [:]
    stallCount = 0
    stallNotes = []

    // 聲音也可能同時好幾層（影片自己的聲音＋配樂），一條軌塞不下重疊的
    // 時間範圍——需要幾條就開幾條
    var aTracks: [(track: AVMutableCompositionTrack, end: CMTime)] = []
    var aParams: [AVMutableAudioMixInputParameters] = []

    /// 一段聲音：找一條這個時間點空著的軌（沒有就開新的）、補空白、
    /// 插進去、套音量與淡入淡出。影片自己的聲音跟純聲音素材（下面的
    /// audios）共用這一套——跟匯出 runExport.addAudio 同一份邏輯
    func addAudio(
      _ sa: AVAssetTrack, range: CMTimeRange, at putAt: CMTime,
      outDur: CMTime, volume: Float, fadeIn: Double, fadeOut: Double
    ) {
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
      guard let i = chosen else { return }
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
      // Flutter 畫的白色最多只有基準白，旁邊 HDR 高光一比就是灰的。
      // ovLive＝清單現在空的（浮水印隱藏中）也要掛：之後打開走 setOverlays
      || (hdrOut && anyHDR && (!overlays.isEmpty || ovLive))
      || ordered.contains { c in
        (c["crop"] as? [Double]) != nil
          || abs(c["rotation"] as? Double ?? 0) > 0.05
          || (c["opacity"] as? Double ?? 1) < 0.999
      }
    // 寫進組建內視鏡：下次「進場顏色白白的」的回報，一眼就能看出
    // HDR 判定有沒有中、CI 有沒有掛（上一輪就是缺這格查了半天）
    buildInfo["HDR"] = anyHDR

    // 同一支素材被切成好幾段（使用者最常做的事）時，每段各開一顆
    // AVURLAsset＝同一支檔的 moov 被重新解析好幾次，而 tracks(withMediaType:)
    // 是同步的：4K HEVC 的那幾十毫秒直接記在「按下播放」的帳上。
    // 合成軌記的是 sourceURL＋sourceTrackID（見 AVCompositionTrackSegment），
    // 同一顆 asset 插進不同軌組出來的分段跟分開開一模一樣——共用純賺
    var assetCache: [String: AVURLAsset] = [:]

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

      let asset: AVURLAsset
      if let hit = assetCache[path] {
        asset = hit
      } else {
        asset = AVURLAsset(url: URL(fileURLWithPath: path))
        assetCache[path] = asset
      }
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

      // 聲音：找一條這個時間點空著的軌，沒有就開新的（見 addAudio）
      if let sa = asset.tracks(withMediaType: .audio).first {
        addAudio(
          sa, range: range, at: putAt, outDur: outDur, volume: volume,
          fadeIn: fadeIn, fadeOut: fadeOut)
      }

      let sourceOpaque = MCPreviewVisibility.sourceIsOpaque(src)
      opaqueByPath[path] = (opaqueByPath[path] ?? true) && sourceOpaque
      segments.append(
        CompSeg(
          range: CMTimeRange(start: putAt, duration: outDur),
          transform: src.preferredTransform, size: src.naturalSize,
          fadeIn: fadeIn, fadeOut: fadeOut, userScale: userScale, px: px,
          py: py, mirror: mirror, track: slot.track, layer: layer,
          crop: cropArr, rotation: rotation, opacity: opacity,
          sourceOpaque: sourceOpaque))
    }
    if segments.isEmpty {
      buildError = "沒有一段畫面接得進去"
      return false
    }

    // ── 時間軸尾巴：合成補長到總長 ─────────────────────────────
    //
    // 合成的長度只到最後一段影片的結尾。圖片/文字/貼圖/配樂拖得比影片
    // 長時，播放時鐘走到影片結尾就停住：尾巴既播不到也拖不過去，位置
    // 甚至會跑到比總長還大。Dart 端以前為了這件事整組放棄合成，退回
    // 逐片段材質播放器（8-bit BGRA，根本顯示不了 HDR）——那就是
    // 「加入圖片素材後為啥整個 HDR 效果都不見了」。
    //
    // 量跟匯出同一個（runExport 的 timelineDuration，Dart 端同一個
    // CompPlayer.padTo 算出來的），結果也跟匯出一樣：補出來的那段是
    // 黑底，圖片層由指令照樣畫在上面。
    // 手法故意跟匯出不同——匯出補的是空範圍，而空範圍加不到軌道尾端
    //（見下面 fillTail 的說明），所以這裡改用鋪媒體。
    //
    // naturalEnd＝沒補之前的長度（下面 makeVC 的片尾保底要用它分辨
    // 「本來就有的片尾」跟「補出來的尾巴」）
    let naturalEnd = comp.duration.seconds
    let padEnd = CMTime(seconds: timelineDuration, preferredTimescale: scale)
    // 0.05 的門檻＝真的有尾巴才補（跟 Dart 端 padTo 同一個數）。
    // 沒有尾巴的專案這一整段是 no-op，一格都不動
    let needsPad = timelineDuration > naturalEnd + 0.05

    /// 把第 [layer] 層的畫面軌鋪到 [to]：拿該軌最後一段結尾的一小格
    /// 拉長蓋過去。畫面看到什麼由指令決定、不是由軌道決定——鋪的是
    /// 媒體，但補出來那段的指令沒有列這條軌，所以仍然是黑底
    ///
    /// 補尾巴刻意不用 insertEmptyTimeRange：
    /// AVMutableCompositionTrack 的標頭明說「you cannot add empty time
    /// ranges to the end of a composition track」——加在軌道尾端的空範圍
    /// 等於沒加，合成長度不會變，補了跟沒補一樣。這個檔裡其他六處
    /// insertEmptyTimeRange 全都是「片段之間的洞」（補完緊接著就插媒體），
    /// 只有匯出 runExport 那一處（vTrack.insertEmptyTimeRange(ownEnd~want)）
    /// 是加在尾端，同一個疑點——所以這裡改用已經在跑的鋪滿手法，
    /// 兩種可能下都成立
    func fillTail(_ layer: Int, to: CMTime) {
      guard let slot = vTracks[layer], slot.end < to, let m = lastMedia[layer]
      else { return }
      let snipDur = CMTime(
        seconds: min(0.2, m.rng.duration.seconds), preferredTimescale: scale)
      let snip = CMTimeRange(start: m.rng.end - snipDur, duration: snipDur)
      guard (try? slot.track.insertTimeRange(snip, of: m.src, at: slot.end))
        != nil
      else { return }
      slot.track.scaleTimeRange(
        CMTimeRange(start: slot.end, duration: snip.duration),
        toDuration: to - slot.end)
      vTracks[layer]?.end = to
    }

    // 補長：最底層那條軌先撐到總長（合成的長度＝最長的那條軌）
    if needsPad, let baseLayer = vTracks.keys.min() {
      fillTail(baseLayer, to: padEnd)
    }
    // CI 路線：每條畫面軌「最後一段結束到合成結尾」也要鋪滿——
    // 對自訂合成器來說，軌道提早結束跟空範圍是同一回事（+79 的
    // 軌 0 只到 0.48s、合成長 1.76s，抽格就是這樣壞的）。
    // 合成結尾已經是補長後的總長，其他軌自然一起被帶到那裡
    if needsCI {
      let fillTo = comp.duration
      for layer in vTracks.keys.sorted() { fillTail(layer, to: fillTo) }
    }

    // ── 純聲音素材（配樂／旁白／提取的聲音）：可以跟影片重疊 ────
    //
    // 合成模式接手後逐片段播放器全收掉（含聲音片段），這些聲音不鋪進
    // 合成就是「預覽無聲、匯出有聲」。欄位跟匯出 runExport 的 audios
    // 一模一樣：path／start／end（來源秒）／offset（時間軸秒）／volume／
    // speed／fadeIn／fadeOut；沒送＝空陣列，什麼都不動。
    // 放在補尾巴之後（跟匯出同一個順序）：上面的 naturalEnd／needsPad／
    // fillTail 看的是 comp.duration，聲音先進去會把它撐長、畫面軌就不補
    // ——CI 路線的軌道提早結束＝供格失敗
    for m in audios {
      guard let path = m["path"] as? String else { continue }
      let start = m["start"] as? Double ?? 0
      let end = m["end"] as? Double ?? 0
      if end - start <= 0.01 { continue }
      let at = CMTime(
        seconds: max(0, m["offset"] as? Double ?? 0), preferredTimescale: scale)
      let speed = max(0.05, m["speed"] as? Double ?? 1)
      let range = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: scale),
        duration: CMTime(seconds: end - start, preferredTimescale: scale))
      let outDur =
        abs(speed - 1) > 0.001
        ? CMTime(seconds: (end - start) / speed, preferredTimescale: scale)
        : range.duration
      let asset: AVURLAsset
      if let hit = assetCache[path] {
        asset = hit
      } else {
        asset = AVURLAsset(url: URL(fileURLWithPath: path))
        assetCache[path] = asset
      }
      guard let sa = asset.tracks(withMediaType: .audio).first else { continue }
      addAudio(
        sa, range: range, at: at, outDur: outDur,
        volume: Float(m["volume"] as? Double ?? 1),
        fadeIn: m["fadeIn"] as? Double ?? 0,
        fadeOut: m["fadeOut"] as? Double ?? 0)
    }
    // 組建內視鏡：收到幾段純聲音、合成裡總共幾條聲音軌（實機定罪
    // 「預覽無聲」時第一眼看這格）
    if !audios.isEmpty {
      buildInfo["純聲音"] = "\(audios.count) 段，聲音軌共 \(aTracks.count) 條"
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
    // 合成包含所有圖層，必須以編輯畫布為界，不能以底層影片裁切 GIF、
    // 浮水印與馬賽克。保持原本長邊預算，後續既有縮放仍會限制預覽成本。
    if let aspect = canvasAspect, aspect.isFinite, aspect > 0,
      size.width >= 2, size.height >= 2 {
      let edge = max(size.width, size.height)
      let ratio = CGFloat(aspect)
      size = CGSize(
        width: max(2, (ratio >= 1 ? edge : edge * ratio).rounded()),
        height: max(2, (ratio >= 1 ? edge / ratio : edge).rounded()))
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
    audioMix = mix
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
      || (hdrOut && anyHDR && (!overlays.isEmpty || ovLive))
      || segments.contains { seg in
        seg.crop != nil || abs(seg.rotation) > 0.05 || seg.opacity < 0.999
      }
      // 補長的尾巴一定要掛合成器：不掛的話畫面直接由軌道決定，
      // 而軌道上補的是「最後一格拉長」＝尾巴凍在最後一幀；掛了
      // 才輪得到指令說話（那一段沒有任何層＝黑底，跟匯出一致）。
      // 成本不是新增的：這些專案上一版根本進不了合成，走的是
      // 一片段一顆播放器的舊路，比多掛一顆合成器貴得多
      || needsPad
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
        // 載入（色彩／方向／HDR 展開）跟匯出同一個入口。只有掛
        // HDR 合成器（hdrOut && anyHDR，見 customVideoCompositorClass）
        // 的合成才展開：SDR 合成器的 RGBA8 工作格式裝不下 1.0 以上
        guard let path = st["path"] as? String,
          let loaded = MCStillLoader.load(
            path: path, hdr: hdrOut && anyHDR, hint: st["hdr"] as? Bool,
            inverseOotf: stillInverseOotf)
        else { continue }
        var img = loaded
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
            clipStart: st["start"] as? Double ?? 0,
            sourceStart: st["sourceStart"] as? Double ?? 0,
            sourceRate: st["sourceRate"] as? Double ?? 1)
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
            z: st["track"] as? Int ?? 0, gif: gifSpec,
            // 即時變形的差量基準（見 CILayerSpec.uScale／render 迴圈
            // 讀 lx 那段）：跟影片段的 uScale/uPx/uPy 同一套，捏合中
            // 才拆得出「使用者這段變了多少」去疊差量。這裡的 u/spx/spy
            // 正是烘進 placement 的那三個值，基準跟畫面完全對齊
            uScale: Double(u), uPx: spx, uPy: spy)
        ))
      }
      buildInfo["圖片層"] = stillSpecs.count
      // 中灰探針（MCStillLoader.hlgProbe）：一個行程量一次、上面載入
      // 第一張圖時就量過並快取了，這裡只把判定＋這次組建的決定寫進
      // 報告（掛 HDR 合成器＋有圖片層時才有意義：圖片素材是唯一從線性
      // 空間插進 HLG 鏈的東西）。沒有使用者開關——場景參考就套反 OOTF、
      // 顯示參考不套、三條路自檢都不動就停用，這一行寫的是決定與理由
      if hdrOut && anyHDR && !stillSpecs.isEmpty {
        let probe = MCStillLoader.hlgReport(override: stillInverseOotf)
        buildInfo["中灰"] = probe
        NSLog("[HDRStill] 中灰探針 %@", probe)
      }

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
      // 補長的接縫本身也是切點。片尾保底（下面的 tail）只看段落的
      // 「起點」在哪，不切的話「本來就有的片尾」跟「補出來的尾巴」
      // 會落在同一段指令裡，整段被當成前者＝該黑的地方凍成最後一幀。
      // 沒補的時候不加（needsPad 擋著），行為完全不變
      if needsPad {
        rawT.append(CMTime(seconds: naturalEnd, preferredTimescale: 600))
      }
      nativeScrubSupported = needsCI && !texture && MCNativeScrubPlane.supported
      rawT.append(contentsOf: MCPreviewVisibility.prerollStarts(before: rawT))
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
      CIExportCompositor.setLiveMosaics(nil)
      // 最後一個可見片段結束的時間：之後的區間就是「片尾」
      let lastShow = segments.map { $0.range.end.seconds }.max() ?? 0
      let visibility = MCPreviewVisibilityState()
      visibilityState = visibility
      let scrubCache = nativeScrubSupported ? nativeScrubCache : nil
      // 產一份 videoComposition（可帶捏合中的即時變形覆寫 ov）。
      // 組建與即時變形共用同一段數學：放手烘定不會跳位。
      // 閉包刻意不碰 self（buildInfo/wmLive 都在外面做）——
      // vcRegen 存在屬性上，碰了 self 就是保留循環
      let makeVC: (CompLiveXform?) -> AVMutableVideoComposition = { ov in
        let scrubLayout = scrubCache?.nextLayout() ?? 0
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
        var proto: [(a: CMTime, b: CMTime, layers: [CILayerSpec], hold: Bool,
                     culled: Bool)] =
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
                uScale: seg.userScale, uPx: seg.px, uPy: seg.py,
                srcWidth: seg.size.width, sourceOpaque: seg.sourceOpaque)
            ))
          }
          for sp in stillSpecs
          where sp.layer.start <= mid + 0.0005
            && sp.layer.end >= mid - 0.0005
          {
            entries.append((z: sp.z, order: 1000 + sp.order, spec: sp.layer))
          }
          entries.sort { $0.z != $1.z ? $0.z < $1.z : $0.order < $1.order }
          let layers = MCPreviewVisibility.visibleLayers(
            entries.map { $0.spec }, canvas: canvas, enabled: visibility.enabled)
          if layers.count < entries.count { visibility.noteCulling() }
          // 片尾（最後一個可見片段之後，例如音樂比畫面長）不留黑：
          // 無條件重播最後一格，畫面停在最後一幀直到播完。
          // 「為了時間軸尾巴補出來的那段」（naturalEnd 之後）不在此列：
          // 匯出那段補的是空白＝黑底，預覽跟著黑才是所見即所得；
          // 不擋的話文字/貼圖的尾巴在預覽是凍住的最後一幀、成品卻是
          // 黑底，兩邊對不上。
          // 只看段落起點就夠：needsPad 時 naturalEnd 一定是切點
          //（見上面 rawT），不會有指令跨在接縫上。
          // 沒補的專案 naturalEnd＝合成總長，每一段指令的起點都嚴格
          // 小於它，這個條件恆真＝行為不變
          let tail =
            a.seconds >= lastShow - 0.001 && a.seconds < naturalEnd - 0.001
          proto.append((
            a: a, b: b, layers: layers,
            hold: layers.isEmpty && ((b - a).seconds < 0.12 || tail),
            culled: layers.count < entries.count
          ))
        }
        // 預捲窗：這一段「用到的軌」＋往後 1.5 秒內會進場的軌。
        // 原本每段都列全部軌道（解碼器全程熱機、接縫不冷啟動），
        // 代價是 5 軌專案在單軌區間 seek 也要等 5 顆解碼器供格——
        // 就是「多部影片後滑動就定位很久」（實測回報）。
        // 改成只看近未來：接縫照樣提前 1.5 秒熱機，seek 只等該等的
        // 沒有任何來源軌的段（只有圖片層、補長出來的黑尾巴、空縫）補列
        // 最底層那條合成軌當必要來源。AVVideoComposition.h 對自訂合成器
        // 只保證兩件事：passthroughTrackID 有值時「The compositor won't be
        // run for the duration of the instruction」、requiredSourceTrackIDs
        // 為 nil 時「all source tracks will be considered required」；
        // 空陣列的段合成器會不會被叫，標頭一個字都沒有。列一條這一段確定
        // 有媒體的軌（CI 路線每條軌都鋪滿到合成結尾，見 fillTail；這裡再
        // 對著軌道分段表驗一次）就落回標頭寫明的一般情況：有必要來源格
        // 的段，合成器一定跑；startRequest 照樣只畫圖片層、不讀那格。
        // 代價是最底層那顆解碼器在尾段繼續熱著——它前一段本來就在跑，
        // 不是 6d7da5c 擋掉的「三顆 4K 解碼器同時冷啟」。只在 needsCI
        // 時做：沒鋪滿的軌列進去反而供格失敗
        let baseTrack: AVMutableCompositionTrack? =
          needsCI ? vTracks.keys.min().flatMap { vTracks[$0]?.track } : nil
        func baseCovers(_ a: CMTime, _ b: CMTime) -> Bool {
          guard let tr = baseTrack else { return false }
          let mid = CMTime(
            seconds: (a.seconds + b.seconds) / 2, preferredTimescale: 600)
          return tr.segments.contains { sg in
            !sg.isEmpty && sg.timeMapping.target.containsTime(mid)
          }
        }
        // 每段自己需要的軌：層用到的；一條都沒有就是最底層軌（見上）
        let own: [Set<CMPersistentTrackID>] = proto.map {
          pi -> Set<CMPersistentTrackID> in
          var s = Set(
            pi.layers.compactMap { l -> CMPersistentTrackID? in
              l.trackID == kCMPersistentTrackID_Invalid ? nil : l.trackID
            })
          if s.isEmpty, let tr = baseTrack, baseCovers(pi.a, pi.b) {
            s.insert(tr.trackID)
          }
          return s
        }
        var built: [CIExportInstruction] = []
        for (i, pi) in proto.enumerated() {
          let ids = MCPreviewVisibility.requiredTracks(
            at: pi.a, own: own[i],
            upcoming: ((i + 1)..<proto.count).lazy.map {
              (start: proto[$0].a, tracks: own[$0])
            })
          // 往後 1.5 秒的聯集拿的是 own：只有圖片層的段列的是最底層軌，
          // 所以有影片層的段若 1.5 秒內接著一段純圖片段，也會把最底層
          // 軌列進來——那條軌本來就在跑，只是無害的預熱，維持原樣
          built.append(
            CIExportInstruction(
              timeRange: CMTimeRange(start: pi.a, end: pi.b),
              layers: pi.layers, mosaics: ciMosaics, overlays: [],
              prerollTrackIDs: ids.sorted().map { NSNumber(value: $0) },
              holdIfEmpty: pi.hold, previewCulled: pi.culled))
        }
        // HDR 輸出模式掛「HDR 預覽」合成器：同一套疊圖、不做色調
        // 映射、輸出走 HLG 管線（跟 HDR 匯出同一顆），另外讀即時
        // 疊加物——浮水印/文字烘在 HDR 畫面上用 EDR 顯示，
        // 白色才是真的白（跟成品同一段提亮程式碼）
        vc.customVideoCompositorClass =
          hdrOut && anyHDR
          ? CIPreviewCompositorHDR.self : CIPreviewCompositorSDR.self
        vc.instructions = built
        for instruction in built {
          instruction.scrubCapture = scrubCache
          instruction.scrubLayout = scrubLayout
        }
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
      lastXformOv = nil  // 新合成不帶舊的即時變形（審查員建議的加固）
      // HDR 預覽的即時疊加物（浮水印/文字）：跟原本一樣只在
      // 「CI 有掛」時收清單（needsCI false＝沒有合成器在讀）。
      // 這份清單的 bx/by/bs/br 就是當下位置，部件差量一併歸零
      if hdrOut && anyHDR && needsCI {
        CIExportCompositor.setPreviewOverlays(
          overlays.compactMap { CIOverlaySpec($0, canvas: canvas) },
          live: [])
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
            let requested = ci.requiredSourceTrackIDs?.count ?? vTracks.count
            return head + " 層z=\(ci.layers.map { $0.z }) 需解碼\(requested)軌"
          }
          let n =
            (raw as? AVMutableVideoCompositionInstruction)?
            .layerInstructions.count ?? 0
          return head + " 層數\(n)"
        }.joined(separator: "；")
        let sourceCounts = vc.instructions.compactMap {
          ($0 as? CIExportInstruction)?.requiredSourceTrackIDs?.count
        }
        if let fewest = sourceCounts.min(), let most = sourceCounts.max() {
          buildInfo["遮蔽剔除"] =
            "來源\(vTracks.count)軌；每段需解碼\(fewest)~\(most)軌；提前\(MCPreviewVisibility.prerollSeconds)秒預熱"
        }
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
    // 片段接縫清單（診斷用，見 CIExportCompositor.seamTimes）。
    // 抄的是軌道自己的分段表，不是我們以為的片段頭尾——鋪滿用的
    // 填充段也會切一刀，而那正是「解碼器換來源」真正發生的地方。
    // 這裡才設（不是在鋪完軌道那裡）：組到一半失敗的合成不會留下
    // 一份對不上任何播放器的接縫表
    var seamPairs: [(t: Double, who: String)] = []
    for k in vTracks.keys.sorted() {
      guard let tr = vTracks[k]?.track else { continue }
      for sg in tr.segments {
        let s = sg.timeMapping.target.start.seconds
        if !s.isFinite || s <= 0.01 { continue }
        seamPairs.append((t: s, who: "軌\(k)"))
      }
    }
    seamPairs.sort { $0.t < $1.t }
    var seamT: [Double] = []
    var seamN: [String] = []
    for p in seamPairs {
      // 同一刻好幾軌一起換段（切割出來的片段接在一起就是這樣）：
      // 併成一筆，不然報告上同一個時間會列好幾行一模一樣的數字
      if let last = seamT.last, p.t - last < 0.01 {
        seamN[seamN.count - 1] += "＋\(p.who)"
        continue
      }
      seamT.append(p.t)
      seamN.append(p.who)
    }
    CIExportCompositor.slowLock.lock()
    CIExportCompositor.seamTimes = seamT
    CIExportCompositor.seamNames = seamN
    CIExportCompositor.seamHits = []
    CIExportCompositor.worstSeamMs = 0
    CIExportCompositor.slowLock.unlock()
    composition = comp
    Self.stItemSwaps += 1
    // 新 item 停在 0 秒：畫面翻面要等 Dart 的定位 seek 落地
    //（見 PlayerHosts.hold；chase 完成／play 時 release）
    PlayerHosts.shared.hold(player)
    player.replaceCurrentItem(with: item)
    // 播放接管的「音訊分身」改成用到才建（見 ensureAudioClone）：
    // 每次重組都多養一顆載著同一份合成的播放器，跟主播放器搶
    // 讀檔／解碼資源，而接管路徑現在根本沒人走。
    // 舊分身載的是上一份合成：丟掉，下次接管再照新合成建
    audioPlayer.replaceCurrentItem(with: nil)
    audioValid = false

    if texture {
      if textureId == 0, let registry = registry {
        textureId = registry.register(self)
      }
      startLink()
    }
    opaqueSourcePaths = Set(opaqueByPath.compactMap { $0.value ? $0.key : nil })
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

  /// 這份合成的音量表（音訊分身要掛同一份）
  private var audioMix: AVMutableAudioMix?

  /// 音訊分身：同一份合成拷貝後拆掉視訊軌，純音訊。第一次接管
  /// 才建，之後沿用（同一份合成）
  private func ensureAudioClone() {
    guard audioPlayer.currentItem == nil, let comp = composition,
      let acomp = comp.mutableCopy() as? AVMutableComposition
    else { return }
    for tr in acomp.tracks(withMediaType: .video) {
      acomp.removeTrack(tr)
    }
    audioValid = !acomp.tracks(withMediaType: .audio).isEmpty
    let aItem = AVPlayerItem(asset: acomp)
    aItem.audioMix = audioMix
    audioPlayer.replaceCurrentItem(with: aItem)
    audioPlayer.automaticallyWaitsToMinimizeStalling = false
    audioPlayer.isMuted = player.isMuted
  }

  /// 播放接管：畫面歸 Metal 引擎、聲音與時鐘歸音訊分身，
  /// 主播放器原地凍結（合成管線完整保留，暫停畫面隨叫隨到）
  func setTakeover(_ on: Bool) {
    takeover = on
    traceClocks(on ? "接管" : "讓位")
    if on {
      ensureAudioClone()
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
    let playIntent = nativePlayIntent.replace()
    nativeScrubRequests.cancel()
    nativeScrubCache.beginPresentation(wantsFrames: false)
    nativeScrubCache.resumeCapturing()
    // A hit may have appeared before its physical chase caught up. Keep that
    // valid frame until AVPlayer is aligned, so playback cannot jump backwards.
    if let time = nativePresentedTime,
      seeking || abs(player.currentTime().seconds - time) > 0.018 {
      nativeScrubReceipt.cancel(); nativeGoal = nil
      let id = nativeScrubReceipt.generation
      seek(time, exact: true, nativeRequest: true) { [weak self] ok in
        guard let self = self, ok, id == self.nativeScrubReceipt.generation,
          self.nativePlayIntent.isCurrent(playIntent) else { return }
        self.hideNativeScrub(); self.play()
      }
      return
    }
    hideNativeScrub()
    // 結束舊的「等待放手定位」收據，但保留已排好的物理定位：舊呼叫方
    // 仍可能 seek()（立即回應）後立刻 play()，取消它會從錯誤時間開播。
    seekCompletion.replace(with: nil)
    if takeover {
      audioPlayer.playImmediately(atRate: targetRate)
      return
    }
    // 還沒跑完的 preroll 會把播放壓住，先取消
    player.cancelPendingPrerolls()
    prerollArmed = false
    // 播放中的格不是拖曳格：合成器回一般模式
    CIExportCompositor.setScrubbing(false)
    nudgeAnchor = .invalid
    // 要播了：換手中的新畫面不能再壓在後面（見 PlayerHosts.hold）
    PlayerHosts.shared.release(player)
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
    nativePlayIntent.replace()
    nativeScrubRequests.cancel()
    nativeScrubCache.beginPresentation(wantsFrames: false)
    nativeGoal = nil; nativeStylePresentation = nil
    nativeScrubReceipt.cancel()
    audioPlayer.pause()
    CIExportCompositor.slowLock.lock()
    CIExportCompositor.watchSupply = false
    CIExportCompositor.slowLock.unlock()
    player.pause()
    nudgeAnchor = .invalid
    CIExportCompositor.setScrubbing(false)
    // 暫停時把管線熱著，下次按播放就不用等（緊接著拖曳的話，
    // 第一發 seek 會先把它取消，見 chase）
    if player.currentItem?.status == .readyToPlay {
      prerollArmed = true
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
  private var seekTargetTolerance = CMTime.zero
  private var seeking = false
  private let seekCompletion = MCSeekCompletionState()
  private var seekLifecycle: UInt64 = 0

  private func cancelSeekRequests() {
    seekCompletion.replace(with: nil)
    seekLifecycle &+= 1
    seekTarget = .invalid
    seeking = false
    chaseWaits = 0
    player.currentItem?.cancelPendingSeeks()
  }

  /// 每一發真正做掉的 seek 花多久（毫秒），以及被合併掉幾發。
  /// 這是「左右滑動順不順」的直接證據：平均 30ms 以下＝跟得上手指，
  /// 200ms 以上＝每滑一下都要等，關鍵幀太疏
  private(set) var seekMs: [Int] = []
  private(set) var seekCoalesced = 0
  /// 落地的 seek 總數（seekMs 只留前 400 發；拖曳偵探要的是不封頂的計數）
  private(set) var seekDone = 0
  private(set) var seekSucceeded = 0
  private(set) var seekUnfinished = 0

  /// 停手後排過預捲、還沒被取消：下一發 seek 開跑前先取消它。
  /// 預捲＝對暫停中的合成連環解碼＋合成好幾格，跟緊接著的 seek 搶解碼器
  private var prerollArmed = false

  /// [exact] 只有「使用者停手了、要對準那一格」時才給 true。
  ///
  /// 密關鍵幀代理的拖曳發與停手發都鎖幀（容差 0，每 4 格
  /// 一個），鎖幀最多多解 3 格，換來拖曳中每一發都是「指針那一格」——
  /// 慢拖每格都換、手指停住那格就是準的、放手不再從吸附格跳到準格
  ///（原本拖曳寬容 0.1s＝永遠吸最近的關鍵幀，慢拖四格一跳）。
  /// exact 只差在停手那發落地後預捲把管線熱著（拖曳中絕不預捲，見 chase）
  func seek(
    _ seconds: Double, exact: Bool, toleranceMs: Int? = nil,
    nativeRequest: Bool = false,
    completion: ((Bool) -> Void)? = nil
  ) {
    if !nativeRequest { hideNativeScrub() }
    let request = seekCompletion.replace(with: completion)
    guard seconds.isFinite else {
      seekCompletion.finish(request, succeeded: false)
      return
    }
    var t = max(0, seconds)
    // 偏移半格（拖曳與停手同一套——兩邊落在同一格，放手畫面不動）：
    // 指針吸在片段邊界（例如馬賽克起點 4.5s）時，來源取樣格的 PTS
    // 常常是 4.4711 之類（29.97fps 對不齊），畫面顯示的是「邊界前一格」
    // ——那格還不在效果的時間段裡，看起來就是「指針指到素材開頭卻沒有
    // 馬賽克」（實測回報）。往前偏半格保證顯示的是邊界上或之後的取樣格
    if nativeRequest { t = Self.nativeFrameTarget(seconds, duration: duration) }
    else { t += 0.02 }
    // 目標夾在「最後一格之前」：seek 到正好等於總長的位置，指令已經
    // 出界，畫面可能刷成黑的——拖到底或播完停在結尾都要停在最後一幀
    if !nativeRequest, duration > 0.1, t > duration - 0.034 { t = duration - 0.034 }
    seekTarget = CMTime(seconds: t, preferredTimescale: 600)
    seekTargetExact = exact
    // 容忍窗不跨指令段（見 clampedScrubToleranceMs）：原生拖曳那條進來的
    // 已經夾過（再夾只會相同或更小），退路 seek 這裡才第一次夾
    seekTargetTolerance = MCSeekCompletionState.tolerance(
      exact: exact,
      milliseconds: exact
        ? 0
        : MCSeekCompletionState.clampedScrubToleranceMs(
          toleranceMs ?? 0, target: t,
          instructions: player.currentItem?.videoComposition?.instructions))
    nudgeAnchor = .invalid
    // 合成器的拖曳模式跟著 seek 節奏走：暫停中的寬容發＝手指在動，
    // 精準發＝停手（播放／暫停也會關，見 play/pause）
    CIExportCompositor.setScrubbing(!exact && player.rate == 0)
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
      if player.currentItem == nil || player.currentItem?.status == .failed
        || chaseWaits >= 40 {
        seeking = false
        chaseWaits = 0
        seekTarget = .invalid
        seekCompletion.finish(seekCompletion.generation, succeeded: false)
        return
      }
      chaseWaits += 1
      seeking = true
      let lifecycle = seekLifecycle
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self = self, lifecycle == self.seekLifecycle else { return }
        self.seeking = false
        self.chase()
      }
      return
    }
    chaseWaits = 0
    let t = seekTarget
    let exact = seekTargetExact
    let tolerance = seekTargetTolerance
    let request = seekCompletion.generation
    let lifecycle = seekLifecycle
    let item = player.currentItem
    seekTarget = .invalid
    seeking = true
    // 上一次停手排的預捲還在跑：先取消，別讓它跟這發 seek 搶解碼器
    if prerollArmed {
      prerollArmed = false
      player.cancelPendingPrerolls()
    }
    let seekStart = CACurrentMediaTime()
    player.seek(to: t, toleranceBefore: tolerance, toleranceAfter: tolerance) {
      [weak self] ok in
      // 完成回呼在 AVFoundation 的背景佇列跑，seeking/seekTarget
      // 卻是主執行緒（method channel）在寫——無鎖交錯下最後那發
      // 「停手精準 seek」可能被安靜吞掉、seeking 卡在 true 之後
      // 全部 seek 都被合併。整段跳回主執行緒，狀態單線化
      DispatchQueue.main.async {
        guard let self = self, lifecycle == self.seekLifecycle else { return }
        guard self.player.currentItem === item else {
          self.cancelSeekRequests()
          return
        }
        if self.seekMs.count < 400 {
          self.seekMs.append(
            Int((CACurrentMediaTime() - seekStart) * 1000))
        }
        self.seekDone += 1
        if ok { self.seekSucceeded += 1 } else { self.seekUnfinished += 1 }
        self.seeking = false
        self.seekCompletion.finish(request, succeeded: ok)
        // 定位落地（沒被下一發打斷）：換手中的新畫面可以翻上來了
        if ok { PlayerHosts.shared.release(self.player) }
        if self.seekTarget.isValid {
          self.chase()  // 手指又動了，追過去
        } else if ok, exact, request == self.seekCompletion.generation,
          self.player.rate == 0,
          self.player.currentItem?.status == .readyToPlay,
          CACurrentMediaTime() - self.lastNudgeAt > 0.5
        {
          // 停手那發落地、後面沒新目標：把管線熱著，下次按播放就不用等。
          // 只有停手發（exact）才預捲——原本拖曳中每發落地都預捲，
          // 手指一動下一發就得先等預捲取消／跟它搶解碼器，正是拖曳
          // p90 拉長、手指停一下再動就頓一下的根。
          // 疊加物驅動的重畫（拖滑桿中）後也「不」預捲——每版一次
          // 預捲＝對暫停中的 10-bit 檔連環開工又取消，解碼器被
          // 餓死（獨立審查 #1）
          self.prerollArmed = true
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
      nudgeAnchor = .invalid
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
      let ctx = CompPlayer.grabCtx
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
    if player.rate == 0, let time = nativePresentedTime { return Int(time * 1000) }
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
    m["nativeScrub"] = nativeScrubCache.stats()
    m["nativeScrubPresented"] = nativePresentedCount
    m["nativeScrubFailures"] = nativeFailedCount
    m["nativeScrubFailureReasons"] = nativeFailureReasons
    if let reason = nativeLastFailure { m["nativeScrubLastFailure"] = reason }
    m["nativeScrubCoalesced"] = nativeScrubRequests.coalesced
    m["nativeScrubActive"] = nativeScrubRequests.active != nil
    m["nativeScrubPending"] = nativeScrubRequests.pending != nil
    m["seekSucceeded"] = seekSucceeded
    m["seekUnfinished"] = seekUnfinished
    if let time = nativeLastPresentedTime { m["nativeScrubLastPresentedTime"] = time }
    if !nativePresentMs.isEmpty {
      m["nativeScrubPresentAvgMs"] = nativePresentMs.reduce(0, +) / nativePresentMs.count
      m["nativeScrubPresentMaxMs"] = nativePresentMs.max()!
    }
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
    // 片段接縫：這條時間軸有幾個接縫、播放中跨過去時牆鐘落後多少
    m["ciSeamCount"] = CIExportCompositor.seamTimes.count
    m["ciSeamWorst"] = CIExportCompositor.worstSeamMs
    m["ciSeams"] = CIExportCompositor.seamHits
    if let comp = composition {
      // 轉向/比例跑掉定位：軌道的原生尺寸與變換角度。轉正代理
      // 應為 identity（0°）；出現 90°/270°＝雙重旋轉現行犯
      m["trackGeo"] = comp.tracks(withMediaType: .video).map { t -> String in
        let n = t.naturalSize
        let x = t.preferredTransform
        let ang = Int((atan2(Double(x.b), Double(x.a)) * 180 / .pi).rounded())
        return "\(Int(n.width))x\(Int(n.height))@\(ang)°"
      }.joined(separator: "、")
      m["canvasWH"] =
        "\(Int(ciCanvas.width))x\(Int(ciCanvas.height))"
    }
    m["ciBurst"] = CIExportCompositor.burstGaps
      .map(String.init).joined(separator: ",")
    m["ciMiss"] = CIExportCompositor.missTotal
    m["ciMissNotes"] = CIExportCompositor.missNotes
    m["ciHoldMiss"] = CIExportCompositor.holdMissCount
    m["ciHoldGap"] = CIExportCompositor.holdGapCount
    m["lumaProbe"] = CIExportCompositor.lumaProbe.joined(separator: "、")
    // HDR 管線探針（見 CIExportCompositor.hdrProbe）：空字串＝這次
    // 沒有任何 HDR 合成器跑過（＝預覽根本沒掛 CI，走系統直通）
    m["hdrProbe"] = CIExportCompositor.hdrProbe
    // HDR 直拷的數值驗證走到哪（見 CIExportCompositor.probeHDRFast）。
    // 這一整段都在 slowLock 裡，只能用不再上鎖的那個版本
    m["hdrFast"] = CIExportCompositor.hdrFastNoteHoldingLock
    CIExportCompositor.slowLock.unlock()
    m["stallNotify"] = stallCount
    m["stallNotifyAt"] = stallNotes
    PlayerPlatformView.statLock.lock()
    m["viewCreates"] = PlayerPlatformView.createCount
    m["viewCreateAt"] = PlayerPlatformView.createNotes
    PlayerPlatformView.statLock.unlock()
    m["frameProbe"] = frameProbe()
    m["layerBound"] = PlayerHosts.shared.bound
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
      m["nudgeInfo"] =
        "\(Self.stNudgeFired)發/丟\(Self.stNudgeDropped)/換件\(Self.stItemSwaps)次"
        + "/vc換\(Self.stVcSwaps)延\(Self.stVcDeferred)"
        + CompPlayer.nudgeLandInfo()
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
    // 拖曳偵探的計數一併帶（便宜的整數；health 那條會做抽格檢查，
    // 拖曳中不能叫）：seek 落地幾發／合併幾發／合成器交了幾格
    CIExportCompositor.slowLock.lock()
    let frames = CIExportCompositor.frameCount
    CIExportCompositor.slowLock.unlock()
    var m: [String: Any] = [
      "seeks": seekDone, "coalesced": seekCoalesced, "frames": frames,
    ]
    let g = frameGaps
    guard !g.isEmpty else {
      m["count"] = 0
      return m
    }
    let sum = g.reduce(0, +)
    m["count"] = g.count
    m["avgMs"] = Double(sum) / Double(g.count)
    m["maxMs"] = g.max() ?? 0
    m["over2x"] = g.filter { $0 > 66 }.count
    return m
  }

  func disposeWatch() {
    watchLink?.invalidate()
    watchLink = nil
  }

  func dispose() {
    nativePlayIntent.replace()
    hideNativeScrub()
    nativeScrubCache.removeAll(dispose: true)
    cancelSeekRequests()
    disposeWatch()
    PlayerHosts.shared.release(player)
    // 重產閉包抓著整組合成軌，不放掉的話合成跟著這顆殭屍活著
    vcRegen = nil
    visibilityState = nil
    if let o = stallObs {
      NotificationCenter.default.removeObserver(o)
      stallObs = nil
    }
    link?.invalidate()
    link = nil
    clockTimer?.invalidate()
    clockTimer = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    audioPlayer.pause()
    audioPlayer.replaceCurrentItem(with: nil)
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

  /// 疊加物 PNG → 紋理（鍵＝CIOverlaySpec.uid 流水號，同一張不重上傳；
  /// 以前用 CGImage 位址當鍵，位址重用時會命中舊樣式的紋理）
  private var ovTextures: [Int: MTLTexture] = [:]

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
        out.append(Double(mcHalfToFloat(p[x * 4 + c])))
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
            // 倒退門檻放寬：來回滑動的小幅反向若都觸發重啟，
            // 每次反向就是 100~200ms 空窗（實機 163：來回滑會卡住）。
            // 小倒退讓 pump 關鍵幀頂著，真的往回拖才重啟
            let behind = shown >= 0 && want < shown - 0.2
            // 順向超前不急著重啟：順序解碼追 1~2 秒只要 ~100ms 而且
            // 沿路有畫面；重啟反而是 100~200ms 空窗。跳太遠才重啟
            let ahead = buffered >= 0 && want > buffered + 2.5
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
        // 保底 pump 只在解碼佇列沒罩到時才餵：兩邊同時全速餵＝
        // 同一支檔案兩套解碼互搶硬體解碼器，佇列被 seek 風暴掐住，
        // 連續拖動就週期性卡住（實機 162：拖曳 seek 每發 63~82ms）
        let rr = readers[sp.id]
        if rr == nil || !rr!.isRunning || abs(rr!.lastShown - want) > 0.25 {
          pumpFor(sp).want(want, coarse: true)
        }
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
      // 幾何一併印：轉向/比例問題一眼定位（畫框尺寸與方向旗標）
      let r = readers[sp.id]
      let geo = r?.infoReady == true
        ? "\(Int(r!.dispW))x\(Int(r!.dispH))轉\(r!.orient)"
        : "\(Int(sp.srcW))x\(Int(sp.srcH))?"
      layerInfo.append(
        "z\(sp.z)@\(String(format: "%.1f", sp.offset))"
          + "~\(String(format: "%.1f", sp.end))"
          + (sp.proxy ? "代理" : "⚠原檔")
          + "[\(geo)]"
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
      // 手停了：pump 補一發精確幀當保底就好。
      // 不再 force 重啟解碼佇列——滑動的佇列本來就停在這個位置，
      // 重啟＝正在顯示的供格鏈被砍斷 50~200ms＝「拉一拉停住會
      // 卡住讀取」（實機 162 回報）。播放已交還系統播放器，
      // 這裡的佇列不需要為起播預熱（舊架構遺物）
      seekSettled = true
      for sp in layers where sp.offset <= curT && curT < sp.end {
        pumpFor(sp).want(sp.trimStart + (curT - sp.offset) * sp.speed)
      }
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
  private func ovTexture(_ ov: CIOverlaySpec) -> MTLTexture? {
    let key = ov.uid
    if let t = ovTextures[key] { return t }
    guard let dev = device else { return nil }
    let loader = MTKTextureLoader(device: dev)
    let up0 = CACurrentMediaTime()
    let tex = try? loader.newTexture(
      cgImage: ov.cgImg,
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
      guard ov.start <= t, t < ov.end, let tex = ovTexture(ov)
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

// ===== HDR 照片匯出（markcut/photo）=====================================
//
// 整段貼到 ios/Runner/AppDelegate.swift 的最尾端（檔案已 import
// AVFoundation / CoreImage / ImageIO / Flutter / UIKit，這裡不用再 import）。
// 然後在 didInitializeImplicitFlutterEngine 裡、registerExportChannel 那行
// 之後加一行：
//
//     registerPhotoChannel(engineBridge)
//
// 通道 "markcut/photo"：
//   probe(String path) -> {hdr: Bool, w: Int, h: Int}
//       只讀檔頭：轉正後的像素尺寸，以及「這張是 HDR、而且這台匯得出
//       HDR」（iOS 17+ 才會回 true；<17 一律 false → Dart 走原本的 SDR 路）
//   export({src, dest, outW, outH, photoX, photoY, overlay?, overlayGain?,
//           quality?}) -> String?（nil＝成功；字串＝失敗原因，Dart 端退 SDR）
//       把來源展開成 HDR（CIImage .expandToHDR），黑底畫布置中、疊上
//       Dart 烘好的整版浮水印 PNG，寫成 10-bit HEIC（Rec.2100 HLG）。
//
// 疊加物的混色數學跟 CIExportCompositorHDR 一字不差：字底下的畫面先夾回
// SDR 白（CIColorClamp 0…1）以 PNG 的 alpha 混進去，再把 PNG 疊上去；
// overlayGain 對應影片路的 CIColorMatrix ×3（照片預設 1＝浮水印停在
// SDR 基準白，跟 SDR 預覽同一個白）。
//
// 最低系統：probe/export 內部以 #available(iOS 17.0) 分流；
// 用到的 API 與最低版本列在檔尾。
//
// [verified] 相對原稿的三處修改（都不改行為契約）：
//   1. registerPhotoChannel 改 private（跟其他 registerXxxChannel 同）
//   2. 背景 dispatch 區塊包 autoreleasepool：ImageIO/UIImage 的暫存物件
//      在 GCD 工作執行緒上不保證馬上釋放，48MP 那級的圖要主動收
//   3. 寫檔後的驗收：成品「打不開」也算失敗（原稿會當成功回 nil，
//      而 gal 的 creationRequestForAssetFromImage(atFileURL:)! 是強制解包，
//      打不開的檔會在存相簿那一步崩）；10-bit 判定放寬為
//      depth ≥ 10 或 ProfileName 含 HLG/2100/PQ，失敗原因附上 profile
//      名稱，這樣要是 ImageIO 對 10-bit HEIF 回報的 Depth 不是 10，
//      不會整條路無聲地永遠退 SDR、而且看得出為什麼

extension AppDelegate {
  private func registerPhotoChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "markcut.photo")
    else { return }
    let channel = FlutterMethodChannel(
      name: "markcut/photo", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "probe":
        guard let path = call.arguments as? String else {
          result(nil)
          return
        }
        // 讀檔頭而已，但增益圖那一問會碰到檔案 I/O，別擋主執行緒
        DispatchQueue.global(qos: .userInitiated).async {
          let m = autoreleasepool { HDRPhotoExport.probe(path) }
          DispatchQueue.main.async { result(m) }
        }
      case "export":
        guard let a = call.arguments as? [String: Any] else {
          result("參數錯誤")
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let err = autoreleasepool { HDRPhotoExport.export(a) }
          DispatchQueue.main.async { result(err) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

enum HDRPhotoExport {
  // 跟 CIExportCompositor.ctxHDR 同一組設定：半浮點＋「明講延伸範圍的
  // 線性空間」。只給 workingFormat 不給 workingColorSpace 的話，展開出來
  // 的高光會在進工作空間那一步被收回 1.0 以內（影片路踩過的坑）
  private static let ctx: CIContext = {
    var opts: [CIContextOption: Any] = [
      .cacheIntermediates: false,
      .workingFormat: CIFormat.RGBAh,
    ]
    if let ws = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
      opts[.workingColorSpace] = ws
    }
    return CIContext(options: opts)
  }()

  /// 檔頭探測：轉正後的尺寸 ＋ 這張要不要走 HDR 路
  static func probe(_ path: String) -> [String: Any] {
    var m: [String: Any] = ["hdr": false, "w": 0, "h": 0]
    let url = URL(fileURLWithPath: path)
    let opts = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return m }
    guard
      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [String: Any]
    else { return m }
    var w = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
    var h = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
    // EXIF 方向 5~8 是轉 90°：Dart 端（dart:ui 解碼）看到的是轉正後的
    // 尺寸，這裡要對齊
    let orient = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
    if orient >= 5 {
      let t = w
      w = h
      h = t
    }
    m["w"] = w
    m["h"] = h
    guard #available(iOS 17.0, *) else { return m }
    m["hdr"] = isHDR(src, props: props)
    return m
  }

  /// 這張是 HDR 照片嗎（不解整張圖）
  @available(iOS 17.0, *)
  private static func isHDR(_ src: CGImageSource, props: [String: Any]) -> Bool {
    // (1) Apple 增益圖（iPhone 12+ 的 HEIC／「相容性最佳」的 JPEG）。
    //     iOS 18 拍的檔案照樣帶這份（ISO 21496-1 之外的相容表示），
    //     所以這一問在 17 與 18 都命中。只有純 ISO 增益圖、沒有 Apple
    //     那份的檔（例：Android Ultra HDR JPEG）會被當 SDR——走原路，
    //     不會壞。想收進來的話在 iOS 18 加問
    //     kCGImageAuxiliaryDataTypeISOGainMap（iOS 18.0+，本檔沒用，
    //     沒編譯器不敢押那個符號）
    if CGImageSourceCopyAuxiliaryDataInfoAtIndex(
      src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    {
      return true
    }
    // (2) 純 HDR（10-bit PQ/HLG 的 HEIF，例：本 App 自己匯出的成品）
    if let depth = (props[kCGImagePropertyDepth as String] as? NSNumber)?.intValue,
      depth >= 10,
      let name = props[kCGImagePropertyProfileName as String] as? String
    {
      let n = name.uppercased()
      if n.contains("HLG") || n.contains("PQ") || n.contains("2100") { return true }
    }
    return false
  }

  /// 匯出。回 nil＝成功；回字串＝原因（Dart 端退回原本的 SDR 路）
  static func export(_ a: [String: Any]) -> String? {
    guard #available(iOS 17.0, *) else { return "需要 iOS 17" }
    guard let srcPath = a["src"] as? String, let dest = a["dest"] as? String,
      let outW = a["outW"] as? Int, let outH = a["outH"] as? Int,
      outW > 1, outH > 1
    else { return "參數錯誤" }
    let photoX = a["photoX"] as? Double ?? 0
    let photoY = a["photoY"] as? Double ?? 0
    let gain = a["overlayGain"] as? Double ?? 1
    let quality = min(1.0, max(0.05, a["quality"] as? Double ?? 0.92))
    let overlayData = (a["overlay"] as? FlutterStandardTypedData)?.data

    // 展開成 HDR：增益圖套上去、像素可以超過 1.0（線性、1.0＝SDR 白）。
    // applyOrientationProperty：EXIF 方向烘進像素，跟 dart:ui 解碼一致
    guard
      let loaded = CIImage(
        contentsOf: URL(fileURLWithPath: srcPath),
        options: [.expandToHDR: true, .applyOrientationProperty: true])
    else { return "讀不到照片" }
    // 轉正後 extent 原點不一定在 0,0：先歸零，後面的定位才是絕對座標
    var photo = loaded.transformed(
      by: CGAffineTransform(
        translationX: -loaded.extent.origin.x, y: -loaded.extent.origin.y))
    let pw = photo.extent.width
    let ph = photo.extent.height
    guard pw > 1, ph > 1 else { return "照片尺寸不對" }

    let canvasRect = CGRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH))
    // Dart 的 photoX/photoY 是左上原點；CI 是左下原點、y 往上
    let ty = CGFloat(outH) - ph - CGFloat(photoY)
    photo = photo.transformed(
      by: CGAffineTransform(translationX: CGFloat(photoX), y: ty))
    // 黑底畫布（不足的邊補黑，跟 renderPhotoComposite 一樣）
    let black = CIImage(color: CIColor.black).cropped(to: canvasRect)
    var out = photo.composited(over: black).cropped(to: canvasRect)

    // ── 浮水印：跟 CIExportCompositorHDR 同一套 ─────────────────
    if let data = overlayData, let ui = UIImage(data: data), let cg = ui.cgImage {
      var ov = CIImage(cgImage: cg)
      let ext = ov.extent
      if ext.width > 1, ext.height > 1 {
        // Dart 是照畫布尺寸烘的；萬一差一兩個像素就拉齊（不翻轉：
        // CIImage(cgImage:) 的 PNG 在 CI 座標裡已經是正的，影片路的
        // CIOverlaySpec 整版時也沒翻）
        if abs(ext.width - canvasRect.width) > 0.5 || abs(ext.height - canvasRect.height) > 0.5 {
          ov = ov.transformed(
            by: CGAffineTransform(
              scaleX: canvasRect.width / ext.width, y: canvasRect.height / ext.height))
        }
        ov = ov.transformed(
          by: CGAffineTransform(translationX: -ov.extent.origin.x, y: -ov.extent.origin.y))
        // 字底下的畫面先夾回 SDR 白以內，照 PNG 的 alpha 混進去：半透明
        // 的字縫裡不會透進超亮的高光把字沖灰；字外的畫面一個位元都不動
        let capped = out.applyingFilter(
          "CIColorClamp",
          parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
          ])
        out = capped.applyingFilter(
          "CIBlendWithAlphaMask",
          parameters: [
            kCIInputBackgroundImageKey: out,
            kCIInputMaskImageKey: ov,
          ]
        ).cropped(to: canvasRect)
        // 影片路在這裡 ×3（HLG 高光旁邊白字才不灰）；照片預設 1＝
        // 停在 SDR 基準白，跟預覽同一個白。要跟影片一樣就傳 3
        if abs(gain - 1) > 0.001 {
          let g = CGFloat(gain)
          ov = ov.applyingFilter(
            "CIColorMatrix",
            parameters: [
              "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
              "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
              "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
            ])
        }
        out = ov.composited(over: out).cropped(to: canvasRect)
      }
    }

    // ── 中繼資料：只留 EXIF 與 TIFF（拍攝日期、相機、鏡頭），方向已經
    //    烘進像素所以改 1。
    //    GPS 不留：浮水印照片是拿去公開分享的，夾帶定位不是使用者預期
    //    的事。IPTC 一起丟——它的 City／Sub-location／LocationCreated
    //    同樣可能寫著地點，留著等於 GPS 換個欄位再跑出來一次。
    //    MakerApple 也整包丟（裡面是舊增益圖的 headroom 標記，成品沒有
    //    增益圖，留著會讓相簿誤判）
    var props: [String: Any] = [:]
    // 只留 EXIF／TIFF：GPS 與 IPTC（City／LocationCreated…）都可能寫著
    // 地點，成品是拿去公開分享的，兩個都不帶
    let keep: [CFString] = [
      kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
    ]
    for k in keep {
      if let v = loaded.properties[k as String] { props[k as String] = v }
    }
    props[kCGImagePropertyOrientation as String] = 1
    if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
      tiff[kCGImagePropertyTIFFOrientation as String] = 1
      props[kCGImagePropertyTIFFDictionary as String] = tiff
    }
    if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
      exif[kCGImagePropertyExifPixelXDimension as String] = outW
      exif[kCGImagePropertyExifPixelYDimension as String] = outH
      props[kCGImagePropertyExifDictionary as String] = exif
    }
    out = out.settingProperties(props)

    // ── 寫 10-bit HEIC（Rec.2100 HLG，跟影片路同一個色彩空間）────
    guard let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG) else {
      return "沒有 HLG 色彩空間"
    }
    let qKey = CIImageRepresentationOption(
      rawValue: kCGImageDestinationLossyCompressionQuality as String)
    try? FileManager.default.removeItem(atPath: dest)
    do {
      try ctx.writeHEIF10Representation(
        of: out, to: URL(fileURLWithPath: dest), colorSpace: hlg,
        options: [qKey: quality])
    } catch {
      try? FileManager.default.removeItem(atPath: dest)
      return "寫檔失敗：\(error.localizedDescription)"
    }
    // 驗收：成品要打得開（gal 存相簿那步是強制解包，打不開就崩），
    // 而且真的是 10-bit／HLG 才算數（不是的話相簿不會當 HDR，
    // 不如退回 SDR 路至少格式照使用者選的）
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: dest) as CFURL, nil),
      let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [String: Any]
    else {
      try? FileManager.default.removeItem(atPath: dest)
      return "成品打不開"
    }
    let depth = (p[kCGImagePropertyDepth as String] as? NSNumber)?.intValue ?? 0
    let prof = ((p[kCGImagePropertyProfileName as String] as? String) ?? "").uppercased()
    let profHDR = prof.contains("HLG") || prof.contains("2100") || prof.contains("PQ")
    if depth < 10 && !profHDR {
      try? FileManager.default.removeItem(atPath: dest)
      return "成品不是 10-bit（depth=\(depth) profile=\(prof)）"
    }
    return nil
  }
}

// ===== 用到的 API 與最低 iOS 版本 ========================================
// FlutterImplicitEngineBridge.pluginRegistry.registrar(forPlugin:)  — 現有寫法
// CGImageSourceCreateWithURL / CopyPropertiesAtIndex                 — iOS 4
// kCGImageSourceShouldCache                                          — iOS 4
// kCGImagePropertyPixelWidth/Height/Orientation/Depth/ProfileName    — iOS 4
// CGImageSourceCopyAuxiliaryDataInfoAtIndex                          — iOS 11
// kCGImageAuxiliaryDataTypeHDRGainMap                                — iOS 14.1
// CIImageOption.expandToHDR                                          — iOS 17.0（整個 export 以 guard #available(iOS 17.0) 包住）
// CIImageOption.applyOrientationProperty                             — iOS 11
// CIContextOption.workingFormat / .workingColorSpace / .cacheIntermediates — iOS 9/9/10
// CIFormat.RGBAh                                                     — iOS 9
// CGColorSpace.extendedLinearSRGB                                    — iOS 10
// CGColorSpace.itur_2100_HLG                                         — iOS 14.0
// CIImage.transformed(by:) / composited(over:) / cropped(to:) / applyingFilter — iOS 8/8/8/8
// CIImage(color:) / CIColor.black                                    — iOS 5 / 10
// CIColorClamp / CIBlendWithAlphaMask / CIColorMatrix                 — iOS 7 / 5 / 5
// CIGammaAdjust / CIMultiplyCompositing                              — iOS 5 / 5
// CIColorKernel(source:) / apply(extent:arguments:)                  — iOS 8（CIKL；iOS 17 SDK 標 deprecated、執行期仍編得過，編不過回 nil → 內建鏈）
// CIContext.render(_:toBitmap:rowBytes:bounds:format:colorSpace:)    — iOS 5
// CIFormat.RGBAf / .RGBA16                                           — iOS 5 / 10
// CIColor(red:green:blue:alpha:colorSpace:)                          — iOS 10
// AVAssetTrackSegment.isEmpty / timeMapping / CMTimeRange.intersection — iOS 4 / 4 / Swift overlay
// CIImage.properties / settingProperties(_:)                         — iOS 5
// CIContext.writeHEIF10Representation(of:to:colorSpace:options:)     — iOS 15.0
// CIImageRepresentationOption(rawValue:) + kCGImageDestinationLossyCompressionQuality — iOS 11 / 4
// UIImage(data:).cgImage / CIImage(cgImage:)                          — iOS 2 / 5
// ===== 照片原生編碼（markcut/photo_save）====================================
//
// 貼法（兩處，都在 ios/Runner/AppDelegate.swift）：
//
// (1) 在 didInitializeImplicitFlutterEngine 裡、registerPhotoChannel(engineBridge)
//     那行之後加一行：
//
//     registerPhotoSaveChannel(engineBridge)
//
// (2) 下面 extension + enum 整段貼到檔案最尾端。
//
// 不用加 import：只用到 Flutter / CoreGraphics / ImageIO / Foundation，
// 檔頭已經 import Flutter、ImageIO、UIKit（UIKit 再匯出 CoreGraphics 與
// Foundation）。這一段用的是 UTI 字串而不是 UTType：CGImageDestination
// 吃的就是字串，"public.jpeg" / "public.png" 從 iOS 2 起就是這兩個值，
// 跟 UTType.jpeg.identifier 同值。（檔頭後來為了相簿挑 GIF 加了
// UniformTypeIdentifiers，這裡沒有跟著改的必要）
//
// 通道 "markcut/photo_save"：
//   probe() -> true
//       Dart 端一個 session 只問一次；沒人接（這段還沒貼）會收到
//       MissingPluginException，之後就不再把 48MB 往這裡送
//   encodeRgba({bytes, w, h, jpeg, quality}) -> FlutterStandardTypedData
//       bytes：Flutter ui.Image.toByteData(rawRgba)——記憶體順序 R,G,B,A、
//              8 bit、**預乘 alpha**、每列 w*4、沒有補齊，共 w*h*4 位元組
//       w, h：像素尺寸（Int）
//       jpeg：true=JPEG、false=PNG（Bool）
//       quality：1~100（Int），只有 JPEG 用；Dart 端已夾好，這裡再夾一次
//       回：編好的 JPEG/PNG 位元組；任何失敗回 FlutterError（Dart 端
//       接到就退回原本那條路：BMP→flutter_image_compress 或 Skia PNG）
//
// 做的事：CGDataProvider 直接罩在 Flutter 送來的 Data 上（不複製）→
// CGImage(bitsPerComponent 8, bitsPerPixel 32, bytesPerRow w*4, sRGB,
// byteOrder32Big | premultipliedLast ＝ 記憶體 RGBA、A 在最後、預乘)→
// CGImageDestination 出 JPEG（kCGImageDestinationLossyCompressionQuality）
// 或 PNG。跟原本 flutter_image_compress 最後那步（UIImageJPEGRepresentation
// / UIImagePNGRepresentation）是同一顆 ImageIO 編碼器；省掉的是它前面的
// UIImage(data: BMP) 解碼＋整張 UIGraphicsImageRenderer 重畫（就算比例
// 是 1 也會畫一遍），以及 Dart 端包 BMP 那 ~100ms。PNG 這條本來走 Skia 的
// zlib（12MP 一張 3.6~4.6 秒），現在也是 ImageIO。
//
// alpha：合成出來的照片本來就不透明（照片鋪滿畫布或黑底補齊）。JPEG 沒有
// alpha，ImageIO 會直接丟掉 A、留下預乘後的 RGB＝壓在黑底上，跟 BMP 路
// （丟 A）一樣。PNG 會保留 alpha（ImageIO 會先反預乘再寫，跟 Skia 一樣是
// 32 位元 RGBA PNG）——只有來源本身帶透明的 PNG 才會碰到這條差異，而且
// 差的只是半透明像素反預乘的四捨五入，不是內容。
//
// 色彩：Flutter 的 raw 像素沒有色彩管理，標成 sRGB——跟 BMP 路（BMP 沒
// profile，UIImage 當 sRGB）一致。
//
// 最低系統（全部遠低於專案的 iOS 15）：
//   CGDataProvider(data:)                          iOS 2
//   CGImage(width:height:bitsPerComponent:...)     iOS 2
//   CGColorSpace(name: CGColorSpace.sRGB)          iOS 9
//   CGImageDestinationCreateWithData / AddImage /
//   Finalize、kCGImageDestinationLossyCompressionQuality   iOS 4
//   FlutterStandardTypedData(bytes:)               Flutter
//   DispatchQueue / autoreleasepool                iOS 8
//   → 不需要任何 #available
//
// 執行緒：編碼在 global(qos: .userInitiated) 做，result 回主執行緒
//（FlutterResult 只能在平台執行緒叫）。閉包抓住 td（FlutterStandardTypedData）
// 讓 Data 活到編完；CGImage 又透過 provider 抓住同一份 CFData。
//
// [self-review 逐行當編譯器過的重點]
//   - `rgba as CFData`：Data → CFData 是標準橋接（Data 是 NSData 的 Swift
//     覆蓋型別，NSData 與 CFData toll-free bridged），`as` 不會失敗
//   - `out as CFMutableData`：NSMutableData 與 CFMutableData toll-free
//     bridged，`as` 合法（常見寫法 CGImageDestinationCreateWithData(data as
//     CFMutableData, ...)）
//   - CGBitmapInfo(rawValue:) 吃 UInt32；CGBitmapInfo.byteOrder32Big.rawValue
//     與 CGImageAlphaInfo.premultipliedLast.rawValue 都是 UInt32，可 |
//   - CGImage init 是 failable（回 Optional），guard let 接
//   - CGImageDestinationAddImage(_:_:_:) 第三個參數 CFDictionary?；
//     [CFString: Any] as CFDictionary 是標準橋接
//   - CGImageDestinationFinalize 回 Bool
//   - FlutterError(code:message:details:) 三個參數都有；details 給 nil
//   - 這段不碰 self，handler 閉包不需要 [weak self]
//
// ===========================================================================

extension AppDelegate {
  // ===== 相簿只列 GIF =====
  //
  // 「從相簿匯入 GIF」本來開的是 file_picker 的「所有照片」，使用者得在
  // 一整片靜態照片裡自己認哪張會動，選錯了才被擋下來（測試回報）。
  // PHPicker 篩得出來：playbackStyle == .imageAnimated 就是 GIF 那一類。
  //
  // 安卓那邊同一個通道名、同一個約定（見 MainActivity.kt）：
  // 回 [路徑]＝選好了、回 []＝使用者取消、回 nil＝叫不出這個選取器
  //（Dart 端看到 nil 會退回 file_picker 的「所有照片」，見 importGif）

  private func registerPickChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "markcut.pick")
    else { return }
    let channel = FlutterMethodChannel(
      name: "markcut/pick", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      // videos 那條在 iOS 走 file_picker（相簿原檔、順序照點選），
      // 沒有理由在這裡再實作一次——回 notImplemented，Dart 端會退回去
      guard call.method == "gifs" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if self.gifPickReply != nil {
        // 已經有一個選取器開著（連點兩下）：這一次當沒選
        result([String]())
        return
      }
      self.gifPickReply = result
      self.gifPickSeq &+= 1
      self.presentGifPicker()
    }
  }

  /// 推選取器要有一個「現在在畫面上」的 view controller。
  ///
  /// 不能用 FlutterAppDelegate 的 window：這個 App 是 UIScene 架構
  /// （見 SceneDelegate.swift 與 Info.plist 的 UIApplicationSceneManifest），
  /// window 掛在 scene delegate 上，AppDelegate 自己那個從頭到尾是 nil
  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
    let scene =
      scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    guard let ws = scene as? UIWindowScene else { return nil }
    let win = ws.keyWindow ?? ws.windows.first
    guard var top = win?.rootViewController else { return nil }
    // 已經有東西被 present（例如叫出這一支的那張底部面板）時要從最上面
    // 那一個推，不然 iOS 會拒絕而且什麼都不發生
    while let next = top.presentedViewController, !next.isBeingDismissed {
      top = next
    }
    return top
  }

  private func presentGifPicker() {
    var config = PHPickerConfiguration()
    // Swift 這邊的 PHPickerFilter 是 struct，工廠名字沒有 ObjC 的
    // Filter 尾巴（imagesFilter → .images、playbackStyleFilter →
    // .playbackStyle）。這支跟部署目標一樣是 iOS 15，不用 #available
    // ——包了反而讓 15 的機子永遠拿到「所有照片」，就是這個功能要修的
    // 那件事
    config.filter = .playbackStyle(.imageAnimated)
    config.selectionLimit = 1
    // 要相簿裡原本那個 GIF，不要系統轉一份給我們
    config.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    // 順手掃掉上幾次留下來的中繼複本（見 sweepPickedTemp）
    DispatchQueue.global(qos: .utility).async { sweepPickedTemp() }
    guard let top = topViewController() else {
      failGifPick(seq: gifPickSeq)
      return
    }
    gifPicker = picker
    top.present(picker, animated: true)
    // present 有可能被 UIKit 默默丟掉（上一個轉場還沒結束就推），那樣
    // 不會有任何 delegate 回呼。presentingViewController 是 present 當下
    // 就設好的（非同步的是動畫），所以直接問一次就知道有沒有推上去——
    // 不必用計時器去猜，也就不會跟「使用者一秒內滑掉」混在一起
    guard picker.presentingViewController != nil else {
      gifPicker = nil
      failGifPick(seq: gifPickSeq)
      return
    }
    armGifWatchdog(picker, seq: gifPickSeq, rounds: 0)
  }

  /// 挑選那一段的底線：推上去了，但 delegate 從來沒被叫（畫面被拆掉）。
  /// 少了它，那次呼叫的 Future 永遠掛著、鎖也永遠不放，之後每一次匯入
  /// 都被當成「已經有一個開著」。
  ///
  /// 三件事要認：
  ///   [seq]——這隻是延後才醒的，醒來時使用者可能已經完成這一次又開了
  ///   下一次；不認編號的話它會去把下一次那個還開著的選取器判死
  ///   選取器還在不在——單純在相簿裡挑久了不算失敗，那種情況再等一輪
  ///   [rounds]——續期要有盡頭。萬一選取器推上去了卻永遠回不來（推在
  ///   一個已經脫離畫面的 controller 上），無限續期等於把鎖卡死到重開
  ///   App，正是這隻要防的事
  private func armGifWatchdog(
    _ picker: PHPickerViewController, seq: Int, rounds: Int
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let self = self, self.gifPickSeq == seq, self.gifPickReply != nil
      else { return }
      // delegate 進來過了（gifPicker 被清掉）：換讀檔那一段的底線在管
      guard self.gifPicker === picker else { return }
      if picker.presentingViewController != nil {
        if rounds < 10 {
          self.armGifWatchdog(picker, seq: seq, rounds: rounds + 1)
          return
        }
        // 續期到頂還開著＝這個選取器回不來了。先把它收掉再收尾，
        // 不然 Dart 端會照著 nil 退回 file_picker，在它上面再疊一個
        picker.dismiss(animated: false)
      }
      self.gifPicker = nil
      self.failGifPick(seq: seq)
    }
  }

  /// 讀檔那一段的底線。要跟挑選那一段分開算——共用一個的話，使用者
  /// 挑了 55 秒才選下去，讀檔就只剩 5 秒，iCloud 上的原檔根本抓不完，
  /// 他選的那一下會被默默丟掉、畫面上還會冒出另一個選取器
  private func armGifLoadWatchdog(seq: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
      guard let self = self, self.gifPickSeq == seq, self.gifPickReply != nil
      else { return }
      self.failGifPick(seq: seq)
    }
  }

  /// 回覆那次 invokeMethod：[路徑]＝選好了、[]＝使用者按了取消。
  ///
  /// [seq] 是「這是第幾次挑」。一定要認：讀檔那一段有可能在底線之後
  /// 才回來，那時候使用者往往已經又開了下一次——不認的話，它會拿上一次
  /// 的檔案去回覆這一次的呼叫，使用者明明選了 B 卻拿到 A
  fileprivate func finishGifPick(_ path: String?, seq: Int) {
    DispatchQueue.main.async {
      guard self.gifPickSeq == seq, let reply = self.gifPickReply else {
        return
      }
      self.gifPickReply = nil
      reply(path.map { [$0] } ?? [String]())
    }
  }

  /// 叫不出這個選取器（找不到能推的畫面、推了沒推上去、東西讀不出來）：
  /// 回 nil，Dart 端會退回 file_picker。這裡不能回空清單——那是「使用者
  /// 按了取消」的意思，退路會被跳過，使用者只會看到按了完全沒反應。
  ///
  /// 已經選好了才失敗（檔案讀不出來）的話，使用者會看到再跳一個
  /// 「所有照片」的選取器。這是刻意的：兩害相權，讓他知道剛才那一下
  /// 沒成功、還有另一條路可以走，比按了之後畫面毫無反應好
  fileprivate func failGifPick(seq: Int) {
    DispatchQueue.main.async {
      guard self.gifPickSeq == seq, let reply = self.gifPickReply else {
        return
      }
      self.gifPickReply = nil
      reply(nil)
    }
  }

  private func registerPhotoSaveChannel(_ engineBridge: FlutterImplicitEngineBridge) {
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "markcut.photo_save")
    else { return }
    let channel = FlutterMethodChannel(
      name: "markcut/photo_save", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "probe":
        result(true)
      case "encodeRgba":
        guard let a = call.arguments as? [String: Any],
          let td = a["bytes"] as? FlutterStandardTypedData,
          let w = (a["w"] as? NSNumber)?.intValue,
          let h = (a["h"] as? NSNumber)?.intValue
        else {
          result(FlutterError(code: "args", message: "encodeRgba 參數錯誤", details: nil))
          return
        }
        let jpeg = (a["jpeg"] as? NSNumber)?.boolValue ?? true
        let quality = (a["quality"] as? NSNumber)?.intValue ?? 92
        // 來源照片路徑（選填）：帶了就把 EXIF／TIFF 搬進成品（不含 GPS
        // 與 IPTC，見 sourceMetadata），
        // 跟 HDR 路一致。沒帶＝跟以前一樣不寫中繼資料
        let src = a["src"] as? String
        DispatchQueue.global(qos: .userInitiated).async {
          let (data, err) = autoreleasepool {
            PhotoRgbaEncode.encode(
              td.data, width: w, height: h, jpeg: jpeg, quality: quality, src: src)
          }
          DispatchQueue.main.async {
            if let data = data {
              result(FlutterStandardTypedData(bytes: data))
            } else {
              result(FlutterError(code: "encode", message: err ?? "編碼失敗", details: nil))
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

enum PhotoRgbaEncode {
  /// 來源照片的 EXIF 與 TIFF（跟 HDR 路 HDRPhotoExport 同一份清單；
  /// GPS 與 IPTC 兩邊都不帶——成品是拿去公開分享的；
  /// MakerApple 一樣整包不帶）。方向改 1：Dart 交來的 RGBA 是解碼時已
  /// 轉正的顯示方向，像素尺寸改成成品的。讀不到就回空——中繼資料只是
  /// 附加，不能因為它讓存檔失敗
  static func sourceMetadata(_ path: String, outW: Int, outH: Int) -> [String: Any] {
    guard
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    else { return [:] }
    var props: [String: Any] = [:]
    // 只留 EXIF／TIFF：GPS 與 IPTC（City／LocationCreated…）都可能寫著
    // 地點，成品是拿去公開分享的，兩個都不帶
    let keep: [CFString] = [
      kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
    ]
    for k in keep {
      if let v = all[k as String] { props[k as String] = v }
    }
    props[kCGImagePropertyOrientation as String] = 1
    if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
      tiff[kCGImagePropertyTIFFOrientation as String] = 1
      props[kCGImagePropertyTIFFDictionary as String] = tiff
    }
    if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
      exif[kCGImagePropertyExifPixelXDimension as String] = outW
      exif[kCGImagePropertyExifPixelYDimension as String] = outH
      props[kCGImagePropertyExifDictionary as String] = exif
    }
    return props
  }

  /// raw RGBA（預乘、每列 width*4）→ JPEG 或 PNG。回 (位元組, nil) 或 (nil, 失敗原因)。
  /// [src]＝來源照片路徑（選填）：帶了就把它的中繼資料寫進成品（見 sourceMetadata）
  static func encode(
    _ rgba: Data, width: Int, height: Int, jpeg: Bool, quality: Int,
    src: String? = nil
  ) -> (Data?, String?) {
    // 32768 一邊是 ImageIO JPEG 的上限附近；合成出來的照片不會到那裡
    guard width > 0, height > 0, width <= 32768, height <= 32768 else {
      return (nil, "尺寸不合理 \(width)x\(height)")
    }
    let bytesPerRow = width * 4
    guard rgba.count >= bytesPerRow * height else {
      return (nil, "位元組不夠：\(rgba.count) < \(bytesPerRow * height)")
    }
    guard let provider = CGDataProvider(data: rgba as CFData) else {
      return (nil, "CGDataProvider 建不起來")
    }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
      return (nil, "sRGB 色彩空間建不起來")
    }
    // 記憶體順序 R,G,B,A、A 在最後——Flutter rawRgba 的定義。
    // 跟本檔 ~L210（影片路吃同一種 raw 緩衝）同一組旗標：
    //   PNG  → premultipliedLast：ImageIO 反預乘後寫 32 位元 RGBA PNG（同 Skia）
    //   JPEG → noneSkipLast：同一塊位元組當「RGBX、不透明」看，第 4 位元組
    //          直接略過。JPEG 本來就沒 alpha；這樣保證留下的是預乘後的 RGB
    //         （＝壓在黑底上），跟 BMP 退路「丟 A」逐位元一致，也省掉 ImageIO
    //          對帶 alpha 影像多做的一次反預乘／合成。
    //   byteOrder 用預設（0）：對 8 bit/成分的 32 bpp 就是記憶體順序，
    //   與 byteOrder32Big 等價；沿用本檔已編過的寫法。
    let alpha: CGImageAlphaInfo = jpeg ? .noneSkipLast : .premultipliedLast
    let info = CGBitmapInfo(rawValue: alpha.rawValue)
    guard
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: bytesPerRow, space: space, bitmapInfo: info, provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else {
      return (nil, "CGImage 建不起來")
    }
    let out = NSMutableData()
    let uti = (jpeg ? "public.jpeg" : "public.png") as CFString
    guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, uti, 1, nil) else {
      return (nil, "CGImageDestination 建不起來（\(uti)）")
    }
    var props: [CFString: Any] = [:]
    if jpeg {
      let q = Double(min(max(quality, 1), 100)) / 100.0
      props[kCGImageDestinationLossyCompressionQuality] = q
    }
    // 以前 SDR 路把來源的 EXIF 全丟（拍攝日期、相機、GPS），HDR 路卻
    // 留著：成品在相簿裡的日期變成匯出時間，兩條路對隱私的態度也不
    // 一致。同一份清單、同一個方向處理
    if let src = src {
      for (k, v) in sourceMetadata(src, outW: width, outH: height) {
        props[k as CFString] = v
      }
    }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
      return (nil, "CGImageDestinationFinalize 失敗")
    }
    guard out.length > 0 else {
      return (nil, "編碼結果是空的")
    }
    return (out as Data, nil)
  }
}

/// 掃掉相簿挑 GIF 留下來的中繼複本。
///
/// 收進「我的 GIF」的那一份是 Dart 端另外複製的（見 GifStore.add），
/// 這裡的只是把系統暫存檔接出來的中繼；不掃的話每匯入一次就在 tmp 裡
/// 多留一份原檔。一小時內的先留著——這一次的可能還在被 Dart 端複製。
/// 不碰任何共用狀態，所以可以在背景緒跑
private func sweepPickedTemp() {
  let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("picked", isDirectory: true)
  let fm = FileManager.default
  guard
    let items = try? fm.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.contentModificationDateKey])
  else { return }
  let cutoff = Date().addingTimeInterval(-3600)
  for item in items {
    let at = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
    // 讀不到日期就留著：判不出新舊時，寧可留下垃圾也不要刪掉還在用的
    guard let at = at, at <= cutoff else { continue }
    try? fm.removeItem(at: item)
  }
}

extension AppDelegate: PHPickerViewControllerDelegate {
  func picker(
    _ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]
  ) {
    picker.dismiss(animated: true)
    // 只認現在這一次的選取器。逾時之後才回來的那個不能動到這一次——
    // 它會在「使用者還在挑」的這一次上面壓一個讀檔期限，甚至把它判死
    guard gifPicker === picker else { return }
    // delegate 進來了＝挑選那一段結束，換讀檔那一段的底線接手計時
    let seq = gifPickSeq
    gifPicker = nil
    armGifLoadWatchdog(seq: seq)
    guard let provider = results.first?.itemProvider else {
      finishGifPick(nil, seq: seq)  // 空的＝使用者按了取消
      return
    }
    let gif = UTType.gif.identifier
    // 篩的是「會動的圖」，正常就是 GIF。真的拿到別的（動態 HEIC 之類）
    // 就照原樣帶回去，讓 Dart 端那句「這不是 GIF，請選會動的那種」講給
    // 使用者聽——在這裡默默不動作的話，他只會看到點了沒反應
    let want =
      provider.hasItemConformingToTypeIdentifier(gif)
      ? gif : provider.registeredTypeIdentifiers.first
    guard let type = want else {
      failGifPick(seq: seq)  // 什麼 representation 都沒有：退回 file_picker
      return
    }
    provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
      // url 指的是系統的暫存檔，這個 closure 一回去就會被刪掉——
      // 要在這裡面複製走，不能只把路徑帶回 Dart
      var copied: String?
      if let url = url {
        var name = url.lastPathComponent.isEmpty ? "picked" : url.lastPathComponent
        // 下游是照副檔名認 GIF 的（見 importGif）：確定是 GIF 卻沒帶
        // 副檔名時自己補，不然收得進來也會被自己的檢查擋掉
        if type == gif, !name.lowercased().hasSuffix(".gif") { name += ".gif" }
        // 每一次挑各自一個資料夾：同名不會撞，也就不用一個一個試名字
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent("picked", isDirectory: true)
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
          at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(name)
        do {
          try FileManager.default.copyItem(at: url, to: dst)
          copied = dst.path
        } catch {
          copied = nil
        }
      }
      // 讀不出來（url 是 nil、或複製失敗）＝這條路走不通，回 nil 讓
      // Dart 端退回 file_picker，不要靜悄悄地什麼都不做
      if let copied = copied {
        self?.finishGifPick(copied, seq: seq)
      } else {
        self?.failGifPick(seq: seq)
      }
    }
  }
}
