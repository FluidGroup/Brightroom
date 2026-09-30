import Testing
import Foundation
import CoreGraphics

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Guards the stroke coordinate contract of `EditingCanvasView.CanvasRenderPlan`.
///
/// Blur-mask strokes are stored in the working space (y-up) of the pre-crop
/// source domain. The tool surface canvas displays the crop output, so the
/// viewing path must flip committed strokes into canvas records and map them
/// through `EditingCanvasCropOutputGeometry`. A regression that hands raw
/// source records to that canvas renders the painted mask translated and
/// rotated away from where the user painted it whenever the final crop is
/// non-identity.
struct EditingCanvasViewStrokeDomainTests {

  private let imageSize = CGSize(width: 400, height: 300)

  private func makeLayer() -> LocalAdjustmentFeature<GaussianBlurFeature> {
    LocalAdjustmentFeature(
      mask: .brush(.init(strokes: [
        .init(
          stampCenters: [CGPoint(x: 100, y: 80), CGPoint(x: 140, y: 120)],
          brush: .init(diameter: 40, hardness: 1, opacity: 1)
        )
      ]))
    ) {
      GaussianBlurFeature(radius: .absolute(10))
    }
  }

  /// The layer's strokes as canvas-source records (y-down), through the
  /// production inverse conversion.
  private func sourceRecords(of layer: LocalAdjustmentFeature<GaussianBlurFeature>) -> [EditingCanvasStrokeRecord] {
    layer.mask.brushStrokes.map {
      EditingCanvasStrokeRecord(workingSpaceStroke: $0, domainHeight: imageSize.height)
    }
  }

  @Test func `Viewing strokes are mapped into crop output domain`() throws {
    let layer = makeLayer()
    let plan = EditingCanvasView.CanvasRenderPlan(localBlur: layer)

    // A non-identity final crop: offset extent plus a 90° rotation.
    let crop = CropGuideState(
      cropFeature: CropFeature.test(
        imageSize: imageSize,
        topLeftRect: CGRect(x: 60, y: 40, width: 200, height: 150),
        quarterTurn: .counterclockwise90
      ),
      imageSize: imageSize
    )
    let geometry = try #require(EditingCanvasCropOutputGeometry(crop: crop))
    #expect(geometry.outputSize == CGSize(width: 150, height: 200))

    let sourceRecords = sourceRecords(of: layer)
    let expected = sourceRecords.map {
      geometry.outputRecord(fromSourceRecord: $0)
    }

    let viewingRecords = plan.committedStrokes(in: geometry, domainHeight: imageSize.height)
    #expect(viewingRecords == expected)
    // The source rectangle remains (60, 40, 200, 150). Under the
    // counterclockwise turn, (x, y) maps to (y - 40, 260 - x). The
    // layer's y-up stamps (100, 80) and (140, 120) are (100, 220) and
    // (140, 180) in the y-down source records.
    let viewingRecord = try #require(viewingRecords.first)
    #expect(viewingRecord.stamps == [CGPoint(x: 180, y: 160), CGPoint(x: 140, y: 120)])
    // The original bug shape: raw source records on the crop-output canvas.
    #expect(viewingRecords != sourceRecords)
  }

  @Test func `Source domain canvas receives flipped source records`() {
    let layer = makeLayer()
    let plan = EditingCanvasView.CanvasRenderPlan(localBlur: layer)

    // CropSurface's rendered-edit-preview canvas is sized to the source image,
    // so a source-domain canvas receives the source records, y-down.
    let records = plan.committedStrokes(in: nil, domainHeight: imageSize.height)
    #expect(records == sourceRecords(of: layer))
    #expect(records.first?.stamps.first == CGPoint(x: 100, y: imageSize.height - 80))
  }

  @Test func `Absent, empty, or non-brush-rooted mask selects the viewport base`() {
    #expect(EditingCanvasView.CanvasRenderPlan(localBlur: nil) == .viewportBase)

    let empty = LocalAdjustmentFeature(mask: .brush(.init())) {
      GaussianBlurFeature(radius: .absolute(10))
    }
    #expect(EditingCanvasView.CanvasRenderPlan(localBlur: empty) == .viewportBase)

    // The canvas composites only the brush-rooted shape ImageEditor authors.
    // A feathered empty brush selects nothing, so export changes nothing
    // either.
    let featheredEmpty = LocalAdjustmentFeature(
      mask: .feathered(.brush(.init()), radius: 4)
    ) {
      GaussianBlurFeature(radius: .absolute(10))
    }
    #expect(EditingCanvasView.CanvasRenderPlan(localBlur: featheredEmpty) == .viewportBase)

    let layer = makeLayer()
    #expect(EditingCanvasView.CanvasRenderPlan(localBlur: layer) == .localBlur(layer))
    #expect(
      EditingCanvasView.CanvasRenderPlan(localBlur: layer).canvasMode
        == .localAdjustment(effect: AnyImageEffect(layer.content))
    )
  }
}
