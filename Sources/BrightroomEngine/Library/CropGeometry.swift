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

/// Pure crop-rect geometry, decoupled from `EditingCrop` so it can be shared by
/// the engine and by the BrightroomUI crop session (`CropEditingState`).
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
  /// This is the canonical normalizer every crop mutation funnels through, so a
  /// stored crop extent is always inside the image and respects the active ratio.
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

  /// The largest centered crop rect of `aspectRatio` that fits inside the image.
  public static func cropRect(
    toFitAspectRatio aspectRatio: PixelAspectRatio,
    in imageSize: CGSize
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
      respectingAspectRatio: aspectRatio
    )
  }

  /// Maps a normalized (`0…1`) bounding box — e.g. a Vision detection — into a
  /// crop rect.
  ///
  /// The box is scaled by the current crop extent's size and flipped from the
  /// detection's y-up normalized space into the engine's y-down display space,
  /// then clamped and aspect-fitted via `fittingRect`. `cropExtent` supplies only
  /// the scale of the box; the result is anchored against the image origin (the
  /// pre-existing engine behavior).
  public static func cropRect(
    toFitBoundingBox boundingBox: CGRect,
    within cropExtent: CGRect,
    in imageSize: CGSize,
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
      respectingAspectRatio: respectingAspectRatio
    )
  }
}
