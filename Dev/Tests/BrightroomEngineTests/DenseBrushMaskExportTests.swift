import BrightroomEngine
import BrightroomParametric
import UIKit
import XCTest

/// Exercises dense brush-mask export without a live canvas or app-specific types.
final class DenseBrushMaskExportTests: XCTestCase {

  @MainActor
  func testDenseBrushMaskPreservesOpacityAndUnpaintedDetail() async throws {
    let stack = EditingStack(imageProvider: ImageProvider(image: try makeSourceImage()))
    let prepared = expectation(description: "The procedural source is ready for editing")
    stack.start { prepared.fulfill() }
    let preparation = await XCTWaiter.fulfillment(of: [prepared], timeout: 10)
    XCTAssertEqual(preparation, .completed)
    _ = try XCTUnwrap(stack.loadedState)

    // Keep source orientation, straightening, exposure, and crop in the same
    // graph as the mask: exporting the mask in isolation misses shader fusion.
    XCTAssertTrue(stack.updateFeature(id: EditingFeatureTree.finalCropNodeID) { feature in
      feature = .domain(CropFeature(
        id: EditingFeatureTree.finalCropNodeID,
        cropRect: CGRect(x: 947, y: 0, width: 2138, height: 3024),
        rotation: .zero,
        straightenRadians: -.pi
      ))
    })
    stack.loadedState?.currentEdit.effects = EffectPipeline(effects: [
      ExposureFeature(value: 0.52238805970149227),
    ])
    let baselineEdit = try XCTUnwrap(stack.loadedState?.currentEdit)
    var maskedEdit = baselineEdit
    let adjustment = LocalAdjustmentFeature(
      maskTree: MaskTree(root: .brush(BrushMask(strokes: makeDenseStrokes()))),
      effectPipeline: EffectPipeline(effects: [GaussianBlurFeature(value: 40)])
    )
    EditingFeatureTree.replaceLocalAdjustments(
      [adjustment], in: &maskedEdit, insertingBefore: EditingFeatureTree.finalCropNodeID
    )

    for maxPixelSize in [1200, 300] {
      let options = BrightRoomImageRenderer.Options(
        resolution: .resize(maxPixelSize: CGFloat(maxPixelSize))
      )
      stack.loadedState?.currentEdit = baselineEdit
      let baselineResult = try await stack.makeRenderer().render(options: options)
      let baselineImage = try baselineResult.cgImage
      let baselinePixels = try rgbaPixels(of: baselineImage)

      stack.loadedState?.currentEdit = maskedEdit
      let maskedResult = try await stack.makeRenderer().render(options: options)
      let maskedImage = try maskedResult.cgImage
      let maskedPixels = try rgbaPixels(of: maskedImage)
      XCTAssertEqual(maskedImage.width, baselineImage.width)
      XCTAssertEqual(maskedImage.height, maxPixelSize)
      XCTAssertEqual(maskedImage.height, baselineImage.height)

      // Ignore the Lanczos boundary; dense kernel fusion previously returned a
      // correctly sized image with every RGBA component zero and no thrown error.
      var opaquePixelCount = 0
      var interiorPixelCount = 0
      for y in 2..<(maskedImage.height - 2) {
        for x in 2..<(maskedImage.width - 2) {
          let alpha = maskedPixels[(y * maskedImage.width + x) * 4 + 3]
          if alpha >= 250 {
            opaquePixelCount += 1
          }
          interiorPixelCount += 1
        }
      }
      XCTAssertGreaterThan(
        Double(opaquePixelCount) / Double(interiorPixelCount),
        0.99,
        "Dense-mask export must remain opaque at \(maxPixelSize) pixels."
      )

      // Sample the painted region across many checkerboard cells so skipping
      // the local adjustment cannot pass, regardless of checkerboard phase.
      var changedPixelCount = 0
      var paintedRegionPixelCount = 0
      for y in (maskedImage.height * 40 / 100)..<(maskedImage.height * 60 / 100) {
        for x in (maskedImage.width * 55 / 100)..<(maskedImage.width * 85 / 100) {
          let offset = (y * maskedImage.width + x) * 4
          let rgbDelta = (0..<3).map { channel in
            abs(Int(maskedPixels[offset + channel]) - Int(baselinePixels[offset + channel]))
          }.max()!
          if rgbDelta > 8 {
            changedPixelCount += 1
          }
          paintedRegionPixelCount += 1
        }
      }
      XCTAssertGreaterThan(
        Double(changedPixelCount) / Double(paintedRegionPixelCount),
        0.01,
        "The painted region must still be blurred at \(maxPixelSize) pixels."
      )

      // This checkerboard sample is outside every stroke, far from the mask's
      // soft edge. It also rejects a fully blurred but opaque export.
      let sampleOffset = (maskedImage.height / 6 * maskedImage.width + maskedImage.width / 4) * 4
      XCTAssertEqual(
        Array(maskedPixels[sampleOffset..<sampleOffset + 4]),
        Array(baselinePixels[sampleOffset..<sampleOffset + 4]),
        "Unpainted pixels must be unchanged at \(maxPixelSize) pixels."
      )
    }
  }

  /// Distinct positions prevent Core Image from collapsing repeated identical
  /// stamps; the eight strokes contain 5,356 stamps in a small part of the crop.
  private func makeDenseStrokes() -> [BrushMaskStroke] {
    [781, 217, 201, 28, 3888, 100, 61, 80].enumerated().map { strokeIndex, count in
      BrushMaskStroke(
        stamps: (0..<count).map { index in
          CGPoint(
            x: 1600 + sin(Double(index) / 150) * 400 + Double(strokeIndex) * 5,
            y: 1200 + Double(index % 200) * 3.8 + Double(strokeIndex) * 0.3
          )
        },
        brush: BrushMaskBrush(diameter: 75.694915254, hardness: 0.72, opacity: 1)
      )
    }
  }

  /// Sharp, asymmetric content exposes unwanted blur without any photo fixture.
  @MainActor
  private func makeSourceImage() throws -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(width: 4032, height: 3024)
    let rawImage = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor(red: 0.75, green: 0.35, blue: 0.2, alpha: 1).setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIColor.blue.setFill()
      context.fill(CGRect(x: 1500, y: 1000, width: 1000, height: 1000))
      UIColor.black.setFill()
      for x in stride(from: 0, to: 4032, by: 40) {
        for y in stride(from: 0, to: 3024, by: 40) where (x / 40 + y / 40).isMultiple(of: 2) {
          context.fill(CGRect(x: x, y: y, width: 40, height: 40))
        }
      }
    }
    return UIImage(cgImage: try XCTUnwrap(rawImage.cgImage), scale: 1, orientation: .down)
  }

  /// Normalizes export buffers so assertions do not depend on their byte order or padding.
  private func rgbaPixels(of image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
      let context = try XCTUnwrap(CGContext(
        data: buffer.baseAddress,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
      ))
      context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
      )
    }
    return pixels
  }
}
