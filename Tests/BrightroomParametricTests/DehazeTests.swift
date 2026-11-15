import BrightroomParametric
import CoreImage
import Foundation
import Testing

/// Public rendering checks for the signed Camera Raw Dehaze slider.
@Suite("Dehaze")
struct DehazeTests {

  @Test func standardRecipeUsesSimpleColorControls() throws {
    let input = try RenderingFixtures.makeSource()
    for amount in [-50.0, 50.0] {
      let expected = input.applyingFilter("CIColorControls", parameters: [
        kCIInputContrastKey: 1 + 0.5 * amount / 100,
        kCIInputSaturationKey: 1 + 0.1 * amount / 100,
      ])
      let actual = try FeatureRenderer().makeImage(from: input, feature: DehazeFeature(amount: amount))
      #expect(RenderingFixtures.maximumDifference(actual, expected) < 0.00001)
    }
  }

  @Test
  func neutralAndRestoredAmounts() throws {
    let source = lightroomColorLattice()
    var effect = DehazeFeature(amount: 101)
    #expect(effect.amount == 100)
    effect.amount = -101
    #expect(effect.amount == -100)
    for amount in [Double.nan, .infinity, -.infinity, 0] {
      effect.amount = amount
      #expect(try FeatureRenderer().makeImage(from: source, feature: effect) === source)
    }
    #expect(DehazeFeature(validatingAmount: -.infinity) == nil)
    #expect(DehazeFeature(validatingAmount: 100.1) == nil)
    #expect(DehazeFeature(validatingAmount: 9) == DehazeFeature(amount: 9))
  }

  @Test
  func neighborhoodsAreIndependentOfTheOutputTileAndUniformOpacity() throws {
    let source = lightroomColorChart(width: 192, height: 96) { x, y, _, _ in
      SIMD3(Double(x) / 191, Double(y) / 95, 0.3)
    }
    let half = source.applyingFilter("CIColorMatrix", parameters: [
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5),
    ])
    let extent = source.extent
    let roi = CGRect(x: 31, y: 23, width: 57, height: 41)
    for amount in [-75.0, 27.0] {
      let effect = DehazeFeature(amount: amount)
      let full = try FeatureRenderer().makeImage(from: source, feature: effect)
      let translucent = try FeatureRenderer().makeImage(from: half, feature: effect)
      #expect(full.extent == extent)
      let all = RenderingFixtures.pixels(of: full)
      let tile = RenderingFixtures.pixels(of: full.cropped(to: roi))
      let partial = RenderingFixtures.pixels(of: translucent)
      var opacityError: Float = 0
      var tileError: Float = 0
      for i in partial.indices {
        opacityError = max(opacityError, abs(partial[i] - all[i] * 0.5))
      }
      for y in 0..<Int(roi.height) {
        let fullOffset = (Int(extent.height - roi.maxY) + y) * Int(extent.width) + Int(roi.minX)
        for x in 0..<Int(roi.width) {
          for channel in 0..<4 {
            let difference = tile[(y * Int(roi.width) + x) * 4 + channel] - all[(fullOffset + x) * 4 + channel]
            tileError = max(tileError, abs(difference))
          }
        }
      }
      #expect(opacityError < 0.001)
      #expect(tileError < 0.001)
    }
  }
}
