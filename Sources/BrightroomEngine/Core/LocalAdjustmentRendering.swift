//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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
import UIKit

import BrightroomParametric

/// The shared evaluation context for engine-side parametric evaluation.
enum EngineParametricEvaluation {
  static let context = FeatureEvaluationContext()
}

extension EditingStack.Edit {

  enum PreviewPurpose: Sendable {
    case editingBase
    case editing
  }

  /// Evaluates the feature list in document order, like the export renderer.
  ///
  /// `.editingBase` skips local adjustments (their mask rasterization is
  /// owned by the render path that knows its target resolution); `.editing`
  /// includes them. Crop features are domain features and not evaluated here.
  func makePreviewImage(
    from sourceImage: CIImage,
    purpose: PreviewPurpose
  ) -> CIImage {
    features.reduce(sourceImage) { image, feature in
      switch feature.payload {
      case .effects(let pipeline):
        return pipeline.applyIgnoringFailure(to: image)
      case .localAdjustment(let adjustment):
        switch purpose {
        case .editingBase:
          return image
        case .editing:
          return adjustment.engineRenderIgnoringFailure(over: image)
        }
      case .crop:
        return image
      }
    }
  }
}

extension EffectPipeline {

  /// Whether the pipeline contains any enabled effect.
  public var hasEnabledEffects: Bool {
    effects.contains(where: \.isEnabled)
  }

  /// Applies the pipeline, returning the input unchanged when evaluation
  /// fails. Failures are programmer errors in built-in effects; custom
  /// effects throwing here degrade to identity rather than poisoning the
  /// whole preview chain.
  ///
  /// `radiusReferenceExtent` is the full source extent in the current render
  /// pixel space, so diagonal-based radii (blur/sharpen) stay a fixed fraction
  /// of the source regardless of crop or viewport zoom. Pass it from any path
  /// that evaluates on a cropped/zoomed intermediate (the live viewport); the
  /// default `nil` is correct when `image` is itself the full source at render
  /// scale (export and preview-composition paths).
  public func applyIgnoringFailure(
    to image: CIImage,
    radiusReferenceExtent: CGRect? = nil
  ) -> CIImage {
    let context = EngineParametricEvaluation.context
      .withRadiusReferenceExtent(radiusReferenceExtent)
    do {
      return try apply(to: image, context: context)
    } catch {
      assertionFailure("EffectPipeline evaluation failed: \(error)")
      return image
    }
  }
}

extension LocalAdjustmentFeature {

  /// Engine-side evaluation: applies the effect pipeline through the mask,
  /// preserving the input extent.
  ///
  /// Brush masks are rasterized on the CPU in the engine's mask space
  /// (oriented display coordinates, top-left origin, y-down); other mask
  /// trees evaluate through the parametric GPU renderer with a vertical flip
  /// at that boundary. Either way the renderer's evaluation strategy stays
  /// independent from the document semantics.
  ///
  /// Throws when the effect pipeline fails to evaluate, so the export path
  /// surfaces the error like a global effects operation does instead of
  /// silently exporting without the adjustment.
  func engineRender(over image: CIImage) throws -> CIImage {
    guard isEnabled, maskTree.engineIsEffectivelyEmpty == false else {
      return image
    }
    guard effectPipeline.hasEnabledEffects else {
      return image
    }

    let extent = image.extent
    let imageInZeroOrigin = image.removingExtentOffset()
    let adjustedImage = try effectPipeline
      .apply(to: imageInZeroOrigin, context: EngineParametricEvaluation.context)
      .cropped(to: CGRect(origin: .zero, size: extent.size))

    guard let maskImage = maskTree.engineMakeMaskImage(size: extent.size) else {
      return image
    }

    let composited = adjustedImage.applyingFilter(
      "CIBlendWithAlphaMask",
      parameters: [
        kCIInputBackgroundImageKey: imageInZeroOrigin,
        kCIInputMaskImageKey: maskImage,
      ]
    )

    if extent.origin == .zero {
      return composited
    } else {
      return composited.transformed(
        by: CGAffineTransform(translationX: extent.minX, y: extent.minY)
      )
    }
  }

  /// Preview variant of `engineRender(over:)` that degrades to identity when
  /// evaluation fails, so one failing effect cannot poison the whole preview
  /// chain. Export must use the throwing variant.
  func engineRenderIgnoringFailure(over image: CIImage) -> CIImage {
    do {
      return try engineRender(over: image)
    } catch {
      assertionFailure("Local adjustment evaluation failed: \(error)")
      return image
    }
  }
}

extension MaskTree {

  /// Whether the mask cannot select anything: a brush-rooted tree that is
  /// disabled or whose strokes carry no stamps. Composite trees are
  /// conservatively treated as non-empty.
  ///
  /// The disabled check mirrors `FeatureGraphCompiler`, which renders a
  /// disabled brush leaf as fully transparent — both evaluation strategies
  /// must agree on what a disabled leaf selects.
  var engineIsEffectivelyEmpty: Bool {
    if case let .brush(mask) = root {
      return mask.isEnabled == false || mask.strokes.allSatisfy(\.stamps.isEmpty)
    }
    return false
  }

  /// Rasterizes the mask for the engine render path.
  ///
  /// Brush-rooted trees draw on the CPU in display coordinates (top-left
  /// origin, y-down — `CIImage(cgImage:)` preserves visual orientation, so no
  /// flip is applied; the falloff matches the interactive Metal brush).
  /// Other trees render through the parametric compiler, whose working space
  /// is y-up, and are flipped back into the display contract.
  func engineMakeMaskImage(size: CGSize) -> CIImage? {
    let targetSize = CGSize(
      width: max(size.width.rounded(), 1),
      height: max(size.height.rounded(), 1)
    )

    if case let .brush(mask) = root {
      guard mask.isEnabled else {
        return nil
      }
      return mask.engineMakeCIImage(size: targetSize)
    }

    do {
      let compiler = FeatureGraphCompiler()
      let extent = CGRect(origin: .zero, size: targetSize)
      let rendered = try compiler.renderMask(self, extent: extent)
      // Stamps are authored y-down; the parametric compiler evaluates y-up.
      return rendered
        .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
        .transformed(by: CGAffineTransform(translationX: 0, y: targetSize.height))
        .cropped(to: extent)
    } catch {
      assertionFailure("Parametric mask rendering failed: \(error)")
      return nil
    }
  }
}

/// Memoizes the CPU mask raster, which costs O(image area + stamp count) per
/// pass (~150ms at full resolution). Masks are Equatable value types, so an
/// equality-validated cache returns bit-identical rasters.
///
/// Only preview-scale rasters are retained: editing previews are bounded by
/// `EditingStack`'s 2560px editing size and re-render repeatedly, while an
/// export-resolution raster is produced once per export and never requested
/// again — pinning one in a process-lifetime static would cost ~200MB for a
/// 48MP image.
private enum LocalAdjustmentMaskRasterStore {

  private struct Entry {
    let mask: BrushMask
    let size: CGSize
    let cgImage: CGImage
    let byteCost: Int
  }

  private static let lock = NSLock()
  private static var entries: [Entry] = []
  private static let maxEntryByteCost = 32 * 1024 * 1024
  private static let totalByteBudget = 64 * 1024 * 1024

  static func image(
    for mask: BrushMask,
    size: CGSize
  ) -> CGImage? {
    lock.lock()
    defer { lock.unlock() }

    guard let index = entries.firstIndex(where: { $0.size == size && $0.mask == mask }) else {
      return nil
    }
    let entry = entries.remove(at: index)
    entries.append(entry)
    return entry.cgImage
  }

  static func store(
    _ cgImage: CGImage,
    for mask: BrushMask,
    size: CGSize
  ) {
    let byteCost = cgImage.bytesPerRow * cgImage.height
    guard byteCost <= maxEntryByteCost else {
      return
    }

    lock.lock()
    defer { lock.unlock() }

    entries.removeAll { $0.size == size && $0.mask == mask }
    entries.append(Entry(mask: mask, size: size, cgImage: cgImage, byteCost: byteCost))

    var totalCost = entries.reduce(0) { $0 + $1.byteCost }
    while totalCost > totalByteBudget, entries.isEmpty == false {
      totalCost -= entries.removeFirst().byteCost
    }
  }
}

extension BrushMask {

  fileprivate func engineMakeCIImage(size targetSize: CGSize) -> CIImage? {
    if let cached = LocalAdjustmentMaskRasterStore.image(for: self, size: targetSize) {
      return CIImage(cgImage: cached)
        .cropped(to: CGRect(origin: .zero, size: targetSize))
    }

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false

    let image = UIGraphicsImageRenderer(size: targetSize, format: format).image { rendererContext in
      let context = rendererContext.cgContext
      context.setBlendMode(.normal)
      context.setFillColor(UIColor.clear.cgColor)
      context.fill(CGRect(origin: .zero, size: targetSize))

      for stroke in strokes {
        stroke.engineDrawMask(in: context)
      }
    }

    guard let cgImage = image.cgImage else {
      return nil
    }

    LocalAdjustmentMaskRasterStore.store(cgImage, for: self, size: targetSize)

    // Stamps are authored in display coordinates (top-left origin, y-down),
    // which is exactly UIGraphics' coordinate system, so the raster is
    // already visually correct. `CIImage(cgImage:)` preserves visual
    // orientation — adding a flip here renders exported masks upside-down
    // relative to the interactive preview. (A flip is required for
    // `CIImage(mtlTexture:)`, not for `CIImage(cgImage:)`.)
    return CIImage(cgImage: cgImage)
      .cropped(to: CGRect(origin: .zero, size: targetSize))
  }
}

extension BrushMaskStroke {

  fileprivate func engineDrawMask(in context: CGContext) {
    guard stamps.isEmpty == false else {
      return
    }

    let radius = max(CGFloat(brush.diameter) / 2, 0.5)
    let opacity = CGFloat(min(max(brush.opacity, 0), 1))
    let hardness = CGFloat(min(max(brush.hardness, 0), 1))

    // The gradient depends only on the per-stroke brush, so build it once
    // instead of per stamp; a long stroke holds hundreds of stamps.
    let softStampGradient: CGGradient?
    if hardness >= 0.999 {
      softStampGradient = nil
    } else {
      guard let gradient = Self.makeSoftStampGradient(hardness: hardness, opacity: opacity) else {
        return
      }
      softStampGradient = gradient
    }

    for stamp in stamps {
      if let softStampGradient {
        context.drawRadialGradient(
          softStampGradient,
          startCenter: stamp,
          startRadius: 0,
          endCenter: stamp,
          endRadius: radius,
          options: []
        )
      } else {
        let rect = CGRect(
          x: stamp.x - radius,
          y: stamp.y - radius,
          width: radius * 2,
          height: radius * 2
        )
        context.setFillColor(UIColor(white: 1, alpha: opacity).cgColor)
        context.fillEllipse(in: rect)
      }
    }
  }

  private static func makeSoftStampGradient(
    hardness: CGFloat,
    opacity: CGFloat
  ) -> CGGradient? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // The falloff must match the interactive Metal brush
    // (EditingCanvasBrushMaskShaderSource) and the parametric GPU kernel
    // (ParametricKernels.metal):
    //   alpha = (1 - smoothstep(hardness, 1, distance)) * opacity
    // A plain linear ramp renders a fatter tail per stamp, and over-blending
    // across overlapping stamps compounds that into visibly wider and
    // stronger coverage in exports than the preview ever showed.
    let hardnessStop = min(max(hardness, 0.001), 0.999)
    let stepCount = 16
    var locations: [CGFloat] = [0, hardnessStop]
    var colors: [CGColor] = [
      UIColor(white: 1, alpha: opacity).cgColor,
      UIColor(white: 1, alpha: opacity).cgColor,
    ]
    for index in 1...stepCount {
      let bandFraction = CGFloat(index) / CGFloat(stepCount)
      let smooth = bandFraction * bandFraction * (3 - 2 * bandFraction)
      locations.append(hardnessStop + (1 - hardnessStop) * bandFraction)
      colors.append(UIColor(white: 1, alpha: opacity * (1 - smooth)).cgColor)
    }

    return CGGradient(
      colorsSpace: colorSpace,
      colors: colors as CFArray,
      locations: &locations
    )
  }
}
