import AVFoundation
import Flutter
import UIKit

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

  /// 正在跑的轉檔工作（取消用）與回報進度的計時器
  private var prepSession: AVAssetExportSession?
  private var prepTimer: Timer?

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
        // 容忍 0.15 秒：允許解碼器就近取材，不必逐格精準解到底，
        // 這是「快」的關鍵；拖曳預覽差半格人眼看不出來
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        var payload: FlutterStandardTypedData?
        if let cg = try? gen.copyCGImage(
          at: CMTime(value: Int64(ms), timescale: 1000), actualTime: nil),
          let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.7)
        {
          payload = FlutterStandardTypedData(bytes: data)
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
        self.comp?.dispose()
        let p = CompPlayer(registry: textures)
        guard p.build(clips: clips, texture: (args["texture"] as? Bool) ?? true)
        else {
          p.dispose()
          result(nil)
          return
        }
        self.comp = p
        // 重組之後畫面上的影片圖層要指到新的播放器，不然還黏在剛被
        // 收掉的那顆上，預覽就是一片黑
        PlayerHosts.shared.use(p.player)
        result([
          "textureId": p.textureId,
          "duration": p.duration,
          "width": Double(p.size.width),
          "height": Double(p.size.height),
        ])
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
      case "cancel":
        self.exportSession?.cancelExport()
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
        py: Double
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
      if end - start <= 0.01 { continue }

      if gap > 0.01 {
        let g = CMTime(seconds: gap, preferredTimescale: scale)
        vTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: g))
        cursor = cursor + g
      }
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      guard let src = asset.tracks(withMediaType: .video).first else { continue }
      let range = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: scale),
        duration: CMTime(seconds: end - start, preferredTimescale: scale))
      let outDur =
        abs(speed - 1) > 0.001
        ? CMTime(seconds: (end - start) / speed, preferredTimescale: scale)
        : range.duration
      do {
        try vTrack.insertTimeRange(range, of: src, at: cursor)
        if outDur != range.duration {
          vTrack.scaleTimeRange(
            CMTimeRange(start: cursor, duration: range.duration),
            toDuration: outDur)
        }
      } catch {
        done("素材接不進時間軸")
        return
      }
      if volume > 0.001 {
        addAudio(
          asset: asset, range: range, at: cursor, outDur: outDur,
          volume: volume, fadeIn: fadeIn, fadeOut: fadeOut)
      }
      segments.append((
        range: CMTimeRange(start: cursor, duration: outDur),
        transform: src.preferredTransform, size: src.naturalSize,
        fadeIn: fadeIn, fadeOut: fadeOut, userScale: userScale, px: px, py: py
      ))
      cursor = cursor + outDur
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
      vTrack.scaleTimeRange(whole, toDuration: target)
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
    vc.frameDuration = CMTime(value: 1, timescale: 30)
    // 明確標成 709。素材是 iPhone 預設的 4K HLG（HDR），不標的話 HDR 的
    // 色彩標記會原封帶進輸出檔，播放器再自己套一次曲線——輕則顏色歪掉，
    // 重則整片黑。轉工作檔那段早就踩過同一個坑，這裡漏了
    vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    var instructions: [AVMutableVideoCompositionInstruction] = []
    for seg in segments {
      let disp = seg.size.applying(seg.transform)
      let dw = abs(disp.width)
      let dh = abs(disp.height)
      guard dw > 1, dh > 1 else { continue }
      let k = min(canvas.width / dw, canvas.height / dh)
      var t = seg.transform
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
    vc.instructions = instructions

    // ── 浮水印與文字：Core Animation 圖層 ──────────────────────
    if !overlays.isEmpty {
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
    if long > 1920, AVAssetExportSession.allExportPresets().contains(
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
    session.shouldOptimizeForNetworkUse = true

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
        self.prepSession?.cancelExport()
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
        self.makeWorkFile(
          src: src, dest: dest, maxShortSide: maxShortSide, channel: channel)
        { path in result(path) }
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func makeWorkFile(
    src: String, dest: String, maxShortSide: Int,
    channel: FlutterMethodChannel,
    done: @escaping (String?) -> Void
  ) {
    // 先照我們自己算的尺寸轉；失敗就退一步、不套 videoComposition 再試
    // 一次（尺寸交給系統預設）。慢動作、時間重映射過的軌套 composition
    // 會直接失敗，但那種素材更需要工作檔——4K HDR 240fps 是最重的一種
    exportOnce(
      src: src, dest: dest, maxShortSide: maxShortSide,
      useComposition: true, channel: channel
    ) { [weak self] err in
      if err == nil {
        self?.denseKeyframes(dest, channel: channel) { _ in done(dest) }
        return
      }
      channel.invokeMethod(
        "note", arguments: "工作檔第一次失敗（\(err!)），改用系統預設尺寸重試")
      self?.exportOnce(
        src: src, dest: dest, maxShortSide: maxShortSide,
        useComposition: false, channel: channel
      ) { err2 in
        if err2 == nil {
          self?.denseKeyframes(dest, channel: channel) { _ in done(dest) }
        } else {
          channel.invokeMethod("note", arguments: "工作檔還是失敗：\(err2!)")
          done(nil)
        }
      }
    }
  }

  /// 把工作檔重編成「密關鍵幀」：每 5 格一個關鍵幀、不用 B 幀。
  ///
  /// 系統轉出來的檔關鍵幀間隔一兩秒，拖曳的每一次 seek 都要從前一個
  /// 關鍵幀解幾十格過來——左右滑動跟不上手指的根本原因。密關鍵幀之後
  /// 一次 seek 最多解 5 格；chase 的 0.1 秒寬容窗裡永遠有關鍵幀可落，
  /// 多數 seek 直接落幀。輸入已經是 SDR H.264，這一步沒有任何色彩
  /// 轉換，純粹重排關鍵幀。失敗就照用原工作檔（只是滑動比較鈍）
  private func denseKeyframes(
    _ path: String, channel: FlutterMethodChannel,
    done: @escaping (Bool) -> Void
  ) {
    let srcURL = URL(fileURLWithPath: path)
    let tmp = path + ".dense.mp4"
    try? FileManager.default.removeItem(atPath: tmp)
    let asset = AVURLAsset(url: srcURL)
    guard let vTrack = asset.tracks(withMediaType: .video).first,
      let reader = try? AVAssetReader(asset: asset),
      let writer = try? AVAssetWriter(
        outputURL: URL(fileURLWithPath: tmp), fileType: .mp4)
    else {
      done(false)
      return
    }
    let fps = vTrack.nominalFrameRate > 1 ? vTrack.nominalFrameRate : 30
    let pixels: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    ]

    // 順便把方向烘進畫面。
    //
    // 轉檔第一次失敗時會退一步用系統預設尺寸重試，那條路出來的檔會保留
    // 旋轉旗標；成功那條則是把方向燒進畫面。同一條時間軸上兩種混在一起，
    // 方向就不一致，合成播放器只好掛上合成器逐格重畫——整條路上最貴的
    // 那件事，就因為這個又被打開。
    //
    // 這裡本來就要重編一次，順手讓讀取端走一份只做轉正的合成，
    // 寫出來的檔一律是「已經轉正、沒有旋轉旗標」。之後所有工作檔方向
    // 天生一致，合成器就不會再被叫醒
    let disp = vTrack.naturalSize.applying(vTrack.preferredTransform)
    let upright = !vTrack.preferredTransform.isIdentity
    let size =
      upright
      ? CGSize(width: abs(disp.width), height: abs(disp.height))
      : vTrack.naturalSize

    let vOut: AVAssetReaderOutput
    if upright {
      let vc = AVMutableVideoComposition()
      vc.renderSize = size
      vc.frameDuration = CMTime(
        value: 1, timescale: CMTimeScale(max(1, min(60, fps.rounded()))))
      let ins = AVMutableVideoCompositionInstruction()
      ins.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
      let li = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
      li.setTransform(vTrack.preferredTransform, at: .zero)
      ins.layerInstructions = [li]
      vc.instructions = [ins]
      let o = AVAssetReaderVideoCompositionOutput(
        videoTracks: [vTrack], videoSettings: pixels)
      o.videoComposition = vc
      vOut = o
    } else {
      vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: pixels)
    }
    vOut.alwaysCopiesSampleData = false
    guard reader.canAdd(vOut) else {
      done(false)
      return
    }
    reader.add(vOut)

    let vIn = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [
          AVVideoMaxKeyFrameIntervalKey: 5,
          AVVideoAllowFrameReorderingKey: false,
          AVVideoAverageBitRateKey: Int(
            size.width * size.height * CGFloat(min(fps, 60)) * 0.2),
          AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
        ] as [String: Any],
      ])
    vIn.expectsMediaDataInRealTime = false
    // 方向已經烘進畫面，不再帶旗標（upright 為 false 時本來就是單位矩陣）
    guard writer.canAdd(vIn) else {
      done(false)
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
      // 整份重編會被判成失敗
      if reader.canAdd(out), writer.canAdd(input) {
        reader.add(out)
        writer.add(input)
        aOut = out
        aIn = input
      }
    }

    guard reader.startReading(), writer.startWriting() else {
      done(false)
      return
    }
    writer.startSession(atSourceTime: .zero)

    let group = DispatchGroup()
    // 一條軌一條佇列：兩個 input 共用一條序列佇列的話，影像那個 block
    // 在 while 裡跑的時候聲音那個永遠排不進去，兩邊互相餓死
    let vq = DispatchQueue(label: "markcut.dense.v")
    let aq = DispatchQueue(label: "markcut.dense.a")
    // append 失敗要記下來：不記的話 writer 仍可能收在 completed，
    // 於是一份「只有前半段」的檔會被換上去，素材默默變短
    let failed = AtomicFlag()
    let t0 = CACurrentMediaTime()

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
    let finish: (Bool, String?) -> Void = { ok, note in
      guard replied.setIfClear() else { return }
      DispatchQueue.main.async {
        if ok {
          done(true)
          return
        }
        try? FileManager.default.removeItem(atPath: tmp)
        if let note = note { channel.invokeMethod("note", arguments: note) }
        done(false)
      }
    }
    // 逾時保險：硬體編碼器被別的工作佔住時 requestMediaDataWhenReady
    // 可能一直不回來，沒有這道就卡在「工作檔轉不完」，畫面永遠是原檔
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
      guard !replied.isSet else { return }
      reader.cancelReading()
      writer.cancelWriting()
      finish(false, "密關鍵幀重編逾時（照用原工作檔，滑動會比較鈍）")
    }

    group.notify(queue: vq) {
      if failed.isSet {
        reader.cancelReading()
        writer.cancelWriting()
        finish(false, "密關鍵幀重編中途失敗（照用原工作檔）")
        return
      }
      writer.finishWriting {
        let ok =
          writer.status == .completed && reader.status == .completed
          && !failed.isSet
        guard ok else {
          finish(false, "密關鍵幀重編沒成功（照用原工作檔，滑動會比較鈍）")
          return
        }
        do {
          _ = try FileManager.default.replaceItemAt(
            srcURL, withItemAt: URL(fileURLWithPath: tmp))
          let ms = Int((CACurrentMediaTime() - t0) * 1000)
          channel.invokeMethod("note", arguments: "密關鍵幀重編完成 \(ms)ms")
          finish(true, nil)
        } catch {
          finish(false, "密關鍵幀重編換檔失敗（照用原工作檔）")
        }
      }
    }
  }

  /// 檢查一份影片檔的實際規格——尺寸、編碼、位元率，以及**關鍵幀間隔**。
  ///
  /// 關鍵幀間隔是「左右滑動順不順」的決定性數字：seek 一定要從前一個
  /// 關鍵幀解過來，間隔 60 格就是每滑一下解 60 格。這裡用 passthrough
  /// 讀（不解碼）數每一格的 sync 旗標，一支十秒的檔幾十毫秒就數完
  private func probeFile(_ path: String) -> [String: Any] {
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
    }
    // 有沒有旋轉旗標：有的話合成播放器要靠 layer instruction 轉正，
    // 沒有的話是已經燒進畫面的（工作檔第一次轉成功就會是這種）
    m["rotated"] = !t.preferredTransform.isIdentity
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
    channel: FlutterMethodChannel,
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
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
      let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
      // 先轉正（直式影片是「橫著存＋旋轉旗標」）再縮
      layer.setTransform(
        track.preferredTransform.concatenating(
          CGAffineTransform(scaleX: scale, y: scale)),
        at: .zero)
      instruction.layerInstructions = [layer]
      comp.instructions = [instruction]
      session.videoComposition = comp
    }

    prepSession = session
    prepTimer?.invalidate()
    // 進度用輪詢的：AVAssetExportSession 沒有回呼式的進度
    prepTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak session] _ in
      guard let session = session else { return }
      channel.invokeMethod("progress", arguments: Double(session.progress))
    }

    session.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        self?.prepTimer?.invalidate()
        self?.prepTimer = nil
        self?.prepSession = nil
        if session.status == .completed,
          FileManager.default.fileExists(atPath: dest)
        {
          channel.invokeMethod("progress", arguments: 1.0)
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
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
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

  func register(_ v: PlayerHostView) {
    views.add(v)
    v.playerLayer.player = current
  }

  /// 換成新的播放器：所有還活著的圖層一起指過去
  func use(_ p: AVPlayer?) {
    current = p
    for v in views.allObjects { v.playerLayer.player = p }
  }
}

final class PlayerPlatformView: NSObject, FlutterPlatformView {
  private let host: PlayerHostView

  init(frame: CGRect) {
    host = PlayerHostView(frame: frame)
    host.backgroundColor = .black
    host.playerLayer.videoGravity = .resizeAspect
    super.init()
    PlayerHosts.shared.register(host)
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
  /// 讓 AVPlayerLayer 的 PlatformView 拿得到（見 PlayerHostView）
  let player = AVPlayer()
  private var output: AVPlayerItemVideoOutput?
  private var link: CADisplayLink?
  private var latest: CVPixelBuffer?
  private let lock = NSLock()

  private weak var registry: FlutterTextureRegistry?
  private(set) var textureId: Int64 = 0

  /// 這次有沒有掛合成器。掛了＝每一格都進合成管線重畫一張，
  /// 沒掛＝硬體解碼直送螢幕（跟相簿播放同一條路）
  private(set) var usesVC = false

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
  func build(clips: [[String: Any]], texture: Bool) -> Bool {
    let comp = AVMutableComposition()
    guard
      let vTrack = comp.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let aTrack = comp.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { return false }

    let scale: CMTimeScale = 600
    var cursor = CMTime.zero
    var mixParams: [AVMutableAudioMixInputParameters] = []
    let aParams = AVMutableAudioMixInputParameters(track: aTrack)
    // 每一段的時間範圍與來源方向。一條合成軌只有一個
    // preferredTransform，混到不同方向的素材就會躺平或被拉扁——
    // 逐段的 layer instruction 才是 AVFoundation 給的正解
    var segments:
      [(
        range: CMTimeRange, transform: CGAffineTransform, size: CGSize,
        fadeIn: Double, fadeOut: Double, userScale: Double, px: Double,
        py: Double
      )] = []

    for clip in clips {
      guard let path = clip["path"] as? String else { continue }
      let start = clip["start"] as? Double ?? 0
      let end = clip["end"] as? Double ?? 0
      let gap = clip["gap"] as? Double ?? 0
      let volume = Float(clip["volume"] as? Double ?? 1)
      let speed = clip["speed"] as? Double ?? 1
      let fadeIn = clip["fadeIn"] as? Double ?? 0
      let fadeOut = clip["fadeOut"] as? Double ?? 0
      let userScale = clip["scale"] as? Double ?? 1
      let px = clip["px"] as? Double ?? 0.5
      let py = clip["py"] as? Double ?? 0.5
      if end - start <= 0.01 { continue }

      // 片段之間的空白：畫面留黑、聲音留靜音，時間軸才對得上
      if gap > 0.01 {
        let g = CMTime(seconds: gap, preferredTimescale: scale)
        vTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: g))
        aTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: g))
        cursor = cursor + g
      }

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
      do {
        try vTrack.insertTimeRange(range, of: src, at: cursor)
        if abs(speed - 1) > 0.001 {
          vTrack.scaleTimeRange(
            CMTimeRange(start: cursor, duration: range.duration),
            toDuration: outDur)
        }
        if let sa = asset.tracks(withMediaType: .audio).first {
          try aTrack.insertTimeRange(range, of: sa, at: cursor)
          if abs(speed - 1) > 0.001 {
            aTrack.scaleTimeRange(
              CMTimeRange(start: cursor, duration: range.duration),
              toDuration: outDur)
          }
        } else {
          aTrack.insertEmptyTimeRange(
            CMTimeRange(start: cursor, duration: outDur))
        }
      } catch {
        return false
      }
      // 每一段的音量；淡入淡出是斜坡，不是階梯
      let segEnd = cursor + outDur
      if fadeIn > 0.01 {
        aParams.setVolumeRamp(
          fromStartVolume: 0, toEndVolume: volume,
          timeRange: CMTimeRange(
            start: cursor,
            duration: CMTime(seconds: fadeIn, preferredTimescale: scale)))
      } else {
        aParams.setVolume(volume, at: cursor)
      }
      if fadeOut > 0.01 {
        let fo = CMTime(seconds: fadeOut, preferredTimescale: scale)
        aParams.setVolumeRamp(
          fromStartVolume: volume, toEndVolume: 0,
          timeRange: CMTimeRange(start: segEnd - fo, duration: fo))
      }
      segments.append((
        range: CMTimeRange(start: cursor, duration: outDur),
        transform: src.preferredTransform,
        size: src.naturalSize,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
        userScale: userScale,
        px: px,
        py: py
      ))
      // 畫面大小以第一段「轉正之後」的尺寸為準
      if size == .zero {
        let d = src.naturalSize.applying(src.preferredTransform)
        size = CGSize(width: abs(d.width), height: abs(d.height))
      }
      cursor = segEnd
    }
    if cursor.seconds <= 0 { return false }
    mixParams.append(aParams)

    let mix = AVMutableAudioMix()
    mix.inputParameters = mixParams
    let item = AVPlayerItem(asset: comp)
    item.audioMix = mix
    // 變速時聲音保持音高（跟主流剪輯 App 一致）
    item.audioTimePitchAlgorithm = .timeDomain

    // 需不需要合成器，先問清楚再掛。
    //
    // 掛了 AVVideoComposition，播放就從「硬體解碼直送螢幕」變成
    // 「每一格都進合成管線重畫一張」——4K 素材那是每格重畫 830 萬像素。
    // 相簿播同一支影片不會這樣，別家剪輯 App 也不會：他們只在真的要
    // 疊圖層、轉正、淡入淡出的時候才掛。
    //
    // 全部片段方向一致、尺寸一致、沒有淡入淡出也沒有縮放位移時，
    // 一條軌照順序播就是正確結果，合成器純粹是多餘的成本——
    // 而且不掛的話 HDR 素材由系統自己映射，顏色跟相簿完全一致
    // 方向不必靠合成器：全部片段方向一致的話，把那個方向設在合成軌上
    // 就好。iPhone 直式影片是「橫著存＋旋轉旗標」，整條時間軸都是同一支
    // 手機拍的話旗標當然一樣——這個情況（也就是絕大多數情況）掛合成器
    // 純屬浪費
    let uniformTransform = segments.first?.transform ?? .identity
    let sameTransform = segments.allSatisfy { $0.transform == uniformTransform }
    let needsVC =
      segments.contains { seg in
        seg.fadeIn > 0.01 || seg.fadeOut > 0.01
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
    if !needsVC { vTrack.preferredTransform = uniformTransform }
    usesVC = needsVC

    if needsVC, size.width > 1, size.height > 1, !segments.isEmpty {
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
      var instructions: [AVMutableVideoCompositionInstruction] = []
      for seg in segments {
        let disp = seg.size.applying(seg.transform)
        let dw = abs(disp.width)
        let dh = abs(disp.height)
        guard dw > 1, dh > 1 else { continue }
        let k = min(size.width / dw, size.height / dh)
        let tx = (size.width - dw * k) / 2
        let ty = (size.height - dh * k) / 2
        var t = seg.transform
          .concatenating(CGAffineTransform(scaleX: k, y: k))
          .concatenating(CGAffineTransform(translationX: tx, y: ty))
        // 使用者的縮放與位移：以畫面中心縮放，再把中心移到 (px, py)
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
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        layer.setTransform(t, at: seg.range.start)
        // 畫面的淡入淡出（背景是黑的，淡不透明度＝淡到黑）
        if seg.fadeIn > 0.01 {
          layer.setOpacityRamp(
            fromStartOpacity: 0, toEndOpacity: 1,
            timeRange: CMTimeRange(
              start: seg.range.start,
              duration: CMTime(seconds: seg.fadeIn, preferredTimescale: scale)))
        }
        if seg.fadeOut > 0.01 {
          let fo = CMTime(seconds: seg.fadeOut, preferredTimescale: scale)
          layer.setOpacityRamp(
            fromStartOpacity: 1, toEndOpacity: 0,
            timeRange: CMTimeRange(start: seg.range.end - fo, duration: fo))
        }
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = seg.range
        ins.layerInstructions = [layer]
        instructions.append(ins)
      }
      vc.instructions = instructions
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
    duration = cursor.seconds
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
    seekTarget = CMTime(seconds: seconds, preferredTimescale: 600)
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
  private func chase() {
    guard seekTarget.isValid, player.currentItem?.status == .readyToPlay else {
      seeking = false
      return
    }
    let t = seekTarget
    let exact = seekTargetExact
    seekTarget = .invalid
    seeking = true
    let tol =
      exact ? CMTime.zero : CMTimeMakeWithSeconds(0.1, preferredTimescale: 600)
    seekStart = CACurrentMediaTime()
    player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol) {
      [weak self] _ in
      guard let self = self else { return }
      if self.seekMs.count < 400 {
        self.seekMs.append(Int((CACurrentMediaTime() - self.seekStart) * 1000))
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

  var positionMs: Int { Int(player.currentTime().seconds * 1000) }

  /// 系統自己記的播放品質。這幾個數字是 AVPlayer 內部統計，
  /// Flutter 端的任何指標都看不到：
  /// - 掉格：解碼器沒把影格及時交出來（畫面頓的直接證據）
  /// - 卡頓：播放中途被迫停下來等資料
  /// - 在等什麼：rate 想跑但跑不動時，系統說的理由
  func healthStats() -> [String: Any] {
    var m: [String: Any] = ["usesVC": usesVC, "renderW": Int(size.width),
                            "renderH": Int(size.height)]
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
