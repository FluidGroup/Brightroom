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
import CoreImage

public struct FilterSharpen: Filtering, Equatable, Codable {
  
  public enum Params {
    public static let radius: ParameterRange<Double, FilterSharpen> = .init(min: 0, max: 20)
    public static let sharpness: ParameterRange<Double, FilterSharpen> = .init(min: 0, max: 1)
  }

  public var sharpness: Double = 0
  public var radius: Double = 0

  public init() {

  }

  public func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {

    let _radius = RadiusCalculator.radius(value: radius, max: FilterGaussianBlur.range.max, imageExtent: image.extent)

    return
      image
        .applyingFilter(
          "CISharpenLuminance", parameters: [
            "inputRadius" : _radius,
            "inputSharpness": sharpness,
            ])
  }
}
