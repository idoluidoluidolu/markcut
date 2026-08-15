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
    let asset = AVURLAsset(url: URL(fileURLWithPath: src))
    guard let track = asset.tracks(withMediaType: .video).first else {
      done(nil)  // 沒有畫面（純音訊）不需要工作檔
      return
    }
    // 1920x1080 這個預設輸出的是 H.264 SDR——素材是 HLG/PQ 時系統會
    // 自己映射回 SDR。實際尺寸由下面的 videoComposition 決定
    guard
      let session = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPreset1920x1080)
    else {
      done(nil)
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
    if dispW > 1, dispH > 1 {
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
          done(dest)
        } else {
          try? FileManager.default.removeItem(atPath: dest)
          done(nil)
        }
      }
    }
  }
}
