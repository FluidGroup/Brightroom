import CoreGraphics
import CoreImage
import Testing

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

struct ImageEditorFeatureTests {

  private let imageSize = CGSize(width: 400, height: 300)

  private let stroke = BrushMask.Stroke(
    stampCenters: [CGPoint(x: 100, y: 220), CGPoint(x: 140, y: 220)],
    brush: .init(diameter: 60, hardness: 0.7, opacity: 1)
  )

  // MARK: - Value equality

  @Test func `Two default documents are equal`() {
    #expect(
      ImageEditorFeature(imageSize: imageSize)
        == ImageEditorFeature(imageSize: imageSize)
    )
    #expect(ImageEditorFeature.Effects() == ImageEditorFeature.Effects())
  }

  @Test func `Documents built through the same operations are equal`() {
    func build() -> ImageEditorFeature {
      var document = ImageEditorFeature(imageSize: imageSize)
      var crop = CropGuideState(cropFeature: document.crop, imageSize: imageSize)
      crop.updateCropExtent(CGRect(x: 10, y: 20, width: 200, height: 100))
      document.crop = crop.makeCropFeature()
      document.appendLocalBlurStroke(stroke)
      ImageEditor.Adjustment.exposure.apply(sliderValue: 50, to: &document)
      return document
    }

    #expect(build() == build())
  }

  @Test func `Committing an equal guide state leaves the document equal`() {
    var document = ImageEditorFeature(imageSize: imageSize)
    var crop = CropGuideState(cropFeature: document.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 10, y: 20, width: 200, height: 100))
    crop.rotation = .counterclockwise90
    document.crop = crop.makeCropFeature()
    let edited = document

    // Re-committing the state read back from the document changes nothing.
    document.crop = CropGuideState(cropFeature: document.crop, imageSize: imageSize).makeCropFeature()
    #expect(document == edited)

    // Neither does committing the same state again.
    document.crop = crop.makeCropFeature()
    #expect(document == edited)
  }

  @Test func `a quarter turn of the full image keeps the whole image`() {
    let size = CGSize(width: 300, height: 200)
    var crop = CropGuideState(imageSize: size, cropRect: CGRect(origin: .zero, size: size))
    // What `EditingCanvasView.rotateCounterclockwise()` does: the output
    // orientation changes and the selection before the turn stays the whole
    // image.
    crop.rotation = .counterclockwise90

    var document = ImageEditorFeature(imageSize: size)
    document.crop = crop.makeCropFeature()

    #expect(document.crop.rect == CGRect(origin: .zero, size: size))
    #expect(document.crop.quarterTurn == .counterclockwise90 || document.crop.quarterTurn == .counterclockwise270)
    #expect(
      document.crop.outputGeometry(in: CGRect(origin: .zero, size: size)).outputBounds.size
        == CGSize(width: 200, height: 300)
    )
  }

  @Test func `A committed guide state stores the snapped rect`() {
    var document = ImageEditorFeature(imageSize: imageSize)
    var crop = CropGuideState(cropFeature: document.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 10.4, y: 20.6, width: 200.3, height: 100.2))
    crop.rotation = .counterclockwise90

    document.crop = crop.makeCropFeature()

    // Pixel-aligned by CropFeature(topLeftRect:), the same way EditingCanvasView commits through.
    #expect(document.crop == CropFeature(
      topLeftRect: crop.cropExtent,
      imageSize: imageSize,
      quarterTurn: crop.rotation,
      straightenRadians: crop.adjustmentAngle.radians
    ))
    #expect(document.crop.rect == document.crop.rect.integral)
    #expect(document.crop.quarterTurn == .counterclockwise90 || document.crop.quarterTurn == .counterclockwise270)

    // An integral rect round-trips exactly through the y-up working space.
    crop.updateCropExtent(CGRect(x: 10, y: 20, width: 200, height: 100))
    document.crop = crop.makeCropFeature()
    #expect(
      document.crop.topLeftRect(imageSize: imageSize)
        == CGRect(x: 10, y: 20, width: 200, height: 100)
    )
    #expect(document.crop.rect == CGRect(x: 10, y: 180, width: 200, height: 100))
  }

  @Test func `First stroke seeds the default blur`() throws {
    var document = ImageEditorFeature(imageSize: imageSize)

    document.appendLocalBlurStroke(stroke)

    let localBlur = try #require(document.localBlur)
    #expect(localBlur.content == ImageEditorFeature.defaultLocalBlurContent)
    #expect(localBlur.content.radius == .proportional(40))
    #expect(localBlur.mask == .brush(BrushMask(strokes: [stroke])))

    // Later strokes append in place and keep the blur content.
    document.appendLocalBlurStroke(stroke)
    #expect(document.localBlurStrokes == [stroke, stroke])
    #expect(document.localBlur?.content == localBlur.content)
  }

  /// A blur whose mask is not a plain brush (a host may restore one) is not
  /// paintable: a stroke leaves the feature unchanged, without trapping in
  /// Debug, and the canvas never offers to paint it.
  @Test(arguments: MasksThatAreNotABrush.all)
  func `A stroke leaves a blur that is not a brush unchanged`(mask: Mask) {
    var document = ImageEditorFeature(imageSize: imageSize)
    document.localBlur = LocalAdjustmentFeature(mask: mask) {
      GaussianBlurFeature(radius: .absolute(12))
    }
    let before = document
    #expect(document.isLocalBlurPaintable == false)

    document.appendLocalBlurStroke(stroke)

    #expect(document == before)
    #expect(document.localBlurStrokes.isEmpty)
  }

  @Test func `A blur is paintable when absent or a brush`() {
    var document = ImageEditorFeature(imageSize: imageSize)
    #expect(document.isLocalBlurPaintable)

    document.appendLocalBlurStroke(stroke)
    #expect(document.isLocalBlurPaintable)

    document.localBlur?.mask = .inverted(.brush(BrushMask(strokes: [stroke])))
    #expect(document.isLocalBlurPaintable == false)

    document.localBlur = nil
    #expect(document.isLocalBlurPaintable)
  }

  /// A host that stores the document's values and rebuilds it gets back the
  /// document the editor produced (the resume path).
  @Test func `A document rebuilt from the same values equals the edited one`() {
    let preset = FilterFeature(
      name: "P",
      id: "p",
      effects: [AnyImageEffect(ContrastFeature(value: 0.1))]
    )

    var edited = ImageEditorFeature(imageSize: imageSize)
    var crop = CropGuideState(cropFeature: edited.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 10, y: 20, width: 200, height: 100))
    crop.rotation = .counterclockwise90
    edited.crop = crop.makeCropFeature()
    edited.appendLocalBlurStroke(stroke)
    ImageEditor.Adjustment.exposure.apply(sliderValue: 50, to: &edited)
    ImageEditor.Adjustment.vignette.apply(sliderValue: 60, to: &edited)
    edited.effects.preset = preset

    let rebuilt = ImageEditorFeature(
      effects: .init(
        preset: FilterFeature(
          name: "P",
          id: "p",
          effects: [AnyImageEffect(ContrastFeature(value: 0.1))]
        ),
        exposure: ExposureFeature(ev: edited.effects.exposure!.ev)
      ),
      localBlur: LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: [stroke]))) {
        GaussianBlurFeature(radius: .proportional(40))
      },
      crop: CropFeature(
        rect: edited.crop.rect,
        quarterTurn: edited.crop.quarterTurn,
        straightenRadians: edited.crop.straightenRadians
      ),
      vignette: VignetteFeature(value: edited.vignette!.value)
    )

    #expect(rebuilt == edited)
    #expect(rebuilt.effects == edited.effects)
    #expect(rebuilt.localBlur == edited.localBlur)
    #expect(rebuilt.crop == edited.crop)
    #expect(rebuilt.vignette == edited.vignette)
  }

  /// Members assigned directly compare equal to the ones the sliders create:
  /// nothing but their values decides equality.
  @Test func `Members assigned directly equal slider-created members`() {
    var sliderMadeFeature = ImageEditorFeature(imageSize: imageSize)
    ImageEditor.Adjustment.exposure.apply(sliderValue: 50, to: &sliderMadeFeature)
    ImageEditor.Adjustment.gaussianBlur.apply(sliderValue: 40, to: &sliderMadeFeature)
    let sliderMade = sliderMadeFeature.effects

    var assigned = ImageEditorFeature.Effects()
    assigned.exposure = ExposureFeature(ev: 0.9)
    assigned.gaussianBlur = GaussianBlurFeature(radius: .proportional(40))

    #expect(assigned == sliderMade)
    #expect(
      ImageEditorFeature.Effects(
        exposure: ExposureFeature(ev: 0.9),
        gaussianBlur: GaussianBlurFeature(radius: .proportional(40))
      ) == sliderMade
    )

    var document = ImageEditorFeature(imageSize: imageSize)
    document.effects = sliderMade
    var direct = ImageEditorFeature(imageSize: imageSize)
    direct.effects.exposure = ExposureFeature(ev: 0.9)
    direct.effects.gaussianBlur = GaussianBlurFeature(radius: .proportional(40))
    #expect(direct == document)
  }

  // MARK: - Evaluation order (D1)

  /// The document's `body` evaluates the global effects in `Effects`
  /// declaration order (the preset's effects first), then the blur mask, then
  /// the final crop, then the vignette. The oracle folds the leaves by hand,
  /// so it shares no builder or composite evaluation with the document.
  @Test func `Body evaluates effects, blur mask, crop, and vignette in order`() throws {
    let document = makeFullDocument()
    let effects = document.effects
    let localBlur = try #require(document.localBlur)
    let presetEffects: [any Feature] = try #require(effects.preset).effects.map { $0.base }
    let globalEffects: [any Feature] = presetEffects + [
      try #require(effects.exposure),
      try #require(effects.brightness),
      try #require(effects.whiteBalance),
      try #require(effects.highlights),
      try #require(effects.shadows),
      try #require(effects.saturation),
      try #require(effects.contrast),
      try #require(effects.sharpen),
      try #require(effects.unsharpMask),
      try #require(effects.gaussianBlur),
      try #require(effects.fade),
    ]
    #expect(globalEffects.count == 12)
    let vignette = try #require(document.vignette)

    let source = makeSource()
    let renderer = FeatureRenderer()
    let actual = try renderer.makeImage(from: source, feature: document)
    let expected = try renderer.makeImage(
      from: source,
      feature: SequentialFeatures(globalEffects + [localBlur, document.crop, vignette])
    )

    #expect(actual.extent == expected.extent)
    #expect(maxDifference(actual, expected) == 0)

    // The blur mask is authored before the crop: evaluating it after the crop
    // puts the stroke somewhere else.
    let blurAfterCrop = try renderer.makeImage(
      from: source,
      feature: SequentialFeatures(globalEffects + [document.crop, localBlur, vignette])
    )
    #expect(blurAfterCrop.extent == expected.extent)
    #expect(maxDifference(blurAfterCrop, expected) > 4)

    // The vignette is centred on the crop output: evaluating it before the
    // (off-centre) crop darkens other pixels.
    let vignetteBeforeCrop = try renderer.makeImage(
      from: source,
      feature: SequentialFeatures(globalEffects + [localBlur, vignette, document.crop])
    )
    #expect(vignetteBeforeCrop.extent == expected.extent)
    #expect(maxDifference(vignetteBeforeCrop, expected) > 4)
  }

  // MARK: - Value substitutions (D5)

  @Test func `Value substitutions render the viewing positions`() throws {
    let document = makeFullDocument()
    let source = makeSource()
    let renderer = FeatureRenderer()

    // The canvas base: global effects only, over the whole source. The
    // canvas draws the vignette inside the crop frame, after these.
    let base = try renderer.makeImage(
      from: source,
      feature: document.withoutLocalBlur().withoutVignette().withCropNeutralized(imageSize: imageSize)
    )
    let effectsOnly = try renderer.makeImage(from: source, feature: document.effects)
    #expect(base.extent == effectsOnly.extent)
    #expect(maxDifference(base, effectsOnly) == 0)

    // Crop editing views the effects and the blur mask, without the crop.
    struct EffectsAndLocalBlur: Feature {
      var effects: ImageEditorFeature.Effects
      var localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?
      var body: some Feature {
        effects
        localBlur
      }
    }
    let cropViewing = try renderer.makeImage(
      from: source,
      feature: document.withoutVignette().withCropNeutralized(imageSize: imageSize)
    )
    let uncropped = try renderer.makeImage(
      from: source,
      feature: EffectsAndLocalBlur(effects: document.effects, localBlur: document.localBlur)
    )
    #expect(cropViewing.extent == uncropped.extent)
    #expect(maxDifference(cropViewing, uncropped) == 0)
  }

  // MARK: - Helpers

  /// A document with all 12 global effect members, a blur mask, a rotated
  /// crop, and a vignette.
  private func makeFullDocument() -> ImageEditorFeature {
    var document = ImageEditorFeature(imageSize: imageSize)
    for (parameter, value) in [
      (ImageEditor.Adjustment.exposure, 40.0),
      (.brightness, 20),
      (.warmth, 30),
      (.highlights, 40),
      (.shadows, 30),
      (.saturation, -30),
      (.contrast, 25),
      (.gaussianBlur, 10),
      (.vignette, 60),
    ] {
      parameter.apply(sliderValue: value, to: &document)
    }
    document.effects.preset = FilterFeature(
      name: "P",
      id: "p",
      effects: [AnyImageEffect(ContrastFeature(value: 0.1))]
    )
    document.effects.sharpen = SharpenFeature(intensity: 0.4, radius: .proportional(1.5))
    document.effects.unsharpMask = UnsharpMaskFeature(intensity: 0.5, radius: .proportional(200))
    document.effects.fade = FadeFeature(intensity: 0.3)

    document.appendLocalBlurStroke(stroke)

    var crop = CropGuideState(cropFeature: document.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 30, y: 20, width: 300, height: 220))
    crop.rotation = .counterclockwise90
    document.crop = crop.makeCropFeature()
    return document
  }

  private func makeSource() -> CIImage {
    let extent = CGRect(origin: .zero, size: imageSize)
    let gradient = CIFilter(
      name: "CILinearGradient",
      parameters: [
        "inputPoint0": CIVector(x: 0, y: 0),
        "inputPoint1": CIVector(x: imageSize.width, y: imageSize.height),
        "inputColor0": CIColor(red: 0.8, green: 0.3, blue: 0.2),
        "inputColor1": CIColor(red: 0.1, green: 0.5, blue: 0.9),
      ]
    )!.outputImage!
    // A checkerboard gives the blur edges to change; a blur leaves a bare
    // linear gradient almost untouched.
    let checker = CIFilter(
      name: "CICheckerboardGenerator",
      parameters: [
        "inputCenter": CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.5),
        "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        "inputWidth": 16,
        "inputSharpness": 1,
      ]
    )!.outputImage!
    return checker.composited(over: gradient).cropped(to: extent)
  }

  private func maxDifference(_ lhs: CIImage, _ rhs: CIImage) -> Int {
    let context = CIContext()
    func bytes(_ image: CIImage) -> [UInt8] {
      let width = Int(image.extent.width)
      let height = Int(image.extent.height)
      var buffer = [UInt8](repeating: 0, count: width * height * 4)
      context.render(
        image,
        toBitmap: &buffer,
        rowBytes: width * 4,
        bounds: image.extent,
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
      )
      return buffer
    }
    return zip(bytes(lhs), bytes(rhs)).map { abs(Int($0) - Int($1)) }.max() ?? -1
  }
}
