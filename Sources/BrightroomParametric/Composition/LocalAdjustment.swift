//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation

/// Applies extent-preserving effects only where a mask allows.
///
/// The content is evaluated from the current image, the mask tree is rendered
/// over the current image extent, and the adjusted image is composited back
/// over the current image through the mask alpha. The extent never changes.
///
/// The content must be an `ImageEffect`, so a domain feature such as
/// `CropFeature` cannot appear inside a local adjustment:
///
/// ```swift
/// LocalAdjustment(maskTree: tree) {
///   GaussianBlurFeature(value: 40)
/// }
/// ```
///
/// Mask coordinates follow the current-Feature-domain contract: brush stamps
/// are Core Image working-space coordinates (bottom-left origin, y-up) of the
/// image this feature receives.
///
/// An empty mask composite anywhere in the tree throws before the content is
/// evaluated. Content that returns its input unchanged (for example
/// `EmptyFeature`, an empty array, or a `nil` member) makes the whole
/// adjustment return its input.
public struct LocalAdjustment<Content: ImageEffect>: ImageEffect {

  /// The mask tree that produces the alpha used for compositing.
  public var maskTree: MaskTree

  /// The effects applied inside the mask.
  public var content: Content

  /// Creates a local adjustment.
  ///
  /// - Parameters:
  ///   - maskTree: The mask that limits where `content` applies.
  ///   - content: The extent-preserving effects applied inside the mask.
  public init(
    maskTree: MaskTree,
    @FeatureBuilder content: () -> Content
  ) {
    self.maskTree = maskTree
    self.content = content()
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let base = image
    // The mask renders first so a malformed mask tree fails before the
    // content is evaluated.
    let mask = try MaskTreeRenderer().render(maskTree, extent: base.extent)
    let adjusted = try content.apply(to: base, context: context)

    // Content that applied nothing returns its input instance. Blending the
    // base over itself is only approximately the base in a half-float
    // context, so return it as is.
    guard adjusted !== base else {
      return base
    }

    return adjusted.applyingFilter(
      "CIBlendWithAlphaMask",
      parameters: [
        kCIInputBackgroundImageKey: base,
        kCIInputMaskImageKey: mask,
      ]
    )
    .cropped(to: base.extent)
  }
}

extension LocalAdjustment: Equatable where Content: Equatable {}
