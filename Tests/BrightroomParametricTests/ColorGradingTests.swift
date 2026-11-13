import BrightroomParametric
import CoreImage
import Foundation
import Testing

/// Public API only: renders the same graph a host or the editing canvas uses.
/// Adobe samples are independent observations, not values from our curve model.
@Suite("Color Grading", .serialized)
struct ColorGradingTests {
  private static let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  private static let context = CIContext(options: [.workingColorSpace: space,
    .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

  @Test func neutralAndHueOnlyBypassExactly() throws {
    let image = Self.image([SIMD4(0.2, 0.4, 0.6, 1)])
    let hueOnly = ColorGradingFeature(shadows: .init(hue: 210), global: .init(hue: 52), blending: 80, balance: -90)
    #expect(hueOnly.isIdentity)
    #expect(try FeatureRenderer().makeImage(from: image, feature: hueOnly) === image)
    #expect(hueOnly.global.hue == 52)
  }

  @Test func finiteClampingAndValidation() {
    var value = ColorGradingFeature.Correction(hue: 500, saturation: -10, luminance: 200)
    #expect(value == .init(hue: 360, saturation: 0, luminance: 100))
    value.hue = .nan
    value.saturation = .infinity
    value.luminance = -.infinity
    #expect(value == .init())
    #expect(ColorGradingFeature.Correction(validatingHue: 361, saturation: 1, luminance: 0) == nil)
    #expect(ColorGradingFeature.Correction(validatingHue: .nan, saturation: 0, luminance: 0) == nil)
    #expect(ColorGradingFeature.Correction(validatingHue: 52.5, saturation: 33.3, luminance: -17.1)
      == .init(hue: 52.5, saturation: 33.3, luminance: -17.1))
    var grading = ColorGradingFeature(blending: 200, balance: -200)
    #expect(grading.blending == 100 && grading.balance == -100)
    grading.blending = .infinity
    grading.balance = .nan
    #expect(grading.blending == 0 && grading.balance == 0)
    #expect(ColorGradingFeature(validatingShadows: .init(), midtones: .init(), highlights: .init(),
      global: .init(), blending: 101, balance: 0) == nil)
  }

  @Test func globalIsIndependentOfRangeControlsAndHueWraps() throws {
    let input = Self.image([SIMD4(0.1, 0.2, 0.3, 1), SIMD4(0.7, 0.5, 0.2, 1)])
    let first = ColorGradingFeature(global: .init(hue: 0, saturation: 35, luminance: 12))
    let second = ColorGradingFeature(global: .init(hue: 360, saturation: 35, luminance: 12), blending: 0, balance: 100)
    let firstPixels = try Self.render(input, first)
    let secondPixels = try Self.render(input, second)
    #expect(firstPixels == secondPixels)
  }

  @Test(arguments: ColorGradingFeature.Range.allCases)
  func alphaExtentAndExtendedValuesStayFinite(range: ColorGradingFeature.Range) throws {
    let input = Self.image([SIMD4(-0.1, 1.5, 0.4, 1), SIMD4(0.03, 0.1, 0.2, 0.5), SIMD4(0, 0, 0, 0)])
    var grading = ColorGradingFeature(blending: 72, balance: -35)
    grading[range] = .init(hue: 211, saturation: 40, luminance: 20)
    let output = try FeatureRenderer().makeImage(from: input, feature: grading)
    #expect(output.extent == input.extent)
    let pixels = Self.read(output)
    #expect(pixels.allSatisfy { $0.isFinite })
    #expect(abs(pixels[3] - 1) < 0.00001)
    #expect(abs(pixels[7] - 0.5) < 0.00001)
    #expect(pixels[11] == 0)
    #expect(pixels[1] > 1, "Extended headroom must not be silently clipped")
  }

  @Test func tonalLuminanceUsesDifferentRegionsAndBalanceChangesThem() throws {
    let input = Self.image([0.02, 0.18, 0.8].map { SIMD4($0, $0, $0, 1) })
    let shadows = try Self.render(input, .init(shadows: .init(luminance: 50)))
    let highlights = try Self.render(input, .init(highlights: .init(luminance: 50)))
    #expect(shadows[0] > highlights[0])
    #expect(highlights[8] > shadows[8])
    let shifted = try Self.render(input, .init(shadows: .init(luminance: 50), balance: 75))
    #expect(zip(shifted, shadows).contains { abs($0 - $1) > 0.001 })
  }

  @Test func globalPredictsIndependentAdobeSamples() throws {
    let input = Self.image(Self.adobeSamples.map(\.0))
    let actual = try Self.render(input, .init(global: .init(hue: 289, saturation: 41, luminance: 27)))
    // A focused regression bound, not an assertion that all settings match.
    for (index, sample) in Self.adobeSamples.enumerated() {
      for channel in 0..<3 {
        #expect(abs(actual[index * 4 + channel] - sample.1[channel]) < 0.002)
      }
    }
  }

  private static func image(_ values: [SIMD4<Float>]) -> CIImage {
    CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: values.count * 16,
      size: CGSize(width: values.count, height: 1), format: .RGBAf, colorSpace: space)
  }

  private static func render(_ image: CIImage, _ grading: ColorGradingFeature) throws -> [Float] {
    read(try FeatureRenderer().makeImage(from: image, feature: grading))
  }

  private static func read(_ image: CIImage) -> [Float] {
    var values = [Float](repeating: .nan, count: Int(image.extent.width) * 4)
    let rowBytes = values.count * 4
    values.withUnsafeMutableBytes {
      context.render(image, toBitmap: $0.baseAddress!, rowBytes: rowBytes,
        bounds: image.extent, format: .RGBAf, colorSpace: space)
    }
    return values
  }

  // Lightroom Classic 15.6 / Camera Raw 18.7, PV 15.4; identical 16-bit P3
  // chart, ProPhoto 16-bit TIFF export. Global H289 S41 L27; no other edit.
  // Source/reference hashes and all 19 validation cases are recorded in the
  // comparison report. Values here are decoded to linear Display-P3.
  private static let adobeSamples: [(SIMD4<Float>, SIMD3<Float>)] = [
    (SIMD4(0.009976710, 0.009976710, 0.009976710, 1.000000000), SIMD3(0.014260249, 0.008281684, 0.014474925)),
    (SIMD4(0.050975401, 0.050975401, 0.050975401, 1.000000000), SIMD3(0.072194733, 0.042945161, 0.073046066)),
    (SIMD4(0.214500442, 0.214500442, 0.214500442, 1.000000000), SIMD3(0.285563171, 0.186669692, 0.286453128)),
    (SIMD4(0.523657322, 0.523657322, 0.523657322, 1.000000000), SIMD3(0.621763587, 0.482690841, 0.618812561)),
    (SIMD4(0.731183469, 0.009529255, 0.002496716, 1.000000000), SIMD3(0.845541775, -0.008313874, 0.004517607)),
    (SIMD4(0.054162942, 0.229281858, 0.054162942, 1.000000000), SIMD3(0.095915198, 0.206093296, 0.081718162)),
    (SIMD4(0.561012566, 0.296428531, 0.296428531, 1.000000000), SIMD3(0.661166072, 0.259785175, 0.382856876)),
    (SIMD4(0.084918790, 0.614825428, 0.793813586, 1.000000000), SIMD3(0.181198135, 0.575701594, 0.853372514)),
  ]
}
