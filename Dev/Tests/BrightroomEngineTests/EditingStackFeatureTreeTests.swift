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
import XCTest

@testable import BrightroomEngine
@testable import BrightroomParametric

final class EditingStackFeatureTreeTests: XCTestCase {

  private func makeEdit(
    localAdjustmentIDs: [FeatureID] = []
  ) -> EditingStack.Edit {
    var edit = EditingStack.Edit.test(imageSize: CGSize(width: 1200, height: 800))
    edit.localAdjustments = localAdjustmentIDs.map { id in
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
    }
    return edit
  }

  // MARK: - Projection

  func testProjectionOrderMatchesRenderOrder() {
    let layerA = FeatureID()
    let layerB = FeatureID()
    let edit = makeEdit(localAdjustmentIDs: [layerA, layerB])

    let tree = EditingFeatureTree(edit: edit)

    XCTAssertEqual(tree.nodes.count, 4)
    XCTAssertEqual(tree.nodes[0].id, EditingFeatureTree.globalEffectsNodeID)
    XCTAssertEqual(tree.nodes[1].id, layerA)
    XCTAssertEqual(tree.nodes[2].id, layerB)
    XCTAssertEqual(tree.nodes[3].id, EditingFeatureTree.finalCropNodeID)
  }

  func testProjectionIsStableAcrossEquivalentEdits() {
    let layer = FeatureID()

    let treeA = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))
    let treeB = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))

    XCTAssertEqual(treeA, treeB)
    XCTAssertEqual(treeA.nodes.map(\.id), treeB.nodes.map(\.id))
  }

  func testAccessors() {
    let layer = FeatureID()
    let edit = makeEdit(localAdjustmentIDs: [layer])
    let tree = EditingFeatureTree(edit: edit)

    XCTAssertEqual(tree.finalCrop, edit.crop)
    XCTAssertEqual(tree.globalEffects, edit.effects)
    XCTAssertEqual(tree.localAdjustmentNodes.count, 1)
    XCTAssertEqual(
      tree.localAdjustment(id: layer),
      edit.localAdjustments[0]
    )
  }

  // MARK: - Point resolution

  func testAppliedFeatureCount() {
    let layer = FeatureID()
    let tree = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))

    XCTAssertEqual(tree.appliedFeatureCount(at: .source), 0)
    XCTAssertEqual(
      tree.appliedFeatureCount(at: .after(EditingFeatureTree.globalEffectsNodeID)),
      1
    )
    XCTAssertEqual(
      tree.appliedFeatureCount(at: .after(layer)),
      2
    )
    XCTAssertEqual(tree.appliedFeatureCount(at: .output), 3)
    XCTAssertNil(tree.appliedFeatureCount(at: .after(FeatureID(rawValue: "unknown"))))
  }

  func testPointIncludesFeature() {
    let layer = FeatureID()
    let tree = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))
    let layerNodeID = layer
    let cropNodeID = EditingFeatureTree.finalCropNodeID

    XCTAssertEqual(tree.point(.output, includes: cropNodeID), true)
    XCTAssertEqual(tree.point(.source, includes: cropNodeID), false)
    XCTAssertEqual(tree.point(.after(layerNodeID), includes: cropNodeID), false)
    XCTAssertEqual(tree.point(.after(cropNodeID), includes: cropNodeID), true)
    XCTAssertEqual(tree.point(.after(layerNodeID), includes: layerNodeID), true)
    XCTAssertNil(tree.point(.after(FeatureID(rawValue: "unknown")), includes: cropNodeID))
  }

  // MARK: - Mutations

  func testUpdateCropFeature() {
    var edit = makeEdit()
    let newCrop = CropFeature(
      id: edit.crop.id,
      displayCropRect: CGRect(x: 100, y: 100, width: 400, height: 300),
      imageSize: CGSize(width: 1200, height: 800)
    )

    let result = EditingFeatureTree.updateFeature(
      id: EditingFeatureTree.finalCropNodeID,
      in: &edit
    ) { feature in
      feature = .domain(newCrop)
    }

    XCTAssertTrue(result)
    XCTAssertEqual(edit.crop, newCrop)
  }

  func testUpdateGlobalEffectsFeature() {
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

    XCTAssertTrue(result)
    XCTAssertEqual(edit.effects.first(of: ExposureFeature.self), exposure)
  }

  func testUpdateLocalAdjustmentFeature() {
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

    XCTAssertTrue(result)
    XCTAssertEqual(edit.localAdjustments[0].isEnabled, false)
    XCTAssertEqual(edit.localAdjustments[0].id, layer)
  }

  func testUpdateUnknownFeatureFails() {
    var edit = makeEdit()
    let original = edit

    let result = EditingFeatureTree.updateFeature(
      id: FeatureID(rawValue: "unknown"),
      in: &edit
    ) { _ in
      XCTFail("mutation must not run for unknown features")
    }

    XCTAssertFalse(result)
    XCTAssertEqual(edit, original)
  }

  func testRemoveLocalAdjustmentFeature() {
    let layer = FeatureID()
    var edit = makeEdit(localAdjustmentIDs: [layer])

    let result = EditingFeatureTree.removeFeature(
      id: layer,
      from: &edit
    )

    XCTAssertTrue(result)
    XCTAssertTrue(edit.localAdjustments.isEmpty)
  }

  func testFinalCropIsNotRemovable() {
    var edit = makeEdit()
    let original = edit

    XCTAssertFalse(
      EditingFeatureTree.removeFeature(id: EditingFeatureTree.finalCropNodeID, from: &edit)
    )
    XCTAssertEqual(edit, original)
  }

  func testGlobalEffectsIsRemovableAndEffectsFallBackToNeutral() {
    var edit = makeEdit()

    XCTAssertTrue(
      EditingFeatureTree.removeFeature(id: EditingFeatureTree.globalEffectsNodeID, from: &edit)
    )
    XCTAssertEqual(edit.effects, .init())

    // The canonical projection re-creates the feature before the final crop.
    var pipeline = EffectPipeline()
    pipeline.set(BrightnessFeature(value: 0.1))
    edit.effects = pipeline
    XCTAssertEqual(edit.effects, pipeline)
    if case .domain = edit.features.last {
      // The crop domain feature remains last.
    } else {
      XCTFail("The final feature must be the crop domain.")
    }
  }
}
