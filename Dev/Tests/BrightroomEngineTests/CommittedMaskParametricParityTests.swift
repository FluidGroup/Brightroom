import CoreImage
import XCTest

@testable import BrightroomEngine
@testable import BrightroomParametric

/// Pins the brush-mask rasterizer unification: the live canvas committed mask,
/// the engine preview mask, and the export mask all rasterize through the shared
/// parametric `brushStamp` kernel (`FeatureGraphCompiler.renderMask`).
///
/// The live canvas (`_EditingCanvasMTKView.committedMaskContentImage`) feeds the
/// compiler stamps **pre-flipped** by the canvas height (mirroring the export
/// path's `EditingDocumentBridge.flippingStampsY`), while the engine preview
/// (`MaskTree.engineMakeMaskImage`) feeds **unflipped** stamps and **post-flips**
/// the rendered image. These must produce the same alpha field, in the same
/// display orientation (top-left origin, y-down) — a regression here re-opens the
/// preview≠export / upside-down-export class of bugs.
final class CommittedMaskParametricParityTests: XCTestCase {

  private static let context = CIContext(options: [.workingColorSpace: NSNull()])

  func testLiveCommittedFlipMatchesEnginePostFlipAndOrientation() throws {
    let canvas = 200
    let height = CGFloat(canvas)
    let brush = BrushMaskBrush(diameter: 48, hardness: 1, opacity: 1)

    // An asymmetric stamp authored near the TOP in display coordinates.
    let authored = CGPoint(x: 70, y: 40)
    // Its vertical mirror must stay empty.
    let mirrored = CGPoint(x: 70, y: height - 40)

    // Engine preview path: renderMask(unflipped stamps) + post-flip by height.
    let engineMask = try XCTUnwrap(
      MaskTree(root: .brush(BrushMask(strokes: [
        BrushMaskStroke(stamps: [authored], brush: brush)
      ])))
      .engineMakeMaskImage(size: CGSize(width: canvas, height: canvas))
    )

    // Live committed path: pre-flip stamps by height, renderMask (no post-flip).
    let liveMask = try FeatureGraphCompiler().renderMask(
      MaskTree(root: .brush(BrushMask(strokes: [
        BrushMaskStroke(
          stamps: [CGPoint(x: authored.x, y: height - authored.y)],
          brush: brush
        )
      ]))),
      extent: CGRect(x: 0, y: 0, width: canvas, height: canvas)
    )

    let engineCG = try render(engineMask, canvas: canvas)
    let liveCG = try render(liveMask, canvas: canvas)

    let engineAuthored = Self.alpha(in: engineCG, at: authored)
    let liveAuthored = Self.alpha(in: liveCG, at: authored)
    let engineMirrored = Self.alpha(in: engineCG, at: mirrored)
    let liveMirrored = Self.alpha(in: liveCG, at: mirrored)

    // Orientation: alpha lands at the authored (top) position, not the mirror.
    XCTAssertGreaterThan(engineAuthored, 0.9, "engine mask missing at authored position")
    XCTAssertGreaterThan(liveAuthored, 0.9, "live mask missing at authored position")
    XCTAssertLessThan(engineMirrored, 0.1, "engine mask leaked to the mirrored position (y-flip regression)")
    XCTAssertLessThan(liveMirrored, 0.1, "live mask leaked to the mirrored position (y-flip regression)")

    // Equivalence: the two flip strategies agree pixel-for-pixel.
    XCTAssertEqual(engineAuthored, liveAuthored, accuracy: 0.02, "live committed flip diverges from engine post-flip")
    XCTAssertEqual(engineMirrored, liveMirrored, accuracy: 0.02)
  }

  private func render(_ image: CIImage, canvas: Int) throws -> CGImage {
    try XCTUnwrap(
      Self.context.createCGImage(
        image,
        from: CGRect(x: 0, y: 0, width: canvas, height: canvas)
      )
    )
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
