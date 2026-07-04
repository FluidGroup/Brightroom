//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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
import Foundation
import Testing

@testable import BrightroomEngine
@testable import BrightroomParametric

struct EditingStackFeatureTreeTests {

  private func makeEdit(
    localAdjustmentIDs: [FeatureID] = []
  ) -> EditingStack.Edit {
    var edit = EditingStack.Edit.test(imageSize: CGSize(width: 1200, height: 800))
    edit.setPhotosCropLocalAdjustmentsForTest(localAdjustmentIDs.map { id in
      LocalAdjustmentFeature(
        id: id,
        maskTree: MaskTree(
          root: .brush(
            BrushMask(
              id: .init(rawValue: id.rawValue + ".mask"),
              strokes: [
                BrushMaskStroke(
                  stamps: [CGPoint(x: 10, y: 20)],
                  brush: BrushMaskBrush(diameter: 24, hardness: 0.7, opacity: 0.9)
                )
              ]
            )
          )
        ),
        // The effect id is derived from the layer id so two edits built from
        // the same layer ids are value-equal: parametric features carry
        // identity, and a fresh FeatureID per call would make "equivalent"
        // edits differ by effect identity alone.
        effectPipeline: EffectPipeline(effects: [
          GaussianBlurFeature(id: .init(rawValue: id.rawValue + ".blur"), radius: 10)
        ])
      )
    })
    return edit
  }

  // MARK: - Projection

  @Test func `Projection order matches render order`() {
    let layerA = FeatureID()
    let layerB = FeatureID()
    let edit = makeEdit(localAdjustmentIDs: [layerA, layerB])

    let tree = EditingFeatureTree(edit: edit)

    #expect(tree.nodes.count == 4)
    #expect(tree.nodes[0].id == EditingFeatureTree.globalEffectsNodeID)
    #expect(tree.nodes[1].id == layerA)
    #expect(tree.nodes[2].id == layerB)
    #expect(tree.nodes[3].id == EditingFeatureTree.finalCropNodeID)
  }

  @Test func `Projection is stable across equivalent edits`() {
    let layer = FeatureID()

    let treeA = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))
    let treeB = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))

    #expect(treeA == treeB)
    #expect(treeA.nodes.map(\.id) == treeB.nodes.map(\.id))
  }

  @Test func accessors() {
    let layer = FeatureID()
    let edit = makeEdit(localAdjustmentIDs: [layer])
    let tree = EditingFeatureTree(edit: edit)

    #expect(tree.finalCrop?.id == EditingFeatureTree.finalCropNodeID)
    #expect(tree.globalEffects == edit.effects)
    #expect(tree.localAdjustmentNodes.count == 1)
    #expect(
      tree.localAdjustment(id: layer) == edit.localAdjustments[0]
    )
  }

  // MARK: - Point resolution

  @Test func `Applied feature count`() {
    let layer = FeatureID()
    let tree = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))

    #expect(tree.appliedFeatureCount(at: .source) == 0)
    #expect(
      tree.appliedFeatureCount(at: .after(EditingFeatureTree.globalEffectsNodeID)) == 1
    )
    #expect(
      tree.appliedFeatureCount(at: .after(layer)) == 2
    )
    #expect(tree.appliedFeatureCount(at: .output) == 3)
    #expect(tree.appliedFeatureCount(at: .after(FeatureID(rawValue: "unknown"))) == nil)
  }

  @Test func `Point includes feature`() {
    let layer = FeatureID()
    let tree = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))
    let layerNodeID = layer
    let cropNodeID = EditingFeatureTree.finalCropNodeID

    #expect(tree.point(.output, includes: cropNodeID) == true)
    #expect(tree.point(.source, includes: cropNodeID) == false)
    #expect(tree.point(.after(layerNodeID), includes: cropNodeID) == false)
    #expect(tree.point(.after(cropNodeID), includes: cropNodeID) == true)
    #expect(tree.point(.after(layerNodeID), includes: layerNodeID) == true)
    #expect(tree.point(.after(FeatureID(rawValue: "unknown")), includes: cropNodeID) == nil)
  }

  // MARK: - Mutations

  @Test func `Update crop feature`() {
    var edit = makeEdit()
    let newCrop = CropFeature(
      id: EditingFeatureTree.finalCropNodeID,
      displayCropRect: CGRect(x: 100, y: 100, width: 400, height: 300),
      imageSize: CGSize(width: 1200, height: 800)
    )

    let result = EditingFeatureTree.updateFeature(
      id: EditingFeatureTree.finalCropNodeID,
      in: &edit
    ) { feature in
      feature = .domain(newCrop)
    }

    #expect(result)
    #expect(EditingFeatureTree(edit: edit).finalCrop == newCrop)
  }

  @Test func `Update global effects feature`() {
    var edit = makeEdit()
    let exposure = ExposureFeature(value: 0.5)

    let result = EditingFeatureTree.updateFeature(
      id: EditingFeatureTree.globalEffectsNodeID,
      in: &edit
    ) { feature in
      guard
        case let .effect(effect) = feature,
        var bundle = effect as? EffectPipelineFeature
      else {
        return
      }
      bundle.pipeline.set(exposure)
      feature = .effect(bundle)
    }

    #expect(result)
    #expect(edit.effects.first(of: ExposureFeature.self) == exposure)
  }

  @Test func `Update local adjustment feature`() {
    let layer = FeatureID()
    var edit = makeEdit(localAdjustmentIDs: [layer])

    let result = EditingFeatureTree.updateFeature(
      id: layer,
      in: &edit
    ) { feature in
      guard case var .localAdjustment(value) = feature else {
        return
      }
      value.isEnabled = false
      feature = .localAdjustment(value)
    }

    #expect(result)
    #expect(edit.localAdjustments[0].isEnabled == false)
    #expect(edit.localAdjustments[0].id == layer)
  }

  @Test func `Update unknown feature fails`() {
    var edit = makeEdit()
    let original = edit

    let result = EditingFeatureTree.updateFeature(
      id: FeatureID(rawValue: "unknown"),
      in: &edit
    ) { _ in
      Issue.record("mutation must not run for unknown features")
    }

    #expect(!result)
    #expect(edit == original)
  }

  @Test func `Remove local adjustment feature`() {
    let layer = FeatureID()
    var edit = makeEdit(localAdjustmentIDs: [layer])

    let result = EditingFeatureTree.removeFeature(
      id: layer,
      from: &edit
    )

    #expect(result)
    #expect(edit.localAdjustments.isEmpty)
  }

  @Test func `Final crop is not removable`() {
    var edit = makeEdit()
    let original = edit

    #expect(
      !EditingFeatureTree.removeFeature(id: EditingFeatureTree.finalCropNodeID, from: &edit)
    )
    #expect(edit == original)
  }

  @Test func `Input domain resolves upstream crops`() {
    let source = CGSize(width: 1200, height: 800)
    var edit = makeEdit()

    // Canonical: [globalEffects, finalCrop]. The final crop's input domain is
    // the full source (its only upstream feature is global effects).
    let tree0 = EditingFeatureTree(edit: edit)
    #expect(tree0.inputPrefixFeatureCount(ofFeature: EditingFeatureTree.finalCropNodeID) == 1)
    #expect(tree0.inputPoint(ofFeature: EditingFeatureTree.finalCropNodeID) == .after(EditingFeatureTree.globalEffectsNodeID))
    #expect(tree0.inputDomainSize(ofFeature: EditingFeatureTree.finalCropNodeID, sourceSize: source) == source)

    // Insert an upstream crop that shrinks the domain to 600x400.
    let cropAID = FeatureID(rawValue: "crop.a")
    let finalIndex = edit.features.firstIndex { $0.id == EditingFeatureTree.finalCropNodeID }!
    edit.insertFeature(
      .domain(CropFeature(id: cropAID, cropRect: CGRect(x: 0, y: 0, width: 600, height: 400))),
      at: finalIndex
    )

    let tree = EditingFeatureTree(edit: edit)
    // Crop A's own input domain is still the full source.
    #expect(tree.inputDomainSize(ofFeature: cropAID, sourceSize: source) == source)
    #expect(tree.inputPoint(ofFeature: cropAID) == .after(EditingFeatureTree.globalEffectsNodeID))
    // The final crop now sees Crop A's 600x400 output as its input domain.
    #expect(tree.inputDomainSize(ofFeature: EditingFeatureTree.finalCropNodeID, sourceSize: source) == CGSize(width: 600, height: 400))
    #expect(tree.inputPoint(ofFeature: EditingFeatureTree.finalCropNodeID) == .after(cropAID))
    #expect(tree.inputPrefixFeatureCount(ofFeature: EditingFeatureTree.finalCropNodeID) == 2)

    // Unknown feature.
    #expect(tree.inputDomainSize(ofFeature: FeatureID(rawValue: "nope"), sourceSize: source) == nil)
    #expect(tree.inputPoint(ofFeature: FeatureID(rawValue: "nope")) == nil)
  }

  @Test func `Viewport crop resolves the framing crop per viewing point`() {
    // Canonical single-crop tree: [globalEffects, finalCrop].
    let single = EditingFeatureTree(edit: makeEdit())
    #expect(single.viewportCrop(at: .output)?.id == EditingFeatureTree.finalCropNodeID)
    #expect(single.viewportCrop(at: .source) == nil)
    #expect(single.viewportCrop(at: .after(EditingFeatureTree.finalCropNodeID))?.id == EditingFeatureTree.finalCropNodeID)
    // A point before the final crop (after the global-effects node) has no crop.
    #expect(single.viewportCrop(at: .after(EditingFeatureTree.globalEffectsNodeID)) == nil)

    // Multi-crop tree: [globalEffects, cropA, localAdjustment, finalCrop(=cropC)].
    var edit = makeEdit(localAdjustmentIDs: [FeatureID(rawValue: "mask")])
    let cropAID = FeatureID(rawValue: "viewport.crop.a")
    let maskIndex = edit.features.firstIndex {
      if case .localAdjustment = $0 { return true } else { return false }
    }!
    edit.insertFeature(
      .domain(CropFeature(id: cropAID, cropRect: CGRect(x: 0, y: 0, width: 800, height: 600))),
      at: maskIndex
    )
    let multi = EditingFeatureTree(edit: edit)
    // [globalEffects, cropA, mask, finalCrop]
    #expect(multi.viewportCrop(at: .output)?.id == EditingFeatureTree.finalCropNodeID)
    #expect(multi.viewportCrop(at: .after(cropAID))?.id == cropAID)
    #expect(multi.viewportCrop(at: .after(FeatureID(rawValue: "mask")))?.id == cropAID)
    #expect(multi.viewportCrop(at: .source) == nil)

    // Disabled final crop falls back to the upstream crop.
    edit.updateFeature(id: EditingFeatureTree.finalCropNodeID) { feature in
      guard case let .domain(domain) = feature, var crop = domain as? CropFeature else { return }
      crop.isEnabled = false
      feature = .domain(crop)
    }
    #expect(EditingFeatureTree(edit: edit).viewportCrop(at: .output)?.id == cropAID)
  }

  @Test func `Local adjustments insert before an arbitrary anchor, not just the final crop`() {
    var edit = makeEdit()

    // Build [globalEffects, cropA, finalCrop].
    let cropAID = FeatureID(rawValue: "anchor.crop.a")
    let finalIndex = edit.features.firstIndex { $0.id == EditingFeatureTree.finalCropNodeID }!
    edit.insertFeature(
      .domain(CropFeature(id: cropAID, cropRect: CGRect(x: 0, y: 0, width: 600, height: 400))),
      at: finalIndex
    )

    // Author a mask layer before cropA (a mid-stack anchor), NOT before the
    // final crop — the flexibility CropView's mask insertion anchor exposes.
    let layerID = FeatureID(rawValue: "anchor.layer")
    let layer = LocalAdjustmentFeature(
      id: layerID,
      maskTree: MaskTree(root: .brush(BrushMask(id: FeatureID(rawValue: "anchor.layer.mask")))),
      effectPipeline: EffectPipeline(effects: [
        GaussianBlurFeature(id: FeatureID(rawValue: "anchor.layer.blur"), radius: 10)
      ])
    )
    EditingFeatureTree.replaceLocalAdjustments([layer], in: &edit, insertingBefore: cropAID)

    #expect(edit.features.map(\.id) == [
      EditingFeatureTree.globalEffectsNodeID,
      layerID,
      cropAID,
      EditingFeatureTree.finalCropNodeID,
    ])
  }

  @Test func `Non-final crop feature is removable`() {
    var edit = makeEdit()

    // Insert an additional, repeated crop before the final crop.
    let extraCropID = FeatureID(rawValue: "test.extra-crop")
    let finalCropIndex = edit.features.firstIndex { $0.id == EditingFeatureTree.finalCropNodeID } ?? edit.features.count
    edit.insertFeature(
      .domain(
        CropFeature(
          id: extraCropID,
          cropRect: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
      ),
      at: finalCropIndex
    )
    #expect(EditingFeatureTree(edit: edit).crop(id: extraCropID) != nil)

    let removed = EditingFeatureTree.removeFeature(id: extraCropID, from: &edit)

    #expect(removed)
    #expect(EditingFeatureTree(edit: edit).crop(id: extraCropID) == nil)
    // The final crop survives.
    #expect(EditingFeatureTree(edit: edit).finalCrop != nil)
  }

  @Test func `Global effects is removable and effects fall back to neutral`() {
    var edit = makeEdit()

    #expect(
      EditingFeatureTree.removeFeature(id: EditingFeatureTree.globalEffectsNodeID, from: &edit)
    )
    #expect(edit.effects == .init())

    // The canonical projection re-creates the feature before the final crop.
    var pipeline = EffectPipeline()
    pipeline.set(BrightnessFeature(value: 0.1))
    edit.effects = pipeline
    #expect(edit.effects == pipeline)
    if case .domain = edit.features.last {
      // The crop domain feature remains last.
    } else {
      Issue.record("The final feature must be the crop domain.")
    }
  }
}
