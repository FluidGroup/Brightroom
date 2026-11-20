import BrightroomParametric
import CoreGraphics

/// Memoized canvas records for the committed blur-mask strokes.
///
/// Mapping every stamp (working space to canvas, then into the crop
/// output) is linear in the painted stamps, and the canvas recomputes its
/// display on every host update (`EditingCanvasView.updateDisplay()` on iOS).
/// An unchanged mask compares equal cheaply (its stroke arrays are shared),
/// and returning the same record arrays lets the canvas renderer's own
/// equality check short-circuit too.
struct CommittedStrokeRecords {

  private var source: (
    localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?,
    records: [EditingCanvasStrokeRecord]
  )?

  private var output: (
    localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?,
    geometry: EditingCanvasCropOutputGeometry,
    records: [EditingCanvasStrokeRecord]
  )?

  /// Records in the source domain (y-down), for a canvas sized to the
  /// source image.
  mutating func sourceRecords(
    localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?,
    domainHeight: CGFloat
  ) -> [EditingCanvasStrokeRecord] {
    if let source, source.localBlur == localBlur {
      return source.records
    }
    let records = CanvasRenderPlan(localBlur: localBlur)
      .committedStrokes(in: nil, domainHeight: domainHeight)
    source = (localBlur, records)
    return records
  }

  /// Records in the crop-output domain of `geometry`, for the tool canvas.
  mutating func outputRecords(
    localBlur: LocalAdjustmentFeature<GaussianBlurFeature>?,
    geometry: EditingCanvasCropOutputGeometry,
    domainHeight: CGFloat
  ) -> [EditingCanvasStrokeRecord] {
    if let output, output.localBlur == localBlur, output.geometry == geometry {
      return output.records
    }
    let records = sourceRecords(localBlur: localBlur, domainHeight: domainHeight).map {
      geometry.outputRecord(fromSourceRecord: $0)
    }
    output = (localBlur, geometry, records)
    return records
  }
}
