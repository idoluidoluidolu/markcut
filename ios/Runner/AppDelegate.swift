import AVFoundation
import Flutter
import UIKit

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
    registrar.register(
      PlayerViewFactory(playerProvider: { [weak self] in self?.comp?.player }),
      withId: "markcut/player_view")
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
      case "dispose":
        self.comp?.dispose()
        self.comp = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
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
    let vOut = AVAssetReaderTrackOutput(
      track: vTrack,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      ])
    vOut.alwaysCopiesSampleData = false
    guard reader.canAdd(vOut) else {
      done(false)
      return
    }
    reader.add(vOut)

    let size = vTrack.naturalSize
    let fps = vTrack.nominalFrameRate > 1 ? vTrack.nominalFrameRate : 30
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
    vIn.transform = vTrack.preferredTransform
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
      if reader.canAdd(out) {
        reader.add(out)
        let input = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey: ch,
            AVSampleRateKey: sr,
            AVEncoderBitRateKey: 128_000,
          ])
        input.expectsMediaDataInRealTime = false
        if writer.canAdd(input) {
          writer.add(input)
          aOut = out
          aIn = input
        }
      }
    }

    guard reader.startReading(), writer.startWriting() else {
      done(false)
      return
    }
    writer.startSession(atSourceTime: .zero)

    let group = DispatchGroup()
    let q = DispatchQueue(label: "markcut.dense")
    group.enter()
    vIn.requestMediaDataWhenReady(on: q) {
      while vIn.isReadyForMoreMediaData {
        if let sb = vOut.copyNextSampleBuffer() {
          if !vIn.append(sb) {
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
      aIn.requestMediaDataWhenReady(on: q) {
        while aIn.isReadyForMoreMediaData {
          if let sb = aOut.copyNextSampleBuffer() {
            if !aIn.append(sb) {
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
    group.notify(queue: q) {
      writer.finishWriting {
        DispatchQueue.main.async {
          let ok = writer.status == .completed && reader.status == .completed
          if ok {
            do {
              _ = try FileManager.default.replaceItemAt(
                srcURL, withItemAt: URL(fileURLWithPath: tmp))
              done(true)
              return
            } catch {}
          }
          try? FileManager.default.removeItem(atPath: tmp)
          channel.invokeMethod(
            "note", arguments: "密關鍵幀重編沒成功（照用原工作檔，滑動會比較鈍）")
          done(false)
        }
      }
    }
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
          let reason =
            session.error?.localizedDescription
            ?? (session.status == .cancelled ? "已取消" : "未知原因")
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

final class PlayerPlatformView: NSObject, FlutterPlatformView {
  private let host: PlayerHostView

  init(frame: CGRect, player: AVPlayer?) {
    host = PlayerHostView(frame: frame)
    host.backgroundColor = .black
    host.playerLayer.videoGravity = .resizeAspect
    host.playerLayer.player = player
    super.init()
  }

  func view() -> UIView { host }
}

final class PlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let playerProvider: () -> AVPlayer?

  init(playerProvider: @escaping () -> AVPlayer?) {
    self.playerProvider = playerProvider
    super.init()
  }

  func create(
    withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?
  ) -> FlutterPlatformView {
    PlayerPlatformView(frame: frame, player: playerProvider())
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

    // 逐段套用「轉正 → 等比縮放貼齊畫面 → 置中」。
    // 有這個之後，直式與橫式、轉正過與沒轉正過的素材可以混在一起，
    // 每一段都用自己的方向畫
    if size.width > 1, size.height > 1, !segments.isEmpty {
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
  func play() { player.playImmediately(atRate: targetRate) }

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

  /// [exact] 只有「使用者停手了、要對準那一格」時才給 true。
  ///
  /// 精準 seek 要從前一個關鍵幀一路解到目標格，而且跑完之前 rate 會被
  /// 壓在 0——按下播放剛好撞上它，畫面就是不動。拖曳中一律寬容，
  /// 停手之後才補一次精準的
  func seek(_ seconds: Double, exact: Bool) {
    seekTarget = CMTime(seconds: seconds, preferredTimescale: 600)
    seekTargetExact = exact
    // 已經有一發在跑：只要記住最新目標就好，跑完會自己追上去
    if !seeking { chase() }
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
    player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol) {
      [weak self] _ in
      guard let self = self else { return }
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

  func dispose() {
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
