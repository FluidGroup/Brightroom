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

public struct PreviewFilterColorCube : Equatable {

  private enum Static {
    static let ciContext = CIContext(options: [.useSoftwareRenderer : false])
    static let heatingQueue = DispatchQueue.init(label: "me.muukii.PixelEngine.Preheat", attributes: [.concurrent])
  }

  public let image: CIImage
  public let filter: FilterColorCube

  init(sourceImage: CIImage, filter: FilterColorCube) {
    self.filter = filter
    self.image = filter.apply(to: sourceImage, sourceImage: sourceImage)
  }

  public func preheat() {
    Static.heatingQueue.async {
      _ = Static.ciContext.createCGImage(self.image, from: self.image.extent)
    }
  }
}

/// A Filter using LUT Image (backed by CIColorCubeWithColorSpace)
/// About LUT Image -> https://en.wikipedia.org/wiki/Lookup_table
public struct FilterColorCube : Filtering, Equatable {

  public static let range: ParameterRange<Double, FilterColorCube> = .init(min: 0, max: 1)

  public let filter: CIFilter

  public let name: String
  public let identifier: String
  public var amount: Double = 1

  public init(
    name: String,
    identifier: String,
    lutImage: Image,
    dimension: Int,
    colorSpace: CGColorSpace = CGColorSpace.init(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    ) {

    self.name = name
    self.identifier = identifier
    self.filter = ColorCube.makeColorCubeFilter(lutImage: lutImage, dimension: dimension, colorSpace: colorSpace)
  }

  public func apply(to image: CIImage, sourceImage: CIImage) -> CIImage {

    let f = filter.copy() as! CIFilter

    f.setValue(image, forKeyPath: kCIInputImageKey)
    if let colorSpace = image.colorSpace {
      f.setValue(colorSpace, forKeyPath: "inputColorSpace")
    }

    let background = image
    let foreground = f.outputImage!.applyingFilter(
      "CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount)),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
    ])

    let composition = CIFilter(
      name: "CISourceOverCompositing",
      parameters: [
        kCIInputImageKey : foreground,
        kCIInputBackgroundImageKey : background
      ])!

    return composition.outputImage!

  }
}
