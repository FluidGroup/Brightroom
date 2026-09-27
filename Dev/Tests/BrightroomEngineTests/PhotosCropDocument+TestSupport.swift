import CoreGraphics

import BrightroomParametric
@testable import BrightroomUI

// The viewing and editing positions as value substitutions on the document
// (docs/vision-of-editing.md, "Viewing Point and Adjustment Point"). The
// canvas reads `effects`, `blurMask`, and `crop` directly, which is equivalent
// because of the body order; these state that equivalence for the tests.
extension PhotosCropFeature {

  /// Whether any global effect is present.
  var hasGlobalEffects: Bool {
    effects != Effects()
  }

  /// The document with the final crop replaced by a crop that covers the
  /// whole source: the viewing point of crop editing.
  func withCropNeutralized(imageSize: CGSize) -> Self {
    var copy = self
    copy.crop = CropFeature(
      displayCropRect: CGRect(origin: .zero, size: orientedImageSize),
      imageSize: orientedImageSize
    )
    return copy
  }

  /// The document without the blur mask: the base the canvas composites the
  /// blur over.
  func withoutBlurMask() -> Self {
    var copy = self
    copy.blurMask = nil
    return copy
  }
}
