import BrightroomParametric
import CoreGraphics

/// How the canvas composites the feature's blur mask.
///
/// Internal (not private) so tests can verify the stroke-domain mapping.
enum CanvasRenderPlan: Equatable {

  /// No blur is composited: the canvas shows the global effects only.
  case viewportBase

  /// The blur mask is composited over the global effects.
  case localBlur(LocalAdjustmentFeature<GaussianBlurFeature>)

  /// `.localBlur` when the mask is present, rooted at a brush, and has at
  /// least one stroke. An empty brush changes nothing at export, so the
  /// canvas does not composite it either.
  init(localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?) {
    guard
      let localBlur,
      case let .brush(brush) = localBlur.mask,
      brush.strokes.isEmpty == false
    else {
      self = .viewportBase
      return
    }
    self = .localBlur(localBlur)
  }

  var canvasMode: EditingCanvasMode {
    switch self {
    case .viewportBase:
      return .viewportBase
    case let .localBlur(layer):
      return .localAdjustment(effect: AnyImageEffect(layer.content))
    }
  }

  /// The committed strokes as canvas display records (y-down).
  ///
  /// The feature stores strokes in the working space (y-up) of the
  /// pre-crop source domain.
  ///
  /// - Parameters:
  ///   - geometry: The crop-output geometry when the destination canvas
  ///     displays the crop output, or nil when the canvas is sized to the
  ///     source image.
  ///   - domainHeight: The oriented source height.
  func committedStrokes(
    in geometry: EditingCanvasCropOutputGeometry?,
    domainHeight: CGFloat
  ) -> [EditingCanvasStrokeRecord] {
    switch self {
    case .viewportBase:
      return []
    case let .localBlur(layer):
      let sourceRecords = layer.mask.brushStrokes.map {
        EditingCanvasStrokeRecord(workingSpaceStroke: $0, domainHeight: domainHeight)
      }
      guard let geometry else {
        return sourceRecords
      }
      return sourceRecords.map {
        geometry.outputRecord(fromSourceRecord: $0)
      }
    }
  }
}
