import Testing
import Foundation
import CoreGraphics

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Guards the stroke coordinate contract of `CropView.CanvasRenderPlan`.
///
/// Local-adjustment strokes are persisted in the pre-crop source domain. The
/// tool surface canvas displays the crop output, so the viewing path must map
/// committed records through `EditingCanvasCropOutputGeometry`. A regression
/// that hands raw source records to that canvas renders the painted mask
/// translated and rotated away from where the user painted it whenever the
/// final crop is non-identity.
struct CropViewCanvasStrokeDomainTests {

  private func makeLayer() -> LocalAdjustmentFeature {
    .init(
      maskTree: .init(root: .brush(.init(strokes: [
        .init(
          stamps: [CGPoint(x: 100, y: 80), CGPoint(x: 140, y: 120)],
          brush: .init(diameter: 40, hardness: 1, opacity: 1)
        )
      ]))),
      effectPipeline: .init(effects: [GaussianBlurFeature(radius: 10)])
    )
  }

  @Test func `Viewing strokes are mapped into crop output domain`() throws {
    let layer = makeLayer()
    let plan = CropView.CanvasRenderPlan(
      localAdjustments: [layer]
    )

    // A non-identity final crop: offset extent plus a 90° rotation.
    let crop = CropEditingState(
      cropFeature: CropFeature.test(
        imageSize: CGSize(width: 400, height: 300),
        cropRect: CGRect(x: 60, y: 40, width: 200, height: 150),
        rotation: .quarterCW
      ),
      imageSize: CGSize(width: 400, height: 300)
    )
    let geometry = try #require(EditingCanvasCropOutputGeometry(crop: crop))

    let sourceRecords = layer.maskTree.canvasBrushStrokes.map {
      EditingCanvasStrokeRecord(brushMaskStroke: $0)
    }
    let expected = sourceRecords.map {
      geometry.outputRecord(fromSourceRecord: $0)
    }

    let viewingRecords = plan.committedStrokes(in: geometry)
    #expect(viewingRecords == expected)
    // The original bug shape: raw source records on the crop-output canvas.
    #expect(viewingRecords != sourceRecords)
  }

  @Test func `Source domain canvas receives raw records`() {
    let layer = makeLayer()
    let plan = CropView.CanvasRenderPlan(
      localAdjustments: [layer]
    )

    let sourceRecords = layer.maskTree.canvasBrushStrokes.map {
      EditingCanvasStrokeRecord(brushMaskStroke: $0)
    }

    // CropSurface's rendered-edit-preview canvas is sized to crop.imageSize,
    // so a source-domain canvas must keep the raw records.
    #expect(plan.committedStrokes(in: nil) == sourceRecords)
  }
}
