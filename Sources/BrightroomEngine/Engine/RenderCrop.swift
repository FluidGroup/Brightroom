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
  internal var cropRect: PixelCropRect

  /// The quarter-turn rotation, expressed in the parametric vocabulary so the
  /// render crop no longer depends on `EditingCrop`.
  internal var rotation: QuarterTurn

  /// The free straightening angle in radians (the engine's adjustment angle).
  internal var straightenRadians: Double

  internal var cropExtent: CGRect {
    cropRect.cgRect
  }

  /// The combined rotation (quarter turn + straighten) in radians, the value the
  /// CoreGraphics crop rotates by.
  internal var aggregatedRotationRadians: Double {
    rotation.radians + (straightenRadians.isFinite ? straightenRadians : 0)
  }

  /// Snaps a y-down display crop rect against the source pixel grid.
  ///
  /// `cropRectYDown` is in the engine's top-left-origin display space (the same
  /// space as `EditingCrop.cropExtent`). The integer pixel contract lives in
  /// `PixelCropRect`, so this initializer is the single snapper UI commits and
  /// engine renders both flow through.
  internal init(
    cropRectYDown: CGRect,
    imageSize: CGSize,
    rotation: QuarterTurn = .zero,
    straightenRadians: Double = 0,
    epsilon: CGFloat = Self.pixelEpsilon
  ) {
    let pixelImageSize = PixelDimensions(imageSize, epsilon: epsilon)

    self.imageSize = pixelImageSize
    self.cropRect = PixelCropRect(
      cropExtent: cropRectYDown,
      in: pixelImageSize,
      epsilon: epsilon
    )
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
    let snapped = renderCrop.cropRect
    let imageHeight = CGFloat(renderCrop.imageSize.height)

    self.init(
      id: id,
      isEnabled: isEnabled,
      cropRect: CGRect(
        x: CGFloat(snapped.x),
        y: imageHeight - CGFloat(snapped.y) - CGFloat(snapped.height),
        width: CGFloat(snapped.width),
        height: CGFloat(snapped.height)
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

