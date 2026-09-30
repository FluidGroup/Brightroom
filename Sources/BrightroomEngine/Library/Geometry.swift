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

public enum Geometry: Sendable {

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
}

extension CGSize {

  func scaled(maxPixelSize: CGFloat) -> CGSize {

    Geometry.sizeThatAspectFit(size: self, maxPixelSize: maxPixelSize)
  }
}
