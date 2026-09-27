//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import CoreImage
import CoreMedia
import Foundation
import Testing

/// Pixel behaviour of feature documents, checked against oracles
/// that do not share the code under test: explicit Core Image recipes, the
/// `SequentialFeatures` fold over primitive leaves, per-pixel mask algebra,
/// and invariants such as order sensitivity and locality.
///
/// Every case also proves that the edit under test is visible, so a member
/// that was skipped, reordered, or resolved against another basis could not
/// match by accident.
@Suite(.serialized)
struct CompositionRenderingTests {

  private typealias Fixtures = RenderingFixtures

  /// The largest channel difference accepted between a document and a recipe
  /// rebuilt from raw Core Image filters. The recipe builds the same filter
  /// graph, so real differences are orders of magnitude larger.
  private static let recipeTolerance: Float = 0.000_5

  // MARK: - Chain entry

  @Test func `a source with a non-zero origin renders as its zero-origin translation`() throws {
    let source = try Fixtures.makeSource()
    #expect(source.extent.origin != .zero)
    let translated = Fixtures.removingOffset(source)

    // The empty document shows the chain entry itself.
    let entry = try Fixtures.renderer.makeImage(from: source, feature: EmptyFeature())
    #expect(entry.extent == Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(translated, entry)

    // A document with crops and proportional radii renders the same from
    // either source.
    let document = MidChainCropBlurDocument()
    Fixtures.expectPixelsMatch(
      try Fixtures.renderer.makeImage(from: translated, feature: document),
      try Fixtures.renderer.makeImage(from: source, feature: document)
    )
  }

  // MARK: - Global effects

  @Test func `a global effect chain equals its members applied in order`() throws {
    let source = try Fixtures.makeSource()
    let document = GlobalChainDocument()

    let composed = try Fixtures.renderer.makeImage(from: source, feature: document)
    let folded = try Fixtures.renderer.makeImage(
      from: source,
      feature: SequentialFeatures(document.steps)
    )

    #expect(composed.extent == Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(folded, composed)
    Fixtures.expectVisiblyDifferent(composed, try Fixtures.normalizedSource())

    // Order is part of the edit: the same members reversed must not match.
    let reversed = try Fixtures.renderer.makeImage(
      from: source,
      feature: SequentialFeatures(document.steps.reversed())
    )
    Fixtures.expectVisiblyDifferent(composed, reversed)
  }

  // MARK: - Domain features

  @Test func `a value-form blur after a mid-chain crop resolves against the chain entry`() throws {
    let source = try Fixtures.makeSource()
    var document = MidChainCropBlurDocument()
    let croppedExtent = CGRect(origin: .zero, size: document.crop.cropRect.size)

    // Explicit recipe for exposure, crop, and blur: the blur radius is the
    // entry diagonal / 50, although the blur receives the cropped image.
    document.sharpen = nil
    let blurOnly = try Fixtures.renderer.makeImage(from: source, feature: document)
    let exposed = try Fixtures.normalizedSource()
      .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: document.exposure.value])
      .cropped(to: Fixtures.entryExtent)
    let cropped = Fixtures.removingOffset(exposed.cropped(to: document.crop.cropRect))
    let recipe = Fixtures.explicitValueBlur(cropped, value: 40, basis: Fixtures.entryExtent)
    #expect(blurOnly.extent == croppedExtent)
    Fixtures.expectPixelsMatch(recipe, blurOnly, tolerance: Self.recipeTolerance)
    Fixtures.expectVisiblyDifferent(blurOnly, cropped)

    // The default basis is the chain entry, not the cropped domain the blur
    // receives.
    document = MidChainCropBlurDocument()
    let composed = try Fixtures.renderer.makeImage(from: source, feature: document)
    #expect(composed.extent == croppedExtent)
    Fixtures.expectPixelsMatch(
      composed,
      try Fixtures.renderer.makeImage(
        from: source,
        feature: document,
        chainEntryExtent: Fixtures.entryExtent
      )
    )
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(
        from: source,
        feature: document,
        chainEntryExtent: croppedExtent
      )
    )

    // An explicit basis reaches every member.
    let viewportReference = CGRect(x: 0, y: 0, width: 960, height: 720)
    Fixtures.expectPixelsMatch(
      try Fixtures.renderer.makeImage(
        from: source,
        feature: SequentialFeatures(document.steps),
        chainEntryExtent: viewportReference
      ),
      try Fixtures.renderer.makeImage(
        from: source,
        feature: document,
        chainEntryExtent: viewportReference
      )
    )
  }

  @Test func `two crops evaluate in the current domain`() throws {
    let source = try Fixtures.makeSource()
    let normalized = try Fixtures.normalizedSource()

    // Axis-aligned crops: the second rectangle is relative to the first
    // crop's output.
    let first = CGRect(x: 30, y: 20, width: 260, height: 200)
    let second = CGRect(x: 20, y: 30, width: 180, height: 120)
    let axisAligned = try Fixtures.renderer.makeImage(
      from: source,
      feature: TwoCropsDocument(
        first: CropFeature(cropRect: first),
        second: CropFeature(cropRect: second)
      )
    )
    let recipe = Fixtures.removingOffset(
      Fixtures.removingOffset(normalized.cropped(to: first))
        .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
        .cropped(to: CGRect(origin: .zero, size: first.size))
        .cropped(to: second)
    )
    .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.1])
    .cropped(to: CGRect(origin: .zero, size: second.size))
    #expect(axisAligned.extent == CGRect(origin: .zero, size: second.size))
    Fixtures.expectPixelsMatch(recipe, axisAligned, tolerance: Self.recipeTolerance)

    // Straightened and quarter-turned crops.
    let document = TwoCropsDocument()
    let composed = try Fixtures.renderer.makeImage(from: source, feature: document)
    // The second crop turns a quarter, so its output exchanges the selection's
    // width and height.
    #expect(composed.extent == CGRect(
      origin: .zero,
      size: CGSize(width: document.second.cropRect.height, height: document.second.cropRect.width)
    ))
    Fixtures.expectPixelsMatch(
      try Fixtures.renderer.makeImage(from: source, feature: SequentialFeatures(document.steps)),
      composed
    )

    // The second crop works in the domain of the first one.
    var secondCropOnly = document
    secondCropOnly.first = nil
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, feature: secondCropOnly)
    )
  }

  // MARK: - Local adjustments

  @Test(arguments: MaskShape.allCases)
  func `a masked blur composites through its mask`(shape: MaskShape) throws {
    let source = try Fixtures.makeSource()
    let maskTree = shape.makeMaskTree()
    let document = MaskedBlurDocument(maskTree: maskTree)

    let composed = try Fixtures.renderer.makeImage(from: source, feature: document)
    #expect(composed.extent == Fixtures.entryExtent)

    // Explicit recipe: exposure, a raw blend of a raw blur through the
    // rendered mask, then contrast.
    let base = try Fixtures.normalizedSource()
      .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.15])
      .cropped(to: Fixtures.entryExtent)
    let blended = Fixtures.explicitBlend(
      adjusted: Fixtures.explicitValueBlur(base, value: 40, basis: Fixtures.entryExtent),
      base: base,
      mask: try Fixtures.renderer.makeMaskImage(for: maskTree, extent: Fixtures.entryExtent)
    )
    let recipe = blended
      .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1])
      .cropped(to: Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(recipe, composed, tolerance: Self.recipeTolerance)

    var withoutMask = document
    withoutMask.localBlur = nil
    let unmasked = try Fixtures.renderer.makeImage(from: source, feature: withoutMask)
    Fixtures.expectVisiblyDifferent(composed, unmasked)

    // Locality: where the mask covers nothing, the blur changes nothing.
    if let untouched = shape.untouchedRect {
      Fixtures.expectPixelsMatch(unmasked.cropped(to: untouched), composed.cropped(to: untouched))
    }
  }

  @Test(arguments: MaskShape.allCases)
  func `mask trees follow alpha algebra`(shape: MaskShape) throws {
    let extent = Fixtures.entryExtent
    func alpha(_ node: MaskNode) throws -> [Float] {
      Fixtures.alpha(of: try Fixtures.renderer.makeMaskImage(for: MaskTree(root: node), extent: extent))
    }
    func featheredAlpha(_ stroke: BrushMaskStroke, radius: Double) throws -> [Float] {
      let leaf = try Fixtures.renderer.makeMaskImage(
        for: MaskTree(root: .brush(BrushMask(strokes: [stroke]))),
        extent: extent
      )
      return Fixtures.alpha(
        of: leaf
          .clamped(to: extent)
          .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
          .cropped(to: extent)
      )
    }
    let lowerLeft = try alpha(.brush(BrushMask(strokes: [Fixtures.lowerLeftStroke])))
    let crossing = try alpha(.brush(BrushMask(strokes: [Fixtures.crossingStroke])))
    let upperRight = try alpha(.brush(BrushMask(strokes: [Fixtures.upperRightStroke])))

    let expected: [Float]
    switch shape {
    case .featheredBrush:
      let feathered = try featheredAlpha(Fixtures.lowerLeftStroke, radius: 6)
      expected = zip(feathered, upperRight).map { max($0, $1) }
    case .invertedBrush:
      expected = lowerLeft.map { 1 - $0 }
    case .subtractedBrush:
      expected = zip(lowerLeft, crossing).map { max($0 - $1, 0) }
    case .intersectedBrushes:
      let feathered = try featheredAlpha(Fixtures.crossingStroke, radius: 3)
      expected = zip(lowerLeft, feathered).map { $0 * $1 }
    }

    let actual = Fixtures.alpha(
      of: try Fixtures.renderer.makeMaskImage(for: shape.makeMaskTree(), extent: extent)
    )
    let difference = Fixtures.maximumDifference(expected, actual)
    #expect(difference <= 0.001, "max alpha difference \(difference)")

    // The shape covers part of the image, not all or nothing.
    #expect(actual.contains { $0 > 0.5 })
    #expect(actual.contains { $0 < 0.2 })
  }

  @Test func `brush stamps are working-space coordinates with a bottom-left origin`() throws {
    let extent = CGRect(x: 0, y: 0, width: 40, height: 50)
    let stamp = CGPoint(x: 20, y: extent.height * 0.2)
    let mask = try Fixtures.renderer.makeMaskImage(
      for: MaskTree(
        root: .brush(
          BrushMask(strokes: [
            BrushMaskStroke(
              stamps: [stamp],
              brush: BrushMaskBrush(diameter: 12, hardness: 1, opacity: 1)
            ),
          ])
        )
      ),
      extent: extent
    )

    // Read the mask back as a bitmap, whose first row is the top of the
    // image: the stamp near the bottom of a y-up image lights a row near the
    // end of the bitmap, and the mirrored row stays empty.
    let cgImage = try #require(Fixtures.context.createCGImage(mask, from: extent))
    let width = cgImage.width
    let height = cgImage.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let bitmap = try #require(
      CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    func alpha(row: Int) -> UInt8 {
      bytes[(row * width + Int(stamp.x)) * 4 + 3]
    }
    let stampRow = height - 1 - Int(stamp.y)
    let mirroredRow = Int(stamp.y)
    #expect(alpha(row: stampRow) > 250)
    #expect(alpha(row: mirroredRow) == 0)
  }

  // MARK: - Color features

  @Test func `color grading members apply in order and each contributes`() throws {
    let source = try Fixtures.makeSource()
    let document = ColorGradingDocument()

    let composed = try Fixtures.renderer.makeImage(from: source, feature: document)
    #expect(composed.extent == Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(
      try Fixtures.renderer.makeImage(from: source, feature: SequentialFeatures(document.steps)),
      composed
    )

    // Each member contributes.
    var withoutCurve = document
    withoutCurve.toneCurve = nil
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, feature: withoutCurve)
    )
    var withoutMixer = document
    withoutMixer.colorMixer = nil
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, feature: withoutMixer)
    )
    var withoutCube = document
    withoutCube.colorCube = nil
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, feature: withoutCube)
    )

    // Order matters.
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(
        from: source,
        feature: SequentialFeatures(document.steps.reversed())
      )
    )
  }

  // MARK: - Presets

  @Test func `a nested preset renders like its flattened effects`() throws {
    let source = try Fixtures.makeSource()
    let document = NestedPresetDocument()

    let composed = try Fixtures.renderer.makeImage(from: source, feature: document)
    #expect(composed.extent == Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(
      try Fixtures.renderer.makeImage(from: source, feature: FlattenedPresetDocument()),
      composed
    )

    // The inner preset contributes.
    var withoutInner = document
    withoutInner.look.preset.effects.removeAll { $0.base is PresetFeature }
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, feature: withoutInner)
    )

    // A fade added to the inner preset is visible.
    var withFade = document
    withFade.look.preset = NestedPresetDocument.makeOuterPreset(includesInnerFade: true)
    Fixtures.expectVisiblyDifferent(
      composed,
      try Fixtures.renderer.makeImage(from: source, feature: withFade)
    )
  }

  // MARK: - Builder composition

  @Test(arguments: CompositionVariant.allCases)
  func `builder control flow renders like the flattened steps`(variant: CompositionVariant) throws {
    let source = try Fixtures.makeSource()
    let document = variant.document

    let composed = try Fixtures.renderer.makeImage(from: source, feature: document)
    let folded = try Fixtures.renderer.makeImage(
      from: source,
      feature: SequentialFeatures(variant.flattenedSteps)
    )

    #expect(folded.extent == composed.extent)
    Fixtures.expectPixelsMatch(folded, composed)
    Fixtures.expectVisiblyDifferent(composed, try Fixtures.normalizedSource())
  }

  // MARK: - Export and video

  @Test func `export renders the image recipe`() throws {
    let source = try Fixtures.makeSource()
    let document = ImageEditorLikeFeature()
    let options = ExportRenderer.Options(
      outputFormat: .RGBAh,
      outputColorSpace: Fixtures.workingColorSpace
    )

    let exported = try ExportRenderer().render(
      from: source,
      feature: document,
      options: options
    )
    .cgImage

    // The same recipe, materialized with the export's working format and
    // working color space.
    let recipe = try Fixtures.renderer.makeImage(from: source, feature: document)
    let exportContext = CIContext(options: [
      .workingFormat: CIFormat.RGBAh,
      .workingColorSpace: Fixtures.workingColorSpace,
      .highQualityDownsample: true,
      .cacheIntermediates: false,
    ])
    let expected = try #require(
      exportContext.createCGImage(
        recipe,
        from: recipe.extent,
        format: .RGBAh,
        colorSpace: Fixtures.workingColorSpace,
        deferred: false
      )
    )

    #expect(exported.width == Int(document.crop.cropRect.width))
    #expect(exported.height == Int(document.crop.cropRect.height))
    Fixtures.expectPixelsMatch(CIImage(cgImage: expected), CIImage(cgImage: exported))
  }

  @Test func `video frames are the image recipe placed in the render extent`() throws {
    let source = try Fixtures.makeSource()
    let document = ImageEditorLikeFeature()
    let videoRenderer = VideoRenderer()
    let renderExtent = CGRect(x: 0, y: 0, width: 280, height: 200)
    let presentationTime = CMTime(value: 7, timescale: 30)

    let frame = try videoRenderer.makeImage(
      from: source,
      feature: document,
      renderExtent: renderExtent,
      presentationTime: presentationTime
    )
    let recipe = try Fixtures.renderer.makeImage(
      from: source,
      feature: document,
      presentationTime: presentationTime
    )
    let placed = recipe
      .composited(over: CIImage(color: .clear).cropped(to: renderExtent))
      .cropped(to: renderExtent)

    #expect(frame.extent == renderExtent)
    Fixtures.expectPixelsMatch(placed, frame)

    let sourceRenderSize = Fixtures.sourceExtent.size
    #expect(
      try videoRenderer.resolveRenderSize(
        sourceRenderSize: sourceRenderSize,
        feature: document,
        mode: .featureOutput
      ) == document.crop.cropRect.size
    )
    #expect(
      try videoRenderer.resolveRenderSize(
        sourceRenderSize: sourceRenderSize,
        feature: document,
        mode: .source
      ) == sourceRenderSize
    )
    let custom = CGSize(width: 64, height: 48)
    #expect(
      try videoRenderer.resolveRenderSize(
        sourceRenderSize: sourceRenderSize,
        feature: document,
        mode: .custom(custom)
      ) == custom
    )
  }

  @Test func `a video composition renders its document`() async throws {
    let asset = try await Fixtures.makeVideoAsset(from: Fixtures.normalizedSource())
    defer {
      try? FileManager.default.removeItem(at: asset.url)
    }
    let document = ImageEditorLikeFeature()
    let videoRenderer = VideoRenderer()

    let composition = try videoRenderer.makeVideoComposition(for: asset, feature: document)
    let foldedComposition = try videoRenderer.makeVideoComposition(
      for: asset,
      feature: SequentialFeatures(document.steps)
    )

    #expect(composition.renderSize == document.crop.cropRect.size)
    #expect(foldedComposition.renderSize == composition.renderSize)

    // Decode the first frame through each composition, so the frame handler
    // runs as it does in playback and export.
    let composed = try await Fixtures.firstFrame(of: asset, composition: composition)
    let folded = try await Fixtures.firstFrame(of: asset, composition: foldedComposition)

    #expect(composed.width == Int(document.crop.cropRect.width))
    #expect(composed.height == Int(document.crop.cropRect.height))
    Fixtures.expectPixelsMatch(CIImage(cgImage: folded), CIImage(cgImage: composed))

    // Both compositions share the frame handler, so the match above would
    // also hold for a handler that ignored the document. The document's
    // effects must be visible against the same crop alone.
    let cropOnly = try await Fixtures.firstFrame(
      of: asset,
      composition: videoRenderer.makeVideoComposition(for: asset, feature: document.crop)
    )
    Fixtures.expectVisiblyDifferent(CIImage(cgImage: cropOnly), CIImage(cgImage: composed))
  }

  @Test func `a video composition evaluates each frame at its composition time`() async throws {
    let asset = try await Fixtures.makeVideoAsset(from: Fixtures.normalizedSource(), frameCount: 2)
    defer {
      try? FileManager.default.removeItem(at: asset.url)
    }
    let composition = try VideoRenderer().makeVideoComposition(
      for: asset,
      feature: PresentationTimeLevel()
    )

    // The probe renders its presentation time in seconds as a gray level, so
    // the frame at 1 s is white only when that time reaches the document.
    func grayLevels(at time: CMTime) async throws -> [Float] {
      let frame = try await Fixtures.frame(of: asset, composition: composition, at: time)
      // Red channel of each RGBA pixel.
      return Fixtures.pixels(of: CIImage(cgImage: frame)).enumerated()
        .filter { $0.offset % 4 == 0 }
        .map(\.element)
    }
    let first = try await grayLevels(at: .zero)
    let second = try await grayLevels(at: CMTime(value: 1, timescale: 1))
    #expect(first.isEmpty == false && second.isEmpty == false)
    #expect(first.max() ?? 1 < 0.05, "frame at 0 s: \(first.max() ?? .nan)")
    #expect(second.min() ?? 0 > 0.95, "frame at 1 s: \(second.min() ?? .nan)")
  }
}

/// Renders its presentation time in seconds, clamped to 0...1, as a gray
/// level over the input extent.
private struct PresentationTimeLevel: ImageEffect {

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let level = min(max(context.presentationTime.seconds, 0), 1)
    return CIImage(color: CIColor(red: level, green: level, blue: level))
      .cropped(to: image.extent)
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

  /// The members as primitive leaves, in body order.
  var steps: [any Feature] {
    [
      exposure, brightness, contrast, saturation, highlights, shadows, temperature, tint,
      sharpen, unsharpMask, blur, fade, vignette,
    ]
  }
}

/// A crop in the middle of the chain, followed by effects whose radii are
/// proportional to the image.
private struct MidChainCropBlurDocument: Feature {

  var exposure = ExposureFeature(value: 0.2)
  var crop = CropFeature(cropRect: CGRect(x: 40, y: 30, width: 160, height: 120))
  var blur = GaussianBlurFeature(value: 40)
  var sharpen: SharpenFeature? = SharpenFeature(sharpness: 0.4, radius: 20)

  var body: some Feature {
    exposure
    crop
    blur
    sharpen
  }

  /// The members as primitive leaves, in body order.
  var steps: [any Feature] {
    var steps: [any Feature] = [exposure, crop, blur]
    if let sharpen {
      steps.append(sharpen)
    }
    return steps
  }
}

/// Two crops with effects between and after them.
private struct TwoCropsDocument: Feature {

  /// By default the first crop straightens and the second one rotates by a
  /// quarter turn inside the straightened domain.
  var first: CropFeature? = CropFeature(
    cropRect: CGRect(x: 30, y: 20, width: 260, height: 200),
    straightenRadians: 0.08
  )
  var saturation = SaturationFeature(value: 0.3)
  var second = CropFeature(
    cropRect: CGRect(x: 20, y: 30, width: 180, height: 120),
    rotation: .counterclockwise
  )
  var exposure = ExposureFeature(value: 0.1)

  var body: some Feature {
    first
    saturation
    second
    exposure
  }

  /// The members as primitive leaves, in body order.
  var steps: [any Feature] {
    var steps: [any Feature] = []
    if let first {
      steps.append(first)
    }
    steps += [saturation, second, exposure] as [any Feature]
    return steps
  }
}

/// The mask trees exercised by the local adjustment tests.
enum MaskShape: String, CaseIterable, Sendable {

  /// A feathered brush united with a hard brush.
  case featheredBrush

  /// Everything outside a brush.
  case invertedBrush

  /// A brush with a smaller brush removed.
  case subtractedBrush

  /// The overlap of two brushes.
  case intersectedBrushes

  func makeMaskTree() -> MaskTree {
    typealias Fixtures = RenderingFixtures
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

  /// A region of the entry domain the mask does not cover, or `nil` when the
  /// mask covers the whole image.
  var untouchedRect: CGRect? {
    switch self {
    case .featheredBrush, .subtractedBrush, .intersectedBrushes:
      CGRect(x: 150, y: 10, width: 40, height: 30)
    case .invertedBrush:
      nil
    }
  }
}

/// A global exposure, a masked blur, and a trailing contrast, in the shape an
/// ImageEditor-like editor stores its local blur.
private struct MaskedBlurDocument: Feature {

  var exposure = ExposureFeature(value: 0.15)
  var localBlur: LocalAdjustment<GaussianBlurFeature>?
  var contrast = ContrastFeature(value: 0.1)

  init(maskTree: MaskTree) {
    localBlur = LocalAdjustment(maskTree: maskTree) {
      GaussianBlurFeature(value: 40)
    }
  }

  var body: some Feature {
    exposure
    localBlur
    contrast
  }
}

/// Tone curve, color mixer, and a color cube.
private struct ColorGradingDocument: Feature {

  var toneCurve: ToneCurveFeature? = RenderingFixtures.makeToneCurve()
  var colorMixer: ColorMixerFeature? = ColorMixerFeature(
    adjustment: ColorMixerAdjustment(
      red: .init(hue: 20, saturation: -30, luminance: 10),
      green: .init(hue: -25, saturation: 35, luminance: -15),
      magenta: .init(hue: 15, saturation: 20)
    )
  )
  var colorCube: ColorCubeFeature? = RenderingFixtures.makeColorCube()

  var body: some Feature {
    toneCurve
    colorMixer
    colorCube
  }

  /// The present members as primitive leaves, in body order.
  var steps: [any Feature] {
    let members: [(any Feature)?] = [toneCurve, colorMixer, colorCube]
    return members.compactMap { $0 }
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

  var look = Look(preset: NestedPresetDocument.makeOuterPreset(includesInnerFade: false))
  var vignette = VignetteFeature(value: 0.4)

  var body: some Feature {
    look
    vignette
  }

  static func makeOuterPreset(includesInnerFade: Bool) -> PresetFeature {
    var innerEffects = [
      AnyImageEffect(ContrastFeature(value: 0.25)),
      AnyImageEffect(SaturationFeature(value: -0.4)),
    ]
    if includesInnerFade {
      innerEffects.append(AnyImageEffect(FadeFeature(intensity: 0.5)))
    }
    let inner = PresetFeature(
      name: "Inner",
      identifier: "composition-tests.inner",
      effects: innerEffects
    )
    return PresetFeature(
      name: "Outer",
      identifier: "composition-tests.outer",
      effects: [
        AnyImageEffect(ExposureFeature(value: 0.2)),
        AnyImageEffect(inner),
        AnyImageEffect(TemperatureFeature(value: -600)),
      ]
    )
  }
}

/// `NestedPresetDocument` written out by hand as one flat body.
private struct FlattenedPresetDocument: Feature {

  var body: some Feature {
    BrightnessFeature(value: 0.03)
    ExposureFeature(value: 0.2)
    ContrastFeature(value: 0.25)
    SaturationFeature(value: -0.4)
    TemperatureFeature(value: -600)
    VignetteFeature(value: 0.4)
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
}

/// The documents compared by the composition test.
enum CompositionVariant: String, CaseIterable, Sendable {

  /// Optional members present, the first branch, two loop passes, a data-driven
  /// catalog with a preset, and a crop.
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
              identifier: "composition-tests.catalog",
              effects: [
                AnyImageEffect(ContrastFeature(value: -0.1)),
                AnyImageEffect(BrightnessFeature(value: 0.05)),
              ]
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

  /// The primitive leaves the document evaluates, listed by hand.
  var flattenedSteps: [any Feature] {
    var steps: [any Feature]
    switch self {
    case .everyMemberPresent:
      steps = [
        ExposureFeature(value: 0.3),
        FadeFeature(intensity: 0.1),
        TemperatureFeature(value: 900, tint: 10),
        SharpenFeature(sharpness: 0.3, radius: 10),
        SharpenFeature(sharpness: 0.2, radius: 25),
        SaturationFeature(value: 0.4),
        ContrastFeature(value: -0.1),
        BrightnessFeature(value: 0.05),
        CropFeature(cropRect: CGRect(x: 16, y: 12, width: 240, height: 200)),
      ]
    case .optionalMembersAbsent:
      steps = [
        TemperatureFeature(value: -900, tint: -10),
        ContrastFeature(value: 0.2),
      ]
    }
    if #available(iOS 18, macOS 15, *) {
      steps.append(VignetteFeature(value: 0.5))
    }
    return steps
  }
}

/// The shape an ImageEditor-like editor stores: global adjustments, an optional
/// preset, an optional local blur, and the final crop.
private struct ImageEditorLikeFeature: Feature {

  var exposure = ExposureFeature(value: 0.25)
  var saturation = SaturationFeature(value: 0.2)
  var preset: PresetFeature? = PresetFeature(
    name: "Film",
    identifier: "composition-tests.film",
    effects: [
      AnyImageEffect(ContrastFeature(value: 0.15)),
      AnyImageEffect(FadeFeature(intensity: 0.06)),
    ]
  )
  var localBlur: LocalAdjustment<GaussianBlurFeature>? = LocalAdjustment(
    maskTree: RenderingFixtures.featheredBrushMaskTree()
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
    localBlur
    crop
  }

  /// The members as primitive leaves, in body order, with the preset
  /// expanded into its effects.
  var steps: [any Feature] {
    var steps: [any Feature] = [exposure, saturation]
    steps += (preset?.effects ?? []).map { $0.base as any Feature }
    if let localBlur {
      steps.append(localBlur)
    }
    steps.append(crop)
    return steps
  }
}
