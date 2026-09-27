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

import BrightroomParametric

/// Crop fitting and coordinate conversions shared by the engine and UI.
///
/// The math is coordinate-convention-agnostic for clamping and aspect fitting:
/// pass the crop rect and image size in the SAME space (the engine and UI use
/// y-down display space; `CropFeature` stores y-up — both work as long as the
/// rect and bounds share a convention). `cropRect(toFitBoundingBox:)` is the one
/// exception and documents its y-flip explicitly.
public enum CropGeometry {

  /// Clamps `rect` into `[0, imageSize]` and, when an aspect ratio is supplied,
  /// fits the largest centered-in-place rectangle of that ratio inside the
  /// clamped bounds.
  ///
  /// Use the overload with `straightenRadians` for a straightened selection.
  public static func fittingRect(
    rect: CGRect,
    in imageSize: CGSize,
    respectingAspectRatio: PixelAspectRatio?
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
  /// `.half` leave the rectangle unchanged. The size exchange is its own inverse.
  /// This is a presentation conversion; stored selections and fitting use the
  /// rectangle before its output turn.
  public static func rect(_ rect: CGRect, turnedBy rotation: QuarterTurn) -> CGRect {
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
  public static func fittingRect(
    rect: CGRect,
    in imageSize: CGSize,
    straightenRadians: Double,
    respectingAspectRatio aspectRatio: PixelAspectRatio?
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

    let cosine = abs(CGFloat(cos(straightenRadians)))
    let sine = abs(CGFloat(sin(straightenRadians)))
    let sourceWidth = cosine * rect.width + sine * rect.height
    let sourceHeight = sine * rect.width + cosine * rect.height
    let epsilon = RenderGeometry.pixelEpsilon
    if rect.midX - sourceWidth / 2 >= -epsilon,
      rect.midX + sourceWidth / 2 <= imageSize.width + epsilon,
      rect.midY - sourceHeight / 2 >= -epsilon,
      rect.midY + sourceHeight / 2 <= imageSize.height + epsilon
    {
      return rect
    }

    let scale = min(1, imageSize.width / sourceWidth, imageSize.height / sourceHeight)
    let size = CGSize(width: rect.width * scale, height: rect.height * scale)
    let halfWidth = sourceWidth * scale / 2
    let halfHeight = sourceHeight * scale / 2
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

  /// A centered selection of `aspectRatio` that fits inside the image
  /// after straightening and before any output quarter turn.
  public static func cropRect(
    toFitAspectRatio aspectRatio: PixelAspectRatio,
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
  /// detection's y-up normalized space into the engine's y-down display space,
  /// then fitted against the straightened source. Both the crop and aspect ratio
  /// are expressed before output rotation. `cropExtent` supplies only the scale
  /// of the box; the result is anchored against the image origin.
  public static func cropRect(
    toFitBoundingBox boundingBox: CGRect,
    within cropExtent: CGRect,
    in imageSize: CGSize,
    straightenRadians: Double = 0,
    respectingAspectRatio: PixelAspectRatio?
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
