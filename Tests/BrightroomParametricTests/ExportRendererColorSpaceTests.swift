//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

import BrightroomParametric

/// Public API only. Pins the color space `ExportRenderer` tags its result
/// with: the source's or the requested space when it can describe the output
/// pixels, and a standard space of the right model when it cannot, so a
/// grayscale source, or a gray or CMYK `outputColorSpace`, still exports.
struct ExportRendererColorSpaceTests {

  // MARK: - Spaces outside RGB

  @Test func `a grayscale JPEG exports to memory tagged sRGB`() throws {
    let source = try Self.grayscaleJPEGSource()
    #expect(source.colorSpace?.model == .monochrome)

    let rendered = try ExportRenderer().render(from: source, feature: EmptyFeature())

    let cgImage = try rendered.cgImage
    #expect(cgImage.colorSpace?.name == CGColorSpace.sRGB)
    #expect(cgImage.width == Self.size.width)
    #expect(cgImage.height == Self.size.height)
    try Self.expectNeutralGray(cgImage)
  }

  @Test(arguments: [
    ExportRenderer.FileType.jpeg(quality: 0.9),
    ExportRenderer.FileType.heif(quality: 0.9),
    ExportRenderer.FileType.png,
  ])
  func `a grayscale JPEG exports to a file`(fileType: ExportRenderer.FileType) throws {
    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let rendered = try ExportRenderer().render(
      from: try Self.grayscaleJPEGSource(),
      feature: EmptyFeature(),
      options: .init(output: .file(url: url, fileType: fileType))
    )

    let cgImage = try rendered.cgImage
    #expect(cgImage.width == Self.size.width)
    #expect(cgImage.height == Self.size.height)
    try Self.expectNeutralGray(cgImage)
  }

  @Test(arguments: [CGColorSpace.linearGray as String, CGColorSpace.genericCMYK as String])
  func `a requested space outside RGB falls back to sRGB for an RGB output`(name: String) throws {
    let requested = try #require(CGColorSpace(name: name as CFString))
    let source = try Self.rgbSource(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)

    let memory = try ExportRenderer().render(
      from: source,
      feature: EmptyFeature(),
      options: .init(outputColorSpace: requested)
    )
    #expect(try memory.cgImage.colorSpace?.name == CGColorSpace.sRGB)

    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try ExportRenderer().render(
      from: source,
      feature: EmptyFeature(),
      options: .init(outputColorSpace: requested, output: .file(url: url, fileType: .png))
    )
    #expect(try file.cgImage.colorSpace?.model == .rgb)
  }

  // MARK: - Luminance output formats

  @Test func `a luminance format keeps a gray source's space`() throws {
    let rendered = try ExportRenderer().render(
      from: try Self.grayscaleJPEGSource(),
      feature: EmptyFeature(),
      options: .init(outputFormat: .L8)
    )

    let cgImage = try rendered.cgImage
    #expect(cgImage.colorSpace?.model == .monochrome)
    #expect(cgImage.bitsPerPixel == 8)
  }

  @Test func `a luminance format tags an RGB source with a gray space`() throws {
    let rendered = try ExportRenderer().render(
      from: try Self.rgbSource(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!),
      feature: EmptyFeature(),
      options: .init(outputFormat: .L8)
    )

    #expect(try rendered.cgImage.colorSpace?.name == CGColorSpace.genericGrayGamma2_2)
  }

  // MARK: - RGB sources are unchanged

  @Test(arguments: [
    CGColorSpace.sRGB as String,
    CGColorSpace.displayP3 as String,
    CGColorSpace.adobeRGB1998 as String,
  ])
  func `an RGB source keeps its own space`(name: String) throws {
    let colorSpace = try #require(CGColorSpace(name: name as CFString))
    let source = try Self.rgbSource(colorSpace: colorSpace)

    let memory = try ExportRenderer().render(from: source, feature: EmptyFeature())
    #expect(try memory.cgImage.colorSpace?.name as String? == name)

    let url = Self.temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try ExportRenderer().render(
      from: source,
      feature: EmptyFeature(),
      options: .init(output: .file(url: url, fileType: .png))
    )
    // A file carries the space as an ICC profile, which Image I/O does not
    // always map back to the named space, so compare the colors it means.
    let filePixel = try Self.centerPixelInSRGB(try file.cgImage)
    let memoryPixel = try Self.centerPixelInSRGB(try memory.cgImage)
    #expect(
      zip(filePixel, memoryPixel).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
      "file \(filePixel), memory \(memoryPixel)"
    )
  }

  @Test func `a requested RGB space wins over the source's`() throws {
    let rendered = try ExportRenderer().render(
      from: try Self.grayscaleJPEGSource(),
      feature: EmptyFeature(),
      options: .init(outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
    )

    #expect(try rendered.cgImage.colorSpace?.name == CGColorSpace.displayP3)
  }

  // MARK: - Fixtures

  private static let size = (width: 24, height: 16)

  /// The gray level the fixtures are filled with, in their own space.
  private static let grayLevel: CGFloat = 0.5

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("export-renderer-color-space-tests-\(UUID().uuidString)")
  }

  /// A mid-gray JPEG encoded from a one-channel gray bitmap, decoded the way
  /// a host reads a black-and-white scan.
  private static func grayscaleJPEGSource() throws -> CIImage {
    let context = try #require(
      CGContext(
        data: nil,
        width: size.width,
        height: size.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    )
    context.setFillColor(gray: grayLevel, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
    let bitmap = try #require(context.makeImage())

    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, bitmap, nil)
    #expect(CGImageDestinationFinalize(destination))
    return try #require(CIImage(data: data as Data))
  }

  private static func rgbSource(colorSpace: CGColorSpace) throws -> CIImage {
    let context = try #require(
      CGContext(
        data: nil,
        width: size.width,
        height: size.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    )
    context.setFillColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
    return CIImage(cgImage: try #require(context.makeImage()))
  }

  /// Expects the center pixel, read in sRGB, to be a neutral gray near the
  /// fixture's level: the export kept the gray rather than tinting or
  /// blanking it.
  private static func expectNeutralGray(_ image: CGImage) throws {
    let pixel = try centerPixelInSRGB(image)
    let (red, green, blue) = (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    #expect(abs(red - green) <= 2 && abs(green - blue) <= 2, "\(pixel)")
    #expect(abs(red - Int(grayLevel * 255)) <= 16, "\(pixel)")
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
}
