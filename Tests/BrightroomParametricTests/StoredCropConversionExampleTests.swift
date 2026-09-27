import CoreGraphics
import CoreImage
import Foundation
import Testing

// Public API only: this file plays the role of a host app that converts crops
// saved by Brightroom 5.x's `ParametricDocumentCodec`. It must not need
// `@testable` access. docs/parametric-persistence.md ("Crop rectangles")
// shows `makeCrop(schema:stored:)`; keep the two in sync.
import BrightroomParametric

/// The `params` of a 5.x `brightroom.domain.crop` envelope.
private struct Stored5xCrop: Decodable {
  var isEnabled: Bool
  var cropRect: CGRect  // [[x, y], [width, height]]
  var rotation: Int?  // absent in schema 1
  var straightenRadians: Double?
}

private enum CropConversionError: Error {
  case unsupportedSchema(Int)
  case unknownRotation(Int)
}

/// Converts a stored 5.x crop; `nil` means the crop was disabled.
private func makeCrop(schema: Int, stored: Stored5xCrop) throws -> CropFeature? {
  guard stored.isEnabled else { return nil }
  let rotation: QuarterTurn
  if let raw = stored.rotation {
    guard let turn = QuarterTurn(rawValue: raw) else { throw CropConversionError.unknownRotation(raw) }
    rotation = turn
  } else {
    rotation = .zero
  }
  let r = stored.cropRect
  let selection: CGRect
  switch schema {
  case 1, 3:
    selection = r
  case 2 where rotation.isSideways:
    // Schema 2 stored the output frame. Keep its center and exchange its size.
    selection = CGRect(x: r.midX - r.height / 2, y: r.midY - r.width / 2, width: r.height, height: r.width)
  case 2:
    selection = r
  default:
    throw CropConversionError.unsupportedSchema(schema)
  }
  let crop = CropFeature(
    cropRect: selection,
    rotation: rotation,
    straightenRadians: stored.straightenRadians ?? 0
  )
  try crop.validate()
  return crop
}

@Suite("Stored 5.x crop conversion example")
struct StoredCropConversionExampleTests {

  private static let context = CIContext(options: [
    .workingColorSpace: NSNull(),
    .outputColorSpace: NSNull(),
  ])

  @Test
  func schemaTwoSidewaysFrameBecomesTheSelectionBeforeTheTurn() throws {
    let json = Data(#"{"isEnabled":true,"cropRect":[[50,-50],[200,300]],"rotation":-90,"straightenRadians":0}"#.utf8)
    let stored = try JSONDecoder().decode(Stored5xCrop.self, from: json)

    let crop = try #require(try makeCrop(schema: 2, stored: stored))

    #expect(crop == CropFeature(cropRect: CGRect(x: 0, y: 0, width: 300, height: 200), rotation: .counterclockwise))
  }

  @Test(arguments: [
    (CGRect(x: 50, y: -50, width: 200, height: 300), -90, 0.0),
    (CGRect(x: 60, y: 10, width: 120, height: 80), -270, 0.0),
    (CGRect(x: 40, y: 30, width: 90, height: 140), -180, 0.0),
    (CGRect(x: 70, y: 20, width: 110, height: 150), -90, 0.12),
    // Odd w − h: the converted origin lies on a half pixel.
    (CGRect(x: 100, y: 50, width: 81, height: 100), -90, 0.0),
    (CGRect(x: 60, y: 10, width: 121, height: 80), -270, 0.0),
    (CGRect(x: 70, y: 20, width: 111, height: 150), -90, 0.12),
  ])
  func convertedSchemaTwoCropRendersLike5_1(frame: CGRect, rotation: Int, straightenRadians: Double) throws {
    let source = Self.makeSource(size: CGSize(width: 300, height: 200))
    let stored = Stored5xCrop(
      isEnabled: true,
      cropRect: frame,
      rotation: rotation,
      straightenRadians: straightenRadians
    )

    let crop = try #require(try makeCrop(schema: 2, stored: stored))
    let converted = try crop.apply(to: source, context: .init())
    let legacy = Self.render5_1(source: source, stored: stored)

    // 5.1.0 output kept the stored frame's size at every rotation.
    #expect(converted.extent == CGRect(origin: .zero, size: frame.size))
    #expect(legacy.extent == converted.extent)
    let tolerance = straightenRadians == 0 ? 0 : 1
    #expect(Self.maximumDifference(Self.pixels(converted), Self.pixels(legacy)) <= tolerance)
  }

  @Test
  func schemaOneAndThreeKeepTheStoredRectangle() throws {
    let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
    let v1 = Stored5xCrop(isEnabled: true, cropRect: rect, rotation: nil, straightenRadians: nil)
    let v3 = Stored5xCrop(isEnabled: true, cropRect: rect, rotation: -90, straightenRadians: 0)

    #expect(try makeCrop(schema: 1, stored: v1) == CropFeature(cropRect: rect))
    #expect(try makeCrop(schema: 3, stored: v3) == CropFeature(cropRect: rect, rotation: .counterclockwise))
  }

  @Test
  func disabledAndUnknownCropsAreHandled() throws {
    let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
    #expect(try makeCrop(schema: 2, stored: .init(isEnabled: false, cropRect: rect)) == nil)
    #expect(throws: CropConversionError.self) {
      try makeCrop(schema: 4, stored: .init(isEnabled: true, cropRect: rect))
    }
    #expect(throws: CropConversionError.self) {
      try makeCrop(schema: 2, stored: .init(isEnabled: true, cropRect: rect, rotation: 45))
    }
    #expect(throws: FeatureEvaluationError.self) {
      try makeCrop(schema: 2, stored: .init(isEnabled: true, cropRect: .init(x: 0, y: 0, width: 0, height: 10)))
    }
  }

  // MARK: - 5.1.0 oracle

  /// Schema 2 as 5.1.0 evaluated it: turn the whole input by
  /// `-(rotation + straighten)` about the frame's center, then cut the frame.
  private static func render5_1(source: CIImage, stored: Stored5xCrop) -> CIImage {
    let rect = stored.cropRect
    let quarter = Double(stored.rotation ?? 0) * .pi / 180
    let angle = CGFloat(-(quarter + (stored.straightenRadians ?? 0)))
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let turn = CGAffineTransform(translationX: center.x, y: center.y)
      .rotated(by: angle)
      .translatedBy(x: -center.x, y: -center.y)
    // Snap the exact quarter-turn coefficients, as Core Image would otherwise
    // resample by the floating-point error of cos/sin.
    let snapped = CGAffineTransform(
      a: turn.a.rounded(toPlaces: 12),
      b: turn.b.rounded(toPlaces: 12),
      c: turn.c.rounded(toPlaces: 12),
      d: turn.d.rounded(toPlaces: 12),
      tx: turn.tx.rounded(toPlaces: 9),
      ty: turn.ty.rounded(toPlaces: 9)
    )
    let canvas = CIImage(color: .clear).cropped(to: rect)
    return source.transformed(by: snapped)
      .composited(over: canvas)
      .cropped(to: rect)
      .transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
  }

  private static func makeSource(size: CGSize) -> CIImage {
    let width = Int(size.width), height = Int(size.height)
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let index = (y * width + x) * 4
        pixels[index] = UInt8((x * 7) % 256)
        pixels[index + 1] = UInt8((y * 11) % 256)
        pixels[index + 2] = UInt8((x * 3 + y * 5) % 256)
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

  private static func maximumDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
    zip(lhs, rhs).map { abs(Int($0) - Int($1)) }.max() ?? 0
  }
}

extension CGFloat {
  fileprivate func rounded(toPlaces places: Int) -> CGFloat {
    let scale = pow(10, CGFloat(places))
    return (self * scale).rounded() / scale
  }
}
