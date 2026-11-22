import CoreImage
import Testing

@testable import BrightroomParametric
@testable import BrightroomUI

struct ImageEditorAdjustmentTests {

  private let imageSize = CGSize(width: 64, height: 48)

  @Test func `effects initializer references remain source compatible`() {
    let original = ImageEditorFeature.Effects.init(
      preset:exposure:brightness:whiteBalance:highlights:shadows:saturation:contrast:
      sharpen:unsharpMask:gaussianBlur:fade:custom:
    )
    let grading = ImageEditorFeature.Effects.init(
      preset:exposure:brightness:whiteBalance:highlights:shadows:saturation:contrast:
      colorGrading:sharpen:unsharpMask:gaussianBlur:fade:custom:
    )

    #expect(original(nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, []) == .init())
    #expect(grading(nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, []) == .init())
    #expect(ImageEditorFeature.Effects(grain: nil) == .init())
  }

  @Test func `grain has dedicated controls and does not use the single value slider`() {
    #expect(ImageEditor.Adjustment.allCases.contains(.grain))
    #expect(ImageEditor.Adjustment.grain.sliderRange == nil)
    var feature = ImageEditorFeature(imageSize: imageSize)
    feature.effects.grain = .init(amount: 20, size: 42, roughness: 70, seed: 12)
    let initial = feature

    ImageEditor.Adjustment.grain.apply(sliderValue: 50, to: &feature)

    #expect(feature == initial)
  }

  @Test func `grain initializer composes grading and renders after spatial effects`() throws {
    let grain = GrainFeature.CameraRaw(amount: 60, size: 42, roughness: 70, seed: 12)
    let grading = ColorGradingFeature(global: .init(hue: 52, saturation: 30))
    let fade = FadeFeature(intensity: 0.4)
    let blur = GaussianBlurFeature(radius: .absolute(2))
    let custom = BrightnessFeature(value: 0.1)
    let effects = ImageEditorFeature.Effects(
      colorGrading: grading,
      gaussianBlur: blur,
      fade: fade,
      grain: grain,
      custom: [AnyImageEffect(custom)]
    )
    #expect(effects.grain == grain)
    #expect(effects.colorGrading == grading)

    let source = CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.8))
      .cropped(to: CGRect(origin: .zero, size: imageSize))
    let context = FeatureEvaluationContext().withChainEntryExtent(source.extent)
    let graded = try grading.apply(to: source, context: context)
    let blurred = try blur.apply(to: graded, context: context)
    let faded = try fade.apply(to: blurred, context: context)
    let grained = try grain.apply(to: faded, context: context)
    let expected = try custom.apply(to: grained, context: context)
    let actual = try effects.apply(to: source, context: context)
    let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    let expectedPixels = try #require(ciContext.createCGImage(expected, from: source.extent))
    let actualPixels = try #require(ciContext.createCGImage(actual, from: source.extent))
    #expect(expectedPixels.dataProvider?.data == actualPixels.dataProvider?.data)
  }

  @Test func `blur adjustment writes value-form gaussian blur`() {
    var feature = ImageEditorFeature(imageSize: imageSize)

    ImageEditor.Adjustment.gaussianBlur.apply(sliderValue: 40, to: &feature)

    #expect(feature.effects.gaussianBlur?.radius == .proportional(40))
    #expect(ImageEditor.Adjustment.gaussianBlur.sliderValue(in: feature) == 40)
  }

  @Test func `blur adjustment removes gaussian blur at neutral value`() {
    var feature = ImageEditorFeature(imageSize: imageSize)
    feature.effects.gaussianBlur = GaussianBlurFeature(radius: .proportional(40))

    ImageEditor.Adjustment.gaussianBlur.apply(sliderValue: 0, to: &feature)

    #expect(feature.effects.gaussianBlur == nil)
  }

  /// A slider write keeps the parameters the slider does not control.
  @Test func `existing effect is changed in place`() {
    var feature = ImageEditorFeature(imageSize: imageSize)
    feature.effects.whiteBalance = WhiteBalanceFeature(temperature: 900, tint: 12)

    ImageEditor.Adjustment.warmth.apply(sliderValue: 20, to: &feature)

    #expect(feature.effects.whiteBalance?.tint == 12)
    #expect(ImageEditor.Adjustment.warmth.sliderValue(in: feature) == 20)
  }

  /// The vignette is the feature's top-level member, after the crop; the
  /// slider writes it there and leaves the effects alone.
  @Test func `vignette adjustment writes the feature's vignette`() {
    var feature = ImageEditorFeature(imageSize: imageSize)

    ImageEditor.Adjustment.vignette.apply(sliderValue: 60, to: &feature)

    #expect(feature.vignette == VignetteFeature(value: 1.2))
    #expect(feature.effects == ImageEditorFeature.Effects())
    #expect(ImageEditor.Adjustment.vignette.sliderValue(in: feature) == 60)

    ImageEditor.Adjustment.vignette.apply(sliderValue: 0, to: &feature)

    #expect(feature.vignette == nil)
    #expect(ImageEditor.Adjustment.vignette.sliderValue(in: feature) == 0)
  }

  /// The order is the type's `body`, so writing a member cannot move it: a
  /// blur added after a fade still evaluates before it.
  @Test func `evaluation order is Effects body`() throws {
    let source = CIFilter(
      name: "CILinearGradient",
      parameters: [
        "inputPoint0": CIVector(x: 0, y: 0),
        "inputPoint1": CIVector(x: 64, y: 0),
        "inputColor0": CIColor(red: 0.2, green: 0.5, blue: 0.8),
        "inputColor1": CIColor(red: 0.9, green: 0.1, blue: 0.3),
      ]
    )!.outputImage!.cropped(to: CGRect(origin: .zero, size: imageSize))
    let context = FeatureEvaluationContext().withChainEntryExtent(source.extent)

    var feature = ImageEditorFeature(imageSize: imageSize)
    feature.effects.fade = FadeFeature(intensity: 0.4)
    ImageEditor.Adjustment.gaussianBlur.apply(sliderValue: 40, to: &feature)
    let effects = feature.effects

    let blur = try #require(effects.gaussianBlur)
    let fade = try #require(effects.fade)
    let expected = try fade.apply(
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
