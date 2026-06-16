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
import UIKit

import BrightroomEngine
import BrightroomParametric

/// Renders a single filter-preview swatch for PhotosCrop's Filters strip.
///
/// A swatch is the session thumbnail — the uncropped, already-oriented ~180px
/// preview the EditingStack decoded at load — center-cropped to a square and run
/// through one preset's effects. Swatches preview the filter only, not the user's
/// manual adjustments or the current crop, matching the Photos/Instagram strip.
///
/// Each chip renders its own swatch when the strip appears and holds it in its
/// SwiftUI `@State`, so the render happens once for that chip's lifetime.
enum PhotosCropFilterThumbnailRenderer {

  /// Wide-gamut, GPU-backed context dedicated to swatch rendering. Mirrors the
  /// editing canvas's working space/precision so a swatch and the live canvas
  /// resolve the same colors. `CIContext` is thread-safe.
  private static let context: CIContext = {
    let options: [CIContextOption: Any] = [
      .name: "Brightroom.FilterThumbnail",
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
      .cacheIntermediates: false,
    ]
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: options)
    }
    return CIContext(options: options)
  }()

  /// Renders a single square swatch — a `nil` preset yields the unfiltered base.
  ///
  /// `@concurrent` runs the body on the concurrent executor, so a chip's
  /// MainActor `.task` offloads the Core Image work off the main thread just by
  /// awaiting it — no queue hop, no box. `CIImage`, `PresetFeature` and `UIImage`
  /// are all `Sendable`, so the values cross the isolation boundary directly.
  ///
  /// - Parameters:
  ///   - pointSize: the swatch's on-screen point size (a square edge).
  ///   - scale: the display scale; the swatch is rendered at `pointSize * scale`
  ///     pixels, never larger than the source thumbnail.
  @concurrent
  static func render(
    base: CIImage,
    preset: PresetFeature?,
    pointSize: CGFloat,
    scale: CGFloat
  ) async -> UIImage? {
    guard let prepared = normalizedSquare(base: base, pointSize: pointSize, scale: scale) else {
      return nil
    }
    return makeImage(from: prepared, preset: preset, scale: scale)
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
    let radiusReferenceExtent: CGRect
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
      radiusReferenceExtent: CGRect(
        origin: .zero,
        size: CGSize(width: extent.width * renderScale, height: extent.height * renderScale)
      )
    )
  }

  private static func makeImage(
    from prepared: Prepared,
    preset: PresetFeature?,
    scale: CGFloat
  ) -> UIImage? {
    let source: CIImage
    if let preset {
      do {
        source = try preset.apply(
          to: prepared.image,
          context: .init(radiusReferenceExtent: prepared.radiusReferenceExtent)
        )
      } catch {
        source = prepared.image
      }
    } else {
      source = prepared.image
    }

    guard
      let cgImage = context.createCGImage(
        source,
        from: prepared.outputRect,
        format: .RGBA8,
        colorSpace: EditingCanvasImageProcessing.drawableColorSpace
      )
    else {
      return nil
    }

    return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
  }
}
