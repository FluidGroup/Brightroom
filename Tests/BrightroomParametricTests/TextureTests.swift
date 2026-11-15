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
