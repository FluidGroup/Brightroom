import BrightroomEngine
import BrightroomParametric
import CoreGraphics
import SwiftUI
import UIKit

/// Selects how an editing canvas host builds the image shown by its
/// viewport.
enum EditingCanvasMode: Equatable {
  /// Draws the current crop/source with global filters in the visible viewport.
  ///
  /// This is the lightest mode and is the preferred default for realtime
  /// interactions such as scrolling, zooming, and base filter slider changes.
  /// Saved local adjustment layers are intentionally ignored.
  case viewportBase

  /// Renders and optionally edits one local adjustment layer in the viewport.
  ///
  /// The mask is kept in the canvas runtime instead of being rasterized through
  /// CoreGraphics.
  case localAdjustment(effect: EffectPipeline)

  /// Materializes the global edit stack into a read-only preview image.
  ///
  /// Saved local adjustments are intentionally excluded from this UI preview
  /// path. Use `localAdjustment(effect:)` while editing one local adjustment, and
  /// use the renderer when the final composed result is required.
  case renderedEditPreview
}

struct EditingCanvasBrush: Equatable {
  var size: Double
  var hardness: Double
  var opacity: Double
  var spacing: Double

  init(
    size: Double = 56,
    hardness: Double = 0.72,
    opacity: Double = 1.0,
    spacing: Double = 0.05
  ) {
    self.size = size
    self.hardness = hardness
    self.opacity = opacity
    self.spacing = spacing
  }
}

public struct EditingCanvasStrokeSmoothingConfiguration: Equatable {
  public var algorithm: EditingCanvasStrokeSmoothingAlgorithm
  public var strength: Double

  public init(
    algorithm: EditingCanvasStrokeSmoothingAlgorithm = .bezier,
    strength: Double = 0.85
  ) {
    self.algorithm = algorithm
    self.strength = strength
  }
}

public enum EditingCanvasStrokeSmoothingAlgorithm: String {
  case raw
  case bezier
  case catmullRom
  case movingAverage
}
