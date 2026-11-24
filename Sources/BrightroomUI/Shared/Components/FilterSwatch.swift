//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import CoreImage
import Metal

import BrightroomEngine
import BrightroomParametric

/// Renders filter swatches: one preset over the centre square of an image's
/// thumbnail, for a strip of filters to choose from.
///
/// A swatch is the thumbnail of a preview source (`PreviewSource.thumbnail`,
/// uncropped and oriented, at most 180 pixels on its short side),
/// centre-cropped to a square and run through one preset's effects. It
/// previews the filter only, not the document's other adjustments or its
/// crop, and renders in the canvas's colour contract, so it shows the colours
/// the canvas shows for the preset.
public enum FilterSwatch {

  /// Wide-gamut, GPU-backed context dedicated to swatch rendering. Mirrors the
  /// editing canvas's working space/precision so a swatch and the live canvas
  /// resolve the same colors. `CIContext` is thread-safe.
  private static let context: CIContext = {
    let options: [CIContextOption: Any] = [
      .name: "Brightroom.FilterSwatch",
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
      .cacheIntermediates: false,
    ]
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: options)
    }
    return CIContext(options: options)
  }()

  /// What a swatch is rendered from: a view renders its swatch again only
  /// when this changes.
  struct RenderKey: Equatable {
    var baseImage: ObjectIdentifier?
    var presetID: String?
    var scale: CGFloat
    var rendering: AdjustmentRendering.Identity
  }

  /// Renders `preset` over the centre square of `previewSource`'s thumbnail,
  /// off the calling actor; a nil preset renders the thumbnail alone. nil when
  /// the thumbnail is empty or the swatch would be smaller than a pixel.
  ///
  /// The swatch is `pointSize` times `scale` pixels square, never larger than
  /// the thumbnail's short side, in 8-bit Display P3: show it at `scale`.
  /// Proportional radii resolve against the whole thumbnail, as the canvas
  /// resolves them against the whole image. Absolute radii are pixels of
  /// `previewSource.source` at full resolution, and scale down to the swatch
  /// as the canvas scales them to its preview. A preset that fails to evaluate
  /// renders the thumbnail alone. Pass the adjustment rendering the canvas
  /// renders with (`adjustmentRendering(_:)`).
  @concurrent
  public static func render(
    _ preset: FilterFeature?,
    over previewSource: PreviewSource,
    pointSize: CGFloat,
    scale: CGFloat,
    adjustmentRendering: AdjustmentRendering = .standard
  ) async -> CGImage? {
    guard
      let prepared = normalizedSquare(base: previewSource.thumbnail, pointSize: pointSize, scale: scale)
    else {
      return nil
    }
    let evaluationContext = FeatureEvaluationContext(
      chainEntryExtent: prepared.chainEntryExtent,
      renderScale: EditingCanvasRenderImageFactory.renderScale(
        evaluated: prepared.chainEntryExtent.size,
        fullResolution: previewSource.source.pixelSize
      ),
      adjustmentRendering: adjustmentRendering
    )
    return makeImage(from: prepared, preset: preset, evaluationContext: evaluationContext)
  }

  // MARK: -

  /// A base thumbnail center-cropped to a square, moved to a zero origin, and
  /// scaled to the render pixel size paired with the rect to read back.
  private struct Prepared {
    let image: CIImage
    let outputRect: CGRect
    /// The FULL (uncropped) thumbnail at the swatch's render scale. Diagonal-
    /// based radii (blur/sharpen/unsharp) must resolve against the source, not
    /// the square crop, so a blur stays the source-relative fraction the canvas
    /// shows instead of weakening with the crop's tighter diagonal.
    let chainEntryExtent: CGRect
  }

  private static func normalizedSquare(
    base: CIImage,
    pointSize: CGFloat,
    scale: CGFloat
  ) -> Prepared? {
    let extent = base.extent
    guard extent.isInfinite == false, extent.isEmpty == false else {
      return nil
    }

    // Center square crop in the base's own coordinate space.
    let side = min(extent.width, extent.height)
    let square = base.cropped(
      to: CGRect(
        x: extent.midX - side / 2,
        y: extent.midY - side / 2,
        width: side,
        height: side
      )
    )

    // Downscale to the requested pixel size; never upscale past the source —
    // 8-bit swatches gain nothing from it.
    let targetPixels = floor(min((pointSize * scale).rounded(), side))
    guard targetPixels >= 1 else {
      return nil
    }
    let renderScale = targetPixels / side
    let normalized =
      square
      .transformed(by: CGAffineTransform(translationX: -square.extent.minX, y: -square.extent.minY))
      .transformed(by: CGAffineTransform(scaleX: renderScale, y: renderScale))

    return Prepared(
      image: normalized,
      outputRect: CGRect(x: 0, y: 0, width: targetPixels, height: targetPixels),
      chainEntryExtent: CGRect(
        origin: .zero,
        size: CGSize(width: extent.width * renderScale, height: extent.height * renderScale)
      )
    )
  }

  private static func makeImage(
    from prepared: Prepared,
    preset: FilterFeature?,
    evaluationContext: FeatureEvaluationContext
  ) -> CGImage? {
    let source: CIImage
    if let preset {
      do {
        source = try preset.apply(to: prepared.image, context: evaluationContext)
      } catch {
        source = prepared.image
      }
    } else {
      source = prepared.image
    }

    return context.createCGImage(
      source,
      from: prepared.outputRect,
      format: .RGBA8,
      colorSpace: EditingCanvasImageProcessing.drawableColorSpace
    )
  }
}
