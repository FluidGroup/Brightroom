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

public struct FilterPreset: Filtering {

  public static let range: ParameterRange<Double, FilterPreset> = .init(min: 0, max: 1)

  public let name: String
  public let identifier: String
  public let filters: [AnyFilter]
  public let userInfo: [String : AnyHashable]

  public init(
    name: String,
    identifier: String,
    filters: [AnyFilter],
    userInfo: [String : AnyHashable]
  ) {

    self.name = name
    self.identifier = identifier
    self.filters = filters
    self.userInfo = userInfo
  }

  public func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {

    filters.reduce(image) { (image, filter) -> CIImage in
      filter.apply(to: image, sourceImage: sourceImage)
    }

  }
}

public struct PreviewFilterPreset: Hashable {

  /**
   An CIImage applied preset.
   Using ``MetalImageView`` may get better performance to display instead of ``UIImageView``.
   */
  public let image: CIImage
  
  public let filter: FilterPreset

  init(sourceImage: CIImage, filter: FilterPreset) {
    self.filter = filter
    self.image = filter.apply(to: sourceImage, sourceImage: sourceImage)
  }

}
