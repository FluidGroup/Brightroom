import CoreGraphics

import BrightroomParametric
@testable import BrightroomUI

// The viewing and editing positions as value substitutions on the document
// (docs/vision-of-editing.md, "Viewing Point and Adjustment Point"). The
// canvas reads `effects`, `localBlur`, and `crop` directly, which is equivalent
// because of the body order; these state that equivalence for the tests.
extension ImageEditorFeature {

  /// Whether any global effect is present.
  var hasGlobalEffects: Bool {
    effects != Effects()
  }

  /// The document with the final crop replaced by a crop that covers the
  /// whole source: the viewing point of crop editing.
  func withCropNeutralized(imageSize: CGSize) -> Self {
    var copy = self
    copy.crop = CropFeature(
      topLeftRect: CGRect(origin: .zero, size: imageSize),
      imageSize: imageSize
    )
    return copy
  }

  /// The document without the vignette, which the canvas draws after the
  /// crop, over the crop frame.
  func withoutVignette() -> Self {
    var copy = self
    copy.vignette = nil
    return copy
  }

  /// The document without the blur mask: the base the canvas composites the
  /// blur over.
  func withoutLocalBlur() -> Self {
    var copy = self
    copy.localBlur = nil
    return copy
  }
}

/// Blur masks a host may restore that are not a plain brush, which the
/// editor cannot paint (`ImageEditorFeature.isLocalBlurPaintable`).
enum MasksThatAreNotABrush {

  static let brush = BrushMask(strokes: [
    .init(
      stampCenters: [CGPoint(x: 120, y: 150), CGPoint(x: 160, y: 150)],
      brush: .init(diameter: 40, hardness: 0.7, opacity: 1)
    )
  ])

  static let otherBrush = BrushMask(strokes: [
    .init(
      stampCenters: [CGPoint(x: 140, y: 150)],
      brush: .init(diameter: 20, hardness: 0.7, opacity: 1)
    )
  ])

  static let all: [Mask] = [
    .inverted(.brush(brush)),
    .feathered(.brush(brush), radius: 8),
    .union([.brush(brush), .brush(otherBrush)]),
    .intersection([.brush(brush), .brush(otherBrush)]),
    .subtraction(.brush(brush), removing: .brush(otherBrush)),
  ]
}
