import CoreGraphics
import CoreImage
import Testing

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

struct PhotosCropDocumentTests {

  private let imageSize = CGSize(width: 400, height: 300)

  private typealias MemberID = PhotosCropDocument.MemberID

  private let stroke = BrushMaskStroke(
    stamps: [CGPoint(x: 100, y: 220), CGPoint(x: 140, y: 220)],
    brush: .init(diameter: 60, hardness: 0.7, opacity: 1)
  )

  // MARK: - Identity (D7)

  @Test func `Two default documents are equal`() {
    #expect(
      PhotosCropDocument(orientedImageSize: imageSize)
        == PhotosCropDocument(orientedImageSize: imageSize)
    )
    #expect(PhotosCropDocument.Effects() == PhotosCropDocument.Effects())
  }

  @Test func `Documents built through the same operations are equal`() {
    func build() -> PhotosCropDocument {
      var document = PhotosCropDocument(orientedImageSize: imageSize)
      var crop = CropEditingState(cropFeature: document.crop, imageSize: imageSize)
      crop.updateCropExtent(CGRect(x: 10, y: 20, width: 200, height: 100))
      document.setCrop(crop)
      document.appendBlurMaskStroke(stroke)
      PhotosCropAdjustmentParameter.exposure.apply(sliderValue: 50, to: &document.effects)
      return document
    }

    #expect(build() == build())
  }

  @Test func `setCrop keeps the crop identity`() {
    var document = PhotosCropDocument(orientedImageSize: imageSize)
    var crop = CropEditingState(cropFeature: document.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 10, y: 20, width: 200, height: 100))
    crop.rotation = .angle_90

    document.setCrop(crop)

    #expect(document.crop.id == MemberID.crop)
    #expect(document.crop.rotation == .quarterCW || document.crop.rotation == .quarterCCW)
    #expect(
      document.crop.displayCropRect(imageSize: imageSize)
        == CGRect(x: 10, y: 20, width: 200, height: 100)
    )
  }

  @Test func `First stroke seeds the default blur with fixed identities`() throws {
    var document = PhotosCropDocument(orientedImageSize: imageSize)

    document.appendBlurMaskStroke(stroke)

    let blurMask = try #require(document.blurMask)
    #expect(blurMask.content.id == MemberID.blurMaskEffect)
    #expect(blurMask.content.radius == .editingStackFilterValue(40))
    guard case let .brush(brush) = blurMask.maskTree.root else {
      Issue.record("Expected a brush-rooted mask tree.")
      return
    }
    #expect(brush.id == MemberID.blurMaskBrush)

    // Later strokes append in place and keep the blur content.
    document.appendBlurMaskStroke(stroke)
    #expect(document.blurMaskStrokes == [stroke, stroke])
    #expect(document.blurMask?.content == blurMask.content)
  }

  @Test func `Rebuilding a document normalizes identities and drops disabled members`() {
    let restored = PhotosCropDocument(
      effects: .init(
        exposure: ExposureFeature(value: 0.9),
        vignette: VignetteFeature(isEnabled: false, value: 1)
      ),
      blurMask: LocalAdjustment(maskTree: MaskTree(root: .brush(BrushMask(strokes: [stroke])))) {
        GaussianBlurFeature(value: 40)
      },
      crop: CropFeature(displayCropRect: CGRect(origin: .zero, size: imageSize), imageSize: imageSize)
    )

    #expect(restored.effects.exposure?.id == MemberID.exposure)
    #expect(restored.effects.vignette == nil)
    #expect(restored.blurMask?.content.id == MemberID.blurMaskEffect)
    #expect(restored.crop.id == MemberID.crop)
    #expect(restored.crop == PhotosCropDocument(orientedImageSize: imageSize).crop)

    // A disabled blur content drops the whole blur mask.
    let disabledBlur = PhotosCropDocument(
      blurMask: LocalAdjustment(maskTree: MaskTree(root: .brush(BrushMask(strokes: [stroke])))) {
        GaussianBlurFeature(isEnabled: false, value: 40)
      },
      crop: CropFeature(displayCropRect: CGRect(origin: .zero, size: imageSize), imageSize: imageSize)
    )
    #expect(disabledBlur.blurMask == nil)
  }

  @Test func `Effects built through the initializer get fixed identities`() {
    let effects = PhotosCropDocument.Effects(
      exposure: ExposureFeature(value: 0.5),
      vignette: VignetteFeature(isEnabled: false, value: 1)
    )

    #expect(effects.exposure?.id == MemberID.exposure)
    #expect(effects.vignette == nil)
    #expect(effects == PhotosCropDocument.Effects(exposure: ExposureFeature(value: 0.5)))
  }

  /// Members assigned after construction bypass normalization; a disabled one
  /// still contributes nothing, as in the identified model.
  @Test func `Disabled members assigned directly render nothing`() throws {
    let source = makeSource()
    let renderer = ParametricImageRenderer()
    let plain = PhotosCropDocument(orientedImageSize: imageSize)

    var disabled = plain
    disabled.effects.exposure = ExposureFeature(isEnabled: false, value: 2)
    disabled.blurMask = LocalAdjustment(
      maskTree: MaskTree(root: .brush(BrushMask(strokes: [stroke])))
    ) {
      GaussianBlurFeature(isEnabled: false, value: 40)
    }

    let expected = try renderer.makeImage(from: source, document: plain)
    let rendered = try renderer.makeImage(from: source, document: disabled)
    #expect(rendered.extent == expected.extent)
    #expect(maxDifference(rendered, expected) == 0)
    #expect(disabled.normalized() == plain)
  }

  // MARK: - Evaluation order (D1)

  /// P2-only bridge: the document's `body` order equals the legacy canonical
  /// document (`[global effects in PhotosCropEffectOrder, local adjustment,
  /// final crop]`). Deleted with the old model in P3.
  @Test func `Body order equals the legacy canonical document`() throws {
    let document = makeFullDocument()

    let effects = document.effects
    let legacyEffects: [any ImageEffectFeatureType] = [
      effects.preset!,
      effects.exposure!,
      effects.brightness!,
      effects.temperature!,
      effects.highlights!,
      effects.shadows!,
      effects.saturation!,
      effects.contrast!,
      effects.sharpen!,
      effects.unsharpMask!,
      effects.gaussianBlur!,
      effects.fade!,
      effects.vignette!,
    ]
    let legacy = EditingDocument(
      mainTree: MainTree(features: [
        .effect(
          EffectPipelineFeature(
            id: FeatureID(rawValue: "legacy.effects"),
            pipeline: EffectPipeline(effects: legacyEffects)
          )
        ),
        .localAdjustment(
          LocalAdjustmentFeature(
            id: FeatureID(rawValue: "legacy.local-adjustment"),
            maskTree: document.blurMask!.maskTree,
            effectPipeline: EffectPipeline(effects: [document.blurMask!.content])
          )
        ),
        .domain(document.crop),
      ])
    )

    let source = makeSource()
    let renderer = ParametricImageRenderer()
    let actual = try renderer.makeImage(from: source, document: document)
    let expected = try renderer.makeImage(from: source, document: legacy)

    #expect(actual.extent == expected.extent)
    #expect(maxDifference(actual, expected) == 0)
  }

  // MARK: - Value substitutions (D5)

  @Test func `Value substitutions render the viewing positions`() throws {
    let document = makeFullDocument()
    let source = makeSource()
    let renderer = ParametricImageRenderer()

    // The canvas base: global effects only, over the whole source.
    let base = try renderer.makeImage(
      from: source,
      document: document.withoutBlurMask().withCropNeutralized(orientedImageSize: imageSize)
    )
    let effectsOnly = try renderer.makeImage(from: source, document: document.effects)
    #expect(base.extent == effectsOnly.extent)
    #expect(maxDifference(base, effectsOnly) == 0)

    // Crop editing views the effects and the blur mask, without the crop.
    struct EffectsAndBlurMask: Feature {
      var effects: PhotosCropDocument.Effects
      var blurMask: LocalAdjustment<GaussianBlurFeature>?
      var body: some Feature {
        effects
        blurMask
      }
    }
    let cropViewing = try renderer.makeImage(
      from: source,
      document: document.withCropNeutralized(orientedImageSize: imageSize)
    )
    let uncropped = try renderer.makeImage(
      from: source,
      document: EffectsAndBlurMask(effects: document.effects, blurMask: document.blurMask)
    )
    #expect(cropViewing.extent == uncropped.extent)
    #expect(maxDifference(cropViewing, uncropped) == 0)
  }

  // MARK: - Helpers

  /// A document with all 13 global effects, a blur mask, and a rotated crop.
  private func makeFullDocument() -> PhotosCropDocument {
    var document = PhotosCropDocument(orientedImageSize: imageSize)
    for (parameter, value) in [
      (PhotosCropAdjustmentParameter.exposure, 40.0),
      (.brightness, 20),
      (.temperature, 30),
      (.highlights, 40),
      (.shadows, 30),
      (.saturation, -30),
      (.contrast, 25),
      (.blur, 10),
      (.vignette, 60),
    ] {
      parameter.apply(sliderValue: value, to: &document.effects)
    }
    document.effects.preset = PresetFeature(
      id: FeatureID(rawValue: "test.preset"),
      name: "P",
      identifier: "p",
      effects: [ContrastFeature(id: FeatureID(rawValue: "test.preset.contrast"), value: 0.1)]
    )
    document.effects.sharpen = SharpenFeature(id: MemberID.sharpen, sharpness: 0.4, radius: 1.5)
    document.effects.unsharpMask = UnsharpMaskFeature(id: MemberID.unsharpMask, intensity: 0.5, radius: 2)
    document.effects.fade = FadeFeature(id: MemberID.fade, intensity: 0.3)

    document.appendBlurMaskStroke(stroke)

    var crop = CropEditingState(cropFeature: document.crop, imageSize: imageSize)
    crop.updateCropExtent(CGRect(x: 30, y: 20, width: 300, height: 220))
    crop.rotation = .angle_90
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
    return gradient.cropped(to: extent)
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
