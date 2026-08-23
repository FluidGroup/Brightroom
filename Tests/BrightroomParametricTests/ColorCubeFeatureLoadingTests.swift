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
      id: FeatureID(rawValue: "test.identity"),
      amount: 0.75
    )

    #expect(feature.id == FeatureID(rawValue: "test.identity"))
    #expect(feature.name == "Identity 2")
    #expect(feature.identifier == "Identity.cube")
    #expect(feature.amount == 0.75)
    #expect(feature.dimension == 2)
    #expect(feature.cubeData.count == 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
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

    let parsed = try _ColorCubeTextParser().parse(cube)
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
    let parsed = try _ColorCubeTextParser().parse(
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
      throws: ColorCubeFeatureLoadingError.invalidDataLine(
        "0 0",
        line: 3
      )
    ) {
      try _ColorCubeTextParser().parse(cube)
    }
  }

  @Test func `Color cube feature normalizes image LUT data`() throws {
    let image = try Self.makeCubeImage()
    let feature = try ColorCubeFeature(
      cubeImage: image,
      name: "Image LUT",
      identifier: "image-lut"
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

      let feature = try ColorCubeFeature(cubeImageAt: url)

      #expect(feature.name == "ImageLUT")
      #expect(feature.identifier == url.lastPathComponent)
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
      throws: ColorCubeFeatureLoadingError.invalidLUT3DSize(
        String(Int.max),
        line: 1
      )
    ) {
      try ColorCubeFeature(contentsOfCubeFile: cubeURL)
    }

    let image = try Self.makeCubeImage()
    #expect(
      throws: ColorCubeFeatureLoadingError.unableToInferCubeDimension(
        width: image.width,
        height: image.height
      )
    ) {
      try ColorCubeFeature(
        cubeImage: image,
        name: "Overflow",
        identifier: "overflow",
        dimension: Int.max
      )
    }
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
