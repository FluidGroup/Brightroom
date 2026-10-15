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

  /// The largest term of a ratio in lowest terms that
  /// `init(topLeftRect:imageSize:quarterTurn:straightenRadians:aspectRatio:epsilon:)`
  /// keeps exact.
  ///
  /// An exact crop is a whole multiple of the terms, so it can be up to one
  /// term minus a pixel smaller than the selection on each axis. 32 keeps
  /// every common ratio exact — 1:1, 4:3, 3:2, 5:4, 7:5, 16:9, 16:10, 20:9,
  /// 21:9 (7:3), 32:9, and their turned forms — and the camera ratios an
  /// "original" lock takes from an image, while a loss stays within 31
  /// pixels. Larger terms come from image sizes such as 1123×794 or a
  /// screenshot's 1179×2556; the multiples of those are too coarse, so they
  /// keep the nearest snap and miss the ratio by less than a pixel or two.
  internal static let maximumExactAspectRatioTerm = 32

  /// Canonicalizes a selection drawn with `aspectRatio` (in the selection's
  /// orientation, before the output quarter turn) so its whole-pixel size
  /// has exactly that ratio, when the ratio allows it.
  ///
  /// Edge-by-edge snapping takes each edge inward separately, so a square
  /// selection can become 479×478. When the ratio in lowest terms is p:q with
  /// both terms at most `maximumExactAspectRatioTerm`, the size is instead
  /// the largest k·p × k·q that fits in the largest whole-pixel size inside
  /// the selection (clipped to the image; with straightening, fitted as
  /// `init(topLeftRect:imageSize:quarterTurn:straightenRadians:epsilon:)`
  /// fits it). It is centered on the selection: without straightening at a
  /// whole-pixel origin inside the image, with straightening at the fitted
  /// center, whose origin can stay fractional. Any other ratio, a selection
  /// smaller than p × q pixels, or an invalid one is snapped as that
  /// initializer snaps it.
  internal init(
    topLeftRect: CGRect,
    imageSize: CGSize,
    quarterTurn: QuarterTurn = .zero,
    straightenRadians: Double = 0,
    aspectRatio: AspectRatio,
    epsilon: CGFloat = Self.pixelEpsilon
  ) {
    self.init(
      topLeftRect: topLeftRect,
      imageSize: imageSize,
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians,
      epsilon: epsilon
    )

    guard
      let terms = Self.exactTerms(of: aspectRatio),
      topLeftRect.minX.isFinite, topLeftRect.minY.isFinite,
      topLeftRect.width.isFinite, topLeftRect.height.isFinite
    else {
      return
    }

    let imageBounds = CGRect(origin: .zero, size: self.imageSize.cgSize)
    let selection: CGRect
    if self.straightenRadians == 0 {
      selection = imageBounds.intersection(topLeftRect.standardized)
    } else {
      selection = CropGeometry.fittingStraightenedRect(
        rect: topLeftRect.standardized,
        in: imageBounds.size,
        straightenRadians: self.straightenRadians
      )
    }
    guard selection.isNull == false, selection.width > 0, selection.height > 0 else {
      return
    }

    // The largest whole-pixel size inside the selection, then the largest
    // multiple of the terms inside that.
    let availableWidth = Int(floor(selection.width + epsilon))
    let availableHeight = Int(floor(selection.height + epsilon))
    let multiple = min(availableWidth / terms.width, availableHeight / terms.height)
    guard multiple >= 1 else {
      return
    }
    let size = CGSize(
      width: CGFloat(multiple * terms.width),
      height: CGFloat(multiple * terms.height)
    )

    if self.straightenRadians == 0 {
      // Whole-pixel origin nearest the centered one, inside the image.
      let x = min(max((selection.midX - size.width / 2).rounded(), 0), imageBounds.width - size.width)
      let y = min(max((selection.midY - size.height / 2).rounded(), 0), imageBounds.height - size.height)
      self.cropExtent = CGRect(origin: CGPoint(x: x, y: y), size: size)
    } else {
      // No larger than the fitted selection about the same center, so its
      // straightened footprint stays inside the source.
      self.cropExtent = CGRect(
        x: selection.midX - size.width / 2,
        y: selection.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
    }
  }

  /// `aspectRatio` in lowest whole-number terms, when both terms are at most
  /// `maximumExactAspectRatioTerm`; nil otherwise.
  ///
  /// Scanning the denominators from 1 finds the lowest terms first, and
  /// accepts ratios given in any scale (`16:9`, `1.5:1`, or an image size
  /// such as `4032×3024`).
  static func exactTerms(of aspectRatio: AspectRatio) -> (width: Int, height: Int)? {
    let ratio = aspectRatio.width / aspectRatio.height
    guard ratio.isFinite, ratio > 0 else {
      return nil
    }
    let maximum = maximumExactAspectRatioTerm
    for height in 1...maximum {
      let width = (ratio * CGFloat(height)).rounded()
      guard width >= 1, width <= CGFloat(maximum) else {
        continue
      }
      if abs(width / CGFloat(height) - ratio) <= ratio * 1e-9 {
        return (Int(width), height)
      }
    }
    return nil
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
    self.init(
      aligned: PixelAlignedCrop(
        topLeftRect: topLeftRect,
        imageSize: imageSize,
        quarterTurn: quarterTurn,
        straightenRadians: straightenRadians
      ),
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians
    )
  }

  /// Creates a crop feature from a y-down selection drawn under an
  /// aspect-ratio lock, aligned to whole pixels with exactly that ratio when
  /// the ratio allows it.
  ///
  /// As `init(topLeftRect:imageSize:quarterTurn:straightenRadians:)`, but
  /// for a ratio whose lowest terms are both at most 32 (1:1, 4:5, 16:9, …)
  /// the size is the largest whole multiple of those terms that fits in the
  /// selection, centered on it, instead of each edge snapped inward on its
  /// own, which can miss the ratio by a pixel (a square as 479×478). Other
  /// ratios snap edge by edge, within a pixel or two of the ratio.
  ///
  /// Package access: the editing canvas aligns a guide it records under a
  /// lock with it. A host aligns a crop with
  /// `init(topLeftRect:imageSize:quarterTurn:straightenRadians:)` or
  /// `pixelAligned(imageSize:)`.
  ///
  /// - Parameters:
  ///   - imageSize: The oriented pixel size of the crop's input.
  ///   - aspectRatio: The locked ratio of the output, after `quarterTurn`;
  ///     a sideways turn exchanges it for the selection.
  package init(
    topLeftRect: CGRect,
    imageSize: CGSize,
    quarterTurn: QuarterTurn = .zero,
    straightenRadians: Double = 0,
    aspectRatio: AspectRatio
  ) {
    self.init(
      aligned: PixelAlignedCrop(
        topLeftRect: topLeftRect,
        imageSize: imageSize,
        quarterTurn: quarterTurn,
        straightenRadians: straightenRadians,
        aspectRatio: quarterTurn.isSideways ? aspectRatio.swapped() : aspectRatio
      ),
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians
    )
  }

  /// Flips an aligned y-down selection into the feature's y-up coordinates.
  private init(
    aligned: PixelAlignedCrop,
    quarterTurn: QuarterTurn,
    straightenRadians: Double
  ) {
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

  /// This crop snapped to the pixel grid of an input of `imageSize`, as
  /// `init(topLeftRect:imageSize:quarterTurn:straightenRadians:)` snaps it.
  ///
  /// Without straightening, the edges snap inward to whole pixels and the
  /// selection is clipped to the input. With straightening, the selection
  /// is fitted so its straightened footprint lies inside the input
  /// (shrinking uniformly and moving only if needed), and its dimensions
  /// snap inward about the fitted center; the origin can stay fractional.
  /// `quarterTurn` and `straightenRadians` are kept. A crop that is already
  /// aligned is returned unchanged.
  ///
  /// Evaluation renders `rect` as given, so a crop set from arbitrary
  /// coordinates can have fractional edges or transparent parts outside the
  /// input. Align it with this method before storing it.
  ///
  /// - Parameter imageSize: The oriented pixel size of the crop's input.
  public func pixelAligned(imageSize: CGSize) -> CropFeature {
    let aligned = CropFeature(
      topLeftRect: topLeftRect(imageSize: imageSize),
      imageSize: imageSize,
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians
    )

    // A straightened crop keeps a fractional origin, and the round trip
    // through y-down coordinates can move it by an ulp. A crop whose size
    // already matches and whose origin is within the snapping tolerance is
    // already aligned, so it is returned as is and compares equal.
    let epsilon = PixelAlignedCrop.pixelEpsilon
    if straightenRadians.isFinite, straightenRadians != 0,
       aligned.rect.size == rect.size,
       abs(aligned.rect.origin.x - rect.origin.x) <= epsilon,
       abs(aligned.rect.origin.y - rect.origin.y) <= epsilon
    {
      return self
    }
    return aligned
  }

  /// The largest selection of `aspectRatio`, centered in an input of
  /// `imageSize` and pixel-aligned.
  ///
  /// The result is re-centered: the current `rect` is not used, so this is
  /// not a fit inside the current selection. `aspectRatio` describes the
  /// output, after `quarterTurn`; a sideways turn exchanges it for the
  /// selection. `quarterTurn` and `straightenRadians` are kept, and with
  /// straightening the selection shrinks until its straightened footprint
  /// lies inside the input.
  ///
  /// - Parameter imageSize: The oriented pixel size of the crop's input.
  public func fitted(to aspectRatio: AspectRatio, imageSize: CGSize) -> CropFeature {
    let selectionAspectRatio = quarterTurn.isSideways ? aspectRatio.swapped() : aspectRatio
    // Centered, so the rectangle is the same in y-down and y-up coordinates.
    let selection = CropGeometry.cropRect(
      toFitAspectRatio: selectionAspectRatio,
      in: imageSize,
      straightenRadians: straightenRadians
    )
    return CropFeature(
      topLeftRect: selection,
      imageSize: imageSize,
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians
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
