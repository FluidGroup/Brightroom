import BrightroomParametric
import CoreImage
import Foundation
import Testing

/// Public rendering checks for the global XMP Saturation slider.
@Suite("Measured global saturation")
struct SaturationApproximationTests {

  private static func image(_ pixels: [SIMD4<Float>]) -> CIImage {
    CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) },
      bytesPerRow: pixels.count * MemoryLayout<SIMD4<Float>>.stride,
      size: CGSize(width: pixels.count, height: 1), format: .RGBAf,
      colorSpace: RenderingFixtures.workingColorSpace)
  }

  @Test
  func zeroAndNonfiniteAmountsBypassAndLegacyEditsUseCoreImage() throws {
    let source = Self.image([SIMD4(0.05, 0.3, 1.1, 1)])
    for amount in [0.0, .nan, .infinity, -.infinity] {
      #expect(try FeatureRenderer().makeImage(from: source,
        feature: SaturationFeature(lightroomAmount: amount)) === source)
    }
    let legacy = SaturationFeature(value: -0.4)
    let measured = SaturationFeature(lightroomAmount: -40)
    #expect(legacy != measured)
    #expect(measured == SaturationFeature(value: -0.4, algorithm: .lightroomApproximation))
    let result = try FeatureRenderer().makeImage(from: source, feature: legacy)
    let reference = source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.6])
    #expect(RenderingFixtures.maximumDifference(result, reference) < 0.00001)
  }

  @Test
  func interpolatedAmountsFollowRegisteredLightroomExports() throws {
    // Six red-fastest lattice vertices from chart exports at two withheld strengths, in linear P3.
    // The yellow moves outside the P3 gamut after +5.
    let input: [SIMD4<Float>] = [
      SIMD4(0.01513312, 0.10338356, 0.46190000, 1), SIMD4(0.73118347, 0.12400001, 0.01513312, 1),
      SIMD4(0.17195027, 0.85946625, 0.10338356, 1), SIMD4(0.92818195, 0.73118347, 0.02229827, 1),
      SIMD4(0.12400001, 0.01513312, 0.92818195, 1), SIMD4(0.61482543, 0.19940831, 0.51005244, 1),
    ]
    let reduced: [SIMD4<Float>] = [
      SIMD4(0.02774052, 0.10374217, 0.41279393, 1), SIMD4(0.66761893, 0.14461438, 0.05085228, 1),
      SIMD4(0.28873351, 0.82813972, 0.23480828, 1), SIMD4(0.88838059, 0.73185021, 0.16880591, 1),
      SIMD4(0.12170308, 0.02060787, 0.86797261, 1), SIMD4(0.57397848, 0.22061804, 0.48482713, 1),
    ]
    let increased: [SIMD4<Float>] = [
      SIMD4(0.01148980, 0.10327531, 0.47644523, 1), SIMD4(0.75018257, 0.11808014, 0.00475053, 1),
      SIMD4(0.13639422, 0.86897141, 0.06318698, 1), SIMD4(0.93799299, 0.73105389, -0.01345376, 1),
      SIMD4(0.12476106, 0.01375358, 0.94414985, 1), SIMD4(0.62734598, 0.19281363, 0.51773494, 1),
    ]
    for (amount, expected, tolerance) in [(-16.0, reduced, Float(0.001)), (5.0, increased, Float(0.003))] {
      let result = try FeatureRenderer().makeImage(from: Self.image(input),
        feature: SaturationFeature(lightroomAmount: amount))
      #expect(RenderingFixtures.maximumDifference(result, Self.image(expected)) < tolerance)
    }
  }

  @Test
  func fullDesaturationPreservesNeutralHeadroomAndPremultipliedAlpha() throws {
    let opaque = SIMD4<Float>(-0.08, 0.4137, 1.27, 1)
    let source = Self.image([opaque, opaque * 0.35, .zero, SIMD4(1.3, 1.3, 1.3, 1)])
    let image = try FeatureRenderer().makeImage(from: source, feature: SaturationFeature(lightroomAmount: -100))
    #expect(image.extent == source.extent)
    let pixels = RenderingFixtures.pixels(of: image)
    #expect(abs(pixels[0] - pixels[1]) < 0.00001 && abs(pixels[1] - pixels[2]) < 0.00001)
    for channel in 0..<4 { #expect(abs(pixels[channel] * 0.35 - pixels[channel + 4]) < 0.00001) }
    #expect(pixels[8..<12].allSatisfy { $0 == 0 })
    #expect(abs(pixels[12] - 1.3) < 0.00001)
    let below = try FeatureRenderer().makeImage(from: source, feature: SaturationFeature(lightroomAmount: -150))
    #expect(RenderingFixtures.maximumDifference(image, below) == 0)
  }
}
