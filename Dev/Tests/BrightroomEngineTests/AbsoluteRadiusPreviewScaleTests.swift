import CoreImage
import Foundation
import Metal
import Testing
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// Pins the canvas preview of absolute radii on a downsampled editing source.
///
/// The editor previews over an editing source the preview loader downsamples
/// (a 12000-px photo becomes about 2560 px), then scales the result up to the
/// document's full-resolution domain. `EffectRadius.absolute` is a number of
/// full-resolution pixels, so the canvas must shrink it by the downsample
/// factor; evaluated as editing-source pixels, a host's `.absolute(6)` blur
/// would preview four times wider than it exports on a 4× downsample.
///
/// The canvas composition (the factories, the render plan, and the brush
/// rasterizer, as `EditingCanvasView` draws them) is rendered on both
/// surfaces. A proportional radius of the same pixels is the oracle: it
/// already resolves against the editing source's extent, so an absolute
/// radius must preview exactly like it. The global blur is also compared with
/// `EditingDocument.render`; for the sharpening and the local blur, the
/// difference from export is dominated by the downsample itself (the unblurred
/// picture around a stroke is a quarter-resolution copy).
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct AbsoluteRadiusPreviewScaleTests {

  private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
  private static let imageSize = CGSize(width: 480, height: 320)
  private static let cropRect = CGRect(x: 40, y: 30, width: 300, height: 200)
  private static let downsample: CGFloat = 4

  enum Edit: String, CaseIterable, CustomTestStringConvertible {
    case blur
    case unsharpMask
    case localBlur

    var testDescription: String { rawValue }

    /// The edit with `radius`, which is `pixels` full-resolution pixels.
    func feature(radius: EffectRadius) -> ImageEditorFeature {
      var feature = ImageEditorFeature(imageSize: AbsoluteRadiusPreviewScaleTests.imageSize)
      switch self {
      case .blur:
        feature.effects.gaussianBlur = GaussianBlurFeature(radius: radius)
      case .unsharpMask:
        feature.effects.unsharpMask = UnsharpMaskFeature(intensity: 1, radius: radius)
      case .localBlur:
        feature.localBlur = LocalAdjustmentFeature(
          mask: .test(
            displayStamps: (0..<9).map { CGPoint(x: 80 + CGFloat($0) * 30, y: 130) },
            diameter: 90,
            domainHeight: AbsoluteRadiusPreviewScaleTests.imageSize.height
          )
        ) {
          GaussianBlurFeature(radius: radius)
        }
      }
      return feature
    }
  }

  @Test(arguments: Edit.allCases, [false, true])
  func `An absolute radius previews on a downsampled editing source as it exports`(
    edit: Edit,
    throughCrop: Bool
  ) async throws {
    let source = Self.makeTexturedImage()
    let pixels = 6.0
    // 100 is a twentieth of the diagonal.
    let diagonal = hypot(Self.imageSize.width, Self.imageSize.height)
    var absolute = edit.feature(radius: .absolute(pixels))
    var proportional = edit.feature(radius: .proportional(pixels * 2000 / diagonal))
    if throughCrop {
      let crop = CropFeature(topLeftRect: Self.cropRect, imageSize: Self.imageSize)
      absolute.crop = crop
      proportional.crop = crop
    }

    func preview(_ feature: ImageEditorFeature) throws -> CGImage {
      try CanvasCompositionPreview.render(
        document: feature,
        source: source,
        throughCrop: throughCrop,
        editingDownsample: Self.downsample
      )
    }
    let absolutePreview = try preview(absolute)
    let proportionalPreview = try preview(proportional)
    #expect(
      try Self.maximumDifference(absolutePreview, proportionalPreview) <= 1,
      "an absolute radius must preview like the proportional radius of the same pixels"
    )

    guard edit == .blur else {
      return
    }
    func export(_ feature: ImageEditorFeature) async throws -> CGImage {
      try await EditingDocument(source: SourceImage(cgImage: source), feature: feature)
        .render(options: .init(outputColorSpace: Self.sRGB)).cgImage
    }
    var unedited = ImageEditorFeature(imageSize: Self.imageSize)
    unedited.crop = absolute.crop
    let exported = try await export(absolute)
    let blurSize = try Self.meanDifference(exported, try await export(unedited))
    let previewDifference = try Self.meanDifference(exported, absolutePreview)
    // Measured: the blur changes the picture by 19 (whole) and 30 (crop) on
    // average, and the preview differs from the export by 1.7 and 1.3.
    #expect(blurSize > 10)
    #expect(previewDifference < blurSize / 5, "preview differs from export by \(previewDifference); the blur by \(blurSize)")
  }

  // MARK: - Fixtures

  /// A horizontal ramp with a 24-px checker over its top half.
  private static func makeTexturedImage() -> CGImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
      for x in 0..<Int(imageSize.width) {
        UIColor(white: 0.2 + 0.6 * CGFloat(x) / imageSize.width, alpha: 1).setFill()
        UIRectFill(CGRect(x: x, y: 0, width: 1, height: Int(imageSize.height)))
      }
      UIColor(white: 0.95, alpha: 1).setFill()
      for y in stride(from: 0, to: Int(imageSize.height) / 2, by: 24) {
        for x in stride(from: 0, to: Int(imageSize.width), by: 24) where (x / 24 + y / 24).isMultiple(of: 2) {
          UIRectFill(CGRect(x: x, y: y, width: 24, height: 24))
        }
      }
    }.cgImage!
  }

  private static func pixels(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
      data: &pixels,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: sRGB,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return pixels
  }

  /// The largest 8-bit difference over the RGB channels.
  private static func maximumDifference(_ lhs: CGImage, _ rhs: CGImage) throws -> Int {
    try #require(lhs.width == rhs.width && lhs.height == rhs.height)
    let a = pixels(lhs)
    let b = pixels(rhs)
    var largest = 0
    for index in a.indices where index % 4 != 3 {
      largest = max(largest, abs(Int(a[index]) - Int(b[index])))
    }
    return largest
  }

  /// The mean absolute 8-bit difference over the RGB channels.
  private static func meanDifference(_ lhs: CGImage, _ rhs: CGImage) throws -> Double {
    try #require(lhs.width == rhs.width && lhs.height == rhs.height)
    let a = pixels(lhs)
    let b = pixels(rhs)
    var sum = 0
    var count = 0
    for index in a.indices where index % 4 != 3 {
      sum += abs(Int(a[index]) - Int(b[index]))
      count += 1
    }
    return Double(sum) / Double(count)
  }
}
