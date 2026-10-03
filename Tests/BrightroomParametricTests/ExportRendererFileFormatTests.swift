//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation
import ImageIO
import Testing

@testable import BrightroomParametric

/// Pins how `Output.file` stores `Options.outputFormat`: each file type keeps
/// the requested depth when it can, the nearest one otherwise, and
/// `RenderedImage` reports the format the file has. `.memory` still delivers
/// the requested format exactly, and a deeper write keeps the strip size in
/// bytes, so its peak memory is unchanged.
struct ExportRendererFileFormatTests {

  struct Case: Sendable, CustomTestStringConvertible {
    let fileType: ExportRenderer.FileType
    let fileExtension: String
    let requested: CIFormat
    let stored: CIFormat
    let bitsPerComponent: Int

    var testDescription: String {
      "\(fileExtension), requested \(requested.rawValue) → stored \(stored.rawValue)"
    }
  }

  static let cases: [Case] = [
    // PNG keeps 16 bits per component.
    Case(fileType: .png, fileExtension: "png", requested: .BGRA8, stored: .RGBA8, bitsPerComponent: 8),
    Case(fileType: .png, fileExtension: "png", requested: .RGBA16, stored: .RGBA16, bitsPerComponent: 16),
    Case(fileType: .png, fileExtension: "png", requested: .RGBAh, stored: .RGBA16, bitsPerComponent: 16),
    Case(fileType: .png, fileExtension: "png", requested: .RGBAf, stored: .RGBA16, bitsPerComponent: 16),
    Case(fileType: .png, fileExtension: "png", requested: .L16, stored: .RGBA16, bitsPerComponent: 16),
    Case(fileType: .png, fileExtension: "png", requested: .rgbXh, stored: .RGBA16, bitsPerComponent: 16),
    Case(fileType: .png, fileExtension: "png", requested: .rgbXf, stored: .RGBA16, bitsPerComponent: 16),
    // HEIF keeps 10.
    Case(fileType: .heif(quality: 0.9), fileExtension: "heic", requested: .BGRA8, stored: .RGBA8, bitsPerComponent: 8),
    Case(fileType: .heif(quality: 0.9), fileExtension: "heic", requested: .RGBA16, stored: .RGB10, bitsPerComponent: 10),
    Case(fileType: .heif(quality: 0.9), fileExtension: "heic", requested: .RGBAh, stored: .RGB10, bitsPerComponent: 10),
    Case(fileType: .heif(quality: 0.9), fileExtension: "heic", requested: .rgbXh, stored: .RGB10, bitsPerComponent: 10),
    // JPEG has only 8.
    Case(fileType: .jpeg(quality: 0.9), fileExtension: "jpg", requested: .BGRA8, stored: .RGBA8, bitsPerComponent: 8),
    Case(fileType: .jpeg(quality: 0.9), fileExtension: "jpg", requested: .RGBAh, stored: .RGBA8, bitsPerComponent: 8),
  ]

  @Test(arguments: cases)
  func `a file stores the depth its type can hold and reports it`(_ testCase: Case) throws {
    let url = Self.temporaryURL(extension: testCase.fileExtension)
    defer { try? FileManager.default.removeItem(at: url) }

    let rendered = try ExportRenderer().render(
      from: Self.gradientSource(),
      feature: EmptyFeature(),
      options: .init(
        outputFormat: testCase.requested,
        outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        output: .file(url: url, fileType: testCase.fileType)
      )
    )

    #expect(rendered.options.outputFormat == testCase.stored)
    #expect(Self.bitsPerComponent(of: rendered.options.outputFormat) == testCase.bitsPerComponent)

    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try #require(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    #expect(properties[kCGImagePropertyDepth] as? Int == testCase.bitsPerComponent)
    let decoded = try rendered.cgImage
    #expect(decoded.bitsPerComponent == testCase.bitsPerComponent)
    #expect(decoded.width == Self.size.width)
    #expect(decoded.height == Self.size.height)
  }

  /// A 16-bit PNG holds more levels than 8 bits can, so the deeper write
  /// keeps real precision rather than widening 8-bit pixels.
  @Test func `a 16-bit PNG keeps levels between 8-bit steps`() throws {
    let url8 = Self.temporaryURL(extension: "png")
    let url16 = Self.temporaryURL(extension: "png")
    defer {
      try? FileManager.default.removeItem(at: url8)
      try? FileManager.default.removeItem(at: url16)
    }

    let image8 = try Self.renderFile(url: url8, outputFormat: .BGRA8)
    let image16 = try Self.renderFile(url: url16, outputFormat: .RGBA16)

    let levels8 = try Self.distinctRedLevels(in: image8)
    let levels16 = try Self.distinctRedLevels(in: image16)
    #expect(levels8 <= 256)
    #expect(levels16 > 512, "\(levels16) distinct levels")
  }

  /// A 16-bit file holds the same colors as an 8-bit one: the strips are
  /// read with the byte order Core Image wrote them in.
  @Test func `a 16-bit PNG has the same colors as an 8-bit one`() throws {
    let url8 = Self.temporaryURL(extension: "png")
    let url16 = Self.temporaryURL(extension: "png")
    defer {
      try? FileManager.default.removeItem(at: url8)
      try? FileManager.default.removeItem(at: url16)
    }

    let pixels8 = try Self.pixelsInSRGB(try Self.renderFile(url: url8, outputFormat: .BGRA8))
    let pixels16 = try Self.pixelsInSRGB(try Self.renderFile(url: url16, outputFormat: .RGBA16))

    let largestDifference = zip(pixels8, pixels16).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(largestDifference <= 1)
  }

  /// Every `CIFormat` the SDK declares.
  static let allFormats: [CIFormat] = [
    .ARGB8, .BGRA8, .RGBA8, .RGBX8, .ABGR8,
    .RGBAh, .RGBA16, .RGBAf, .RGBX16, .rgbXh, .rgbXf, .RGB10,
    .A8, .A16, .Ah, .Af,
    .R8, .R16, .Rh, .Rf,
    .RG8, .RG16, .RGh, .RGf,
    .L8, .L16, .Lh, .Lf,
    .LA8, .LA16, .LAh, .LAf,
  ]

  /// The formats Core Image cannot render into a `CGImage` with any color
  /// space: alpha only, red only, and red-green.
  static let formatsWithoutMemoryResult: [CIFormat] = [
    .A8, .A16, .Ah, .Af,
    .R8, .R16, .Rh, .Rf,
    .RG8, .RG16, .RGh, .RGf,
  ]

  /// The file keeps more than 8 bits per component exactly when the
  /// `.memory` result in the same format has them, so no deep format is
  /// missing from the list `Output.file` checks.
  @Test(arguments: allFormats.filter { formatsWithoutMemoryResult.contains($0) == false })
  func `a PNG is deep exactly when the memory result is`(format: CIFormat) throws {
    let memory = try ExportRenderer().render(
      from: Self.gradientSource(),
      feature: EmptyFeature(),
      options: .init(
        outputFormat: format,
        outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
      )
    )
    let isDeep = try memory.cgImage.bitsPerComponent > 8

    let url = Self.temporaryURL(extension: "png")
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try ExportRenderer().render(
      from: Self.gradientSource(),
      feature: EmptyFeature(),
      options: .init(
        outputFormat: format,
        outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        output: .file(url: url, fileType: .png)
      )
    )

    #expect(file.options.outputFormat == (isDeep ? .RGBA16 : .RGBA8))
    #expect(try file.cgImage.bitsPerComponent == (isDeep ? 16 : 8))
  }

  // MARK: - Memory output is unchanged

  @Test(arguments: [
    (CIFormat.BGRA8, 8),
    (CIFormat.RGBA16, 16),
    (CIFormat.RGBAh, 16),
  ])
  func `a memory result has the requested format`(format: CIFormat, bitsPerComponent: Int) throws {
    let rendered = try ExportRenderer().render(
      from: Self.gradientSource(),
      feature: EmptyFeature(),
      options: .init(outputFormat: format)
    )

    #expect(rendered.options.outputFormat == format)
    #expect(try rendered.cgImage.bitsPerComponent == bitsPerComponent)
  }

  // MARK: - Bounded memory

  @Test func `a strip holds the same number of bytes at every depth`() {
    typealias Writer = CIImageStreamingFileWriter
    let bytes8 = Writer.stripHeight(for: .rgba8) * Writer.PixelFormat.rgba8.bytesPerPixel
    let bytes16 = Writer.stripHeight(for: .rgba16) * Writer.PixelFormat.rgba16.bytesPerPixel

    #expect(Writer.stripHeight(for: .rgba8) == Writer.referenceStripHeight)
    #expect(bytes16 == bytes8)
  }

  // MARK: - Fixtures

  private static let size = (width: 2048, height: 4)

  private static func temporaryURL(extension fileExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("export-renderer-file-format-tests-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)
  }

  /// The bits per component of the formats `Output.file` reports.
  private static func bitsPerComponent(of format: CIFormat) -> Int? {
    switch format {
    case .RGBA8: 8
    case .RGB10: 10
    case .RGBA16: 16
    default: nil
    }
  }

  /// A horizontal black-to-white ramp, one level per pixel column.
  private static func gradientSource() throws -> CIImage {
    let gradient = try #require(
      CIFilter(
        name: "CILinearGradient",
        parameters: [
          "inputPoint0": CIVector(x: 0, y: 0),
          "inputPoint1": CIVector(x: CGFloat(size.width), y: 0),
          "inputColor0": CIColor(red: 0, green: 0, blue: 0),
          "inputColor1": CIColor(red: 1, green: 1, blue: 1),
        ]
      )?.outputImage
    )
    return gradient.cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
  }

  private static func renderFile(url: URL, outputFormat: CIFormat) throws -> CGImage {
    let rendered = try ExportRenderer().render(
      from: gradientSource(),
      feature: EmptyFeature(),
      options: .init(
        outputFormat: outputFormat,
        outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        output: .file(url: url, fileType: .png)
      )
    )
    return try rendered.cgImage
  }

  /// The number of distinct red values along the first row, read at 16 bits
  /// per component so no level is merged.
  private static func distinctRedLevels(in image: CGImage) throws -> Int {
    let context = try #require(
      CGContext(
        data: nil,
        width: image.width,
        height: 1,
        bitsPerComponent: 16,
        bytesPerRow: image.width * 8,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          | CGBitmapInfo.byteOrder16Little.rawValue
      )
    )
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: 1))
    let data = try #require(context.data)
    let row = UnsafeBufferPointer(
      start: data.assumingMemoryBound(to: UInt16.self),
      count: image.width * 4
    )
    return Set(stride(from: 0, to: row.count, by: 4).map { row[$0] }).count
  }

  /// Every pixel drawn into an 8-bit sRGB bitmap.
  private static func pixelsInSRGB(_ image: CGImage) throws -> [UInt8] {
    let context = try #require(
      CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    )
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let data = try #require(context.data)
    return Array(
      UnsafeBufferPointer(
        start: data.assumingMemoryBound(to: UInt8.self),
        count: image.width * image.height * 4
      )
    )
  }
}
