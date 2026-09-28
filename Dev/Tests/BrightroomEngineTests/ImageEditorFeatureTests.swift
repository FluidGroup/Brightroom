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
      var crop = CropEditingState(cropFeature: document.crop, imageSize: imageSize)
      crop.updateCropExtent(CGRect(x: 10, y: 20, width: 200, height: 100))
      document.setCrop(crop)
      document.appendLocalBlurStroke(stroke)
      ImageEditor.Adjustment.exposure.apply(sliderValue: 50, to: &document.effects)
      return document
    }

    #expect(build() == build())
  }

  @Test func `setCrop with an equal state leaves the document equal`() {
    var document = ImageEditorFeature(imageSize: imageSize)
    var crop = CropEditingState(cropFeature: document.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 10, y: 20, width: 200, height: 100))
    crop.rotation = .counterclockwise90
    document.setCrop(crop)
    let edited = document

    // Re-committing the state read back from the document changes nothing.
    document.setCrop(CropEditingState(cropFeature: document.crop, imageSize: imageSize))
    #expect(document == edited)

    // Neither does committing the same state again.
    document.setCrop(crop)
    #expect(document == edited)
  }

  @Test func `a quarter turn of the full image keeps the whole image`() {
    let size = CGSize(width: 300, height: 200)
    var crop = CropEditingState(imageSize: size, cropRect: CGRect(origin: .zero, size: size))
    // What `EditingCanvasView.rotateCounterclockwise()` does: the output
    // orientation changes and the selection before the turn stays the whole
    // image.
    crop.rotation = .counterclockwise90

    var document = ImageEditorFeature(imageSize: size)
    document.setCrop(crop)

    #expect(document.crop.rect == CGRect(origin: .zero, size: size))
    #expect(document.crop.quarterTurn == .counterclockwise90 || document.crop.quarterTurn == .counterclockwise270)
    #expect(
      document.crop.outputGeometry(in: CGRect(origin: .zero, size: size)).outputBounds.size
        == CGSize(width: 200, height: 300)
    )
  }

  @Test func `setCrop stores the snapped rect`() {
    var document = ImageEditorFeature(imageSize: imageSize)
    var crop = CropEditingState(cropFeature: document.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 10.4, y: 20.6, width: 200.3, height: 100.2))
    crop.rotation = .counterclockwise90

    document.setCrop(crop)

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
    document.setCrop(crop)
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

  /// A host that stores the document's values and rebuilds it gets back the
  /// document the editor produced (the resume path).
  @Test func `A document rebuilt from the same values equals the edited one`() {
    let preset = FilterFeature(
      name: "P",
      id: "p",
      effects: [AnyImageEffect(ContrastFeature(value: 0.1))]
    )

    var edited = ImageEditorFeature(imageSize: imageSize)
    var crop = CropEditingState(cropFeature: edited.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 10, y: 20, width: 200, height: 100))
    crop.rotation = .counterclockwise90
    edited.setCrop(crop)
    edited.appendLocalBlurStroke(stroke)
    ImageEditor.Adjustment.exposure.apply(sliderValue: 50, to: &edited.effects)
    ImageEditor.Adjustment.vignette.apply(sliderValue: 60, to: &edited.effects)
    edited.effects.preset = preset

    let rebuilt = ImageEditorFeature(
      effects: .init(
        preset: FilterFeature(
          name: "P",
          id: "p",
          effects: [AnyImageEffect(ContrastFeature(value: 0.1))]
        ),
        exposure: ExposureFeature(ev: edited.effects.exposure!.ev),
        vignette: VignetteFeature(value: edited.effects.vignette!.value)
      ),
      localBlur: LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: [stroke]))) {
        GaussianBlurFeature(radius: .proportional(40))
      },
      crop: CropFeature(
        rect: edited.crop.rect,
        quarterTurn: edited.crop.quarterTurn,
        straightenRadians: edited.crop.straightenRadians
      )
    )

    #expect(rebuilt == edited)
    #expect(rebuilt.effects == edited.effects)
    #expect(rebuilt.localBlur == edited.localBlur)
    #expect(rebuilt.crop == edited.crop)
  }

  /// Members assigned directly compare equal to the ones the sliders create:
  /// nothing but their values decides equality.
  @Test func `Members assigned directly equal slider-created members`() {
    var sliderMade = ImageEditorFeature.Effects()
    ImageEditor.Adjustment.exposure.apply(sliderValue: 50, to: &sliderMade)
    ImageEditor.Adjustment.gaussianBlur.apply(sliderValue: 40, to: &sliderMade)

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
  /// the final crop. The oracle folds the leaves by hand, so it shares no
  /// builder or composite evaluation with the document.
  @Test func `Body evaluates effects, blur mask, and crop in order`() throws {
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
      try #require(effects.vignette),
    ]
    #expect(globalEffects.count == 13)

    let source = makeSource()
    let renderer = FeatureRenderer()
    let actual = try renderer.makeImage(from: source, feature: document)
    let expected = try renderer.makeImage(
      from: source,
      feature: SequentialFeatures(globalEffects + [localBlur, document.crop])
    )

    #expect(actual.extent == expected.extent)
    #expect(maxDifference(actual, expected) == 0)

    // The blur mask is authored before the crop: evaluating it after the crop
    // puts the stroke somewhere else.
    let blurAfterCrop = try renderer.makeImage(
      from: source,
      feature: SequentialFeatures(globalEffects + [document.crop, localBlur])
    )
    #expect(blurAfterCrop.extent == expected.extent)
    #expect(maxDifference(blurAfterCrop, expected) > 4)
  }

  // MARK: - Value substitutions (D5)

  @Test func `Value substitutions render the viewing positions`() throws {
    let document = makeFullDocument()
    let source = makeSource()
    let renderer = FeatureRenderer()

    // The canvas base: global effects only, over the whole source.
    let base = try renderer.makeImage(
      from: source,
      feature: document.withoutLocalBlur().withCropNeutralized(imageSize: imageSize)
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
      feature: document.withCropNeutralized(imageSize: imageSize)
    )
    let uncropped = try renderer.makeImage(
      from: source,
      feature: EffectsAndLocalBlur(effects: document.effects, localBlur: document.localBlur)
    )
    #expect(cropViewing.extent == uncropped.extent)
    #expect(maxDifference(cropViewing, uncropped) == 0)
  }

  // MARK: - Helpers

  /// A document with all 13 global effect members, a blur mask, and a rotated crop.
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
      parameter.apply(sliderValue: value, to: &document.effects)
    }
    document.effects.preset = FilterFeature(
      name: "P",
      id: "p",
      effects: [AnyImageEffect(ContrastFeature(value: 0.1))]
    )
    document.effects.sharpen = SharpenFeature(intensity: 0.4, radius: 1.5)
    document.effects.unsharpMask = UnsharpMaskFeature(intensity: 0.5, radius: 2)
    document.effects.fade = FadeFeature(intensity: 0.3)

    document.appendLocalBlurStroke(stroke)

    var crop = CropEditingState(cropFeature: document.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 30, y: 20, width: 300, height: 220))
    crop.rotation = .counterclockwise90
    document.setCrop(crop)
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
