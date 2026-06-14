import XCTest
import UIKit

@testable import BrightroomParametric
@testable import BrightroomEngine

private extension MainFeature {
  /// A stable string tag for the feature case, replacing the old
  /// `EditingFeature.Payload.Kind` the tests asserted against.
  var testKind: String {
    switch self {
    case .effect: return "effect"
    case .localAdjustment: return "localAdjustment"
    case .domain: return "crop"
    }
  }
}

/// Contracts of the parametric editing document: `Edit` stores an
/// `EditingDocument`, the engine never reorders its main tree, and history
/// versions are whole-document snapshots with undo/redo.
final class EditingFeatureDocumentTests: XCTestCase {

  private let imageSize = CGSize(width: 1200, height: 800)

  private func makeCrop() -> CropFeature {
    CropFeature.test(imageSize: imageSize)
  }

  private func effectsFeature(
    id: FeatureID = EditingStack.Edit.globalEffectsID,
    _ pipeline: EffectPipeline = .init()
  ) -> MainFeature {
    .effect(EffectPipelineFeature(id: id, pipeline: pipeline))
  }

  private func cropFeature(id: FeatureID = EditingStack.Edit.finalCropID) -> MainFeature {
    .domain(CropFeature.test(imageSize: imageSize).with(id: id))
  }

  private func makeEdit(features: [MainFeature]) -> EditingStack.Edit {
    EditingStack.Edit(
      document: EditingDocument(mainTree: MainTree(features: features)),
      orientedImageSize: imageSize
    )
  }

  private func makeAdjustment() -> LocalAdjustmentFeature {
    LocalAdjustmentFeature(
      maskTree: MaskTree(
        root: .brush(
          BrushMask(strokes: [
            BrushMaskStroke(
              stamps: [CGPoint(x: 10, y: 10)],
              brush: BrushMaskBrush(diameter: 8, hardness: 0.7, opacity: 1)
            )
          ])
        )
      ),
      effectPipeline: EffectPipeline(effects: [GaussianBlurFeature(radius: 10)])
    )
  }

  // MARK: - Document shape

  func testCanonicalDefaultDocument() {
    let edit = EditingStack.Edit(crop: makeCrop(), orientedImageSize: imageSize)

    XCTAssertEqual(edit.features.map(\.testKind), ["effect", "crop"])
    XCTAssertEqual(edit.features.first?.id, EditingStack.Edit.globalEffectsID)
    XCTAssertEqual(edit.features.last?.id, EditingStack.Edit.finalCropID)
  }

  func testLocalAdjustmentsProjectionInsertsBeforeFinalCrop() {
    var edit = EditingStack.Edit(crop: makeCrop(), orientedImageSize: imageSize)
    let adjustment = makeAdjustment()

    edit.localAdjustments = [adjustment]

    XCTAssertEqual(
      edit.features.map(\.testKind),
      ["effect", "localAdjustment", "crop"]
    )
    XCTAssertEqual(edit.localAdjustments, [adjustment])
    XCTAssertEqual(edit.features[1].id, adjustment.id)
  }

  func testCustomArrangementIsNotReorderedByProjectionWrites() {
    // A non-canonical arrangement: adjustment evaluated BEFORE the global
    // effects. Assembly is the host's decision; projection writes must keep
    // positions.
    let adjustment = makeAdjustment()
    var edit = makeEdit(features: [
      .localAdjustment(adjustment),
      effectsFeature(),
      cropFeature(),
    ])

    let effects = EffectPipeline(effects: [BrightnessFeature(value: 0.1)])
    edit.effects = effects

    XCTAssertEqual(
      edit.features.map(\.testKind),
      ["localAdjustment", "effect", "crop"]
    )
    XCTAssertEqual(edit.effects, effects)

    var replacedAdjustment = adjustment
    replacedAdjustment.effectPipeline = EffectPipeline(effects: [
      ExposureFeature(value: 0.5)
    ])
    edit.localAdjustments = [replacedAdjustment]

    XCTAssertEqual(
      edit.features.map(\.testKind),
      ["localAdjustment", "effect", "crop"]
    )
    XCTAssertEqual(edit.localAdjustments, [replacedAdjustment])
  }

  func testUpdateFeatureKeepsKindStableAndRejectsUnknownIDs() {
    var edit = EditingStack.Edit(crop: makeCrop(), orientedImageSize: imageSize)

    XCTAssertFalse(
      edit.updateFeature(id: FeatureID(rawValue: "unknown")) { _ in }
    )

    let newCrop = CropFeature(
      id: EditingStack.Edit.finalCropID,
      displayCropRect: CropGeometry.cropRect(toFitAspectRatio: .square, in: imageSize),
      imageSize: imageSize
    )
    XCTAssertTrue(
      edit.updateFeature(id: EditingStack.Edit.finalCropID) { feature in
        feature = .domain(newCrop)
      }
    )
    XCTAssertEqual(edit.crop, newCrop)
  }

  // MARK: - Undo / redo

  private func makeLoaded() -> EditingStack.Loaded {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let cgImage = UIGraphicsImageRenderer(
      size: CGSize(width: 40, height: 20),
      format: format
    ).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    }.cgImage!

    let sourceCIImage = CIImage(cgImage: cgImage)
    let initialEdit = EditingStack.Edit.test(imageSize: CGSize(width: 40, height: 20))
    return EditingStack.Loaded(
      imageSource: ImageSource(cgImage: cgImage),
      metadata: .init(orientation: .up, imageSize: CGSize(width: 40, height: 20)),
      initialEditing: initialEdit,
      currentEdit: initialEdit,
      thumbnailCIImage: sourceCIImage,
      editingSourceCGImage: cgImage,
      editingSourceCIImage: sourceCIImage,
      editingPreviewCIImage: initialEdit.makePreviewImage(
        from: sourceCIImage,
        purpose: .editingBase
      )
    )
  }

  func testUndoRedoWalksVersions() {
    var loaded = makeLoaded()
    let v0 = loaded.currentEdit

    loaded.makeVersion()
    var v1 = v0
    v1.effects = EffectPipeline(effects: [BrightnessFeature(value: 0.1)])
    loaded.currentEdit = v1

    loaded.makeVersion()
    var v2 = v1
    v2.localAdjustments = [makeAdjustment()]
    loaded.currentEdit = v2

    loaded.undoEditing()
    XCTAssertEqual(loaded.currentEdit, v1)
    XCTAssertTrue(loaded.canRedo)

    loaded.undoEditing()
    XCTAssertEqual(loaded.currentEdit, v0)

    loaded.redoEditing()
    XCTAssertEqual(loaded.currentEdit, v1)

    loaded.redoEditing()
    XCTAssertEqual(loaded.currentEdit, v2)
    XCTAssertFalse(loaded.canRedo)
  }

  func testInterleavedArrangementSurvivesLocalAdjustmentsWrites() {
    // [GE1, LA_A, GE2, LA_B, crop]: appending an adjustment through the
    // projection must not move LA_B across GE2.
    let adjustmentA = makeAdjustment()
    var adjustmentB = makeAdjustment()
    adjustmentB.effectPipeline = EffectPipeline(effects: [
      ExposureFeature(value: 0.5)
    ])
    let secondEffectsID = FeatureID(rawValue: "test.second-global-effects")

    var edit = makeEdit(features: [
      effectsFeature(),
      .localAdjustment(adjustmentA),
      effectsFeature(id: secondEffectsID),
      .localAdjustment(adjustmentB),
      cropFeature(),
    ])

    let adjustmentC = makeAdjustment()
    edit.localAdjustments = [adjustmentA, adjustmentB, adjustmentC]

    XCTAssertEqual(
      edit.features.map(\.id),
      [
        EditingStack.Edit.globalEffectsID,
        adjustmentA.id,
        secondEffectsID,
        adjustmentB.id,
        adjustmentC.id,
        EditingStack.Edit.finalCropID,
      ]
    )

    // Removing an adjustment keeps the others in place.
    edit.localAdjustments = [adjustmentA, adjustmentB]
    XCTAssertEqual(
      edit.features.map(\.id),
      [
        EditingStack.Edit.globalEffectsID,
        adjustmentA.id,
        secondEffectsID,
        adjustmentB.id,
        EditingStack.Edit.finalCropID,
      ]
    )
  }

  func testCommitStyleSnapshotUndoChangesStateOnFirstPress() {
    // PhotosCrop snapshots AFTER mutating (commit style): history.last equals
    // currentEdit at settled states. One undo press must still change state.
    var loaded = makeLoaded()
    let v0 = loaded.currentEdit

    var v1 = v0
    v1.effects = EffectPipeline(effects: [BrightnessFeature(value: 0.1)])
    loaded.currentEdit = v1
    loaded.makeVersion()

    var v2 = v1
    v2.localAdjustments = [makeAdjustment()]
    loaded.currentEdit = v2
    loaded.makeVersion()

    XCTAssertTrue(loaded.canUndo)
    loaded.undoEditing()
    XCTAssertEqual(loaded.currentEdit, v1)

    loaded.undoEditing()
    XCTAssertEqual(loaded.currentEdit, v0)

    loaded.redoEditing()
    XCTAssertEqual(loaded.currentEdit, v1)
    loaded.redoEditing()
    XCTAssertEqual(loaded.currentEdit, v2)
    XCTAssertFalse(loaded.canRedo)
  }

  func testNewVersionClearsRedo() {
    var loaded = makeLoaded()

    loaded.makeVersion()
    var v1 = loaded.currentEdit
    v1.effects = EffectPipeline(effects: [BrightnessFeature(value: 0.1)])
    loaded.currentEdit = v1

    loaded.undoEditing()
    XCTAssertTrue(loaded.canRedo)

    var divergent = loaded.currentEdit
    divergent.effects = EffectPipeline(effects: [ContrastFeature(value: 0.1)])
    loaded.currentEdit = divergent
    loaded.makeVersion()

    XCTAssertFalse(loaded.canRedo)
  }
}

private extension CropFeature {
  /// Returns a copy with a replaced identity (test convenience for building
  /// custom main-tree arrangements with well-known node ids).
  func with(id: FeatureID) -> CropFeature {
    var copy = self
    copy.id = id
    return copy
  }
}
