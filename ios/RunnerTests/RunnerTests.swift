import Flutter
import UIKit
import XCTest
import CoreImage
import ImageIO
import AVFoundation
import Metal
import file_picker
@testable import Runner

private final class ScrubTestTextureRegistry: NSObject, FlutterTextureRegistry {
  func register(_ texture: FlutterTexture) -> Int64 { 1 }
  func textureFrameAvailable(_ textureId: Int64) {}
  func unregisterTexture(_ textureId: Int64) {}
}

/// Holds each asynchronous provider open until the test releases its callback.
private final class HeldImportProvider: NSItemProvider {
  let started: XCTestExpectation
  let requestProgress = Progress(totalUnitCount: 1)
  private let lock = NSLock()
  private var callback: ((URL?, Error?) -> Void)?
  private var starts = 0
  let supported: Bool
  init(_ started: XCTestExpectation, supported: Bool = true) {
    self.started = started
    self.supported = supported
    super.init()
  }
  var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
  override func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool {
    supported && typeIdentifier == "public.movie"
  }
  override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String,
    completionHandler: @escaping (URL?, Error?) -> Void) -> Progress {
    lock.lock()
    starts += 1
    callback = completionHandler
    lock.unlock()
    started.fulfill()
    return requestProgress
  }
  func finish(_ url: URL?, error: Error? = nil) {
    lock.lock()
    let reply = callback
    callback = nil
    lock.unlock()
    reply?(url, error)
  }
}

class RunnerTests: XCTestCase {

  private func hdrFixture() throws -> URL {
    try XCTUnwrap(Bundle(for: RunnerTests.self)
      .url(forResource: "native-hdr-rotated", withExtension: "mp4"))
  }

  private func hdrLuma(_ buffer: CVPixelBuffer, at point: CGPoint) -> Double {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let x = max(0, min(CVPixelBufferGetWidth(buffer) - 1, Int(point.x)))
    let y = max(0, min(CVPixelBufferGetHeight(buffer) - 1, Int(point.y)))
    let row = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
      .advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
      .assumingMemoryBound(to: UInt16.self)
    return Double(row[x] >> 6) / 1023
  }

  func testProxyGeometryNormalizesTranslatedRotationsAndMirrors() throws {
    for angle in [0.0, Double.pi / 2, Double.pi, -Double.pi / 2] {
      for mirror in [CGFloat(1), CGFloat(-1)] {
        let raw = CGAffineTransform(scaleX: mirror, y: 1)
          .concatenating(CGAffineTransform(rotationAngle: angle))
          .concatenating(CGAffineTransform(translationX: -173, y: 97))
        let geometry = try XCTUnwrap(MCProxyGeometry(naturalSize: CGSize(width: 128, height: 64),
          preferredTransform: raw, maxShortSide: 32))
        let bounds = CGRect(x: 0, y: 0, width: 128, height: 64).applying(geometry.transform)
        XCTAssertEqual(bounds.minX, 0, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.001)
        XCTAssertEqual(bounds.width, geometry.size.width, accuracy: 0.001)
        XCTAssertEqual(bounds.height, geometry.size.height, accuracy: 0.001)
        XCTAssertEqual(min(geometry.size.width, geometry.size.height), 32)
      }
    }
  }

  func testProxyGeometryKeepsCanonicalPortraitAndNeverUpscales() throws {
    let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0)
    let geometry = try XCTUnwrap(MCProxyGeometry(naturalSize: CGSize(width: 128, height: 64),
      preferredTransform: portrait, maxShortSide: 900))
    XCTAssertEqual(geometry.size, CGSize(width: 64, height: 128))
    XCTAssertEqual(geometry.transform, portrait)
    XCTAssertNil(MCProxyGeometry(naturalSize: .zero, preferredTransform: .identity, maxShortSide: 900))
  }

  func testHDRProxyPoolHardLimitAndReuseAfterEncoderReleasesBuffer() throws {
    let renderer = try XCTUnwrap(MCBoundedHDRRenderer(size: CGSize(width: 64, height: 128)))
    var held: [CVPixelBuffer] = []
    for _ in 0..<MCBoundedHDRRenderer.bufferLimit {
      try autoreleasepool {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(renderer.takeBuffer(&buffer), kCVReturnSuccess)
        held.append(try XCTUnwrap(buffer))
      }
    }
    for _ in 0..<20 {
      var denied: CVPixelBuffer?
      XCTAssertEqual(renderer.takeBuffer(&denied), kCVReturnWouldExceedAllocationThreshold)
      XCTAssertNil(denied, "backpressure must not allocate a ninth surface")
    }
    held.removeLast()
    var recycled: CVPixelBuffer?
    XCTAssertEqual(renderer.takeBuffer(&recycled), kCVReturnSuccess)
    XCTAssertNotNil(recycled, "a released encoder surface must be reusable")
    withExtendedLifetime(held) {}
  }

  func testHDRProxyCadencePreservesVariableTimestampsAndCaps120FPS() {
    var cadence = MCProxyFrameCadence()
    let times = (0..<120).map { CMTime(value: Int64($0), timescale: 120) }
    let kept = times.filter { cadence.accepts($0, sourceFPS: 120) }
    XCTAssertEqual(kept.count, 60)
    XCTAssertEqual(kept.first, .zero)
    XCTAssertEqual(kept.last, CMTime(value: 118, timescale: 120))
    for value in [0, 33, 69, 103, 138, 171] {
      XCTAssertTrue(cadence.accepts(CMTime(value: Int64(value), timescale: 1000), sourceFPS: 29.97))
    }
  }

  func testHDRProxyRendererBakesAllOrientationsWithoutClippingHighlights() throws {
    let asset = AVURLAsset(url: try hdrFixture())
    let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    defer { reader.cancelReading() }
    let sample = try XCTUnwrap(output.copyNextSampleBuffer())
    let source = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    let transforms: [CGAffineTransform] = [
      .identity,
      CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0),
      CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 128, ty: 64),
      CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 128),
    ]
    for (index, rawTransform) in (transforms + [track.preferredTransform]).enumerated() {
      try autoreleasepool {
        let geometry = try XCTUnwrap(MCProxyGeometry(naturalSize: track.naturalSize,
          preferredTransform: rawTransform, maxShortSide: 64))
        let transform = geometry.transform
        let renderer = try XCTUnwrap(MCBoundedHDRRenderer(size: geometry.size))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(renderer.takeBuffer(&buffer), kCVReturnSuccess)
        let rendered = try XCTUnwrap(buffer)
        renderer.render(source, to: rendered, transform: transform, sourceHeight: 64)
        let bright = hdrLuma(rendered, at: CGPoint(x: 32, y: 32).applying(transform))
        let gray = hdrLuma(rendered, at: CGPoint(x: 96, y: 32).applying(transform))
        XCTAssertEqual(bright, 940.0 / 1023, accuracy: 0.05, "rotation \(index): HDR highlight clipped")
        XCTAssertEqual(gray, 512.0 / 1023, accuracy: 0.05, "rotation \(index): wrong geometry or transfer")
        let transfer = CVBufferGetAttachment(rendered, kCVImageBufferTransferFunctionKey, nil)?
          .takeUnretainedValue() as? String
        XCTAssertEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
      }
    }
  }

  func testSpatialAudioProxyRequestsBinauralDecodeAndValidStereoAACSettings() throws {
    for channels: UInt32 in [1, 4, 16] {
      var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: 0x61706163,
        mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
        mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
      var format: CMAudioFormatDescription?
      XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
        asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
        extensions: nil, formatDescriptionOut: &format), noErr)
      let plan = MCProxyAudioPlan(format: try XCTUnwrap(format))
      let read = try XCTUnwrap(plan.readerSettings)
      let write = try XCTUnwrap(plan.writerSettings)
      XCTAssertEqual(read[AVNumberOfChannelsKey] as? Int, 2)
      XCTAssertEqual(write[AVNumberOfChannelsKey] as? Int, 2)
      for (settings, expectedTag) in [(read, kAudioChannelLayoutTag_Binaural),
                                      (write, kAudioChannelLayoutTag_Stereo)] {
        let data = try XCTUnwrap(settings[AVChannelLayoutKey] as? Data)
        var layout = AudioChannelLayout()
        _ = withUnsafeMutableBytes(of: &layout) { data.copyBytes(to: $0) }
        XCTAssertEqual(layout.mChannelLayoutTag, expectedTag)
      }
      // This is the constructor that used to raise an uncaught exception.
      // It must receive two channels plus a matching, explicit layout.
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: write)
      XCTAssertEqual(input.mediaType, .audio)
    }
  }

  func testHDRProxyTranscodesReal10BitRotatedVideoWithMultichannelAAC() throws {
    let input = try hdrFixture()
    let source = AVURLAsset(url: input)
    let track = try XCTUnwrap(source.tracks(withMediaType: .audio).first)
    let format = try XCTUnwrap(track.formatDescriptions.first) as! CMFormatDescription
    let plan = MCProxyAudioPlan(format: format)
    XCTAssertNil(plan.readerSettings, "AAC should not start another decoder")
    XCTAssertNil(plan.writerSettings, "preserve the original AAC channel layout and packets")
    XCTAssertNotNil(plan.sourceFormatHint, "MP4 passthrough requires a format hint")
    try assertHDRProxy(input: input, sourceChannels: 4, outputChannels: 4, duration: 3, frames: 90)
  }

  func testHDRProxyConvertsSurroundPCMBeforeInitializingAACWriter() throws {
    let input = try XCTUnwrap(Bundle(for: RunnerTests.self)
      .url(forResource: "native-hdr-surround", withExtension: "mov"))
    try assertHDRProxy(input: input, sourceChannels: 6, outputChannels: 2, duration: 1, frames: 30)
  }

  private func assertHDRProxy(input: URL, sourceChannels: UInt32, outputChannels: UInt32,
                             duration: Double, frames: Int) throws {
    let source = AVURLAsset(url: input)
    let sourceTrack = try XCTUnwrap(source.tracks(withMediaType: .audio).first)
    let sourceFormat = try XCTUnwrap(sourceTrack.formatDescriptions.first) as! CMFormatDescription
    XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormat)?.pointee.mChannelsPerFrame,
      sourceChannels, "fixture must cover the >2-channel crash path")
    XCTAssertTrue(CompPlayer.isHDRSource(input.path), "the fixture must really be HDR")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("proxy.mp4")
    let complete = expectation(description: "bounded HDR proxy completed")
    complete.assertForOverFulfill = true
    var error: String?
    let delegate = AppDelegate()
    delegate.transcodeWorkFile(src: input.path, dest: destination.path, maxShortSide: 64,
      channel: nil, label: "HDR regression", hdrPass: true) { result in
        XCTAssertTrue(Thread.isMainThread)
        error = result
        complete.fulfill()
      }
    wait(for: [complete], timeout: 90)
    withExtendedLifetime(delegate) {}
    XCTAssertNil(error)
    guard error == nil else { return }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["proxy.mp4"])
    let asset = AVURLAsset(url: destination)
    let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
    XCTAssertEqual(track.naturalSize, CGSize(width: 64, height: 128))
    XCTAssertTrue(track.preferredTransform.isIdentity, "orientation must be baked, not applied twice")
    XCTAssertEqual(asset.duration.seconds, duration, accuracy: 0.05)
    XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1)
    let audioTrack = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
    let audioFormat = try XCTUnwrap(audioTrack.formatDescriptions.first) as! CMFormatDescription
    XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee.mChannelsPerFrame,
      outputChannels)
    XCTAssertEqual(audioTrack.timeRange.duration.seconds, duration, accuracy: 0.05)
    let audioReader = try AVAssetReader(asset: asset)
    let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
      AVFormatIDKey: Int(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false])
    audioReader.add(audioOutput)
    XCTAssertTrue(audioReader.startReading())
    var audible = false
    while try autoreleasepool(invoking: { () throws -> Bool in
      guard let sample = audioOutput.copyNextSampleBuffer() else { return false }
      let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
      let length = CMBlockBufferGetDataLength(block)
      var samples = [Int16](repeating: 0, count: length / 2)
      let status = samples.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
      }
      XCTAssertEqual(status, kCMBlockBufferNoErr)
      audible = audible || samples.contains { abs(Int($0)) > 32 }
      return true
    }) {}
    XCTAssertEqual(audioReader.status, .completed)
    XCTAssertTrue(audible, "conversion must not silently lose the sound")
    XCTAssertTrue(CompPlayer.isHDRSource(destination.path))
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    XCTAssertTrue(reader.startReading())
    var count = 0
    var previous = -1.0
    while autoreleasepool(invoking: { () -> Bool in
      guard let sample = output.copyNextSampleBuffer() else { return false }
      let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      XCTAssertGreaterThan(time, previous)
      previous = time
      if count == 0 {
        let buffer = CMSampleBufferGetImageBuffer(sample)!
        let top = hdrLuma(buffer, at: CGPoint(x: 32, y: 32))
        let bottom = hdrLuma(buffer, at: CGPoint(x: 32, y: 96))
        XCTAssertGreaterThan(max(top, bottom), 0.85)
        XCTAssertGreaterThan(abs(top - bottom), 0.3, "portrait pixels must not be stretched sideways")
      }
      count += 1
      return true
    }) {}
    XCTAssertEqual(reader.status, .completed)
    XCTAssertEqual(count, frames, "all frames must survive repeated buffer-pool recycling")
  }
  func testPickerBatchLoadsOneProviderAtATimeAndPreservesPartialSuccessOrder() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let providers = (0..<5).map { HeldImportProvider(expectation(description: "provider \($0)")) }
    let output = directory.appendingPathComponent("copies")
    let batch = FPFileImportBatch(providers: providers,
      acceptedTypeIdentifiers: ["public.movie"], destinationDirectory: output)
    let done = expectation(description: "batch complete")
    var progress: [Int] = []
    batch.start(progress: { count, total in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(total, 5)
      progress.append(Int(count))
    }, completion: { urls, errors in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertEqual(errors.count, 1)
      XCTAssertEqual(urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) },
        ["video 0", "video 2", "video 3", "video 4"])
      XCTAssertEqual(progress, [1, 2, 3, 4, 5])
      done.fulfill()
    })
    for index in providers.indices {
      wait(for: [providers[index].started], timeout: 3)
      XCTAssertTrue(providers.dropFirst(index + 1).allSatisfy { $0.startCount == 0 },
        "a serial dispatch queue must not start all async providers at once")
      if index == 1 {
        providers[index].finish(nil, error: NSError(domain: "test", code: 1))
      } else {
        let source = directory.appendingPathComponent("source\(index).mov")
        try "video \(index)".write(to: source, atomically: true, encoding: .utf8)
        providers[index].finish(source)
        // Emulate NSItemProvider removing its temporary URL on callback return.
        try FileManager.default.removeItem(at: source)
      }
    }
    wait(for: [done], timeout: 3)
  }

  func testPickerCancellationDropsQueuedProvidersAndDeletesUndeliveredCopies() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = HeldImportProvider(expectation(description: "first"))
    let second = HeldImportProvider(expectation(description: "second"))
    let never = expectation(description: "third must not start")
    never.isInverted = true
    let third = HeldImportProvider(never)
    let output = directory.appendingPathComponent("copies")
    let batch = FPFileImportBatch(providers: [first, second, third],
      acceptedTypeIdentifiers: ["public.movie"], destinationDirectory: output)
    let completion = expectation(description: "cancelled batch must not reply")
    completion.isInverted = true
    batch.start(progress: nil, completion: { _, _ in completion.fulfill() })
    wait(for: [first.started], timeout: 3)
    let source = directory.appendingPathComponent("source.mov")
    try Data([1, 2, 3]).write(to: source)
    first.finish(source)
    wait(for: [second.started], timeout: 3)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 1)
    batch.cancel()
    second.finish(source) // a late callback must not copy or advance the batch
    wait(for: [never, completion], timeout: 0.3)
    XCTAssertTrue(second.requestProgress.isCancelled)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
  }

  func testPickerInvalidBatchCompletesWithErrorsInsteadOfHanging() throws {
    let never = expectation(description: "unsupported providers never load")
    never.isInverted = true
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let batch = FPFileImportBatch(providers: [HeldImportProvider(never, supported: false)],
      acceptedTypeIdentifiers: ["public.movie"], destinationDirectory: directory)
    let done = expectation(description: "unsupported type completes")
    batch.start(progress: nil, completion: { urls, errors in
      XCTAssertTrue(urls.isEmpty)
      XCTAssertEqual(errors.count, 1)
      done.fulfill()
    })
    wait(for: [done], timeout: 3)
    wait(for: [never], timeout: 0.1)
  }

  func testImportThumbnailsRetainOnlyTheCurrentDecoder() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pool = MCFrameGeneratorPool()
    for index in 0..<5 {
      let file = directory.appendingPathComponent("\(index).mov")
      try Data([1, 2, 3]).write(to: file)
      let current = try XCTUnwrap(pool.generator(path: file.path, maxH: 200))
      XCTAssertEqual(pool.count, 1)
      XCTAssertEqual(pool.capacity, 1)
      XCTAssertTrue(current === pool.generator(path: file.path, maxH: 200))
    }
    XCTAssertEqual(pool.createdCount, 5)
    XCTAssertEqual(pool.hitCount, 5)
  }

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
    #if targetEnvironment(simulator)
    XCTAssertFalse(MCNativeScrubPlane.supported)
    XCTAssertTrue(MCNativeScrubPlane.presentationUnavailableReason?.contains("Simulator") == true)
    // Offscreen encoding remains testable below, but GPU completion cannot be
    // advertised as an onscreen receipt on this destination.
    #endif
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

  func testNativeNoOpRedrawKeepsFractionalDurationLastFrameAndInstructionBounds() throws {
    let duration = 48.38
    let last = CompPlayer.nativeFrameTarget(duration, duration: duration)
    let full = CMTimeRange(start: .zero,
      duration: CMTime(seconds: duration, preferredTimescale: 60_000))
    let redrawn = try XCTUnwrap(CompPlayer.nativeRedrawTarget(last,
      duration: duration, instruction: full))
    XCTAssertEqual(last, 48.3666666667, accuracy: 0.000001)
    XCTAssertGreaterThan(redrawn, last, "must never jump back to duration-40ms")
    XCTAssertLessThan(redrawn - last, 0.004)
    XCTAssertLessThan(redrawn, duration)
    XCTAssertEqual(floor(redrawn * 30), floor(last * 30))
    let editedAgain = try XCTUnwrap(CompPlayer.nativeRedrawTarget(last,
      duration: duration, instruction: full, avoiding: redrawn))
    XCTAssertNotEqual(editedAgain, redrawn, "a repeated style change still requests a fresh frame")
    XCTAssertGreaterThan(editedAgain, last)
    XCTAssertLessThan(editedAgain - last, 0.004)
    XCTAssertLessThan(editedAgain, duration)

    let shortInstruction = CMTimeRange(start: CMTime(seconds: 48, preferredTimescale: 60_000),
      end: CMTime(seconds: 48.367, preferredTimescale: 60_000))
    let nearBoundary = try XCTUnwrap(CompPlayer.nativeRedrawTarget(last,
      duration: duration, instruction: shortInstruction))
    XCTAssertGreaterThan(nearBoundary, last)
    XCTAssertLessThan(nearBoundary, shortInstruction.end.seconds)
    XCTAssertNil(CompPlayer.nativeRedrawTarget(duration, duration: duration, instruction: full))
    XCTAssertNil(CompPlayer.nativeRedrawTarget(47, duration: duration, instruction: shortInstruction))
    XCTAssertNil(CompPlayer.nativeRedrawTarget(.nan, duration: duration, instruction: full))
  }

  func testPendingScrubDoesNotStartOrInvalidateTheActiveStyleProducer() {
    let requests = MCNativeScrubRequests()
    var activeStyleProducer: UInt64?
    requests.onStart = { _ in activeStyleProducer = nil }
    requests.submit(seconds: 1, exact: false, toleranceMs: 0) { _ in }
    let active = requests.active!.id
    activeStyleProducer = 42 // style changes while this frame is decoding
    requests.submit(seconds: 4, exact: true, toleranceMs: 0) { _ in }
    XCTAssertEqual(activeStyleProducer, 42,
      "pending touches must leave the active frame's final style redraw alive")
    requests.complete(active, result: ["displayed": true, "actualSeconds": 1.0])
    XCTAssertNil(activeStyleProducer, "only actually starting the new target transfers ownership")
    XCTAssertEqual(requests.active?.seconds, 4)
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
      XCTAssertEqual(MCNativeScrubPlane.hdrPixelFormat, .rgba16Float)
      let (context, texture, command) = try scrubMetalResources(format: MCNativeScrubPlane.hdrPixelFormat)
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
      var words = [UInt16](repeating: 0, count: 16 * 16 * 4)
      words.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 16 * 4 * 2,
        from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
      let pixel = (8 * 16 + 8) * 4
      for channel in 0..<3 {
        let component = mcHalfToFloat(words[pixel + channel])
        XCTAssertEqual(Double(component), Double(level), accuracy: 0.015,
          "HLG encoded values must survive the display conversion without another white-point gain")
      }
      XCTAssertEqual(Double(mcHalfToFloat(words[pixel + 3])), 1, accuracy: 0.001)
    }
  }

  private func verifyNativeDrawablePresentation(hdr: Bool) throws {
    if let reason = MCNativeScrubPlane.presentationUnavailableReason { throw XCTSkip(reason) }
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
      XCTAssertEqual(host.scrubPlane.layer.pixelFormat, hdr ? .rgba16Float : .bgra8Unorm)
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
    // A fixed 30-frame H.264 fixture keeps decoder/timing tests independent of
    // simulator encoder startup. Each test owns a disposable file copy.
    let source = try XCTUnwrap(Bundle(for: RunnerTests.self)
      .url(forResource: "native-scrub", withExtension: "mp4"))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("native-scrub-\(UUID().uuidString).mp4")
    try FileManager.default.copyItem(at: source, to: url)
    return url
  }

  func testPreviewTailUsesTheActualLastSampleAndDoesNotFillRealGaps() throws {
    let url = try makeScrubVideo()
    defer { try? FileManager.default.removeItem(at: url) }
    let asset = AVURLAsset(url: url)
    let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
    let last = try XCTUnwrap(MCPreviewTail.lastSample(of: track,
      before: CMTime(seconds: 1.02, preferredTimescale: 600), after: .zero))
    XCTAssertEqual(last.start.seconds, 29.0 / 30, accuracy: 0.002)
    XCTAssertEqual(last.end.seconds, track.timeRange.end.seconds, accuracy: 0.002)
    let trimmed = try XCTUnwrap(MCPreviewTail.lastSample(of: track,
      before: CMTime(seconds: 0.5, preferredTimescale: 600), after: .zero))
    XCTAssertEqual(trimmed.start.seconds, 14.0 / 30, accuracy: 0.002)
    XCTAssertEqual(MCPreviewTail.displayEnd(0.98, projectEnd: 1), 1)
    XCTAssertEqual(MCPreviewTail.displayEnd(0.8, projectEnd: 1), 0.8)

    let player = CompPlayer(registry: ScrubTestTextureRegistry())
    defer { player.dispose() }
    XCTAssertTrue(player.build(clips: [
      ["path": url.path, "start": 0.0, "end": 1.02, "offset": 0.0, "track": 0],
      ["path": url.path, "start": 0.0, "end": 1.0, "offset": 0.0, "track": 1],
    ], texture: false))
    let composition = try XCTUnwrap(player.player.currentItem?.asset)
    let tracks = composition.tracks(withMediaType: .video)
    XCTAssertEqual(tracks.count, 2)
    for video in tracks {
      XCTAssertEqual(video.timeRange.end.seconds, 1.02, accuracy: 0.002)
      let tail = try XCTUnwrap(video.segments.last)
      XCTAssertFalse(tail.isEmpty)
      XCTAssertEqual(tail.timeMapping.source.start.seconds, 29.0 / 30, accuracy: 0.002)
    }
  }

  func testLiveClipVolumesUpdateTheCurrentItemAndPreserveOtherClipsAndFades() throws {
    let videoURL = try makeScrubVideo()
    let audioURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("volume-\(UUID().uuidString).caf")
    defer {
      try? FileManager.default.removeItem(at: videoURL)
      try? FileManager.default.removeItem(at: audioURL)
    }
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    do {
      let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
      buffer.frameLength = 48_000
      let samples = try XCTUnwrap(buffer.floatChannelData)[0]
      for i in 0..<48_000 { samples[i] = 0.1 }
      try file.write(from: buffer)
    }
    let player = CompPlayer(registry: ScrubTestTextureRegistry())
    defer { player.dispose() }
    XCTAssertTrue(player.build(clips: [["id": 4, "path": videoURL.path,
      "start": 0.0, "end": 1.0, "offset": 0.0, "track": 0]], texture: false,
      audios: [
        ["id": 1, "path": audioURL.path, "start": 0.0, "end": 0.5,
         "offset": 0.0, "volume": 0.3, "fadeIn": 0.1],
        ["id": 2, "path": audioURL.path, "start": 0.0, "end": 0.5,
         "offset": 0.5, "volume": 0.8],
        ["id": 3, "path": audioURL.path, "start": 0.0, "end": 1.0,
         "offset": 0.0, "volume": 0.6],
      ]))
    let item = try XCTUnwrap(player.player.currentItem)
    let trackIDs = try XCTUnwrap(item.audioMix).inputParameters.map(\.trackID)
    XCTAssertEqual(trackIDs.count, 2)
    func ramp(_ trackID: CMPersistentTrackID, at seconds: Double) throws -> (Float, Float) {
      let param = try XCTUnwrap(item.audioMix?.inputParameters.first { $0.trackID == trackID })
      var from: Float = -1, to: Float = -1
      var range = CMTimeRange.zero
      XCTAssertTrue(param.getVolumeRamp(for: CMTime(seconds: seconds, preferredTimescale: 600),
        startVolume: &from, endVolume: &to, timeRange: &range))
      return (from, to)
    }
    player.setClipVolumes([["id": 1, "volume": 0.0], ["id": 2, "volume": 0.0]])
    XCTAssertTrue(player.player.currentItem === item)
    XCTAssertEqual(try ramp(trackIDs[0], at: 0.25).0, 0, accuracy: 0.001)
    XCTAssertEqual(try ramp(trackIDs[0], at: 0.75).0, 0, accuracy: 0.001)
    XCTAssertEqual(try ramp(trackIDs[1], at: 0.25).0, 0.6, accuracy: 0.001)
    player.setClipVolumes([["id": 1, "volume": 0.3], ["id": 2, "volume": 0.8]])
    XCTAssertTrue(player.player.currentItem === item)
    XCTAssertEqual(try ramp(trackIDs[0], at: 0.05).0, 0, accuracy: 0.001)
    XCTAssertEqual(try ramp(trackIDs[0], at: 0.05).1, 0.3, accuracy: 0.001)
    XCTAssertEqual(try ramp(trackIDs[0], at: 0.75).0, 0.8, accuracy: 0.001)
    XCTAssertEqual(try ramp(trackIDs[1], at: 0.25).0, 0.6, accuracy: 0.001)
  }

  func testNativeExactScrubActuallyPresentsAfterClearingCacheAtTheSamePlayerTime() throws {
    if let reason = MCNativeScrubPlane.presentationUnavailableReason { throw XCTSkip(reason) }
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

  func testInteractivePrepGateThrottlesInsteadOfBlockingWhileInteractive() {
    // 互動中不再整個停住：每一格讓一小段（≈ 1 倍速）就放行，代理才轉得完
    //（實機 199：使用者一直滑，3.1 秒的代理轉了 11.4 秒、48 秒那支永遠是原檔）
    let gate = MCInteractivePrepGate()
    let cancel = AtomicFlag()
    gate.setInteractive(true)
    let t0 = CACurrentMediaTime()
    XCTAssertTrue(gate.wait(cancelled: cancel))
    let throttled = CACurrentMediaTime() - t0
    XCTAssertGreaterThanOrEqual(throttled, MCInteractivePrepGate.interactiveThrottle * 0.5)
    XCTAssertLessThan(throttled, 1)
    XCTAssertTrue(gate.isInteractive)
    // 聲音那條不讓：throttle 0 只看取消
    // 「沒讓」的上界放寬到 0.5 秒：這兩發本來就不等，量到的是排程延誤，
    // 卡的 CI 主機偶爾會超過 30ms
    let t1 = CACurrentMediaTime()
    XCTAssertTrue(gate.wait(cancelled: cancel, throttle: 0))
    XCTAssertLessThan(CACurrentMediaTime() - t1, 0.5)
    gate.setInteractive(false)
    XCTAssertGreaterThanOrEqual(gate.pausedDuration, throttled * 0.5)
    // 不在互動中：立刻放行
    let t2 = CACurrentMediaTime()
    XCTAssertTrue(gate.wait(cancelled: cancel))
    XCTAssertLessThan(CACurrentMediaTime() - t2, 0.5)
  }

  func testInteractivePrepGateResumesTheSameWaitingJobWhenInteractionEnds() {
    // 互動結束會叫醒正在讓路的那一格（不用等 throttle 走完）；同一個工作繼續，
    // 不是失敗也不是重排
    let gate = MCInteractivePrepGate()
    let cancel = AtomicFlag()
    gate.setInteractive(true)
    let completed = expectation(description: "worker resumed")
    DispatchQueue.global().async {
      XCTAssertTrue(gate.wait(cancelled: cancel, throttle: 5))
      completed.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.05)
    gate.setInteractive(false)
    wait(for: [completed], timeout: 1)
    XCTAssertGreaterThanOrEqual(gate.pausedDuration, 0)
  }

  func testInteractivePrepGateCancellationDoesNotRequireResumingPlayback() {
    let gate = MCInteractivePrepGate()
    let cancel = AtomicFlag()
    gate.setInteractive(true)
    let completed = expectation(description: "cancelled while paused")
    // 先取消再進 wait：取消不會叫醒讓路中的那一格（它讓完 30ms 才看旗標），
    // 先派工再取消的話，主執行緒被排程延誤超過 30ms 就會看到 true
    cancel.set()
    DispatchQueue.global().async {
      XCTAssertFalse(gate.wait(cancelled: cancel)); completed.fulfill()
    }
    wait(for: [completed], timeout: 1)
    XCTAssertTrue(gate.isInteractive)
  }

  func testInteractivePrepGatePausesBothTracksDuringDirectManipulation() {
    let gate = MCInteractivePrepGate()
    let cancel = AtomicFlag()
    gate.setInteractive(true, pauseDecoding: true)
    let released = AtomicFlag()
    let complete = expectation(description: "both sample workers resumed")
    complete.expectedFulfillmentCount = 2
    for throttle in [0.0, MCInteractivePrepGate.interactiveThrottle] {
      DispatchQueue.global().async {
        XCTAssertTrue(gate.wait(cancelled: cancel, throttle: throttle))
        XCTAssertTrue(released.isSet, "no samples allowed before gesture release")
        complete.fulfill()
      }
    }
    Thread.sleep(forTimeInterval: 0.12)
    released.set()
    // Still playing: resume without an intervening interactive=false.
    gate.setInteractive(true, pauseDecoding: false)
    wait(for: [complete], timeout: 2)
    XCTAssertTrue(gate.isInteractive)
  }

  func testInteractivePrepGateCancelsAnAlreadyPausedWorker() {
    let gate = MCInteractivePrepGate()
    let cancel = AtomicFlag()
    gate.setInteractive(true, pauseDecoding: true)
    let complete = expectation(description: "paused worker cancelled")
    DispatchQueue.global().async {
      XCTAssertFalse(gate.wait(cancelled: cancel))
      complete.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.12)
    cancel.set() // no resume broadcast: poll must observe cancellation
    wait(for: [complete], timeout: 2)
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

  func testReaderCancellationRejectsLateSetupAndFailure() {
    var state = MCReaderLifetime()
    let old = state.start()
    XCTAssertTrue(state.accepts(old))
    state.stop()
    XCTAssertFalse(state.accepts(old), "cancel before setup publishes must invalidate it")
    let current = state.start()
    XCTAssertFalse(state.accepts(old))
    XCTAssertFalse(state.finish(old), "late failure must not kill the new decoder")
    XCTAssertTrue(state.accepts(current))
    XCTAssertTrue(state.finish(current))
    XCTAssertFalse(state.accepts(current))
    XCTAssertFalse(state.finish(current))
  }

  func testRapidReaderRestartsOnlyAcceptNewestGeneration() {
    var state = MCReaderLifetime()
    var tokens: [Int] = []
    for _ in 0..<100 {
      state.stop()
      tokens.append(state.start())
    }
    for token in tokens.dropLast() {
      XCTAssertFalse(state.accepts(token))
      XCTAssertFalse(state.finish(token))
    }
    XCTAssertTrue(state.accepts(tokens.last!))
  }

  func testScrubbingManyClipsRetainsOnlyCurrentReadersAfterSetupGrace() {
    for time in [0.0, 4.5, 9.0, 19.0, 2.0] {
      let kept = (0..<20).filter { index in
        MCPreviewReaderWindow.keep(start: Double(index), end: Double(index + 1),
          time: time, playing: false, age: 1)
      }
      XCTAssertEqual(kept, [Int(time)])
    }
    XCTAssertTrue(MCPreviewReaderWindow.keep(start: 8, end: 9, time: 1,
      playing: false, age: 0.1), "allow setup to settle before disposal")
    XCTAssertTrue(MCPreviewReaderWindow.keep(start: 2, end: 3, time: 1,
      playing: true, age: 1), "playback keeps its existing pre-roll")
    XCTAssertFalse(MCPreviewReaderWindow.keep(start: 4, end: 5, time: 1,
      playing: true, age: 1))
  }

  func testPreviewRenderReceiptTracksCompletedFramesWithoutAddingPlaybackCallbacks() {
    let unexpected = expectation(description: "no main callback without a waiting copy")
    unexpected.isInverted = true
    let receipt = MCPreviewRenderReceipt { _, _ in unexpected.fulfill() }
    receipt.rendered(epoch: 1, time: 0.4)
    receipt.rendered(epoch: 2, time: 0.4 + 1.0 / 600.0)
    XCTAssertEqual(receipt.completedFrame?.epoch, 2)
    XCTAssertEqual(receipt.completedFrame?.time, 0.4 + 1.0 / 600.0)
    wait(for: [unexpected], timeout: 0.1)
  }

  func testPausedStyleRendersLatestThroughCopyOrOneBoundedFallback() throws {
    let url = try makeScrubVideo()
    defer { try? FileManager.default.removeItem(at: url) }
    let player = CompPlayer(registry: ScrubTestTextureRegistry())
    let layer = AVPlayerLayer(player: player.player)
    layer.frame = CGRect(x: 0, y: 0, width: 128, height: 192)
    let window = UIApplication.shared.windows.first(where: \.isKeyWindow)
    window?.layer.addSublayer(layer)
    defer {
      layer.removeFromSuperlayer(); layer.player = nil; player.dispose()
      CIExportCompositor.setLiveXform(nil)
    }
    XCTAssertTrue(player.build(clips: [["path": url.path, "start": 0.0, "end": 1.0,
      "offset": 0.0, "track": 0, "opacity": 0.99]], texture: false))
    XCTAssertTrue(player.liveCIOn)
    let item = try XCTUnwrap(player.player.currentItem)
    let positioned = expectation(description: "initial paused frame")
    player.seek(0.4, exact: true) { ok in
      XCTAssertTrue(ok); positioned.fulfill()
    }
    wait(for: [positioned], timeout: 5)
    let position = player.player.currentTime().seconds
    for _ in 0..<100 {
      CIExportCompositor.setLiveXform(nil)
      player.nudgeRedrawIfPaused()
    }
    let finalEpoch = CIExportCompositor.liveEpoch
    let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let q = player.qualitySnapshot()
      return (q["previewRenderedEpoch"] as? Int) == finalEpoch
        && abs((q["previewRenderedSeconds"] as? Double ?? -10) - position) < 1.0 / 30.0
        && (q["pausedRedrawCopyInFlight"] as? Bool) == false
        && (q["pausedRedrawCopyPending"] as? Bool) == false
        && (q["redrawInFlight"] as? Bool) == false
        && (q["redrawPending"] as? Bool) == false
    }, object: nil)
    wait(for: [rendered], timeout: 5)
    XCTAssertTrue(player.player.currentItem === item)
    let quality = player.qualitySnapshot()
    let timeouts = try XCTUnwrap(quality["pausedRedrawCopyTimeouts"] as? Int)
    // QA1966 does not promise that a paused composition copy renders within
    // 250ms on every OS/loaded simulator. Both supported production paths must
    // render the final epoch; a seek acknowledgement alone cannot pass this test.
    XCTAssertLessThanOrEqual(timeouts, 1)
    if timeouts == 0 {
      XCTAssertGreaterThan(quality["pausedRedrawRenderCompleted"] as? Int ?? 0, 0)
      XCTAssertEqual(player.player.currentTime().seconds, position, accuracy: 0.001)
      XCTAssertEqual(quality["redrawCount"] as? Int, 0, "copy path must not seek")
    } else {
      XCTAssertEqual(quality["redrawCount"] as? Int, 1, "one bounded compatibility seek")
      XCTAssertEqual(quality["redrawCallbackFailures"] as? Int, 0)
      XCTAssertEqual(player.player.currentTime().seconds, position, accuracy: 2.0 / 600.0 + 0.0001)
    }
    XCTAssertEqual(quality["pausedRedrawCopyInFlight"] as? Bool, false)
    XCTAssertEqual(quality["pausedRedrawCopyPending"] as? Bool, false)
  }

  func testFailedOverlappingFrameGrabsDetachTheirOriginalVideoOutput() {
    let player = CompPlayer(registry: ScrubTestTextureRegistry())
    defer { player.dispose() }
    // No video samples: both requests must take the timeout exit.
    let original = AVPlayerItem(asset: AVMutableComposition())
    player.player.replaceCurrentItem(with: original)
    let failed = expectation(description: "both grabs finish")
    failed.expectedFulfillmentCount = 2
    for _ in 0..<2 {
      player.grabFrame(maxH: 64) { data in
        XCTAssertNil(data); failed.fulfill()
      }
    }
    XCTAssertEqual(original.outputs.count, 1, "overlapping readers share one tap")
    let replacement = AVPlayerItem(asset: AVMutableComposition())
    let replacementOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    replacement.add(replacementOutput)
    player.player.replaceCurrentItem(with: replacement)
    wait(for: [failed], timeout: 3)
    let detached = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      original.outputs.isEmpty
    }, object: nil)
    wait(for: [detached], timeout: 2)
    XCTAssertTrue(replacement.outputs.contains { $0 === replacementOutput },
      "cleanup must not remove outputs belonging to the replacement item")
  }

  func testPreviewMemoryBudgetAllowsRecoveryProxyWithoutFootprintDeadlock() {
    let budget = MCPreviewMemoryBudget()
    XCTAssertFalse(budget.shouldDefer(usedMB: 2405, availableMB: 1500,
      physicalMB: 8000, now: 0), "the original player must not permanently starve its replacement proxy")
    XCTAssertTrue(budget.shouldDefer(usedMB: 2800, availableMB: 700,
      physicalMB: 8000, now: 1, active: true), "running work still yields before allowance exhaustion")
    XCTAssertTrue(budget.shouldDefer(usedMB: 2405, availableMB: 1600,
      physicalMB: 8000, now: 3), "headroom recovery cannot bypass cooldown")
    XCTAssertFalse(budget.shouldDefer(usedMB: 2405, availableMB: 1600,
      physicalMB: 8000, now: 7), "no impossible 1280MB footprint requirement on recovery")
    budget.notePressure(now: 9)
    XCTAssertTrue(budget.shouldDefer(usedMB: nil, availableMB: 1800,
      physicalMB: 8000, now: 20), "unknown measurement must defer")
    XCTAssertFalse(budget.shouldDefer(usedMB: 2405, availableMB: 1800,
      physicalMB: 8000, now: 26))
  }

  func testPreviewMemoryBudgetReservesMoreBeforeStartingThanWhileRunning() {
    let starting = MCPreviewMemoryBudget()
    let running = MCPreviewMemoryBudget()
    XCTAssertTrue(starting.shouldDefer(usedMB: 400, availableMB: 900,
      physicalMB: 3000, now: 0))
    XCTAssertFalse(running.shouldDefer(usedMB: 800, availableMB: 900,
      physicalMB: 3000, now: 0, active: true))
    XCTAssertTrue(running.shouldDefer(usedMB: 800, availableMB: 700,
      physicalMB: 3000, now: 1, active: true))
    XCTAssertFalse(running.shouldDefer(usedMB: 800, availableMB: 1300,
      physicalMB: 3000, now: 7))
  }

  func testPausedRedrawKeepsOneActiveFrameAndOnlyTheLatestPendingEdit() throws {
    let gate = MCPausedRedrawGate()
    gate.request(epoch: 1, time: 3)
    let first = try XCTUnwrap(gate.take())
    for epoch in 2...500 {
      gate.request(epoch: epoch, time: 3)
      XCTAssertNil(gate.take(), "no context storm while first frame is outstanding")
    }
    XCTAssertFalse(gate.complete(epoch: 0, time: 3))
    XCTAssertFalse(gate.complete(epoch: 500, time: 4), "a forward preroll is not the paused frame")
    XCTAssertEqual(gate.active?.id, first.id)
    XCTAssertTrue(gate.complete(epoch: 1, time: 3))
    let latest = try XCTUnwrap(gate.take())
    XCTAssertEqual(latest.epoch, 500)
    XCTAssertTrue(gate.complete(epoch: 500, time: 3.001))
    XCTAssertNil(gate.take())
  }

  func testPausedRedrawNewerRenderedEpochSatisfiesPendingEditWithoutExtraCopy() throws {
    let gate = MCPausedRedrawGate()
    gate.request(epoch: 1, time: 2)
    XCTAssertNotNil(gate.take())
    gate.request(epoch: 2, time: 2)
    XCTAssertTrue(gate.complete(epoch: 2, time: 2))
    XCTAssertFalse(gate.pending)
    XCTAssertNil(gate.take())
  }

  func testPausedRedrawCancellationAndOldTimeoutCannotAffectNewGesture() throws {
    let gate = MCPausedRedrawGate()
    gate.request(epoch: 1, time: 2)
    let first = try XCTUnwrap(gate.take())
    gate.cancel()
    gate.request(epoch: 3, time: 5)
    let latest = try XCTUnwrap(gate.take())
    XCTAssertFalse(gate.timeout(first.id))
    XCTAssertFalse(gate.complete(epoch: 1, time: 2))
    XCTAssertEqual(gate.active?.id, latest.id)
    XCTAssertTrue(gate.timeout(latest.id))
    XCTAssertNil(gate.active)
    XCTAssertFalse(gate.pending)
    gate.request(epoch: 4, time: .nan)
    XCTAssertNil(gate.take())
  }

  func testPausedCompositionCopyPreservesHDRPlanAndReceipt() throws {
    let original = AVMutableVideoComposition()
    original.renderSize = CGSize(width: 900, height: 1600)
    original.frameDuration = CMTime(value: 1, timescale: 30)
    original.colorPrimaries = AVVideoColorPrimaries_ITU_R_2020
    original.colorTransferFunction = AVVideoTransferFunction_ITU_R_2100_HLG
    original.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_2020
    original.customVideoCompositorClass = CIPreviewCompositorHDR.self
    let instruction = CIExportInstruction(timeRange: scrubRange,
      layers: [], mosaics: [], overlays: [])
    let receipt = MCPreviewRenderReceipt { _, _ in }
    instruction.renderReceipt = receipt
    original.instructions = [instruction]
    let copy = try XCTUnwrap(original.mutableCopy() as? AVMutableVideoComposition)
    XCTAssertFalse(copy === original)
    XCTAssertEqual(copy.renderSize, original.renderSize)
    XCTAssertEqual(copy.frameDuration, original.frameDuration)
    XCTAssertEqual(copy.colorPrimaries, original.colorPrimaries)
    XCTAssertEqual(copy.colorTransferFunction, original.colorTransferFunction)
    XCTAssertEqual(copy.colorYCbCrMatrix, original.colorYCbCrMatrix)
    let compositorClass = try XCTUnwrap(copy.customVideoCompositorClass)
    XCTAssertEqual(ObjectIdentifier(compositorClass), ObjectIdentifier(CIPreviewCompositorHDR.self))
    let copiedInstruction = try XCTUnwrap(copy.instructions.first as? CIExportInstruction)
    XCTAssertTrue(copiedInstruction.renderReceipt === receipt)
  }

  func testIdleFrameGeneratorReleaseDoesNotEvictAResumedGesture() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    try Data([1, 2, 3]).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let pool = MCFrameGeneratorPool()
    XCTAssertNotNil(pool.generator(path: url.path, maxH: 200))
    let idleToken = pool.activity
    XCTAssertNotNil(pool.generator(path: url.path, maxH: 200))
    XCTAssertFalse(pool.removeIfIdle(since: idleToken))
    XCTAssertEqual(pool.count, 1)
    XCTAssertTrue(pool.removeIfIdle(since: pool.activity))
    XCTAssertEqual(pool.count, 0)
    XCTAssertEqual(pool.idleReleases, 1)
    XCTAssertNotNil(pool.generator(path: url.path, maxH: 200))
    XCTAssertEqual(pool.createdCount, 2)
  }

  func testPrepCancellationReasonIsStableAcrossDuplicateStops() {
    let state = MCPrepStopState()
    XCTAssertNil(state.reason)
    XCTAssertFalse(state.cancelled.isSet)
    XCTAssertTrue(state.request("memory deferred"))
    XCTAssertTrue(state.cancelled.isSet)
    XCTAssertFalse(state.request("timeout"))
    XCTAssertEqual(state.reason, "memory deferred")
  }

  func testHiddenPreviewSourcesAreRemovedBeforeOcclusionAndDecoderDemand() {
    let canvas = CGSize(width: 100, height: 100)
    let layers = (1...4).map { visibilityLayer(id: Int32($0)) }
    let state = MCPreviewVisibilityState()
    XCTAssertTrue(state.setHiddenTracks([3, 4]))
    XCTAssertFalse(state.setHiddenTracks([4, 3]), "same set must not replace VC again")
    XCTAssertTrue(state.enabled, "hiding must not permanently disable occlusion")
    let visible = MCPreviewVisibility.visibleLayers(layers, canvas: canvas,
      enabled: state.enabled, hiddenTracks: state.hiddenTracks)
    XCTAssertEqual(visible.map { $0.trackID }, [2], "hidden upper cover cannot hide lower source")
    let instruction = CIExportInstruction(
      timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10,
        preferredTimescale: 600)), layers: visible, mosaics: [], overlays: [])
    XCTAssertEqual(instruction.requiredSourceTrackIDs?.count, 1)
    XCTAssertEqual((instruction.requiredSourceTrackIDs?.first as? NSNumber)?.int32Value, 2)

    XCTAssertTrue(state.beginEditing())
    XCTAssertEqual(MCPreviewVisibility.visibleLayers(layers, canvas: canvas,
      enabled: state.enabled, hiddenTracks: state.hiddenTracks).map { $0.trackID }, [1, 2],
      "live transforms restore covered sources, never explicitly hidden ones")
    XCTAssertTrue(state.setHiddenTracks([]))
    XCTAssertEqual(MCPreviewVisibility.visibleLayers(layers, canvas: canvas,
      enabled: state.enabled, hiddenTracks: state.hiddenTracks).map { $0.trackID }, [1, 2, 3, 4])
  }

  func testHiddenPreviewStillsAndAllHiddenLayersDoNotBecomeOpaqueCovers() {
    let canvas = CGSize(width: 100, height: 100)
    let still = CILayerSpec(trackID: kCMPersistentTrackID_Invalid,
      still: CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)),
      transform: .identity, srcHeight: 100, start: 0, end: 10,
      fadeIn: 0, fadeOut: 0, colorMatrix: nil, z: 8)
    let layers = [visibilityLayer(id: 1), still]
    XCTAssertEqual(MCPreviewVisibility.visibleLayers(layers, canvas: canvas,
      enabled: true, hiddenTracks: [8]).map { $0.z }, [1])
    XCTAssertTrue(MCPreviewVisibility.visibleLayers(layers, canvas: canvas,
      enabled: false, hiddenTracks: [1, 8]).isEmpty)
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

  func testScrubToleranceStaysInsideTheInstructionContainingTheTarget() {
    func instruction(_ start: Double, _ end: Double) -> AVMutableVideoCompositionInstruction {
      let i = AVMutableVideoCompositionInstruction()
      i.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
      return i
    }
    let instructions: [AVVideoCompositionInstructionProtocol] = [
      instruction(0, 1.2), instruction(1.2, 2.47), instruction(2.47, 48.38),
    ]
    // 段落中間：吃滿上限（原檔拖動關鍵幀貼齊）
    XCTAssertEqual(MCSeekCompletionState.clampedScrubToleranceMs(
      500, target: 20, instructions: instructions), 500)
    // 離下一個接縫 0.3 秒：尾端留一個合成刻度（1/600），窗縮到 298，
    // 窗的邊絕不壓在隔壁片段的起點上
    XCTAssertEqual(MCSeekCompletionState.clampedScrubToleranceMs(
      500, target: 0.9, instructions: instructions), 298)
    // 離上一個接縫 0.3 秒：起點側不留邊（落在 start 就是這一段的第一格）
    XCTAssertEqual(MCSeekCompletionState.clampedScrubToleranceMs(
      500, target: 1.5, instructions: instructions), 300)
    // 窗的上緣嚴格在段內：閉區間的邊碰到 end 就會被吸到隔壁段的起點
    let nearEnd = MCSeekCompletionState.clampedScrubToleranceMs(
      500, target: 2.0, instructions: instructions)
    XCTAssertEqual(nearEnd, 468)
    XCTAssertLessThan(2.0 + Double(nearEnd) / 1000, 2.47)
    // 段落起點：0（起點本來就是同步點，精準 seek 一樣便宜）
    XCTAssertEqual(MCSeekCompletionState.clampedScrubToleranceMs(
      500, target: 1.2, instructions: instructions), 0)
    // 上限、負值、沒有 videoComposition、壞 target：只套上限
    XCTAssertEqual(MCSeekCompletionState.clampedScrubToleranceMs(
      5000, target: 20, instructions: instructions), MCSeekCompletionState.scrubToleranceCapMs)
    XCTAssertEqual(MCSeekCompletionState.clampedScrubToleranceMs(
      -1, target: 20, instructions: instructions), 0)
    XCTAssertEqual(MCSeekCompletionState.clampedScrubToleranceMs(
      500, target: 20, instructions: nil), 500)
    XCTAssertEqual(MCSeekCompletionState.clampedScrubToleranceMs(
      500, target: .nan, instructions: instructions), 500)
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

  /// x420（10-bit bi-planar）測試緩衝：Y 平面照 [luma] 給值、CbCr 給常數。
  /// 逐位元組小端寫入，跟 comparePlanes10 的讀法對齊
  private func makeTenBitBuffer(
    width: Int, height: Int, luma: (Int) -> Int, chroma: Int
  ) throws -> CVPixelBuffer {
    var optional: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height,
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:],
       kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &optional)
    XCTAssertEqual(status, kCVReturnSuccess)
    let buffer = try XCTUnwrap(optional)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<2 {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
        .assumingMemoryBound(to: UInt8.self)
      let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, plane)
      let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, plane)
      let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      let comps = plane == 0 ? 1 : 2
      for y in 0..<planeHeight {
        for x in 0..<planeWidth {
          for c in 0..<comps {
            let value = plane == 0 ? luma(x) : chroma
            let i = y * rowBytes + (x * comps + c) * 2
            base[i] = UInt8(value & 0xFF)
            base[i + 1] = UInt8((value >> 8) & 0xFF)
          }
        }
      }
    }
    return buffer
  }

  /// HDR 直拷的判準（見 CIExportCompositor.probeHDRFast）：同一張畫面的
  /// 兩種算法差幾個碼值要判通過，黑畫面要判不過，而「基準本身是平的」
  /// 那一格不能拿來當證據
  func testComparePlanes10SeparatesRoundTripNoiseFromABlackFrame() throws {
    let ramp: (Int) -> Int = { ($0 * 16) << 6 }
    let neutral = 512 << 6
    let reference = try makeTenBitBuffer(
      width: 64, height: 64, luma: ramp, chroma: neutral)
    let copy = try makeTenBitBuffer(
      width: 64, height: 64, luma: ramp, chroma: neutral)
    let identical = try XCTUnwrap(
      CIExportCompositor.comparePlanes10(copy, reference))
    XCTAssertEqual(identical.meanY, 0, accuracy: 0.001)
    XCTAssertEqual(identical.meanC, 0, accuracy: 0.001)
    // 取樣是每 4 行一點，所以最大值落在 x=60（不是 x=63）
    XCTAssertEqual(identical.peak, 61440)
    // 樣本靠左裝：刻度 65535，動態要有滿刻度的 1/8 才算得了數
    XCTAssertGreaterThan(identical.spread, 65535 / 8)
    XCTAssertLessThanOrEqual(identical.meanY, Double(identical.spread) / 16)

    // 幾個碼值的來回誤差（CI 那趟 YUV→RGB→YUV）：照樣要通過
    let noisy = try makeTenBitBuffer(
      width: 64, height: 64, luma: { ramp($0) + 192 }, chroma: neutral + 192)
    let jitter = try XCTUnwrap(
      CIExportCompositor.comparePlanes10(noisy, reference))
    XCTAssertLessThanOrEqual(jitter.meanY, Double(jitter.spread) / 16)
    XCTAssertLessThanOrEqual(jitter.meanC, Double(jitter.spread) / 16)

    // 直拷吐黑畫面（實機 144 的形狀）：平均差遠大於門檻，判不過
    let black = try makeTenBitBuffer(
      width: 64, height: 64, luma: { _ in 0 }, chroma: 0)
    let caught = try XCTUnwrap(
      CIExportCompositor.comparePlanes10(black, reference))
    XCTAssertGreaterThan(caught.spread, 65535 / 8)
    XCTAssertGreaterThan(caught.meanY, Double(caught.spread) / 16)

    // 基準自己是平的（全黑）：動態範圍不夠，這一格不算數，換下一格再驗。
    // 全黑的 peak 是 0，刻度推成 1023，門檻是 127
    let flat = try XCTUnwrap(CIExportCompositor.comparePlanes10(reference, black))
    XCTAssertEqual(flat.peak, 0)
    XCTAssertLessThan(flat.spread, 1023 / 8)

    // 格式不同不比
    var bgra: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &bgra),
      kCVReturnSuccess)
    XCTAssertNil(
      CIExportCompositor.comparePlanes10(try XCTUnwrap(bgra), reference))
  }

}
