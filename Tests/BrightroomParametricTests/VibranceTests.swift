import BrightroomParametric
import CoreImage
import Testing

struct VibranceTests {

  @Test(arguments: [-100.0, -45, 30, 100])
  func signedAmountMatchesCoreImage(_ amount: Double) throws {
    let input = try RenderingFixtures.normalizedSource()
    let output = try FeatureRenderer().makeImage(from: input, feature: VibranceFeature(amount: amount))
    let expected = input.applyingFilter("CIVibrance", parameters: ["inputAmount": amount / 100])

    #expect(output.extent == input.extent)
    #expect(RenderingFixtures.maximumDifference(output, expected) < RenderingFixtures.tolerance)
    #expect(RenderingFixtures.maximumDifference(output, input) > RenderingFixtures.visibleDifference)
  }

  @Test func amountCanBeRestoredOrClamped() {
    for amount in [-100.0, -12.5, 0, 74, 100] {
      #expect(VibranceFeature(validatingAmount: amount)?.amount == amount)
    }
    var feature = VibranceFeature(amount: -120)
    #expect(feature.amount == -100)
    feature.amount = 120
    #expect(feature.amount == 100)
    for amount in [Double.nan, .infinity, -.infinity] {
      feature.amount = amount
      #expect(feature == VibranceFeature())
      #expect(VibranceFeature(validatingAmount: amount) == nil)
    }
    #expect(VibranceFeature(validatingAmount: -101) == nil)
    #expect(VibranceFeature(validatingAmount: 101) == nil)
  }
}
