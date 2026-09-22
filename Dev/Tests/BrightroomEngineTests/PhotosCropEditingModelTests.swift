import CoreImage
import CoreGraphics
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

@MainActor
struct PhotosCropEditingModelTests {

  @Test func `PhotosCrop model reads loaded stack state`() {
    let model = PhotosCropEditingModel(editingStack: makeStack())

    #expect(model.isLoaded)
  }

  @Test func `PhotosCrop model owns editing stack for view dependency`() {
    weak var retainedStack: EditingStack?
    let model: PhotosCropEditingModel

    do {
      let stack = makeStack()
      retainedStack = stack
      model = PhotosCropEditingModel(editingStack: stack)
    }

    #expect(retainedStack != nil)
    #expect(model.isLoaded)
  }

  @Test func `Feature focus is resolved by PhotosCrop policy`() {
    let model = PhotosCropEditingModel(editingStack: makeStack())

    #expect(
      model.featureFocus(for: .crop) == CropViewFeatureFocus(
        viewingPoint: .output,
        editingTarget: .crop(id: EditingFeatureTree.finalCropNodeID)
      )
    )

    #expect(
      model.featureFocus(for: .blurMasking) == CropViewFeatureFocus(
        viewingPoint: .output,
        editingTarget: .localAdjustmentMask(
          id: nil,
          seedEffect: CropViewMaskingDefaults.blurEffectPipeline
        )
      )
    )

    #expect(model.featureFocus(for: .filters) == CropViewFeatureFocus(viewingPoint: .output))
    #expect(model.featureFocus(for: .adjustments) == CropViewFeatureFocus(viewingPoint: .output))
  }

  @Test func `Global effect edits go through PhotosCrop model`() {
    let stack = makeStack()
    let model = PhotosCropEditingModel(editingStack: stack)
    let preset = PresetFeature(
      id: FeatureID(rawValue: "test-preset-feature"),
      name: "Test",
      identifier: "test",
      effects: [BrightnessFeature(value: 0.1)]
    )

    model.selectFilterPreset(preset)
    model.setAdjustmentValue(50, parameter: .exposure)

    let effects = stack.loadedState?.currentEdit.effects
    #expect(effects?.first(of: PresetFeature.self)?.identifier == "test")
    #expect(effects?.first(of: ExposureFeature.self)?.value == 0.9)
  }

  @Test func `Global effect edits insert missing PhotosCrop node before local adjustments`() {
    let stack = makeStack()
    let model = PhotosCropEditingModel(editingStack: stack)
    let adjustment = LocalAdjustmentFeature(
      id: FeatureID(rawValue: "local-adjustment"),
      maskTree: .init(root: .brush(.init())),
      effectPipeline: EffectPipeline(effects: [GaussianBlurFeature(radius: 10)])
    )

    var loaded = stack.loadedState!
    var edit = loaded.currentEdit
    #expect(
      EditingFeatureTree.removeFeature(
        id: EditingFeatureTree.globalEffectsNodeID,
        from: &edit
      )
    )
    EditingFeatureTree.replaceLocalAdjustments(
      [adjustment],
      in: &edit,
      insertingBefore: EditingFeatureTree.finalCropNodeID
    )
    loaded.currentEdit = edit
    stack.loadedState = loaded

    model.setAdjustmentValue(50, parameter: .exposure)

    let features = stack.loadedState?.currentEdit.features
    #expect(features?.map(\.id) == [
      EditingFeatureTree.globalEffectsNodeID,
      adjustment.id,
      EditingFeatureTree.finalCropNodeID,
    ])
    #expect(
      stack.loadedState?.currentEdit.effects.first(of: ExposureFeature.self)?.value == 0.9
    )
  }

  @Test func `PhotosCrop model commits undo checkpoints at tool boundary`() {
    let stack = makeStack()
    let model = PhotosCropEditingModel(editingStack: stack)
    let preset = PresetFeature(
      id: FeatureID(rawValue: "test-preset-feature"),
      name: "Test",
      identifier: "test",
      effects: [BrightnessFeature(value: 0.1)]
    )

    model.selectFilterPreset(preset)
    model.commitCurrentEditIfNeeded()

    #expect(stack.loadedState?.canUndo == true)

    stack.undo()
    #expect(stack.loadedState?.currentEdit.effects.first(of: PresetFeature.self) == nil)

    stack.redo()
    #expect(
      stack.loadedState?.currentEdit.effects.first(of: PresetFeature.self)?.identifier == "test"
    )
  }

  @Test func `Blur mask clear removes only PhotosCrop blur layer`() {
    let stack = makeStack()
    let model = PhotosCropEditingModel(editingStack: stack)
    let blurLayer = LocalAdjustmentFeature(
      id: FeatureID(rawValue: "blur-layer"),
      maskTree: .init(root: .brush(.init())),
      effectPipeline: CropViewMaskingDefaults.blurEffectPipeline
    )
    let exposureLayer = LocalAdjustmentFeature(
      id: FeatureID(rawValue: "exposure-layer"),
      maskTree: .init(root: .brush(.init())),
      effectPipeline: EffectPipeline(effects: [ExposureFeature(value: 0.2)])
    )

    var loaded = stack.loadedState!
    var edit = loaded.currentEdit
    edit.setPhotosCropLocalAdjustmentsForTest([blurLayer, exposureLayer])
    loaded.currentEdit = edit
    stack.loadedState = loaded

    model.clearBlurMaskingLayer()

    let remaining = stack.loadedState?.currentEdit.localAdjustments
    #expect(remaining?.map(\.id) == [exposureLayer.id])
  }

  private func makeStack() -> EditingStack {
    let size = CGSize(width: 40, height: 20)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let cgImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor.white.setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
    }.cgImage!
    let sourceCIImage = CIImage(cgImage: cgImage)
    let initialEdit = EditingStack.Edit.test(imageSize: size)
    let loaded = EditingStack.Loaded(
      imageSource: ImageSource(cgImage: cgImage),
      metadata: .init(orientation: .up, imageSize: size),
      initialEditing: initialEdit,
      currentEdit: initialEdit,
      thumbnailCIImage: sourceCIImage,
      editingSourceCGImage: cgImage,
      editingSourceCIImage: sourceCIImage
    )
    let stack = EditingStack(imageProvider: .init(image: UIImage(cgImage: cgImage)))
    stack.loadedState = loaded
    return stack
  }
}
