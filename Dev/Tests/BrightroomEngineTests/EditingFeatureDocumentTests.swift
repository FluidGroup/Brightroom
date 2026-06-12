import XCTest
import UIKit

import BrightroomParametric
@testable import BrightroomEngine

/// Contracts of the feature-list editing document: `Edit` stores nothing but
/// an ordered `[EditingFeature]`, the engine never reorders it, and history
/// versions are whole-document snapshots with undo/redo.
final class EditingFeatureDocumentTests: XCTestCase {

  private func makeCrop() -> EditingCrop {
    EditingCrop(imageSize: CGSize(width: 1200, height: 800))
  }

  private func makeLayer() -> EditingStack.Edit.LocalAdjustmentLayer {
    EditingStack.Edit.LocalAdjustmentLayer(
      effect: .gaussianBlur(radius: 10),
      mask: .init(strokes: [
        .init(
          stamps: [CGPoint(x: 10, y: 10)],
          brush: .init(size: 8, hardness: 0.7, opacity: 1)
        )
      ])
    )
  }

  // MARK: - Document shape

  func testCanonicalDefaultDocument() {
    let edit = EditingStack.Edit(crop: makeCrop())

    XCTAssertEqual(edit.features.map(\.payload.kind), [.globalEffects, .crop])
    XCTAssertEqual(edit.features.first?.id, EditingFeature.globalEffectsID)
    XCTAssertEqual(edit.features.last?.id, EditingFeature.finalCropID)
  }

  func testLocalAdjustmentsProjectionInsertsBeforeFinalCrop() {
    var edit = EditingStack.Edit(crop: makeCrop())
    let layer = makeLayer()

    edit.localAdjustments = [layer]

    XCTAssertEqual(
      edit.features.map(\.payload.kind),
      [.globalEffects, .localAdjustment, .crop]
    )
    XCTAssertEqual(edit.localAdjustments, [layer])
    XCTAssertEqual(
      edit.features[1].id,
      EditingFeature.localAdjustmentID(for: layer.id)
    )
  }

  func testCustomArrangementIsNotReorderedByProjectionWrites() {
    // A non-canonical arrangement: adjustment evaluated BEFORE the global
    // effects. Assembly is the host's decision; projection writes must keep
    // positions.
    let layer = makeLayer()
    var edit = EditingStack.Edit(features: [
      .init(
        id: EditingFeature.localAdjustmentID(for: layer.id),
        payload: .localAdjustment(layer)
      ),
      .init(id: EditingFeature.globalEffectsID, payload: .globalEffects(.init())),
      .init(id: EditingFeature.finalCropID, payload: .crop(makeCrop())),
    ])

    var filters = EditingStack.Edit.Filters()
    filters.brightness = FilterBrightness()
    edit.filters = filters

    XCTAssertEqual(
      edit.features.map(\.payload.kind),
      [.localAdjustment, .globalEffects, .crop]
    )
    XCTAssertEqual(edit.filters, filters)

    var replacedLayer = layer
    replacedLayer.effect = .exposure(value: 0.5)
    edit.localAdjustments = [replacedLayer]

    XCTAssertEqual(
      edit.features.map(\.payload.kind),
      [.localAdjustment, .globalEffects, .crop]
    )
    XCTAssertEqual(edit.localAdjustments, [replacedLayer])
  }

  func testUpdateFeatureKeepsKindStableAndRejectsUnknownIDs() {
    var edit = EditingStack.Edit(crop: makeCrop())

    XCTAssertFalse(
      edit.updateFeature(id: FeatureID(rawValue: "unknown")) { _ in }
    )

    var newCrop = makeCrop()
    newCrop.updateCropExtentIfNeeded(toFitAspectRatio: .square)
    XCTAssertTrue(
      edit.updateFeature(id: EditingFeature.finalCropID) { payload in
        payload = .crop(newCrop)
      }
    )
    XCTAssertEqual(edit.crop, newCrop)
  }

  // MARK: - Renderer order

  func testRendererResolvedOperationsRespectExplicitOrder() {
    var edit = BrightRoomImageRenderer.Edit()
    edit.operations = [
      .localAdjustment(makeLayer()),
      .filters([FilterBrightness().asAny()]),
    ]

    let resolved = edit.resolvedOperations
    XCTAssertEqual(resolved.count, 2)
    guard case .localAdjustment = resolved[0], case .filters = resolved[1] else {
      XCTFail("operations must keep document order")
      return
    }
  }

  func testRendererLegacyInputsKeepFixedOrder() {
    var edit = BrightRoomImageRenderer.Edit()
    edit.modifiers = [FilterBrightness().asAny()]
    edit.localAdjustments = [makeLayer()]

    let resolved = edit.resolvedOperations
    XCTAssertEqual(resolved.count, 2)
    guard case .filters = resolved[0], case .localAdjustment = resolved[1] else {
      XCTFail("legacy inputs evaluate filters first, then adjustments")
      return
    }
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
    let initialEdit = EditingStack.Edit(
      crop: EditingCrop(imageSize: CGSize(width: 40, height: 20))
    )
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
    v1.filters.brightness = FilterBrightness()
    loaded.currentEdit = v1

    loaded.makeVersion()
    var v2 = v1
    v2.localAdjustments = [makeLayer()]
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
    // [GE1, LA_A, GE2, LA_B, crop]: appending a layer through the projection
    // must not move LA_B across GE2.
    let layerA = makeLayer()
    var layerB = makeLayer()
    layerB.effect = .exposure(value: 0.5)
    let secondEffectsID = FeatureID(rawValue: "test.second-global-effects")

    var edit = EditingStack.Edit(features: [
      .init(id: EditingFeature.globalEffectsID, payload: .globalEffects(.init())),
      .init(
        id: EditingFeature.localAdjustmentID(for: layerA.id),
        payload: .localAdjustment(layerA)
      ),
      .init(id: secondEffectsID, payload: .globalEffects(.init())),
      .init(
        id: EditingFeature.localAdjustmentID(for: layerB.id),
        payload: .localAdjustment(layerB)
      ),
      .init(id: EditingFeature.finalCropID, payload: .crop(makeCrop())),
    ])

    let layerC = makeLayer()
    edit.localAdjustments = [layerA, layerB, layerC]

    XCTAssertEqual(
      edit.features.map(\.id),
      [
        EditingFeature.globalEffectsID,
        EditingFeature.localAdjustmentID(for: layerA.id),
        secondEffectsID,
        EditingFeature.localAdjustmentID(for: layerB.id),
        EditingFeature.localAdjustmentID(for: layerC.id),
        EditingFeature.finalCropID,
      ]
    )

    // Removing a layer keeps the others in place.
    edit.localAdjustments = [layerA, layerB]
    XCTAssertEqual(
      edit.features.map(\.id),
      [
        EditingFeature.globalEffectsID,
        EditingFeature.localAdjustmentID(for: layerA.id),
        secondEffectsID,
        EditingFeature.localAdjustmentID(for: layerB.id),
        EditingFeature.finalCropID,
      ]
    )
  }

  func testCommitStyleSnapshotUndoChangesStateOnFirstPress() {
    // PhotosCrop snapshots AFTER mutating (commit style): history.last equals
    // currentEdit at settled states. One undo press must still change state.
    var loaded = makeLoaded()
    let v0 = loaded.currentEdit

    var v1 = v0
    v1.filters.brightness = FilterBrightness()
    loaded.currentEdit = v1
    loaded.makeVersion()

    var v2 = v1
    v2.localAdjustments = [makeLayer()]
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

  func testRenderParityBetweenOperationsAndLegacyInputs() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let cgImage = UIGraphicsImageRenderer(
      size: CGSize(width: 64, height: 64),
      format: format
    ).image { context in
      UIColor.gray.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
    }.cgImage!

    var brightness = FilterBrightness()
    brightness.value = 0.2
    let layer = makeLayer()

    let legacyRenderer = BrightRoomImageRenderer(
      source: .init(cgImage: cgImage),
      orientation: .up
    )
    legacyRenderer.edit.modifiers = [brightness.asAny()]
    legacyRenderer.edit.localAdjustments = [layer]
    let legacy = try legacyRenderer.render()

    let operationsRenderer = BrightRoomImageRenderer(
      source: .init(cgImage: cgImage),
      orientation: .up
    )
    operationsRenderer.edit.operations = [
      .filters([brightness.asAny()]),
      .localAdjustment(layer),
    ]
    let compiled = try operationsRenderer.render()

    XCTAssertEqual(legacy.cgImage.width, compiled.cgImage.width)
    XCTAssertEqual(legacy.cgImage.height, compiled.cgImage.height)
    XCTAssertEqual(
      legacy.cgImage.dataProvider?.data as Data?,
      compiled.cgImage.dataProvider?.data as Data?
    )
  }

  func testNewVersionClearsRedo() {
    var loaded = makeLoaded()

    loaded.makeVersion()
    var v1 = loaded.currentEdit
    v1.filters.brightness = FilterBrightness()
    loaded.currentEdit = v1

    loaded.undoEditing()
    XCTAssertTrue(loaded.canRedo)

    var divergent = loaded.currentEdit
    divergent.filters.contrast = FilterContrast()
    loaded.currentEdit = divergent
    loaded.makeVersion()

    XCTAssertFalse(loaded.canRedo)
  }
}
