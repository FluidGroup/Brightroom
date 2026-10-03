//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Testing

// Public API only: this file exports the way a host does, through
// `ExportRenderer`, with no package symbols.
import BrightroomParametric

/// Pins `ExportRenderer.Resolution.resize` as a whole-pixel resample: the
/// output size is decided first, and the whole image is resampled onto
/// exactly that grid, with no partial last row or column and no transparent
/// frame around an opaque image.
struct ExportRendererResizeTests {

  @Test(arguments: [
    // 398.67 rounds up to 399: the rounded-up column used to be about half
    // transparent.
    ResizeCase(width: 3984, height: 5976, maxPixelSize: 598, expectedWidth: 399, expectedHeight: 598),
    ResizeCase(width: 1123, height: 794, maxPixelSize: 281, expectedWidth: 281, expectedHeight: 199),
    ResizeCase(width: 777, height: 333, maxPixelSize: 101, expectedWidth: 101, expectedHeight: 43),
    ResizeCase(width: 1000, height: 750, maxPixelSize: 77, expectedWidth: 77, expectedHeight: 58),
    // Already whole on both sides.
    ResizeCase(width: 1000, height: 750, maxPixelSize: 200, expectedWidth: 200, expectedHeight: 150),
  ])
  func `an opaque image resizes to whole pixels and stays opaque to its edges`(
    resize: ResizeCase
  ) throws {
    let source = Self.makeOpaqueNoise(width: resize.width, height: resize.height)

    let image = try ExportRenderer().render(
      from: source,
      feature: EmptyFeature(),
      options: .init(resolution: .resize(maxPixelSize: resize.maxPixelSize))
    ).cgImage

    #expect(image.width == resize.expectedWidth)
    #expect(image.height == resize.expectedHeight)
    let pixels = try Self.rgba8Pixels(of: image)
    #expect(Self.translucentPixelCount(in: pixels) == 0)
  }

  @Test(arguments: [
    ThinCrop(height: 6, maxPixelSize: 256, expectedWidth: 256),
    ThinCrop(height: 10, maxPixelSize: 256, expectedWidth: 256),
    ThinCrop(height: 1, maxPixelSize: 1000, expectedWidth: 1000),
  ])
  func `a thin crop resizes to at least one opaque row`(crop: ThinCrop) throws {
    let source = Self.makeOpaqueNoise(width: 4000, height: 3000)

    let image = try ExportRenderer().render(
      from: source,
      feature: CropFeature(rect: CGRect(x: 0, y: 1000, width: 4000, height: crop.height)),
      options: .init(resolution: .resize(maxPixelSize: crop.maxPixelSize))
    ).cgImage

    #expect(image.width == crop.expectedWidth)
    #expect(image.height == 1)
    let pixels = try Self.rgba8Pixels(of: image)
    #expect(Self.translucentPixelCount(in: pixels) == 0)
  }

  /// A linear ramp across the shorter side reads back the position each
  /// output pixel samples. The whole input maps onto the whole-pixel grid, so
  /// output pixel `j` of `n` samples `(j + 0.5) / n` of the way across; the
  /// rounded side is stretched to fill its last pixel rather than left short.
  @Test(arguments: [
    // 200 × 100 / 301 = 66.45 rounds to 66, so the height is stretched.
    RampCase(width: 301, height: 200, maxPixelSize: 100, rampAxis: .vertical),
    RampCase(width: 200, height: 301, maxPixelSize: 100, rampAxis: .horizontal),
  ])
  func `the whole image maps onto the whole-pixel grid`(ramp: RampCase) throws {
    let extent = CGRect(x: 0, y: 0, width: ramp.width, height: ramp.height)
    let gradient = CIFilter.linearGradient()
    gradient.point0 = .zero
    gradient.point1 = ramp.rampAxis == .vertical
      ? CGPoint(x: 0, y: ramp.height)
      : CGPoint(x: ramp.width, y: 0)
    gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
    gradient.color1 = CIColor(red: 1, green: 1, blue: 1)
    let source = try #require(gradient.outputImage).cropped(to: extent)
    let linearSRGB = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))

    let image = try ExportRenderer().render(
      from: source,
      feature: EmptyFeature(),
      options: .init(
        resolution: .resize(maxPixelSize: ramp.maxPixelSize),
        outputFormat: .RGBAf,
        outputColorSpace: linearSRGB
      )
    ).cgImage

    let pixels = try Self.rgbaFloatPixels(of: image)
    let count = ramp.rampAxis == .vertical ? image.height : image.width
    #expect(count == 66)
    // Clamped edges do not continue the ramp; check the pixels Lanczos reads
    // entirely from inside the image.
    var largestError = 0.0
    for index in 3..<(count - 3) {
      // Core Image's y axis points up; the bitmap's first row is the top.
      let x = ramp.rampAxis == .vertical ? image.width / 2 : index
      let y = ramp.rampAxis == .vertical ? image.height - 1 - index : image.height / 2
      let value = Double(pixels[(y * image.width + x) * 4])
      let sampledPosition = value * Double(count) - 0.5
      largestError = max(largestError, abs(sampledPosition - Double(index)))
    }
    #expect(largestError < 0.1, "Output pixels sample \(largestError) px away from the whole-pixel grid.")
  }

  @Test func `transparent corners of a straightened crop stay transparent`() throws {
    let source = Self.makeOpaqueNoise(width: 1200, height: 800)

    let image = try ExportRenderer().render(
      from: source,
      feature: CropFeature(
        rect: CGRect(x: 0, y: 0, width: 1200, height: 800),
        straightenRadians: 8 * .pi / 180
      ),
      options: .init(resolution: .resize(maxPixelSize: 300))
    ).cgImage

    #expect(image.width == 300)
    #expect(image.height == 200)
    let pixels = try Self.rgba8Pixels(of: image)
    func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * image.width + x) * 4 + 3] }
    #expect(alpha(0, 0) == 0)
    #expect(alpha(image.width - 1, 0) == 0)
    #expect(alpha(0, image.height - 1) == 0)
    #expect(alpha(image.width - 1, image.height - 1) == 0)
    #expect(alpha(image.width / 2, image.height / 2) == 255)
  }

  @Test(arguments: [
    ResizeCase(width: 3984, height: 5976, maxPixelSize: 598, expectedWidth: 399, expectedHeight: 598),
    ResizeCase(width: 4000, height: 6, maxPixelSize: 256, expectedWidth: 256, expectedHeight: 1),
  ])
  func `a resized file matches the resized memory result`(resize: ResizeCase) throws {
    let source = Self.makeOpaqueNoise(width: resize.width, height: resize.height)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("export-renderer-resize-tests-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }

    // A photo carries its color space; tag both results with the same one.
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))

    let memory = try ExportRenderer().render(
      from: source,
      feature: EmptyFeature(),
      options: .init(
        resolution: .resize(maxPixelSize: resize.maxPixelSize),
        outputColorSpace: sRGB
      )
    ).cgImage
    let file = try ExportRenderer().render(
      from: source,
      feature: EmptyFeature(),
      options: .init(
        resolution: .resize(maxPixelSize: resize.maxPixelSize),
        outputColorSpace: sRGB,
        output: .file(url: url, fileType: .png)
      )
    ).cgImage

    #expect(file.width == resize.expectedWidth)
    #expect(file.height == resize.expectedHeight)
    #expect(file.width == memory.width)
    #expect(file.height == memory.height)
    let memoryPixels = try Self.rgba8Pixels(of: memory)
    let filePixels = try Self.rgba8Pixels(of: file)
    #expect(Self.translucentPixelCount(in: filePixels) == 0)
    let largestDifference = zip(memoryPixels, filePixels)
      .map { abs(Int($0) - Int($1)) }
      .max() ?? 0
    #expect(largestDifference <= 1)
  }

  // MARK: - Fixtures

  struct ResizeCase: Sendable, CustomTestStringConvertible {
    var width: CGFloat
    var height: CGFloat
    var maxPixelSize: CGFloat
    var expectedWidth: Int
    var expectedHeight: Int

    var testDescription: String {
      "\(Int(width))×\(Int(height)) → \(Int(maxPixelSize))"
    }
  }

  struct ThinCrop: Sendable, CustomTestStringConvertible {
    var height: CGFloat
    var maxPixelSize: CGFloat
    var expectedWidth: Int

    var testDescription: String {
      "4000×\(Int(height)) → \(Int(maxPixelSize))"
    }
  }

  struct RampCase: Sendable, CustomTestStringConvertible {
    enum Axis: Sendable { case horizontal, vertical }

    var width: CGFloat
    var height: CGFloat
    var maxPixelSize: CGFloat
    var rampAxis: Axis

    var testDescription: String {
      "\(Int(width))×\(Int(height)) → \(Int(maxPixelSize)), \(rampAxis) ramp"
    }
  }

  /// Opaque, full-contrast noise that reaches every edge, the hardest case
  /// for Lanczos ringing at the border.
  private static func makeOpaqueNoise(width: CGFloat, height: CGFloat) -> CIImage {
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    return CIFilter.randomGenerator().outputImage!
      .settingAlphaOne(in: extent)
      .cropped(to: extent)
  }

  private static func translucentPixelCount(in pixels: [UInt8]) -> Int {
    stride(from: 3, to: pixels.count, by: 4).count(where: { pixels[$0] != 255 })
  }

  /// Premultiplied RGBA, 8 bits per component, first row at the top.
  private static func rgba8Pixels(of image: CGImage) throws -> [UInt8] {
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try pixels.withUnsafeMutableBytes { buffer in
      let context = try #require(CGContext(
        data: buffer.baseAddress,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
      ))
      context.setBlendMode(.copy)
      context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
      )
    }
    return pixels
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
