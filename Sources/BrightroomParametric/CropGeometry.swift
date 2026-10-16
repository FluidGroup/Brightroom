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

/// Crop fitting and coordinate conversions shared by pixel alignment and the
/// crop UI.
///
/// Package access: hosts fit crops with `CropFeature.fitted(to:imageSize:)`
/// and `CropFeature.pixelAligned(imageSize:)`.
///
/// The math is coordinate-convention-agnostic for clamping and aspect fitting:
/// pass the crop rect and image size in the SAME space (pixel alignment and
/// the UI use y-down top-left coordinates; `CropFeature` stores y-up — both work as long as the
/// rect and bounds share a convention). `cropRect(toFitBoundingBox:)` is the one
/// exception and documents its y-flip explicitly.
package enum CropGeometry {

  /// Clamps `rect` into `[0, imageSize]` and, when an aspect ratio is supplied,
  /// fits the largest centered-in-place rectangle of that ratio inside the
  /// clamped bounds.
  ///
  /// Use the overload with `straightenRadians` for a straightened selection.
  package static func fittingRect(
    rect: CGRect,
    in imageSize: CGSize,
    respectingAspectRatio: AspectRatio?
  ) -> CGRect {

    func clamp<T: Comparable>(value: T, lower: T, upper: T) -> T {
      return min(max(value, lower), upper)
    }

    /*
     Cuts the area off that out of maximum bounds

            image-size
      ┌────────────┐
      │            │
      │            │  crop extent
      │    ┌───────┼───┐
      │    │xxxxxxx│   │
      │    │xxxxxxx│   │
      │    │xxxxxxx│   │
      │    │xxxxxxx│   │
      └────┼───────┘   │
           │           │
           └───────────┘
     */

    var fixed = CGRect(origin: .zero, size: imageSize).intersection(rect)

    respectAspectRatio: do {

      /*
       Fits the fixed rect to aspect ratio if present.
       */

      if let aspectRatio = respectingAspectRatio {

        /*
         Find maximum bounds to create a new rect inside.
         */

        let maxSizeFromPoint = CGSize(
          width: imageSize.width - fixed.minX,
          height: imageSize.height - fixed.minY
        )

        let maxRect = CGRect(
          origin: fixed.origin,
          size: .init(
            width: clamp(value: fixed.width, lower: 0, upper: maxSizeFromPoint.width),
            height: clamp(value: fixed.height, lower: 0, upper: maxSizeFromPoint.height)
          )
        )

        fixed = aspectRatio.rectThatFits(in: maxRect)
      }
    }

    validation: do {
      assert(fixed.maxX <= imageSize.width)
      assert(fixed.maxY <= imageSize.height)
      assert(fixed.origin.x >= 0)
      assert(fixed.origin.y >= 0)
      assert(fixed.width <= imageSize.width)
      assert(fixed.height <= imageSize.height)
    }

    return fixed
  }

  /// Exchanges a crop's display dimensions for a quarter-turned viewport.
  ///
  /// A sideways turn swaps width and height about the same center. `.zero` and
  /// `.counterclockwise180` leave the rectangle unchanged. The size exchange is its own inverse.
  /// This is a presentation conversion; stored selections and fitting use the
  /// rectangle before its output turn.
  package static func rect(_ rect: CGRect, turnedBy rotation: QuarterTurn) -> CGRect {
    guard rotation.isSideways else {
      return rect
    }

    return CGRect(
      x: rect.midX - rect.height / 2,
      y: rect.midY - rect.width / 2,
      width: rect.height,
      height: rect.width
    )
  }

  /// Fits a selection after straightening and before any output quarter turn.
  ///
  /// `rect` and `aspectRatio` use that same selection orientation. Straightening
  /// determines the sampled source area; output rotation has no role in fitting.
  package static func fittingRect(
    rect: CGRect,
    in imageSize: CGSize,
    straightenRadians: Double,
    respectingAspectRatio aspectRatio: AspectRatio?
  ) -> CGRect {
    if straightenRadians.isFinite, straightenRadians != 0 {
      return fittingStraightenedRect(
        rect: aspectRatio?.rectThatFits(in: rect) ?? rect,
        in: imageSize,
        straightenRadians: straightenRadians
      )
    }

    let imageBounds = CGRect(origin: .zero, size: imageSize)
    guard imageBounds.intersects(rect), rect.isEmpty == false else {
      return .null
    }

    return fittingRect(
      rect: rect,
      in: imageSize,
      respectingAspectRatio: aspectRatio
    )
  }

  /// Fits the crop before output rotation using only the free straighten angle.
  ///
  /// Valid rectangles are retained, including ones that extend outside the
  /// unrotated bounds while sampling entirely inside the source. Invalid
  /// rectangles shrink uniformly if needed, then move just far enough to fit.
  /// No output-quarter-turn policy participates in this calculation.
  static func fittingStraightenedRect(
    rect: CGRect,
    in imageSize: CGSize,
    straightenRadians: Double
  ) -> CGRect {
    guard
      rect.minX.isFinite, rect.minY.isFinite,
      rect.width.isFinite, rect.height.isFinite,
      rect.width > 0, rect.height > 0
    else {
      return CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    let sampledSize = sampledSize(of: rect.size, straightenRadians: straightenRadians)
    let epsilon = PixelAlignedCrop.pixelEpsilon
    if rect.midX - sampledSize.width / 2 >= -epsilon,
      rect.midX + sampledSize.width / 2 <= imageSize.width + epsilon,
      rect.midY - sampledSize.height / 2 >= -epsilon,
      rect.midY + sampledSize.height / 2 <= imageSize.height + epsilon
    {
      return rect
    }

    return translatedIntoBounds(
      rect: rect,
      in: imageSize,
      straightenRadians: straightenRadians
    )
  }

  /// Moves `rect` the shortest distance that puts the area it samples inside
  /// the image, keeping its size.
  ///
  /// The sampled area is the bounding box of `rect` straightened about its
  /// center by `straightenRadians`; with no straighten it is `rect` itself,
  /// and an edge past the image's edge lands on it. Only a rectangle that
  /// cannot fit at its size shrinks, uniformly about its center, before it
  /// moves. Unlike `fittingRect`, this never clips one edge or refits an
  /// aspect ratio, so the result keeps the proportions of `rect`.
  package static func translatedIntoBounds(
    rect: CGRect,
    in imageSize: CGSize,
    straightenRadians: Double = 0
  ) -> CGRect {
    guard
      rect.minX.isFinite, rect.minY.isFinite,
      rect.width.isFinite, rect.height.isFinite,
      rect.width > 0, rect.height > 0
    else {
      return rect
    }

    let sampledSize = sampledSize(
      of: rect.size,
      straightenRadians: straightenRadians.isFinite ? straightenRadians : 0
    )
    let scale = min(1, imageSize.width / sampledSize.width, imageSize.height / sampledSize.height)
    let size = CGSize(width: rect.width * scale, height: rect.height * scale)
    let halfWidth = sampledSize.width * scale / 2
    let halfHeight = sampledSize.height * scale / 2
    let center = CGPoint(
      x: min(max(rect.midX, halfWidth), imageSize.width - halfWidth),
      y: min(max(rect.midY, halfHeight), imageSize.height - halfHeight)
    )

    return CGRect(
      x: center.x - size.width / 2,
      y: center.y - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  /// `rect` grown about its center until the crop aligned from it has sides
  /// of at least `minimumSide` pixels, kept inside the image.
  ///
  /// ImageEditor's minimum crop size uses it; any crop size stays a valid
  /// `CropFeature`.
  ///
  /// - Without `aspectRatio`, each side grows on its own. Without
  ///   straightening, a side whose whole-pixel span (snapped inward, as
  ///   pixel alignment snaps it) is under `minimumSide` becomes
  ///   `minimumSide` rounded up to a whole pixel; with straightening, a side
  ///   under `minimumSide` does. The other side is left as it is.
  /// - With `aspectRatio` (the selection's, before the output quarter turn),
  ///   a rectangle whose aligned shorter side is under `minimumSide` grows
  ///   to that ratio. When the ratio's lowest terms are both at most 32, the
  ///   aligned size is the largest whole multiple of the terms inside the
  ///   rectangle's whole-pixel size, as ratio-exact alignment writes it (a
  ///   16:9 rectangle of 227.6 × 128 aligns to 224 × 126), and the
  ///   rectangle grows to the smallest multiple that reaches `minimumSide`
  ///   (`smallestShorterSide(reaching:aspectRatio:)`). Otherwise the aligned
  ///   sides are snapped as for no ratio, and the rectangle grows to a
  ///   shorter side of `minimumSide` and the longer side to the nearest
  ///   whole pixel. Without
  ///   straightening, the multiple is at most the largest the image holds;
  ///   a rectangle that already has that multiple (one as large as the
  ///   image holds) is returned as is, never shrunk.
  ///
  /// Without straightening, a grown side gets the whole-pixel origin nearest
  /// its centered one, inside the image, so pixel alignment keeps it as it
  /// is. A size the image cannot hold, or a straightened one, is moved (and
  /// shrunk if needed) as `translatedIntoBounds(rect:in:straightenRadians:)`
  /// moves it. A rectangle that needs no growth, or an invalid one, is
  /// returned as is.
  ///
  /// - Parameter imageSize: The image in the same coordinates as `rect`;
  ///   the result is the same in y-down and y-up coordinates, except for
  ///   which way a centered origin halfway between two pixels rounds.
  package static func rectEnlarged(
    toMinimumSide minimumSide: CGFloat,
    rect: CGRect,
    in imageSize: CGSize,
    straightenRadians: Double = 0,
    aspectRatio: AspectRatio? = nil
  ) -> CGRect {
    guard
      minimumSide.isFinite, minimumSide > 0,
      rect.minX.isFinite, rect.minY.isFinite,
      rect.width.isFinite, rect.height.isFinite,
      rect.width > 0, rect.height > 0,
      imageSize.width.isFinite, imageSize.height.isFinite,
      imageSize.width > 0, imageSize.height > 0
    else {
      return rect
    }

    let straighten = straightenRadians.isFinite ? straightenRadians : 0
    let epsilon = PixelAlignedCrop.pixelEpsilon
    let wholeMinimum = ceil(minimumSide - epsilon)

    let grows: (width: Bool, height: Bool)
    var size = rect.size

    if let aspectRatio {
      let ratio = aspectRatio.width / aspectRatio.height
      guard ratio.isFinite, ratio > 0 else {
        return rect
      }
      grows = (true, true)

      if let terms = PixelAlignedCrop.exactTerms(of: aspectRatio) {
        let termWidth = CGFloat(terms.width)
        let termHeight = CGFloat(terms.height)
        // The multiple ratio-exact alignment gives the rectangle: the
        // largest inside its whole-pixel size. Its shorter side, not the
        // rectangle's, is what has to reach the minimum: a 16:9 guide of
        // 227.6 × 128 aligns to 224 × 126.
        let fittingMultiple = min(
          floor(floor(rect.width + epsilon) / termWidth),
          floor(floor(rect.height + epsilon) / termHeight)
        )
        var multiple = smallestShorterSide(reaching: wholeMinimum, aspectRatio: aspectRatio)
          / min(termWidth, termHeight)
        guard fittingMultiple < multiple else {
          return rect
        }
        if straighten == 0 {
          let largest = floor(min(imageSize.width / termWidth, imageSize.height / termHeight) + epsilon)
          if largest >= 1 {
            multiple = min(multiple, largest)
          }
        }
        // A cap no larger than the rectangle's multiple (a rectangle as
        // large as the image holds) would shrink it rather than grow it.
        guard multiple > fittingMultiple else {
          return rect
        }
        size = CGSize(width: multiple * termWidth, height: multiple * termHeight)
      } else {
        // Pixel alignment snaps each edge inward without straightening and
        // the size down with it, so those are the sides that must reach the
        // minimum.
        let alignedShorterSide = straighten == 0
          ? min(
            wholePixelSpan(lower: rect.minX, upper: rect.maxX, bound: imageSize.width),
            wholePixelSpan(lower: rect.minY, upper: rect.maxY, bound: imageSize.height)
          )
          : min(floor(rect.width + epsilon), floor(rect.height + epsilon))
        guard alignedShorterSide < wholeMinimum else {
          return rect
        }
        size = ratio >= 1
          ? CGSize(width: max(wholeMinimum, (wholeMinimum * ratio).rounded()), height: wholeMinimum)
          : CGSize(width: wholeMinimum, height: max(wholeMinimum, (wholeMinimum / ratio).rounded()))
      }
    } else {
      if straighten == 0 {
        grows = (
          wholePixelSpan(lower: rect.minX, upper: rect.maxX, bound: imageSize.width) < wholeMinimum,
          wholePixelSpan(lower: rect.minY, upper: rect.maxY, bound: imageSize.height) < wholeMinimum
        )
      } else {
        grows = (rect.width < minimumSide - epsilon, rect.height < minimumSide - epsilon)
      }
      guard grows.width || grows.height else {
        return rect
      }
      if grows.width {
        size.width = wholeMinimum
      }
      if grows.height {
        size.height = wholeMinimum
      }
    }

    let centered = CGRect(
      x: rect.midX - size.width / 2,
      y: rect.midY - size.height / 2,
      width: size.width,
      height: size.height
    )

    guard
      straighten == 0,
      size.width <= imageSize.width + epsilon,
      size.height <= imageSize.height + epsilon
    else {
      return translatedIntoBounds(rect: centered, in: imageSize, straightenRadians: straighten)
    }

    func wholePixelOrigin(_ centeredOrigin: CGFloat, length: CGFloat, bound: CGFloat) -> CGFloat {
      min(max(centeredOrigin.rounded(), 0), max(bound - length, 0))
    }

    var result = rect
    if grows.width {
      result.origin.x = wholePixelOrigin(centered.minX, length: size.width, bound: imageSize.width)
      result.size.width = size.width
    }
    if grows.height {
      result.origin.y = wholePixelOrigin(centered.minY, length: size.height, bound: imageSize.height)
      result.size.height = size.height
    }
    return result
  }

  /// The shorter side of the smallest crop of `aspectRatio` whose shorter
  /// side reaches `minimumSide` once aligned to whole pixels.
  ///
  /// With a ratio whose lowest terms are both at most 32, ratio-exact
  /// alignment keeps only whole multiples of the terms, so this is the
  /// smallest multiple of the shorter term that reaches `minimumSide`
  /// (135 for 16:9 and 128, 129 for 4:3); otherwise, and without a ratio,
  /// `minimumSide` rounded up to a whole pixel.
  package static func smallestShorterSide(reaching minimumSide: CGFloat, aspectRatio: AspectRatio?) -> CGFloat {
    let wholeMinimum = ceil(minimumSide - PixelAlignedCrop.pixelEpsilon)
    guard let aspectRatio, let terms = PixelAlignedCrop.exactTerms(of: aspectRatio) else {
      return wholeMinimum
    }
    let shorterTerm = CGFloat(min(terms.width, terms.height))
    return ceil(wholeMinimum / shorterTerm) * shorterTerm
  }

  /// The smallest crop of `aspectRatio`, in its orientation, whose shorter
  /// side reaches `minimumSide` once aligned to whole pixels: its shorter
  /// side is `smallestShorterSide(reaching:aspectRatio:)`. With a ratio
  /// whose lowest terms are both at most 32 it is a whole multiple of the
  /// terms (240 × 135 for 16:9 and 128, 172 × 129 for 4:3); with larger
  /// terms the longer side follows the ratio, continuous; without a ratio
  /// it is a square.
  package static func smallestSize(reaching minimumSide: CGFloat, aspectRatio: AspectRatio?) -> CGSize {
    let shorterSide = smallestShorterSide(reaching: minimumSide, aspectRatio: aspectRatio)
    guard let aspectRatio else {
      return CGSize(width: shorterSide, height: shorterSide)
    }
    if let terms = PixelAlignedCrop.exactTerms(of: aspectRatio) {
      let multiple = shorterSide / CGFloat(min(terms.width, terms.height))
      return CGSize(width: multiple * CGFloat(terms.width), height: multiple * CGFloat(terms.height))
    }
    let ratio = aspectRatio.width / aspectRatio.height
    guard ratio.isFinite, ratio > 0 else {
      return CGSize(width: shorterSide, height: shorterSide)
    }
    return ratio >= 1
      ? CGSize(width: shorterSide * ratio, height: shorterSide)
      : CGSize(width: shorterSide, height: shorterSide / ratio)
  }

  /// The whole pixels between `lower` and `upper` once both snap inward
  /// inside `[0, bound]`, as pixel alignment snaps a crop without
  /// straightening.
  private static func wholePixelSpan(lower: CGFloat, upper: CGFloat, bound: CGFloat) -> CGFloat {
    let epsilon = PixelAlignedCrop.pixelEpsilon
    let snappedLower = min(max(ceil(lower - epsilon), 0), bound)
    let snappedUpper = min(max(floor(upper + epsilon), 0), bound)
    return max(snappedUpper - snappedLower, 0)
  }

  /// The size of the bounding box of a `size` rectangle straightened about
  /// its center.
  private static func sampledSize(of size: CGSize, straightenRadians: Double) -> CGSize {
    let cosine = abs(CGFloat(cos(straightenRadians)))
    let sine = abs(CGFloat(sin(straightenRadians)))
    return CGSize(
      width: cosine * size.width + sine * size.height,
      height: sine * size.width + cosine * size.height
    )
  }

  /// A centered selection of `aspectRatio` that fits inside the image
  /// after straightening and before any output quarter turn.
  package static func cropRect(
    toFitAspectRatio aspectRatio: AspectRatio,
    in imageSize: CGSize,
    straightenRadians: Double = 0
  ) -> CGRect {

    let maxSize = aspectRatio.sizeThatFits(in: imageSize)

    let proposed = CGRect(
      origin: .init(
        x: (imageSize.width - maxSize.width) / 2,
        y: (imageSize.height - maxSize.height) / 2
      ),
      size: maxSize
    )

    return fittingRect(
      rect: proposed,
      in: imageSize,
      straightenRadians: straightenRadians,
      respectingAspectRatio: aspectRatio
    )
  }

  /// Maps a normalized (`0…1`) bounding box — e.g. a Vision detection — into a
  /// crop rect.
  ///
  /// The box is scaled by the current crop extent's size and flipped from the
  /// detection's y-up normalized space into y-down top-left coordinates,
  /// then fitted against the straightened source. Both the crop and aspect ratio
  /// are expressed before output rotation. `cropExtent` supplies only the scale
  /// of the box; the result is anchored against the image origin.
  package static func cropRect(
    toFitBoundingBox boundingBox: CGRect,
    within cropExtent: CGRect,
    in imageSize: CGSize,
    straightenRadians: Double = 0,
    respectingAspectRatio: AspectRatio?
  ) -> CGRect {

    let transform = CGAffineTransform(scaleX: 1, y: -1)
      .translatedBy(x: 0, y: -cropExtent.height)

    let scale = CGAffineTransform.identity
      .scaledBy(x: cropExtent.width, y: cropExtent.height)

    let proposed =
      boundingBox
      .applying(scale)
      .applying(transform)

    return fittingRect(
      rect: proposed,
      in: imageSize,
      straightenRadians: straightenRadians,
      respectingAspectRatio: respectingAspectRatio
    )
  }
}
