import CoreGraphics

extension CropFeature {

  /// The coordinate mapping from a crop's current input domain to its output.
  ///
  /// Evaluation straightens the input, extracts a zero-origin crop, and then
  /// turns that cropped image by an exact quarter turn. Coordinates are y-up.
  /// This value describes geometry only; it does not snap the stored parameters
  /// to pixels or choose a raster resolution.
  public struct OutputGeometry: Sendable {

    /// The requested final canvas, with its origin at zero.
    ///
    /// Every crop retains this canvas, with transparent pixels where the source
    /// is absent. Core Image rounds fractional bounds outward when evaluating
    /// them; callers that need exact raster dimensions should use pixel sizes.
    public let outputBounds: CGRect

    /// Maps absolute input coordinates to the final zero-origin output.
    ///
    /// Tool surfaces can invert this transform to map output gestures back to
    /// the input domain. Clipping is separate from this coordinate mapping.
    public var inputToOutputTransform: CGAffineTransform {
      inputToCropTransform.concatenating(cropToOutputTransform)
    }

    /// The zero-origin crop canvas before its final quarter turn.
    let cropBounds: CGRect

    /// Straightens the input and places the crop in its zero-origin canvas.
    let inputToCropTransform: CGAffineTransform

    /// Turns the cropped canvas using only exact zero/one matrix coefficients.
    let cropToOutputTransform: CGAffineTransform
  }

  /// Resolves this crop against the extent of its current input image.
  ///
  /// `rect` selects the straightened image before its final quarter turn,
  /// relative to `inputExtent.origin`. The selection is independent of output
  /// orientation; only `outputBounds` exchanges dimensions for a sideways turn.
  public func outputGeometry(in inputExtent: CGRect) -> OutputGeometry {
    let cropSize = rect.size
    let outputSize = quarterTurn.isSideways
      ? CGSize(width: cropSize.height, height: cropSize.width)
      : cropSize

    let center = CGPoint(
      x: inputExtent.minX + rect.midX,
      y: inputExtent.minY + rect.midY
    )
    let straighten = straightenRadians.isFinite ? CGFloat(straightenRadians) : 0
    let inputToCrop = CGAffineTransform(
      translationX: cropSize.width / 2,
      y: cropSize.height / 2
    )
    .rotated(by: -straighten)
    .translatedBy(x: -center.x, y: -center.y)

    // QuarterTurn's raw value is a y-down angle, so the image transform in
    // y-up coordinates uses its opposite sign.
    let cropToOutput: CGAffineTransform
    switch quarterTurn {
    case .zero:
      cropToOutput = .identity
    case .counterclockwise90:
      cropToOutput = .init(a: 0, b: 1, c: -1, d: 0, tx: cropSize.height, ty: 0)
    case .counterclockwise180:
      cropToOutput = .init(a: -1, b: 0, c: 0, d: -1, tx: cropSize.width, ty: cropSize.height)
    case .counterclockwise270:
      cropToOutput = .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: cropSize.width)
    }

    return OutputGeometry(
      outputBounds: CGRect(origin: .zero, size: outputSize),
      cropBounds: CGRect(origin: .zero, size: cropSize),
      inputToCropTransform: inputToCrop,
      cropToOutputTransform: cropToOutput
    )
  }
}
