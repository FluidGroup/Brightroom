import BrightroomParametric
import CoreImage
import Foundation
import Testing

/// Public API only. Pixel assertions cover independent Adobe observations and
/// an analytic spline control; no test calls the feature's private evaluator.
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

  @Test func rgbCurvesPredictIndependentAdobeSamples() throws {
    let input = Self.image(Self.adobeSamples.map(\.0))
    let actual = try Self.render(input, Self.rgbFeature())
    // Regression bound for these frozen observations, not universal parity.
    for (index, sample) in Self.adobeSamples.enumerated() {
      for channel in 0..<3 {
        #expect(abs(actual[index * 4 + channel] - sample.1[channel]) < 0.001)
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

  @Test(arguments: [0, 50, 100])
  func masterMatchesLightroomAtEachRefinement(amount: Int) throws {
    let curve = try #require(ToneCurve(validating: [
      .init(input: 0, output: 0), .init(input: 128.0 / 255, output: 160.0 / 255), .init(input: 1, output: 1),
    ]))
    // Original ProPhoto chart and three separate PV 15.4 exports decoded to
    // linear Display-P3. The third color reaches the upper ROMM gamut bound
    // at zero refinement. Negative P3 components in these samples are valid.
    let samples: [(input: SIMD4<Float>, adobe: [SIMD3<Float>])] = [
      (SIMD4(-0.04891186, -0.00486303, 0.35139352, 1), [
        SIMD3(-0.04506271, -0.00303847, 0.40054542), SIMD3(-0.05761972, -0.00499737, 0.45930240),
        SIMD3(-0.07132015, -0.00690806, 0.52275658)]),
      (SIMD4(0.14392553, 0.61840975, 0.03926284, 1), [
        SIMD3(0.23411009, 0.79669684, 0.08702258), SIMD3(0.23793401, 0.78692085, 0.09135273),
        SIMD3(0.24170227, 0.77719492, 0.09574074)]),
      (SIMD4(-0.04099320, 0.66501552, 0.94093931, 1), [
        SIMD3(0.13173017, 0.78229290, 1.01046407), SIMD3(0.14575289, 0.77291656, 0.99092859),
        SIMD3(0.15977916, 0.76354718, 0.97159296)]),
      (SIMD4(-0.02821539, 0.95590663, 0.48550025, 1), [
        SIMD3(0.00764176, 1.09922743, 0.58210522), SIMD3(0.08612215, 1.04777813, 0.59963769),
        SIMD3(0.16891865, 0.99689257, 0.61734056)]),
    ]
    let feature = PointCurveFeature(curves: .init(master: curve), refineSaturation: Double(amount))
    let actual = try Self.render(Self.image(samples.map(\.input)), feature)
    for (index, sample) in samples.enumerated() {
      for channel in 0..<3 {
        #expect(abs(actual[index * 4 + channel] - sample.adobe[amount / 50][channel]) < 0.001)
      }
    }
  }

  @Test(arguments: [CGColorSpace.extendedLinearDisplayP3 as String, CGColorSpace.extendedLinearSRGB as String,
    CGColorSpace.displayP3 as String, CGColorSpace.sRGB as String])
  func contextAlphaAndExtendedHeadroom(workingSpaceName: String) throws {
    var curves = try Self.rgbFeature().curves
    curves.master = try #require(ToneCurve(validating: [
      .init(input: 0, output: 0), .init(input: 0.5, output: 0.35), .init(input: 1, output: 1),
    ]))
    let feature = PointCurveFeature(curves: curves, refineSaturation: 50)
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
    func curve(_ values: [(Double, Double)]) throws -> ToneCurve {
      try #require(ToneCurve(validating: values.map { .init(input: $0.0 / 255, output: $0.1 / 255) }))
    }
    return try PointCurveFeature(curves: .init(
      red: curve([(0,0),(27,11),(58,39),(121,118),(185,195),(255,255)]),
      green: curve([(0,0),(25,11),(53,36),(128,128),(186,196),(255,255)]),
      blue: curve([(0,0),(32,16),(64,49),(130,130),(181,185),(219,225),(255,255)])
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

  // A10 RGB curves only; Lightroom Classic 15.6 / Camera Raw 18.7 / PV 15.4.
  // Input probe and reference hashes are retained in the A10 comparison report.
  // Values are linear Display-P3, including valid negative out-of-gamut values.
  private static let adobeSamples: [(SIMD4<Float>, SIMD3<Float>)] = [
    (SIMD4(0.050975401, 0.050975401, 0.050975401, 1), SIMD3(0.024887193, 0.029912220, 0.030481257)),
    (SIMD4(0.214500442, 0.214500442, 0.214500442, 1), SIMD3(0.209213123, 0.214607507, 0.213089094)),
    (SIMD4(0.523657322, 0.523657322, 0.523657322, 1), SIMD3(0.595851481, 0.587275803, 0.552501082)),
    (SIMD4(0.199408308, 0.054162942, 0, 1), SIMD3(0.171888709, 0.030588582, -0.000017603)),
    (SIMD4(0.373832971, 0.614825428, 0.054162942, 1), SIMD3(0.422961444, 0.683606565, 0.028196277)),
    (SIMD4(0.054162942, 0.261599183, 0.510052443, 1), SIMD3(0.017842248, 0.275426954, 0.538001895)),
    (SIMD4(0.261599183, 0.022298275, 0.928181946, 1), SIMD3(0.305870235, -0.009465970, 0.955767214)),
  ]
}
