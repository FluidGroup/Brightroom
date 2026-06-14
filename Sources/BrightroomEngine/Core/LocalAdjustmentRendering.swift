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

import CoreGraphics
import CoreImage

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
      switch feature {
      case .effect(let effect):
        return effect.applyIgnoringFailure(to: image)
      case .localAdjustment(let adjustment):
        switch purpose {
        case .editingBase:
          return image
        case .editing:
          return adjustment.engineRenderIgnoringFailure(over: image)
        }
      case .domain:
        return image
      }
    }
  }
}

extension ImageEffectFeatureType {

  /// Applies a single effect node, returning the input unchanged when the node
  /// is disabled or evaluation fails. Mirrors `EffectPipeline.applyIgnoringFailure`
  /// for the per-node reduction the preview path performs.
  func applyIgnoringFailure(
    to image: CIImage,
    radiusReferenceExtent: CGRect? = nil
  ) -> CIImage {
    guard isEnabled else {
      return image
    }
    let context = EngineParametricEvaluation.context
      .withRadiusReferenceExtent(radiusReferenceExtent)
    do {
      return try apply(to: image, context: context)
    } catch {
      assertionFailure("Effect evaluation failed: \(error)")
      return image
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

  /// Rasterizes the mask for the engine render path through the shared
  /// parametric `brushStamp` kernel (`FeatureGraphCompiler.renderMask`) — the
  /// identical rasterizer the export renderer (`ParametricImageRenderer`) uses —
  /// so the preview and the exported result agree by construction.
  ///
  /// Stamps are authored y-down (display, top-left origin); the parametric
  /// compiler evaluates y-up, so the rendered alpha is flipped back into the
  /// display contract. Flipping the image by the canvas height is equivalent to
  /// the export path's stamp pre-flip (`EditingDocumentBridge.flippingStampsY`),
  /// so both produce the same alpha field.
  func engineMakeMaskImage(size: CGSize) -> CIImage? {
    let targetSize = CGSize(
      width: max(size.width.rounded(), 1),
      height: max(size.height.rounded(), 1)
    )

    // A disabled brush leaf selects nothing; skip the composite entirely.
    if case let .brush(mask) = root, mask.isEnabled == false {
      return nil
    }

    do {
      let compiler = FeatureGraphCompiler()
      let extent = CGRect(origin: .zero, size: targetSize)
      let rendered = try compiler.renderMask(self, extent: extent)
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
