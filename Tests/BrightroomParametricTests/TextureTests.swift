import BrightroomParametric
import CoreImage
import Testing

/// Public-API checks of the signed Texture response on developed RGB.
@Suite("Texture")
struct TextureTests {

  @Test
  func restoresTheCameraRawSliderAndBypassesNeutral() throws {
    let source = lightroomColorChart(width: 16, height: 12) { _, _, _, _ in .init(repeating: 0.5) }
    for amount in [0.0, .nan, .infinity, -.infinity] {
      #expect(try FeatureRenderer().makeImage(from: source, feature: TextureFeature(amount: amount)) === source)
    }
    var effect = TextureFeature(amount: 105)
    #expect(effect.amount == 100)
    effect.amount = -106
    #expect(effect.amount == -100)
    #expect(TextureFeature(validatingAmount: 4) == TextureFeature(amount: 4))
    #expect(TextureFeature(validatingAmount: -.infinity) == nil)
    #expect(TextureFeature(validatingAmount: 100.01) == nil)
  }

  /// Measures the fundamental of the 16-pixel-period patch in the registered frequency chart.
  private func relativeContrast(amount: Double, level: Double, amplitude: Double) throws -> Float {
    let source = lightroomColorChart(width: 192, height: 96) { x, _, _, _ in
      .init(repeating: level + amplitude * cos(Double(x) * .pi / 8))
    }
    func contrast(_ image: CIImage) -> Float {
      let strip = image.cropped(to: CGRect(x: 72, y: 47, width: 48, height: 1))
      let pixels = RenderingFixtures.pixels(of: strip)
      return (0..<48).reduce(Float.zero) { result, index in
        let linear = pixels[4 * index + 1]
        let code = 1.055 * pow(linear, 1 / 2.4) - 0.055
        return result + code * cos(Float(index + 72) * .pi / 8)
      } / 24
    }
    let result = try FeatureRenderer().makeImage(from: source, feature: TextureFeature(amount: amount))
    return contrast(result) / contrast(source) - 1
  }

  @Test
  func darkPatchTracksTheSignedContrastOfTheFrequencyChart() throws {
    for (amount, measured): (Double, Float) in [(-50, -0.287), (50, 0.348)] {
      let change = try relativeContrast(amount: amount, level: 0.25, amplitude: 0.06)
      #expect(abs(change - measured) < 0.10)
    }
  }

  @Test
  func weakMidtoneDetailRetainsItsPolarityAtStrongSettings() throws {
    // Self-normalized Lightroom contrast on the 0.5 ± 0.035 patch.
    for (amount, measured): (Double, Float) in [(-100, -0.633), (50, 0.459)] {
      let change = try relativeContrast(amount: amount, level: 0.5, amplitude: 0.035)
      #expect(abs(change - measured) < 0.09)
    }
  }

  @Test
  func transparentEdgesRetainTheirStraightColorAndAlpha() throws {
    let extent = CGRect(x: 24, y: -16, width: 96, height: 64)
    let foreground = CIImage(color: CIColor(red: 0.38, green: 0.57, blue: 0.24, alpha: 0.6))
      .cropped(to: extent.insetBy(dx: 22, dy: 16))
    let source = foreground.composited(over: CIImage(color: .clear).cropped(to: extent))
    let neutral = try FeatureRenderer().makeImage(from: source, feature: TextureFeature())
    let result = try FeatureRenderer().makeImage(from: source, feature: TextureFeature(amount: 75))
    #expect(result.extent == neutral.extent)
    #expect(RenderingFixtures.maximumDifference(result, neutral) < 0.001)
  }
}
