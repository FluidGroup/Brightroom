import BrightroomParametric
import CoreImage
import Foundation
import Testing

/// Public rendering checks for the signed Camera Raw Dehaze slider.
@Suite("Dehaze")
struct DehazeTests {

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
  func signedAmountsFollowTheRegisteredChart() throws {
    let source = lightroomColorLattice()
    // A gray ramp and a green-blue patch from the 16-bit ProPhoto Lightroom
    // exports. Positions are top-down in the shared 1024 × 256 chart.
    for (amount, gray, color, tolerance): (Double, Float, SIMD3<Float>, Float) in [
      (-100, 0.84307, SIMD3(0.69927, 0.79032, 0.77132), 0.085),
      (-50, 0.56993, SIMD3(0.29575, 0.60983, 0.54681), 0.040),
      (9, 0.27802, SIMD3(0.00366, 0.40311, 0.31934), 0.009),
      (50, 0.15901, SIMD3(-0.06965, 0.33632, 0.25116), 0.040),
      (100, 0.03568, SIMD3(-0.08982, 0.23934, 0.17026), 0.055),
    ] {
      let result = try FeatureRenderer().makeImage(from: source, feature: DehazeFeature(amount: amount))
      let pixels = RenderingFixtures.pixels(of: result)
      #expect(abs(pixels[(32 * 1024 + 600) * 4] - gray) < tolerance)
      for channel in 0..<3 {
        #expect(abs(pixels[(204 * 1024 + 677) * 4 + channel] - color[channel]) < tolerance)
      }
    }
  }

  @Test
  func intermediateAmountsInterpolateTheMeasuredResponses() throws {
    let source = lightroomColorLattice()
    // This gray remains inside the SDR cube at both ends of these intervals.
    func green(_ amount: Double) throws -> Float {
      let output = try FeatureRenderer().makeImage(from: source, feature: DehazeFeature(amount: amount))
      return RenderingFixtures.pixels(of: output)[(32 * 1024 + 600) * 4 + 1]
    }
    for (lower, upper) in [(-100.0, -50.0), (9.0, 50.0)] {
      let left = try green(lower)
      let right = try green(upper)
      let halfway = try green((lower + upper) / 2)
      #expect(abs(left - right) > 0.05)
      #expect(abs(halfway - (left + right) / 2) < 0.001)
    }
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
