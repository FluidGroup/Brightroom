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

  /// The prefix of features evaluated to produce the input domain of the
  /// feature identified by `featureID` — every node before it.
  ///
  /// Returns nil (use the default source-plus-effects path) unless an *upstream
  /// crop* reshaped the input domain away from the source extent. This is the
  /// criterion — not whether the target is the final crop: a feature authored
  /// over an upstream crop must be shown against that crop's already-cropped
  /// output, while a feature with no upstream crop still works against the full
  /// source (which the default path already renders, preserving the single-crop
  /// PhotosCrop behavior including its live local-adjustment preview).
  func inputDomainFeatures(before featureID: FeatureID?) -> [MainFeature]? {
    guard
      let featureID,
      let prefix = featureTree.inputPrefixFeatureCount(ofFeature: featureID),
      prefix > 0
    else {
      return nil
    }

    let features = Array(featureTree.nodes.prefix(prefix))
    guard features.contains(where: EditingFeatureTree.isCropFeature) else {
      return nil
    }
    return features
  }

  /// The input-domain base image for the feature identified by `featureID`:
  /// every upstream feature evaluated into a single image, so a canvas frames
  /// the already-cropped, already-adjusted result rather than the full source.
  ///
  /// The crop surface passes the edited crop (to frame its input), and the tool
  /// surface passes the edited mask layer (to composite it live over its input)
  /// or the viewport crop (to preview the pre-crop result). Returns nil to use
  /// the default full-source path.
  func inputDomainImage(before featureID: FeatureID?) -> CIImage? {
    guard let features = inputDomainFeatures(before: featureID) else {
      return nil
    }

    let document = EditingDocument(mainTree: MainTree(features: features))
    do {
      let output = try FeatureGraphCompiler().makeOutput(
        from: editingSourceImage.removingExtentOffset(),
        document: document
      )
      return output.image
    } catch {
      return nil
    }
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
  ///
  /// `insertingBefore` names the node a newly created layer is inserted ahead
  /// of — the host's chosen mask authoring domain, carried on the focus. This
  /// boundary is not assumed to be the final crop.
  func appendMaskStroke(
    record: EditingCanvasStrokeRecord,
    effect: EffectPipeline,
    insertingBefore insertionTargetID: FeatureID
  ) {
    strokeCommitPipeline.append(
      record: record,
      effect: effect,
      to: editingStack,
      insertingBefore: insertionTargetID
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
