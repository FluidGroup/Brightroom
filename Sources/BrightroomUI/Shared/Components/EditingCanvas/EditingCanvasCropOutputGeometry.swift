import BrightroomParametric
import CoreGraphics

/// Describes the coordinate relationship between the pre-final-crop source
/// image and the image produced by applying the final Crop Feature.
///
/// Tool surfaces display and navigate the crop output, but persisted Tool
/// strokes still belong to the pre-crop Feature domain. This type keeps that
/// domain crossing explicit and shared by rendering, gesture input, and commit
/// paths.
struct EditingCanvasCropOutputGeometry: Equatable {
  /// The size of the image domain before the final Crop Feature is applied.
  let sourceImageSize: CGSize

  /// The zero-origin canvas size displayed by Tool surfaces.
  let outputSize: CGSize

  /// Maps persisted Tool stroke geometry into the displayed crop output.
  let sourceToOutputTransform: CGAffineTransform

  /// Maps Tool gesture geometry back into the persisted pre-crop domain.
  let outputToSourceTransform: CGAffineTransform

  /// The zero-origin bounds of the displayed crop-output image.
  var outputBounds: CGRect {
    CGRect(origin: .zero, size: outputSize)
  }

  init?(crop: CropEditingState) {
    let cropRect = crop.cropExtent.standardized
    guard
      crop.imageSize.width > 0,
      crop.imageSize.height > 0,
      cropRect.width > 0,
      cropRect.height > 0
    else {
      return nil
    }

    // Both crop models store the selection before output rotation; only y is
    // flipped here. Building a feature directly keeps Tool gesture geometry
    // continuous instead of applying export's pixel snapping.
    let feature = CropFeature(
      id: crop.id,
      cropRect: CGRect(
        x: cropRect.minX,
        y: crop.imageSize.height - cropRect.maxY,
        width: cropRect.width,
        height: cropRect.height
      ),
      rotation: crop.rotation.quarterTurn,
      straightenRadians: crop.adjustmentAngle.radians
    )
    let geometry = feature.outputGeometry(in: CGRect(origin: .zero, size: crop.imageSize))
    let outputSize = geometry.outputBounds.size
    let displayToCoreImageTransform = CGAffineTransform(scaleX: 1, y: -1)
      .concatenating(.init(translationX: 0, y: crop.imageSize.height))
    let outputDisplayTransform = CGAffineTransform(scaleX: 1, y: -1)
      .concatenating(.init(translationX: 0, y: outputSize.height))
    let sourceToOutputTransform = displayToCoreImageTransform
      .concatenating(geometry.sourceToOutputTransform)
      .concatenating(outputDisplayTransform)
    self.sourceImageSize = crop.imageSize
    self.outputSize = outputSize
    self.sourceToOutputTransform = sourceToOutputTransform
    self.outputToSourceTransform = sourceToOutputTransform.inverted()
  }

  func sourceRecord(fromOutputRecord record: EditingCanvasStrokeRecord) -> EditingCanvasStrokeRecord {
    record.applying(outputToSourceTransform)
  }

  func outputRecord(fromSourceRecord record: EditingCanvasStrokeRecord) -> EditingCanvasStrokeRecord {
    record.applying(sourceToOutputTransform)
  }
}

private extension EditingCanvasStrokeRecord {
  func applying(_ transform: CGAffineTransform) -> EditingCanvasStrokeRecord {
    EditingCanvasStrokeRecord(
      stamps: stamps.map { $0.applying(transform) },
      brush: brush
    )
  }
}
