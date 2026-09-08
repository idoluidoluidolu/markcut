import Flutter
import UIKit
import XCTest
import CoreImage
import ImageIO
import AVFoundation
import Metal
@testable import Runner

private final class ScrubTestTextureRegistry: NSObject, FlutterTextureRegistry {
  func register(_ texture: FlutterTexture) -> Int64 { 1 }
  func textureFrameAvailable(_ textureId: Int64) {}
  func unregisterTexture(_ textureId: Int64) {}
}

class RunnerTests: XCTestCase {
  private func scrubBuffer(width: Int = 16, height: Int = 16) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
      kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
      &buffer), kCVReturnSuccess)
    return try XCTUnwrap(buffer)
  }
  private var scrubRange: CMTimeRange {
    CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600))
  }

  func testNativeScrubRetainsPixelBufferAndColorAttachmentsWithoutJPEG() throws {
    let cache = MCNativeScrubCache()
    let layout = cache.nextLayout()
    let buffer = try scrubBuffer()
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
      kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
    cache.insert(buffer, time: 0, epoch: CIExportCompositor.liveEpoch,
                 layout: layout, range: scrubRange, hdr: true)
    let frame = try XCTUnwrap(cache.nearest(0, tolerance: 0.001))
    XCTAssertTrue(frame.buffer === buffer)
    XCTAssertEqual(frame.time, 0)
    XCTAssertTrue(frame.hdr)
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(frame.buffer), kCVPixelFormatType_32BGRA)
    let transfer = try XCTUnwrap(CVBufferGetAttachment(frame.buffer,
      kCVImageBufferTransferFunctionKey, nil)?.takeUnretainedValue())
    XCTAssertTrue(CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG))
  }

  func testNativeScrubCacheHonorsByteCountAndTimeWindowBounds() throws {
    let buffer = try scrubBuffer()
    let bytes = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
    let cache = MCNativeScrubCache(budget: bytes * 2, capacity: 3)
    let layout = cache.nextLayout()
    for t in [0.0, 0.1, 0.2] {
      cache.insert(buffer, time: t, epoch: CIExportCompositor.liveEpoch,
                   layout: layout, range: scrubRange, hdr: false)
    }
    XCTAssertEqual(cache.stats()["frames"] as? Int, 2)
    XCTAssertLessThanOrEqual(cache.stats()["bytes"] as? Int ?? Int.max, bytes * 2)
    XCTAssertNil(cache.nearest(0, tolerance: 0.001))
    cache.beginPresentation(wantsFrames: false) // release the scrub center for playback
    cache.insert(buffer, time: 5, epoch: CIExportCompositor.liveEpoch,
                 layout: layout, range: scrubRange, hdr: false)
    cache.insert(buffer, time: 5.1, epoch: CIExportCompositor.liveEpoch,
                 layout: layout, range: scrubRange, hdr: false)
    XCTAssertNotNil(cache.nearest(5, tolerance: 0.001))
    XCTAssertNil(cache.nearest(0.2, tolerance: 0.001))
  }

  func testNativeScrubRejectsStaleLayoutStyleAndPresentationGenerations() throws {
    let cache = MCNativeScrubCache()
    let layout = cache.nextLayout()
    let epoch = CIExportCompositor.liveEpoch
    let buffer = try scrubBuffer()
    cache.insert(buffer, time: 1, epoch: epoch, layout: layout, range: scrubRange, hdr: false)
    let frame = try XCTUnwrap(cache.nearest(1, tolerance: 0.001))
    let first = cache.beginPresentation(target: 1)
    XCTAssertTrue(cache.isCurrent(frame, presentation: first))
    cache.beginPresentation(target: 2)
    XCTAssertFalse(cache.isCurrent(frame, presentation: first))
    cache.nextLayout()
    cache.insert(buffer, time: 1, epoch: epoch, layout: layout, range: scrubRange, hdr: false)
    XCTAssertEqual(cache.stats()["frames"] as? Int, 0)
    XCTAssertFalse(cache.isCurrent(frame))
    let currentLayout = cache.nextLayout()
    cache.insert(buffer, time: 1, epoch: epoch - 1, layout: currentLayout,
                 range: scrubRange, hdr: false)
    XCTAssertEqual(cache.stats()["frames"] as? Int, 0)
    cache.removeAll(dispose: true)
    cache.insert(buffer, time: 1, epoch: epoch, layout: currentLayout,
                 range: scrubRange, hdr: false)
    XCTAssertEqual(cache.stats()["frames"] as? Int, 0)
  }

  func testNativeScrubToleranceDoesNotCrossAClipBoundaryOrAcceptUnknownTime() {
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
    XCTAssertTrue(MCNativeScrubCache.accepts(time: 0, target: 0, tolerance: 0, range: range))
    XCTAssertFalse(MCNativeScrubCache.accepts(time: 0.99, target: 1,
      tolerance: 0.15, range: range))
    XCTAssertFalse(MCNativeScrubCache.accepts(time: .nan, target: 0,
      tolerance: 0.15, range: range))
    XCTAssertFalse(MCNativeScrubCache.accepts(time: 0, target: .infinity,
      tolerance: 0.15, range: range))
  }

  func testNativeScrubNoticesCoalesceAndPreserveTheMatchingFrame() throws {
    let cache = MCNativeScrubCache()
    let layout = cache.nextLayout()
    let buffer = try scrubBuffer()
    let delivered = expectation(description: "one matching notice")
    delivered.assertForOverFulfill = true
    cache.onFrame = { frame in XCTAssertEqual(frame.time, 1); delivered.fulfill() }
    cache.beginPresentation(target: 1, tolerance: 0.001)
    // A preroll frame arriving after the target must not replace the target's
    // pending notice, or exact scrub would wait forever despite having its frame.
    for t in [0.9, 1.0, 1.03, 1.06, 1.1] {
      cache.insert(buffer, time: t, epoch: CIExportCompositor.liveEpoch,
                   layout: layout, range: scrubRange, hdr: false)
    }
    wait(for: [delivered], timeout: 1)
    cache.finishPresentation()
  }

  func testNativeScrubExactReceiptRequiresSeekAndPresentationInEitherOrder() {
    for presentationFirst in [false, true] {
      let receipt = MCNativeScrubReceipt()
      var replies: [[String: Any]] = []
      let id = receipt.begin(exact: true) { replies.append($0) }
      if presentationFirst { receipt.didPresent(id, time: 0, cacheHit: true) }
      else { receipt.didSeek(id, ok: true) }
      XCTAssertTrue(replies.isEmpty)
      if presentationFirst { receipt.didSeek(id, ok: true) }
      else { receipt.didPresent(id, time: 0, cacheHit: true) }
      XCTAssertEqual(replies.count, 1)
      XCTAssertEqual(replies[0]["displayed"] as? Bool, true)
      XCTAssertEqual(replies[0]["actualSeconds"] as? Double, 0)
      receipt.didPresent(id, time: 1, cacheHit: false)
      XCTAssertEqual(replies.count, 1)
    }
  }

  func testNativeScrubNewGestureCancelAndFailureCannotCompleteAnOldReceipt() {
    let receipt = MCNativeScrubReceipt()
    var oldResults: [[String: Any]] = []
    var newResults: [[String: Any]] = []
    let old = receipt.begin(exact: true) { oldResults.append($0) }
    let newest = receipt.begin(exact: true) { newResults.append($0) }
    XCTAssertEqual(oldResults.first?["displayed"] as? Bool, false)
    receipt.didSeek(old, ok: true)
    receipt.didPresent(old, time: 1, cacheHit: true)
    XCTAssertTrue(newResults.isEmpty)
    receipt.didSeek(newest, ok: false)
    receipt.didPresent(newest, time: 2, cacheHit: true)
    XCTAssertEqual(newResults.count, 1)
    XCTAssertEqual(newResults.first?["displayed"] as? Bool, false)
    receipt.cancel()
    XCTAssertEqual(newResults.count, 1)
  }

  func testNativeScrubStyleChangeKeepsSeekReceiptButRequiresNewPresentation() {
    let receipt = MCNativeScrubReceipt()
    var replies: [[String: Any]] = []
    let request = receipt.begin(exact: true) { replies.append($0) }
    receipt.didPresent(request, time: 4, cacheHit: true)
    receipt.invalidatePresentation()
    receipt.didSeek(request, ok: true)
    XCTAssertTrue(replies.isEmpty, "old-style presentation cannot finish the exact request")
    XCTAssertEqual(receipt.generation, request, "the user's latest seek stays pending")
    receipt.didPresent(request, time: 4, cacheHit: false)
    XCTAssertEqual(replies.first?["actualSeconds"] as? Double, 4)
  }

  func testNativeScrubOldRenderFailureCannotCancelNewStylePresentation() {
    let receipt = MCNativeScrubReceipt()
    var replies: [[String: Any]] = []
    let request = receipt.begin(exact: true) { replies.append($0) }
    let oldPresentation: UInt64 = 10
    let newPresentation: UInt64 = 11
    receipt.didSeek(request, ok: true)
    receipt.invalidatePresentation() // style keeps the user's exact seek alive
    // The old drawable's invalidation reports false after a new style render
    // has begun. This is the same ownership gate as the production callback.
    if receipt.acceptsPresentation(request, presentation: oldPresentation,
                                   currentPresentation: newPresentation) {
      receipt.cancel()
    }
    XCTAssertTrue(replies.isEmpty)
    XCTAssertTrue(receipt.isPending)
    XCTAssertFalse(receipt.acceptsPresentation(request, presentation: oldPresentation,
                                              currentPresentation: nil))
    XCTAssertTrue(receipt.acceptsPresentation(request, presentation: newPresentation,
                                             currentPresentation: newPresentation))
    receipt.didPresent(request, time: 4, cacheHit: false)
    XCTAssertEqual(replies.count, 1)
    XCTAssertEqual(replies.first?["displayed"] as? Bool, true)
    XCTAssertEqual(replies.first?["actualSeconds"] as? Double, 4)
  }

  func testNativePauseInvalidatesPlayAfterAlignmentWithoutCancellingScrub() {
    let intent = MCNativePlaybackIntent()
    let playWaitingForSeek = intent.replace()
    intent.replace() // pause/new gesture/dispose
    XCTAssertFalse(intent.isCurrent(playWaitingForSeek))
    let nextPlay = intent.replace()
    XCTAssertTrue(intent.isCurrent(nextPlay))
    XCTAssertFalse(intent.isCurrent(playWaitingForSeek))
  }

  func testNativeScrubNoOpRedrawAcceptsActualTickWithoutCrossingInstruction() throws {
    let cache = MCNativeScrubCache()
    let layout = cache.nextLayout()
    let target = 0.4
    let actual = target + 2.0 / 600.0
    let delivered = expectation(description: "actual redraw tick")
    cache.beginPresentation(target: target, tolerance: 0.001)
    cache.allowNoticeTolerance(2.0 / 600.0 + 0.0001)
    cache.onFrame = { frame in
      XCTAssertEqual(frame.time, actual)
      delivered.fulfill()
    }
    let buffer = try scrubBuffer()
    cache.insert(buffer, time: actual, epoch: CIExportCompositor.liveEpoch,
      layout: layout, range: scrubRange, hdr: false)
    wait(for: [delivered], timeout: 1)
    let nextInstruction = CMTimeRange(start: CMTime(seconds: 0.402, preferredTimescale: 600),
      duration: CMTime(seconds: 1, preferredTimescale: 600))
    XCTAssertFalse(MCNativeScrubCache.accepts(time: actual, target: target,
      tolerance: 2.0 / 600.0 + 0.0001, range: nextInstruction))
  }

  func testNativeScrubRequestsKeepOneFrameAliveUntilItPresentsThenTakeOnlyLatest() {
    let requests = MCNativeScrubRequests()
    var starts: [MCNativeScrubRequests.Request] = []
    var results: [Int: [[String: Any]]] = [:]
    requests.onStart = { starts.append($0) }
    for second in 1...100 {
      requests.submit(seconds: Double(second), exact: second == 100, toleranceMs: 150) {
        results[second, default: []].append($0)
      }
    }
    XCTAssertEqual(starts.map(\.seconds), [1])
    XCTAssertEqual(requests.pending?.seconds, 100)
    XCTAssertEqual(requests.coalesced, 99)
    XCTAssertEqual(results[1]?.first?["displayed"] as? Bool, false)
    XCTAssertNil(results[100])
    // The first physical request can finish after its obsolete Dart reply was
    // cancelled. Intermediate touches did not restart its decoder or drawable.
    requests.complete(starts[0].id, result: ["displayed": true, "actualSeconds": 1.0])
    XCTAssertEqual(starts.map(\.seconds), [1, 100])
    XCTAssertTrue(starts[1].exact)
    XCTAssertEqual(results[1]?.count, 1)
    requests.complete(starts[0].id, result: ["displayed": false])
    XCTAssertEqual(requests.active?.seconds, 100, "late old failures cannot cancel final exact")
    requests.complete(starts[1].id, result: ["displayed": true, "actualSeconds": 100.0])
    XCTAssertEqual(results[100]?.first?["actualSeconds"] as? Double, 100)
    XCTAssertNil(requests.active)
  }

  func testNativeScrubRequestsCancelActiveAndPendingWithoutRestartingOnLateCompletion() {
    let requests = MCNativeScrubRequests()
    var starts: [MCNativeScrubRequests.Request] = []
    var replies = 0
    requests.onStart = { starts.append($0) }
    requests.submit(seconds: 1, exact: false, toleranceMs: 150) { _ in replies += 1 }
    requests.submit(seconds: 4, exact: true, toleranceMs: 0) { _ in replies += 1 }
    requests.cancel() // play/pause/dispose/new composition
    requests.complete(starts[0].id, result: ["displayed": true])
    XCTAssertEqual(replies, 2)
    XCTAssertEqual(starts.count, 1)
    XCTAssertNil(requests.active)
    XCTAssertNil(requests.pending)
  }

  func testNativeScrubPresentationIgnoresHiddenAndOffscreenHosts() {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let parent = UIView(frame: window.bounds)
    let visible = UIView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
    let hidden = UIView(frame: visible.frame)
    window.addSubview(parent); parent.addSubview(visible); parent.addSubview(hidden)
    window.isHidden = false
    defer { window.isHidden = true }
    hidden.isHidden = true
    XCTAssertTrue(MCNativeScrubPlane.canPresent(in: visible))
    XCTAssertFalse(MCNativeScrubPlane.canPresent(in: hidden))
    visible.frame.origin.x = 101
    XCTAssertFalse(MCNativeScrubPlane.canPresent(in: visible))
    visible.frame.origin.x = 0
    parent.alpha = 0
    XCTAssertFalse(MCNativeScrubPlane.canPresent(in: visible))
  }

  func testNativeScrubFrameGridPreservesStartAndEndAndDoesNotGoBeforeBoundary() {
    XCTAssertEqual(CompPlayer.nativeFrameTarget(0, duration: 10), 0)
    XCTAssertEqual(CompPlayer.nativeFrameTarget(1.001, duration: 10), 31.0 / 30)
    XCTAssertEqual(CompPlayer.nativeFrameTarget(10, duration: 10), 299.0 / 30)
    XCTAssertEqual(CompPlayer.nativeFrameTarget(-1, duration: 10), 0)
    XCTAssertEqual(CompPlayer.nativeFrameTarget(.nan, duration: 10), 0)
  }

  private func scrubMetalResources(format: MTLPixelFormat) throws
    -> (CIContext, MTLTexture, MTLCommandBuffer) {
    guard let device = MTLCreateSystemDefaultDevice(),
      let command = device.makeCommandQueue()?.makeCommandBuffer() else {
      throw XCTSkip("Metal unavailable on this test destination")
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format, width: 16, height: 16, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let context = CIContext(mtlDevice: device, options: [
      .workingFormat: CIFormat.RGBAh,
      .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
    ])
    return (context, texture, command)
  }

  func testNativeScrubMetalDisplayPreservesTopAndBottomOrientation() throws {
    let (context, texture, command) = try scrubMetalResources(format: .bgra8Unorm)
    let buffer = try scrubBuffer()
    CVPixelBufferLockBaseAddress(buffer, [])
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    for y in 0..<16 { for x in 0..<16 {
      let p = pixels.advanced(by: y * stride + x * 4)
      p[0] = y < 8 ? 0 : 255; p[1] = 0
      p[2] = y < 8 ? 255 : 0; p[3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let frame = MCNativeScrubCache.Frame(buffer: buffer, time: 0, epoch: 0, layout: 0,
      range: scrubRange, hdr: false, bytes: stride * 16)
    try MCNativeScrubPlane.encode(frame, to: texture, command: command, context: context)
    command.commit(); command.waitUntilCompleted()
    XCTAssertEqual(command.status, .completed)
    var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
    bytes.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 64,
      from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
    XCTAssertGreaterThan(bytes[2], 240, "top red row must stay at top")
    XCTAssertLessThan(bytes[0], 10)
    XCTAssertGreaterThan(bytes[15 * 64], 240, "bottom blue row must stay at bottom")
    XCTAssertLessThan(bytes[15 * 64 + 2], 10)
  }

  func testNativeScrubHLGDisplayDoesNotRenormalizeReferenceWhiteOrHighlights() throws {
    guard #available(iOS 16.0, *) else { throw XCTSkip("Native HDR scrub requires iOS 16") }
    for level: Float in [0.5, 0.75, 1.0] {
      let (context, texture, command) = try scrubMetalResources(format: .bgr10a2Unorm)
      let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2100_HLG))
      let values: [Float] = [level, level, level, 1]
      let data = values.withUnsafeBytes { Data($0) }
      let image = CIImage(bitmapData: data, bytesPerRow: 16,
        size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: colorSpace)
        .clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
      var optionalBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:],
         kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &optionalBuffer)
      XCTAssertEqual(status, kCVReturnSuccess)
      let buffer = try XCTUnwrap(optionalBuffer)
      context.render(image, to: buffer, bounds: image.extent, colorSpace: colorSpace)
      CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
      CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
      CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
      let frame = MCNativeScrubCache.Frame(buffer: buffer, time: 0, epoch: 0, layout: 0,
        range: scrubRange, hdr: true, bytes: 1)
      try MCNativeScrubPlane.encode(frame, to: texture, command: command, context: context)
      command.commit(); command.waitUntilCompleted()
      XCTAssertEqual(command.status, .completed)
      var words = [UInt32](repeating: 0, count: 256)
      words.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 64,
        from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
      let pixel = words[8 * 16 + 8]
      for component in [pixel & 1023, (pixel >> 10) & 1023, (pixel >> 20) & 1023] {
        XCTAssertEqual(Double(component) / 1023, Double(level), accuracy: 0.015,
          "HLG encoded values must survive the display conversion without another white-point gain")
      }
    }
  }

  private func verifyNativeDrawablePresentation(hdr: Bool) throws {
    guard MCNativeScrubPlane.supported else { throw XCTSkip("Metal unavailable") }
    let previousKeyWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
    let window: UIWindow
    if let scene = previousKeyWindow?.windowScene {
      window = UIWindow(windowScene: scene)
      window.frame = scene.coordinateSpace.bounds
    } else {
      window = UIWindow(frame: UIScreen.main.bounds)
    }
    let controller = UIViewController()
    controller.view.backgroundColor = .black
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true; previousKeyWindow?.makeKeyAndVisible() }
    let host = PlayerHostView(frame: CGRect(x: 20, y: 60, width: 128, height: 192))
    controller.view.addSubview(host)
    host.setNeedsLayout(); host.layoutIfNeeded()
    XCTAssertTrue(MCNativeScrubPlane.canPresent(in: host))
    let buffer = try scrubBuffer()
    let frame = MCNativeScrubCache.Frame(buffer: buffer, time: 0, epoch: 0, layout: 0,
      range: scrubRange, hdr: hdr, bytes: 1024)
    // Unlike the offscreen encode tests, this exercises nextDrawable, a real
    // UIView hierarchy, the CA transaction and addPresentedHandler. Repeating
    // the same PTS here validates the display plane, independently of AVPlayer.
    for attempt in 0..<3 {
      let presented = expectation(description: "\(hdr ? "HLG" : "SDR") drawable \(attempt)")
      host.scrubPlane.present(frame, valid: { true }) { ok, reason in
        XCTAssertTrue(ok, "native drawable was not displayed: \(reason ?? "unknown")")
        presented.fulfill()
      }
      wait(for: [presented], timeout: 5)
      XCTAssertTrue(host.scrubPlane.visible)
      XCTAssertEqual(host.scrubPlane.layer.pixelFormat, hdr ? .bgr10a2Unorm : .bgra8Unorm)
      if #available(iOS 16.0, *) {
        XCTAssertNil(host.scrubPlane.layer.edrMetadata,
          "encoded HDR must not enable the linear-float EDR metadata pipeline")
      }
    }
  }

  func testNativeSDRDrawableActuallyPresentsRepeatedSameTimeInWindow() throws {
    try verifyNativeDrawablePresentation(hdr: false)
  }

  func testNativeHLGDrawableActuallyPresentsRepeatedSameTimeInWindow() throws {
    try verifyNativeDrawablePresentation(hdr: true)
  }

  private func makeScrubVideo() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("native-scrub-\(UUID().uuidString).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
      AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 10],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
      ])
    XCTAssertTrue(writer.canAdd(input)); writer.add(input)
    XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    let finished = expectation(description: "encoded scrub fixture")
    let buffer = try scrubBuffer(width: 64, height: 64)
    CVPixelBufferLockBaseAddress(buffer, [])
    let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
    address.initializeMemory(as: UInt8.self, repeating: 128,
      count: CVPixelBufferGetBytesPerRow(buffer) * 64)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    var next = 0
    var ending = false
    input.requestMediaDataWhenReady(on: DispatchQueue(label: "native-scrub.fixture")) {
      guard !ending else { return }
      while input.isReadyForMoreMediaData, next < 30 {
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(next), timescale: 30)) else {
          ending = true; writer.cancelWriting(); finished.fulfill(); return
        }
        next += 1
      }
      if next == 30 {
        ending = true; input.markAsFinished()
        writer.finishWriting { finished.fulfill() }
      }
    }
    wait(for: [finished], timeout: 10)
    XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "fixture encode failed")
    return url
  }

  func testNativeExactScrubActuallyPresentsAfterClearingCacheAtTheSamePlayerTime() throws {
    guard MCNativeScrubPlane.supported else { throw XCTSkip("Metal unavailable") }
    let url = try makeScrubVideo()
    defer { try? FileManager.default.removeItem(at: url) }
    let registry = ScrubTestTextureRegistry()
    let player = CompPlayer(registry: registry)
    let previousKeyWindow = UIApplication.shared.windows.first(where: \.isKeyWindow)
    let window: UIWindow
    if let scene = previousKeyWindow?.windowScene {
      window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
    } else { window = UIWindow(frame: UIScreen.main.bounds) }
    window.rootViewController = UIViewController(); window.makeKeyAndVisible()
    let host = PlayerHostView(frame: CGRect(x: 20, y: 60, width: 128, height: 192))
    window.rootViewController!.view.addSubview(host)
    host.setNeedsLayout(); host.layoutIfNeeded()
    PlayerHosts.shared.register(host)
    defer {
      PlayerHosts.shared.onNativeScrubInvalidated = nil
      PlayerHosts.shared.onNativeScrubStyleChanged = nil
      PlayerHosts.shared.use(nil); player.dispose()
      window.isHidden = true; previousKeyWindow?.makeKeyAndVisible()
    }
    XCTAssertTrue(player.build(clips: [["path": url.path, "start": 0.0, "end": 1.0,
      "offset": 0.0, "track": 0, "opacity": 0.99]], texture: false))
    XCTAssertTrue(player.nativeScrubSupported)
    PlayerHosts.shared.use(player.player)
    PlayerHosts.shared.onNativeScrubInvalidated = { [weak player] in player?.invalidateNativeScrub() }
    PlayerHosts.shared.onNativeScrubStyleChanged = { [weak player] in player?.nativeStyleChanged() }
    for attempt in 0..<2 {
      if attempt > 0 { PlayerHosts.shared.invalidateNativeScrub() }
      let landed = expectation(description: "same-time exact CI scrub \(attempt)")
      player.scrub(0.4, exact: true, toleranceMs: 0) { result in
        XCTAssertEqual(result["displayed"] as? Bool, true, "\(player.healthStats())")
        XCTAssertEqual(result["actualSeconds"] as? Double ?? -1, 0.4, accuracy: 0.004)
        landed.fulfill()
      }
      wait(for: [landed], timeout: 5)
    }
  }

  func testInteractivePrepGateResumesTheSameWaitingJob() {
    let gate = MCInteractivePrepGate()
    let cancel = AtomicFlag()
    gate.setInteractive(true)
    let entered = expectation(description: "worker entered")
    let completed = expectation(description: "worker resumed")
    let returned = AtomicFlag()
    DispatchQueue.global().async {
      entered.fulfill()
      XCTAssertTrue(gate.wait(cancelled: cancel))
      returned.set(); completed.fulfill()
    }
    wait(for: [entered], timeout: 1)
    XCTAssertFalse(returned.isSet)
    XCTAssertTrue(gate.isInteractive)
    gate.setInteractive(false)
    wait(for: [completed], timeout: 1)
    XCTAssertGreaterThanOrEqual(gate.pausedDuration, 0)
  }

  func testInteractivePrepGateCancellationDoesNotRequireResumingPlayback() {
    let gate = MCInteractivePrepGate()
    let cancel = AtomicFlag()
    gate.setInteractive(true)
    let completed = expectation(description: "cancelled while paused")
    DispatchQueue.global().async {
      XCTAssertFalse(gate.wait(cancelled: cancel)); completed.fulfill()
    }
    cancel.set()
    wait(for: [completed], timeout: 1)
    XCTAssertTrue(gate.isInteractive)
  }

  func testFrameGeneratorPoolReusesAndEvictsTheLeastRecentlyUsedEntry() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = (0..<3).map { directory.appendingPathComponent("\($0).mov").path }
    for path in paths { try Data([1, 2, 3]).write(to: URL(fileURLWithPath: path)) }
    let pool = MCFrameGeneratorPool()
    let first = try XCTUnwrap(pool.generator(path: paths[0], maxH: 540))
    let second = try XCTUnwrap(pool.generator(path: paths[1], maxH: 540))
    XCTAssertTrue(first === pool.generator(path: paths[0], maxH: 540))
    XCTAssertEqual(pool.hitCount, 1)
    XCTAssertNotNil(pool.generator(path: paths[2], maxH: 540))
    XCTAssertEqual(pool.count, 2)
    XCTAssertFalse(second === pool.generator(path: paths[1], maxH: 540))
    XCTAssertEqual(pool.count, 2)
    XCTAssertEqual(pool.createdCount, 4)
    pool.removeAll()
    XCTAssertEqual(pool.count, 0)
  }

  func testFrameGeneratorPoolInvalidatesReplacedFilesAndOutputSize() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    try Data([1, 2, 3]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let pool = MCFrameGeneratorPool()
    let first = try XCTUnwrap(pool.generator(path: url.path, maxH: 540))
    let large = try XCTUnwrap(pool.generator(path: url.path, maxH: 1080))
    XCTAssertFalse(first === large)
    XCTAssertEqual(pool.count, 2)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)],
      ofItemAtPath: url.path)
    let replaced = try XCTUnwrap(pool.generator(path: url.path, maxH: 540))
    XCTAssertFalse(first === replaced)
    XCTAssertEqual(pool.count, 1, "replacing a path invalidates all its previous output sizes")
    try Data([1, 2, 3, 4]).write(to: url)
    let resized = try XCTUnwrap(pool.generator(path: url.path, maxH: 540))
    XCTAssertFalse(replaced === resized)
    XCTAssertEqual(pool.count, 1)
    try FileManager.default.removeItem(at: url)
    XCTAssertNil(pool.generator(path: url.path, maxH: 540))
    XCTAssertEqual(pool.count, 0)
  }

  private func visibilityLayer(
    id: CMPersistentTrackID, width: CGFloat = 100, height: CGFloat = 100,
    transform: CGAffineTransform = .identity, opaque: Bool = true,
    opacity: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0,
    crop: CGRect? = nil, rotation: Double = 0, color: [Double]? = nil
  ) -> CILayerSpec {
    CILayerSpec(trackID: id, still: nil, transform: transform,
      srcHeight: height, start: 0, end: 10, fadeIn: fadeIn, fadeOut: fadeOut,
      colorMatrix: color, crop: crop, rotation: rotation, opacity: opacity,
      z: Int(id), srcWidth: width, sourceOpaque: opaque)
  }

  func testPreviewOcclusionRequestsOnlyTheTopOpaqueFullCanvasSource() {
    let layers = (1...5).map { visibilityLayer(id: Int32($0)) }
    let retained = MCPreviewVisibility.visibleLayers(
      layers, canvas: CGSize(width: 100, height: 100), enabled: true)
    XCTAssertEqual(retained.map { $0.trackID }, [5])
    let instruction = CIExportInstruction(
      timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10,
        preferredTimescale: 600)), layers: retained, mosaics: [], overlays: [])
    XCTAssertEqual(instruction.requiredSourceTrackIDs?.count, 1)
    XCTAssertEqual((instruction.requiredSourceTrackIDs?.first as? NSNumber)?.int32Value, 5)
  }

  func testPreviewSourceWithMissingFormatMetadataCannotOcclude() throws {
    let composition = AVMutableComposition()
    let track = try XCTUnwrap(composition.addMutableTrack(
      withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
    XCTAssertFalse(MCPreviewVisibility.sourceIsOpaque(track))
  }

  func testPreviewOcclusionPreservesTransparencyAndPartialCoverage() {
    let canvas = CGSize(width: 100, height: 100)
    let base = visibilityLayer(id: 1)
    let candidates = [
      visibilityLayer(id: 2, opaque: false),
      visibilityLayer(id: 2, opacity: 0.99),
      visibilityLayer(id: 2, fadeIn: 1),
      visibilityLayer(id: 2, fadeOut: 1),
      visibilityLayer(id: 2, crop: CGRect(x: 0, y: 0, width: 1, height: 1)),
      visibilityLayer(id: 2, rotation: 0.01),
      visibilityLayer(id: 2, color: Array(repeating: 0, count: 20)),
      visibilityLayer(id: 2, transform: CGAffineTransform(scaleX: 0.5, y: 0.5)),
      visibilityLayer(id: 2, transform: CGAffineTransform(translationX: 1, y: 0)),
      visibilityLayer(id: 2, width: 50), // portrait material in square canvas
    ]
    for candidate in candidates {
      XCTAssertFalse(MCPreviewVisibility.coversCanvas(candidate, canvas: canvas))
      XCTAssertEqual(MCPreviewVisibility.visibleLayers([base, candidate],
        canvas: canvas, enabled: true).map { $0.trackID }, [1, 2])
    }
  }

  func testPreviewCoverageUsesPolygonRatherThanRotatedBoundingBox() {
    let canvas = CGSize(width: 100, height: 100)
    let diamond = CGAffineTransform(translationX: -50, y: -50)
      .concatenating(CGAffineTransform(rotationAngle: .pi / 4))
      .concatenating(CGAffineTransform(translationX: 50, y: 50))
    XCTAssertFalse(MCPreviewVisibility.coversCanvas(
      visibilityLayer(id: 1, transform: diamond), canvas: canvas))
    let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 100, ty: 0)
    XCTAssertTrue(MCPreviewVisibility.coversCanvas(
      visibilityLayer(id: 1, transform: quarterTurn), canvas: canvas))
    let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 100, ty: 0)
    XCTAssertTrue(MCPreviewVisibility.coversCanvas(
      visibilityLayer(id: 1, transform: mirror), canvas: canvas))
    XCTAssertFalse(MCPreviewVisibility.coversCanvas(visibilityLayer(id: 1,
      transform: CGAffineTransform(scaleX: 0, y: 1)), canvas: canvas))
  }

  func testPreviewOcclusionKeepsHigherStillsAndEditingRestoresAllLayers() {
    let canvas = CGSize(width: 100, height: 100)
    let overlay = CILayerSpec(trackID: kCMPersistentTrackID_Invalid,
      still: CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.5)),
      transform: .identity, srcHeight: 100, start: 0, end: 10,
      fadeIn: 0, fadeOut: 0, colorMatrix: nil, z: 3)
    let layers = [visibilityLayer(id: 1), visibilityLayer(id: 2), overlay]
    let state = MCPreviewVisibilityState()
    XCTAssertEqual(MCPreviewVisibility.visibleLayers(layers, canvas: canvas,
      enabled: state.enabled).map { $0.z }, [2, 3])
    state.noteCulling()
    XCTAssertTrue(state.hasCulledLayers)
    XCTAssertTrue(state.beginEditing())
    XCTAssertFalse(state.beginEditing())
    XCTAssertEqual(MCPreviewVisibility.visibleLayers(layers, canvas: canvas,
      enabled: state.enabled).map { $0.z }, [1, 2, 3])
    XCTAssertTrue(MCPreviewVisibilityState().enabled, "only a new build enables culling again")
  }

  func testPreviewPrerollDoesNotDecodeUpcomingSourceThroughoutLongInstruction() {
    func time(_ sec: Double) -> CMTime {
      CMTime(seconds: sec, preferredTimescale: 600)
    }
    XCTAssertEqual(MCPreviewVisibility.prerollStarts(before: [time(0), time(10)])
      .map { $0.seconds }, [8.5])
    let nearBoundary = MCPreviewVisibility.prerollStarts(
      before: [time(0), time(3.842), time(5.338)])
    XCTAssertFalse(nearBoundary.contains { abs($0.seconds - 3.838) < 0.005 },
      "a preroll point cannot displace a nearby true clip boundary")
    let exactlyThreeTicks = MCPreviewVisibility.prerollStarts(before: [
      .zero, CMTime(value: 2305, timescale: 600), CMTime(value: 3202, timescale: 600)])
    XCTAssertFalse(exactlyThreeTicks.contains { $0 == CMTime(value: 2302, timescale: 600) })
    XCTAssertFalse(MCPreviewVisibility.prerollStarts(before: [time(0), time(9.998), time(11.5)])
      .contains { abs($0.seconds - 10) < 0.001 })
    let upcoming: [(start: CMTime, tracks: Set<CMPersistentTrackID>)] = [
      (time(8.5), [5]), (time(10), [4]), (time(20), [3]),
    ]
    XCTAssertEqual(MCPreviewVisibility.requiredTracks(
      at: time(0), own: [5], upcoming: upcoming), [5])
    XCTAssertEqual(MCPreviewVisibility.requiredTracks(
      at: time(8.5), own: [5], upcoming: Array(upcoming.dropFirst())), [4, 5])
    XCTAssertEqual(MCPreviewVisibility.requiredTracks(
      at: time(10), own: [4], upcoming: Array(upcoming.dropFirst(2))), [4])
  }

  func testSeekReceiptsResolveExactlyOnceAndIgnoreSupersededNativeCallbacks() {
    let state = MCSeekCompletionState()
    var first: [Bool] = []
    var second: [Bool] = []
    let stale = state.replace { first.append($0) }
    let latest = state.replace { second.append($0) }
    XCTAssertEqual(first, [false])
    state.finish(stale, succeeded: true)
    XCTAssertTrue(second.isEmpty)
    state.finish(latest, succeeded: true)
    state.finish(latest, succeeded: false)
    XCTAssertEqual(second, [true])
    var cancelled: [Bool] = []
    let pending = state.replace { cancelled.append($0) }
    state.replace(with: nil) // play / build / dispose
    state.finish(pending, succeeded: true)
    XCTAssertEqual(cancelled, [false])
  }

  func testExactSeekAlwaysUsesZeroTolerance() {
    XCTAssertEqual(MCSeekCompletionState.tolerance(exact: true, milliseconds: 150), .zero)
    XCTAssertEqual(MCSeekCompletionState.tolerance(exact: false, milliseconds: nil), .zero)
    XCTAssertEqual(MCSeekCompletionState.tolerance(exact: false, milliseconds: 150).seconds,
      0.15, accuracy: 0.000001)
    XCTAssertEqual(MCSeekCompletionState.tolerance(exact: false, milliseconds: -1), .zero)
    XCTAssertEqual(MCSeekCompletionState.tolerance(exact: false, milliseconds: 5000).seconds,
      0.5, accuracy: 0.000001)
  }

  func testTrimmedGifSamplesSourceTimeInsteadOfRestarting() throws {
    let context = CIContext()
    let bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("gif")
    defer { try? FileManager.default.removeItem(at: url) }
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
      url as CFURL, "com.compuserve.gif" as CFString, 2, nil))
    for color in [CIColor(red: 1, green: 0, blue: 0), CIColor(red: 0, green: 0, blue: 1)] {
      let image = try XCTUnwrap(context.createCGImage(
        CIImage(color: color).cropped(to: bounds), from: bounds))
      CGImageDestinationAddImage(destination, image,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let gif = try XCTUnwrap(CIGifSpec(path: url.path, placement: .identity,
      clipStart: 2, sourceStart: 0.6, sourceRate: 2))
    func rgb(at time: Double) throws -> [UInt8] {
      let frame = try XCTUnwrap(gif.image(at: time))
      var pixel = [UInt8](repeating: 0, count: 4)
      context.render(frame, toBitmap: &pixel, rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
      return pixel
    }
    XCTAssertGreaterThan(try rgb(at: 2)[2], 240, "trim begins on the blue frame")
    XCTAssertGreaterThan(try rgb(at: 2.3)[0], 240, "2x speed wraps to the red frame")
  }

  private func hlgCode(_ scene: Double) -> Double {
    if scene <= 1.0 / 12 { return sqrt(3 * scene) }
    let a = 0.17883277
    return a * log(12 * scene - (1 - 4 * a)) + 0.5 - a * log(4 * a)
  }

  func testHlgWhiteCalibrationSeparatesGammaFromWhiteLevel() throws {
    let reference = MCStillLoader.hlgScene(0.75)
    // Correct reference white, 100-nit white, and peak-normalized output.
    // Each can independently use scene- or display-referred conversion.
    for white in [reference, pow(0.1, 1 / 1.2), 1.0] {
      for power in [1.0, 1 / 1.2] {
        let mapping = try XCTUnwrap(MCStillLoader.transfer(
          greyCode: hlgCode(white * pow(0.18, power)), whiteCode: hlgCode(white)))
        XCTAssertEqual(mapping.sceneReferred, power == 1)
        XCTAssertEqual(hlgCode(white * pow(mapping.whiteGain, power)), 0.75,
                       accuracy: 0.0001)
        let adjustedGrey = mapping.whiteGain *
          (mapping.sceneReferred ? pow(0.18, 1 / 1.2) : 0.18)
        XCTAssertEqual(pow(white * pow(adjustedGrey, power) / reference, 1.2),
                       0.18, accuracy: 0.0001)
      }
    }
    XCTAssertNil(MCStillLoader.transfer(greyCode: .nan, whiteCode: 0.75))
    XCTAssertNil(MCStillLoader.transfer(greyCode: 0.8, whiteCode: 0.75))
  }

  func testOpaqueImportedWhiteAndGreyKeepTheirHlgReferenceLevels() throws {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let hlg = CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
    let bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
    let ctx = CIExportCompositor.ctxHDR
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    defer { try? FileManager.default.removeItem(at: url) }
    for value in [CGFloat(1), CGFloat(0.4614)] {
      let source = CIImage(color: CIColor(red: value, green: value, blue: value,
                                         alpha: 1, colorSpace: srgb)!).cropped(to: bounds)
      try ctx.writePNGRepresentation(of: source, to: url, format: .RGBA8,
                                     colorSpace: srgb, options: [:])
      let loaded = try XCTUnwrap(MCStillLoader.load(path: url.path, hdr: true, hint: false))
      XCTAssertTrue(MCStillLoader.hlgProbe().ok, MCStillLoader.hlgReport(override: nil))
      var pixel = [UInt16](repeating: 0, count: 4)
      ctx.render(loaded, toBitmap: &pixel, rowBytes: 8,
                 bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                 format: .RGBA16, colorSpace: hlg)
      let expected = value == 1 ? 0.75 : hlgCode(
        MCStillLoader.hlgScene(0.75) * pow(0.18, 1 / 1.2))
      for channel in pixel.prefix(3) {
        XCTAssertEqual(Double(channel) / 65535, expected, accuracy: 0.01)
      }
      XCTAssertEqual(pixel[3], 65535, "100% opacity must remain opaque")
    }
  }

  func testOpacityPreservesColorOverWhite() {
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let ctx = CIContext(options: [.workingColorSpace: space])
    let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1,
                                      alpha: 1, colorSpace: space)!).cropped(to: bounds)
    for opacity in [0.0, 0.25, 0.5, 0.94, 1.0] {
      let output = CIExportCompositor.applyingOpacity(white, opacity: opacity)
        .composited(over: white)
      var pixel = [Float](repeating: 0, count: 4)
      ctx.render(output, toBitmap: &pixel, rowBytes: 16, bounds: bounds,
                 format: .RGBAf, colorSpace: space)
      for channel in pixel {
        XCTAssertEqual(channel, 1, accuracy: 0.005,
                       "White over white must stay white at opacity \(opacity)")
      }
    }
  }

  func testOpacityBlendsColorWithoutExtraDimming() {
    let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let ctx = CIContext(options: [.workingColorSpace: space])
    let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let source = CIImage(color: CIColor(red: 0.8, green: 0.4, blue: 0.2,
                                       alpha: 1, colorSpace: space)!).cropped(to: bounds)
    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1,
                                      alpha: 1, colorSpace: space)!).cropped(to: bounds)
    let output = CIExportCompositor.applyingOpacity(source, opacity: 0.5)
      .composited(over: white)
    var pixel = [Float](repeating: 0, count: 4)
    ctx.render(output, toBitmap: &pixel, rowBytes: 16, bounds: bounds,
               format: .RGBAf, colorSpace: space)
    for (actual, expected) in zip(pixel, [Float(0.9), 0.7, 0.6, 1]) {
      XCTAssertEqual(actual, expected, accuracy: 0.005)
    }
  }

}
