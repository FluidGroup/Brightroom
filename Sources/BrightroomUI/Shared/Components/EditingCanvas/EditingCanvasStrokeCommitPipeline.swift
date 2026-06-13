import Foundation

import BrightroomEngine
import BrightroomParametric

/// Single owner of the `LocalAdjustmentFeature` that an editing canvas commits
/// brush strokes into.
///
/// Both `CropView` and `_EditingCanvasView` route their stroke commits through
/// this type so layer lookup, creation, and effect semantics cannot diverge.
///
/// Semantics:
/// - A committed layer's effect pipeline is frozen at creation. Appending
///   strokes never rewrites the pipeline, because UI-side effect values may
///   drift and committed document parameters must stay stable.
/// - `updateEffect(_:in:)` exists for deliberate effect changes only
///   (e.g. the user adjusts the effect parameter of the active layer).
final class EditingCanvasStrokeCommitPipeline {

  /// The layer this pipeline committed to most recently.
  private(set) var layerID: FeatureID?

  /// Forgets the tracked layer, so the next commit creates or re-adopts one.
  /// Call when the active effect identity changes.
  func resetLayerTracking() {
    layerID = nil
  }

  /// Explicitly adopts a layer as the commit target, overriding the
  /// effect-identity lookup. Call when the host addresses an existing
  /// FeatureTree node rather than seeding a new layer.
  func adoptLayer(id: FeatureID) {
    layerID = id
  }

  /// Appends a stroke (already in source/canvas coordinates) to the tracked
  /// layer, creating the layer when missing.
  func append(
    record: EditingCanvasStrokeRecord,
    effect: EffectPipeline,
    to editingStack: EditingStack
  ) {
    var localAdjustments = editingStack.loadedState?.currentEdit.localAdjustments ?? []
    let layerIndex: Int
    if let existingIndex = self.layerIndex(in: localAdjustments, matching: effect) {
      layerIndex = existingIndex
    } else {
      let id = FeatureID()
      layerID = id
      localAdjustments.append(
        .init(
          id: id,
          maskTree: .init(root: .brush(.init())),
          effectPipeline: effect
        )
      )
      layerIndex = localAdjustments.index(before: localAdjustments.endIndex)
    }

    localAdjustments[layerIndex].isEnabled = true
    localAdjustments[layerIndex].maskTree.appendCanvasBrushStroke(record.brushMaskStroke)
    editingStack.set(localAdjustments: localAdjustments)
  }

  /// Deliberately updates the tracked layer's effect pipeline.
  func updateEffect(
    _ effect: EffectPipeline,
    in editingStack: EditingStack
  ) {
    var localAdjustments = editingStack.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = layerIndex(in: localAdjustments, matching: effect) else {
      return
    }

    guard localAdjustments[layerIndex].effectPipeline != effect else {
      return
    }

    localAdjustments[layerIndex].effectPipeline = effect
    editingStack.set(localAdjustments: localAdjustments)
  }

  /// The effect pipeline persisted on the tracked layer, if one exists.
  func committedEffect(
    matching effect: EffectPipeline,
    in loadedState: EditingStack.Loaded
  ) -> EffectPipeline? {
    let localAdjustments = loadedState.currentEdit.localAdjustments
    guard let layerIndex = layerIndex(in: localAdjustments, matching: effect) else {
      return nil
    }

    return localAdjustments[layerIndex].effectPipeline
  }

  /// The tracked layer's strokes in source/canvas coordinates.
  func committedRecords(
    matching effect: EffectPipeline?,
    in editingStack: EditingStack?
  ) -> [EditingCanvasStrokeRecord] {
    guard let effect else {
      return []
    }

    let localAdjustments = editingStack?.loadedState?.currentEdit.localAdjustments ?? []
    guard let layerIndex = layerIndex(in: localAdjustments, matching: effect) else {
      return []
    }

    return localAdjustments[layerIndex].maskTree.canvasBrushStrokes.map {
      EditingCanvasStrokeRecord(brushMaskStroke: $0)
    }
  }

  /// Finds the tracked layer by its remembered id, falling back to effect
  /// identity and adopting the found layer.
  func layerIndex(
    in localAdjustments: [LocalAdjustmentFeature],
    matching effect: EffectPipeline
  ) -> Int? {
    if
      let layerID,
      let index = localAdjustments.firstIndex(where: { $0.id == layerID })
    {
      return index
    }

    guard let index = localAdjustments.firstIndex(where: { layer in
      layer.effectPipeline.editingCanvasEffectIdentity == effect.editingCanvasEffectIdentity
    }) else {
      return nil
    }

    layerID = localAdjustments[index].id
    return index
  }
}

// MARK: - Brush-rooted MaskTree access

/// Canvas tooling authors brush-rooted mask trees only. These accessors keep
/// that assumption in one place; composite trees (generated masks, future
/// refinements) pass through untouched and are conservatively treated as
/// selecting something.
extension MaskTree {

  /// The strokes of a brush-rooted tree; empty for composite trees.
  var canvasBrushStrokes: [BrushMaskStroke] {
    guard case let .brush(mask) = root else {
      return []
    }
    return mask.strokes
  }

  /// Appends a stroke to a brush-rooted tree. Composite trees are not
  /// editable by the canvas; appending to one is a programmer error.
  mutating func appendCanvasBrushStroke(_ stroke: BrushMaskStroke) {
    guard case var .brush(mask) = root else {
      assertionFailure("The canvas can only append strokes to a brush-rooted mask tree.")
      return
    }
    mask.strokes.append(stroke)
    root = .brush(mask)
  }

  /// Whether the mask cannot select anything: a brush-rooted tree with no
  /// strokes. Composite trees are conservatively treated as non-empty.
  var canvasIsEffectivelyEmpty: Bool {
    guard case let .brush(mask) = root else {
      return false
    }
    return mask.strokes.isEmpty
  }
}
