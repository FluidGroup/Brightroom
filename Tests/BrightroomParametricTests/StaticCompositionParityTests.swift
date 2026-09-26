//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import CoreImage
import CoreMedia
import Foundation
import Testing

/// Pixel parity between the identified model (`EditingDocument`, evaluated by
/// `FeatureGraphCompiler`) and statically composed `Feature` documents that
/// describe the same edit.
///
/// Both models evaluate the same built-in recipes, so equivalent documents must
/// produce the same pixels and the same extent. Every case also proves that
/// the edit under test is visible, so a member that one model skipped,
/// reordered, or resolved against another basis could not match by accident.
@Suite(.serialized)
struct StaticCompositionParityTests {

  private typealias Fixtures = StaticCompositionFixtures

  // MARK: - Global effects

  @Test func `a global effect chain matches the identified model`() throws {
    let source = try Fixtures.makeSource()
    let document = GlobalChainDocument()

    let identified = try Fixtures.renderer.makeImage(
      from: source,
      document: document.identifiedDocument
    )
    let composed = try Fixtures.renderer.makeImage(from: source, document: document)

    #expect(composed.extent == Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(identified, composed)
    Fixtures.expectVisiblyDifferent(composed, try Fixtures.normalizedSource())

    // Order is part of the edit: the same members reversed must not match.
    let reversed = EditingDocument(
      mainTree: MainTree(features: Array(document.identifiedDocument.mainTree.features.reversed()))
    )
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, document: reversed)
    )
  }

  // MARK: - Domain features

  @Test(arguments: [true, false])
  func `a value-form blur after a mid-chain crop resolves against the chain entry`(
    normalizesInputExtent: Bool
  ) throws {
    let source = try Fixtures.makeSource()
    let renderer = ParametricImageRenderer(
      compiler: FeatureGraphCompiler(
        options: .init(normalizesInputExtent: normalizesInputExtent)
      )
    )
    let document = MidChainCropBlurDocument()

    let identified = try renderer.makeImage(from: source, document: document.identifiedDocument)
    let composed = try renderer.makeImage(from: source, document: document)

    #expect(composed.extent == CGRect(origin: .zero, size: document.crop.cropRect.size))
    Fixtures.expectPixelsMatch(identified, composed)

    // The default basis is the chain entry, not the cropped domain the blur
    // receives.
    let entryExtent = normalizesInputExtent ? Fixtures.entryExtent : source.extent
    Fixtures.expectPixelsMatch(
      composed,
      try renderer.makeImage(from: source, document: document, radiusReferenceExtent: entryExtent)
    )
    Fixtures.expectVisiblyDifferent(
      composed,
      try renderer.makeImage(
        from: source,
        document: document,
        radiusReferenceExtent: CGRect(origin: .zero, size: document.crop.cropRect.size)
      )
    )

    // An explicit basis reaches both models alike.
    let viewportReference = CGRect(x: 0, y: 0, width: 960, height: 720)
    Fixtures.expectPixelsMatch(
      try renderer.makeImage(
        from: source,
        document: document.identifiedDocument,
        radiusReferenceExtent: viewportReference
      ),
      try renderer.makeImage(
        from: source,
        document: document,
        radiusReferenceExtent: viewportReference
      )
    )
  }

  @Test func `a vignette after a crop matches the identified model`() throws {
    let source = try Fixtures.makeSource()
    let crop = CropFeature(cropRect: CGRect(x: 110, y: 20, width: 190, height: 200))
    let vignette = VignetteFeature(value: 0.9)

    struct Document: Feature {
      var crop: CropFeature
      var vignette: VignetteFeature

      var body: some Feature {
        crop
        vignette
      }
    }

    let identified = try Fixtures.renderer.makeImage(
      from: source,
      document: EditingDocument(mainTree: MainTree(features: [.domain(crop), .effect(vignette)]))
    )
    let composed = try Fixtures.renderer.makeImage(
      from: source,
      document: Document(crop: crop, vignette: vignette)
    )

    #expect(composed.extent == CGRect(origin: .zero, size: crop.cropRect.size))
    Fixtures.expectPixelsMatch(identified, composed)

    // The vignette centers on the cropped domain, so applying it before the
    // crop gives a different image.
    let vignetteBeforeCrop = try Fixtures.renderer.makeImage(
      from: source,
      document: EditingDocument(mainTree: MainTree(features: [.effect(vignette), .domain(crop)]))
    )
    Fixtures.expectVisiblyDifferent(composed, vignetteBeforeCrop)
  }

  @Test func `two crops match the identified model`() throws {
    let source = try Fixtures.makeSource()
    let document = TwoCropsDocument()

    let identified = try Fixtures.renderer.makeImage(
      from: source,
      document: document.identifiedDocument
    )
    let composed = try Fixtures.renderer.makeImage(from: source, document: document)

    #expect(composed.extent == CGRect(origin: .zero, size: document.second.cropRect.size))
    Fixtures.expectPixelsMatch(identified, composed)

    // The second crop works in the domain of the first one.
    var secondCropOnly = document
    secondCropOnly.first = nil
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, document: secondCropOnly)
    )
  }

  // MARK: - Local adjustments

  @Test(arguments: MaskShape.allCases)
  func `a masked blur matches the identified local adjustment`(shape: MaskShape) throws {
    let source = try Fixtures.makeSource()
    let document = MaskedBlurDocument(maskTree: shape.makeMaskTree())

    let identified = try Fixtures.renderer.makeImage(
      from: source,
      document: document.identifiedDocument
    )
    let composed = try Fixtures.renderer.makeImage(from: source, document: document)

    #expect(composed.extent == Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(identified, composed)

    var withoutMask = document
    withoutMask.blurMask = nil
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, document: withoutMask)
    )
  }

  // MARK: - Color features

  @Test func `tone curve, color mixer, and color cube match the identified model`() throws {
    let source = try Fixtures.makeSource()
    let document = ColorGradingDocument()

    #expect(document.toneCurve?.isEnabled == true)
    #expect(document.colorMixer?.isEnabled == true)

    let identified = try Fixtures.renderer.makeImage(
      from: source,
      document: document.identifiedDocument
    )
    let composed = try Fixtures.renderer.makeImage(from: source, document: document)

    #expect(composed.extent == Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(identified, composed)

    // Each member contributes.
    var withoutCurve = document
    withoutCurve.toneCurve = nil
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, document: withoutCurve)
    )
    var withoutMixer = document
    withoutMixer.colorMixer = nil
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, document: withoutMixer)
    )
    var withoutCube = document
    withoutCube.colorCube = nil
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, document: withoutCube)
    )
  }

  // MARK: - Presets

  @Test func `a nested preset inside a composite effect matches the identified model`() throws {
    let source = try Fixtures.makeSource()
    let document = NestedPresetDocument()

    let identified = try Fixtures.renderer.makeImage(
      from: source,
      document: document.identifiedDocument
    )
    let composed = try Fixtures.renderer.makeImage(from: source, document: document)

    #expect(composed.extent == Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(identified, composed)

    // The inner preset contributes.
    var withoutInner = document
    withoutInner.look.preset.effects.removeAll { $0 is PresetFeature }
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, document: withoutInner)
    )

    // Both models still skip the disabled child of the inner preset; enabling
    // it is visible.
    var enabledFade = document
    enabledFade.look.preset = NestedPresetDocument.makeOuterPreset(innerFadeIsEnabled: true)
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, document: enabledFade)
    )
  }

  // MARK: - Builder composition

  @Test(arguments: CompositionVariant.allCases)
  func `optional, branch, loop, and array members match the flattened identified model`(
    variant: CompositionVariant
  ) throws {
    let source = try Fixtures.makeSource()
    let document = variant.document

    let identified = try Fixtures.renderer.makeImage(
      from: source,
      document: document.identifiedDocument
    )
    let composed = try Fixtures.renderer.makeImage(from: source, document: document)

    #expect(identified.extent == composed.extent)
    Fixtures.expectPixelsMatch(identified, composed)
    Fixtures.expectVisiblyDifferent(composed, try Fixtures.normalizedSource())
  }

  // MARK: - Export and video overloads

  @Test func `the export renderer overload matches the identified model`() throws {
    let source = try Fixtures.makeSource()
    let document = PhotosCropLikeDocument()
    let exportRenderer = ParametricExportRenderer()
    let options = ParametricExportRenderer.Options(
      workingFormat: .RGBAh,
      workingColorSpace: Fixtures.workingColorSpace
    )

    let identified = try exportRenderer.render(
      source: source,
      document: document.identifiedDocument,
      options: options
    )
    .cgImage
    let composed = try exportRenderer.render(
      source: source,
      document: document,
      options: options
    )
    .cgImage

    #expect(composed.width == Int(document.crop.cropRect.width))
    #expect(composed.height == Int(document.crop.cropRect.height))
    Fixtures.expectPixelsMatch(CIImage(cgImage: identified), CIImage(cgImage: composed))
  }

  @Test func `the video renderer overloads match the identified model`() throws {
    let source = try Fixtures.makeSource()
    let document = PhotosCropLikeDocument()
    let videoRenderer = ParametricVideoRenderer()
    let renderExtent = CGRect(x: 0, y: 0, width: 280, height: 200)
    let presentationTime = CMTime(value: 7, timescale: 30)

    let identified = try videoRenderer.makeFrameImage(
      from: source,
      document: document.identifiedDocument,
      renderExtent: renderExtent,
      presentationTime: presentationTime
    )
    let composed = try videoRenderer.makeFrameImage(
      from: source,
      document: document,
      renderExtent: renderExtent,
      presentationTime: presentationTime
    )

    #expect(composed.extent == renderExtent)
    Fixtures.expectPixelsMatch(identified, composed)

    let sourceRenderSize = Fixtures.sourceExtent.size
    let modes: [ParametricVideoRenderer.RenderSizeMode] = [
      .featureOutput,
      .source,
      .custom(CGSize(width: 64, height: 48)),
    ]
    for mode in modes {
      let identifiedSize = try videoRenderer.resolveRenderSize(
        sourceRenderSize: sourceRenderSize,
        document: document.identifiedDocument,
        mode: mode
      )
      let composedSize = try videoRenderer.resolveRenderSize(
        sourceRenderSize: sourceRenderSize,
        document: document,
        mode: mode
      )
      #expect(identifiedSize == composedSize, "\(mode)")
    }
    #expect(
      try videoRenderer.resolveRenderSize(
        sourceRenderSize: sourceRenderSize,
        document: document,
        mode: .featureOutput
      ) == document.crop.cropRect.size
    )
  }

  @Test func `the video composition overload matches the identified model`() async throws {
    let asset = try await Fixtures.makeVideoAsset(from: Fixtures.normalizedSource())
    defer {
      try? FileManager.default.removeItem(at: asset.url)
    }
    let document = PhotosCropLikeDocument()
    let videoRenderer = ParametricVideoRenderer()

    let identifiedComposition = try videoRenderer.makeVideoComposition(
      for: asset,
      document: document.identifiedDocument
    )
    let composedComposition = try videoRenderer.makeVideoComposition(
      for: asset,
      document: document
    )

    #expect(composedComposition.renderSize == document.crop.cropRect.size)
    #expect(composedComposition.renderSize == identifiedComposition.renderSize)

    // Decode the first frame through each composition, so the frame handler
    // runs as it does in playback and export.
    let identified = try await Fixtures.firstFrame(of: asset, composition: identifiedComposition)
    let composed = try await Fixtures.firstFrame(of: asset, composition: composedComposition)

    #expect(composed.width == Int(document.crop.cropRect.width))
    #expect(composed.height == Int(document.crop.cropRect.height))
    Fixtures.expectPixelsMatch(CIImage(cgImage: identified), CIImage(cgImage: composed))
  }
}

// MARK: - Documents

/// Every built-in global effect, in one chain.
private struct GlobalChainDocument: Feature {

  var exposure = ExposureFeature(value: 0.35)
  var brightness = BrightnessFeature(value: 0.04)
  var contrast = ContrastFeature(value: 0.18)
  var saturation = SaturationFeature(value: -0.25)
  var highlights = HighlightsFeature(value: 0.3)
  var shadows = ShadowsFeature(value: 0.4)
  var temperature = TemperatureFeature(value: 700, tint: 12)
  var tint = HighlightShadowTintFeature(
    highlightColor: ParametricRGBAColor(red: 1, green: 0.85, blue: 0.6, alpha: 0.08),
    shadowColor: ParametricRGBAColor(red: 0.1, green: 0.2, blue: 0.45, alpha: 0.1)
  )
  var sharpen = SharpenFeature(sharpness: 0.5, radius: 30)
  var unsharpMask = UnsharpMaskFeature(intensity: 0.6, radius: 0.4)
  var blur = GaussianBlurFeature(radius: 1.5)
  var fade = FadeFeature(intensity: 0.08)
  var vignette = VignetteFeature(value: 0.7)

  var body: some Feature {
    exposure
    brightness
    contrast
    saturation
    highlights
    shadows
    temperature
    tint
    sharpen
    unsharpMask
    blur
    fade
    vignette
  }

  var identifiedDocument: EditingDocument {
    EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(exposure),
          .effect(brightness),
          .effect(contrast),
          .effect(saturation),
          .effect(highlights),
          .effect(shadows),
          .effect(temperature),
          .effect(tint),
          .effect(sharpen),
          .effect(unsharpMask),
          .effect(blur),
          .effect(fade),
          .effect(vignette),
        ]
      )
    )
  }
}

/// A crop in the middle of the chain, followed by effects whose radii are
/// proportional to the image.
private struct MidChainCropBlurDocument: Feature {

  var exposure = ExposureFeature(value: 0.2)
  var crop = CropFeature(cropRect: CGRect(x: 40, y: 30, width: 160, height: 120))
  var blur = GaussianBlurFeature(value: 40)
  var sharpen = SharpenFeature(sharpness: 0.4, radius: 20)

  var body: some Feature {
    exposure
    crop
    blur
    sharpen
  }

  var identifiedDocument: EditingDocument {
    EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(exposure),
          .domain(crop),
          .effect(blur),
          .effect(sharpen),
        ]
      )
    )
  }
}

/// Two crops; the second one rotates by a quarter turn inside the first one's
/// straightened domain.
private struct TwoCropsDocument: Feature {

  var first: CropFeature? = CropFeature(
    cropRect: CGRect(x: 30, y: 20, width: 260, height: 200),
    straightenRadians: 0.08
  )
  var saturation = SaturationFeature(value: 0.3)
  var second = CropFeature(
    cropRect: CGRect(x: 20, y: 30, width: 180, height: 120),
    rotation: .quarterCW
  )
  var exposure = ExposureFeature(value: 0.1)

  var body: some Feature {
    first
    saturation
    second
    exposure
  }

  var identifiedDocument: EditingDocument {
    EditingDocument(
      mainTree: MainTree(
        features: (first.map { [MainFeature.domain($0)] } ?? []) + [
          .effect(saturation),
          .domain(second),
          .effect(exposure),
        ]
      )
    )
  }
}

/// The mask trees exercised by the masked-blur parity test.
enum MaskShape: String, CaseIterable, Sendable {

  /// A feathered brush united with a hard brush.
  case featheredBrush

  /// Everything outside a brush.
  case invertedBrush

  /// A brush with a smaller brush removed.
  case subtractedBrush

  /// The overlap of two brushes.
  case intersectedBrushes

  /// Builds the tree with fresh node identities, so the identified model's
  /// duplicate-ID validation accepts it.
  func makeMaskTree() -> MaskTree {
    typealias Fixtures = StaticCompositionFixtures
    switch self {
    case .featheredBrush:
      return Fixtures.featheredBrushMaskTree()
    case .invertedBrush:
      return MaskTree(root: .invert(.brush(BrushMask(strokes: [Fixtures.lowerLeftStroke]))))
    case .subtractedBrush:
      return MaskTree(
        root: .subtract(
          MaskSubtract(
            base: .brush(BrushMask(strokes: [Fixtures.lowerLeftStroke])),
            removing: .brush(BrushMask(strokes: [Fixtures.crossingStroke]))
          )
        )
      )
    case .intersectedBrushes:
      return MaskTree(
        root: .intersect([
          .brush(BrushMask(strokes: [Fixtures.lowerLeftStroke])),
          .feather(
            MaskFeather(
              input: .brush(BrushMask(strokes: [Fixtures.crossingStroke])),
              radius: 3
            )
          ),
        ])
      )
    }
  }
}

/// A global exposure, a masked blur, and a trailing contrast, in the shape a
/// PhotosCrop-like editor stores its blur mask.
private struct MaskedBlurDocument: Feature {

  var exposure = ExposureFeature(value: 0.15)
  var blurMask: LocalAdjustment<GaussianBlurFeature>?
  var contrast = ContrastFeature(value: 0.1)

  init(maskTree: MaskTree) {
    blurMask = LocalAdjustment(maskTree: maskTree) {
      GaussianBlurFeature(value: 40)
    }
  }

  var body: some Feature {
    exposure
    blurMask
    contrast
  }

  var identifiedDocument: EditingDocument {
    var features: [MainFeature] = [.effect(exposure)]
    if let blurMask {
      features.append(
        .localAdjustment(
          LocalAdjustmentFeature(
            maskTree: blurMask.maskTree,
            effectPipeline: EffectPipeline(effects: [blurMask.content]),
            blendMode: blurMask.blendMode
          )
        )
      )
    }
    features.append(.effect(contrast))
    return EditingDocument(mainTree: MainTree(features: features))
  }
}

/// Tone curve, color mixer, and a color cube.
private struct ColorGradingDocument: Feature {

  var toneCurve: ToneCurveFeature? = StaticCompositionFixtures.makeToneCurve()
  var colorMixer: ColorMixerFeature? = ColorMixerFeature(
    adjustment: ColorMixerAdjustment(
      red: .init(hue: 20, saturation: -30, luminance: 10),
      green: .init(hue: -25, saturation: 35, luminance: -15),
      magenta: .init(hue: 15, saturation: 20)
    )
  )
  var colorCube: ColorCubeFeature? = StaticCompositionFixtures.makeColorCube()

  var body: some Feature {
    toneCurve
    colorMixer
    colorCube
  }

  var identifiedDocument: EditingDocument {
    let effects: [(any ImageEffectFeatureType)?] = [toneCurve, colorMixer, colorCube]
    return EditingDocument(
      mainTree: MainTree(features: effects.compactMap { $0 }.map { .effect($0) })
    )
  }
}

/// A preset that contains another preset, evaluated inside a host composite.
private struct NestedPresetDocument: Feature {

  /// A host composite whose body holds a preset among other effects.
  struct Look: ImageEffect {

    var brightness = BrightnessFeature(value: 0.03)
    var preset: PresetFeature

    var body: some ImageEffect {
      brightness
      preset
    }
  }

  var look = Look(preset: NestedPresetDocument.makeOuterPreset(innerFadeIsEnabled: false))
  var vignette = VignetteFeature(value: 0.4)

  var body: some Feature {
    look
    vignette
  }

  var identifiedDocument: EditingDocument {
    EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(look.brightness),
          .effect(look.preset),
          .effect(vignette),
        ]
      )
    )
  }

  static func makeOuterPreset(innerFadeIsEnabled: Bool) -> PresetFeature {
    let inner = PresetFeature(
      name: "Inner",
      identifier: "static-composition-tests.inner",
      effects: [
        ContrastFeature(value: 0.25),
        SaturationFeature(value: -0.4),
        FadeFeature(isEnabled: innerFadeIsEnabled, intensity: 0.5),
      ]
    )
    return PresetFeature(
      name: "Outer",
      identifier: "static-composition-tests.outer",
      effects: [
        ExposureFeature(value: 0.2),
        inner,
        TemperatureFeature(value: -600),
      ]
    )
  }
}

/// A document that uses every control-flow shape of `FeatureBuilder`.
private struct ComposedDocument: Feature {

  var exposure: ExposureFeature?
  var fade: FadeFeature?
  var usesWarmBalance: Bool
  var sharpenPasses: [SharpenFeature]
  var catalog: [AnyImageEffect]
  var crop: CropFeature?

  var body: some Feature {
    exposure
    fade
    if usesWarmBalance {
      TemperatureFeature(value: 900, tint: 10)
    } else {
      TemperatureFeature(value: -900, tint: -10)
      ContrastFeature(value: 0.2)
    }
    for pass in sharpenPasses {
      pass
    }
    catalog
    if let crop {
      crop
    }
    if #available(iOS 18, macOS 15, *) {
      VignetteFeature(value: 0.5)
    }
  }

  var identifiedDocument: EditingDocument {
    var features: [MainFeature] = []
    if let exposure {
      features.append(.effect(exposure))
    }
    if let fade {
      features.append(.effect(fade))
    }
    if usesWarmBalance {
      features.append(.effect(TemperatureFeature(value: 900, tint: 10)))
    } else {
      features.append(.effect(TemperatureFeature(value: -900, tint: -10)))
      features.append(.effect(ContrastFeature(value: 0.2)))
    }
    features += sharpenPasses.map { .effect($0) }
    // The built-in effects in the catalog belong to both models. A dropped
    // entry would show up as a pixel mismatch.
    features += catalog.compactMap { $0.base as? any ImageEffectFeatureType }.map { .effect($0) }
    if let crop {
      features.append(.domain(crop))
    }
    if #available(iOS 18, macOS 15, *) {
      features.append(.effect(VignetteFeature(value: 0.5)))
    }
    return EditingDocument(mainTree: MainTree(features: features))
  }
}

/// The documents compared by the composition parity test.
enum CompositionVariant: String, CaseIterable, Sendable {

  /// Optional members present, the first branch, two loop passes, a data-driven
  /// catalog, and a crop.
  case everyMemberPresent

  /// Optional members absent, the second branch, no loop pass, an empty
  /// catalog, and no crop.
  case optionalMembersAbsent

  fileprivate var document: ComposedDocument {
    switch self {
    case .everyMemberPresent:
      ComposedDocument(
        exposure: ExposureFeature(value: 0.3),
        fade: FadeFeature(intensity: 0.1),
        usesWarmBalance: true,
        sharpenPasses: [
          SharpenFeature(sharpness: 0.3, radius: 10),
          SharpenFeature(sharpness: 0.2, radius: 25),
        ],
        catalog: [
          AnyImageEffect(SaturationFeature(value: 0.4)),
          AnyImageEffect(
            PresetFeature(
              name: "Catalog",
              identifier: "static-composition-tests.catalog",
              effects: [ContrastFeature(value: -0.1), BrightnessFeature(value: 0.05)]
            )
          ),
        ],
        crop: CropFeature(cropRect: CGRect(x: 16, y: 12, width: 240, height: 200))
      )
    case .optionalMembersAbsent:
      ComposedDocument(
        exposure: nil,
        fade: nil,
        usesWarmBalance: false,
        sharpenPasses: [],
        catalog: [],
        crop: nil
      )
    }
  }
}

/// The shape a PhotosCrop-like editor stores: global adjustments, an optional
/// preset, an optional blur mask, and the final crop.
private struct PhotosCropLikeDocument: Feature {

  var exposure = ExposureFeature(value: 0.25)
  var saturation = SaturationFeature(value: 0.2)
  var preset: PresetFeature? = PresetFeature(
    name: "Film",
    identifier: "static-composition-tests.film",
    effects: [ContrastFeature(value: 0.15), FadeFeature(intensity: 0.06)]
  )
  var blurMask: LocalAdjustment<GaussianBlurFeature>? = LocalAdjustment(
    maskTree: StaticCompositionFixtures.featheredBrushMaskTree()
  ) {
    GaussianBlurFeature(value: 40)
  }
  var crop = CropFeature(
    cropRect: CGRect(x: 24, y: 18, width: 250, height: 190),
    straightenRadians: 0.05
  )

  var body: some Feature {
    exposure
    saturation
    preset
    blurMask
    crop
  }

  var identifiedDocument: EditingDocument {
    var features: [MainFeature] = [.effect(exposure), .effect(saturation)]
    if let preset {
      features.append(.effect(preset))
    }
    if let blurMask {
      features.append(
        .localAdjustment(
          LocalAdjustmentFeature(
            maskTree: blurMask.maskTree,
            effectPipeline: EffectPipeline(effects: [blurMask.content]),
            blendMode: blurMask.blendMode
          )
        )
      )
    }
    features.append(.domain(crop))
    return EditingDocument(mainTree: MainTree(features: features))
  }
}
