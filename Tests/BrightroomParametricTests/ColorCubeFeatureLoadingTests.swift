//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BrightroomParametric

struct ColorCubeFeatureLoadingTests {

  @Test func `Color cube feature loads cube files directly`() throws {
    let directory = try Self.makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let url = directory.appendingPathComponent("Identity.cube")
    try Self.identityCube(size: 2, title: "Identity 2").write(
      to: url,
      atomically: true,
      encoding: .utf8
    )

    let feature = try ColorCubeFeature(
      contentsOfCubeFile: url,
      intensity: 0.75
    )

    #expect(feature.name == "Identity 2")
    #expect(feature.id == "Identity.cube")
    #expect(feature.intensity == 0.75)
    #expect(feature.dimension == 2)
    #expect(feature.cubeData.count == 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)

    let identified = try ColorCubeFeature(contentsOfCubeFile: url, id: "pack-a/identity")
    #expect(identified.id == "pack-a/identity")
    #expect(identified.cubeData == feature.cubeData)
  }

  @Test func `Color cube parser reads CRLF comments and numeric exponents`() throws {
    let cube = [
      "  # DaVinci Resolve style comment",
      "title \"Identity ü\" # inline comment",
      "lut_3d_size\t2",
      "lut_3d_input_range 0e0 1e0",
      "",
      "0 0 0",
      "1e0 0 0",
      "0 1 0",
      "1 1 0",
      "0 0 1",
      "1 0 1",
      "0 1 1",
      "1 1 1 # final value",
    ].joined(separator: "\r\n")

    let parsed = try ColorCubeTextParser().parse(cube)
    let values = parsed.cubeData.withUnsafeBytes {
      Array($0.bindMemory(to: Float.self))
    }

    #expect(parsed.title == "Identity ü")
    #expect(parsed.dimension == 2)
    #expect(
      values == [
        0, 0, 0, 1,
        1, 0, 0, 1,
        0, 1, 0, 1,
        1, 1, 0, 1,
        0, 0, 1, 1,
        1, 0, 1, 1,
        0, 1, 1, 1,
        1, 1, 1, 1,
      ]
    )
  }

  @Test func `Color cube parser materializes a production-sized cube`() throws {
    let parsed = try ColorCubeTextParser().parse(
      Self.identityCube(size: 64, title: "Identity 64")
    )

    #expect(parsed.title == "Identity 64")
    #expect(parsed.dimension == 64)
    #expect(
      parsed.cubeData.count
        == 64 * 64 * 64 * 4 * MemoryLayout<Float>.size
    )
  }

  @Test func `Color cube parser preserves malformed data diagnostics`() {
    let cube = [
      "LUT_3D_SIZE 2",
      "0 0 0",
      "0 0",
    ].joined(separator: "\n")

    #expect(
      throws: ColorCubeLoadingError.invalidDataLine(
        "0 0",
        line: 3
      )
    ) {
      try ColorCubeTextParser().parse(cube)
    }
  }

  @Test func `Color cube parser rejects a non-default domain`() {
    let cube = [
      "LUT_3D_SIZE 2",
      "DOMAIN_MIN -0.5 0.0 0.0",
      "DOMAIN_MAX 1.0 1.0 1.0",
      "0 0 0",
      "1 0 0",
      "0 1 0",
      "1 1 0",
      "0 0 1",
      "1 0 1",
      "0 1 1",
      "1 1 1",
    ].joined(separator: "\n")

    #expect(
      throws: ColorCubeLoadingError.unsupportedDomain(
        domainMin: [-0.5, 0, 0],
        domainMax: [1, 1, 1]
      )
    ) {
      try ColorCubeTextParser().parse(cube)
    }
  }

  @Test func `Color cube feature normalizes image LUT data`() throws {
    let image = try Self.makeCubeImage()
    let feature = try ColorCubeFeature(
      cubeImage: image,
      name: "Image LUT",
      id: "image-lut"
    )

    #expect(feature.dimension == 4)
    #expect(feature.cubeData.count == 4 * 4 * 4 * 4 * MemoryLayout<Float>.size)

    let values = feature.cubeData.withUnsafeBytes {
      Array($0.bindMemory(to: Float.self))
    }
    #expect(abs(values[0] - 64 / 255) < 0.0001)
    #expect(abs(values[1] - 128 / 255) < 0.0001)
    #expect(abs(values[2] - 192 / 255) < 0.0001)
    #expect(abs(values[3] - 1) < 0.0001)
  }

  @Test func `Color cube feature loads PNG and JPEG LUT images`() throws {
    let directory = try Self.makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let image = try Self.makeCubeImage()
    let formats = [
      (fileExtension: "png", type: UTType.png),
      (fileExtension: "jpg", type: UTType.jpeg),
    ]

    for format in formats {
      let url = directory
        .appendingPathComponent("ImageLUT")
        .appendingPathExtension(format.fileExtension)
      try Self.write(image, to: url, type: format.type)

      let feature = try ColorCubeFeature(contentsOfCubeImage: url)

      #expect(feature.name == "ImageLUT")
      #expect(feature.id == url.lastPathComponent)
      #expect(try ColorCubeFeature(contentsOfCubeImage: url, id: "pack-a/image").id == "pack-a/image")
      #expect(feature.dimension == 4)
      #expect(feature.cubeData.count == 4 * 4 * 4 * 4 * MemoryLayout<Float>.size)
    }
  }

  @Test func `Color cube feature rejects dimensions that overflow storage`() throws {
    let directory = try Self.makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }

    let cubeURL = directory.appendingPathComponent("Overflow.cube")
    try "LUT_3D_SIZE \(Int.max)".write(
      to: cubeURL,
      atomically: true,
      encoding: .utf8
    )

    #expect(
      throws: ColorCubeLoadingError.invalidCubeSize(
        String(Int.max),
        line: 1
      )
    ) {
      try ColorCubeFeature(contentsOfCubeFile: cubeURL)
    }

    let image = try Self.makeCubeImage()
    #expect(
      throws: ColorCubeLoadingError.unableToInferCubeDimension(
        width: image.width,
        height: image.height
      )
    ) {
      try ColorCubeFeature(
        cubeImage: image,
        name: "Overflow",
        id: "overflow",
        dimension: Int.max
      )
    }
  }

  /// LUT pixels are table entries, so an image tagged with a wide or
  /// non-sRGB space loads its raw values instead of colors converted to
  /// sRGB, in memory and through a PNG file that carries the profile.
  @Test(arguments: [
    CGColorSpace.sRGB as String,
    CGColorSpace.displayP3 as String,
    CGColorSpace.adobeRGB1998 as String,
  ])
  func `Image LUTs keep their raw values in their own RGB space`(spaceName: String) throws {
    let space = try #require(CGColorSpace(name: spaceName as CFString))
    let bytes = Self.rawValueCubeBytes(dimension: 16)
    let image = try Self.makeRGBXImage(bytes: bytes, width: 64, height: 64, space: space)
    let expected = bytes.enumerated().map { index, byte in
      index % 4 == 3 ? Float(1) : Float(byte) / 255
    }

    let inMemory = try ColorCubeFeature(cubeImage: image, name: "Raw", id: "raw")
    #expect(inMemory.dimension == 16)
    #expect(Self.maximumDifference(Self.floats(of: inMemory.cubeData), expected) < 0.000_01)

    let directory = try Self.makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let url = directory.appendingPathComponent("LUT_16_Raw.png")
    try Self.write(image, to: url, type: .png)
    let decoded = try #require(
      CGImageSourceCreateWithURL(url as CFURL, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    )
    // The file keeps its profile (ImageIO leaves Adobe RGB unnamed).
    let decodedName = decoded.colorSpace?.name.map { $0 as String }
    #expect((decodedName == CGColorSpace.sRGB as String) == (spaceName == CGColorSpace.sRGB as String))

    let fromFile = try ColorCubeFeature(contentsOfCubeImage: url, dimension: 16)
    #expect(Self.maximumDifference(Self.floats(of: fromFile.cubeData), expected) < 0.000_01)
  }

  /// An image in an extended space, which an 8-bit context cannot hold,
  /// keeps its raw values in 0...1 through the standard-range version of the
  /// space, including wide-gamut and linear ones.
  @Test(arguments: [
    CGColorSpace.extendedSRGB as String,
    CGColorSpace.extendedDisplayP3 as String,
    CGColorSpace.extendedLinearSRGB as String,
  ])
  func `Image LUTs in an extended space keep their raw values`(spaceName: String) throws {
    let space = try #require(CGColorSpace(name: spaceName as CFString))
    let dimension = 16
    let values = Self.rawValueCubeBytes(dimension: dimension).enumerated().map { index, byte in
      index % 4 == 3 ? Float(1) : Float(byte) / 255
    }
    let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    let provider = try #require(CGDataProvider(data: data as CFData))
    let image = try #require(
      CGImage(
        width: 64,
        height: 64,
        bitsPerComponent: 32,
        bitsPerPixel: 128,
        bytesPerRow: 64 * 4 * MemoryLayout<Float>.size,
        space: space,
        bitmapInfo: CGBitmapInfo(
          rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    )

    let feature = try ColorCubeFeature(cubeImage: image, name: "Extended", id: "extended")

    #expect(feature.dimension == dimension)
    // Only 8-bit quantization separates the loaded values from the source.
    #expect(Self.maximumDifference(Self.floats(of: feature.cubeData), values) <= 0.5 / 255 + 0.000_01)
  }

  /// An identity LUT image renders its input unchanged, which pins the row
  /// order, the channel order, and the cube layout of image loading.
  @Test func `Identity LUT image renders its input unchanged`() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let image = try Self.makeRGBXImage(
      bytes: Self.identityCubeBytes(dimension: 16),
      width: 64,
      height: 64,
      space: space
    )
    let identity = try ColorCubeFeature(cubeImage: image, name: "Identity", id: "identity-image-lut")
    let source = try RenderingFixtures.normalizedSource()

    let rendered = try RenderingFixtures.renderer.makeImage(
      from: RenderingFixtures.makeSource(),
      feature: identity
    )

    RenderingFixtures.expectPixelsMatch(source, rendered, tolerance: 1 / 255)
  }

  /// The RGBA8 bytes of an identity cube, red varying fastest.
  private static func identityCubeBytes(dimension: Int) -> [UInt8] {
    let scale = Double(dimension - 1)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(dimension * dimension * dimension * 4)
    for blue in 0..<dimension {
      for green in 0..<dimension {
        for red in 0..<dimension {
          bytes += [red, green, blue].map { UInt8((Double($0) / scale * 255).rounded()) }
          bytes.append(255)
        }
      }
    }
    return bytes
  }

  /// RGBA8 bytes where every channel of every entry has its own value, so a
  /// color conversion, a swapped channel, or a flipped row changes them.
  private static func rawValueCubeBytes(dimension: Int) -> [UInt8] {
    let count = dimension * dimension * dimension
    return (0..<count).flatMap { index -> [UInt8] in
      [
        UInt8(index % 251),
        UInt8((index * 7 + 30) % 253),
        UInt8((index / 3 + 90) % 256),
        255,
      ]
    }
  }

  /// An opaque 8-bit image laid out the way ImageIO decodes most LUT files.
  private static func makeRGBXImage(
    bytes: [UInt8],
    width: Int,
    height: Int,
    space: CGColorSpace
  ) throws -> CGImage {
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    return try #require(
      CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGBitmapInfo(
          rawValue:
            CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    )
  }

  private static func floats(of data: Data) -> [Float] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  private static func maximumDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
    guard lhs.count == rhs.count else {
      return .infinity
    }
    return zip(lhs, rhs).reduce(0) { max($0, abs($1.0 - $1.1)) }
  }

  private static func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private static func makeCubeImage() throws -> CGImage {
    let width = 8
    let height = 8
    let pixel = [UInt8](arrayLiteral: 64, 128, 192, 255)
    let pixelData = Data((0..<(width * height)).flatMap { _ in pixel })
    let provider = try #require(CGDataProvider(data: pixelData as CFData))
    return try #require(
      CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
          rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    )
  }

  private static func write(
    _ image: CGImage,
    to url: URL,
    type: UTType
  ) throws {
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  private static func identityCube(size: Int, title: String) -> String {
    let divisor = Float(size - 1)
    var lines = [
      "# comment",
      "TITLE \"\(title)\"",
      "LUT_3D_SIZE \(size)",
      "DOMAIN_MIN 0.0 0.0 0.0",
      "DOMAIN_MAX 1.0 1.0 1.0",
    ]

    for blueIndex in 0..<size {
      for greenIndex in 0..<size {
        for redIndex in 0..<size {
          let red = Float(redIndex) / divisor
          let green = Float(greenIndex) / divisor
          let blue = Float(blueIndex) / divisor
          lines.append("\(red) \(green) \(blue)")
        }
      }
    }

    return lines.joined(separator: "\n")
  }
}
