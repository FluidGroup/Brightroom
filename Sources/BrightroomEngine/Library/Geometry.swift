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

import CoreImage
import UIKit

public enum Geometry {

  public static func sizeThatAspectFit(size: CGSize, maxPixelSize: CGFloat) -> CGSize {

    guard size.width >= maxPixelSize || size.height >= maxPixelSize else {
      return size
    }

    var s = size

    if size.width > size.height {
      s.width = maxPixelSize
      s.height *= maxPixelSize / size.width
    } else {
      s.height = maxPixelSize
      s.width *= maxPixelSize / size.height
    }

    s.width.round()
    s.height.round()

    return s
  }

  public static func sizeThatAspectFit(aspectRatio: CGSize, boundingSize: CGSize) -> CGSize {
    let widthRatio = boundingSize.width / aspectRatio.width
    let heightRatio = boundingSize.height / aspectRatio.height
    var size = boundingSize

    if widthRatio < heightRatio {
      size.height = boundingSize.width / aspectRatio.width * aspectRatio.height
    } else if heightRatio < widthRatio {
      size.width = boundingSize.height / aspectRatio.height * aspectRatio.width
    }

    return CGSize(
      width: ceil(size.width),
      height: ceil(size.height)
    )
  }

  public static func sizeThatAspectFill(aspectRatio: CGSize, minimumSize: CGSize) -> CGSize {
    let widthRatio = minimumSize.width / aspectRatio.width
    let heightRatio = minimumSize.height / aspectRatio.height

    var size = minimumSize

    if widthRatio > heightRatio {
      size.height = minimumSize.width / aspectRatio.width * aspectRatio.height
    } else if heightRatio > widthRatio {
      size.width = minimumSize.height / aspectRatio.height * aspectRatio.width
    }

    return CGSize(
      width: ceil(size.width),
      height: ceil(size.height)
    )
  }

  public static func rectThatAspectFit(aspectRatio: CGSize, boundingRect: CGRect) -> CGRect {
    let size = sizeThatAspectFit(aspectRatio: aspectRatio, boundingSize: boundingRect.size)
    var origin = boundingRect.origin
    origin.x += (boundingRect.size.width - size.width) / 2.0
    origin.y += (boundingRect.size.height - size.height) / 2.0
    return CGRect(origin: origin, size: size)
  }

  public static func rectThatAspectFill(aspectRatio: CGSize, minimumRect: CGRect) -> CGRect {
    let size = sizeThatAspectFill(aspectRatio: aspectRatio, minimumSize: minimumRect.size)
    var origin = CGPoint.zero
    origin.x = (minimumRect.size.width - size.width) / 2.0
    origin.y = (minimumRect.size.height - size.height) / 2.0
    return CGRect(origin: origin, size: size)
  }

  public static func diagonalRatio(to: CGSize, from: CGSize) -> CGFloat {
    let _from = sqrt(pow(from.height, 2) + pow(from.width, 2))
    let _to = sqrt(pow(to.height, 2) + pow(to.width, 2))

    return _to / _from
  }
}

extension CGSize {

  /**
   Creates an instance from CGPoint.
   The values would be rounded.
   */
  init(image: CIImage) {
    self = image.extent.size
  }

  init(image: UIImage) {
    self.init(
      width: image.size.width * image.scale,
      height: image.size.height * image.scale
    )
  }

  var aspectRatio: PixelAspectRatio {
    .init(width: CGFloat(width), height: CGFloat(height))
  }

  func scaled(maxPixelSize: CGFloat) -> CGSize {

    Geometry.sizeThatAspectFit(size: self, maxPixelSize: maxPixelSize)
  }
}

public struct PixelAspectRatio: Hashable {

  public static func == (lhs: Self, rhs: Self) -> Bool {
    (lhs.height / lhs.width) == (rhs.height / rhs.width)
  }

  public var width: CGFloat
  public var height: CGFloat

  public init(width: CGFloat, height: CGFloat) {
    self.width = width
    self.height = height
  }

  public init(_ cgSize: CGSize) {
    self.init(width: cgSize.width, height: cgSize.height)
  }

  public func height(forWidth: CGFloat) -> CGFloat {
    forWidth * (height / width)
  }

  public func width(forHeight: CGFloat) -> CGFloat {
    forHeight * (width / height)
  }

  public func size(byWidth: CGFloat) -> CGSize {
    CGSize(width: byWidth, height: height(forWidth: byWidth))
  }

  public func size(byHeight: CGFloat) -> CGSize {
    CGSize(width: width(forHeight: byHeight), height: byHeight)
  }

  public func asCGSize() -> CGSize {
    .init(width: width, height: height)
  }

  /// Returns a new instance that swapped height and width
  public func swapped() -> PixelAspectRatio {
    .init(width: height, height: width)
  }

  public func sizeThatFillRounding(in boundingSize: CGSize) -> CGSize {
    let widthRatio = boundingSize.width / width
    let heightRatio = boundingSize.height / height
    var size = boundingSize

    if widthRatio < heightRatio {
      size.height = boundingSize.width / width * height
    } else if heightRatio < widthRatio {
      size.width = boundingSize.height / height * width
    }

    return CGSize(
      width: size.width.rounded(.down),
      height: size.height.rounded(.down)
    )
  }

  public func sizeThatFitsWithRounding(in boundingSize: CGSize) -> CGSize {

    let widthRatio = boundingSize.width / width
    let heightRatio = boundingSize.height / height
    var size = boundingSize

    if widthRatio < heightRatio {
      size.height = boundingSize.width / width * height
    } else if heightRatio < widthRatio {
      size.width = boundingSize.height / height * width
    }

    return CGSize(
      width: size.width.rounded(.down),
      height: size.height.rounded(.down)
    )

  }

  public func rectThatFitsWithRounding(in boundingRect: CGRect) -> CGRect {
    let size = sizeThatFitsWithRounding(in: boundingRect.size)
    var origin = boundingRect.origin
    origin.x += (boundingRect.size.width - size.width) / 2.0
    origin.y += (boundingRect.size.height - size.height) / 2.0

    origin.x.round(.down)
    origin.y.round(.down)

    return CGRect(origin: origin, size: size)
  }

  public func rectThatFillWithRounding(in boundingRect: CGRect) -> CGRect {
    let size = sizeThatFillRounding(in: boundingRect.size)
    var origin = CGPoint.zero
    origin.x = (boundingRect.size.width - size.width) / 2.0
    origin.y = (boundingRect.size.height - size.height) / 2.0

    origin.x.round(.down)
    origin.y.round(.down)
    return CGRect(origin: origin, size: size)
  }

  public func _minimized() -> Self {
    func gcd(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
      let r = a.truncatingRemainder(dividingBy: b)
      if r != 0 {
        return gcd(b, r)
      } else {
        return b
      }
    }

    let v = gcd(width, height)

    return .init(width: width / v, height: height / v)
  }

  public var localizedText: String {
    "\(width):\(height)"
  }

  public static var square: Self {
    .init(width: 1, height: 1)
  }

}

