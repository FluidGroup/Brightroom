import Foundation
import Testing

@testable import BrightroomParametric

@Suite("Color Mixer adjustment")
struct ColorMixerAdjustmentTests {

  @Test
  func bandsHaveStableFixedOrder() {
    #expect(
      ColorMixerBand.allCases == [
        .red, .orange, .yellow, .green, .aqua, .blue, .purple, .magenta,
      ])
    #expect(ColorMixerBand.allCases.map(\.rawValue) == Array(0..<8))
  }

  @Test
  func valuesClampOnInitializationAndMutation() {
    var value = ColorMixerBandAdjustment(hue: 101, saturation: -101, luminance: 200)
    #expect(value == ColorMixerBandAdjustment(hue: 100, saturation: -100, luminance: 100))
    value.hue = -1_000
    value.saturation = 1_000
    value.luminance = -1_000
    #expect(value == ColorMixerBandAdjustment(hue: -100, saturation: 100, luminance: -100))
  }

  @Test
  func typedSubscriptMutatesExactlyOneFixedSlot() {
    var adjustment = ColorMixerAdjustment.neutral
    adjustment[.aqua] = ColorMixerBandAdjustment(hue: 25, saturation: 40, luminance: -10)
    #expect(adjustment.isNeutral == false)
    #expect(adjustment.aqua == adjustment[.aqua])
    for band in ColorMixerBand.allCases where band != .aqua {
      #expect(adjustment[band].isNeutral)
    }
  }

  @Test
  func neutralHasNoRenderPlanAndFeatureIsDisabled() {
    #expect(ColorMixerAdjustment.neutral.isNeutral)
    #expect(ColorMixerRenderPlan(adjustment: .neutral) == nil)
    let feature = ColorMixerFeature(adjustment: .neutral)
    #expect(feature.isEnabled == false)
    #expect(feature.algorithm == .oklch)
    #expect(feature.id.rawValue == "brightroom.color-mixer")
  }

  @Test
  func previewIdentityUsesTheNormalizedRenderParameters() throws {
    var first = ColorMixerAdjustment.neutral
    first.red.hue = 10
    var equivalent = ColorMixerAdjustment.neutral
    equivalent.red.hue = 10.0.nextUp
    var changed = ColorMixerAdjustment.neutral
    changed.red.hue = 11

    let firstIdentity = try #require(
      ColorMixerRenderIdentity(activeAdjustment: first)
    )
    let equivalentIdentity = try #require(
      ColorMixerRenderIdentity(activeAdjustment: equivalent)
    )
    let changedIdentity = try #require(
      ColorMixerRenderIdentity(activeAdjustment: changed)
    )
    let explicitIdentity = try #require(
      ColorMixerRenderIdentity(activeAdjustment: first, algorithm: .oklch)
    )

    #expect(
      ColorMixerRenderIdentity(activeAdjustment: .neutral) == nil
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
      ColorMixerBandAdjustment(validatingHue: -100, saturation: 100, luminance: 10.0.nextUp)
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
      id: FeatureID(rawValue: "active-mixer"),
      adjustment: .init(red: .init(hue: 10.0.nextUp, saturation: -45, luminance: 20)),
      algorithm: .oklch
    )
    let neutral = ColorMixerFeature(id: FeatureID(rawValue: "neutral-mixer"), adjustment: .neutral)

    let restoredActive = try Self.restore(active)
    let restoredNeutral = try Self.restore(neutral)

    #expect(restoredActive == active)
    #expect(restoredActive.adjustment == active.adjustment)
    #expect(restoredActive.algorithm == .oklch)
    #expect(restoredActive.isEnabled)
    #expect(restoredNeutral == neutral)
    #expect(restoredNeutral.adjustment == .neutral)
    #expect(restoredNeutral.isEnabled == false)
  }

  private static func validatedBand(replacing axis: String, with value: Double)
    -> ColorMixerBandAdjustment?
  {
    ColorMixerBandAdjustment(
      validatingHue: axis == "hue" ? value : 0,
      saturation: axis == "saturation" ? value : 0,
      luminance: axis == "luminance" ? value : 0
    )
  }

  /// Rebuilds a feature from the scalar values and algorithm identifier a
  /// host would store.
  private static func restore(_ feature: ColorMixerFeature) throws -> ColorMixerFeature {
    var adjustment = ColorMixerAdjustment.neutral
    for band in ColorMixerBand.allCases {
      let stored = feature.adjustment[band]
      adjustment[band] = try #require(
        ColorMixerBandAdjustment(
          validatingHue: stored.hue,
          saturation: stored.saturation,
          luminance: stored.luminance
        )
      )
    }
    return ColorMixerFeature(
      id: FeatureID(rawValue: feature.id.rawValue),
      adjustment: adjustment,
      algorithm: try #require(ColorMixerFeature.Algorithm(rawValue: feature.algorithm.rawValue))
    )
  }
}
