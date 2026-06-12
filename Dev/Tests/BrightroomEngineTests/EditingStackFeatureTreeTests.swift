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
    localAdjustmentIDs: [UUID] = []
  ) -> EditingStack.Edit {
    var edit = EditingStack.Edit(
      crop: .init(imageSize: CGSize(width: 1200, height: 800))
    )
    edit.localAdjustments = localAdjustmentIDs.map { id in
      .init(
        id: id,
        effect: .gaussianBlur(radius: 10),
        mask: .init(
          strokes: [
            .init(
              stamps: [CGPoint(x: 10, y: 20)],
              brush: .init(size: 24, hardness: 0.7, opacity: 0.9)
            )
          ]
        )
      )
    }
    return edit
  }

  // MARK: - Projection

  func testProjectionOrderMatchesRenderOrder() {
    let layerA = UUID()
    let layerB = UUID()
    let edit = makeEdit(localAdjustmentIDs: [layerA, layerB])

    let tree = EditingFeatureTree(edit: edit)

    XCTAssertEqual(tree.nodes.count, 4)
    XCTAssertEqual(tree.nodes[0].id, EditingFeatureTree.globalEffectsNodeID)
    XCTAssertEqual(tree.nodes[1].id, EditingFeatureTree.nodeID(forLocalAdjustment: layerA))
    XCTAssertEqual(tree.nodes[2].id, EditingFeatureTree.nodeID(forLocalAdjustment: layerB))
    XCTAssertEqual(tree.nodes[3].id, EditingFeatureTree.finalCropNodeID)
  }

  func testProjectionIsStableAcrossEquivalentEdits() {
    let layer = UUID()

    let treeA = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))
    let treeB = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))

    XCTAssertEqual(treeA, treeB)
    XCTAssertEqual(treeA.nodes.map(\.id), treeB.nodes.map(\.id))
  }

  func testAccessors() {
    let layer = UUID()
    let edit = makeEdit(localAdjustmentIDs: [layer])
    let tree = EditingFeatureTree(edit: edit)

    XCTAssertEqual(tree.finalCrop, edit.crop)
    XCTAssertEqual(tree.globalEffects, edit.filters)
    XCTAssertEqual(tree.localAdjustmentNodes.count, 1)
    XCTAssertEqual(
      tree.localAdjustment(id: EditingFeatureTree.nodeID(forLocalAdjustment: layer)),
      edit.localAdjustments[0]
    )
  }

  func testLocalAdjustmentNodeIDRoundTrip() {
    let id = UUID()
    let nodeID = EditingFeatureTree.nodeID(forLocalAdjustment: id)

    XCTAssertEqual(EditingFeatureTree.localAdjustmentID(from: nodeID), id)
    XCTAssertNil(EditingFeatureTree.localAdjustmentID(from: EditingFeatureTree.finalCropNodeID))
  }

  // MARK: - Point resolution

  func testAppliedFeatureCount() {
    let layer = UUID()
    let tree = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))

    XCTAssertEqual(tree.appliedFeatureCount(at: .source), 0)
    XCTAssertEqual(
      tree.appliedFeatureCount(at: .after(EditingFeatureTree.globalEffectsNodeID)),
      1
    )
    XCTAssertEqual(
      tree.appliedFeatureCount(at: .after(EditingFeatureTree.nodeID(forLocalAdjustment: layer))),
      2
    )
    XCTAssertEqual(tree.appliedFeatureCount(at: .output), 3)
    XCTAssertNil(tree.appliedFeatureCount(at: .after(FeatureID(rawValue: "unknown"))))
  }

  func testPointIncludesFeature() {
    let layer = UUID()
    let tree = EditingFeatureTree(edit: makeEdit(localAdjustmentIDs: [layer]))
    let layerNodeID = EditingFeatureTree.nodeID(forLocalAdjustment: layer)
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
    var newCrop = edit.crop
    newCrop.updateCropExtent(CGRect(x: 100, y: 100, width: 400, height: 300))

    let result = EditingFeatureTree.updateFeature(
      id: EditingFeatureTree.finalCropNodeID,
      in: &edit
    ) { payload in
      payload = .crop(newCrop)
    }

    XCTAssertTrue(result)
    XCTAssertEqual(edit.crop, newCrop)
  }

  func testUpdateGlobalEffectsFeature() {
    var edit = makeEdit()
    var exposure = FilterExposure()
    exposure.value = 0.5

    let result = EditingFeatureTree.updateFeature(
      id: EditingFeatureTree.globalEffectsNodeID,
      in: &edit
    ) { payload in
      guard case var .globalEffects(filters) = payload else {
        return
      }
      filters.exposure = exposure
      payload = .globalEffects(filters)
    }

    XCTAssertTrue(result)
    XCTAssertEqual(edit.filters.exposure, exposure)
  }

  func testUpdateLocalAdjustmentFeature() {
    let layer = UUID()
    var edit = makeEdit(localAdjustmentIDs: [layer])

    let result = EditingFeatureTree.updateFeature(
      id: EditingFeatureTree.nodeID(forLocalAdjustment: layer),
      in: &edit
    ) { payload in
      guard case var .localAdjustment(value) = payload else {
        return
      }
      value.isEnabled = false
      payload = .localAdjustment(value)
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
    let layer = UUID()
    var edit = makeEdit(localAdjustmentIDs: [layer])

    let result = EditingFeatureTree.removeFeature(
      id: EditingFeatureTree.nodeID(forLocalAdjustment: layer),
      from: &edit
    )

    XCTAssertTrue(result)
    XCTAssertTrue(edit.localAdjustments.isEmpty)
  }

  func testStructuralFeaturesAreNotRemovable() {
    var edit = makeEdit()
    let original = edit

    XCTAssertFalse(
      EditingFeatureTree.removeFeature(id: EditingFeatureTree.finalCropNodeID, from: &edit)
    )
    XCTAssertFalse(
      EditingFeatureTree.removeFeature(id: EditingFeatureTree.globalEffectsNodeID, from: &edit)
    )
    XCTAssertEqual(edit, original)
  }
}
