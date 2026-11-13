import BrightroomParametric
import CoreImage
import Testing

/// Public rendering checks against isolated Lightroom Clarity settings on developed RGB.
@Suite("Clarity")
struct ClarityTests {

  @Test
  func neutralAndRestoredAmounts() throws {
    let source = lightroomColorLattice()
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
  func signedChangesFollowTheMeasuredColorPatch() throws {
    let source = lightroomColorLattice()
    // Linear-P3 red at (317, 210) on the 16-bit chart. Subtract each engine's
    // neutral, as in the comparison of the corresponding Lightroom exports.
    let index = (210 * 1024 + 317) * 4
    let neutral = RenderingFixtures.pixels(of: source)[index]
    for (amount, measured, tolerance): (Double, Float, Float) in [
      (-100, -0.14162, 0.015), (-50, -0.08085, 0.010), (4, 0.00704, 0.0018),
      (50, 0.08518, 0.012), (100, 0.16354, 0.022),
    ] {
      let output = try FeatureRenderer().makeImage(from: source, feature: ClarityFeature(amount: amount))
      #expect(abs(RenderingFixtures.pixels(of: output)[index] - neutral - measured) < tolerance)
    }
  }

  @Test
  func negativeClarityLiftsTheDarkSideOfTheRampBoundary() throws {
    let source = lightroomColorLattice()
    // The first eight rows of the lattice border a neutral gray ramp.
    // Lightroom's mean blue lift here is 0.01518 at −50 and 0.02996 at −100.
    let band = CGRect(x: 768, y: 120, width: 128, height: 8)
    let neutral = RenderingFixtures.pixels(of: source.cropped(to: band))
    for (amount, measured, tolerance): (Double, Float, Float) in [
      (-50, 0.01518, 0.008), (-100, 0.02996, 0.014),
    ] {
      let adjusted = try FeatureRenderer().makeImage(from: source, feature: ClarityFeature(amount: amount))
      let pixels = RenderingFixtures.pixels(of: adjusted.cropped(to: band))
      let blue = stride(from: 2, to: pixels.count, by: 4)
      let lift = blue.reduce(Float.zero) { $0 + (pixels[$1] - neutral[$1]) } / Float(pixels.count / 4)
      #expect(abs(lift - measured) < tolerance)
    }
  }

  @Test
  func neighborhoodsMatchAcrossTilesAndUniformOpacity() throws {
    let source = lightroomColorChart(width: 240, height: 120) { x, y, _, _ in
      SIMD3(x < 120 ? 0.2 : 0.8, Double(y) / 119, 0.3)
    }
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
