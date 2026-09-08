import Flutter
import UIKit
import XCTest
import CoreImage
import ImageIO
@testable import Runner

class RunnerTests: XCTestCase {

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
