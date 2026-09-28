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

import CoreGraphics

/// The proportion between a width and a height.
///
/// Equality and hashing compare the proportion, not the authored numbers:
/// `4:3`, `8:6` and a `4032x3024` image size are the same value, so they
/// collapse to one element in a `Set` and find the same `Dictionary` entry.
public struct AspectRatio: Hashable, CustomReflectable, Identifiable, Sendable {

  /// Identifies the exact width and height pair, not the proportion.
  ///
  /// This is deliberately finer than `==`, so a `ForEach` over presets such
  /// as `5:4` and `10:8` keeps a separate, stable row for each.
  public var id: String {
    return "\(width.bitPattern), \(height.bitPattern)"
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs._comparingValue == rhs._comparingValue
  }

  /// Hashes the same proportion that `==` compares, so equal ratios always
  /// hash equally.
  public func hash(into hasher: inout Hasher) {
    hasher.combine(_comparingValue)
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

  public func size(byWidth: CGFloat) -> CGSize {
    CGSize(width: byWidth, height: height(forWidth: byWidth))
  }

  /// Returns a new instance that swapped height and width
  public func swapped() -> AspectRatio {
    .init(width: height, height: width)
  }

  public func sizeThatFits(in boundingSize: CGSize) -> CGSize {

    let widthRatio = boundingSize.width / width
    let heightRatio = boundingSize.height / height
    var size = boundingSize

    if widthRatio < heightRatio {
      size.height = boundingSize.width / width * height
    } else if heightRatio < widthRatio {
      size.width = boundingSize.height / height * width
    }

    return CGSize(
      width: size.width,
      height: size.height
    )

  }

  public func rectThatFits(in boundingRect: CGRect) -> CGRect {
    let size = sizeThatFits(in: boundingRect.size)
    var origin = boundingRect.origin
    origin.x += (boundingRect.size.width - size.width) / 2.0
    origin.y += (boundingRect.size.height - size.height) / 2.0

    return CGRect(origin: origin, size: size)
  }

  /// The same proportion in its lowest terms, such as `4:3` for a
  /// `4032x3024` image size.
  public func reduced() -> Self {
    func gcd(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
      let r = a.truncatingRemainder(dividingBy: b)
      if r.isNormal {
        return gcd(b, r)
      } else {
        return b
      }
    }

    let v = gcd(width, height)

    return .init(width: width / v, height: height / v)
  }

  public var _comparingValue: CGFloat {
    return (height / width)
  }

  public static var square: Self {
    .init(width: 1, height: 1)
  }

  public var customMirror: Mirror {

    return Mirror(
      self,
      children: [
        "width": width,
        "height": height,
        "ratio": _comparingValue
      ],
      displayStyle:.struct
    )
  }

}
