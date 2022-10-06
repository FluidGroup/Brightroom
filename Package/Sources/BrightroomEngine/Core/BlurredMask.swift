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

public struct BlurredMask: GraphicsDrawing {
  public var paths: [DrawnPath]

  public init(paths: [DrawnPath]) {
    self.paths = paths
  }

  public func draw(in context: CGContext) {
    guard !paths.isEmpty else {
      return
    }

    let mainContext = context

    guard
      let cglayer = CGLayer(
        mainContext,
        size: mainContext.boundingBoxOfClipPath.size,
        auxiliaryInfo: nil
      ),
      let layerCGContext = cglayer.context
    else {
      assert(false, "Failed to create CGLayer")
      return
    }

    renderDrawings: do {
      let ciContext = CIContext(
        cgContext: layerCGContext,
        options: [
          .workingFormat: CIFormat.RGBA8,
          .highQualityDownsample: true,
          .cacheIntermediates: false,
        ]
      )
      let ciBlurredImage = BlurredMask.blur(image: CIImage(cgImage: context.makeImage()!))!

      /**
       To keep wide-color(DisplayP3), use createCGImage instead drawing with CIContext
       */
      let cgImage = ciContext.createCGImage(
        ciBlurredImage,
        from: ciBlurredImage.extent,
        format: CIFormat.RGBA8,
        colorSpace: CGColorSpace.init(name: CGColorSpace.displayP3),
        deferred: true
      )!

      UIGraphicsPushContext(layerCGContext)

      paths.forEach { path in
        layerCGContext.saveGState()
        layerCGContext.translateBy(
          x: -mainContext.boundingBoxOfClipPath.minX,
          y: -mainContext.boundingBoxOfClipPath.minY
        )
        path.draw(in: layerCGContext)

        layerCGContext.restoreGState()
      }

      layerCGContext.saveGState()

      layerCGContext.setBlendMode(.sourceIn)

      layerCGContext.draw(cgImage, in: ciBlurredImage.extent)

      layerCGContext.restoreGState()

      UIGraphicsPopContext()
    }

    renderLayer: do {
      UIGraphicsPushContext(mainContext)

      mainContext.draw(
        cglayer,
        at: .init(
          x: mainContext.boundingBoxOfClipPath.minX,
          y: mainContext.boundingBoxOfClipPath.minY
        )
      )

//      #if DEBUG
//      paths.forEach { path in
//        path.draw(in: mainContext, canvasSize: canvasSize)
//      }
//      #endif

      UIGraphicsPopContext()
    }
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
          "inputRadius": _radius,
        ]
      )
      .cropped(to: image.extent)

    return outputImage
  }
}
