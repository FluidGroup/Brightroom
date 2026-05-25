import BrightroomEngine
import CoreGraphics
import SwiftUI
import UIKit

public enum EditingCanvasInteractionMode: String, CaseIterable, Identifiable {
  case draw
  case view

  public var id: Self { self }

  public var title: String {
    switch self {
    case .draw:
      return "Draw"
    case .view:
      return "View"
    }
  }
}

extension EditingCanvasInteractionMode {
  var isDrawingEnabled: Bool {
    switch self {
    case .draw:
      return true
    case .view:
      return false
    }
  }

  var panMinimumNumberOfTouches: Int {
    switch self {
    case .draw:
      return 2
    case .view:
      return 1
    }
  }
}

public struct EditingCanvasMetrics: Equatable {
  public var zoomScale: Double
  public var stampCount: Int
  public var strokeCount: Int
  public var framesPerSecond: Double

  public init(
    zoomScale: Double = 1,
    stampCount: Int = 0,
    strokeCount: Int = 0,
    framesPerSecond: Double = 0
  ) {
    self.zoomScale = zoomScale
    self.stampCount = stampCount
    self.strokeCount = strokeCount
    self.framesPerSecond = framesPerSecond
  }
}

/// Selects how `SwiftUIEditingCanvasView` builds the image shown by its
/// viewport.
public enum EditingCanvasMode: Equatable {
  /// Draws the current crop/source with global filters in the visible viewport.
  ///
  /// This is the lightest mode and is the preferred default for realtime
  /// interactions such as scrolling, zooming, and base filter slider changes.
  /// Saved local adjustment layers are intentionally ignored.
  case viewportBase

  /// Renders and optionally edits one local adjustment layer in the viewport.
  ///
  /// Use this mode with `.interactionMode(.view)` when an existing local
  /// adjustment should remain visible while drawing is disabled. The mask is
  /// kept in the canvas runtime instead of being rasterized through CoreGraphics.
  case localAdjustment(effect: EditingStack.Edit.LocalAdjustmentEffect)

  /// Materializes the full edit stack into a read-only preview image.
  ///
  /// This mode is useful for idle or final-preview surfaces that need the same
  /// composed result as the engine path. It can be expensive when local
  /// adjustments exist because the compatibility path may rasterize saved masks
  /// through CoreGraphics.
  case renderedEditPreview

  /// Compatibility spelling for `renderedEditPreview`.
  ///
  /// Prefer `viewportBase` for realtime preview and `renderedEditPreview` when
  /// the heavier, fully materialized edit result is explicitly required.
  case preview

  var localEffect: EditingStack.Edit.LocalAdjustmentEffect {
    switch self {
    case .viewportBase, .renderedEditPreview, .preview:
      return .gaussianBlur(radius: 0)
    case let .localAdjustment(effect):
      return effect
    }
  }

  var activeLocalEffect: EditingStack.Edit.LocalAdjustmentEffect? {
    switch self {
    case .viewportBase, .renderedEditPreview, .preview:
      return nil
    case let .localAdjustment(effect):
      return effect
    }
  }

  var rendersFullEditPreview: Bool {
    switch self {
    case .renderedEditPreview, .preview:
      return true
    case .viewportBase, .localAdjustment:
      return false
    }
  }

  var defaultInteractionMode: EditingCanvasInteractionMode {
    switch self {
    case .viewportBase, .renderedEditPreview, .preview:
      return .view
    case .localAdjustment:
      return .draw
    }
  }
}

public struct EditingCanvasBrush: Equatable {
  public var size: Double
  public var hardness: Double
  public var opacity: Double
  public var spacing: Double

  public init(
    size: Double = 56,
    hardness: Double = 0.72,
    opacity: Double = 0.9,
    spacing: Double = 0.18
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

public enum EditingCanvasStrokeSmoothingAlgorithm: String, CaseIterable, Identifiable {
  case raw
  case bezier
  case catmullRom
  case movingAverage

  public var id: Self { self }

  public var title: String {
    switch self {
    case .raw:
      return "Raw"
    case .bezier:
      return "Bezier"
    case .catmullRom:
      return "Catmull"
    case .movingAverage:
      return "Avg"
    }
  }
}
