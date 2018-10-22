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

import Foundation

public enum Geometry {

  public static func sizeThatAspectFit(aspectRatio: CGSize, boundingSize: CGSize) -> CGSize {

    let widthRatio = boundingSize.width / aspectRatio.width
    let heightRatio = boundingSize.height / aspectRatio.height
    var size = boundingSize

    if widthRatio < heightRatio {
      size.height = boundingSize.width / aspectRatio.width * aspectRatio.height
    }
    else if (heightRatio < widthRatio) {
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
      size.height = minimumSize.width / aspectRatio.width * aspectRatio.height;
    }
    else if heightRatio > widthRatio {
      size.width = minimumSize.height / aspectRatio.height * aspectRatio.width;
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
