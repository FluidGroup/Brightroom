import Testing
import Foundation
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

/// Exercises the export path through Core Image at large scale to confirm the
/// brush-mask local adjustment composites correctly when the parametric mask is
/// rasterized via the resolution-independent, tiling-capable CIKernel path
/// (the same code path used for full-resolution export and tiled rendering).
///
/// The source size is intentionally large but simulator-safe (4096x4096).
/// Going truly past the Metal tiling threshold (>16384 on a side) would require
/// asserting on a multi-gigabyte intermediate, which is too memory-heavy to
/// stand up reliably in CI; 4096x4096 drives the identical resolution-
/// independent kernel path at scale without that cost.
struct LargeMaskedExportTests {

  /// A large-but-simulator-safe source side length. See type doc for why this
  /// is not pushed past the >16384 tiling threshold.
  private static let side = 4096

  @Test func `Large brush masked exposure export applies only inside mask`() async throws {
    let side = Self.side
    let size = CGSize(width: side, height: side)
    let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)

    // A solid mid-grey source so any local exposure lift is unmistakable.
    let source = Self.makeSolidImage(width: side, height: side, white: 0.25)

    // A big, fully-opaque, hard-edged brush stamp centered in the image, with a
    // strong exposure lift. The brush diameter covers the central quarter so the
    // center pixel is deep inside the painted region and the corners are far
    // outside it.
    let diameter = Double(side) / 4
    let layer = LocalAdjustmentFeature(
      maskTree: MaskTree(
        root: .brush(
          BrushMask(
            strokes: [
              BrushMaskStroke(
                stamps: [center],
                brush: BrushMaskBrush(diameter: diameter, hardness: 1, opacity: 1)
              ),
            ]
          )
        )
      ),
      effectPipeline: EffectPipeline(effects: [ExposureFeature(value: 2)])
    )

    // Export WITH the local adjustment through an identity crop.
    let adjustedRenderer = BrightRoomImageRenderer(
      source: ImageSource(cgImage: source),
      orientation: .up
    )
    adjustedRenderer.edit = .make(
      crop: CropFeature.test(imageSize: size),
      orientedImageSize: size,
      localAdjustments: [layer]
    )
    let adjusted = try await adjustedRenderer.render(
      options: .init(workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    ).cgImage

    // Export the SAME edit with NO local adjustment as the baseline.
    let baselineRenderer = BrightRoomImageRenderer(
      source: ImageSource(cgImage: source),
      orientation: .up
    )
    baselineRenderer.edit = .make(
      crop: CropFeature.test(imageSize: size),
      orientedImageSize: size
    )
    let baseline = try await baselineRenderer.render(
      options: .init(workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    ).cgImage

    // Identity crop preserves the source dimensions at full scale.
    #expect(adjusted.width == side)
    #expect(adjusted.height == side)
    #expect(baseline.width == side)
    #expect(baseline.height == side)

    // INSIDE the painted region: the exposure lift makes the center brighter
    // than the same pixel in the unadjusted baseline export.
    let centerX = side / 2
    let centerY = side / 2
    let adjustedCenter = Self.rgba(in: adjusted, x: centerX, y: centerY)
    let baselineCenter = Self.rgba(in: baseline, x: centerX, y: centerY)
    #expect(
      Int(adjustedCenter.red) > Int(baselineCenter.red),
      "Masked center pixel should be brightened by the local exposure adjustment"
    )

    // FAR OUTSIDE the mask (top-left corner): unchanged versus baseline.
    let cornerX = 2
    let cornerY = 2
    let adjustedCorner = Self.rgba(in: adjusted, x: cornerX, y: cornerY)
    let baselineCorner = Self.rgba(in: baseline, x: cornerX, y: cornerY)
    #expect(
      adjustedCorner == baselineCorner,
      "Pixel far outside the mask must be untouched by the local adjustment"
    )
  }

  // MARK: - Fixtures

  private static func makeSolidImage(
    width: Int,
    height: Int,
    white: CGFloat
  ) -> CGImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true

    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor(white: white, alpha: 1).setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
    }.cgImage!
  }

  private static func rgba(in image: CGImage, x: Int, y: Int) -> RGBA {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let clampedX = min(max(x, 0), width - 1)
    let clampedY = min(max(y, 0), height - 1)
    let offset = (clampedY * width + clampedX) * 4
    return RGBA(
      red: pixels[offset],
      green: pixels[offset + 1],
      blue: pixels[offset + 2],
      alpha: pixels[offset + 3]
    )
  }

  private struct RGBA: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
  }
}
