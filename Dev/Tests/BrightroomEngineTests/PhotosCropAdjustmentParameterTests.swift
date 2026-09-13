import Testing

@testable import BrightroomParametric
@testable import BrightroomUI

struct PhotosCropAdjustmentParameterTests {

  @Test func `blur adjustment writes value-form gaussian blur`() {
    var effects = EffectPipeline()

    PhotosCropAdjustmentParameter.blur.apply(sliderValue: 40, to: &effects)

    let blur = effects.first(of: GaussianBlurFeature.self)
    #expect(blur?.radius == .editingStackFilterValue(40))
    #expect(PhotosCropAdjustmentParameter.blur.sliderValue(in: effects) == 40)
  }

  @Test func `blur adjustment removes gaussian blur at neutral value`() {
    var effects = EffectPipeline(effects: [
      GaussianBlurFeature(value: 40)
    ])

    PhotosCropAdjustmentParameter.blur.apply(sliderValue: 0, to: &effects)

    #expect(effects.first(of: GaussianBlurFeature.self) == nil)
  }

  @Test func `blur adjustment keeps photos crop effect order`() {
    var effects = EffectPipeline(effects: [
      VignetteFeature(value: 1)
    ])

    PhotosCropAdjustmentParameter.blur.apply(sliderValue: 40, to: &effects)

    #expect(effects.effects.count == 2)
    #expect(effects.effects[0] is GaussianBlurFeature)
    #expect(effects.effects[1] is VignetteFeature)
  }
}
