import CoreGraphics
import CoreImage

import BrightroomEngine
import BrightroomParametric

/// Read-only document state consumed by `CropView`.
///
/// The snapshot is a stable projection of the current edit for one UI update.
/// It intentionally carries FeatureTree vocabulary, not `EditingStack`, so the
/// crop canvas can render and edit a focused feature without knowing which
/// owner stores history, undo, or persistence.
struct CropViewDocumentSnapshot {

  /// The downsampled, display-oriented source image used by live canvas
  /// rendering.
  var editingSourceImage: CIImage

  /// The crop used as CropView's visible display frame.
  ///
  /// This is currently PhotosCrop's final crop. A host may still direct edits
  /// at another crop node through `CropViewFeatureFocus`.
  var displayCrop: CropFeature

  /// The current parametric feature tree.
  var featureTree: EditingFeatureTree

  /// The image size used by crop geometry.
  var imageSize: CGSize

  /// Global effects evaluated by the canvas preview.
  var effects: EffectPipeline

  /// Local adjustment layers in the current edit graph.
  var localAdjustments: [LocalAdjustmentFeature]

  init?(
    loadedState: EditingStack.Loaded
  ) {
    let tree = EditingFeatureTree(edit: loadedState.currentEdit)
    guard let displayCrop = tree.finalCrop else {
      return nil
    }

    self.editingSourceImage = loadedState.editingSourceImage
    self.displayCrop = displayCrop
    self.featureTree = tree
    self.imageSize = loadedState.currentEdit.imageSize
    self.effects = loadedState.currentEdit.effects
    self.localAdjustments = loadedState.currentEdit.localAdjustments
  }

  /// The crop feature addressed by a FeatureTree node identity.
  func cropFeature(id: FeatureID) -> CropFeature? {
    featureTree.crop(id: id)
  }
}

/// The document boundary used by `CropView`.
///
/// The class owns the bridge from CropView's display/editing contract to
/// Brightroom's `EditingStack`: it exposes read-only snapshots and accepts
/// explicit FeatureTree editing commands.
///
/// A hosted `CropView` is the single writer for its active crop target while it
/// is mounted. External crop mutation during that editing session is
/// unsupported; higher-level tools should route crop edits through this
/// document boundary, then use `EditingStack` history for committed checkpoints.
@MainActor
final class CropViewDocument {

  private let editingStack: EditingStack
  private let strokeCommitPipeline = EditingCanvasStrokeCommitPipeline()

  init(editingStack: EditingStack) {
    self.editingStack = editingStack
  }

  /// The latest edit projection available to the crop canvas.
  var snapshot: CropViewDocumentSnapshot? {
    editingStack.loadedState.flatMap(CropViewDocumentSnapshot.init)
  }

  /// Starts any asynchronous source-image preparation required before a
  /// snapshot can be produced.
  func start() {
    editingStack.start()
  }

  /// Renders the current document after pending CropView edits have been
  /// committed by the caller.
  func renderImage() async throws -> BrightRoomImageRenderer.Rendered? {
    try await editingStack.makeRenderer().render()
  }

  /// Replaces an existing crop feature by FeatureTree node identity.
  @discardableResult
  func updateCropFeature(
    id: FeatureID,
    with crop: CropFeature
  ) -> Bool {
    guard editingStack.featureTree?.crop(id: id) != nil else {
      return false
    }

    return editingStack.updateFeature(id: id) { feature in
      var crop = crop
      crop.id = id
      feature = .domain(crop)
    }
  }

  /// Forgets the tracked mask layer used by subsequent brush commits.
  func resetMaskLayerTracking() {
    strokeCommitPipeline.resetLayerTracking()
  }

  /// Uses an existing local-adjustment layer as the next mask commit target.
  func adoptMaskLayer(id: FeatureID) {
    strokeCommitPipeline.adoptLayer(id: id)
  }

  /// Appends a brush stroke to the active local-adjustment mask layer.
  func appendMaskStroke(
    record: EditingCanvasStrokeRecord,
    effect: EffectPipeline
  ) {
    strokeCommitPipeline.append(
      record: record,
      effect: effect,
      to: editingStack,
      insertingBefore: EditingFeatureTree.finalCropNodeID
    )
  }

  /// The effect pipeline persisted on the active local-adjustment mask layer.
  func committedMaskEffect(
    matching effect: EffectPipeline
  ) -> EffectPipeline? {
    guard let loadedState = editingStack.loadedState else {
      return nil
    }

    return strokeCommitPipeline.committedEffect(
      matching: effect,
      in: loadedState
    )
  }

  /// The active local-adjustment mask layer's strokes in source coordinates.
  func committedMaskRecords(
    matching effect: EffectPipeline?
  ) -> [EditingCanvasStrokeRecord] {
    strokeCommitPipeline.committedRecords(
      matching: effect,
      in: editingStack
    )
  }

  /// Returns the current snapshot for a branch that has already checked the
  /// document is loaded.
  func requireSnapshotForLoadedCropView(
    file: StaticString = #fileID,
    line: UInt = #line
  ) -> CropViewDocumentSnapshot {
    assert(
      snapshot != nil,
      "SwiftUI loaded branch created or updated a CropView while CropViewDocument.snapshot was nil.",
      file: file,
      line: line
    )
    return snapshot!
  }
}
