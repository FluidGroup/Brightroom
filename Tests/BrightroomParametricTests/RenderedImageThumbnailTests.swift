//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Testing

// Public API only: this file previews a result the way a host does, through
// `ExportRenderer` and `RenderedImage`, with no package symbols.
import BrightroomParametric

/// Pins `RenderedImage.thumbnail(maxPixelSize:)`: an in-memory result larger
/// than the cap comes back downsampled to it, on the whole-pixel grid
/// `ExportRenderer.Resolution.resize` uses and in the result's own format and
/// color space; one within the cap comes back itself; a file result still
/// decodes a thumbnail.
struct RenderedImageThumbnailTests {

  @Test(arguments: [
    ThumbnailCase(width: 1000, height: 750, maxPixelSize: 200, expectedWidth: 200, expectedHeight: 150),
    ThumbnailCase(width: 750, height: 1000, maxPixelSize: 200, expectedWidth: 150, expectedHeight: 200),
    // 794 × 281 / 1123 = 198.67 rounds up to 199, as `.resize` rounds.
    ThumbnailCase(width: 1123, height: 794, maxPixelSize: 281, expectedWidth: 281, expectedHeight: 199),
    ThumbnailCase(width: 777, height: 333, maxPixelSize: 101, expectedWidth: 101, expectedHeight: 43),
  ])
  func `a memory result larger than the cap thumbnails to whole pixels`(
    thumbnail: ThumbnailCase
  ) throws {
    let rendered = try ExportRenderer().render(
      from: Self.makeOpaqueNoise(width: thumbnail.width, height: thumbnail.height),
      feature: EmptyFeature()
    )

    let image = try rendered.thumbnail(maxPixelSize: thumbnail.maxPixelSize)

    #expect(image.width == thumbnail.expectedWidth)
    #expect(image.height == thumbnail.expectedHeight)
    #expect(image.bitsPerComponent == 8)
  }

  /// The cap is inclusive: a result whose longer side is `maxPixelSize` is
  /// within it.
  @Test(arguments: [320, 1000] as [CGFloat])
  func `a memory result within the cap is returned itself`(maxPixelSize: CGFloat) throws {
    let rendered = try ExportRenderer().render(
      from: Self.makeOpaqueNoise(width: 320, height: 240),
      feature: EmptyFeature()
    )
    let full = try rendered.cgImage

    let image = try rendered.thumbnail(maxPixelSize: maxPixelSize)

    #expect(image === full)
    #expect(image.width == 320)
    #expect(image.height == 240)
  }

  @Test(arguments: [
    DepthCase(colorSpaceName: CGColorSpace.displayP3 as String, format: .BGRA8, bitsPerComponent: 8),
    DepthCase(colorSpaceName: CGColorSpace.displayP3 as String, format: .RGBA16, bitsPerComponent: 16),
    DepthCase(colorSpaceName: CGColorSpace.adobeRGB1998 as String, format: .RGBAh, bitsPerComponent: 16),
    // A luminance result: gray pixels tagged with a gray space.
    DepthCase(colorSpaceName: CGColorSpace.genericGrayGamma2_2 as String, format: .L8, bitsPerComponent: 8),
    DepthCase(colorSpaceName: CGColorSpace.genericGrayGamma2_2 as String, format: .L16, bitsPerComponent: 16),
  ])
  func `a memory thumbnail keeps the result's color space and depth`(depth: DepthCase) throws {
    let colorSpace = try #require(CGColorSpace(name: depth.colorSpaceName as CFString))
    let rendered = try ExportRenderer().render(
      from: Self.makeFlatColor(width: 800, height: 600),
      feature: EmptyFeature(),
      options: .init(outputFormat: depth.format, outputColorSpace: colorSpace)
    )

    let image = try rendered.thumbnail(maxPixelSize: 200)

    #expect(image.colorSpace?.name as String? == depth.colorSpaceName)
    #expect(image.bitsPerComponent == depth.bitsPerComponent)
    // The same color as the full result, not its pixels re-read in another
    // space.
    let thumbnailPixel = try Self.centerPixelInSRGB(image)
    let fullPixel = try Self.centerPixelInSRGB(try rendered.cgImage)
    #expect(
      zip(thumbnailPixel, fullPixel).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
      "thumbnail \(thumbnailPixel), full \(fullPixel)"
    )
  }

  /// The thumbnail is the same Lanczos resample onto the same whole-pixel
  /// grid as `Resolution.resize`, so a host previews what a resized export
  /// delivers. Compared at float precision in a linear space, so only the
  /// resample itself can differ.
  @Test func `a memory thumbnail scales as a resized render does`() throws {
    let source = Self.makeOpaqueNoise(width: 1000, height: 750)
    let linearSRGB = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))

    let thumbnail = try ExportRenderer().render(
      from: source,
      feature: EmptyFeature(),
      options: .init(outputFormat: .RGBAf, outputColorSpace: linearSRGB)
    ).thumbnail(maxPixelSize: 200)
    let resized = try ExportRenderer().render(
      from: source,
      feature: EmptyFeature(),
      options: .init(
        resolution: .resize(maxPixelSize: 200),
        outputFormat: .RGBAf,
        outputColorSpace: linearSRGB
      )
    ).cgImage

    #expect(thumbnail.width == resized.width)
    #expect(thumbnail.height == resized.height)
    let largestDifference = zip(
      try Self.rgbaFloatPixels(of: thumbnail),
      try Self.rgbaFloatPixels(of: resized)
    )
    .map { abs($0 - $1) }
    .max() ?? 0
    #expect(largestDifference < 0.01, "thumbnail and resized render differ by \(largestDifference)")
  }

  @Test func `a file result decodes a thumbnail`() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rendered-image-thumbnail-tests-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }

    let rendered = try ExportRenderer().render(
      from: Self.makeOpaqueNoise(width: 1000, height: 750),
      feature: EmptyFeature(),
      options: .init(output: .file(url: url, fileType: .png))
    )

    let image = try rendered.thumbnail(maxPixelSize: 200)

    #expect(image.width == 200)
    #expect(abs(image.height - 150) <= 1)
  }

  // MARK: - Fixtures

  struct ThumbnailCase: Sendable, CustomTestStringConvertible {
    var width: CGFloat
    var height: CGFloat
    var maxPixelSize: CGFloat
    var expectedWidth: Int
    var expectedHeight: Int

    var testDescription: String {
      "\(Int(width))×\(Int(height)) → \(Int(maxPixelSize))"
    }
  }

  struct DepthCase: Sendable, CustomTestStringConvertible {
    var colorSpaceName: String
    var format: CIFormat
    var bitsPerComponent: Int

    var testDescription: String {
      "\(colorSpaceName), \(format.rawValue)"
    }
  }

  /// Opaque, full-contrast noise that reaches every edge.
  private static func makeOpaqueNoise(width: CGFloat, height: CGFloat) -> CIImage {
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    return CIFilter.randomGenerator().outputImage!
      .settingAlphaOne(in: extent)
      .cropped(to: extent)
  }

  /// One saturated color, whose encoding differs between RGB spaces.
  private static func makeFlatColor(width: CGFloat, height: CGFloat) -> CIImage {
    CIImage(color: CIColor(red: 0.9, green: 0.2, blue: 0.1))
      .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
  }

  /// The center pixel of `image` drawn into an 8-bit sRGB bitmap, so images
  /// tagged with different spaces compare by the colors they mean.
  private static func centerPixelInSRGB(_ image: CGImage) throws -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try #require(
      CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    )
    let center = CGRect(
      x: -CGFloat(image.width / 2),
      y: -CGFloat(image.height / 2),
      width: CGFloat(image.width),
      height: CGFloat(image.height)
    )
    context.draw(image, in: center)
    return pixel
  }

  /// The image's own RGBA float components, first row at the top.
  private static func rgbaFloatPixels(of image: CGImage) throws -> [Float] {
    #expect(image.bitsPerComponent == 32)
    #expect(image.bitsPerPixel == 128)
    let data = try #require(image.dataProvider?.data) as Data
    var pixels = [Float](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeBytes { bytes in
      for y in 0..<image.height {
        for x in 0..<(image.width * 4) {
          pixels[y * image.width * 4 + x] = bytes.loadUnaligned(
            fromByteOffset: y * image.bytesPerRow + x * 4,
            as: Float.self
          )
        }
      }
    }
    return pixels
  }
}
