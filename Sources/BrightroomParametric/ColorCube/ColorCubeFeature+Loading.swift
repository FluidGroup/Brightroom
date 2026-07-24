//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// Errors raised while materializing a color-cube feature from a LUT file.
public enum ColorCubeFeatureLoadingError: Error, Equatable, LocalizedError, Sendable {

  /// ImageIO could not decode the LUT image.
  case failedToCreateImage(String)

  /// The image dimensions do not describe a complete three-dimensional cube.
  case unableToInferCubeDimension(width: Int, height: Int)

  /// The `.cube` file does not contain a `LUT_3D_SIZE` directive.
  case missingLUT3DSize

  /// The `LUT_3D_SIZE` value is malformed.
  case invalidLUT3DSize(String, line: Int)

  /// One-dimensional LUTs are not supported by `ColorCubeFeature`.
  case unsupportedLUT1DSize(line: Int)

  /// The parser encountered an unsupported directive.
  case invalidDirective(String, line: Int)

  /// A domain or input-range directive is malformed.
  case invalidDomain(String, line: Int)

  /// Only the default zero-to-one input domain is currently supported.
  case unsupportedDomain(domainMin: [Float], domainMax: [Float])

  /// A color data row is malformed.
  case invalidDataLine(String, line: Int)

  /// The number of color rows does not match the declared cube dimension.
  case mismatchedDataCount(expected: Int, actual: Int)

  public var errorDescription: String? {
    switch self {
    case .failedToCreateImage(let name):
      return "Could not decode LUT image '\(name)'."
    case .unableToInferCubeDimension(let width, let height):
      return "The \(width)×\(height) LUT image does not contain a complete color cube."
    case .missingLUT3DSize:
      return "The LUT is missing a LUT_3D_SIZE directive."
    case .invalidLUT3DSize(let value, let line):
      return "Invalid LUT_3D_SIZE '\(value)' at line \(line)."
    case .unsupportedLUT1DSize(let line):
      return "LUT_1D_SIZE is not supported at line \(line)."
    case .invalidDirective(let value, let line):
      return "Invalid LUT directive '\(value)' at line \(line)."
    case .invalidDomain(let value, let line):
      return "Invalid LUT domain '\(value)' at line \(line)."
    case .unsupportedDomain(let domainMin, let domainMax):
      return "Only the default 0...1 LUT domain is supported; received \(domainMin)...\(domainMax)."
    case .invalidDataLine(let value, let line):
      return "Invalid LUT color data '\(value)' at line \(line)."
    case .mismatchedDataCount(let expected, let actual):
      return "Expected \(expected) LUT color rows, but found \(actual)."
    }
  }
}

extension ColorCubeFeature {

  /// Creates a color-cube feature from an Adobe or DaVinci Resolve `.cube` file.
  ///
  /// The caller remains responsible for opening any security-scoped file access
  /// before invoking this initializer.
  ///
  /// - Parameters:
  ///   - url: The local URL of a three-dimensional `.cube` file.
  ///   - id: A stable feature identifier. The file name is used by default.
  ///   - name: A display name. The file's `TITLE` or base name is used by default.
  ///   - amount: The opacity used when compositing the LUT result.
  public init(
    contentsOfCubeFile url: URL,
    id: FeatureID? = nil,
    name: String? = nil,
    amount: Double = 1
  ) throws {
    let parsed = try _ColorCubeTextParser().parse(contentsOf: url)
    let identifier = url.lastPathComponent
    self.init(
      id: id ?? FeatureID(rawValue: identifier),
      name: name ?? parsed.title ?? url.deletingPathExtension().lastPathComponent,
      identifier: identifier,
      amount: amount,
      dimension: parsed.dimension,
      cubeData: parsed.cubeData
    )
  }

  /// Creates a color-cube feature from a square Hald/CLUT PNG or JPEG file.
  ///
  /// When `dimension` is omitted, it is inferred from the image's pixel count,
  /// which must equal `dimension³`.
  ///
  /// - Parameters:
  ///   - url: The local URL of a square LUT image.
  ///   - id: A stable feature identifier. The file name is used by default.
  ///   - name: A display name. The file's base name is used by default.
  ///   - amount: The opacity used when compositing the LUT result.
  ///   - dimension: An explicit color-cube dimension, or `nil` to infer it.
  public init(
    cubeImageAt url: URL,
    id: FeatureID? = nil,
    name: String? = nil,
    amount: Double = 1,
    dimension: Int? = nil
  ) throws {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw ColorCubeFeatureLoadingError.failedToCreateImage(url.lastPathComponent)
    }

    let identifier = url.lastPathComponent
    try self.init(
      cubeImage: image,
      id: id ?? FeatureID(rawValue: identifier),
      name: name ?? url.deletingPathExtension().lastPathComponent,
      identifier: identifier,
      amount: amount,
      dimension: dimension
    )
  }

  /// Creates a color-cube feature from an in-memory square LUT image.
  ///
  /// The image is normalized to tightly packed RGBA8 pixels before conversion,
  /// so its original bit depth and alpha layout do not leak into cube data.
  public init(
    cubeImage: CGImage,
    id: FeatureID = .init(),
    name: String,
    identifier: String,
    amount: Double = 1,
    dimension: Int? = nil
  ) throws {
    let resolvedDimension =
      try dimension
      ?? Self.inferCubeDimension(width: cubeImage.width, height: cubeImage.height)
    let cubeData = try Self.makeCubeData(
      from: cubeImage,
      dimension: resolvedDimension
    )

    self.init(
      id: id,
      name: name,
      identifier: identifier,
      amount: amount,
      dimension: resolvedDimension,
      cubeData: cubeData
    )
  }

  /// Infers the cube dimension `d` when `width × height == d³`.
  public static func inferCubeDimension(width: Int, height: Int) throws -> Int {
    let (pixelCount, overflowed) = width.multipliedReportingOverflow(by: height)
    guard overflowed == false, pixelCount > 0 else {
      throw ColorCubeFeatureLoadingError.unableToInferCubeDimension(
        width: width,
        height: height
      )
    }

    let approximate = Int(cbrt(Double(pixelCount)).rounded())
    for candidate in [approximate - 1, approximate, approximate + 1]
    where candidate > 1 {
      if Self.cubePixelCount(dimension: candidate) == pixelCount {
        return candidate
      }
    }

    throw ColorCubeFeatureLoadingError.unableToInferCubeDimension(
      width: width,
      height: height
    )
  }

  private static func makeCubeData(
    from image: CGImage,
    dimension: Int
  ) throws -> Data {
    let width = image.width
    let height = image.height
    guard let expectedPixelCount = Self.cubePixelCount(dimension: dimension) else {
      throw ColorCubeFeatureLoadingError.unableToInferCubeDimension(
        width: width,
        height: height
      )
    }

    let (imagePixelCount, imagePixelCountOverflowed) =
      width.multipliedReportingOverflow(by: height)
    guard
      imagePixelCountOverflowed == false,
      imagePixelCount == expectedPixelCount
    else {
      throw ColorCubeFeatureLoadingError.unableToInferCubeDimension(
        width: width,
        height: height
      )
    }

    let componentCount = expectedPixelCount * 4
    var rgbaBytes = [UInt8](repeating: 0, count: componentCount)

    let didRender = rgbaBytes.withUnsafeMutableBytes { storage -> Bool in
      guard
        let context = CGContext(
          data: storage.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo:
            CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      else {
        return false
      }

      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }

    guard didRender else {
      throw ColorCubeFeatureLoadingError.failedToCreateImage("CGImage")
    }

    var floatComponents = [Float](repeating: 0, count: componentCount)
    rgbaBytes.withUnsafeBufferPointer { input in
      floatComponents.withUnsafeMutableBufferPointer { output in
        guard let inputBaseAddress = input.baseAddress,
              let outputBaseAddress = output.baseAddress
        else {
          return
        }

        vDSP_vfltu8(
          inputBaseAddress,
          1,
          outputBaseAddress,
          1,
          vDSP_Length(componentCount)
        )
        var divisor = Float(255)
        vDSP_vsdiv(
          outputBaseAddress,
          1,
          &divisor,
          outputBaseAddress,
          1,
          vDSP_Length(componentCount)
        )
      }
    }

    return floatComponents.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  private static func cubePixelCount(dimension: Int) -> Int? {
    guard dimension > 1 else {
      return nil
    }

    let (square, squareOverflowed) = dimension.multipliedReportingOverflow(by: dimension)
    let (cube, cubeOverflowed) = square.multipliedReportingOverflow(by: dimension)
    guard
      squareOverflowed == false,
      cubeOverflowed == false,
      cube <= Int.max / 4
    else {
      return nil
    }
    return cube
  }
}
