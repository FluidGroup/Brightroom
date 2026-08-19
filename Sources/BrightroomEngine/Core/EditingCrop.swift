//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
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

import UIKit
import Vision
import SwiftUI

/// A representation of cropping extent in Image.
public struct EditingCrop: Equatable, Sendable {
  public enum Rotation: Equatable, CaseIterable, Sendable {
    /// 0 degree - default
    case angle_0

    /// 90 degree
    case angle_90

    /// 180 degree
    case angle_180

    /// 270 degree
    case angle_270

    public var angle: AdjustmentAngle {
      switch self {
      case .angle_0:
        return .degrees(0)
      case .angle_90:
        return .degrees(-90)
      case .angle_180:
        return .degrees(-180)
      case .angle_270:
        return .degrees(-270)
      }
    }

    public var transform: CGAffineTransform {
      .init(rotationAngle: angle.radians)
    }

    public func next() -> Self {
      switch self {
      case .angle_0: return .angle_90
      case .angle_90: return .angle_180
      case .angle_180: return .angle_270
      case .angle_270: return .angle_0
      }
    }
  }

  public typealias AdjustmentAngle = SwiftUI.Angle

  public struct Flip: OptionSet, Equatable, Sendable, Hashable {

    public let rawValue: Int

    public init(rawValue: Int) {
      self.rawValue = rawValue
    }

    public static let horizontal = Flip(rawValue: 1 << 0)
    public static let vertical = Flip(rawValue: 1 << 1)
  }

  public struct PerspectiveCorrection: Equatable, Sendable, Hashable {

    public struct Quadrilateral: Equatable, Sendable, Hashable {
      public var topLeft: CGPoint
      public var topRight: CGPoint
      public var bottomRight: CGPoint
      public var bottomLeft: CGPoint
    }

    public static let identity = PerspectiveCorrection()

    public static let maximumInsetRatio: CGFloat = 0.36

    public private(set) var horizontal: CGFloat
    public private(set) var vertical: CGFloat

    public var isIdentity: Bool {
      horizontal == 0 && vertical == 0
    }

    public init(
      horizontal: CGFloat = 0,
      vertical: CGFloat = 0
    ) {
      self.horizontal = Self.clamped(horizontal)
      self.vertical = Self.clamped(vertical)
    }

    public func settingHorizontal(_ horizontal: CGFloat) -> Self {
      .init(horizontal: horizontal, vertical: vertical)
    }

    public func settingVertical(_ vertical: CGFloat) -> Self {
      .init(horizontal: horizontal, vertical: vertical)
    }

    public func coreImageTargetQuadrilateral(in rect: CGRect) -> Quadrilateral {
      guard rect.isEmpty == false else {
        let origin = rect.origin
        return .init(
          topLeft: origin,
          topRight: origin,
          bottomRight: origin,
          bottomLeft: origin
        )
      }

      var topLeft = CGPoint(x: rect.minX, y: rect.maxY)
      var topRight = CGPoint(x: rect.maxX, y: rect.maxY)
      var bottomRight = CGPoint(x: rect.maxX, y: rect.minY)
      var bottomLeft = CGPoint(x: rect.minX, y: rect.minY)

      let verticalInset = rect.width * min(abs(vertical), 1) * Self.maximumInsetRatio
      if vertical > 0 {
        topLeft.x += verticalInset
        topRight.x -= verticalInset
      } else if vertical < 0 {
        bottomLeft.x += verticalInset
        bottomRight.x -= verticalInset
      }

      let horizontalInset = rect.height * min(abs(horizontal), 1) * Self.maximumInsetRatio
      if horizontal > 0 {
        topLeft.y -= horizontalInset
        bottomLeft.y += horizontalInset
      } else if horizontal < 0 {
        topRight.y -= horizontalInset
        bottomRight.y += horizontalInset
      }

      return .init(
        topLeft: topLeft,
        topRight: topRight,
        bottomRight: bottomRight,
        bottomLeft: bottomLeft
      )
    }

    public func displayTargetQuadrilateral(in rect: CGRect) -> Quadrilateral {
      guard rect.isEmpty == false else {
        let origin = rect.origin
        return .init(
          topLeft: origin,
          topRight: origin,
          bottomRight: origin,
          bottomLeft: origin
        )
      }

      var topLeft = CGPoint(x: rect.minX, y: rect.minY)
      var topRight = CGPoint(x: rect.maxX, y: rect.minY)
      var bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
      var bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)

      let verticalInset = rect.width * min(abs(vertical), 1) * Self.maximumInsetRatio
      if vertical > 0 {
        topLeft.x += verticalInset
        topRight.x -= verticalInset
      } else if vertical < 0 {
        bottomLeft.x += verticalInset
        bottomRight.x -= verticalInset
      }

      let horizontalInset = rect.height * min(abs(horizontal), 1) * Self.maximumInsetRatio
      if horizontal > 0 {
        topLeft.y += horizontalInset
        bottomLeft.y -= horizontalInset
      } else if horizontal < 0 {
        topRight.y += horizontalInset
        bottomRight.y -= horizontalInset
      }

      return .init(
        topLeft: topLeft,
        topRight: topRight,
        bottomRight: bottomRight,
        bottomLeft: bottomLeft
      )
    }

    public func axisAlignedCoverageRect(in rect: CGRect) -> CGRect {
      guard rect.isEmpty == false else {
        return rect
      }

      let quadrilateral = displayTargetQuadrilateral(in: rect)
      let minX = max(quadrilateral.topLeft.x, quadrilateral.bottomLeft.x)
      let maxX = min(quadrilateral.topRight.x, quadrilateral.bottomRight.x)
      let minY = max(quadrilateral.topLeft.y, quadrilateral.topRight.y)
      let maxY = min(quadrilateral.bottomLeft.y, quadrilateral.bottomRight.y)

      guard minX < maxX, minY < maxY else {
        return rect
      }

      return .init(
        x: minX,
        y: minY,
        width: maxX - minX,
        height: maxY - minY
      )
    }

    static func clamped(_ value: CGFloat) -> CGFloat {
      min(max(value, -1), 1)
    }
  }

  /// The dimensions in pixel for the image.
  /// Applied image-orientation.
  public var imageSize: CGSize

  /// The rectangle that specifies the extent of the cropping.
  public private(set) var cropExtent: CGRect

  /// The angle that specifies rotation for the image.
  public var rotation: Rotation = .angle_0

  /// Mirroring applied to the visible crop result.
  public var flip: Flip = []

  public private(set) var _usedAspectRatio: PixelAspectRatio?

  /// An angle to rotate in addition to the specified rotation.
  public var adjustmentAngle: AdjustmentAngle = .zero

  /// Perspective correction applied to the image before producing the crop.
  public var perspectiveCorrection: PerspectiveCorrection = .identity

  public var aggregatedRotation: AdjustmentAngle {
    rotation.angle + adjustmentAngle
  }

  public private(set) var scaleToRestore: CGFloat

  public init(from ciImage: CIImage) {
    self.init(
      imageSize: .init(image: ciImage),
      cropRect: .init(origin: .zero, size: ciImage.extent.size)
    )
  }

  public init(imageSize: CGSize) {
    self.init(
      imageSize: imageSize,
      cropRect: .init(origin: .zero, size: imageSize),
      rotation: .angle_0
    )
  }

  public init(
    imageSize: CGSize,
    cropRect: CGRect,
    rotation: Rotation = .angle_0,
    flip: Flip = [],
    perspectiveCorrection: PerspectiveCorrection = .identity,
    scaleToRestore: CGFloat = 1
  ) {
    self.imageSize = imageSize
    self.cropExtent = Self.fittingRect(rect: cropRect, in: imageSize, respectingAspectRatio: nil)
    self.rotation = rotation
    self.flip = flip
    self.perspectiveCorrection = perspectiveCorrection
    self.scaleToRestore = scaleToRestore
  }

  public func makeInitial() -> Self {
    .init(
      imageSize: imageSize,
      cropRect: .init(origin: .zero, size: imageSize),
      scaleToRestore: scaleToRestore
    )
  }

  public func scaledWithPixelPerfect(maxPixelSize: CGFloat) -> Self {

    let scaledImageSize = imageSize.scaled(maxPixelSize: maxPixelSize)

    let scale = scaledImageSize.width / imageSize.width

    var new = scaled(scale)
    new.imageSize = scaledImageSize
    new.scaleToRestore = imageSize.width / scaledImageSize.width

    return new
  }

  private consuming func scaled(_ scale: CGFloat) -> Self {

    var modified = self

    var cropExtent = modified.cropExtent
    var imageSize = modified.imageSize

    cropExtent.origin.x *= scale
    cropExtent.origin.y *= scale
    cropExtent.size.width *= scale
    cropExtent.size.height *= scale

    imageSize.width *= scale
    imageSize.height *= scale

    modified.cropExtent = Self.fittingRect(
      rect: cropExtent,
      in: imageSize,
      respectingAspectRatio: nil
    )
    modified.imageSize = imageSize

    return modified
  }

  /**
   Set new aspect ratio with updating cropping extent.
   Currently, the cropping extent changes to maximum size in the size of image.

   - TODO: Resizing cropping extent with keeping area by new aspect ratio.
   */
  public mutating func updateCropExtent(toFitAspectRatio newAspectRatio: PixelAspectRatio) {

    let maxSize = newAspectRatio.sizeThatFits(in: imageSize)

    let proposed = CGRect(
      origin: .init(
        x: (imageSize.width - maxSize.width) / 2,
        y: (imageSize.height - maxSize.height) / 2
      ),
      size: maxSize
    )

    self._usedAspectRatio = newAspectRatio

    self.cropExtent = Self.fittingRect(
      rect: proposed,
      in: imageSize,
      respectingAspectRatio: newAspectRatio
    )
  }

  /**
   (Won't do mutating, If current aspect ratio is the same with specified aspect ratio.)
   Set new aspect ratio with updating cropping extent.
   Currently, the cropping extent changes to maximum size in the size of image.

   */
  public mutating func updateCropExtentIfNeeded(toFitAspectRatio newAspectRatio: PixelAspectRatio) {
    // FIXME: it won't perform correctly. won't match values as using floating point value
    /*
     Depends on the size of image, it can not always express the exact value of given aspect-ratio.
     - image-size: (7864.0, 5248.0)
     - aspect ratio: 1.0:1.2 (0.8333333333)
     - calculated fitting image size with ratio: (1745.0, 0.0, 4373.0, 5247.0)
     - (4373.0 : 5247.0) -> 0.8334286259
     */
    guard _usedAspectRatio != newAspectRatio else {
      return
    }
    updateCropExtent(toFitAspectRatio: newAspectRatio)
  }

  public mutating func purgeAspectRatio() {
    _usedAspectRatio = nil
  }

  /**
   Updates the crop extent to fit bounding box that comes from Vision.framework.
   */
  public mutating func updateCropExtent(
    toFitBoundingBox boundingBox: CGRect,
    respectingApectRatio: PixelAspectRatio?
  ) {

    var proposed = cropExtent

    let transform = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -proposed.height)

    let scale = CGAffineTransform.identity.scaledBy(x: proposed.width, y: proposed.height)

    proposed =
      boundingBox
      .applying(scale)
      .applying(transform)

    self._usedAspectRatio = respectingApectRatio

    self.cropExtent = Self.fittingRect(
      rect: proposed,
      in: imageSize,
      respectingAspectRatio: respectingApectRatio
    )
  }

  public mutating func updateCropExtent(
    _ cropExtent: CGRect
  ) {
    self.cropExtent = cropExtent
  }

  private static func fittingRect(
    rect: CGRect,
    in imageSize: CGSize,
    respectingAspectRatio: PixelAspectRatio?
  ) -> CGRect {

    var fixed = rect

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

    fixed = CGRect(origin: .zero, size: imageSize).intersection(fixed)

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

        let newRect = aspectRatio.rectThatFits(in: maxRect)

        fixed = newRect

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

    #if DEBUG
      EngineLog.debug(
        """
        [Normalizing CropExtent]
        Output: \(fixed)
          - resultAspectRatio: \(PixelAspectRatio(fixed.size)._minimized().localizedText)
          - source: \(rect)
          - imageSize: \(imageSize)
          - respectingApectRatio: \(respectingAspectRatio.map { "\($0.width):\($0.height)" } ?? "null")
        """
      )
    #endif

    return fixed
  }

  /*
  @objc
  public func debugQuickLookObject() -> AnyObject? {

    let path = UIBezierPath(rect: CGRect(origin: .zero, size: imageSize))

    return path
  }
   */
}
