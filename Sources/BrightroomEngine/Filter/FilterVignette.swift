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
import CoreImage

public struct FilterVignette: Filtering, Equatable, Codable, Sendable {

  public static let range: ParameterRange<Double, FilterVignette> = .init(min: 0, max: 2)

  public var value: Double = 0

  public init() {

  }
    
  public func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {

    guard abs(value) > 0.0001 else {
      return image
    }

    let extent = image.extent
    let radius = max(extent.width, extent.height) * 0.5

    return image.applyingFilter(
      "CIVignetteEffect",
      parameters: [
        kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
        kCIInputRadiusKey: radius,
        kCIInputIntensityKey: value,
        "inputFalloff": 0.5,
      ]
    )
    .cropped(to: extent)
  }
}
