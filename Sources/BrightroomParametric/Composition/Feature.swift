//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation

/// A step of a parametric editing document, composed statically.
///
/// A feature is a plain value: it has no identity, history, or editing
/// session. It either evaluates itself (a *primitive*, which implements
/// `apply(to:context:)` and leaves `Body` as `Never`) or describes its content
/// through `body` (a *composite*, which gets `apply(to:context:)` from the
/// default implementation that evaluates `body`).
///
/// ```swift
/// struct PhotoDocument: Feature, Equatable {
///   var exposure = ExposureFeature(value: 0)
///   var localBlur: LocalAdjustment<GaussianBlurFeature>? = nil
///   var crop: CropFeature
///
///   var body: some Feature {
///     exposure
///     localBlur
///     crop
///   }
/// }
/// ```
///
/// Members of a `body` evaluate in order, and each one receives the output of
/// the previous one. A feature that is not an `ImageEffect` (for example
/// `CropFeature`) may change the image domain; later members work in the new
/// domain.
///
/// Enablement is part of the composition: a `nil` member, a branch not taken,
/// or a mask node left out contributes nothing.
///
/// An `any ImageEffect` value cannot be written in a `body`. Store content
/// decided by data as `AnyImageEffect` (or `[AnyImageEffect]`) instead.
///
/// Use `ParametricImageRenderer.makeImage(from:document:radiusReferenceExtent:presentationTime:)`
/// to evaluate a document from a source image. It prepares the chain entry
/// once: the source is translated to zero origin and value-form radii resolve
/// against its extent. Calling `apply(to:context:)` directly skips the origin
/// normalization; a composite called with a context that has no
/// `radiusReferenceExtent` treats its input as the chain entry.
public protocol Feature: Sendable {

  /// The type of the feature's content.
  ///
  /// Primitive features keep the default, `Never`.
  associatedtype Body: Feature = Never

  /// The content of a composite feature, evaluated in order.
  ///
  /// Primitive features do not implement this; accessing it traps.
  @FeatureBuilder var body: Body { get }

  /// Evaluates the feature over the input image.
  ///
  /// Primitive features implement this. Composite features use the default
  /// implementation, which evaluates `body`.
  ///
  /// - Parameters:
  ///   - image: The output of the previous feature, in the current domain.
  ///   - context: Render-time values shared by the whole evaluation, created
  ///     once at chain entry.
  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage
}

/// A feature that preserves the extent and coordinate domain of its input.
///
/// Places that only accept image effects, such as the content of
/// `LocalAdjustment` or a `some ImageEffect` body, reject domain features
/// like `CropFeature` at compile time. A composite is an image effect only
/// when its body is one.
public protocol ImageEffect: Feature where Body: ImageEffect {}

extension Feature where Body == Never {

  /// A primitive feature has no body; it implements `apply(to:context:)`.
  public var body: Never {
    fatalError(
      "\(Self.self) is a primitive feature and has no body. Primitive features implement apply(to:context:)."
    )
  }

  /// Makes a conformance that provides neither `body` nor its own
  /// `apply(to:context:)` (or misspells it) fail to compile instead of
  /// trapping at the first render.
  @available(
    *,
    unavailable,
    message: "Implement apply(to:context:) for a primitive feature, or declare a body for a composite feature."
  )
  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    fatalError()
  }
}

extension Feature {

  /// Evaluates `body`.
  ///
  /// Primitive features replace this with their own evaluation. When the
  /// context has no radius basis yet, `image` is the chain entry and its
  /// extent becomes the basis for the whole body.
  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try body.apply(to: image, context: context.resolvingChainEntry(for: image))
  }
}

extension FeatureEvaluationContext {

  /// Returns a context whose radius basis is set, using `image` as the chain
  /// entry when no basis has been resolved yet.
  ///
  /// Composites call this before evaluating their members, so a direct
  /// `apply(to:context:)` on a document with the default context resolves
  /// value-form radii against the document's input rather than against
  /// whatever a mid-chain crop produces. Renderers always resolve the basis
  /// at chain entry, so this never changes their result.
  func resolvingChainEntry(for image: CIImage) -> FeatureEvaluationContext {
    guard radiusReferenceExtent == nil, image.extent.isInfinite == false else {
      return self
    }
    return withRadiusReferenceExtent(image.extent)
  }
}

extension Never: ImageEffect {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    switch self {}
  }
}
