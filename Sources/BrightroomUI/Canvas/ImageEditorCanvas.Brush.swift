import UIKit

import BrightroomEngine
import BrightroomParametric

extension ImageEditorCanvas {

  /// A masking brush authored in host-friendly units.
  ///
  /// Hosts describe the brush the way their controls express it; the canvas
  /// resolves the diameter into the pre-final-crop image pixels the masking
  /// surface paints with, using its own viewport geometry. This keeps the
  /// conversion math — and therefore the persisted stroke geometry — out of the
  /// UI layers.
  public struct Brush: Equatable {

    public enum Diameter: Equatable {
      /// Diameter in viewport points. The canvas converts it with the tool
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
      opacity: Double = 1.0,
      spacing: Double = 0.05
    ) {
      self.diameter = diameter
      self.hardness = hardness
      self.opacity = opacity
      self.spacing = spacing
    }
  }
}

extension ImageEditorCanvas.Brush {

  /// Converts a brush diameter authored in viewport points into the
  /// pre-final-crop image pixels the masking surface expects.
  ///
  /// Mirrors the Tool surface's minimum-zoom fit: the crop output is
  /// aspect-fitted into the full viewport bounds (the canvas's content inset
  /// does not participate there; the Tool surface uses insets only to center
  /// the content).
  static func imageSpaceDiameter(
    pointDiameter: CGFloat,
    viewportSize: CGSize,
    crop: CropFeature?
  ) -> CGFloat {
    guard
      let crop,
      viewportSize.width > 0,
      viewportSize.height > 0,
      crop.cropRect.width > 0,
      crop.cropRect.height > 0
    else {
      return pointDiameter
    }

    // Brush sizing follows the canvas after the final output quarter turn.
    let outputSize = crop.rotation.isSideways
      ? CGSize(width: crop.cropRect.height, height: crop.cropRect.width)
      : crop.cropRect.size
    let fitScale = min(
      viewportSize.width / outputSize.width,
      viewportSize.height / outputSize.height
    )
    return pointDiameter / max(fitScale, 0.0001)
  }
}
