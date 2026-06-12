import UIKit

import BrightroomEngine

/// A masking brush authored in host-friendly units.
///
/// Hosts describe the brush the way their controls express it; CropView
/// resolves the diameter into the pre-final-crop image pixels the masking
/// surface paints with, using its own viewport geometry. This keeps the
/// conversion math — and therefore the persisted stroke geometry — out of the
/// UI layers.
public struct CropViewMaskingBrush: Equatable {

  public enum Diameter: Equatable {
    /// Diameter in viewport points. CropView converts it with the tool
    /// surface's minimum-zoom fit so the painted width matches what the user
    /// sees on screen.
    case viewportPoints(CGFloat)
    /// Diameter already expressed in pre-final-crop image pixels.
    case imagePixels(CGFloat)
  }

  public var diameter: Diameter
  public var hardness: Double
  public var opacity: Double
  public var spacing: Double

  public init(
    diameter: Diameter,
    hardness: Double = 0.72,
    opacity: Double = 0.9,
    spacing: Double = 0.18
  ) {
    self.diameter = diameter
    self.hardness = hardness
    self.opacity = opacity
    self.spacing = spacing
  }
}

/// Shared policies for editors hosting CropView's masking surface.
///
/// PhotosCrop and PixelEditor previously duplicated these verbatim; keep the
/// single definition here so the editors cannot drift apart.
enum CropViewMaskingDefaults {

  /// Default blur effect whose radius scales with the crop diagonal so the
  /// apparent strength is comparable across image sizes.
  ///
  /// The effect is frozen into the layer at stroke commit; later crop changes
  /// do not rewrite already-painted layers.
  static func blurEffect(for crop: EditingCrop?) -> EditingStack.Edit.LocalAdjustmentEffect {
    guard let crop else {
      return .gaussianBlur(radius: 18)
    }

    let diagonalLength = hypot(crop.cropExtent.width, crop.cropExtent.height)
    return .gaussianBlur(radius: max(diagonalLength / 50, 1))
  }

  /// Converts a brush diameter authored in viewport points into the
  /// pre-final-crop image pixels the masking surface expects.
  ///
  /// Mirrors the Tool surface's minimum-zoom fit: the crop output is
  /// aspect-fitted into the full viewport bounds (CropView's contentInset
  /// does not participate there; the Tool surface uses insets only to center
  /// the content).
  static func imageSpaceBrushDiameter(
    pointDiameter: CGFloat,
    viewportSize: CGSize,
    crop: EditingCrop?
  ) -> CGFloat {
    guard
      let crop,
      viewportSize.width > 0,
      viewportSize.height > 0,
      crop.cropExtent.width > 0,
      crop.cropExtent.height > 0
    else {
      return pointDiameter
    }

    let fitScale = min(
      viewportSize.width / crop.cropExtent.width,
      viewportSize.height / crop.cropExtent.height
    )
    return pointDiameter / max(fitScale, 0.0001)
  }
}
