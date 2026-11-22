import BrightroomParametric
import CoreImage
import Foundation
import Testing

/// Public API only. Covers analytic spline behavior and authoring/rendering contracts.
@Suite("Point Curve", .serialized)
struct PointCurveTests {

  private static let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

  @Test func identityBypassAndAuthoredEquality() throws {
    let input = Self.image([SIMD4(0.2, 0.3, 0.4, 1)])
    let diagonal = try #require(ToneCurve(validating: [
      .init(input: 0, output: 0), .init(input: 0.5, output: 0.5), .init(input: 1, output: 1),
    ]))
    let feature = PointCurveFeature(curves: .init(master: diagonal, red: diagonal))
    #expect(feature != PointCurveFeature())
    #expect(try FeatureRenderer().makeImage(from: input, feature: feature) === input)
    #expect(PointCurveFeature(curves: feature.curves) == feature)
  }

  @Test func naturalSplineAndTransferFunction() throws {
    let curve = try #require(ToneCurve(validating: [
      .init(input: 0, output: 0), .init(input: 0.5, output: 0.75), .init(input: 1, output: 1),
    ]))
    // Natural boundary conditions give f(0.25) = 0.421875 exactly for these
    // three points. Input/output below are independently decoded with sRGB.
    let input = Self.image([SIMD4(0.050876088, 0.050876088, 0.050876088, 1)])
    for feature in [PointCurveFeature(curves: .init(master: curve)),
      PointCurveFeature(curves: .init(red: curve, green: curve, blue: curve))] {
      let pixels = try Self.render(input, feature)
      for value in pixels.prefix(3) {
        #expect(abs(value - 0.148718511) < 0.0003)
      }
    }
  }

  @Test func refinementRestoresAuthoredValuesAndKeepsIdentity() throws {
    let curves = PointCurveFeature.Curves()
    let input = Self.image([SIMD4(0.2, 0.3, 0.4, 1)])
    let refined = try #require(PointCurveFeature(validatingCurves: curves, refineSaturation: 0))
    #expect(refined != PointCurveFeature(curves: curves))
    #expect(try FeatureRenderer().makeImage(from: input, feature: refined) === input)
    for invalid in [-1.0, 101.0, .nan, .infinity] {
      #expect(PointCurveFeature(validatingCurves: curves, refineSaturation: invalid) == nil)
    }
    var edited = try Self.rgbFeature()
    let rgbOnly = try Self.render(input, edited)
    edited.refineSaturation = -1
    #expect(edited.refineSaturation == 0)
    #expect(try Self.render(input, edited) == rgbOnly)
    edited.refineSaturation = .nan
    #expect(edited.refineSaturation == 100)
  }

  @Test(arguments: [CGColorSpace.extendedLinearDisplayP3 as String, CGColorSpace.extendedLinearSRGB as String,
    CGColorSpace.displayP3 as String, CGColorSpace.sRGB as String], [0.0, 50.0, 100.0])
  func contextAlphaAndExtendedHeadroom(workingSpaceName: String, refinement: Double) throws {
    var curves = try Self.rgbFeature().curves
    curves.master = try #require(ToneCurve(validating: [
      .init(input: 0, output: 0), .init(input: 0.5, output: 0.35), .init(input: 1, output: 1),
    ]))
    let feature = PointCurveFeature(curves: curves, refineSaturation: refinement)
    let input = Self.image([SIMD4(0.2, 0.3, 0.1, 1), SIMD4(0.1, 0.15, 0.05, 0.5),
      SIMD4(1.5, 1.5, 1.5, 1), SIMD4(-0.1, -0.1, -0.1, 1), SIMD4(0, 0, 0, 0)])
    let result = try FeatureRenderer().makeImage(from: input, feature: feature)
    #expect(result.extent == input.extent)
    let actual = Self.read(result, workingSpace: CGColorSpace(name: workingSpaceName as CFString)!)
    let expected = Self.read(result, workingSpace: Self.space)
    #expect(actual.allSatisfy { $0.isFinite })
    for (value, reference) in zip(actual, expected) {
      #expect(abs(value - reference) < 0.002)
    }
    #expect(actual[3] == 1 && actual[7] == 0.5 && actual[19] == 0)
    for channel in 0..<3 {
      #expect(abs(actual[4 + channel] * 2 - actual[channel]) < 0.001)
      #expect(abs(actual[8 + channel] - 1.5) < 0.001)
      #expect(abs(actual[12 + channel] + 0.1) < 0.001)
    }
  }

  private static func rgbFeature() throws -> PointCurveFeature {
    func curve(midpoint: Double) throws -> ToneCurve {
      try #require(ToneCurve(validating: [
        .init(input: 0, output: 0), .init(input: 0.5, output: midpoint), .init(input: 1, output: 1),
      ]))
    }
    return try PointCurveFeature(curves: .init(
      red: curve(midpoint: 0.4),
      green: curve(midpoint: 0.6),
      blue: curve(midpoint: 0.7)
    ))
  }

  private static func image(_ pixels: [SIMD4<Float>]) -> CIImage {
    CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: pixels.count * 16,
      size: CGSize(width: pixels.count, height: 1), format: .RGBAf, colorSpace: space)
  }

  private static func render(_ input: CIImage, _ feature: PointCurveFeature) throws -> [Float] {
    read(try FeatureRenderer().makeImage(from: input, feature: feature), workingSpace: space)
  }

  private static func read(_ image: CIImage, workingSpace: CGColorSpace) -> [Float] {
    let context = CIContext(options: [.workingColorSpace: workingSpace, .workingFormat: CIFormat.RGBAf])
    var pixels = [Float](repeating: .nan, count: Int(image.extent.width) * 4)
    context.render(image, toBitmap: &pixels, rowBytes: pixels.count * 4,
      bounds: image.extent, format: .RGBAf, colorSpace: space)
    return pixels
  }
}
