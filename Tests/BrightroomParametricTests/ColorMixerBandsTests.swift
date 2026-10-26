import CoreImage
import Foundation
import Testing

@testable import BrightroomParametric

@Suite("Color Mixer bands")
struct ColorMixerBandsTests {

  @Test
  func bandsHaveStableFixedOrder() {
    #expect(
      ColorMixerFeature.Band.allCases == [
        .red, .orange, .yellow, .green, .aqua, .blue, .purple, .magenta,
      ])
    #expect(ColorMixerFeature.Band.allCases.map(\.rawValue) == Array(0..<8))
  }

  @Test
  func valuesClampOnInitializationAndMutation() {
    var value = ColorMixerFeature.BandCorrection(hue: 101, saturation: -101, luminance: 200)
    #expect(value == ColorMixerFeature.BandCorrection(hue: 100, saturation: -100, luminance: 100))
    value.hue = -1_000
    value.saturation = 1_000
    value.luminance = -1_000
    #expect(value == ColorMixerFeature.BandCorrection(hue: -100, saturation: 100, luminance: -100))
  }

  @Test
  func typedSubscriptMutatesExactlyOneFixedSlot() {
    var adjustment = ColorMixerFeature.Bands.neutral
    adjustment[.aqua] = ColorMixerFeature.BandCorrection(hue: 25, saturation: 40, luminance: -10)
    #expect(adjustment.isIdentity == false)
    #expect(adjustment.aqua == adjustment[.aqua])
    for band in ColorMixerFeature.Band.allCases where band != .aqua {
      #expect(adjustment[band].isIdentity)
    }
  }

  @Test
  func neutralHasNoRenderPlanAndFeatureBypasses() throws {
    #expect(ColorMixerFeature.Bands.neutral.isIdentity)
    #expect(ColorMixerRenderPlan(bands: .neutral) == nil)
    #expect(ColorMixerFeature.RenderKey(activeBands: .neutral) == nil)
    let feature = ColorMixerFeature(bands: .neutral)
    #expect(feature.bands.isIdentity)
    #expect(feature.algorithm == .oklch)
    let image = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7))
      .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    #expect(try feature.apply(to: image, context: .init()) === image)
  }

  @Test
  func previewIdentityUsesTheNormalizedRenderParameters() throws {
    var first = ColorMixerFeature.Bands.neutral
    first.red.hue = 10
    var equivalent = ColorMixerFeature.Bands.neutral
    equivalent.red.hue = 10.0.nextUp
    var changed = ColorMixerFeature.Bands.neutral
    changed.red.hue = 11

    let firstIdentity = try #require(
      ColorMixerFeature.RenderKey(activeBands: first)
    )
    let equivalentIdentity = try #require(
      ColorMixerFeature.RenderKey(activeBands: equivalent)
    )
    let changedIdentity = try #require(
      ColorMixerFeature.RenderKey(activeBands: changed)
    )
    let explicitIdentity = try #require(
      ColorMixerFeature.RenderKey(activeBands: first, algorithm: .oklch)
    )

    #expect(
      ColorMixerFeature.RenderKey(activeBands: .neutral) == nil
    )
    #expect(firstIdentity.semanticVersion == ColorMixerRenderPlan.semanticVersion)
    #expect(firstIdentity.algorithm == .oklch)
    #expect(firstIdentity == equivalentIdentity)
    #expect(firstIdentity == explicitIdentity)
    #expect(Set([firstIdentity, explicitIdentity]).count == 1)
    #expect(firstIdentity != changedIdentity)
  }

  @Test
  func validatingInitializerKeepsInRangeValuesExactly() throws {
    let band = try #require(
      ColorMixerFeature.BandCorrection(validatingHue: -100, saturation: 100, luminance: 10.0.nextUp)
    )

    #expect(band.hue == -100)
    #expect(band.saturation == 100)
    #expect(band.luminance == 10.0.nextUp)
  }

  @Test(arguments: ["hue", "saturation", "luminance"], [101.0, (-100.0).nextDown])
  func validatingInitializerRejectsOutOfRangeAxes(_ axis: String, _ value: Double) {
    #expect(Self.validatedBand(replacing: axis, with: value) == nil)
  }

  @Test(arguments: [Double.nan, .infinity, -.infinity])
  func validatingInitializerRejectsNonfiniteAxes(_ value: Double) {
    for axis in ["hue", "saturation", "luminance"] {
      #expect(Self.validatedBand(replacing: axis, with: value) == nil)
    }
  }

  @Test
  func restoredFeatureRebuildsAuthoredValuesAndDerivedEnabledState() throws {
    let active = ColorMixerFeature(
      bands: .init(red: .init(hue: 10.0.nextUp, saturation: -45, luminance: 20)),
      algorithm: .oklch
    )
    let neutral = ColorMixerFeature(bands: .neutral)

    let restoredActive = try Self.restore(active)
    let restoredNeutral = try Self.restore(neutral)

    #expect(restoredActive == active)
    #expect(restoredActive.bands == active.bands)
    #expect(restoredActive.algorithm == .oklch)
    #expect(ColorMixerFeature.RenderKey(activeBands: restoredActive.bands) != nil)
    #expect(restoredNeutral == neutral)
    #expect(restoredNeutral.bands == .neutral)
    #expect(restoredNeutral.bands.isIdentity)
  }

  private static func validatedBand(replacing axis: String, with value: Double)
    -> ColorMixerFeature.BandCorrection?
  {
    ColorMixerFeature.BandCorrection(
      validatingHue: axis == "hue" ? value : 0,
      saturation: axis == "saturation" ? value : 0,
      luminance: axis == "luminance" ? value : 0
    )
  }

  /// Rebuilds a feature from the scalar values and algorithm identifier a
  /// host would store.
  private static func restore(_ feature: ColorMixerFeature) throws -> ColorMixerFeature {
    var adjustment = ColorMixerFeature.Bands.neutral
    for band in ColorMixerFeature.Band.allCases {
      let stored = feature.bands[band]
      adjustment[band] = try #require(
        ColorMixerFeature.BandCorrection(
          validatingHue: stored.hue,
          saturation: stored.saturation,
          luminance: stored.luminance
        )
      )
    }
    return ColorMixerFeature(
      bands: adjustment,
      algorithm: try #require(ColorMixerFeature.Algorithm(rawValue: feature.algorithm.rawValue))
    )
  }
}
