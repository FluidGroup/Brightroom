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

public struct BlurredMask : GraphicsDrawing {

  public var paths: [DrawnPathInRect]

  public init(paths: [DrawnPathInRect]) {
    self.paths = paths
  }

  public func draw(in context: CGContext, canvasSize: CGSize) {

    guard !paths.isEmpty else {
      return
    }

    let mainContext = context
    let size = canvasSize

    guard
      let cglayer = CGLayer(mainContext, size: size, auxiliaryInfo: nil),
      let layerContext = cglayer.context else {
        assert(false, "Failed to create CGLayer")
        return
    }

    let ciContext = CIContext(cgContext: layerContext, options: [:])
    let ciImage = BlurredMask.blur(image: CIImage(image: UIGraphicsGetImageFromCurrentImageContext()!)!)!

    UIGraphicsPushContext(layerContext)

    paths.forEach { path in
      layerContext.saveGState()

      let scale = Geometry.diagonalRatio(to: canvasSize, from: path.inRect.size)

      layerContext.scaleBy(x: scale, y: scale)
      path.draw(in: layerContext, canvasSize: canvasSize)

      layerContext.restoreGState()
    }

    layerContext.saveGState()

    layerContext.setBlendMode(.sourceIn)
    layerContext.translateBy(x: 0, y: canvasSize.height)
    layerContext.scaleBy(x: 1, y: -1)

    ciContext.draw(ciImage, in: ciImage.extent, from: ciImage.extent)

    layerContext.restoreGState()

    UIGraphicsPopContext()

    UIGraphicsPushContext(mainContext)

    mainContext.draw(cglayer, at: .zero)

    UIGraphicsPopContext()
  }

  public static func blur(image: CIImage) -> CIImage? {

    func radius(_ imageExtent: CGRect) -> Double {

      let v = Double(sqrt(pow(imageExtent.width, 2) + pow(imageExtent.height, 2)))
      return v / 20 // ?
    }

    // let min: Double = 0
    let max: Double = 100
    let value: Double = 40

    let _radius = radius(image.extent) * value / max

    let outputImage = image
      .clamped(to: image.extent)
      .applyingFilter(
        "CIGaussianBlur",
        parameters: [
          "inputRadius" : _radius
        ])
      .cropped(to: image.extent)

    return outputImage
  }
}
