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
import SwiftUI

import BrightroomParametric

internal enum RenderGeometry {
  internal static let pixelEpsilon: CGFloat = 1e-8
}

internal struct PixelDimensions: Equatable, Sendable {

  internal var width: Int
  internal var height: Int

  internal var cgSize: CGSize {
    .init(width: CGFloat(width), height: CGFloat(height))
  }

  internal init(width: Int, height: Int) {
    precondition(width > 0)
    precondition(height > 0)

    self.width = width
    self.height = height
  }

  internal init(
    _ size: CGSize,
    epsilon: CGFloat = RenderGeometry.pixelEpsilon
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

internal struct PixelCropRect: Equatable, Sendable {

  internal var x: Int
  internal var y: Int
  internal var width: Int
  internal var height: Int

  internal var size: PixelDimensions {
    .init(width: width, height: height)
  }

  internal var cgRect: CGRect {
    .init(
      x: CGFloat(x),
      y: CGFloat(y),
      width: CGFloat(width),
      height: CGFloat(height)
    )
  }

  internal init(
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

  internal init(
    cropExtent: CGRect,
    in imageSize: PixelDimensions,
    epsilon: CGFloat = RenderGeometry.pixelEpsilon
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

  /// The rect adjusted by one pixel so that its width and height differ by an
  /// even number of pixels, staying as close as it can to `requested`, the
  /// unsnapped rect it was snapped inward from.
  ///
  /// A quarter turn about the rect's center maps the pixel grid onto itself
  /// only when the width and height differ by an even number of pixels.
  /// Otherwise the turned rect lies on half pixels, and every output pixel
  /// would be resampled between two source pixels (Core Image also rounds such
  /// an extent outward, adding a partially covered border).
  ///
  /// Every pixel of the inward-snapped rect is fully inside `requested`, so
  /// dropping a line of them misses `requested` by a whole pixel. When
  /// `requested` partly covers the pixel line just outside an edge, taking
  /// that line misses it by less, so the rect grows by the most-covered one.
  /// This also snaps sub-pixel error back to the same pixels: CropView
  /// re-reads an unchanged frame from its views on Done, a fraction of a pixel
  /// off. Only when no such line exists does the longer side lose one pixel at
  /// its max edge.
  internal func evenedForQuarterTurn(
    requested: CGRect,
    in imageSize: PixelDimensions,
    epsilon: CGFloat = RenderGeometry.pixelEpsilon
  ) -> PixelCropRect {
    guard (width - height) % 2 != 0 else {
      return self
    }

    // How much of the pixel line just outside each edge `requested` covers,
    // with `requested` clamped to the image as the inward snap did.
    let requested = requested.standardized
    if
      requested.minX.isFinite, requested.minY.isFinite,
      requested.maxX.isFinite, requested.maxY.isFinite
    {
      let minX = Self.clamp(requested.minX, lower: 0, upper: CGFloat(imageSize.width))
      let maxX = Self.clamp(requested.maxX, lower: 0, upper: CGFloat(imageSize.width))
      let minY = Self.clamp(requested.minY, lower: 0, upper: CGFloat(imageSize.height))
      let maxY = Self.clamp(requested.maxY, lower: 0, upper: CGFloat(imageSize.height))

      let left = CGFloat(x) - minX
      let right = maxX - CGFloat(x + width)
      let top = CGFloat(y) - minY
      let bottom = maxY - CGFloat(y + height)
      let mostCovered = max(left, right, top, bottom)

      if mostCovered > epsilon, mostCovered < 1 {
        switch mostCovered {
        case left:
          return .init(x: x - 1, y: y, width: width + 1, height: height)
        case right:
          return .init(x: x, y: y, width: width + 1, height: height)
        case top:
          return .init(x: x, y: y - 1, width: width, height: height + 1)
        default:
          return .init(x: x, y: y, width: width, height: height + 1)
        }
      }
    }

    if width > height {
      return .init(x: x, y: y, width: width - 1, height: height)
    } else {
      return .init(x: x, y: y, width: width, height: height - 1)
    }
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

internal struct RenderCrop: Equatable, Sendable {

  internal static let pixelEpsilon = RenderGeometry.pixelEpsilon

  internal var imageSize: PixelDimensions

  /// The source pixels the crop keeps, snapped inward to the pixel grid and
  /// clamped to the image.
  ///
  /// This is the crop rect's footprint on the source image: the y-down crop rect
  /// turned back by `rotation` about its center. For `.zero` and `.half` it is
  /// the crop rect itself; a sideways turn swaps its width and height.
  internal var cropRect: PixelCropRect

  /// The quarter-turn rotation, expressed in the parametric vocabulary so the
  /// render crop no longer depends on `EditingCrop`.
  internal var rotation: QuarterTurn

  /// The free straightening angle in radians (the engine's adjustment angle).
  internal var straightenRadians: Double

  /// The y-down crop rect in the output orientation: `cropRect` turned by
  /// `rotation` about its center. Integral, because a sideways footprint's
  /// width and height differ by an even number of pixels.
  internal var cropExtent: CGRect {
    CropGeometry.rect(cropRect.cgRect, turnedBy: rotation)
  }

  /// The combined rotation (quarter turn + straighten) in radians, the value the
  /// CoreGraphics crop rotates by.
  internal var aggregatedRotationRadians: Double {
    rotation.radians + (straightenRadians.isFinite ? straightenRadians : 0)
  }

  /// Snaps a y-down display crop rect against the source pixel grid.
  ///
  /// `cropRectYDown` is in the engine's top-left-origin display space (the same
  /// space as `EditingCrop.cropExtent`), in the output orientation of
  /// `rotation`. The integer pixel contract lives in `PixelCropRect`, so this
  /// initializer is the single snapper UI commits and engine renders both flow
  /// through.
  ///
  /// The snap and clamp apply to the rect's footprint on the source image, not
  /// to the rect itself: a full-image crop turned a quarter is
  /// `(W/2 - H/2, H/2 - W/2, H, W)`, which extends past the unrotated image
  /// bounds while keeping every source pixel. Under a sideways turn the
  /// footprint also keeps an even width-height difference (see
  /// `PixelCropRect.evenedForQuarterTurn(requested:in:epsilon:)`), so an odd
  /// one gains a partly covered pixel line or loses one pixel.
  internal init(
    cropRectYDown: CGRect,
    imageSize: CGSize,
    rotation: QuarterTurn = .zero,
    straightenRadians: Double = 0,
    epsilon: CGFloat = Self.pixelEpsilon
  ) {
    let pixelImageSize = PixelDimensions(imageSize, epsilon: epsilon)

    self.imageSize = pixelImageSize
    let requestedFootprint = CropGeometry.rect(cropRectYDown, turnedBy: rotation)
    let footprint = PixelCropRect(
      cropExtent: requestedFootprint,
      in: pixelImageSize,
      epsilon: epsilon
    )
    self.cropRect = rotation.isSideways
      ? footprint.evenedForQuarterTurn(
        requested: requestedFootprint,
        in: pixelImageSize,
        epsilon: epsilon
      )
      : footprint
    self.rotation = rotation
    self.straightenRadians = straightenRadians
  }

  internal init(
    imageSize: PixelDimensions,
    cropRect: PixelCropRect,
    rotation: QuarterTurn = .zero,
    straightenRadians: Double = 0
  ) {
    self.imageSize = imageSize
    self.cropRect = cropRect
    self.rotation = rotation
    self.straightenRadians = straightenRadians
  }
}

// MARK: - CropFeature ⇄ engine display space (shared y-flip + integer snap)

extension CropFeature {

  /// Creates a crop feature from a y-down display crop rect, reusing the engine's
  /// integer pixel snap so UI commits and engine renders agree exactly.
  ///
  /// The display rect is snapped to the inward-integer pixel contract
  /// (`RenderCrop`/`PixelCropRect`) and then flipped from the engine's y-down
  /// display space (top-left origin) into the compiler's y-up working space
  /// (Core Image bottom-left). UI crop sessions MUST build committed crops
  /// through this initializer; authoring an independent snapper makes
  /// `isRenderingEquivalent` oscillate against the engine and the crop jitters.
  public init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    displayCropRect: CGRect,
    imageSize: CGSize,
    rotation: QuarterTurn = .zero,
    straighten: Double = 0
  ) {
    let renderCrop = RenderCrop(
      cropRectYDown: displayCropRect,
      imageSize: imageSize,
      rotation: rotation,
      straightenRadians: straighten
    )
    let snapped = renderCrop.cropExtent
    let imageHeight = CGFloat(renderCrop.imageSize.height)

    self.init(
      id: id,
      isEnabled: isEnabled,
      cropRect: CGRect(
        x: snapped.minX,
        y: imageHeight - snapped.maxY,
        width: snapped.width,
        height: snapped.height
      ),
      rotation: rotation,
      straightenRadians: straighten
    )
  }

  /// The stored crop rect mapped back into the engine's y-down display space.
  ///
  /// The inverse of `init(displayCropRect:…)`. UI crop sessions seed their y-down
  /// working model from this. The stored rect is already pixel-snapped, so the
  /// round trip through `init(displayCropRect:…)` is stable.
  public func displayCropRect(imageSize: CGSize) -> CGRect {
    CGRect(
      x: cropRect.minX,
      y: imageSize.height - cropRect.maxY,
      width: cropRect.width,
      height: cropRect.height
    )
  }

  /// Builds the engine's integer-snapped render crop for this feature against an
  /// oriented source pixel size.
  func renderCrop(orientedImageSize: CGSize) -> RenderCrop {
    RenderCrop(
      cropRectYDown: displayCropRect(imageSize: orientedImageSize),
      imageSize: orientedImageSize,
      rotation: rotation,
      straightenRadians: straightenRadians
    )
  }

  /// Whether two crops snap to the same integer render rect (plus the same
  /// rotation and straighten) against an oriented source size.
  ///
  /// This is the engine's pixel-snap equivalence the UI uses to decide whether a
  /// crop change is renderable — sub-pixel differences that snap to the same
  /// render rect are equivalent. Public so the BrightroomUI crop session can
  /// reuse the same contract instead of re-deriving it.
  public func isRenderingEquivalent(to other: CropFeature, orientedImageSize: CGSize) -> Bool {
    renderCrop(orientedImageSize: orientedImageSize)
      == other.renderCrop(orientedImageSize: orientedImageSize)
  }
}

