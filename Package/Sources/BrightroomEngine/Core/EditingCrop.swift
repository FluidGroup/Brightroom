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

/// A representation of cropping extent in Image.
public struct EditingCrop: Equatable {
  public enum Rotation: Equatable, CaseIterable {
    /// 0 degree - default
    case angle_0

    /// 90 degree
    case angle_90

    /// 180 degree
    case angle_180

    /// 270 degree
    case angle_270

    public var angle: CGFloat {
      switch self {
      case .angle_0:
        return 0
      case .angle_90:
        return -CGFloat.pi / 2
      case .angle_180:
        return -CGFloat.pi
      case .angle_270:
        return CGFloat.pi / 2
      }
    }

    public var transform: CGAffineTransform {
      .init(rotationAngle: angle)
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

  /// The dimensions in pixel for the image.
  /// Applied image-orientation.
  public var imageSize: CGSize

  /// The rectangle that specifies the extent of the cropping.
  public private(set) var cropExtent: CGRect

  /// The angle that specifies rotation for the image.
  public var rotation: Rotation = .angle_0

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
    scaleToRestore: CGFloat = 1
  ) {
    self.imageSize = imageSize
    self.cropExtent = Self.fittingRect(rect: cropRect, in: imageSize, respectingAspectRatio: nil)
    self.rotation = rotation
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

  private func scaled(_ scale: CGFloat) -> Self {

    var modified = self

    var cropExtent = modified.cropExtent
    var imageSize = modified.imageSize

    cropExtent.origin.x *= scale
    cropExtent.origin.y *= scale
    cropExtent.size.width *= scale
    cropExtent.size.height *= scale

    imageSize.width *= scale
    imageSize.height *= scale
    imageSize.width.round(.down)
    imageSize.height.round(.down)

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

    let maxSize = newAspectRatio.sizeThatFitsWithRounding(in: imageSize)

    let proposed = CGRect(
      origin: .init(
        x: (imageSize.width - maxSize.width) / 2,
        y: (imageSize.height - maxSize.height) / 2
      ),
      size: maxSize
    )

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
    guard PixelAspectRatio(cropExtent.size) != newAspectRatio else {
      return
    }
    updateCropExtent(toFitAspectRatio: newAspectRatio)
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

    self.cropExtent = Self.fittingRect(
      rect: proposed,
      in: imageSize,
      respectingAspectRatio: respectingApectRatio
    )
  }

  /// Updates cropExtent with new specified rect and normalizing value using aspectRatio(optional).
  /// cropExtent would be rounded in order to drop floating point value for fitting pixel.
  /// With specifing `respectingAspectRatio`, it fixes cropExtent's size.
  ///
  /// - Parameters:
  ///   - cropExtent:
  ///   - respectingAspectRatio:
  public mutating func updateCropExtentNormalizing(
    _ cropExtent: CGRect,
    respectingAspectRatio: PixelAspectRatio?
  ) {
    self.cropExtent = Self.fittingRect(
      rect: cropExtent,
      in: imageSize,
      respectingAspectRatio: respectingAspectRatio
    )
  }

  private static func fittingRect(
    rect: CGRect,
    in imageSize: CGSize,
    respectingAspectRatio: PixelAspectRatio?
  ) -> CGRect {

    var fixed = rect

    func containsFractionInCGFloat(_ value: CGFloat) -> Bool {
      Int(exactly: value) == nil
    }

    func rectIsPixelPerfect(_ rect: CGRect) -> Bool {
      guard containsFractionInCGFloat(rect.origin.x) == false else { return false }
      guard containsFractionInCGFloat(rect.origin.y) == false else { return false }
      guard containsFractionInCGFloat(rect.size.width) == false else { return false }
      guard containsFractionInCGFloat(rect.size.height) == false else { return false }
      return true
    }

    func clamp<T: Comparable>(value: T, lower: T, upper: T) -> T {
      return min(max(value, lower), upper)
    }

    /*
     Drops decimal fraction
     */

    fixed.origin.x.round(.down)
    fixed.origin.y.round(.down)
    fixed.size.width.round(.down)
    fixed.size.height.round(.down)

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

        let newRect = aspectRatio.rectThatFitsWithRounding(in: maxRect)

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

      assert(rectIsPixelPerfect(fixed))
    }

    #if DEBUG
      EngineLog.debug(
        """
        Normalizing CropExtent
        => \(fixed)
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

extension CIImage {
  func cropped(to _cropRect: EditingCrop) -> CIImage {

    let targetImage = self
    var cropRect = _cropRect.cropExtent

    cropRect.origin.y = targetImage.extent.height - cropRect.minY - cropRect.height

    let croppedImage =
      targetImage
      .cropped(to: cropRect)

    return croppedImage
  }
}
