import CoreImage
import Metal
import Testing

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

/// The canvas preview of an `ImageEditorFeature`, composed from the same pieces
/// `EditingCanvasView` renders with: the render plan, the canvas image factory, the
/// Metal brush rasterizer, and the alpha blend of the viewport composite.
///
/// The canvas is sized to the source (no crop, no viewport transform), so the
/// result is directly comparable to an export of the same document.
enum CanvasCompositionPreview {

  static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

  private static let context = CIContext()

  /// Renders the canvas composition of `document` over `source`, as a
  /// top-left-origin image.
  ///
  /// - Parameters:
  ///   - throughCrop: When false, the canvas is sized to the source (the crop
  ///     surface's source-domain canvas) and the crop is not applied. When
  ///     true, the canvas displays the crop output (the tool surface).
  ///   - editingDownsample: How many times smaller the editing source is
  ///     than `source`, as the editor's preview loader downsamples a large
  ///     image. 1 uses `source` itself.
  static func render(
    document: ImageEditorFeature,
    source: CGImage,
    throughCrop: Bool = false,
    editingDownsample: CGFloat = 1
  ) throws -> CGImage {
    let imageSize = CGSize(width: source.width, height: source.height)
    let plan = EditingCanvasView.CanvasRenderPlan(localBlur: document.localBlur)
    let editingSource = editingDownsample == 1
      ? CIImage(cgImage: source)
      : CIImage(cgImage: source)
        .clampedToExtent()
        .applyingFilter(
          "CILanczosScaleTransform",
          parameters: [kCIInputScaleKey: 1 / editingDownsample, kCIInputAspectRatioKey: 1]
        )
        .cropped(
          to: CGRect(
            x: 0,
            y: 0,
            width: (imageSize.width / editingDownsample).rounded(),
            height: (imageSize.height / editingDownsample).rounded()
          )
        )

    let images: EditingCanvasRenderImages
    let geometry: EditingCanvasCropOutputGeometry?
    if throughCrop {
      let cropOutput = try #require(
        EditingCanvasCropOutputGeometry(
          crop: CropGuideState(cropFeature: document.crop, imageSize: imageSize)
        )
      )
      geometry = cropOutput
      images = try #require(
        EditingCanvasRenderImageFactory.makeCropOutputRenderImages(
          editingSourceImage: editingSource,
          effects: document.effects.canvasEffect,
          geometry: cropOutput,
          mode: plan.canvasMode
        )
      )
    } else {
      geometry = nil
      images = try #require(
        EditingCanvasRenderImageFactory.makeRenderImages(
          editingSourceImage: editingSource,
          effects: document.effects.canvasEffect,
          canvasSize: imageSize,
          mode: plan.canvasMode
        )
      )
    }
    let canvasSize = geometry?.outputSize ?? imageSize
    let canvasRect = CGRect(origin: .zero, size: canvasSize)

    let stamps = plan.committedStrokes(in: geometry, domainHeight: imageSize.height)
      .flatMap { record in
        record.stamps.map {
          BrushMaskMetalRasterizer.Stamp(
            center: $0,
            pixelRadius: CGFloat(record.brush.size / 2),
            hardness: Float(record.brush.hardness),
            opacity: Float(record.brush.opacity)
          )
        }
      }

    // The canvas content space is y-down (the factory flips the source into
    // it, and the rasterizer places a record's y at the same row).
    let composed: CIImage
    if stamps.isEmpty {
      composed = images.base
    } else {
      let device = try #require(MTLCreateSystemDefaultDevice())
      let rasterizer = try #require(BrushMaskMetalRasterizer(device: device))
      let mask = try #require(rasterizer.rasterize(stamps: stamps, canvasPixelSize: canvasSize))
      composed = images.adjusted
        .applyingFilter(
          "CIBlendWithAlphaMask",
          parameters: [
            kCIInputBackgroundImageKey: images.base,
            kCIInputMaskImageKey: mask,
          ]
        )
        .cropped(to: canvasRect)
    }

    // Back to Core Image's y-up space, so the rendered CGImage is upright.
    let upright = composed
      .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
      .transformed(by: CGAffineTransform(translationX: 0, y: canvasSize.height))

    return try #require(
      context.createCGImage(upright, from: canvasRect, format: .RGBA8, colorSpace: sRGB)
    )
  }
}
