import CoreImage
import Testing

@testable import BrightroomParametric
@testable import BrightroomUI

struct PhotosCropAdjustmentParameterTests {

  @Test func `blur adjustment writes value-form gaussian blur`() {
    var effects = PhotosCropDocument.Effects()

    PhotosCropAdjustmentParameter.blur.apply(sliderValue: 40, to: &effects)

    #expect(effects.gaussianBlur?.radius == .editingStackFilterValue(40))
    #expect(effects.gaussianBlur?.id == PhotosCropDocument.MemberID.gaussianBlur)
    #expect(PhotosCropAdjustmentParameter.blur.sliderValue(in: effects) == 40)
  }

  @Test func `blur adjustment removes gaussian blur at neutral value`() {
    var effects = PhotosCropDocument.Effects(
      gaussianBlur: GaussianBlurFeature(value: 40)
    )

    PhotosCropAdjustmentParameter.blur.apply(sliderValue: 0, to: &effects)

    #expect(effects.gaussianBlur == nil)
  }

  @Test func `existing effect is changed in place`() {
    var effects = PhotosCropDocument.Effects()
    PhotosCropAdjustmentParameter.exposure.apply(sliderValue: 50, to: &effects)
    let created = effects.exposure

    PhotosCropAdjustmentParameter.exposure.apply(sliderValue: 20, to: &effects)

    #expect(effects.exposure?.id == created?.id)
    #expect(PhotosCropAdjustmentParameter.exposure.sliderValue(in: effects) == 20)
  }

  /// The order is the type's `body`, so writing a member cannot move it: a
  /// blur added after a vignette still evaluates before it.
  @Test func `evaluation order is Effects body`() throws {
    let source = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8))
      .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
    let context = FeatureEvaluationContext().withRadiusReferenceExtent(source.extent)

    var effects = PhotosCropDocument.Effects(vignette: VignetteFeature(value: 1))
    PhotosCropAdjustmentParameter.blur.apply(sliderValue: 40, to: &effects)

    let blur = try #require(effects.gaussianBlur)
    let vignette = try #require(effects.vignette)
    let expected = try vignette.apply(
      to: try blur.apply(to: source, context: context),
      context: context
    )
    let actual = try effects.apply(to: source, context: context)

    let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    let expectedPixels = try #require(ciContext.createCGImage(expected, from: source.extent))
    let actualPixels = try #require(ciContext.createCGImage(actual, from: source.extent))
    #expect(expectedPixels.dataProvider?.data == actualPixels.dataProvider?.data)
  }
}
