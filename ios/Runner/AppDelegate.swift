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

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

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
}
