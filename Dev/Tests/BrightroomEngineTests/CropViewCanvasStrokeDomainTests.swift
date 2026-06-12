import XCTest

@testable import BrightroomEngine
@testable import BrightroomUI

/// Guards the stroke coordinate contract of `CropView.CanvasRenderPlan`.
///
/// Local-adjustment strokes are persisted in the pre-crop source domain. The
/// tool surface canvas displays the crop output, so the viewing path must map
/// committed records through `EditingCanvasCropOutputGeometry`. A regression
/// that hands raw source records to that canvas renders the painted mask
/// translated and rotated away from where the user painted it whenever the
/// final crop is non-identity.
final class CropViewCanvasStrokeDomainTests: XCTestCase {

  private func makeLayer() -> EditingStack.Edit.LocalAdjustmentLayer {
    .init(
      effect: .gaussianBlur(radius: 10),
      mask: .init(strokes: [
        .init(
          stamps: [CGPoint(x: 100, y: 80), CGPoint(x: 140, y: 120)],
          brush: .init(size: 40, hardness: 1, opacity: 1)
        )
      ])
    )
  }

  func testViewingStrokesAreMappedIntoCropOutputDomain() throws {
    let layer = makeLayer()
    let plan = CropView.CanvasRenderPlan(
      localAdjustments: [layer]
    )

    // A non-identity final crop: offset extent plus a 90° rotation.
    let crop = EditingCrop(
      imageSize: CGSize(width: 400, height: 300),
      cropRect: CGRect(x: 60, y: 40, width: 200, height: 150),
      rotation: .angle_90
    )
    let geometry = try XCTUnwrap(EditingCanvasCropOutputGeometry(crop: crop))

    let sourceRecords = layer.mask.strokes.map {
      EditingCanvasStrokeRecord(localAdjustmentStroke: $0)
    }
    let expected = sourceRecords.map {
      geometry.outputRecord(fromSourceRecord: $0)
    }

    let viewingRecords = plan.committedStrokes(in: geometry)
    XCTAssertEqual(viewingRecords, expected)
    // The original bug shape: raw source records on the crop-output canvas.
    XCTAssertNotEqual(viewingRecords, sourceRecords)
  }

  func testSourceDomainCanvasReceivesRawRecords() {
    let layer = makeLayer()
    let plan = CropView.CanvasRenderPlan(
      localAdjustments: [layer]
    )

    let sourceRecords = layer.mask.strokes.map {
      EditingCanvasStrokeRecord(localAdjustmentStroke: $0)
    }

    // CropSurface's rendered-edit-preview canvas is sized to crop.imageSize,
    // so a source-domain canvas must keep the raw records.
    XCTAssertEqual(plan.committedStrokes(in: nil), sourceRecords)
  }
}
