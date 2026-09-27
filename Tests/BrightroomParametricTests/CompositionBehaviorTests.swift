//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import CoreImage
import CoreMedia
import Foundation
import Testing
import os

/// Behavior of feature documents that pixel comparisons alone do not pin: the
/// static shapes `FeatureBuilder` produces, evaluation order and
/// nesting, the evaluation context passed down from chain entry, and the
/// errors that invalid parameters throw.
@Suite(.serialized)
struct CompositionBehaviorTests {

  private typealias Fixtures = RenderingFixtures

  // MARK: - Builder shapes

  @Test func `the builder produces fully static shapes`() {
    let log = EvaluationLog()
    let document = OrderedDocument(
      log: log,
      includesOptional: true,
      takesFirstBranch: true,
      loopLabels: ["loop.0"]
    )

    #expect(
      type(of: document.body)
        == TupleFeature<
          EvaluationProbe,
          EvaluationProbe?,
          EitherFeature<EvaluationProbe, TupleFeature<EvaluationProbe, NestedProbes>>,
          [EvaluationProbe],
          NestedProbes,
          EvaluationProbe
        >.self
    )
    #expect(
      type(of: NestedProbes(log: log).body) == TupleFeature<EvaluationProbe, EvaluationProbe>.self
    )
    #expect(type(of: SingleMemberDocument().body) == ExposureFeature.self)
    #expect(type(of: EmptyDocument().body) == EmptyFeature.self)

    // A structural feature is an image effect exactly when all of its parts
    // are.
    #expect((document.body as Any) is any ImageEffect)
    #expect(((CropThenEffectDocument().body as Any) is any ImageEffect) == false)
    #expect((CropThenEffectDocument().body as Any) is any Feature)
  }

  @Test func `members evaluate in written order, including branches, loops, and nested composites`()
    throws
  {
    let source = try Fixtures.makeSource()

    let firstLog = EvaluationLog()
    _ = try Fixtures.renderer.makeImage(
      from: source,
      document: OrderedDocument(
        log: firstLog,
        includesOptional: true,
        takesFirstBranch: true,
        loopLabels: ["loop.0", "loop.1"]
      )
    )
    #expect(
      firstLog.labels == [
        "first",
        "optional",
        "if",
        "loop.0",
        "loop.1",
        "nested.0",
        "nested.1",
        "last",
      ]
    )

    let secondLog = EvaluationLog()
    _ = try Fixtures.renderer.makeImage(
      from: source,
      document: OrderedDocument(
        log: secondLog,
        includesOptional: false,
        takesFirstBranch: false,
        loopLabels: []
      )
    )
    #expect(
      secondLog.labels == [
        "first",
        "else",
        "nested.0",
        "nested.1",
        "nested.0",
        "nested.1",
        "last",
      ]
    )
  }

  @Test func `absent members leave the image unchanged`() throws {
    let source = try Fixtures.makeSource()
    let normalized = source.transformed(
      by: CGAffineTransform(
        translationX: -Fixtures.sourceExtent.minX,
        y: -Fixtures.sourceExtent.minY
      )
    )

    struct Document: Feature {
      var exposure: ExposureFeature? = nil
      var passes: [SharpenFeature] = []
      var appliesFade = false

      var body: some Feature {
        exposure
        passes
        if appliesFade {
          FadeFeature(intensity: 1)
        }
        EmptyFeature()
      }
    }

    let composed = try Fixtures.renderer.makeImage(from: source, document: Document())
    #expect(composed.extent == Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(normalized, composed)

    // The same members, present, do change the image.
    let present = try Fixtures.renderer.makeImage(
      from: source,
      document: Document(
        exposure: ExposureFeature(value: 0.5),
        passes: [SharpenFeature(sharpness: 0.4, radius: 20)],
        appliesFade: true
      )
    )
    Fixtures.expectVisiblyDifferent(normalized, present)
  }

  // MARK: - Local adjustments

  @Test func `a composite image effect works inside a local adjustment`() throws {
    let source = try Fixtures.makeSource()
    let maskTree = MaskTree(root: .brush(BrushMask(strokes: [Self.hardStroke])))
    let look = Look()

    struct Document: Feature {
      var maskTree: MaskTree
      var look: Look

      var body: some Feature {
        LocalAdjustment(maskTree: maskTree) {
          look
        }
      }
    }

    let composed = try Fixtures.renderer.makeImage(
      from: source,
      document: Document(maskTree: maskTree, look: look)
    )

    // The look's leaves, blended through the rendered mask with the raw
    // filter.
    let normalized = try Fixtures.normalizedSource()
    let adjusted = try Fixtures.renderer.makeImage(
      from: normalized,
      document: SequentialFeatures(
        [look.exposure, look.saturation] + look.preset.effects.map { $0.base as any Feature }
      )
    )
    let expected = Fixtures.explicitBlend(
      adjusted: adjusted,
      base: normalized,
      mask: try Fixtures.renderer.makeMaskImage(for: maskTree, extent: Fixtures.entryExtent)
    )

    #expect(composed.extent == Fixtures.entryExtent)
    Fixtures.expectPixelsMatch(expected, composed)

    // The look applies inside the mask; far from the stroke the input is
    // untouched.
    let insideMask = CGRect(x: 72, y: 48, width: 16, height: 8)
    let outsideMask = CGRect(x: 220, y: 160, width: 80, height: 60)
    Fixtures.expectVisiblyDifferent(
      composed.cropped(to: insideMask),
      normalized.cropped(to: insideMask)
    )
    Fixtures.expectPixelsMatch(
      normalized.cropped(to: outsideMask),
      composed.cropped(to: outsideMask)
    )

    // A local adjustment with composite content keeps value semantics.
    var changedLook = look
    changedLook.exposure.value = 0
    let adjustment = LocalAdjustment(maskTree: maskTree) { look }
    let sameAdjustment = LocalAdjustment(maskTree: maskTree) { look }
    let changedAdjustment = LocalAdjustment(maskTree: maskTree) { changedLook }
    #expect(adjustment == sameAdjustment)
    #expect(adjustment != changedAdjustment)
  }

  // MARK: - Evaluation context

  @Test func `presentation time and the chain-entry context reach every nested feature`() throws {
    let source = try Fixtures.makeSource()
    let crop = CropFeature(cropRect: CGRect(x: 40, y: 30, width: 200, height: 150))
    let croppedExtent = CGRect(origin: .zero, size: crop.cropRect.size)
    let presentationTime = CMTime(value: 1_234, timescale: 600)

    func expectedEntries(
      radiusReferenceExtent: CGRect,
      presentationTime: CMTime
    ) -> [EvaluationLog.Entry] {
      [
        ("entry", Fixtures.entryExtent),
        ("after crop", croppedExtent),
        ("inside local adjustment", croppedExtent),
        ("nested.0", croppedExtent),
        ("nested.1", croppedExtent),
      ]
      .map { label, inputExtent in
        EvaluationLog.Entry(
          label: label,
          inputExtent: inputExtent,
          radiusReferenceExtent: radiusReferenceExtent,
          presentationTime: presentationTime
        )
      }
    }

    // Still-image renderer, default basis.
    let imageLog = EvaluationLog()
    _ = try Fixtures.renderer.makeImage(
      from: source,
      document: ContextProbeDocument(log: imageLog, crop: crop),
      presentationTime: presentationTime
    )
    #expect(
      imageLog.entries
        == expectedEntries(
          radiusReferenceExtent: Fixtures.entryExtent,
          presentationTime: presentationTime
        )
    )

    // Still-image renderer, explicit basis.
    let viewportReference = CGRect(x: 0, y: 0, width: 1_280, height: 960)
    let explicitLog = EvaluationLog()
    _ = try Fixtures.renderer.makeImage(
      from: source,
      document: ContextProbeDocument(log: explicitLog, crop: crop),
      radiusReferenceExtent: viewportReference,
      presentationTime: presentationTime
    )
    #expect(
      explicitLog.entries
        == expectedEntries(
          radiusReferenceExtent: viewportReference,
          presentationTime: presentationTime
        )
    )

    // Video frame.
    let frameTime = CMTime(value: 42, timescale: 30)
    let videoLog = EvaluationLog()
    _ = try ParametricVideoRenderer().makeFrameImage(
      from: source,
      document: ContextProbeDocument(log: videoLog, crop: crop),
      renderExtent: croppedExtent,
      presentationTime: frameTime
    )
    #expect(
      videoLog.entries
        == expectedEntries(
          radiusReferenceExtent: Fixtures.entryExtent,
          presentationTime: frameTime
        )
    )
  }

  @Test func `a direct apply with the default context treats its input as the chain entry`() throws {
    let source = try Fixtures.normalizedSource()
    let crop = CropFeature(cropRect: CGRect(x: 40, y: 30, width: 120, height: 90))

    struct Document: Feature {
      var crop: CropFeature

      var body: some Feature {
        crop
        GaussianBlurFeature(value: 40)
      }
    }
    let document = Document(crop: crop)

    let rendered = try Fixtures.renderer.makeImage(from: source, document: document)
    let applied = try document.apply(to: source, context: FeatureEvaluationContext())
    Fixtures.expectPixelsMatch(rendered, applied)

    let tupleApplied = try TupleFeature(crop, GaussianBlurFeature(value: 40))
      .apply(to: source, context: FeatureEvaluationContext())
    Fixtures.expectPixelsMatch(rendered, tupleApplied)

    // The basis matters: re-basing the radius on the crop changes the blur.
    let rebased = try Fixtures.renderer.makeImage(
      from: source,
      document: document,
      radiusReferenceExtent: CGRect(origin: .zero, size: crop.cropRect.size)
    )
    Fixtures.expectVisiblyDifferent(rendered, rebased)
  }

  // MARK: - Type erasure

  @Test func `erased effects are equal only when they wrap the same type`() {
    let exposure = ExposureFeature(value: 0.2)

    #expect(AnyImageEffect(exposure) == AnyImageEffect(exposure))
    #expect(AnyImageEffect(AnyImageEffect(exposure)) == AnyImageEffect(exposure))
    #expect(
      AnyImageEffect(exposure)
        != AnyImageEffect(ExposureFeature(value: 0.3))
    )

    // A plain cast would bridge these.
    #expect(AnyImageEffect(ExposureFeature?.none) != AnyImageEffect(FadeFeature?.none))
    #expect(AnyImageEffect([ExposureFeature]()) != AnyImageEffect([FadeFeature]()))
    #expect(AnyImageEffect(Optional(exposure)) != AnyImageEffect(exposure))
    #expect(AnyImageEffect(exposure) != AnyImageEffect(Optional(exposure)))
  }

  // MARK: - Equality

  @Test func `tone curve equality compares authored values rather than render identity`() throws {
    // A diagonal interior point is an authored edit that renders as identity:
    // the first point a curve drag adds usually sits on the diagonal.
    var diagonal = ToneCurveEditorValue()
    let diagonalIndex = diagonal.y.insertPoint(input: 0.5, output: 0.5)
    _ = try #require(diagonalIndex)
    let neutralCurve = ToneCurveFeature(value: .neutral)
    let diagonalCurve = ToneCurveFeature(value: diagonal)
    #expect(diagonalCurve != neutralCurve)
    #expect(ToneCurveRenderIdentity(value: diagonal) == ToneCurveRenderIdentity(value: .neutral))
    #expect(ToneCurveRenderIdentity(activeValue: diagonal) == nil)

    // Points are plain coordinates: the same curve reached through different
    // edits is the same value.
    var first = ToneCurveEditorValue()
    var second = ToneCurveEditorValue()
    let firstIndex = first.y.insertPoint(input: 0.4, output: 0.55)
    let secondIndex = second.y.insertPoint(input: 0.6, output: 0.3)
    _ = try #require(firstIndex)
    let movedIndex = try #require(secondIndex)
    second.y.movePoint(at: movedIndex, input: 0.4, output: 0.55)
    #expect(ToneCurveFeature(value: first) == ToneCurveFeature(value: second))
    #expect(ToneCurveRenderIdentity(value: first) == ToneCurveRenderIdentity(value: second))
  }

  @Test func `color mixer equality compares authored values rather than render identity`() throws {
    // Values that differ as Doubles but normalize to the same Float32 plan.
    var first = ColorMixerAdjustment.neutral
    first.red.hue = 10
    var equivalent = ColorMixerAdjustment.neutral
    equivalent.red.hue = 10.0.nextUp
    #expect(ColorMixerFeature(adjustment: first) != ColorMixerFeature(adjustment: equivalent))
    #expect(
      ColorMixerRenderIdentity(activeAdjustment: first)
        == ColorMixerRenderIdentity(activeAdjustment: equivalent)
    )
    #expect(ColorMixerFeature(adjustment: first) == ColorMixerFeature(adjustment: first))
    #expect(
      ColorMixerFeature(adjustment: first, algorithm: .oklch)
        == ColorMixerFeature(adjustment: first)
    )
  }

  @Test func `a document compares the authored values of its members`() throws {
    var diagonal = ToneCurveEditorValue()
    let diagonalIndex = diagonal.y.insertPoint(input: 0.5, output: 0.5)
    _ = try #require(diagonalIndex)
    var mixer = ColorMixerAdjustment.neutral
    mixer.red.hue = 10
    var equivalentMixer = ColorMixerAdjustment.neutral
    equivalentMixer.red.hue = 10.0.nextUp

    let document = ColorDocument(
      toneCurve: ToneCurveFeature(value: .neutral),
      colorMixer: ColorMixerFeature(adjustment: mixer)
    )
    #expect(document == document)

    // An owner that drops equal updates keeps each of these edits.
    var curveEdited = document
    curveEdited.toneCurve = ToneCurveFeature(value: diagonal)
    #expect(curveEdited != document)

    var mixerEdited = document
    mixerEdited.colorMixer = ColorMixerFeature(adjustment: equivalentMixer)
    #expect(mixerEdited != document)

    // A document rebuilt from the same values is equal.
    let rebuilt = ColorDocument(
      toneCurve: ToneCurveFeature(value: diagonal),
      colorMixer: ColorMixerFeature(adjustment: mixer)
    )
    #expect(rebuilt == curveEdited)
  }

  // MARK: - Errors

  @Test func `an empty mask composite throws at any depth`() throws {
    let source = try Fixtures.makeSource()
    let brush = MaskNode.brush(BrushMask(strokes: [Self.hardStroke]))
    let trees = [
      MaskTree(root: .subtract(MaskSubtract(base: brush, removing: .union([])))),
      MaskTree(root: .union([brush, .feather(MaskFeather(input: .intersect([]), radius: 4))])),
    ]

    for maskTree in trees {
      let error = #expect(throws: FeatureEvaluationError.self) {
        try Fixtures.renderer.makeImage(
          from: source,
          document: LocalAdjustment(maskTree: maskTree) {
            GaussianBlurFeature(value: 40)
          }
        )
      }
      #expect(error == .emptyMaskComposite)

      // Mask inspection reports the same error.
      #expect(throws: FeatureEvaluationError.emptyMaskComposite) {
        try Fixtures.renderer.makeMaskImage(for: maskTree, extent: Fixtures.entryExtent)
      }
    }
  }

  @Test(arguments: [
    CGRect(x: 0, y: 0, width: 0, height: 10),
    CGRect(x: 0, y: 0, width: 10, height: -5),
    CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10),
  ])
  func `an invalid crop rect throws the rectangle`(cropRect: CGRect) throws {
    let source = try Fixtures.makeSource()
    let crop = CropFeature(cropRect: cropRect)

    struct Document: Feature {
      var crop: CropFeature

      var body: some Feature {
        ExposureFeature(value: 0.2)
        crop
      }
    }

    let error = #expect(throws: FeatureEvaluationError.self) {
      try Fixtures.renderer.makeImage(from: source, document: Document(crop: crop))
    }
    #expect(error == .invalidCropRect(cropRect))

    // Validation is available before rendering.
    #expect(throws: FeatureEvaluationError.invalidCropRect(cropRect)) {
      try crop.validate()
    }
  }

  @Test func `invalid color cube data throws at any depth`() throws {
    let source = try Fixtures.makeSource()
    let cube = ColorCubeFeature(
      name: "Invalid",
      identifier: "composition-tests.invalid-cube",
      dimension: 4,
      cubeData: Data(count: 10)
    )
    let expectedError = FeatureEvaluationError.invalidColorCubeData(
      identifier: "composition-tests.invalid-cube",
      expectedByteCount: 4 * 4 * 4 * 4 * 4,
      actualByteCount: 10
    )

    #expect(throws: expectedError) {
      try cube.validate()
    }

    struct Root: Feature {
      var cube: ColorCubeFeature

      var body: some Feature {
        ExposureFeature(value: 0.2)
        cube
      }
    }

    struct Composite: ImageEffect {
      var cube: ColorCubeFeature

      var body: some ImageEffect {
        SaturationFeature(value: 0.1)
        cube
      }
    }

    struct Masked: Feature {
      var cube: ColorCubeFeature

      var body: some Feature {
        LocalAdjustment(maskTree: MaskTree(root: .brush(BrushMask(strokes: [])))) {
          Composite(cube: cube)
        }
      }
    }

    let preset = PresetFeature(
      name: "Broken",
      identifier: "composition-tests.broken",
      effects: [AnyImageEffect(ContrastFeature(value: 0.1)), AnyImageEffect(cube)]
    )

    let documents: [any Feature] = [
      Root(cube: cube),
      Composite(cube: cube),
      Masked(cube: cube),
      [AnyImageEffect(cube)],
      preset,
    ]
    for document in documents {
      let error = #expect(throws: FeatureEvaluationError.self) {
        try Fixtures.renderer.makeImage(from: source, document: document)
      }
      #expect(error == expectedError, "\(type(of: document))")
    }
  }

  @Test func `a nil optional document throws instead of rendering the source`() async throws {
    let source = try Fixtures.makeSource()
    let absent: ExposureFeature? = nil
    let present: ExposureFeature? = ExposureFeature(value: 0.4)

    #expect(throws: FeatureEvaluationError.documentUnavailable) {
      try Fixtures.renderer.makeImage(from: source, document: absent)
    }
    #expect(throws: FeatureEvaluationError.documentUnavailable) {
      try ParametricExportRenderer().render(source: source, document: absent)
    }
    #expect(throws: FeatureEvaluationError.documentUnavailable) {
      try ParametricVideoRenderer().makeFrameImage(from: source, document: absent)
    }
    #expect(throws: FeatureEvaluationError.documentUnavailable) {
      try ParametricVideoRenderer().resolveRenderSize(
        sourceRenderSize: Fixtures.sourceExtent.size,
        document: absent,
        mode: .featureOutput
      )
    }
    let asset = try await Fixtures.makeVideoAsset(from: Fixtures.normalizedSource())
    defer {
      try? FileManager.default.removeItem(at: asset.url)
    }
    #expect(throws: FeatureEvaluationError.documentUnavailable) {
      try ParametricVideoRenderer().makeVideoComposition(for: asset, document: absent)
    }

    // A present optional renders its value.
    Fixtures.expectPixelsMatch(
      try Fixtures.renderer.makeImage(from: source, document: ExposureFeature(value: 0.4)),
      try Fixtures.renderer.makeImage(from: source, document: present)
    )
    // The unedited image is an explicit request.
    Fixtures.expectPixelsMatch(
      Fixtures.removingOffset(source),
      try Fixtures.renderer.makeImage(from: source, document: EmptyFeature())
    )
  }

  @Test func `a local adjustment with empty content returns its input`() throws {
    let input = try Fixtures.normalizedSource()
    let context = FeatureEvaluationContext()
    let maskTree = MaskTree(root: .brush(BrushMask(strokes: [Self.hardStroke])))

    let empty = LocalAdjustment(maskTree: maskTree) {}
    #expect(try empty.apply(to: input, context: context) === input)

    let emptyArray = LocalAdjustment(maskTree: maskTree) { [AnyImageEffect]() }
    #expect(try emptyArray.apply(to: input, context: context) === input)

    let absent: ExposureFeature? = nil
    let absentMember = LocalAdjustment(maskTree: maskTree) { absent }
    #expect(try absentMember.apply(to: input, context: context) === input)

    // The mask still renders first, so an empty mask composite throws even
    // when the content applies nothing.
    let invalidMask = LocalAdjustment(maskTree: MaskTree(root: .union([]))) {}
    #expect(throws: FeatureEvaluationError.emptyMaskComposite) {
      try invalidMask.apply(to: input, context: context)
    }

    // A mask error takes precedence over an error from the content.
    let invalidCube = ColorCubeFeature(
      name: "Invalid",
      identifier: "composition-tests.invalid-cube",
      dimension: 4,
      cubeData: Data(count: 10)
    )
    let invalidBoth = LocalAdjustment(maskTree: MaskTree(root: .union([]))) { invalidCube }
    let error = #expect(throws: FeatureEvaluationError.self) {
      try invalidBoth.apply(to: input, context: context)
    }
    #expect(error == .emptyMaskComposite)
  }

  // MARK: - Fixtures

  /// A hard stroke in the lower-left of the entry domain (y-up).
  private static let hardStroke = BrushMaskStroke(
    stamps: [
      CGPoint(x: 60, y: 50),
      CGPoint(x: 80, y: 55),
      CGPoint(x: 100, y: 60),
    ],
    brush: BrushMaskBrush(diameter: 50, hardness: 1, opacity: 1)
  )
}

// MARK: - Probes

/// Records how a composition evaluates.
private final class EvaluationLog: Equatable, Sendable {

  /// One evaluation of a probe.
  struct Entry: Equatable, Sendable {
    var label: String
    var inputExtent: CGRect
    var radiusReferenceExtent: CGRect?
    var presentationTime: CMTime
  }

  private let storage = OSAllocatedUnfairLock<[Entry]>(initialState: [])

  var entries: [Entry] {
    storage.withLock { $0 }
  }

  var labels: [String] {
    entries.map(\.label)
  }

  func append(_ entry: Entry) {
    storage.withLock { $0.append(entry) }
  }

  static func == (lhs: EvaluationLog, rhs: EvaluationLog) -> Bool {
    lhs === rhs
  }
}

/// A host primitive that records its input and context and returns the input
/// unchanged.
private struct EvaluationProbe: ImageEffect, Equatable {

  var label: String
  var log: EvaluationLog

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    log.append(
      EvaluationLog.Entry(
        label: label,
        inputExtent: image.extent,
        radiusReferenceExtent: context.radiusReferenceExtent,
        presentationTime: context.presentationTime
      )
    )
    return image
  }
}

/// A host composite of two probes.
private struct NestedProbes: ImageEffect, Equatable {

  var log: EvaluationLog

  var body: some ImageEffect {
    EvaluationProbe(label: "nested.0", log: log)
    EvaluationProbe(label: "nested.1", log: log)
  }
}

/// A document that uses every control-flow shape of `FeatureBuilder`.
private struct OrderedDocument: Feature {

  var log: EvaluationLog
  var includesOptional: Bool
  var takesFirstBranch: Bool
  var loopLabels: [String]

  var body: some Feature {
    EvaluationProbe(label: "first", log: log)
    if includesOptional {
      EvaluationProbe(label: "optional", log: log)
    }
    if takesFirstBranch {
      EvaluationProbe(label: "if", log: log)
    } else {
      EvaluationProbe(label: "else", log: log)
      NestedProbes(log: log)
    }
    for label in loopLabels {
      EvaluationProbe(label: label, log: log)
    }
    NestedProbes(log: log)
    EvaluationProbe(label: "last", log: log)
  }
}

/// Probes before and after a crop, inside a local adjustment, and inside a
/// host composite.
private struct ContextProbeDocument: Feature {

  var log: EvaluationLog
  var crop: CropFeature

  var body: some Feature {
    EvaluationProbe(label: "entry", log: log)
    crop
    EvaluationProbe(label: "after crop", log: log)
    LocalAdjustment(maskTree: MaskTree(root: .brush(BrushMask(strokes: [])))) {
      EvaluationProbe(label: "inside local adjustment", log: log)
    }
    NestedProbes(log: log)
  }
}

private struct SingleMemberDocument: Feature {

  var body: some Feature {
    ExposureFeature(value: 0.1)
  }
}

private struct EmptyDocument: Feature {

  var body: some Feature {}
}

private struct CropThenEffectDocument: Feature {

  var body: some Feature {
    CropFeature(cropRect: CGRect(x: 0, y: 0, width: 10, height: 10))
    ExposureFeature(value: 0.1)
  }
}

/// A host composite look: global adjustments and a preset.
private struct Look: ImageEffect, Equatable {

  var exposure = ExposureFeature(value: 0.6)
  var saturation = SaturationFeature(value: -0.8)
  var preset = PresetFeature(
    name: "Punch",
    identifier: "composition-tests.punch",
    effects: [AnyImageEffect(ContrastFeature(value: 0.2))]
  )

  var body: some ImageEffect {
    exposure
    saturation
    preset
  }
}

/// A document whose members compare by their authored values.
private struct ColorDocument: ImageEffect, Equatable {
  var toneCurve: ToneCurveFeature?
  var colorMixer: ColorMixerFeature?

  var body: some ImageEffect {
    toneCurve
    colorMixer
  }
}
