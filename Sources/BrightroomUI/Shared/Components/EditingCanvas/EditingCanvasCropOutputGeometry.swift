import BrightroomEngine
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

  /// The final crop rectangle in pre-final-crop source coordinates.
  let cropRectInSource: CGRect

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

  init?(crop: EditingCrop) {
    let cropRect = crop.cropExtent.standardized
    guard
      crop.imageSize.width > 0,
      crop.imageSize.height > 0,
      cropRect.width > 0,
      cropRect.height > 0
    else {
      return nil
    }

    let outputSize = CGSize(
      width: max(cropRect.width, 1),
      height: max(cropRect.height, 1)
    )
    let outputCenter = CGPoint(x: outputSize.width / 2, y: outputSize.height / 2)
    let displayToCoreGraphicsTransform = CGAffineTransform(scaleX: 1, y: -1)
      .concatenating(.init(translationX: 0, y: crop.imageSize.height))
    let cropTranslation = CGAffineTransform(
      translationX: -cropRect.minX,
      y: -(crop.imageSize.height - cropRect.maxY)
    )
    // Match CGImage.croppedWithColorspace while keeping persisted strokes in
    // EditingCanvas' display-oriented source coordinate space.
    let outputRotation = CGAffineTransform(
      translationX: outputCenter.x,
      y: outputCenter.y
    )
    .rotated(by: -crop.aggregatedRotation.radians)
    .translatedBy(x: -outputCenter.x, y: -outputCenter.y)
    let outputDisplayTransform = CGAffineTransform(scaleX: 1, y: -1)
      .concatenating(.init(translationX: 0, y: outputSize.height))
    let sourceToOutputTransform = displayToCoreGraphicsTransform
      .concatenating(cropTranslation)
      .concatenating(outputRotation)
      .concatenating(outputDisplayTransform)
    guard Self.isInvertible(sourceToOutputTransform) else {
      return nil
    }

    self.sourceImageSize = crop.imageSize
    self.cropRectInSource = cropRect
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

  private static func isInvertible(_ transform: CGAffineTransform) -> Bool {
    abs(transform.a * transform.d - transform.b * transform.c) > 0.000001
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
