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
/// Until the identified model is removed, mask nodes keep their own
/// `isEnabled` flags: a disabled `BrushMask` covers nothing, and a disabled
/// `MaskFeather` or `MaskSubtract` passes its input through.
public struct LocalAdjustment<Content: ImageEffect>: ImageEffect {

  /// The mask tree that produces the alpha used for compositing.
  public var maskTree: MaskTree

  /// The blend rule used to composite the adjusted image over the input.
  public var blendMode: LocalAdjustmentBlendMode

  /// The effects applied inside the mask.
  public var content: Content

  /// Creates a local adjustment.
  ///
  /// - Parameters:
  ///   - maskTree: The mask that limits where `content` applies.
  ///   - blendMode: The blend rule used to composite the adjusted image.
  ///   - content: The extent-preserving effects applied inside the mask.
  public init(
    maskTree: MaskTree,
    blendMode: LocalAdjustmentBlendMode = .alpha,
    @FeatureBuilder content: () -> Content
  ) {
    self.maskTree = maskTree
    self.blendMode = blendMode
    self.content = content()
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try MaskTreeRenderer.validate(maskTree)

    let base = image
    let adjusted = try content.apply(to: base, context: context)
    let mask = try MaskTreeRenderer(kernelRegistry: context.kernelRegistry)
      .render(maskTree, extent: base.extent)

    switch blendMode {
    case .alpha:
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
}

extension LocalAdjustment: Equatable where Content: Equatable {}
