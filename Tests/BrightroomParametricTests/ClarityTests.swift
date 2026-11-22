import BrightroomParametric
import CoreImage
import Testing

/// Public rendering checks for Clarity's authored amount, tiling, and alpha.
@Suite("Clarity")
struct ClarityTests {

  @Test
  func neutralAndRestoredAmounts() throws {
    let source = try RenderingFixtures.normalizedSource()
    for value in [0.0, .nan, .infinity, -.infinity] {
      #expect(try FeatureRenderer().makeImage(from: source, feature: ClarityFeature(amount: value)) === source)
    }
    var effect = ClarityFeature(amount: 110)
    #expect(effect.amount == 100)
    effect.amount = -110
    #expect(effect.amount == -100)
    #expect(ClarityFeature(validatingAmount: -100.1) == nil)
    #expect(ClarityFeature(validatingAmount: .nan) == nil)
    #expect(ClarityFeature(validatingAmount: 4) == ClarityFeature(amount: 4))
  }

  @Test
  func neighborhoodsMatchAcrossTilesAndUniformOpacity() throws {
    let source = try RenderingFixtures.normalizedSource()
      .cropped(to: CGRect(x: 0, y: 0, width: 240, height: 120))
    let half = source.applyingFilter("CIColorMatrix", parameters: [
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5),
    ])
    let tileBounds = CGRect(x: 94, y: 21, width: 52, height: 44)
    for amount in [-67.0, 27.0] {
      let feature = ClarityFeature(amount: amount)
      let full = try FeatureRenderer().makeImage(from: source, feature: feature)
      let translucent = try FeatureRenderer().makeImage(from: half, feature: feature)
      #expect(full.extent == source.extent)
      let pixels = RenderingFixtures.pixels(of: full)
      let halfPixels = RenderingFixtures.pixels(of: translucent)
      let opacityError = zip(pixels, halfPixels).map { abs($0 * 0.5 - $1) }.max()!
      #expect(opacityError < 0.001)
      let tile = RenderingFixtures.pixels(of: full.cropped(to: tileBounds))
      var tileError: Float = 0
      for row in 0..<Int(tileBounds.height) {
        let offset = (Int(full.extent.height - tileBounds.maxY) + row) * Int(full.extent.width) + Int(tileBounds.minX)
        for column in 0..<(Int(tileBounds.width) * 4) {
          tileError = max(tileError, abs(tile[row * Int(tileBounds.width) * 4 + column] - pixels[offset * 4 + column]))
        }
      }
      #expect(tileError < 0.001)
    }
  }
}
