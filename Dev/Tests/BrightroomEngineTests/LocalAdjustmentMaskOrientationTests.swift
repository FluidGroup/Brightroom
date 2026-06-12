import XCTest

@testable import BrightroomEngine

/// Guards the coordinate contract of exported local-adjustment masks.
///
/// Stamps are authored in display coordinates (top-left origin, y-down).
/// A regression that flips the rasterized mask renders the adjustment at the
/// vertically mirrored position — the export no longer matches what the user
/// painted on the interactive canvas.
final class LocalAdjustmentMaskOrientationTests: XCTestCase {

  func testMaskAppliesAtAuthoredDisplayPosition() throws {
    let imageSource = ImageSource(image: Asset.l1000069.image)
    let imageSize = imageSource.readImageSize()

    // A single hard stamp in the top-left quadrant.
    let stampCenter = CGPoint(x: imageSize.width * 0.25, y: imageSize.height * 0.25)
    // The vertically mirrored position must remain untouched.
    let mirroredCenter = CGPoint(x: imageSize.width * 0.25, y: imageSize.height * 0.75)

    let layer = EditingStack.Edit.LocalAdjustmentLayer(
      id: UUID(),
      effect: .exposure(value: 2),
      mask: .init(strokes: [
        .init(
          stamps: [stampCenter],
          brush: .init(size: imageSize.width * 0.2, hardness: 1, opacity: 1)
        )
      ])
    )

    func render(localAdjustments: [EditingStack.Edit.LocalAdjustmentLayer]) throws -> CGImage {
      let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)
      renderer.edit.croppingRect = EditingCrop(imageSize: imageSize)
      renderer.edit.localAdjustments = localAdjustments
      return try renderer.render().cgImage
    }

    let base = try render(localAdjustments: [])
    let adjusted = try render(localAdjustments: [layer])

    let deltaAtStamp = abs(
      try Self.brightness(of: adjusted, at: stampCenter)
        - Self.brightness(of: base, at: stampCenter)
    )
    let deltaAtMirrored = abs(
      try Self.brightness(of: adjusted, at: mirroredCenter)
        - Self.brightness(of: base, at: mirroredCenter)
    )

    XCTAssertGreaterThan(
      deltaAtStamp,
      0.05,
      "The adjustment must land where the stamp was authored."
    )
    XCTAssertLessThan(
      deltaAtMirrored,
      0.01,
      "The vertically mirrored position changed — the exported mask is y-flipped."
    )
  }

  /// Average RGB at a display-coordinate point (top-left origin).
  private static func brightness(of image: CGImage, at point: CGPoint) throws -> CGFloat {
    let cropRect = CGRect(
      x: point.x.rounded(),
      y: point.y.rounded(),
      width: 1,
      height: 1
    )
    let cropped = try XCTUnwrap(image.cropping(to: cropRect))

    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixel,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))

    return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / (3 * 255)
  }
}
