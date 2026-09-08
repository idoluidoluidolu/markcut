import Flutter
import UIKit
import XCTest
import CoreImage
import ImageIO
import AVFoundation
@testable import Runner

class RunnerTests: XCTestCase {

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
