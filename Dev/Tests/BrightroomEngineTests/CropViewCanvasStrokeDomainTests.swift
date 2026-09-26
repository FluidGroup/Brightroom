import Testing
import Foundation
import CoreGraphics

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Guards the stroke coordinate contract of `CropView.CanvasRenderPlan`.
///
/// Blur-mask strokes are stored in the working space (y-up) of the pre-crop
/// source domain. The tool surface canvas displays the crop output, so the
/// viewing path must flip committed strokes into canvas records and map them
/// through `EditingCanvasCropOutputGeometry`. A regression that hands raw
/// source records to that canvas renders the painted mask translated and
/// rotated away from where the user painted it whenever the final crop is
/// non-identity.
struct CropViewCanvasStrokeDomainTests {

  private let imageSize = CGSize(width: 400, height: 300)

  private func makeLayer() -> LocalAdjustment<GaussianBlurFeature> {
    LocalAdjustment(
      maskTree: .init(root: .brush(.init(strokes: [
        .init(
          stamps: [CGPoint(x: 100, y: 80), CGPoint(x: 140, y: 120)],
          brush: .init(diameter: 40, hardness: 1, opacity: 1)
        )
      ])))
    ) {
      GaussianBlurFeature(radius: 10)
    }
  }

  /// The layer's strokes as canvas-source records (y-down), through the
  /// production inverse conversion.
  private func sourceRecords(of layer: LocalAdjustment<GaussianBlurFeature>) -> [EditingCanvasStrokeRecord] {
    layer.maskTree.canvasBrushStrokes.map {
      EditingCanvasStrokeRecord(workingSpaceStroke: $0, domainHeight: imageSize.height)
    }
  }

  @Test func `Viewing strokes are mapped into crop output domain`() throws {
    let layer = makeLayer()
    let plan = CropView.CanvasRenderPlan(blurMask: layer)

    // A non-identity final crop: offset extent plus a 90° rotation.
    let crop = CropEditingState(
      cropFeature: CropFeature.test(
        imageSize: imageSize,
        cropRect: CGRect(x: 60, y: 40, width: 200, height: 150),
        rotation: .quarterCW
      ),
      imageSize: imageSize
    )
    let geometry = try #require(EditingCanvasCropOutputGeometry(crop: crop))

    let sourceRecords = sourceRecords(of: layer)
    let expected = sourceRecords.map {
      geometry.outputRecord(fromSourceRecord: $0)
    }

    let viewingRecords = plan.committedStrokes(in: geometry, domainHeight: imageSize.height)
    #expect(viewingRecords == expected)
    // The original bug shape: raw source records on the crop-output canvas.
    #expect(viewingRecords != sourceRecords)
  }

  @Test func `Source domain canvas receives flipped source records`() {
    let layer = makeLayer()
    let plan = CropView.CanvasRenderPlan(blurMask: layer)

    // CropSurface's rendered-edit-preview canvas is sized to the source image,
    // so a source-domain canvas receives the source records, y-down.
    let records = plan.committedStrokes(in: nil, domainHeight: imageSize.height)
    #expect(records == sourceRecords(of: layer))
    #expect(records.first?.stamps.first == CGPoint(x: 100, y: imageSize.height - 80))
  }

  @Test func `Absent, empty, or non-brush-rooted mask selects the viewport base`() {
    #expect(CropView.CanvasRenderPlan(blurMask: nil) == .viewportBase)

    let empty = LocalAdjustment(maskTree: .init(root: .brush(.init()))) {
      GaussianBlurFeature(radius: 10)
    }
    #expect(CropView.CanvasRenderPlan(blurMask: empty) == .viewportBase)

    // The canvas composites only the brush-rooted shape PhotosCrop authors.
    // A feathered empty brush selects nothing, so export changes nothing
    // either.
    let featheredEmpty = LocalAdjustment(
      maskTree: .init(root: .feather(MaskFeather(input: .brush(.init()), radius: 4)))
    ) {
      GaussianBlurFeature(radius: 10)
    }
    #expect(CropView.CanvasRenderPlan(blurMask: featheredEmpty) == .viewportBase)

    let layer = makeLayer()
    #expect(CropView.CanvasRenderPlan(blurMask: layer) == .blurMask(layer))
    #expect(
      CropView.CanvasRenderPlan(blurMask: layer).canvasMode
        == .localAdjustment(effect: AnyImageEffect(layer.content))
    )
  }
}
