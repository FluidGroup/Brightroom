import Foundation

import BrightroomEngine

/// Single owner of the `LocalAdjustmentLayer` that an editing canvas commits
/// brush strokes into.
///
/// Both `CropView` and `_EditingCanvasView` route their stroke commits through
/// this type so layer lookup, creation, and effect semantics cannot diverge.
///
/// Semantics:
/// - A committed layer's effect is frozen at creation. Appending strokes never
///   rewrites the effect, because UI-side effect values may drift (PhotosCrop
///   derives the blur radius from the current crop) and committed document
///   parameters must stay stable.
/// - `updateEffect(_:in:)` exists for deliberate effect changes only
///   (e.g. the user adjusts the effect parameter of the active layer).
final class EditingCanvasStrokeCommitPipeline {

  /// The layer this pipeline committed to most recently.
  private(set) var layerID: UUID?

  /// Forgets the tracked layer, so the next commit creates or re-adopts one.
  /// Call when the active effect identity changes.
  func resetLayerTracking() {
    layerID = nil
  }

  /// Explicitly adopts a layer as the commit target, overriding the
  /// effect-identity lookup. Call when the host addresses an existing
  /// FeatureTree node rather than seeding a new layer.
  func adoptLayer(id: UUID) {
    layerID = id
  }

  /// Appends a stroke (already in source/canvas coordinates) to the tracked
  /// layer, creating the layer when missing.
  func append(
    record: EditingCanvasStrokeRecord,
    effect: EditingStack.Edit.LocalAdjustmentEffect,
    to editingStack: EditingStack
  ) {
    var localAdjustments = editingStack.loadedState?.currentEdit.localAdjustments ?? []
    let layerIndex: Int
    if let existingIndex = self.layerIndex(in: localAdjustments, matching: effect) {
      layerIndex = existingIndex
    } else {
      let id = UUID()
      layerID = id
      localAdjustments.append(
        .init(
          id: id,
          effect: effect,
          mask: .init()
        )
      )
      layerIndex = localAdjustments.index(before: localAdjustments.endIndex)
    }

    localAdjustments[layerIndex].isEnabled = true
    localAdjustments[layerIndex].mask.strokes.append(record.localAdjustmentStroke)
    editingStack.set(localAdjustments: localAdjustments)
  }

  /// Deliberately updates the tracked layer's effect.
  func updateEffect(
    _ effect: EditingStack.Edit.LocalAdjustmentEffect,
    in editingStack: EditingStack
  ) {
    var localAdjustments = editingStack.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = layerIndex(in: localAdjustments, matching: effect) else {
      return
    }

    guard localAdjustments[layerIndex].effect != effect else {
      return
    }

    localAdjustments[layerIndex].effect = effect
    editingStack.set(localAdjustments: localAdjustments)
  }

  /// The effect persisted on the tracked layer, if one exists.
  func committedEffect(
    matching effect: EditingStack.Edit.LocalAdjustmentEffect,
    in loadedState: EditingStack.Loaded
  ) -> EditingStack.Edit.LocalAdjustmentEffect? {
    let localAdjustments = loadedState.currentEdit.localAdjustments
    guard let layerIndex = layerIndex(in: localAdjustments, matching: effect) else {
      return nil
    }

    return localAdjustments[layerIndex].effect
  }

  /// The tracked layer's strokes in source/canvas coordinates.
  func committedRecords(
    matching effect: EditingStack.Edit.LocalAdjustmentEffect?,
    in editingStack: EditingStack?
  ) -> [EditingCanvasStrokeRecord] {
    guard let effect else {
      return []
    }

    let localAdjustments = editingStack?.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = layerIndex(in: localAdjustments, matching: effect) else {
      return []
    }

    return localAdjustments[layerIndex].mask.strokes.map {
      EditingCanvasStrokeRecord(localAdjustmentStroke: $0)
    }
  }

  /// Finds the tracked layer by its remembered id, falling back to effect
  /// identity and adopting the found layer.
  func layerIndex(
    in localAdjustments: [EditingStack.Edit.LocalAdjustmentLayer],
    matching effect: EditingStack.Edit.LocalAdjustmentEffect
  ) -> Int? {
    if
      let layerID,
      let index = localAdjustments.firstIndex(where: { $0.id == layerID })
    {
      return index
    }

    guard let index = localAdjustments.firstIndex(where: { layer in
      layer.effect.editingCanvasEffectIdentity == effect.editingCanvasEffectIdentity
    }) else {
      return nil
    }

    layerID = localAdjustments[index].id
    return index
  }
}
