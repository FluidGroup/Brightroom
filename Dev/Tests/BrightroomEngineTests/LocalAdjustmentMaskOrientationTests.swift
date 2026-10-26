import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Guards the coordinate contract of exported local-adjustment masks.
///
/// Stamps are painted in display coordinates (top-left origin, y-down) and
/// stored in working space (bottom-left origin, y-up). A regression that
/// flips twice, or not at all, renders the adjustment at the vertically
/// mirrored position — the export no longer matches what the user painted on
/// the interactive canvas.
struct LocalAdjustmentMaskOrientationTests {

  /// The stamp is authored as a display point and stored in working space
  /// through the production conversion, against the ORIENTED image size
  /// (`SourceImage.pixelSize`). The `.right` case swaps width and
  /// height, so a regression that flips by the raw pixel height passes every
  /// `.up` case and fails only there.
  @Test(arguments: [CGImagePropertyOrientation.up, .right])
  func `Mask applies at authored display position`(
    orientation: CGImagePropertyOrientation
  ) async throws {
    let pixelSize = SourceImage.test(Asset.l1000069.image).pixelSize
    let imageSize = orientation == .up
      ? pixelSize
      : CGSize(width: pixelSize.height, height: pixelSize.width)
    #expect(imageSize.width != imageSize.height)
    let imageSource = SourceImage.test(Asset.l1000069.image, orientation: orientation)
    #expect(imageSource.pixelSize == imageSize)

    // A single hard stamp in the top-left quadrant.
    let stampCenter = CGPoint(x: imageSize.width * 0.25, y: imageSize.height * 0.25)
    // The vertically mirrored position must remain untouched.
    let mirroredCenter = CGPoint(x: imageSize.width * 0.25, y: imageSize.height * 0.75)

    let adjustment = LocalAdjustmentFeature(
      mask: .test(
        displayStamps: [stampCenter],
        diameter: imageSize.width * 0.2,
        domainHeight: imageSize.height
      )
    ) {
      [AnyImageEffect(ExposureFeature(ev: 2))]
    }

    func render(
      localAdjustments: [LocalAdjustmentFeature<[AnyImageEffect]>]
    ) async throws -> CGImage {
      let renderer = EditingDocument(
        source: imageSource,
        feature: RendererTestDocument(
          localAdjustments: localAdjustments,
          crop: CropFeature.test(imageSize: imageSize)
        )
      )
      return try await renderer.render().cgImage
    }

    let base = try await render(localAdjustments: [])
    let adjusted = try await render(localAdjustments: [adjustment])
    #expect(CGSize(width: adjusted.width, height: adjusted.height) == imageSize)

    let deltaAtStamp = abs(
      try Self.brightness(of: adjusted, at: stampCenter)
        - Self.brightness(of: base, at: stampCenter)
    )
    let deltaAtMirrored = abs(
      try Self.brightness(of: adjusted, at: mirroredCenter)
        - Self.brightness(of: base, at: mirroredCenter)
    )

    #expect(
      deltaAtStamp > 0.05,
      "The adjustment must land where the stamp was authored."
    )
    #expect(
      deltaAtMirrored < 0.01,
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
    let cropped = try #require(image.cropping(to: cropRect))

    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try #require(
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
