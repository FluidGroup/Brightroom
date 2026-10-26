//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreGraphics
import CoreImage
import Foundation
import Testing

// Public API only: this file exports the way a host does, through
// `ExportRenderer`, with no editor or package symbols.
import BrightroomParametric

/// Exports a local blur whose brush mask holds thousands of stamps.
///
/// A mask drawn as one Core Image node per stamp grew until Core Image could
/// no longer fuse the graph into a working Metal function, and the export came
/// back correctly sized with every RGBA component zero and no error.
@Suite(.serialized)
struct DenseBrushMaskExportTests {

  /// The source orientation, the straightening, the exposure, and the crop
  /// stay in the same graph as the mask: exporting the mask in isolation
  /// misses the shader fusion that failed.
  private struct DenseEdit: Feature, Equatable {
    var localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?

    var body: some Feature {
      ExposureFeature(ev: 0.52238805970149227)
      localBlur
      CropFeature(
        rect: CGRect(x: 947, y: 0, width: 2138, height: 3024),
        straightenRadians: -.pi
      )
    }
  }

  @Test(arguments: [1200, 300])
  func `a dense brush mask keeps the export opaque and unpainted pixels unchanged`(
    maxPixelSize: Int
  ) throws {
    let source = try Self.makeSourceImage()
    let options = ExportRenderer.Options(
      resolution: .resize(maxPixelSize: CGFloat(maxPixelSize))
    )

    let baselineImage = try ExportRenderer().render(
      from: source,
      feature: DenseEdit(localBlur: nil),
      options: options
    ).cgImage
    let maskedImage = try ExportRenderer().render(
      from: source,
      feature: DenseEdit(
        localBlur: LocalAdjustmentFeature(
          mask: .brush(BrushMask(strokes: Self.makeDenseStrokes()))
        ) {
          GaussianBlurFeature(radius: .proportional(40))
        }
      ),
      options: options
    ).cgImage
    let baselinePixels = try Self.rgbaPixels(of: baselineImage)
    let maskedPixels = try Self.rgbaPixels(of: maskedImage)

    #expect(maskedImage.width == baselineImage.width)
    #expect(maskedImage.height == maxPixelSize)
    #expect(maskedImage.height == baselineImage.height)

    // Ignore the Lanczos boundary. The failure returned every RGBA component
    // zero, without an error.
    var opaquePixelCount = 0
    var interiorPixelCount = 0
    for y in 2..<(maskedImage.height - 2) {
      for x in 2..<(maskedImage.width - 2) {
        if maskedPixels[(y * maskedImage.width + x) * 4 + 3] >= 250 {
          opaquePixelCount += 1
        }
        interiorPixelCount += 1
      }
    }
    #expect(
      Double(opaquePixelCount) / Double(interiorPixelCount) > 0.99,
      "Dense-mask export must remain opaque at \(maxPixelSize) pixels."
    )

    // Sample the painted region across many checkerboard cells, so skipping
    // the local adjustment cannot pass, whatever the checkerboard phase.
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
    #expect(
      Double(changedPixelCount) / Double(paintedRegionPixelCount) > 0.01,
      "The painted region must still be blurred at \(maxPixelSize) pixels."
    )

    // This checkerboard sample is outside every stroke, far from the mask's
    // soft edge. It also rejects a fully blurred but opaque export.
    let sampleOffset = (maskedImage.height / 6 * maskedImage.width + maskedImage.width / 4) * 4
    #expect(
      Array(maskedPixels[sampleOffset..<sampleOffset + 4])
        == Array(baselinePixels[sampleOffset..<sampleOffset + 4]),
      "Unpainted pixels must be unchanged at \(maxPixelSize) pixels."
    )
  }

  /// Distinct positions keep Core Image from collapsing repeated identical
  /// stamps; the eight strokes hold 5,356 stamps in a small part of the crop.
  /// Centers are Core Image working-space coordinates of the 4032 × 3024
  /// oriented source.
  private static func makeDenseStrokes() -> [BrushMask.Stroke] {
    [781, 217, 201, 28, 3888, 100, 61, 80].enumerated().map { strokeIndex, count in
      BrushMask.Stroke(
        stampCenters: (0..<count).map { index in
          CGPoint(
            x: 1600 + sin(Double(index) / 150) * 400 + Double(strokeIndex) * 5,
            y: 1200 + Double(index % 200) * 3.8 + Double(strokeIndex) * 0.3
          )
        },
        brush: BrushMask.Brush(diameter: 75.694915254, hardness: 0.72, opacity: 1)
      )
    }
  }

  /// Sharp, asymmetric content exposes unwanted blur without a photo fixture.
  /// The source is turned upside down, as a photo with `.down` EXIF
  /// orientation reaches the renderer.
  private static func makeSourceImage() throws -> CIImage {
    let width = 4032
    let height = 3024
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 0.75, green: 0.35, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 1500, y: 1000, width: 1000, height: 1000))
    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    for x in stride(from: 0, to: width, by: 40) {
      for y in stride(from: 0, to: height, by: 40) where (x / 40 + y / 40).isMultiple(of: 2) {
        context.fill(CGRect(x: x, y: y, width: 40, height: 40))
      }
    }
    let image = try #require(context.makeImage())
    let oriented = CIImage(cgImage: image).oriented(.down)
    // Move the oriented image to a zero origin, as a decoded source arrives.
    return oriented.transformed(
      by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY)
    )
  }

  /// Normalizes export buffers so the assertions do not depend on byte order
  /// or row padding.
  private static func rgbaPixels(of image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
      let context = try #require(CGContext(
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
