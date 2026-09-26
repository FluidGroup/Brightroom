import CoreImage
import Foundation
import Testing

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Pins the single y-flip between the canvas (top-left origin, y-down) and
/// the document's working space (bottom-left origin, y-up).
///
/// A committed stroke is converted once, at commit, and its inverse is used
/// only to display committed strokes on the canvas. Export renders the stored
/// stamps as they are. A regression here re-opens the preview≠export /
/// upside-down-export class of bugs.
struct MaskWorkingSpaceTests {

  private static let context = CIContext(options: [.workingColorSpace: NSNull()])

  private let brush = EditingCanvasBrush(size: 48, hardness: 1, opacity: 1, spacing: 0.05)

  @Test func `Working space conversion flips y by the domain height`() {
    let record = EditingCanvasStrokeRecord(stamps: [CGPoint(x: 10, y: 5)], brush: brush)

    let stroke = record.workingSpaceStroke(domainHeight: 100)

    #expect(stroke.stamps == [CGPoint(x: 10, y: 95)])
    #expect(stroke.brush == BrushMaskBrush(diameter: 48, hardness: 1, opacity: 1))
    #expect(
      EditingCanvasStrokeRecord(workingSpaceStroke: stroke, domainHeight: 100) == record
    )
  }

  @Test func `Fractional coordinates round trip within tolerance`() {
    let stamps = [CGPoint(x: 10.3, y: 5.7), CGPoint(x: 0.1, y: 99.9)]
    let record = EditingCanvasStrokeRecord(stamps: stamps, brush: brush)

    let roundTrip = EditingCanvasStrokeRecord(
      workingSpaceStroke: record.workingSpaceStroke(domainHeight: 123.5),
      domainHeight: 123.5
    )

    for (actual, expected) in zip(roundTrip.stamps, stamps) {
      #expect(abs(actual.x - expected.x) < 1e-9)
      #expect(abs(actual.y - expected.y) < 1e-9)
    }
  }

  @Test func `Converted stroke renders at the display position`() throws {
    let canvas = 200
    let height = CGFloat(canvas)

    // An asymmetric stamp authored near the TOP in display coordinates.
    let authored = CGPoint(x: 70, y: 40)
    // Its vertical mirror must stay empty.
    let mirrored = CGPoint(x: 70, y: height - 40)

    let stroke = EditingCanvasStrokeRecord(stamps: [authored], brush: brush)
      .workingSpaceStroke(domainHeight: height)
    let mask = try ParametricImageRenderer().makeMaskImage(
      for: MaskTree(root: .brush(BrushMask(strokes: [stroke]))),
      extent: CGRect(x: 0, y: 0, width: canvas, height: canvas)
    )
    let image = try #require(
      Self.context.createCGImage(mask, from: CGRect(x: 0, y: 0, width: canvas, height: canvas))
    )

    #expect(Self.alpha(in: image, at: authored) > 0.9, "mask missing at authored position")
    #expect(
      Self.alpha(in: image, at: mirrored) < 0.1,
      "mask leaked to the mirrored position (y-flip regression)"
    )
  }

  @Test func `Committed strokes display as the records that were painted`() {
    let height: CGFloat = 300
    let records = [
      EditingCanvasStrokeRecord(stamps: [CGPoint(x: 12, y: 30), CGPoint(x: 40, y: 50)], brush: brush),
      EditingCanvasStrokeRecord(stamps: [CGPoint(x: 200, y: 280)], brush: brush),
    ]

    var document = PhotosCropDocument(orientedImageSize: CGSize(width: 400, height: height))
    for record in records {
      document.appendBlurMaskStroke(record.workingSpaceStroke(domainHeight: height))
    }

    let plan = CropView.CanvasRenderPlan(blurMask: document.blurMask)
    #expect(plan.committedStrokes(in: nil, domainHeight: height) == records)
  }

  /// Alpha at a display-coordinate point (top-left origin, y-down). Uses
  /// `CGImage.cropping` (top-left native) — the same convention
  /// `LocalAdjustmentMaskOrientationTests` uses to assert authored position.
  private static func alpha(in image: CGImage, at point: CGPoint) -> Double {
    let cropRect = CGRect(x: point.x.rounded(), y: point.y.rounded(), width: 1, height: 1)
    guard let cropped = image.cropping(to: cropRect) else {
      return 0
    }
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
      data: &pixel,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Double(pixel[3]) / 255
  }
}
