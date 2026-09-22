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
import CoreMedia
import Foundation

/// Values available to features while they evaluate.
///
/// The context deliberately carries no document state. A feature sees its input
/// image, explicit render-time values, and shared facilities. This keeps
/// evaluation a pure function of (parameters, input, context).
public struct FeatureEvaluationContext: Sendable {

  /// Custom Core Image kernels shared by mask rendering.
  public let kernelRegistry: ParametricKernelRegistry

  /// The presentation time of the image being evaluated.
  ///
  /// Video renderers supply the exact AVFoundation composition time for each
  /// frame. Still-image renderers use `.zero` by default, which gives
  /// time-sensitive effects a deterministic sample without adding time to the
  /// persisted feature parameters.
  public let presentationTime: CMTime

  /// The image extent that diagonal-based radii (Gaussian blur, sharpen,
  /// unsharp mask) resolve against, expressed in the **current render pixel
  /// space**.
  ///
  /// A radius like "value 40" means "diagonal / 50 of the image". The basis
  /// must be the **source** image, not the cropped/zoomed/intermediate extent
  /// the effect happens to be applied to — otherwise a tighter crop or a
  /// zoomed viewport silently changes the blur strength. Render pipelines set
  /// this to the full source extent scaled to the resolution they are
  /// rendering at, so the radius stays a fixed fraction of the source in every
  /// path (export, preview, live viewport).
  ///
  /// `nil` falls back to the input image's own extent at the recipe level.
  /// `FeatureGraphCompiler` never relies on that fallback: it resolves the
  /// reference ONCE at chain entry, so a mid-chain crop cannot re-base the
  /// radius. The fallback only applies to direct `apply(to:context:)` calls
  /// outside the compiler, where the input is expected to be the chain entry.
  public let radiusReferenceExtent: CGRect?

  /// Creates an evaluation context.
  public init(
    kernelRegistry: ParametricKernelRegistry = .init(),
    radiusReferenceExtent: CGRect? = nil,
    presentationTime: CMTime = .zero
  ) {
    self.kernelRegistry = kernelRegistry
    self.radiusReferenceExtent = radiusReferenceExtent
    self.presentationTime = presentationTime
  }

  /// Returns the extent that a diagonal-based radius must resolve against when
  /// the recipe is evaluating `image`.
  ///
  /// Every recipe with a proportional radius goes through this accessor rather
  /// than reading `radiusReferenceExtent` and writing its own fallback: the
  /// fallback to `image.extent` is correct ONLY when `image` is the chain entry.
  /// Applied to any mid-chain input — a cropped result, a zoomed viewport slice,
  /// an intermediate — it re-bases the radius and silently changes the strength
  /// of a committed effect, which is exactly what the pinned semantics forbid.
  public func radiusBasis(for image: CIImage) -> CGRect {
    radiusReferenceExtent ?? image.extent
  }

  /// Returns a copy that resolves diagonal-based radii against `extent`
  /// (the full source extent in the current render pixel space).
  public func withRadiusReferenceExtent(_ extent: CGRect?) -> Self {
    .init(
      kernelRegistry: kernelRegistry,
      radiusReferenceExtent: extent,
      presentationTime: presentationTime
    )
  }
}

/// An extent-preserving image effect.
///
/// Conforming types are pure parameter values; `apply` is the feature's
/// evaluation, dispatched natively through the protocol witness — no registry
/// participates at runtime. Implementations must return an image cropped to
/// the input extent.
///
/// `apply` evaluates unconditionally: `isEnabled` is the CALLER's contract.
/// The evaluator and composite features (preset, local adjustment pipelines)
/// filter disabled features before calling `apply`.
public protocol ImageEffectFeatureType: Feature {

  /// Evaluates the effect over the input image.
  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage

  /// Validates the parameters before evaluation.
  func validate() throws

  /// Nested features evaluated inside this effect, exposed for tree-level
  /// validation such as duplicate-ID detection.
  var childFeatures: [any Feature] { get }
}

extension ImageEffectFeatureType {

  public func validate() throws {}

  public var childFeatures: [any Feature] { [] }
}

/// A feature that may change the current image domain (extent or coordinate
/// meaning), such as crop or future geometry correction.
///
/// The evaluator treats the returned image's extent as the new current
/// domain; implementations should reset their output to zero origin.
public protocol DomainFeatureType: Feature {

  /// Evaluates the domain change over the input image.
  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage

  /// Validates the parameters before evaluation.
  func validate() throws
}

extension DomainFeatureType {

  public func validate() throws {}
}

extension EffectPipeline {

  /// Evaluates the enabled effects in order over the input image.
  ///
  /// This is the pipeline-level evaluator UIs and renderers use without
  /// fabricating a whole document.
  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try effects
      .filter(\.isEnabled)
      .reduce(image) { image, effect in
        try effect.apply(to: image, context: context)
      }
  }
}

extension Feature {

  /// Compares this feature against another behind an existential.
  ///
  /// Method dispatch opens `Self`; differing dynamic types are never equal.
  public func isEqualFeature(to other: any Feature) -> Bool {
    guard let other = other as? Self else {
      return false
    }
    return self == other
  }
}

/// Compares two features behind existentials.
public func parametricFeatureIsEqual(_ lhs: any Feature, _ rhs: any Feature) -> Bool {
  lhs.isEqualFeature(to: rhs)
}

/// Compares two ordered existential feature arrays.
public func parametricFeaturesAreEqual(
  _ lhs: [any Feature],
  _ rhs: [any Feature]
) -> Bool {
  guard lhs.count == rhs.count else {
    return false
  }
  return zip(lhs, rhs).allSatisfy { pair in
    pair.0.isEqualFeature(to: pair.1)
  }
}
