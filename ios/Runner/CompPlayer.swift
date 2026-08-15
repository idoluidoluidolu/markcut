import AVFoundation
import Flutter
import UIKit

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
  private let player = AVPlayer()
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
  func build(clips: [[String: Any]]) -> Bool {
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

    for clip in clips {
      guard let path = clip["path"] as? String else { continue }
      let start = clip["start"] as? Double ?? 0
      let end = clip["end"] as? Double ?? 0
      let gap = clip["gap"] as? Double ?? 0
      let volume = Float(clip["volume"] as? Double ?? 1)
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
      do {
        try vTrack.insertTimeRange(range, of: src, at: cursor)
        if let sa = asset.tracks(withMediaType: .audio).first {
          try aTrack.insertTimeRange(range, of: sa, at: cursor)
        } else {
          aTrack.insertEmptyTimeRange(
            CMTimeRange(start: cursor, duration: range.duration))
        }
      } catch {
        return false
      }
      // 每一段的音量（靜音的軌、調過音量的片段）
      aParams.setVolume(volume, at: cursor)
      if size == .zero {
        // 工作檔都是轉正過的，直接拿第一段的尺寸當畫面大小
        size = src.naturalSize
      }
      cursor = cursor + range.duration
    }
    if cursor.seconds <= 0 { return false }
    mixParams.append(aParams)

    let mix = AVMutableAudioMix()
    mix.inputParameters = mixParams
    let item = AVPlayerItem(asset: comp)
    item.audioMix = mix
    // 影格輸出：BGRA 直接給 Flutter 材質用
    let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ])
    item.add(out)
    output = out
    duration = cursor.seconds
    player.replaceCurrentItem(with: item)

    if textureId == 0, let registry = registry {
      textureId = registry.register(self)
    }
    startLink()
    return true
  }

  private func startLink() {
    link?.invalidate()
    let l = CADisplayLink(target: self, selector: #selector(onFrame))
    l.add(to: .main, forMode: .common)
    link = l
  }

  @objc private func onFrame() {
    guard let out = output else { return }
    let t = player.currentTime()
    guard out.hasNewPixelBuffer(forItemTime: t),
      let buf = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    else { return }
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

  func play() { player.play() }
  func pause() { player.pause() }
  func setRate(_ r: Double) { player.rate = Float(r) }

  func seek(_ seconds: Double) {
    // 容忍半格：拖曳時要的是跟手，逐格精準會慢到沒辦法用
    let t = CMTime(seconds: seconds, preferredTimescale: 600)
    player.seek(t, toleranceBefore: .zero, toleranceAfter: CMTime(value: 8, timescale: 600))
  }

  var positionMs: Int { Int(player.currentTime().seconds * 1000) }

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
