import CoreGraphics
import CoreImage
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

@MainActor
struct ParametricFeatureEditorModelTests {

  @Test func `Rows project canonical document with source and output anchors`() {
    let model = ParametricFeatureEditorModel(editingStack: makeStack())

    #expect(model.rows.map(\.id) == [
      FeatureID(rawValue: "brightroom.parametric-editor.source"),
      EditingFeatureTree.globalEffectsNodeID,
      EditingFeatureTree.finalCropNodeID,
      FeatureID(rawValue: "brightroom.parametric-editor.output"),
    ])
  }

  @Test func `Final crop selection resolves to CropView crop focus`() {
    let model = ParametricFeatureEditorModel(editingStack: makeStack())

    #expect(
      model.currentFeatureFocus == CropViewFeatureFocus(
        viewingPoint: .output,
        editingTarget: .crop(id: EditingFeatureTree.finalCropNodeID)
      )
    )
  }

  @Test func `Adding global adjustment creates child row and stable feature id`() {
    let stack = makeStack()
    let model = ParametricFeatureEditorModel(editingStack: stack)

    model.addGlobalAdjustment(.exposure)

    let exposure = stack.loadedState?.currentEdit.effects.first(of: ExposureFeature.self)
    #expect(exposure?.id == ParametricFeatureEditorAdjustmentParameter.exposure.featureID)
    #expect(abs((exposure?.value ?? 0) - 0.36) < 0.0001)
    #expect(model.selection.activeFeatureID == ParametricFeatureEditorAdjustmentParameter.exposure.featureID)
    #expect(
      model.rows.contains {
        $0.kind == .globalAdjustment(.exposure)
          && $0.id == ParametricFeatureEditorAdjustmentParameter.exposure.featureID
      }
    )

    model[globalAdjustment: .exposure] = 50
    #expect(stack.loadedState?.currentEdit.effects.first(of: ExposureFeature.self)?.value == 0.9)
  }

  @Test func `Adding blur mask inserts a local adjustment before final crop and edits its mask`() {
    let stack = makeStack()
    let model = ParametricFeatureEditorModel(editingStack: stack)

    model.addBlurMaskAdjustment()

    let features = stack.loadedState?.currentEdit.features ?? []
    let localAdjustment = stack.loadedState?.currentEdit.localAdjustments.first
    #expect(localAdjustment != nil)
    #expect(features.map(\.id) == [
      EditingFeatureTree.globalEffectsNodeID,
      localAdjustment?.id,
      EditingFeatureTree.finalCropNodeID,
    ])
    #expect(model.selection.activeFeatureID == localAdjustment?.id)
    #expect(model.selection.mode == .mask)
    #expect(
      model.currentFeatureFocus == CropViewFeatureFocus(
        viewingPoint: .output,
        editingTarget: .localAdjustmentMask(
          id: localAdjustment?.id,
          seedEffect: localAdjustment?.effectPipeline,
          insertBefore: EditingFeatureTree.finalCropNodeID
        )
      )
    )
  }

  @Test func `Adding a crop inserts a repeated crop before final crop and edits it`() {
    let stack = makeStack()
    let model = ParametricFeatureEditorModel(editingStack: stack)

    model.addCrop()

    let features = stack.loadedState?.currentEdit.features ?? []
    let insertedCropID = model.selection.activeFeatureID
    #expect(features.map(\.id) == [
      EditingFeatureTree.globalEffectsNodeID,
      insertedCropID,
      EditingFeatureTree.finalCropNodeID,
    ])
    // The inserted crop starts as an identity crop over the final crop's input
    // domain (the full 40x20 source, since there is no upstream crop).
    let insertedCrop = stack.loadedState?.currentEdit.features
      .compactMap { feature -> CropFeature? in
        guard case let .domain(domain) = feature else { return nil }
        return domain as? CropFeature
      }
      .first { $0.id == insertedCropID }
    #expect(insertedCrop?.cropRect == CGRect(x: 0, y: 0, width: 40, height: 20))

    #expect(model.selection.mode == .crop)
    // The row projects as an editable crop and the focus targets it, viewing its
    // input domain (after global effects, before this crop).
    #expect(model.rows.contains { $0.id == insertedCropID && $0.kind == .crop })
    #expect(
      model.currentFeatureFocus == CropViewFeatureFocus(
        viewingPoint: .after(EditingFeatureTree.globalEffectsNodeID),
        editingTarget: .crop(id: insertedCropID)
      )
    )
  }

  @Test func `Crop over an upstream crop previews the upstream crop output as its input domain`() {
    let stack = makeStack()
    let model = ParametricFeatureEditorModel(editingStack: stack)

    // With only the final crop, nothing upstream reshapes the domain, so the
    // crop surface uses the default source path.
    #expect(
      model.cropViewDocument.snapshot?.cropEditingInputFeatures(
        forTarget: EditingFeatureTree.finalCropNodeID
      ) == nil
    )

    model.addCrop()
    let cropID = model.selection.activeFeatureID

    let snapshot = model.cropViewDocument.snapshot
    // The added crop has no upstream crop -> default source path.
    #expect(snapshot?.cropEditingInputFeatures(forTarget: cropID) == nil)
    // The final crop now sits downstream of the added crop, so its crop surface
    // must partial-evaluate that crop's output as the input domain.
    let finalInput = snapshot?.cropEditingInputFeatures(
      forTarget: EditingFeatureTree.finalCropNodeID
    )
    #expect(finalInput != nil)
    #expect(finalInput?.contains { $0.id == cropID } == true)
  }

  @Test func `Removing an added crop restores the canonical rows and final crop focus`() {
    let stack = makeStack()
    let model = ParametricFeatureEditorModel(editingStack: stack)

    model.addCrop()
    let insertedCropID = model.selection.activeFeatureID
    model.removeFeature(id: insertedCropID)

    #expect(stack.loadedState?.currentEdit.features.map(\.id) == [
      EditingFeatureTree.globalEffectsNodeID,
      EditingFeatureTree.finalCropNodeID,
    ])
    #expect(model.selection.activeFeatureID == EditingFeatureTree.finalCropNodeID)
    #expect(model.selection.mode == .crop)
    // The final crop is not removable.
    model.removeFeature(id: EditingFeatureTree.finalCropNodeID)
    #expect(stack.loadedState?.currentEdit.features.contains { $0.id == EditingFeatureTree.finalCropNodeID } == true)
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
