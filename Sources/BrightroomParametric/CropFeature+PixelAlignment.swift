//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import CoreGraphics

/// A whole-pixel size of at least 1x1.
///
/// Package access: BrightroomEngine sizes its bitmap contexts with it.
package struct PixelDimensions: Equatable, Sendable {

  package var width: Int
  package var height: Int

  package var cgSize: CGSize {
    .init(width: CGFloat(width), height: CGFloat(height))
  }

  package init(width: Int, height: Int) {
    precondition(width > 0)
    precondition(height > 0)

    self.width = width
    self.height = height
  }

  package init(
    _ size: CGSize,
    epsilon: CGFloat = PixelAlignedCrop.pixelEpsilon
  ) {
    self.init(
      width: max(1, Int(floor(Self.finite(size.width, fallback: 1) + epsilon))),
      height: max(1, Int(floor(Self.finite(size.height, fallback: 1) + epsilon)))
    )
  }

  private static func finite(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
    value.isFinite ? value : fallback
  }
}

/// An inward pixel-aligned rectangle for crops without straightening.
private struct PixelCropRect {

  let x: Int
  let y: Int
  let width: Int
  let height: Int

  var cgRect: CGRect {
    .init(
      x: CGFloat(x),
      y: CGFloat(y),
      width: CGFloat(width),
      height: CGFloat(height)
    )
  }

  init(
    x: Int,
    y: Int,
    width: Int,
    height: Int
  ) {
    precondition(x >= 0)
    precondition(y >= 0)
    precondition(width > 0)
    precondition(height > 0)

    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  init(
    cropExtent: CGRect,
    in imageSize: PixelDimensions,
    epsilon: CGFloat = PixelAlignedCrop.pixelEpsilon
  ) {
    let cropExtent = Self.finite(
      cropExtent,
      fallback: .init(origin: .zero, size: .init(width: 1, height: 1))
    )
    .standardized

    let imageWidth = CGFloat(imageSize.width)
    let imageHeight = CGFloat(imageSize.height)
    let minX = Self.clamp(cropExtent.minX, lower: 0, upper: imageWidth)
    let minY = Self.clamp(cropExtent.minY, lower: 0, upper: imageHeight)
    let maxX = Self.clamp(cropExtent.maxX, lower: 0, upper: imageWidth)
    let maxY = Self.clamp(cropExtent.maxY, lower: 0, upper: imageHeight)

    let xSpan = Self.pixelSpan(
      lower: min(minX, maxX),
      upper: max(minX, maxX),
      upperBound: imageSize.width,
      epsilon: epsilon
    )
    let ySpan = Self.pixelSpan(
      lower: min(minY, maxY),
      upper: max(minY, maxY),
      upperBound: imageSize.height,
      epsilon: epsilon
    )

    self.init(
      x: xSpan.lower,
      y: ySpan.lower,
      width: xSpan.upper - xSpan.lower,
      height: ySpan.upper - ySpan.lower
    )
  }

  private static func pixelSpan(
    lower: CGFloat,
    upper: CGFloat,
    upperBound: Int,
    epsilon: CGFloat
  ) -> (lower: Int, upper: Int) {
    let upperBound = CGFloat(upperBound)
    let snappedLower = Int(clamp(ceil(lower - epsilon), lower: 0, upper: upperBound))
    let snappedUpper = Int(clamp(floor(upper + epsilon), lower: 0, upper: upperBound))

    if snappedUpper > snappedLower {
      return (snappedLower, snappedUpper)
    }

    // A sub-pixel or broken extent cannot be represented as an inward-only integer rect.
    // Keep rendering viable by selecting the nearest single pixel inside the image.
    let fallbackLower = Int(clamp(
      floor((lower + upper) / 2),
      lower: 0,
      upper: max(0, upperBound - 1)
    ))
    return (fallbackLower, fallbackLower + 1)
  }

  private static func finite(_ rect: CGRect, fallback: CGRect) -> CGRect {
    guard
      rect.origin.x.isFinite,
      rect.origin.y.isFinite,
      rect.size.width.isFinite,
      rect.size.height.isFinite
    else {
      return fallback
    }

    return rect
  }

  private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}

/// A pixel-sized crop after straightening, followed by an independent output turn.
///
/// The rectangle uses y-down image coordinates before the quarter turn. Its
/// origin may be fractional under straightening; only its dimensions determine
/// the raster size. Output orientation never changes the selected source area.
internal struct PixelAlignedCrop: Equatable, Sendable {

  internal static let pixelEpsilon: CGFloat = 1e-8

  internal var imageSize: PixelDimensions

  /// The y-down selection after straightening and before the output turn.
  internal var cropExtent: CGRect

  /// The orientation applied to the already-cropped output.
  internal var quarterTurn: QuarterTurn

  /// The free angle applied to the source before extracting the crop.
  internal var straightenRadians: Double

  /// Canonicalizes a y-down selection before its output quarter turn.
  ///
  /// Without straightening, source edges snap inward to the source pixel grid.
  /// With straightening, the selection is first fitted so its straightened
  /// footprint lies inside the source (shrinking uniformly and moving only if
  /// needed), then its dimensions snap inward about the fitted center. The
  /// quarter turn is retained separately and does not change the selection
  /// rectangle.
  internal init(
    topLeftRect: CGRect,
    imageSize: CGSize,
    quarterTurn: QuarterTurn = .zero,
    straightenRadians: Double = 0,
    epsilon: CGFloat = Self.pixelEpsilon
  ) {
    let pixelImageSize = PixelDimensions(imageSize, epsilon: epsilon)
    let straighten = straightenRadians.isFinite ? straightenRadians : 0

    self.imageSize = pixelImageSize
    self.quarterTurn = quarterTurn
    self.straightenRadians = straighten

    if straighten == 0 {
      self.cropExtent = PixelCropRect(
        cropExtent: topLeftRect,
        in: pixelImageSize,
        epsilon: epsilon
      ).cgRect
    } else {
      var fitted = CropGeometry.fittingStraightenedRect(
        rect: topLeftRect,
        in: pixelImageSize.cgSize,
        straightenRadians: straighten
      )
      if fitted.width < 1 - epsilon || fitted.height < 1 - epsilon {
        // An inward integer crop is impossible. Use the nearest fitting 1x1
        // canvas instead of expanding a thin crop beyond the source bounds.
        fitted = CropGeometry.fittingStraightenedRect(
          rect: CGRect(x: fitted.midX - 0.5, y: fitted.midY - 0.5, width: 1, height: 1),
          in: pixelImageSize.cgSize,
          straightenRadians: straighten
        )
      }
      let size = PixelDimensions(fitted.size, epsilon: epsilon).cgSize
      // A source too small to contain a rotated 1x1 pixel retains that minimum
      // canvas at the fitted center; uncovered corners remain transparent.
      self.cropExtent = size == fitted.size ? fitted : CGRect(
        x: fitted.midX - size.width / 2,
        y: fitted.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
    }
  }
}

// MARK: - CropFeature in top-left coordinates

extension CropFeature {

  /// Creates a crop feature from a y-down (top-left origin) selection,
  /// snapped to the pixel grid the same way every render snaps it, so UI
  /// commits and renders agree exactly.
  ///
  /// `topLeftRect` is the selection after straightening and before the
  /// output quarter turn. Canonicalization does not depend on `quarterTurn`.
  /// Source edges snap inward without straightening. Straightened crops are
  /// fitted so their straightened footprint lies inside the source (shrinking
  /// uniformly and moving only if needed), then their dimensions snap inward
  /// about the fitted center; the origin can stay fractional.
  ///
  /// This initializer also flips the rectangle from y-down (top-left) to the
  /// feature's y-up coordinates (Core Image bottom-left).
  ///
  /// - Parameter imageSize: The oriented pixel size of the crop's input.
  public init(
    topLeftRect: CGRect,
    imageSize: CGSize,
    quarterTurn: QuarterTurn = .zero,
    straightenRadians: Double = 0
  ) {
    let aligned = PixelAlignedCrop(
      topLeftRect: topLeftRect,
      imageSize: imageSize,
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians
    )
    let snapped = aligned.cropExtent
    let imageHeight = CGFloat(aligned.imageSize.height)

    self.init(
      rect: CGRect(
        x: snapped.minX,
        y: imageHeight - snapped.maxY,
        width: snapped.width,
        height: snapped.height
      ),
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians
    )
  }

  /// The pre-quarter-turn selection in y-down (top-left origin) coordinates.
  ///
  /// This conversion changes only the y-axis convention. Features created
  /// through `init(topLeftRect:…)` have already been pixel-aligned; this
  /// method does not snap raw `rect` values.
  public func topLeftRect(imageSize: CGSize) -> CGRect {
    CGRect(
      x: rect.minX,
      y: imageSize.height - rect.maxY,
      width: rect.width,
      height: rect.height
    )
  }

  /// This crop snapped to the pixel grid of an input of `imageSize`.
  func pixelAlignedCrop(imageSize: CGSize) -> PixelAlignedCrop {
    PixelAlignedCrop(
      topLeftRect: topLeftRect(imageSize: imageSize),
      imageSize: imageSize,
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians
    )
  }

  /// Whether two crops select the same pixels, with the same quarter turn
  /// and straighten, from an input of `imageSize`.
  ///
  /// Sub-pixel differences that snap to the same pixel-aligned rectangle are
  /// equivalent. The editing canvas uses this to decide whether a crop change
  /// is worth committing.
  public func isPixelEquivalent(to other: CropFeature, imageSize: CGSize) -> Bool {
    pixelAlignedCrop(imageSize: imageSize)
      == other.pixelAlignedCrop(imageSize: imageSize)
  }
}
