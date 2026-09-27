import CoreImage
import Foundation
import Testing

@testable import BrightroomParametric

/// Verifies crop-then-turn rendering against discrete source-pixel positions.
struct CropOutputGeometryTests {

  private static let context = CIContext(options: [
    .workingColorSpace: NSNull(),
    .outputColorSpace: NSNull(),
  ])

  @Test(arguments: [
    CGSize(width: 300, height: 200),
    CGSize(width: 301, height: 200),
    CGSize(width: 300, height: 201),
    CGSize(width: 301, height: 201),
    CGSize(width: 200, height: 301),
    CGSize(width: 1, height: 2),
    CGSize(width: 2, height: 1),
    CGSize(width: 1, height: 1),
  ], QuarterTurn.allCases)
  func fullImagePreservesEveryPixel(size: CGSize, rotation: QuarterTurn) throws {
    let source = Self.makeSource(size: size)
    let footprint = CGRect(origin: .zero, size: size)
    try Self.expectExactQuarterTurn(source: source, footprint: footprint, rotation: rotation)
  }

  @Test(arguments: QuarterTurn.allCases)
  func partialCropPreservesMixedParityDimensions(rotation: QuarterTurn) throws {
    let source = Self.makeSource(size: CGSize(width: 301, height: 200))
    try Self.expectExactQuarterTurn(
      source: source,
      footprint: CGRect(x: 20, y: 30, width: 121, height: 80),
      rotation: rotation
    )
  }

  @Test(arguments: [CGPoint(x: 17, y: -12), CGPoint(x: 17.25, y: -12.5)], QuarterTurn.allCases)
  func cropResolvesAgainstActualInputExtent(offset: CGPoint, rotation: QuarterTurn) throws {
    let source = Self.makeSource(size: CGSize(width: 301, height: 200))
      .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
    try Self.expectExactQuarterTurn(
      source: source,
      footprint: CGRect(origin: .zero, size: source.extent.size),
      rotation: rotation
    )
  }

  @Test(arguments: QuarterTurn.allCases)
  func laterCropUsesPreviousOutputDomain(rotation: QuarterTurn) throws {
    let source = Self.makeSource(size: CGSize(width: 301, height: 200))
    let first = CropFeature(cropRect: source.extent, rotation: .quarterCW)
    let intermediate = try first.apply(to: source, context: .init())
    try Self.expectExactQuarterTurn(
      source: intermediate,
      footprint: CGRect(x: 12, y: 25, width: 73, height: 40),
      rotation: rotation
    )
  }

  @Test func straightenKeepsAValidThinFrame() throws {
    let source = Self.makeSource(size: CGSize(width: 300, height: 200))
    let feature = CropFeature(
      cropRect: CGRect(x: 132, y: -5, width: 36, height: 210),
      rotation: .quarterCW,
      straightenRadians: .pi / 6
    )
    let output = try feature.apply(to: source, context: .init())

    #expect(output.extent == CGRect(x: 0, y: 0, width: 210, height: 36))
    let pixels = Self.pixels(output)
    #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
  }

  @Test func uncoveredCornersRetainTheRequestedCanvas() throws {
    let source = Self.makeSource(size: CGSize(width: 301, height: 200))
    let feature = CropFeature(cropRect: source.extent, straightenRadians: .pi / 6)
    let output = try feature.apply(to: source, context: .init())

    #expect(output.extent == source.extent)
    let pixels = Self.pixels(output)
    #expect(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 })
  }

  /// Missing source pixels are transparent parts of the requested canvas.
  /// The same discrete pixel mapping applies with and without an output turn.
  @Test(arguments: [
    CGRect(x: -2, y: 1, width: 6, height: 4),
    CGRect(x: -20, y: 1, width: 6, height: 4),
    CGRect(x: 8, y: 6, width: 5, height: 4),
  ], QuarterTurn.allCases)
  func cropOutsideSourcePreservesCanvasAndPixelPositions(footprint: CGRect, rotation: QuarterTurn) throws {
    let source = Self.makeSource(size: CGSize(width: 10, height: 8))
    try Self.expectExactQuarterTurn(source: source, footprint: footprint, rotation: rotation)
  }

  /// Fractional dimensions describe a continuous crop. Its zero-origin raster
  /// covers ceil(width) × ceil(height), even when part of the source is absent.
  @Test(arguments: QuarterTurn.allCases)
  func fractionalCropNormalizesBeforeRasterBoundsAreChosen(rotation: QuarterTurn) throws {
    let source = Self.makeSource(size: CGSize(width: 10, height: 8))
    let cases: [(footprint: CGRect, rasterSize: CGSize)] = [
      (CGRect(x: 0.2, y: 0.2, width: 6.3, height: 4.3), CGSize(width: 7, height: 5)),
      (CGRect(x: 8.2, y: 2.2, width: 4.3, height: 4.3), CGSize(width: 5, height: 5)),
    ]

    for fixture in cases {
      let crop = CropFeature(cropRect: fixture.footprint, rotation: rotation)
      let output = try crop.apply(to: source, context: .init())
      let isSideways = rotation == .quarterCW || rotation == .quarterCCW
      let expectedSize = isSideways
        ? CGSize(width: fixture.rasterSize.height, height: fixture.rasterSize.width)
        : fixture.rasterSize
      #expect(output.extent == CGRect(origin: .zero, size: expectedSize))
    }
  }

  // MARK: - Independent pixel oracle

  /// Uses discrete index permutations, without inverting the implementation's
  /// affine transform or deriving expectations from its output geometry.
  private static func expectExactQuarterTurn(
    source: CIImage,
    footprint: CGRect,
    rotation: QuarterTurn,
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let fx = Int(footprint.minX), fy = Int(footprint.minY)
    let fw = Int(footprint.width), fh = Int(footprint.height)
    let width: Int
    let height: Int
    switch rotation {
    case .zero, .half:
      (width, height) = (fw, fh)
    case .quarterCW, .quarterCCW:
      (width, height) = (fh, fw)
    }
    let crop = CropFeature(cropRect: footprint, rotation: rotation)
    let output = try crop.apply(to: source, context: .init())
    let expectedBounds = CGRect(x: 0, y: 0, width: width, height: height)
    try #require(output.extent == expectedBounds, sourceLocation: sourceLocation)

    let inputPixels = pixels(source)
    let outputPixels = pixels(output)
    let inputWidth = Int(source.extent.width), inputHeight = Int(source.extent.height)
    var mismatches = 0
    for row in 0..<height {
      for x in 0..<width {
        let y = height - 1 - row
        let sourceX: Int
        let sourceY: Int
        switch rotation {
        case .zero:
          sourceX = fx + x
          sourceY = fy + y
        case .quarterCW:
          sourceX = fx + y
          sourceY = fy + fh - 1 - x
        case .half:
          sourceX = fx + fw - 1 - x
          sourceY = fy + fh - 1 - y
        case .quarterCCW:
          sourceX = fx + fw - 1 - y
          sourceY = fy + x
        }
        let outputIndex = (row * width + x) * 4
        let expectedPixel: ArraySlice<UInt8>
        if (0..<inputWidth).contains(sourceX), (0..<inputHeight).contains(sourceY) {
          let inputIndex = ((inputHeight - 1 - sourceY) * inputWidth + sourceX) * 4
          expectedPixel = inputPixels[inputIndex..<(inputIndex + 4)]
        } else {
          expectedPixel = [0, 0, 0, 0]
        }
        if expectedPixel != outputPixels[outputIndex..<(outputIndex + 4)] {
          mismatches += 1
        }
      }
    }
    #expect(mismatches == 0, "\(mismatches) pixels changed position or value", sourceLocation: sourceLocation)
  }

  /// A pixel-scale pattern reveals interpolation and wrong row/column choices.
  private static func makeSource(size: CGSize) -> CIImage {
    let width = Int(size.width), height = Int(size.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let index = (y * width + x) * 4
        pixels[index] = x.isMultiple(of: 2) ? 255 : 0
        pixels[index + 1] = y.isMultiple(of: 2) ? 255 : 0
        pixels[index + 2] = UInt8((x * 17 + y * 23) % 256)
        pixels[index + 3] = 255
      }
    }
    return CIImage(
      bitmapData: Data(pixels),
      bytesPerRow: width * 4,
      size: size,
      format: .RGBA8,
      colorSpace: nil
    )
  }

  private static func pixels(_ image: CIImage) -> [UInt8] {
    let width = Int(image.extent.width), height = Int(image.extent.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes {
      context.render(
        image,
        toBitmap: $0.baseAddress!,
        rowBytes: width * 4,
        bounds: image.extent,
        format: .RGBA8,
        colorSpace: nil
      )
    }
    return pixels
  }
}
