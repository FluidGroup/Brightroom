//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import CoreGraphics
import CoreImage

import BrightroomEngine
import BrightroomParametric

/// PhotosCrop's policy layer over `EditingStack`'s generic FeatureTree.
///
/// PhotosCrop views depend on this model rather than talking to `EditingStack`
/// directly. The stack still owns the document, history, and renderer; this
/// model owns the Photos-style interpretation of that document: which node is
/// the final crop, which effect bundle backs filter/adjustment controls, and
/// how the blur mask layer is found or cleared.
@MainActor
public final class PhotosCropEditingModel {

  /// The stack whose current edit is interpreted as a PhotosCrop document.
  private let editingStack: EditingStack

  /// The stable crop-canvas document for this PhotosCrop editing session.
  private let cropViewDocumentStore: CropViewDocument

  public init(editingStack: EditingStack) {
    self.editingStack = editingStack
    self.cropViewDocumentStore = CropViewDocument(editingStack: editingStack)
  }

  /// The crop-canvas document used at the boundary where PhotosCrop hosts the
  /// reusable `CropView`.
  ///
  /// Keep this access narrow: PhotosCrop-specific feature choices should be
  /// expressed as model operations, not as ad-hoc stack mutations in views.
  var cropViewDocument: CropViewDocument {
    cropViewDocumentStore
  }

  /// The current loaded state, if the stack has finished image preparation.
  var loadedState: EditingStack.Loaded? {
    editingStack.loadedState
  }

  /// The current FeatureTree projection owned by PhotosCrop's editing policy.
  ///
  /// This is projected from the stack at access time so CropView commits, undo,
  /// redo, and external stack mutations cannot leave the model with a stale
  /// tree. PhotosCrop still owns *how* the tree is interpreted and edited.
  var featureTree: EditingFeatureTree? {
    loadedState.map { EditingFeatureTree(edit: $0.currentEdit) }
  }

  /// Whether the editor has an image ready for controls and canvas display.
  var isLoaded: Bool {
    loadedState != nil
  }

  /// The original oriented source aspect ratio used by the crop controls.
  var originalAspectRatio: PixelAspectRatio? {
    loadedState.map { PixelAspectRatio($0.imageSize) }
  }

  /// The thumbnail base image used by filter swatches.
  var filterPreviewBaseImage: CIImage? {
    loadedState?.thumbnailImage
  }

  /// The global effects node exposed to filter and adjustment controls.
  var currentEffects: EffectPipeline? {
    featureTree?.globalEffects ?? loadedState?.currentEdit.effects
  }

  /// Starts image preparation.
  func start() {
    editingStack.start()
  }

  /// Commits the current PhotosCrop document as an undo checkpoint when needed.
  func commitCurrentEditIfNeeded() {
    editingStack.commitCurrentEditIfNeeded()
  }

  /// The `CropView` focus for a PhotosCrop toolbar mode.
  func featureFocus(for mode: PhotosCropEditingMode) -> CropViewFeatureFocus {
    switch mode {
    case .crop:
      return .init(
        viewingPoint: .output,
        editingTarget: .crop(id: EditingFeatureTree.finalCropNodeID)
      )
    case .blurMasking:
      return .init(
        viewingPoint: .output,
        editingTarget: .localAdjustmentMask(
          id: nil,
          seedEffect: CropViewMaskingDefaults.blurEffectPipeline,
          insertBefore: EditingFeatureTree.finalCropNodeID
        )
      )
    case .filters, .adjustments:
      return .init(viewingPoint: .output)
    }
  }

  /// Whether the final crop differs from PhotosCrop's Reset target.
  ///
  /// Reset only restores the crop geometry, so this intentionally ignores
  /// effects and mask layers.
  func hasCropChanges(tolerance: CGFloat = 1) -> Bool {
    guard let crop = finalCropEditingState else {
      return false
    }

    let initial = crop.makeInitial()
    return crop.rotation != initial.rotation
      || abs(crop.adjustmentAngle.radians - initial.adjustmentAngle.radians) > 0.0001
      || abs(crop.cropExtent.minX - initial.cropExtent.minX) > tolerance
      || abs(crop.cropExtent.minY - initial.cropExtent.minY) > tolerance
      || abs(crop.cropExtent.width - initial.cropExtent.width) > tolerance
      || abs(crop.cropExtent.height - initial.cropExtent.height) > tolerance
  }

  /// Writes the selected preset into PhotosCrop's global-effects node.
  func selectFilterPreset(_ preset: PresetFeature?) {
    updateGlobalEffects { effects in
      guard effects.first(of: PresetFeature.self)?.identifier != preset?.identifier else {
        return
      }
      effects.set(
        preset,
        insertionIndex: PhotosCropEffectOrder.insertionIndex(for: PresetFeature.self)
      )
    }
  }

  /// Writes an adjustment slider value into PhotosCrop's global-effects node.
  func setAdjustmentValue(
    _ sliderValue: Double,
    parameter: PhotosCropAdjustmentParameter
  ) {
    updateGlobalEffects { effects in
      parameter.apply(sliderValue: sliderValue, to: &effects)
    }
  }

  /// Removes PhotosCrop's blur-mask local adjustment layer, if one exists.
  func clearBlurMaskingLayer() {
    let blurIdentity = CropViewMaskingDefaults.blurEffectPipeline.editingCanvasEffectIdentity
    let localAdjustments = featureTree?.localAdjustments ?? []
    let remainingLocalAdjustments = localAdjustments.filter {
      $0.effectPipeline.editingCanvasEffectIdentity != blurIdentity
    }

    guard remainingLocalAdjustments != localAdjustments else {
      return
    }

    replaceLocalAdjustments(remainingLocalAdjustments)
  }

  /// Mutates PhotosCrop's global-effects node.
  private func updateGlobalEffects(
    _ mutate: (inout EffectPipeline) -> Void
  ) {
    guard var edit = loadedState?.currentEdit else {
      return
    }

    if edit.updateFeature(id: EditingFeatureTree.globalEffectsNodeID, mutate: { feature in
      if
        case let .effect(effect) = feature,
        var bundle = effect as? EffectPipelineFeature
      {
        mutate(&bundle.pipeline)
        feature = .effect(bundle)
      }
    }) {
      applyEditIfChanged(edit)
      return
    }

    var pipeline = EffectPipeline()
    mutate(&pipeline)
    guard pipeline.isEmpty == false else {
      return
    }

    edit.insertFeature(
      .effect(
        EffectPipelineFeature(
          id: EditingFeatureTree.globalEffectsNodeID,
          pipeline: pipeline
        )
      ),
      at: globalEffectsInsertionIndex(in: edit)
    )
    applyEditIfChanged(edit)
  }

  /// Rewrites PhotosCrop's local-adjustment layer list in the pre-final-crop
  /// domain.
  private func replaceLocalAdjustments(
    _ localAdjustments: [LocalAdjustmentFeature]
  ) {
    guard var edit = loadedState?.currentEdit else {
      return
    }

    EditingFeatureTree.replaceLocalAdjustments(
      localAdjustments,
      in: &edit,
      insertingBefore: EditingFeatureTree.finalCropNodeID
    )
    applyEditIfChanged(edit)
  }

  /// PhotosCrop inserts global effects before local adjustments and the final
  /// crop. This keeps effects global to the pre-final-crop image domain without
  /// teaching `EditingStack.Edit` where PhotosCrop wants that node to live.
  private func globalEffectsInsertionIndex(in edit: EditingStack.Edit) -> Int {
    let features = edit.features
    let finalCropIndex = features.firstIndex {
      $0.id == EditingFeatureTree.finalCropNodeID
    } ?? features.count

    for index in features.indices where index < finalCropIndex {
      if case .localAdjustment = features[index] {
        return index
      }
    }

    return finalCropIndex
  }

  private func applyEditIfChanged(_ edit: EditingStack.Edit) {
    if editingStack.loadedState?.currentEdit != edit {
      editingStack.loadedState?.currentEdit = edit
    }
  }

  private var finalCropEditingState: CropEditingState? {
    guard
      let loadedState,
      let crop = featureTree?.finalCrop
    else {
      return nil
    }

    return CropEditingState(
      cropFeature: crop,
      imageSize: loadedState.currentEdit.imageSize
    )
  }
}

extension SwiftUICropView {

  /// Creates the reusable crop canvas through PhotosCrop's editing model.
  ///
  /// This keeps PhotosCrop views depending on `PhotosCropEditingModel`; the
  /// model is the narrow boundary that maps PhotosCrop policy onto the shared
  /// crop canvas document.
  init(
    editingModel: PhotosCropEditingModel,
    isGuideInteractionEnabled: Bool
  ) {
    self.init(
      document: editingModel.cropViewDocument,
      isGuideInteractionEnabled: isGuideInteractionEnabled
    )
  }
}
