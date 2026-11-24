import CoreGraphics
import Testing

import BrightroomParametric
@testable import BrightroomUI

/// How `ImageEditor.Adjustment` maps slider values onto the feature's members.
struct ImageEditorAdjustmentMappingTests {

  private static let imageSize = CGSize(width: 40, height: 20)

  /// The editor has no Tint control, so Warmth at neutral removes only the
  /// temperature: a tint the host authored stays.
  @Test func `An authored tint survives Warmth at 0`() {
    var feature = ImageEditorFeature(imageSize: Self.imageSize)
    feature.effects.whiteBalance = WhiteBalanceFeature(temperature: 900, tint: 12)

    ImageEditor.Adjustment.warmth.apply(sliderValue: 0, to: &feature)

    #expect(feature.effects.whiteBalance == WhiteBalanceFeature(temperature: 0, tint: 12))
    #expect(ImageEditor.Adjustment.warmth.sliderValue(in: feature) == 0)

    // Without a tint, white balance at neutral is removed.
    feature.effects.whiteBalance = WhiteBalanceFeature(temperature: 900)
    ImageEditor.Adjustment.warmth.apply(sliderValue: 0, to: &feature)

    #expect(feature.effects.whiteBalance == nil)
    #expect(feature == ImageEditorFeature(imageSize: Self.imageSize))
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
