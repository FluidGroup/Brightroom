import CoreGraphics
import Testing

import BrightroomParametric
@testable import BrightroomUI

/// How `ImageEditor.Adjustment` maps slider values onto the feature's members.
struct ImageEditorAdjustmentMappingTests {

  private static let imageSize = CGSize(width: 40, height: 20)

  @Test func `Tint writes the white balance tint and reads it back`() {
    var feature = ImageEditorFeature(imageSize: Self.imageSize)

    ImageEditor.Adjustment.tint.apply(sliderValue: 30, to: &feature)

    #expect(feature.effects.whiteBalance == WhiteBalanceFeature(temperature: 0, tint: 30))
    #expect(ImageEditor.Adjustment.tint.sliderValue(in: feature) == 30)
    #expect(ImageEditor.Adjustment.warmth.sliderValue(in: feature) == 0)

    ImageEditor.Adjustment.tint.apply(sliderValue: -45, to: &feature)

    #expect(feature.effects.whiteBalance == WhiteBalanceFeature(temperature: 0, tint: -45))
    #expect(ImageEditor.Adjustment.tint.sliderValue(in: feature) == -45)
  }

  @Test func `Neutral Warmth keeps the tint, and neutral Tint keeps the temperature`() {
    let balance = WhiteBalanceFeature(temperature: 900, tint: 12)
    var feature = ImageEditorFeature(imageSize: Self.imageSize)

    feature.effects.whiteBalance = balance
    ImageEditor.Adjustment.warmth.apply(sliderValue: 0, to: &feature)
    #expect(feature.effects.whiteBalance == WhiteBalanceFeature(temperature: 0, tint: 12))
    #expect(ImageEditor.Adjustment.tint.sliderValue(in: feature) == 12)

    feature.effects.whiteBalance = balance
    ImageEditor.Adjustment.tint.apply(sliderValue: 0, to: &feature)
    #expect(feature.effects.whiteBalance == WhiteBalanceFeature(temperature: 900, tint: 0))
    #expect(ImageEditor.Adjustment.warmth.sliderValue(in: feature) == 30)
  }

  @Test func `White balance is removed once temperature and tint are both neutral`() {
    var feature = ImageEditorFeature(imageSize: Self.imageSize)
    ImageEditor.Adjustment.warmth.apply(sliderValue: 20, to: &feature)
    ImageEditor.Adjustment.tint.apply(sliderValue: -40, to: &feature)
    #expect(feature.effects.whiteBalance == WhiteBalanceFeature(temperature: 600, tint: -40))

    ImageEditor.Adjustment.warmth.apply(sliderValue: 0, to: &feature)
    #expect(feature.effects.whiteBalance == WhiteBalanceFeature(temperature: 0, tint: -40))

    // Values under half a step are neutral.
    ImageEditor.Adjustment.tint.apply(sliderValue: 0.4, to: &feature)
    #expect(feature.effects.whiteBalance == nil)
    #expect(feature == ImageEditorFeature(imageSize: Self.imageSize))
  }

  /// A positive Black Point deepens the blacks, which `BlacksFeature` does
  /// with a negative amount.
  @Test func `Black Point stores the negated blacks amount and reads it back`() {
    var feature = ImageEditorFeature(imageSize: Self.imageSize)

    ImageEditor.Adjustment.blackPoint.apply(sliderValue: 30, to: &feature)

    #expect(feature.effects.blacks == BlacksFeature(amount: -30))
    #expect(ImageEditor.Adjustment.blackPoint.sliderValue(in: feature) == 30)

    ImageEditor.Adjustment.blackPoint.apply(sliderValue: -25, to: &feature)

    #expect(feature.effects.blacks == BlacksFeature(amount: 25))
    #expect(ImageEditor.Adjustment.blackPoint.sliderValue(in: feature) == -25)

    ImageEditor.Adjustment.blackPoint.apply(sliderValue: 0, to: &feature)

    #expect(feature.effects.blacks == nil)
    #expect(ImageEditor.Adjustment.blackPoint.sliderValue(in: feature) == 0)
  }

  @Test func `Texture and Clarity write their amounts one to one and are removed at neutral`() {
    var feature = ImageEditorFeature(imageSize: Self.imageSize)

    ImageEditor.Adjustment.texture.apply(sliderValue: 25, to: &feature)
    ImageEditor.Adjustment.clarity.apply(sliderValue: -60, to: &feature)

    #expect(feature.effects.texture == TextureFeature(amount: 25))
    #expect(feature.effects.clarity == ClarityFeature(amount: -60))
    #expect(ImageEditor.Adjustment.texture.sliderValue(in: feature) == 25)
    #expect(ImageEditor.Adjustment.clarity.sliderValue(in: feature) == -60)

    ImageEditor.Adjustment.texture.apply(sliderValue: 0, to: &feature)
    ImageEditor.Adjustment.clarity.apply(sliderValue: 0, to: &feature)

    #expect(feature.effects.texture == nil)
    #expect(feature.effects.clarity == nil)
    #expect(feature == ImageEditorFeature(imageSize: Self.imageSize))
  }

  @Test func `Adjust mode lists its eleven parameters in their order`() {
    #expect(
      ImageEditor.Adjustment.adjustModeCases == [
        .exposure,
        .brightness,
        .contrast,
        .saturation,
        .colorGrading,
        .warmth,
        .highlights,
        .shadows,
        .gaussianBlur,
        .vignette,
        .grain,
      ]
    )
  }

  /// Reset removes them, so the editor counts them as effects.
  @Test func `Blacks, clarity and texture each count as an effect`() {
    let plain = ImageEditorFeature(imageSize: Self.imageSize)
    var blacks = plain
    blacks.effects.blacks = BlacksFeature(amount: -30)
    var clarity = plain
    clarity.effects.clarity = ClarityFeature(amount: 40)
    var texture = plain
    texture.effects.texture = TextureFeature(amount: 20)

    #expect(plain.hasAnyEffect == false)
    #expect(blacks.hasAnyEffect)
    #expect(clarity.hasAnyEffect)
    #expect(texture.hasAnyEffect)
  }
}
